#!/usr/bin/env python3
"""
Migrazione una-tantum degli AuditEvent PRE-separazione dallo store clinico
(irccs-hapi-fhir, partizione logica AUDIT) allo store di audit dedicato
(irccs-hapi-audit).

Contesto: fino alla separazione fisica dello storage (commit irccs-common
`fffb12c` / irccs-docker `4a55019`) gli AuditEvent venivano scritti nella
partizione AUDIT dell'istanza HAPI clinica. Dopo la separazione i microservizi
scrivono su `org.quarkus.irccs.audit-fhir-server` (= irccs-hapi-audit) e la
dashboard li consulta via `/fhir/auth/audit-events` -> irccs-hapi-audit.
Gli eventi storici restano quindi invisibili finche' non vengono spostati.

Cosa fa lo script:
  1. Legge tutti gli AuditEvent dallo store sorgente in ordine cronologico
     (`_sort=date,_lastUpdated` -> AuditEvent.recorded crescente), seguendo i
     link di paginazione.
  2. Per ogni evento rimuove `id` e `meta` (assegnati dal server) e le
     extension di hash-chain `audit-chain-prev` / `audit-chain-hash` (verranno
     ricalcolate dall'istanza di destinazione).
  3. POST **sequenziale** (uno per volta) su irccs-hapi-audit. La sequenzialita'
     e' obbligatoria: l'`AuditEventHashChainInterceptor` aggancia ogni nuovo
     evento all'ultimo presente (sort `_lastUpdated` DESC) -> POST in parallelo
     o via bundle forkerebbe la catena. Inserendo in ordine di `recorded` su uno
     store vuoto la catena si ricostruisce coerente.
  4. Checkpoint su file (una riga per id sorgente gia' migrato): in caso di
     errore si riprende con `--resume` senza duplicare.

NON cancella nulla dalla sorgente: gli AuditEvent sono append-only (interceptor
+ trigger DB). Restano come copia storica ridondante sull'istanza clinica.

IMPORTANTE - eseguire su store di destinazione VUOTO. Se irccs-hapi-audit
contiene gia' AuditEvent (perche' i microservizi separati sono gia' in
esercizio), quei nuovi eventi hanno una catena propria: mescolarli agli storici
va deciso esplicitamente. Lo script si rifiuta di partire su destinazione non
vuota, salvo `--resume` (riprende la stessa migrazione) o `--allow-nonempty`
(forza: gli storici vengono agganciati in coda alla catena esistente, con
`recorded` nel passato ma posizione in catena successiva - accettabile perche'
la catena certifica l'ordine di *inserimento*, non quello temporale).

Esempi:
  # deploy irccs-docker (script sull'host, entrambe le istanze su 127.0.0.1):
  python3 migrate_auditevents_to_audit_store.py

  # con token bearer (se le istanze sono dietro auth):
  python3 migrate_auditevents_to_audit_store.py \
      --source-url http://127.0.0.1:8080/fhir \
      --target-url http://127.0.0.1:8081/fhir \
      --source-token "$ADMIN_BEARER" --target-token "$ADMIN_BEARER"

  # prova a vuoto (nessuna scrittura):
  python3 migrate_auditevents_to_audit_store.py --dry-run

  # riprendi dopo un errore:
  python3 migrate_auditevents_to_audit_store.py --resume
"""
import argparse
import json
import os
import sys
import time

import requests

FHIR_MEDIA_TYPE = "application/fhir+json"
CHAIN_EXT_URLS = {
    "http://irccs.pascale.it/fhir/StructureDefinition/audit-chain-prev",
    "http://irccs.pascale.it/fhir/StructureDefinition/audit-chain-hash",
}
DEFAULT_CHECKPOINT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), ".migrate_auditevents.state"
)


def auth_headers(token):
    h = {"Accept": FHIR_MEDIA_TYPE, "Content-Type": FHIR_MEDIA_TYPE}
    if token:
        h["Authorization"] = token if token.lower().startswith("bearer ") else f"Bearer {token}"
    return h


def count_auditevents(base_url, token):
    r = requests.get(
        f"{base_url}/AuditEvent",
        params={"_summary": "count", "_total": "accurate"},
        headers=auth_headers(token),
        timeout=60,
    )
    r.raise_for_status()
    return r.json().get("total", 0)


def iter_source_auditevents(base_url, token, page_size):
    """Genera gli AuditEvent sorgente in ordine di recorded crescente."""
    url = f"{base_url}/AuditEvent"
    params = {"_sort": "date,_lastUpdated", "_count": str(page_size)}
    while url:
        r = requests.get(url, params=params, headers=auth_headers(token), timeout=120)
        r.raise_for_status()
        bundle = r.json()
        for entry in bundle.get("entry", []):
            res = entry.get("resource")
            if res and res.get("resourceType") == "AuditEvent":
                yield res
        url = None
        params = None
        for link in bundle.get("link", []):
            if link.get("relation") == "next":
                url = link.get("url")
                break


def clean_for_repost(res):
    out = dict(res)
    out.pop("id", None)
    out.pop("meta", None)
    if "extension" in out:
        kept = [e for e in out["extension"] if e.get("url") not in CHAIN_EXT_URLS]
        if kept:
            out["extension"] = kept
        else:
            out.pop("extension", None)
    return out


def load_checkpoint(path):
    if not os.path.exists(path):
        return set()
    with open(path, "r", encoding="utf-8") as f:
        return {line.strip() for line in f if line.strip()}


def main():
    ap = argparse.ArgumentParser(
        description="Migra gli AuditEvent storici dallo store clinico allo store di audit dedicato"
    )
    ap.add_argument("--source-url", default="http://127.0.0.1:8080/fhir",
                    help="base URL FHIR store sorgente (default: irccs-hapi-fhir)")
    ap.add_argument("--target-url", default="http://127.0.0.1:8081/fhir",
                    help="base URL FHIR store destinazione (default: irccs-hapi-audit)")
    ap.add_argument("--source-token", default=None, help="bearer token per la sorgente")
    ap.add_argument("--target-token", default=None, help="bearer token per la destinazione")
    ap.add_argument("--page-size", type=int, default=200, help="dimensione pagina in lettura")
    ap.add_argument("--checkpoint", default=DEFAULT_CHECKPOINT, help="file di checkpoint")
    ap.add_argument("--limit", type=int, default=0, help="migra al massimo N eventi (0 = tutti)")
    ap.add_argument("--dry-run", action="store_true", help="non scrive nulla, stampa soltanto")
    ap.add_argument("--resume", action="store_true",
                    help="riprende una migrazione interrotta usando il checkpoint")
    ap.add_argument("--allow-nonempty", action="store_true",
                    help="procede anche se la destinazione contiene gia' AuditEvent")
    args = ap.parse_args()

    print(f"Sorgente:     {args.source_url}")
    print(f"Destinazione: {args.target_url}")

    try:
        src_total = count_auditevents(args.source_url, args.source_token)
        tgt_total = count_auditevents(args.target_url, args.target_token)
    except requests.RequestException as e:
        print(f"ERRORE: impossibile contattare le istanze HAPI: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"AuditEvent in sorgente:     {src_total}")
    print(f"AuditEvent in destinazione: {tgt_total}")

    done = load_checkpoint(args.checkpoint) if args.resume else set()
    if args.resume:
        print(f"Checkpoint: {len(done)} eventi gia' migrati, verranno saltati")

    if tgt_total > 0 and not args.dry_run and not args.resume and not args.allow_nonempty:
        print(
            "\nRIFIUTO: la destinazione contiene gia' AuditEvent.\n"
            "  - riprendi una migrazione interrotta:  --resume\n"
            "  - forza l'accodamento degli storici:   --allow-nonempty",
            file=sys.stderr,
        )
        sys.exit(2)

    if src_total == 0:
        print("Niente da migrare.")
        return

    migrated = skipped = 0
    checkpoint_f = None
    if not args.dry_run:
        checkpoint_f = open(args.checkpoint, "a", encoding="utf-8")

    try:
        for res in iter_source_auditevents(args.source_url, args.source_token, args.page_size):
            src_id = res.get("id")
            if src_id in done:
                skipped += 1
                continue
            if args.limit and migrated >= args.limit:
                print(f"Raggiunto --limit {args.limit}, stop.")
                break

            payload = clean_for_repost(res)
            recorded = res.get("recorded", "?")
            if args.dry_run:
                print(f"[dry-run] {src_id}  recorded={recorded}")
                migrated += 1
                continue

            try:
                r = requests.post(
                    f"{args.target_url}/AuditEvent",
                    headers=auth_headers(args.target_token),
                    data=json.dumps(payload),
                    timeout=60,
                )
            except requests.RequestException as e:
                print(f"\nERRORE di rete su {src_id}: {e}\nRilancia con --resume.", file=sys.stderr)
                sys.exit(3)

            if r.status_code not in (200, 201):
                print(
                    f"\nERRORE: POST {src_id} -> HTTP {r.status_code}\n{r.text[:500]}\n"
                    "Migrazione interrotta. Correggi e rilancia con --resume.",
                    file=sys.stderr,
                )
                sys.exit(3)

            new_id = r.json().get("id", "?")
            checkpoint_f.write(src_id + "\n")
            checkpoint_f.flush()
            migrated += 1
            if migrated % 100 == 0:
                print(f"  ... {migrated} migrati")
            else:
                print(f"OK  {src_id}  ->  {new_id}   recorded={recorded}")
            time.sleep(0.02)
    finally:
        if checkpoint_f:
            checkpoint_f.close()

    print(f"\nFatto. Migrati: {migrated}  Saltati (gia' fatti): {skipped}")

    if not args.dry_run:
        final_tgt = count_auditevents(args.target_url, args.target_token)
        print(f"AuditEvent in destinazione ora: {final_tgt}")
        expected = tgt_total + migrated
        if final_tgt < expected:
            print(
                f"NOTA: atteso {expected}, contati {final_tgt}. Il conteggio HAPI puo'\n"
                "essere in ritardo sull'indice full-text subito dopo scritture massive:\n"
                "ricontrolla tra qualche minuto con\n"
                f"  curl '{args.target_url}/AuditEvent?_summary=count&_total=accurate'",
                file=sys.stderr,
            )
        else:
            print("Conteggio coerente.")
        print(
            "\nVerifica catena di hash (opzionale): ricalcola la sequenza sugli\n"
            "AuditEvent di destinazione ordinati per _lastUpdated e controlla che\n"
            "ogni audit-chain-prev == audit-chain-hash del precedente."
        )


if __name__ == "__main__":
    main()
