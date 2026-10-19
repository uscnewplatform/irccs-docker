#!/usr/bin/env python3
"""Audit SOLO LETTURA delle Observation `end-of-treatments-N`.

Il lettore del dashboard sblocca l'eleggibilita' della linea successiva quando esiste per il paziente una
Observation con codice `end-of-treatments-N`. Le Observation nascono da `QuestionnaireResponse/$extract` con
id deterministico `extract-<qrId>.<linkId>`. Nello schema nuovo il campo e' una DATA marcata con
l'estensione `end-of-treatment`; nello schema vecchio il codice era scritto a mano su un Si'/No (o sulla
data) e un salvataggio automatico con il Si'/No lasciato a "No" poteva sbloccare la linea per errore.

Per ogni Observation legge la QuestionnaireResponse (`derivedFrom`), il Questionnaire e trova l'item sorgente
dal linkId dell'id; classi:
  OK                    item sorgente marcato `end-of-treatment` e di tipo diverso da boolean
  SOSPETTA-valore-falso valueBoolean = false (prevale su tutte le altre classi, anche SORGENTE-NON-TROVATA)
  SOSPETTA-boolean      item sorgente di tipo boolean (schema vecchio)
  NON-MARCATA           item sorgente senza marcatore (codice scritto a mano)
  SORGENTE-NON-TROVATA  QR/Questionnaire/item sorgente non determinabili (e valore non false)
Output: solo id e tipo di valore; il valore e' stampato solo per i boolean (nessun dato anagrafico/clinico). NESSUNA scrittura: la sanatoria e' manuale.

Sicurezze: solo HAPI diretto (base che termina con /fhir); `--conferma-host HOST` obbligatorio e uguale
all'host di `--base` (controllo prima di qualsiasi chiamata di rete); il link `next` dei Bundle e' seguito
solo se punta allo stesso host/porta/percorso base.

Uso (solo preprod):
  python3 audit_end_of_treatments.py --base http://HOST:8080/fhir --conferma-host HOST
"""
import argparse, os, re, sys
from collections import Counter
from urllib.parse import urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import align_therapy_branch as a  # noqa: E402

MARK = "http://irccs.pascale.napoli.it/fhir/StructureDefinition/end-of-treatment"
CLASSI = ["OK", "SOSPETTA-boolean", "SOSPETTA-valore-falso", "NON-MARCATA", "SORGENTE-NON-TROVATA"]
EXTRACT_ID_RE = re.compile(r"^extract-(\d+)\.(.+)$")
QUEST_REF_RE = re.compile(r"(?:^|/)Questionnaire/(\d+)(?:\||$)")


def host_di(base):
    """Host (senza porta) dell'URL base, in minuscolo."""
    return (urlparse(base).hostname or "").lower()


def netloc_di(url):
    p = urlparse(url)
    return (p.scheme.lower(), (p.hostname or "").lower(), p.port)


def trova_item(items, linkid):
    """Ricerca ricorsiva dell'item con il linkId dato (None se assente)."""
    for it in items or []:
        if it.get("linkId") == linkid:
            return it
        r = trova_item(it.get("item"), linkid)
        if r is not None:
            return r
    return None


def marcato(it):
    return any(e.get("url") == MARK and e.get("valueBoolean") is True for e in it.get("extension", []))


def classifica(obs, item):
    """Classe dell'Observation dato l'item sorgente (None se non trovato)."""
    if obs.get("valueBoolean") is False:
        return "SOSPETTA-valore-falso"
    if item is None:
        return "SORGENTE-NON-TROVATA"
    if item.get("type") == "boolean":
        return "SOSPETTA-boolean"
    if not marcato(item):
        return "NON-MARCATA"
    return "OK"


def valore(obs):
    for k, v in obs.items():
        if k.startswith("value"):
            return f"{k[5:]}={v}" if isinstance(v, bool) else k[5:]  # valore solo per i boolean
    return "-"


def next_path(bundle, base):
    """Percorso relativo (rispetto a base) del link `next`, None se assente; sys.exit se su altro host."""
    url = next((l.get("url") for l in bundle.get("link", []) if l.get("relation") == "next"), None)
    if not url:
        return None
    pb, pn = urlparse(base), urlparse(url)
    if netloc_di(url) != netloc_di(base) or not (pn.path.rstrip("/") == pb.path.rstrip("/") or pn.path.startswith(pb.path.rstrip("/") + "/")):
        sys.exit(f"rifiuto: il link next del Bundle punta a un altro host/percorso ({pn.scheme}://{pn.netloc}{pn.path})")
    rel = pn.path[len(pb.path.rstrip("/")) + 1:]  # "" se il link e' la base stessa (tipico HAPI: /fhir?_getpages=...)
    return rel + ("?" + pn.query if pn.query else "")


MAX_PAGINE = 5000


def leggi_observation(f, base, codici):
    """Tutte le Observation con i codici dati, con paginazione (_count=100 + next)."""
    path = "Observation?code=" + ",".join(codici) + "&_count=100"
    out, visti = [], set()
    while path:
        if path in visti:
            sys.exit("rifiuto: paginazione ciclica")
        visti.add(path)
        if len(visti) > MAX_PAGINE:
            sys.exit(f"rifiuto: oltre {MAX_PAGINE} pagine di risultati, interrompo la paginazione")
        b = f.get(path)
        out += [e["resource"] for e in b.get("entry", []) if (e.get("resource") or {}).get("resourceType") == "Observation"]
        path = next_path(b, base)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--conferma-host", metavar="HOST", help="obbligatorio: deve coincidere con l'host di --base")
    ap.add_argument("--linee", default="1,2,3", help="numeri di linea N da cercare (default 1,2,3)")
    args = ap.parse_args()
    if not args.base.rstrip("/").endswith("/fhir"):
        sys.exit("solo HAPI diretto: la base deve terminare con /fhir (usare solo su preprod)")
    host = host_di(args.base)
    if not args.conferma_host:
        sys.exit(f"serve --conferma-host {host or 'HOST'} (host di --base)")
    if args.conferma_host.strip().lower() != host:
        sys.exit(f"--conferma-host {args.conferma_host!r} non coincide con l'host di --base ({host!r})")
    linee = [x.strip() for x in args.linee.split(",")]
    if not all(re.match(r"^\d+$", x) for x in linee):
        sys.exit("--linee: solo numeri separati da virgola")
    base = args.base.rstrip("/")
    f = a.Fhir(base)

    obs_list = leggi_observation(f, base, [f"end-of-treatments-{n}" for n in linee])
    print(f"Observation trovate: {len(obs_list)}")
    qr_cache, q_cache, conteggio = {}, {}, Counter()
    righe = []
    for o in obs_list:
        oid = str(o.get("id"))
        paz = (o.get("subject") or {}).get("reference", "-")
        code = next((c.get("code") for c in (o.get("code") or {}).get("coding", [])
                     if (c.get("code") or "").startswith("end-of-treatments-")), "-")
        m = EXTRACT_ID_RE.match(oid)
        qr_id, linkid = (m.group(1), m.group(2)) if m else (None, None)
        if qr_id is None:  # id non standard: prova con derivedFrom
            d = next((x.get("reference") for x in o.get("derivedFrom", []) if (x.get("reference") or "").startswith("QuestionnaireResponse/")), None)
            qr_id = d.split("/", 1)[1] if d else None
        qr_stato, q_id, item = "-", "-", None
        if qr_id and re.match(r"^\d+$", qr_id):
            if qr_id not in qr_cache:
                qr = f.get(f"QuestionnaireResponse/{qr_id}")
                qr_cache[qr_id] = qr if isinstance(qr, dict) and qr.get("resourceType") == "QuestionnaireResponse" else None
            qr = qr_cache[qr_id]
            if qr:
                qr_stato = qr.get("status", "-")
                qm = QUEST_REF_RE.search(qr.get("questionnaire") or "")
                if qm:
                    q_id = qm.group(1)
                    if q_id not in q_cache:
                        q = f.get(f"Questionnaire/{q_id}")
                        q_cache[q_id] = q if isinstance(q, dict) and q.get("resourceType") == "Questionnaire" else None
                    if q_cache[q_id] and linkid:
                        item = trova_item(q_cache[q_id].get("item"), linkid)
        cl = classifica(o, item)
        conteggio[cl] += 1
        righe.append((paz, oid, f"{qr_id or '-'} ({qr_stato})", q_id, (linkid or "-")[:8], code, valore(o), cl))
    for r in sorted(righe, key=lambda r: (r[0], r[1])):
        print("Paziente={} Observation={} QR={} Questionnaire={} linkId={} codice={} valore={} classe={}".format(*r))
    print("\nRiassunto per classe:")
    for c in CLASSI:
        print(f"  {c}: {conteggio.get(c, 0)}")
    print(f"  TOTALE: {sum(conteggio.values())}")


if __name__ == "__main__":
    main()
