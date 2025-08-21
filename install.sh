#!/bin/bash
# simple-tor-chat installer (idempotent)
# Target: clean Ubuntu instance, but robust on any host.
# Goal: deploy & start service end-to-end; on failure show what/why; reruns succeed.

###############################################################################
#                              CONFIG (DEFAULTS)                              #
###############################################################################
CHAT_PORT_DEFAULT="3000"
INFO_PORT_DEFAULT="3330"
DOMAIN_DEFAULT=""
REPO_URL="https://github.com/czerwinskicez/simple-tor-chat.git"
APP_DIR="/var/www/chat"
LOG_FILE="/tmp/chat_install.log"

###############################################################################
#                                COLOR OUTPUT                                 #
###############################################################################
# Disable colors if NO_COLOR is set or output is not a TTY
if [[ -t 1 && -z "$NO_COLOR" ]]; then
  C_RESET="\e[0m"; C_DIM="\e[2m"
  C_RED="\e[31m"; C_GREEN="\e[32m"; C_YELLOW="\e[33m"; C_BLUE="\e[34m"
  C_MAGENTA="\e[35m"; C_CYAN="\e[36m"; C_BOLD="\e[1m"
else
  C_RESET=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
  C_MAGENTA=""; C_CYAN=""; C_BOLD=""
fi

say()   { printf "%b%s%b\n" "$1" "$2" "$C_RESET"; }
info()  { say "$C_CYAN"    "$1"; }
ok()    { say "$C_GREEN"   "$1"; }
warn()  { say "$C_YELLOW"  "$1"; }
err()   { say "$C_RED"     "$1"; }
head1() { printf "%b\n"    "${C_BOLD}${C_BLUE}== $1 ==${C_RESET}"; }
head2() { printf "%b\n"    "${C_BOLD}${C_MAGENTA}# $1${C_RESET}"; }

###############################################################################
#                              STATUS TRACKING                                 #
###############################################################################
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

###############################################################################
#                              USER DETECTION                                  #
###############################################################################
if [ -n "$SUDO_USER" ]; then
  RUN_AS_USER=$SUDO_USER
  USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
  RUN_AS_USER=$USER
  USER_HOME=$HOME
fi

###############################################################################
#                                   HELP                                       #
###############################################################################
usage() {
  cat <<USAGE
${C_BOLD}Usage:${C_RESET} $0 -a ADMIN_KEYS [-c CHAT_PORT] [-i INFO_PORT] [-d DOMAIN]

  -a ADMIN_KEYS  Comma-separated admin keys (MANDATORY)
  -c CHAT_PORT   Chat port (default: $CHAT_PORT_DEFAULT)
  -i INFO_PORT   Info/HTTP port (default: $INFO_PORT_DEFAULT)
  -d DOMAIN      Domain for Nginx/Certbot (optional)

${C_DIM}Example:${C_RESET}
  sudo bash $0 -a key1,key2 -d chat.example.com -c 3000 -i 3330
USAGE
  exit 1
}

###############################################################################
#                                  HELPERS                                     #
###############################################################################
log_hdr() {
  head2 "Step $1: ${STEPS[$1]}"
}

run_as_user_with_nvm() {
  # Runs arbitrary command as the app user with NVM loaded.
  # Usage: run_as_user_with_nvm "commands"
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
  log_hdr "$step_num"
  if eval "$cmd" >> "$LOG_FILE" 2>&1; then
    STATUS[$step_num]="${C_GREEN}SUCCESS${C_RESET}"
    ok "Status: SUCCESS"
  else
    STATUS[$step_num]="${C_RED}FAILED${C_RESET}"
    err "Status: FAILED (see $LOG_FILE)"
  fi
}

###############################################################################
#                              INITIAL SETUP                                   #
###############################################################################
head1 "simple-tor-chat installer"
info "Logging to: $LOG_FILE"
: > "$LOG_FILE"
info "Running as: $RUN_AS_USER"
info "User home : $USER_HOME"
echo "Running as: $RUN_AS_USER"   >> "$LOG_FILE"
echo "User home : $USER_HOME"     >> "$LOG_FILE"

# Parse args
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
  err "Error: -a ADMIN_KEYS is mandatory."
  usage
fi

###############################################################################
#                                   SCRIPT                                     #
###############################################################################

# Step 1: System Update
run_step 1 "sudo apt-get update -y && sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y"

# Step 2: Dependencies
run_step 2 "sudo apt-get install -y nginx git tor curl ufw"

# Step 3: Node via NVM
log_hdr "3"
{
  export NVM_DIR="$USER_HOME/.nvm"
  if [ ! -d "$NVM_DIR" ]; then
    echo "Installing NVM to $NVM_DIR"
    sudo -u "$RUN_AS_USER" -i bash -lc "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash"
  else
    echo "NVM already present at $NVM_DIR"
  fi
  run_as_user_with_nvm "nvm install --lts && nvm alias default 'lts/*' && nvm use default"
  run_as_user_with_nvm "node -v && npm -v"
  STATUS[3]="${C_GREEN}SUCCESS${C_RESET}"
} >> "$LOG_FILE" 2>&1 || STATUS[3]="${C_RED}FAILED${C_RESET}"
[ "${STATUS[3]}" = "${C_RED}FAILED${C_RESET}" ] && err "Status: FAILED (see $LOG_FILE)" || ok "Status: SUCCESS"

# Step 4: Configure Tor Hidden Service
log_hdr "4"
{
  TORRC="/etc/tor/torrc"
  TS="$(date +%Y%m%d-%H%M%S)"
  sudo cp -a "$TORRC" "$TORRC.bak.$TS" 2>/dev/null || true

  sudo mkdir -p /var/lib/tor/hidden_service
  sudo chown -R debian-tor:debian-tor /var/lib/tor/hidden_service
  sudo chmod 700 /var/lib/tor/hidden_service

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
      STEP4_OK=1
      break
    fi
    sleep 1
  done
  if [ -n "${STEP4_OK:-}" ]; then
    STATUS[4]="${C_GREEN}SUCCESS${C_RESET}"
  else
    echo "Timed out waiting for $HOSTNAME_FILE"
    STATUS[4]="${C_RED}FAILED (Timeout)${C_RESET}"
  fi
} >> "$LOG_FILE" 2>&1
[[ "${STATUS[4]}" =~ SUCCESS ]] && ok "Status: SUCCESS" || err "Status: ${STATUS[4]} (see $LOG_FILE)"

# Step 5: Clone/Update repository
log_hdr "5"
{
  TS="$(date +%Y%m%d-%H%M%S)"
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
  STATUS[5]="${C_GREEN}SUCCESS${C_RESET} (${ACTION})"
} >> "$LOG_FILE" 2>&1 || STATUS[5]="${C_RED}FAILED${C_RESET}"
[[ "${STATUS[5]}" =~ SUCCESS ]] && ok "Status: ${STATUS[5]}" || err "Status: FAILED (see $LOG_FILE)"

# Step 6: Configure application (Node version, deps, .env)
log_hdr "6"
{
  if run_as_user_with_nvm "test -f '$APP_DIR/.nvmrc'"; then
    run_as_user_with_nvm "cd '$APP_DIR' && nvm install && nvm use"
  else
    run_as_user_with_nvm "nvm use default"
  fi

  if run_as_user_with_nvm "test -f '$APP_DIR/package-lock.json'"; then
    run_as_user_with_nvm "cd '$APP_DIR' && npm ci"
  else
    echo "package-lock.json not found – running npm install"
    run_as_user_with_nvm "cd '$APP_DIR' && npm install"
  fi

  : "${ONION_LINK:=}"
  ENV_ONION=""
  if [ -n "$ONION_LINK" ]; then
    ENV_ONION="http://$ONION_LINK"
  else
    echo "WARNING: ONION_LINK is empty (Tor step likely failed). Proceeding anyway."
  fi

  run_as_user_with_nvm "cd '$APP_DIR' && cat > .env <<'ENVEOF'
CHAT_PORT=$CHAT_PORT
INFO_PORT=$INFO_PORT
ONION_LINK=$ENV_ONION
ADMIN_KEYS=$ADMIN_KEYS
ENVEOF
"
  STATUS[6]="${C_GREEN}SUCCESS${C_RESET}"
} >> "$LOG_FILE" 2>&1 || STATUS[6]="${C_RED}FAILED${C_RESET}"
[[ "${STATUS[6]}" =~ SUCCESS ]] && ok "Status: SUCCESS" || err "Status: FAILED (see $LOG_FILE)"

# Step 7: Start app with PM2, enable autostart, optional healthcheck
log_hdr "7"
{
  run_as_user_with_nvm "command -v pm2 >/dev/null || npm i -g pm2"

  # Detect entrypoint: prefer npm start, else server.js/app.js/index.js
  HAS_NPM_START=$(run_as_user_with_nvm "cd '$APP_DIR' && [ -f package.json ] && grep -q '\"start\"[[:space:]]*:' package.json && echo yes || echo no")
  if [ "$HAS_NPM_START" = "yes" ]; then
    run_as_user_with_nvm "cd '$APP_DIR' && (pm2 reload simple-chat || pm2 start npm --name simple-chat -- start)"
  else
    ENTRY=""
    run_as_user_with_nvm "[ -f '$APP_DIR/server.js' ]" && ENTRY="server.js" || true
    if [ -z "$ENTRY" ]; then run_as_user_with_nvm "[ -f '$APP_DIR/app.js' ]" && ENTRY="app.js" || true; fi
    if [ -z "$ENTRY" ]; then run_as_user_with_nvm "[ -f '$APP_DIR/index.js' ]" && ENTRY="index.js" || true; fi
    if [ -n "$ENTRY" ]; then
      run_as_user_with_nvm "cd '$APP_DIR' && (pm2 reload simple-chat || pm2 start '$ENTRY' --name simple-chat)"
    else
      echo "ERROR: No entrypoint found (server.js/app.js/index.js) and no 'npm start'."
      false
    fi
  fi

  run_as_user_with_nvm "pm2 save"

  # PM2 autostart
  STARTUP_CMD=$(run_as_user_with_nvm "pm2 startup systemd -u '$RUN_AS_USER' --hp '$USER_HOME'" | tail -n 1)
  if echo "$STARTUP_CMD" | grep -q "sudo"; then
    eval "$STARTUP_CMD"
  else
    sudo env PATH=$PATH pm2 startup systemd -u "$RUN_AS_USER" --hp "$USER_HOME"
  fi

  # Optional healthcheck (not blocking)
  if command -v curl >/dev/null; then
    curl -fsS "http://127.0.0.1:$INFO_PORT/health" >/dev/null 2>&1 && echo "Healthcheck: OK" || echo "Healthcheck: not available (ignored)"
  fi

  STATUS[7]="${C_GREEN}SUCCESS${C_RESET}"
} >> "$LOG_FILE" 2>&1 || STATUS[7]="${C_RED}FAILED${C_RESET}"
[[ "${STATUS[7]}" =~ SUCCESS ]] && ok "Status: SUCCESS" || err "Status: FAILED (see $LOG_FILE)"

# Step 8: Nginx config (if DOMAIN provided)
if [ -n "$DOMAIN" ]; then
  log_hdr "8"
  {
    NGINX_PATH="/etc/nginx/sites-available/$DOMAIN"
    TS="$(date +%Y%m%d-%H%M%S)"
    if [ -f "$NGINX_PATH" ]; then
      sudo cp -a "$NGINX_PATH" "$NGINX_PATH.bak.$TS"
    fi

    sudo tee "$NGINX_PATH" >/dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;

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

    # Optional subpath to Chat:
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
    STATUS[8]="${C_GREEN}SUCCESS${C_RESET}"
  } >> "$LOG_FILE" 2>&1 || STATUS[8]="${C_RED}FAILED${C_RESET}"
  [[ "${STATUS[8]}" =~ SUCCESS ]] && ok "Status: SUCCESS" || err "Status: FAILED (see $LOG_FILE)"
else
  STATUS[8]="${C_DIM}SKIPPED (No domain provided)${C_RESET}"
  warn "Status: SKIPPED (No domain provided)"
fi

# Step 9: UFW rules
log_hdr "9"
{
  sudo ufw allow 'OpenSSH' || sudo ufw allow 22/tcp
  if [ -n "$DOMAIN" ]; then
    sudo ufw allow 'Nginx Full' || { sudo ufw allow 80/tcp; sudo ufw allow 443/tcp; }
  else
    sudo ufw allow 80/tcp || true
  fi
  sudo ufw --force enable
  STATUS[9]="${C_GREEN}SUCCESS${C_RESET}"
} >> "$LOG_FILE" 2>&1 || STATUS[9]="${C_RED}FAILED${C_RESET}"
[[ "${STATUS[9]}" =~ SUCCESS ]] && ok "Status: SUCCESS" || err "Status: FAILED (see $LOG_FILE)"

# Step 10: Certbot
if [ -n "$DOMAIN" ]; then
  log_hdr "10"
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

    STATUS[10]="${C_GREEN}SUCCESS${C_RESET} (${CB_STATE})"
  } >> "$LOG_FILE" 2>&1 || STATUS[10]="${C_RED}FAILED${C_RESET}"
  [[ "${STATUS[10]}" =~ SUCCESS ]] && ok "Status: SUCCESS" || err "Status: FAILED (see $LOG_FILE)"
else
  STATUS[10]="${C_DIM}SKIPPED (No domain provided)${C_RESET}"
  warn "Status: SKIPPED (No domain provided)"
fi

###############################################################################
#                               FINAL SUMMARY                                  #
###############################################################################
echo
head1 "Installation Summary"
FAILED_ANY=0
for i in $(seq 1 10); do
  printf "%-6s %-30s -> %b\n" "Step $i:" "${STEPS[$i]}" "${STATUS[$i]}"
  # crude check for the word FAILED in colorized status:
  if [[ "${STATUS[$i]}" == *"FAILED"* ]]; then FAILED_ANY=1; fi
done
echo "----------------------------------------"

# PM2 status (robust ASCII parsing)
APP_STATUS=$(run_as_user_with_nvm \
  "pm2 show simple-chat 2>/dev/null | awk -F: '/status/ {gsub(/^[ \t]+|[ \t]+$/,\"\",\$2); print \$2; exit}'" \
  || echo "")
if [[ -z "$APP_STATUS" ]]; then
  APP_STATUS="NOT RUNNING"
fi
printf "%s %b\n" "Application Status:" "$( [[ "$APP_STATUS" =~ [Oo]nline ]] && echo "${C_GREEN}$APP_STATUS${C_RESET}" || echo "${C_RED}$APP_STATUS${C_RESET}" )"

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

# If anything failed, tail install log
if [[ $FAILED_ANY -eq 1 ]]; then
  echo
  head2 "Tail of install log (last 120 lines)"
  tail -n 120 "$LOG_FILE" || true
fi

# If app is not online, show last PM2 logs for quick DX
if [[ ! "$APP_STATUS" =~ [Oo]nline ]]; then
  echo
  head2 "PM2 logs (last 80 lines)"
  run_as_user_with_nvm "pm2 logs simple-chat --lines 80 --nostream" || true
fi
