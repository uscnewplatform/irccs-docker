#!/usr/bin/env python3
"""
Allineamento di PIU' bracci terapeutici a un braccio "master" (es. Treme+Durva), con creazione di
CarePlan / Questionnaire mancanti. Evoluzione di align_therapy_branch.py (stessa libreria di helper).

Per ogni target della config:
  - step "shared"    : il CarePlan del target punta ai Questionnaire del master (stesso id ovunque);
  - step "trattamento": come shared, ma lo slot "Somministrazione" resta il Questionnaire del farmaco
                       del target (o ne viene clonato uno da `somm_from`); "Assunzione Farmaco" esce;
  - step "sae"       : Questionnaire per terapia (SAE, SAE Follow-up, CTCAE SAE): contenuto sincronizzato
                       dal master, titoli/descrizioni/precompilazione propri; i mancanti vengono creati;
  - CarePlan mancanti: creati clonando quello del master e agganciati all'ActivityDefinition;
  - Questionnaire sostituiti e non piu' referenziati: `retired`.
Gruppi di eleggibilita' e Somministrazione non vengono toccati. Le QuestionnaireResponse non si ripuntano.

Modi: backup | dry-run | apply --yes [--targets A,B] | restore --yes
Credenziali: IRCCS_USER / IRCCS_PASSWORD (o IRCCS_TOKEN).
"""
import argparse, copy, hashlib, json, os, re, sys, uuid
from datetime import datetime, timezone
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import align_therapy_branch as base
from align_therapy_branch import Fhir, norm, ident, refs_in, normalize_extensions, strip_meta, diff_dict, ext_key

SD = base.SD
PREPOP = SD + "prepopulate-from-questionnaire-response"
RENDER = SD + "render-as-patient-questionnaire"
STEP_ORDER = ["Dati Basali", "Trattamenti Locoregionali", "Stadiazione", "Farmaci E Patologie Concomitanti",
              "Trattamento", "Follow Up", "SAE"]


def fill(tpl, t):
    return tpl.format(drug=t["drug"], line=t["line"])


def canon(r):
    """Risorsa senza meta e con le extension in ordine canonico: l'ordine delle extension non e' una differenza
    (l'import e copy_group_ids.py mettono i group_ids in posizioni diverse)."""
    r = copy.deepcopy(strip_meta(r))
    if isinstance(r.get("extension"), list):
        r["extension"] = sorted(r["extension"], key=lambda e: json.dumps(e, sort_keys=True))
    return r


MASTER_DRUGS = ("Tremelimumab", "Durvalumab", "Atezolizumab", "Bevacizumab")
ECRF_OPTION = "https://irccs-pascale.it/fhir/CodeSystem/ecrf-option"


def duid(*parts):
    """UUID deterministico: SAE e SAE Follow-up della stessa linea condividono i linkId e i dry-run restano a 0."""
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "jli-sae:" + ":".join(parts)))


def restrict_drugs(items, drugs, key):
    """Riscrive gli item per-farmaco del SAE (menu "Trattamento in corso", date per farmaco, Nesso,
    Provvedimenti presi) lasciando solo `drugs`, nell'ordine dato. I farmaci gia' nel master
    mantengono i loro id; i nuovi sono clonati dal primo item per-farmaco con id deterministici."""
    items = copy.deepcopy(items)

    def regen(it, drug):
        it["linkId"] = duid(key, drug, it["linkId"])
        for o in it.get("answerOption", []):
            vc = o.get("valueCoding")
            if vc and vc.get("id"):
                vc["id"] = duid(key, drug, vc["id"])
        for ch in it.get("item", []):
            regen(ch, drug)

    def walk(lst):
        idx = [i for i, it in enumerate(lst) if it.get("text") in MASTER_DRUGS and it["type"] in ("group", "choice")]
        if idx:
            existing = {lst[i]["text"]: lst[i] for i in idx}
            template = lst[idx[0]]
            built = []
            for d in drugs:
                if d in existing:
                    built.append(existing[d])
                    continue
                n = copy.deepcopy(template)
                n["text"] = d
                regen(n, d)
                for e in n.get("enableWhen", []):
                    e["answerCoding"]["code"] = d.lower()
                built.append(n)
            rest = [it for i, it in enumerate(lst) if i not in idx]
            rest[idx[0]:idx[0]] = built
            lst[:] = rest
        for it in lst:
            if it["type"] == "choice" and (it.get("text") or "").startswith("Trattamento in corso") and it.get("answerOption") \
                    and (it["answerOption"][0].get("valueCoding") or {}).get("system") == ECRF_OPTION:
                old = {(o["valueCoding"].get("display")): o for o in it["answerOption"]}
                it["answerOption"] = [old[d] if d in old else {"valueCoding": {
                    "id": duid(key, d, "opt"), "system": ECRF_OPTION, "code": d.lower(), "display": d}} for d in drugs]
            walk(it.get("item", []))
    walk(items)
    return items


class Tree:
    def __init__(self, cfg, f, only=None):
        self.cfg, self.f = cfg, f
        self.cache, self.orig = {}, {}
        self.writes = {}          # ref -> risorsa modificata
        self.creates = []         # dict(key, type, res, params)
        self.notes = []
        self.only = set(only.split(",")) if only else None
        self.final_refs = set()   # Questionnaire referenziati a fine lavoro da qualunque CarePlan toccato
        self.old_refs = set()     # Questionnaire che un CarePlan target referenziava prima
        self.n = 0
        self.sae_owner = {}       # gruppo SAE -> Questionnaire SAE del proprietario (anche se ancora da creare)

    # ── I/O con cache
    def read(self, ref):
        if ref.startswith("NEW:"):
            return next(c["res"] for c in self.creates if c["key"] == ref)
        if ref not in self.cache:
            self.cache[ref] = self.f.get(ref)
            self.orig[ref] = copy.deepcopy(self.cache[ref])
        return self.cache[ref]

    def note(self, lvl, txt):
        self.notes.append((lvl, txt))

    def touch(self, ref):
        r = self.read(ref)
        self.writes[ref] = r
        return r

    def new(self, rtype, res, params=None):
        if params is None:
            params = f"?patientJourneyId={self.cfg['study']}" if rtype in ("Questionnaire", "CarePlan", "ActivityDefinition", "PlanDefinition") else ""
        self.n += 1
        key = f"NEW:{rtype}:{self.n}#"
        self.creates.append({"key": key, "type": rtype, "res": res, "params": params})
        return key

    # ── helpers FHIR
    def careplans_of(self, ad_ref):
        ad = self.read(ad_ref)
        out = {}
        for ra in ad.get("relatedArtifact", []):
            r = ra.get("resource", "")
            if r.startswith("CarePlan/"):
                out[norm(self.read(r).get("title"))] = r
        return out

    def qrefs(self, cp):
        out = []
        for a in cp.get("activity", []):
            for o in a.get("outcomeReference", []):
                out.append(o["reference"])
        return out

    # ── pianificazione
    def run(self):
        c = self.cfg
        self.master_cps = self.careplans_of(c["master_activity"])
        for t in c["targets"]:
            if self.only and t["label"] not in self.only:
                continue
            if t.get("optional") and not self.only:
                continue
            self.plan_target(t)
        self.plan_external()
        self.retire_replaced()
        self.normalize_all()

    def plan_target(self, t):
        self.note("TARGET", f"{t['label']}  ({t['activity']})")
        cps = self.careplans_of(t["activity"])
        ad_new_cps = []
        for step in STEP_ORDER:
            if t.get("only_steps") and step not in t["only_steps"]:
                continue
            key = norm(step)
            mref = self.master_cps.get(key)
            if not mref:
                self.note("ERR", f"master senza step {step}")
                continue
            tref = cps.get(key) or cps.get(norm(step.replace("Follow Up", "Follow up")))
            if not tref and step == "Dati Basali":
                tref = cps.get("dati basali")
            if not tref:
                if not t.get("create_missing"):
                    self.note("SKIP", f"   {step}: assente nel target (create_missing=false)")
                    continue
                tref = self.new("CarePlan", self.clone_careplan(self.read(mref)))
                ad_new_cps.append(tref)
                self.note("CREATE", f"   CarePlan '{step}' (nuovo, clonato da {mref})")
            self.plan_step(t, step, mref, tref)
        if ad_new_cps:
            ad = self.touch(t["activity"])
            ra = ad.setdefault("relatedArtifact", [])
            first_group = next((i for i, r in enumerate(ra) if r.get("type") == "composed-of"), len(ra))
            for k in ad_new_cps:
                ra.insert(first_group, {"type": "documentation", "resource": k})
                first_group += 1
            self.note("AD", f"   {t['activity']} riceve {len(ad_new_cps)} CarePlan")

    def clone_careplan(self, mcp):
        c = copy.deepcopy(mcp)
        for k in ("id", "meta", "text"):
            c.pop(k, None)
        c["activity"] = []
        # le duplicateCrfItem del master puntano ai SUOI Questionnaire SAE: mai ereditarle, altrimenti
        # plan_sae li scambia per quelli del braccio e li sovrascrive
        c["extension"] = [e for e in c.get("extension", []) if e["url"] != "duplicateCrfItem"]
        return c

    def plan_step(self, t, step, mref, tref):
        mcp = self.read(mref)
        tcp = self.read(tref)
        before = copy.deepcopy(tcp)
        old_q = self.qrefs(tcp)
        self.old_refs |= {q for q in old_q if not q.startswith("NEW:")}
        cp = tcp
        # campi testuali dal master (con nome del farmaco per Trattamento)
        if step == "Trattamento":
            txt = fill(self.cfg["trattamento_text"], t)
            cp["title"] = mcp["title"]; cp["description"] = txt; cp["note"] = [{"text": txt}]
        else:
            for fld in ("title", "description", "note"):
                if mcp.get(fld) is None: cp.pop(fld, None)
                else: cp[fld] = copy.deepcopy(mcp[fld])
        cp["status"], cp["intent"] = self.cfg["careplan_status"], self.cfg["careplan_intent"]
        keep_ext = [e for e in cp.get("extension", []) if e["url"] == "duplicateCrfItem"]
        cp["extension"] = [copy.deepcopy(e) for e in mcp.get("extension", []) if e["url"] != "duplicateCrfItem"]
        # Questionnaire desiderati
        mq = self.qrefs(mcp)
        if step == "SAE":
            sae, fol, cte = self.plan_sae(t, tcp, mcp, keep_ext)
            want = [sae, fol]
            self.final_refs.add(cte)
            cp["extension"] += [
                {"url": "duplicateCrfItem", "valueReference": {"reference": r}} for r in (cte, sae, fol)]
            # etichette bottone SAE Follow-up: come master
            cp["extension"] = [e for e in cp["extension"] if e["url"] not in ("duplicateCrfButtonLabel", "duplicateCrfButtonLabelEn")] + \
                [copy.deepcopy(e) for e in mcp["extension"] if e["url"] in ("duplicateCrfButtonLabel", "duplicateCrfButtonLabelEn")]
        elif step == "Trattamento":
            slot = self.cfg["somm_slot"]
            own = self.own_somm(t, old_q)
            want = [own if re.search(slot, ident(self.read(r)) or "") else r for r in mq]
            if own is None:
                want = [r for r in want if r is not None]
        else:
            want = list(mq)
        if not cp["extension"]:
            cp.pop("extension")
        cp["activity"] = [{"outcomeReference": [{"reference": r} for r in want]}]
        self.final_refs |= set(want)
        if not tref.startswith("NEW:"):
            if canon(cp) != canon(self.orig.get(tref, {})):
                self.writes[tref] = cp
                for d in diff_dict(before, cp):
                    self.note("CAREPLAN", f"   {step}: {d}")
            else:
                self.note("OK", f"   {step}: gia' allineato")
        else:
            self.note("CREATE", f"   {step}: Q = {[self.label(r) for r in want]}")
        # master: status/intent uniformi
        mw = copy.deepcopy(mcp)
        mw["status"], mw["intent"] = self.cfg["careplan_status"], self.cfg["careplan_intent"]
        if mw != mcp:
            self.writes[mref] = mw
            self.cache[mref] = mw
            self.note("CAREPLAN", f"   (master {mref}) status/intent -> active/plan")

    def label(self, ref):
        r = self.read(ref)
        return f"{ref.split(':')[0] if ref.startswith('NEW') else ref} '{ident(r)}'"

    # slot Somministrazione del farmaco
    def own_somm(self, t, old_q):
        pat = re.compile(self.cfg["own_somm_pattern"], re.I)
        own = [q for q in old_q if not q.startswith("NEW:") and pat.search(ident(self.read(q)) or "")]
        if own:
            if len(own) > 1:
                self.note("WARN", f"   {t['label']}: piu' Questionnaire farmaco {own}, uso {own[0]}")
            self.note("KEEP", f"   Somministrazione resta {self.label(own[0])}")
            return own[0]
        src_ad = t.get("somm_from")
        if not src_ad:
            self.note("ERR", f"   {t['label']}: nessun Questionnaire farmaco e nessun somm_from")
            return None
        src_cps = self.careplans_of(src_ad)
        scp = self.read(src_cps["trattamento"])
        cand = [q for q in self.qrefs(scp) if pat.search(ident(self.read(q)) or "")]
        if not cand:
            self.note("ERR", f"   {t['label']}: somm_from {src_ad} senza Questionnaire farmaco")
            return None
        q = copy.deepcopy(self.read(cand[0]))
        for k in ("id", "meta", "text"):
            q.pop(k, None)
        q["status"] = "active"
        key = self.new("Questionnaire", q, f"?patientJourneyId={self.cfg['study']}")
        self.note("CREATE", f"   Somministrazione clonata da {cand[0]} '{ident(q)}'")
        return key

    # SAE: tre Questionnaire per terapia
    def plan_sae(self, t, tcp, mcp, prev_dup=()):
        c = self.cfg
        m_sae = next(r for r in self.qrefs(mcp) if re.search(c["sae"]["trattamento"], ident(self.read(r)), re.I))
        m_fol = next(r for r in self.qrefs(mcp) if re.search(c["sae"]["followup"], ident(self.read(r)), re.I))
        m_cte = next(x["valueReference"]["reference"] for x in mcp["extension"]
                     if x["url"] == "duplicateCrfItem" and re.search(c["sae"]["ctcae"], ident(self.read(x["valueReference"]["reference"])), re.I))
        # esistenti del target (anche tra le duplicateCrfItem)
        cands = list(dict.fromkeys(self.qrefs(tcp) + [x["valueReference"]["reference"] for x in list(prev_dup) + tcp.get("extension", [])
                                                        if x["url"] == "duplicateCrfItem"]))
        # protezione: i Questionnaire SAE del master non sono mai del braccio (non sovrascriverli, non ritirarli)
        cands = [q for q in cands if q not in (m_sae, m_fol, m_cte)]
        self.old_refs |= {q for q in cands if not q.startswith("NEW:")}
        def find(pat):
            hit = [q for q in cands if re.search(pat, ident(self.read(q)) or "", re.I)]
            return hit[0] if hit else None
        t_sae, t_fol, t_cte = find(c["sae"]["trattamento"]), find(c["sae"]["followup"]), find(c["sae"]["ctcae"])
        line = t["line"]
        # SAE Trattamento condiviso per (tipo, linea): stesso id per tutti i bracci del gruppo, farmaci della linea
        gname = t.get("sae_group")
        grp = c.get("sae_groups", {}).get(gname) if gname else None
        shared_sae = None            # Questionnaire SAE condiviso (non si sincronizza qui, tranne il proprietario)
        drugs = grp.get("drugs") if grp else None
        if grp and grp.get("master"):
            shared_sae = m_sae
        elif grp and grp["owner"] != t["label"]:
            if gname in self.sae_owner:          # proprietario gia' pianificato (puo' essere un Questionnaire NEW:)
                shared_sae = self.sae_owner[gname]
            else:
                ot = next(x for x in c["targets"] if x["label"] == grp["owner"])
                ocp = self.careplans_of(ot["activity"])["sae"]
                shared_sae = next(r for r in self.qrefs(self.read(ocp)) if re.search(c["sae"]["trattamento"], ident(self.read(r)), re.I))
            self.note("SAE-SHARE", f"   {t['label']}: SAE condiviso = {shared_sae} (proprietario {grp['owner']})")
        elif grp:
            self.note("SAE-SHARE", f"   {t['label']}: proprietario del SAE del gruppo {gname}, farmaci {drugs}")
        if shared_sae:
            t_sae = shared_sae
        titles = {"sae": f"SAE TRATTAMENTO JLI{line}", "fol": f"SAE FOLLOWUP TRATTAMENTO JLI{line}",
                  "cte": self.read(m_cte)["title"] if self.read(m_cte).get("title") else self.read(m_cte)["name"]}
        res = {}
        for role, tref, mref in (("sae", t_sae, m_sae), ("cte", t_cte, m_cte), ("fol", t_fol, m_fol)):
            if tref is None:
                q = copy.deepcopy(self.read(mref))
                for k in ("id", "meta", "text"):
                    q.pop(k, None)
                tref = self.new("Questionnaire", q, f"?patientJourneyId={c['study']}")
                self.note("CREATE", f"   {role.upper()} nuovo per {t['label']} (clonato da {mref})")
            res[role] = tref
        if grp and not shared_sae and gname not in self.sae_owner:
            self.sae_owner[gname] = res["sae"]
        # sincronizzazione contenuto + testi
        for role, mref in (("sae", m_sae), ("cte", m_cte), ("fol", m_fol)):
            ref = res[role]
            if role == "sae" and shared_sae:
                continue            # gia' sincronizzato dal proprietario / e' quello del master
            q = self.read(ref)
            m = self.read(mref)
            b = copy.deepcopy(q)
            q["item"] = copy.deepcopy(m.get("item"))
            if drugs and role in ("sae", "fol"):
                q["item"] = restrict_drugs(q["item"], drugs, gname)
            exts = [copy.deepcopy(e) for e in m.get("extension", []) if e["url"] != PREPOP]
            if role == "fol":
                exts.append({"url": PREPOP, "valueString": (res['sae'] if res['sae'].startswith("NEW:") else res['sae'].split("/")[1]) + "|all|autofill"})
            if exts:
                q["extension"] = exts
            else:
                q.pop("extension", None)
            q["status"] = "active"
            tt = titles[role]
            q["title"] = q["name"] = tt
            q["url"] = f"http://example.org/fhir/Questionnaire/{tt}"
            if role == "sae":
                q["description"] = fill(c["sae"]["desc_sae"], dict(t, drug=" / ".join(drugs))) if drugs else fill(c["sae"]["desc_sae"], t)
            elif role == "fol":
                q["description"] = fill(c["sae"]["desc_fol"], t)
            else:
                q["description"] = m.get("description")
            if not ref.startswith("NEW:"):
                self.writes[ref] = q
                d = diff_dict({k: v for k, v in b.items() if k not in ("item", "extension")},
                              {k: v for k, v in q.items() if k not in ("item", "extension")})
                itemsame = b.get("item") == q["item"]
                extsame = b.get("extension") == q.get("extension")
                self.note("SAE-SYNC", f"   {role.upper()} {ref}: items {'=' if itemsame else 'RISCRITTI'} ext {'=' if extsame else 'riallineate'} {d if d else ''}")
        # il prepopulate del follow-up punta al SAE reale (dopo creazione ref sara' riscritto)
        return res["sae"], res["fol"], res["cte"]

    def plan_external(self):
        ex = self.cfg.get("external_lines")
        if not ex or (self.only and "EXTERNAL" not in self.only):
            return
        src = self.read(ex["source_activity"])
        ra = src["relatedArtifact"]
        src_cps = [r["resource"] for r in ra if r["resource"].startswith("CarePlan/")]
        src_groups = [r["resource"] for r in ra if r["resource"].startswith("Group/")]
        for t in ex["targets"]:
            pd = self.read(t["plan_definition"])
            exists = [a["definitionCanonical"] for a in pd.get("action", []) if a.get("definitionCanonical")
                      and norm(self.read(a["definitionCanonical"]).get("title")) == norm(t["name"])]
            self.note("TARGET", f"linea esterna '{t['name']}' in {t['plan_definition']}")
            src_gids = [e for e in src.get("extension", []) if e["url"] == "group_ids"]
            if exists:
                # riparazione: l'AD deve avere gli stessi group_ids (visibilita') della sorgente
                adx = self.read(exists[0])
                have = {e["valueString"] for e in adx.get("extension", []) if e["url"] == "group_ids"}
                miss = [copy.deepcopy(e) for e in src_gids if e["valueString"] not in have]
                if miss:
                    self.touch(exists[0]).setdefault("extension", []).extend(miss)
                    self.note("AD", f"   {exists[0]}: aggiunti {len(miss)} group_ids mancanti")
                else:
                    self.note("OK", f"   gia' presente: {exists[0]}")
                continue
            new_g = []
            for g in src_groups:
                x = copy.deepcopy(self.read(g))
                for k in ("id", "meta", "text", "member"):
                    x.pop(k, None)
                if x.get("name") == "Eleggibili":
                    x["code"] = {"text": t["name"]}
                new_g.append(self.new("Group", x))
                self.note("CREATE", f"   Group '{x.get('name')}' clonato da {g}")
            new_cp = []
            for cpref in src_cps:
                x = copy.deepcopy(self.read(cpref))
                for k in ("id", "meta", "text"):
                    x.pop(k, None)
                tt = ex["careplan_titles"].get(norm(x.get("title")), x.get("title"))
                x["title"], x["description"], x["note"] = tt, tt, [{"text": tt}]
                x["status"], x["intent"] = self.cfg["careplan_status"], self.cfg["careplan_intent"]
                new_cp.append(self.new("CarePlan", x))
                self.note("CREATE", f"   CarePlan '{tt}' Q={[q.split('/')[1] for q in self.qrefs(x)]} (stessi Questionnaire di {ex['source_activity']})")
            ad = copy.deepcopy(src)
            for k in ("id", "meta", "text"):
                ad.pop(k, None)
            ad["title"], ad["description"], ad["status"] = t["name"], "Terapia esterna", "active"
            ad["extension"] = [{"url": "http://irccs.org/fhir/StructureDefinition/activitydefinition-permit-choice", "valueBoolean": False},
                               {"url": "http://irccs.org/fhir/StructureDefinition/activitydefinition-permit-randomization", "valueBoolean": False}] \
                + [copy.deepcopy(e) for e in src_gids]
            ad["relatedArtifact"] = [{"type": "documentation", "resource": k} for k in new_cp] + \
                                    [{"type": "composed-of", "resource": k} for k in new_g]
            k_ad = self.new("ActivityDefinition", ad)
            self.note("CREATE", f"   ActivityDefinition '{t['name']}' ({len(new_cp)} CarePlan, {len(new_g)} Group)")
            pdw = self.touch(t["plan_definition"])
            pdw.setdefault("action", []).append({"definitionCanonical": k_ad})
            self.note("PD", f"   {t['plan_definition']} riceve la nuova azione")

    def retire_replaced(self):
        for q in sorted(self.old_refs - self.final_refs, key=lambda s: int(s.split("/")[1])):
            if q in self.cfg.get("never_retire", []):
                continue
            r = self.touch(q)
            if r.get("status") != "retired":
                r["status"] = "retired"
                self.note("RETIRE", f"   {q} '{ident(r)}' -> retired")

    def normalize_all(self):
        refs = {q for q in self.final_refs if not q.startswith("NEW:")}
        for ref in sorted(refs, key=lambda s: int(s.split("/")[1])):
            q = self.writes.get(ref) or copy.deepcopy(self.read(ref))
            ch = normalize_extensions(q)
            if ch:
                self.writes[ref] = q
                self.cache[ref] = q
                for c in ch:
                    self.note("EXT", f"   {ref} '{ident(q)}': {c}")
        for c in self.creates:
            if c["type"] == "Questionnaire":
                normalize_extensions(c["res"])

    def changed(self):
        return {r: v for r, v in self.writes.items() if canon(v) != canon(self.orig.get(r, {}))}


# ── backup / restore ────────────────────────────────────────────────────────
def closure(f, cfg):
    seen = {}
    def add(ref):
        if ref not in seen:
            seen[ref] = f.get(ref)
        return seen[ref]
    ads = [cfg["master_activity"]] + [t["activity"] for t in cfg["targets"]]
    ex = cfg.get("external_lines")
    if ex:
        ads.append(ex["source_activity"])
        for t in ex["targets"]:
            pdx = add(t["plan_definition"])
            # anche le linee esterne create dallo script (azioni del PlanDefinition) devono stare nel backup
            ads += [a["definitionCanonical"] for a in pdx.get("action", []) if a.get("definitionCanonical")]
        ads = list(dict.fromkeys(ads))
    for ad in ads:
        a = add(ad)
        for ra in a.get("relatedArtifact", []):
            r = ra.get("resource", "")
            if r.startswith("CarePlan/"):
                cp = add(r)
                for x in refs_in(cp):
                    if x.startswith("Questionnaire/"):
                        add(x)
    for q in [k for k in seen if k.startswith("Questionnaire/")]:
        for e in f.get(f"QuestionnaireResponse?questionnaire={q}&_count=500").get("entry", []):
            seen["QuestionnaireResponse/" + e["resource"]["id"]] = e["resource"]
    return seen


def do_backup(f, cfg, d):
    seen = closure(f, cfg)
    sums = []
    for ref, res in seen.items():
        os.makedirs(os.path.join(d, res["resourceType"]), exist_ok=True)
        p = os.path.join(d, ref + ".json")
        json.dump(res, open(p, "w"), indent=1, ensure_ascii=False)
        sums.append((hashlib.sha256(open(p, "rb").read()).hexdigest(), ref + ".json"))
    with open(os.path.join(d, "SHA256SUMS"), "w") as fh:
        for h, p in sorted(sums, key=lambda x: x[1]):
            fh.write(f"{h}  ./{p}\n")
    print(f"backup: {len(seen)} risorse in {d}")


# ── apply ───────────────────────────────────────────────────────────────────
def resolve(o, mapping):
    if isinstance(o, dict):
        return {k: resolve(v, mapping) for k, v in o.items()}
    if isinstance(o, list):
        return [resolve(v, mapping) for v in o]
    if isinstance(o, str):
        if o in mapping:
            return mapping[o]
        for k, v in mapping.items():
            if k in o:
                o = o.replace(k, v.split("/")[1])
    return o


def apply(f, tree, ch, backup_dir):
    base.verify_backup(backup_dir, [r for r in ch if not r.startswith("NEW:")])
    for ref in ch:
        bv = json.load(open(os.path.join(backup_dir, ref + ".json")))["meta"]["versionId"]
        if bv != tree.orig[ref]["meta"]["versionId"]:
            sys.exit(f"{ref}: modificata dopo il backup; rifare il backup")
    mapping = {}
    journal = open(os.path.join(backup_dir, "created.jsonl"), "a")
    # 1) crea i Questionnaire, 2) i CarePlan (i riferimenti NEW:* si risolvono man mano)
    for typ in ("Questionnaire", "Group", "CarePlan", "ActivityDefinition"):
        for c in [c for c in tree.creates if c["type"] == typ]:
            body = resolve(c["res"], mapping)
            body.pop("id", None)
            sc = tree.cfg.get("create_scope")
            hdr = {"X-Create-Scope": sc["groupId"], "organizationId": sc["organizationId"]} if sc else None
            r = f.call("POST", typ + c["params"], body, hdr)
            mapping[c["key"]] = f"{typ}/{r['id']}"
            print("POST", typ, "->", mapping[c["key"]], flush=True)
            journal.write(json.dumps({"ref": mapping[c["key"]]}) + "\n"); journal.flush()
            # il prepopulate dei follow-up contiene l'id del SAE: gia' risolto perche' SAE e' creato prima? (ordine Q)
    # il server scarta le estensioni top-level in creazione: riscrivile con una PUT; risolvi anche i
    # riferimenti NEW (es. prepopulate dei follow-up) che puntano a risorse create dopo
    for c in tree.creates:
        real = mapping[c["key"]]
        cur = f.get(real)
        want = resolve(c["res"], mapping)
        fixed = copy.deepcopy(cur)
        for fld in ("extension", "relatedArtifact", "activity", "item"):
            if fld in want:
                fixed[fld] = want[fld]
            else:
                fixed.pop(fld, None)
        if fixed != cur:
            f.put(fixed); print("FIX", real, "(estensioni/riferimenti riallineati)")
    order = {"Questionnaire": 0, "CarePlan": 1, "ActivityDefinition": 2, "PlanDefinition": 3}
    for ref in sorted(ch, key=lambda r: (order.get(r.split("/")[0], 9), int(r.split("/")[1]))):
        f.put(resolve(ch[ref], mapping)); print("PUT", ref)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["backup", "dry-run", "apply", "restore", "undo-creates"])
    ap.add_argument("--config", required=True)
    ap.add_argument("--base", required=True)
    ap.add_argument("--backup-dir", required=True)
    ap.add_argument("--targets", help="etichette separate da virgola (default: tutte)")
    ap.add_argument("--yes", action="store_true")
    ap.add_argument("--report")
    a = ap.parse_args()
    cfg = json.load(open(a.config))
    f = Fhir(a.base)
    if a.mode == "backup":
        return do_backup(f, cfg, a.backup_dir)
    if a.mode == "restore":
        if not a.yes: sys.exit("restore richiede --yes")
        return base.do_restore(f, a.backup_dir)
    if a.mode == "undo-creates":
        # cancella le risorse create da un apply interrotto (elenco in created.jsonl), solo se non referenziate
        if not a.yes: sys.exit("undo-creates richiede --yes")
        jf = os.path.join(a.backup_dir, "created.jsonl")
        refs = [json.loads(l)["ref"] for l in open(jf)] if os.path.exists(jf) else []
        for ref in reversed(refs):
            f.call("DELETE", ref); print("DELETE", ref)
        open(jf, "w").close()
        return
    tree = Tree(cfg, f, a.targets)
    tree.run()
    ch = tree.changed()
    lines = [f"# {datetime.now(timezone.utc):%Y-%m-%d %H:%M}Z {a.mode} master={cfg['master_activity']}"]
    lines += [f"[{l}] {t}" for l, t in tree.notes]
    from collections import Counter
    c = Counter(r.split("/")[0] for r in ch)
    cr = Counter(x["type"] for x in tree.creates)
    errs = [t for l, t in tree.notes if l == "ERR"]
    lines.append(f"\nDA MODIFICARE: {len(ch)} {dict(c)}   DA CREARE: {len(tree.creates)} {dict(cr)}")
    lines.append(f"ERRORI: {len(errs)}  WARN: {sum(1 for l, _ in tree.notes if l == 'WARN')}")
    txt = "\n".join(lines)
    print(txt)
    if a.report:
        open(a.report, "w").write(txt + "\n")
    if a.mode == "dry-run":
        return
    if errs: sys.exit("errori: apply annullato")
    if not a.yes: sys.exit("apply richiede --yes")
    apply(f, tree, ch, a.backup_dir)
    print("apply completato; rilanciare il dry-run: deve risultare 0 da modificare e 0 da creare")


if __name__ == "__main__":
    main()
