# Template email di Zammad

`application_wrapper.html.erb` sostituisce (montato in sola lettura) il template con cui Zammad avvolge le email HTML
in uscita (`app/views/mailer/application_wrapper.html.erb` dell'immagine). Il corpo degli articoli passa dal sanitizer di
Zammad, che toglie `<style>`, media query e `max-width`; questo template invece non e' sanitizzato.

E' l'originale di Zammad **7.2.2** (`original-7.2.2.html.erb`, solo per il diff) piu un blocco CSS in coda, limitato alle
mail del microservizio zammad con selettori sugli attributi che il sanitizer conserva: pagina `bgcolor="#f0f4f8"`,
scheda `bgcolor="#ffffff"`, caselle `align="left"`. Effetto: scheda centrata e larga al massimo 600px, caselle
affiancate su desktop e impilate a tutta larghezza su telefono (media query a 480px). Le mail scritte a mano dagli agenti
non cambiano.

## Versione
Il template e' quello di Zammad **7.2.2**: la versione in produzione (il default `VERSION` di questo compose e' piu' vecchio
e viene sovrascritto da `.env`). Con una versione diversa il template montato non corrisponde all'originale e cambierebbe
l'aspetto di tutte le mail: prima di cambiare `VERSION` seguire "Aggiornare Zammad".

## Aggiornare Zammad
A ogni cambio di `VERSION`: estrarre il template nuovo e riapplicare il blocco CSS.

    docker run --rm --entrypoint cat ghcr.io/zammad/zammad:<versione> /opt/zammad/app/views/mailer/application_wrapper.html.erb > mail-template/original-<versione>.html.erb
    diff mail-template/original-7.2.2.html.erb mail-template/original-<versione>.html.erb

Se il diff e' vuoto basta aggiornare il nome del file; altrimenti riportare le novita' nel template montato.

## Provarlo
Dopo `docker compose up -d`, mandare una mail di prova (Query ad alta priorita') e controllarla in Gmail su PC e telefono.
Il file e' letto a ogni invio: dopo una modifica basta ricreare i container (`docker compose up -d --force-recreate zammad-scheduler zammad-railsserver`).
