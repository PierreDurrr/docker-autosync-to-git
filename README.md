# 🐳 Docker Auto-Sync to GitHub (PRA)

Ce projet met en place une sauvegarde automatisée, sécurisée et intelligente des configurations Docker (`docker-compose.yml`, `.env`, fichiers `.md`, `.txt` et configurations ciblées) depuis un serveur de production vers un dépôt GitHub privé (`https://github.com/PierreDurrr/Compose`).

---

## 🎯 1. Objectifs et Cahier des charges

* **Ciblage strict :** Sauvegarder uniquement les fichiers de configuration texte (Infrastructure as Code) et exclure toutes les données lourdes, dynamiques ou sensibles (bases de données SQLite, logs, caches) générées par les conteneurs.
* **Non-intrusif (Lecture seule) :** Ne jamais arrêter ni perturber les conteneurs en production dans `/docker_data2` pendant la sauvegarde.
* **Validation humaine :** Créer automatiquement des **Pull Requests** sur une branche dédiée (`auto-sync`) plutôt que de pousser directement sur `master`, afin de garder un contrôle visuel avant fusion.
* **Silencieux :** Ne déclencher de commit, de Pull Request et de notification **que** s'il y a eu une véritable modification.
* **Résilience absolue (Fail-Safe) :** En cas de coupure internet ou d'erreur GitHub, le script s'arrête proprement et s'auto-répare lors de l'exécution suivante.

---

## 🏗️ 2. Architecture et Choix Techniques

### Arborescence sur le serveur hôte
```text
/
├── docker_data2/                  # 🔴 PRODUCTION (Source de vérité - Lecture seule pour le script)
│   ├── .env
│   ├── _test/                     # Ignoré (commence par _)
│   └── yamtrack/
│       ├── docker-compose.yml
│       └── config/                # Ignoré par défaut (contient db.sqlite3, etc.)
│
├── docker_data2-git-sync/         # 🟡 DOSSIER TAMPON (Dépôt Git local cloné)
│   ├── .git/
│   ├── 0_template/                # 🟢 Dossier protégé (non touché par rsync --delete)
│   └── docker_data2/              # Cible de la synchronisation rsync
│
└── docker_data2-script/           # 🔵 SCRIPTS D'EXÉCUTION
    ├── sync-compose.sh            # Script principal
    └── README.md                  # Documentation
```

### Pourquoi ces choix d'architecture ?
1. **`rsync` en amont plutôt qu'un simple `.gitignore` :** Filtrer avec `rsync` évite de copier des gigaoctets de bases SQLite dans le dossier tampon (économie d'écriture disque et de RAM) et évite les conflits de sous-modules si un conteneur possède lui-même un dossier `.git/config`.
2. **Exécution sur l'hôte (Bare-Metal) vs Conteneur Docker :** 
   * *Indépendance :* Si le démon Docker tombe en panne, le script de sauvegarde sur l'hôte continue de fonctionner.
   * *Permissions :* Évite les conflits de droits Linux (`UID/GID`) sur les volumes montés et les fichiers `.env` en `chmod 600`.
   * *Sécurité :* Les tokens GitHub restent confinés dans l'environnement `root` de l'hôte, sans avoir à les injecter dans un conteneur.
3. **`systemd` (Timer + Service) vs `cron` :** `systemd` garantit un environnement d'exécution propre (`HOME=/root`), centralise les journaux dans `journalctl`, empêche les exécutions fantômes et rattrape les sauvegardes manquées si le serveur était éteint (`Persistent=true`).

---

## 🔑 3. Prérequis et Connexion à Git / GitHub

Toutes les opérations sont réalisées en tant que `root` sur l'hôte.

### Étape 3.1 : Installation des paquets requis (`git`, `rsync`, `curl`, `gh`)
```bash
apt update && apt install -y git rsync curl gpg

# Installation officielle de GitHub CLI (gh) sur Debian/Ubuntu
mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
apt update && apt install -y gh
```

### Étape 3.2 : Configuration de l'identité Git (sur l'hôte)
Indispensable pour que le script puisse créer des commits :
```bash
git config --global user.name "PierreDurrr"
git config --global user.email "ton-email@domaine.com"
```

### Étape 3.3 : Authentification GitHub CLI (`gh`) et liaison avec Git
Lancer l'assistant d'authentification :
```bash
gh auth login
```
Paramètres à sélectionner dans l'assistant :
1. **Where do you use GitHub?** `GitHub.com`
2. **Preferred protocol for Git operations?** `HTTPS`
3. **Authenticate Git with your GitHub credentials?** `Yes`
4. **How would you like to authenticate?** 
   * Soit via `Login with a web browser` (copier le code à 8 caractères sur `https://github.com/login/device`).
   * Soit via `Paste an authentication token` (Personal Access Token).
     * *Note Token (Classic) :* Cocher les scopes `repo` et `workflow`.
     * *Note Token (Fine-grained) :* Donner l'accès au dépôt `Compose` avec les permissions **Contents** (`Read and write`), **Pull requests** (`Read and write`) et **Metadata** (`Read-only`).

Forcer la liaison des identifiants `gh` avec `git` et vérifier le statut :
```bash
gh auth setup-git
gh auth status
```

### Étape 3.4 : Clonage du dépôt dans le dossier tampon
```bash
git clone https://github.com/PierreDurrr/Compose.git /docker_data2-git-sync
mkdir -p /docker_data2-git-sync/docker_data2
```

---

## 🚀 4. Le Script Principal de Synchronisation

Créer le dossier et le fichier du script :
```bash
mkdir -p /docker_data2-script
nano /docker_data2-script/sync-compose.sh
```

Contenu de `/docker_data2-script/sync-compose.sh` :
```bash
#!/usr/bin/env bash
set -euo pipefail

# --- CONFIGURATION ---
SRC="/docker_data2"
REPO="/docker_data2-git-sync"
TARGET_SUBDIR="docker_data2"   # Dossier cible dans le dépôt Git
BASE_BRANCH="master"           # Branche principale (main ou master)
SYNC_BRANCH="auto-sync"        # Branche dédiée aux Pull Requests automatiques
LOCK_FILE="/run/sync-compose.lock"

# --- VERROU D'EXÉCUTION UNIQUE ---
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Une synchronisation est déjà en cours. Abandon."
  exit 0
fi

# --- VÉRIFICATIONS PRÉALABLES ---
if [ ! -d "$SRC" ]; then
  echo "Erreur : Le dossier source $SRC est introuvable." >&2
  exit 1
fi

if [ ! -d "$REPO/.git" ]; then
  echo "Erreur : Le dépôt Git $REPO n'est pas initialisé." >&2
  exit 1
fi

cd "$REPO"

# Nettoyage d'éventuels fichiers non suivis laissés par un crash précédent
git reset --hard -q
git clean -fd -q
git fetch origin --prune

# --- GESTION INTELLIGENTE DE LA BRANCHE DE PR ---
PR_STATE=$(gh pr view "$SYNC_BRANCH" --json state -q .state 2>/dev/null || echo "NONE")

if [ "$PR_STATE" = "OPEN" ]; then
  echo "PR déjà ouverte sur $SYNC_BRANCH : mise à jour de la branche existante."
  git checkout -B "$SYNC_BRANCH" "origin/$SYNC_BRANCH"
else
  echo "Aucune PR ouverte : préparation d'une nouvelle branche depuis $BASE_BRANCH."
  git checkout -B "$SYNC_BRANCH" "origin/$BASE_BRANCH"
fi

mkdir -p "$REPO/$TARGET_SUBDIR"

# --- SYNCHRONISATION LECTURE SEULE DEPUIS /docker_data2 ---
# Règles d'inclusion :
# 1. Exclut les dossiers de test à la racine commençant par _ (ex: _test/)
# 2. Inclut le fichier .env et les .md à la racine de /docker_data2
# 3. Autorise uniquement le 1er niveau de sous-dossiers (/*/)
# 4. Inclut uniquement les compose, .md, .txt et .env de ce 1er niveau
# 5. Exclut tout le reste (n'entre jamais dans config/, data/, db/, logs/, etc.)
rsync -a --delete --prune-empty-dirs \
  --exclude='/_*' \
  --include='/.env' \
  --include='/*.[mM][dD]' \
  --include='/*/' \
  --include='/*/docker-compose.y*ml' \
  --include='/*/compose.y*ml' \
  --include='/*/*.[mM][dD]' \
  --include='/*/*.[tT][xX][tT]' \
  --include='/*/.env' \
  --exclude='*' \
  "$SRC/" "$REPO/$TARGET_SUBDIR/"

# Protection des permissions du .env dans le dossier tampon
[ -f "$REPO/$TARGET_SUBDIR/.env" ] && chmod 600 "$REPO/$TARGET_SUBDIR/.env"

# --- COMMIT, PUSH ET CRÉATION DE LA PULL REQUEST ---
if [ -n "$(git status --porcelain)" ]; then
  TIMESTAMP=$(date '+%d/%m/%Y à %H:%M')
  CHANGED_FILES=$(git status --short)

  git add -A
  git commit -m "chore(sync): mise à jour depuis /docker_data2 ($TIMESTAMP)"

  if [ "$PR_STATE" = "OPEN" ]; then
    git push origin "$SYNC_BRANCH"
    echo "Branche $SYNC_BRANCH mise à jour sur la PR existante."
  else
    git push --force-with-lease -u origin "$SYNC_BRANCH"
    gh pr create \
      --base "$BASE_BRANCH" \
      --head "$SYNC_BRANCH" \
      --title "Sync /docker_data2 du $TIMESTAMP" \
      --body "$(printf "Modifications détectées dans \`/docker_data2\` :\n\n\`\`\`text\n%s\n\`\`\`" "$CHANGED_FILES")"
    echo "Nouvelle Pull Request créée avec succès."
  fi
else
  echo "Aucun changement détecté par rapport au dépôt."
fi
```

Verrouiller les permissions et rendre le script exécutable :
```bash
chmod 700 /docker_data2-script/sync-compose.sh
```

---

## ⏱️ 5. Automatisation avec Systemd (Service & Timer)

### Étape 5.1 : Créer le Service
Fichier `/etc/systemd/system/sync-compose.service` :
```ini
[Unit]
Description=Synchronisation de /docker_data2 vers GitHub (PR)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
Environment=HOME=/root
ExecStart=/docker_data2-script/sync-compose.sh
```

### Étape 5.2 : Créer le Timer (Planification)
Fichier `/etc/systemd/system/sync-compose.timer` :
```ini
[Unit]
Description=Timer de synchronisation de /docker_data2

[Timer]
OnCalendar=hourly
Persistent=true
RandomizedDelaySec=120

[Install]
WantedBy=timers.target
```
*Fonctionnement :* Déclenchement toutes les heures piles avec un délai aléatoire de 0 à 120 secondes (`RandomizedDelaySec=120`) pour lisser la charge CPU. Si l'on souhaite passer à une exécution quotidienne à 03h00 du matin, remplacer `OnCalendar=hourly` par `OnCalendar=*-*-* 03:00:00`.

### Étape 5.3 : Activer et démarrer le Timer
```bash
systemctl daemon-reload
systemctl enable --now sync-compose.timer
```

---

## 💻 6. Utilisation Quotidienne, Alias et Gestion des Logs

### Alias de synchronisation manuelle (`dcsync`)
Ajouté dans `/root/.bashrc` pour déclencher une synchronisation immédiate après modification d'un fichier et afficher les 15 dernières lignes de logs :
```bash
echo "alias dcsync='systemctl start sync-compose.service && journalctl -u sync-compose.service -n 15 --no-pager'" >> /root/.bashrc
source /root/.bashrc
```

### Commandes utiles de suivi et de maintenance
* **Lancer une synchronisation manuelle :** `dcsync`
* **Voir la date/heure exacte de la prochaine exécution :** `systemctl list-timers sync-compose.timer`
* **Consulter les logs complets :** `journalctl -u sync-compose.service -n 30 --no-pager`
* **Effacer l'historique des logs (repartir à zéro après une erreur) :**
  ```bash
  journalctl --rotate
  journalctl --vacuum-time=1s
  ```

---

## 🛡️ 7. Règles de Gestion et Sauvegarde de Fichiers de Config

### Règle n°1 : La synchronisation est strictement unidirectionnelle
Le serveur `/docker_data2` est le **maître absolu**.
* Si un dossier/fichier surveillé est ajouté manuellement depuis l'interface web de GitHub dans `docker_data2/`, `rsync --delete` constatera qu'il n'existe pas sur le serveur et proposera une PR pour **le supprimer**.
* **Exception pour les brouillons (`0_template/`) :** Comme `rsync` cible uniquement `/docker_data2-git-sync/docker_data2/`, tout ce qui se trouve à la racine du dépôt Git (comme le dossier `0_template/`) est totalement ignoré par `rsync --delete` et ne sera jamais écrasé.

### Règle n°2 : Comment sauvegarder ses propres fichiers de configuration ?

#### Méthode 1 : Placer les fichiers au 1er niveau du conteneur (Recommandé)
Sortir le fichier de configuration du sous-dossier `config/` pour le placer juste à côté du `docker-compose.yml` et le monter en lecture seule (`:ro`) :
```yaml
volumes:
  - ./nginx.conf:/etc/nginx/nginx.conf:ro
  - ./config:/app/config
```
Puis ajouter les extensions souhaitées dans le bloc `rsync` du script :
```bash
  --include='/*/*.[cC][oO][nN][fF]' \
  --include='/*/*.[jJ][sS][oO][nN]' \
  --include='/*/*.[yY][aA][mM][lL]' \
```

#### Méthode 2 : L'inclusion chirurgicale dans un sous-dossier ("Poupées russes")
Si un fichier doit impérativement rester dans `config/` (ex: `settings.json`), il faut ouvrir la porte du sous-dossier puis cibler le fichier **avant** la ligne `--exclude='*'` finale. Grâce à `--prune-empty-dirs`, l'arborescence sera créée automatiquement sur Git sans aspirer les bases SQLite voisines :

* *Pour un seul conteneur spécifique (`yamtrack`) :*
  ```bash
  --include='/yamtrack/config/' \
  --include='/yamtrack/config/settings.json' \
  --exclude='*' \
  ```
* *Pour TOUS les conteneurs ayant un `settings.json` dans `config/` :*
  ```bash
  --include='/*/config/' \
  --include='/*/config/settings.json' \
  --exclude='*' \
  ```

---

## 🧩 8. Modules Complémentaires (Prêts à intégrer)

### Module A : Notifications (Discord / Telegram / Home Assistant)
À insérer dans `sync-compose.sh`, juste après `echo "Nouvelle Pull Request créée avec succès."` (ou juste avant le `else` du bloc `if [ -n "$(git status --porcelain)" ]; then` si l'on veut aussi être notifié des mises à jour d'une PR déjà ouverte) :

```bash
    # --- OPTION 1 : DISCORD ---
    DISCORD_WEBHOOK="https://discord.com/api/webhooks/XXX/YYY"
    DISCORD_MSG=$(printf '{"content": "🐳 **Nouvelle PR de sauvegarde** (%s)\\nFichiers modifiés :\\n```text\\n%s\\n```\\nPense à la valider sur GitHub !"}' "$TIMESTAMP" "${CHANGED_FILES//$'\n'/\\n}")
    curl -s -H "Content-Type: application/json" -d "$DISCORD_MSG" "$DISCORD_WEBHOOK" >/dev/null

    # --- OPTION 2 : TELEGRAM ---
    TG_TOKEN="TON_TOKEN_BOT"
    TG_CHAT_ID="TON_CHAT_ID"
    TG_MSG="🐳 Nouvelle PR de sauvegarde ($TIMESTAMP)

Fichiers modifiés :
$CHANGED_FILES

Pense à la valider sur GitHub !"
    curl -s -G -d chat_id="$TG_CHAT_ID" --data-urlencode text="$TG_MSG" "https://api.telegram.org/bot$TG_TOKEN/sendMessage" >/dev/null
```
*(Note : `>/dev/null` masque la réponse JSON de l'API pour garder des logs `journalctl` propres).*

#### Comment obtenir les identifiants Discord ou Telegram :
* **Discord :** Paramètres du serveur $\rightarrow$ *Intégrations* $\rightarrow$ *Webhooks* $\rightarrow$ *Nouveau Webhook* $\rightarrow$ Choisir le salon $\rightarrow$ *Copier l'URL du Webhook*.
* **Telegram :**
  1. Contacter **@BotFather** sur Telegram, envoyer `/newbot`, choisir un nom et récupérer le `TG_TOKEN`.
  2. Envoyer un premier message au bot, puis contacter **@userinfobot** (ou visiter `https://api.telegram.org/bot<TON_TOKEN>/getUpdates`) pour récupérer son `TG_CHAT_ID`.

### Module B : Mode Simulation (`--dry-run`)
Permet de vérifier à blanc ce que `rsync` va copier/supprimer et de valider que la mécanique fonctionne sans rien modifier ni pousser sur GitHub.

1. **En haut du script (après `LOCK_FILE`) :**
   ```bash
   DRY_RUN=""
   RSYNC_VERBOSE=""
   if [ "${1:-}" = "--dry-run" ]; then
     echo "🚀 Mode SIMULATION activé : aucune vraie modification ne sera effectuée."
     DRY_RUN="--dry-run"
     RSYNC_VERBOSE="v"
   fi
   ```
2. **Sur la commande `rsync` :**
   ```bash
   rsync -a$RSYNC_VERBOSE $DRY_RUN --delete --prune-empty-dirs \
   ```
3. **Juste avant `# --- COMMIT, PUSH ET CRÉATION DE LA PULL REQUEST ---` :**
   ```bash
   if [ -n "$DRY_RUN" ]; then
     echo "✅ Simulation terminée avec succès ! Le flux est sain, une vraie synchro fonctionnera."
     exit 0
   fi
   ```
4. **Alias de test dans `/root/.bashrc` :**
   ```bash
   alias dcsync-test='/docker_data2-script/sync-compose.sh --dry-run'
   ```

### Module C : Pre-flight Check (Vérification de santé des conteneurs avant sync)
Optionnel — à placer après le verrou `flock` si l'on veut interdire la sauvegarde lorsque Docker ou un conteneur est en erreur :
```bash
if ! docker info >/dev/null 2>&1; then
  echo "Erreur : Le moteur Docker ne répond pas. Abandon." >&2
  exit 1
fi
if [ -n "$(docker ps -q -f status=restarting)" ] || [ -n "$(docker ps -q -f health=unhealthy)" ]; then
  echo "Erreur : Au moins un conteneur est instable (restarting/unhealthy). Abandon." >&2
  exit 1
fi
```

---

## 🛠️ 9. État d'avancement et To-Do List

* ✅ Installation et authentification Git / GitHub CLI (`gh`) sur l'hôte.
* ✅ Clonage du dépôt tampon `/docker_data2-git-sync` (`PierreDurrr/Compose`).
* ✅ Création et sécurisation du script `/docker_data2-script/sync-compose.sh` avec filtrage strict `rsync`.
* ✅ Mise en place et validation du service et du timer `systemd` (exécution horaire).
* ✅ Création de l'alias manuel `dcsync` et purge des journaux de test.
* ✅ Activation effective du webhook de notification (Discord / Telegram) dans le script.
* ✅ Ajout de l'argument `--dry-run` (`dcsync-test`) dans le script en production.
* ⏳ Ajout d'inclusions chirurgicales pour d'éventuels fichiers de configuration spécifiques (`/*/config/...`).
* ⏳ Chiffrement à la volée des fichiers `.env` (via `sops` ou `age`) avant l'envoi sur GitHub.
