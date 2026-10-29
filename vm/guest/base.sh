#!/usr/bin/env bash
# Exécuté DANS l'invité, en root, via SSH. Installe Docker et le groupe adm.
set -Eeuo pipefail

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1
ok()    { printf '[invité/base] [OK]      %s\n' "$*"; }
fait()  { printf '[invité/base] [FAIT]    %s\n' "$*"; }
echec() { printf "[invité/base] [ÉCHEC]   %s\n" "$*"; }
die()   { echec "$*"; exit 1; }

check_all() {
  local fail=0
  command -v docker >/dev/null || { echec "docker absent"; fail=1; }
  systemctl is-active --quiet docker || { echec "service docker inactif"; fail=1; }
  docker compose version >/dev/null 2>&1 || { echec "plugin docker compose absent"; fail=1; }
  id -nG adm | grep -qw docker || { echec "adm n'est pas dans le groupe docker"; fail=1; }
  (( fail == 0 )) && ok "Docker, compose et groupe adm conformes"
  return "$fail"
}

if (( CHECK )); then check_all; exit $?; fi

if ! command -v docker >/dev/null 2>&1 || ! dpkg -s docker-ce >/dev/null 2>&1 ||
  ! docker compose version >/dev/null 2>&1; then
  install -d -m 0755 /etc/apt/keyrings
  curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
    https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o DPkg::Lock::Timeout=300 update
  apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fait "Docker installé depuis le dépôt officiel"
fi

systemctl enable --now docker
systemctl is-active --quiet docker || die "le service docker ne démarre pas"
if id -nG adm | grep -qw docker; then
  ok "adm déjà dans le groupe docker"
else
  usermod -aG docker adm
  fait "adm ajouté au groupe docker"
fi
docker compose version >/dev/null || die "plugin docker compose indisponible"
check_all
