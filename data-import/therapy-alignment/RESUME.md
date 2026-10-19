# Allineamento bracci J-LI NEW — stato al 2026-10-10

## Stato
**Preprod: COMPLETATO e verificato.** Tutti i bracci con farmaco di Indicata e Controindicata (Linee 1-3) sono allineati al master Treme+Durva.
- Dry-run globale finale: 0 da modificare, 0 da creare, 0 errori.
- Check indipendente (lettura diretta HAPI, 15 bracci): 0 problemi.
- Creati: 5 bracci di Linea 3, linee esterne Controindicata (AD 34848/34849/34850, 15 CarePlan, 6 Group) e un Questionnaire SAE per terapia.
- Cancellati gli AD "Fine Trattamento" dello studio (32150, 32233, 32296, 32415 [TO DELETE], 32526 [TO DELETE]) con CarePlan, Group, Questionnaire e azione nei PlanDefinition, con `delete_fine_trattamento.py`. Backup in `backup-fhir/2026-10-10-pre-delete-fine-trattamento/`. Restano per scelta i Group orfani 32236/32237 (vedi Aperti).
- **SAE Trattamento condiviso per (tipo, linea) con i farmaci della linea** (2026-10-10, backup `backup-fhir/2026-10-10-pre-sae-farmaci/`): un solo Questionnaire SAE per gruppo (`sae_groups` in config; proprietario = primo target): IND-L1 = master 32375 (4 farmaci, condiviso con Atezo+Beva), IND-L2 = 32506 (Sorafenib, Cabozantinib, Regorafenib, Lenvatinib), IND-L3 = 34773 (Sorafenib, Cabozantinib, Regorafenib), CTR-L1 = 32194 (Sorafenib, Lenvatinib), CTR-L2 = 32278 (Sorafenib, Cabozantinib, Regorafenib), CTR-L3 = 34785 (Cabozantinib, Regorafenib). I SAE per-braccio sostituiti sono `retired`. `restrict_drugs()` in align_tree.py riscrive menu "Trattamento in corso", gruppi date, Nesso e Provvedimenti con id deterministici (uuid5) uguali in SAE e SAE Follow-up della stessa linea. Il Follow-up resta per braccio (prepopula dal SAE condiviso). Atezo+Beva e' ora un target `only_steps: [SAE]`.
- Ultima correzione: `Questionnaire/34544` (SAE Follow-up Atezo+Beva), tolti i `group_ids` residui. Backup in `backup-fhir/2026-10-10-q34544/`.

**Produzione: NON eseguito.** Vedi sezione dedicata.

## File
- `align_therapy_branch.py` — libreria `Fhir` (modo diretto se `--base` finisce per `/fhir`, retry, throttle) + allineamento Linea 1.
- `align_tree.py` — multi-braccio: creazioni, SAE per terapia, linee esterne.
  Modi: `backup | dry-run | apply --yes [--targets A,B|EXTERNAL] | restore --yes | undo-creates --yes`.
  Le risorse create finiscono nel journal `created.jsonl` del backup-dir.
- `delete_fine_trattamento.py` — cancella gli AD "Fine Trattamento" (modi `dry-run | apply --yes`, `--base`, `--backup-dir`). Id dei target scritti nello script (preprod). Controlla titolo e 0 QuestionnaireResponse, NON le Observation (vedi sotto).
- `config-jli-new-linea1.json` — Linea 1 Atezo+Beva (riferisce `Questionnaire/34544`).
- `config-jli-new-tutti-i-bracci.json` — 15 target + `external_lines`.
- Credenziali solo via env: `IRCCS_USER`, `IRCCS_PASSWORD` (mai in config). Pausa tra richieste: `IRCCS_THROTTLE` (default 0,2 s).
- Backup JSON+SHA256 in `~/Scrivania/sviluppo/IRCCS/backup-fhir/` (ultimo: `2026-10-10-preprod-hapi-diretto-post-giro4b`; stato pre-modifiche: `2026-10-09-preprod-jli-new-linea1`).
- Gli script non sono committati.

## Regole di allineamento (decise dall'utente)
- Step condivisi con lo stesso id Questionnaire del master: Dati Basali, Trattamenti Locoregionali, Stadiazione, Farmaci/Patologie, Follow Up, e in Trattamento CTCAE + Fine Trattamento.
- Per terapia: Somministrazione, SAE Follow-up, CTCAE SAE, Group Eleggibili. SAE Trattamento: condiviso per (tipo, linea), vedi sopra. (vecchio elenco: SAE, SAE Follow-up (precompila dal proprio SAE, valore = id nudo `<id>|all|autofill`), CTCAE SAE, Group Eleggibili. Quelli di Linea 3 sono clonati da Linea 2.
- CarePlan tutti `active/plan`, titoli Title Case, estensioni sempre in forma lunga (URL assoluto). I vecchi Questionnaire sostituiti diventano `retired`. "Assunzione Farmaco" esce dal CarePlan Trattamento.
- "Fine Trattamento ..." (AD): eliminati (regola cambiata il 2026-10-10; Atezo+Beva e Treme+Durva non li hanno). Una nuova linea non deve averli.
- Non toccare: linee esterne Indicata esistenti (32342/32474/32541), Diario, QuestionnaireResponse (non vengono ripuntate), Group Eleggibili/Non eleggibili, Somministrazione.

## Come si usa
```bash
cd "<repo>/irccs-docker/data-import"
C="--config therapy-alignment/config-jli-new-tutti-i-bracci.json --base <BASE>"
B=~/Scrivania/sviluppo/IRCCS/backup-fhir/<data>-<ambiente>-pre
python3 therapy-alignment/align_tree.py backup  $C --backup-dir $B
python3 therapy-alignment/align_tree.py dry-run $C --backup-dir $B     # da rivedere
python3 therapy-alignment/align_tree.py apply --yes --targets <A,B|EXTERNAL> $C --backup-dir $B   # a gruppi
python3 therapy-alignment/align_tree.py dry-run $C --backup-dir $B     # verifica: deve dare 0 / 0
```
- Ordine seguito in preprod: Linea 1 (`align_therapy_branch.py`), Indicata L2, Controindicata L1-L2, Linea 3, `EXTERNAL`.
- Se un apply si interrompe: NON rilanciare subito. Leggere `created.jsonl`, eseguire `undo-creates --yes`, rifare il backup e ripartire.
- `<BASE>` che finisce per `/fhir` = HAPI diretto (senza auth); altrimenti proxy autenticato.

## Lezioni tecniche
- La visibilità si controlla con le estensioni `group_ids` sulla risorsa (CarePlan/AD/Group/PD: i 7 gruppi dello studio; Questionnaire: di norma nessuno). Il proxy le nasconde: per leggerle serve HAPI diretto.
- Il POST via microservizio richiede `X-Create-Scope` (gruppo "IRCCS Istituto Nazionale Tumori Admins" `1689f3a0-22d6-4e97-ade8-034753fe23c4` + `organizationId: 5579`) e scarta le estensioni top-level: dopo la creazione serve una PUT.
- Clonando un AD, sostituire le estensioni cancella i `group_ids`.
- I CarePlan clonati dal master NON devono ereditare le sue `duplicateCrfItem`, altrimenti si sovrascrivono i SAE del master (32375/33465). Il clone è senza `duplicateCrfItem` e `plan_sae` protegge i SAE del master.
- I Questionnaire creati da dashboard come "(Copia)" ereditano `group_ids`: vanno tolti per allinearli ai fratelli (caso 34544).
- Molti Questionnaire hanno `name` ma non `title`.
- Non lanciare molte richieste ravvicinate sul proxy pubblico (preprod ha smesso di rispondere il 2026-10-09): letture massive su HAPI diretto.
- Le scritture dirette su HAPI non hanno utente nell'audit trail; vanno autorizzate esplicitamente per ogni ambiente.
- Il classificatore auto-mode blocca le modifiche inline allo script; sbloccato con la regola `Edit(.../therapy-alignment/**)` in `.claude/settings.local.json`.

## Produzione: da fare prima di lanciare
Gli id di partenza di prod coincidono con quelli di preprod (il dump è stato fatto prima delle modifiche), quindi le config sono riusabili. Mancano però questi passi:
1. **Confronto prod / backup pre-modifiche** (`2026-10-09-preprod-jli-new-linea1`), in sola lettura. Se qualcuno ha modificato risorse in prod dopo il dump, lo script le sovrascrive.
2. **Cancellazione "Fine Trattamento" anche in prod**: gli id coincidono col dump, ma ripetere i controlli (Observation sui Group, QuestionnaireResponse) prima dell'apply.
3. **`Questionnaire/34544` non esiste in prod.** È la copia fatta da dashboard il 2026-10-09, dopo il dump. `config-jli-new-linea1.json` lo riferisce (riga 47). Scelta aperta: A) farlo creare allo script come per le altre terapie e aggiornare la config (consigliato); B) crearlo a mano dal dashboard e aggiornare l'id.
4. **Verifica `group_ids` e Keycloak.** Il dump HAPI non include Keycloak: controllare che UUID dei 7 gruppi dello studio, gruppo Admins e `organizationId` 5579 siano uguali in prod.
5. **Autorizzazione esplicita** dell'utente per le scritture dirette su HAPI di prod, e endpoint di prod (HAPI diretto e proxy).
6. Le risorse create avranno id diversi da preprod: il check finale va rifatto con gli id di prod.
7. Controllare che nessuna linea in uso perda il Questionnaire che i pazienti stanno compilando (le QuestionnaireResponse vecchie non vengono ripuntate).
8. Controllo visivo nel dashboard di preprod (Controindicata L1, bracci Linea 3) prima di andare in prod.
9. Backup completo con hash, dry-run rivisto dall'utente, apply a gruppi, dry-run di verifica 0/0, check indipendente.

## Studio nuovo "JLI Final" (copia di J-LI NEW, preprod, 2026-10-10)
- `ResearchStudy/34852`, 384 risorse; master Treme+Durva = `ActivityDefinition/35058`. Config: `config-jli-final.json` (id mappati dall'originale).
- Procedura (ripetibile su prod con URL/`organizationId` suoi):
  1. `pascale-local/setup/merge_studies_newest.py --a 32130 --b 32130 --title "JLI Final" --includi Questionnaire/15025 --hapi <HAPI diretto> --import-url https://<host>/Bundle/import --scope <gruppo Admins> --organization-id <org> --conferma-host <host> --apply` (token = login `/auth/users/token`; l'URL giusto e' `/Bundle/import`, NON `/fhir/Bundle/import` che serve l'HTML del dashboard). Dry-run senza `--apply`. `--includi` copia una risorsa esterna (prepopulate); gli id citati dentro le espressioni (es. `Q.id = '32304'`) vengono riscritti dopo l'import.
  2. Mappa id originale->copia: crawl dei due studi con la stessa chiave strutturale (383/383 mappate) -> config nuova.
  3. `align_tree.py backup/apply/dry-run` con la config nuova (gli unici diff erano l'ordine delle extension; ora `canon()` ignora l'ordine).
  4. `copy_group_ids.py dry-run|apply --yes --orig 32130 --copy 34852 --extra Questionnaire/15025=Questionnaire/34851`: l'import assegna a tutto il solo gruppo Admins (anche ai Questionnaire); lo script copia i group_ids dall'originale (7 gruppi sulle risorse di design, nessuno sui Q).
- Esito: dry-run allineamento 0/0, copy_group_ids 0 da allineare, check indipendente sulla copia (`/tmp/claude-1000/chk/check_jli_final.py`) 0 problemi. Rollback import: `created-refs.json` in scratchpad `clone-jli-apply`.

## Aperti
- Group 32236/32237 (Eleggibili/Non Eleggibili di "Fine Trattamento Linea 2" Controindicata) NON cancellati: `Observation/34695` (Patient/34629, `eligibility-flow|notEligibleTreatmentArm`) li usa in `focus` (HAPI 409). Decisione utente 2026-10-10: lasciarli. In prod controllare prima le Observation con `focus` sui Group (`Observation?focus=Group/<id>`): cancellare solo i Group senza riferimenti.
- Committare script e config (solo su richiesta esplicita).
- Cambiare la password dell'utente, che era stata scritta in chat.
- Replica su prod: vedi sopra.

## STATO PRODUZIONE "JLI Final" (aggiornato 2026-10-11, ripresa)
- Import fatto: `ResearchStudy/34726` "JLI Final" su pj.istitutotumori.na.it (455 risorse NUOVE; master `ActivityDefinition/34960`; Q 15025 copiato). Output/backup/rollback: `~/Scrivania/sviluppo/IRCCS/backup-fhir/2026-10-10-jli-final-prod-import/` (created-refs.json). J-LI NEW prod (32130) NON toccato.
- Mappa id originale->copia: `/tmp/claude-1000/map_prod.json` (454/454; in /tmp, rigenerabile). Config: `config-jli-final-prod.json` (study 34726).
- Dry-run allineamento (proxy, sola lettura): 220 da modificare, 85 da creare, 118 Q da ritirare, 0 errori. VERIFICATO: nessun id < 34726 toccato (vincolo utente 2026-10-11: Q vecchi/altri studi NON si toccano, tutte le risorse dello studio devono essere nuove).
- Fix fatto in align_tree: `sae_owner` in `plan_sae`.
- DA FARE (serve IRCCS_USER/IRCCS_PASSWORD, l'utente li inserisce con `!`):
  1. `align_tree.py backup` + `apply --yes --targets IND-L2-Sorafenib` (base https://pj.istitutotumori.na.it, backup-dir `.../2026-10-10-jli-final-prod-align`, IRCCS_THROTTLE=0.2); verificare che la PUT via proxy conservi i group_ids.
  2. apply a gruppi (bracci esistenti, poi Linea 3, poi EXTERNAL); dry-run finale 0/0.
  3. Controllare che nella copia NON restino riferimenti a risorse fuori dallo studio (es. prepopulate verso `Questionnaire/8544` "Farmaci concomitanti" L2; se resta, ripuntare a un Q nuovo).
  4. Cancellare i 5 AD "Fine Trattamento" della copia (script con id mappati; controllare Observation/QR `focus` prima dei Group).
  5. Visibilita': senza HAPI diretto copy_group_ids non va; assegnare i 7 gruppi (8795ba6e, 48447b2f, 0ba62f00, 1689f3a0, 17663fba, 772b0cec, c88a1fe9) dal dashboard e togliere i group_ids dai Q; verificare esistenza gruppi in prod.
  6. Check indipendente con id prod; controllo visivo dashboard (SAE per linea, Follow-up).
- Niente commit senza richiesta; cambiare la password condivisa in chat.

### Prod JLI Final (34726): ESEGUITO 2026-10-11
- Backup `backup-fhir/2026-10-11-jli-final-prod-align` (291 risorse) + apply di tutti i target (L1 Atezo+Beva, L2, L3 nuovi, CTR L1-L3, EXTERNAL): dry-run globale 0/0, 0 errori. Nessun id <34726 toccato.
- "Fine Trattamento" eliminati nella copia (5 AD: 34746, 34831, 35015, 34894, 35125, con PD/CarePlan/Group/Q; backup `2026-10-11-jli-final-prod-pre-delete-fine-trattamento`) con `delete_fine_trattamento.py --targets-json` (scoperta via crawl, proxy autenticato).
- Verifica riferimenti: nessun riferimento a Questionnaire/CarePlan/Group/AD/PD vecchi; restano solo `DocumentReference/5878` e `5883` (template consenso nei Group Eleggibili 34934/35115, ereditati dall'originale, 404 anche in prod).
- NOTA crawl: il ResearchStudy radice punta ai ResearchStudy figli (non ai PD): includere `ResearchStudy` nel BFS.
- Restano: group_ids/visibilita' dal dashboard (non leggibili via proxy: verificare che la PUT li abbia conservati), controllo visivo, check indipendente con id prod.

### Chiusura prod 2026-10-11
- Verifica isolamento: 393 risorse dello studio 34726 (5 RS, 135 Q, 147 CP, 53 Group, 23 AD, 8 PD, 22 Library), nessun riferimento a risorse di altri studi. Eccezioni note: Q 34725 = copia nuova di Q15025 (creata dall'import, id <34726 ma e' dello studio); `DocumentReference/5878` e `5883` (consensi nei Group 34934/35115, ereditati dall'originale, 404 in prod: da ripuntare a 34727/34728 se serve); Organization 5579, Practitioner 9971 condivisi. 0 ResearchSubject sul nuovo studio.
- Check visivo dell'utente nel dashboard: tutto ok (visibilita' inclusa).
- Script di scoperta/verifica usati (scratchpad, non conservati): crawl BFS dal ResearchStudy radice includendo i ResearchStudy figli.
- Aperti: commit script/config (solo su richiesta), cambio password condivisa in chat, DocumentReference rotti.

## Fine Trattamento: marcatore e linea (2026-10-11)
- Scope: il codice `end-of-treatments-N` del CRF Fine Trattamento non e' piu' scritto a mano ma derivato dal dashboard (linea risolta dall'ActivityDefinition + marcatore `end-of-treatment` su un campo di un tipo in allowlist: boolean, date, dateTime, time, string, text, integer, decimal, quantity, choice, open-choice; con observationExtract). Spec: `irccs-react-dashboard/docs/superpowers/specs/2026-10-11-fine-trattamento-linea-design.md`.
- Script: `set_end_of_treatment_marker.py` (in questa cartella). Dry-run di default; apply solo con `--yes --backup-dir <dir> --conferma-host HOST` (HOST deve essere l'host di `--base`; backup per file + SHA256SUMS, deep copy della stessa lettura usata per il PUT; rifiuta risorse senza `meta.versionId`); `--base` deve finire con `/fhir` (HAPI diretto, preprod). L'ID di `--campo` deve essere numerico; stessa allowlist di tipi del dashboard (`src/fhir/extensions/endOfTreatment.ts`), da tenere allineata a mano. Uso: `--campo ID=LINKID` ripetibile (es. `--campo 35030=eb78d984-eb38-40fc-8921-aa1839b629bd`): marca il campo indicato (observationExtract + marcatore, il suo code resta intatto) e ripulisce ogni altro item con un coding `end-of-treatments-N` scritto a mano (toglie il coding; se non resta alcun code toglie anche `code` e observationExtract; toglie un marcatore residuo). I CRF delle linee esterne (predefiniti 35048/35124/35204) sono rifiutati in apply senza `--anche-linee-esterne`; l'elenco si sostituisce con `--linee-esterne ID[,ID...]` (altri ambienti).
- Legame alla data: nel CRF Fine Trattamento il marcatore sta sulla data "Data della definitiva decisione di interruzione del trattamento" (linkId `eb78d984-eb38-40fc-8921-aa1839b629bd`, sotto il Si'/No `6e77ad5b-212d-4fc3-8656-4c6fbaee01f9`); il Si'/No non estrae piu' nulla. Una data non ha valore di default: un autosave di un CRF aperto e non compilato non crea l'Observation.
- Causa del difetto "linea 2 sempre attiva": con il marcatore/codice sul Si'/No un CRF autosalvato (`in-progress`) con Si'/No lasciato a "No" creava l'Observation `end-of-treatments-N` e abilitava la linea successiva (paziente 33339 preprod, QuestionnaireResponse 34409, "ELEGIBILITY LINE 2" abilitata). Risolto spostando il marcatore sulla data.
- Regola a runtime: sull'item marcato il dashboard toglie OGNI coding `end-of-treatments-N` (qualunque system), tiene gli altri coding e aggiunge `urn:uuid:end-of-treatments|end-of-treatments-<linea>`. Serve perche' il Questionnaire 35030 ha sulla data un coding scritto a mano `end-of-treatments-1` con system uuid: tenuto, l'Observation di L2 avrebbe `-1` e `-2` e il lettore (ricerca per solo codice) sbloccherebbe la linea sbagliata. Il toggle OFF del designer toglie il marcatore e `observationExtract` solo se l'item non ha code con valore.
- Audit (solo lettura): `audit_end_of_treatments.py --base http://HOST:8080/fhir --conferma-host HOST`. Classifica ogni Observation `end-of-treatments-N`: OK / SOSPETTA-boolean / SOSPETTA-valore-falso / NON-MARCATA / SORGENTE-NON-TROVATA. Preprod (2026-10-11): 13 Observation, OK 2 (paziente di prova 35236), SOSPETTA-boolean 2, SOSPETTA-valore-falso 3, NON-MARCATA 6. Sanatoria prima di J-LI NEW: ri-salvare dal dashboard le QuestionnaireResponse interessate o rimuovere a mano le Observation sospette, poi secondo audit.
- Prova funzionale preprod (paziente 35236, JLI Final): CRF aperto senza toccarlo / Si'/No=No / Si' con data vuota -> nessuna Observation, pulsante linea successiva disabilitato; data compilata e salvata -> `end-of-treatments-1` (L1) e `-2` (L2, stesso Questionnaire 35030), pulsante abilitato.
- Rollback: prima ripristinare il Questionnaire dal backup (`SHA256SUMS`), poi il dashboard. Questionnaire migrato + dashboard vecchio = nessuna Observation, linea non sbloccata, silenzioso.
- Limiti noti e dettagli: vedi spec (sezioni "Rilascio e rollback", "Limiti noti", "Sanatoria dati prima di J-LI NEW").
- Stato preprod: `35030` = data marcata, Si'/No senza estrazione (marcatore, observationExtract e code rimossi). Se non gia' applicato, verificare con dry-run `--campo 35030=eb78d984-eb38-40fc-8921-aa1839b629bd`. Prod (34982, 34932) NON toccata.
- Ordine: 1) rilascio dashboard (retro-compatibile) -> 2) migrazione preprod di 35030 con `--campo` -> 3) prova funzionale (L1 -> `end-of-treatments-1`, L2 -> `-2`, eleggibilita' successiva sbloccata) -> 4) prod solo su richiesta esplicita dell'utente.
- Id: preprod 35030; prod 34982 e 34932 (in prod serve una variante dello script per il proxy autenticato).
- ATTENZIONE: l'apply riguarda SOLO il CRF condiviso. I Fine Trattamento delle linee esterne (35048, 35124, 35204) NON vanno migrati. Non applicare prima del rilascio dashboard: senza di esso il CRF marcato e senza codice non genera l'Observation.
