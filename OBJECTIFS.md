# OBJECTIVES and CONSTRAINTS — ai-local

> **Status: contract.** This document is authoritative. The code complies with
> it; in case of disagreement, the code is at fault. Any change to the contract
> is made in the same commit as the code that applies it.
>
> Version 3 — 2026-11-01. English translation; output vocabulary is now English.
> Replaces the single-VM contract of `ollama-gpu`.

## 0. Reading order

- Sections 1–3: mission, non-goals, constraints.
- Sections 4–8: tree, observable contract, steps, specifications.
- Sections 9–12: proof, agent rules, troubleshooting, risks.
- Sections 13–14: decisions and definition of done.

## 1. Mission

A single repository, short scripts, one launcher. `up` brings to a Debian 13
host a complete local AI chain, replayable and repairable by hand:

```
aider (host) ──► Ollama (VM 1, GPU passthrough, container)
Open WebUI (VM 2, container) ──► Ollama
```

User stories:

1. Everything runs: `sudo ./bootstrap.sh up` prints only `[OK]`, exit 0.
2. After a host reboot: the same command recreates the network, VMs and
   containers, preserves models and data, then answers `Result: OK`.
3. Fresh host: `up` configures VFIO, answers `REBOOT REQUIRED`, exit 2; after a
   manual reboot, `up` completes.
4. Without an AI token and without reading the code, an administrator diagnoses
   with `status`, `check`, `test` and the commands in section 11.
5. `./bootstrap.sh test` proves the end-to-end path: host → Ollama API,
   WebUI container → Ollama, host → WebUI, host → aider → Ollama.

## 2. Non-goals

Forbidden, unless explicitly decided in section 13:

- **No host persistence**: no systemd service, daemon, cron, logrotate, state
  file, "installed" marker. The only exceptions are the VFIO kernel
  configuration (section 6.2), the requested Debian packages, uv/aider in
  `~/.local/` and the aliases in `~/.bashrc`.
- **No binaries in the repository**: uv, Python 3.12 and aider are downloaded
  at install time into `~/.local/`. `data/` only contains VM artifacts (images,
  disks, seeds, keys). Nothing in `/opt` or `/usr/local`; `/etc` stays reserved
  for VFIO.
- **No third VM**, no reverse proxy, no multi-host, no high availability, no
  Kubernetes.
- **No home-grown framework**: no logging library, no global redirection, no
  `trap ERR/EXIT`, no programmatic YAML generation, no state file.
- **No review process**: no `report/*` branch, no hook, no report, no evolving
  status. Direct commits on `main`.
- **No secret tracked by Git**: the SSH key is generated in `data/ssh/`
  (ignored).

## 3. Hard constraints

1. **Host**: Debian 13, x86_64, VT-x/VT-d, `/dev/kvm`, dedicated NVIDIA card
   whose two PCI functions are alone in their IOMMU group, iGPU for display,
   ≥ 20 GiB free.
2. **Guests**: Debian 13 genericcloud pinned by version and SHA-512, user
   `adm`, SSH key only, fixed IP on the private network.
3. **Imposed tree** (section 4). No file outside this list.
4. **Size**: ≤ 1700 lines of shell in total (excluding cloud-init), no script
   longer than 220 lines, `common.sh` ≤ 30 lines.
5. **Host dependencies**: packages from section 6.1, `qemu-system-x86_64`,
   `qemu-img`, `cloud-localds`, `ssh`, `curl`, `sha256sum`, `sha512sum`, `ip`,
   `brctl`, `nft`, `python3`, `git`, `tar`, `vim`, `tmux`, `glow`, `rsync`.
   Aider is installed by uv, itself downloaded and verified by SHA-256, into
   the caller's `~/.local/`.
6. **Idempotence**: second consecutive `up` = only `[OK]`, no change, exit 0.
7. **Synchronous**: no background installation. Each action is printed while it
   runs. A Ctrl-C leaves a resumable state.
8. **State is the system.** No state file. The only runtime artifacts are
   `run/<vm>.pid`, `run/<vm>.qmp`, revalidated against the real process before
   use.
9. **English** for messages and documentation.
10. **Files created in the repository**: owned by the caller
    (`SUDO_UID`/`SUDO_GID`), never hard-coded `root:root`. Guest logs and data
    belong to `adm` in the VM.
11. **Never reboot the host automatically.** Guest reboots are allowed and
    expected (NVIDIA driver).
12. **Ephemeral private network.** Created by `up`, removed by `down`.

## 4. Tree

```
ai-local/
├── bootstrap.sh          launcher: up | check | status | down | test | ssh
├── config.sh             parameters: network, GPU, image, versions, model, VMs
├── common.sh             contractual output, root, caller (≤ 30 lines)
├── bin/
│   └── aider-ollama      aider launcher (model ollama_chat/<model>)
├── host/
│   ├── 00-prereq.sh      host checks, packages, SSH key, directories
│   ├── 10-vfio.sh        VFIO kernel configuration (exit 2 = reboot required)
│   ├── 20-network.sh     bridge, TAP, NAT, forwarding (ephemeral)
│   ├── 30-app.sh         syncs the compose and installs the app in a VM
│   ├── 30-aider.sh       downloads uv + aider into ~/.local/
│   └── 40-test.sh        end-to-end validation
├── vm/
│   ├── 10-image.sh       Debian image (SHA-512), once only
│   ├── 20-lifecycle.sh   disk, seed, UEFI, QEMU, SSH, shutdown via QMP
│   ├── guest/
│   │   ├── base.sh       Docker + compose, adm group
│   │   ├── nvidia.sh     NVIDIA driver + Docker GPU runtime
│   │   ├── ollama.sh     Ollama container + GPU
│   │   └── openwebui.sh  Open WebUI container
│   ├── apps/
│   │   ├── Modelfile     derived model (64k context, OpenCode prompt)
│   │   ├── ollama.yaml   Ollama compose (models in a bind mount)
│   │   └── openwebui.yaml Open WebUI compose (Ollama URL)
│   └── cloud-init/       user-data, meta-data, network-config
├── data/                 images, disks, seeds, UEFI, keys (gitignore)
├── logs/                 consoles and traces (gitignore)
├── run/                  pids, QMP sockets (gitignore)
├── OBJECTIFS.md
└── README.md
```

## 5. Interface contract

### 5.1 Launcher

| Command | Effect | Codes |
|---|---|---|
| `sudo ./bootstrap.sh up [vm...]` | converge everything, or only the named VMs | 0 OK, 1 failure, 2 host reboot required |
| `./bootstrap.sh check [vm...]` | read-only, changes nothing | 0 compliant, 1 non-compliant |
| `./bootstrap.sh status` | overview of host, VMs, containers, API, model | 0 always |
| `sudo ./bootstrap.sh down [vm...\|all]` | clean shutdown, network removal | 0 OK, 1 failure |
| `./bootstrap.sh test` | end-to-end validation | 0 OK, 1 failure |
| `./bootstrap.sh ssh <ollama\|webui>` | `adm` session in the VM | SSH code |

`up [vm...]` with a subset only starts those VMs (the network and image remain
shared). `check` and `status` are used without root; checks that require root
(`nft`) are marked `[SKIP]` and do not invalidate the result.

### 5.2 Step scripts

- `host/NN-*.sh` and `vm/NN-*.sh`: `--check` (read-only, 0/1) or converge;
  executable alone, in order.
- `vm/20-lifecycle.sh`: `up|check|status|down <vm>`.
- `host/30-app.sh`: `<vm>` (converge), `check <vm>`, `status <vm>`.
- `host/30-aider.sh`: converge, `--check`, `--status`.
- `10-vfio.sh` returns **2** when it has modified the kernel configuration; the
  launcher stops and does not try the rest.

### 5.3 Output vocabulary

```
[host/vfio]      [OK]      GPU already bound to vfio-pci
[network]        [DONE]    bridge ailocal0 created (10.0.10.1/24)
[guest/ollama]   [OK]      ollama container active, API and GPU compliant
[test/aider]     [OK]      aider 0.86.2 responded via ollama_chat/gemma4:12b-agent
Result: OK
```

Tokens: `[OK]` (already compliant), `[DONE]` (changed), `[WAIT]` (long),
`[SKIP]` (not applicable without root), `[FAIL]` (blocking + diagnostics).
Last line: `Result: OK` | `Result: REBOOT REQUIRED` | `Result: FAIL`.

## 6. Host steps

### 6.1 `00-prereq.sh`

Debian 13, x86_64, VT-x, `/dev/kvm`, two PCI functions present, ≥ 20 GiB free,
required commands and packages. Installs if missing: `qemu-system-x86`,
`qemu-utils`, `ovmf`, `cloud-image-utils`, `bridge-utils`, `iproute2`,
`nftables`, `curl`, `openssh-client`, `initramfs-tools`, `grub2-common`,
`python3`, `git`, `vim`, `tmux`, `glow`, `rsync`. Creates `data/vm`, `data/ssh`,
`logs`, `run` and an ed25519 key in `data/ssh/`, owned by the caller. Checks
`alias ll=` and `alias la=` in `~/.bashrc` and only adds missing aliases,
never replacing an existing definition.

### 6.2 `10-vfio.sh`

Guarantees exactly:

- `/etc/modprobe.d/ai-local-vfio.conf`:
  `options vfio-pci ids=10de:2805,10de:22bd`,
  `softdep nouveau pre: vfio-pci`, `softdep snd_hda_intel pre: vfio-pci`;
- `/etc/modprobe.d/ai-local-blacklist.conf`: `blacklist nouveau`;
- `vfio`, `vfio_pci`, `vfio_iommu_type1` in `/etc/initramfs-tools/modules`;
- `intel_iommu=on iommu=pt` in `GRUB_CMDLINE_LINUX_DEFAULT`.

If a file changes: single backup `*.ai-local.bak`, `update-initramfs -u`,
`update-grub`, then exit 2. If both functions are already bound to `vfio-pci`
and the IOMMU group contains only them: `[OK]`.

### 6.3 `20-network.sh`

- bridge `ailocal0`, `10.0.10.1/24`;
- TAP `tap-ollama` and `tap-webui` (tap mode, root), attached, up;
- `net.ipv4.ip_forward=1`;
- `nftables` table: forward policy drop, established accepted, VM↔VM accepted,
  `10.0.10.0/24` → WAN accepted; masquerade to the default interface.

No service, no persistent file. `--down` removes rules, TAP and bridge.

### 6.4 `vm/10-image.sh`

Image `debian-13-genericcloud-amd64-20261026-2643.qcow2` downloaded from a
versioned URL, SHA-512 verified on every pass, kept in `data/vm/`. If the file
exists but the checksum differs: failure, file preserved.

### 6.5 `vm/20-lifecycle.sh <vm>`

- qcow2 disk with a backing file, created once, never resized;
- `OVMF_VARS` copied once per VM;
- cloud-init seed rebuilt from `vm/cloud-init/*` (`sed` substitution) and
  replaced **only** if its content changes; instance-id derived from content;
- QEMU: vCPU/RAM from `config.sh`, 4M UEFI, virtio disk, seed CD-ROM, TAP,
  fixed MAC, `vfio-pci` GPU for `ollama` only, QMP and pidfile in `run/`,
  console in `logs/`, `-daemonize`;
- PID validation before any `[OK]` or shutdown; stale artifacts cleaned up;
- real SSH wait (root key), 300 s;
- `down`: ACPI via QMP, 120 s, then SIGTERM/SIGKILL after revalidation.

### 6.6 `host/30-app.sh <vm>`

1. checks root SSH;
2. runs `vm/guest/base.sh` (Docker + compose + `adm` group);
3. renders the compose from `vm/apps/<app>.yaml` with the values from
   `config.sh`, compares its SHA-256 with the copy in
   `/home/adm/<app>/compose.yaml`, copies it if different and then requests a
   container recreation;
4. for `ollama`, does the same with `vm/apps/Modelfile` (rendered with
   `MODEL_BASE`) and `/home/adm/ollama/Modelfile`;
5. for `ollama`, runs `vm/guest/nvidia.sh`; on code 3, reboots the guest, waits
   for SSH, retries once;
6. runs `vm/guest/<app>.sh`;
7. for `ollama`, ensures `MODEL_BASE` is in `/api/tags` (pull if absent), then
   creates `MODEL` with `docker exec ollama ollama create -f` when it is
   missing or when the Modelfile changed.

`check` runs the same scripts with `--check` and compares the compose and the
Modelfile; `status` shows container, API, base model and derived model.

### 6.7 `host/30-aider.sh`

Installs uv (pinned version and SHA-256) into `~/.local/bin/uv`, Python 3.12 and
`aider-chat==0.86.2` under the caller's `~/.local/{share/uv,bin}`. Nothing is
versioned. The `bin/aider-ollama` launcher sets `OLLAMA_API_BASE` and prefixes
the model with `ollama_chat/`. `--check` verifies uv, aider, launcher, API and
model; `--status` is informational and changes nothing.

### 6.8 `host/40-test.sh`

Without root. In order, stopping at the first failure for readability:

1. host → `GET /api/version` then `GET /api/tags` (model present);
2. host → `POST /api/generate` (non-empty response) then `GET /api/ps`
   (`size_vram == size`, so the model runs entirely on the GPU);
3. `open-webui` container → `OLLAMA_BASE_URL/api/tags` (via `docker exec`);
4. host → `GET http://10.0.10.11:3000/health` (HTTP 200);
5. aider non-interactively in `data/test/aider`: response containing `42`
   (question `17 + 25`, whose operands do not appear in the expected answer),
   exit code 0.

## 7. Guest specification

### 7.1 Account and access

- user `adm`, SSH key from the host, no password;
- `adm` member of the `docker` group (created by the Docker package);
- `adm` can run `docker`, `docker compose` and `sudo reboot`;
- single rule `/etc/sudoers.d/90-ai-local-reboot` (0440, validated by
  `visudo -c`): `adm ALL=(root) NOPASSWD: /usr/sbin/reboot`; no
  `NOPASSWD: ALL`;
- provisioning: **root** SSH by key, on the private network only
  (`PermitRootLogin prohibit-password`, `AllowUsers adm root`);
- cloud-init: pinned image, `resize_rootfs`, `qemu-guest-agent`, `curl`,
  `gnupg`, `ca-certificates`, `sudo`, `openssh-server`.

### 7.2 `vm/guest/base.sh` (root)

Enables the official Docker repository (`docker.sources` + key), installs
`docker-ce docker-ce-cli containerd.io docker-buildx-plugin
docker-compose-plugin`, enables Docker, adds `adm` to the `docker` group.
Idempotent: docker active + compose + group = `[OK]`.

### 7.3 `vm/guest/nvidia.sh` (root)

Enables `non-free`, installs `linux-image/headers-<cloud-amd64|amd64>`,
`nvidia-driver`, `nvidia-smi`, `libcuda1`, `pciutils`. Installs
`nvidia-container-toolkit` from its official repository, runs
`nvidia-ctk runtime configure --runtime=docker`, regenerates the CDI spec
`/var/run/cdi/nvidia.yaml`, restarts Docker. `libcuda1` is essential: without
it `nvidia-smi` works but Ollama sees no CUDA backend and falls back to CPU.
If `nvidia-smi` still fails: exit **3** (the host reboots the guest and retries
once). If the runtime or the CDI spec remains incomplete: diagnostics and
exit 1.

### 7.4 `vm/guest/ollama.sh` (root)

`/home/adm/ollama/compose.yaml` (copied by the host):

```yaml
services:
  ollama:
    image: ollama/ollama:0.40.12
    container_name: ollama
    restart: unless-stopped
    ports: ["10.0.10.10:11434:11434"]
    volumes: ["/home/adm/ollama/models:/root/.ollama"]
    environment: ["OLLAMA_HOST=0.0.0.0:11434"]
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
```

`docker compose up -d`, wait for API + `nvidia-smi` **and** `libcuda.so.1` in
the container (180 s). `AILOCAL_RECREATE=1` or a container without CUDA forces
`--force-recreate` when the compose or GPU access has changed.

### 7.5 `vm/guest/openwebui.sh` (root)

`/home/adm/openwebui/compose.yaml`: image
`ghcr.io/open-webui/open-webui:v0.12.4`, port `10.0.10.11:3000:8080`, data in
`/home/adm/openwebui/data`, `OLLAMA_BASE_URL` **and** `OLLAMA_BASE_URLS`
pointing to `http://10.0.10.10:11434`. Wait for `/health` (180 s).

### 7.6 Model

`config.sh` defines `MODEL_BASE="gemma4:12b"` (pulled from the registry) and
`MODEL="gemma4:12b-agent"` (derived). `vm/apps/Modelfile` sets `num_ctx 65536`,
`temperature 0.1`, `top_p 0.95`, `top_k 64`, the stops `<|turn|>` and
`<|file|>`, and an English OpenCode system prompt. Base present = `[OK]`; absent =
`docker exec ollama ollama pull`. The derived model is recreated with
`ollama create` when it is missing or when the Modelfile changed. Another model
is requested from aider with `--model`; the default does not change.

## 8. Idempotence

Each step follows: `if <real check>; [OK]; otherwise act; [DONE]`.
Forbidden: reinstalling a present package, recreating an existing object,
re-running a pull for a present model, restarting a running VM, rewriting an
identical file, re-running `docker compose up` without a change. An `up` on a
compliant system produces only `[OK]`.

The only systematic action: rebuilding the cloud-init seed in memory, followed
by a binary comparison; the file is replaced only if it differs.

## 9. Acceptance matrix

To be run on the real machine, without a test harness or fake `ssh`.

| # | Manipulation | Expected |
|---|---|---|
| A | `sudo ./bootstrap.sh up` twice | 2nd pass: only `[OK]`, exit 0 |
| B | reboot host then `up` | network, VMs, containers recreated; models and data preserved; `test` OK |
| C | `down` then `up` | network absent then recreated; disks and models intact |
| D | `sudo ip link del ailocal0` then `up` | only the network is recreated |
| E | `ssh ollama docker stop ollama` then `up` | only the Ollama container is restarted |
| F | `ssh ollama sudo reboot`, wait, then `up` | container restarted, API and GPU OK |
| G | `ssh ollama docker exec ollama ollama rm gemma4:12b-agent` then `up` | derived model recreated, then `[OK]` |
| H | fresh host | `up` → REBOOT REQUIRED (2) → reboot → `up` → `test` OK |
| I | `check` compliant / VM stopped | exit 0 / exit 1 |
| J | `up` interrupted (Ctrl-C) during guest install | rerun resumes without duplication |
| K | `ssh webui docker stop open-webui` then `up` | WebUI container restarted, `test` OK |
| L | modify `OLLAMA_BASE_URL` in the webui VM compose, then `test` | `test` fails (webui→ollama); `up` reinstalls the compose, recreates the container, `test` OK |

Budget: compliant `up` < 90 s (health included), `check` < 30 s, `test` < 10 min
(depending on model speed).

## 10. Agent rules

1. Read `OBJECTIFS.md` in full, then `README.md`.
2. Run `./bootstrap.sh check` before any change, and after. A change is only
   complete once `check` is back to 0.
3. Smallest possible change. No opportunistic refactoring, renaming or
   reorganization.
4. Do not add files outside section 4, nor dependencies outside section 6.1,
   nor exceed the budgets.
5. Never fix by adding: a state file, a service, a marker, a library, an
   abstraction layer, a hidden variable.
6. Git: direct commits on `main`, one commit = one change, message
   `what: why`. No branch, hook, report or `--force`.
7. Ambiguous requirement or impossible test: stop, write the question in
   `TODO.md` (and only there), do not guess.
8. Do not modify this contract without an explicit request; the code that
   applies a contract change is in the same commit.
9. Never weaken a check to make a test pass.
10. Verify at least A, B and `test` before concluding.

## 11. Reference troubleshooting

```sh
./bootstrap.sh status
./bootstrap.sh check
./bootstrap.sh test
tail -n 100 logs/ollama-gpu-console.log
tail -n 100 logs/openwebui-console.log
./bootstrap.sh ssh ollama
    docker ps -a
    docker logs --tail 50 ollama
    nvidia-smi
    docker exec ollama nvidia-smi -L
    docker exec ollama ollama list
./bootstrap.sh ssh webui
    docker ps -a
    docker logs --tail 50 open-webui
    curl -s http://10.0.10.10:11434/api/tags
curl -s http://10.0.10.10:11434/api/tags
curl -s http://10.0.10.11:3000/health
ps -ef | grep qemu-system
sudo nft list ruleset
ip -br link
```

Repairs:

- network removed → `sudo ./bootstrap.sh up`;
- container stopped → `docker restart <name>` or `up`;
- compose modified by hand → `up` reinstalls it and recreates the container;
- model deleted → `up` re-downloads it;
- broken NVIDIA driver → `up` reinstalls it and reboots the guest if needed;
- corrupted disk → `down`, delete `data/vm/<vm>.qcow2`, `up`.

## 12. Known risks

- The GPU leaves the host once VFIO is enabled: console access is essential.
- The IOMMU group must contain exactly the two GPU functions; otherwise
  `10-vfio.sh` fails on purpose.
- The Ollama API has no authentication: it only listens on `10.0.10.0/24`.
- The `docker` group is root-equivalent inside a VM; the VMs are not exposed
  to the LAN.
- `gemma4:12b` weighs several GB and the derived 64k context uses ~10 GiB of
  VRAM; the first `up` is long and depends on the network.
- A change of image or driver may require recreating a disk; models must then
  be re-downloaded.
- 31 GiB of RAM are needed for 16 GiB (Ollama) + 8 GiB (WebUI) + host.

## 13. Decisions

| # | Decision | Reason |
|---|---|---|
| ADR-1 | VFIO is the only persistent host state | without it the GPU stays taken at boot |
| ADR-2 | Ollama and Open WebUI in containers | pinned versions, `docker compose` as the interface |
| ADR-3 | Two identical VMs, only the application changes | replayable install, isolation |
| ADR-4 | Models and data in bind mounts inside the VMs | visible, backupable, repairable |
| ADR-5 | Ephemeral network, no systemd service | removes the boot failure point |
| ADR-6 | No state file; state is observed | removes marker/reality divergences |
| ADR-7 | Host reboot never automatic; guest reboot yes | the administrator stays in control |
| ADR-8 | Provisioning over root SSH by key, private network | `adm` keeps narrow rights |
| ADR-9 | uv/aider downloaded at install time into `~/.local/` | no binaries in the repository, replayable install |
| ADR-10 | `gemma4:12b-agent` derived from `gemma4:12b` by default | user choice; 64k context and low temperature fit in 16 GiB of VRAM |
| ADR-11 | `test` separate from `check` | `check` fast and local; `test` costly and end-to-end |
| ADR-12 | Direct commits on `main`, no review | the process had outgrown the code |
| ADR-13 | `vim`, `tmux`, `glow`, `rsync` and `ll`/`la` aliases on the host | requested comfort, without a service or binary in the repository |

## 14. Definition of done

- [ ] No file outside section 4, no tracked secret.
- [ ] `wc -l` of the scripts ≤ 1700, no script > 220 lines, `common.sh` ≤ 30.
- [ ] Scenarios A to L passed on the real machine.
- [ ] `down` leaves the host without bridge, TAP or nft rule.
- [ ] `check` exit 0 on a compliant system, exit 1 when a VM is stopped.
- [ ] `test` validates the four paths (host→Ollama, WebUI→Ollama,
      host→WebUI, host→aider).
- [ ] `up` on a compliant system prints only `[OK]`.
- [ ] `vim`, `tmux`, `glow`, `rsync` present and `ll`/`la` aliases active.
- [ ] `README.md` is enough for an administrator who has never read the code.
- [ ] `data/`, `logs/`, `run/` ignored by Git.
