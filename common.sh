#!/usr/bin/env bash
# Contractual output and minimal helpers.
# Forbidden here: global redirection, trap, install function.

STEP="${STEP:-general}"

ok()      { printf '[%s] [OK]      %s\n' "$STEP" "$*"; }
fait()    { printf '[%s] [DONE]    %s\n' "$STEP" "$*"; }
attente() { printf '[%s] [WAIT]    %s\n' "$STEP" "$*"; }
saute()   { printf '[%s] [SKIP]    %s\n' "$STEP" "$*"; }
echec()   { printf '[%s] [FAIL]    %s\n' "$STEP" "$*"; }
result()  { printf '\nResult: %s\n' "$1"; }
die()     { echec "$*"; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "run with sudo"
}

# Run a command as the calling user (useful when the script runs as root).
as_caller() {
  local uid name home
  uid="$(caller_uid)"
  if [[ "$uid" == "$(id -u)" ]]; then
    "$@"
  else
    name="$(caller_name)"
    home="$(getent passwd "$uid" | cut -d: -f6)"
    runuser -u "$name" -- env HOME="$home" USER="$name" LOGNAME="$name" "$@"
  fi
}
