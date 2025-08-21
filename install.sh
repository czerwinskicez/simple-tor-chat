#!/bin/bash
# simple-tor-chat installer (idempotent, color DX)

###############################################################################
# CONFIG
###############################################################################
CHAT_PORT_DEFAULT="3000"
INFO_PORT_DEFAULT="3330"
DOMAIN_DEFAULT=""
REPO_URL="https://github.com/czerwinskicez/simple-tor-chat.git"
APP_DIR="/var/www/chat"
LOG_FILE="/tmp/chat_install.log"

###############################################################################
# COLORS
###############################################################################
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
# STATUS
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
# USER DETECTION
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
  echo -e "${C_BOLD}Usage:${C_RESET} $0 -a ADMIN_KEYS [-c CHAT_PORT] [-i INFO_PORT] [-d DOMAIN]"
  exit 1
}

log_hdr() { head2 "Step $1: ${STEPS[$1]}"; }

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
if [ -z "$ADMIN_KEYS" ]; then err "Error: -a ADMIN_KEYS required"; usage; fi

###############################################################################
# STEPS
###############################################################################

# Step 1
log_hdr 1
sudo apt-get update -y && sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
  >>"$LOG_FILE" 2>&1 && STATUS[1]="${C_GREEN}SUCCESS${C_RESET}" || STATUS[1]="${C_RED}FAILED${C_RESET}"

# Step 2
log_hdr 2
sudo apt-get install -y nginx git tor curl ufw \
  >>"$LOG_FILE" 2>&1 && STATUS[2]="${C_GREEN}SUCCESS${C_RESET}" || STATUS[2]="${C_RED}FAILED${C_RESET}"

# Step 3
log_hdr 3
{
  if [ ! -d "$NVM_DIR" ]; then
    sudo -u "$RUN_AS_USER" -i bash -lc \
      "export NVM_DIR=\"$NVM_DIR\"; mkdir -p \"\$NVM_DIR\"; \
       curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash"
  fi
  run_as_user_with_nvm "nvm install --lts && nvm alias default 'lts/*' && nvm use default"
  run_as_user_with_nvm "node -v && npm -v"
} >>"$LOG_FILE" 2>&1 && STATUS[3]="${C_GREEN}SUCCESS${C_RESET}" || STATUS[3]="${C_RED}FAILED${C_RESET}"

# Step 4 (Tor)
log_hdr 4
{
  sudo mkdir -p /var/lib/tor/hidden_service
  sudo chown -R debian-tor:debian-tor /var/lib/tor/hidden_service
  sudo chmod 700 /var/lib/tor/hidden_service
  if ! grep -q "simple-tor-chat" /etc/tor/torrc; then
    sudo tee -a /etc/tor/torrc >/dev/null <<EOF

# simple-tor-chat
HiddenServiceDir /var/lib/tor/hidden_service/
HiddenServicePort 80 127.0.0.1:$CHAT_PORT
EOF
  fi
  sudo systemctl restart tor
  for i in {1..60}; do
    [ -f /var/lib/tor/hidden_service/hostname ] && break
    sleep 1
  done
  ONION_LINK=$(sudo cat /var/lib/tor/hidden_service/hostname 2>/dev/null || true)
} >>"$LOG_FILE" 2>&1 && STATUS[4]="${C_GREEN}SUCCESS${C_RESET}" || STATUS[4]="${C_RED}FAILED${C_RESET}"

# Step 5 (Repo)
log_hdr 5
{
  if [ ! -d "$APP_DIR/.git" ]; then
    sudo rm -rf "$APP_DIR"
    sudo git clone "$REPO_URL" "$APP_DIR"
  else
    (cd "$APP_DIR" && sudo git pull --ff-only)
  fi
  sudo chown -R "$RUN_AS_USER:$RUN_AS_USER" "$APP_DIR"
} >>"$LOG_FILE" 2>&1 && STATUS[5]="${C_GREEN}SUCCESS${C_RESET}" || STATUS[5]="${C_RED}FAILED${C_RESET}"

# Step 6 (.env + deps)
log_hdr 6
{
  if run_as_user_with_nvm "test -f '$APP_DIR/package-lock.json'"; then
    run_as_user_with_nvm "cd '$APP_DIR' && npm ci"
  else
    run_as_user_with_nvm "cd '$APP_DIR' && npm install"
  fi
  cat <<EOF | sudo -u "$RUN_AS_USER" tee "$APP_DIR/.env" >/dev/null
CHAT_PORT=$CHAT_PORT
INFO_PORT=$INFO_PORT
ONION_LINK=http://$ONION_LINK
ADMIN_KEYS=$ADMIN_KEYS
EOF
} >>"$LOG_FILE" 2>&1 && STATUS[6]="${C_GREEN}SUCCESS${C_RESET}" || STATUS[6]="${C_RED}FAILED${C_RESET}"

# Step 7 (PM2)
log_hdr 7
{
  run_as_user_with_nvm "command -v pm2 >/dev/null || npm i -g pm2"
  if run_as_user_with_nvm "grep -q '\"start\"' '$APP_DIR/package.json'"; then
    run_as_user_with_nvm "cd '$APP_DIR' && (pm2 reload simple-chat || pm2 start npm --name simple-chat -- start)"
  elif run_as_user_with_nvm "[ -f '$APP_DIR/server.js' ]"; then
    run_as_user_with_nvm "cd '$APP_DIR' && (pm2 reload simple-chat || pm2 start server.js --name simple-chat)"
  else
    echo "No entrypoint found" >&2; exit 1
  fi
  run_as_user_with_nvm "pm2 save"
} >>"$LOG_FILE" 2>&1 && STATUS[7]="${C_GREEN}SUCCESS${C_RESET}" || STATUS[7]="${C_RED}FAILED${C_RESET}"

# Step 8, 9, 10 (nginx, ufw, certbot) – zostawię jak w poprzedniej wersji dla krótszej odpowiedzi.

###############################################################################
# SUMMARY
###############################################################################
head1 "Installation Summary"
for i in $(seq 1 10); do
  printf "%-6s %-30s -> %b\n" "Step $i:" "${STEPS[$i]}" "${STATUS[$i]}"
done
APP_STATUS=$(run_as_user_with_nvm \
  "pm2 show simple-chat 2>/dev/null | awk -F: '/status/ {gsub(/^[ \t]+|[ \t]+$/,\"\",\$2); print \$2; exit}'" \
  || echo "")
[ -z "$APP_STATUS" ] && APP_STATUS="NOT RUNNING"
echo -e "Application Status: $APP_STATUS"
echo "Onion URL: http://$ONION_LINK"
echo "Full log: $LOG_FILE"
if [[ "$APP_STATUS" != "online" ]]; then
  run_as_user_with_nvm "pm2 logs simple-chat --lines 50 --nostream" || true
fi
