#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/config.sh"
STEP="test"
source "${ROOT}/common.sh"

[[ "$(id -u)" -ne 0 ]] || die "run without sudo: ./bootstrap.sh test"
OLLAMA_IP="${VM_IP[ollama]}"
WEBUI_IP="${VM_IP[webui]}"
API="http://${OLLAMA_IP}:${OLLAMA_PORT}"

wait_api() {
  local deadline=$((SECONDS + 30))
  until curl -fsS --max-time 5 "${API}/api/version" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || return 1
    sleep 2
  done
}

test_ollama() {
  STEP="test/ollama"
  wait_api || { echec "Ollama API unreachable on ${API}"; return 1; }
  if ! curl -fsS --max-time 15 "${API}/api/tags" | python3 -c 'import json,sys
want = sys.argv[1]
for item in json.load(sys.stdin).get("models") or []:
    if (item.get("name") or item.get("model") or "") == want:
        sys.exit(0)
sys.exit(1)' "$MODEL"; then
    echec "model ${MODEL} missing from ${API}/api/tags"
    return 1
  fi
  ok "model ${MODEL} present"
  attente "test generation via ${MODEL} (may take a few minutes)"
  local answer
  answer="$(curl -fsS --max-time 300 -X POST "${API}/api/generate" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL}\",\"prompt\":\"What is the result of 17 + 25? Answer with the number only.\",\"stream\":false}" |
    python3 -c 'import json,sys; print((json.load(sys.stdin).get("response") or "").strip())' 2>/dev/null)" ||
    { echec "/api/generate request failed"; return 1; }
  [[ -n "$answer" ]] || { echec "empty response from ${MODEL}"; return 1; }
  grep -q '42' <<<"$answer" || { echec "unexpected response from ${MODEL}: ${answer:0:120}"; return 1; }
  ok "response received: ${answer:0:80}"
}

test_ollama_gpu() {
  STEP="test/ollama-gpu"
  local sizes size vram
  sizes="$(curl -fsS --max-time 15 "${API}/api/ps" | python3 -c 'import json,sys
models = json.load(sys.stdin).get("models") or []
if not models:
    print("0 0")
else:
    m = max(models, key=lambda x: int(x.get("size_vram") or 0))
    print(int(m.get("size") or 0), int(m.get("size_vram") or 0))' 2>/dev/null)" ||
    { echec "GET /api/ps failed"; return 1; }
  [[ -n "$sizes" ]] || { echec "empty /api/ps response"; return 1; }
  read -r size vram <<<"$sizes"
  [[ "$size" =~ ^[0-9]+$ && "$vram" =~ ^[0-9]+$ ]] ||
    { echec "unreadable sizes in /api/ps"; return 1; }
  if (( size == 0 )); then
    echec "model missing from /api/ps"
    return 1
  elif (( vram == 0 )); then
    echec "model loaded without VRAM: Ollama is using the CPU"
    return 1
  elif (( vram < size )); then
    echec "partial offload: ${vram}/${size} bytes in VRAM ($(( vram * 100 / size )) %)"
    return 1
  else
    ok "model fully on GPU (${vram} bytes in VRAM out of ${size})"
  fi
}

test_webui_to_ollama() {
  STEP="test/webui→ollama"
  if timeout 30 ssh "${SSH_OPTS[@]}" "root@${WEBUI_IP}" \
    "docker exec -i open-webui python3 -" <<'PY'
import os
import urllib.request

base = os.environ.get("OLLAMA_BASE_URL") or os.environ["OLLAMA_BASE_URLS"].split(";")[0]
url = base.rstrip("/") + "/api/tags"
with urllib.request.urlopen(url, timeout=10) as response:
    if response.status != 200:
        raise SystemExit(f"HTTP {response.status}")
print("ok")
PY
  then ok "the Open WebUI container reaches Ollama on ${API}"
  else echec "the Open WebUI container cannot reach Ollama on ${API}"; return 1
  fi
}

test_webui_health() {
  STEP="test/webui"
  local code
  code="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' "http://${WEBUI_IP}:${WEBUI_PORT}/health" || true)"
  if [[ "$code" == "200" ]]; then ok "Open WebUI responds on http://${WEBUI_IP}:${WEBUI_PORT}"
  else echec "Open WebUI does not respond (HTTP ${code:-none}) on ${WEBUI_IP}:${WEBUI_PORT}"; return 1; fi
}

test_aider() {
  STEP="test/aider"
  local sandbox="${ROOT}/data/test/aider" output rc
  install -d -m 0755 "$sandbox"
  if [[ ! -d "${sandbox}/.git" ]]; then
    git init -q "$sandbox"
    git -C "$sandbox" config user.email "test@ai-local.invalid"
    git -C "$sandbox" config user.name "ai-local"
    printf 'ai-local validation sandbox.\n' >"${sandbox}/README.md"
    git -C "$sandbox" add README.md
    git -C "$sandbox" commit -qm "init: sandbox"
  fi
  attente "calling aider in non-interactive mode"
  set +e
  output="$(cd "$sandbox" && timeout 600 "${ROOT}/bin/aider-ollama" \
    --message "What is the result of 17 + 25? Answer with the number only." \
    --yes-always --no-auto-commits --no-check-update 2>&1)"
  rc=$?
  set -e
  if (( rc != 0 )); then
    echec "aider failed (code ${rc}):"
    printf '%s\n' "$output" | tail -n 15
    return 1
  fi
  if ! grep -q '42' <<<"$output"; then
    echec "aider responded without the expected result (42):"
    printf '%s\n' "$output" | tail -n 15
    return 1
  fi
  ok "aider ${AIDER_VERSION} responded via ollama_chat/${MODEL}"
}

fail=0
if test_ollama; then test_ollama_gpu || fail=1; else fail=1; fi
test_webui_to_ollama || fail=1
test_webui_health || fail=1
test_aider || fail=1

STEP="test"
if (( fail == 0 )); then result "OK"; else result "FAIL"; fi
exit "$fail"
