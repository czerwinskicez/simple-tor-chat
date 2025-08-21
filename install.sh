#!/bin/bash
# simple-tor-chat installer
# Target: clean Ubuntu instance, but idempotent + verbose on any host.
# Goal: deploy & start service end-to-end; on failure show what/why; reruns succeed.

# --- Configuration (defaults, can be overridden by flags) ---
CHAT_PORT_DEFAULT="3000"
INFO_PORT_DEFAULT="3330"
DOMAIN_DEFAULT=""
REPO_URL="https://github.com/czerwinskicez/simple-tor-chat.git"
APP_DIR="/var/www/chat"
LOG_FILE="/tmp/chat_install.log"

# --- Status Tracking ---
declare -A STEPS=(
  ["1"]="System Update"
  ["2"]="Install Dependencies"
  ["3"]="Install Node.js (NVM)"
  ["4"]="Configure Tor Hidden Service"
  ["5"]="Clone/Update Repository"
  ["6"]="Configure Application"
  ["7"]="Start Application (PM2 + Autostart)"
  ["8"]="Configure Nginx"
  ["9"]="Configure Firewall (UFW)"
  ["10"]="Configure SSL (Certbot)"
)
declare -A STATUS
for i in ${!STEPS[@]}; do STATUS[$i]="SKIPPED"; done

# --- User Detection ---
if [ -n "$SUDO_USER" ]; then
  RUN_AS_USER=$SUDO_USER
  USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
  RUN_AS_USER=$USER
  USER_HOME=$HOME
fi

# --- Helpers ---
usage() {
  cat <<USAGE
Usage: $0 -a ADMIN_KEYS [-c CHAT_PORT] [-i INFO_PORT] [-d DOMAIN]
  -a ADMIN_KEYS: Comma-separated admin keys (MANDATORY)
  -c CHAT_PORT : Chat port (default: $CHAT_PORT_DEFAULT)
  -i INFO_PORT : Info port (default: $INFO_PORT_DEFAULT)
  -d DOMAIN    : Domain for Nginx/Certbot (optional)
USAGE
  exit 1
}

log_hdr() {
  echo "### $1..."
}

run_as_user_with_nvm() {
  # Runs arbitrary command as the app user with NVM environment loaded.
  # Usage: run_as_user_with_nvm "your commands"
  local cmd="$*"
  sudo -u "$RUN_AS_USER" -i bash -lc "
    set -Eeuo pipefail
    export NVM_DIR=\"$USER_HOME/.nvm\"
    [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
    $cmd
  "
}

run_step() {
  local step_num=$1; shift
  local cmd="$*"
  log_hdr "Step $step_num: ${STEPS[$step_num]}"
  if eval "$cmd" >> "$LOG_FILE" 2>&1; then
    STATUS[$step_num]="SUCCESS"
  else
    STATUS[$step_num]="FAILED"
  fi
  echo "--- Status: ${STATUS[$step_num]}"
}

# --- Initial Setup ---
echo "Starting installation. Logging to $LOG_FILE"
: > "$LOG_FILE" # truncate
echo "Running as: $RUN_AS_USER" | tee -a "$LOG_FILE"
echo "User home: $USER_HOME"   | tee -a "$LOG_FILE"

# --- Argument Parsing ---
while getopts ":c:i:d:a:" opt; do
  case ${opt} in
    c) CHAT_PORT=$OPTARG ;;
    i) INFO_PORT=$OPTARG ;;
    d) DOMAIN=$OPTARG ;;
    a) ADMIN_KEYS=$OPTARG ;;
    \?) usage ;;
  esac
done

CHAT_PORT=${CHAT_PORT:-$CHAT_PORT_DEFAULT}
INFO_PORT=${INFO_PORT:-$INFO_PORT_DEFAULT}
DOMAIN=${DOMAIN:-$DOMAIN_DEFAULT}

if [ -z "$ADMIN_KEYS" ]; then
  echo "Error: -a ADMIN_KEYS is mandatory." | tee -a "$LOG_FILE"
  usage
fi

# --- Script ---

# Step 1: System Update
run_step 1 "sudo apt-get update -y && sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y"

# Step 2: Dependencies
run_step 2 "sudo apt-get install -y nginx git tor curl ufw"

# Step 3: Node via NVM (install NVM if missing, install default LTS)
log_hdr "Step 3: ${STEPS[3]}"
{
  export NVM_DIR="$USER_HOME/.nvm"
  if [ ! -d "$NVM_DIR" ]; then
    echo "Installing NVM to $NVM_DIR"
    sudo -u "$RUN_AS_USER" -i bash -lc "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash"
  else
    echo "NVM already present at $NVM_DIR"
  fi

  # Install/Use LTS as default for now (repo-specific .nvmrc handled later in Step 6)
  run_as_user_with_nvm "nvm install --lts && nvm alias default 'lts/*' && nvm use default"
  run_as_user_with_nvm "node -v && npm -v"
  STATUS[3]="SUCCESS"
} >> "$LOG_FILE" 2>&1 || STATUS[3]="FAILED"
echo "--- Status: ${STATUS[3]}"

# Step 4: Configure Tor Hidden Service
log_hdr "Step 4: ${STEPS[4]}"
{
  TORRC="/etc/tor/torrc"
  TS="$(date +%Y%m%d-%H%M%S)"
  sudo cp -a "$TORRC" "$TORRC.bak.$TS" 2>/dev/null || true

  # Ensure HiddenServiceDir exists and has correct ownership/permissions
  sudo mkdir -p /var/lib/tor/hidden_service
  sudo chown -R debian-tor:debian-tor /var/lib/tor/hidden_service
  sudo chmod 700 /var/lib/tor/hidden_service

  # Idempotently add our block (if not already present)
  if ! grep -q "# --- simple-tor-chat ---" "$TORRC"; then
    sudo tee -a "$TORRC" >/dev/null <<EOF

# --- simple-tor-chat ---
HiddenServiceDir /var/lib/tor/hidden_service/
HiddenServicePort 80 127.0.0.1:$CHAT_PORT
# --- end simple-tor-chat ---
EOF
  else
    echo "Tor config block already present."
  fi

  sudo systemctl restart tor

  echo "Waiting for Tor hostname (up to 120s)..."
  HOSTNAME_FILE="/var/lib/tor/hidden_service/hostname"
  for i in $(seq 1 120); do
    if sudo test -f "$HOSTNAME_FILE"; then
      ONION_LINK="$(sudo cat "$HOSTNAME_FILE")"
      echo "Tor Onion Service Address: http://$ONION_LINK"
      STATUS[4]="SUCCESS"
      break
    fi
    sleep 1
  done
  if [ "${STATUS[4]}" != "SUCCESS" ]; then
    echo "Timed out waiting for $HOSTNAME_FILE"
    STATUS[4]="FAILED (Timeout)"
  fi
} >> "$LOG_FILE" 2>&1
echo "--- Status: ${STATUS[4]}"

# Step 5: Clone/Update repository
log_hdr "Step 5: ${STEPS[5]}"
{
  if [ ! -d "$APP_DIR" ]; then
    sudo mkdir -p "$(dirname "$APP_DIR")"
    sudo git clone "$REPO_URL" "$APP_DIR"
    ACTION="Cloned"
  else
    if [ -d "$APP_DIR/.git" ]; then
      (cd "$APP_DIR" && sudo git pull --ff-only) || true
      ACTION="Pulled"
    else
      echo "WARNING: $APP_DIR exists but is not a git repo. Backing it up and recloning."
      sudo mv "$APP_DIR" "${APP_DIR}.bak.$TS"
      sudo git clone "$REPO_URL" "$APP_DIR"
      ACTION="Recloned"
    fi
  fi
  sudo chown -R "$RUN_AS_USER:$RUN_AS_USER" "$APP_DIR"
  STATUS[5]="SUCCESS ($ACTION)"
} >> "$LOG_FILE" 2>&1 || STATUS[5]="FAILED"
echo "--- Status: ${STATUS[5]}"

# Step 6: Configure application (Node version, deps, .env)
log_hdr "Step 6: ${STEPS[6]}"
{
  # If repo defines .nvmrc, respect it for this project
  if run_as_user_with_nvm "test -f '$APP_DIR/.nvmrc'"; then
    run_as_user_with_nvm "cd '$APP_DIR' && nvm install && nvm use"
  else
    run_as_user_with_nvm "nvm use default"
  fi

  # Install deps: prefer npm ci if lockfile present
  if run_as_user_with_nvm "test -f '$APP_DIR/package-lock.json'"; then
    run_as_user_with_nvm "cd '$APP_DIR' && npm ci"
  else
    echo "package-lock.json not found – running npm install"
    run_as_user_with_nvm "cd '$APP_DIR' && npm install"
  fi

  # Compose .env content
  : "${ONION_LINK:=}"
  ENV_ONION=""
  if [ -n "$ONION_LINK" ]; then
    ENV_ONION="http://$ONION_LINK"
  else
    echo "WARNING: ONION_LINK is empty (Tor step likely failed). Proceeding anyway."
  fi

  # Write .env safely as app user (heredoc, no expansion inside)
  run_as_user_with_nvm "cd '$APP_DIR' && cat > .env <<'ENVEOF'
CHAT_PORT=$CHAT_PORT
INFO_PORT=$INFO_PORT
ONION_LINK=$ENV_ONION
ADMIN_KEYS=$ADMIN_KEYS
ENVEOF
"
  STATUS[6]="SUCCESS"
} >> "$LOG_FILE" 2>&1 || STATUS[6]="FAILED"
echo "--- Status: ${STATUS[6]}"

# Step 7: Start app with PM2, enable autostart, optional healthcheck
log_hdr "Step 7: ${STEPS[7]}"
{
  run_as_user_with_nvm "command -v pm2 >/dev/null || npm i -g pm2"

  # Start/reload
  run_as_user_with_nvm "cd '$APP_DIR' && (pm2 reload simple-chat || pm2 start server.js --name simple-chat)"
  run_as_user_with_nvm "pm2 save"

  # Setup PM2 to start on boot (systemd)
  # pm2 prints a command we should run as root; capture and execute safely.
  STARTUP_CMD=$(run_as_user_with_nvm "pm2 startup systemd -u '$RUN_AS_USER' --hp '$USER_HOME'" | tail -n 1)
  if echo "$STARTUP_CMD" | grep -q "sudo"; then
    # Execute the printed command
    eval "$STARTUP_CMD"
  else
    # Fallback: run explicitly
    sudo env PATH=$PATH pm2 startup systemd -u "$RUN_AS_USER" --hp "$USER_HOME"
  fi

  # Optional healthcheck (won't fail the step)
  if command -v curl >/dev/null; then
    curl -fsS "http://127.0.0.1:$INFO_PORT/health" >/dev/null 2>&1 && echo "Healthcheck: OK" || echo "Healthcheck: not available (ignored)"
  fi

  STATUS[7]="SUCCESS"
} >> "$LOG_FILE" 2>&1 || STATUS[7]="FAILED"
echo "--- Status: ${STATUS[7]}"

# Step 8: Nginx config (if DOMAIN provided)
if [ -n "$DOMAIN" ]; then
  log_hdr "Step 8: ${STEPS[8]}"
  {
    NGINX_PATH="/etc/nginx/sites-available/$DOMAIN"
    TS="$(date +%Y%m%d-%H%M%S)"
    if [ -f "$NGINX_PATH" ]; then
      sudo cp -a "$NGINX_PATH" "$NGINX_PATH.bak.$TS"
    fi

    # Serve INFO_PORT at / ; websockets/upgrade headers included; add common proxy headers
    sudo tee "$NGINX_PATH" >/dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    # Redirect /.well-known/acme-challenge to nginx root for Certbot (nginx plugin manages this)
    location /.well-known/acme-challenge/ { root /var/www/html; allow all; }

    location / {
        proxy_pass http://127.0.0.1:$INFO_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
    }

    # Optional path to Chat server (if you want direct access on /chat)
    location /chat/ {
        rewrite ^/chat/?(.*)$ /\$1 break;
        proxy_pass http://127.0.0.1:$CHAT_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
    }

    access_log /var/log/nginx/${DOMAIN}_access.log;
    error_log  /var/log/nginx/${DOMAIN}_error.log;
}
EOF

    sudo ln -sf "$NGINX_PATH" "/etc/nginx/sites-enabled/$DOMAIN"
    sudo nginx -t
    sudo systemctl restart nginx
    STATUS[8]="SUCCESS"
  } >> "$LOG_FILE" 2>&1 || STATUS[8]="FAILED"
  echo "--- Status: ${STATUS[8]}"
else
  STATUS[8]="SKIPPED (No domain provided)"
  echo "--- Status: ${STATUS[8]}"
fi

# Step 9: UFW rules (safe for SSH)
log_hdr "Step 9: ${STEPS[9]}"
{
  sudo ufw allow 'OpenSSH' || sudo ufw allow 22/tcp
  if [ -n "$DOMAIN" ]; then
    sudo ufw allow 'Nginx Full' || { sudo ufw allow 80/tcp; sudo ufw allow 443/tcp; }
  else
    # No domain: still open 80 for potential local reverse proxy, optional
    sudo ufw allow 80/tcp || true
  fi
  sudo ufw --force enable
  STATUS[9]="SUCCESS"
} >> "$LOG_FILE" 2>&1 || STATUS[9]="FAILED"
echo "--- Status: ${STATUS[9]}"

# Step 10: Certbot (if DOMAIN provided)
if [ -n "$DOMAIN" ]; then
  log_hdr "Step 10: ${STEPS[10]}"
  {
    if ! command -v certbot >/dev/null 2>&1; then
      sudo apt-get install -y certbot python3-certbot-nginx
      CB_STATE="Installed, "
    else
      CB_STATE="Exists, "
    fi

    if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
      sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN" --redirect
      CB_STATE+="new cert created"
    else
      CB_STATE+="cert exists"
    fi

    STATUS[10]="SUCCESS ($CB_STATE)"
  } >> "$LOG_FILE" 2>&1 || STATUS[10]="FAILED"
  echo "--- Status: ${STATUS[10]}"
else
  STATUS[10]="SKIPPED (No domain provided)"
  echo "--- Status: ${STATUS[10]}"
fi

# --- Final Summary ---
echo
echo "========================================"
echo " Installation Summary"
echo "========================================"
FAILED_ANY=0
for i in $(seq 1 10); do
  printf "Step %-2s: %-28s -> %s\n" "$i" "${STEPS[$i]}" "${STATUS[$i]}"
  if [[ "${STATUS[$i]}" == FAILED* ]]; then FAILED_ANY=1; fi
done
echo "----------------------------------------"

# PM2 status
APP_STATUS_RAW=$(run_as_user_with_nvm "pm2 describe simple-chat 2>/dev/null | grep -m1 'status'" || echo "status: not_found")
APP_STATUS=$(echo "$APP_STATUS_RAW" | awk -F'│' '{gsub(/ /,\"\"); print \$4}' | tr -d '[:space:]')
if [[ -z "$APP_STATUS" || "$APP_STATUS" == "not_found" ]]; then
  echo "Application Status: NOT RUNNING"
else
  echo "Application Status: $APP_STATUS"
fi

# URLs
if [ -n "$ONION_LINK" ]; then
  echo "Onion URL: http://$ONION_LINK"
else
  echo "Onion URL: (unavailable)"
fi
if [ -n "$DOMAIN" ]; then
  echo "Domain URL: https://$DOMAIN"
fi
echo "========================================"
echo "Full log: $LOG_FILE"

# If anything failed, show last 120 lines of log to console
if [[ $FAILED_ANY -eq 1 ]]; then
  echo
  echo "---- Tail of log (last 120 lines) ----"
  tail -n 120 "$LOG_FILE" || true
  echo "--------------------------------------"
fi
