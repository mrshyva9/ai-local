#!/usr/bin/env bash
# Executed INSIDE the guest, as root. Starts Ollama in a container with the GPU.
set -Eeuo pipefail

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1
APP_HOME="/home/adm/ollama"
COMPOSE="${APP_HOME}/compose.yaml"
RECREATE="${AILOCAL_RECREATE:-0}"
ok()    { printf '[guest/ollama] [OK]      %s\n' "$*"; }
fait()  { printf '[guest/ollama] [DONE]    %s\n' "$*"; }
echec() { printf "[guest/ollama] [FAIL]    %s\n" "$*"; }
die()   { echec "$*"; exit 1; }

running() { [[ "$(docker inspect -f '{{.State.Running}}' ollama 2>/dev/null || true)" == "true" ]]; }
cuda_ready() { docker exec ollama sh -c 'ldconfig -p 2>/dev/null | grep -q "libcuda.so.1"' >/dev/null 2>&1; }
gpu_ready() { docker exec ollama nvidia-smi -L >/dev/null 2>&1 && cuda_ready; }
api_ready() { docker exec ollama ollama list >/dev/null 2>&1; }

ready() {
  local deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    if api_ready && gpu_ready; then ok "Ollama API ready, GPU visible in the container"; return 0; fi
    sleep 3
  done
  die "Ollama does not become ready (container, API or GPU); see docker logs ollama"
}

[[ -f "$COMPOSE" ]] || die "compose missing: ${COMPOSE}"
install -d -m 0755 -o adm -g adm "${APP_HOME}/models"

if (( CHECK )); then
  running || { echec "ollama container stopped"; exit 1; }
  api_ready || { echec "Ollama API does not respond in the container"; exit 1; }
  gpu_ready || { echec "GPU or CUDA missing from the container (nvidia-smi / libcuda)"; exit 1; }
  ok "ollama container active, API and GPU/CUDA compliant"
  exit 0
fi

if running; then
  if [[ "$RECREATE" == "1" ]] || ! gpu_ready; then
    docker compose -f "$COMPOSE" up -d --force-recreate
    fait "ollama container recreated (compose or GPU access changed)"
  else
    ok "ollama container already active"
  fi
else
  docker compose -f "$COMPOSE" up -d
  fait "ollama container started"
fi
ready
