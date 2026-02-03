#!/bin/bash

# Script per convertire DOCX in formato Antora con AsciiDoc
# Usage: ./docx-to-antora.sh input.docx [module-name]

set -e

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Determina la directory root del progetto
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# Se lo script è in una sottocartella (es. scripts/), cerca la root
if [ ! -f "$PROJECT_ROOT/antora-playbook.yml" ] && [ ! -d "$PROJECT_ROOT/docs" ]; then
    # Prova a risalire di un livello
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

echo -e "${BLUE}Project root: $PROJECT_ROOT${NC}"

# Verifica argomenti
if [ $# -lt 1 ]; then
    echo -e "${RED}Errore: Specifica il file DOCX da convertire${NC}"
    echo "Usage: $0 input.docx [module-name]"
    echo "Example: $0 documento.docx ROOT"
    exit 1
fi

INPUT_FILE="$1"
MODULE_NAME="${2:-ROOT}"
TEMP_DIR="$PROJECT_ROOT/temp_conversion_$$"
ANTORA_BASE="$PROJECT_ROOT/docs/modules/$MODULE_NAME"

# Se il file di input è un path relativo, rendilo assoluto
if [[ "$INPUT_FILE" != /* ]]; then
    INPUT_FILE="$(pwd)/$INPUT_FILE"
fi

# Verifica che il file esista
if [ ! -f "$INPUT_FILE" ]; then
    echo -e "${RED}Errore: File $INPUT_FILE non trovato${NC}"
    exit 1
fi

# Verifica pandoc
if ! command -v pandoc &> /dev/null; then
    echo -e "${RED}Errore: Pandoc non è installato${NC}"
    echo "Installa con: sudo apt-get install pandoc (Linux) o brew install pandoc (macOS)"
    exit 1
fi

# Verifica versione pandoc
PANDOC_VERSION=$(pandoc --version | head -n1 | awk '{print $2}')
echo -e "${BLUE}Versione Pandoc: $PANDOC_VERSION${NC}"

# Estrai nome file senza estensione
BASENAME=$(basename "$INPUT_FILE" .docx)
OUTPUT_FILE="${BASENAME}.adoc"

echo -e "${GREEN}=== Conversione DOCX to Antora AsciiDoc ===${NC}"
echo "Project root: $PROJECT_ROOT"
echo "Input: $INPUT_FILE"
echo "Output: $OUTPUT_FILE"
echo "Module: $MODULE_NAME"
echo "Destination: $ANTORA_BASE"
echo ""

# Cambia nella directory del progetto
cd "$PROJECT_ROOT"

# Crea directory temporanea
mkdir -p "$TEMP_DIR"

# Step 1: Converti DOCX in AsciiDoc ed estrai immagini
echo -e "${YELLOW}[1/6] Conversione DOCX → AsciiDoc...${NC}"
pandoc "$INPUT_FILE" \
    -f docx \
    -t asciidoc \
    --wrap=none \
    --extract-media="$TEMP_DIR" \
    -o "$TEMP_DIR/$OUTPUT_FILE"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Conversione completata${NC}"
else
    echo -e "${RED}✗ Errore durante la conversione${NC}"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Step 2: Verifica/crea struttura docs base
echo -e "${YELLOW}[2/6] Verifica struttura base...${NC}"
if [ ! -d "$PROJECT_ROOT/docs" ]; then
    echo -e "${BLUE}Cartella docs/ non trovata, la creo...${NC}"
    mkdir -p "$PROJECT_ROOT/docs"

    # Crea antora.yml se non esiste
    if [ ! -f "$PROJECT_ROOT/docs/antora.yml" ]; then
        cat > "$PROJECT_ROOT/docs/antora.yml" << 'EOF'
name: docs
title: IRCCS Docker Documentation
version: 'main'
nav:
  - modules/ROOT/nav.adoc
  - modules/microservices/nav.adoc
  - modules/configuration/nav.adoc
  - modules/deployment/nav.adoc
EOF
        echo -e "${GREEN}✓ Creato docs/antora.yml${NC}"
    fi
fi

# Verifica estrazione immagini
echo -e "${YELLOW}[3/6] Verifica estrazione immagini...${NC}"
echo -e "${BLUE}Contenuto di $TEMP_DIR:${NC}"
find "$TEMP_DIR" -type f -o -type d | sort

# Step 4: Crea struttura Antora
echo -e "${YELLOW}[4/6] Creazione struttura Antora...${NC}"
mkdir -p "$ANTORA_BASE/pages"
mkdir -p "$ANTORA_BASE/images"
mkdir -p "$ANTORA_BASE/examples"

# Crea nav.adoc se non esiste
if [ ! -f "$ANTORA_BASE/nav.adoc" ]; then
    if [ "$MODULE_NAME" = "ROOT" ]; then
        cat > "$ANTORA_BASE/nav.adoc" << 'EOF'
* xref:index.adoc[Home]
EOF
    else
        cat > "$ANTORA_BASE/nav.adoc" << EOF
.$MODULE_NAME
EOF
    fi
    echo -e "${GREEN}✓ Creato $ANTORA_BASE/nav.adoc${NC}"
fi

echo -e "${GREEN}✓ Struttura creata in: $ANTORA_BASE${NC}"

# Step 5: Sposta e rinomina immagini
echo -e "${YELLOW}[5/6] Gestione immagini...${NC}"
IMAGE_COUNT=0

# Cerca immagini in tutte le possibili location
for search_path in "$TEMP_DIR/media" "$TEMP_DIR" "$TEMP_DIR"/*; do
    if [ -d "$search_path" ]; then
        for ext in png jpg jpeg gif svg webp bmp; do
            while IFS= read -r -d '' img; do
                if [ -f "$img" ]; then
                    IMG_NAME=$(basename "$img")
                    echo -e "${BLUE}  Trovata: $IMG_NAME${NC}"
                    cp "$img" "$ANTORA_BASE/images/"
                    ((IMAGE_COUNT++))
                fi
            done < <(find "$search_path" -maxdepth 1 -type f -iname "*.$ext" -print0)
        done
    fi
done

if [ $IMAGE_COUNT -gt 0 ]; then
    echo -e "${GREEN}✓ $IMAGE_COUNT immagini estratte${NC}"
    echo -e "${BLUE}Immagini in $ANTORA_BASE/images/:${NC}"
    ls -lh "$ANTORA_BASE/images/"
else
    echo -e "${YELLOW}⚠ Nessuna immagine trovata${NC}"
    echo -e "${BLUE}Verifica se il DOCX contiene immagini embedded${NC}"
fi

# Step 6: Sistema riferimenti immagini nel file AsciiDoc
echo -e "${YELLOW}[6/6] Aggiornamento riferimenti immagini...${NC}"
if [ -f "$TEMP_DIR/$OUTPUT_FILE" ]; then
    # Mostra i riferimenti originali alle immagini
    echo -e "${BLUE}Riferimenti immagini nel file:${NC}"
    grep -n "image::" "$TEMP_DIR/$OUTPUT_FILE" || echo "Nessun riferimento image:: trovato"

    # Backup del file originale
    cp "$TEMP_DIR/$OUTPUT_FILE" "$TEMP_DIR/${OUTPUT_FILE}.backup"

    # Rimuovi vari pattern di path dalle immagini
    sed -i.bak 's|image::media/|image::|g' "$TEMP_DIR/$OUTPUT_FILE"
    sed -i.bak 's|image::'"$TEMP_DIR"'/media/|image::|g' "$TEMP_DIR/$OUTPUT_FILE"
    sed -i.bak 's|image::'"$TEMP_DIR"'/|image::|g' "$TEMP_DIR/$OUTPUT_FILE"
    sed -i.bak 's|image::\./|image::|g' "$TEMP_DIR/$OUTPUT_FILE"

    # Aggiungi header Antora se non presente
    if ! grep -q "^= " "$TEMP_DIR/$OUTPUT_FILE"; then
        cat > "$TEMP_DIR/temp_header.adoc" << EOF
= ${BASENAME}
:navtitle: ${BASENAME}

EOF
        cat "$TEMP_DIR/$OUTPUT_FILE" >> "$TEMP_DIR/temp_header.adoc"
        mv "$TEMP_DIR/temp_header.adoc" "$TEMP_DIR/$OUTPUT_FILE"
    fi

    # Mostra i riferimenti aggiornati
    echo -e "${BLUE}Riferimenti dopo la correzione:${NC}"
    grep -n "image::" "$TEMP_DIR/$OUTPUT_FILE" || echo "Nessun riferimento trovato"

    echo -e "${GREEN}✓ Riferimenti aggiornati${NC}"
fi

# Sposta file finale
mv "$TEMP_DIR/$OUTPUT_FILE" "$ANTORA_BASE/pages/"
echo -e "${GREEN}✓ File spostato in $ANTORA_BASE/pages/$OUTPUT_FILE${NC}"

# Aggiorna nav.adoc se necessario
if ! grep -q "$OUTPUT_FILE" "$ANTORA_BASE/nav.adoc"; then
    echo "* xref:$OUTPUT_FILE[$BASENAME]" >> "$ANTORA_BASE/nav.adoc"
    echo -e "${GREEN}✓ Aggiunto a nav.adoc${NC}"
fi

# Cleanup
rm -rf "$TEMP_DIR"
echo -e "${GREEN}✓ File temporanei rimossi${NC}"

echo ""
echo -e "${GREEN}=== Conversione completata! ===${NC}"
echo ""
echo "Struttura creata:"
echo "  📄 $ANTORA_BASE/pages/$OUTPUT_FILE"
if [ $IMAGE_COUNT -gt 0 ]; then
    echo "  🖼  $ANTORA_BASE/images/ ($IMAGE_COUNT immagini)"
fi
echo ""

if [ $IMAGE_COUNT -eq 0 ]; then
    echo -e "${YELLOW}ATTENZIONE: Nessuna immagine trovata!${NC}"
    echo "Possibili cause:"
    echo "  1. Il DOCX non contiene immagini embedded"
    echo "  2. Le immagini sono collegate esternamente (non embedded)"
    echo ""
fi

echo "Prossimi passi:"
echo "  1. Verifica il file: $ANTORA_BASE/pages/$OUTPUT_FILE"
if [ $IMAGE_COUNT -gt 0 ]; then
    echo "  2. Controlla le immagini in: $ANTORA_BASE/images/"
fi
echo "  3. Il file è stato aggiunto automaticamente a nav.adoc"
echo "  4. Esegui: cd $PROJECT_ROOT && npm run docs:build"
echo ""