#!/usr/bin/env python3
"""
Importa le panel ValueSets LOINC in HAPI FHIR leggendo PanelsAndForms.csv dal ZIP LOINC.

HAPI FHIR 8.6.x non processa PanelsAndForms.csv durante l'upload — questo script
crea le ValueSet resources manualmente per ogni panel, rendendo disponibile
$expand?url=http://loinc.org/vs/{panelCode}.

Uso:
    python3 import-loinc-panels.py [opzioni]

Esempi:
    python3 import-loinc-panels.py
    python3 import-loinc-panels.py --hapi-url http://10.99.88.204:8080/fhir
    python3 import-loinc-panels.py --loinc-zip /path/to/loinc.zip --prefix Loinc_2.83
"""

import csv
import io
import json
import sys
import time
import zipfile
import argparse
from collections import defaultdict
from urllib.request import urlopen, Request
from urllib.error import HTTPError, URLError

GREEN  = '\033[0;32m'
YELLOW = '\033[1;33m'
RED    = '\033[0;31m'
BLUE   = '\033[0;34m'
NC     = '\033[0m'

def ok(msg):   print(f'{GREEN}[OK]{NC}   {msg}')
def warn(msg): print(f'{YELLOW}[WARN]{NC} {msg}')
def err(msg):  print(f'{RED}[ERR]{NC}  {msg}')
def info(msg): print(f'{BLUE}[INFO]{NC} {msg}')


def parse_args():
    parser = argparse.ArgumentParser(
        description='Importa panel ValueSets LOINC in HAPI FHIR'
    )
    parser.add_argument(
        '--hapi-url', default='http://localhost:8080/fhir',
        help='Base URL HAPI FHIR (default: http://localhost:8080/fhir)'
    )
    parser.add_argument(
        '--loinc-zip', default='terminology/loinc.zip',
        help='Path al file loinc.zip (default: terminology/loinc.zip)'
    )
    parser.add_argument(
        '--prefix', default='Loinc_2.82',
        help='Prefisso versione nel ZIP (default: Loinc_2.82)'
    )
    parser.add_argument(
        '--version', default='2.82',
        help='Versione LOINC da inserire nelle ValueSet (default: 2.82)'
    )
    parser.add_argument(
        '--delay', type=float, default=0.05,
        help='Pausa in secondi tra ogni POST (default: 0.05)'
    )
    parser.add_argument(
        '--dry-run', action='store_true',
        help='Mostra quanti panel verrebbero importati senza fare POST'
    )
    return parser.parse_args()


def find_panels_csv(zip_path, prefix):
    canonical = f'{prefix}/AccessoryFiles/PanelsAndForms/PanelsAndForms.csv'
    with zipfile.ZipFile(zip_path, 'r') as z:
        names = z.namelist()
        if canonical in names:
            return canonical
        for name in names:
            if name.endswith('PanelsAndForms.csv') and 'PanelsAndForms' in name:
                return name
    return None


def read_panels(zip_path, csv_path):
    """Ritorna dict: panel_code -> lista ordinata di member_codes (in ordine Seq)."""
    rows = []
    with zipfile.ZipFile(zip_path, 'r') as z:
        with z.open(csv_path) as f:
            reader = csv.DictReader(io.TextIOWrapper(f, encoding='utf-8-sig'))
            for row in reader:
                parent = row.get('ParentLoinc', '').strip()
                child  = row.get('Loinc', '').strip()
                seq    = row.get('Seq', '0').strip()
                if parent and child and parent != child:
                    try:
                        seq_int = int(seq)
                    except ValueError:
                        seq_int = 0
                    rows.append((parent, seq_int, child))

    panels = defaultdict(list)
    for parent, _, child in sorted(rows, key=lambda r: (r[0], r[1])):
        panels[parent].append(child)
    return panels


def build_valueset(panel_code, member_codes, version):
    return {
        'resourceType': 'ValueSet',
        'url': f'http://loinc.org/vs/{panel_code}',
        'version': version,
        'name': f'LOINCPanel{panel_code.replace("-", "")}',
        'title': f'LOINC Panel {panel_code}',
        'status': 'active',
        'publisher': 'Regenstrief Institute, Inc.',
        'compose': {
            'include': [{
                'system': 'http://loinc.org',
                'concept': [{'code': c} for c in member_codes]
            }]
        }
    }


def post_valueset(hapi_url, vs):
    body = json.dumps(vs).encode('utf-8')
    req = Request(
        f'{hapi_url}/ValueSet',
        data=body,
        headers={
            'Content-Type': 'application/fhir+json',
            'Accept': 'application/fhir+json',
        },
        method='POST'
    )
    try:
        with urlopen(req, timeout=30) as resp:
            return resp.status, None
    except HTTPError as e:
        return e.code, e.read().decode('utf-8', errors='replace')[:300]
    except URLError as e:
        return 0, str(e)


def check_hapi(hapi_url):
    req = Request(
        f'{hapi_url}/metadata',
        headers={'Accept': 'application/fhir+json'},
    )
    try:
        with urlopen(req, timeout=10) as resp:
            return resp.status == 200
    except Exception:
        return False


def main():
    args = parse_args()

    print('=' * 60)
    print(' LOINC Panel ValueSet Importer')
    print(f' HAPI FHIR : {args.hapi_url}')
    print(f' LOINC ZIP : {args.loinc_zip}')
    print(f' Prefisso  : {args.prefix}')
    if args.dry_run:
        print(f' Modalità  : DRY RUN (nessun POST)')
    print('=' * 60)
    print()

    if not args.dry_run:
        info('Verifica connessione HAPI FHIR...')
        if not check_hapi(args.hapi_url):
            err(f'HAPI FHIR non raggiungibile a {args.hapi_url}')
            sys.exit(1)
        ok('HAPI FHIR raggiungibile')
        print()

    info('Ricerca PanelsAndForms.csv nel ZIP...')
    csv_path = find_panels_csv(args.loinc_zip, args.prefix)
    if not csv_path:
        err(f'PanelsAndForms.csv non trovato nel ZIP con prefisso "{args.prefix}"')
        err(f'Verifica: unzip -l {args.loinc_zip} | grep -i panel')
        sys.exit(1)
    ok(f'Trovato: {csv_path}')

    info('Lettura panel...')
    panels = read_panels(args.loinc_zip, csv_path)
    total = len(panels)
    total_members = sum(len(v) for v in panels.values())
    ok(f'{total} panel, {total_members} osservazioni membro totali')
    print()

    if args.dry_run:
        info('Dry run completato. Esempi panel:')
        for i, (code, members) in enumerate(list(panels.items())[:5]):
            print(f'  {code} ({len(members)} figli): {", ".join(members[:5])}{"..." if len(members) > 5 else ""}')
        sys.exit(0)

    info(f'Inizio import... (delay={args.delay}s per POST)')
    print()

    n_ok = 0
    n_err = 0
    n_skip = 0
    err_msgs = []

    for i, (panel_code, member_codes) in enumerate(panels.items(), 1):
        vs = build_valueset(panel_code, member_codes, args.version)
        status, error = post_valueset(args.hapi_url, vs)

        if status in (200, 201):
            n_ok += 1
        elif status == 422:
            # ValueSet già esistente con stesso URL — HAPI ritorna 422 su duplicato URL
            n_skip += 1
        else:
            n_err += 1
            msg = f'{panel_code}: HTTP {status} — {error}'
            err_msgs.append(msg)
            if n_err <= 5:
                warn(msg)

        if i % 200 == 0 or i == total:
            pct = i * 100 // total
            print(f'  [{pct:3d}%] {i}/{total} — OK:{n_ok} SKIP:{n_skip} ERR:{n_err}')

        if args.delay > 0:
            time.sleep(args.delay)

    print()
    print('=' * 60)
    if n_err == 0:
        ok(f'Import completato: {n_ok} creati, {n_skip} già esistenti')
    else:
        warn(f'Import completato con errori: {n_ok} OK, {n_skip} skip, {n_err} errori')
        if len(err_msgs) > 5:
            warn(f'... e altri {len(err_msgs) - 5} errori')
    print()
    info(f'Verifica: curl -s \'{args.hapi_url}/ValueSet/$expand?url=http://loinc.org/vs/85353-1&_count=5\'')
    print('=' * 60)


if __name__ == '__main__':
    main()
