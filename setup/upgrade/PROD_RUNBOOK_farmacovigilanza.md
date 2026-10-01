# Runbook PROD — allineamento gruppo farmacovigilanza (`opened_sae_email`)

Procedura per allineare **un ambiente nuovo (es. produzione)** alla feature gruppo
farmacovigilanza: realm role Keycloak + `Group.code` sui gruppi esistenti + gruppo
`<Org> Farmaco vigilanza` per ogni centro.

Idempotente: rilanciabile. Token admin passato direttamente (no user/pass).

> Riferimento stato/decisioni: memoria `opened-sae-email-group`. Ambiente 10.99.88.240
> gia' allineato (modello di verifica usato qui sotto).

---

## 0. Variabili ambiente

Compila gli endpoint PROD (porte dirette o reverse-proxy) e incolla il token admin.

```bash
# --- endpoint PROD (adatta) ---
export FHIR=https://PROD/fhir            # base HAPI FHIR
export CENTRO=https://PROD               # base microservizio centro-ricerca (POST Group)
export GROUP_PATH=/fhir/Group            # /fhir/Group porte dirette · /Group dietro reverse-proxy
export KC=https://PROD:9445              # base Keycloak
export REALM=pascale

# --- token admin (super-admin Keycloak / master realm) ---
export TOKEN='Bearer eyJ...'             # incolla qui il bearer admin

auth=(-H "Authorization: $TOKEN")
```

Il token deve appartenere a super-admin (gruppo KC `/admin`) o avere
`internal:create:group` / `internal:create:organization`, e potere admin sul realm
per i passi Keycloak.

---

## 1. PRE-REQUISITO: codice deployato

Prima di toccare i dati, su PROD devono girare le versioni con la feature:

- `irccs-common` bumpato e pubblicato su Nexus.
- Consumer rebuildati/redeployati: **centro-ricerca** (creazione Group + header `role`,
  `OrganizationFlow` con `Group.code`), **practitioner**, **studio-clinico**.
- Frontend `irccs-react-dashboard` con mapping `code` + filtro designer SAE.

Senza centro-ricerca aggiornato, il POST del gruppo farmaco non crea il gruppo KC figlio
ne' assegna il role → lo step 3 fallirebbe a meta'.

---

## 2. Keycloak: realm role `opened_sae_email` + flag

### 2a. Verifica se gia' presente

```bash
echo "=== role opened_sae_email ==="
curl -fsS "${auth[@]}" "$KC/admin/realms/$REALM/roles/opened_sae_email" \
  | jq '{name,composite,description}' 2>/dev/null || echo "ASSENTE"
echo "=== compositi (attesi 25) ==="
curl -fsS "${auth[@]}" "$KC/admin/realms/$REALM/roles/opened_sae_email/composites" \
  | jq -r '.[].name' | sort
echo "=== flag internal:read:study-associated ==="
curl -fsS "${auth[@]}" "$KC/admin/realms/$REALM/roles/internal%3Aread%3Astudy-associated" \
  | jq '{name,composite}' 2>/dev/null || echo "ASSENTE"
```

Lista attesa dei 25 compositi:

```
internal:ui:patients  internal:read:study-associated  internal:read:group  internal:create:group
patient:read patient:search  questionnaire:read questionnaire:search
questionnaireresponse:read questionnaireresponse:search
researchstudy:read researchstudy:search  researchsubject:read researchsubject:search
adverseevent:read adverseevent:search  practitioner:read practitioner:search
group:read group:search  organization:read organization:search
task:create task:read task:search
```

NB: NIENTE `internal:read:organization`, NIENTE `questionnaireresponse:create/update`.

### 2b. Se assente / da allineare — crea con token

Snippet token-based (no user/pass). Idempotente: crea il flag, il role composito, e
ri-assegna i compositi (POST additivo). I sotto-ruoli devono gia' esistere nel realm.

```bash
COMPOSITE_ROLES=(
  internal:ui:patients internal:read:study-associated internal:read:group internal:create:group
  patient:read patient:search questionnaire:read questionnaire:search
  questionnaireresponse:read questionnaireresponse:search
  researchstudy:read researchstudy:search researchsubject:read researchsubject:search
  adverseevent:read adverseevent:search practitioner:read practitioner:search
  group:read group:search organization:read organization:search
  task:create task:read task:search
)
enc() { jq -rn --arg s "$1" '$s|@uri'; }
api() { curl -fsS "${auth[@]}" -H "Content-Type: application/json" "$@"; }

# flag (composite=false)
api "$KC/admin/realms/$REALM/roles/$(enc internal:read:study-associated)" >/dev/null 2>&1 \
  || api -X POST "$KC/admin/realms/$REALM/roles" \
       -d '{"name":"internal:read:study-associated","description":"Abilita read/search sulle risorse di tutti i centri degli studi a cui i gruppi dell utente sono associati","composite":false}'

# role composito
api "$KC/admin/realms/$REALM/roles/opened_sae_email" >/dev/null 2>&1 \
  || api -X POST "$KC/admin/realms/$REALM/roles" \
       -d '{"name":"opened_sae_email","description":"Farmacovigilanza: lettura pazienti/CRF di tutti i centri degli studi associati + apertura query/ticket","composite":true}'

# assembla e assegna i compositi
COMPOSITES_JSON="[]"
for r in "${COMPOSITE_ROLES[@]}"; do
  rep=$(api "$KC/admin/realms/$REALM/roles/$(enc "$r")" 2>/dev/null || true)
  [ -n "$rep" ] && [ "$(jq -r '.name//empty' <<<"$rep")" != "" ] \
    && COMPOSITES_JSON=$(jq -c --argjson x "$rep" '.+[$x]' <<<"$COMPOSITES_JSON") \
    || echo "  ATTENZIONE: sotto-ruolo '$r' assente, salto."
done
echo "compositi risolti: $(jq length <<<"$COMPOSITES_JSON")"
api -X POST "$KC/admin/realms/$REALM/roles/opened_sae_email/composites" -d "$COMPOSITES_JSON" >/dev/null
echo "role allineato."
```

> Alternativa con user/pass: `keycloak-config/add-farmacovigilanza-role.sh`
> (`KC_URL=... REALM=pascale ADMIN_USER=... ADMIN_PASS=... ./add-farmacovigilanza-role.sh`).

---

## 3. FHIR backfill — `Group.code` + gruppi farmaco

### 3a. DRY-RUN (sempre prima)

```bash
cd "$(dirname "$0")" 2>/dev/null; cd irccs-docker/setup 2>/dev/null || true
python3 backfill_farmacovigilanza.py \
  --fhir-url "$FHIR" \
  --centro-url "$CENTRO" \
  --group-path "$GROUP_PATH" \
  --token "$TOKEN" \
  --dry-run
```

Leggi il riepilogo. `code aggiunti` / `farmaco creati` = quante scritture farebbe il run reale.

### 3b. RUN reale

Rimuovi `--dry-run`:

```bash
python3 backfill_farmacovigilanza.py \
  --fhir-url "$FHIR" --centro-url "$CENTRO" --group-path "$GROUP_PATH" --token "$TOKEN"
```

Exit code ≠ 0 ⇒ ci sono stati errori (vedi righe `ERRORE ...`). Risolvi e rilancia
(idempotente).

Cosa fa:
1. PUT diretto su HAPI: aggiunge `Group.code` (system `group-type`) ai gruppi che ne
   sono privi, deducendo il tipo dal suffisso del nome.
2. POST `centro-ricerca $GROUP_PATH` (header `organizationId`+`role: opened_sae_email`):
   crea `<Org> Farmaco vigilanza` mancante → crea anche gruppo KC figlio + assegna role.

> Gruppi orfani (su Organization cancellate o senza `identifier.assigner`) NON vengono
> toccati: il backfill itera solo i gruppi delle Organization vive. È atteso.

---

## 4. Verifica post-run

```bash
# 4a. tutte le Org vive hanno i gruppi codati e il gruppo farmaco
python3 - "$FHIR" <<'PY'
import sys,json,urllib.request
F=sys.argv[1].rstrip('/'); SYS="http://irccs.pascale.it/fhir/CodeSystem/group-type"
def get(q): return json.load(urllib.request.urlopen(f"{F}/{q}"))
orgs=get("Organization?_count=1000&_elements=name")
live={e['resource']['id']:e['resource'].get('name') for e in orgs.get('entry',[])}
grp=get("Group?type=practitioner&_count=1000&_elements=name,code,identifier")
def code(g):
  for c in (g.get('code',{})or{}).get('coding',[]):
    if c.get('system')==SYS: return c.get('code')
def org(g):
  for i in g.get('identifier',[]):
    r=(i.get('assigner')or{}).get('reference')
    if r: return r.split('/')[-1]
bad=[]; farmaco={}
for e in grp.get('entry',[]):
  g=e['resource']; o=org(g)
  if o in live:
    if not code(g): bad.append((live[o],g.get('name')))
    if code(g)=='opened-sae-email': farmaco[o]=1
print("Org vive:",len(live))
print("Org vive CON gruppo farmaco:",len(farmaco),"->",("OK" if len(farmaco)==len(live) else "MANCANTI: "+str([live[o] for o in live if o not in farmaco])))
print("gruppi su Org viva SENZA code:",len(bad),bad or "(nessuno OK)")
PY

# 4b. il role e' assegnato a un gruppo KC per ogni Org viva
echo "=== gruppi KC con role opened_sae_email ==="
curl -fsS "${auth[@]}" "$KC/admin/realms/$REALM/roles/opened_sae_email/groups?max=500" \
  | jq -r '.[].path'
echo "conteggio (atteso = n. Org vive):"
curl -fsS "${auth[@]}" "$KC/admin/realms/$REALM/roles/opened_sae_email/groups?max=500" | jq length
```

Atteso: 0 gruppi senza code su Org viva, n. gruppi farmaco = n. Org vive, n. gruppi KC
col role = n. Org vive.

---

## 5. HAPI search param `Group:code` (filtro designer SAE)

Il filtro modale/designer cerca `Group?code=...|opened-sae-email`. Verifica che HAPI
risolva la ricerca su `Group.code`:

```bash
curl -fsS "$FHIR/Group?code=http://irccs.pascale.it/fhir/CodeSystem/group-type|opened-sae-email&_summary=count" \
  -H "Accept: application/fhir+json" | jq .total
```

Se `total` = n. Org vive → search param attivo. Se 0 con gruppi esistenti → installare
il search param `Group:code` (vedi `pascale-local/setup/install_searchparameters.sh`).

---

## Checklist sintetica

- [ ] §1 codice deployato (common bump + centro-ricerca/practitioner/studio-clinico + UI)
- [ ] §2 role `opened_sae_email` (25 compositi) + flag `internal:read:study-associated`
- [ ] §3a dry-run controllato
- [ ] §3b run reale, exit 0
- [ ] §4a 0 gruppi senza code su Org viva, farmaco = n.Org
- [ ] §4b role KC assegnato = n.Org
- [ ] §5 `Group:code` searchable
