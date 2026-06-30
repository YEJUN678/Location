// server.js
// Location sharing + chat server with admin ban/force-logout/search and optional Redis persistence.

const express = require('express');
const http = require('http');
const path = require('path');
const fetch = require('node-fetch');
const { Server } = require('socket.io');
const bodyParser = require('body-parser');

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

app.use(bodyParser.json());
app.use(express.static(path.join(__dirname, 'build', 'web')));

// In-memory structures and fallbacks
const addressCache = new Map(); // lat,lng -> address cache
const roomMembers = new Map(); // roomId -> Map(userId -> memberObject)

// fallback maps for socket mapping and bans if Redis not present
const userSocketMap = new Map();      // userId -> socketId
const clientSocketMap = new Map();    // clientId -> socketId
const bannedClients = new Set();      // clientId
const bannedUsers = new Set();        // userId
const bannedIps = new Set();          // ip strings

// Helper: normalize payload
function normalizeRoomPayload(payload) {
  if (!payload) return {};
  if (typeof payload === 'string') return { roomId: payload };
  return payload;
}

// Redis helpers for room members
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

// Chat persistence helpers (Redis list)
async function saveChatMessage(roomId, msg) {
  const json = JSON.stringify(msg);
  if (redisClient) {
    try {
      await redisClient.lpush(`chat:${roomId}`, json);
      await redisClient.ltrim(`chat:${roomId}`, 0, 999); // keep last 1000
    } catch (err) {
      console.warn('[redis] save chat failed', err);
    }
  } else {
    if (!global._chatStore) global._chatStore = {};
    global._chatStore[roomId] = global._chatStore[roomId] || [];
    global._chatStore[roomId].unshift(msg);
    if (global._chatStore[roomId].length > 1000) global._chatStore[roomId].pop();
  }
}

async function getChatHistory(roomId, limit = 50) {
  if (redisClient) {
    try {
      const items = await redisClient.lrange(`chat:${roomId}`, 0, limit - 1);
      return items.map(i => JSON.parse(i));
    } catch (err) {
      console.warn('[redis] get chat history failed', err);
      return [];
    }
  } else {
    const arr = (global._chatStore && global._chatStore[roomId]) || [];
    return arr.slice(0, limit);
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

// Hydrate memory from Redis on startup
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

// Utility: emit to admin sockets
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

// Ban check and socket lookup helpers
async function isBanned({ clientId, userId, token, ip }) {
  try {
    if (redisClient) {
      if (clientId) {
        const v = await redisClient.get(`banned:client:${clientId}`);
        if (v) return true;
      }
      if (userId) {
        const v = await redisClient.get(`banned:user:${userId}`);
        if (v) return true;
      }
      if (ip) {
        const v = await redisClient.get(`banned:ip:${ip}`);
        if (v) return true;
      }
      if (token) {
        const v = await redisClient.get(`banned:token:${token}`);
        if (v) return true;
      }
    } else {
      if (clientId && bannedClients.has(clientId)) return true;
      if (userId && bannedUsers.has(userId)) return true;
      if (ip && bannedIps.has(ip)) return true;
    }
  } catch (e) {
    console.warn('[ban] check failed', e);
  }
  return false;
}

async function lookupSocketIdByType(type, id) {
  if (!id) return null;
  if (redisClient) {
    if (type === 'client') return await redisClient.get(`client_socket:${id}`);
    if (type === 'user') return await redisClient.get(`user_socket:${id}`);
    return null;
  } else {
    if (type === 'client') return clientSocketMap.get(id) || null;
    if (type === 'user') return userSocketMap.get(id) || null;
    return null;
  }
}

// Express endpoints
app.get('/health', (req, res) => {
  res.json({ ok: true });
});

// Chat history endpoint
app.get('/api/chat/:roomId', async (req, res) => {
  const roomId = req.params.roomId;
  const limit = parseInt(req.query.limit || '50', 10);
  try {
    const messages = await getChatHistory(roomId, limit);
    res.json({ ok: true, messages });
  } catch (err) {
    res.status(500).json({ ok: false, error: 'failed' });
  }
});

// Admin endpoints
app.post('/admin/ban', async (req, res) => {
  const { type, id, reason } = req.body; // type: client|user|ip|token
  if (!type || !id) return res.status(400).json({ ok: false, error: 'type and id required' });

  try {
    if (redisClient) {
      await redisClient.set(`banned:${type}:${id}`, JSON.stringify({ reason: reason || '', ts: Date.now() }));
    } else {
      if (type === 'client') bannedClients.add(id);
      if (type === 'user') bannedUsers.add(id);
      if (type === 'ip') bannedIps.add(id);
    }

    const socketId = await lookupSocketIdByType(type, id);
    if (socketId && io.sockets.sockets.get(socketId)) {
      io.to(socketId).emit('force_logout', { reason: reason || 'banned' });
      io.sockets.sockets.get(socketId).disconnect(true);
    }

    return res.json({ ok: true });
  } catch (err) {
    console.warn('[admin/ban] error', err);
    return res.status(500).json({ ok: false, error: 'internal' });
  }
});

app.post('/admin/unban', async (req, res) => {
  const { type, id } = req.body;
  if (!type || !id) return res.status(400).json({ ok: false, error: 'type and id required' });
  try {
    if (redisClient) {
      await redisClient.del(`banned:${type}:${id}`);
    } else {
      if (type === 'client') bannedClients.delete(id);
      if (type === 'user') bannedUsers.delete(id);
      if (type === 'ip') bannedIps.delete(id);
    }
    return res.json({ ok: true });
  } catch (err) {
    console.warn('[admin/unban] error', err);
    return res.status(500).json({ ok: false, error: 'internal' });
  }
});

app.post('/admin/force_logout', async (req, res) => {
  const { type, id } = req.body; // type: client|user
  if (!type || !id) return res.status(400).json({ ok: false, error: 'type and id required' });
  try {
    const socketId = await lookupSocketIdByType(type, id);
    if (socketId && io.sockets.sockets.get(socketId)) {
      io.to(socketId).emit('force_logout', { reason: 'admin' });
      io.sockets.sockets.get(socketId).disconnect(true);
      return res.json({ ok: true, forced: true });
    }
    return res.json({ ok: true, forced: false });
  } catch (err) {
    console.warn('[admin/force_logout] error', err);
    return res.status(500).json({ ok: false, error: 'internal' });
  }
});

app.get('/admin/search', async (req, res) => {
  const q = (req.query.q || '').toString().trim();
  if (!q) return res.json({ ok: true, rooms: [], users: [] });

  try {
    const rooms = [];
    roomMembers.forEach((members, roomId) => {
      if (roomId.includes(q)) rooms.push(roomId);
    });

    const users = [];
    roomMembers.forEach((members) => {
      members.forEach((m) => {
        if (m.userId && m.userId.includes(q)) users.push(m.userId);
        if (m.displayName && m.displayName.includes(q)) users.push(m.displayName);
      });
    });

    const uniqueUsers = Array.from(new Set(users)).slice(0, 200);
    return res.json({ ok: true, rooms, users: uniqueUsers });
  } catch (err) {
    console.warn('[admin/search] error', err);
    return res.status(500).json({ ok: false, error: 'internal' });
  }
});

// Socket.IO
const io = new Server(server, {
  cors: { origin: allowedOrigin },
});

io.on('connection', (socket) => {
  console.log(`[connect] ${socket.id}`);

  // register_user: client sends { clientId, userId, token }
  socket.on('register_user', async (data) => {
    const clientId = data?.clientId;
    const userId = data?.userId;
    const token = data?.token;
    const ip = socket.handshake.address;

    const banned = await isBanned({ clientId, userId, token, ip });
    if (banned) {
      socket.emit('force_logout', { reason: 'banned' });
      socket.disconnect(true);
      return;
    }

    try {
      if (clientId) {
        if (redisClient) await redisClient.set(`client_socket:${clientId}`, socket.id);
        else clientSocketMap.set(clientId, socket.id);
        socket.data.clientId = clientId;
      }
      if (userId) {
        if (redisClient) await redisClient.set(`user_socket:${userId}`, socket.id);
        else userSocketMap.set(userId, socket.id);
        socket.data.userId = userId;
      }
      socket.data.token = token;
    } catch (err) {
      console.warn('[register_user] mapping save failed', err);
    }
  });

  // Admin registration
  socket.on('register_admin', async () => {
    socket.data.isAdmin = true;
    console.log(`[admin registered] ${socket.id}`);
    roomMembers.forEach((members, roomId) => {
      socket.emit('room_state', {
        roomId,
        users: [...members.values()],
      });
    });
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

    if (socket.data.roomId && socket.data.roomId !== roomId) {
      emitUserLeft(socket);
      socket.leave(socket.data.roomId);
    }

    socket.data.roomId = roomId;
    socket.data.userId = pUserId || socket.data.userId || socket.id;
    socket.data.displayName = pDisplayName || socket.data.displayName || socket.data.userId;

    socket.join(roomId);
    console.log(`[join_room] socket=${socket.id} user=${socket.data.userId} room=${roomId}`);

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

    socket.emit('room_state', {
      roomId,
      users: getRoomMembers(roomId, socket.data.userId),
    });

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

    socket.to(roomId).emit('location_changed', locationPayload);
    emitToAdmins('location_changed', locationPayload);

    socket.emit('room_state', {
      roomId,
      users: getRoomMembers(roomId, userId),
    });
  });

  // Chat message handling: save and broadcast
  socket.on('chat_message', async (data) => {
    try {
      const roomId = data?.roomId;
      if (!roomId) return;

      // normalize message object and add id/ts
      const msg = {
        id: data.id || `${Date.now()}_${Math.random().toString(36).slice(2,8)}`,
        userId: data.userId || socket.data.userId || 'unknown',
        displayName: data.displayName || socket.data.displayName || (data.userId || 'unknown'),
        message: data.message || '',
        image: data.image || null,
        ts: Date.now(),
      };

      await saveChatMessage(roomId, msg);

      socket.to(roomId).emit('chat_message', msg);
      emitToAdmins('chat_message', msg);
    } catch (err) {
      console.warn('[chat_message] error', err);
    }
  });

  socket.on('request_rooms', async () => {
    if (redisClient) {
      const rooms = await redisGetAllRooms();
      socket.emit('rooms_list', rooms || {});
    } else {
      const out = {};
      roomMembers.forEach((members, roomId) => {
        out[roomId] = [...members.keys()];
      });
      socket.emit('rooms_list', out);
    }
  });

  socket.on('disconnect', () => {
    // cleanup mappings
    const cid = socket.data?.clientId;
    const uid = socket.data?.userId;
    if (cid) {
      if (redisClient) redisClient.del(`client_socket:${cid}`).catch(()=>{});
      else clientSocketMap.delete(cid);
    }
    if (uid) {
      if (redisClient) redisClient.del(`user_socket:${uid}`).catch(()=>{});
      else userSocketMap.delete(uid);
    }

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
