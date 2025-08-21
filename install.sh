#!/bin/bash

# --- Configuration ---
CHAT_PORT_DEFAULT="3000"
INFO_PORT_DEFAULT="3330"
DOMAIN_DEFAULT=""
REPO_URL="https://github.com/czerwinskicez/simple-tor-chat.git"
APP_DIR="/var/www/chat"
LOG_FILE="/tmp/chat_install.log"

# --- Colors ---
BLUE='\033[1;34m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m' # No Color

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
    echo -e "${RED}Error: -a ADMIN_KEYS is a mandatory argument.${NC}"
    usage
fi

# --- Script ---

# Step 1: System Update
echo -e "\n${BLUE}### Step 1: ${STEPS[1]}...${NC}"
{
    sudo apt-get update && sudo apt-get upgrade -y
} 2>&1 | tee -a "$LOG_FILE"
if [ ${PIPESTATUS[0]} -eq 0 ]; then
    STATUS[1]="${GREEN}SUCCESS${NC}"
else
    LAST_ERROR=$(tail -n 5 "$LOG_FILE")
    STATUS[1]="${RED}FAILED${NC}\n--- Last error ---\n$LAST_ERROR\n------------------"
fi
echo -e "--- Status: ${STATUS[1]}"

# Step 2: Install Nginx, Git and Tor
echo -e "\n${BLUE}### Step 2: ${STEPS[2]}...${NC}"
{
    sudo apt-get install -y nginx git tor
} 2>&1 | tee -a "$LOG_FILE"
if [ ${PIPESTATUS[0]} -eq 0 ]; then
    STATUS[2]="${GREEN}SUCCESS${NC}"
else
    LAST_ERROR=$(tail -n 5 "$LOG_FILE")
    STATUS[2]="${RED}FAILED${NC}\n--- Last error ---\n$LAST_ERROR\n------------------"
fi
echo -e "--- Status: ${STATUS[2]}"

# Step 3: Install Node.js (via NVM)
echo -e "\n${BLUE}### Step 3: ${STEPS[3]}...${NC}"
{
    STEP_3_DETAIL=""
    if [ ! -d "$USER_HOME/.nvm" ]; then
        echo "NVM not found, installing..."
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
        STEP_3_DETAIL="NVM installed"
    else
        echo "NVM already exists."
        STEP_3_DETAIL="NVM exists"
    fi
    export NVM_DIR="$USER_HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    if ! nvm list | grep -q 'lts'; then
        echo "Node.js LTS not found, installing..."
        nvm install --lts
        STEP_3_DETAIL+=", Node LTS installed"
    else
        echo "Node.js LTS already exists."
        STEP_3_DETAIL+=", Node LTS exists"
    fi
} 2>&1 | tee -a "$LOG_FILE" | sudo -u "$RUN_AS_USER" -i -- bash
if [ ${PIPESTATUS[1]} -eq 0 ]; then
    STATUS[3]="${GREEN}SUCCESS ($STEP_3_DETAIL)${NC}"
else
    LAST_ERROR=$(tail -n 5 "$LOG_FILE")
    STATUS[3]="${RED}FAILED${NC}\n--- Last error ---\n$LAST_ERROR\n------------------"
fi
echo -e "--- Status: ${STATUS[3]}"

# Step 4: Configure Tor
echo -e "\n${BLUE}### Step 4: ${STEPS[4]}...${NC}"
{
    sudo tee /etc/tor/torrc > /dev/null <<EOF
HiddenServiceDir /var/lib/tor/hidden_service/
HiddenServicePort 80 127.0.0.1:$CHAT_PORT
EOF
    sudo systemctl restart tor
    echo "Waiting for Tor hostname file..."
    ATTEMPTS=0; MAX_ATTEMPTS=30; HOSTNAME_FILE="/var/lib/tor/hidden_service/hostname"
    while [ ! -f "$HOSTNAME_FILE" ]; do
        if [ $ATTEMPTS -ge $MAX_ATTEMPTS ]; then echo "Timed out"; exit 1; fi
        sleep 1; ATTEMPTS=$((ATTEMPTS+1))
    done
    ONION_LINK=$(sudo cat "$HOSTNAME_FILE")
} 2>&1 | tee -a "$LOG_FILE"
if [ ${PIPESTATUS[0]} -eq 0 ]; then
    STATUS[4]="${GREEN}SUCCESS${NC}"
else
    LAST_ERROR=$(tail -n 5 "$LOG_FILE")
    STATUS[4]="${RED}FAILED${NC}\n--- Last error ---\n$LAST_ERROR\n------------------"
fi
echo -e "--- Status: ${STATUS[4]}"

# Step 5: Clone repository
echo -e "\n${BLUE}### Step 5: ${STEPS[5]}...${NC}"
{
    STEP_5_DETAIL=""
    if [ ! -d "$APP_DIR" ]; then
        sudo git clone "$REPO_URL" "$APP_DIR"; STEP_5_DETAIL="Cloned"
    else
        cd "$APP_DIR"; sudo git pull; STEP_5_DETAIL="Pulled"
    fi
    sudo chown -R "$RUN_AS_USER:$RUN_AS_USER" "$APP_DIR"
} 2>&1 | tee -a "$LOG_FILE"
if [ ${PIPESTATUS[0]} -eq 0 ]; then
    STATUS[5]="${GREEN}SUCCESS ($STEP_5_DETAIL)${NC}"
else
    LAST_ERROR=$(tail -n 5 "$LOG_FILE")
    STATUS[5]="${RED}FAILED${NC}\n--- Last error ---\n$LAST_ERROR\n------------------"
fi
echo -e "--- Status: ${STATUS[5]}"

# Step 6: Configure application
echo -e "\n${BLUE}### Step 6: ${STEPS[6]}...${NC}"
{
    # --- NPM Install Logic with Retry ---
    echo "Running 'npm install'. This may take a moment..."
    MAX_RETRIES=3
    RETRY_COUNT=1
    NPM_SUCCESS=false
    until [ "$NPM_SUCCESS" = true ]; do
        if run_as_user_with_nvm "cd \"$APP_DIR\" && npm install"; then
            NPM_SUCCESS=true
        else
            RETRY_COUNT=$((RETRY_COUNT+1))
            if [ $RETRY_COUNT -gt $MAX_RETRIES ]; then
                echo "NPM command failed after $MAX_RETRIES attempts."
                exit 1 # Critical error, exit the subshell with failure
            fi
            echo "NPM command failed. Retrying in 5 seconds... ($((RETRY_COUNT-1))/$MAX_RETRIES)"
            sleep 5
        fi
    done

    # --- .env file creation ---
    ENV_CONTENT="CHAT_PORT=$CHAT_PORT\nINFO_PORT=$INFO_PORT\nONION_LINK=http://$ONION_LINK\nADMIN_KEYS=$ADMIN_KEYS"
    run_as_user_with_nvm "cd \"$APP_DIR\" && echo \"$ENV_CONTENT\" > .env"

} 2>&1 | tee -a "$LOG_FILE"
if [ ${PIPESTATUS[0]} -eq 0 ]; then
    STATUS[6]="${GREEN}SUCCESS (npm install completed)${NC}"
else
    LAST_ERROR=$(tail -n 5 "$LOG_FILE")
    STATUS[6]="${RED}FAILED${NC}\n--- Last error ---
$LAST_ERROR
------------------"
fi
echo -e "--- Status: ${STATUS[6]}"

# Step 7: Start application with PM2
echo -e "\n${BLUE}### Step 7: ${STEPS[7]}...${NC}"
{
    STEP_7_DETAIL=""
    if ! run_as_user_with_nvm "command -v pm2 &>/dev/null"; then
        run_as_user_with_nvm "npm install pm2 -g"; STEP_7_DETAIL="Installed"
    else
        STEP_7_DETAIL="Already exists"
    fi
    run_as_user_with_nvm "cd \"$APP_DIR\" && (pm2 reload simple-chat || pm2 start server.js --name simple-chat)"
    run_as_user_with_nvm "pm2 save"
} 2>&1 | tee -a "$LOG_FILE"
if [ ${PIPESTATUS[0]} -eq 0 ]; then
    STATUS[7]="${GREEN}SUCCESS ($STEP_7_DETAIL)${NC}"
else
    LAST_ERROR=$(tail -n 5 "$LOG_FILE")
    STATUS[7]="${RED}FAILED${NC}\n--- Last error ---\n$LAST_ERROR\n------------------"
fi
echo -e "--- Status: ${STATUS[7]}"

# Step 8: Configure Nginx
if [ -n "$DOMAIN" ]; then
    echo -e "\n${BLUE}### Step 8: ${STEPS[8]}...${NC}"
    {
        NGINX_CONFIG="server {\n    listen 80;\n    server_name $DOMAIN;\n    location / {\n        proxy_pass http://127.0.0.1:$INFO_PORT;\n        proxy_http_version 1.1;\n        proxy_set_header Upgrade \\\\$http_upgrade;\n        proxy_set_header Connection 'upgrade';\n        proxy_set_header Host \\\\$host;\n        proxy_cache_bypass \\\\$http_upgrade;\n    }\n}"
        echo "$NGINX_CONFIG" | sudo tee /etc/nginx/sites-available/"$DOMAIN" > /dev/null
        sudo ln -sf /etc/nginx/sites-available/"$DOMAIN" /etc/nginx/sites-enabled/
        sudo nginx -t && sudo systemctl restart nginx
    } 2>&1 | tee -a "$LOG_FILE"
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        STATUS[8]="${GREEN}SUCCESS${NC}"
    else
        LAST_ERROR=$(tail -n 5 "$LOG_FILE")
        STATUS[8]="${RED}FAILED${NC}\n--- Last error ---\n$LAST_ERROR\n------------------"
    fi
    echo -e "--- Status: ${STATUS[8]}"
else
    STATUS[8]="${GREEN}SKIPPED (No domain provided)${NC}"
fi

# Step 9: Configure Firewall (UFW)
echo -e "\n${BLUE}### Step 9: ${STEPS[9]}...${NC}"
{
    sudo ufw allow 'Nginx Full'
    if ! sudo ufw allow 'OpenSSH'; then
        echo "UFW profile 'OpenSSH' not found. Allowing port 22/tcp as a fallback."
        sudo ufw allow 22/tcp
    fi
    sudo ufw --force enable
} 2>&1 | tee -a "$LOG_FILE"
if [ ${PIPESTATUS[0]} -eq 0 ]; then
    STATUS[9]="${GREEN}SUCCESS${NC}"
else
    LAST_ERROR=$(tail -n 5 "$LOG_FILE")
    STATUS[9]="${RED}FAILED${NC}\n--- Last error ---\n$LAST_ERROR\n------------------"
fi
echo -e "--- Status: ${STATUS[9]}"

# Step 10: Configure SSL with Certbot
if [ -n "$DOMAIN" ]; then
    echo -e "\n${BLUE}### Step 10: ${STEPS[10]}...${NC}"
    {
        STEP_10_DETAIL=""
        if ! command -v certbot &>/dev/null; then
            sudo apt-get install -y certbot python3-certbot-nginx; STEP_10_DETAIL="Installed, "
        else
            STEP_10_DETAIL="Exists, "
        fi
        if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
            sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN"; STEP_10_DETAIL+=\"new cert created\"
        else
            STEP_10_DETAIL+=\"cert exists\"
        fi
    } 2>&1 | tee -a "$LOG_FILE"
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        STATUS[10]="${GREEN}SUCCESS ($STEP_10_DETAIL)${NC}"
    else
        LAST_ERROR=$(tail -n 5 "$LOG_FILE")
        STATUS[10]="${RED}FAILED${NC}\n--- Last error ---\n$LAST_ERROR\n------------------"
    fi
    echo -e "--- Status: ${STATUS[10]}"
else
    STATUS[10]="${GREEN}SKIPPED (No domain provided)${NC}"
fi

# --- Final Summary ---
ANY_STEP_FAILED=false
for i in $(seq 1 10); do
    if [[ "${STATUS[$i]}" == *FAILED* ]]; then
        ANY_STEP_FAILED=true
        break
    fi
done

echo
echo -e "${BLUE}========================================${NC}"
if [ "$ANY_STEP_FAILED" = true ]; then
    echo -e "${RED} Installation Summary (COMPLETED WITH ERRORS)${NC}"
else
    echo -e "${GREEN} Installation Summary (SUCCESS)${NC}"
fi
echo -e "${BLUE}========================================${NC}"
for i in $(seq 1 10); do
    printf "Step %-2s: %-25s -> %b\n" "$i" "${STEPS[$i]}" "${STATUS[$i]}"
done
echo -e "${BLUE}----------------------------------------${NC}"

APP_STATUS_RAW=$(run_as_user_with_nvm "pm2 describe simple-chat 2>/dev/null | grep 'status' | head -n 1" || echo "status: not_found")
APP_STATUS=$(echo "$APP_STATUS_RAW" | awk -F'│' '{print $4}' | tr -d '[:space:]')

if [[ -z "$APP_STATUS" || "$APP_STATUS" == "not_found" ]]; then
    echo -e "Application Status: ${RED}NOT RUNNING${NC}"
else
    echo -e "Application Status: ${GREEN}$APP_STATUS${NC}"
fi

echo "Onion URL: http://$ONION_LINK"
if [ -n "$DOMAIN" ]; then
    echo "Domain URL: https://$DOMAIN"
fi
echo -e "${BLUE}========================================${NC}"
echo "Full installation log is available at: $LOG_FILE"
if [ "$ANY_STEP_FAILED" = true ]; then
    echo -e "${RED}!!! Some steps failed. Please review the summary above and check the log for details. !!!${NC}"
fi
