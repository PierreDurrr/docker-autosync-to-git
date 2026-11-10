# 🐳 Docker Auto-Sync to GitHub (PRA)

Ce projet met en place une sauvegarde automatisée et intelligente des configurations Docker (fichiers `docker-compose.yml`, `.env`, fichiers markdown et configurations ciblées) depuis un serveur de production vers un dépôt GitHub privé.

## 🎯 Objectifs et Cahier des charges
* **Ciblage strict :** Sauvegarder uniquement les fichiers de configuration texte (Infrastructure as Code) et exclure absolument toutes les données lourdes ou sensibles (bases de données SQLite, logs, caches) qui pullulent dans les dossiers des conteneurs.
* **Non-intrusif :** Ne jamais interrompre le fonctionnement des conteneurs en production pendant la sauvegarde.
* **Validation humaine :** Créer des **Pull Requests** sur GitHub plutôt que de pousser directement sur la branche principale, afin de garder un contrôle visuel sur les changements.
* **Résilience absolue :** Le système doit être capable de s'auto-réparer en cas de coupure réseau ou de crash en plein milieu d'une exécution.

## 🏗️ Architecture et Choix Techniques

1. **`rsync` (Le Filtre) :** Agit comme un tamis ultra-précis grâce au principe des listes blanches (`--include` / `--exclude`). Il transfère la configuration de `/docker_data2` vers un dossier tampon `/docker_data2-git-sync`.
2. **`git` & `gh` (Le Versioning) :** Détecte les modifications du dossier tampon, crée une branche dédiée (`auto-sync`) et utilise la CLI GitHub pour générer la Pull Request.
3. **`systemd` (La Planification) :** Remplace l'obsolète `cron`. Un *Timer* déclenche le script toutes les heures. Avantages : environnement d'exécution fiable, rattrapage des retards d'exécution, et logs centralisés via `journalctl`.
4. **Hôte vs Conteneur :** Le script tourne en "bare-metal" (sur l'hôte) et non dans un conteneur Docker. Cela évite les problèmes de droits (UID/GID), permet au script de fonctionner même si le moteur Docker crashe, et sécurise le token GitHub localement.

## 🚀 Installation et Déploiement

### 1. Le Script Principal
Emplacement : `/docker_data2-script/sync-compose.sh`
*(N'oubliez pas de le rendre exécutable : `chmod 700 /docker_data2-script/sync-compose.sh`)*

```bash
#!/usr/bin/env bash
set -euo pipefail

# --- CONFIGURATION ---
SRC="/docker_data2"
REPO="/docker_data2-git-sync"
TARGET_SUBDIR="docker_data2"   # Dossier cible dans le dépôt Git
BASE_BRANCH="master"             # Branche principale (main ou master)
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

### 2. Planification Systemd

**Service (`/etc/systemd/system/sync-compose.service`) :**
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

**Timer (`/etc/systemd/system/sync-compose.timer`) :**
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
*Activation :* `systemctl daemon-reload && systemctl enable --now sync-compose.timer`

### 3. Utilisation Manuelle (Alias)
Un alias a été ajouté au `~/.bashrc` pour forcer la synchronisation manuellement après une modification et lire les logs en direct :
```bash
alias dcsync='systemctl start sync-compose.service && journalctl -u sync-compose.service -n 15 --no-pager'
```

## 🛡️ Règles de Sécurité et Fonctionnement

* **Unidirectionnel (Source de Vérité) :** Le serveur de production `/docker_data2` est le maître absolu. Les modifications directes sur GitHub (en dehors des dossiers protégés comme `0_template`) seront systématiquement écrasées/effacées par le `rsync --delete` de la prochaine synchronisation.
* **Fail-Safe :** La directive `set -e` coupe l'exécution à la moindre erreur réseau. La séquence initiale `git reset --hard` nettoie automatiquement les tentatives avortées au prochain lancement.
* **Silencieux :** Le script s'arrête prématurément si aucun changement n'est détecté. Aucune création de branche ou notification inutile.

## 🛠️ Améliorations futures (À implémenter)
* [ ] Intégration de la notification (Discord / Telegram) en fin de script.
* [ ] Ajout de l'argument `--dry-run` pour tester les exclusions rsync à blanc.
* [ ] Ajout des inclusions spécifiques (poupées russes) pour des fichiers comme `/*/config/settings.json`.
* [ ] Chiffrement à la volée du fichier `.env` (via `sops` ou `age`) avant le push GitHub.
