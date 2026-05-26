const express = require('express');
const { WebSocketServer } = require('ws');
const http = require('http');
const path = require('path');
const { v4: uuidv4 } = require('uuid');
const apn = require('@parse/node-apn');

const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ server });

app.use(express.static(path.join(__dirname, 'public')));
app.get('*', (req, res) => res.sendFile(path.join(__dirname, 'public', 'index.html')));

// ---- APNs ----
let apnProvider = null;
if (process.env.APN_KEY && process.env.APN_KEY_ID && process.env.APN_TEAM_ID) {
  try {
    const raw = process.env.APN_KEY;
    // Support both base64-encoded and raw PEM (with literal \n escapes)
    const rawKey = raw.includes('-----BEGIN')
      ? raw.replace(/\\n/g, '\n')
      : Buffer.from(raw, 'base64').toString('utf8');
    apnProvider = new apn.Provider({
      token: {
        key: Buffer.from(rawKey),
        keyId: process.env.APN_KEY_ID,
        teamId: process.env.APN_TEAM_ID,
      },
      production: process.env.APN_PRODUCTION === 'true',
    });
    console.log('[APNs] Provider initialized');
  } catch (e) {
    console.error('[APNs] Failed to initialize:', e.message);
  }
}

const BUNDLE_ID = process.env.BUNDLE_ID || 'com.sounddepo.setcom';

async function sendAlertPush(token, title, body, data = {}) {
  if (!apnProvider || !token) return;
  const note = new apn.Notification();
  note.expiry = Math.floor(Date.now() / 1000) + 3600;
  note.badge = 1;
  note.sound = 'default';
  note.alert = { title, body };
  note.topic = BUNDLE_ID;
  note.priority = 10;
  note.pushType = 'alert';
  note.aps['interruption-level'] = 'time-sensitive';
  note.payload = data;
  const result = await apnProvider.send(note, token).catch(e => ({ failed: [{ error: e }] }));
  if (result?.failed?.length) console.log('[APNs] Alert push failed:', result.failed[0].response || result.failed[0].error);
}

async function sendVoIPPush(token, data) {
  if (!apnProvider || !token) return;
  const note = new apn.Notification();
  note.expiry = Math.floor(Date.now() / 1000) + 30;
  note.payload = data;
  note.topic = `${BUNDLE_ID}.voip`;
  note.priority = 10;
  const result = await apnProvider.send(note, token).catch(e => ({ failed: [{ error: e }] }));
  if (result?.failed?.length) console.log('[APNs] VoIP push failed:', result.failed[0].response || result.failed[0].error);
}


// ---- Client store ----
// { ws, name, role, channel, device, pushToken, voipToken, pttToken }
const clients = new Map();

function getRoster() {
  const list = [];
  for (const [id, c] of clients) {
    if (c.device === 'watch' || c.device === 'native-audio') continue;
    if (c.name) list.push({ id, name: c.name, role: c.role, channel: c.channel });
  }
  return list;
}

function broadcast(data, excludeId = null) {
  const msg = JSON.stringify(data);
  for (const [id, c] of clients) {
    if (id !== excludeId && c.ws.readyState === 1) c.ws.send(msg);
  }
}

function sendTo(id, data) {
  const c = clients.get(id);
  if (c && c.ws.readyState === 1) c.ws.send(JSON.stringify(data));
}

// ---- Per-channel call cooldown (5s) ----
const callCooldown = new Map();

// ---- Zombie connection cleanup (ping every 30s, drop if no pong in 10s) ----
setInterval(() => {
  for (const [id, c] of clients) {
    if (c.ws.readyState !== 1) { clients.delete(id); continue; }
    if (c._waitingPong) {
      console.log(`[ZOMBIE] dropping ${c.name || id}`);
      if (c.transmitting && c.name) broadcast({ type: 'ptt-stop', from: id, name: c.name }, id);
      c.ws.terminate();
      clients.delete(id);
      broadcast({ type: 'roster', roster: getRoster() });
      continue;
    }
    c._waitingPong = true;
    c.ws.ping();
  }
}, 30000);


// ---- WebSocket ----
wss.on('connection', (ws) => {
  const id = uuidv4();
  clients.set(id, { ws, name: null, role: null, channel: null, device: 'phone',
                     pushToken: null, voipToken: null, pttToken: null });

  ws.send(JSON.stringify({ type: 'welcome', id, roster: getRoster() }));

  ws.on('pong', () => {
    const c = clients.get(id);
    if (c) c._waitingPong = false;
  });

  ws.on('message', async (raw, isBinary) => {
    // ---- Binary audio frames: route to matching-channel clients ----
    if (isBinary) {
      const client = clients.get(id);
      if (!client) return;
      if (!client._audioFrames) { client._audioFrames = 0; }
      client._audioFrames++;
      if (client._audioFrames === 1) console.log(`[AUDIO] first frame from ${client.name} (${raw.length} bytes)`);
      // Use the active PTT channel if set (authoritative), fall back to join channel
      const srcChannel = client.pttChannel || client.channel;
      if (!srcChannel || srcChannel === '') return; // no routing until channel is known
      for (const [peerId, peer] of clients) {
        if (peerId === id) continue;
        if (peer.name && client.name && peer.name === client.name) continue; // no self-echo
        const chMatch = srcChannel === 'all' || peer.channel === 'all'
                     || peer.channel === srcChannel;
        if (!chMatch) continue;
        if (peer.ws.readyState === 1) peer.ws.send(raw, { binary: true });
      }
      return;
    }

    let msg;
    try { msg = JSON.parse(raw); } catch { return; }
    const client = clients.get(id);
    if (!client) return;

    switch (msg.type) {

      case 'join':
        client.name    = msg.name    || 'Unknown';
        client.role    = msg.role    || 'crew';
        client.channel = msg.channel || (msg.device === 'native-audio' ? '' : 'all');
        client.device  = msg.device  || 'phone';
        console.log(`[JOIN] ${client.name} (${client.role}) ch=${client.channel} dev=${client.device}`);
        broadcast({ type: 'roster', roster: getRoster() });
        break;

      case 'channel-change':
        client.channel = msg.channel || client.channel;
        broadcast({ type: 'roster', roster: getRoster() });
        break;

      case 'ptt-start':
        console.log(`[PTT-START] ${client.name} → ${msg.channel}`);
        client.transmitting = true;
        client.pttChannel = msg.channel;
        broadcast({ type: 'ptt-start', from: id, name: client.name, channel: msg.channel }, id);
        // Wake backgrounded phones on the same channel
        for (const [, peer] of clients) {
          if (peer.name === client.name) continue;
          const ch = msg.channel;
          const chMatch = ch === 'all' || peer.channel === 'all' || peer.channel === ch;
          if (!chMatch) continue;
          if (peer.voipToken) sendVoIPPush(peer.voipToken, { type: 'ptt-start', name: client.name, channel: ch }).catch(() => {});
        }
        break;

      case 'ptt-stop':
        client.transmitting = false;
        client.pttChannel = null;
        broadcast({ type: 'ptt-stop', from: id, name: client.name }, id);
        break;

      case 'call-channel': {
        const ch = msg.channel;
        const now = Date.now();
        const key = `${client.name}:${ch}`;
        if (callCooldown.get(key) && now - callCooldown.get(key) < 5000) {
          sendTo(id, { type: 'call-result', channel: ch, cooldown: true });
          break;
        }
        callCooldown.set(key, now);
        let pushed = 0;
        for (const [peerId, peer] of clients) {
          if (peerId === id) continue;
          const chMatch = ch === 'all' || peer.channel === 'all' || peer.channel === ch;
          if (!chMatch) continue;
          sendTo(peerId, { type: 'incoming-call', from: id, name: client.name, channel: ch });
          if (peer.voipToken) { sendVoIPPush(peer.voipToken, { type: 'incoming-call', name: client.name, channel: ch }); pushed++; }
          if (peer.pushToken) { sendAlertPush(peer.pushToken, '📞 SETCOM CALL', `${client.name} · ${ch}`, { name: client.name, channel: ch }); pushed++; }
        }
        console.log(`[CALL] ${client.name} → ch=${ch}, pushed VoIP to ${pushed} device(s)`);
        sendTo(id, { type: 'call-result', channel: ch, pushed });
        break;
      }

      case 'register-push-token':
        client.pushToken = msg.token;
        break;

      case 'register-voip-token':
        client.voipToken = msg.token;
        console.log(`[VoIP] Token registered for ${client.name || 'unknown'}`);
        break;


      default:
        break;
    }
  });

  ws.on('close', () => {
    const client = clients.get(id);
    if (client?.transmitting && client.name) {
      broadcast({ type: 'ptt-stop', from: id, name: client.name }, id);
    }
    console.log(`[LEAVE] ${client?.name || id}`);
    clients.delete(id);
    broadcast({ type: 'roster', roster: getRoster() });
  });

  ws.on('error', () => {
    const client = clients.get(id);
    if (client?.transmitting && client.name) {
      broadcast({ type: 'ptt-stop', from: id, name: client.name }, id);
    }
    clients.delete(id);
  });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => console.log(`Setcom server running on port ${PORT}`));
