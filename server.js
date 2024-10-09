const express = require('express');
const fs = require('fs');
const path = require('path');
const http = require('http');
const WebSocket = require('ws');

const app = express();
const port = 3000;

// Create HTTP server for Express
const server = http.createServer(app);

// Create a WebSocket server
const wss = new WebSocket.Server({ server });

app.use(express.static('public'));
app.use(express.urlencoded({ extended: true }));

// Function to broadcast message to all connected WebSocket clients
function broadcastMessage(message) {
  wss.clients.forEach((client) => {
    if (client.readyState === WebSocket.OPEN) {
      client.send(message);
    }
  });
}

// Endpoint to handle message submissions
app.post('/send-message', (req, res) => {
  const { nick, message } = req.body;
  const filePath = path.join(__dirname, 'messages.txt');
  const logMessage = `[${new Date().toLocaleString()}] ${nick}: ${message}\n`;

  // Append message to the file
  fs.appendFile(filePath, logMessage, (err) => {
    if (err) {
      console.error('Error saving message:', err);
      return res.status(500).send('Error saving message');
    }

    console.log('Message saved:', logMessage);
    broadcastMessage(logMessage); // Broadcast the new message to all WebSocket clients
    res.send('Message received');
  });
});

// Endpoint to fetch all previous messages
app.get('/messages', (req, res) => {
  const filePath = path.join(__dirname, 'messages.txt');

  fs.readFile(filePath, 'utf8', (err, data) => {
    if (err) {
      console.error('Error reading messages file:', err);
      return res.status(500).send('Error reading messages');
    }

    res.send(data);
  });
});

// Start the server
server.listen(port, () => {
  console.log(`Server running on http://localhost:${port}`);
});
