// server.js
const express = require('express');
const http = require('http');
const path = require('path');
const { Server } = require('socket.io');

const REDIS_URL = process.env.REDIS_URL || '';
let Redis;
let redisClient;

if (REDIS_URL) {
  try {
    Redis = require('ioredis');
    redisClient = new Redis(REDIS_URL);
    console.log('[redis] connected to', REDIS_URL);
  } catch (err) {
    console.warn('[redis] ioredis not installed or failed to connect, falling back to memory only', err);
    redisClient = null;
  }
} else {
  redisClient = null;
}

const app = express();
const server = http.createServer(app);
const port = process.env.PORT || 3000;
const allowedOrigin = process.env.CORS_ORIGIN || '*';
const googleMapsApiKey = process.env.GOOGLE_MAPS_API_KEY || '';

const addressCache = new Map(); // lat,lng -> address cache
// In-memory structure: roomId -> Map(userId -> memberObject)
const roomMembers = new Map();

// Helper: normalize payload
function normalizeRoomPayload(payload) {
  if (!payload) return {};
  if (typeof payload === 'string') return { roomId: payload };
  return payload;
}

// Redis helpers (if redisClient available)
// We store each room as a Redis hash: key = room:{roomId}, field = userId, value = JSON.stringify(member)
async function redisSaveMember(roomId, userId, member) {
  if (!redisClient) return;
  try {
    await redisClient.hset(`room:${roomId}`, userId, JSON.stringify(member));
  } catch (err) {
    console.warn('[redis] save member failed', err);
  }
}

async function redisRemoveMember(roomId, userId) {
  if (!redisClient) return;
  try {
    await redisClient.hdel(`room:${roomId}`, userId);
    const len = await redisClient.hlen(`room:${roomId}`);
    if (len === 0) {
      await redisClient.del(`room:${roomId}`);
    }
  } catch (err) {
    console.warn('[redis] remove member failed', err);
  }
}

async function redisGetRoomMembers(roomId) {
  if (!redisClient) return null;
  try {
    const data = await redisClient.hgetall(`room:${roomId}`);
    const members = [];
    for (const key of Object.keys(data)) {
      try {
        members.push(JSON.parse(data[key]));
      } catch (e) {
        // ignore parse error
      }
    }
    return members;
  } catch (err) {
    console.warn('[redis] get room members failed', err);
    return null;
  }
}

async function redisGetAllRooms() {
  if (!redisClient) return null;
  try {
    const keys = await redisClient.keys('room:*');
    const rooms = {};
    for (const k of keys) {
      const roomId = k.replace(/^room:/, '');
      const members = await redisGetRoomMembers(roomId);
      rooms[roomId] = members || [];
    }
    return rooms;
  } catch (err) {
    console.warn('[redis] get all rooms failed', err);
    return null;
  }
}

// Save member in memory and optionally Redis
function saveRoomMember(roomId, member) {
  if (!roomMembers.has(roomId)) {
    roomMembers.set(roomId, new Map());
  }
  roomMembers.get(roomId).set(member.userId, { ...member, updatedAt: Date.now() });
  if (redisClient) {
    redisSaveMember(roomId, member.userId, roomMembers.get(roomId).get(member.userId));
  }
}

// Remove member from memory and optionally Redis
function removeRoomMember(roomId, userId) {
  const members = roomMembers.get(roomId);
  if (!members) return;
  members.delete(userId);
  if (members.size === 0) {
    roomMembers.delete(roomId);
  }
  if (redisClient) {
    redisRemoveMember(roomId, userId);
  }
}

// Get members array for a room (excluding optional exceptUserId)
function getRoomMembers(roomId, exceptUserId) {
  const members = roomMembers.get(roomId);
  if (!members) return [];
  return [...members.values()].filter((m) => m.userId !== exceptUserId);
}

// Reverse geocode with caching
function cacheKey(latitude, longitude) {
  return `${Number(latitude).toFixed(4)},${Number(longitude).toFixed(4)}`;
}

async function reverseGeocode(latitude, longitude) {
  if (!googleMapsApiKey) return '';
  const key = cacheKey(latitude, longitude);
  if (addressCache.has(key)) return addressCache.get(key);
  try {
    const url = new URL('https://maps.googleapis.com/maps/api/geocode/json');
    url.searchParams.set('latlng', `${latitude},${longitude}`);
    url.searchParams.set('language', 'ko');
    url.searchParams.set('key', googleMapsApiKey);
    const res = await fetch(url.toString());
    if (!res.ok) {
      console.warn('[geocode] http', res.status);
      return '';
    }
    const data = await res.json();
    const address = data.results?.[0]?.formatted_address || '';
    if (address) addressCache.set(key, address);
    return address;
  } catch (err) {
    console.warn('[geocode] failed', err);
    return '';
  }
}

// Express endpoints
app.get('/health', (req, res) => {
  res.json({ ok: true });
});

// Serve static Flutter web build if exists
app.use(express.static(path.join(__dirname, 'build', 'web')));

// Socket.IO
const io = new Server(server, {
  cors: { origin: allowedOrigin },
});

// On startup, if Redis present, hydrate memory from Redis
(async function hydrateFromRedis() {
  if (!redisClient) return;
  try {
    const rooms = await redisGetAllRooms();
    if (!rooms) return;
    for (const [roomId, members] of Object.entries(rooms)) {
      if (!Array.isArray(members)) continue;
      const map = new Map();
      for (const m of members) {
        if (m && m.userId) {
          map.set(m.userId, { ...m, updatedAt: Date.now() });
        }
      }
      if (map.size > 0) roomMembers.set(roomId, map);
    }
    console.log('[redis] hydrated memory from redis, rooms:', roomMembers.size);
  } catch (err) {
    console.warn('[redis] hydrate failed', err);
  }
})();

function emitToAdmins(event, payload) {
  io.sockets.sockets.forEach((s) => {
    if (s.data?.isAdmin) {
      s.emit(event, payload);
    }
  });
}

function emitUserLeft(socket) {
  const { roomId, userId, displayName } = socket.data || {};
  if (!roomId || !userId) return;

  removeRoomMember(roomId, userId);

  const payload = {
    userId,
    displayName: displayName || userId,
    roomId,
  };

  socket.to(roomId).emit('user_left', payload);
  emitToAdmins('user_left', payload);
}

io.on('connection', (socket) => {
  console.log(`[connect] ${socket.id}`);

  // Admin registration: mark socket as admin and send current rooms state
  socket.on('register_admin', async () => {
    socket.data.isAdmin = true;
    console.log(`[admin registered] ${socket.id}`);
    // send memory rooms
    roomMembers.forEach((members, roomId) => {
      socket.emit('room_state', {
        roomId,
        users: [...members.values()],
      });
    });
    // if redis present, also send rooms from redis that might not be in memory
    if (redisClient) {
      try {
        const rooms = await redisGetAllRooms();
        if (rooms) {
          for (const [rId, members] of Object.entries(rooms)) {
            socket.emit('room_state', {
              roomId: rId,
              users: members,
            });
          }
        }
      } catch (err) {
        console.warn('[admin] failed to send redis rooms', err);
      }
    }
  });

  socket.on('join_room', async (payload) => {
    const { roomId, userId: pUserId, displayName: pDisplayName } = normalizeRoomPayload(payload);
    if (!roomId) return;

    // If socket was in another room, remove it
    if (socket.data.roomId && socket.data.roomId !== roomId) {
      emitUserLeft(socket);
      socket.leave(socket.data.roomId);
    }

    socket.data.roomId = roomId;
    socket.data.userId = pUserId || socket.data.userId || socket.id;
    socket.data.displayName = pDisplayName || socket.data.displayName || socket.data.userId;

    socket.join(roomId);
    console.log(`[join_room] socket=${socket.id} user=${socket.data.userId} room=${roomId}`);

    // If we have Redis but memory doesn't have this room, try to load from Redis
    if (redisClient && !roomMembers.has(roomId)) {
      const members = await redisGetRoomMembers(roomId);
      if (members && members.length > 0) {
        const map = new Map();
        for (const m of members) {
          if (m && m.userId) map.set(m.userId, { ...m, updatedAt: Date.now() });
        }
        if (map.size > 0) roomMembers.set(roomId, map);
      }
    }

    // send current room state to this socket
    socket.emit('room_state', {
      roomId,
      users: getRoomMembers(roomId, socket.data.userId),
    });

    // notify admins
    emitToAdmins('room_state', {
      roomId,
      users: getRoomMembers(roomId, null),
    });
  });

  socket.on('update_location', async (data) => {
    const {
      roomId,
      userId,
      displayName,
      latitude,
      longitude,
      accuracy,
    } = data || {};

    if (!roomId || !userId || latitude == null || longitude == null) {
      return;
    }

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
      updatedAt: Date.now(),
    };

    saveRoomMember(roomId, locationPayload);

    console.log(`[update_location] room=${roomId} user=${userId} name=${displayName || userId} lat=${latitude} lng=${longitude}`);

    // broadcast to room
    socket.to(roomId).emit('location_changed', locationPayload);

    // send to admins
    emitToAdmins('location_changed', locationPayload);

    // send updated room state back to the emitter (optional)
    socket.emit('room_state', {
      roomId,
      users: getRoomMembers(roomId, userId),
    });
  });

  // Chat message handling
  socket.on('chat_message', (data) => {
    try {
      const roomId = data?.roomId;
      if (!roomId) return;
      // broadcast to room
      socket.to(roomId).emit('chat_message', data);
      // also send to admins
      emitToAdmins('chat_message', data);
    } catch (err) {
      console.warn('[chat_message] error', err);
    }
  });

  // Optional: client can request rooms list (if redis present)
  socket.on('request_rooms', async () => {
    if (redisClient) {
      const rooms = await redisGetAllRooms();
      socket.emit('rooms_list', rooms || {});
    } else {
      // build from memory
      const out = {};
      roomMembers.forEach((members, roomId) => {
        out[roomId] = [...members.keys()];
      });
      socket.emit('rooms_list', out);
    }
  });

  socket.on('disconnect', () => {
    emitUserLeft(socket);
    console.log(`[disconnect] ${socket.id}`);
  });
});

// Graceful shutdown
function shutdown() {
  console.log('Shutting down...');
  try {
    io.close();
    server.close(() => {
      console.log('HTTP server closed');
      if (redisClient) {
        redisClient.quit().catch(() => {});
      }
      process.exit(0);
    });
  } catch (err) {
    console.error('Error during shutdown', err);
    process.exit(1);
  }
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

server.listen(port, '0.0.0.0', () => {
  console.log(`Location socket server listening on port ${port}`);
});
