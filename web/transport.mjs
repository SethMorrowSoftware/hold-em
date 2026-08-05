// Transport adapters.
//
// HOLDEM-PROTOCOL.md section 6.1 states what a transport must provide, not
// which one to use: message-oriented, peer-addressed, may lose/duplicate/
// reorder/redeliver, carries an admission token at handshake. Everything that
// makes the table safe -- authenticity, ordering, secrecy of the two private
// lanes, recovery -- lives above this layer.
//
// Two adapters here:
//   LoopbackBus  in-process, for tests and the headless sim. Can be told to
//                drop, duplicate, and reorder, precisely BECAUSE the protocol
//                is supposed to survive all three.
//   WebSocketTransport  a browser/Node client against a dumb fan-out relay.
//                The relay needs no protocol knowledge and cannot cheat:
//                every envelope is signed end to end and hash-chained.

// ---------------------------------------------------------------- loopback
export class LoopbackBus {
  constructor(opts = {}) {
    this.ports = new Map();          // peerId -> port
    this.next = 1;
    this.queue = [];
    this.dropRate = opts.dropRate ?? 0;
    this.dupRate = opts.dupRate ?? 0;
    this.reorder = opts.reorder ?? false;
    this.rng = opts.rng ?? Math.random;
    this.delivered = 0;
    this.dropped = 0;
    this.duplicated = 0;
  }

  port() {
    const id = this.next++;
    const p = new LoopbackPort(this, id);
    this.ports.set(id, p);
    return p;
  }

  _enqueue(fromId, toId, payload) {
    if (this.rng() < this.dropRate) { this.dropped++; return; }
    this.queue.push({ fromId, toId, payload });
    if (this.rng() < this.dupRate) { this.queue.push({ fromId, toId, payload }); this.duplicated++; }
  }

  // Deliver everything currently queued (and anything queued as a result),
  // until the bus goes quiet. Returns the number of payloads delivered.
  pump(maxRounds = 5000) {
    let rounds = 0;
    while (this.queue.length && rounds++ < maxRounds) {
      let batch = this.queue;
      this.queue = [];
      if (this.reorder && batch.length > 1) {
        batch = batch.slice();
        for (let i = batch.length - 1; i > 0; i--) {
          const j = Math.floor(this.rng() * (i + 1));
          [batch[i], batch[j]] = [batch[j], batch[i]];
        }
      }
      for (const m of batch) {
        const dest = this.ports.get(m.toId);
        if (!dest) continue;
        this.delivered++;
        dest._deliver(m.fromId, m.payload);
      }
    }
    return this.delivered;
  }

  // every port handshakes with every other (the phantom-swarm shape)
  connectAll() {
    const all = [...this.ports.values()];
    for (const a of all)
      for (const b of all) {
        if (a === b) continue;
        if (a.token !== null) b._handshake(a.id, a.token);
      }
  }
}

class LoopbackPort {
  constructor(bus, id) {
    this.bus = bus;
    this.id = id;
    this.token = null;
    this._onMsg = () => {};
    this._onHs = () => {};
    this.hostPeer = null;
  }
  setToken(token) { this.token = token; }
  onMessage(cb) { this._onMsg = cb; }
  onHandshake(cb) { this._onHs = cb; }
  send(peer, payload) { this.bus._enqueue(this.id, peer, payload); }
  broadcast(payload) {
    for (const id of this.bus.ports.keys()) if (id !== this.id) this.send(id, payload);
  }
  sendToHost(payload) {
    if (this.hostPeer !== null) this.send(this.hostPeer, payload);
  }
  _deliver(fromId, payload) { this._onMsg(fromId, payload); }
  _handshake(fromId, token) { this._onHs(fromId, token); }
}

// -------------------------------------------------------------- websocket
// Frames on the wire are:  <peerId> "\x01" <payload>
// The relay assigns peer ids, echoes handshakes, and fans out. It does not
// parse, verify, or understand anything else -- see web/relay.mjs.
export class WebSocketTransport {
  constructor(url, { tableCode }) {
    this.url = url;
    this.tableCode = tableCode;
    this.token = null;
    this._onMsg = () => {};
    this._onHs = () => {};
    this.hostPeer = null;
    this.ws = null;
    this.ready = new Promise((res) => { this._res = res; });
  }

  connect(WS = globalThis.WebSocket) {
    this.ws = new WS(`${this.url}?table=${this.tableCode}`);
    this.ws.onopen = () => {
      if (this.token !== null) this.ws.send(`\x02${this.token}`);
      this._res();
    };
    this.ws.onmessage = (ev) => {
      const data = typeof ev.data === 'string' ? ev.data : String(ev.data);
      const i = data.indexOf('\x01');
      if (i < 0) return;
      const peer = Number(data.slice(0, i));
      const rest = data.slice(i + 1);
      if (rest.startsWith('\x02')) this._onHs(peer, rest.slice(1));
      else this._onMsg(peer, rest);
    };
    return this.ready;
  }

  setToken(token) {
    this.token = token;
    if (this.ws && this.ws.readyState === 1) this.ws.send(`\x02${token}`);
  }
  onMessage(cb) { this._onMsg = cb; }
  onHandshake(cb) { this._onHs = cb; }
  send(peer, payload) { this.ws.send(`${peer}\x01${payload}`); }
  broadcast(payload) { this.ws.send(`*\x01${payload}`); }
  sendToHost(payload) {
    if (this.hostPeer !== null) this.send(this.hostPeer, payload);
    else this.broadcast(payload);      // pre-adoption: the host will pick it up
  }
}
