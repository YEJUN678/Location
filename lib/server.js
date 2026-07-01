// server.js
// Location socket server with admin force-logout and ban support
// - Real-time location updates via socket.io
// - Admin REST endpoint to force logout by userId or clientId
// - Admin REST endpoint to ban user/client (persisted to ./data/bans.json)
// - Minimal file-based logs and users.json persistence for demo purposes

const express = require('express');
const fs = require('fs');
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

app.use(express.json()); // parse JSON bodies for admin endpoints

app.get('/health', (req, res) => {
  res.json({ ok: true });
});

// serve web build if present
app.use(express.static(path.join(__dirname, '../build/web')));

// admin data endpoints (existing)
app.get('/api/admin/users', (req, res) => {
  res.json(readJson('./data/users.json', {}));
});

app.get('/api/admin/logs', (req, res) => {
  res.json(readJson('./data/logs.json', []));
});

app.get('/api/admin/rooms', (req, res) => {
  const users = Object.values(readJson('./data/users.json', {}));
  const rooms = {};
  users.forEach((user) => {
    if (!rooms[user.roomId]) {
      rooms[user.roomId] = [];
    }
    rooms[user.roomId].push(user);
  });
  res.json(rooms);
});

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

  socket.to(roomId).emit('user_left', {
    userId,
    displayName: displayName || userId,
    roomId,
  });
}

function getRoomMembers(roomId, exceptUserId) {
  const members = roomMembers.get(roomId);
  if (!members) return [];

  return [...members.values()].filter((member) => {
    return member.userId !== exceptUserId;
  });
}

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    return fallback;
  }
}

function writeJson(file, data) {
  try {
    // ensure directory exists
    const dir = path.dirname(file);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(file, JSON.stringify(data, null, 2));
  } catch (err) {
    console.warn(`[writeJson] failed to write ${file}`, err);
  }
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

/**
 * Ban list utilities
 * bans.json structure:
 * {
 *   "users": { "<userId>": { "id": "<userId>", "type": "user", "reason": "...", "ts": 123456789 } },
 *   "clients": { "<clientId>": { "id": "<clientId>", "type": "client", "reason": "...", "ts": 123456789 } }
 * }
 */
const BANS_FILE = './data/bans.json';

function loadBans() {
  return readJson(BANS_FILE, { users: {}, clients: {} });
}

function saveBan(type, id, reason) {
  const bans = loadBans();
  if (type === 'user') {
    bans.users[id] = { id, type, reason: reason || '', ts: Date.now() };
  } else if (type === 'client') {
    bans.clients[id] = { id, type, reason: reason || '', ts: Date.now() };
  }
  writeJson(BANS_FILE, bans);
}

function isBanned(type, id) {
  const bans = loadBans();
  if (type === 'user') {
    return !!bans.users[id];
  } else if (type === 'client') {
    return !!bans.clients[id];
  }
  return false;
}

function disconnectMatchingSocketsByType(type, id, reason) {
  let found = 0;
  for (const socket of io.sockets.sockets.values()) {
    try {
      if ((type === 'user' && socket.data.userId === id) || (type === 'client' && socket.data.clientId === id)) {
        socket.emit('force_logout', { reason: reason || 'Admin action (ban/force logout)' });
        socket.disconnect(true);
        found++;
      }
    } catch (e) {
      // ignore per-socket errors
    }
  }
  return found;
}

/**
 * Admin endpoint: force logout (existing)
 * POST /admin/force_logout
 * Body: { "type": "user" | "client", "id": "<userId or clientId>", "reason": "optional reason" }
 *
 * This endpoint does NOT modify any ban list; it only sends 'force_logout' to matching sockets and disconnects them.
 */
app.post('/admin/force_logout', (req, res) => {
  try {
    const { type, id, reason } = req.body || {};
    if (!type || !id) {
      return res.status(400).json({ ok: false, error: 'type and id required' });
    }

    let found = 0;
    for (const socket of io.sockets.sockets.values()) {
      try {
        if ((type === 'user' && socket.data.userId === id) || (type === 'client' && socket.data.clientId === id)) {
          socket.emit('force_logout', { reason: reason || 'Admin forced logout' });
          socket.disconnect(true);
          found++;
        }
      } catch (e) {
        // ignore per-socket errors
      }
    }

    return res.json({ ok: true, message: found ? `force logout sent to ${found} socket(s)` : 'no matching sockets' });
  } catch (err) {
    console.error('[admin/force_logout] error', err);
    return res.status(500).json({ ok: false, error: 'internal error' });
  }
});

/**
 * Admin endpoint: ban user or client (new)
 * POST /admin/ban
 * Body: { "type": "user" | "client", "id": "<userId or clientId>", "reason": "optional reason" }
 *
 * This will persist the ban to data/bans.json and disconnect any matching sockets immediately.
 */
app.post('/admin/ban', (req, res) => {
  try {
    const { type, id, reason } = req.body || {};
    if (!type || !id) {
      return res.status(400).json({ ok: false, error: 'type and id required' });
    }

    if (type !== 'user' && type !== 'client') {
      return res.status(400).json({ ok: false, error: 'type must be "user" or "client"' });
    }

    // persist ban
    saveBan(type, id, reason || '');

    // disconnect matching sockets
    const found = disconnectMatchingSocketsByType(type, id, reason);

    return res.json({ ok: true, message: `banned ${type} ${id}`, disconnected: found });
  } catch (err) {
    console.error('[admin/ban] error', err);
    return res.status(500).json({ ok: false, error: 'internal error' });
  }
});

// Optional admin search endpoint used by admin UI
app.get('/admin/search', (req, res) => {
  try {
    const q = (req.query.q || '').toString().trim().toLowerCase();
    if (!q) return res.json({ rooms: [], users: [] });

    const usersObj = readJson('./data/users.json', {});
    const users = Object.keys(usersObj).filter((u) => u.toLowerCase().includes(q));
    const roomsObj = readJson('./data/users.json', {});
    const roomsSet = new Set();
    Object.values(roomsObj).forEach((u) => {
      if (u && u.roomId && u.roomId.toLowerCase().includes(q)) roomsSet.add(u.roomId);
    });

    return res.json({ rooms: Array.from(roomsSet), users });
  } catch (err) {
    console.error('[admin/search] error', err);
    return res.status(500).json({ rooms: [], users: [] });
  }
});

io.on('connection', (socket) => {
  console.log(`[connect] ${socket.id}`);

  // register_user: client should emit this on connect with clientId and userId
  socket.on('register_user', (payload) => {
    try {
      const { clientId, userId, token } = payload || {};
      socket.data.clientId = clientId || socket.data.clientId;
      socket.data.userId = userId || socket.data.userId || socket.id;
      socket.data.token = token || socket.data.token;

      // If this user/client is banned, immediately force logout
      try {
        if (socket.data.userId && isBanned('user', socket.data.userId)) {
          socket.emit('force_logout', { reason: 'You are banned' });
          socket.disconnect(true);
          console.log(`[register_user] disconnected banned user=${socket.data.userId}`);
          return;
        }
        if (socket.data.clientId && isBanned('client', socket.data.clientId)) {
          socket.emit('force_logout', { reason: 'You are banned' });
          socket.disconnect(true);
          console.log(`[register_user] disconnected banned client=${socket.data.clientId}`);
          return;
        }
      } catch (e) {
        // ignore ban-check errors
      }

      // Note: No ban list here by default; we record clientId/userId for admin actions.
      console.log(`[register_user] socket=${socket.id} user=${socket.data.userId} clientId=${socket.data.clientId}`);
    } catch (err) {
      console.warn('[register_user] error', err);
    }
  });

  // Admin-initiated force logout via socket event (new)
  // Only allow if the emitter socket has been registered as admin (socket.data.isAdmin === true)
  socket.on('admin_force_logout', (payload) => {
    try {
      if (!socket.data || !socket.data.isAdmin) {
        // ignore or optionally emit an error back
        socket.emit('admin_error', { error: 'not_authorized' });
        return;
      }
      const { type, id, reason } = payload || {};
      if (!type || !id) {
        socket.emit('admin_error', { error: 'type_and_id_required' });
        return;
      }
      // perform same action as REST endpoint: emit force_logout and disconnect matching sockets
      let found = 0;
      for (const s of io.sockets.sockets.values()) {
        try {
          if ((type === 'user' && s.data.userId === id) || (type === 'client' && s.data.clientId === id)) {
            s.emit('force_logout', { reason: reason || 'Admin forced logout' });
            s.disconnect(true);
            found++;
          }
        } catch (e) {
          // ignore per-socket errors
        }
      }
      socket.emit('admin_result', { ok: true, message: found ? `force logout sent to ${found} socket(s)` : 'no matching sockets' });
    } catch (err) {
      console.error('[admin_force_logout] error', err);
      socket.emit('admin_error', { error: 'internal_error' });
    }
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
    socket.data.displayName =
      displayName || socket.data.displayName || socket.data.userId;

    socket.join(roomId);
    console.log(
      `[join_room] socket=${socket.id} user=${socket.data.userId} room=${roomId}`,
    );

    const logs = readJson('./data/logs.json', []);
    logs.push({
      type: 'join',
      userId: socket.data.userId,
      displayName: socket.data.displayName,
      roomId,
      ip: socket.handshake.address,
      time: new Date().toISOString(),
    });
    writeJson('./data/logs.json', logs);

    socket.emit('room_state', {
      roomId,
      users: getRoomMembers(roomId, socket.data.userId),
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
    } = data;

    if (!roomId || !userId || latitude == null || longitude == null) {
      return;
    }

    // update socket data (in case register_user wasn't called)
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
    };

    saveRoomMember(roomId, locationPayload);
    const users = readJson('./data/users.json', {});

    users[userId] = {
      userId,
      displayName,
      roomId,
      latitude,
      longitude,
      address,
      lastSeen: new Date().toISOString(),
    };

    writeJson('./data/users.json', users);

    console.log(
      `[update_location] room=${roomId} user=${userId} name=${displayName || userId} lat=${latitude} lng=${longitude}`,
    );

    socket.to(roomId).emit('location_changed', locationPayload);
    socket.emit('room_state', {
      roomId,
      users: getRoomMembers(roomId, userId),
    });
  });

  socket.on('chat_message', (data) => {
    // basic relay - server could persist chat here
    try {
      const msg = {
        id: `${Date.now()}`,
        userId: data.userId,
        displayName: data.displayName,
        message: data.message,
        ts: Date.now(),
        roomId: data.roomId,
      };

      // append to chat store if desired (not implemented here)
      socket.to(data.roomId).emit('chat_message', msg);
      socket.emit('chat_message', msg);
    } catch (e) {
      // ignore
    }
  });

  socket.on('typing', (data) => {
    try {
      socket.to(data.roomId).emit('typing', data);
    } catch (e) {}
  });

  socket.on('request_rooms', () => {
    // build a simple rooms list from roomMembers and users.json
    const users = readJson('./data/users.json', {});
    const rooms = {};
    Object.values(users).forEach((u) => {
      if (!u || !u.roomId) return;
      if (!rooms[u.roomId]) rooms[u.roomId] = [];
      rooms[u.roomId].push(u.userId);
    });
    socket.emit('rooms_list', rooms);
  });

  socket.on('register_admin', () => {
    // admin-specific registration; could check token in future
    socket.data.isAdmin = true;
    console.log(`[register_admin] socket=${socket.id}`);
  });

  socket.on('disconnect', () => {
    const logs = readJson('./data/logs.json', []);
    logs.push({
      type: 'leave',
      userId: socket.data.userId,
      displayName: socket.data.displayName,
      roomId: socket.data.roomId,
      time: new Date().toISOString(),
    });
    writeJson('./data/logs.json', logs);

    emitUserLeft(socket);

    console.log(`[disconnect] ${socket.id}`);
  });
});

server.listen(port, '0.0.0.0', () => {
  console.log(`Location socket server listening on port ${port}`);
});
