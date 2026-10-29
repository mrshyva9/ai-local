#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/config.sh"
STEP="test"
source "${ROOT}/common.sh"

[[ "$(id -u)" -ne 0 ]] || die "lancer sans sudo : ./bootstrap.sh test"
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
  wait_api || { echec "API Ollama injoignable sur ${API}"; return 1; }
  if ! curl -fsS --max-time 15 "${API}/api/tags" | python3 -c 'import json,sys
want = sys.argv[1]
for item in json.load(sys.stdin).get("models") or []:
    if (item.get("name") or item.get("model") or "") == want:
        sys.exit(0)
sys.exit(1)' "$MODEL"; then
    echec "modèle ${MODEL} absent de ${API}/api/tags"
    return 1
  fi
  ok "modèle ${MODEL} présent"
  attente "génération de test via ${MODEL} (peut prendre quelques minutes)"
  local answer
  answer="$(curl -fsS --max-time 300 -X POST "${API}/api/generate" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL}\",\"prompt\":\"Quel est le résultat de 17 + 25 ? Réponds uniquement par le nombre.\",\"stream\":false}" |
    python3 -c 'import json,sys; print((json.load(sys.stdin).get("response") or "").strip())' 2>/dev/null)" ||
    { echec "requête /api/generate en échec"; return 1; }
  [[ -n "$answer" ]] || { echec "réponse vide de ${MODEL}"; return 1; }
  grep -q '42' <<<"$answer" || { echec "réponse inattendue de ${MODEL} : ${answer:0:120}"; return 1; }
  ok "réponse reçue : ${answer:0:80}"
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
  then ok "le conteneur Open WebUI joint Ollama sur ${API}"
  else echec "le conteneur Open WebUI ne joint pas Ollama sur ${API}"; return 1
  fi
}

test_webui_health() {
  STEP="test/webui"
  local code
  code="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' "http://${WEBUI_IP}:${WEBUI_PORT}/health" || true)"
  if [[ "$code" == "200" ]]; then ok "Open WebUI répond sur http://${WEBUI_IP}:${WEBUI_PORT}"
  else echec "Open WebUI ne répond pas (HTTP ${code:-aucun}) sur ${WEBUI_IP}:${WEBUI_PORT}"; return 1; fi
}

test_aider() {
  STEP="test/aider"
  local sandbox="${ROOT}/data/test/aider" output rc
  install -d -m 0755 "$sandbox"
  if [[ ! -d "${sandbox}/.git" ]]; then
    git init -q "$sandbox"
    git -C "$sandbox" config user.email "test@ai-local.invalid"
    git -C "$sandbox" config user.name "ai-local"
    printf 'Bac à sable de validation ai-local.\n' >"${sandbox}/README.md"
    git -C "$sandbox" add README.md
    git -C "$sandbox" commit -qm "init: bac à sable"
  fi
  attente "appel d'aider en mode non interactif"
  set +e
  output="$(cd "$sandbox" && timeout 600 "${ROOT}/bin/aider-ollama" \
    --message "Quel est le résultat de 17 + 25 ? Réponds uniquement par le nombre." \
    --yes-always --no-auto-commits --no-check-update 2>&1)"
  rc=$?
  set -e
  if (( rc != 0 )); then
    echec "aider a échoué (code ${rc}) :"
    printf '%s\n' "$output" | tail -n 15
    return 1
  fi
  if ! grep -q '42' <<<"$output"; then
    echec "aider a répondu sans le résultat attendu (42) :"
    printf '%s\n' "$output" | tail -n 15
    return 1
  fi
  ok "aider ${AIDER_VERSION} a répondu via ollama_chat/${MODEL}"
}

fail=0
test_ollama || fail=1
test_webui_to_ollama || fail=1
test_webui_health || fail=1
test_aider || fail=1

STEP="test"
if (( fail == 0 )); then result "OK"; else result "ÉCHEC"; fi
exit "$fail"
