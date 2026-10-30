#!/usr/bin/env bash
# Exécuté DANS l'invité, en root. Démarre Ollama en conteneur avec le GPU.
set -Eeuo pipefail

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1
APP_HOME="/home/adm/ollama"
COMPOSE="${APP_HOME}/compose.yaml"
RECREATE="${AILOCAL_RECREATE:-0}"
ok()    { printf '[invité/ollama] [OK]      %s\n' "$*"; }
fait()  { printf '[invité/ollama] [FAIT]    %s\n' "$*"; }
echec() { printf "[invité/ollama] [ÉCHEC]   %s\n" "$*"; }
die()   { echec "$*"; exit 1; }

running() { [[ "$(docker inspect -f '{{.State.Running}}' ollama 2>/dev/null || true)" == "true" ]]; }
cuda_ready() { docker exec ollama sh -c 'ldconfig -p 2>/dev/null | grep -q "libcuda.so.1"' >/dev/null 2>&1; }
gpu_ready() { docker exec ollama nvidia-smi -L >/dev/null 2>&1 && cuda_ready; }
api_ready() { docker exec ollama ollama list >/dev/null 2>&1; }

ready() {
  local deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    if api_ready && gpu_ready; then ok "API Ollama prête, GPU visible dans le conteneur"; return 0; fi
    sleep 3
  done
  die "Ollama ne devient pas prêt (conteneur, API ou GPU) ; voir docker logs ollama"
}

[[ -f "$COMPOSE" ]] || die "compose absent : ${COMPOSE}"
install -d -m 0755 -o adm -g adm "${APP_HOME}/models"

if (( CHECK )); then
  running || { echec "conteneur ollama arrêté"; exit 1; }
  api_ready || { echec "API Ollama ne répond pas dans le conteneur"; exit 1; }
  gpu_ready || { echec "GPU ou CUDA absent du conteneur (nvidia-smi / libcuda)"; exit 1; }
  ok "conteneur ollama actif, API et GPU/CUDA conformes"
  exit 0
fi

if running; then
  if [[ "$RECREATE" == "1" ]] || ! gpu_ready; then
    docker compose -f "$COMPOSE" up -d --force-recreate
    fait "conteneur ollama recréé (compose ou accès GPU modifié)"
  else
    ok "conteneur ollama déjà actif"
  fi
else
  docker compose -f "$COMPOSE" up -d
  fait "conteneur ollama démarré"
fi
ready
