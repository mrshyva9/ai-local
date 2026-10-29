#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/config.sh"
STEP="invité"
source "${ROOT}/common.sh"

CHECK=0
if [[ "${1:-}" == "check" ]]; then CHECK=1; MODE=check; VM="${2:-}"
elif [[ "${1:-}" == "status" ]]; then MODE=status; VM="${2:-}"
else MODE=up; VM="${1:-}"; fi
[[ -n "${VM_NAME[$VM]:-}" ]] || die "VM inconnue : ${VM:-<vide>} (attendu : ${VMS[*]})"

APP="${VM_APP[$VM]}"
STEP="invité/${APP}"
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
    ok "compose ${APP} à jour"
    return 0
  fi
  CHANGED=1
  if (( CHECK )); then
    echec "compose ${APP} absent ou différent dans la VM"
    return 1
  fi
  render | ssh "${SSH_OPTS[@]}" "root@${IP}" \
    "install -d -m 0755 '${REMOTE_DIR}' && cat > '${REMOTE_COMPOSE}' && chown adm:adm '${REMOTE_DIR}' '${REMOTE_COMPOSE}'" ||
    { echec "copie du compose ${APP} impossible"; return 1; }
  fait "compose ${APP} installé dans ${REMOTE_COMPOSE}"
}

wait_guest() {
  local deadline=$((SECONDS + 240))
  attente "attente du retour de ${VM_NAME[$VM]} après redémarrage"
  while (( SECONDS < deadline )); do
    if ssh_ok; then ok "VM ${VM_NAME[$VM]} revenue"; return 0; fi
    sleep 5
  done
  die "SSH ne revient pas sur ${IP} après redémarrage de l'invité"
}

ensure_nvidia() {
  local rc
  set +e
  guest nvidia
  rc=$?
  set -e
  if (( rc == 3 )); then
    attente "redémarrage de l'invité pour charger le pilote NVIDIA"
    ssh "${SSH_OPTS[@]}" "root@${IP}" "systemctl reboot" >/dev/null 2>&1 || true
    sleep 5
    wait_guest
    set +e
    guest nvidia
    rc=$?
    set -e
  fi
  (( rc == 0 )) || die "pilote NVIDIA non opérationnel dans ${VM_NAME[$VM]}"
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
  [[ "$MODEL" =~ ^[A-Za-z0-9._:/-]+$ ]] || die "nom de modèle invalide : ${MODEL}"
  if model_present; then ok "modèle ${MODEL} présent"
  elif (( CHECK )); then echec "modèle ${MODEL} absent"; return 1
  else
    attente "téléchargement de ${MODEL} dans ${VM_NAME[ollama]} (plusieurs Go, une fois)"
    ssh "${SSH_OPTS[@]}" "root@${VM_IP[ollama]}" "docker exec ollama ollama pull '${MODEL}'" ||
      die "téléchargement de ${MODEL} impossible"
    model_present || die "modèle ${MODEL} toujours absent après téléchargement"
    fait "modèle ${MODEL} téléchargé"
  fi
}

case "$MODE" in
  status)
    state="$(ssh "${SSH_OPTS[@]}" "root@${IP}" "docker inspect -f '{{.State.Status}}' '${VM_CONTAINER[$VM]}' 2>/dev/null" 2>/dev/null || true)"
    [[ -n "$state" ]] || state="injoignable"
    if [[ "$state" == "running" ]]; then ok "conteneur ${VM_CONTAINER[$VM]} actif"
    else echec "conteneur ${VM_CONTAINER[$VM]} : ${state}"; fi
    if [[ "$APP" == "ollama" ]]; then
      if version="$(curl -fsS --max-time 5 "http://${IP}:${OLLAMA_PORT}/api/version" 2>/dev/null)"; then
        ok "API Ollama ${version}"
      else echec "API Ollama injoignable sur ${IP}:${OLLAMA_PORT}"; fi
      if model_present; then ok "modèle ${MODEL} présent"; else echec "modèle ${MODEL} absent"; fi
    else
      if curl -fsS --max-time 5 "http://${IP}:${WEBUI_PORT}/health" >/dev/null 2>&1; then
        ok "Open WebUI répond sur http://${IP}:${WEBUI_PORT}"
      else echec "Open WebUI injoignable sur ${IP}:${WEBUI_PORT}"; fi
    fi
    ;;
  check)
    ssh_ok || { echec "VM ${VM_NAME[$VM]} injoignable en SSH sur ${IP}"; exit 1; }
    fail=0
    guest base || fail=1
    sync_compose || fail=1
    if [[ "${VM_GPU[$VM]}" == "1" ]]; then guest nvidia || fail=1; fi
    guest "$APP" || fail=1
    if [[ "$APP" == "ollama" ]]; then ensure_model || fail=1; fi
    (( fail == 0 )) || exit 1
    ;;
  up)
    ssh_ok || die "VM ${VM_NAME[$VM]} injoignable en SSH sur ${IP} ; lancer d'abord up"
    guest base
    sync_compose || die "synchronisation du compose ${APP} impossible"
    if [[ "${VM_GPU[$VM]}" == "1" ]]; then ensure_nvidia; fi
    guest "$APP"
    if [[ "$APP" == "ollama" ]]; then ensure_model; fi
    ;;
esac
