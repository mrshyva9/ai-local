#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/config.sh"
STEP="hôte/prérequis"
source "${ROOT}/common.sh"

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

PACKAGES=(qemu-system-x86 qemu-utils ovmf cloud-image-utils bridge-utils
  iproute2 nftables curl openssh-client initramfs-tools grub2-common python3 git
  vim tmux glow rsync)
COMMANDS=(qemu-system-x86_64 qemu-img cloud-localds ssh curl ip brctl nft
  sha512sum sha256sum python3 git tar vim tmux glow rsync)

fail=0
bad() { echec "$*"; fail=1; }

# /usr/sbin et /sbin ne sont pas toujours dans le PATH d'un utilisateur non
# root : check doit voir brctl/nft sans exiger sudo.
has_command() {
  local command="$1" dir
  command -v "$command" >/dev/null 2>&1 && return 0
  for dir in /usr/sbin /sbin /usr/bin /bin; do
    [[ -x "${dir}/${command}" ]] && return 0
  done
  return 1
}

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
# Observer avant d'agir : en check, un manque est un échec ; en up, il est
# annoncé puis réévalué après installation. Seuls les manques restants
# comptent dans le verdict final.
missing_pkgs=()
for package in "${PACKAGES[@]}"; do
  dpkg -s "$package" >/dev/null 2>&1 || missing_pkgs+=("$package")
done
missing_cmds=()
for command in "${COMMANDS[@]}"; do
  has_command "$command" || missing_cmds+=("$command")
done

if (( CHECK )); then
  (( ${#missing_pkgs[@]} == 0 )) || bad "paquet(s) absent(s) : ${missing_pkgs[*]}"
  (( ${#missing_cmds[@]} == 0 )) || bad "commande(s) absente(s) : ${missing_cmds[*]}"
else
  if (( ${#missing_pkgs[@]} > 0 || ${#missing_cmds[@]} > 0 )); then
    attente "${#missing_pkgs[@]} paquet(s) et ${#missing_cmds[@]} commande(s) à installer"
  fi
  if (( ${#missing_pkgs[@]} > 0 )); then
    require_root
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends "${missing_pkgs[@]}"
    fait "paquets installés"
  fi

  # Re-vérification : ne conserver que ce qui manque réellement après apt.
  missing_pkgs=()
  for package in "${PACKAGES[@]}"; do
    dpkg -s "$package" >/dev/null 2>&1 || missing_pkgs+=("$package")
  done
  missing_cmds=()
  for command in "${COMMANDS[@]}"; do
    has_command "$command" || missing_cmds+=("$command")
  done
  if (( ${#missing_pkgs[@]} == 0 && ${#missing_cmds[@]} == 0 )); then
    ok "paquets et commandes disponibles"
  else
    (( ${#missing_pkgs[@]} == 0 )) || bad "paquet(s) toujours absent(s) : ${missing_pkgs[*]}"
    (( ${#missing_cmds[@]} == 0 )) || bad "commande(s) toujours absente(s) : ${missing_cmds[*]}"
  fi
fi

# --- Clé SSH et répertoires de travail --------------------------------------
uid="$(caller_uid)"
gid="$(caller_gid)"
USER_HOME="$(getent passwd "$uid" | cut -d: -f6)"
[[ -n "$USER_HOME" && -d "$USER_HOME" ]] || bad "répertoire personnel introuvable pour l'uid ${uid}"
for dir in "$DATA" "$KEYS" "$LOGS" "$RUN"; do
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

# Alias de confort : ne remplace jamais une définition existante de l'utilisateur.
ensure_aliases() {
  local rc="${USER_HOME}/.bashrc" missing=()
  if [[ ! -f "$rc" ]]; then
    if (( CHECK )); then bad "fichier ${rc} absent"; return 0; fi
    install -m 0644 -o "$uid" -g "$gid" /dev/null "$rc"
  fi
  grep -qE '^[[:space:]]*alias ll=' "$rc" || missing+=("alias ll='ls -alF'")
  grep -qE '^[[:space:]]*alias la=' "$rc" || missing+=("alias la='ls -A'")
  if (( ${#missing[@]} == 0 )); then ok "alias ll/la actifs dans ${rc}"; return 0; fi
  if (( CHECK )); then bad "alias manquant(s) dans ${rc} : ${missing[*]}"; return 0; fi
  printf '\n# ai-local : alias de confort\n' >>"$rc"
  printf '%s\n' "${missing[@]}" >>"$rc"
  chown "$uid:$gid" "$rc"
  fait "alias ajoutés à ${rc} : ${missing[*]}"
}
ensure_aliases

if (( fail )); then
  exit 1
fi
ok "hôte prêt (Debian 13, VT-x, GPU, paquets, clé SSH)"
