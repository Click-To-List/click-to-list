#!/usr/bin/env bash
set -euo pipefail

# Make deploy file executable
chmod +x /home/ubuntu/ctl/api/deploy.sh

# --- Config ---
APP_DIR="/home/ubuntu/ctl/api"           # path to your git working copy
PM2_APP_NAME="ctl-api"           # pm2 process name
ENV_FILE="$APP_DIR/.env"

export SECRET_DEV_IDS="arn:aws:secretsmanager:us-east-1:484908221623:secret:ctl/app/dev-main-dnCmrV,arn:aws:secretsmanager:us-east-1:484908221623:secret:ctl/db/dev-main-wCfvu2"
export SECRET_STAGE_IDS="arn:aws:secretsmanager:us-east-1:484908221623:secret:ctl/app/staging-main-Yf7OGO,arn:aws:secretsmanager:us-east-1:484908221623:secret:ctl/db/staging-main-omJ7b9"
export SECRET_PROD_IDS="arn:aws:secretsmanager:us-east-1:484908221623:secret:ctl/app/prod-main-lP4OK8,arn:aws:secretsmanager:us-east-1:484908221623:secret:ctl/db/prod-main-tZWjdU"

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
  dev|Dev|DEV)         BRANCH="dev"; SECRET_IDS="$SECRET_DEV_IDS" ;;
  staging|Staging)     BRANCH="stage"; SECRET_IDS="$SECRET_STAGE_IDS" ;;
  prod|Prod|PROD|production|Production)
                       BRANCH="main"; SECRET_IDS="$SECRET_PROD_IDS" ;;
  *)
    echo "ERROR: Unknown Environment '$ENV_TAG'. Expected one of: dev, staging, prod." >&2
    exit 1
    ;;
esac

echo "Instance: $INSTANCE_ID, Region: $REGION, Environment: $ENV_TAG -> Branch: $BRANCH"
echo "Secrets (in order): $SECRET_IDS"

# --- Helper: fetch one secret, emit KEY=VALUE lines to stdout ---
emit_env_from_secret() {
  local sid="$1" region="$2"
  local sstr sbin

  # SecretString
  if sstr="$(aws secretsmanager get-secret-value --secret-id "$sid" --region "$region" --query 'SecretString' --output text 2>/dev/null)"; then
    :
  else
    sstr=""
  fi

  # Fallback SecretBinary
  if [[ -z "$sstr" || "$sstr" == "None" ]]; then
    if sbin="$(aws secretsmanager get-secret-value --secret-id "$sid" --region "$region" --query 'SecretBinary' --output text 2>/dev/null)"; then
      sstr="$(printf '%s' "$sbin" | base64 -d || true)"
    fi
  fi

  if [[ -z "${sstr:-}" || "$sstr" == "None" ]]; then
    echo "ERROR: Secret '$sid' empty or not found." >&2
    return 1
  fi

  # JSON → KEY=VALUE; else assume .env text
  if [[ "$sstr" =~ ^[[:space:]]*\{ ]]; then
    if command -v jq >/dev/null 2>&1; then
      printf '%s' "$sstr" \
        | jq -r 'to_entries | .[] | "\(.key)=\(.value|tostring)"'
    else
      echo "ERROR: jq required to convert JSON secret '$sid'." >&2
      return 1
    fi
  else
    # Normalize newlines, pass through
    printf '%s\n' "$sstr"
  fi
}

# --- Merge multiple secrets into .env (later secret wins) ---
write_env_from_secrets() {
  local sid_csv="$1" region="$2" dest="$3"
  local combined
  combined="$(mktemp)"

  IFS=',' read -r -a arr <<< "$sid_csv"
  for sid in "${arr[@]}"; do
    sid="$(echo "$sid" | xargs)"  # trim
    echo "→ Fetching $sid"
    emit_env_from_secret "$sid" "$region" \
      | sed 's/\r$//' \
      | awk 'NF' \
      >> "$combined"
    echo >> "$combined"
  done

  # De-dup by KEY keeping the LAST occurrence across all secrets.
  # Uses tac to reverse, keep first occurrence, then reverse back.
  # Handles lines with multiple '=' by splitting only on the first '='.
  local merged
  merged="$(mktemp)"
  tac "$combined" \
    | awk 'BEGIN{FS="="; OFS="="}
           /^[[:space:]]*($|#)/{next}
           {
             key=$1;
             sub(/^[[:space:]]+|[[:space:]]+$/,"",key);
             if(!seen[key]++){
               print $0
             }
           }' \
    | tac > "$merged"

  # Write final .env
  install -m 600 /dev/null "$dest"
  cat "$merged" > "$dest"
  rm -f "$combined" "$merged"

  echo ".env written to $dest (merged from ${#arr[@]} secret(s))."
}

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

# --- Build env before install/build ---
write_env_from_secrets "$SECRET_IDS" "$REGION" "$ENV_FILE"

# Load NVM
export NVM_DIR="$HOME/.nvm"
if [ -s "$NVM_DIR/nvm.sh" ]; then
  . "$NVM_DIR/nvm.sh"
  nvm use 22  # or whatever version you need
fi

# --- Install deps and build (optional) ---
# If you want prod-only deps, use: NODE_ENV=production npm install --omit=dev
npm install
if jq -e '.scripts.build' package.json >/dev/null 2>&1; then
  npm run build
fi

# --- Restart PM2 ---
if command -v npx pm2 >/dev/null 2>&1; then
  if npx pm2 describe "$PM2_APP_NAME" >/dev/null 2>&1; then
    npx pm2 reload "$PM2_APP_NAME" --update-env
  else
    npx pm2 start "npm -- start" --name "$PM2_APP_NAME" --update-env
  fi
  npx pm2 save
else
  echo "WARNING: pm2 not found in PATH. Skipping PM2 restart." >&2
fi

echo "✅ Deployed branch '$BRANCH' at $(date -Is) in $APP_DIR"
