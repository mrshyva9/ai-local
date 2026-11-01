# ai-local — local AI on Debian 13 (GPU passthrough)

Two identical VMs, only the application changes:

```
Debian 13 host
├── bridge ailocal0 (10.0.10.1/24, ephemeral)
├── ollama-gpu  10.0.10.10  NVIDIA GPU passthrough → Ollama in a container
└── openwebui   10.0.10.11  Open WebUI in a container → http://10.0.10.10:11434
        aider (host) ─────────────────────────────────┘
```

Everything is replayable: `up` only does what is missing, otherwise prints `[OK]`.
Models, WebUI data and drivers live in the qcow2 disks.
The host keeps only the VFIO kernel configuration (GRUB, initramfs, modprobe),
the comfort tools and the aider client, installed in `~/.local/` during `up`.

## Prerequisites

- Debian 13, x86_64, VT-x/VT-d, 24 GiB of free RAM recommended, ≥ 20 GiB disk.
- Dedicated NVIDIA card whose two PCI functions are alone in their IOMMU
  group; the host display stays on the iGPU.
- Console access to the host: the GPU disappears from the host once VFIO is
  enabled.
- Internet access for downloads (image, Docker, driver, model).

## Commands

```sh
sudo ./bootstrap.sh up          # converge everything; exit 2 = reboot the host
./bootstrap.sh status           # readable state, without root
./bootstrap.sh check            # deviation from the contract, without root (exit 0/1)
./bootstrap.sh test             # end-to-end validation, without root
sudo ./bootstrap.sh down        # clean VM shutdown + network removal
./bootstrap.sh ssh ollama       # adm session in the VM (or: webui)
```

First run on a fresh host:

1. `sudo ./bootstrap.sh up` configures VFIO, prints `REBOOT REQUIRED`, exit 2.
2. Reboot the host manually.
3. `sudo ./bootstrap.sh up` downloads the image, creates both VMs, installs
   Docker, the NVIDIA driver, Ollama and Open WebUI, then pulls `gemma4:12b`
   (~8 GiB) and derives `gemma4:12b-agent` from `vm/apps/Modelfile`.
   Allow 20–40 min depending on the connection.

On subsequent runs, `up` must be almost immediate and print only `[OK]`.

## Access

| Service | URL |
|---|---|
| Ollama (API) | `http://10.0.10.10:11434` |
| Open WebUI | `http://10.0.10.11:3000` |
| aider | `./bin/aider-ollama` (model `ollama_chat/gemma4:12b-agent`) |

Open WebUI creates its administrator account on first access: the first
registered user becomes admin. Data persists in the disk of the `openwebui` VM.

## aider

```sh
cd ~/my-project
"$HOME/ai-local/bin/aider-ollama" file.py
"$HOME/ai-local/bin/aider-ollama" --model ollama_chat/gemma4:e2b   # override
```

The launcher sets `OLLAMA_API_BASE=http://10.0.10.10:11434` and prefixes the
model with `ollama_chat/` (without that prefix, aider fails with "LLM Provider
NOT provided"). Nothing is versioned: `up` downloads uv, Python 3.12 and aider
into `~/.local/` of the user who runs sudo.

## Model

`gemma4:12b` is pulled from the registry as the base. `up` then creates
`gemma4:12b-agent` from `vm/apps/Modelfile`: 64k context, temperature 0.1,
`top_p 0.95`, `top_k 64`, two stop tokens and an English OpenCode system prompt.
The Modelfile is copied into the VM only when its content changes, and the
derived model is rebuilt when it is missing or when the Modelfile changed.
A second `up` prints only `[OK]`.

## Comfort tools

`up` installs `vim`, `tmux`, `glow` and `rsync` on the host. The `ll` and `la`
aliases are checked in `~/.bashrc`; only missing aliases are added, an existing
definition is never replaced. Open a new shell (or `source ~/.bashrc`) to
activate them.

## Troubleshooting

```sh
./bootstrap.sh status
./bootstrap.sh check
tail -n 100 logs/ollama-gpu-console.log
tail -n 100 logs/openwebui-console.log
./bootstrap.sh ssh ollama
    docker ps -a; docker logs --tail 50 ollama; nvidia-smi
    docker exec ollama ollama ps          # must show 100% GPU
    docker exec ollama nvidia-smi -L
./bootstrap.sh ssh webui
    docker ps -a; docker logs --tail 50 open-webui
ls data/vm/*-seed-*.iso                    # cloud-init seeds, named by content
sudo ip -br link; sudo nft list ruleset
```

Typical repairs, all followed by `up`:

| Symptom | Action |
|---|---|
| bridge/TAP removed | `sudo ./bootstrap.sh up` (only the network is recreated) |
| container stopped | `docker restart ollama` in the VM, or `up` |
| VM stopped | `sudo ./bootstrap.sh up` |
| model deleted | `sudo ./bootstrap.sh up` (re-downloads and recreates it) |
| Modelfile modified | `sudo ./bootstrap.sh up` (recreates the derived model) |
| Ollama stays on CPU (`ollama ps`) | `up` checks `libcuda1` and regenerates the CDI spec |
| broken NVIDIA driver | `up` reinstalls it, then reboots the guest if needed |
| disk to rebuild | stop, delete `data/vm/<vm>.qcow2`, `up` |

`down` preserves disks, models and data. To start from scratch:
`sudo ./bootstrap.sh down`, then delete the relevant qcow2 files.

## Accepted limitations

- The Ollama API has **no authentication**: it only listens on the private
  `10.0.10.0/24` network, never on the LAN.
- Inside the VMs, `adm` belongs to the `docker` group (root-equivalent) and can
  run `sudo reboot` without a password. The VMs are disposable and not exposed.
- The private network is **ephemeral**: no systemd service, no persistence
  across boot. `up` recreates it.
- The full contract (acceptance matrix, decisions) is in
  [`OBJECTIFS.md`](OBJECTIFS.md).
