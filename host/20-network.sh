#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/config.sh"
STEP="réseau"
source "${ROOT}/common.sh"

MODE="${1:-up}"
case "$MODE" in
  --check|--down) ;;
  up|"") MODE="up" ;;
  *) die "usage : $0 [--check|--down]" ;;
esac

WAN=""
if [[ "$MODE" != "--down" ]]; then
  WAN="${WAN_INTERFACE:-$(ip -4 route show default | awk 'NR == 1 {print $5}')}"
  [[ "$WAN" =~ ^[[:alnum:]_.:-]+$ ]] || die "interface WAN introuvable (définir WAN_INTERFACE)"
  [[ -d "/sys/class/net/${WAN}" ]] || die "interface WAN absente : ${WAN}"
  [[ "$WAN" != "$BRIDGE" ]] || die "interface WAN incorrecte : ${WAN}"
fi

VM_IPS="$(printf '%s, ' "${VM_IP[@]}")"
VM_IPS="${VM_IPS%, }"

nft_rules_ok() {
  local rules
  rules="$(nft list table inet "$NFT_FWD" 2>/dev/null || true)"
  [[ "$rules" == *"policy drop"* &&
     "$rules" == *"iifname \"${BRIDGE}\""* &&
     "$rules" == *"oifname \"${WAN}\""* &&
     "$rules" == *"ip saddr ${SUBNET} accept"* ]] || return 1
  local nat
  nat="$(nft list table ip "$NFT_NAT" 2>/dev/null || true)"
  [[ "$nat" == *"ip saddr ${SUBNET} oifname \"${WAN}\" masquerade"* ]]
}

write_nft() {
  nft delete table inet "$NFT_FWD" 2>/dev/null || true
  nft delete table ip "$NFT_NAT" 2>/dev/null || true
  nft -f - <<EOF
table inet ${NFT_FWD} {
  chain forward {
    type filter hook forward priority filter; policy drop;
    ct state established,related accept
    iifname "${BRIDGE}" oifname "${BRIDGE}" ip saddr { ${VM_IPS} } ip daddr { ${VM_IPS} } accept
    iifname "${BRIDGE}" oifname "${WAN}" ip saddr ${SUBNET} accept
  }
}
table ip ${NFT_NAT} {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr ${SUBNET} oifname "${WAN}" masquerade
  }
}
EOF
}

if [[ "$MODE" == "--down" ]]; then
  require_root
  nft delete table inet "$NFT_FWD" 2>/dev/null || true
  nft delete table ip "$NFT_NAT" 2>/dev/null || true
  fait "règles nftables retirées"
  for vm in "${VMS[@]}"; do
    tap="${VM_TAP[$vm]}"
    if ip link show "$tap" >/dev/null 2>&1; then
      ip link del "$tap"
      fait "TAP retiré : ${tap}"
    fi
  done
  if ip link show "$BRIDGE" >/dev/null 2>&1; then
    ip link del "$BRIDGE"
    fait "bridge retiré : ${BRIDGE}"
  fi
  ok "réseau privé retiré"
  exit 0
fi

if [[ "$MODE" == "--check" ]]; then
  fail=0
  if ip link show "$BRIDGE" >/dev/null 2>&1 &&
    ip -4 addr show dev "$BRIDGE" | grep -qF "${BRIDGE_IP}/"; then
    ok "bridge ${BRIDGE} ${BRIDGE_IP}/${SUBNET_PREFIX}"
  else
    echec "bridge ${BRIDGE} absent ou sans adresse"; fail=1
  fi
  for vm in "${VMS[@]}"; do
    tap="${VM_TAP[$vm]}"
    if ip link show "$tap" >/dev/null 2>&1 &&
      [[ "$(readlink -f "/sys/class/net/${tap}/master" 2>/dev/null)" == "$(readlink -f "/sys/class/net/${BRIDGE}")" ]]; then
      ok "TAP ${tap} rattaché"
    else
      echec "TAP ${tap} absent ou non rattaché"; fail=1
    fi
  done
  [[ "$(< /proc/sys/net/ipv4/ip_forward)" == "1" ]] || { echec "ip_forward désactivé"; fail=1; }
  if [[ "${EUID}" -eq 0 ]]; then
    if nft_rules_ok; then ok "règles nftables conformes"; else echec "règles nftables absentes ou périmées"; fail=1; fi
  else
    saute "contrôle nftables (root requis)"
  fi
  (( fail == 0 )) || exit 1
  exit 0
fi

require_root

if ip link show "$BRIDGE" >/dev/null 2>&1; then
  [[ -d "/sys/class/net/${BRIDGE}/bridge" ]] || die "${BRIDGE} existe mais n'est pas un bridge"
  ok "bridge ${BRIDGE} présent"
else
  brctl addbr "$BRIDGE"
  fait "bridge créé : ${BRIDGE}"
fi

if ip -4 addr show dev "$BRIDGE" | grep -qF "${BRIDGE_IP}/"; then
  ok "adresse ${BRIDGE_IP}/${SUBNET_PREFIX} présente"
else
  ip address add "${BRIDGE_IP}/${SUBNET_PREFIX}" dev "$BRIDGE"
  fait "adresse ${BRIDGE_IP}/${SUBNET_PREFIX} ajoutée"
fi
ip link set "$BRIDGE" up

for vm in "${VMS[@]}"; do
  tap="${VM_TAP[$vm]}"
  if ip link show "$tap" >/dev/null 2>&1; then
    [[ -e "/sys/class/net/${tap}/tun_flags" ]] || die "${tap} existe mais n'est pas un TAP"
  else
    ip tuntap add dev "$tap" mode tap user root
    fait "TAP créé : ${tap}"
  fi
  if [[ "$(readlink -f "/sys/class/net/${tap}/master" 2>/dev/null)" != "$(readlink -f "/sys/class/net/${BRIDGE}")" ]]; then
    brctl addif "$BRIDGE" "$tap"
    fait "TAP rattaché : ${tap}"
  fi
  ip link set "$tap" up
done

if [[ "$(< /proc/sys/net/ipv4/ip_forward)" == "1" ]]; then
  ok "ip_forward actif"
else
  printf '1\n' >/proc/sys/net/ipv4/ip_forward
  fait "ip_forward activé"
fi

if nft_rules_ok; then
  ok "règles nftables conformes"
else
  write_nft
  fait "règles nftables écrites (NAT via ${WAN})"
fi
