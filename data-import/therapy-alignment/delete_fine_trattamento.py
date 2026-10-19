#!/usr/bin/env python3
"""Elimina gli ActivityDefinition "Fine Trattamento ..." di una copia di studio terapia.

QUESTO STRUMENTO E' PENSATO PER UNA COPIA DI STUDIO APPENA CREATA, con ZERO soggetti arruolati,
e `apply` funziona SOLO su HAPI DIRETTO (base che finisce per /fhir) con --diretto esplicito. Il
proxy e' ammesso solo per il dry-run in sola lettura: via proxy il filtro di visibilita' puo'
restituire total=0 per ResearchSubject/CarePlan/QuestionnaireResponse, quindi nessuna guardia
basata su conteggi sarebbe affidabile. Un'esecuzione interrotta si completa A MANO dai backup.

Per ogni AD: toglie l'azione dal PlanDefinition (PUT con If-Match), poi cancella (DELETE) AD,
CarePlan, Group e Questionnaire collegati, in questo ordine. Prima di scrivere qualsiasi cosa
gira un PREFLIGHT (solo GET) che deve finire senza errori: qualunque anomalia = uscita con
messaggio chiaro e ZERO scritture. Le letture sono "fail closed": ogni GET deve restituire
resourceType/id attesi (una risorsa mancante, 404/410, ABORTISCE), ogni ricerca deve avere
"total" intero e nessun link "next", ogni scansione deve avere total == numero di entry.

Il file --targets-json e' OBBLIGATORIO (nessun default hard-coded: gli stessi id su un altro
ambiente possono appartenere a risorse diverse, es. lo studio originale in produzione):
  {"host": "HOST", "studio": "ResearchStudy/<id>",
   "ActivityDefinition/<id>": {"title": "...", "cps": ["CarePlan/<id>"],
                               "groups": ["Group/<id>"], "qs": ["Questionnaire/<id>"],
                               "pds": ["PlanDefinition/<id>"]}}
"host" e "studio" sono OBBLIGATORI in apply e devono coincidere con --conferma-host / --studio.
Gli elenchi cps/groups/qs devono coincidere ESATTAMENTE (uguaglianza di insiemi) con quanto
l'AD referenzia (relatedArtifact; Questionnaire dalle activity dei CarePlan): niente orfani.
Piu' AD target nello stesso PlanDefinition sono RIFIUTATI: un file/esecuzione per ogni PD.

Uso:
  python3 delete_fine_trattamento.py dry-run --base http://HOST:8080/fhir --targets-json F.json [--studio ResearchStudy/N]
  python3 delete_fine_trattamento.py apply --diretto --yes --base http://HOST:8080/fhir --targets-json F.json \\
      --backup-dir DIR --conferma-host HOST --studio ResearchStudy/N --id-minimo N \\
      --conferma-titolo-studio "TITOLO"

CHECKLIST PRIMA DI UN APPLY
  1. host: --base e --conferma-host e "host" del file coincidono (e' l'ambiente giusto?).
  2. studio: --studio e' la RADICE della copia appena creata (e "studio" nel file); titolo esatto in
     --conferma-titolo-studio.
  3. --id-minimo = il PIU' BASSO id creato dalla copia (tutto cio' che e' sotto e' dell'originale).
  4. una sola AD per PlanDefinition; il dry-run precedente e' pulito.
  5. --backup-dir nuova o vuota, su disco sicuro (0700).
  6. snapshot del DB eseguito PRIMA (per le risorse cancellate non esiste ripristino).
  7. Dopo l'apply, verificare con un account privilegiato i group_ids del PD (il proxy li nasconde,
     l'HAPI diretto li conserva: controllare comunque).

Protezioni obbligatorie in apply:
  --diretto              conferma esplicita HAPI diretto; con base non /fhir apply e' rifiutato
                         prima di qualsiasi chiamata di rete.
  --conferma-host HOST   deve coincidere con l'host di --base (minuscolo) e con "host" del file.
  --id-minimo N          N >= 1; rifiuta se un qualunque id del file, lo studio, un figlio o una
                         PlanDefinition dell'albero e' < N.
  --studio ResearchStudy/<id>
                         VERA radice della copia. Albero percorso solo verso il basso:
                         radice.partOf -> studi figli (orientamento invertito su questa
                         piattaforma), studio.protocol -> PlanDefinition, PD.relatedArtifact
                         (documentation) -> PD di sotto-linea. Ogni PD dei target deve stare
                         nell'albero. ResearchSubject?study= deve dare 0 per OGNI studio
                         dell'albero, radice inclusa (l'arruolamento sta sulla radice), e il titolo
                         della radice deve coincidere con --conferma-titolo-studio (case-sensitive).
                         Antenati: nessun ResearchStudy FUORI dall'albero puo' referenziare uno
                         studio dell'albero (partOf/relatedArtifact/qualunque riferimento) e i
                         partOf degli studi dell'albero devono restare nell'albero; altrimenti la
                         radice non e' una vera radice -> abort. Nessuna risorsa FUORI
                         dall'albero puo' referenziare i PlanDefinition target (protocol, altre PD).

Scansioni fail-closed di TUTTI ActivityDefinition, PlanDefinition, ResearchStudy, CarePlan,
ResearchSubject, Task, Library e Questionnaire (_count=5000; oltre il tetto = abort; se la ricerca
di un tipo non e' supportata o da' errore = abort): riferimenti normalizzati (URL assoluti,
|versione, _history) sull'intero JSON, piu' url canonico di AD e Questionnaire (anche
url|versione). Gli unici ammessi a referenziare i target sono l'AD stesso, il suo PlanDefinition
e i suoi CarePlan. NON scansionati: ServiceRequest, MedicationRequest, RequestGroup, List,
Composition (tipi non pertinenti alla struttura studio/linea e potenzialmente enormi); controlli
compensativi: conteggio QuestionnaireResponse (anche subito prima del DELETE del Questionnaire) e
integrita' referenziale di HAPI (un DELETE referenziato fallisce con 409). Controlli ulteriori: 0
QuestionnaireResponse (forme Questionnaire/<id>, URL assoluto, url canonico; su preprod
QuestionnaireResponse.questionnaire usa la forma Questionnaire/<id>), Group senza member e senza
Observation/Consent/ResearchStudy.enrollment, CarePlan senza QR/Observation based-on, esattamente
un'azione nel PD.

PUT del PlanDefinition: la versione letta deve coincidere con quella del backup; If-Match sulla
versione; dopo il PUT si rilegge il PD e si confronta tutto tranne action e meta, piu' meta.tag e
meta.security: se qualcosa cambia ci si ferma PRIMA di qualsiasi DELETE con istruzioni di
ripristino dal backup. Prima di OGNI DELETE si rilegge la risorsa e si confronta meta.versionId
con quello del backup (diverso = abort); prima del DELETE del Questionnaire si riconta che le
QuestionnaireResponse siano 0. Dopo ogni DELETE si rilegge la risorsa e si attende 404/410.

ATTENZIONE: per le risorse cancellate NON esiste ripristino (i backup sono snapshot JSON con
SHA256SUMS, da ricreare a mano con PUT). In caso di errore ci si FERMA al primo fallimento e si
stampa fatto / fallito / in attesa (ogni errore non-HTTP su una scrittura, timeout e Ctrl-C =
"ESITO INCERTO: verificare"). NON esiste modalita' di ripresa: un'esecuzione interrotta si
completa A MANO dai backup (PUT del PD / DELETE delle risorse in attesa). --backup-dir deve
essere una directory nuova o vuota.
"""
import argparse, hashlib, http.client, json, os, re, sys, time, urllib.error, urllib.request
from urllib.parse import quote, urlparse

H = {"Content-Type": "application/fhir+json", "Accept": "application/fhir+json"}
TIMEOUT = 60
CAP = 5000


class ApiError(Exception):
    """Errore di chiamata al server, uniforme per modalita' diretta e proxy."""

    def __init__(self, msg, status=None, uncertain=False):
        super().__init__(msg)
        self.status = status
        self.uncertain = uncertain


def make_raw(base):
    """Ritorna (call(method, path, body, headers)->dict, diretto). Il proxy riusa Fhir di align_therapy_branch."""
    b = base.rstrip("/")
    direct = b.endswith("/fhir")
    if not direct:
        # proxy autenticato: login con IRCCS_USER/IRCCS_PASSWORD o IRCCS_TOKEN (mai stampati)
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import align_therapy_branch, socket
        socket.setdefaulttimeout(TIMEOUT)  # anche per il login (urlopen senza timeout nel client)
        proxy = align_therapy_branch.Fhir(base)
        return (lambda m, u, d=None, h=None: proxy.call(m, u, d, h)), False

    def call(m, u, d=None, h=None):
        hh = dict(H)
        hh.update(h or {})
        r = urllib.request.Request(b + "/" + u, json.dumps(d).encode() if d is not None else None,
                                   method=m, headers=hh)
        time.sleep(0.2)
        raw = urllib.request.urlopen(r, timeout=TIMEOUT).read()
        return json.loads(raw) if raw.strip() else {}
    return call, True


class Api:
    """Uniforma gli errori: qualunque fallimento (HTTPError, SystemExit del client, rete) -> ApiError."""

    def __init__(self, raw):
        self.raw = raw

    def call(self, m, u, d=None, h=None):
        try:
            return self.raw(m, u, d, h) or {}
        except SystemExit as e:
            msg = str(e)
            st = re.search(r"HTTP (\d{3})", msg)
            # su scrittura, errore senza risposta HTTP = esito incerto
            raise ApiError(f"{m} {u}: {msg}", int(st.group(1)) if st else None,
                           "esito incerto" in msg or (m != "GET" and not st))
        except urllib.error.HTTPError as e:
            raise ApiError(f"{m} {u}: HTTP {e.code}", e.code)
        except Exception as e:
            # qualunque errore non-HTTP (RemoteDisconnected, reset, timeout, ...): su scrittura e' incerto
            raise ApiError(f"{m} {u}: {type(e).__name__}: {e}", None, m != "GET")

    def get(self, u):
        return self.call("GET", u)


def die(msg, code=2):
    print(msg, file=sys.stderr)
    sys.exit(code)




# ---------------------------------------------------------------- letture fail-closed
def rd(api, tipo, i):
    """GET tipo/i con verifica di resourceType e id (un 200 con {} o OperationOutcome = errore)."""
    try:
        r = api.get(f"{tipo}/{i}")
    except ApiError as e:
        if e.status in (404, 410):
            raise ApiError(f"{tipo}/{i} NON esiste (HTTP {e.status}): target o risorsa attesa mancante, abort")
        raise
    if r.get("resourceType") != tipo or str(r.get("id")) != str(i):
        raise ApiError(f"GET {tipo}/{i}: risposta anomala (resourceType={r.get('resourceType')!r}, id={r.get('id')!r})")
    return r


def bundle(api, path):
    b = api.get(path)
    if b.get("resourceType") != "Bundle":
        raise ApiError(f"GET {path}: la risposta non e' un Bundle")
    if any(l.get("relation") == "next" for l in b.get("link", [])):
        raise ApiError(f"GET {path}: Bundle paginato (link next), conteggio non affidabile")
    return b


def cnt(api, path):
    b = bundle(api, path)
    t = b.get("total")
    if not isinstance(t, int) or isinstance(t, bool):
        raise ApiError(f"GET {path}: 'total' assente o non intero")
    return t


def norm_ref(r):
    """'http://x/fhir/CarePlan/5/_history/2' / 'Questionnaire/7|1.0' -> 'CarePlan/5' / 'Questionnaire/7'."""
    s = str(r or "").split("|")[0]
    m = re.search(r"([A-Za-z]+/\d+)(?:/_history/\d+)?/?$", s)
    return m.group(1) if m else s


def strings(o):
    if isinstance(o, str):
        yield o
    elif isinstance(o, dict):
        for v in o.values():
            yield from strings(v)
    elif isinstance(o, list):
        for v in o:
            yield from strings(v)


def num(ref, tipo):
    """'Tipo/123' -> 123; riferimento non numerico = ApiError (mai ValueError)."""
    m = re.fullmatch(rf"{tipo}/(\d+)", norm_ref(ref))
    if not m:
        raise ApiError(f"riferimento non valido {ref!r}: atteso {tipo}/<id numerico>")
    return int(m.group(1))


# ---------------------------------------------------------------- targets
def pid(ref, tipo):
    m = re.fullmatch(rf"{tipo}/(\d+)", str(ref))
    if not m:
        die(f"targets-json: riferimento {ref!r} non valido, atteso '{tipo}/<id numerico>'")
    return int(m.group(1))


def _no_dup(pairs):
    d = {}
    for k, v in pairs:
        if k in d:
            die(f"targets-json: chiave duplicata {k!r}")
        d[k] = v
    return d


def load_targets(path):
    """-> ({ad: (pd, [cp], [group], [q])}, meta{host, studio})."""
    try:
        with open(path) as f:
            data = json.load(f, object_pairs_hook=_no_dup)
    except (OSError, ValueError) as e:
        die(f"targets-json illeggibile: {e}")
    if not isinstance(data, dict):
        die("targets-json: atteso un oggetto")
    meta = {k: data.pop(k) for k in ("host", "studio") if k in data}
    if not data:
        die("targets-json: nessun ActivityDefinition")
    out, visti = {}, {}
    for k, v in data.items():
        try:
            ad = pid(k, "ActivityDefinition")
            if ad in out:
                die(f"targets-json: AD {ad} compare piu' volte (chiavi equivalenti)")
            if len(v["pds"]) != 1:
                die(f"targets-json {k}: serve esattamente un PlanDefinition in 'pds'")
            out[ad] = (pid(v["pds"][0], "PlanDefinition"), [pid(x, "CarePlan") for x in v["cps"]],
                       [pid(x, "Group") for x in v["groups"]], [pid(x, "Questionnaire") for x in v["qs"]])
        except (KeyError, TypeError) as e:
            die(f"targets-json {k}: formato non valido ({e!r})")
    for ad, (pd, cps, gs, qs) in out.items():
        for r in [f"ActivityDefinition/{ad}"] + [f"CarePlan/{c}" for c in cps] + [f"Group/{x}" for x in gs] \
                + [f"Questionnaire/{q}" for q in qs]:
            if r in visti:
                die(f"targets-json: {r} elencato piu' volte (AD {visti[r]} e AD {ad})")
            visti[r] = ad
    return out, meta


def all_ids(targets):
    for ad, (pd, cps, gs, qs) in targets.items():
        yield from [ad, pd, *cps, *gs, *qs]


def count_actions(actions, canon):
    """(occorrenze al primo livello, occorrenze totali incluse le azioni annidate)."""
    top = sum(1 for x in actions if x.get("definitionCanonical") == canon)
    tot = 0
    stack = list(actions)
    while stack:
        x = stack.pop()
        tot += 1 if x.get("definitionCanonical") == canon else 0
        stack.extend(x.get("action", []))
    return top, tot


# ---------------------------------------------------------------- preflight
def study_tree(api, studio, id_minimo, errs):
    """Solo verso il basso: radice.partOf -> figli, studio.protocol -> PD, PD.relatedArtifact -> PD sotto-linea.
    Ritorna (id studi, id PD, titolo radice)."""
    sid = num(studio, "ResearchStudy")
    root = rd(api, "ResearchStudy", sid)
    studies, pds = {sid}, set()
    figli = [num(p.get("reference"), "ResearchStudy") for p in root.get("partOf", [])]
    for f in figli:
        studies.add(f)
    coda_pd = []
    for i in sorted(studies):
        st = root if i == sid else rd(api, "ResearchStudy", i)
        for p in st.get("protocol", []):
            coda_pd.append(num(p.get("reference"), "PlanDefinition"))
        if i != sid:
            for p in st.get("partOf", []):
                if num(p.get("reference"), "ResearchStudy") not in studies:
                    errs.append(f"ResearchStudy/{i}: partOf {p.get('reference')} punta FUORI dall'albero")
        n = cnt(api, f"ResearchSubject?study=ResearchStudy/{i}&_summary=count&_total=accurate")
        print(f"  studio {i}: ResearchSubject = {n}")
        if n:
            errs.append(f"ResearchStudy/{i} ha {n} ResearchSubject: una copia non ha pazienti arruolati, "
                        f"questo sembra lo studio ORIGINALE")
    while coda_pd:
        i = coda_pd.pop()
        if i in pds:
            continue
        if len(pds) > 500:
            raise ApiError("albero PlanDefinition troppo grande (>500): abort")
        pds.add(i)
        p = rd(api, "PlanDefinition", i)
        for ra in p.get("relatedArtifact", []):
            if ra.get("type") != "documentation":
                continue
            r = ra.get("resource") or ra.get("url")
            if r and norm_ref(r).startswith("PlanDefinition/"):
                coda_pd.append(num(r, "PlanDefinition"))
    if id_minimo is not None:
        for i in sorted(studies | pds):
            if i < id_minimo:
                errs.append(f"id {i} dell'albero studio (studio o PlanDefinition) < --id-minimo {id_minimo}")
    return studies, pds, root.get("title")


def qr_forms(api_base, qres, q):
    forms = [f"Questionnaire/{q}", f"{api_base.rstrip('/')}/Questionnaire/{q}"]
    if qres.get("url"):
        forms.append(qres["url"])
        if qres.get("version"):
            forms.append(f"{qres['url']}|{qres['version']}")
    return forms


def build_index(api):
    """Scansione fail-closed di tutte le risorse che possono referenziare i target.
    Ritorna (refs {Tipo/id: {owner}}, urls {stringa url: {owner}})."""
    refs, urls = {}, {}
    for tipo in ("ActivityDefinition", "PlanDefinition", "ResearchStudy", "CarePlan", "ResearchSubject",
                 "Task", "Library", "Questionnaire"):
        try:
            b = bundle(api, f"{tipo}?_count={CAP}&_total=accurate")
        except ApiError as e:
            raise ApiError(f"scansione {tipo} non eseguibile ({e}): controllo fail-closed, abort")
        ents = [e["resource"] for e in b.get("entry", []) if "resource" in e]
        t = b.get("total")
        if not isinstance(t, int) or isinstance(t, bool) or t != len(ents):
            raise ApiError(f"scansione {tipo} non affidabile (total={t!r}, entry={len(ents)})")
        for r in ents:
            owner = f"{tipo}/{r.get('id')}"
            # l'url canonico PROPRIO della risorsa non e' un riferimento (url condivisi tra versioni/copie)
            for s in strings({k: v for k, v in r.items() if k != "url"}):
                n = norm_ref(s)
                if re.fullmatch(r"[A-Za-z]+/\d+", n):
                    refs.setdefault(n, set()).add(owner)
                urls.setdefault(s.split("|")[0], set()).add(owner)
        print(f"  scansione {tipo}: total={t}, {len(ents)} risorse")
    return refs, urls


def preflight(api, base, targets, studio, id_minimo, titolo):
    """Solo GET. Ritorna la lista dei problemi (vuota = ok)."""
    errs = []
    tree_pds = None
    studies = set()
    perpd = {}
    for ad, (pd, _c, _g, _q) in targets.items():
        perpd.setdefault(pd, []).append(ad)
    for pd, ads in perpd.items():
        if len(ads) > 1:
            errs.append(f"PlanDefinition/{pd} contiene piu' AD target {sorted(ads)}: dividere in un file/esecuzione per ogni PD")
    if errs:
        return errs
    if studio:
        studies, tree_pds, tit = study_tree(api, studio, id_minimo, errs)
        print(f"  albero studio {studio}: titolo radice {tit!r}, {len(studies)} studi, {len(tree_pds)} PlanDefinition")
        if titolo is not None and titolo != tit:
            errs.append(f"--conferma-titolo-studio {titolo!r} diverso dal titolo dello studio {tit!r}")
    else:
        print("  ATTENZIONE: --studio assente, albero studio NON verificato (obbligatorio in apply)")
    try:
        refs, urls = build_index(api)
    except ApiError as e:
        errs.append(str(e))
        return errs
    if studio:
        # antenati: nessuno studio FUORI dall'albero deve referenziare uno studio dell'albero
        for sid_ in sorted(studies):
            fuori = {o for o in refs.get(f"ResearchStudy/{sid_}", set())
                     if o.startswith("ResearchStudy/") and int(o.split("/")[1]) not in studies}
            if fuori:
                errs.append(f"ResearchStudy/{sid_} e' referenziato da studi FUORI dall'albero {sorted(fuori)}: "
                            f"--studio non e' una vera radice (o e' parte dell'originale)")
        # PlanDefinition target: referenziati solo da studi/PD dell'albero
        dentro = {f"ResearchStudy/{i}" for i in studies} | {f"PlanDefinition/{i}" for i in tree_pds}
        for pd in perpd:
            fuori = refs.get(f"PlanDefinition/{pd}", set()) - dentro
            if fuori:
                errs.append(f"PlanDefinition/{pd} e' referenziato da risorse FUORI dall'albero {sorted(fuori)}")

    for ad, (pd, cps, gs, qs) in targets.items():
        tag = f"AD {ad}"
        adr = rd(api, "ActivityDefinition", ad)
        t = adr.get("title")
        if not isinstance(t, str) or not t:
            raise ApiError(f"ActivityDefinition/{ad}: titolo assente o nullo")
        if not t.lower().startswith("fine trattamento"):
            errs.append(f"{tag}: titolo inatteso {t!r}")
        rel = {norm_ref(r.get("resource")) for r in adr.get("relatedArtifact", [])}
        rel_cp = {r for r in rel if r.startswith("CarePlan/")}
        rel_g = {r for r in rel if r.startswith("Group/")}
        if rel_cp != {f"CarePlan/{c}" for c in cps}:
            errs.append(f"{tag}: CarePlan in relatedArtifact {sorted(rel_cp)} != elencati "
                        f"{sorted(f'CarePlan/{c}' for c in cps)}")
        if rel_g != {f"Group/{x}" for x in gs}:
            errs.append(f"{tag}: Group in relatedArtifact {sorted(rel_g)} != elencati "
                        f"{sorted(f'Group/{x}' for x in gs)}")
        allowed = {f"ActivityDefinition/{ad}", f"PlanDefinition/{pd}"} | {f"CarePlan/{c}" for c in cps}
        cp_q = set()
        for c in cps:
            cpr = rd(api, "CarePlan", c)
            for r in strings(cpr.get("activity", [])):
                n = norm_ref(r)
                if n.startswith("Questionnaire/"):
                    cp_q.add(n)
            for sub in ("QuestionnaireResponse", "Observation"):
                n = cnt(api, f"{sub}?based-on=CarePlan/{c}&_summary=count&_total=accurate")
                if n:
                    errs.append(f"{tag}: {n} {sub} con based-on CarePlan/{c}")
        listed_q = {f"Questionnaire/{q}" for q in qs}
        if cp_q != listed_q:
            errs.append(f"{tag}: Questionnaire referenziati dai CarePlan {sorted(cp_q)} != elencati {sorted(listed_q)}")
        qurls = set()
        for q in qs:
            qr = rd(api, "Questionnaire", q)
            if qr.get("url"):
                qurls.add(qr["url"])
            for f in qr_forms(base, qr, q):
                n = cnt(api, f"QuestionnaireResponse?questionnaire={quote(f, safe='/:')}&_summary=count&_total=accurate")
                print(f"  conteggio QuestionnaireResponse per {f}: {n}")
                if n:
                    errs.append(f"{tag}: {n} QuestionnaireResponse su {f}")
        for x in gs:
            g = rd(api, "Group", x)
            if g.get("member"):
                errs.append(f"{tag}: Group/{x} ha {len(g['member'])} member")
            for path in (f"Observation?focus=Group/{x}", f"Observation?subject=Group/{x}",
                         f"Consent?actor=Group/{x}", f"ResearchStudy?enrollment=Group/{x}"):
                n = cnt(api, path + "&_summary=count&_total=accurate")
                if n:
                    errs.append(f"{tag}: {n} risorse trovate da {path}")
        # nessun altro referrer (riferimenti normalizzati e url canonici) per AD/CP/Group/Q
        target_refs = [f"ActivityDefinition/{ad}"] + [f"CarePlan/{c}" for c in cps] \
            + [f"Group/{x}" for x in gs] + sorted(listed_q)
        aurl = adr.get("url")
        for r in target_refs:
            found = set(refs.get(r, set()))
            if r.startswith("ActivityDefinition/") and aurl:
                found |= urls.get(aurl, set())
            if r.startswith("Questionnaire/"):
                for u in qurls:
                    found |= urls.get(u, set())
            extra = found - allowed - {r}
            if extra:
                errs.append(f"{tag}: {r} e' referenziato da risorse non ammesse: {sorted(extra)}")
        # PlanDefinition
        canon = f"ActivityDefinition/{ad}"
        if tree_pds is not None and pd not in tree_pds:
            errs.append(f"{tag}: PlanDefinition/{pd} NON appartiene all'albero dello studio {studio}")
        p = rd(api, "PlanDefinition", pd)
        top, tot = count_actions(p.get("action", []), canon)
        if (top, tot) != (1, 1):
            errs.append(f"{tag}: nel PlanDefinition/{pd} l'azione {canon} compare {top} volte al primo "
                        f"livello e {tot} in totale (atteso esattamente 1)")
        n = cnt(api, f"PlanDefinition?definition={canon}&_summary=count&_total=accurate")
        if n != 1:
            errs.append(f"{tag}: {n} PlanDefinition referenziano {canon} (atteso 1: PlanDefinition/{pd})")
    return errs


# ---------------------------------------------------------------- esecuzione
def write_backups(api, targets, bdir):
    refs = []
    for ad, (pd, cps, gs, qs) in targets.items():
        for r in [("ActivityDefinition", ad), ("PlanDefinition", pd)] + [("CarePlan", c) for c in cps] \
                + [("Group", x) for x in gs] + [("Questionnaire", q) for q in qs]:
            if r not in refs:
                refs.append(r)
    paths = {r: os.path.join(bdir, f"{r[0]}-{r[1]}.json") for r in refs}
    if os.path.exists(bdir) and (not os.path.isdir(bdir) or os.listdir(bdir)):
        die(f"--backup-dir {bdir} esiste e non e' una directory vuota: usare una directory nuova o vuota")
    os.makedirs(bdir, mode=0o700, exist_ok=True)
    os.chmod(bdir, 0o700)
    opener = lambda path, flags: os.open(path, flags, 0o600)
    n = 0
    for (t, i), p in paths.items():
        raw = json.dumps(rd(api, t, i), indent=1)
        with open(p, "x", opener=opener) as f:
            f.write(raw)
        with open(os.path.join(bdir, "SHA256SUMS"), "a", opener=opener) as f:
            f.write(f"{hashlib.sha256(raw.encode()).hexdigest()}  {os.path.basename(p)}\n")
        n += 1
    print(f"backup: {n} risorse in {bdir}")


def build_steps(api, targets, bdir, base):
    steps = []
    for ad, (pd, cps, gs, qs) in targets.items():
        def rimuovi(ad=ad, pd=pd):
            canon = f"ActivityDefinition/{ad}"
            p = rd(api, "PlanDefinition", pd)
            top, tot = count_actions(p.get("action", []), canon)
            if (top, tot) != (1, 1):
                raise ApiError(f"PlanDefinition/{pd}: azione {canon} trovata {top}/{tot} volte, atteso 1")
            v = p.get("meta", {}).get("versionId")
            if not v:
                raise ApiError(f"PlanDefinition/{pd}: versionId assente, impossibile If-Match")
            with open(os.path.join(bdir, f"PlanDefinition-{pd}.json")) as f:
                vb = json.load(f).get("meta", {}).get("versionId")
            if vb != v:
                raise ApiError(f"PlanDefinition/{pd} modificato dopo il backup (versione {vb} -> {v}): abort")
            nuovo = dict(p)
            nuovo["action"] = [x for x in p["action"] if x.get("definitionCanonical") != canon]
            api.call("PUT", f"PlanDefinition/{pd}", nuovo, {"If-Match": f'W/"{v}"'})
            dopo = rd(api, "PlanDefinition", pd)
            diff = sorted(k for k in (set(p) | set(dopo)) - {"action", "meta"} if p.get(k) != dopo.get(k))
            for k in ("tag", "security"):
                if p.get("meta", {}).get(k) != dopo.get("meta", {}).get(k):
                    diff.append(f"meta.{k}")
            if diff or dopo.get("action") != nuovo["action"]:
                raise ApiError(f"PlanDefinition/{pd} alterato dal PUT (campi diversi: {diff or ['action']}). "
                               f"STOP prima dei DELETE. Ripristino: PUT del backup "
                               f"{os.path.join(bdir, f'PlanDefinition-{pd}.json')} su PlanDefinition/{pd}")
        steps.append((f"PUT PlanDefinition/{pd} (toglie azione AD {ad})", rimuovi))
        for t, ids in (("ActivityDefinition", [ad]), ("CarePlan", cps), ("Group", gs), ("Questionnaire", qs)):
            for i in ids:
                def canc(t=t, i=i):
                    # TOCTOU: la versione corrente deve coincidere con quella del backup
                    cur = rd(api, t, i)
                    with open(os.path.join(bdir, f"{t}-{i}.json")) as f:
                        vb = json.load(f).get("meta", {}).get("versionId")
                    if cur.get("meta", {}).get("versionId") != vb:
                        raise ApiError(f"{t}/{i} modificato dopo il backup (versione {vb} -> "
                                       f"{cur.get('meta', {}).get('versionId')}): abort prima del DELETE")
                    if t == "Questionnaire":
                        for fm in qr_forms(base, cur, i):
                            n = cnt(api, f"QuestionnaireResponse?questionnaire={quote(fm, safe='/:')}"
                                         f"&_summary=count&_total=accurate")
                            if n:
                                raise ApiError(f"Questionnaire/{i}: comparse {n} QuestionnaireResponse su {fm}: "
                                               f"abort prima del DELETE")
                    api.call("DELETE", f"{t}/{i}")
                    try:
                        api.get(f"{t}/{i}")
                    except ApiError as e:
                        if e.status in (404, 410):  # esisteva nel preflight (altrimenti abort): 404 accettabile
                            return
                        raise ApiError(f"{t}/{i}: cancellazione non verificabile: {e}", None, True)
                    raise ApiError(f"{t}/{i}: cancellazione non confermata (la GET successiva risponde 200)",
                                   None, True)
                steps.append((f"DELETE {t}/{i}", canc))
    return steps


def run_steps(steps):
    """Si ferma al primo errore. Ritorna True se tutto ok."""
    done, failed, pending = [], None, []
    for idx, (desc, fn) in enumerate(steps):
        try:
            fn()
            done.append(desc)
            print(f"  OK {desc}")
        except KeyboardInterrupt:
            failed = (desc, "interrotto dall'utente: ESITO INCERTO, verificare sul server")
        except Exception as e:
            inc = getattr(e, "uncertain", False)
            failed = (desc, ("ESITO INCERTO, verificare sul server: " if inc else "") + str(e))
        if failed:
            pending = [d for d, _ in steps[idx + 1:]]
            break
    if not failed:
        print(f"completato: {len(done)} operazioni")
        return True
    print("\nERRORE: esecuzione INTERROTTA al primo fallimento")
    print(f"FATTE ({len(done)}):", *([f"  - {d}" for d in done] or ["  (nessuna)"]), sep="\n")
    print(f"FALLITA:\n  - {failed[0]}: {failed[1]}")
    print(f"IN ATTESA ({len(pending)}):", *([f"  - {d}" for d in pending] or ["  (nessuna)"]), sep="\n")
    print("Nessun ripristino ne' ripresa automatici: completare A MANO dai backup (PUT del PD / DELETE in attesa).")
    return False


def main(argv=None):
    ap = argparse.ArgumentParser(description="Elimina gli AD 'Fine Trattamento' di una copia studio")
    ap.add_argument("mode", choices=["dry-run", "apply"])
    ap.add_argument("--base", required=True)
    ap.add_argument("--targets-json", required=True,
                    help="mappa 'ActivityDefinition/<id>' -> {title, cps, groups, qs, pds} (id come 'Tipo/id') + host/studio")
    ap.add_argument("--backup-dir")
    ap.add_argument("--yes", action="store_true")
    ap.add_argument("--conferma-host", help="host atteso di --base (obbligatorio in apply)")
    ap.add_argument("--studio", help="ResearchStudy/<id> radice dello studio copia (obbligatorio in apply)")
    ap.add_argument("--conferma-titolo-studio", help="titolo esatto dello studio radice (obbligatorio in apply)")
    ap.add_argument("--id-minimo", type=int, help="N >= 1: rifiuta se un id e' inferiore (obbligatorio in apply)")
    ap.add_argument("--diretto", action="store_true",
                    help="apply solo su HAPI diretto: conferma esplicita (base che finisce per /fhir)")
    a = ap.parse_args(argv)

    # --- controlli locali, prima di qualsiasi chiamata di rete ---
    targets, meta = load_targets(a.targets_json)
    if a.id_minimo is not None:
        if a.id_minimo < 1:
            die("--id-minimo deve essere >= 1")
        bassi = sorted(i for i in all_ids(targets) if i < a.id_minimo)
        if bassi:
            die(f"id inferiori a --id-minimo {a.id_minimo}: {bassi}. Rifiuto, nessuna chiamata effettuata.")
    host = (urlparse(a.base).hostname or "").lower()
    if a.conferma_host is not None and a.conferma_host.lower() != host:
        die(f"--conferma-host {a.conferma_host!r} non coincide con l'host di --base ({host!r})")
    if "host" in meta and str(meta["host"]).lower() != host:
        die(f"targets-json: host {meta['host']!r} diverso dall'host di --base ({host!r})")
    if a.studio is not None:
        sid = pid(a.studio, "ResearchStudy")
        if a.id_minimo is not None and sid < a.id_minimo:
            die(f"--studio {a.studio} ha id < --id-minimo {a.id_minimo}")
    if "studio" in meta and (a.studio is None or meta["studio"] != a.studio):
        die(f"targets-json: studio {meta['studio']!r} diverso da --studio ({a.studio!r})")
    direct = a.base.rstrip("/").endswith("/fhir")
    if a.mode == "apply":
        if not a.diretto or not direct:
            die("apply e' ammesso SOLO su HAPI diretto: serve --diretto e una --base che finisce per /fhir "
                "(il proxy e' consentito solo per il dry-run in sola lettura)")
        if not a.conferma_host:
            die("apply richiede --conferma-host HOST (deve coincidere con l'host di --base)")
        if a.id_minimo is None:
            die("apply richiede --id-minimo N (>= 1)")
        if not a.studio:
            die("apply richiede --studio ResearchStudy/<id>")
        if "host" not in meta or "studio" not in meta:
            die("apply richiede le chiavi 'host' e 'studio' nel targets-json")
        if a.conferma_titolo_studio is None:
            die("apply richiede --conferma-titolo-studio \"TITOLO\"")
        if not a.yes:
            die("serve --yes")
        if not a.backup_dir:
            die("apply richiede --backup-dir")
        if os.path.exists(a.backup_dir) and (not os.path.isdir(a.backup_dir) or os.listdir(a.backup_dir)):
            die(f"--backup-dir {a.backup_dir} esiste e non e' una directory vuota")

    raw, direct = make_raw(a.base)
    api = Api(raw)

    # --- preflight (solo GET) ---
    try:
        errs = preflight(api, a.base, targets, a.studio, a.id_minimo, a.conferma_titolo_studio)
    except ApiError as e:
        die(f"preflight interrotto: {e}. Nessuna modifica.", 1)
    if errs:
        die("PREFLIGHT FALLITO, nessuna modifica effettuata:\n" + "\n".join(f"  - {e}" for e in errs), 1)
    print("preflight OK")
    if not direct:
        print("ATTENZIONE: via proxy i conteggi riflettono solo cio' che l'utente vede: questo dry-run NON e' una garanzia "
              "(apply ammesso solo su HAPI diretto).")
    if a.mode == "dry-run":
        for ad, (pd, cps, gs, qs) in targets.items():
            print(f"  [dry-run] PUT PlanDefinition/{pd} (toglie azione AD {ad})")
            for t, ids in (("ActivityDefinition", [ad]), ("CarePlan", cps), ("Group", gs), ("Questionnaire", qs)):
                for i in ids:
                    print(f"  [dry-run] DELETE {t}/{i}")
        return

    try:
        write_backups(api, targets, a.backup_dir)
    except ApiError as e:
        die(f"backup fallito: {e}. Nessuna scrittura sul server.", 1)
    if not run_steps(build_steps(api, targets, a.backup_dir, a.base)):
        sys.exit(1)


if __name__ == "__main__":
    main()
