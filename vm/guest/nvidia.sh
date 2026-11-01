#!/usr/bin/env bash
# Executed INSIDE the guest, as root. NVIDIA driver + Docker GPU runtime.
# Exit code 3 = guest reboot required.
set -Eeuo pipefail

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1
ok()    { printf '[guest/nvidia] [OK]      %s\n' "$*"; }
fait()  { printf '[guest/nvidia] [DONE]    %s\n' "$*"; }
echec() { printf "[guest/nvidia] [FAIL]    %s\n" "$*"; }
die()   { echec "$*"; exit 1; }

smi_ok()     { nvidia-smi -L >/dev/null 2>&1; }
cuda_ok()    { ldconfig -p 2>/dev/null | grep -q 'libcuda\.so\.1'; }
driver_ok()  { smi_ok && cuda_ok; }
toolkit_ok() {
  command -v nvidia-ctk >/dev/null 2>&1 &&
    docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia
}
# Recent Docker runtimes go through CDI: a spec generated before libcuda1 does
# not contain libcuda.so, and the container silently falls back to CPU.
cdi_ok() {
  [[ -f /var/run/cdi/nvidia.yaml ]] &&
    grep -q 'libcuda\.so' /var/run/cdi/nvidia.yaml
}

diagnose() {
  echec "nvidia-smi does not work; diagnostics:"
  modinfo -F vermagic nvidia 2>&1 || true
  lsmod | grep -E '^nvidia' || true
  ldconfig -p | grep -E 'libcuda|libnvidia-ml' || true
  dmesg --level=err,warn 2>/dev/null | grep -i nvidia | tail -n 15 || true
}

if driver_ok && toolkit_ok && cdi_ok; then
  ok "GPU visible and Docker nvidia runtime active: $(nvidia-smi -L | head -n 1)"
  exit 0
fi
if (( CHECK )); then
  smi_ok || echec "nvidia-smi unavailable (driver missing or reboot required)"
  cuda_ok || echec "libcuda.so.1 missing (libcuda1 package missing)"
  toolkit_ok || echec "Docker nvidia runtime missing (nvidia-container-toolkit)"
  cdi_ok || echec "NVIDIA CDI spec stale (libcuda missing)"
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
    fait "non-free repository enabled"
  fi
  case "$(uname -r)" in
    *-cloud-amd64) SUFFIX=cloud-amd64 ;;
    *-amd64) SUFFIX=amd64 ;;
    *) die "unrecognized Debian kernel: $(uname -r)" ;;
  esac
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o DPkg::Lock::Timeout=300 update
  apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends \
    "linux-image-${SUFFIX}" "linux-headers-${SUFFIX}" nvidia-driver nvidia-smi \
    libcuda1 pciutils
  fait "NVIDIA driver installed"
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
  fait "nvidia-container-toolkit installed"
fi

nvidia-ctk runtime configure --runtime=docker >/dev/null
install -d -m 0755 /var/run/cdi
if ! nvidia-ctk cdi generate --output=/var/run/cdi/nvidia.yaml >/dev/null 2>&1; then
  die "generating the NVIDIA CDI spec failed"
fi
fait "NVIDIA CDI spec regenerated"
systemctl restart docker
systemctl is-active --quiet docker || die "Docker does not restart after nvidia configuration"

if driver_ok && toolkit_ok && cdi_ok; then
  ok "GPU visible and Docker nvidia runtime active: $(nvidia-smi -L | head -n 1)"
  exit 0
fi
if ! driver_ok; then
  diagnose
  if ! smi_ok; then
    printf '[guest/nvidia] [WAIT] driver installed, guest reboot required\n'
    exit 3
  fi
  die "libcuda.so.1 still missing after installing libcuda1"
fi
die "Docker nvidia runtime or CDI spec incomplete after configuration"
