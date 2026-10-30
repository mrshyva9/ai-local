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

smi_ok()     { nvidia-smi -L >/dev/null 2>&1; }
cuda_ok()    { ldconfig -p 2>/dev/null | grep -q 'libcuda\.so\.1'; }
driver_ok()  { smi_ok && cuda_ok; }
toolkit_ok() {
  command -v nvidia-ctk >/dev/null 2>&1 &&
    docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia
}
# Le runtime Docker récent passe par CDI : un spec généré avant libcuda1 ne
# contient pas libcuda.so et le conteneur retombe silencieusement sur CPU.
cdi_ok() {
  [[ -f /var/run/cdi/nvidia.yaml ]] &&
    grep -q 'libcuda\.so' /var/run/cdi/nvidia.yaml
}

diagnose() {
  echec "nvidia-smi ne fonctionne pas ; diagnostic :"
  modinfo -F vermagic nvidia 2>&1 || true
  lsmod | grep -E '^nvidia' || true
  ldconfig -p | grep -E 'libcuda|libnvidia-ml' || true
  dmesg --level=err,warn 2>/dev/null | grep -i nvidia | tail -n 15 || true
}

if driver_ok && toolkit_ok && cdi_ok; then
  ok "GPU visible et runtime Docker nvidia actif : $(nvidia-smi -L | head -n 1)"
  exit 0
fi
if (( CHECK )); then
  smi_ok || echec "nvidia-smi indisponible (pilote absent ou redémarrage requis)"
  cuda_ok || echec "libcuda.so.1 absente (paquet libcuda1 manquant)"
  toolkit_ok || echec "runtime Docker nvidia absent (nvidia-container-toolkit)"
  cdi_ok || echec "spec CDI NVIDIA obsolète (libcuda absente)"
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
    "linux-image-${SUFFIX}" "linux-headers-${SUFFIX}" nvidia-driver nvidia-smi \
    libcuda1 pciutils
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
install -d -m 0755 /var/run/cdi
if ! nvidia-ctk cdi generate --output=/var/run/cdi/nvidia.yaml >/dev/null 2>&1; then
  die "génération du spec CDI NVIDIA impossible"
fi
fait "spec CDI NVIDIA régénéré"
systemctl restart docker
systemctl is-active --quiet docker || die "Docker ne redémarre pas après configuration nvidia"

if driver_ok && toolkit_ok && cdi_ok; then
  ok "GPU visible et runtime Docker nvidia actif : $(nvidia-smi -L | head -n 1)"
  exit 0
fi
if ! driver_ok; then
  diagnose
  if ! smi_ok; then
    printf '[invité/nvidia] [ATTENTE] pilote installé, redémarrage de l’invité nécessaire\n'
    exit 3
  fi
  die "libcuda.so.1 toujours absente après installation de libcuda1"
fi
die "runtime Docker nvidia ou spec CDI incomplet après configuration"
