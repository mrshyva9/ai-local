#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/config.sh"
STEP="guest"
source "${ROOT}/common.sh"

CHECK=0
if [[ "${1:-}" == "check" ]]; then CHECK=1; MODE=check; VM="${2:-}"
elif [[ "${1:-}" == "status" ]]; then MODE=status; VM="${2:-}"
else MODE=up; VM="${1:-}"; fi
[[ -n "${VM_NAME[$VM]:-}" ]] || die "unknown VM: ${VM:-<empty>} (expected: ${VMS[*]})"

APP="${VM_APP[$VM]}"
STEP="guest/${APP}"
IP="${VM_IP[$VM]}"
REMOTE_DIR="${GUEST_HOME}/${APP}"
REMOTE_COMPOSE="${REMOTE_DIR}/compose.yaml"
CHANGED=0

render() {
  sed -e "s|__VM_IP__|${IP}|g" -e "s|__GUEST_HOME__|${GUEST_HOME}|g" \
    -e "s|__OLLAMA_IMAGE__|${OLLAMA_IMAGE}|g" -e "s|__OLLAMA_PORT__|${OLLAMA_PORT}|g" \
    -e "s|__OLLAMA_IP__|${VM_IP[ollama]}|g" -e "s|__WEBUI_IMAGE__|${WEBUI_IMAGE}|g" \
    -e "s|__WEBUI_PORT__|${WEBUI_PORT}|g" \
    -e "s|__WEBUI_INTERNAL_PORT__|${WEBUI_INTERNAL_PORT}|g" \
    "${ROOT}/vm/apps/${APP}.yaml"
}

ssh_ok() { timeout 15 ssh "${SSH_OPTS[@]}" "root@${IP}" true >/dev/null 2>&1; }

guest() {
  local script="$1"
  if (( CHECK )); then
    ssh "${SSH_OPTS[@]}" "root@${IP}" "bash -s -- --check" <"${ROOT}/vm/guest/${script}.sh"
  else
    ssh "${SSH_OPTS[@]}" "root@${IP}" "AILOCAL_RECREATE=${CHANGED} bash -s" \
      <"${ROOT}/vm/guest/${script}.sh"
  fi
}

sync_compose() {
  local local_sum remote_sum
  local_sum="$(render | sha256sum | cut -d' ' -f1)"
  remote_sum="$(ssh "${SSH_OPTS[@]}" "root@${IP}" \
    "sha256sum '${REMOTE_COMPOSE}' 2>/dev/null | cut -d' ' -f1" 2>/dev/null || true)"
  if [[ "$local_sum" == "$remote_sum" ]]; then
    ok "compose ${APP} up to date"
    return 0
  fi
  CHANGED=1
  if (( CHECK )); then
    echec "compose ${APP} missing or different in the VM"
    return 1
  fi
  render | ssh "${SSH_OPTS[@]}" "root@${IP}" \
    "install -d -m 0755 '${REMOTE_DIR}' && cat > '${REMOTE_COMPOSE}' && chown adm:adm '${REMOTE_DIR}' '${REMOTE_COMPOSE}'" ||
    { echec "copying compose ${APP} failed"; return 1; }
  fait "compose ${APP} installed in ${REMOTE_COMPOSE}"
}

wait_guest() {
  local deadline=$((SECONDS + 240))
  attente "waiting for ${VM_NAME[$VM]} to come back after reboot"
  while (( SECONDS < deadline )); do
    if ssh_ok; then ok "VM ${VM_NAME[$VM]} is back"; return 0; fi
    sleep 5
  done
  die "SSH does not come back on ${IP} after guest reboot"
}

ensure_nvidia() {
  local rc
  set +e
  guest nvidia
  rc=$?
  set -e
  if (( rc == 3 )); then
    attente "guest reboot to load the NVIDIA driver"
    ssh "${SSH_OPTS[@]}" "root@${IP}" "systemctl reboot" >/dev/null 2>&1 || true
    sleep 5
    wait_guest
    set +e
    guest nvidia
    rc=$?
    set -e
  fi
  (( rc == 0 )) || die "NVIDIA driver not operational in ${VM_NAME[$VM]}"
}

model_present() {
  curl -fsS --max-time 15 "http://${IP}:${OLLAMA_PORT}/api/tags" 2>/dev/null |
    python3 -c 'import json,sys
want = sys.argv[1]
for item in json.load(sys.stdin).get("models") or []:
    if (item.get("name") or item.get("model") or "") == want:
        sys.exit(0)
sys.exit(1)' "$MODEL" 2>/dev/null
}

ensure_model() {
  [[ "$MODEL" =~ ^[A-Za-z0-9._:/-]+$ ]] || die "invalid model name: ${MODEL}"
  if model_present; then ok "model ${MODEL} present"
  elif (( CHECK )); then echec "model ${MODEL} missing"; return 1
  else
    attente "downloading ${MODEL} into ${VM_NAME[ollama]} (several GB, once)"
    ssh "${SSH_OPTS[@]}" "root@${VM_IP[ollama]}" "docker exec ollama ollama pull '${MODEL}'" ||
      die "downloading ${MODEL} failed"
    model_present || die "model ${MODEL} still missing after download"
    fait "model ${MODEL} downloaded"
  fi
}

case "$MODE" in
  status)
    state="$(ssh "${SSH_OPTS[@]}" "root@${IP}" "docker inspect -f '{{.State.Status}}' '${VM_CONTAINER[$VM]}' 2>/dev/null" 2>/dev/null || true)"
    [[ -n "$state" ]] || state="unreachable"
    if [[ "$state" == "running" ]]; then ok "container ${VM_CONTAINER[$VM]} running"
    else echec "container ${VM_CONTAINER[$VM]}: ${state}"; fi
    if [[ "$APP" == "ollama" ]]; then
      if version="$(curl -fsS --max-time 5 "http://${IP}:${OLLAMA_PORT}/api/version" 2>/dev/null)"; then
        ok "Ollama API ${version}"
      else echec "Ollama API unreachable on ${IP}:${OLLAMA_PORT}"; fi
      if model_present; then ok "model ${MODEL} present"; else echec "model ${MODEL} missing"; fi
    else
      if curl -fsS --max-time 5 "http://${IP}:${WEBUI_PORT}/health" >/dev/null 2>&1; then
        ok "Open WebUI responds on http://${IP}:${WEBUI_PORT}"
      else echec "Open WebUI unreachable on ${IP}:${WEBUI_PORT}"; fi
    fi
    ;;
  check)
    ssh_ok || { echec "VM ${VM_NAME[$VM]} unreachable over SSH on ${IP}"; exit 1; }
    fail=0
    guest base || fail=1
    sync_compose || fail=1
    if [[ "${VM_GPU[$VM]}" == "1" ]]; then guest nvidia || fail=1; fi
    guest "$APP" || fail=1
    if [[ "$APP" == "ollama" ]]; then ensure_model || fail=1; fi
    (( fail == 0 )) || exit 1
    ;;
  up)
    ssh_ok || die "VM ${VM_NAME[$VM]} unreachable over SSH on ${IP}; run up first"
    guest base
    sync_compose || die "synchronizing compose ${APP} failed"
    if [[ "${VM_GPU[$VM]}" == "1" ]]; then ensure_nvidia; fi
    guest "$APP"
    if [[ "$APP" == "ollama" ]]; then ensure_model; fi
    ;;
esac
