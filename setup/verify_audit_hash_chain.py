#!/usr/bin/env python3
"""
Verifica crittografica di integrità dell'Audit Trail (Hash-Chain).

Ricalcola in modo deterministico il canonicalPayload e l'hash SHA-256 per ogni
AuditEvent FHIR presente sullo store di audit (irccs-hapi-audit), replicando
esattamente la logica di AuditEventHashChainInterceptor.java:
  selfHash = sha256(prevHash + "|" + canonicalPayload(event))

Rileva:
  1. Manomissioni del contenuto: alterazione di chi ha fatto l'azione (agent.who, agent.network),
     di cosa è stato fatto (entity.detail, action, subtype), dell'orario (recorded) o
     delle risorse toccate (entity.what, paziente).
  2. Cancellazioni o buchi di record: rottura della continuità tra audit-chain-prev e
     l'audit-chain-hash del record precedente.
  3. Inserimenti retroattivi o fork nella catena.

Supporta:
  - Modalità --full: scansione completa dell'intero storico.
  - Modalità --incremental: verifica solo i nuovi eventi registrati dall'ultimo checkpoint.
  - Modalità --since / --to: range temporale (ISO-8601).
  - Output per Alerting Loki: prefissi AUDIT-INTEGRITY-OK e AUDIT-INTEGRITY-VIOLATION.
  - Output metriche Prometheus Textfile (--prometheus-textfile).

Exit codes:
  0 = Integrità verificata con successo (nessuna anomalia)
  1 = Violazione di integrità rilevata (manomissione, rottura catena, hash mismatch)
  2 = Errore di connessione / parametri / sistema
"""
import argparse
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from typing import Dict, List, Optional, Set, Tuple

FHIR_MEDIA_TYPE = "application/fhir+json"
EXT_PREV = "http://irccs.pascale.it/fhir/StructureDefinition/audit-chain-prev"
EXT_HASH = "http://irccs.pascale.it/fhir/StructureDefinition/audit-chain-hash"
DEFAULT_STATE_FILE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), ".audit_integrity_checkpoint.json"
)


def auth_headers(token: Optional[str] = None) -> Dict[str, str]:
    h = {"Accept": FHIR_MEDIA_TYPE, "Content-Type": FHIR_MEDIA_TYPE}
    if token:
        h["Authorization"] = token if token.lower().startswith("bearer ") else f"Bearer {token}"
    return h


def sha256_hex(data: str) -> str:
    """Calcola SHA-256 su stringa UTF-8 e ritorna stringa esadecimale minuscola."""
    return hashlib.sha256(data.encode("utf-8")).hexdigest()


def canonical_payload(event: Dict, include_detail: bool = True) -> str:
    """
    Replica la logica di canonicalPayload(AuditEvent e) in AuditEventHashChainInterceptor.java:
      recorded=...;action=...;outcome=...;type=...;[subtype=...;][agent=...;][entity=...;]site=...
    
    include_detail=True: formato attuale (include entity.detail per protezione tamper completa)
    include_detail=False: formato legacy per retrocompatibilità con eventi scritti pre-commit ed4f933
    """
    sb = []

    # 1. recorded
    recorded = event.get("recorded", "")
    sb.append(f"recorded={recorded};")

    # 2. action
    action = event.get("action", "")
    sb.append(f"action={action};")

    # 3. outcome
    outcome = event.get("outcome", "")
    sb.append(f"outcome={outcome};")

    # 4. type (Coding: system|code)
    ev_type = event.get("type", {})
    type_system = ev_type.get("system", "")
    type_code = ev_type.get("code", "")
    if type_system or type_code:
        sb.append(f"type={type_system}|{type_code};")
    else:
        sb.append("type=;")

    # 5. subtype (primo elemento: getSubtypeFirstRep().getCode())
    subtypes = event.get("subtype", [])
    if subtypes and isinstance(subtypes, list) and len(subtypes) > 0:
        first_sub_code = subtypes[0].get("code", "")
        if first_sub_code:
            sb.append(f"subtype={first_sub_code};")

    # 6. agent
    agents = event.get("agent", [])
    if agents and isinstance(agents, list):
        for a in agents:
            agent_str = "agent="
            who = a.get("who", {})
            ident = who.get("identifier", {})
            if ident.get("system") or ident.get("value"):
                ident_sys = ident.get("system", "")
                ident_val = ident.get("value", "")
                agent_str += f"{ident_sys}|{ident_val}"
            
            net = a.get("network", {})
            if net.get("address"):
                agent_str += f"@{net.get('address')}"
            
            agent_str += ";"
            sb.append(agent_str)

    # 7. entity
    entities = event.get("entity", [])
    if entities and isinstance(entities, list):
        for en in entities:
            entity_str = "entity="
            what = en.get("what", {})
            if what.get("reference"):
                entity_str += what.get("reference", "")
            elif what.get("identifier"):
                ident = what.get("identifier", {})
                ident_sys = ident.get("system", "")
                ident_val = ident.get("value", "")
                entity_str += f"{ident_sys}|{ident_val}"

            # entity.detail (presente nel formato corrente)
            if include_detail:
                details = en.get("detail", [])
                for d in details:
                    entity_str += "detail="
                    if "valueString" in d:
                        entity_str += str(d["valueString"])
                    elif "valueStringType" in d:
                        entity_str += str(d["valueStringType"])
                    elif "value" in d:
                        entity_str += str(d["value"])
                    entity_str += ","

            entity_str += ";"
            sb.append(entity_str)

    # 8. site
    site = event.get("source", {}).get("site", "")
    sb.append(f"site={site}")

    return "".join(sb)


def extract_chain_extensions(event: Dict) -> Tuple[Optional[str], Optional[str]]:
    """Estrae (audit-chain-prev, audit-chain-hash) dalle extension dell'AuditEvent."""
    prev_hash = None
    self_hash = None
    for ext in event.get("extension", []):
        url = ext.get("url")
        if url == EXT_PREV:
            prev_hash = ext.get("valueString")
        elif url == EXT_HASH:
            self_hash = ext.get("valueString")
    return prev_hash, self_hash


def verify_single_event(event: Dict, expected_prev: Optional[str] = None) -> Tuple[bool, str, str, str]:
    """
    Verifica crittograficamente un singolo AuditEvent.
    Ritorna: (is_valid, expected_hash, actual_hash, error_reason)
    """
    eid = event.get("id", "unknown")
    actual_prev, actual_hash = extract_chain_extensions(event)

    if actual_hash is None:
        return False, "", "", f"Evento {eid} privo dell'extension audit-chain-hash"

    # Se c'è un expected_prev (diverso da None), verifica la continuità dell'anello
    if expected_prev is not None:
        if actual_prev != expected_prev and not (expected_prev == "genesis" and actual_prev in ("genesis", "")):
            return False, "", actual_hash, (
                f"Rottura catena su evento {eid}: audit-chain-prev '{actual_prev}' "
                f"!= hash precedente atteso '{expected_prev}'"
            )

    # 1. Prova formato corrente (con entity.detail)
    canon = canonical_payload(event, include_detail=True)
    hash_input = f"{actual_prev or ''}|{canon}"
    expected_hash = sha256_hex(hash_input)

    if actual_hash == expected_hash:
        return True, expected_hash, actual_hash, ""

    # 2. Prova formato legacy (senza entity.detail) per eventi storici pre-aggiornamento
    canon_legacy = canonical_payload(event, include_detail=False)
    hash_input_legacy = f"{actual_prev or ''}|{canon_legacy}"
    expected_hash_legacy = sha256_hex(hash_input_legacy)

    if actual_hash == expected_hash_legacy:
        return True, expected_hash_legacy, actual_hash, ""

    return False, expected_hash, actual_hash, (
        f"Alterazione contenuto/Tamper su evento {eid}: hash memorizzato '{actual_hash}' "
        f"!= hash calcolato dal payload '{expected_hash}'"
    )


class FhirHttpError(Exception):
    """Errore di rete / HTTP nel contattare lo store di audit."""


def _http_get_json(url: str, headers: Dict[str, str], timeout: int = 120) -> Dict:
    req = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        raise FhirHttpError(f"HTTP {e.code} su {url}: {e.reason}") from e
    except urllib.error.URLError as e:
        raise FhirHttpError(f"connessione fallita a {url}: {e.reason}") from e
    except (TimeoutError, OSError) as e:
        raise FhirHttpError(f"errore di rete su {url}: {e}") from e
    try:
        return json.loads(body)
    except ValueError as e:
        raise FhirHttpError(f"risposta non-JSON da {url}: {e}") from e


def fetch_all_auditevents(base_url: str, token: Optional[str], page_size: int = 200,
                          since: Optional[str] = None, to: Optional[str] = None) -> List[Dict]:
    """Recupera tutti gli AuditEvent (o quelli nel range specificato)."""
    query = [("_sort", "date,_lastUpdated"), ("_count", str(page_size))]
    if since:
        query.append(("date", f"ge{since}"))
    if to:
        query.append(("date", f"le{to}"))
    url = f"{base_url}/AuditEvent?{urllib.parse.urlencode(query)}"

    headers = auth_headers(token)
    events = []
    while url:
        bundle = _http_get_json(url, headers)
        for entry in bundle.get("entry", []):
            res = entry.get("resource")
            if res and res.get("resourceType") == "AuditEvent":
                events.append(res)
        url = None
        for link in bundle.get("link", []):
            if link.get("relation") == "next":
                url = link.get("url")
                break
    return events


def count_auditevents(base_url: str, token: Optional[str]) -> Optional[int]:
    """Conteggio esatto degli AuditEvent presenti (per rilevare una regressione da restore)."""
    try:
        b = _http_get_json(f"{base_url}/AuditEvent?_summary=count&_total=accurate", auth_headers(token))
        return int(b.get("total")) if b.get("total") is not None else None
    except (FhirHttpError, ValueError, TypeError):
        return None


def save_checkpoint(path: str, last_event_id: str, last_hash: str, total_verified: int,
                    last_recorded: Optional[str] = None, unhashed_baseline: Optional[int] = None,
                    total_present: Optional[int] = None):
    data = {
        "last_event_id": last_event_id,
        "last_hash": last_hash,
        "last_recorded": last_recorded or "",
        "total_verified": total_verified,
        "unhashed_baseline": unhashed_baseline if unhashed_baseline is not None else 0,
        "total_present": total_present if total_present is not None else 0,
        "last_verified_at": datetime.now(timezone.utc).isoformat()
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)


def load_checkpoint(path: str) -> Optional[Dict]:
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        print(f"WARN: Impossibile leggere il checkpoint {path}: {e}", file=sys.stderr)
        return None


def write_prometheus_metrics(path: str, is_ok: bool, verified_count: int,
                             violation_count: int, break_count: int, fork_count: int = 0):
    """Scrive metriche in formato Prometheus Textfile per node_exporter."""
    lines = [
        "# HELP irccs_audit_integrity_status 1 se l'audit trail e' integro, 0 se rilevata violazione/corruzione.",
        "# TYPE irccs_audit_integrity_status gauge",
        f"irccs_audit_integrity_status {1 if is_ok else 0}",
        "# HELP irccs_audit_events_verified_total Numero totale di AuditEvent verificati crittograficamente.",
        "# TYPE irccs_audit_events_verified_total counter",
        f"irccs_audit_events_verified_total {verified_count}",
        "# HELP irccs_audit_integrity_violations_total Numero di violazioni/manomissioni di contenuto rilevate.",
        "# TYPE irccs_audit_integrity_violations_total counter",
        f"irccs_audit_integrity_violations_total {violation_count}",
        "# HELP irccs_audit_chain_breaks_total Numero di rotture di sequenza/buchi nella catena rilevati.",
        "# TYPE irccs_audit_chain_breaks_total counter",
        f"irccs_audit_chain_breaks_total {break_count}",
        "# HELP irccs_audit_chain_forks_total Punti in cui due AuditEvent dichiarano lo stesso predecessore.",
        "# TYPE irccs_audit_chain_forks_total counter",
        f"irccs_audit_chain_forks_total {fork_count}",
        "# HELP irccs_audit_last_verification_timestamp_seconds Timestamp Unix dell'ultima verifica.",
        "# TYPE irccs_audit_last_verification_timestamp_seconds gauge",
        f"irccs_audit_last_verification_timestamp_seconds {int(time.time())}",
    ]
    tmp_path = f"{path}.tmp.{os.getpid()}"
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp_path, path)


def main():
    ap = argparse.ArgumentParser(
        description="Verifica crittografica e tamper-evidence dell'Audit Trail FHIR (Hash-Chain)"
    )
    ap.add_argument("--audit-fhir", default=os.getenv("IRCCS_AUDIT_FHIR_URL", "http://127.0.0.1:8081/fhir"),
                    help="Base URL FHIR dello store di audit (default: http://127.0.0.1:8081/fhir)")
    ap.add_argument("--token", default=os.getenv("IRCCS_AUDIT_TOKEN", None),
                    help="Bearer token per HAPI FHIR se protetto")
    ap.add_argument("--full", action="store_true",
                    help="Esegue una scansione completa di tutti gli AuditEvent (ignora checkpoint)")
    ap.add_argument("--incremental", action="store_true",
                    help="Esegue la verifica a partire dall'ultimo checkpoint memorizzato")
    ap.add_argument("--checkpoint-file", default=DEFAULT_STATE_FILE,
                    help="Percorso del file di checkpoint (default: .audit_integrity_checkpoint.json)")
    ap.add_argument("--since", default=None, help="Verifica solo eventi con recorded >= since (ISO-8601)")
    ap.add_argument("--to", default=None, help="Verifica solo eventi con recorded <= to (ISO-8601)")
    ap.add_argument("--page-size", type=int, default=200, help="Dimensione pagina per batch FHIR")
    ap.add_argument("--report-file", default=None, help="File in cui salvare il report dettagliato in formato JSON")
    ap.add_argument("--prometheus-textfile", default=None,
                    help="Percorso file .prom per Prometheus node_exporter textfile collector")
    ap.add_argument("--quiet", action="store_true", help="Stampa solo gli errori ed il risultato finale")
    ap.add_argument("--strict", action="store_true",
                    help="Tratta i fork della catena (due eventi con lo stesso prev) come violazione (exit 1)")
    args = ap.parse_args()

    checkpoint = None
    start_hash = None
    if args.incremental and not args.full:
        checkpoint = load_checkpoint(args.checkpoint_file)
        if checkpoint:
            start_hash = checkpoint.get("last_hash")
            if not args.quiet:
                print(f"[CHECKPOINT] Ripresa verifica dall'evento '{checkpoint.get('last_event_id')}' "
                      f"con hash atteso '{start_hash}'")

    if not args.quiet:
        print(f"== Verifica Integrita' Audit Trail (Hash-Chain) ==")
        print(f"Store Audit: {args.audit_fhir}")
        print(f"Modalita':   {'FULL' if args.full else ('INCREMENTALE' if args.incremental else 'STANDARD')}\n")

    start_time = time.time()
    try:
        raw_events = fetch_all_auditevents(
            args.audit_fhir, args.token, page_size=args.page_size,
            since=args.since, to=args.to
        )
    except FhirHttpError as e:
        print(f"AUDIT-INTEGRITY-ERROR: Impossibile contattare il server FHIR {args.audit_fhir}: {e}", file=sys.stderr)
        if args.prometheus_textfile:
            write_prometheus_metrics(args.prometheus_textfile, False, 0, 0, 0)
        sys.exit(2)

    if not raw_events:
        if not args.quiet:
            print("Nessun AuditEvent trovato nel periodo selezionato.")
        print("AUDIT-INTEGRITY-OK: 0 eventi presenti.")
        sys.exit(0)

    # Indicizza per prev e per hash per ricostruzione topologica
    by_prev: Dict[str, List[Dict]] = {}
    by_hash: Dict[str, Dict] = {}
    all_events_map: Dict[str, Dict] = {}
    unhashed_count = 0

    for ev in raw_events:
        eid = ev.get("id", "?")
        all_events_map[eid] = ev
        p, h = extract_chain_extensions(ev)
        if not h:
            unhashed_count += 1
            continue
        p_key = p or ""
        by_prev.setdefault(p_key, []).append(ev)
        by_hash[h] = ev

    # Ricostruzione topologica della sequenza
    entry_hashes = [start_hash] if start_hash else ["", "genesis"]
    if not start_hash:
        root_nodes = [p for p in by_prev.keys() if p not in by_hash]
        if root_nodes:
            entry_hashes = root_nodes

    visited_eids: Set[str] = set()
    ordered_events: List[Dict] = []
    forks: List[Tuple[str, List[str]]] = []

    queue = list(entry_hashes)
    while queue:
        cur_h = queue.pop(0)
        children = by_prev.get(cur_h, [])
        if len(children) > 1:
            forks.append((cur_h, [c.get("id", "?") for c in children]))
        for ch in children:
            cid = ch.get("id", "?")
            if cid not in visited_eids:
                visited_eids.add(cid)
                ordered_events.append(ch)
                _, ch_hash = extract_chain_extensions(ch)
                if ch_hash:
                    queue.append(ch_hash)

    # In modalità incrementale, gli eventi antecedenti al checkpoint sono già verificati
    if start_hash:
        orphans = []
    else:
        orphans = [ev for eid, ev in all_events_map.items() if eid not in visited_eids]

    verified_count = 0
    violations: List[Dict] = []
    chain_breaks: List[Dict] = []
    last_valid_hash = start_hash
    last_event_id = checkpoint.get("last_event_id") if checkpoint else None
    last_recorded = checkpoint.get("last_recorded", "") if checkpoint else ""

    # 1. Verifica crittografica di tutti gli eventi ordinati topologicamente
    for ev in ordered_events:
        eid = ev.get("id", "?")
        rec = ev.get("recorded", "?")
        p, h = extract_chain_extensions(ev)

        is_valid, exp_h, act_h, err = verify_single_event(ev, expected_prev=None)
        if not is_valid:
            violations.append({
                "id": eid,
                "recorded": rec,
                "actual_prev": p,
                "actual_hash": act_h,
                "expected_hash": exp_h,
                "error": err
            })
            print(f"\n[TAMPER-VIOLATION] ❌ {err}", file=sys.stderr)
        else:
            verified_count += 1
            last_event_id = eid
            last_valid_hash = h
            if rec and rec != "?":
                last_recorded = rec
            if not args.quiet and verified_count % 100 == 0:
                print(f"  ... {verified_count} AuditEvent verificati OK")

    # 2. Segnala eventuali orfani disconnessi (solo in scansione full/standard)
    for o in orphans:
        p, h = extract_chain_extensions(o)
        if h:
            chain_breaks.append({
                "id": o.get("id", "?"),
                "recorded": o.get("recorded", "?"),
                "actual_prev": p,
                "actual_hash": h,
                "error": f"Evento {o.get('id')} disconnesso dalla catena principale (prev '{p}' non trovato)"
            })
            print(f"\n[CHAIN-BREAK] ❌ Evento {o.get('id')} orfano/disconnesso da prev '{p}'", file=sys.stderr)

    elapsed = time.time() - start_time
    # I fork (due eventi con lo stesso prev) su una scansione FULL sono attesi: la catena
    # si biforca a ogni riavvio dello stack (lastIssuedHash riparte dal DB). Solo i fork
    # visti in una scansione INCREMENTALE - cioe' nel delta di eventi nuovi della stessa
    # istanza in esecuzione - sono un'anomalia reale (scrittura concorrente non
    # serializzata, o inserimento illecito). --strict li tratta come violazione ovunque.
    fork_is_anomaly = args.strict or (bool(forks) and not args.full)
    total_issues = len(violations) + len(chain_breaks) + (len(forks) if fork_is_anomaly else 0)
    is_all_ok = (total_issues == 0)

    if forks:
        if fork_is_anomaly and not args.strict:
            marker = "AUDIT-INTEGRITY-FORK"
        elif fork_is_anomaly:
            marker = "AUDIT-INTEGRITY-VIOLATION"
        else:
            marker = "[INFO] fork storici (riavvii stack)"
        out = sys.stderr if fork_is_anomaly else sys.stdout
        print(f"\n{marker}: {len(forks)} biforcazioni nella hash-chain "
              f"(due AuditEvent con lo stesso predecessore).", file=out)
        for fh, cids in forks[:10]:
            print(f"       prev {fh[:16]}... -> eventi {cids}", file=out)

    # Checkpoint "stantio": in modalità incrementale non si è agganciato nessun evento
    # nuovo (by_prev[start_hash] vuoto) MA esistono eventi con hash e 'recorded' successivo
    # al checkpoint. Significa che l'hash del checkpoint non è più la foglia della catena
    # (tipicamente: re-seed della catena dopo un riavvio HAPI agganciato a un predecessore
    # diverso). NON è "tutto ok": va segnalato e il checkpoint NON va avanzato, così il
    # full scan periodico ricalcola dalla radice.
    stale_checkpoint = False
    if is_all_ok and verified_count == 0 and start_hash:
        newer = [
            ev for eid, ev in all_events_map.items()
            if eid not in visited_eids
            and extract_chain_extensions(ev)[1]
            and (not last_recorded or ev.get("recorded", "") > last_recorded)
        ]
        if newer:
            stale_checkpoint = True
            is_all_ok = False

    # --- Gap threat-model: eventi nuovi senza hash-chain --------------------
    # Un attore con accesso alla config del container puo' disattivare
    # l'AuditEventHashChainInterceptor: i nuovi AuditEvent vengono scritti senza
    # le extension di catena. Il verificatore li conta come "Saltati". Se il
    # conteggio dei non-hashed cresce oltre la baseline nota, e' un'anomalia.
    unhashed_baseline = (checkpoint.get("unhashed_baseline", 0) if checkpoint else 0)
    unhashed_regression = False
    if unhashed_count > max(unhashed_baseline, 0) and (args.full or args.incremental):
        # in incrementale unhashed_count e' gia' il solo delta nuovo
        new_unhashed = unhashed_count if args.incremental else (unhashed_count - unhashed_baseline)
        if new_unhashed > 0:
            unhashed_regression = True
            is_all_ok = False

    # --- Gap threat-model: regressione del conteggio (restore/rollback) ----
    total_present = count_auditevents(args.audit_fhir, args.token)
    prev_present = (checkpoint.get("total_present", 0) if checkpoint else 0)
    count_regression = False
    if total_present is not None and prev_present and total_present < prev_present:
        count_regression = True
        is_all_ok = False

    # Log strutturato per Loki
    if unhashed_regression:
        print(f"\nAUDIT-INTEGRITY-UNHASHED: {new_unhashed} AuditEvent nuovi senza hash-chain "
              f"(baseline={unhashed_baseline}, totale non-hashed={unhashed_count}). "
              f"Possibile disattivazione dell'interceptor di catena.", file=sys.stderr)
    if count_regression:
        print(f"\nAUDIT-INTEGRITY-COUNT-REGRESSION: gli AuditEvent presenti sono {total_present}, "
              f"erano {prev_present} al checkpoint precedente. Possibile restore/rollback dello store.",
              file=sys.stderr)
    if stale_checkpoint:
        print(f"\nAUDIT-INTEGRITY-STALE-CHECKPOINT: il checkpoint (ID={last_event_id}) non è più "
              f"la foglia della hash-chain; {len(newer)} AuditEvent nuovi non verificabili "
              f"dall'incrementale. Attesa la scansione full per il ricalcolo.", file=sys.stderr)
    elif is_all_ok:
        if verified_count == 0 and start_hash:
            print(f"\nAUDIT-INTEGRITY-OK: Nessun nuovo evento dal checkpoint (catena ferma a ID={last_event_id}). "
                  f"Verificati=0 in {elapsed:.2f}s")
        else:
            print(f"\nAUDIT-INTEGRITY-OK: Catena di hash integra. Verificati={verified_count} Saltati={unhashed_count} "
                  f"in {elapsed:.2f}s (ultimo evento={last_event_id})")
    elif total_issues > 0:
        print(f"\nAUDIT-INTEGRITY-VIOLATION: Rilevate {total_issues} anomalie nell'audit trail! "
              f"Tamper={len(violations)}, ChainBreaks={len(chain_breaks)}, "
              f"Fork={len(forks) if fork_is_anomaly else 0}, Verificati={verified_count} "
              f"in {elapsed:.2f}s", file=sys.stderr)
    # else: is_all_ok=False per sola regressione conteggio/unhashed -> il marker
    # dedicato e' gia' stato stampato sopra; l'exit code resta 1.

    # Aggiorna checkpoint se ci sono stati nuovi eventi verificati con successo
    if is_all_ok and last_event_id and last_valid_hash and (args.incremental or args.full):
        prev_total = (checkpoint.get("total_verified", 0) if checkpoint else 0)
        save_checkpoint(args.checkpoint_file, last_event_id, last_valid_hash,
                        prev_total + verified_count, last_recorded,
                        unhashed_baseline=unhashed_count,
                        total_present=(total_present if total_present is not None else prev_present))
        if not args.quiet:
            print(f"[CHECKPOINT] Salvato stato aggiornato su {args.checkpoint_file}")

    # Salva report JSON
    if args.report_file:
        report_data = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "status": "PASS" if is_all_ok else "FAIL",
            "verified_count": verified_count,
            "unhashed_count": unhashed_count,
            "violations_count": len(violations),
            "chain_breaks_count": len(chain_breaks),
            "forks_count": len(forks),
            "strict": args.strict,
            "violations": violations,
            "chain_breaks": chain_breaks,
            "forks": [{"prev": fh, "events": cids} for fh, cids in forks],
            "last_event_id": last_event_id,
            "elapsed_seconds": round(elapsed, 3)
        }
        with open(args.report_file, "w", encoding="utf-8") as f:
            json.dump(report_data, f, indent=2)
        if not args.quiet:
            print(f"[REPORT] Report salvato in {args.report_file}")

    if args.prometheus_textfile:
        write_prometheus_metrics(args.prometheus_textfile, is_all_ok, verified_count,
                                 len(violations), len(chain_breaks), len(forks))

    sys.exit(0 if is_all_ok else 1)


if __name__ == "__main__":
    main()
