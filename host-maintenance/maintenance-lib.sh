#!/usr/bin/env bash
# Funzioni comuni a maintenance-on.sh / maintenance-off.sh (da "source", non eseguire).
#
# Stack gestiti (tutti agganciati alla rete docker "irccs" creata dallo stack main):
#   main        docker-compose.yaml                  (include irccs-httpd-dashboard)
#   monitoring  docker-compose-monitoring.yaml       (Loki/Grafana/Alloy)
#   pwa         docker-compose.pwa.yml               (irccs-pwa)
#   zammad      zammad-ticketing/docker-compose.yaml (ticketing, usa il suo .env)

COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLAG_FILE="$COMPOSE_DIR/httpd-config/.maintenance-flag"
STATE_FILE="$COMPOSE_DIR/host-maintenance/.maintenance-stacks"
HTTPD_SERVICE="irccs-httpd"
HTTPD_CONTAINER="irccs-httpd-dashboard"

# nome -> "directory-di-lavoro|file-compose" (relativi a COMPOSE_DIR)
declare -A STACK_DEF=(
    [main]=".|docker-compose.yaml"
    [monitoring]=".|docker-compose-monitoring.yaml"
    [pwa]=".|docker-compose.pwa.yml"
    [zammad]="zammad-ticketing|docker-compose.yaml"
)
# Ordine di AVVIO (main per primo: crea la rete "irccs"); lo stop e' l'inverso.
STACK_ORDER=(main monitoring zammad pwa)

if docker compose version &>/dev/null; then
    COMPOSE=(docker compose)
elif command -v docker-compose &>/dev/null; then
    COMPOSE=(docker-compose)
else
    echo "[ERRORE] Ne' 'docker compose' (v2) ne' 'docker-compose' (v1) trovati." >&2
    exit 1
fi

# stack_compose <stack> <args...>: esegue compose sullo stack, dalla sua directory.
stack_compose() {
    local stack="$1"; shift
    local def="${STACK_DEF[$stack]}"
    local dir="${def%%|*}" file="${def##*|}"
    (cd "$COMPOSE_DIR/$dir" && "${COMPOSE[@]}" -f "$file" "$@")
}

stack_exists() {
    local def="${STACK_DEF[$1]}"
    [ -f "$COMPOSE_DIR/${def%%|*}/${def##*|}" ]
}

# stack_running <stack>: vero se almeno un container dello stack e' in esecuzione.
stack_running() {
    local ids
    ids="$(stack_compose "$1" ps -q 2>/dev/null || true)"
    [ -n "$ids" ] || return 1
    # shellcheck disable=SC2086
    docker inspect -f '{{.State.Running}}' $ids 2>/dev/null | grep -q true
}

# ensure_bind_files: i file montati come bind-mount singoli da irccs-httpd DEVONO
# esistere come FILE prima dell'up. Se mancano, Docker crea al loro posto una
# DIRECTORY e il container non parte ("not a directory: Are you trying to mount
# a directory onto a file"). Ripara: directory vuota -> rimossa, file mancante -> ricreato.
ensure_bind_files() {
    local cfg="$COMPOSE_DIR/httpd-config" f
    for f in "$cfg/versions.json" "$FLAG_FILE"; do
        if [ -d "$f" ]; then
            if rmdir "$f" 2>/dev/null || sudo rmdir "$f"; then
                echo "[FIX] $f era una directory (creata da Docker): rimossa."
            else
                echo "[ERRORE] $f e' una directory NON vuota: sistemala a mano." >&2
                exit 1
            fi
        fi
    done
    [ -e "$FLAG_FILE" ] || { : > "$FLAG_FILE"; echo "[FIX] ricreato $FLAG_FILE (vuoto)."; }
    if [ ! -e "$cfg/versions.json" ]; then
        if [ -f "$COMPOSE_DIR/.env" ] && bash "$cfg/generate-versions-env.sh" "$COMPOSE_DIR/.env" "$cfg/versions.json"; then
            echo "[FIX] rigenerato $cfg/versions.json."
        else
            echo '{}' > "$cfg/versions.json"
            echo "[ATTENZIONE] versions.json non generabile da .env: creato '{}' (pagina /versions vuota)."
        fi
    fi
    # Apache nel container gira come utente non-root: i file montati devono essere leggibili da tutti
    chmod a+r "$cfg/versions.json" "$FLAG_FILE" 2>/dev/null || true
}
