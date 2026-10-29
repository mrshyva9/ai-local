#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/config.sh"
STEP="vm"
source "${ROOT}/common.sh"

usage() { die "usage : $0 up|check|status|down <${VMS[*]}>"; }
MODE="${1:-}"; VM="${2:-}"
[[ -n "${VM_NAME[$VM]:-}" ]] || usage
case "$MODE" in up|check|status|down) ;; *) usage ;; esac

NAME="${VM_NAME[$VM]}"
IP="${VM_IP[$VM]}"
TAP="${VM_TAP[$VM]}"
DISK="${DATA}/${NAME}.qcow2"
SEED=""
VARS="${DATA}/${NAME}-OVMF_VARS.fd"
PIDFILE="${RUN}/${NAME}.pid"
QMP="${RUN}/${NAME}.qmp"
CONSOLE="${LOGS}/${NAME}-console.log"
BASE="${DATA}/${IMAGE_NAME}"
if [[ -f "${KEYS}/id_ed25519.pub" ]]; then PUBKEY="$(<"${KEYS}/id_ed25519.pub")"; else PUBKEY=""; fi

arg() { awk -v o="$2" '$0 == o { getline; print; exit }' <<<"$1"; }

# 0 = ce PID est bien la VM attendue ; 1 = arrêtée ; die = PID suspect.
running() {
  local pid cmd
  [[ -f "$PIDFILE" ]] || return 1
  pid="$(<"$PIDFILE")"
  [[ "$pid" =~ ^[0-9]+$ ]] || die "PID invalide dans ${PIDFILE}"
  kill -0 "$pid" 2>/dev/null || return 1
  [[ "$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)" == *qemu-system-x86_64 ]] ||
    die "le PID ${pid} n'est pas QEMU ; intervention manuelle requise"
  cmd="$(tr '\0' '\n' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
  [[ "$(arg "$cmd" -name)" == "$NAME" && "$(arg "$cmd" -pidfile)" == "$PIDFILE" ]] ||
    die "le PID ${pid} n'est pas la VM ${NAME} ; intervention manuelle requise"
  return 0
}

render() {
  sed -e "s|__PROJECT__|${PROJECT}|g" -e "s|__VM_NAME__|${NAME}|g" \
    -e "s|__GUEST_USER__|${GUEST_USER}|g" -e "s|__SSH_PUBKEY__|${PUBKEY}|g" \
    -e "s|__VM_MAC__|${VM_MAC[$VM]}|g" -e "s|__VM_CIDR__|${IP}/${SUBNET_PREFIX}|g" \
    -e "s|__BRIDGE_IP__|${BRIDGE_IP}|g" -e "s|__DNS1__|${DNS1}|g" \
    -e "s|__DNS2__|${DNS2}|g" "$1"
}

# L'instance-id et le nom du seed dérivent du contenu : seed stable = [OK].
seed_id() { { render "${ROOT}/vm/cloud-init/user-data.yaml"; render "${ROOT}/vm/cloud-init/network-config.yaml"; render "${ROOT}/vm/cloud-init/meta-data.yaml"; } | sha256sum | cut -c1-16; }
seed_path() { SEED="${DATA}/${NAME}-seed-$(seed_id).iso"; }

build_seed() {
  seed_path
  if [[ -f "$SEED" ]]; then
    ok "seed cloud-init à jour"
    return 0
  fi
  local tmp id
  tmp="$(mktemp -d "${RUN}/seed.XXXXXX")"
  id="$(seed_id)"
  render "${ROOT}/vm/cloud-init/user-data.yaml" >"${tmp}/user-data"
  render "${ROOT}/vm/cloud-init/network-config.yaml" >"${tmp}/network-config"
  render "${ROOT}/vm/cloud-init/meta-data.yaml" | sed "s|__INSTANCE_ID__|${NAME}-${id}|" >"${tmp}/meta-data"
  cloud-localds --network-config="${tmp}/network-config" "${tmp}/seed.iso" \
    "${tmp}/user-data" "${tmp}/meta-data" >/dev/null
  install -m 0640 -o "$(caller_uid)" -g "$(caller_gid)" "${tmp}/seed.iso" "$SEED"
  find "$DATA" -maxdepth 1 -name "${NAME}-seed-*.iso" ! -name "$(basename "$SEED")" -delete
  rm -rf -- "$tmp"
  fait "seed cloud-init régénéré"
}

prepare() {
  [[ -f "$BASE" ]] || die "image de base absente : lancer vm/10-image.sh"
  if [[ ! -f "$DISK" ]]; then
    qemu-img create -q -f qcow2 -F qcow2 -b "$BASE" "$DISK" "${VM_DISK_GIB[$VM]}G"
    chown "$(caller_uid):$(caller_gid)" "$DISK"
    ssh-keygen -R "$IP" -f "${KEYS}/known_hosts" >/dev/null 2>&1 || true
    fait "disque créé : ${DISK#${ROOT}/}"
  fi
  if [[ -f "$VARS" ]]; then ok "variables UEFI présentes"
  else install -m 0644 -o "$(caller_uid)" -g "$(caller_gid)" "$OVMF_VARS_TEMPLATE" "$VARS"; fait "variables UEFI créées"; fi
  build_seed
}

wait_ssh() {
  local deadline=$((SECONDS + 300)) next=$((SECONDS + 30))
  attente "attente de SSH sur ${IP}:22 (cloud-init)"
  while (( SECONDS < deadline )); do
    if timeout 12 ssh "${SSH_OPTS[@]}" "root@${IP}" true >/dev/null 2>&1; then
      ok "SSH répond sur ${IP}"
      attente "attente de la fin de cloud-init"
      timeout 300 ssh "${SSH_OPTS[@]}" "root@${IP}" \
        "cloud-init status --wait >/dev/null 2>&1" ||
        attente "cloud-init non terminé ou en erreur ; poursuite (les étapes invité sont rejouables)"
      return 0
    fi
    if (( SECONDS >= next )); then
      attente "toujours en attente de SSH sur ${IP} (voir ${CONSOLE#${ROOT}/})"
      next=$((SECONDS + 30))
    fi
    sleep 5
  done
  die "SSH ne répond pas sur ${IP} après 300 s ; la VM reste démarrée"
}

start() {
  require_root
  ip link show "$TAP" >/dev/null 2>&1 ||
    die "TAP ${TAP} absent : lancer d'abord host/20-network.sh"
  install -d -m 0755 "$RUN" "$LOGS" "$DATA"
  prepare
  if running; then ok "VM ${NAME} déjà démarrée (PID $(<"$PIDFILE"))"; return 0; fi
  if [[ -e "$PIDFILE" || -e "$QMP" ]]; then
    rm -f -- "$PIDFILE"
    [[ -S "$QMP" ]] && rm -f -- "$QMP"
    [[ -e "$QMP" ]] && die "chemin QMP suspect : ${QMP}"
  fi

  local args=(-name "$NAME" -enable-kvm -machine q35,accel=kvm -cpu host
    -smp "${VM_VCPUS[$VM]}" -m "${VM_RAM_MIB[$VM]}M"
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}"
    -drive "if=pflash,format=raw,file=${VARS}"
    -drive "file=${DISK},if=virtio,format=qcow2"
    -drive "file=${SEED},media=cdrom,readonly=on"
    -netdev "tap,id=net0,ifname=${TAP},script=no,downscript=no"
    -device "virtio-net-pci,netdev=net0,mac=${VM_MAC[$VM]}")
  if [[ "${VM_GPU[$VM]}" == "1" ]]; then
    args+=(-device "vfio-pci,host=${GPU_VIDEO}" -device "vfio-pci,host=${GPU_AUDIO}")
  fi
  args+=(-display none -serial "file:${CONSOLE}" -monitor none
    -qmp "unix:${QMP},server=on,wait=off" -pidfile "$PIDFILE" -daemonize)

  : >"$CONSOLE"
  chown "$(caller_uid):$(caller_gid)" "$CONSOLE"
  attente "démarrage de ${NAME} (${VM_VCPUS[$VM]} vCPU, $((VM_RAM_MIB[$VM] / 1024)) Gio)"
  if ! qemu-system-x86_64 "${args[@]}"; then
    die "QEMU n'a pas démarré ; voir ${CONSOLE#${ROOT}/}"
  fi
  running || die "QEMU a rendu la main sans processus ${NAME} ; voir ${CONSOLE#${ROOT}/}"
  fait "VM ${NAME} démarrée (PID $(<"$PIDFILE"))"
  wait_ssh
}

qmp_powerdown() {
  python3 - "$QMP" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(sys.argv[1])
f = s.makefile("rwb", buffering=0)
f.readline()
for command in ("qmp_capabilities", "system_powerdown"):
    f.write(json.dumps({"execute": command}).encode() + b"\r\n")
    while True:
        answer = json.loads(f.readline())
        if "error" in answer:
            raise SystemExit(f"QMP a refusé {command} : {answer['error']}")
        if "return" in answer:
            break
PY
}

stop() {
  require_root
  if ! running; then
    rm -f -- "$PIDFILE"
    [[ -S "$QMP" ]] && rm -f -- "$QMP"
    ok "VM ${NAME} déjà arrêtée"
    return 0
  fi
  [[ -S "$QMP" ]] || die "socket QMP absente ; arrêt annulé"
  local pid; pid="$(<"$PIDFILE")"
  attente "arrêt ACPI de ${NAME}"
  qmp_powerdown || die "QMP n'a pas accepté l'arrêt ; VM laissée en l'état"
  local deadline=$((SECONDS + 120))
  while kill -0 "$pid" 2>/dev/null && (( SECONDS < deadline )); do sleep 2; done
  if kill -0 "$pid" 2>/dev/null; then
    attente "arrêt ACPI trop long, SIGTERM"
    kill -TERM "$pid"
    deadline=$((SECONDS + 15))
    while kill -0 "$pid" 2>/dev/null && (( SECONDS < deadline )); do sleep 1; done
    kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f -- "$PIDFILE"
  [[ -S "$QMP" ]] && rm -f -- "$QMP"
  fait "VM ${NAME} arrêtée (disque et modèles conservés)"
}

case "$MODE" in
  status)
    # Sous-shell : un PID suspect ne doit jamais faire échouer `status`.
    if (running) 2>/dev/null; then ok "VM ${NAME} active (PID $(<"$PIDFILE"), ${IP})"
    else echec "VM ${NAME} arrêtée"; fi
    ;;
  check)
    fail=0
    seed_path
    [[ -f "$BASE" ]] || { echec "image de base absente"; fail=1; }
    [[ -f "$DISK" ]] || { echec "disque absent : ${DISK#${ROOT}/}"; fail=1; }
    [[ -f "$SEED" ]] || { echec "seed absent : ${SEED#${ROOT}/}"; fail=1; }
    [[ -f "$VARS" ]] || { echec "variables UEFI absentes : ${VARS#${ROOT}/}"; fail=1; }
    running || { echec "VM ${NAME} non démarrée"; fail=1; }
    (( fail == 0 )) && ok "VM ${NAME} conforme"
    (( fail == 0 )) || exit 1
    ;;
  up) start ;;
  down) stop ;;
esac
