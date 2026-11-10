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
