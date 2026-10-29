#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/config.sh"
STEP="image"
source "${ROOT}/common.sh"

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

BASE="${DATA}/${IMAGE_NAME}"

[[ -r "$OVMF_CODE" ]] || die "firmware absente : ${OVMF_CODE}"
[[ -r "$OVMF_VARS_TEMPLATE" ]] || die "modèle OVMF absent : ${OVMF_VARS_TEMPLATE}"

if [[ -f "$BASE" ]]; then
  printf '%s  %s\n' "$IMAGE_SHA512" "$BASE" | sha512sum --check --status ||
    die "empreinte SHA-512 invalide pour ${BASE} ; fichier préservé, le supprimer pour retélécharger"
  ok "image Debian présente et vérifiée"
  exit 0
fi

if (( CHECK )); then
  echec "image absente : ${BASE#"$ROOT"/}"
  exit 1
fi

require_root
attente "téléchargement de l'image Debian 13 (une seule fois)"
tmp="$(mktemp "${DATA}/.${IMAGE_NAME}.XXXXXX")"
if ! curl --fail --location --retry 3 --proto '=https' --tlsv1.2 --output "$tmp" "$IMAGE_URL"; then
  rm -f -- "$tmp"
  die "téléchargement de l'image impossible : ${IMAGE_URL}"
fi
if ! printf '%s  %s\n' "$IMAGE_SHA512" "$tmp" | sha512sum --check --status; then
  rm -f -- "$tmp"
  die "empreinte SHA-512 invalide pour l'image téléchargée"
fi
chmod 0640 "$tmp"
chown "$(caller_uid):$(caller_gid)" "$tmp"
mv -- "$tmp" "$BASE"
[[ -f "$BASE" ]] || die "image absente après téléchargement"
fait "image Debian téléchargée et vérifiée"
