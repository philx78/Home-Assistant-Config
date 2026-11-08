#!/bin/sh
# kblue_login.sh - Login al KBlue che NON sovrascrive il cookie buono se il login fallisce.
#
# Il login viene fatto su un file temporaneo. Solo se il KBlue risponde "lgn":0 il file
# temporaneo sostituisce /config/kblue_site_session_raw.txt. Se il login e' rifiutato
# (es. {"lgn":-3,"sessions":8}, troppe sessioni aperte) il cookie in uso resta quello di prima.
#
# Credenziali: file /config/.kblue_credentials con due righe (utente, password), chmod 600.
#
# Codici di uscita: 0 ok | 1 login rifiutato o KBlue non raggiungibile | 2 credenziali mancanti

URL="http://192.168.1.54:50080/authorize"
COOKIE_FILE="/config/kblue_site_session_raw.txt"
CRED_FILE="/config/.kblue_credentials"

[ -r "$CRED_FILE" ] || { echo "manca $CRED_FILE" >&2; exit 2; }
KB_USER=$(sed -n 1p "$CRED_FILE")
KB_PASS=$(sed -n 2p "$CRED_FILE")
[ -n "$KB_USER" ] && [ -n "$KB_PASS" ] || { echo "credenziali vuote in $CRED_FILE" >&2; exit 2; }

TMP=$(mktemp /tmp/kblue_login.XXXXXX) || exit 1
OUT=$(curl -s -m 10 -c "$TMP" -X POST -H "Content-Type: application/json" \
  -d "{\"authorize\":1,\"user\":\"$KB_USER\",\"password\":\"$KB_PASS\",\"type\":0,\"redirect\":\"index.html\"}" \
  "$URL")

case "$OUT" in
  *'"lgn":0'*)
    cp "$TMP" "$COOKIE_FILE" && rm -f "$TMP"
    echo "login ok"
    ;;
  *)
    rm -f "$TMP"
    echo "login rifiutato: $OUT" >&2
    exit 1
    ;;
esac
