#!/bin/bash

# --- Configuration ---
CHAT_PORT_DEFAULT="3000"
INFO_PORT_DEFAULT="3330"
DOMAIN_DEFAULT=""
REPO_URL="https://github.com/czerwinskicez/simple-tor-chat.git"
APP_DIR="/var/www/chat"
LOG_FILE="/tmp/chat_install.log"

# --- Status Tracking ---
declare -A STEPS
STEPS=(
    ["1"]="System Update"
    ["2"]="Install Dependencies"
    ["3"]="Install Node.js"
    ["4"]="Configure Tor"
    ["5"]="Clone Repository"
    ["6"]="Configure Application"
    ["7"]="Start Application (PM2)"
    ["8"]="Configure Nginx"
    ["9"]="Configure Firewall"
    ["10"]="Configure SSL"
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

# --- Functions ---
usage() {
    echo "Usage: $0 -a ADMIN_KEYS [-c CHAT_PORT] [-i INFO_PORT] [-d DOMAIN]"
    echo "  -a ADMIN_KEYS: Comma-separated admin keys (MANDATORY)"
    echo "  -c CHAT_PORT: Chat port (default: $CHAT_PORT_DEFAULT)"
    echo "  -i INFO_PORT: Info port (default: $INFO_PORT_DEFAULT)"
    echo "  -d DOMAIN: Domain for Nginx and Certbot (optional)"
    exit 1
}

run_as_user_with_nvm() {
    sudo -u "$RUN_AS_USER" -i -- bash -c ". \"$HOME/.nvm/nvm.sh\" && $1"
}

run_step() {
    local step_num=$1
    local cmd=$2
    echo "### Step $step_num: ${STEPS[$step_num]}..."
    # Execute command, redirecting stdout/stderr to log file
    if eval "$cmd" >> "$LOG_FILE" 2>&1; then
        STATUS[$step_num]="SUCCESS"
    else
        STATUS[$step_num]="FAILED"
    fi
    echo "--- Status: ${STATUS[$step_num]}"
}

# --- Initial Setup ---
echo "Starting installation. Details will be logged to $LOG_FILE"
> "$LOG_FILE" # Clear log file
echo "Running script as user: $RUN_AS_USER" | tee -a "$LOG_FILE"
echo "User home directory: $USER_HOME" | tee -a "$LOG_FILE"

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
    echo "Error: -a ADMIN_KEYS is a mandatory argument."
    usage
fi

# --- Script ---

# Step 1: System Update
run_step 1 "sudo apt update && sudo apt upgrade -y"

# Step 2: Install Nginx, Git and Tor
run_step 2 "sudo apt install -y nginx git tor"

# Step 3: Install Node.js (via NVM)
CMD="if [ ! -d \"$USER_HOME/.nvm\" ]; then sudo -u \"$RUN_AS_USER\" -i -- bash -c \"curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash\"; fi && run_as_user_with_nvm \"nvm install --lts\""
run_step 3 "$CMD"

# Step 4: Configure Tor
echo "### Step 4: ${STEPS[4]}..."
{
    sudo tee /etc/tor/torrc > /dev/null <<EOF
HiddenServiceDir /var/lib/tor/hidden_service/
HiddenServicePort 80 127.0.0.1:$CHAT_PORT
EOF
    sudo systemctl restart tor

    echo "Waiting for Tor hostname file..."
    ATTEMPTS=0
    MAX_ATTEMPTS=30
    HOSTNAME_FILE="/var/lib/tor/hidden_service/hostname"
    while [ ! -f "$HOSTNAME_FILE" ]; do
        if [ $ATTEMPTS -ge $MAX_ATTEMPTS ]; then
            echo "Error: Timed out waiting for Tor hostname file."
            STATUS[4]="FAILED (Timeout)"
            break
        fi
        sleep 1
        ATTEMPTS=$((ATTEMPTS+1))
    done

    if [ "${STATUS[4]}" != "FAILED (Timeout)" ]; then
        ONION_LINK=$(sudo cat "$HOSTNAME_FILE")
        echo "Tor Onion Service Address: http://$ONION_LINK"
        STATUS[4]="SUCCESS"
    fi
} >> "$LOG_FILE" 2>&1
echo "--- Status: ${STATUS[4]}"


# Step 5: Clone repository
CMD="if [ ! -d \"$APP_DIR\" ]; then sudo git clone \"$REPO_URL\" \"$APP_DIR\"; else cd \"$APP_DIR\" && sudo git pull; fi && sudo chown -R \"$RUN_AS_USER:$RUN_AS_USER\" \"$APP_DIR\""
run_step 5 "$CMD"

# Step 6: Configure application
echo "### Step 6: ${STEPS[6]}..."
{
    run_as_user_with_nvm "cd \"$APP_DIR\" && npm ci"
    
    ENV_CONTENT="CHAT_PORT=$CHAT_PORT
INFO_PORT=$INFO_PORT
ONION_LINK=http://$ONION_LINK
ADMIN_KEYS=$ADMIN_KEYS"

    # Use run_as_user_with_nvm to ensure correct ownership of .env
    run_as_user_with_nvm "cd \"$APP_DIR\" && echo \"$ENV_CONTENT\" > .env"
    
    # Check exit code of the last command
    if [ $? -eq 0 ]; then
        STATUS[6]="SUCCESS"
    else
        STATUS[6]="FAILED"
    fi
} >> "$LOG_FILE" 2>&1
echo "--- Status: ${STATUS[6]}"

# Step 7: Start application with PM2
CMD="run_as_user_with_nvm \"npm install pm2 -g && cd \\\"$APP_DIR\\\" && (pm2 reload simple-chat || pm2 start server.js --name simple-chat)\" && run_as_user_with_nvm \"pm2 save\""
run_step 7 "$CMD"

# Step 8: Configure Nginx
if [ -n "$DOMAIN" ]; then
    NGINX_CONFIG="server {
    listen 80;
    server_name $DOMAIN;
    location / {
        proxy_pass http://127.0.0.1:$INFO_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \\\\$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \\\\$host;
        proxy_cache_bypass \\\\$http_upgrade;
    }
}"
    CMD="echo \"$NGINX_CONFIG\" | sudo tee /etc/nginx/sites-available/\"$DOMAIN\" > /dev/null && sudo ln -sf /etc/nginx/sites-available/\"$DOMAIN\" /etc/nginx/sites-enabled/ && sudo nginx -t && sudo systemctl restart nginx"
    run_step 8 "$CMD"
else
    STATUS[8]="SKIPPED (No domain provided)"
fi

# Step 9: Configure Firewall (UFW)
echo "### Step 9: ${STEPS[9]}..."
{
    sudo ufw allow 'Nginx Full'
    if ! sudo ufw allow 'OpenSSH'; then
        echo "UFW profile 'OpenSSH' not found. Allowing port 22/tcp as a fallback."
        sudo ufw allow 22/tcp
    fi
    sudo ufw --force enable
    if [ $? -eq 0 ]; then
        STATUS[9]="SUCCESS"
    else
        STATUS[9]="FAILED"
    fi
} >> "$LOG_FILE" 2>&1
echo "--- Status: ${STATUS[9]}"

# Step 10: Configure SSL with Certbot
if [ -n "$DOMAIN" ]; then
    CMD="sudo apt install -y certbot python3-certbot-nginx && sudo certbot --nginx -d \"$DOMAIN\" --non-interactive --agree-tos -m \"admin@$DOMAIN\""
    run_step 10 "$CMD"
else
    STATUS[10]="SKIPPED (No domain provided)"
fi

# --- Final Summary ---
echo
echo "========================================"
echo " Installation Summary"
echo "========================================"
for i in $(seq 1 10); do
    printf "Step %-2s: %-25s -> %s\n" "$i" "${STEPS[$i]}" "${STATUS[$i]}"
done
echo "----------------------------------------"

APP_STATUS_RAW=$(run_as_user_with_nvm "pm2 describe simple-chat 2>/dev/null | grep 'status' | head -n 1" || echo "status: not_found")
APP_STATUS=$(echo "$APP_STATUS_RAW" | awk -F'│' '{print $4}' | tr -d '[:space:]')

if [[ -z "$APP_STATUS" || "$APP_STATUS" == "not_found" ]]; then
    echo "Application Status: NOT RUNNING"
else
    echo "Application Status: $APP_STATUS"
fi

echo "Onion URL: http://$ONION_LINK"
if [ -n "$DOMAIN" ]; then
    echo "Domain URL: https://$DOMAIN"
fi
echo "========================================"
echo "Installation log is available at: $LOG_FILE"
