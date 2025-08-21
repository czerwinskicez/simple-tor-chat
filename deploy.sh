#!/bin/bash

# Exit on any error
set -e

# --- Configuration ---
CHAT_PORT_DEFAULT="3000"
INFO_PORT_DEFAULT="3330"
DOMAIN_DEFAULT=""
ADMIN_KEYS_DEFAULT="sekretnyKlucz1,innySekretnyKlucz"
REPO_URL="https://github.com/czerwinskicez/simple-tor-chat.git"
APP_DIR="/var/www/chat"

# --- User Detection ---
if [ -n "$SUDO_USER" ]; then
    RUN_AS_USER=$SUDO_USER
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    RUN_AS_USER=$USER
    USER_HOME=$HOME
fi

echo "Running script as user: $RUN_AS_USER"
echo "User home directory: $USER_HOME"

# --- Functions ---
usage() {
    echo "Usage: $0 [-c CHAT_PORT] [-i INFO_PORT] [-d DOMAIN] [-a ADMIN_KEYS]"
    echo "  -c CHAT_PORT: Chat port (default: $CHAT_PORT_DEFAULT)"
    echo "  -i INFO_PORT: Info port (default: $INFO_PORT_DEFAULT)"
    echo "  -d DOMAIN: Domain for Nginx and Certbot (optional)"
    echo "  -a ADMIN_KEYS: Comma-separated admin keys (default: $ADMIN_KEYS_DEFAULT)"
    exit 1
}

# Runs a command as the target user, ensuring NVM is available.
run_as_user_with_nvm() {
    # The -i flag simulates a login, setting HOME correctly.
    # We then explicitly source nvm.sh, which is the most reliable method.
    sudo -u "$RUN_AS_USER" -i -- bash -c ". \"$HOME/.nvm/nvm.sh\" && $1"
}

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
ADMIN_KEYS=${ADMIN_KEYS:-$ADMIN_KEYS_DEFAULT}

# --- Script ---
echo "Starting deployment..."

# Step 1: System Update
echo "### Step 1: Updating system..."
sudo apt update && sudo apt upgrade -y

# Step 2: Install Nginx, Git and Tor
echo "### Step 2: Installing Nginx, Git and Tor..."
sudo apt install -y nginx git tor

# Step 3: Install Node.js (via NVM)
echo "### Step 3: Installing Node.js..."
if [ ! -d "$USER_HOME/.nvm" ]; then
    # The NVM installation script is run directly, without trying to source nvm.sh yet.
    sudo -u "$RUN_AS_USER" -i -- bash -c "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash"
fi
run_as_user_with_nvm "nvm install --lts"

# Step 4: Configure Tor
echo "### Step 4: Configuring Tor..."
sudo tee /etc/tor/torrc > /dev/null <<EOF
HiddenServiceDir /var/lib/tor/hidden_service/
HiddenServicePort 80 127.0.0.1:$CHAT_PORT
EOF
sudo systemctl restart tor
sleep 5 # Wait for hostname file to be created
ONION_LINK=$(sudo cat /var/lib/tor/hidden_service/hostname)
echo "Tor Onion Service Address: http://$ONION_LINK"

# Step 5: Clone repository
echo "### Step 5: Cloning repository..."
if [ ! -d "$APP_DIR" ]; then
    sudo git clone "$REPO_URL" "$APP_DIR"
else
    cd "$APP_DIR"
    sudo git pull
fi
sudo chown -R "$RUN_AS_USER:$RUN_AS_USER" "$APP_DIR"

# Step 6: Configure application
echo "### Step 6: Configuring application..."
cd "$APP_DIR"
run_as_user_with_nvm "cd $APP_DIR && npm install"
tee .env > /dev/null <<EOF
CHAT_PORT=$CHAT_PORT
INFO_PORT=$INFO_PORT
ONION_LINK=http://$ONION_LINK
ADMIN_KEYS=$ADMIN_KEYS
EOF

# Step 7: Start application with PM2
echo "### Step 7: Starting application with PM2..."
run_as_user_with_nvm "npm install pm2 -g"
run_as_user_with_nvm "cd $APP_DIR && pm2 start server.js --name \"simple-chat\""
PM2_STARTUP_COMMAND=$(run_as_user_with_nvm "pm2 startup | tail -n 1")
if [[ -n "$PM2_STARTUP_COMMAND" ]]; then
    echo "Executing PM2 startup command: $PM2_STARTUP_COMMAND"
    eval "$PM2_STARTUP_COMMAND"
fi
run_as_user_with_nvm "pm2 save"

# Step 8: Configure Nginx
if [ -n "$DOMAIN" ]; then
    echo "### Step 8: Configuring Nginx for domain $DOMAIN..."
    sudo tee /etc/nginx/sites-available/"$DOMAIN" > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:$INFO_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF
    sudo ln -sf "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/"
    sudo nginx -t
    sudo systemctl restart nginx
fi

# Step 9: Configure Firewall (UFW)
echo "### Step 9: Configuring Firewall..."
sudo ufw allow 'Nginx Full'
sudo ufw allow 'OpenSSH'
sudo ufw --force enable

# Step 10: Configure SSL with Certbot
if [ -n "$DOMAIN" ]; then
    echo "### Step 10: Configuring SSL with Certbot..."
    sudo apt install -y certbot python3-certbot-nginx
    sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN"
fi

echo "---"
echo "Deployment finished!"
echo "Onion URL: http://$ONION_LINK"
if [ -n "$DOMAIN" ]; then
    echo "Domain URL: https://$DOMAIN"
fi
echo "---"
