// Headless multi-client table simulation -- the end-to-end proof.
//
// Spins up N independent Table clients over the loopback bus and plays real
// hands: signed envelopes, the hash chain, the Level 0 committed deal with
// sealed seeds and sealed hole cards, betting through the verified engine,
// board wires, seed reveals, settlement, co-signed receipts, and per-client
// audits. Nothing is stubbed -- every client verifies every signature and
// folds the same chain independently, exactly as it would over a real socket.
//
// --lossy runs the identical code over a transport that DROPS, DUPLICATES,
// and REORDERS payloads, because surviving all three is the entire job of the
// ingest rules in protocol doc section 7.
//
//   node table-sim.mjs [--players N] [--hands H] [--lossy] [--quiet]

import * as P from './holdem-protocol.mjs';
import { Table } from './client.mjs';
import { LoopbackBus } from './transport.mjs';

const arg = (name, dflt) => {
  const i = process.argv.indexOf(name);
  return i < 0 ? dflt : Number(process.argv[i + 1]);
};
const PLAYERS = arg('--players', 3);
const HANDS = arg('--hands', 3);
const START_STACK = 200;
const LOSSY = process.argv.includes('--lossy');
const QUIET = process.argv.includes('--quiet');

// deterministic RNG so any failure is reproducible
let seed = 0x2026_0805 >>> 0;
const rng = () => {
  seed ^= seed << 13; seed >>>= 0;
  seed ^= seed >> 17;
  seed ^= seed << 5; seed >>>= 0;
  return seed / 0x1_0000_0000;
};

let fails = 0;
const check = (label, cond, detail = '') => {
  if (cond) { if (!QUIET) console.log(`PASS  ${label}`); }
  else { fails++; console.log(`FAIL  ${label}${detail ? '\n      ' + detail : ''}`); }
};

// Virtual clock. The client's resync debounce and per-peer replay rate limit
// are wall-clock rules that MUST stay -- they are what stops a flood of resync
// requests amplifying into unbounded replays (protocol doc 6.2). But a sim
// runs a whole session in microseconds, so in real time those timers never
// expire and a client that falls behind could never re-ask. Advancing a
// virtual clock between rounds is what lets recovery actually run.
let vclock = 0;
const now = () => vclock;

await P.ready();

const bus = new LoopbackBus(LOSSY
  ? { dropRate: 0.06, dupRate: 0.10, reorder: true, rng }
  : { dupRate: 0.05, rng });

// --- build the table: client 0 hosts, the rest join ---
const tables = [];
for (let i = 0; i < PLAYERS; i++) {
  const port = bus.port();
  const t = new Table({
    idSeed: P.H(P.sodium.from_string(`holde-em sim identity ${i}`)),
    transport: port,
    isHost: i === 0,
    tableIdHex: i === 0 ? undefined : tables[0].tableIdHex,
    cfg: { sb: 1, bb: 2, ante: 0, stack: START_STACK },
    log: (m) => { if (!QUIET && i === 0) console.log(`   [host] ${m}`); },
    now,
  });
  t._port = port;
  tables.push(t);
}
const host = tables[0];
for (const t of tables) t._port.hostPeer = host._port.id;

// One recovery round: advance past the debounce windows, let every client
// re-emit whatever the transcript still does not carry, and let anyone behind
// the host ask for a replay. This is what a live client does on a timer.
function round(all = tables) {
  vclock += 2500;
  for (const t of all) t.retryPass();
  for (const t of all) if (t.lastSeq < host.lastSeq) t._requestSync();
  bus.pump();
}

// Drive until every client has caught up to the host and the bus is quiet.
// Convergence here is EVENTUAL, not instantaneous -- under loss a client is
// legitimately a few wires behind at any given instant, and asserting before
// quiescence tests the sim's timing rather than the protocol.
function converge(maxRounds = 400) {
  for (let i = 0; i < maxRounds; i++) {
    bus.pump();
    if (bus.queue.length === 0 && tables.every((t) => t.lastSeq === host.lastSeq))
      return true;
    round();
  }
  return false;
}

for (const t of tables) t.start();
bus.connectAll();
converge();

check('every client adopted the host key',
  tables.every((t) => t.hostPubHex === host.idPubHex));
check('every client folded the signed cfg',
  tables.every((t) => t.cfgBody === host.cfgBodyText()),
  tables.map((t) => t.cfgBody).join(' | '));
check(`all ${PLAYERS} players published a session box key`,
  host.boxByPub.size === PLAYERS, `have ${host.boxByPub.size}`);

// --- play ---
const started = host.startGame();
check('host started the game', started.ok, started.why);
converge();

let handsPlayed = 0;
let eliminated = false;

for (let h = 0; h < HANDS; h++) {
  let guard = 0;
  while (guard++ < 6000) {
    bus.pump();
    const st = host.state;
    if (!st) break;

    if (st.phase === 'acting') {
      const seat = st.toAct;
      const who = tables.find((t) => t.mySeat === seat);
      if (!who) { round(); continue; }
      // the acting client may itself be lagging: let it catch up first
      if (who.state?.toAct !== seat || who.state?.phase !== 'acting') { round(); continue; }
      const legal = who.legalActions();
      if (!legal.length) { round(); continue; }
      const pick = legal[Math.floor(rng() * legal.length)];
      const [verb, ...rest] = pick.split(' ');
      let amt = 0;
      if (verb === 'call' || verb === 'allin') amt = Number(rest[0]);
      else if (verb === 'bet' || verb === 'raise') {
        const lo = Number(rest[0]), hi = Number(rest[1]);
        amt = rng() < 0.75 ? lo : lo + Math.floor(rng() * (hi - lo + 1));
      }
      who.act(verb, amt);
      bus.pump();
      // under loss the action itself can vanish; a round re-drives everything
      if (host.state?.toAct === seat && host.state?.phase === 'acting') round();
      continue;
    }

    if (host.deal.settleDone) break;

    // nobody to act: the deal / reveal / settle ladder is running on its own
    const before = tables.map((t) => t.lastSeq).join(',');
    round();
    if (before === tables.map((t) => t.lastSeq).join(',')
        && !host.deal.settleDone && bus.queue.length === 0) {
      // one genuinely idle round is not proof of a wedge under a lossy bus;
      // give it a few more before declaring the hand stuck
      let stuck = true;
      for (let k = 0; k < 8; k++) {
        round();
        if (tables.map((t) => t.lastSeq).join(',') !== before) { stuck = false; break; }
      }
      if (stuck) break;
    }
  }
  converge();

  if (!host.deal.settleDone) {
    check(`hand ${h + 1} completed`, false,
      `phase=${host.state?.phase} commits=${host.deal.commitsBy.size} ` +
      `seals=${host.deal.sealsBy.size} holes=${host.deal.holeSealedBy.size} ` +
      `reveals=${host.deal.revealsBy.size}`);
    break;
  }
  handsPlayed++;

  // --- the invariants, checked on EVERY client independently ---
  check(`hand ${h + 1}: all clients agree on the chain head`,
    new Set(tables.map((t) => t.chainHead)).size === 1,
    tables.map((t) => `${t.mySeat}:${t.chainHead.slice(0, 10)}`).join(' '));

  check(`hand ${h + 1}: all clients applied the same seq`,
    new Set(tables.map((t) => t.lastSeq)).size === 1,
    tables.map((t) => t.lastSeq).join(' vs '));

  const stackSets = tables.map((t) =>
    [...t.stacksBy.entries()].sort((a, b) => a[0] - b[0]).map(([s, v]) => `${s}:${v}`).join(','));
  check(`hand ${h + 1}: all clients agree on stacks`,
    new Set(stackSets).size === 1, stackSets.join(' | '));

  const total = [...host.stacksBy.values()].reduce((a, b) => a + b, 0);
  check(`hand ${h + 1}: chips conserved (${total})`, total === PLAYERS * START_STACK,
    `expected ${PLAYERS * START_STACK}`);

  check(`hand ${h + 1}: receipt chain agrees`,
    new Set(tables.map((t) => t.rcptHead)).size === 1);
  check(`hand ${h + 1}: receipt co-signed by every seat`,
    host.deal.receiptsBy.size === host.deal.dealCount,
    `${host.deal.receiptsBy.size}/${host.deal.dealCount}`);

  const verdicts = [...host.deal.auditsBy.values()];
  check(`hand ${h + 1}: every audit verdict is pass`,
    verdicts.length > 0 && verdicts.every((v) => v === 'pass'), verdicts.join(','));

  check(`hand ${h + 1}: nobody flagged a settlement dispute`,
    tables.every((t) => !t.disputed));

  const gotHoles = tables.filter((t) => t.mySeat > 0 && t.deal.myHoles?.length === 2).length;
  check(`hand ${h + 1}: every seat opened its sealed hole cards`,
    gotHoles === host.deal.dealCount, `${gotHoles}/${host.deal.dealCount}`);

  if (h < HANDS - 1) {
    // handKick returning false is a legitimate game over (a player busted),
    // not a failure -- heads-up with equal stacks, one all-in ends the match
    if (!host.handKick()) { eliminated = true; break; }
    converge();
  }
}

check(`played ${HANDS} hands (or ended on an elimination)`,
  handsPlayed === HANDS || eliminated,
  `played ${handsPlayed}, eliminated=${eliminated}`);

// --- a late joiner must converge from the transcript alone (protocol doc 9.4) ---
{
  const port = bus.port();
  port.hostPeer = host._port.id;
  const late = new Table({
    idSeed: P.H(P.sodium.from_string('holde-em sim latecomer')),
    transport: port, isHost: false, tableIdHex: host.tableIdHex, log: () => {}, now,
  });
  late._port = port;
  tables.push(late);
  late.start();
  bus.connectAll();
  converge();
  check('a late joiner replays to the same chain head', late.chainHead === host.chainHead,
    `${late.chainHead.slice(0, 12)} vs ${host.chainHead.slice(0, 12)}`);
  check('a late joiner derives the same stacks',
    [...late.stacksBy.entries()].sort().join() === [...host.stacksBy.entries()].sort().join());
}

// --- adversarial: settle handling ---
// Two DISTINCT guards, tested separately, because the first masks the second:
// once a hand is settled a further settle is ignored outright (idempotence),
// so the mismatch branch is only reachable while no settle has been accepted.
if (handsPlayed > 0) {
  const victim = tables[1];
  const lie = victim.state.occ.map((s, i) => `${s}:${i === 0 ? 9999 : -1}`).join('|');

  const before1 = [...victim.stacksBy.entries()].sort().join();
  victim._foldGame('settle', victim.hostPubHex, `deltas=${lie}`, String(victim.handNum));
  check('a settle for an already-settled hand is ignored',
    [...victim.stacksBy.entries()].sort().join() === before1);
  check('...and it does not raise a false dispute', !victim.disputed);

  victim.deal.settleDone = false;
  const honest = victim.computeSettleTxt();
  check('the victim can recompute the hand settlement itself', honest !== '');
  const before2 = [...victim.stacksBy.entries()].sort().join();
  victim._foldGame('settle', victim.hostPubHex, `deltas=${lie}`, String(victim.handNum));
  check('a lying host settle moves no chips',
    [...victim.stacksBy.entries()].sort().join() === before2);
  check('a lying host settle is flagged as disputed', victim.disputed === true);
  check('a lying host settle does not complete the hand', !victim.deal.settleDone);

  // the honest settle, at that same point, IS accepted
  victim.disputed = false;
  victim._foldGame('settle', victim.hostPubHex, `deltas=${honest}`, String(victim.handNum));
  check('the HONEST settle at that same point is accepted', victim.deal.settleDone === true);
}

// --- adversarial: an out-of-turn act is engine-rejected on fold ---
if (host.state) {
  const before = JSON.stringify(host.state);
  const notTurn = host.state.occ.find((s) => s !== host.state.toAct);
  host._foldGame('act', host.pubBySeat.get(notTurn) ?? '', 'verb=raise,amount=999',
                 String(host.handNum));
  check('an out-of-turn act changes no engine state', JSON.stringify(host.state) === before);
}

// --- adversarial: a forged wire is refused ---
{
  const good = host.wireLog[host.wireLog.length - 1];
  const f = good.split('\t');
  f[5] = P.hex(P.sodium.from_string('deltas=1:99999'));   // tamper the body
  const victim = tables[1];
  const seqBefore = victim.lastSeq;
  victim.ingest(f.join('\t'));
  check('a wire with a tampered body is refused', victim.lastSeq === seqBefore);
}

console.log(`\nbus: ${bus.delivered} delivered, ${bus.dropped} dropped, ` +
            `${bus.duplicated} duplicated` +
            (LOSSY ? '  (lossy: 6% drop, 10% dup, reordering)' : '  (5% dup)'));
console.log(`${fails ? 'FAILED' : 'ALL PASS'} -- ${PLAYERS} players, ` +
            `${handsPlayed} hand(s), ${fails} failure(s)`);
process.exit(fails ? 1 : 0);
