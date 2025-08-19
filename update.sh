#!/bin/bash

set -e

cd /home/nodeapps/very-simple-chat || { echo "Error: Cannot find application directory."; exit 1; }

echo "Downloading."
git fetch --all
git reset --hard origin/master

echo "Updating dependencies."
npm install

echo "Building application."
npm run build

echo "Reloading application."
pm2 reload tor-hidden-chat

echo "Cleaning up."
git clean -fd

echo ""
echo "Update completed successfully."
echo ""
echo "Application info:"
echo "- Chat application: Running on port ${CHAT_PORT:-3000} (.onion network)"
echo "- Info page: Running on port ${INFO_PORT:-3330} (public domain)"
echo "- Both services run from the same Node.js process"