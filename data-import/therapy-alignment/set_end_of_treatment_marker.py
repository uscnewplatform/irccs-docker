#!/usr/bin/env python3
"""Marca il campo "fine trattamento" indicato e ripulisce i codici `end-of-treatments-N` scritti a mano.

Per ogni Questionnaire indicato con `--campo ID=LINKID`:
  - l'item con quel linkId (cercato ricorsivamente; tipi ammessi: gli stessi di `canBeEndOfTreatment`
    del dashboard, vedi TIPI_AMMESSI; se il linkId e' duplicato OGNI item deve essere di tipo ammesso;
    di norma la DATA di fine trattamento) riceve `observationExtract=true` e il marcatore `end-of-treatment`;
    il suo `code` NON viene modificato (il numero della linea e' applicato a runtime dal dashboard);
  - ogni altro item con un coding `end-of-treatments-N` (qualsiasi system) perde quel coding; se non
    restano altri code, perde la chiave `code` e anche `observationExtract` (un item estraibile senza
    codice puo' far fallire `$extract`); perde anche un eventuale marcatore `end-of-treatment`
    (caso: esecuzione precedente che aveva marcato il Si'/No);
  - un item gia' marcato diverso dal target, senza coding scritto a mano, perde il marcatore
    (e `observationExtract` solo se non ha `code`).
Lo script e' idempotente: una seconda esecuzione riporta "nessuna modifica".

Sicurezze: solo HAPI diretto (base che termina con /fhir); `apply` richiede `--yes`, `--backup-dir` e
`--conferma-host HOST` (deve coincidere con l'host di `--base`; il dry-run non lo richiede); il backup di
ogni Questionnaire e' la copia della STESSA lettura usata per la PUT (If-Match da meta.versionId; senza
versionId `apply` rifiuta); `--campo` accetta solo id numerici e la risorsa letta deve essere il
Questionnaire richiesto. Le linee esterne (default 35048,35124,35204, sostituibili con
`--linee-esterne ID[,ID...]`) sono rifiutate in apply salvo `--anche-linee-esterne`.

Uso (HAPI diretto, solo preprod):
  python3 set_end_of_treatment_marker.py dry-run --base http://HOST:8080/fhir \\
      --campo 35030=eb78d984-eb38-40fc-8921-aa1839b629bd
  python3 set_end_of_treatment_marker.py apply --yes --base ... --campo ID=LINKID --backup-dir DIR \\
      --conferma-host HOST
`--campo` e' ripetibile (uno per Questionnaire). I Fine Trattamento delle linee esterne
(un CRF per linea, codice gia' corretto) NON vanno indicati.
"""
import argparse, copy, hashlib, json, os, re, sys
from urllib.parse import urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import align_therapy_branch as a  # noqa: E402

MARK = "http://irccs.pascale.napoli.it/fhir/StructureDefinition/end-of-treatment"
EXTRACT = "http://hl7.org/fhir/StructureDefinition/questionnaire-observationExtract"
# CRF Fine Trattamento delle linee esterne (codice gia' corretto): non vanno migrati
# (default; sostituibile con --linee-esterne per altri ambienti)
LINEE_ESTERNE = {"35048", "35124", "35204"}
CODE_RE = re.compile(r"^end-of-treatments-\d+$")
ID_RE = re.compile(r"^\d+$")
# stessi tipi di canBeEndOfTreatment (src/fhir/extensions/endOfTreatment.ts); tipo mancante = non ammesso
TIPI_AMMESSI = frozenset({"boolean", "date", "dateTime", "time", "string", "text", "integer", "decimal",
                          "quantity", "choice", "open-choice"})


def _trova_tutti(items, linkid):
    """Cerca ricorsivamente TUTTI gli item con il linkId dato."""
    out = []
    for it in items or []:
        if it.get("linkId") == linkid:
            out.append(it)
        out += _trova_tutti(it.get("item"), linkid)
    return out


def _set_ext(it, urls_da_togliere, da_aggiungere):
    """Riscrive le estensioni dell'item: toglie gli url indicati, aggiunge quelle richieste."""
    exts = [e for e in it.get("extension", []) if e.get("url") not in urls_da_togliere]
    exts += da_aggiungere
    if exts:
        it["extension"] = exts
    else:
        it.pop("extension", None)


def _marcato_ok(it):
    """True se l'item ha gia' esattamente un EXTRACT=true e un MARK=true."""
    exts = it.get("extension", [])
    for url in (EXTRACT, MARK):
        mie = [e for e in exts if e.get("url") == url]
        if len(mie) != 1 or mie[0].get("valueBoolean") is not True:
            return False
    return True


def _visita(items, target_linkid, azioni):
    for it in items or []:
        lid = it.get("linkId")
        if lid == target_linkid:
            if not _marcato_ok(it):
                _set_ext(it, (MARK, EXTRACT),
                         [{"url": EXTRACT, "valueBoolean": True}, {"url": MARK, "valueBoolean": True}])
                azioni.append((lid, "campo target: aggiunti observationExtract + marcatore end-of-treatment"))
        else:
            codes = [c for c in (it.get("code") or []) if CODE_RE.match(c.get("code") or "")]
            marcato = any(e.get("url") == MARK for e in it.get("extension", []))
            if codes:
                rest = [c for c in (it.get("code") or []) if c not in codes]
                if rest:
                    it["code"] = rest
                else:
                    del it["code"]
            if codes or marcato:
                fatto = []
                if codes:
                    fatto.append("tolto coding " + ", ".join(c["code"] for c in codes))
                if marcato:
                    fatto.append("tolto marcatore end-of-treatment")
                da_togliere = [MARK]
                if not it.get("code") and any(e.get("url") == EXTRACT for e in it.get("extension", [])):
                    da_togliere.append(EXTRACT)
                    fatto.append("tolto observationExtract (nessun code)")
                _set_ext(it, da_togliere, [])
                azioni.append((lid, "; ".join(fatto)))
        _visita(it.get("item"), target_linkid, azioni)


def migrate_items(items, target_linkid):
    """Modifica in place gli item; ritorna la lista di tuple (linkId, azione).

    Solleva ValueError se il campo target manca o se uno degli item con quel linkId ha un tipo non
    ammesso (nessuna modifica fatta).
    """
    targets = _trova_tutti(items, target_linkid)
    if not targets:
        raise ValueError(f"campo target {target_linkid!r} non trovato")
    for target in targets:
        if target.get("type") not in TIPI_AMMESSI:
            raise ValueError(f"campo target {target_linkid!r} di tipo {target.get('type')!r}: non ammesso")
    azioni = []
    _visita(items, target_linkid, azioni)
    return azioni


def parse_campi(valori):
    """Converte i valori `ID=LINKID` in lista [(id, linkId)] deduplicata; ValueError se malformati o in conflitto."""
    out = {}
    for v in valori:
        qid, sep, lid = v.partition("=")
        qid, lid = qid.strip(), lid.strip()
        if not sep or not qid or not lid or "=" in lid:
            raise ValueError(f"--campo {v!r} malformato: atteso ID=LINKID (es. 35030=eb78d984-eb38-40fc-8921-aa1839b629bd)")
        if not ID_RE.match(qid):
            raise ValueError(f"--campo {v!r}: l'id Questionnaire {qid!r} deve essere numerico")
        if qid in out and out[qid] != lid:
            raise ValueError(f"Questionnaire/{qid} indicato con due linkId diversi: {out[qid]!r} e {lid!r}")
        out[qid] = lid
    return list(out.items())  # dict: ordine di inserimento preservato


def parse_linee_esterne(valore):
    """Converte `ID[,ID...]` in insieme di id numerici; ValueError se malformato."""
    ids = [x.strip() for x in valore.split(",")]
    for x in ids:
        if not ID_RE.match(x):
            raise ValueError(f"--linee-esterne: id {x!r} non numerico")
    return set(ids)


def host_di(base):
    """Host (senza porta) dell'URL base, in minuscolo."""
    return (urlparse(base).hostname or "").lower()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["dry-run", "apply"])
    ap.add_argument("--base", required=True)
    ap.add_argument("--campo", action="append", required=True, metavar="ID=LINKID",
                    help="id Questionnaire e linkId del campo di fine trattamento (ripetibile)")
    ap.add_argument("--backup-dir")
    ap.add_argument("--yes", action="store_true")
    ap.add_argument("--anche-linee-esterne", action="store_true",
                    help="consente di migrare i CRF delle linee esterne (di norma NON vanno migrati)")
    ap.add_argument("--linee-esterne", metavar="ID[,ID...]",
                    help="sostituisce l'elenco predefinito dei Questionnaire delle linee esterne")
    ap.add_argument("--conferma-host", metavar="HOST",
                    help="obbligatorio in apply: deve coincidere con l'host di --base")
    args = ap.parse_args()
    if not args.base.rstrip("/").endswith("/fhir"):
        sys.exit("solo HAPI diretto: la base deve terminare con /fhir (usare solo su preprod)")
    if args.mode == "apply":
        host = host_di(args.base)
        if not args.conferma_host:
            sys.exit(f"apply richiede --conferma-host {host or 'HOST'} (host di --base)")
        if args.conferma_host.strip().lower() != host:
            sys.exit(f"--conferma-host {args.conferma_host!r} non coincide con l'host di --base ({host!r})")
    try:
        linee_esterne = parse_linee_esterne(args.linee_esterne) if args.linee_esterne is not None else LINEE_ESTERNE
        # id duplicati collassati mantenendo l'ordine: un secondo GET restituirebbe la risorsa gia' migrata
        campi = parse_campi(args.campo)
    except ValueError as e:
        sys.exit(f"errore: {e}")
    f = a.Fhir(args.base)
    todo = []
    esterni = [i for i, _ in campi if i in linee_esterne]
    for i in esterni:
        print(f"ATTENZIONE Questionnaire/{i}: linea esterna: NON migrare")
    if esterni and args.mode == "apply" and not args.anche_linee_esterne:
        sys.exit("rifiuto: id di linee esterne (" + ", ".join(esterni) + "); usare --anche-linee-esterne per forzare")
    for qid, linkid in campi:
        q = f.get(f"Questionnaire/{qid}")
        if not isinstance(q, dict) or q.get("resourceType") != "Questionnaire" or str(q.get("id")) != qid:
            sys.exit(f"errore Questionnaire/{qid}: la risorsa letta non e' il Questionnaire richiesto")
        # backup = stessa lettura usata per la PUT, copiata PRIMA di migrate_items
        original = copy.deepcopy(q)
        try:
            azioni = migrate_items(q.get("item"), linkid)
        except ValueError as e:
            sys.exit(f"errore Questionnaire/{qid}: {e}")
        print(f"Questionnaire/{q['id']} {q.get('title')!r} ({q.get('status')}): "
              + ("nessuna modifica" if not azioni else f"{len(azioni)} modifiche"))
        for lid, azione in azioni:
            print(f"  - {lid[:8]}: {azione}")
        if azioni:
            todo.append((q, original))
    if args.mode == "dry-run":
        return
    if not args.yes or not args.backup_dir:
        sys.exit("servono --yes e --backup-dir")
    senza_ver = [q["id"] for q, _ in todo if not (q.get("meta") or {}).get("versionId")]
    if senza_ver:
        sys.exit("rifiuto: Questionnaire senza meta.versionId (nessuna scrittura senza If-Match): " + ", ".join(senza_ver))
    paths = {q["id"]: f"{args.backup_dir}/Questionnaire-{q['id']}.json" for q, _ in todo}
    gia = [p for p in paths.values() if os.path.exists(p)]
    if gia:
        sys.exit("backup gia' esistenti, rifiuto di sovrascrivere: " + ", ".join(gia))
    os.makedirs(args.backup_dir, exist_ok=True)
    sums_path = args.backup_dir + "/SHA256SUMS"
    for q, original in todo:
        raw = json.dumps(original, indent=1)
        path = paths[q["id"]]
        # backup e relativo checksum scritti PRIMA del PUT: un PUT fallito non lascia backup senza SHA256SUMS
        with open(path, "x") as bf:
            bf.write(raw)
        with open(sums_path, "a") as sf:
            sf.write(f"{hashlib.sha256(raw.encode()).hexdigest()}  {os.path.basename(path)}\n")
        f.put(q)
        print(f"PUT Questionnaire/{q['id']}")


if __name__ == "__main__":
    main()
