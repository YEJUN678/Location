const express = require('express');
const http = require('http');
const path = require('path');
const { Server } = require('socket.io');

const app = express();
const server = http.createServer(app);
const port = process.env.PORT || 3000;
const allowedOrigin = process.env.CORS_ORIGIN || '*';
const googleMapsApiKey = process.env.GOOGLE_MAPS_API_KEY || '';
const addressCache = new Map();
const roomMembers = new Map();

app.get('/health', (req, res) => {
  res.json({ ok: true });
});

app.use(express.static(path.join(__dirname, '../build/web')));

const io = new Server(server, {
  cors: { origin: allowedOrigin },
});

function normalizeRoomPayload(payload) {
  if (typeof payload === 'string') {
    return { roomId: payload };
  }
  return payload || {};
}

function emitUserLeft(socket) {
  const { roomId, userId, displayName } = socket.data || {};
  if (!roomId || !userId) return;

  const members = roomMembers.get(roomId);
  if (members) {
    members.delete(userId);
    if (members.size === 0) {
      roomMembers.delete(roomId);
    }
  }

  const payload = {
    userId,
    displayName: displayName || userId,
    roomId,
  };

  socket.to(roomId).emit('user_left', payload);

  // 관리자에게도 전달
  io.sockets.sockets.forEach((s) => {
    if (s.data?.isAdmin) {
      s.emit('user_left', payload);
    }
  });
}

function getRoomMembers(roomId, exceptUserId) {
  const members = roomMembers.get(roomId);
  if (!members) return [];
  return [...members.values()].filter((member) => member.userId !== exceptUserId);
}

function saveRoomMember(roomId, member) {
  if (!roomMembers.has(roomId)) {
    roomMembers.set(roomId, new Map());
  }
  roomMembers.get(roomId).set(member.userId, {
    ...member,
    updatedAt: Date.now(),
  });
}

function cacheKey(latitude, longitude) {
  return `${Number(latitude).toFixed(4)},${Number(longitude).toFixed(4)}`;
}

async function reverseGeocode(latitude, longitude) {
  if (!googleMapsApiKey) return '';
  const key = cacheKey(latitude, longitude);
  if (addressCache.has(key)) {
    return addressCache.get(key);
  }

  const url = new URL('https://maps.googleapis.com/maps/api/geocode/json');
  url.searchParams.set('latlng', `${latitude},${longitude}`);
  url.searchParams.set('language', 'ko');
  url.searchParams.set('key', googleMapsApiKey);

  try {
    const response = await fetch(url);
    if (!response.ok) {
      console.warn(`[geocode] HTTP ${response.status}`);
      return '';
    }
    const data = await response.json();
    const address = data.results?.[0]?.formatted_address || '';
    addressCache.set(key, address);
    return address;
  } catch (error) {
    console.warn('[geocode] failed', error);
    return '';
  }
}

io.on('connection', (socket) => {
  console.log(`[connect] ${socket.id}`);

  // 관리자 등록
  socket.on('register_admin', () => {
    socket.data.isAdmin = true;
    console.log(`[admin registered] ${socket.id}`);
    // 현재 모든 방 상태를 관리자에게 전달
    roomMembers.forEach((members, roomId) => {
      socket.emit('room_state', {
        roomId,
        users: [...members.values()],
      });
    });
  });

  socket.on('join_room', (payload) => {
    const { roomId, userId, displayName } = normalizeRoomPayload(payload);
    if (!roomId) return;

    if (socket.data.roomId && socket.data.roomId !== roomId) {
      emitUserLeft(socket);
      socket.leave(socket.data.roomId);
    }

    socket.data.roomId = roomId;
    socket.data.userId = userId || socket.data.userId || socket.id;
    socket.data.displayName = displayName || socket.data.displayName || socket.data.userId;

    socket.join(roomId);
    console.log(`[join_room] socket=${socket.id} user=${socket.data.userId} room=${roomId}`);

    socket.emit('room_state', {
      roomId,
      users: getRoomMembers(roomId, socket.data.userId),
    });
  });

  socket.on('update_location', async (data) => {
    const { roomId, userId, displayName, latitude, longitude, accuracy } = data;
    if (!roomId || !userId || latitude == null || longitude == null) return;

    socket.data.roomId = roomId;
    socket.data.userId = userId;
    socket.data.displayName = displayName || userId;
    socket.join(roomId);

    const address = await reverseGeocode(latitude, longitude);
    const locationPayload = {
      userId,
      displayName: displayName || userId,
      latitude,
      longitude,
      accuracy,
      address,
      roomId,
    };

    saveRoomMember(roomId, locationPayload);

    console.log(`[update_location] room=${roomId} user=${userId} name=${displayName || userId} lat=${latitude} lng=${longitude}`);

    socket.to(roomId).emit('location_changed', locationPayload);

    // 관리자에게도 전달
    io.sockets.sockets.forEach((s) => {
      if (s.data?.isAdmin) {
        s.emit('location_changed', locationPayload);
      }
    });

    socket.emit('room_state', {
      roomId,
      users: getRoomMembers(roomId, userId),
    });
  });

  socket.on('disconnect', () => {
    emitUserLeft(socket);
    console.log(`[disconnect] ${socket.id}`);
  });
});

server.listen(port, '0.0.0.0', () => {
  console.log(`Location socket server listening on port ${port}`);
});
