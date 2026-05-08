#!/usr/bin/env bash
set -euo pipefail

DOMAINS_DIR="${DOMAINS_DIR:-hostinger_snapshot/domains}"
WORK_DIR="${WORK_DIR:-domain_repos_work}"
VISIBILITY="${VISIBILITY:-private}"

if ! command -v git >/dev/null 2>&1; then
  echo "ERROR: git is not installed."
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: GitHub CLI gh is not installed."
  echo "Install it or run this in a GitHub Codespace with gh available."
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: GitHub CLI is not authenticated."
  echo "Run:"
  echo "gh auth login"
  exit 1
fi

if [ ! -d "$DOMAINS_DIR" ]; then
  echo "ERROR: Domains folder not found: $DOMAINS_DIR"
  echo "Available folders:"
  find . -maxdepth 3 -type d | sort | sed 's#^\./##'
  exit 1
fi

mkdir -p "$WORK_DIR"

sanitize_repo_name() {
  local name="$1"
  name="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
  name="$(echo "$name" | sed -E 's/[^a-z0-9]+/-/g')"
  name="$(echo "$name" | sed -E 's/^-+|-+$//g')"
  echo "$name"
}

create_gitignore() {
  cat > .gitignore <<'EOF'
# Secrets
.env
.env.*
*.pem
*.key
*.crt
*.p12
*.pfx
.vscode/sftp.json

# Dependencies
node_modules/

# PHP dependencies
# Keep vendor ignored by default.
# If this is an old PHP project without composer.json and vendor is required, review manually.
vendor/

# Builds
dist/
build/
.next/
.nuxt/
out/

# Logs and cache
*.log
logs/
cache/
tmp/
temp/
.runtime/
.storage/

# Backups and archives
*.zip
*.tar
*.tar.gz
*.tgz
*.rar
*.7z
*.bak
*.backup
*.old

# Database dumps
*.sql
*.sqlite
*.sqlite3
*.db
*.dump

# OS/editor
.DS_Store
Thumbs.db
.idea/
EOF
}

echo "Scanning domains in: $DOMAINS_DIR"
echo

mapfile -t DOMAIN_PATHS < <(find "$DOMAINS_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

if [ "${#DOMAIN_PATHS[@]}" -eq 0 ]; then
  echo "ERROR: No domain folders found inside $DOMAINS_DIR"
  exit 1
fi

printf "%-35s %-35s %-15s %s\n" "DOMAIN" "REPO" "STATUS" "URL"
printf "%-35s %-35s %-15s %s\n" "------" "----" "------" "---"

for DOMAIN_PATH in "${DOMAIN_PATHS[@]}"; do
  DOMAIN="$(basename "$DOMAIN_PATH")"
  REPO_NAME="$(sanitize_repo_name "$DOMAIN")"
  TARGET_DIR="$WORK_DIR/$REPO_NAME"

  STATUS="pending"
  URL=""

  rm -rf "$TARGET_DIR"
  mkdir -p "$TARGET_DIR"

  rsync -a \
    --exclude='.git' \
    --exclude='.env' \
    --exclude='.env.*' \
    --exclude='node_modules' \
    --exclude='vendor' \
    --exclude='*.log' \
    --exclude='logs' \
    --exclude='cache' \
    --exclude='tmp' \
    --exclude='*.zip' \
    --exclude='*.tar' \
    --exclude='*.tar.gz' \
    --exclude='*.tgz' \
    --exclude='*.rar' \
    --exclude='*.7z' \
    --exclude='*.sql' \
    --exclude='*.sqlite' \
    --exclude='*.sqlite3' \
    --exclude='*.db' \
    "$DOMAIN_PATH"/ "$TARGET_DIR"/

  cd "$TARGET_DIR"

  create_gitignore

  git init -q
  git branch -M main
  git add .

  if git diff --cached --quiet; then
    STATUS="empty"
    cd - >/dev/null
    printf "%-35s %-35s %-15s %s\n" "$DOMAIN" "$REPO_NAME" "$STATUS" "$URL"
    continue
  fi

  git commit -m "Initial import from Hostinger domain: $DOMAIN" >/dev/null

  if gh repo view "$REPO_NAME" >/dev/null 2>&1; then
    STATUS="exists"
    URL="$(gh repo view "$REPO_NAME" --json url -q .url)"
  else
    gh repo create "$REPO_NAME" --"$VISIBILITY" --source=. --remote=origin --push >/dev/null
    STATUS="created"
    URL="$(gh repo view "$REPO_NAME" --json url -q .url)"
    cd - >/dev/null
    printf "%-35s %-35s %-15s %s\n" "$DOMAIN" "$REPO_NAME" "$STATUS" "$URL"
    continue
  fi

  if ! git remote get-url origin >/dev/null 2>&1; then
    git remote add origin "$URL.git"
  fi

  git push -u origin main >/dev/null 2>&1 || STATUS="push_failed"

  cd - >/dev/null
  printf "%-35s %-35s %-15s %s\n" "$DOMAIN" "$REPO_NAME" "$STATUS" "$URL"
done

echo
echo "Done."
echo "Local clean repo copies are inside: $WORK_DIR"
echo "Original downloaded Hostinger files remain unchanged inside: $DOMAINS_DIR"
