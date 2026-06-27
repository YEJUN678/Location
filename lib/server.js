const express = require('express');
const http = require('http');
const path = require('path');
const { Server } = require('socket.io');

const app = express();
const server = http.createServer(app);
const port = process.env.PORT || 3000;
const allowedOrigin = process.env.CORS_ORIGIN || '*';

app.get('/health', (req, res) => {
  res.json({ ok: true });
});

app.use(express.static(path.join(__dirname, '../build/web')));

const io = new Server(server, {
  cors: { origin: allowedOrigin },
});

io.on('connection', (socket) => {
  console.log(`[connect] ${socket.id}`);

  socket.on('join_room', (roomId) => {
    socket.join(roomId);
    console.log(`[join_room] socket=${socket.id} room=${roomId}`);
  });

  socket.on('update_location', (data) => {
    const { roomId, userId, displayName, latitude, longitude } = data;
    console.log(
      `[update_location] room=${roomId} user=${userId} name=${displayName || userId} lat=${latitude} lng=${longitude}`,
    );

    socket.to(roomId).emit('location_changed', {
      userId,
      displayName: displayName || userId,
      latitude,
      longitude,
    });
  });

  socket.on('disconnect', () => {
    console.log(`[disconnect] ${socket.id}`);
  });
});

server.listen(port, '0.0.0.0', () => {
  console.log(`Location socket server listening on port ${port}`);
});
