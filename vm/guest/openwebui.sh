#!/usr/bin/env bash
# Executed INSIDE the guest, as root. Starts Open WebUI in a container.
set -Eeuo pipefail

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1
APP_HOME="/home/adm/openwebui"
COMPOSE="${APP_HOME}/compose.yaml"
RECREATE="${AILOCAL_RECREATE:-0}"
IP="$(hostname -I | awk '{print $1}')"
ok()    { printf '[guest/webui] [OK]      %s\n' "$*"; }
fait()  { printf '[guest/webui] [DONE]    %s\n' "$*"; }
echec() { printf "[guest/webui] [FAIL]    %s\n" "$*"; }
die()   { echec "$*"; exit 1; }

running() { [[ "$(docker inspect -f '{{.State.Running}}' open-webui 2>/dev/null || true)" == "true" ]]; }
healthy() { curl -fsS --max-time 5 "http://${IP}:3000/health" >/dev/null 2>&1; }

ready() {
  local deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    if healthy; then ok "Open WebUI responds on ${IP}:3000"; return 0; fi
    sleep 3
  done
  die "Open WebUI does not respond on ${IP}:3000; see docker logs open-webui"
}

[[ -f "$COMPOSE" ]] || die "compose missing: ${COMPOSE}"
install -d -m 0755 -o adm -g adm "${APP_HOME}/data"

if (( CHECK )); then
  running || { echec "open-webui container stopped"; exit 1; }
  healthy || { echec "Open WebUI does not respond on ${IP}:3000"; exit 1; }
  ok "open-webui container active and API compliant"
  exit 0
fi

if running; then
  if [[ "$RECREATE" == "1" ]]; then
    docker compose -f "$COMPOSE" up -d --force-recreate
    fait "open-webui container recreated (compose changed)"
  else
    ok "open-webui container already active"
  fi
else
  docker compose -f "$COMPOSE" up -d
  fait "open-webui container started"
fi
ready
