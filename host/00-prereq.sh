#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/config.sh"
STEP="hôte/prérequis"
source "${ROOT}/common.sh"

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

PACKAGES=(qemu-system-x86 qemu-utils ovmf cloud-image-utils bridge-utils
  iproute2 nftables curl openssh-client initramfs-tools grub2-common python3 git)
COMMANDS=(qemu-system-x86_64 qemu-img cloud-localds ssh curl ip brctl nft
  sha512sum sha256sum python3 git tar)

fail=0
bad() { echec "$*"; fail=1; }

# --- Système ---------------------------------------------------------------
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "debian" ]] || bad "Debian attendu (détecté : ${ID:-inconnu})"
  [[ "${VERSION_ID:-}" == "13" ]] || bad "Debian 13 attendu (détecté : ${VERSION_ID:-inconnu})"
else
  bad "/etc/os-release absent"
fi
[[ "$(uname -m)" == "x86_64" ]] || bad "x86_64 attendu (détecté : $(uname -m))"
grep -qw vmx /proc/cpuinfo || bad "VT-x absent (vérifier le BIOS/UEFI)"
[[ -c /dev/kvm ]] || bad "/dev/kvm absent"

for address in "$GPU_VIDEO" "$GPU_AUDIO"; do
  [[ -e "/sys/bus/pci/devices/${address}" ]] || bad "GPU absent : ${address}"
done

# --- Espace disque ----------------------------------------------------------
free_kb="$(df -Pk "$ROOT" | awk 'NR == 2 {print $4}')"
if [[ -z "$free_kb" || "$free_kb" -lt $((20 * 1024 * 1024)) ]]; then
  bad "moins de 20 Gio libres sur ${ROOT}"
fi

# --- Commandes et paquets ---------------------------------------------------
missing_cmds=()
for command in "${COMMANDS[@]}"; do
  command -v "$command" >/dev/null 2>&1 || missing_cmds+=("$command")
done
(( ${#missing_cmds[@]} == 0 )) || bad "commande(s) absente(s) : ${missing_cmds[*]}"

missing_pkgs=()
for package in "${PACKAGES[@]}"; do
  dpkg -s "$package" >/dev/null 2>&1 || missing_pkgs+=("$package")
done
if (( ${#missing_pkgs[@]} > 0 )); then
  if (( CHECK )); then
    bad "paquet(s) absent(s) : ${missing_pkgs[*]}"
  else
    require_root
    attente "installation : ${missing_pkgs[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends "${missing_pkgs[@]}"
    fait "paquets installés"
  fi
fi

# --- Clé SSH et répertoires de travail --------------------------------------
uid="$(caller_uid)"
gid="$(caller_gid)"
for dir in "$DATA" "$KEYS" "$CLIENT" "$LOGS" "$RUN"; do
  if [[ ! -d "$dir" ]]; then
    if (( CHECK )); then
      bad "répertoire absent : ${dir#"$ROOT"/}"
    else
      require_root
      install -d -m 0755 -o "$uid" -g "$gid" "$dir"
      if [[ "$dir" == "$KEYS" ]]; then chmod 0700 "$dir"; fi
      fait "répertoire créé : ${dir#"$ROOT"/}"
    fi
  elif (( ! CHECK )) && [[ "$(stat -c '%u' "$dir")" != "$uid" ]]; then
    require_root
    chown "$uid:$gid" "$dir"
    fait "propriétaire corrigé : ${dir#"$ROOT"/}"
  fi
done

if [[ ! -f "${KEYS}/id_ed25519" ]]; then
  if (( CHECK )); then
    bad "clé SSH absente : data/ssh/id_ed25519"
  else
    require_root
    as_caller ssh-keygen -q -t ed25519 -N '' -C "ai-local" -f "${KEYS}/id_ed25519"
    chmod 0600 "${KEYS}/id_ed25519"
    chmod 0644 "${KEYS}/id_ed25519.pub"
    fait "clé SSH générée"
  fi
elif [[ ! -f "${KEYS}/id_ed25519.pub" ]]; then
  bad "clé publique absente : data/ssh/id_ed25519.pub"
fi

if [[ ! -f "${KEYS}/known_hosts" ]]; then
  if (( CHECK )); then
    bad "data/ssh/known_hosts absent"
  else
    require_root
    install -m 0644 -o "$uid" -g "$gid" /dev/null "${KEYS}/known_hosts"
    fait "known_hosts créé"
  fi
fi

if (( fail )); then
  exit 1
fi
ok "hôte prêt (Debian 13, VT-x, GPU, paquets, clé SSH)"
