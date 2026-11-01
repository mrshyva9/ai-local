#!/usr/bin/env bash
# Executed INSIDE the guest, as root, over SSH. Installs Docker and the adm group.
set -Eeuo pipefail

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1
ok()    { printf '[guest/base] [OK]      %s\n' "$*"; }
fait()  { printf '[guest/base] [DONE]    %s\n' "$*"; }
echec() { printf "[guest/base] [FAIL]    %s\n" "$*"; }
die()   { echec "$*"; exit 1; }

check_all() {
  local fail=0
  command -v docker >/dev/null || { echec "docker missing"; fail=1; }
  systemctl is-active --quiet docker || { echec "docker service inactive"; fail=1; }
  docker compose version >/dev/null 2>&1 || { echec "docker compose plugin missing"; fail=1; }
  id -nG adm | grep -qw docker || { echec "adm is not in the docker group"; fail=1; }
  (( fail == 0 )) && ok "Docker, compose and adm group compliant"
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
  fait "Docker installed from the official repository"
fi

systemctl enable --now docker
systemctl is-active --quiet docker || die "the docker service does not start"
if id -nG adm | grep -qw docker; then
  ok "adm already in the docker group"
else
  usermod -aG docker adm
  fait "adm added to the docker group"
fi
docker compose version >/dev/null || die "docker compose plugin unavailable"
check_all
