#!/bin/bash

# Installer, aggiornamento e avvio della Dashboard Portafoglio.
# Repository GitHub: Msantelli-dev/Dashboard_Portafoglio

REPO="Msantelli-dev/Dashboard_Portafoglio"
ASSET_NAME="Dashboard_Portafoglio_Locale.zip"
APP_DIR="$HOME/Dashboard_Portafoglio"
API_URL="https://api.github.com/repos/$REPO/releases/latest"
LOCAL_URL="http://127.0.0.1:8765"
PORT="8765"

pause_and_exit() {
  echo
  read -r -p "Premi Invio per chiudere..."
  exit "${1:-1}"
}

if ! command -v python3 >/dev/null 2>&1; then
  echo "Errore: Python 3 non e installato."
  echo "Installa Python 3 e riprova."
  pause_and_exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Errore: curl non e disponibile su questo Mac."
  pause_and_exit 1
fi

if ! command -v unzip >/dev/null 2>&1; then
  echo "Errore: unzip non e disponibile su questo Mac."
  pause_and_exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dashboard-portafoglio.XXXXXX")" || exit 1
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

echo "Controllo aggiornamenti Dashboard Portafoglio..."

RELEASE_JSON="$TMP_DIR/release.json"
if ! curl -fsSL \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "$API_URL" -o "$RELEASE_JSON"; then
  echo "Non riesco a leggere l'ultima Release GitHub."
  echo "Verifica la connessione e che il repository abbia almeno una Release pubblicata."
  pause_and_exit 1
fi

LATEST_TAG="$(python3 - "$RELEASE_JSON" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
print(str(payload.get("tag_name") or "").strip())
PY
)"

ASSET_URL="$(python3 - "$RELEASE_JSON" "$ASSET_NAME" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
name = sys.argv[2]
for asset in payload.get("assets", []):
    if asset.get("name") == name:
        print(asset.get("browser_download_url") or "")
        break
PY
)"

if [ -z "$LATEST_TAG" ]; then
  echo "La Release piu recente non contiene un tag valido."
  pause_and_exit 1
fi

if [ -z "$ASSET_URL" ]; then
  echo "Nella Release $LATEST_TAG non trovo l'asset:"
  echo "$ASSET_NAME"
  echo "Carica lo ZIP con questo nome esatto e riprova."
  pause_and_exit 1
fi

LATEST_VERSION="${LATEST_TAG#v}"
LOCAL_VERSION=""
if [ -f "$APP_DIR/VERSION" ]; then
  LOCAL_VERSION="$(tr -d '[:space:]' < "$APP_DIR/VERSION")"
fi

NEEDS_UPDATE=0
if [ ! -f "$APP_DIR/dashboard_server.py" ] || [ ! -f "$APP_DIR/dashboard_portafoglio_locale.html" ]; then
  NEEDS_UPDATE=1
elif [ "$LOCAL_VERSION" != "$LATEST_VERSION" ]; then
  NEEDS_UPDATE=1
fi

stop_running_dashboard() {
  if curl -fsS --max-time 1 "$LOCAL_URL/api/status" >/dev/null 2>&1; then
    PID=""
    if [ -f "$APP_DIR/.dashboard_server.pid" ]; then
      PID="$(tr -d '[:space:]' < "$APP_DIR/.dashboard_server.pid")"
      if ! kill -0 "$PID" >/dev/null 2>&1; then
        PID=""
      fi
    fi
    if [ -z "$PID" ] && command -v lsof >/dev/null 2>&1; then
      PID="$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | head -1)"
    fi
    if [ -n "$PID" ]; then
      echo "Arresto la versione precedente..."
      kill "$PID" >/dev/null 2>&1 || true
      COUNT=0
      while kill -0 "$PID" >/dev/null 2>&1 && [ "$COUNT" -lt 20 ]; do
        sleep 0.2
        COUNT=$((COUNT + 1))
      done
    fi
  fi
}

if [ "$NEEDS_UPDATE" -eq 1 ]; then
  echo "Installazione/aggiornamento alla versione $LATEST_VERSION..."
  ZIP_FILE="$TMP_DIR/$ASSET_NAME"
  UNPACK_DIR="$TMP_DIR/unpacked"
  mkdir -p "$UNPACK_DIR"

  if ! curl -fL --retry 2 --connect-timeout 15 "$ASSET_URL" -o "$ZIP_FILE"; then
    echo "Download dell'aggiornamento non riuscito."
    pause_and_exit 1
  fi

  if ! unzip -q "$ZIP_FILE" -d "$UNPACK_DIR"; then
    echo "Lo ZIP scaricato non e valido."
    pause_and_exit 1
  fi

  SERVER_SOURCE="$(find "$UNPACK_DIR" -type f -name dashboard_server.py | head -1)"
  if [ -z "$SERVER_SOURCE" ]; then
    echo "Nello ZIP non trovo dashboard_server.py."
    pause_and_exit 1
  fi
  SOURCE_DIR="$(dirname "$SERVER_SOURCE")"

  if [ ! -f "$SOURCE_DIR/dashboard_portafoglio_locale.html" ]; then
    echo "Nello ZIP non trovo dashboard_portafoglio_locale.html."
    pause_and_exit 1
  fi

  stop_running_dashboard
  mkdir -p "$APP_DIR"

  cp "$SOURCE_DIR/dashboard_server.py" "$APP_DIR/dashboard_server.py"
  cp "$SOURCE_DIR/dashboard_portafoglio_locale.html" "$APP_DIR/dashboard_portafoglio_locale.html"
  if [ -f "$SOURCE_DIR/LEGGIMI.txt" ]; then
    cp "$SOURCE_DIR/LEGGIMI.txt" "$APP_DIR/LEGGIMI.txt"
  fi
  printf '%s\n' "$LATEST_VERSION" > "$APP_DIR/VERSION"
  chmod 700 "$APP_DIR/dashboard_server.py" 2>/dev/null || true
  echo "Aggiornamento completato."
else
  echo "Versione $LOCAL_VERSION gia aggiornata."
fi

if curl -fsS --max-time 1 "$LOCAL_URL/api/status" >/dev/null 2>&1; then
  echo "La dashboard e gia avviata."
  /usr/bin/open "$LOCAL_URL"
  exit 0
fi

echo "Avvio della dashboard locale..."
nohup /usr/bin/env python3 "$APP_DIR/dashboard_server.py" --no-browser \
  > "$APP_DIR/dashboard_server.log" 2>&1 &
SERVER_PID=$!
printf '%s\n' "$SERVER_PID" > "$APP_DIR/.dashboard_server.pid"

COUNT=0
while [ "$COUNT" -lt 30 ]; do
  if curl -fsS --max-time 1 "$LOCAL_URL/api/status" >/dev/null 2>&1; then
    echo "Dashboard avviata: $LOCAL_URL"
    /usr/bin/open "$LOCAL_URL"
    exit 0
  fi
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    break
  fi
  sleep 0.3
  COUNT=$((COUNT + 1))
done

echo "Il server non si e avviato correttamente."
echo "Controlla il file: $APP_DIR/dashboard_server.log"
pause_and_exit 1
