# Cluster Docker Network
- r5-fhir-server
- httpd 2.4.46
- redis:7.0-rc
- java-env


# Build delle immagini

Navigando le soluzioni nella folder `docker` httpd e java eseguire i relativi script di build: `build.sh`
Per il server fhir l'immagine è separata poiché include tutta la soluzione java, è quindi necessario
eseguire un checkout del **master** del seguente repository `git@github.com:infocube-it/irccs-fhir-server.git`
eseguire lo script `build.sh`


# Deploy react dashboard

Il front-end usato è il seguente:
```
    git@github.com:infocube-it/irccs-react-dashboard.git
```

Da ritenere aggiornato il branch `origin/develop` versioni e istruzioni per le build sono contenute nella root del progetto,
una volta buildata la soluzione, spostare il contenuto sotto `html/` eliminando la `index.html` se presente.


# Struttura Progetto E Deploy micro-servizi
I micro-servizi associati al progetto sono:

```
    git@github.com:infocube-dev-team/irccs-ctcae-service.git
    git@github.com:infocube-it/irccs-microservice-studio-clinico.git
    git@github.com:infocube-it/irccs-microservice-centro-ricerca.git
    git@github.com:infocube-it/irccs-microservice-anagrafica-pazienti.git
    
```

Da ritenere aggiornato il branch `origin/develop`  
Ogni micro-servizio ha versione di jdk e maven usata per la build,


Il progetto è strutturato in modo tale che i micro-servizi sono montati come volume dalla cartella services.
Quarkus una volta buildato la soluzione con `mvn package` NON bisogna copiare il jar posizionato nella root della folder target
ma la sub-directory `quarkus-app`.
Tale folder deve essere rinominata e spostata sotto `services` come riportato:

```
├───docker
├───html
│   └───index.html
└───services
    └───organization-app
        ├───app
        ├───lib
        │   ├───boot
        │   └───main
        └───quarkus    
```