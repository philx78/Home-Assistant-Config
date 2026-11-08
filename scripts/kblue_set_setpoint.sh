#!/bin/bash
# kblue_set_setpoint.sh - Controlla un termostato KBlue (v6)
#
# Utilizzo:
#   Setpoint manuale:  kblue_set_setpoint.sh <ixogm> <temperatura>
#   Ripristino auto:   kblue_set_setpoint.sh <ixogm> auto
#   Accensione:        kblue_set_setpoint.sh <ixogm> on
#   Spegnimento:       kblue_set_setpoint.sh <ixogm> off
#
# Esempi (Salone):
#   kblue_set_setpoint.sh 0000008100000642 21.5
#   kblue_set_setpoint.sh 0000008100000642 auto
#   kblue_set_setpoint.sh 0000008100000642 on
#   kblue_set_setpoint.sh 0000008100000642 off
#
# Novita' della v3:
#   - ixm e ixv NON sono piu' scritti a mano: per auto/on/off lo script legge la voce
#     del termostato (cmd:20) e usa il suo "ixm" e gli ixv di S[0] (on/off) e S[12]
#     (flag manuale). L'ixm cambia da zona a zona (Salone = 1, Cam Francesco = 0):
#     con ixm sbagliato il comando finiva su un altro modulo.
#   - se la voce non si trova o un ixv e' 65535 (assente), NON si scrive nulla
#   - un eventuale terzo argomento (ixv) viene ignorato, con un avviso su stderr
#
# Novita' della v4:
#   - dopo ogni scrittura rilegge il termostato dal KBlue (cmd:20) finche' mostra il valore
#     atteso (max ~6 s) e termina con codice 3 se non lo vede: la conferma non dipende piu'
#     dai sensori REST di Home Assistant
#
# Novita' della v5:
#   - registro delle comunicazioni in /config/kblue_comandi.log (una riga per evento:
#     ora, pid, termostato, azione, risposta del KBlue troncata). Mai password ne' cookie.
#     Quando supera 200 KB viene ruotato in kblue_comandi.log.1
#   - la lettura del programma (cmd:130) viene ripetuta fino a 3 volte se il KBlue risponde
#     senza PRG (es. occupato o sessione non valida); e' una lettura, quindi e' sicuro
#   - se la lettura fallisce l'errore riporta l'ultima risposta del KBlue
#
# Novita' della v6:
#   - anche la lettura dell'elenco termostati (cmd:20), prima di auto/on/off, viene ripetuta
#     fino a 3 volte se il KBlue risponde senza il termostato richiesto
#
# Dalla v2: PRG verificato prima di scrivere il setpoint, ripetizione dopo 2 s,
# temperatura 15-25 °C arrotondata a 0.5, errori su stderr.
#
# Codici di uscita: 0 ok | 1 errore generico | 2 argomenti non validi | 3 non confermato dal KBlue

KBLUE_URL="http://192.168.1.54:50080/request_json"
COOKIE_FILE="/config/kblue_site_session_raw.txt"
TEMP_MIN=15
TEMP_MAX=25
LOG_FILE="/config/kblue_comandi.log"
LOG_MAX=204800

IXOGM="$1"
ACTION="$2"
IXV_ARG="$3"

# Registro delle comunicazioni (best effort: se non si puo' scrivere, si prosegue)
log() {
    if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_MAX" ]; then
        mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null
    fi
    printf '%s [%s] ixogm=%s azione=%s %s\n' "$(date '+%F %T')" "$$" "$IXOGM" "$ACTION" "$*" \
        >> "$LOG_FILE" 2>/dev/null || true
}

err() { log "ERRORE: $1"; echo "Errore: $1" >&2; exit "${2:-1}"; }


[ -z "$IXOGM" ] || [ -z "$ACTION" ] && err "uso: $0 <ixogm> <temperatura|auto|on|off>" 2

# POST verso KBlue con una ripetizione. $1 = valore del parametro "command"
kblue_post() {
    local out rc attempt
    for attempt in 1 2; do
        out=$(curl -s -f --max-time 10 \
                -b "$COOKIE_FILE" \
                -X POST \
                -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
                --data-urlencode "command=$1" \
                "$KBLUE_URL")
        rc=$?
        if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
            printf '%s' "$out"
            return 0
        fi
        log "richiesta fallita (tentativo $attempt): curl exit=$rc risposta='${out:0:150}'"
        [ "$attempt" -eq 1 ] && sleep 2
    done
    return 1
}

# Rilegge il termostato finche' V[indice] vale "atteso" (entro tolleranza).
# $1 = indice in V, $2 = valore atteso, $3 = tolleranza. Esce con 3 se non lo vede.
kblue_confirm() {
    local idx="$1" atteso="$2" tol="$3" lista val i ultimo=""
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        if lista=$(kblue_post '{"cmd":20,"schema":0,"idmp":14}'); then
            val=$(echo "$lista" | jq -r --arg o "$IXOGM" --argjson i "$idx" \
                '.OGGETTI[] | select(.ixogm==$o) | .V[$i]' 2>/dev/null | head -n 1)
            ultimo="$val"
            if awk -v v="$val" -v a="$atteso" -v t="$tol" \
                'BEGIN { exit !(v ~ /^-?[0-9]+([.][0-9]+)?$/ && v - a <= t && a - v <= t) }'; then
                log "confermato: V[$idx]=$val (atteso $atteso) al tentativo $i"
                return 0
            fi
        fi
        sleep 0.5 2>/dev/null || sleep 1
    done
    log "NON CONFERMATO: V[$idx]=${ultimo:-?} (atteso $atteso) dopo 12 letture"
    echo "Errore: non confermato dal KBlue: V[$idx]=${ultimo:-?} (atteso $atteso)" >&2
    return 3
}

# Scrive una variabile semplice (cmd:31) del termostato $IXOGM.
# $1 = quale ("onoff" o "manuale"), $2 = valore, $3 = indice in V da confermare (0 on/off, 12 manuale)
kblue_set_var() {
    local quale="$1" valore="$2" vidx="$3" lista riga ixm ixv_onoff ixv_man ixv
    # La lettura dell'elenco viene ripetuta fino a 3 volte: se il KBlue e' occupato o la
    # sessione non e' valida risponde senza OGGETTI (es. {"cmd":-19}). E' solo una lettura.
    local prova ultima=""
    riga=""
    for prova in 1 2 3; do
        if lista=$(kblue_post '{"cmd":20,"schema":0,"idmp":14}'); then
            riga=$(echo "$lista" | jq -r --arg o "$IXOGM" \
                '.OGGETTI[]? | select(.ixogm==$o) | [.ixm, .S[0], .S[12]] | @tsv' 2>/dev/null | head -n 1)
            [ -n "$riga" ] && break
            ultima="${lista:0:150}"
            log "cmd:20 senza il termostato (prova $prova): '${ultima}'"
        else
            ultima="nessuna risposta"
        fi
        sleep 1
    done
    [ -n "$riga" ] \
        || err "termostato $IXOGM non trovato nella risposta del KBlue dopo 3 prove, nessuna scrittura (ultima risposta: '${ultima:-nessuna}')"
    IFS=$'\t' read -r ixm ixv_onoff ixv_man <<< "$riga"

    for n in "$ixm" "$ixv_onoff" "$ixv_man"; do
        [[ "$n" =~ ^[0-9]+$ ]] || err "ixm/ixv non numerici per $IXOGM ('$riga'), nessuna scrittura"
    done
    if [ "$quale" = "onoff" ]; then ixv="$ixv_onoff"; else ixv="$ixv_man"; fi
    [ "$ixv" != "65535" ] || err "variabile '$quale' assente per $IXOGM, nessuna scrittura"

    if [ -n "$IXV_ARG" ] && [ "$IXV_ARG" != "$ixv" ]; then
        echo "Avviso: ixv passato ($IXV_ARG) ignorato, uso quello letto dal KBlue ($ixv, ixm=$ixm)" >&2
    fi

    # Scrittura ripetuta fino a 3 volte se il KBlue risponde occupato ({"cmd":-19}) o non
    # accetta il comando: impostare lo stesso valore piu' volte e' innocuo.
    local result="" w
    for w in 1 2 3; do
        if result=$(kblue_post "{\"cmd\":31,\"VARIABILI\":[{\"ixm\":${ixm},\"ixv\":${ixv},\"v\":\"${valore}\"}]}") \
            && echo "$result" | jq -e '.cmd == 0' >/dev/null 2>&1; then
            break
        fi
        log "cmd:31 non accettato (prova $w): '${result:0:150}'"
        sleep 1
    done
    log "cmd:31 ixm=${ixm} ixv=${ixv} v=${valore} -> ${result:0:150}"
    echo "$result"
    kblue_confirm "$vidx" "$valore" 0.01
}

log "inizio"
case "$ACTION" in
    auto) kblue_set_var manuale 0 12 ;;   # flag manuale a 0 -> torna al programma
    off)  kblue_set_var onoff 0 0 ;;     # flag on/off a 0
    on)   kblue_set_var onoff 1 0 ;;     # flag on/off a 1

    *)
        # === SETPOINT MANUALE: cmd:130 (leggi PRG) + cmd:131 con man:true ===
        TEMP="$ACTION"

        [[ "$TEMP" =~ ^[0-9]+(\.[0-9]+)?$ ]] || err "temperatura non valida: '$TEMP'" 2
        # Il setpoint KBlue va a passi di 0.5 °C: arrotonda al mezzo grado piu' vicino
        TEMP=$(awk -v t="$TEMP" 'BEGIN { printf "%.1f", int(t * 2 + 0.5) / 2 }')
        awk -v t="$TEMP" -v lo="$TEMP_MIN" -v hi="$TEMP_MAX" \
            'BEGIN { exit !(t >= lo && t <= hi) }' \
            || err "temperatura fuori range (${TEMP_MIN}-${TEMP_MAX}): $TEMP" 2

        PRG_RESPONSE=""
        ULTIMA=""
        for prova in 1 2 3; do
            if PRG_RESPONSE=$(kblue_post "{\"cmd\":130,\"ixogm\":\"${IXOGM}\",\"type\":0}") \
                && echo "$PRG_RESPONSE" | jq -e '.PRG != null' >/dev/null 2>&1; then
                break
            fi
            ULTIMA="${PRG_RESPONSE:0:150}"
            log "cmd:130 senza PRG valido (prova $prova): '${ULTIMA}'"
            PRG_RESPONSE=""
            sleep 1
        done
        [ -n "$PRG_RESPONSE" ] \
            || err "risposta cmd:130 senza PRG valido dopo 3 prove, scrittura annullata (ultima risposta: '${ULTIMA:-nessuna}')"

        WRITE_PAYLOAD=$(echo "$PRG_RESPONSE" | jq -c \
            --arg ixogm "$IXOGM" \
            --arg temp "$TEMP" \
            '{PRG: .PRG, cmd: 131, ixogm: $ixogm, man: true, mant: $temp}') \
            || err "impossibile costruire il payload"

        RESULT=$(kblue_post "$WRITE_PAYLOAD") || err "impossibile inviare il setpoint"
        log "cmd:131 mant=${TEMP} -> ${RESULT:0:150}"
        echo "$RESULT"
        kblue_confirm 10 "$TEMP" 0.26
        ;;
esac
