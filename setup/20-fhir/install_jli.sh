#!/bin/bash

# Controllo parametro URL
if [ $# -lt 1 ]; then
  echo "Uso: $0 <url>"
  exit 1
fi

API_URL=$1

# Path assoluto della cartella dove risiede lo script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Nome del file JSON (modifica qui se diverso)
JSON_FILE="$SCRIPT_DIR/J-LI_Batch.json"

# Controllo esistenza file
if [ ! -f "$JSON_FILE" ]; then
  echo "File JSON non trovato: $JSON_FILE"
  exit 1
fi

# Esecuzione chiamata
echo "Inviando POST a $API_URL con payload da $JSON_FILE..."
curl -s -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d @"$JSON_FILE" \
  -w "\n\nStatus: %{http_code}\n"

# Fine