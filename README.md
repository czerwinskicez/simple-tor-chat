# Very Simple Chat

A real-time messaging application designed for privacy, accessible via the Tor network. It's built with Node.js, Express, and WebSockets, featuring a persistent SQLite database and a separate public-facing page with Tor access information.

## Architecture Overview

The project consists of two distinct Node.js servers running within a single process:

1.  **Chat Server**: The core real-time chat application, accessible exclusively through a Tor hidden service (`.onion` address). It handles WebSocket connections, message storage, and admin functionalities.
2.  **Info Server**: A simple, public-facing web server that displays a page with information on how to access the chat via the Tor network. It provides the `.onion` link dynamically from environment variables.

A build process is in place to minify frontend assets (HTML, CSS, JS) from the `private/` directory and output them to the `public/` directory, which is then served by the applications.

## Features

- **Tor-Exclusive Chat**: The main chat is designed to be accessed only as a Tor hidden service, enhancing user privacy.
- **Real-time Messaging**: Instant message delivery using WebSockets (`ws`).
- **Persistent Storage**: Messages are stored in a local SQLite database.
- **Admin Moderation**: Admins can delete messages in real-time using a special URL parameter.
- **Build Process**: Frontend assets are minified for production using `html-minifier-terser`, `terser`, and `clean-css`.
- **Automated Deployment**: An `update.sh` script automates the deployment process on the server (fetching updates, installing dependencies, building, and reloading the app with PM2).

## Tech Stack

- **Backend**: Node.js, Express.js, WebSocket (`ws`), SQLite3
- **Frontend**: Vanilla HTML, CSS, and JavaScript
- **Build Tools**: `html-minifier-terser`, `terser`, `clean-css`
- **Environment**: `dotenv` for configuration management.

## Project Structure

```
.
├── private/            # Source frontend files (unminified)
│   ├── index.html
│   └── info.html
├── public/             # Built/minified frontend files
│   ├── index.html
│   └── info.html
├── database.sqlite     # SQLite database file
├── .env                # Environment variables (not versioned)
├── build.js            # Build script for minifying assets
├── server.js           # Main server logic for both apps
├── update.sh           # Deployment script for the server
├── package.json
└── README.md
```

## Installation and Setup

1.  **Clone the repository:**
    ```bash
    git clone <repository-url>
    cd very-simple-chat
    ```

2.  **Install dependencies:**
    ```bash
    npm install
    ```

## Configuration

1.  Create a `.env` file in the root directory.

2.  Add the required environment variables to the `.env` file:

    ```env
    # Port for the chat server (Tor hidden service)
    CHAT_PORT=3000

    # Port for the public info page
    INFO_PORT=3330

    # The .onion address of your chat service
    ONION_LINK=youronionaddress.onion

    # Comma-separated list of keys for admin privileges
    ADMIN_KEYS=secretkey1,admin123
    ```

## Usage

### Development

To run the application in a development environment (with automatic building):

```bash
npm run dev
```

This will first build the assets and then start the server.

- The chat will be available at `http://localhost:3000` (or your `CHAT_PORT`).
- The info page will be available at `http://localhost:3330` (or your `INFO_PORT`).

### Production & Deployment

The `update.sh` script is designed to automate deployment on a production server. It performs the following steps:
1.  Navigates to the application directory.
2.  Pulls the latest changes from the `origin/master` branch.
3.  Installs dependencies with `npm install`.
4.  Builds the frontend assets using `npm run build`.
5.  Reloads the application using PM2 (`pm2 reload tor-hidden-chat`).
6.  Cleans up untracked files.

To use it, ensure you have PM2 installed and the application is already running under the name `tor-hidden-chat`.

### Admin Features

To access admin features (message deletion), append the `adminkey` query parameter to the chat URL with a valid key from your `.env` file.

Example: `http://youronionaddress.onion?adminkey=secretkey1`
