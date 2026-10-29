#!/usr/bin/env bash
# Exécuté DANS l'invité, en root. Pilote NVIDIA + runtime Docker GPU.
# Code retour 3 = redémarrage de l'invité nécessaire.
set -Eeuo pipefail

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1
ok()    { printf '[invité/nvidia] [OK]      %s\n' "$*"; }
fait()  { printf '[invité/nvidia] [FAIT]    %s\n' "$*"; }
echec() { printf "[invité/nvidia] [ÉCHEC]   %s\n" "$*"; }
die()   { echec "$*"; exit 1; }

driver_ok()  { nvidia-smi -L >/dev/null 2>&1; }
toolkit_ok() {
  command -v nvidia-ctk >/dev/null 2>&1 &&
    docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia
}

diagnose() {
  echec "nvidia-smi ne fonctionne pas ; diagnostic :"
  modinfo -F vermagic nvidia 2>&1 || true
  lsmod | grep -E '^nvidia' || true
  dmesg --level=err,warn 2>/dev/null | grep -i nvidia | tail -n 15 || true
}

if driver_ok && toolkit_ok; then
  ok "GPU visible et runtime Docker nvidia actif : $(nvidia-smi -L | head -n 1)"
  exit 0
fi
if (( CHECK )); then
  driver_ok || echec "nvidia-smi indisponible (pilote absent ou redémarrage requis)"
  toolkit_ok || echec "runtime Docker nvidia absent (nvidia-container-toolkit)"
  exit 1
fi

if ! driver_ok; then
  SOURCES=/etc/apt/sources.list.d/ai-local-nonfree.sources
  if [[ ! -e "$SOURCES" ]]; then
    cat >"$SOURCES" <<'EOF'
Types: deb
URIs: https://deb.debian.org/debian
Suites: trixie trixie-updates
Components: contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://security.debian.org/debian-security
Suites: trixie-security
Components: contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    fait "dépôt non-free activé"
  fi
  case "$(uname -r)" in
    *-cloud-amd64) SUFFIX=cloud-amd64 ;;
    *-amd64) SUFFIX=amd64 ;;
    *) die "noyau Debian non reconnu : $(uname -r)" ;;
  esac
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o DPkg::Lock::Timeout=300 update
  apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends \
    "linux-image-${SUFFIX}" "linux-headers-${SUFFIX}" nvidia-driver nvidia-smi pciutils
  fait "pilote NVIDIA installé"
fi

if ! command -v nvidia-ctk >/dev/null 2>&1; then
  install -d -m 0755 /usr/share/keyrings
  curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
    https://nvidia.github.io/libnvidia-container/gpgkey |
    gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
    https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
    sed 's#^deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' \
      >/etc/apt/sources.list.d/nvidia-container-toolkit.list
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o DPkg::Lock::Timeout=300 update
  apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends \
    nvidia-container-toolkit
  fait "nvidia-container-toolkit installé"
fi

nvidia-ctk runtime configure --runtime=docker >/dev/null
systemctl restart docker
systemctl is-active --quiet docker || die "Docker ne redémarre pas après configuration nvidia"

if driver_ok && toolkit_ok; then
  ok "GPU visible et runtime Docker nvidia actif : $(nvidia-smi -L | head -n 1)"
  exit 0
fi
if ! driver_ok; then
  diagnose
  printf '[invité/nvidia] [ATTENTE] pilote installé, redémarrage de l’invité nécessaire\n'
  exit 3
fi
die "runtime Docker nvidia toujours absent après configuration"
