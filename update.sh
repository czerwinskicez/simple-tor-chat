#!/bin/bash

set -e

cd /home/nodeapps/very-simple-chat || { echo "Error: Cannot find application directory."; exit 1; }

echo "Downloading."
git fetch --all
git reset --hard origin/master

echo "Updating dependencies."
npm install

echo "Reloading application."
pm2 reload tor-hidden-chat

echo "Cleaning up."
git clean -fd

echo ""
echo "Update completed successfully!"