# OBJECTIFS et CONTRAINTES — ai-local

> **Statut : contrat.** Ce document fait foi. Le code s'y conforme ; en cas de
> désaccord, c'est le code qui est en tort. Toute évolution du contrat se fait
> dans le même commit que le code qui l'applique.
>
> Version 2 — 2026-10-29. Remplace le contrat mono-VM de `ollama-gpu`.

## 0. Lecture

- Sections 1–3 : mission, non-objectifs, contraintes.
- Sections 4–8 : arborescence, contrat observable, étapes, spécifications.
- Sections 9–12 : preuve, règles agent, dépannage, risques.
- Sections 13–14 : décisions et définition de terminé.

## 1. Mission

Un dépôt unique, des scripts courts, un lanceur. `up` apporte sur un hôte
Debian 13 une chaîne d'IA locale complète, rejouable et réparable à la main :

```
aider (hôte) ──► Ollama (VM 1, GPU passthrough, conteneur)
Open WebUI (VM 2, conteneur) ──► Ollama
```

Récits utilisateur :

1. Tout tourne : `sudo ./bootstrap.sh up` n'affiche que des `[OK]`, exit 0.
2. Après reboot de l'hôte : la même commande recrée réseau, VM, conteneurs,
   conserve modèles et données, puis répond `Résultat : OK`.
3. Hôte vierge : `up` configure VFIO, répond `REDÉMARRAGE REQUIS`, exit 2 ; après
   reboot manuel, `up` termine.
4. Sans jeton d'IA et sans lire le code, un administrateur diagnostique avec
   `status`, `check`, `test` et les commandes de la section 11.
5. `./bootstrap.sh test` prouve le chemin de bout en bout : hôte → API Ollama,
   conteneur WebUI → Ollama, hôte → WebUI, hôte → aider → Ollama.

## 2. Non-objectifs

Interdits, sauf décision explicite en section 13 :

- **Aucune persistance hôte** : pas de service systemd, démon, cron, logrotate,
  fichier d'état, marqueur « installé ». Les seules exceptions sont la
  configuration noyau VFIO (section 6.2), les paquets Debian demandés,
  uv/aider dans `~/.local/` et les alias dans `~/.bashrc`.
- **Pas de binaires dans le dépôt** : uv, Python 3.12 et aider sont téléchargés
  à l'installation dans `~/.local/`. `data/` ne contient que les artefacts de
  VM (images, disques, seeds, clés). Rien dans `/opt` ou `/usr/local` ; `/etc`
  reste réservé à VFIO.
- **Pas de troisième VM**, pas de reverse proxy, pas de multi-hôte, pas de
  haute disponibilité, pas de Kubernetes.
- **Pas de framework maison** : pas de bibliothèque de journalisation, pas de
  redirection globale, pas de `trap ERR/EXIT`, pas de génération de YAML par
  programme, pas de state file.
- **Pas de process de revue** : pas de branche `report/*`, pas de hook, pas de
  rapport, pas de statut à faire évoluer. Commits directs sur `main`.
- **Aucun secret suivi par Git** : la clé SSH est générée dans `data/ssh/`
  (ignoré).

## 3. Contraintes dures

1. **Hôte** : Debian 13, x86_64, VT-x/VT-d, `/dev/kvm`, carte NVIDIA dédiée dont
   les deux fonctions PCI sont seules dans leur groupe IOMMU, iGPU pour
   l'affichage, ≥ 20 Gio libres.
2. **Invités** : Debian 13 genericcloud figée par version et SHA-512, utilisateur
   `adm`, clé SSH uniquement, IP fixe sur le réseau privé.
3. **Arborescence imposée** (section 4). Aucun fichier hors de cette liste.
4. **Taille** : ≤ 1700 lignes de shell au total (hors cloud-init), aucun script
   de plus de 220 lignes, `common.sh` ≤ 30 lignes.
5. **Dépendances hôte** : paquets de la section 6.1, `qemu-system-x86_64`,
   `qemu-img`, `cloud-localds`, `ssh`, `curl`, `sha256sum`, `sha512sum`, `ip`,
   `brctl`, `nft`, `python3`, `git`, `tar`, `vim`, `tmux`, `glow`, `rsync`.
   Aider est installé par uv, lui-même téléchargé et vérifié par SHA-256, dans
   `~/.local/` de l'appelant.
6. **Idempotence** : deuxième `up` consécutif = uniquement des `[OK]`, aucune
   modification, exit 0.
7. **Synchrone** : aucune installation en arrière-plan. Chaque action est
   affichée pendant qu'elle s'exécute. Un Ctrl-C laisse un état reprenable.
8. **L'état, c'est le système.** Aucun fichier de state. Les seuls artefacts
   runtime sont `run/<vm>.pid`, `run/<vm>.qmp`, revalidés contre le processus
   réel avant usage.
9. **Français** pour les messages et la documentation.
10. **Fichiers créés dans le dépôt** : propriété de l'appelant
    (`SUDO_UID`/`SUDO_GID`), jamais `root:root` en dur. Les logs et données des
    invités appartiennent à `adm` dans la VM.
11. **Jamais de redémarrage automatique de l'hôte.** Les redémarrages d'invité
    sont autorisés et attendus (pilote NVIDIA).
12. **Réseau privé éphémère.** Créé par `up`, retiré par `down`.

## 4. Arborescence

```
ai-local/
├── bootstrap.sh          lanceur : up | check | status | down | test | ssh
├── config.sh             paramètres : réseau, GPU, image, versions, modèle, VM
├── common.sh             sortie contractuelle, root, appelant (≤ 30 lignes)
├── bin/
│   └── aider-ollama      lanceur aider (modèle ollama_chat/<modèle>)
├── host/
│   ├── 00-prereq.sh      contrôles hôte, paquets, clé SSH, répertoires
│   ├── 10-vfio.sh        configuration noyau VFIO (exit 2 = reboot requis)
│   ├── 20-network.sh     bridge, TAP, NAT, forwarding (éphémère)
│   ├── 30-app.sh         synchronise le compose et installe l'app dans une VM
│   ├── 30-aider.sh       télécharge uv + aider dans ~/.local/
│   └── 40-test.sh        validation de bout en bout
├── vm/
│   ├── 10-image.sh       image Debian (SHA-512), une seule fois
│   ├── 20-lifecycle.sh   disque, seed, UEFI, QEMU, SSH, arrêt par QMP
│   ├── guest/
│   │   ├── base.sh       Docker + compose, groupe adm
│   │   ├── nvidia.sh     pilote NVIDIA + runtime Docker GPU
│   │   ├── ollama.sh     conteneur Ollama + GPU
│   │   └── openwebui.sh  conteneur Open WebUI
│   ├── apps/
│   │   ├── ollama.yaml   compose Ollama (modèles en bind mount)
│   │   └── openwebui.yaml compose Open WebUI (URL Ollama)
│   └── cloud-init/       user-data, meta-data, network-config
├── data/                 images, disques, seeds, UEFI, clés (gitignore)
├── logs/                 consoles et traces (gitignore)
├── run/                  pid, sockets QMP (gitignore)
├── OBJECTIFS.md
└── README.md
```

## 5. Contrat d'interface

### 5.1 Lanceur

| Commande | Effet | Codes |
|---|---|---|
| `sudo ./bootstrap.sh up [vm...]` | converge tout, ou seulement les VM nommées | 0 OK, 1 échec, 2 reboot hôte requis |
| `./bootstrap.sh check [vm...]` | lecture seule, ne modifie rien | 0 conforme, 1 non conforme |
| `./bootstrap.sh status` | panorama hôte, VM, conteneurs, API, modèle | 0 toujours |
| `sudo ./bootstrap.sh down [vm...\|all]` | arrêt propre, retrait réseau | 0 OK, 1 échec |
| `./bootstrap.sh test` | validation de bout en bout | 0 OK, 1 échec |
| `./bootstrap.sh ssh <ollama\|webui>` | session `adm` dans la VM | code SSH |

`up [vm...]` avec un sous-ensemble ne démarre que ces VM (le réseau et l'image
restent communs). `check` et `status` s'utilisent sans root ; les contrôles qui
exigent root (`nft`) sont marqués `[SAUTÉ]` et n'invalident pas le résultat.

### 5.2 Scripts d'étape

- `host/NN-*.sh` et `vm/NN-*.sh` : `--check` (lecture seule, 0/1) ou converge ;
  exécutables seuls, dans l'ordre.
- `vm/20-lifecycle.sh` : `up|check|status|down <vm>`.
- `host/30-app.sh` : `<vm>` (converge), `check <vm>`, `status <vm>`.
- `host/30-aider.sh` : converge, `--check`, `--status`.
- `10-vfio.sh` retourne **2** quand il a modifié la configuration noyau ; le
  lanceur s'arrête et n'essaie pas la suite.

### 5.3 Vocabulaire de sortie

```
[hôte/vfio]      [OK]      GPU déjà lié à vfio-pci
[réseau]         [FAIT]    bridge ailocal0 créé (10.0.10.1/24)
[invité/ollama]  [OK]      conteneur ollama actif, API et GPU conformes
[test/aider]     [OK]      aider 0.86.2 a répondu via ollama_chat/gemma4:12b
Résultat : OK
```

Jetons : `[OK]` (déjà conforme), `[FAIT]` (modifié), `[ATTENTE]` (long),
`[SAUTÉ]` (non applicable sans root), `[ÉCHEC]` (bloquant + diagnostic).
Dernière ligne : `Résultat : OK` | `Résultat : REDÉMARRAGE REQUIS` |
`Résultat : ÉCHEC`.

## 6. Étapes hôte

### 6.1 `00-prereq.sh`

Debian 13, x86_64, VT-x, `/dev/kvm`, deux fonctions PCI présentes, ≥ 20 Gio
libres, commandes et paquets requis. Installe si absent : `qemu-system-x86`,
`qemu-utils`, `ovmf`, `cloud-image-utils`, `bridge-utils`, `iproute2`,
`nftables`, `curl`, `openssh-client`, `initramfs-tools`, `grub2-common`,
`python3`, `git`, `vim`, `tmux`, `glow`, `rsync`. Crée `data/vm`, `data/ssh`,
`logs`, `run` et une clé ed25519 dans `data/ssh/`, propriété de l'appelant.
Vérifie `alias ll=` et `alias la=` dans `~/.bashrc` et n'ajoute que les alias
manquants, sans jamais remplacer une définition existante.

### 6.2 `10-vfio.sh`

Garantit exactement :

- `/etc/modprobe.d/ai-local-vfio.conf` :
  `options vfio-pci ids=10de:2805,10de:22bd`,
  `softdep nouveau pre: vfio-pci`, `softdep snd_hda_intel pre: vfio-pci` ;
- `/etc/modprobe.d/ai-local-blacklist.conf` : `blacklist nouveau` ;
- `vfio`, `vfio_pci`, `vfio_iommu_type1` dans `/etc/initramfs-tools/modules` ;
- `intel_iommu=on iommu=pt` dans `GRUB_CMDLINE_LINUX_DEFAULT`.

Si un fichier change : sauvegarde unique `*.ai-local.bak`, `update-initramfs -u`,
`update-grub`, puis exit 2. Si les deux fonctions sont déjà liées à `vfio-pci`
et que le groupe IOMMU ne contient qu'elles : `[OK]`.

### 6.3 `20-network.sh`

- bridge `ailocal0`, `10.0.10.1/24` ;
- TAP `tap-ollama` et `tap-webui` (mode tap, root), rattachés, up ;
- `net.ipv4.ip_forward=1` ;
- table `nftables` : forward policy drop, établissement accepté, VM↔VM accepté,
  `10.0.10.0/24` → WAN accepté ; masquerade vers l'interface par défaut.

Aucun service, aucun fichier persistant. `--down` retire règles, TAP et bridge.

### 6.4 `vm/10-image.sh`

Image `debian-13-genericcloud-amd64-20261026-2643.qcow2` téléchargée depuis une
URL versionnée, vérifiée SHA-512 à chaque passage, conservée dans `data/vm/`.
Si le fichier existe mais que l'empreinte diffère : échec, fichier préservé.

### 6.5 `vm/20-lifecycle.sh <vm>`

- disque qcow2 à backing file, créé une fois, jamais redimensionné ;
- `OVMF_VARS` copié une fois par VM ;
- seed cloud-init reconstruit depuis `vm/cloud-init/*` (substitution `sed`) et
  remplacé **seulement** si son contenu change ; instance-id dérivé du contenu ;
- QEMU : vCPU/RAM de `config.sh`, UEFI 4M, disque virtio, seed CD-ROM, TAP,
  MAC fixe, GPU `vfio-pci` pour `ollama` seulement, QMP et pidfile dans `run/`,
  console dans `logs/`, `-daemonize` ;
- validation du PID avant tout `[OK]` ou arrêt ; artefacts périmés nettoyés ;
- attente SSH réelle (clé root), 300 s ;
- `down` : ACPI par QMP, 120 s, puis SIGTERM/SIGKILL après revalidation.

### 6.6 `host/30-app.sh <vm>`

1. vérifie SSH root ;
2. exécute `vm/guest/base.sh` (Docker + compose + groupe `adm`) ;
3. rend le compose depuis `vm/apps/<app>.yaml` avec les valeurs de `config.sh`,
   compare son SHA-256 à la copie dans `/home/adm/<app>/compose.yaml`, le copie
   si différent et demande alors une recréation du conteneur ;
4. pour `ollama`, exécute `vm/guest/nvidia.sh` ; sur code 3, redémarre l'invité,
   attend SSH, réessaie une fois ;
5. exécute `vm/guest/<app>.sh` ;
6. pour `ollama`, vérifie `MODEL` dans `/api/tags`, sinon
   `docker exec ollama ollama pull "$MODEL"`.

`check` exécute les mêmes scripts en `--check` et compare le compose ;
`status` affiche conteneur, API et modèle.

### 6.7 `host/30-aider.sh`

Installe uv (version et SHA-256 épinglés) dans `~/.local/bin/uv`, Python 3.12 et
`aider-chat==0.86.2` sous `~/.local/{share/uv,bin}` de l'appelant. Rien n'est
versionné. Le lanceur `bin/aider-ollama` fixe `OLLAMA_API_BASE` et préfixe le
modèle avec `ollama_chat/`. `--check` vérifie uv, aider, lanceur, API et modèle ;
`--status` est informatif et ne modifie rien.

### 6.8 `host/40-test.sh`

Sans root. Dans l'ordre, et arrêt au premier échec pour la lisibilité :

1. hôte → `GET /api/version` puis `GET /api/tags` (modèle présent) ;
2. hôte → `POST /api/generate` (réponse non vide) puis `GET /api/ps`
   (`size_vram == size`, donc le modèle tourne entièrement sur le GPU) ;
3. conteneur `open-webui` → `OLLAMA_BASE_URL/api/tags` (via `docker exec`) ;
4. hôte → `GET http://10.0.10.11:3000/health` (HTTP 200) ;
5. aider en non interactif dans `data/test/aider` : réponse contenant `42`
   (question `17 + 25`, dont les opérandes n'apparaissent pas dans la réponse
   attendue), code 0.

## 7. Spécification des invités

### 7.1 Compte et accès

- utilisateur `adm`, clé SSH de l'hôte, pas de mot de passe ;
- `adm` membre du groupe `docker` (créé par le paquet Docker) ;
- `adm` peut lancer `docker`, `docker compose` et `sudo reboot` ;
- règle unique `/etc/sudoers.d/90-ai-local-reboot` (0440, validée `visudo -c`) :
  `adm ALL=(root) NOPASSWD: /usr/sbin/reboot` ; pas de `NOPASSWD: ALL` ;
- provisioning : SSH **root** par clé, sur le réseau privé uniquement
  (`PermitRootLogin prohibit-password`, `AllowUsers adm root`) ;
- cloud-init : image figée, `resize_rootfs`, `qemu-guest-agent`, `curl`,
  `gnupg`, `ca-certificates`, `sudo`, `openssh-server`.

### 7.2 `vm/guest/base.sh` (root)

Active le dépôt Docker officiel (`docker.sources` + clé), installe
`docker-ce docker-ce-cli containerd.io docker-buildx-plugin
docker-compose-plugin`, active Docker, ajoute `adm` au groupe `docker`.
Idempotent : docker actif + compose + groupe = `[OK]`.

### 7.3 `vm/guest/nvidia.sh` (root)

Active `non-free`, installe `linux-image/headers-<cloud-amd64|amd64>`,
`nvidia-driver`, `nvidia-smi`, `libcuda1`, `pciutils`. Installe
`nvidia-container-toolkit` depuis son dépôt officiel, exécute
`nvidia-ctk runtime configure --runtime=docker`, régénère le spec CDI
`/var/run/cdi/nvidia.yaml`, redémarre Docker. `libcuda1` est indispensable :
sans lui `nvidia-smi` fonctionne mais Ollama ne voit aucun backend CUDA et
retombe sur CPU. Si `nvidia-smi` échoue encore : exit **3** (l'hôte redémarre
l'invité et réessaie une fois). Si le runtime ou le spec CDI reste incomplet :
diagnostic et exit 1.

### 7.4 `vm/guest/ollama.sh` (root)

`/home/adm/ollama/compose.yaml` (copié par l'hôte) :

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

`docker compose up -d`, attente API + `nvidia-smi` **et** `libcuda.so.1` dans
le conteneur (180 s). `AILOCAL_RECREATE=1` ou un conteneur sans CUDA force
`--force-recreate` quand le compose ou l'accès GPU a changé.

### 7.5 `vm/guest/openwebui.sh` (root)

`/home/adm/openwebui/compose.yaml` : image
`ghcr.io/open-webui/open-webui:v0.12.4`, port `10.0.10.11:3000:8080`, données
dans `/home/adm/openwebui/data`, `OLLAMA_BASE_URL` **et** `OLLAMA_BASE_URLS`
pointant sur `http://10.0.10.10:11434`. Attente `/health` (180 s).

### 7.6 Modèle

`MODEL` dans `config.sh`, défaut `gemma4:12b`. Présent dans `/api/tags` = `[OK]` ;
absent = `docker exec ollama ollama pull`, puis vérification. Un autre modèle se
demande à aider par `--model`; le défaut ne change pas.

## 8. Idempotence

Chaque étape suit : `si <vérification réelle> ; [OK] ; sinon agir ; [FAIT]`.
Interdits : réinstaller un paquet présent, recréer un objet existant, relancer un
pull de modèle présent, redémarrer une VM qui tourne, réécrire un fichier
identique, relancer un `docker compose up` sans changement. Un `up` sur système
conforme ne produit que des `[OK]`.

Seule action systématique : reconstruction du seed cloud-init en mémoire, suivie
d'une comparaison binaire ; le fichier n'est remplacé que s'il diffère.

## 9. Matrice d'acceptation

À exécuter sur la machine réelle, sans harnais de test ni faux `ssh`.

| # | Manipulation | Attendu |
|---|---|---|
| A | `sudo ./bootstrap.sh up` deux fois | 2e passe : que des `[OK]`, exit 0 |
| B | reboot hôte puis `up` | réseau, VM, conteneurs recréés ; modèles et données conservés ; `test` OK |
| C | `down` puis `up` | réseau absent puis recréé ; disques et modèles intacts |
| D | `sudo ip link del ailocal0` puis `up` | seul le réseau est recréé |
| E | `ssh ollama docker stop ollama` puis `up` | seul le conteneur Ollama est redémarré |
| F | `ssh ollama sudo reboot`, attendre, puis `up` | conteneur relancé, API et GPU OK |
| G | `ssh ollama docker exec ollama ollama rm gemma4:12b` puis `up` | modèle retéléchargé, puis `[OK]` |
| H | hôte vierge | `up` → REDÉMARRAGE REQUIS (2) → reboot → `up` → `test` OK |
| I | `check` conforme / VM arrêtée | exit 0 / exit 1 |
| J | `up` interrompu (Ctrl-C) pendant l'install invité | relance reprend sans doublon |
| K | `ssh webui docker stop open-webui` puis `up` | conteneur WebUI redémarré, `test` OK |
| L | modifier `OLLAMA_BASE_URL` dans le compose de la VM webui, puis `test` | `test` échoue (webui→ollama) ; `up` réinstalle le compose, recrée le conteneur, `test` OK |

Budget : `up` conforme < 90 s (santé incluse), `check` < 30 s, `test` < 10 min
(selon la vitesse du modèle).

## 10. Règles pour un agent

1. Lire `OBJECTIFS.md` en entier puis `README.md`.
2. Lancer `./bootstrap.sh check` avant toute modification, et après. Un
   changement n'est terminé que si `check` repasse à 0.
3. Plus petit changement possible. Pas de refactor opportuniste, de renommage ou
   de réorganisation.
4. Ne pas ajouter de fichier hors section 4, ni de dépendance hors section 6.1,
   ni dépasser les budgets.
5. Ne jamais corriger en ajoutant : un state file, un service, un marqueur, une
   bibliothèque, une couche d'abstraction, une variable cachée.
6. Git : commits directs sur `main`, un commit = un changement, message
   `quoi: pourquoi`. Pas de branche, hook, rapport ou `--force`.
7. Exigence ambiguë ou test impossible : s'arrêter, écrire la question dans
   `TODO.md` (et seulement là), ne pas deviner.
8. Ne pas modifier ce contrat sans demande explicite ; le code qui applique un
   changement de contrat est dans le même commit.
9. Ne jamais affaiblir une vérification pour faire passer un test.
10. Vérifier au minimum A, B et `test` avant de conclure.

## 11. Dépannage de référence

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

Réparations :

- réseau supprimé → `sudo ./bootstrap.sh up` ;
- conteneur arrêté → `docker restart <nom>` ou `up` ;
- compose modifié à la main → `up` le réinstalle et recrée le conteneur ;
- modèle supprimé → `up` le retélécharge ;
- pilote NVIDIA cassé → `up` réinstalle et redémarre l'invité au besoin ;
- disque corrompu → `down`, supprimer `data/vm/<vm>.qcow2`, `up`.

## 12. Risques connus

- Le GPU quitte l'hôte après activation VFIO : accès console indispensable.
- Le groupe IOMMU doit contenir exactement les deux fonctions GPU ; sinon
  `10-vfio.sh` échoue volontairement.
- L'API Ollama n'a aucune authentification : elle n'écoute que sur
  `10.0.10.0/24`.
- Le groupe `docker` équivaut à root dans une VM ; les VM ne sont pas exposées
  au LAN.
- `gemma4:12b` pèse plusieurs Go ; le premier `up` est long et dépend du réseau.
- Un changement d'image ou de pilote peut nécessiter de recréer un disque ; les
  modèles sont alors à retélécharger.
- 31 Gio de RAM sont nécessaires pour 16 Gio (Ollama) + 8 Gio (WebUI) + hôte.

## 13. Décisions

| # | Décision | Raison |
|---|---|---|
| ADR-1 | VFIO est le seul état persistant hôte | sans lui le GPU reste pris au reboot |
| ADR-2 | Ollama et Open WebUI en conteneurs | versions figées, `docker compose` comme interface |
| ADR-3 | Deux VM identiques, seule l'application change | installation rejouable, isolation |
| ADR-4 | Modèles et données en bind mount dans les VM | visibles, sauvegardables, réparables |
| ADR-5 | Réseau éphémère, aucun service systemd | supprime le point de panne du boot |
| ADR-6 | Aucun fichier d'état ; l'état est observé | supprime les divergences marqueur/réalité |
| ADR-7 | Reboot hôte jamais automatique ; reboot invité oui | l'administrateur garde la main |
| ADR-8 | Provisioning en root SSH par clé, réseau privé | `adm` garde des droits étroits |
| ADR-9 | uv/aider téléchargés à l'installation dans `~/.local/` | pas de binaires dans le dépôt, installation rejouable |
| ADR-10 | `gemma4:12b` par défaut | choix utilisateur ; tient sur 16 Gio de VRAM |
| ADR-11 | `test` séparé de `check` | `check` rapide et local ; `test` coûteux et bout en bout |
| ADR-12 | Commits directs sur `main`, pas de revue | le process avait dépassé le code |
| ADR-13 | `vim`, `tmux`, `glow`, `rsync` et alias `ll`/`la` sur l'hôte | confort demandé, sans service ni binaire dans le dépôt |

## 14. Définition de terminé

- [ ] Aucun fichier hors section 4, aucun secret suivi.
- [ ] `wc -l` des scripts ≤ 1700, aucun script > 220 lignes, `common.sh` ≤ 30.
- [ ] Scénarios A à L passés sur la machine réelle.
- [ ] `down` laisse l'hôte sans bridge, TAP ni règle nft.
- [ ] `check` exit 0 sur système conforme, exit 1 VM arrêtée.
- [ ] `test` valide les quatre chemins (hôte→Ollama, WebUI→Ollama,
      hôte→WebUI, hôte→aider).
- [ ] `up` sur système conforme n'affiche que des `[OK]`.
- [ ] `vim`, `tmux`, `glow`, `rsync` présents et alias `ll`/`la` actifs.
- [ ] `README.md` suffit à un administrateur qui n'a jamais lu le code.
- [ ] `data/`, `logs/`, `run/` ignorés par Git.
