#!/usr/bin/env bash
set -euo pipefail

# --- CONFIGURATION ---
SRC="/docker_data2"
REPO="/docker_data2-git-sync"
TARGET_SUBDIR="docker_data2"   # Dossier cible dans le dépôt Git
BASE_BRANCH="master"           # Branche principale (main ou master)
SYNC_BRANCH="auto-sync"        # Branche dédiée aux Pull Requests automatiques
LOCK_FILE="/run/sync-compose.lock"

# IMPORTANT : Chemin vers le fichier de règles externe
RULES="/docker_data2-script/rsync-rules.txt"

# --- OPTIONS DE SAUVEGARDE HÔTE (ACTIVABLES / DÉSACTIVABLES) ---
BACKUP_DAEMON_JSON=true
BACKUP_FSTAB=true

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

# Garde-fou : le fichier de règles doit exister et être valide
grep -q '^+ ' "$RULES" 2>/dev/null || { echo "Règles absentes ou invalides : $RULES" >&2; exit 1; }

# Détection du mode dry-run (-n, -ni, --dry-run...)
DRY=0
for a in "$@"; do
  [[ "$a" == "--dry-run" || "$a" =~ ^-[a-zA-Z]*n[a-zA-Z]*$ ]] && DRY=1
done

cd "$REPO"

# Nettoyage d'éventuels fichiers non suivis laissés par un crash précédent
git reset --hard -q
git clean -fd -q
git fetch origin --prune

# --- GESTION INTELLIGENTE DE LA BRANCHE DE PR ---
# On ignore les manipulations Git si on est juste en train de tester (dry-run)
if [ $DRY -eq 0 ]; then
  PR_STATE=$(gh pr view "$SYNC_BRANCH" --json state -q .state 2>/dev/null || echo "NONE")

  if [ "$PR_STATE" = "OPEN" ]; then
    echo "PR déjà ouverte sur $SYNC_BRANCH : mise à jour de la branche existante."
    git checkout -B "$SYNC_BRANCH" "origin/$SYNC_BRANCH"
  else
    echo "Aucune PR ouverte : préparation d'une nouvelle branche depuis $BASE_BRANCH."
    git checkout -B "$SYNC_BRANCH" "origin/$BASE_BRANCH"
  fi
fi

mkdir -p "$REPO/$TARGET_SUBDIR"

# --- SYNCHRONISATION LECTURE SEULE DEPUIS /docker_data2 ---
rsync -a --delete --prune-empty-dirs \
  --filter="merge $RULES" \
  --exclude='*' \
  "$@" \
  "$SRC/" "$REPO/$TARGET_SUBDIR/"

# --- NETTOYAGE DES DONNÉES VOLATILES ---
SEERR_SETTINGS="$REPO/$TARGET_SUBDIR/seerr/config/settings.json"
if [[ $DRY -eq 0 && -f "$SEERR_SETTINGS" ]]; then
  sed -i -E 's/"lastScan": *[0-9]+/"lastScan": 0/g' "$SEERR_SETTINGS"
fi

DIYHUE_DIR="$REPO/$TARGET_SUBDIR/diyhue/config"
if [[ $DRY -eq 0 && -d "$DIYHUE_DIR" ]]; then
  find "$DIYHUE_DIR" -maxdepth 1 -name "*.yaml" -exec sed -i -E \
    -e "s/(localtime: ')[0-9T:-]+(')/\11970-01-01T00:00:00\2/g" \
    -e "s/(lastupdated: ')[0-9T:.-]+Z(')/\11970-01-01T00:00:00.000Z\2/g" \
    -e "s/(buttonevent: )[0-9]+/\10/g" {} +
fi

# Protection des permissions du .env dans le dossier tampon
if [[ $DRY -eq 0 && -f "$REPO/$TARGET_SUBDIR/.env" ]]; then
  chmod 600 "$REPO/$TARGET_SUBDIR/.env"
fi

# --- SYNCHRONISATION DES CONFIGURATIONS HÔTE (DAEMON & FSTAB FILTRÉ) ---
HOST_CONFIG_DIR="$REPO/host_config"
mkdir -p "$HOST_CONFIG_DIR"

# 1. Gestion de daemon.json (copie pure, rsync gère bien la date de modif)
RSYNC_DAEMON_OPTS="-a"
[ $DRY -eq 1 ] && RSYNC_DAEMON_OPTS="-a -ni"

if [ "$BACKUP_DAEMON_JSON" = true ] && [ -f "/etc/docker/daemon.json" ]; then
  rsync $RSYNC_DAEMON_OPTS "/etc/docker/daemon.json" "$HOST_CONFIG_DIR/daemon.json"
else
  [ $DRY -eq 0 ] && rm -f "$HOST_CONFIG_DIR/daemon.json"
fi

# 2. Gestion de fstab (filtrage temporaire + comparaison par empreinte)
if [ "$BACKUP_FSTAB" = true ] && [ -f "/etc/fstab" ]; then
  TMP_FSTAB="/tmp/sync_fstab_temp"
  
  # On coupe tout de la ligne 1 jusqu'au swap, on ne garde que la suite
  sed '1,/swap\.img/d' /etc/fstab > "$TMP_FSTAB"
  
  # On FORCE la vérification par Checksum (-c) pour ignorer la date du fichier temp
  RSYNC_FSTAB_OPTS="-a -c"
  [ $DRY -eq 1 ] && RSYNC_FSTAB_OPTS="-a -c -ni"
  
  rsync $RSYNC_FSTAB_OPTS "$TMP_FSTAB" "$HOST_CONFIG_DIR/fstab"
  rm -f "$TMP_FSTAB"
else
  [ $DRY -eq 0 ] && rm -f "$HOST_CONFIG_DIR/fstab"
fi

# Nettoyage si le dossier host_config devient vide
[ $DRY -eq 0 ] && find "$HOST_CONFIG_DIR" -type d -empty -delete 2>/dev/null || true


# --- ARRÊT ICI SI DRY-RUN ---
if [ $DRY -eq 1 ]; then
  echo "✅ Simulation (dry-run) terminée. Aucune commande Git exécutée."
  exit 0
fi

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
      --body "$(printf "Modifications détectées dans \`/docker_data2\` et l'hôte :\n\n\`\`\`text\n%s\n\`\`\`" "$CHANGED_FILES")"
    echo "Nouvelle Pull Request créée avec succès."
  fi

  # ==========================================
  # NOTIFICATION DISCORD OU TELEGRAM (Optionnel)
  # ==========================================
  
  # --- OPTION 1 : DISCORD ---
  # DISCORD_WEBHOOK="https://discord.com/api/webhooks/XXX/YYY"
  # DISCORD_MSG=$(printf '{"content": "🐳 **Nouvelle PR de sauvegarde** (%s)\\nFichiers modifiés :\\n```text\\n%s\\n```\\nPense à la valider sur GitHub !"}' "$TIMESTAMP" "${CHANGED_FILES//$'\n'/\\n}")
  # curl -s -H "Content-Type: application/json" -d "$DISCORD_MSG" "$DISCORD_WEBHOOK" >/dev/null

  # --- OPTION 2 : TELEGRAM ---
  # TG_TOKEN="TON_TOKEN_BOT"
  # TG_CHAT_ID="TON_ID"
  # TG_MSG="🐳 Nouvelle PR de sauvegarde ($TIMESTAMP)
  # 
  # Fichiers modifiés :
  # $CHANGED_FILES
  # 
  # Pense à la valider sur GitHub !"
  # curl -s -G -d chat_id="$TG_CHAT_ID" --data-urlencode text="$TG_MSG" "https://api.telegram.org/bot$TG_TOKEN/sendMessage" >/dev/null

else
  echo "Aucun changement détecté par rapport au dépôt."
fi
