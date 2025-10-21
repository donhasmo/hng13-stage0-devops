#!/usr/bin/env bash
# deploy.sh — Simple, beginner-friendly deployment script
# Combines steps 1-10: collect params, clone repo (PAT auth), verify Docker files,
# validate SSH, prepare remote (Docker, Docker Compose, Nginx), transfer files,
# build/run containers, configure Nginx, validate, logging, idempotency & cleanup.
#
# Usage:
#   ./deploy.sh           # run deployment
#   ./deploy.sh --cleanup # remove deployed resources from remote
#
# Exit codes:
#   0 = success
#   1 = general error
#   2 = input validation fail
#   3 = SSH/connectivity fail
#   4 = remote prep failed (Docker/nginx install)
#   5 = deploy/build failed
#   6 = validation failed

set -euo pipefail

# --------------------------
# Basic variables and logging
# --------------------------
TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"
LOGDIR="./logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/deploy_${TIMESTAMP}.log"

# Simple logging functions
log()    { printf "%s [INFO] %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOGFILE"; }
warn()   { printf "%s [WARN] %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOGFILE"; }
err()    { printf "%s [ERROR] %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOGFILE" >&2; }

# Trap unexpected errors
on_exit() {
  code=$?
  if [ $code -ne 0 ]; then
    err "Script exited with code $code. See log: $LOGFILE"
  else
    log "Script finished successfully."
  fi
}
trap on_exit EXIT

# --------------------------
# Helpers / validators
# --------------------------
is_valid_git_url() {
  [[ "$1" =~ ^(https:\/\/|git@|ssh:\/\/) ]] && return 0 || return 1
}
is_valid_ip() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0 || return 1
}
is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 > 0 && $1 <= 65535 )) && return 0 || return 1
}
file_readable() {
  [[ -f "$1" && -r "$1" ]]
}

# --------------------------
# Step 0: cleanup flag
# --------------------------
CLEANUP=false
if [[ "${1:-}" == "--cleanup" || "${1:-}" == "-c" ]]; then
  CLEANUP=true
fi

# --------------------------
# Step 1: Collect parameters
# --------------------------
prompt() {
  local prompt_text="$1"
  local default="$2"
  read -r -p "$prompt_text${default:+ [$default]}: " val
  if [[ -z "$val" && -n "$default" ]]; then
    val="$default"
  fi
  echo "$val"
}

log "Collecting parameters (step 1)."

# Git repo
while true; do
  GIT_REPO="$(prompt "Enter Git repository URL (HTTPS recommended)" "")"
  if is_valid_git_url "$GIT_REPO"; then break; else echo "Invalid repo URL. Try again."; fi
done

# PAT (hidden)
read -rs -p "Enter Personal Access Token (PAT) for repo (input hidden): " GIT_PAT
echo
if [[ -z "$GIT_PAT" ]]; then err "PAT is required."; exit 2; fi

BRANCH="$(prompt "Branch name (optional - leave blank for 'main')" "main")"
SSH_USER="$(prompt "Remote SSH username" "ubuntu")"
while true; do
  SERVER_IP="$(prompt "Remote server IP address" "")"
  if is_valid_ip "$SERVER_IP"; then break; else echo "Invalid IP. Try again."; fi
done
SSH_KEY_PATH_RAW="$(prompt "Path to SSH private key (e.g. ~/.ssh/id_ed25519)" "~/.ssh/id_ed25519")"
SSH_KEY_PATH="${SSH_KEY_PATH_RAW/#\~/$HOME}"
if ! file_readable "$SSH_KEY_PATH"; then err "SSH key not found or not readable: $SSH_KEY_PATH"; exit 2; fi

while true; do
  APP_PORT="$(prompt "Application internal container port (e.g. 8080)" "8080")"
  if is_valid_port "$APP_PORT"; then break; else echo "Invalid port. Try again."; fi
done

log "Parameters collected. (PAT not logged for security.)"

# --------------------------
# If cleanup mode — perform remote cleanup and exit
# --------------------------
if $CLEANUP; then
  log "Running cleanup on remote host..."
  ssh -i "$SSH_KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" bash -s <<'EOF'
set -e
APP_NAME="deployed_app"
# Stop and remove container(s)
docker ps -q --filter "name=$APP_NAME" | xargs -r docker stop
docker ps -a -q --filter "name=$APP_NAME" | xargs -r docker rm
# Remove network if exists
docker network ls --format '{{.Name}}' | grep -q "^${APP_NAME}_net$" && docker network rm ${APP_NAME}_net || true
# Remove deployed project dir
rm -rf ~/deployed_app || true
# Remove Nginx config
sudo rm -f /etc/nginx/sites-enabled/${APP_NAME}.conf
sudo rm -f /etc/nginx/sites-available/${APP_NAME}.conf
sudo nginx -t && sudo systemctl reload nginx || true
EOF
  log "Cleanup complete."
  exit 0
fi

# --------------------------
# Step 2: Clone repository locally (with PAT)
# --------------------------
log "Cloning repository (step 2). Using temporary workdir /tmp/deploy_repo."
WORKDIR="/tmp/deploy_repo"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

REPO_NAME="$(basename -s .git "$GIT_REPO")"
if [[ -d "$REPO_NAME/.git" ]]; then
  log "Repo already exists locally - pulling latest."
  cd "$REPO_NAME"
  # Use safe remote URL without exposing PAT in logs by temporarily setting remote
  git fetch origin "$BRANCH" || error_exit "Failed to fetch branch"
  git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH" origin/"$BRANCH" || true
  git pull origin "$BRANCH" || error_exit "Failed to pull latest"
else
  log "Cloning repo..."
  # Prefer HTTPS and embed PAT in clone URL temporarily for cloning only
  if [[ "$GIT_REPO" =~ ^https:// ]]; then
    # Insert token after https://
    CLONE_URL="${GIT_REPO/https:\/\//https:\/\/${GIT_PAT}@}"
  else
    CLONE_URL="$GIT_REPO"
  fi
  git clone --branch "$BRANCH" "$CLONE_URL" "$REPO_NAME" || { error_exit "Git clone failed"; }
  # Remove credential from remote
  cd "$REPO_NAME"
  if [[ "$GIT_REPO" =~ ^https:// ]]; then
    git remote set-url origin "$GIT_REPO"
  fi
fi

log "Checked out branch '$BRANCH' in $(pwd)."

# --------------------------
# Step 3: Navigate and verify Docker artifacts
# --------------------------
log "Verifying Dockerfile or docker-compose.yml (step 3)."
if [[ -f "Dockerfile" ]]; then
  log "Found Dockerfile."
  DEPLOY_MODE="dockerfile"
elif [[ -f "docker-compose.yml" || -f "docker-compose.yaml" ]]; then
  log "Found docker-compose file."
  DEPLOY_MODE="compose"
else
  err "No Dockerfile or docker-compose.yml found in project root. Aborting."
  exit 1
fi

# Store repo absolute path for transfer
LOCAL_PROJECT_DIR="$(pwd)"
log "Local project path: $LOCAL_PROJECT_DIR"

# --------------------------
# Step 4: SSH connectivity check
# --------------------------
log "Checking SSH connectivity to ${SSH_USER}@${SERVER_IP} (step 4)."
if ping -c 2 -W 2 "$SERVER_IP" >/dev/null 2>&1; then
  log "Ping OK."
else
  warn "Ping failed (server may block ICMP). Will try SSH connection test."
fi

if ssh -i "$SSH_KEY_PATH" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" 'echo SSH_OK' >/tmp/ssh_test.out 2>&1; then
  if grep -q "SSH_OK" /tmp/ssh_test.out; then
    log "SSH connection test succeeded."
    rm -f /tmp/ssh_test.out
  fi
else
  cat /tmp/ssh_test.out || true
  rm -f /tmp/ssh_test.out
  err "SSH connectivity failed. Check IP, username, and SSH key."
  exit 3
fi

# --------------------------
# Step 5: Prepare remote environment
# --------------------------
log "Preparing remote server (install Docker, Docker Compose, Nginx) (step 5)."
ssh -i "$SSH_KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" bash -s <<'REMOTE_PREP'
set -euo pipefail

echo "Updating packages..."
sudo apt-get update -y
sudo apt-get upgrade -y

# Install prerequisites for Docker
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# Install Docker if missing
if ! command -v docker &>/dev/null; then
  echo "Installing Docker..."
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io
  sudo systemctl enable docker
  sudo systemctl start docker
else
  echo "Docker present."
fi

# Install docker-compose if missing
if ! command -v docker-compose &>/dev/null; then
  echo "Installing docker-compose..."
  sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose
else
  echo "docker-compose present."
fi

# Install nginx if missing
if ! command -v nginx &>/dev/null; then
  echo "Installing Nginx..."
  sudo apt-get install -y nginx
  sudo systemctl enable nginx
  sudo systemctl start nginx
else
  echo "Nginx present."
fi

# Add current user to docker group (so no sudo needed)
if ! groups "$USER" | grep -q '\bdocker\b'; then
  sudo usermod -aG docker "$USER" || true
  echo "Added $USER to docker group (may need re-login to apply)."
fi

# Show versions
echo "Docker version: $(docker --version || true)"
echo "Docker Compose version: $(docker-compose --version || echo 'not found')"
echo "Nginx version: $(nginx -v 2>&1 || true)"

REMOTE_PREP

# --------------------------
# Step 6: Deploy the Dockerized Application
# --------------------------
log "Transferring project files to remote and deploying (step 6)."

REMOTE_APP_DIR="~/deployed_app"
RSYNC_OPTS="-az --delete --exclude .git"
log "Rsync to $SSH_USER@$SERVER_IP:$REMOTE_APP_DIR"
rsync $RSYNC_OPTS -e "ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no" "$LOCAL_PROJECT_DIR/" "$SSH_USER@$SERVER_IP:$REMOTE_APP_DIR/" || { err "File transfer failed"; exit 5; }

log "Files transferred. Running remote build and start."

ssh -i "$SSH_KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" bash -s <<'REMOTE_DEPLOY'
set -euo pipefail

APP_DIR=~/deployed_app
cd "$APP_DIR"

# stop old container if exists
APP_NAME="deployed_app"
if docker ps -a --format '{{.Names}}' | grep -q "^${APP_NAME}$"; then
  docker stop "${APP_NAME}" || true
  docker rm "${APP_NAME}" || true
fi

# If docker-compose present in project, use it
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  echo "Using docker-compose to build and run..."
  sudo docker-compose down || true
  sudo docker-compose pull || true
  sudo docker-compose up -d --build
else
  # Use Dockerfile path
  if [ -f Dockerfile ]; then
    echo "Building Docker image..."
    sudo docker build -t ${APP_NAME}:latest .
    echo "Running container..."
    sudo docker run -d --name ${APP_NAME} --network bridge -p ${APP_PORT}:80 ${APP_NAME}:latest
  else
    echo "No Dockerfile or docker-compose.yml found on remote. Aborting."
    exit 5
  fi
fi

# Wait a little for container to boot
sleep 8

# Show container status and last logs
docker ps --filter "name=${APP_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
docker logs $(docker ps -q --filter "name=${APP_NAME}" | head -n1) --tail 20 || true

REMOTE_DEPLOY

# --------------------------
# Step 7: Configure Nginx as reverse proxy
# --------------------------
log "Configuring Nginx on remote (step 7)."

ssh -i "$SSH_KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" bash -s <<'REMOTE_NGINX'
set -euo pipefail
APP_PORT="'$APP_PORT'"
APP_NAME="deployed_app"
NGINX_CONF="/etc/nginx/sites-available/${APP_NAME}.conf"
sudo bash -c "cat > $NGINX_CONF" <<'NGCONF'
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:APP_PORT_REPLACE;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
    }
}
NGCONF
# Replace placeholder port
sudo sed -i "s/APP_PORT_REPLACE/${APP_PORT}/g" "$NGINX_CONF"

sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/${APP_NAME}.conf
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl reload nginx
REMOTE_NGINX

# --------------------------
# Step 8: Validate Deployment
# --------------------------
log "Validating deployment (step 8)."

ssh -i "$SSH_KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" bash -s <<'REMOTE_VALIDATE'
set -euo pipefail
APP_NAME="deployed_app"
APP_PORT="'$APP_PORT'"

# Docker service
if systemctl is-active --quiet docker; then
  echo "Docker is running."
else
  echo "Docker is NOT running."
  exit 6
fi

# Container check
if docker ps --format '{{.Names}}' | grep -q "^${APP_NAME}$"; then
  echo "Container ${APP_NAME} is running."
else
  echo "Container ${APP_NAME} not found."
  docker ps -a
  exit 6
fi

# Nginx check
if systemctl is-active --quiet nginx; then
  echo "Nginx running."
else
  echo "Nginx not running."
  exit 6
fi

# Local curl check via Nginx
if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1" | grep -q "200"; then
  echo "Local HTTP test via Nginx succeeded (200)."
else
  echo "Local HTTP test failed; check app logs."
  docker logs $(docker ps -q --filter "name=${APP_NAME}" | head -n1) --tail 30 || true
  exit 6
fi
REMOTE_VALIDATE

log "Validation succeeded."

# --------------------------
# Step 9: Logging summary
# --------------------------
log "Deployment finished. Logs saved to $LOGFILE"

# --------------------------
# Step 10: Idempotency notes
# --------------------------
log "Script is idempotent: re-running will stop/remove old containers and redeploy safely."

# End
exit 0
