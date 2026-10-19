#!/usr/bin/env python3
"""
Allineamento di un ramo terapeutico (ActivityDefinition "target") a uno "master".

Per ogni step (CarePlan, abbinato per titolo) la config dice se e' condiviso o per-terapia:
  shared       i Questionnaire del target vengono sostituiti da quelli del master (stesso id
               in tutte le terapie: una modifica vale ovunque); i vecchi vengono messi `retired`
               e le QuestionnaireResponse esistenti ripuntate al master.
  per-therapy  Questionnaire distinti, restano risorse separate (Somministrazione, SAE, ...).
In entrambi i casi il CarePlan del target e' allineato a quello del master (title, description,
note, estensioni) e a status/intent della config. Vedi config-jli-new-linea1.json.

Modi:
  backup    esporta in --backup-dir tutte le risorse coinvolte (+ SHA256SUMS)
  dry-run   calcola e stampa le modifiche, NON scrive (default)
  apply     applica (richiede --yes e un backup verificato)
  restore   rimette le risorse del backup (PUT della versione salvata)

Credenziali: variabili d'ambiente IRCCS_USER / IRCCS_PASSWORD (login /auth/users/token) oppure
IRCCS_TOKEN. Mai in config.
"""
import argparse, copy, hashlib, json, os, re, sys, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timezone

SD = "http://irccs.pascale.napoli.it/fhir/StructureDefinition/"
# forma corta (legacy) -> forma lunga (quella scritta dal dashboard)
SHORT_TO_LONG = {
    "shouldIncludeOrganization": SD + "should-include-organization",
    "renderAsPatientQuestionnaire": SD + "render-as-patient-questionnaire",
    "prepopulateFromPreviousCycle": SD + "prepopulate-from-previous-cycle",
}
KEEP_IN_TARGET_CAREPLAN = {"duplicateCrfItem"}  # per-terapia: mai sovrascritto dal master


# ── client FHIR ─────────────────────────────────────────────────────────────
class Fhir:
    def __init__(self, base):
        self.base = base.rstrip("/")
        # base che finisce per /fhir = HAPI diretto (autorizzato dall'utente): niente login e i
        # group_ids (nascosti dal proxy) restano visibili nelle letture e preservati nelle scritture
        self.direct = self.base.endswith("/fhir")
        self.token = None if self.direct else (os.environ.get("IRCCS_TOKEN") or self._login())

    def _login(self):
        u, p = os.environ.get("IRCCS_USER"), os.environ.get("IRCCS_PASSWORD")
        if not (u and p):
            sys.exit("Servono IRCCS_TOKEN oppure IRCCS_USER + IRCCS_PASSWORD")
        body = urllib.parse.urlencode({"grant_type": "password", "scope": "openid",
                                       "username": u, "password": p}).encode()
        r = urllib.request.urlopen(urllib.request.Request(self.base + "/auth/users/token", body))
        return json.load(r)["access_token"]

    def call(self, method, path, body=None, headers=None):
        h = {"Accept": "application/fhir+json"}
        if self.token:
            h["Authorization"] = "Bearer " + self.token
        if self.direct:
            headers = None  # X-Create-Scope & co. non servono su HAPI diretto
            path = re.sub(r"[?&]patientJourneyId=\d+", "", path)
        if body is not None:
            h["Content-Type"] = "application/fhir+json"
        h.update(headers or {})
        req = urllib.request.Request(self.base + "/" + path, method=method, headers=h,
                                     data=json.dumps(body).encode() if body is not None else None)
        import time
        time.sleep(float(os.environ.get("IRCCS_THROTTLE", "0.2")))
        for attempt in range(5):
            try:
                raw = urllib.request.urlopen(req, timeout=120).read()
                return json.loads(raw) if raw.strip() else {}
            except urllib.error.HTTPError as e:
                if e.code in (502, 503, 504) and method == "GET" and attempt < 4:
                    time.sleep(2 * (attempt + 1)); continue
                sys.exit(f"{method} {path} -> HTTP {e.code}: {e.read()[:400]!r}")
            except urllib.error.URLError as e:
                # URLError = errore in fase di connessione/handshake: la richiesta non e' mai partita,
                # quindi ritentare e' sicuro anche per POST/PUT
                if attempt < 4:
                    time.sleep(3 * (attempt + 1)); continue
                sys.exit(f"{method} {path} -> {e}")
            except TimeoutError as e:
                # timeout di lettura: per le scritture la richiesta potrebbe essere arrivata, non ritentare
                if method == "GET" and attempt < 4:
                    time.sleep(2 * (attempt + 1)); continue
                sys.exit(f"{method} {path} -> {e} (esito incerto: verificare prima di rilanciare)")

    def get(self, path):
        return self.call("GET", path)

    def put(self, res):
        v = res.get("meta", {}).get("versionId")
        hdr = {"If-Match": f'W/"{v}"'} if v else {}
        return self.call("PUT", f"{res['resourceType']}/{res['id']}", res, hdr)


# ── utilita' ────────────────────────────────────────────────────────────────
def norm(s):
    return re.sub(r"\s+", " ", (s or "").strip()).lower()


def refs_in(o, out=None):
    out = set() if out is None else out
    if isinstance(o, dict):
        for k, v in o.items():
            if k == "reference" and isinstance(v, str) and re.match(r"^[A-Za-z]+/\d+$", v):
                out.add(v)
            else:
                refs_in(v, out)
    elif isinstance(o, list):
        for v in o:
            refs_in(v, out)
    return out


def replace_refs(o, mapping):
    """Sostituisce Questionnaire/old -> Questionnaire/new in reference e nelle stringhe `id|...`."""
    if isinstance(o, dict):
        return {k: replace_refs(v, mapping) for k, v in o.items()}
    if isinstance(o, list):
        return [replace_refs(v, mapping) for v in o]
    if isinstance(o, str):
        if o in mapping:
            return mapping[o]
    return o


def ext_key(url):
    return url.split("/")[-1]


def normalize_extensions(res):
    """Forma corta -> lunga; se esistono entrambe tiene la lunga. Solo estensioni top-level."""
    exts, changes = res.get("extension", []), []
    longs = {e["url"] for e in exts if e["url"] in SHORT_TO_LONG.values()}
    out = []
    for e in exts:
        long = SHORT_TO_LONG.get(e["url"])
        if long is None:
            out.append(e)
        elif long in longs:
            changes.append(f"rimossa forma corta {e['url']} (esiste la lunga)")
        else:
            out.append({**e, "url": long})
            longs.add(long)
            changes.append(f"{e['url']} -> forma lunga")
    if changes:
        res["extension"] = out
    return changes


def items_flat(q):
    out = {}
    def walk(items):
        for i in items or []:
            exts = sorted(ext_key(e["url"]).replace("-", "").lower() for e in i.get("extension", []))
            opts = tuple(a.get("valueCoding", {}).get("code") for a in i.get("answerOption", []))
            out[i["linkId"]] = (i.get("text"), i.get("type"), i.get("required"),
                                json.dumps(i.get("enableWhen"), sort_keys=True), tuple(exts), opts)
            walk(i.get("item"))
    walk(q.get("item"))
    return out


# ── pianificazione ──────────────────────────────────────────────────────────
class Plan:
    def __init__(self, cfg, fhir):
        self.cfg, self.f = cfg, fhir
        self.cache = {}
        self.originals = {}   # ref -> risorsa letta
        self.writes = {}      # ref -> risorsa nuova
        self.notes = []       # (livello, testo)

    def read(self, ref):
        if ref not in self.cache:
            self.cache[ref] = self.f.get(ref)
            self.originals[ref] = copy.deepcopy(self.cache[ref])
        return self.cache[ref]

    def touch(self, ref):
        self.writes[ref] = self.read(ref)
        return self.writes[ref]

    def note(self, lvl, txt):
        self.notes.append((lvl, txt))

    def careplans(self, ad_ref):
        ad = self.read(ad_ref)
        res = {}
        for ra in ad.get("relatedArtifact", []):
            r = ra.get("resource", "")
            if r.startswith("CarePlan/"):
                cp = self.read(r)
                res[norm(cp.get("title"))] = r
        return res

    def run(self):
        cfg = self.cfg
        master_cps = self.careplans(cfg["master_activity"])
        target_cps = self.careplans(cfg["target_activity"])
        qmap = {}     # old Questionnaire ref -> master ref
        for step, scfg in cfg["steps"].items():
            key = norm(step)
            if key not in master_cps or key not in target_cps:
                self.note("ERR", f"step '{step}': CarePlan mancante (master={key in master_cps}, target={key in target_cps})")
                continue
            self.plan_step(step, scfg, master_cps[key], target_cps[key], qmap)
        self.plan_qr_and_retire(qmap)
        self.plan_patches()
        self.plan_extension_normalization(master_cps, target_cps)
        return qmap

    # step
    def plan_step(self, step, scfg, mcp_ref, tcp_ref, qmap):
        mcp, tcp = self.read(mcp_ref), self.read(tcp_ref)
        mode = scfg["mode"]
        self.note("STEP", f"{step}: {mode}  ({tcp_ref} <- {mcp_ref})")
        cp = copy.deepcopy(tcp)
        # 1) campi del CarePlan copiati dal master
        for fld in scfg.get("copy_fields", ["title", "description", "note"]):
            if mcp.get(fld) is None:
                cp.pop(fld, None)
            else:
                cp[fld] = copy.deepcopy(mcp[fld])
        # 2) status/intent
        for fld in ("status", "intent"):
            cp[fld] = cfg_val(self.cfg, "careplan_" + fld)
        # 3) estensioni: specchio del master, tranne quelle per-terapia
        if scfg.get("mirror_extensions", True):
            keep = [e for e in tcp.get("extension", []) if e["url"] in KEEP_IN_TARGET_CAREPLAN]
            mir = [copy.deepcopy(e) for e in mcp.get("extension", []) if e["url"] not in KEEP_IN_TARGET_CAREPLAN]
            cp["extension"] = mir + keep
            if not cp["extension"]:
                cp.pop("extension")
        # 4) Questionnaire condivisi: ripuntamento per titolo
        if mode == "shared":
            m_q = self.qs_of(mcp)
            t_q = self.qs_of(tcp)
            keep_re = re.compile(scfg["keep_questionnaires_matching"]) if scfg.get("keep_questionnaires_matching") else None
            m_by_title = {}
            for r in m_q:
                k = norm(ident(self.read(r)))
                if not k or k in m_by_title:
                    self.note("ERR", f"   identita' (title/name) vuota o duplicata nel master: {r} '{k}'")
                m_by_title[k] = r
            t_keys = [norm(ident(self.read(r))) for r in t_q]
            if len(set(t_keys)) != len(t_keys) or "" in t_keys:
                self.note("ERR", f"   identita' (title/name) vuota o duplicata nel target: {t_keys}")
            local_map = {}
            for r in t_q:
                title = ident(self.read(r))
                if keep_re and keep_re.search(title or ""):
                    self.note("KEEP", f"   {r} '{title}' resta per-terapia")
                    continue
                m = m_by_title.get(norm(title))
                if m in local_map.values():
                    self.note("ERR", f"   {r}: il master {m} e' gia' usato da un altro Questionnaire del target")
                    continue
                if not m:
                    self.note("WARN", f"   {r} '{title}': nessun Questionnaire master con lo stesso titolo -> invariato")
                    continue
                if m != r:
                    local_map[r] = m
                    self.compare_content(r, m)
            if local_map:
                m2 = {}
                for o, n in local_map.items():
                    m2[o] = n
                cp = replace_refs(cp, m2)
                qmap.update(local_map)
                for o, n in local_map.items():
                    self.note("REPOINT", f"   {o} -> {n}")
            # estensioni da riportare sul master (es. save-disable-*)
            for url_key in scfg.get("master_extensions_from_target", []):
                for o, n in local_map.items():
                    src = [e for e in self.read(o).get("extension", []) if ext_key(e["url"]) == url_key]
                    mq = self.read(n)
                    have = {ext_key(e["url"]) for e in mq.get("extension", [])}
                    if src and url_key not in have:
                        q = self.touch(n)
                        q.setdefault("extension", []).extend(copy.deepcopy(src))
                        self.note("MASTER-EXT", f"   {n} riceve '{url_key}' da {o}")
        # status/intent anche sul CarePlan master (uniformita' tra i rami)
        mnew = copy.deepcopy(mcp)
        for fld in ("status", "intent"):
            mnew[fld] = cfg_val(self.cfg, "careplan_" + fld)
        if mnew != mcp:
            self.writes[mcp_ref] = mnew
            for d in diff_dict(mcp, mnew):
                self.note("CAREPLAN", f"   {mcp_ref} (master) {d}")
        if cp != tcp:
            self.writes[tcp_ref] = cp
            self.cache[tcp_ref] = cp
            for d in diff_dict(tcp, cp):
                self.note("CAREPLAN", f"   {tcp_ref} {d}")
        else:
            self.note("OK", f"   {tcp_ref} gia' allineato")

    def qs_of(self, cp):
        return sorted(r for r in refs_in(cp.get("activity", [])) if r.startswith("Questionnaire/"))

    def compare_content(self, old, new):
        a, b = items_flat(self.read(old)), items_flat(self.read(new))
        only_a, only_b = set(a) - set(b), set(b) - set(a)
        changed = [k for k in a if k in b and a[k] != b[k]]
        if only_a or only_b or changed:
            self.note("WARN", f"   CONTENUTO DIVERSO {old} vs {new}: solo-vecchio={len(only_a)} solo-master={len(only_b)} modificati={len(changed)}")
            for k in list(only_a)[:5]:
                self.note("WARN", f"      solo vecchio: {a[k][0]}")
            for k in changed[:5]:
                self.note("WARN", f"      {a[k][0]!r} => {b[k][0]!r}")
        else:
            self.note("OK", f"   contenuto {old} == {new} (item/enableWhen/estensioni item)")

    def plan_qr_and_retire(self, qmap):
        for old, new in sorted(qmap.items()):
            bundle = self.f.get(f"QuestionnaireResponse?questionnaire={old}&_count=500") if self.cfg.get("repoint_responses", True) else {}
            for e in bundle.get("entry", []):
                qr = self.read("QuestionnaireResponse/" + e["resource"]["id"])
                linkids = set(items_flat(self.read(new)))
                used = set()
                def walk(items):
                    for i in items or []:
                        used.add(i["linkId"]); walk(i.get("item"))
                walk(qr.get("item"))
                missing = used - linkids
                if missing:
                    self.note("ERR", f"QR/{qr['id']}: linkId assenti nel master {new}: {sorted(missing)[:5]}")
                    continue
                n = self.touch("QuestionnaireResponse/" + qr["id"])
                n["questionnaire"] = new
                self.note("QR", f"   QuestionnaireResponse/{qr['id']}: {old} -> {new}")
            if self.cfg.get("retire_replaced", True):
                q = self.touch(old)
                if q.get("status") != "retired":
                    q["status"] = "retired"
                    self.note("RETIRE", f"   {old} '{ident(q)}' -> retired")

    def plan_patches(self):
        for p in self.cfg.get("patches", []):
            ref = p["ref"]
            res = self.touch(ref) if ref not in self.writes else self.writes[ref]
            before = copy.deepcopy(res)
            for k, v in p.get("set", {}).items():
                res[k] = v
            for url, val in p.get("extensions", {}).items():
                ex = [e for e in res.get("extension", []) if e["url"] != url]
                ex.append({"url": url, **val})
                res["extension"] = ex
            for d in diff_dict(before, res):
                self.note("PATCH", f"   {ref} {d}  [{p.get('why', '')}]")

    def plan_extension_normalization(self, mcps, tcps):
        refs = set()
        for r in list(mcps.values()) + list(tcps.values()):
            refs |= {x for x in refs_in(self.read(r)) if x.startswith("Questionnaire/")}
        for ref in sorted(refs, key=lambda s: int(s.split("/")[1])):
            q = self.writes.get(ref) or copy.deepcopy(self.read(ref))
            ch = normalize_extensions(q)
            if ch:
                self.writes[ref] = q
                self.cache[ref] = q
                for c in ch:
                    self.note("EXT", f"   {ref} '{ident(q)}': {c}")

    def changed(self):
        out = {}
        for ref, new in self.writes.items():
            if strip_meta(new) != strip_meta(self.originals.get(ref, {})):
                out[ref] = new
        return out


def ident(q):
    return q.get("title") or q.get("name")


def cfg_val(cfg, k):
    return cfg[k]


def strip_meta(r):
    r = copy.deepcopy(r); r.pop("meta", None); return r


def diff_dict(a, b, path=""):
    out = []
    for k in sorted(set(a) | set(b)):
        if a.get(k) != b.get(k):
            out.append(f"{path}{k}: {short(a.get(k))} -> {short(b.get(k))}")
    return out


def short(v):
    s = json.dumps(v, ensure_ascii=False) if not isinstance(v, str) else v
    return s if len(s) < 140 else s[:137] + "..."


# ── backup / restore ────────────────────────────────────────────────────────
def collect_refs(fhir, cfg):
    seen = {}
    todo = list(cfg.get("backup_roots", [])) + [cfg["master_activity"], cfg["target_activity"]]
    def add(ref):
        if ref in seen:
            return
        seen[ref] = fhir.get(ref)
    for r in todo:
        add(r)
    for ad in (cfg["master_activity"], cfg["target_activity"]):
        for ra in seen[ad].get("relatedArtifact", []):
            r = ra.get("resource", "")
            if r:
                add(r)
                for x in refs_in(seen[r]):
                    if x.startswith(("Questionnaire/", "Library/")):
                        add(x)
    for q in [r for r in list(seen) if r.startswith("Questionnaire/")]:
        b = fhir.get(f"QuestionnaireResponse?questionnaire={q}&_count=500")
        for e in b.get("entry", []):
            seen["QuestionnaireResponse/" + e["resource"]["id"]] = e["resource"]
    return seen


def do_backup(fhir, cfg, d):
    os.makedirs(d, exist_ok=True)
    seen = collect_refs(fhir, cfg)
    sums = []
    for ref, res in seen.items():
        os.makedirs(os.path.join(d, res["resourceType"]), exist_ok=True)
        path = os.path.join(d, ref + ".json")
        with open(path, "w") as fh:
            json.dump(res, fh, indent=1, ensure_ascii=False)
        sums.append((hashlib.sha256(open(path, "rb").read()).hexdigest(), ref + ".json"))
    with open(os.path.join(d, "SHA256SUMS"), "w") as fh:
        for h, p in sorted(sums, key=lambda x: x[1]):
            fh.write(f"{h}  ./{p}\n")
    print(f"backup: {len(seen)} risorse in {d}")


def verify_backup(d, refs):
    sums = {}
    for line in open(os.path.join(d, "SHA256SUMS")):
        h, p = line.split(None, 1); sums[p.strip().lstrip("./")] = h
    for ref in refs:
        p = ref + ".json"
        if p not in sums:
            sys.exit(f"backup incompleto: manca {ref}")
        if hashlib.sha256(open(os.path.join(d, p), "rb").read()).hexdigest() != sums[p]:
            sys.exit(f"backup corrotto: {ref}")


def do_restore(fhir, d):
    n = 0
    for root, _, files in os.walk(d):
        for fn in files:
            if not fn.endswith(".json"):
                continue
            saved = json.load(open(os.path.join(root, fn)))
            cur = fhir.get(f"{saved['resourceType']}/{saved['id']}")
            if strip_meta(cur) != strip_meta(saved):
                body = copy.deepcopy(saved)
                body["meta"] = {"versionId": cur["meta"]["versionId"]}
                fhir.put(body); n += 1
                print("restored", saved["resourceType"], saved["id"])
    print(f"restore: {n} risorse ripristinate")


# ── main ────────────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["backup", "dry-run", "apply", "restore"])
    ap.add_argument("--config", required=True)
    ap.add_argument("--base", required=True, help="es. https://irccs.preprod.infocube.it")
    ap.add_argument("--backup-dir", required=True)
    ap.add_argument("--yes", action="store_true")
    ap.add_argument("--only", help="lista di riferimenti separati da virgola: applica solo questi (test graduale)")
    ap.add_argument("--report", help="scrive il report anche su file")
    a = ap.parse_args()
    cfg = json.load(open(a.config))
    f = Fhir(a.base)
    if a.mode == "backup":
        return do_backup(f, cfg, a.backup_dir)
    if a.mode == "restore":
        if not a.yes:
            sys.exit("restore richiede --yes")
        return do_restore(f, a.backup_dir)
    plan = Plan(cfg, f)
    plan.run()
    ch = plan.changed()
    if a.only:
        sel = set(a.only.split(","))
        ch = {r: v for r, v in ch.items() if r in sel}
    lines = [f"# {datetime.now(timezone.utc):%Y-%m-%d %H:%M}Z {a.mode} master={cfg['master_activity']} target={cfg['target_activity']}"]
    lines += [f"[{l}] {t}" for l, t in plan.notes]
    from collections import Counter
    c = Counter(r.split("/")[0] for r in ch)
    lines.append(f"\nRISORSE DA SCRIVERE: {len(ch)} {dict(c)}")
    errs = [t for l, t in plan.notes if l == "ERR"]
    lines.append(f"ERRORI: {len(errs)}  WARN: {sum(1 for l, _ in plan.notes if l == 'WARN')}")
    txt = "\n".join(lines)
    print(txt)
    if a.report:
        open(a.report, "w").write(txt + "\n")
    if a.mode == "dry-run":
        return
    if errs:
        sys.exit("ci sono errori: apply annullato")
    if not a.yes:
        sys.exit("apply richiede --yes")
    verify_backup(a.backup_dir, ch.keys())
    for ref in ch:  # il backup deve corrispondere alla versione attuale
        bv = json.load(open(os.path.join(a.backup_dir, ref + ".json")))["meta"]["versionId"]
        if bv != plan.originals[ref]["meta"]["versionId"]:
            sys.exit(f"{ref}: modificata dopo il backup (v{bv} -> v{plan.originals[ref]['meta']['versionId']}); rifare il backup")
    # ordine: Questionnaire (master prima) -> CarePlan -> QuestionnaireResponse
    order = {"Questionnaire": 0, "CarePlan": 1, "QuestionnaireResponse": 2}
    for ref in sorted(ch, key=lambda r: (order.get(r.split("/")[0], 9), int(r.split("/")[1]))):
        r = f.put(ch[ref]); print("PUT", ref, "-> v" + r.get("meta", {}).get("versionId", "?"))
    print("apply completato; rilanciare dry-run: deve risultare 0 risorse da scrivere")


if __name__ == "__main__":
    main()
