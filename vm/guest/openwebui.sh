#!/usr/bin/env bash
# Exécuté DANS l'invité, en root. Démarre Open WebUI en conteneur.
set -Eeuo pipefail

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1
APP_HOME="/home/adm/openwebui"
COMPOSE="${APP_HOME}/compose.yaml"
RECREATE="${AILOCAL_RECREATE:-0}"
IP="$(hostname -I | awk '{print $1}')"
ok()    { printf '[invité/webui] [OK]      %s\n' "$*"; }
fait()  { printf '[invité/webui] [FAIT]    %s\n' "$*"; }
echec() { printf "[invité/webui] [ÉCHEC]   %s\n" "$*"; }
die()   { echec "$*"; exit 1; }

running() { [[ "$(docker inspect -f '{{.State.Running}}' open-webui 2>/dev/null || true)" == "true" ]]; }
healthy() { curl -fsS --max-time 5 "http://${IP}:3000/health" >/dev/null 2>&1; }

ready() {
  local deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    if healthy; then ok "Open WebUI répond sur ${IP}:3000"; return 0; fi
    sleep 3
  done
  die "Open WebUI ne répond pas sur ${IP}:3000 ; voir docker logs open-webui"
}

[[ -f "$COMPOSE" ]] || die "compose absent : ${COMPOSE}"
install -d -m 0755 -o adm -g adm "${APP_HOME}/data"

if (( CHECK )); then
  running || { echec "conteneur open-webui arrêté"; exit 1; }
  healthy || { echec "Open WebUI ne répond pas sur ${IP}:3000"; exit 1; }
  ok "conteneur open-webui actif et API conformes"
  exit 0
fi

if running; then
  if [[ "$RECREATE" == "1" ]]; then
    docker compose -f "$COMPOSE" up -d --force-recreate
    fait "conteneur open-webui recréé (compose modifié)"
  else
    ok "conteneur open-webui déjà actif"
  fi
else
  docker compose -f "$COMPOSE" up -d
  fait "conteneur open-webui démarré"
fi
ready
