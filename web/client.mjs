// holde-em table client -- the protocol loop.
//
// Implements HOLDEM-PROTOCOL.md sections 7 (ingest and ordering), 8 (message
// vocabulary and the authority matrix), 9 (lifecycle), and 10 (the Level 0
// deal), on top of web/holdem-protocol.mjs (bytes) and web/engine.mjs (rules).
//
// One class, two roles: every Table is a player, and a Table constructed with
// {isHost:true} additionally sequences, countersigns, relays, and emits the
// host-authored message types. That mirrors the reference implementation,
// where the host is a player whose machine also runs the switchboard.
//
// Transport-agnostic: a Table is handed a transport object (see transport.mjs)
// and never touches a socket itself.

import * as P from './holdem-protocol.mjs';
import * as E from './engine.mjs';

const MAX_SEATS = 6;
const WIRE_BUF_MAX = 64;          // bounded reorder buffer (protocol doc 7.2)
const RESYNC_DEBOUNCE_MS = 2000;
const REPLAY_RATE_MS = 2000;      // per-peer replay rate limit (protocol doc 6.2)

export class Table {
  constructor(opts) {
    const { idSeed, transport, isHost = false, tableIdHex = null, cfg = {},
            log = () => {}, now = () => Date.now() } = opts;

    // Injectable clock. The resync debounce and the per-peer replay rate limit
    // are the only time-dependent rules in the client, and both MUST stay
    // (they are what stops replay amplification -- protocol doc 6.2). Making
    // the clock a parameter is what lets a simulation drive them in virtual
    // time instead of waiting out real seconds.
    this.now = now;
    this.tx = transport;
    this.isHost = isHost;
    this.logLine = log;

    // identity (protocol doc 4.1-4.2)
    this.idSeed = idSeed;
    this.idSeedHex = P.hex(idSeed);
    const kp = P.identityFromSeed(idSeed);
    this.idPub = kp.publicKey;
    this.idSec = kp.privateKey;
    this.idPubHex = P.hex(this.idPub);
    this.fingerprint = P.fingerprint(this.idPub);
    const box = P.boxKeyFromIdSeedHex(this.idSeedHex);
    this.boxPub = box.publicKey;
    this.boxSec = box.privateKey;

    // table
    this.tableIdHex = tableIdHex ?? P.hex(P.sodium.randombytes_buf(32));
    this.infohash = P.infohashOf(P.unhex(this.tableIdHex));
    this.hostPubHex = isHost ? this.idPubHex : '';

    this.cfg = { sb: 1, bb: 2, ante: 0, stack: 400, seats: MAX_SEATS, ...cfg };

    // chain state (protocol doc 7.1)
    this.seqCounter = 0;
    this.lastSeq = 0;
    this.chainHead = P.GENESIS;
    this.wireLog = [];
    this.buffer = new Map();
    this.syncAskedAt = -Infinity;
    this.replayAt = new Map();
    this.catchUpTo = null;

    // presence
    this.admitted = new Map();     // pubHex -> role
    this.peerByPub = new Map();
    this.pubByPeer = new Map();
    this.rosterBody = '';
    this.cfgBody = '';

    // game
    this.handNum = 0;
    this.gameOn = false;
    this.joinSent = false;
    this.seatByPub = new Map();
    this.pubBySeat = new Map();
    this.boxByPub = new Map();
    this.seatedList = [];
    this.stacksBy = new Map();
    this.lastBB = 0;
    this.buttonSeat = 0;
    this.state = null;             // engine state
    this.rcptHead = P.GENESIS;
    this.deal = freshDeal();
    this.phase = 'lobby';

    this.admitted.set(this.idPubHex, isHost ? 'host' : 'player');

    this.tx.onHandshake((peer, token) => this._onHandshake(peer, token));
    this.tx.onMessage((peer, payload) => this._onMessage(peer, payload));

    this.onChange = () => {};
  }

  get myRole() { return this.isHost ? 'host' : 'player'; }
  get admitToken() {
    return P.admitToken(this.tableIdHex, this.idPubHex, this.idSec, this.myRole);
  }
  get mySeat() { return this.seatByPub.get(this.idPubHex) ?? 0; }

  // The host seeds the transcript with a signed cfg at seq 1 from genesis;
  // late joiners replay it and verify the host key before anything else.
  start() {
    this.tx.setToken(this.admitToken);
    if (this.isHost) this.send('cfg', this.cfgBodyText());
  }

  cfgBodyText() {
    const c = this.cfg;
    return `v=1,level=0,sb=${c.sb},bb=${c.bb},ante=${c.ante},` +
           `stack=${c.stack},seats=${c.seats},button=1`;
  }

  // ------------------------------------------------------------ transport in
  _onHandshake(peer, token) {
    const ok = P.admitTokenVerify(token, this.tableIdHex);
    if (!ok) { this.logLine('drop   handshake from an unadmitted peer'); return; }
    const { pubHex, role } = ok;

    const isNew = !this.admitted.has(pubHex);
    const oldPeer = this.peerByPub.get(pubHex);
    const reconnect = oldPeer !== undefined && oldPeer !== peer;
    if (reconnect) this.pubByPeer.delete(oldPeer);

    this.pubByPeer.set(peer, pubHex);
    this.peerByPub.set(pubHex, peer);
    this.admitted.set(pubHex, role);

    // Adopt as host ONLY a peer whose token DECLARES role "host", and pin the
    // first one: a second host-declaring key is surfaced, never silently
    // swapped in (protocol doc 4.4, trust-on-first-use).
    if (!this.isHost && role === 'host') {
      if (this.hostPubHex === '') this.hostPubHex = pubHex;
      else if (this.hostPubHex !== pubHex)
        this.logLine(`WARN   ignored a second host-declaring key ${pubHex.slice(0, 12)}`);
    }

    if (isNew) this.logLine(`+peer  ${pubHex.slice(0, 12)}  (${role})`);

    if (this.isHost && (isNew || reconnect)) {
      this._replayTo(peer);
      if (isNew) this._emitRoster();
    }
    this.onChange();
  }

  _onMessage(peer, payload) {
    const i = payload.indexOf('\t');
    const kind = i < 0 ? payload : payload.slice(0, i);
    const rest = i < 0 ? '' : payload.slice(i + 1);

    switch (kind) {
      case 'c':
        if (this.isHost) this._relay(peer, rest);
        break;
      case 'w':
        this.ingest(rest);
        break;
      case 'r!': {
        // honored ONLY from the pinned host's live handle -- an unsigned
        // control frame from anyone else could suppress a victim's emissions
        // indefinitely (protocol doc 6.2 / 7.5)
        if (peer === this.peerByPub.get(this.hostPubHex) && /^\d+$/.test(rest)) {
          this.catchUpTo = Number(rest);
          this.logLine(`catch  replay to seq ${rest} announced`);
        }
        break;
      }
      case 's?': {
        const pub = this.pubByPeer.get(peer);
        if (!this.isHost || pub === undefined) break;
        const last = this.replayAt.get(pub) ?? -Infinity;
        if (this.now() - last < REPLAY_RATE_MS) break;   // per-peer rate limit
        this.replayAt.set(pub, this.now());
        this.logLine(`sync!  replaying transcript to ${pub.slice(0, 8)}`);
        this._replayTo(peer);
        break;
      }
    }
  }

  // ------------------------------------------------------------- host relay
  _relay(peer, contentAndSig) {
    const f = contentAndSig.split('\t');
    if (f.length < 7) return;
    const content = f.slice(0, 6).join('\t');
    const senderSig = f[6];
    const fromHex = f[3];
    const type = f[4];

    if (!P.isHex(fromHex, 64) || !P.isHex(senderSig, 128)) return;
    // host-authored presence must never be sequenced for a non-host sender
    if ((type === 'cfg' || type === 'roster') && fromHex !== this.hostPubHex) return;
    if (!P.verify(P.unhex(senderSig), P.sodium.from_string(content), P.unhex(fromHex))) return;
    if (!this.admitted.has(fromHex)) return;

    this.seqCounter += 1;
    const env = `${content}\t${senderSig}\t${this.seqCounter}\t${this.chainHead}`;
    const wire = `${env}\t${P.hex(P.sign(P.sodium.from_string(env), this.idSec))}`;
    this.tx.broadcast(`w\t${wire}`);
    this.ingest(wire);
  }

  _replayTo(peer) {
    this.tx.send(peer, `r!\t${this.lastSeq}`);
    for (const w of this.wireLog) this.tx.send(peer, `w\t${w}`);
  }

  _emitRoster() {
    if (!this.isHost) return;
    const members = [...this.admitted.entries()].map(([p, r]) => [p, r || 'player']);
    this.send('roster', P.rosterBody(members));
  }

  // ------------------------------------------------------------ emission
  send(type, body) {
    const content = P.contentLine(this.tableIdHex, this.handNum, this.idPubHex, type, body);
    const packet = `${content}\t${P.senderSigHex(content, this.idSec)}`;
    if (this.isHost) this._relay(null, packet);
    else this.tx.sendToHost(`c\t${packet}`);
  }

  _requestSync() {
    if (this.isHost || this.hostPubHex === '') return;
    if (this.now() - this.syncAskedAt < RESYNC_DEBOUNCE_MS) return;
    this.syncAskedAt = this.now();
    this.logLine('sync?  requested transcript replay (chain gap)');
    this.tx.sendToHost('s?');
  }

  // --------------------------------------------------------------- ingest
  // Protocol doc 7.2. Classify by seq against lastSeq -- NEVER by a bare
  // prev-vs-head test, or every redelivery becomes a "gap" and the client
  // resync-storms forever.
  ingest(wire) {
    const verdict = P.verifyWire(wire, '', this.hostPubHex, '');
    if (verdict !== 'ok') {
      this.logLine(`${verdict} ${wire.slice(0, 24)}`);
      return;
    }
    const a = P.parseWire(wire);
    if (a.table !== this.tableIdHex) { this.logLine('drop:wrong-table'); return; }
    if (a.v !== P.ENV_V) { this.logLine('drop:bad-version'); return; }
    if (!/^\d+$/.test(a.seq)) { this.logLine('drop:bad-seq'); return; }

    const seq = Number(a.seq);
    if (seq <= this.lastSeq) return;                    // duplicate: SILENT drop
    if (seq > this.lastSeq + 1) {
      if (seq <= this.lastSeq + WIRE_BUF_MAX && !this.buffer.has(seq))
        this.buffer.set(seq, wire);
      this.logLine(`gap    seq ${seq} held (need ${this.lastSeq + 1})`);
      this._requestSync();
      return;
    }
    if (a.prev !== this.chainHead) {
      this.logLine('drop:chain-break');
      this._requestSync();
      return;
    }
    this._apply(wire, a);
    this._drain();
    this.onChange();
  }

  _drain() {
    for (;;) {
      const next = this.lastSeq + 1;
      if (!this.buffer.has(next)) break;
      const w = this.buffer.get(next);
      this.buffer.delete(next);
      const a = P.parseWire(w);
      if (a.prev !== this.chainHead) break;   // no longer chains: leave for replay
      this._apply(w, a);
    }
  }

  _apply(wire, a) {
    this.chainHead = P.chainNext(wire);
    this.lastSeq = Number(a.seq);
    this.wireLog.push(wire);
    if (this.isHost) this.seqCounter = Math.max(this.seqCounter, this.lastSeq);

    // An unrostered sender's body does NOTHING. The chain still advances --
    // refusing a host-authentic link would wedge the table (protocol doc 7.4).
    if (a.from !== this.hostPubHex && !this._rosterHas(a.from)) {
      this.logLine(`note   unrostered sender ${a.from.slice(0, 8)} -- body ignored`);
      return;
    }

    const body = P.bodyText(a.bodyHex);
    if (a.type === 'roster' || a.type === 'cfg') {
      if (a.from !== this.hostPubHex) { this.logLine(`drop   non-host ${a.type} ignored`); return; }
      if (a.type === 'roster') this.rosterBody = body;
      else {
        this.cfgBody = body;
        const c = P.parseBody(body);
        for (const k of ['sb', 'bb', 'ante', 'stack'])
          if (c[k] !== undefined && /^\d+$/.test(c[k])) this.cfg[k] = Number(c[k]);
      }
      this.react();
      return;
    }
    this._foldGame(a.type, a.from, body, a.hand);
  }

  _rosterHas(pubHex) {
    if (!this.rosterBody) return false;
    return this.rosterBody.split(',').some((m) => m.split(':')[0] === pubHex);
  }

  // ------------------------------------------------ game fold (doc 8.1/8.3)
  _foldGame(type, from, bodyText, handTxt) {
    const b = P.parseBody(bodyText);
    const fromSeat = this.seatByPub.get(from) ?? 0;
    const num = (v) => (/^-?\d+$/.test(String(v)) ? Number(v) : null);
    const dealerPub = () => this.pubBySeat.get(this.deal.dealerSeat);

    switch (type) {
      case 'join': {
        if (P.isHex(b.box, 64)) {
          this.boxByPub.set(from, b.box);
          this.logLine(`join   ${from.slice(0, 8)} bound a session box key`);
        } else this.logLine('drop   join with a malformed box key');
        break;
      }

      case 'sit': {
        if (from !== this.hostPubHex) { this.logLine('drop   non-host sit'); break; }
        const seat = num(b.seat);
        if (seat === null || seat < 1 || seat > MAX_SEATS || !P.isHex(b.pub, 64)) {
          this.logLine('drop   malformed sit'); break;
        }
        this.seatByPub.set(b.pub, seat);
        this.pubBySeat.set(seat, b.pub);
        if (!this.seatedList.includes(seat)) {
          this.seatedList.push(seat);
          this.seatedList.sort((x, y) => x - y);
        }
        if (!this.stacksBy.has(seat)) this.stacksBy.set(seat, this.cfg.stack);
        this.gameOn = true;
        break;
      }

      case 'handStart': {
        if (from !== this.hostPubHex) { this.logLine('drop   non-host handStart'); break; }
        const occ = String(b.seats ?? '').split('|').map(Number).filter((n) => n > 0);
        const button = num(b.button);
        if (!occ.length || button === null) { this.logLine('drop   malformed handStart'); break; }
        this.deal = freshDeal();
        this.handNum = Number(handTxt);
        this.buttonSeat = button;
        const stacks = {};
        for (const s of occ) stacks[s] = this.stacksBy.get(s) ?? this.cfg.stack;
        this.state = E.newHand(this.cfg.sb, this.cfg.bb, stacks, occ, button, this.cfg.ante);
        this.lastBB = this.state.bbSeat;
        this.phase = 'hand';
        this.logLine(`hand   #${this.handNum} begins (button seat ${button})`);
        break;
      }

      case 'dealLevel': {
        if (from !== this.hostPubHex) { this.logLine('drop   non-host dealLevel'); break; }
        if (b.level !== '0') { this.logLine(`drop   unsupported deal level ${b.level}`); break; }
        const dealer = num(b.dealer), count = num(b.count);
        if (dealer === null || count === null) { this.logLine('drop   malformed dealLevel'); break; }
        this.deal.dealerSeat = dealer;
        this.deal.dealCount = count;
        break;
      }

      case 'seedCommit': {
        const pos = num(b.pos);
        if (pos === null || !P.isHex(b.commit, 64) || this._seatAtPos(pos) !== fromSeat || !fromSeat) {
          this.logLine('drop   bad seedCommit'); break;
        }
        if (!this.deal.commitsBy.has(pos)) { this.deal.commitsBy.set(pos, b.commit); }
        break;
      }

      case 'seedSeal': {
        const pos = num(b.pos);
        if (pos === null || !P.isHex(b.sealed) || this._seatAtPos(pos) !== fromSeat || !fromSeat) {
          this.logLine('drop   bad seedSeal'); break;
        }
        if (!this.deal.sealsBy.has(pos)) this.deal.sealsBy.set(pos, b.sealed);
        break;
      }

      case 'holeDeliver': {
        if (from !== dealerPub()) { this.logLine('drop   holeDeliver not from the dealer'); break; }
        const seat = num(b.seat);
        if (seat === null || !P.isHex(b.sealed)) { this.logLine('drop   malformed holeDeliver'); break; }
        if (!this.deal.holeSealedBy.has(seat)) this.deal.holeSealedBy.set(seat, b.sealed);
        if (seat === this.mySeat && !this.deal.myHoles) {
          const open = P.sealOpen(P.unhex(b.sealed), this.boxPub, this.boxSec);
          if (!open) { this.logLine('drop   holeDeliver would not open'); break; }
          const cards = P.sodium.to_string(open).split(',').map(Number);
          if (cards.length === 2 && cards.every((c) => Number.isInteger(c) && c >= 1 && c <= 52))
            this.deal.myHoles = cards;
          else this.logLine('drop   holeDeliver opened to garbage');
        }
        break;
      }

      case 'bidAnte': case 'bidSB': case 'bidBB': {
        if (!fromSeat) { this.logLine('drop   bid from an unseated key'); break; }
        this._engineFold(type, fromSeat, num(b.amount));
        break;
      }

      case 'act': {
        if (!fromSeat) { this.logLine('drop   act from an unseated key'); break; }
        this._engineFold('act', fromSeat, `${b.verb},${b.amount}`);
        break;
      }

      case 'board': {
        if (from !== dealerPub()) { this.logLine('drop   board not from the dealer'); break; }
        // street-vs-count dedupe: a doubled flop would shift every later slot
        // and corrupt the audit's board compare (protocol doc 8.4)
        const n = this.deal.board.length;
        const ok = (b.street === 'flop' && n === 0) || (b.street === 'turn' && n === 3)
                || (b.street === 'river' && n === 4);
        if (!ok) { this.logLine(`drop   out-of-order/duplicate board (${b.street})`); break; }
        const idx = String(b.cards ?? '').split('|').map((nm) => E.cardIndex(nm));
        const want = b.street === 'flop' ? 3 : 1;
        if (idx.length !== want || !idx.every((c) => Number.isInteger(c) && c >= 1 && c <= 52)) {
          this.logLine('drop   malformed board'); break;
        }
        this.deal.board.push(...idx);
        this._engineFold('board', 0, 0);
        break;
      }

      case 'seedReveal': {
        const pos = num(b.pos);
        if (pos === null || !P.isHex(b.seed, 64) || this._seatAtPos(pos) !== fromSeat || !fromSeat) {
          this.logLine('drop   bad seedReveal'); break;
        }
        // the reveal MUST open the commitment made before the deal
        if (P.seedCommitHex(b.seed) !== this.deal.commitsBy.get(pos)) {
          this.logLine(`AUDIT  seedReveal pos ${pos} does not match its commit`);
          break;
        }
        if (!this.deal.revealsBy.has(pos)) this.deal.revealsBy.set(pos, b.seed);
        break;
      }

      case 'settle': {
        if (from !== this.hostPubHex) { this.logLine('drop   non-host settle'); break; }
        if (this.deal.settleDone) break;
        const mine = this.computeSettleTxt();
        if (!mine) { this.logLine('drop   settle before the reveals completed'); break; }
        if (b.deltas !== mine) {
          // Refused OUTRIGHT: following a provably wrong host is worse than
          // stalling, and the transcript preserves the evidence either way.
          this.logLine(`SETTLE-MISMATCH host=${b.deltas} ours=${mine}`);
          this.disputed = true;
          break;
        }
        this._applySettle(b.deltas);
        break;
      }

      case 'receipt': {
        if (!fromSeat) { this.logLine('drop   receipt from an unseated key'); break; }
        if (!P.isHex(b.head, 64) || !P.isHex(b.sig, 128) || b.head !== this.rcptHead
            || !P.receiptSigVerify(b.sig, b.head, from)) {
          this.logLine(`drop   bad receipt from seat ${fromSeat}`); break;
        }
        if (!this.deal.receiptsBy.has(fromSeat)) this.deal.receiptsBy.set(fromSeat, b.sig);
        if (this.deal.receiptsBy.size >= this.deal.dealCount)
          this.logLine(`rcpt   hand ${this.handNum} receipt co-signed by all ${this.deal.receiptsBy.size} seats`);
        break;
      }

      case 'audit': {
        if (!fromSeat) { this.logLine('drop   audit from an unseated key'); break; }
        if (!this.deal.auditsBy.has(fromSeat)) this.deal.auditsBy.set(fromSeat, b.result);
        this.logLine(`audit  seat ${fromSeat}: ${b.result}`);
        break;
      }

      default:
        break;   // unknown type: the chain carries it, nothing acts on it
    }
    this.react();
  }

  _engineFold(type, seat, amount) {
    const next = E.apply(this.state, type, seat, amount);
    if (next.err) { this.logLine(`drop   engine-rejected ${type} ${next.err}`); return; }
    this.state = next;
    if (next.phase === 'runout') this.phase = 'runout';
    else if (next.phase === 'showdown' || next.phase === 'handdone') this.phase = 'showdown';
  }

  _seatAtPos(pos) { return this.state?.occ?.[pos - 1] ?? 0; }
  _posOfSeat(seat) { const i = this.state?.occ?.indexOf(seat) ?? -1; return i < 0 ? 0 : i + 1; }

  // ------------------------------------------------- the react ladder (9.3)
  // Emit ONLY what our seat owes next. Every emission is guarded TWICE: a
  // presence guard against the folded transcript (replay-proof) and a sent
  // flag (redelivery-proof).
  react() {
    // While a replay is streaming, every mid-replay state is HISTORICAL --
    // reacting would re-emit our whole history onto the live chain (7.5).
    if (this.catchUpTo !== null) {
      if (this.lastSeq < this.catchUpTo) return;
      this.catchUpTo = null;
    }

    // 1. bind our session box key once the roster lists us
    if (!this.joinSent && !this.boxByPub.has(this.idPubHex)
        && this.rosterBody.includes(this.idPubHex)) {
      this.joinSent = true;
      this.send('join', `box=${P.hex(this.boxPub)}`);
      return;
    }
    if (!this.gameOn || !this.state) return;

    const d = this.deal;
    const seat = this.mySeat;
    const pos = this._posOfSeat(seat);
    const count = d.dealCount;
    if (!count) return;

    // 2. our deal entropy: DERIVED, so a reconnect re-derives the exact seed
    // it committed and can still reveal (protocol doc 10.1)
    if (pos > 0 && !d.mySeedHex)
      d.mySeedHex = P.handSeedHex(this.idSeedHex, this.tableIdHex, this.handNum);

    if (pos > 0 && d.mySeedHex && !d.commitSent && !d.commitsBy.has(pos)) {
      d.commitSent = true;
      this.send('seedCommit', `pos=${pos},commit=${P.seedCommitHex(d.mySeedHex)}`);
      return;
    }

    // 3. seal our seed to the dealer -- only once EVERY commit is in, which is
    // what stops the dealer stacking (protocol doc 9.3 rule 1)
    if (pos > 0 && d.commitsBy.size >= count && !d.sealSent && !d.sealsBy.has(pos)) {
      const dealerBox = this.boxByPub.get(this.pubBySeat.get(d.dealerSeat));
      if (P.isHex(dealerBox, 64)) {
        d.sealSent = true;
        const sealed = P.seal(P.sodium.from_string(d.mySeedHex), P.unhex(dealerBox));
        this.send('seedSeal', `pos=${pos},sealed=${P.hex(sealed)}`);
        return;
      }
    }

    // 4. we deal this hand
    if (seat === d.dealerSeat && seat > 0 && d.sealsBy.size >= count && !d.dealerDeal) {
      if (this._dealerDeal()) return;
    }

    // 5. blinds, once every seat has its (sealed) holes
    if (d.holeSealedBy.size >= count && pos > 0 && this.state.phase === 'blinds') {
      const st = this.state;
      if (this.cfg.ante > 0 && !d.anteSent && st.antePostedBy?.[seat] !== 'true') {
        d.anteSent = true;
        this.send('bidAnte', `amount=${Math.min(this.cfg.ante, st.stackBy[seat])}`);
        return;
      }
      const allAntes = this.cfg.ante === 0
        || st.occ.every((s) => st.antePostedBy?.[s] === 'true');
      if (allAntes && seat === st.sbSeat && st.sbPosted !== 'true' && !d.sbSent) {
        d.sbSent = true;
        this.send('bidSB', `amount=${Math.min(st.sb, st.stackBy[seat])}`);
        return;
      }
      // the BB posts only after it SEES the SB fold, so the two forced posts
      // can never race in the relay's ordering (protocol doc 9.3 rule 3)
      if (st.sbPosted === 'true' && seat === st.bbSeat && !d.bbSent) {
        d.bbSent = true;
        this.send('bidBB', `amount=${Math.min(st.bb, st.stackBy[seat])}`);
        return;
      }
    }

    // 6. we deal this hand and a street is due
    if (seat === d.dealerSeat && seat > 0) {
      const st = this.state;
      const n = d.board.length;
      let street = '';
      if (st.phase === 'acting' || st.phase === 'runout') {
        if (n === 0 && (st.street !== 'preflop' || st.phase === 'runout')) street = 'flop';
        else if (n === 3 && (st.street === 'turn' || st.street === 'river' || st.phase === 'runout')) street = 'turn';
        else if (n === 4 && (st.street === 'river' || st.phase === 'runout')) street = 'river';
      }
      if (street) { this._dealerBoard(street); return; }
    }

    // 7. hand over: reveal our seed so everyone can audit
    const st = this.state;
    if ((st.phase === 'showdown' || st.phase === 'handdone') && pos > 0
        && !d.revealSent && !d.revealsBy.has(pos) && d.mySeedHex) {
      d.revealSent = true;
      this.send('seedReveal', `pos=${pos},seed=${d.mySeedHex}`);
      return;
    }

    // 8. host: settle once every seed is revealed
    if (this.isHost && d.revealsBy.size >= count && !d.settleSent
        && (st.phase === 'showdown' || st.phase === 'handdone')) {
      const deltas = this.computeSettleTxt();
      if (deltas) { d.settleSent = true; this.send('settle', `deltas=${deltas}`); return; }
    }

    // 9. co-sign the settlement receipt
    if (d.settleDone && pos > 0 && !d.receiptSent && !d.receiptsBy.has(seat)) {
      d.receiptSent = true;
      this.send('receipt', `head=${this.rcptHead},sig=${P.receiptSigHex(this.rcptHead, this.idSec)}`);
      return;
    }

    // 10. our audit verdict
    if (d.settleDone && pos > 0 && !d.auditSent && !d.auditsBy.has(seat)) {
      d.auditSent = true;
      this.send('audit', `result=${this.auditHand()}`);
      return;
    }
  }

  // ---------------------------------------------------------- retry pass
  // The sent-flags in react() are a DOUBLE-SEND guard, not a delivery
  // guarantee: react() fires after every applied wire, so without them one
  // owed emission would go out N times per cascade. But a flag that is never
  // cleared turns a single lost player->host frame into a wedged hand -- the
  // sender believes it has spoken, and nothing ever makes it speak again.
  //
  // The reference implementation has the same shape and gets away with it
  // because rp1 rides TCP peer connections, so the c-frame lane does not drop.
  // A web transport is not owed that assumption, so: whenever the chain is
  // quiet and the transcript still does not carry something we owe, clear the
  // flag and let react() say it again.
  //
  // This is safe precisely BECAUSE every emission is presence-guarded and the
  // fold side is idempotent (protocol doc 8.4) -- a duplicate that does land
  // is recorded once. It changes no wire bytes and no rules; call it on a
  // timer (a few seconds) in a live client.
  retryPass() {
    const d = this.deal;
    const st = this.state;
    const seat = this.mySeat;
    const pos = this._posOfSeat(seat);

    if (this.joinSent && !this.boxByPub.has(this.idPubHex)) this.joinSent = false;
    if (!st || !this.gameOn) { this.react(); return; }

    if (d.commitSent && pos > 0 && !d.commitsBy.has(pos)) d.commitSent = false;
    if (d.sealSent && pos > 0 && !d.sealsBy.has(pos)) d.sealSent = false;
    if (d.anteSent && st.antePostedBy?.[seat] !== 'true') d.anteSent = false;
    if (d.sbSent && st.sbPosted !== 'true') d.sbSent = false;
    if (d.bbSent && st.phase === 'blinds') d.bbSent = false;
    if (d.revealSent && pos > 0 && !d.revealsBy.has(pos)) d.revealSent = false;
    if (d.settleSent && !d.settleDone) d.settleSent = false;
    if (d.receiptSent && seat > 0 && !d.receiptsBy.has(seat)) d.receiptSent = false;
    if (d.auditSent && seat > 0 && !d.auditsBy.has(seat)) d.auditSent = false;

    // dealer: a lost holeDeliver leaves that seat unserved. Re-send only the
    // missing seats -- the deck is already derived and must not be re-derived.
    if (seat === d.dealerSeat && d.dealerDeal) {
      for (const s of st.occ) {
        if (d.holeSealedBy.has(s)) continue;
        const box = this.boxByPub.get(this.pubBySeat.get(s));
        if (!P.isHex(box, 64)) continue;
        const sealed = P.seal(P.sodium.from_string(d.dealerDeal.holes[s].join(',')),
                              P.unhex(box));
        this.send('holeDeliver', `seat=${s},sealed=${P.hex(sealed)}`);
      }
    }
    // a lost dealer board wire: react()'s street check is presence-driven
    // (board length vs street), so it re-emits on its own.
    this.react();
  }

  // -------------------------------------------------------- dealer duties
  _dealerDeal() {
    const d = this.deal;
    const seeds = [];
    for (let pos = 1; pos <= d.dealCount; pos++) {
      const sealed = d.sealsBy.get(pos);
      const open = sealed ? P.sealOpen(P.unhex(sealed), this.boxPub, this.boxSec) : null;
      const seedHex = open ? P.sodium.to_string(open) : '';
      // MUST abort rather than deal from a seed set that failed its
      // commitments -- and name the position (protocol doc 10.8)
      if (!P.isHex(seedHex, 64) || P.seedCommitHex(seedHex) !== d.commitsBy.get(pos)) {
        this.logLine(`AUDIT  seal at pos ${pos} bad or commit-mismatched -- deal aborted`);
        return false;
      }
      seeds.push(seedHex);
    }
    const deck = P.level0Deck(P.unhex(this.tableIdHex), this.handNum, seeds);
    d.dealerDeal = P.dealAssign(deck, this.state.occ, this.buttonSeat);

    for (const s of this.state.occ) {
      // presence-guarded per seat: a reconnected dealer re-derives the deck
      // but never re-sends a delivery the transcript already carries
      if (d.holeSealedBy.has(s)) continue;
      const box = this.boxByPub.get(this.pubBySeat.get(s));
      if (!P.isHex(box, 64)) continue;
      const pair = d.dealerDeal.holes[s].join(',');
      const sealed = P.seal(P.sodium.from_string(pair), P.unhex(box));
      this.send('holeDeliver', `seat=${s},sealed=${P.hex(sealed)}`);
    }
    return true;
  }

  _dealerBoard(street) {
    const d = this.deal;
    if (!d.dealerDeal) return;
    const idx = street === 'flop' ? d.dealerDeal.flop
      : street === 'turn' ? [d.dealerDeal.turn] : [d.dealerDeal.river];
    this.send('board', `street=${street},cards=${idx.map(E.cardName).join('|')}`);
  }

  // ------------------------------------------------------------ settlement
  revealedDeal() {
    const d = this.deal;
    if (!d.dealCount || d.revealsBy.size < d.dealCount) return null;
    const seeds = [];
    for (let pos = 1; pos <= d.dealCount; pos++) seeds.push(d.revealsBy.get(pos));
    const deck = P.level0Deck(P.unhex(this.tableIdHex), this.handNum, seeds);
    return P.dealAssign(deck, this.state.occ, this.buttonSeat);
  }

  // Showdown ranks come from the REVEALED deck, never from a player's claim
  // about its own hand (protocol doc 13.1).
  computeSettleTxt() {
    const deal = this.revealedDeal();
    if (!deal) return '';
    const st = this.state;
    const inHand = E.inHandList(st);
    const ranks = {};
    if (inHand.length > 1)
      for (const s of inHand)
        ranks[s] = E.eval7([...deal.holes[s], ...deal.flop, deal.turn, deal.river]);
    const deltas = E.settle(st, ranks);
    return st.occ.map((s) => `${s}:${deltas[s]}`).join('|');
  }

  _applySettle(deltasTxt) {
    for (const pair of deltasTxt.split('|')) {
      const [s, v] = pair.split(':');
      if (/^\d+$/.test(s) && /^-?\d+$/.test(v))
        this.stacksBy.set(Number(s), (this.stacksBy.get(Number(s)) ?? 0) + Number(v));
    }
    // settleHash binds the deltas to the chain head AFTER this settle wire
    const csv = deltasTxt.replaceAll('|', ',');
    const sh = P.settleHashHex(csv, P.unhex(this.chainHead));
    this.rcptHead = P.receiptHeadHex(sh, this.rcptHead);
    this.deal.settleDone = true;
    this.phase = 'between';
    this.logLine(`settle hand ${this.handNum}: ${deltasTxt}`);
  }

  auditHand() {
    const deal = this.revealedDeal();
    if (!deal) return 'fail:reveals-incomplete';
    const d = this.deal;
    for (let pos = 1; pos <= d.dealCount; pos++) {
      const seed = d.revealsBy.get(pos);
      if (P.seedCommitHex(seed) !== d.commitsBy.get(pos))
        return `fail:commit-mismatch-position-${pos}`;
    }
    // check what we WITNESSED: our own delivered holes, and the wired board
    if (this.mySeat > 0 && d.myHoles) {
      const want = deal.holes[this.mySeat];
      if (!want || want.join(',') !== d.myHoles.join(','))
        return `fail:hole-mismatch-seat-${this.mySeat}`;
    }
    if (d.board.length >= 3 && d.board.slice(0, 3).join(',') !== deal.flop.join(','))
      return 'fail:flop-mismatch';
    if (d.board.length >= 4 && d.board[3] !== deal.turn) return 'fail:turn-mismatch';
    if (d.board.length >= 5 && d.board[4] !== deal.river) return 'fail:river-mismatch';
    return 'pass';
  }

  // ------------------------------------------------------------ host actions
  // Seats are assigned in ascending-pubkey order: deterministic, so every
  // client could re-derive it; the sit wires make it explicit and signed.
  startGame() {
    if (!this.isHost || this.gameOn) return { ok: false, why: 'not host, or already started' };
    const joined = [...this.boxByPub.keys()].filter((p) => this.admitted.has(p)).sort();
    if (joined.length < 2) return { ok: false, why: `need 2 joined players (have ${joined.length})` };
    if (joined.length > MAX_SEATS) return { ok: false, why: 'too many players' };
    joined.forEach((pub, i) => this.send('sit', `seat=${i + 1},pub=${pub}`));
    this.handKick();
    return { ok: true };
  }

  handKick() {
    if (!this.isHost) return;
    const occ = this.seatedList.filter((s) => (this.stacksBy.get(s) ?? 0) > 0);
    if (occ.length < 2) { this.logLine('Game over -- one stack left.'); return false; }
    const button = E.scheduleButton(occ, this.lastBB);
    this.handNum += 1;
    this.send('handStart', `seats=${occ.join('|')},button=${button}`);
    this.send('dealLevel', `level=0,dealer=${button},count=${occ.length}`);
    return true;
  }

  // a seated player's own action
  act(verb, amount = 0) {
    if (!this.state || this.state.toAct !== this.mySeat) return false;
    this.send('act', `verb=${verb},amount=${amount}`);
    return true;
  }

  legalActions() {
    if (!this.state) return [];
    return E.betLegal(this.state, this.mySeat);
  }
}

function freshDeal() {
  return {
    commitsBy: new Map(), sealsBy: new Map(), holeSealedBy: new Map(),
    revealsBy: new Map(), receiptsBy: new Map(), auditsBy: new Map(),
    board: [], myHoles: null, mySeedHex: '', dealerDeal: null,
    dealerSeat: 0, dealCount: 0,
    commitSent: false, sealSent: false, anteSent: false, sbSent: false,
    bbSent: false, revealSent: false, settleSent: false, receiptSent: false,
    auditSent: false, settleDone: false,
  };
}
