const express = require('express');
const path = require('path');
const http = require('http');
const WebSocket = require('ws');
const sqlite3 = require('sqlite3').verbose();
require('dotenv').config();

const app = express();
const infoApp = express();
const chatPort = process.env.CHAT_PORT || 3000;
const infoPort = process.env.INFO_PORT || 3330;

// Set up SQLite database
const dbPath = path.join(__dirname, 'database.sqlite');
const db = new sqlite3.Database(dbPath, (err) => {
    if (err) {
        console.error('Error opening database', err.message);
    } else {
        console.log('Connected to the SQLite database.');
        db.run(`CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            nickname TEXT NOT NULL,
            message TEXT NOT NULL
        )`);
    }
});

const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

// Serve the built files from public directory
app.use(express.static('public'));
app.use(express.urlencoded({ extended: true }));
app.use(express.json()); // Middleware to parse JSON bodies

app.use(express.static('public'));

// Serve chat UI (Tor-only service should reverse-proxy to this app)
app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'private', 'index.html'));
});

// Function to remove emojis
function removeEmojis(text) {
    if (typeof text !== 'string') return '';
    return text.replace(/([\u2700-\u27BF]|[\uE000-\uF8FF]|\uD83C[\uDC00-\uDFFF]|\uD83D[\uDC00-\uDFFF]|[\u2011-\u26FF]|\uD83E[\uDD10-\uDDFF])/g, '');
}

// Function to broadcast message to all connected WebSocket clients
function broadcastMessage(message) {
  wss.clients.forEach((client) => {
    if (client.readyState === WebSocket.OPEN) {
      client.send(JSON.stringify(message));
    }
  });
}

// Endpoint to handle message submissions
app.post('/send-message', (req, res) => {
  let { nick, message } = req.body;

  nick = removeEmojis(nick);
  message = removeEmojis(message);

  if (!nick || !message) {
      return res.status(400).send('Nickname and message are required.');
  }

  const timestamp = new Date().toISOString();
  const stmt = db.prepare("INSERT INTO messages (timestamp, nickname, message) VALUES (?, ?, ?)");
  
  stmt.run(timestamp, nick, message, function(err) {
      if (err) {
          console.error('Error saving message:', err);
          return res.status(500).send('Error saving message');
      }
      const newMessage = { id: this.lastID, timestamp, nickname: nick, message };
      console.log('Message saved:', newMessage);
      broadcastMessage(newMessage);
      res.status(201).json(newMessage);
  });
});

// Endpoint to delete a message
app.post('/delete-message', (req, res) => {
    const { messageId, adminkey } = req.body;
    const adminKeys = (process.env.ADMIN_KEYS || '').split(',');

    if (!adminKeys.includes(adminkey)) {
        return res.status(403).send('Forbidden');
    }
    
    db.run("DELETE FROM messages WHERE id = ?", [messageId], function(err) {
        if (err) {
            console.error('Error deleting message:', err);
            return res.status(500).send('Error deleting message');
        }
        if (this.changes === 0) {
            return res.status(404).send('Message not found');
        }
        broadcastMessage({ type: 'delete', id: messageId });
        res.send('Message deleted');
    });
});

// Endpoint to fetch all previous messages
app.get('/messages', (req, res) => {
    db.all("SELECT * FROM messages ORDER BY timestamp ASC", [], (err, rows) => {
        if (err) {
            console.error('Error fetching messages:', err);
            return res.status(500).send('Error fetching messages');
        }
        res.json(rows);
    });
});

// Info app - simple page with onion link
const fs = require('fs');
// Serve shared public assets for the info app as well
infoApp.use(express.static('public'));

infoApp.get('/', (req, res) => {
    const onionLink = process.env.ONION_LINK;
    const infoHtmlPath = path.join(__dirname, 'public', 'info.html');
    
    fs.readFile(infoHtmlPath, 'utf8', (err, data) => {
        if (err) {
            console.error('Error reading info.html:', err);
            return res.status(500).send('Error loading page');
        }
        
        // Replace placeholder with actual onion link
        const html = data.replace(/\{\{ONION_LINK\}\}/g, onionLink || '');
        res.send(html);
    });
});

// Start both servers
server.listen(chatPort, '127.0.0.1', () => {
  console.log(`Chat server listening on 127.0.0.1:${chatPort} (Tor should proxy to this port)`);
});

infoApp.listen(infoPort, () => {
  console.log(`Info server running on http://localhost:${infoPort}`);
});
