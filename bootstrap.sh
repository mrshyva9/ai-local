#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
source ./config.sh
STEP="bootstrap"
source ./common.sh

usage() {
  cat <<EOF
Usage: $0 <command> [vm...]

  up [vm...]      converge everything, or only the named VMs (${VMS[*]})
  check [vm...]   verify without modifying; exit 0 compliant, 1 otherwise
  status          readable state of the host, VMs and applications
  down [vm...]    stop the VMs and remove the network (default: all)
  test            end-to-end validation (host, VMs, applications, aider)
  ssh <vm>        admin session in the VM

The first up may require a host reboot (VFIO configuration).
EOF
}

valid_vm() { [[ -n "${VM_NAME[$1]:-}" ]] || die "unknown VM: $1 (expected: ${VMS[*]})"; }

# Run a step and guarantee a final "Result: FAIL" line.
run() { "$@" || { result "FAIL"; exit 1; }; }

cmd_up() {
  require_root
  local vms=("$@") vm rc=0
  (( ${#vms[@]} )) || vms=("${VMS[@]}")
  for vm in "${vms[@]}"; do valid_vm "$vm"; done

  run "$ROOT/host/00-prereq.sh"

  set +e
  "$ROOT/host/10-vfio.sh"
  rc=$?
  set -e
  if (( rc == 2 )); then
    result "REBOOT REQUIRED"
    exit 2
  fi
  (( rc == 0 )) || { result "FAIL"; exit "$rc"; }

  run "$ROOT/host/20-network.sh"
  run "$ROOT/vm/10-image.sh"
  for vm in "${vms[@]}"; do
    run "$ROOT/vm/20-lifecycle.sh" up "$vm"
  done
  for vm in "${vms[@]}"; do
    run "$ROOT/host/30-app.sh" "$vm"
  done

  STEP="host/aider"
  if [[ -n "${SUDO_USER:-}" ]]; then
    run as_caller "$ROOT/host/30-aider.sh"
  else
    saute "aider installation skipped (run up via sudo from your account)"
  fi

  STEP="bootstrap"
  result "OK"
}

cmd_check() {
  local vms=("$@") vm rc=0
  (( ${#vms[@]} )) || vms=("${VMS[@]}")
  for vm in "${vms[@]}"; do valid_vm "$vm"; done

  for s in host/00-prereq.sh host/10-vfio.sh host/20-network.sh vm/10-image.sh; do
    "$ROOT/$s" --check || rc=1
  done
  for vm in "${vms[@]}"; do
    "$ROOT/vm/20-lifecycle.sh" check "$vm" || rc=1
    "$ROOT/host/30-app.sh" check "$vm" || rc=1
  done
  as_caller "$ROOT/host/30-aider.sh" --check || rc=1

  if (( rc == 0 )); then result "OK"; else result "FAIL"; fi
  return "$rc"
}

cmd_status() {
  local vm
  STEP="network"
  if ip link show "$BRIDGE" >/dev/null 2>&1; then
    ok "bridge ${BRIDGE} $(ip -4 -o addr show dev "$BRIDGE" | awk '{print $4}')"
  else
    echec "bridge ${BRIDGE} missing (run up)"
  fi
  for vm in "${VMS[@]}"; do
    "$ROOT/vm/20-lifecycle.sh" status "$vm"
    "$ROOT/host/30-app.sh" status "$vm"
  done
  STEP="host/aider"
  as_caller "$ROOT/host/30-aider.sh" --status || true
}

cmd_down() {
  require_root
  local vms=("$@") vm
  if (( ${#vms[@]} == 0 )) || [[ "${vms[0]}" == "all" ]]; then
    vms=("${VMS[@]}")
  fi
  for vm in "${vms[@]}"; do
    valid_vm "$vm"
    run "$ROOT/vm/20-lifecycle.sh" down "$vm"
  done
  run "$ROOT/host/20-network.sh" --down
  result "OK"
}

cmd_ssh() {
  (($# == 1)) || die "usage: $0 ssh <vm>"
  valid_vm "$1"
  exec ssh "${SSH_OPTS[@]}" "${GUEST_USER}@${VM_IP[$1]}"
}

case "${1:-}" in
  up)     shift; cmd_up "$@" ;;
  check)  shift; cmd_check "$@" ;;
  status) cmd_status ;;
  down)   shift; cmd_down "$@" ;;
  test)   shift; as_caller "$ROOT/host/40-test.sh" ;;
  ssh)    shift; cmd_ssh "$@" ;;
  -h|--help|help|"") usage ;;
  *) usage >&2; exit 1 ;;
esac
