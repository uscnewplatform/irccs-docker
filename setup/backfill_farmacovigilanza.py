#!/usr/bin/env python3
"""
Backfill del gruppo di farmacovigilanza ("opened-sae-email") e del marker
FHIR Group.code sui gruppi autorizzativi dei centri (Organization) gia' esistenti.

Per ogni Organization:
  1. Aggiunge Group.code (system group-type) ai 5 gruppi esistenti che ne sono privi,
     deducendo il tipo dal suffisso del nome (idempotente). Update diretto su HAPI FHIR.
  2. Crea il gruppo "<Org> Farmaco vigilanza" (code opened-sae-email, realm role
     opened_sae_email) se mancante. La creazione passa dal microservizio centro-ricerca
     (POST /fhir/Group) cosi' da creare anche il gruppo Keycloak figlio + il realm role.

Idempotente: rilanciabile senza creare duplicati.

Esempio:
  python3 backfill_farmacovigilanza.py \
      --fhir-url http://localhost:8080/fhir \
      --centro-url http://localhost:8080 \
      --token "$ADMIN_BEARER" [--dry-run]

Il token deve appartenere a un utente super-admin (gruppo Keycloak /admin) oppure
avere i ruoli internal:create:group / internal:create:organization.
"""
import argparse
import json
import sys
import requests

GROUP_TYPE_SYSTEM = "http://irccs.pascale.it/fhir/CodeSystem/group-type"
FHIR_MEDIA_TYPE = "application/fhir+json"

# Suffisso nome (lowercase) -> (group-type code, realm role). Ordine: il piu' specifico prima.
NAME_SUFFIX_TO_TYPE = [
    ("sperimentatori pi", ("sperimentatore_pi", "sperimentatore_pi")),
    ("sperimentatori",    ("sperimentatore",    "sperimentatore")),
    ("radiologi",         ("radiologo",         "radiologo")),
    ("data managers",     ("data_manager",      "admin")),
    ("admins",            ("admin",             "admin")),
    ("farmaco vigilanza", ("opened-sae-email",  "opened_sae_email")),
]

FARMACO_SUFFIX = "Farmaco vigilanza"
FARMACO_CODE = "opened-sae-email"
FARMACO_ROLE = "opened_sae_email"


def auth_headers(token, media_type=FHIR_MEDIA_TYPE):
    h = {"Accept": media_type, "Content-Type": media_type}
    if token:
        h["Authorization"] = token if token.lower().startswith("bearer ") else f"Bearer {token}"
    return h


def fetch_all(fhir_url, token, query):
    """Segue la paginazione FHIR e ritorna tutte le risorse."""
    url = f"{fhir_url}/{query}"
    resources = []
    while url:
        r = requests.get(url, headers=auth_headers(token), timeout=60)
        r.raise_for_status()
        bundle = r.json()
        for entry in bundle.get("entry", []):
            res = entry.get("resource")
            if res:
                resources.append(res)
        url = None
        for link in bundle.get("link", []):
            if link.get("relation") == "next":
                url = link.get("url")
                break
    return resources


def has_group_type_coding(group):
    for c in (group.get("code", {}) or {}).get("coding", []):
        if c.get("system") == GROUP_TYPE_SYSTEM:
            return c.get("code")
    return None


def infer_type_from_name(name):
    low = (name or "").lower()
    for suffix, (code, role) in NAME_SUFFIX_TO_TYPE:
        if low.endswith(suffix):
            return code, role
    return None, None


def org_assigner_id(group):
    """Ritorna l'id FHIR dell'Organization assegnataria del gruppo (identifier.assigner)."""
    for ident in group.get("identifier", []):
        ref = (ident.get("assigner") or {}).get("reference")
        if ref:
            return ref.split("/")[-1]
    return None


def main():
    ap = argparse.ArgumentParser(description="Backfill gruppo farmacovigilanza + Group.code")
    ap.add_argument("--fhir-url", required=True, help="Base URL HAPI FHIR, es. http://localhost:8080/fhir")
    ap.add_argument("--centro-url", required=True, help="Base URL per POST creazione Group (centro-ricerca o reverse-proxy)")
    ap.add_argument("--group-path", default="/fhir/Group", help="Path di creazione Group sul centro-url (es. /fhir/Group in locale, /Group dietro reverse-proxy preprod)")
    ap.add_argument("--token", default="", help="Bearer token admin (super-admin Keycloak)")
    ap.add_argument("--dry-run", action="store_true", help="Mostra le azioni senza eseguirle")
    args = ap.parse_args()

    fhir = args.fhir_url.rstrip("/")
    centro = args.centro_url.rstrip("/")

    print(">> Carico Organizations e Group practitioner...")
    orgs = fetch_all(fhir, args.token, "Organization?_count=1000")
    groups = fetch_all(fhir, args.token, "Group?type=practitioner&_count=1000")
    print(f"   Organizations: {len(orgs)} | Group practitioner: {len(groups)}")

    # Indicizza i gruppi per Organization assegnataria.
    groups_by_org = {}
    for g in groups:
        oid = org_assigner_id(g)
        if oid:
            groups_by_org.setdefault(oid, []).append(g)

    stats = {"code_added": 0, "code_skipped": 0, "farmaco_created": 0, "farmaco_present": 0, "errors": 0}

    for org in orgs:
        org_id = org.get("id")
        org_name = org.get("name") or org_id
        org_groups = groups_by_org.get(org_id, [])

        # 1. Aggiungi Group.code mancante ai gruppi esistenti.
        for g in org_groups:
            existing = has_group_type_coding(g)
            if existing:
                stats["code_skipped"] += 1
                continue
            code, _role = infer_type_from_name(g.get("name"))
            if not code:
                print(f"   [SKIP] '{g.get('name')}' (org {org_name}): tipo non deducibile dal nome")
                stats["code_skipped"] += 1
                continue
            g["code"] = {"coding": [{"system": GROUP_TYPE_SYSTEM, "code": code}]}
            gid = g.get("id")
            print(f"   [CODE] {g.get('name')} -> {code}")
            if not args.dry_run:
                try:
                    r = requests.put(f"{fhir}/Group/{gid}", headers=auth_headers(args.token),
                                     data=json.dumps(g), timeout=60)
                    r.raise_for_status()
                    stats["code_added"] += 1
                except requests.RequestException as e:
                    print(f"      ERRORE update Group/{gid}: {e}")
                    stats["errors"] += 1
            else:
                stats["code_added"] += 1

        # 2. Crea il gruppo Farmaco vigilanza se assente.
        has_farmaco = any(
            has_group_type_coding(g) == FARMACO_CODE
            or (g.get("name") or "").lower().endswith(FARMACO_SUFFIX.lower())
            for g in org_groups
        )
        if has_farmaco:
            stats["farmaco_present"] += 1
            continue

        payload = {
            "resourceType": "Group",
            "type": "practitioner",
            "membership": "definitional",
            "code": {"coding": [{"system": GROUP_TYPE_SYSTEM, "code": FARMACO_CODE}]},
            "name": f"{org_name} {FARMACO_SUFFIX}",
        }
        print(f"   [NEW ] {org_name} {FARMACO_SUFFIX} (org {org_id})")
        if not args.dry_run:
            try:
                headers = auth_headers(args.token)
                headers["organizationId"] = org_id
                headers["role"] = FARMACO_ROLE
                r = requests.post(f"{centro}{args.group_path}", headers=headers, data=json.dumps(payload),
                                  timeout=120)
                r.raise_for_status()
                stats["farmaco_created"] += 1
            except requests.RequestException as e:
                print(f"      ERRORE create gruppo per org {org_id}: {e}")
                stats["errors"] += 1
        else:
            stats["farmaco_created"] += 1

    print("\n== Riepilogo ==")
    print(f"  code aggiunti:        {stats['code_added']}")
    print(f"  code gia' presenti:   {stats['code_skipped']}")
    print(f"  farmaco creati:       {stats['farmaco_created']}")
    print(f"  farmaco gia' presenti:{stats['farmaco_present']}")
    print(f"  errori:               {stats['errors']}")
    if args.dry_run:
        print("  (DRY-RUN: nessuna modifica applicata)")
    sys.exit(1 if stats["errors"] else 0)


if __name__ == "__main__":
    main()
