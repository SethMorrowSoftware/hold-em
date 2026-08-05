// holde-em game engine -- JS port of the pure rules layer.
//
// Ports HOLDEM-PROTOCOL.md sections 11 (cards + evaluator), 12 (betting), and
// 13.1 (settlement). Every function here is PURE: values in, values out, no
// transport, no UI, no clock. That is what makes it machine-checkable, and
// web/engine-conformance.mjs checks it differentially against the Python
// mirror in tools/betting-kat.py over tens of thousands of generated hands.
//
// STATE SHAPE NOTE: booleans live as the strings "true"/"false", and seat maps
// are plain objects keyed by seat number. That is deliberate -- it mirrors the
// xTalk reference (where custom properties are text) and the Python mirror
// exactly, so a differential comparison is a straight deep-equal with nothing
// to normalize. The UI layer converts at its own boundary.

// ------------------------------------------------------------------- cards
export const RANKS = '23456789TJQKA';
export const SUITS = 'cdhs';

export const cardRank = (i) => ((i - 1) >> 2) + 2;      // 2..14, ace high
export const cardSuit = (i) => ((i - 1) % 4) + 1;       // 1..4
export const cardName = (i) => RANKS[(i - 1) >> 2] + SUITS[(i - 1) % 4];
export const cardIndex = (n) => RANKS.indexOf(n[0]) * 4 + SUITS.indexOf(n[1]) + 1;

const two = (n) => String(n).padStart(2, '0');

// ---------------------------------------------------------------- evaluator
// 12-char packed decimal: six 2-digit fields, category then five tiebreaks.
// Fixed width means plain string comparison orders hands (protocol doc 11.2).
export function rank5(five) {
  const ranks = five.map(cardRank).sort((a, b) => b - a);
  const suits = five.map(cardSuit);

  const flush = suits.every((s) => s === suits[0]);

  const distinct = [...new Set(ranks)];
  let highStraight = 0;
  if (distinct.length === 5) {
    if (distinct[0] - distinct[4] === 4) highStraight = distinct[0];
    else if (distinct.join(',') === '14,5,4,3,2') highStraight = 5;   // the wheel
  }

  if (flush && highStraight > 0) return '08' + two(highStraight) + '00000000';

  // histogram, sorted by (count, rank) descending via a single precomputed key
  const counts = new Map();
  for (const r of ranks) counts.set(r, (counts.get(r) || 0) + 1);
  const groups = [...counts.entries()]
    .map(([r, c]) => ({ key: c * 100 + r, c, r }))
    .sort((a, b) => b.key - a.key);
  const sizes = groups.map((g) => g.c);
  const gRanks = groups.map((g) => g.r);

  if (sizes[0] === 4) return '07' + two(gRanks[0]) + two(gRanks[1]) + '000000';
  if (sizes[0] === 3 && sizes[1] === 2) return '06' + two(gRanks[0]) + two(gRanks[1]) + '000000';
  if (flush) return '05' + ranks.map(two).join('');
  if (highStraight > 0) return '04' + two(highStraight) + '00000000';
  if (sizes[0] === 3) return '03' + two(gRanks[0]) + two(gRanks[1]) + two(gRanks[2]) + '0000';
  if (sizes[0] === 2 && sizes[1] === 2)
    return '02' + two(gRanks[0]) + two(gRanks[1]) + two(gRanks[2]) + '0000';
  if (sizes[0] === 2)
    return '01' + two(gRanks[0]) + two(gRanks[1]) + two(gRanks[2]) + two(gRanks[3]) + '00';
  return '00' + ranks.map(two).join('');
}

// best 5 of 7 by exhaustive 21-combination scan -- the dumbest correct
// algorithm, identical to both mirrors, nothing clever to get wrong
export function eval7(seven) {
  let best = '';
  for (let a = 0; a < 6; a++)
    for (let b = a + 1; b < 7; b++) {
      const five = seven.filter((_, i) => i !== a && i !== b);
      const r = rank5(five);
      if (best === '' || r > best) best = r;
    }
  return best;
}

// ------------------------------------------------------------- seat helpers
export const nextIn = (list, entry) => list[(list.indexOf(entry) + 1) % list.length];

export function rotateAfter(list, entry) {
  const i = list.indexOf(entry);
  return list.slice(i + 1).concat(list.slice(0, i + 1));
}

export const inHandList = (st) => st.occ.filter((s) => st.foldedBy[s] === 'false');

const pending = (st, s) => {
  if (st.foldedBy[s] === 'true' || st.allinBy[s] === 'true') return false;
  if (st.streetBy[s] < st.betCur) return true;
  return st.actedBy[s] === 'false';
};

const nextPending = (st, after) => rotateAfter(st.occ, after).find((s) => pending(st, s)) ?? 0;

const liveCount = (st) =>
  st.occ.filter((s) => st.foldedBy[s] === 'false' && st.allinBy[s] === 'false').length;

const firstInHandAfter = (st, after) =>
  rotateAfter(st.occ, after).find((s) => st.foldedBy[s] === 'false') ?? 0;

const clone = (st) => structuredClone(st);

function pay(st, s, amount) {
  st.stackBy[s] -= amount;
  st.streetBy[s] += amount;
  st.handBy[s] += amount;
  if (st.stackBy[s] === 0) st.allinBy[s] = 'true';
}

// antes: pot (handBy) only, NEVER the street bet, so an ante does not reduce
// what a seat still owes to call the blind (protocol doc 12.2)
function payDead(st, s, amount) {
  st.stackBy[s] -= amount;
  st.handBy[s] += amount;
  if (st.stackBy[s] === 0) st.allinBy[s] = 'true';
}

// ------------------------------------------------------------ hand creation
export function newHand(sb, bb, stacks, occ, button, ante = 0) {
  const st = {
    sb, bb, ante, occ: [...occ], buttonSeat: button,
    street: 'preflop', phase: 'blinds', toAct: 0,
    betCur: 0, raiseFull: bb, aggressor: 0, sdFirst: 0,
    err: '', note: '',
    stackBy: {}, streetBy: {}, handBy: {},
    foldedBy: {}, allinBy: {}, actedBy: {},
  };
  for (const s of occ) {
    st.stackBy[s] = stacks[s];
    st.streetBy[s] = 0;
    st.handBy[s] = 0;
    st.foldedBy[s] = 'false';
    st.allinBy[s] = 'false';
    st.actedBy[s] = 'false';
  }
  // heads-up: the button IS the small blind (protocol doc 12.1)
  st.sbSeat = occ.length === 2 ? button : nextIn(occ, button);
  st.bbSeat = nextIn(occ, st.sbSeat);
  return st;
}

const NEXT_STREET = { preflop: 'flop', flop: 'turn', turn: 'river' };

function closeStreet(st) {
  st.sdFirst = st.aggressor > 0 ? st.aggressor : firstInHandAfter(st, st.buttonSeat);
  for (const s of st.occ) { st.streetBy[s] = 0; st.actedBy[s] = 'false'; }
  st.betCur = 0;
  st.raiseFull = st.bb;
  st.aggressor = 0;
  if (st.street === 'river') {
    st.phase = 'showdown'; st.toAct = 0; st.note += 'showdown\n';
    return st;
  }
  if (liveCount(st) <= 1) {
    st.phase = 'runout'; st.toAct = 0; st.note += 'runout\n';
    return st;
  }
  st.street = NEXT_STREET[st.street];
  st.toAct = nextPending(st, st.buttonSeat);
  st.phase = 'acting';
  st.note += `advance:${st.street}\n`;
  return st;
}

function afterAction(st, s) {
  const nxt = nextPending(st, s);
  if (nxt === 0) return closeStreet(st);
  st.toAct = nxt;
  return st;
}

// ------------------------------------------------------ THE transition function
// Returns the next state. On any illegal message `err` is set and the state is
// otherwise unchanged -- callers MUST check err and drop, never fold a
// rejected message (protocol doc 12).
export function apply(state, mtype, seat, amount) {
  const st = clone(state);
  st.err = '';
  st.note = '';

  if (mtype === 'bidAnte') {
    if (st.phase !== 'blinds') { st.err = 'bidAnte-out-of-phase'; return st; }
    if (!st.occ.includes(seat)) { st.err = 'bidAnte-wrong-seat'; return st; }
    if (st.antePostedBy?.[seat] === 'true') { st.err = 'bidAnte-duplicate'; return st; }
    const p = Math.min(st.ante, st.stackBy[seat]);
    if (amount !== p) { st.err = 'bidAnte-wrong-amount'; return st; }
    payDead(st, seat, p);
    (st.antePostedBy ??= {})[seat] = 'true';
    return st;
  }

  if (mtype === 'bidSB') {
    if (st.phase !== 'blinds') { st.err = 'bidSB-out-of-phase'; return st; }
    if (seat !== st.sbSeat) { st.err = 'bidSB-wrong-seat'; return st; }
    if (st.sbPosted === 'true') { st.err = 'bidSB-duplicate'; return st; }
    const p = Math.min(st.sb, st.stackBy[seat]);
    if (amount !== p) { st.err = 'bidSB-wrong-amount'; return st; }
    pay(st, seat, p);
    st.sbPosted = 'true';
    return st;
  }

  if (mtype === 'bidBB') {
    if (st.phase !== 'blinds') { st.err = 'bidBB-out-of-phase'; return st; }
    if (seat !== st.bbSeat) { st.err = 'bidBB-wrong-seat'; return st; }
    const p = Math.min(st.bb, st.stackBy[seat]);
    if (amount !== p) { st.err = 'bidBB-wrong-amount'; return st; }
    pay(st, seat, p);
    st.betCur = st.bb;          // the BB is the opening bet even when posted short
    st.raiseFull = st.bb;
    st.phase = 'acting';
    return afterAction(st, seat);
  }

  if (mtype === 'board') {
    if (st.phase === 'runout') {
      st.street = NEXT_STREET[st.street] ?? st.street;
      if (st.street === 'river') { st.phase = 'showdown'; st.note += 'showdown\n'; }
    }
    return st;
  }

  if (mtype !== 'act') { st.err = 'unknown-message:' + mtype; return st; }

  // act: amount is "verb,amount" text (the wire form)
  const parts = String(amount).split(',');
  const verb = parts[0];
  let amt = parts.length > 1 ? parts[1] : '0';
  if (amt === '' || amt === undefined || amt === null) amt = 0;
  else { const f = Number(amt); amt = Number.isFinite(f) ? f : null; }

  if (st.phase !== 'acting') { st.err = 'act-out-of-phase'; return st; }
  if (seat !== st.toAct) { st.err = 'act-out-of-turn'; return st; }

  if (verb === 'fold') {
    st.foldedBy[seat] = 'true';
    st.actedBy[seat] = 'true';
    const still = inHandList(st);
    if (still.length === 1) {
      st.phase = 'handdone'; st.toAct = 0; st.note += `foldwin:${still[0]}\n`;
      return st;
    }
    return afterAction(st, seat);
  }

  if (verb === 'check') {
    if (st.streetBy[seat] < st.betCur) { st.err = 'check-facing-bet'; return st; }
    st.actedBy[seat] = 'true';
    return afterAction(st, seat);
  }

  if (verb === 'call') {
    const owe = st.betCur - st.streetBy[seat];
    if (owe <= 0) { st.err = 'call-nothing-to-call'; return st; }
    const p = Math.min(owe, st.stackBy[seat]);
    if (amt !== p) { st.err = 'call-wrong-amount'; return st; }
    pay(st, seat, p);
    st.actedBy[seat] = 'true';
    return afterAction(st, seat);
  }

  if (verb === 'bet' || verb === 'raise' || verb === 'allin') {
    let target;
    if (verb === 'allin') {
      target = st.streetBy[seat] + st.stackBy[seat];
      if (amt !== target) { st.err = 'allin-wrong-amount'; return st; }
      if (target <= st.betCur) {
        // an all-in that cannot even match the bet is a call for less
        pay(st, seat, st.stackBy[seat]);
        st.actedBy[seat] = 'true';
        return afterAction(st, seat);
      }
    } else {
      // integer-only wagers: a fractional target flows into settle()'s div/mod
      // chip accounting and MINTS chips, and the replay audit would then stamp
      // the minting hand clean (protocol doc 12.3)
      if (amt === null || amt !== Math.trunc(amt)) { st.err = 'act-bad-amount'; return st; }
      target = Math.trunc(amt);
      if (verb === 'bet' && st.betCur > 0) { st.err = 'bet-facing-bet-use-raise'; return st; }
      if (verb === 'raise' && st.betCur === 0) { st.err = 'raise-nothing-to-raise-use-bet'; return st; }
    }
    if (target <= st.betCur) { st.err = 'raise-not-above-bet'; return st; }
    const p = target - st.streetBy[seat];
    if (p > st.stackBy[seat]) { st.err = 'raise-beyond-stack'; return st; }
    const isAllin = p === st.stackBy[seat];
    const increment = target - st.betCur;
    if (increment < st.raiseFull && !isAllin) { st.err = 'raise-below-minimum'; return st; }
    if (st.actedBy[seat] === 'true') { st.err = 'raise-not-reopened'; return st; }
    pay(st, seat, p);
    st.betCur = target;
    st.aggressor = seat;
    st.actedBy[seat] = 'true';
    if (increment >= st.raiseFull) {
      // a FULL raise reopens action for everyone else
      st.raiseFull = increment;
      for (const s of st.occ) if (s !== seat) st.actedBy[s] = 'false';
    }
    return afterAction(st, seat);
  }

  st.err = 'unknown-verb:' + verb;
  return st;
}

// ------------------------------------------------------------ legal actions
// One entry each of "fold" / "check" / "call N" / "bet MIN MAX" /
// "raise MINTO MAXTO" / "allin N". What this offers must be EXACTLY what
// apply() accepts -- the fuzz checks that invariant.
export function betLegal(st, seat) {
  const out = [];
  if (st.phase !== 'acting' || st.toAct !== seat) return out;
  const owe = st.betCur - st.streetBy[seat];
  out.push('fold');
  if (owe <= 0) out.push('check');
  else out.push(`call ${Math.min(owe, st.stackBy[seat])}`);
  const maxTo = st.streetBy[seat] + st.stackBy[seat];
  if (st.actedBy[seat] === 'false' && maxTo > st.betCur) {
    const minTo = Math.min(st.betCur + st.raiseFull, maxTo);
    out.push(st.betCur === 0 ? `bet ${minTo} ${maxTo}` : `raise ${minTo} ${maxTo}`);
  }
  // a shove above the bet is a raise (needs betting open); at or under it is
  // just a call for less
  if (st.actedBy[seat] === 'false' || maxTo <= st.betCur) out.push(`allin ${maxTo}`);
  return out;
}

// pot-limit sizing for the Min / half / pot buttons, clamped to [minTo, maxTo]
export function quickAmount(st, seat, kind) {
  const owe = st.betCur - st.streetBy[seat];
  const potAfter = st.occ.reduce((a, s) => a + st.handBy[s], 0) + owe;
  const maxTo = st.streetBy[seat] + st.stackBy[seat];
  const minTo = Math.min(st.betCur + st.raiseFull, maxTo);
  let to;
  if (kind === 'half') to = st.betCur + Math.floor(potAfter / 2);
  else if (kind === 'pot') to = st.betCur + potAfter;
  else to = minTo;
  return Math.max(minTo, Math.min(to, maxTo));
}

// last aggressor of the final street first, then clockwise (protocol doc 12.6)
export function showdownOrder(st) {
  let first = st.sdFirst;
  if (first === 0 || st.foldedBy[first] === 'true')
    first = firstInHandAfter(st, st.buttonSeat);
  const order = [first, ...rotateAfter(st.occ, first)];
  const out = [];
  for (const s of order)
    if (st.foldedBy[s] === 'false' && !out.includes(s)) out.push(s);
  return out;
}

// ---------------------------------------------------------------- settlement
// Layered side pots: each distinct all-in level is its own pot, awarded
// independently; the odd chip goes to the first winner clockwise from the
// button. Deltas always sum to zero (protocol doc 13.1).
export function settle(st, ranks) {
  const deltas = {};
  for (const s of st.occ) deltas[s] = -st.handBy[s];

  const levels = [...new Set(st.occ.filter((s) => st.handBy[s] > 0).map((s) => st.handBy[s]))]
    .sort((a, b) => a - b);

  let prev = 0;
  for (const level of levels) {
    const layer = st.occ.reduce(
      (a, s) => a + Math.max(0, Math.min(st.handBy[s], level) - prev), 0);
    const eligible = st.occ.filter(
      (s) => st.foldedBy[s] === 'false' && st.handBy[s] >= level);

    if (eligible.length === 0) {
      // everyone who covered this layer folded: refund each contributor
      for (const s of st.occ) {
        const c = Math.min(st.handBy[s], level) - prev;
        if (c > 0) deltas[s] += c;
      }
      prev = level;
      continue;
    }

    let winners;
    if (eligible.length === 1) winners = eligible;      // uncontested
    else {
      const best = eligible.reduce((b, s) => (ranks[s] > b ? ranks[s] : b), '');
      winners = eligible.filter((s) => ranks[s] === best);
    }

    const share = Math.floor(layer / winners.length);
    let rem = layer % winners.length;
    for (const s of winners) deltas[s] += share;
    for (const s of rotateAfter(st.occ, st.buttonSeat)) {
      if (rem === 0) break;
      if (winners.includes(s)) { deltas[s] += 1; rem -= 1; }
    }
    prev = level;
  }
  return deltas;
}

// ------------------------------------------------------- blind schedule
// Dead-button-aware: the big blind ALWAYS advances to the next live seat
// clockwise from the previous big blind, so nobody posts it twice running and
// no live seat skips it across an elimination. Returns the button seat.
export function scheduleButton(liveList, lastBB) {
  if (lastBB === 0) return liveList[0];
  const nextLiveAfter = (pos) => liveList.find((s) => s > pos) ?? liveList[0];
  const prevLiveBefore = (pos) => {
    let prev = liveList[liveList.length - 1];
    for (const s of liveList) if (s < pos) prev = s;
    return prev;
  };
  const bb = nextLiveAfter(lastBB);
  const sb = prevLiveBefore(bb);
  if (liveList.length === 2) return sb;      // heads-up: button IS the SB
  return prevLiveBefore(sb);
}
