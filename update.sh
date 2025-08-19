#!/bin/bash

set -e

cd /home/nodeapps/very-simple-chat || { echo "Error: Cannot find application directory."; exit 1; }

echo "Downloading."
git pull

echo "Updating dependencies."
npm install

echo "Reloading application."
pm2 reload server

echo ""
echo "Update completed successfully!"