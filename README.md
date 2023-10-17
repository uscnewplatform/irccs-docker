# Cluster Docker Network
- sql server 2019
- r4-fhir-server
- httpd 2.4.46


# Struttura Progetto

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

# Build delle immagini

Navigando le soluzioni nella folder `docker` httpd e java eseguire i relativi script di build: `build.sh`
Per il server fhir l'immagine è separata poiché include tutta la soluzione java, è quindi necessario
eseguire un checkout del **master** del seguente repository `git@github.com:infocube-it/irccs-fhir-r4-server.git`
eseguire lo script `build.sh`