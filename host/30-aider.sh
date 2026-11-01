#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/config.sh"
STEP="host/aider"
source "${ROOT}/common.sh"

MODE=install
case "${1:-}" in
  --check) MODE=check ;;
  --status) MODE=status ;;
  "") ;;
  *) die "usage: $0 [--check|--status]" ;;
esac

# uv and aider are downloaded at install time, into the caller's HOME.
USER_HOME="$(getent passwd "$(caller_uid)" | cut -d: -f6)"
[[ -n "$USER_HOME" && -d "$USER_HOME" ]] || die "home directory not found"
LOCAL_BIN="${USER_HOME}/.local/bin"
UV_BIN="${LOCAL_BIN}/uv"
AIDER_BIN="${LOCAL_BIN}/aider"
WRAPPER="${ROOT}/bin/aider-ollama"
export UV_PYTHON_INSTALL_DIR="${USER_HOME}/.local/share/uv/python"
export UV_TOOL_DIR="${USER_HOME}/.local/share/uv/tools"
export UV_TOOL_BIN_DIR="${LOCAL_BIN}"
export UV_CACHE_DIR="${USER_HOME}/.cache/uv"

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
  else echec "uv ${UV_VERSION} missing (${UV_BIN})"; fail=1; fi
  if [[ -x "$AIDER_BIN" ]] && [[ "$(aider_version)" == "$AIDER_VERSION" ]]; then ok "aider ${AIDER_VERSION}"
  else echec "aider ${AIDER_VERSION} missing (${AIDER_BIN})"; fail=1; fi
  if [[ -x "$WRAPPER" ]]; then ok "launcher ${WRAPPER#${ROOT}/}"
  else echec "launcher missing: ${WRAPPER#${ROOT}/}"; fail=1; fi
  if version="$(api_version)" && [[ -n "$version" ]]; then
    ok "Ollama API ${version} on ${VM_IP[ollama]}:${OLLAMA_PORT}"
    api_ok=1
  else echec "Ollama API unreachable on ${VM_IP[ollama]}:${OLLAMA_PORT}"; fail=1; fi
  if (( api_ok )); then
    if model_present; then ok "model ${MODEL} present"
    else echec "model ${MODEL} missing"; fail=1; fi
  else
    saute "model ${MODEL} not checked (API unreachable)"
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

[[ "$(id -u)" -ne 0 ]] || die "run without sudo: the installation belongs to the calling user"
command -v curl >/dev/null || die "curl missing"
command -v python3 >/dev/null || die "python3 missing"

install_uv() {
  local tmp arch
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64-unknown-linux-gnu" ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
  if [[ -x "$UV_BIN" ]] && [[ "$(uv_version)" == "$UV_VERSION" ]]; then
    ok "uv ${UV_VERSION} already installed"
    return 0
  fi
  install -d -m 0755 "$LOCAL_BIN"
  tmp="$(mktemp -d "${LOCAL_BIN}/.uv.XXXXXX")"
  if ! curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
    -o "${tmp}/uv.tar.gz" \
    "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${arch}.tar.gz"; then
    rm -rf -- "$tmp"; die "downloading uv ${UV_VERSION} failed"
  fi
  if ! printf '%s  %s\n' "$UV_SHA256" "${tmp}/uv.tar.gz" | sha256sum --check --status; then
    rm -rf -- "$tmp"; die "invalid SHA-256 for uv ${UV_VERSION}"
  fi
  tar -xzf "${tmp}/uv.tar.gz" -C "$tmp"
  install -m 0755 "${tmp}/uv-${arch}/uv" "$UV_BIN"
  rm -rf -- "$tmp"
  fait "uv ${UV_VERSION} installed in ${LOCAL_BIN}"
}

install_aider() {
  if [[ -x "$AIDER_BIN" ]] && [[ "$(aider_version)" == "$AIDER_VERSION" ]]; then
    ok "aider ${AIDER_VERSION} already installed"
    return 0
  fi
  attente "downloading Python ${AIDER_PYTHON} and aider ${AIDER_VERSION}"
  "$UV_BIN" python install "$AIDER_PYTHON" >/dev/null
  "$UV_BIN" tool install --force --python "$AIDER_PYTHON" "aider-chat==${AIDER_VERSION}" >/dev/null ||
    die "installing aider ${AIDER_VERSION} failed"
  [[ -x "$AIDER_BIN" ]] || die "aider missing after installation"
  fait "aider ${AIDER_VERSION} installed in ${LOCAL_BIN}"
}

install_uv
install_aider
[[ -x "$WRAPPER" ]] || die "launcher missing from repository: ${WRAPPER#${ROOT}/}"
report || die "aider is installed but the Ollama chain is not ready (see [FAIL])"
