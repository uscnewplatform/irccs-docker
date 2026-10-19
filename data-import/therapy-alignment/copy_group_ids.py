#!/usr/bin/env python3
"""Copia i group_ids (visibilita') dalle risorse di uno studio originale a quelle della copia.

L'import di un studio (Bundle/import) assegna a tutte le risorse il solo gruppo di lavoro di chi importa
(e anche ai Questionnaire). Per rendere la copia visibile come l'originale, ogni risorsa della copia riceve
gli STESSI group_ids della risorsa corrispondente (stessa chiave strutturale); un Questionnaire senza
group_ids nell'originale li perde nella copia.

Uso (HAPI diretto, scrittura autorizzata dall'utente):
  python3 copy_group_ids.py dry-run --base http://HOST:8080/fhir --orig 32130 --copy 34852 --backup-dir DIR
  python3 copy_group_ids.py apply --yes ... [--extra Questionnaire/15025=Questionnaire/NNNN]
Il backup salva il JSON attuale di ogni risorsa che verra' modificata.
"""
import argparse, json, os, sys, time, urllib.request

sys.path.insert(0, "/home/gennaroaurilia/Scrivania/sviluppo/IRCCS/git/pascale-local/setup")
import merge_studies_newest as m


def gids(r):
    return sorted(e["valueString"] for e in r.get("extension", []) if e["url"] == "group_ids")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["dry-run", "apply"])
    ap.add_argument("--base", required=True)
    ap.add_argument("--orig", required=True)
    ap.add_argument("--copy", required=True)
    ap.add_argument("--backup-dir", required=True)
    ap.add_argument("--extra", action="append", default=[], metavar="ORIG=COPIA",
                    help="coppie fuori dallo studio (es. Questionnaire/15025=Questionnaire/35200)")
    ap.add_argument("--yes", action="store_true")
    a = ap.parse_args()
    h = m.Hapi(a.base)
    rA, kA = m.crawl(h, f"ResearchStudy/{a.orig}")
    rB, kB = m.crawl(h, f"ResearchStudy/{a.copy}")
    pairs = {kA[k][0]: kB[k][0] for k in kA if k in kB}
    for e in a.extra:
        o, c = e.split("=")
        pairs[o] = c
    todo = []
    for o, c in pairs.items():
        want, have = gids(h.get(o)), gids(h.get(c))
        if want != have:
            todo.append((o, c, want, have))
    print(f"coppie: {len(pairs)}  da allineare: {len(todo)}")
    for o, c, want, have in todo[:6]:
        print(f"  {c}: {[x[:8] for x in have]} -> {[x[:8] for x in want]}   (da {o})")
    if a.mode == "dry-run":
        return
    if not a.yes:
        sys.exit("serve --yes")
    os.makedirs(a.backup_dir, exist_ok=True)
    for o, c, want, have in todo:
        cur = h.get_fresh(c)
        with open(f"{a.backup_dir}/{c.replace('/', '-')}.json", "w") as f:
            json.dump(cur, f, indent=1)
        cur["extension"] = [e for e in cur.get("extension", []) if e["url"] != "group_ids"] + \
            [{"url": "group_ids", "valueString": g} for g in want]
        if not cur["extension"]:
            cur.pop("extension")
        h.put(c, cur)
        time.sleep(0.2)
    print(f"aggiornate {len(todo)} risorse; backup in {a.backup_dir}")


if __name__ == "__main__":
    main()
