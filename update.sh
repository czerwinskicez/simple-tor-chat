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
CHAT_PORT=$(grep CHAT_PORT .env | cut -d '=' -f2)
INFO_PORT=$(grep INFO_PORT .env | cut -d '=' -f2)
echo "- Chat application: Running on port ${CHAT_PORT} (.onion network)"
echo "- Info page: Running on port ${INFO_PORT} (public domain)"
echo "- Both services run from the same Node.js process"