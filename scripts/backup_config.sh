#!/usr/bin/env bash
# Backup on-demand della configurazione di Home Assistant:
# file YAML + script custom, in un tar.gz con checksum e rotazione per numero ed età.
# Percorso consigliato: /config/scripts/backup_config.sh  (chmod +x)
#
# Variabili sovrascrivibili:
#   HA_BACKUP_DIR              destinazione dei backup        (default: $HA_CONFIG_DIR/backups_config)
#   HA_CONFIG_DIR              directory di configurazione    (default: /config)
#   HA_BACKUP_INCLUDE_SECRETS  yes|no: includere secrets.yaml (default: yes)
#   HA_BACKUP_EXTRA_DIRS       cartelle (relative a HA_CONFIG_DIR, separate da spazio)
#                              di cui salvare tutti i file    (default: scripts)
#
# Politica di svecchiamento (backup ordinati dal più recente):
#   HA_BACKUP_KEEP_MIN         i più recenti N non vengono mai eliminati      (default: 5)
#   HA_BACKUP_MAX_AGE_DAYS     oltre i KEEP_MIN, elimina quelli più vecchi di N giorni (default: 30)
#   HA_BACKUP_KEEP             tetto massimo di backup conservati             (default: 30)

set -euo pipefail

CONFIG_DIR="${HA_CONFIG_DIR:-/config}"
BACKUP_DIR="${HA_BACKUP_DIR:-$CONFIG_DIR/backups_config}"
INCLUDE_SECRETS="${HA_BACKUP_INCLUDE_SECRETS:-yes}"
EXTRA_DIRS="${HA_BACKUP_EXTRA_DIRS:-scripts}"
KEEP_MIN="${HA_BACKUP_KEEP_MIN:-5}"
MAX_AGE_DAYS="${HA_BACKUP_MAX_AGE_DAYS:-30}"
KEEP="${HA_BACKUP_KEEP:-30}"

# Sanificazione dei parametri di retention
[ "$KEEP_MIN" -ge 1 ] 2>/dev/null || KEEP_MIN=1
[ "$KEEP" -ge "$KEEP_MIN" ] 2>/dev/null || KEEP="$KEEP_MIN"
[ "$MAX_AGE_DAYS" -ge 1 ] 2>/dev/null || MAX_AGE_DAYS=30

LOCK_FILE="/tmp/ha_config_backup.lock"
TS="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="$BACKUP_DIR/ha-config-$TS.tar.gz"
TMP_ARCHIVE="$ARCHIVE.part"
FILE_LIST="$(mktemp)"

cleanup() { rm -f "$FILE_LIST" "$TMP_ARCHIVE"; }
trap cleanup EXIT

# Evita esecuzioni concorrenti (doppio click sul pulsante)
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "ERRORE: un backup è già in corso"
  exit 1
fi

[ -d "$CONFIG_DIR" ] || { echo "ERRORE: $CONFIG_DIR non esiste"; exit 1; }

umask 077
mkdir -p "$BACKUP_DIR"
cd "$CONFIG_DIR"

# Elenco dei file YAML, escludendo cartelle non rilevanti
FIND_ARGS=(
  . \(
    -path ./.storage -o -path ./custom_components -o -path ./deps
    -o -path ./.git -o -path ./www -o -path ./tts -o -path ./node_modules
    -o -path ./.cloud -o -path "./$(basename "$BACKUP_DIR")"
  \) -prune -o
  -type f \( -name '*.yaml' -o -name '*.yml' \)
)
if [ "$INCLUDE_SECRETS" != "yes" ]; then
  FIND_ARGS+=( ! -name secrets.yaml )
fi
FIND_ARGS+=( -print )

find "${FIND_ARGS[@]}" > "$FILE_LIST"

# Script custom e file di supporto (escluse cache Python)
for extra in $EXTRA_DIRS; do
  if [ -d "./$extra" ]; then
    find "./$extra" -type f ! -name '*.pyc' ! -path '*/__pycache__/*' -print >> "$FILE_LIST"
  fi
done
# Elimina eventuali duplicati (es. yaml dentro scripts/)
sort -u -o "$FILE_LIST" "$FILE_LIST"

N_FILES="$(wc -l < "$FILE_LIST" | tr -d ' ')"
if [ "$N_FILES" -eq 0 ]; then
  echo "ERRORE: nessun file trovato in $CONFIG_DIR"
  exit 1
fi

# Creazione archivio (su file temporaneo, poi rename atomico)
tar -T "$FILE_LIST" -czf "$TMP_ARCHIVE"

# Verifica integrità
if ! tar -tzf "$TMP_ARCHIVE" > /dev/null; then
  echo "ERRORE: archivio corrotto, backup scartato"
  exit 1
fi

mv "$TMP_ARCHIVE" "$ARCHIVE"
( cd "$BACKUP_DIR" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256" )

# --- Svecchiamento ---------------------------------------------------------
# Ordine dal più recente. Regole, in sequenza:
#  1) i primi KEEP_MIN non vengono mai eliminati
#  2) oltre il KEEP-esimo: eliminati
#  3) tra KEEP_MIN e KEEP: eliminati se più vecchi di MAX_AGE_DAYS
# L'età si ricava dal timestamp nel nome file (non dalla data di modifica).
cd "$BACKUP_DIR"
CUTOFF="$(date -d "@$(( $(date +%s) - MAX_AGE_DAYS * 86400 ))" +%Y%m%d-%H%M%S 2>/dev/null || true)"

DELETED=0
i=0
while read -r f; do
  i=$((i + 1))
  ts="${f#ha-config-}"
  ts="${ts%.tar.gz}"
  remove=no
  if [ "$i" -le "$KEEP_MIN" ]; then
    remove=no
  elif [ "$i" -gt "$KEEP" ]; then
    remove=yes
  elif [ -n "$CUTOFF" ] && [[ "$ts" < "$CUTOFF" ]]; then
    remove=yes
  fi
  if [ "$remove" = "yes" ]; then
    rm -f -- "$f" "$f.sha256"
    DELETED=$((DELETED + 1))
  fi
done < <(ls -1t ha-config-*.tar.gz 2>/dev/null)

# Rimuove checksum orfani (archivio già eliminato a mano)
for s in ha-config-*.tar.gz.sha256; do
  [ -e "$s" ] || continue
  [ -e "${s%.sha256}" ] || rm -f -- "$s"
done

SIZE="$(du -h "$ARCHIVE" | cut -f1)"
N_BACKUPS="$(ls -1 ha-config-*.tar.gz | wc -l | tr -d ' ')"
echo "OK: $N_FILES file (YAML + script) -> $(basename "$ARCHIVE") ($SIZE). Backup presenti: $N_BACKUPS, eliminati: $DELETED (min $KEEP_MIN, max $KEEP, età max ${MAX_AGE_DAYS}g)"
