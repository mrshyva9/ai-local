#!/usr/bin/env bash
# Sortie contractuelle et aides minimales.
# Interdit ici : redirection globale, trap, fonction d'installation.

STEP="${STEP:-général}"

ok()      { printf '[%s] [OK]      %s\n' "$STEP" "$*"; }
fait()    { printf '[%s] [FAIT]    %s\n' "$STEP" "$*"; }
attente() { printf '[%s] [ATTENTE] %s\n' "$STEP" "$*"; }
saute()   { printf '[%s] [SAUTÉ]   %s\n' "$STEP" "$*"; }
echec()   { printf '[%s] [ÉCHEC]   %s\n' "$STEP" "$*"; }
result()  { printf '\nRésultat : %s\n' "$1"; }
die()     { echec "$*"; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "lancer avec sudo"
}

# Exécute une commande en tant qu'appelant (utile quand le script tourne en root).
as_caller() {
  local uid name
  uid="$(caller_uid)"
  if [[ "$uid" == "$(id -u)" ]]; then
    "$@"
  else
    name="$(caller_name)"
    runuser -u "$name" -- "$@"
  fi
}
