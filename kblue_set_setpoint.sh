#!/bin/bash
# /config/scripts/kblue_set_setpoint.sh
# Uso: kblue_set_setpoint.sh <ixogm> <setpoint>

IXOGM="$1"
SETPOINT="$2"

SESSION=$(grep 'session' /config/kblue_site_session_raw.txt | awk '{print $NF}')
USER=$(grep 'user' /config/kblue_site_session_raw.txt | awk '{print $NF}')

# 1. Leggi stato attuale
STATE=$(curl -s -X POST "http://192.168.1.54:50080/request_json" \
  -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
  -H "Cookie: user=$USER; session=$SESSION" \
  -d "command={\"cmd\":130,\"ixogm\":\"$IXOGM\",\"type\":0}")

# 2. Modifica mant e man
NEWSTATE=$(echo "$STATE" | sed "s/\"mant\":\"[^\"]*\"/\"mant\":\"$SETPOINT\"/" | sed 's/"man":false/"man":true/')

# 3. Invia
curl -s -X POST "http://192.168.1.54:50080/request_json" \
  -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
  -H "Cookie: user=$USER; session=$SESSION" \
  -d "command=$NEWSTATE"
