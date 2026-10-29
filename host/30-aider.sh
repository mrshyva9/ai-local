#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/config.sh"
STEP="hôte/aider"
source "${ROOT}/common.sh"

MODE=install
case "${1:-}" in
  --check) MODE=check ;;
  --status) MODE=status ;;
  "") ;;
  *) die "usage : $0 [--check|--status]" ;;
esac

UV_BIN="${CLIENT}/uv/uv"
AIDER_BIN="${CLIENT}/bin/aider"
WRAPPER="${ROOT}/bin/aider-ollama"
export UV_PYTHON_INSTALL_DIR="${CLIENT}/python"
export UV_TOOL_DIR="${CLIENT}/tools"
export UV_TOOL_BIN_DIR="${CLIENT}/bin"
export UV_CACHE_DIR="${CLIENT}/cache"

uv_version() { "$UV_BIN" --version 2>/dev/null | awk '{print $2}'; }
aider_version() { "$AIDER_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1; }
api_version() {
  curl -fsS --max-time 10 "http://${VM_IP[ollama]}:${OLLAMA_PORT}/api/version" 2>/dev/null |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' 2>/dev/null
}
model_present() {
  curl -fsS --max-time 10 "http://${VM_IP[ollama]}:${OLLAMA_PORT}/api/tags" 2>/dev/null |
    python3 -c 'import json,sys
want = sys.argv[1]
for item in json.load(sys.stdin).get("models") or []:
    if (item.get("name") or item.get("model") or "") == want:
        sys.exit(0)
sys.exit(1)' "$MODEL" 2>/dev/null
}

report() {
  local fail=0 api_ok=0
  if [[ -x "$UV_BIN" ]] && [[ "$(uv_version)" == "$UV_VERSION" ]]; then ok "uv ${UV_VERSION}"
  else echec "uv ${UV_VERSION} absent (${UV_BIN})"; fail=1; fi
  if [[ -x "$AIDER_BIN" ]] && [[ "$(aider_version)" == "$AIDER_VERSION" ]]; then ok "aider ${AIDER_VERSION}"
  else echec "aider ${AIDER_VERSION} absent (${AIDER_BIN})"; fail=1; fi
  if [[ -x "$WRAPPER" ]]; then ok "lanceur ${WRAPPER#${ROOT}/}"
  else echec "lanceur absent : ${WRAPPER#${ROOT}/}"; fail=1; fi
  if version="$(api_version)" && [[ -n "$version" ]]; then
    ok "API Ollama ${version} sur ${VM_IP[ollama]}:${OLLAMA_PORT}"
    api_ok=1
  else echec "API Ollama injoignable sur ${VM_IP[ollama]}:${OLLAMA_PORT}"; fail=1; fi
  if (( api_ok )); then
    if model_present; then ok "modèle ${MODEL} présent"
    else echec "modèle ${MODEL} absent"; fail=1; fi
  else
    saute "modèle ${MODEL} non vérifié (API injoignable)"
  fi
  return "$fail"
}

if [[ "$MODE" == "status" ]]; then
  report || true
  exit 0
fi

if [[ "$MODE" == "check" ]]; then
  report
  exit $?
fi

[[ "$(id -u)" -ne 0 ]] || die "lancer sans sudo : l'installation appartient à l'utilisateur appelant"
command -v curl >/dev/null || die "curl absent"
command -v python3 >/dev/null || die "python3 absent"

install_uv() {
  local tmp arch
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64-unknown-linux-gnu" ;;
    *) die "architecture non gérée : $(uname -m)" ;;
  esac
  install -d -m 0755 "${CLIENT}/uv"
  if [[ -x "$UV_BIN" ]] && [[ "$(uv_version)" == "$UV_VERSION" ]]; then
    ok "uv ${UV_VERSION} déjà installé"
    return 0
  fi
  tmp="$(mktemp -d "${CLIENT}/uv.XXXXXX")"
  if ! curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
    -o "${tmp}/uv.tar.gz" \
    "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${arch}.tar.gz"; then
    rm -rf -- "$tmp"; die "téléchargement de uv ${UV_VERSION} impossible"
  fi
  if ! printf '%s  %s\n' "$UV_SHA256" "${tmp}/uv.tar.gz" | sha256sum --check --status; then
    rm -rf -- "$tmp"; die "somme SHA-256 invalide pour uv ${UV_VERSION}"
  fi
  tar -xzf "${tmp}/uv.tar.gz" -C "$tmp"
  install -m 0755 "${tmp}/uv-${arch}/uv" "$UV_BIN"
  rm -rf -- "$tmp"
  fait "uv ${UV_VERSION} installé dans ${CLIENT#${ROOT}/}"
}

install_aider() {
  if [[ -x "$AIDER_BIN" ]] && [[ "$(aider_version)" == "$AIDER_VERSION" ]]; then
    ok "aider ${AIDER_VERSION} déjà installé"
    return 0
  fi
  attente "installation de Python ${AIDER_PYTHON} et aider ${AIDER_VERSION}"
  "$UV_BIN" python install "$AIDER_PYTHON" >/dev/null
  "$UV_BIN" tool install --force --python "$AIDER_PYTHON" "aider-chat==${AIDER_VERSION}" >/dev/null ||
    die "installation d'aider ${AIDER_VERSION} impossible"
  [[ -x "$AIDER_BIN" ]] || die "aider absent après installation"
  fait "aider ${AIDER_VERSION} installé dans ${CLIENT#${ROOT}/}"
}

install_uv
install_aider
[[ -x "$WRAPPER" ]] || die "lanceur absent du dépôt : ${WRAPPER#${ROOT}/}"
report || die "aider est installé mais la chaîne Ollama n'est pas prête (voir [ÉCHEC])"
