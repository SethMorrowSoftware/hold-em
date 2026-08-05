// A deliberately dumb WebSocket fan-out relay, plus a static file server.
//
//   node relay.mjs [--port 8787]   then open http://localhost:8787/
//
// WHAT THIS IS NOT: an authority. It does not verify a signature, does not
// know what poker is, cannot read a hole card, cannot forge or alter a
// message, and cannot change who wins. Every envelope that passes through it
// is signed by its author, countersigned by the host, and hash-chained
// (HOLDEM-PROTOCOL.md section 5), so a hostile relay's entire power is to
// drop or delay payloads -- which is exactly the failure the ingest rules in
// section 7 are built to survive.
//
// It exists because browsers cannot accept inbound connections, so two
// browsers need someone to introduce them. That is its whole job. See
// web/README.md section 3 for why this is the near-term transport and what
// replaces it.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PORT = (() => {
  const i = process.argv.indexOf('--port');
  return i < 0 ? 8787 : Number(process.argv[i + 1]);
})();

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json',
  '.wasm': 'application/wasm',
};

const server = http.createServer((req, res) => {
  const rel = decodeURIComponent((req.url || '/').split('?')[0]);
  if (rel === '/favicon.ico') { res.writeHead(204); res.end(); return; }
  const file = path.join(HERE, rel === '/' ? 'index.html' : rel);
  if (!file.startsWith(HERE) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    res.writeHead(404); res.end('not found'); return;
  }
  res.writeHead(200, { 'content-type': TYPES[path.extname(file)] || 'application/octet-stream' });
  fs.createReadStream(file).pipe(res);
});

const wss = new WebSocketServer({ server });

// One room per table code. The relay knows a table only as an opaque string.
const rooms = new Map();          // tableCode -> Map(peerId -> {ws, token})
let nextPeerId = 1;

wss.on('connection', (ws, req) => {
  const url = new URL(req.url, 'http://x');
  const table = url.searchParams.get('table') || 'default';
  if (!rooms.has(table)) rooms.set(table, new Map());
  const room = rooms.get(table);
  const id = nextPeerId++;
  room.set(id, { ws, token: null });
  console.log(`+ peer ${id} joined table ${table.slice(0, 12)}... (${room.size} in room)`);

  ws.on('message', (raw) => {
    const data = raw.toString();

    // \x02 = "this is my admission token". The relay stores it verbatim and
    // introduces this peer to the others -- it never inspects or validates it;
    // the clients do that themselves (protocol doc 4.4).
    if (data.startsWith('\x02')) {
      const token = data.slice(1);
      room.get(id).token = token;
      for (const [otherId, other] of room) {
        if (otherId === id) continue;
        if (other.ws.readyState === 1) other.ws.send(`${id}\x01\x02${token}`);
        if (other.token !== null && ws.readyState === 1)
          ws.send(`${otherId}\x01\x02${other.token}`);
      }
      return;
    }

    // <target>\x01<payload>, target "*" = everyone else. Payload is opaque.
    const i = data.indexOf('\x01');
    if (i < 0) return;
    const target = data.slice(0, i);
    const payload = data.slice(i + 1);
    const framed = `${id}\x01${payload}`;
    if (target === '*') {
      for (const [otherId, other] of room)
        if (otherId !== id && other.ws.readyState === 1) other.ws.send(framed);
    } else {
      const dest = room.get(Number(target));
      if (dest && dest.ws.readyState === 1) dest.ws.send(framed);
    }
  });

  ws.on('close', () => {
    room.delete(id);
    console.log(`- peer ${id} left table ${table.slice(0, 12)}... (${room.size} left)`);
    if (room.size === 0) rooms.delete(table);
  });
});

server.listen(PORT, () => {
  console.log(`holde-em relay + static server on http://localhost:${PORT}/`);
  console.log('This relay verifies nothing and cannot cheat -- see the header comment.');
});
