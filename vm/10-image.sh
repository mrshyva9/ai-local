#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/config.sh"
STEP="image"
source "${ROOT}/common.sh"

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

BASE="${DATA}/${IMAGE_NAME}"

[[ -r "$OVMF_CODE" ]] || die "firmware missing: ${OVMF_CODE}"
[[ -r "$OVMF_VARS_TEMPLATE" ]] || die "OVMF template missing: ${OVMF_VARS_TEMPLATE}"

if [[ -f "$BASE" ]]; then
  printf '%s  %s\n' "$IMAGE_SHA512" "$BASE" | sha512sum --check --status ||
    die "invalid SHA-512 for ${BASE}; file preserved, delete it to re-download"
  ok "Debian image present and verified"
  exit 0
fi

if (( CHECK )); then
  echec "image missing: ${BASE#"$ROOT"/}"
  exit 1
fi

require_root
attente "downloading the Debian 13 image (once)"
tmp="$(mktemp "${DATA}/.${IMAGE_NAME}.XXXXXX")"
if ! curl --fail --location --retry 3 --proto '=https' --tlsv1.2 --output "$tmp" "$IMAGE_URL"; then
  rm -f -- "$tmp"
  die "image download failed: ${IMAGE_URL}"
fi
if ! printf '%s  %s\n' "$IMAGE_SHA512" "$tmp" | sha512sum --check --status; then
  rm -f -- "$tmp"
  die "invalid SHA-512 for the downloaded image"
fi
chmod 0640 "$tmp"
chown "$(caller_uid):$(caller_gid)" "$tmp"
mv -- "$tmp" "$BASE"
[[ -f "$BASE" ]] || die "image missing after download"
fait "Debian image downloaded and verified"
