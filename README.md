# ai-local — IA locale sur Debian 13 (GPU passthrough)

Deux VM identiques, seule l'application change :

```
hôte Debian 13
├── bridge ailocal0 (10.0.10.1/24, éphémère)
├── ollama-gpu  10.0.10.10  GPU NVIDIA en passthrough → Ollama en conteneur
└── openwebui   10.0.10.11  Open WebUI en conteneur → http://10.0.10.10:11434
        aider (hôte) ────────────────────────────────┘
```

Tout est rejouable : `up` ne fait que ce qui manque, sinon affiche `[OK]`.
Les modèles, les données WebUI et les pilotes vivent dans les disques qcow2.
L'hôte ne garde que la configuration noyau VFIO (GRUB, initramfs, modprobe), les
outils de confort et le client aider, installé dans `~/.local/` au moment du `up`.

## Prérequis

- Debian 13, x86_64, VT-x/VT-d, 24 Gio de RAM libres conseillés, ≥ 20 Gio disque.
- Carte NVIDIA dédiée dont les deux fonctions PCI sont seules dans leur groupe
  IOMMU ; l'affichage de l'hôte reste sur l'iGPU.
- Accès console à l'hôte : le GPU disparaît de l'hôte après activation VFIO.
- Sortie Internet pour les téléchargements (image, Docker, pilote, modèle).

## Commandes

```sh
sudo ./bootstrap.sh up          # converge tout ; exit 2 = redémarrer l'hôte
./bootstrap.sh status           # état lisible, sans root
./bootstrap.sh check            # écart au contrat, sans root (exit 0/1)
./bootstrap.sh test             # validation de bout en bout, sans root
sudo ./bootstrap.sh down        # arrêt propre des VM + retrait du réseau
./bootstrap.sh ssh ollama       # session adm dans la VM (ou : webui)
```

Premier lancement sur hôte vierge :

1. `sudo ./bootstrap.sh up` configure VFIO, affiche `REDÉMARRAGE REQUIS`, exit 2.
2. Redémarrer l'hôte à la main.
3. `sudo ./bootstrap.sh up` télécharge l'image, crée les deux VM, installe
   Docker, le pilote NVIDIA, Ollama, Open WebUI, puis `gemma4:12b` (~8 Gio).
   Compter 20–40 min selon la connexion.

Les fois suivantes, `up` doit être quasi immédiat et n'afficher que des `[OK]`.

## Accès

| Service | URL |
|---|---|
| Ollama (API) | `http://10.0.10.10:11434` |
| Open WebUI | `http://10.0.10.11:3000` |
| aider | `./bin/aider-ollama` (modèle `ollama_chat/gemma4:12b`) |

Open WebUI crée son compte administrateur au premier accès : le premier
utilisateur enregistré devient admin. Les données persistent dans le disque de
la VM `openwebui`.

## aider

```sh
cd ~/mon-projet
"$HOME/ai-local/bin/aider-ollama" fichier.py
"$HOME/ai-local/bin/aider-ollama" --model ollama_chat/gemma4:e2b   # override
```

Le lanceur fixe `OLLAMA_API_BASE=http://10.0.10.10:11434` et préfixe le modèle
avec `ollama_chat/` (sans ce préfixe, aider échoue avec « LLM Provider NOT
provided »). Rien n'est versionné : `up` télécharge uv, Python 3.12 et aider
dans `~/.local/` de l'utilisateur qui lance sudo.

## Outils de confort

`up` installe `vim`, `tmux`, `glow` et `rsync` sur l'hôte. Les alias `ll` et
`la` sont vérifiés dans `~/.bashrc` ; seuls les alias manquants sont ajoutés,
une définition existante n'est jamais remplacée. Ouvrir un nouveau shell (ou
`source ~/.bashrc`) pour les activer.

## Dépannage

```sh
./bootstrap.sh status
./bootstrap.sh check
tail -n 100 logs/ollama-gpu-console.log
tail -n 100 logs/openwebui-console.log
./bootstrap.sh ssh ollama
    docker ps -a; docker logs --tail 50 ollama; nvidia-smi
    docker exec ollama ollama ps          # doit afficher 100% GPU
    docker exec ollama nvidia-smi -L
./bootstrap.sh ssh webui
    docker ps -a; docker logs --tail 50 open-webui
ls data/vm/*-seed-*.iso                    # seeds cloud-init, nommés par contenu
sudo ip -br link; sudo nft list ruleset
```

Réparations typiques, toutes suivies de `up` :

| Symptôme | Geste |
|---|---|
| bridge/TAP supprimés | `sudo ./bootstrap.sh up` (seul le réseau est recréé) |
| conteneur arrêté | `docker restart ollama` dans la VM, ou `up` |
| VM arrêtée | `sudo ./bootstrap.sh up` |
| modèle supprimé | `sudo ./bootstrap.sh up` (retélécharge) |
| Ollama reste sur CPU (`ollama ps`) | `up` vérifie `libcuda1` et régénère le spec CDI |
| pilote NVIDIA cassé | `up` réinstalle puis redémarre l'invité si nécessaire |
| disque à refaire | arrêter, supprimer `data/vm/<vm>.qcow2`, `up` |

`down` conserve les disques, les modèles et les données. Pour repartir de zéro :
`sudo ./bootstrap.sh down`, puis supprimer les qcow2 concernés.

## Limites assumées

- L'API Ollama n'a **aucune authentification** : elle n'écoute que sur le
  réseau privé `10.0.10.0/24`, jamais sur le LAN.
- Dans les VM, `adm` appartient au groupe `docker` (équivalent root) et peut
  faire `sudo reboot` sans mot de passe. Les VM sont jetables et non exposées.
- Le réseau privé est **éphémère** : aucun service systemd, pas de persistance
  au boot. `up` le recrée.
- Le contrat complet (matrice d'acceptation, décisions) est dans
  [`OBJECTIFS.md`](OBJECTIFS.md).
