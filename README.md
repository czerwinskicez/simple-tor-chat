# Very Simple Chat

A lightweight, real-time messaging application built with Node.js, Express, and WebSockets. It features a clean, modern dark-mode interface and includes an admin functionality for message moderation.

## Features

- **Real-time Messaging**: Instant message delivery using WebSockets.
- **Persistent Chat History**: Messages are saved on the server in a `.txt` file.
- **Structured Message Logging**: Messages are stored in a structured format: `📅{timestamp}👤{nickname}📝{message}`.
- **Modern UI**: A clean, dark-themed, and responsive user interface.
- **Nickname Persistence**: The user's nickname is saved in the browser's `localStorage`.
- **Admin Message Deletion**: Users with a valid admin key can delete messages directly from the UI.
- **Emoji Sanitization**: Emojis are automatically removed from nicknames and messages to maintain data integrity.

## Tech Stack

- **Backend**: Node.js, Express.js, ws (WebSocket library)
- **Frontend**: HTML5, CSS3, Vanilla JavaScript
- **Configuration**: dotenv

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

1.  **Create a `.env` file** in the root directory of the project.
2.  **Add admin keys**. The keys should be a comma-separated string without any spaces.

    **.env file example:**
    ```env
    ADMIN_KEYS=secretkey1,admin123,anotherkey
    ```

## Usage

1.  **Start the server:**
    ```bash
    node server.js
    ```

2.  **Open the application** in your browser at `http://localhost:3000`.

3.  **To use admin features:**
    -   Access the application with an admin key as a URL parameter.
    -   Example: `http://localhost:3000?adminkey=secretkey1`
    -   If the key is valid, you will see a "Delete" button next to each message.
