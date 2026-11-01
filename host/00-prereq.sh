#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/config.sh"
STEP="host/prereq"
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

# /usr/sbin and /sbin are not always in a non-root user's PATH:
# check must see brctl/nft without requiring sudo.
has_command() {
  local command="$1" dir
  command -v "$command" >/dev/null 2>&1 && return 0
  for dir in /usr/sbin /sbin /usr/bin /bin; do
    [[ -x "${dir}/${command}" ]] && return 0
  done
  return 1
}

# --- System ---------------------------------------------------------------
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "debian" ]] || bad "Debian expected (detected: ${ID:-unknown})"
  [[ "${VERSION_ID:-}" == "13" ]] || bad "Debian 13 expected (detected: ${VERSION_ID:-unknown})"
else
  bad "/etc/os-release missing"
fi
[[ "$(uname -m)" == "x86_64" ]] || bad "x86_64 expected (detected: $(uname -m))"
grep -qw vmx /proc/cpuinfo || bad "VT-x missing (check the BIOS/UEFI)"
[[ -c /dev/kvm ]] || bad "/dev/kvm missing"

for address in "$GPU_VIDEO" "$GPU_AUDIO"; do
  [[ -e "/sys/bus/pci/devices/${address}" ]] || bad "GPU missing: ${address}"
done

# --- Disk space -------------------------------------------------------------
free_kb="$(df -Pk "$ROOT" | awk 'NR == 2 {print $4}')"
if [[ -z "$free_kb" || "$free_kb" -lt $((20 * 1024 * 1024)) ]]; then
  bad "less than 20 GiB free on ${ROOT}"
fi

# --- Commands and packages --------------------------------------------------
# Observe before acting: in check mode, a missing item is a failure; in up
# mode, it is announced then re-evaluated after installation. Only remaining
# gaps count in the final verdict.
missing_pkgs=()
for package in "${PACKAGES[@]}"; do
  dpkg -s "$package" >/dev/null 2>&1 || missing_pkgs+=("$package")
done
missing_cmds=()
for command in "${COMMANDS[@]}"; do
  has_command "$command" || missing_cmds+=("$command")
done

if (( CHECK )); then
  (( ${#missing_pkgs[@]} == 0 )) || bad "missing package(s): ${missing_pkgs[*]}"
  (( ${#missing_cmds[@]} == 0 )) || bad "missing command(s): ${missing_cmds[*]}"
else
  if (( ${#missing_pkgs[@]} > 0 || ${#missing_cmds[@]} > 0 )); then
    attente "${#missing_pkgs[@]} package(s) and ${#missing_cmds[@]} command(s) to install"
  fi
  if (( ${#missing_pkgs[@]} > 0 )); then
    require_root
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends "${missing_pkgs[@]}"
    fait "packages installed"
  fi

  # Re-check: keep only what is really missing after apt.
  missing_pkgs=()
  for package in "${PACKAGES[@]}"; do
    dpkg -s "$package" >/dev/null 2>&1 || missing_pkgs+=("$package")
  done
  missing_cmds=()
  for command in "${COMMANDS[@]}"; do
    has_command "$command" || missing_cmds+=("$command")
  done
  if (( ${#missing_pkgs[@]} == 0 && ${#missing_cmds[@]} == 0 )); then
    ok "packages and commands available"
  else
    (( ${#missing_pkgs[@]} == 0 )) || bad "package(s) still missing: ${missing_pkgs[*]}"
    (( ${#missing_cmds[@]} == 0 )) || bad "command(s) still missing: ${missing_cmds[*]}"
  fi
fi

# --- SSH key and working directories ----------------------------------------
uid="$(caller_uid)"
gid="$(caller_gid)"
USER_HOME="$(getent passwd "$uid" | cut -d: -f6)"
[[ -n "$USER_HOME" && -d "$USER_HOME" ]] || bad "home directory not found for uid ${uid}"
for dir in "$DATA" "$KEYS" "$LOGS" "$RUN"; do
  if [[ ! -d "$dir" ]]; then
    if (( CHECK )); then
      bad "directory missing: ${dir#"$ROOT"/}"
    else
      require_root
      install -d -m 0755 -o "$uid" -g "$gid" "$dir"
      if [[ "$dir" == "$KEYS" ]]; then chmod 0700 "$dir"; fi
      fait "directory created: ${dir#"$ROOT"/}"
    fi
  elif (( ! CHECK )) && [[ "$(stat -c '%u' "$dir")" != "$uid" ]]; then
    require_root
    chown "$uid:$gid" "$dir"
    fait "owner fixed: ${dir#"$ROOT"/}"
  fi
done

if [[ ! -f "${KEYS}/id_ed25519" ]]; then
  if (( CHECK )); then
    bad "SSH key missing: data/ssh/id_ed25519"
  else
    require_root
    as_caller ssh-keygen -q -t ed25519 -N '' -C "ai-local" -f "${KEYS}/id_ed25519"
    chmod 0600 "${KEYS}/id_ed25519"
    chmod 0644 "${KEYS}/id_ed25519.pub"
    fait "SSH key generated"
  fi
elif [[ ! -f "${KEYS}/id_ed25519.pub" ]]; then
  bad "public key missing: data/ssh/id_ed25519.pub"
fi

if [[ ! -f "${KEYS}/known_hosts" ]]; then
  if (( CHECK )); then
    bad "data/ssh/known_hosts missing"
  else
    require_root
    install -m 0644 -o "$uid" -g "$gid" /dev/null "${KEYS}/known_hosts"
    fait "known_hosts created"
  fi
fi

# Comfort aliases: never replace an existing user definition.
ensure_aliases() {
  local rc="${USER_HOME}/.bashrc" missing=()
  if [[ ! -f "$rc" ]]; then
    if (( CHECK )); then bad "file ${rc} missing"; return 0; fi
    install -m 0644 -o "$uid" -g "$gid" /dev/null "$rc"
  fi
  grep -qE '^[[:space:]]*alias ll=' "$rc" || missing+=("alias ll='ls -alF'")
  grep -qE '^[[:space:]]*alias la=' "$rc" || missing+=("alias la='ls -A'")
  if (( ${#missing[@]} == 0 )); then ok "aliases ll/la active in ${rc}"; return 0; fi
  if (( CHECK )); then bad "missing alias(es) in ${rc}: ${missing[*]}"; return 0; fi
  printf '\n# ai-local: comfort aliases\n' >>"$rc"
  printf '%s\n' "${missing[@]}" >>"$rc"
  chown "$uid:$gid" "$rc"
  fait "aliases added to ${rc}: ${missing[*]}"
}
ensure_aliases

if (( fail )); then
  exit 1
fi
ok "host ready (Debian 13, VT-x, GPU, packages, SSH key)"
