#!/bin/bash
# simple-tor-chat installer — robust & idempotent, full 10 steps, colored DX

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
# COLOR DX
###############################################################################
if [[ -t 1 && -z "$NO_COLOR" ]]; then
  C_RESET="\e[0m"; C_DIM="\e[2m"
  C_RED="\e[31m"; C_GREEN="\e[32m"; C_YELLOW="\e[33m"; C_BLUE="\e[34m"
  C_MAGENTA="\e[35m"; C_CYAN="\e[36m"; C_BOLD="\e[1m"
  SYM_OK="✔"; SYM_ERR="✖"; SYM_WARN="⚠"
else
  C_RESET=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
  C_MAGENTA=""; C_CYAN=""; C_BOLD=""
  SYM_OK="[OK]"; SYM_ERR="[ERR]"; SYM_WARN="[!]"
fi
say()   { printf "%b%s%b\n" "$1" "$2" "$C_RESET"; }
ok()    { say "$C_GREEN"   "$SYM_OK $1"; }
err()   { say "$C_RED"     "$SYM_ERR $1"; }
warn()  { say "$C_YELLOW"  "$SYM_WARN $1"; }
info()  { say "$C_CYAN"    "$1"; }
head1() { printf "%b\n"    "${C_BOLD}${C_BLUE}== $1 ==${C_RESET}"; }
head2() { printf "%b\n"    "${C_BOLD}${C_MAGENTA}# $1${C_RESET}"; }

###############################################################################
# STATUS tracking
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
  local f="$1"
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  [ -f "$f" ] && sudo cp -a "$f" "$f.bak.$ts"
}

run_as_user_with_nvm() {
  # Run command as app user with NVM loaded from $USER_HOME (never /root)
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

print_step_header() {
  local n="$1"
  head2 "Step $n: ${STEPS[$n]}"
}

###############################################################################
# ARGS
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
head1 "simple-tor-chat installer"
: > "$LOG_FILE"
info "Log file: $LOG_FILE"
info "Run as user: $RUN_AS_USER  (home: $USER_HOME)"
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
  err "System update failed (see $LOG_FILE)"
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
# Step 3: Install Node.js (NVM) for $RUN_AS_USER
# -----------------------------------------------------------------------------
print_step_header 3
{
  if [ ! -d "$NVM_DIR" ]; then
    ok "Installing NVM to $NVM_DIR"
    sudo -u "$RUN_AS_USER" -i bash -lc "export NVM_DIR=\"$NVM_DIR\"; mkdir -p \"\$NVM_DIR\"; curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash"
  else
    info "NVM already present: $NVM_DIR"
  fi
  run_as_user_with_nvm "nvm install --lts && nvm alias default 'lts/*' && nvm use default"
  run_as_user_with_nvm "node -v && npm -v"
} >>"$LOG_FILE" 2>&1
if [ $? -eq 0 ]; then
  STATUS[3]="${C_GREEN}SUCCESS${C_RESET}"
  ok "Node LTS ready"
else
  STATUS[3]="${C_RED}FAILED${C_RESET}"
  err "NVM/Node installation failed"
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
    echo "[torrc] appended simple-tor-chat block" >>"$LOG_FILE"
  else
    echo "[torrc] block already present" >>"$LOG_FILE"
  fi

  sudo systemctl restart tor

  HOSTNAME_FILE="/var/lib/tor/hidden_service/hostname"
  echo "Waiting for $HOSTNAME_FILE ..." >>"$LOG_FILE"
  for i in $(seq 1 120); do
    if sudo test -f "$HOSTNAME_FILE"; then
      ONION_HOST=$(sudo cat "$HOSTNAME_FILE")
      break
    fi
    sleep 1
  done
} >>"$LOG_FILE" 2>&1
if [ -n "${ONION_HOST:-}" ]; then
  STATUS[4]="${C_GREEN}SUCCESS${C_RESET}"
  ok "Tor onion address: http://$ONION_HOST"
else
  STATUS[4]="${C_RED}FAILED (Timeout)${C_RESET}"
  err "Tor hostname not generated (timeout)"
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
# Step 6: Configure Application (Node version, deps, .env)
# -----------------------------------------------------------------------------
print_step_header 6
{
  # Respect .nvmrc if present
  if run_as_user_with_nvm "test -f '$APP_DIR/.nvmrc'"; then
    run_as_user_with_nvm "cd '$APP_DIR' && nvm install && nvm use"
  else
    run_as_user_with_nvm "nvm use default"
  fi

  # Install deps (prefer npm ci)
  if run_as_user_with_nvm "test -f '$APP_DIR/package-lock.json'"; then
    run_as_user_with_nvm "cd '$APP_DIR' && npm ci"
  else
    echo "package-lock.json not found – using npm install" >>"$LOG_FILE"
    run_as_user_with_nvm "cd '$APP_DIR' && npm install"
  fi

  # Prepare ONION_LINK value (can be empty if Step 4 failed)
  ENV_ONION=""
  if [ -n "${ONION_HOST:-}" ]; then
    ENV_ONION="http://$ONION_HOST"
  fi

  # Write .env (interpolated values)
  run_as_user_with_nvm "cd '$APP_DIR' && cat > .env <<EOF
CHAT_PORT=$CHAT_PORT
INFO_PORT=$INFO_PORT
ONION_LINK=$ENV_ONION
ADMIN_KEYS=$ADMIN_KEYS
EOF
"
} >>"$LOG_FILE" 2>&1
if [ $? -eq 0 ]; then
  STATUS[6]="${C_GREEN}SUCCESS${C_RESET}"
  ok ".env created and dependencies installed"
else
  STATUS[6]="${C_RED}FAILED${C_RESET}"
  err "Application configuration failed"
fi

# -----------------------------------------------------------------------------
# Step 7: Start Application (PM2 + Autostart)
# -----------------------------------------------------------------------------
print_step_header 7
{
  run_as_user_with_nvm "command -v pm2 >/dev/null || npm i -g pm2"

  # Detect entrypoint: prefer npm start, else server.js/app.js/index.js
  HAS_NPM_START=$(run_as_user_with_nvm "cd '$APP_DIR' && [ -f package.json ] && grep -q '\"start\"[[:space:]]*:' package.json && echo yes || echo no")
  if [ "$HAS_NPM_START" = "yes" ]; then
    run_as_user_with_nvm "cd '$APP_DIR' && (pm2 reload simple-chat || pm2 start npm --name simple-chat -- start)"
  else
    ENTRY=""
    run_as_user_with_nvm "[ -f '$APP_DIR/server.js' ]" && ENTRY="server.js" || true
    if [ -z "$ENTRY" ]; then run_as_user_with_nvm "[ -f '$APP_DIR/app.js' ]"   && ENTRY="app.js"   || true; fi
    if [ -z "$ENTRY" ]; then run_as_user_with_nvm "[ -f '$APP_DIR/index.js' ]" && ENTRY="index.js" || true; fi
    if [ -n "$ENTRY" ]; then
      run_as_user_with_nvm "cd '$APP_DIR' && (pm2 reload simple-chat || pm2 start '$ENTRY' --name simple-chat)"
    else
      echo "No entrypoint found (npm start / server.js / app.js / index.js)" >&2
      exit 1
    fi
  fi

  run_as_user_with_nvm "pm2 save"

  # PM2 autostart (systemd)
  STARTUP_CMD=$(run_as_user_with_nvm "pm2 startup systemd -u '$RUN_AS_USER' --hp '$USER_HOME'" | tail -n 1)
  if echo "$STARTUP_CMD" | grep -q "sudo"; then
    eval "$STARTUP_CMD" >>"$LOG_FILE" 2>&1 || true
  else
    sudo env PATH=$PATH pm2 startup systemd -u "$RUN_AS_USER" --hp "$USER_HOME" >>"$LOG_FILE" 2>&1 || true
  fi

  # Optional healthcheck (non-blocking)
  if command -v curl >/dev/null 2>&1; then
    curl -fsS "http://127.0.0.1:$INFO_PORT/health" >/dev/null 2>&1 && echo "Healthcheck OK" >>"$LOG_FILE" || echo "Healthcheck missing/failed (ignored)" >>"$LOG_FILE"
  fi
} >>"$LOG_FILE" 2>&1
if [ $? -eq 0 ]; then
  STATUS[7]="${C_GREEN}SUCCESS${C_RESET}"
  ok "PM2 process configured"
else
  STATUS[7]="${C_RED}FAILED${C_RESET}"
  err "PM2 start failed"
fi

# -----------------------------------------------------------------------------
# Step 8: Configure Nginx (if DOMAIN)
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

    # Allow ACME challenge pre-SSL
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
# Step 10: Configure SSL (Certbot) if DOMAIN
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
head1 "Installation Summary"
FAILED_ANY=0
for i in $(seq 1 10); do
  step_name="${STEPS[$i]}"
  step_status="${STATUS[$i]}"
  printf "%-6s %-32s -> %b\n" "Step $i:" "$step_name" "$step_status"
  [[ "$step_status" == *"FAILED"* ]] && FAILED_ANY=1
done
echo "----------------------------------------"

# PM2 status (robust ASCII parsing)
APP_STATUS=$(run_as_user_with_nvm \
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
  echo "Onion URL : http://$ONION_HOST"
else
  warn "Onion URL : unavailable (Tor hostname not generated)"
fi
if [ -n "$DOMAIN" ]; then
  echo "Domain URL: https://$DOMAIN"
fi
echo "Log file  : $LOG_FILE"
echo "========================================"

# Tail install log if any failures
if [[ $FAILED_ANY -eq 1 ]]; then
  echo
  head2 "Tail of install log (last 120 lines)"
  tail -n 120 "$LOG_FILE" || true
fi

# Show PM2 logs if app not online
if [[ ! "$APP_STATUS" =~ ^[Oo]nline$ ]]; then
  echo
  head2 "PM2 logs (last 80 lines)"
  run_as_user_with_nvm "pm2 logs simple-chat --lines 80 --nostream" || true
fi
