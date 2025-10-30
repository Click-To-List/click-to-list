#!/usr/bin/env bash
set -euo pipefail

# Load NVM
export NVM_DIR="$HOME/.nvm"
if [ -s "$NVM_DIR/nvm.sh" ]; then
  . "$NVM_DIR/nvm.sh"
  nvm use 22  # or whatever version you need
fi

# Make deploy file executable
chmod +x /home/ubuntu/ctl/api/deploy.sh

# --- Config ---
APP_DIR="/home/ubuntu/ctl/api"           # path to your git working copy
PM2_APP_NAME="ctl-api"           # pm2 process name

# --- Discover instance-id and region (IMDSv2) ---
TOKEN="$(curl -sS -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds:21600')"
INSTANCE_ID="$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)"
IDENTITY_DOC="$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/dynamic/instance-identity/document)"
REGION="$(printf '%s' "$IDENTITY_DOC" | awk -F\" '/region/ {print $4; exit}')"

if [[ -z "${INSTANCE_ID:-}" || -z "${REGION:-}" ]]; then
  echo "ERROR: Could not determine INSTANCE_ID or REGION from IMDSv2." >&2
  exit 1
fi

# --- Read Environment tag from EC2 ---
ENV_TAG="$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query "Reservations[0].Instances[0].Tags[?Key=='Environment'].Value | [0]" \
  --output text)"

if [[ -z "${ENV_TAG:-}" || "$ENV_TAG" == "None" ]]; then
  echo "ERROR: Environment tag not found on instance $INSTANCE_ID." >&2
  exit 1
fi

# --- Map Environment -> Git branch ---
case "$ENV_TAG" in
  dev|Dev|DEV)         BRANCH="dev" ;;
  staging|Staging)     BRANCH="stage" ;;
  prod|Prod|PROD|production|Production)
                       BRANCH="main" ;;
  *)
    echo "ERROR: Unknown Environment '$ENV_TAG'. Expected one of: dev, staging, prod." >&2
    exit 1
    ;;
esac

echo "Instance: $INSTANCE_ID, Region: $REGION, Environment: $ENV_TAG -> Branch: $BRANCH"

# --- Ensure git working copy exists ---
cd "$APP_DIR"
if [[ ! -d ".git" ]]; then
  echo "ERROR: $APP_DIR is not a git working copy (missing .git). Clone your repo to $APP_DIR first." >&2
  exit 1
fi

# --- Git pull the mapped branch ---
git fetch --all --prune
# Ensure we have the branch locally tracking origin
if ! git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git checkout -B "$BRANCH" "origin/$BRANCH"
else
  git checkout "$BRANCH"
fi
git pull --ff-only origin "$BRANCH"

# --- Install deps and build (optional) ---
# If you want prod-only deps, use: NODE_ENV=production npm install --omit=dev
npm install
if jq -e '.scripts.build' package.json >/dev/null 2>&1; then
  npm run build
fi

# --- Restart PM2 ---
if command -v pm2 >/dev/null 2>&1; then
  if pm2 describe "$PM2_APP_NAME" >/dev/null 2>&1; then
    pm2 reload "$PM2_APP_NAME" --update-env
  else
    pm2 start "npm -- start" --name "$PM2_APP_NAME" --update-env
  fi
  pm2 save
else
  echo "WARNING: pm2 not found in PATH. Skipping PM2 restart." >&2
fi

echo "✅ Deployed branch '$BRANCH' at $(date -Is) in $APP_DIR"
