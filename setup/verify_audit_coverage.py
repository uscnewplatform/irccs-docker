#!/usr/bin/env python3
"""
Riconciliazione copertura audit: risorse cliniche critiche orfane.

Colma un gap non coperto dalla verifica hash-chain (verify_audit_hash_chain.py,
che verifica SOLO gli AuditEvent gia' scritti) ne' dal fail-closed sincrono in
FhirClient.create() (AuditRequiredException + compensatingDelete, vedi
irccs-common): quest'ultimo protegge solo dal caso in cui l'errore di scrittura
audit arrivi PRIMA che create() ritorni. Se il processo crasha (OOM-kill, pod
restart, network partition) tra la creazione della risorsa clinica riuscita e
la scrittura del suo AuditEvent, nessun codice in-process puo' reagire: la
risorsa resta creata, silenziosamente senza audit, per sempre.

Questo script confronta, per i tipi di risorsa critici (stessi di
org.quarkus.irccs.audit.critical-resource-types in irccs-common, default
Consent/ResearchSubject/CarePlan), lo store FHIR clinico con lo store di audit
isolato: ogni risorsa clinica priva di un AuditEvent corrispondente
(entity-identifier = urn:internal|{ResourceType}/{id}, stessa convenzione di
FhirClient.java e useAuditTrail.ts) oltre il periodo di grazia e' un orfano.

Grace period (--grace-seconds, default 300): una risorsa appena creata puo'
non avere ancora il suo AuditEvent semplicemente perche' la scrittura e' in
corso (percorso normale, non un crash) - senza grazia lo script genererebbe
falsi positivi ad ogni ciclo sulle risorse piu' recenti.

Output per Alerting Loki: marker AUDIT-INTEGRITY-ORPHAN-RESOURCE (stesso
prefisso family di verify_audit_hash_chain.py, stesso usato dal compensatingDelete
fallito in FhirClient.java - un'unica regola Loki puo' coprire entrambi i
percorsi, sincrono e da riconciliazione).

Exit codes:
  0 = nessun orfano rilevato
  1 = almeno un orfano rilevato
  2 = errore di connessione / parametri / sistema
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from typing import Dict, List, Optional

AUDIT_ENTITY_SYSTEM = "urn:internal"
DEFAULT_CRITICAL_TYPES = ["Consent", "ResearchSubject", "CarePlan"]
DEFAULT_STATE_FILE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), ".audit_coverage_checkpoint.json"
)


class FhirHttpError(Exception):
    pass


def auth_headers(token: Optional[str] = None) -> Dict[str, str]:
    h = {"Accept": "application/fhir+json"}
    if token:
        h["Authorization"] = token if token.lower().startswith("bearer ") else f"Bearer {token}"
    return h


def _http_get_json(url: str, headers: Dict[str, str], timeout: int = 60) -> Dict:
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


def fetch_resources_since(base_url: str, token: Optional[str], resource_type: str,
                           since: Optional[str], page_size: int = 100) -> List[Dict]:
    """Risorse di un tipo con _lastUpdated >= since (paginato, ordinate crescenti)."""
    query = [("_sort", "_lastUpdated"), ("_count", str(page_size))]
    if since:
        query.append(("_lastUpdated", f"ge{since}"))
    url = f"{base_url}/{resource_type}?{urllib.parse.urlencode(query)}"
    headers = auth_headers(token)
    out = []
    while url:
        bundle = _http_get_json(url, headers)
        for entry in bundle.get("entry", []):
            res = entry.get("resource")
            if res and res.get("resourceType") == resource_type:
                out.append(res)
        url = None
        for link in bundle.get("link", []):
            if link.get("relation") == "next":
                url = link.get("url")
                break
    return out


def has_audit_coverage(audit_base_url: str, token: Optional[str], resource_type: str, resource_id: str) -> bool:
    identifier = f"{AUDIT_ENTITY_SYSTEM}|{resource_type}/{resource_id}"
    query = [("entity-identifier", identifier), ("_summary", "count"), ("_total", "accurate")]
    url = f"{audit_base_url}/AuditEvent?{urllib.parse.urlencode(query)}"
    bundle = _http_get_json(url, auth_headers(token))
    total = bundle.get("total")
    return isinstance(total, int) and total > 0


def load_checkpoint(path: str) -> Optional[Dict]:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, ValueError):
        return None


def save_checkpoint(path: str, since_by_type: Dict[str, str]):
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"since_by_type": since_by_type, "updated_at": datetime.now(timezone.utc).isoformat()}, f)
    os.replace(tmp, path)


def write_prometheus_metrics(path: str, orphan_count: int, checked_count: int, is_ok: bool):
    tmp = f"{path}.tmp"
    lines = [
        "# HELP irccs_audit_orphan_resources_total Risorse cliniche critiche senza AuditEvent oltre il periodo di grazia",
        "# TYPE irccs_audit_orphan_resources_total gauge",
        f"irccs_audit_orphan_resources_total {orphan_count}",
        "# HELP irccs_audit_coverage_checked_total Risorse cliniche critiche controllate nell'ultimo ciclo",
        "# TYPE irccs_audit_coverage_checked_total gauge",
        f"irccs_audit_coverage_checked_total {checked_count}",
        "# HELP irccs_audit_coverage_ok Ultimo ciclo di riconciliazione senza orfani (1=ok, 0=orfani trovati)",
        "# TYPE irccs_audit_coverage_ok gauge",
        f"irccs_audit_coverage_ok {1 if is_ok else 0}",
    ]
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, path)


def main() -> int:
    p = argparse.ArgumentParser(description="Riconciliazione copertura audit: risorse cliniche orfane senza AuditEvent")
    p.add_argument("--clinical-fhir", default=os.environ.get("IRCCS_CLINICAL_FHIR_URL", "http://irccs-hapi-fhir:8080/fhir"))
    p.add_argument("--audit-fhir", default=os.environ.get("IRCCS_AUDIT_FHIR_URL", "http://irccs-hapi-audit:8080/fhir"))
    p.add_argument("--clinical-token", default=os.environ.get("IRCCS_CLINICAL_FHIR_TOKEN"))
    p.add_argument("--audit-token", default=os.environ.get("IRCCS_AUDIT_FHIR_TOKEN"))
    p.add_argument("--critical-types", default=",".join(DEFAULT_CRITICAL_TYPES),
                   help="CSV dei resourceType da riconciliare (default: stesso set di audit.critical-resource-types)")
    p.add_argument("--grace-seconds", type=int, default=300,
                   help="ignora risorse piu' recenti di N secondi (scrittura audit ancora in corso, non un crash)")
    p.add_argument("--checkpoint-file", default=DEFAULT_STATE_FILE)
    p.add_argument("--report-file")
    p.add_argument("--prometheus-textfile")
    p.add_argument("--reset-checkpoint", action="store_true",
                   help="ignora il checkpoint esistente, riparte da --lookback-days")
    p.add_argument("--lookback-days", type=int, default=7,
                   help="finestra iniziale (nessun checkpoint / --reset-checkpoint): quanti giorni indietro scansionare")
    p.add_argument("--quiet", action="store_true")
    args = p.parse_args()

    critical_types = [t.strip() for t in args.critical_types.split(",") if t.strip()]
    now = datetime.now(timezone.utc)
    grace_cutoff = now - timedelta(seconds=args.grace_seconds)

    checkpoint = None if args.reset_checkpoint else load_checkpoint(args.checkpoint_file)
    since_by_type: Dict[str, str] = (checkpoint or {}).get("since_by_type", {})
    default_since = (now - timedelta(days=args.lookback_days)).strftime("%Y-%m-%dT%H:%M:%SZ")

    orphans: List[Dict] = []
    checked_count = 0
    new_since_by_type: Dict[str, str] = dict(since_by_type)

    try:
        for rtype in critical_types:
            since = since_by_type.get(rtype, default_since)
            if not args.quiet:
                print(f"riconciliazione {rtype}: da {since}")
            resources = fetch_resources_since(args.clinical_fhir, args.clinical_token, rtype, since)

            max_seen_lastupdated = since
            for res in resources:
                rid = res.get("id")
                last_updated = res.get("meta", {}).get("lastUpdated")
                if not rid or not last_updated:
                    continue
                try:
                    lu_dt = datetime.strptime(last_updated.split(".")[0].replace("Z", ""), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
                except ValueError:
                    continue

                if lu_dt > max_seen_lastupdated_dt(max_seen_lastupdated):
                    max_seen_lastupdated = last_updated

                if lu_dt >= grace_cutoff:
                    # ancora in periodo di grazia: non avanzare il checkpoint oltre
                    # questo punto, ricontrollato al prossimo ciclo.
                    max_seen_lastupdated = since
                    continue

                checked_count += 1
                covered = has_audit_coverage(args.audit_fhir, args.audit_token, rtype, rid)
                if not covered:
                    orphans.append({"resourceType": rtype, "id": rid, "lastUpdated": last_updated})
                    print(f"AUDIT-INTEGRITY-ORPHAN-RESOURCE: {rtype}/{rid} (lastUpdated={last_updated}) "
                          f"senza AuditEvent corrispondente oltre il periodo di grazia ({args.grace_seconds}s)")

            new_since_by_type[rtype] = max_seen_lastupdated

    except FhirHttpError as e:
        print(f"AUDIT-INTEGRITY-ERROR: {e}", file=sys.stderr)
        return 2

    is_ok = len(orphans) == 0
    if is_ok:
        print(f"AUDIT-INTEGRITY-COVERAGE-OK: {checked_count} risorse critiche controllate, nessun orfano.")
    else:
        print(f"AUDIT-INTEGRITY-COVERAGE-VIOLATION: {len(orphans)} risorse orfane su {checked_count} controllate.")

    save_checkpoint(args.checkpoint_file, new_since_by_type)

    if args.report_file:
        tmp = f"{args.report_file}.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({
                "timestamp": now.isoformat(), "checked_count": checked_count,
                "orphans": orphans, "critical_types": critical_types,
            }, f, indent=2)
        os.replace(tmp, args.report_file)

    if args.prometheus_textfile:
        write_prometheus_metrics(args.prometheus_textfile, len(orphans), checked_count, is_ok)

    return 0 if is_ok else 1


def max_seen_lastupdated_dt(value: str) -> datetime:
    try:
        return datetime.strptime(value.split(".")[0].replace("Z", ""), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    except ValueError:
        return datetime.min.replace(tzinfo=timezone.utc)


if __name__ == "__main__":
    sys.exit(main())
