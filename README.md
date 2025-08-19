# Very Simple Chat

A robust, real-time messaging application built with Node.js, Express, and WebSockets. It features a clean, modern dark-mode interface, persistent message storage in a SQLite database, and includes admin functionality for message moderation.

## Features

- **Real-time Messaging**: Instant message delivery using WebSockets.
- **Persistent & Reliable Storage**: Messages are stored in a SQLite database, ensuring data integrity and reliability.
- **Modern UI**: A clean, dark-themed, and responsive user interface built with vanilla HTML, CSS, and JavaScript.
- **Nickname Persistence**: The user's nickname is saved in the browser's `localStorage` for convenience.
- **Admin Message Deletion**: Users with a valid admin key can delete messages directly from the UI. The action is broadcasted in real-time to all clients.
- **Emoji Sanitization**: Emojis are automatically removed from nicknames and messages before being stored.

## Tech Stack

- **Backend**: Node.js, Express.js, WebSocket (`ws`), SQLite3
- **Frontend**: HTML5, CSS3, Vanilla JavaScript
- **Configuration**: `dotenv` for environment variables.

## Project Structure
```
.
├── public/
│   └── index.html      # Frontend logic and UI
├── database.sqlite     # SQLite database file
├── .env.example        # Example environment file
├── .gitignore          # Git ignore file
├── package.json
├── README.md
└── server.js           # Main server logic
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

1.  **Create a `.env` file** in the root directory by copying the example:
    ```bash
    cp .env.example .env
    ```

2.  **Add your admin keys** to the `.env` file. Keys should be a comma-separated string without any spaces.

    **.env file contents:**
    ```env
    # Comma-separated list of keys for admin privileges
    ADMIN_KEYS=secretkey1,admin123,anotherkey
    
    # Optional port setting, defaults to 3000
    # PORT=8080
    ```
    
3.  Ensure `database.sqlite` is writable by the application. The server will automatically create and initialize the database on first run.

## Usage

1.  **Start the server:**
    ```bash
    npm start
    ```

2.  **Open the application** in your browser at `http://localhost:3000` (or the port you specified in `.env`).

3.  **To use admin features:**
    -   Access the application with an admin key as a URL parameter.
    -   Example: `http://localhost:3000?adminkey=secretkey1`
    -   If the key is valid, a "Delete" button will appear next to each message.
