#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/config.sh"
STEP="hôte/vfio"
source "${ROOT}/common.sh"

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

VFIO_CONF="/etc/modprobe.d/${PROJECT}-vfio.conf"
BLACKLIST_CONF="/etc/modprobe.d/${PROJECT}-blacklist.conf"
MODULES_FILE="/etc/initramfs-tools/modules"
GRUB_FILE="/etc/default/grub"
MODULES=(vfio vfio_pci vfio_iommu_type1)

vfio_content="options vfio-pci ids=${GPU_IDS}
softdep nouveau pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci"

driver_of() {
  local path
  path="$(readlink -f "/sys/bus/pci/devices/$1/driver" 2>/dev/null || true)"
  [[ -n "$path" ]] && basename "$path"
}

bound_ok() {
  [[ "$(driver_of "$GPU_VIDEO")" == "vfio-pci" &&
     "$(driver_of "$GPU_AUDIO")" == "vfio-pci" ]]
}

group_ok() {
  local vg ag found expected
  vg="$(readlink -f "/sys/bus/pci/devices/${GPU_VIDEO}/iommu_group" 2>/dev/null || true)"
  ag="$(readlink -f "/sys/bus/pci/devices/${GPU_AUDIO}/iommu_group" 2>/dev/null || true)"
  [[ -n "$vg" && "$vg" == "$ag" ]] || return 1
  found="$(find "${vg}/devices" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)"
  expected="$(printf '%s\n' "$GPU_AUDIO" "$GPU_VIDEO" | sort)"
  [[ "$found" == "$expected" ]]
}

files_ok() {
  cmp -s "$VFIO_CONF" <(printf '%s\n' "$vfio_content") || return 1
  cmp -s "$BLACKLIST_CONF" <(printf 'blacklist nouveau\n') || return 1
  local module
  for module in "${MODULES[@]}"; do
    grep -qxF "$module" "$MODULES_FILE" || return 1
  done
  grep -q 'intel_iommu=on' "$GRUB_FILE" && grep -q 'iommu=pt' "$GRUB_FILE"
}

if (( CHECK )); then
  fail=0
  files_ok || { echec "fichiers noyau/GRUB non conformes"; fail=1; }
  group_ok || { echec "groupe IOMMU absent ou contenant d'autres périphériques"; fail=1; }
  bound_ok || { echec "GPU non lié à vfio-pci (redémarrage en attente ?)"; fail=1; }
  (( fail == 0 )) || exit 1
  ok "GPU lié à vfio-pci, configuration noyau conforme"
  exit 0
fi

require_root

changed=0

if ! cmp -s "$VFIO_CONF" <(printf '%s\n' "$vfio_content"); then
  if [[ ! -e "${VFIO_CONF}.${PROJECT}.bak" && -e "$VFIO_CONF" ]]; then
    cp -a "$VFIO_CONF" "${VFIO_CONF}.${PROJECT}.bak"
  fi
  printf '%s\n' "$vfio_content" >"$VFIO_CONF"
  chmod 0644 "$VFIO_CONF"
  changed=1
  fait "options vfio-pci écrites"
fi

if ! cmp -s "$BLACKLIST_CONF" <(printf 'blacklist nouveau\n'); then
  if [[ ! -e "${BLACKLIST_CONF}.${PROJECT}.bak" && -e "$BLACKLIST_CONF" ]]; then
    cp -a "$BLACKLIST_CONF" "${BLACKLIST_CONF}.${PROJECT}.bak"
  fi
  printf 'blacklist nouveau\n' >"$BLACKLIST_CONF"
  chmod 0644 "$BLACKLIST_CONF"
  changed=1
  fait "nouveau blacklisté"
fi

for module in "${MODULES[@]}"; do
  if ! grep -qxF "$module" "$MODULES_FILE"; then
    printf '%s\n' "$module" >>"$MODULES_FILE"
    changed=1
    fait "module ajouté à initramfs : ${module}"
  fi
done

if ! grep -q 'intel_iommu=on' "$GRUB_FILE" || ! grep -q 'iommu=pt' "$GRUB_FILE"; then
  [[ -e "${GRUB_FILE}.${PROJECT}.bak" ]] || cp -a "$GRUB_FILE" "${GRUB_FILE}.${PROJECT}.bak"
  for param in intel_iommu=on iommu=pt; do
    grep -q "$param" "$GRUB_FILE" && continue
    sed -i -E "s/^(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*)\"/\1 ${param}\"/" "$GRUB_FILE"
  done
  grep -q 'intel_iommu=on' "$GRUB_FILE" && grep -q 'iommu=pt' "$GRUB_FILE" ||
    die "GRUB_CMDLINE_LINUX_DEFAULT non reconnu dans ${GRUB_FILE}"
  changed=1
  fait "paramètres IOMMU ajoutés à GRUB"
fi

if (( changed )); then
  attente "régénération initramfs et GRUB"
  update-initramfs -u
  update-grub
  fait "initramfs et GRUB régénérés"
fi

if ! group_ok; then
  die "le groupe IOMMU de ${GPU_VIDEO} ne contient pas exactement ${GPU_VIDEO} et ${GPU_AUDIO} ; un redémarrage n'y changerait rien"
fi

if bound_ok; then
  ok "GPU lié à vfio-pci"
  exit 0
fi

attente "redémarrage de l'hôte requis pour activer vfio-pci"
exit 2
