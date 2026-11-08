#!/usr/bin/env python3
"""
Controlla RainViewer e stampa su stdout un JSON con l'esito.

Exit code:
  0 = controllo riuscito (vedi il campo "pioggia" nel JSON)
  1 = errore reale (rete, API, parsing)
"""

import json
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

# ── Configurazione ────────────────────────────────────────────────
LAT = 41.8947
LON = 12.49348
SOGLIA_BYTES = 3000
TIMEOUT = 10
USER_AGENT = "HomeAssistant-Script/1.0"
# ─────────────────────────────────────────────────────────────────


def fetch(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return resp.read()


def check_rain() -> dict:
    data = json.loads(fetch("https://api.rainviewer.com/public/weather-maps.json"))

    host = data["host"]
    past_frames = data["radar"]["past"]
    if not past_frames:
        raise ValueError("Nessun frame radar disponibile")

    # Controlla gli ultimi 2 frame (ultimi ~20 minuti)
    hits = 0
    for frame in past_frames[-2:]:
        tile_url = f"{host}{frame['path']}/256/6/{LAT}/{LON}/2/1_1.png"
        if len(fetch(tile_url)) > SOGLIA_BYTES:
            hits += 1

    frame_time = datetime.fromtimestamp(past_frames[-1]["time"], tz=timezone.utc)
    minuti_fa = int((datetime.now(tz=timezone.utc) - frame_time).total_seconds() / 60)

    return {"pioggia": hits >= 1, "frame_minuti_fa": minuti_fa}


if __name__ == "__main__":
    try:
        print(json.dumps(check_rain()))
        sys.exit(0)
    except Exception as e:
        print(f"❌ Errore: {e}", file=sys.stderr)
        sys.exit(1)
