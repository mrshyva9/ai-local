#!/usr/bin/env bash
# Project parameters. No logic, no secrets.
# Sourced by every script; do not execute anything here.

PROJECT="ai-local"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DATA="${ROOT}/data/vm"
KEYS="${ROOT}/data/ssh"
LOGS="${ROOT}/logs"
RUN="${ROOT}/run"
GUEST_USER="adm"
GUEST_HOME="/home/${GUEST_USER}"

# --- Host private network (ephemeral, recreated on every up) -----------------
BRIDGE="ailocal0"
SUBNET="10.0.10.0/24"
SUBNET_PREFIX="${SUBNET#*/}"
BRIDGE_IP="10.0.10.1"
DNS1="1.1.1.1"
DNS2="9.9.9.9"
NFT_FWD="ailocal"
NFT_NAT="ailocal_nat"

# --- GPU (both functions must share the same IOMMU group) --------------------
GPU_VIDEO="0000:01:00.0"
GPU_AUDIO="0000:01:00.1"
GPU_IDS="10de:2805,10de:22bd"

# --- Guest image (pinned version: the URL, unlike "latest") ------------------
IMAGE_VERSION="20261026-2643"
IMAGE_NAME="debian-13-genericcloud-amd64-${IMAGE_VERSION}.qcow2"
IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/${IMAGE_VERSION}/${IMAGE_NAME}"
IMAGE_SHA512="3ace18e33bdd036edb49d1f79342bd01d2ab980e35194edb0b410435cd543538d286a0bd13bbb0835f7862306e3d385ce2f6a70d8ecf0bd961111166adbc1b8e"
OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS_TEMPLATE="/usr/share/OVMF/OVMF_VARS_4M.fd"

# --- Applications ------------------------------------------------------------
OLLAMA_IMAGE="ollama/ollama:0.40.12"
OLLAMA_PORT="11434"
MODEL="gemma4:12b"
WEBUI_IMAGE="ghcr.io/open-webui/open-webui:v0.12.4"
WEBUI_PORT="3000"
WEBUI_INTERNAL_PORT="8080"

# --- Host client: uv and aider are downloaded at install time ----------------
# Nothing is versioned or stored in the repository: everything goes to ~/.local.
AIDER_VERSION="0.86.2"
AIDER_PYTHON="3.12"
UV_VERSION="0.13.5"
UV_SHA256="f68d291c75783122dad58ab77def0e13f3233f358731db5d6d7e8715603b928f"

# --- VM definitions: same architecture, only the application changes --------
VMS=(ollama webui)

declare -A VM_NAME VM_IP VM_MAC VM_VCPUS VM_RAM_MIB VM_DISK_GIB VM_TAP VM_GPU VM_APP VM_CONTAINER
VM_NAME[ollama]="ollama-gpu"
VM_IP[ollama]="10.0.10.10"
VM_MAC[ollama]="52:54:00:aa:00:01"
VM_VCPUS[ollama]=8
VM_RAM_MIB[ollama]=16384
VM_DISK_GIB[ollama]=100
VM_TAP[ollama]="tap-ollama"
VM_GPU[ollama]=1
VM_APP[ollama]="ollama"
VM_CONTAINER[ollama]="ollama"

VM_NAME[webui]="openwebui"
VM_IP[webui]="10.0.10.11"
VM_MAC[webui]="52:54:00:aa:00:02"
VM_VCPUS[webui]=4
VM_RAM_MIB[webui]=8192
VM_DISK_GIB[webui]=60
VM_TAP[webui]="tap-webui"
VM_GPU[webui]=0
VM_APP[webui]="openwebui"
VM_CONTAINER[webui]="open-webui"

# --- SSH to guests (key and known_hosts stay in the repository) --------------
SSH_OPTS=(
  -i "${KEYS}/id_ed25519"
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o UserKnownHostsFile="${KEYS}/known_hosts"
  -o StrictHostKeyChecking=accept-new
  -o LogLevel=ERROR
)

# Return the username owning the caller.
caller_uid() { printf '%s' "${SUDO_UID:-$(id -u)}"; }
caller_gid() { printf '%s' "${SUDO_GID:-$(id -g)}"; }
caller_name() { id -un "$(caller_uid)"; }
