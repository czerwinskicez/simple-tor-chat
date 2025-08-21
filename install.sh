#!/bin/bash
# simple-tor-chat installer — robust, idempotent, DX-boosted (full 10 steps)
# - Installs/validates Node via NVM (with NodeSource fallback)
# - Sets up Tor hidden service (prints Onion URL)
# - Clones/updates repo, installs deps, writes .env
# - Starts app with PM2 (+ autostart), configures Nginx/UFW/Certbot (optional)
# - Colorful output, clear per-step status, rich summary + logs on failure
#
# USAGE:
#   sudo bash install.sh -a adminKey1,adminKey2 [-c 3000] [-i 3330] [-d your.domain]
#
# EXIT CODES:
#   0  success, or success-with-warnings
#   1  fatal failure (some step FAILED). See /tmp/chat_install.log + summary tail

###############################################################################
# CONFIG (defaults; overridable by flags)
###############################################################################
CHAT_PORT_DEFAULT="3000"
INFO_PORT_DEFAULT="3330"
DOMAIN_DEFAULT=""
REPO_URL="https://github.com/czerwinskicez/simple-tor-chat.git"
APP_DIR="/var/www/chat"
LOG_FILE="/tmp/chat_install.log"

###############################################################################
# COLORS & FX (disable with NO_COLOR=1)
###############################################################################
if [[ -t 1 && -z "$NO_COLOR" ]]; then
  C_RESET="\e[0m"; C_DIM="\e[2m"
  C_RED="\e[31m"; C_GREEN="\e[32m"; C_YELLOW="\e[33m"; C_BLUE="\e[34m"
  C_MAGENTA="\e[35m"; C_CYAN="\e[36m"; C_BOLD="\e[1m"
  SYM_OK="✔"; SYM_ERR="✖"; SYM_WARN="⚠"
  FX_SPARKLES="\e[38;5;213m❇\e[0m"
  FX_ROCKET="\e[38;5;45m🚀\e[0m"
else
  C_RESET=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
  C_MAGENTA=""; C_CYAN=""; C_BOLD=""
  SYM_OK="[OK]"; SYM_ERR="[ERR]"; SYM_WARN="[!]"
  FX_SPARKLES="*"; FX_ROCKET="->"
fi
say()   { printf "%b%s%b\n" "$1" "$2" "$C_RESET"; }
ok()    { say "$C_GREEN"   "$SYM_OK $1"; }
err()   { say "$C_RED"     "$SYM_ERR $1"; }
warn()  { say "$C_YELLOW"  "$SYM_WARN $1"; }
info()  { say "$C_CYAN"    "$1"; }
head1() { printf "%b\n"    "${C_BOLD}${C_BLUE}== $1 ==${C_RESET}"; }
head2() { printf "%b\n"    "${C_BOLD}${C_MAGENTA}# $1${C_RESET}"; }
blink() { printf "%b%s%b\n" "$C_BOLD$C_YELLOW" "$1" "$C_RESET"; }

###############################################################################
# STATUS tracking (10 steps)
###############################################################################
declare -A STEPS=(
  ["1"]="System Update"
  ["2"]="Install Dependencies"
  ["3"]="Install Node.js (NVM, fallback NodeSource)"
  ["4"]="Configure Tor Hidden Service"
  ["5"]="Clone/Update Repository"
  ["6"]="Configure Application (.env + deps)"
  ["7"]="Start Application (PM2 + Autostart)"
  ["8"]="Configure Nginx (optional)"
  ["9"]="Configure Firewall (UFW)"
  ["10"]="Configure SSL (Certbot, optional)"
)
declare -A STATUS
for i in ${!STEPS[@]}; do STATUS[$i]="${C_DIM}SKIPPED${C_RESET}"; done

###############################################################################
# USER detection
###############################################################################
if [ -n "$SUDO_USER" ]; then
  RUN_AS_USER=$SUDO_USER
  USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
  RUN_AS_USER=$USER
  USER_HOME=$HOME
fi
NVM_DIR="$USER_HOME/.nvm"

###############################################################################
# HELPERS
###############################################################################
usage() {
  cat <<USAGE
${C_BOLD}Usage:${C_RESET} sudo bash $0 -a ADMIN_KEYS [-c CHAT_PORT] [-i INFO_PORT] [-d DOMAIN]
  -a  Comma-separated admin keys (MANDATORY)
  -c  Chat port (default: $CHAT_PORT_DEFAULT)
  -i  Info port (default: $INFO_PORT_DEFAULT)
  -d  Domain for Nginx/Certbot (optional)
USAGE
  exit 1
}
backup_file() {
  local f="$1"; local ts="$(date +%Y%m%d-%H%M%S)"
  [ -f "$f" ] && sudo cp -a "$f" "$f.bak.$ts"
}
print_step_header() {
  local n="$1"
  head2 "Step $n: ${STEPS[$n]}"
}
run_as_user_with_nvm() {
  local cmd="$*"
  sudo -u "$RUN_AS_USER" -i bash -lc "
    export NVM_DIR=\"$NVM_DIR\"
    if [ ! -s \"\$NVM_DIR/nvm.sh\" ]; then
      echo 'ERROR: NVM not found at' \"\$NVM_DIR/nvm.sh\" >&2
      exit 127
    fi
    . \"\$NVM_DIR/nvm.sh\"
    $cmd
  "
}
run_as_user_with_node() {
  # If NVM exists for user, use it; otherwise run plain (Node from system)
  local cmd="$*"
  if sudo -u "$RUN_AS_USER" -i bash -lc '[ -s "$HOME/.nvm/nvm.sh" ]'; then
    run_as_user_with_nvm "$cmd"
  else
    sudo -u "$RUN_AS_USER" -i bash -lc "$cmd"
  fi
}
tail_errors() {
  echo
  head2 "Recent errors in install log"
  grep -nE "ERROR|Error|failed|not found|ENOENT|EADDRINUSE|ECONN|Cannot|permission denied" "$LOG_FILE" | tail -n 30 || true
}

###############################################################################
# ARGUMENTS
###############################################################################
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
if [ -z "$ADMIN_KEYS" ]; then err "Missing -a ADMIN_KEYS"; usage; fi

###############################################################################
# START
###############################################################################
head1 "simple-tor-chat installer ${FX_ROCKET}"
: > "$LOG_FILE"
info "Log file  : $LOG_FILE"
info "Run as    : $RUN_AS_USER  (home: $USER_HOME)"
info "Repo URL  : $REPO_URL"
echo "RUN_AS_USER=$RUN_AS_USER USER_HOME=$USER_HOME NVM_DIR=$NVM_DIR" >> "$LOG_FILE"

# -----------------------------------------------------------------------------
# Step 1: System Update
# -----------------------------------------------------------------------------
print_step_header 1
if sudo apt-get update -y >>"$LOG_FILE" 2>&1 && \
   sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y >>"$LOG_FILE" 2>&1; then
  STATUS[1]="${C_GREEN}SUCCESS${C_RESET}"
  ok "System updated"
else
  STATUS[1]="${C_RED}FAILED${C_RESET}"
  err "System update failed"
fi

# -----------------------------------------------------------------------------
# Step 2: Install Dependencies
# -----------------------------------------------------------------------------
print_step_header 2
if sudo apt-get install -y nginx git tor curl ufw >>"$LOG_FILE" 2>&1; then
  STATUS[2]="${C_GREEN}SUCCESS${C_RESET}"
  ok "Dependencies installed"
else
  STATUS[2]="${C_RED}FAILED${C_RESET}"
  err "Installing dependencies failed"
fi

# -----------------------------------------------------------------------------
# Step 3: Install Node.js (NVM, fallback NodeSource)
# -----------------------------------------------------------------------------
print_step_header 3
NODE_READY=0
{
  if [ ! -d "$NVM_DIR" ]; then
    ok "Installing NVM to $NVM_DIR"
    sudo -u "$RUN_AS_USER" -i bash -lc \
      "export NVM_DIR=\"$NVM_DIR\"; mkdir -p \"\$NVM_DIR\"; \
       curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash"
  else
    echo "[NVM] Directory exists: $NVM_DIR" >>"$LOG_FILE"
  fi

  if sudo -u "$RUN_AS_USER" -i bash -lc '[ -s "$HOME/.nvm/nvm.sh" ]'; then
    run_as_user_with_nvm "nvm install --lts && nvm alias default 'lts/*' && nvm use default"
    run_as_user_with_nvm "node -v && npm -v"
    NODE_READY=1
  else
    echo "[Step3] NVM missing after install; will try NodeSource fallback." >>"$LOG_FILE"
  fi

  if [ $NODE_READY -eq 0 ]; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - >>"$LOG_FILE" 2>&1 \
      && sudo apt-get install -y nodejs >>"$LOG_FILE" 2>&1
    if node -v >>"$LOG_FILE" 2>&1; then
      echo "[Step3] Node via NodeSource OK" >>"$LOG_FILE"
      NODE_READY=1
    fi
  fi
} >>"$LOG_FILE" 2>&1

if [ $NODE_READY -eq 1 ]; then
  STATUS[3]="${C_GREEN}SUCCESS${C_RESET}"
  ok "Node available ${FX_SPARKLES}"
else
  STATUS[3]="${C_RED}FAILED${C_RESET}"
  err "No Node available (NVM and fallback failed)"
fi

# -----------------------------------------------------------------------------
# Step 4: Configure Tor Hidden Service
# -----------------------------------------------------------------------------
print_step_header 4
{
  backup_file "/etc/tor/torrc"

  sudo mkdir -p /var/lib/tor/hidden_service
  sudo chown -R debian-tor:debian-tor /var/lib/tor/hidden_service
  sudo chmod 700 /var/lib/tor/hidden_service

  if ! grep -q "# --- simple-tor-chat ---" /etc/tor/torrc; then
    sudo tee -a /etc/tor/torrc >/dev/null <<EOF

# --- simple-tor-chat ---
HiddenServiceDir /var/lib/tor/hidden_service/
HiddenServicePort 80 127.0.0.1:$CHAT_PORT
# --- end simple-tor-chat ---
EOF
  fi

  sudo systemctl restart tor

  HOSTNAME_FILE="/var/lib/tor/hidden_service/hostname"
  for i in $(seq 1 120); do
    if sudo test -f "$HOSTNAME_FILE"; then
      ONION_HOST="$(sudo cat "$HOSTNAME_FILE")"
      break
    fi
    sleep 1
  done
} >>"$LOG_FILE" 2>&1

if [ -n "${ONION_HOST:-}" ]; then
  STATUS[4]="${C_GREEN}SUCCESS${C_RESET}"
  ok "Tor onion address: http://$ONION_HOST"
else
  STATUS[4]="${C_RED}FAILED (timeout)${C_RESET}"
  err "Tor hostname not generated"
fi

# -----------------------------------------------------------------------------
# Step 5: Clone/Update Repository
# -----------------------------------------------------------------------------
print_step_header 5
STEP5_DETAIL=""
{
  if [ ! -d "$APP_DIR" ]; then
    sudo mkdir -p "$(dirname "$APP_DIR")"
  fi
  if [ -d "$APP_DIR/.git" ]; then
    (cd "$APP_DIR" && sudo git pull --ff-only) && STEP5_DETAIL="Pulled" || STEP5_DETAIL="Pulled (with warnings)"
  else
    sudo rm -rf "$APP_DIR"
    sudo git clone "$REPO_URL" "$APP_DIR" && STEP5_DETAIL="Cloned"
  fi
  sudo chown -R "$RUN_AS_USER:$RUN_AS_USER" "$APP_DIR"
} >>"$LOG_FILE" 2>&1
if [ $? -eq 0 ]; then
  STATUS[5]="${C_GREEN}SUCCESS${C_RESET} (${STEP5_DETAIL})"
  ok "Repository $STEP5_DETAIL"
else
  STATUS[5]="${C_RED}FAILED${C_RESET}"
  err "Repository sync failed"
fi

# -----------------------------------------------------------------------------
# Step 6: Configure Application (.env + deps)
# -----------------------------------------------------------------------------
print_step_header 6
if [[ "${STATUS[3]}" == *"FAILED"* ]]; then
  STATUS[6]="${C_DIM}SKIPPED (No Node)${C_RESET}"
  warn "Skipping app configuration (Node not available)"
else
  {
    # Prefer .nvmrc if exists
    if run_as_user_with_node "test -f '$APP_DIR/.nvmrc'"; then
      run_as_user_with_nvm "cd '$APP_DIR' && nvm install && nvm use"
    fi

    # Install deps (prefer npm ci)
    if run_as_user_with_node "test -f '$APP_DIR/package-lock.json'"; then
      run_as_user_with_node "cd '$APP_DIR' && npm ci"
    else
      echo "package-lock.json not found – using npm install" >>"$LOG_FILE"
      run_as_user_with_node "cd '$APP_DIR' && npm install"
    fi

    # ONION_LINK value
    ENV_ONION=""
    if [ -n "${ONION_HOST:-}" ]; then
      ENV_ONION="http://$ONION_HOST"
    fi

    # Write .env (interpolated)
    run_as_user_with_node "cat > '$APP_DIR/.env' <<EOF
CHAT_PORT=$CHAT_PORT
INFO_PORT=$INFO_PORT
ONION_LINK=$ENV_ONION
ADMIN_KEYS=$ADMIN_KEYS
EOF"
  } >>"$LOG_FILE" 2>&1
  if [ $? -eq 0 ]; then
    STATUS[6]="${C_GREEN}SUCCESS${C_RESET}"
    ok ".env created and dependencies installed"
  else
    STATUS[6]="${C_RED}FAILED${C_RESET}"
    err "Application configuration failed"
  fi
fi

# -----------------------------------------------------------------------------
# Step 7: Start Application (PM2 + Autostart)
# -----------------------------------------------------------------------------
print_step_header 7
if [[ "${STATUS[3]}" == *"FAILED"* ]]; then
  STATUS[7]="${C_DIM}SKIPPED (No Node)${C_RESET}"
  warn "Skipping PM2 start (Node not available)"
else
  {
    run_as_user_with_node "command -v pm2 >/dev/null || npm i -g pm2"

    # Detect entrypoint: prefer npm start, else server.js/app.js/index.js
    HAS_NPM_START=$(run_as_user_with_node "cd '$APP_DIR' && [ -f package.json ] && grep -q '\"start\"[[:space:]]*:' package.json && echo yes || echo no")
    if [ "$HAS_NPM_START" = "yes" ]; then
      run_as_user_with_node "cd '$APP_DIR' && (pm2 reload simple-chat || pm2 start npm --name simple-chat -- start)"
    else
      ENTRY=""
      run_as_user_with_node "[ -f '$APP_DIR/server.js' ]" && ENTRY="server.js" || true
      if [ -z "$ENTRY" ]; then run_as_user_with_node "[ -f '$APP_DIR/app.js' ]"   && ENTRY="app.js"   || true; fi
      if [ -z "$ENTRY" ]; then run_as_user_with_node "[ -f '$APP_DIR/index.js' ]" && ENTRY="index.js" || true; fi
      if [ -n "$ENTRY" ]; then
        run_as_user_with_node "cd '$APP_DIR' && (pm2 reload simple-chat || pm2 start '$ENTRY' --name simple-chat)"
      else
        echo "No entrypoint found (npm start / server.js / app.js / index.js)" >&2
        exit 1
      fi
    fi

    run_as_user_with_node "pm2 save"

    # PM2 autostart (systemd)
    STARTUP_CMD=$(run_as_user_with_node "pm2 startup systemd -u '$RUN_AS_USER' --hp '$USER_HOME'" | tail -n 1)
    if echo "$STARTUP_CMD" | grep -q "sudo"; then
      eval "$STARTUP_CMD" >>"$LOG_FILE" 2>&1 || true
    else
      sudo env PATH=$PATH pm2 startup systemd -u "$RUN_AS_USER" --hp "$USER_HOME" >>"$LOG_FILE" 2>&1 || true
    fi

    # Optional healthcheck
    if command -v curl >/dev/null 2>&1; then
      curl -fsS "http://127.0.0.1:$INFO_PORT/health" >/dev/null 2>&1 \
        && echo "Healthcheck OK" >>"$LOG_FILE" \
        || echo "Healthcheck missing/failed (ignored)" >>"$LOG_FILE"
    fi
  } >>"$LOG_FILE" 2>&1
  if [ $? -eq 0 ]; then
    STATUS[7]="${C_GREEN}SUCCESS${C_RESET}"
    ok "PM2 process configured"
  else
    STATUS[7]="${C_RED}FAILED${C_RESET}"
    err "PM2 start failed"
  fi
fi

# -----------------------------------------------------------------------------
# Step 8: Configure Nginx (optional)
# -----------------------------------------------------------------------------
print_step_header 8
if [ -n "$DOMAIN" ]; then
  {
    NGINX_PATH="/etc/nginx/sites-available/$DOMAIN"
    backup_file "$NGINX_PATH"

    sudo tee "$NGINX_PATH" >/dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    # ACME challenge pre-SSL
    location /.well-known/acme-challenge/ { root /var/www/html; allow all; }

    # Main app (INFO_PORT)
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

    # Optional: expose chat on /chat
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
  } >>"$LOG_FILE" 2>&1
  if [ $? -eq 0 ]; then
    STATUS[8]="${C_GREEN}SUCCESS${C_RESET}"
    ok "Nginx vhost configured for $DOMAIN"
  else
    STATUS[8]="${C_RED}FAILED${C_RESET}"
    err "Nginx configuration failed"
  fi
else
  STATUS[8]="${C_DIM}SKIPPED (No domain)${C_RESET}"
  warn "No domain provided — skipping Nginx"
fi

# -----------------------------------------------------------------------------
# Step 9: Configure Firewall (UFW)
# -----------------------------------------------------------------------------
print_step_header 9
{
  sudo ufw allow 'OpenSSH' || sudo ufw allow 22/tcp
  if [ -n "$DOMAIN" ]; then
    sudo ufw allow 'Nginx Full' || { sudo ufw allow 80/tcp; sudo ufw allow 443/tcp; }
  else
    sudo ufw allow 80/tcp || true
  fi
  sudo ufw --force enable
} >>"$LOG_FILE" 2>&1
if [ $? -eq 0 ]; then
  STATUS[9]="${C_GREEN}SUCCESS${C_RESET}"
  ok "UFW rules applied"
else
  STATUS[9]="${C_RED}FAILED${C_RESET}"
  err "UFW configuration failed"
fi

# -----------------------------------------------------------------------------
# Step 10: Configure SSL (Certbot, optional)
# -----------------------------------------------------------------------------
print_step_header 10
if [ -n "$DOMAIN" ]; then
  {
    if ! command -v certbot >/dev/null 2>&1; then
      sudo apt-get install -y certbot python3-certbot-nginx
    fi
    if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
      sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN" --redirect
      CB_STATE="new cert created"
    else
      CB_STATE="cert exists"
    fi
  } >>"$LOG_FILE" 2>&1
  if [ $? -eq 0 ]; then
    STATUS[10]="${C_GREEN}SUCCESS${C_RESET} (${CB_STATE})"
    ok "TLS configured: $CB_STATE"
  else
    STATUS[10]="${C_RED}FAILED${C_RESET}"
    err "Certbot/SSL configuration failed"
  fi
else
  STATUS[10]="${C_DIM}SKIPPED (No domain)${C_RESET}"
  warn "No domain provided — skipping SSL"
fi

###############################################################################
# FINAL SUMMARY
###############################################################################
echo
head1 "Installation Summary ${FX_SPARKLES}"
FAILED_ANY=0
for i in $(seq 1 10); do
  printf "%-6s %-36s -> %b\n" "Step $i:" "${STEPS[$i]}" "${STATUS[$i]}"
  [[ "${STATUS[$i]}" == *"FAILED"* ]] && FAILED_ANY=1
done
echo "----------------------------------------"

# PM2 status (robust ASCII parsing)
APP_STATUS=$(run_as_user_with_node \
  "pm2 show simple-chat 2>/dev/null | awk -F: '/status/ { sub(/^[ \t]+/,\"\",\$2); sub(/[ \t]+$/,\"\",\$2); print \$2; exit }'" \
  || echo "")
[ -z "$APP_STATUS" ] && APP_STATUS="NOT RUNNING"
if [[ "$APP_STATUS" =~ ^[Oo]nline$ ]]; then
  ok "Application Status: $APP_STATUS"
else
  err "Application Status: $APP_STATUS"
fi

# Onion / Domain URLs
if [ -n "${ONION_HOST:-}" ]; then
  blink "Onion URL : http://$ONION_HOST"
else
  warn "Onion URL : unavailable (Tor hostname not generated)"
fi
[ -n "$DOMAIN" ] && echo "Domain URL: https://$DOMAIN"
echo "Log file  : $LOG_FILE"
echo "========================================"

# Tail install log if any failures
if [[ $FAILED_ANY -eq 1 ]]; then
  echo
  head2 "Tail of install log (last 120 lines)"
  tail -n 120 "$LOG_FILE" || true
  tail_errors
fi

# Show PM2 logs if app not online
if [[ ! "$APP_STATUS" =~ ^[Oo]nline$ ]]; then
  echo
  head2 "PM2 logs (last 100 lines)"
  run_as_user_with_node "pm2 logs simple-chat --lines 100 --nostream" || true
fi

# Exit code
if [[ $FAILED_ANY -eq 1 || ! "$APP_STATUS" =~ ^[Oo]nline$ ]]; then
  exit 1
else
  ok "All set. ${FX_ROCKET}"
  exit 0
fi
