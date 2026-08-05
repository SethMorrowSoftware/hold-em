// Differential conformance: web/engine.mjs against the REFERENCE betting
// mirror in tools/betting-kat.py and the evaluator vectors in
// tools/evaluator-kat.py.
//
// web/gen-engine-trace.py drives the Python mirror over randomized hands with
// a fixed seed and records every intermediate state. This replays the identical
// message sequence through the JS engine and requires an exact match at every
// step -- so a divergence is caught at the message that caused it, not at the
// end of the hand.
//
// Because tools/logic-fuzz.py already checks that mirror against an
// INDEPENDENT reference implementation of the rules, matching it transitively
// pins the JS port to the same rules the xTalk engine and the fuzz agree on.

import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import * as E from './engine.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const HANDS = process.argv.includes('--quick') ? 120 : 600;

const T = JSON.parse(execFileSync('python3',
  [path.join(HERE, 'gen-engine-trace.py'), '--hands', String(HANDS)],
  { encoding: 'utf8', maxBuffer: 1 << 28 }));

let pass = 0, fail = 0;
const fails = [];
const bad = (label, detail) => {
  fail++;
  if (fails.length < 8) fails.push(`FAIL  ${label}\n      ${detail}`);
};

// ------------------------------------------------------- evaluator vectors
for (const v of T.evaluator) {
  const got = E.eval7(v.cards);
  if (got === v.expect) pass++;
  else bad(`evaluator: ${v.label}`, `got ${got} want ${v.expect}`);
}

// ------------------------------------------------- differential hand replay
// Compare only the fields the mirror snapshots, keyed the same way.
const SCALARS = ['street', 'phase', 'toAct', 'betCur', 'raiseFull', 'aggressor',
                 'sdFirst', 'err', 'note', 'sbSeat', 'bbSeat', 'sb', 'bb',
                 'ante', 'buttonSeat'];
const MAPS = ['stackBy', 'streetBy', 'handBy', 'foldedBy', 'allinBy', 'actedBy'];

function diffState(js, want, label) {
  for (const k of SCALARS) {
    if (String(js[k] ?? '') !== String(want[k] ?? ''))
      return `${label}: ${k} got ${JSON.stringify(js[k])} want ${JSON.stringify(want[k])}`;
  }
  if (js.occ.join(',') !== want.occ.join(','))
    return `${label}: occ got ${js.occ} want ${want.occ}`;
  for (const m of MAPS)
    for (const s of want.occ) {
      const g = js[m][s], w = want[m][String(s)];
      if (String(g) !== String(w))
        return `${label}: ${m}[${s}] got ${JSON.stringify(g)} want ${JSON.stringify(w)}`;
    }
  if (want.sbPosted !== undefined && String(js.sbPosted ?? '') !== String(want.sbPosted))
    return `${label}: sbPosted got ${js.sbPosted} want ${want.sbPosted}`;
  if (want.antePostedBy)
    for (const s of want.occ) {
      const g = js.antePostedBy?.[s], w = want.antePostedBy[String(s)];
      if (String(g ?? '') !== String(w ?? ''))
        return `${label}: antePostedBy[${s}] got ${g} want ${w}`;
    }
  return null;
}

let steps = 0;
for (const h of T.hands) {
  const stacks = {};
  for (const [k, v] of Object.entries(h.setup.stacks)) stacks[Number(k)] = v;
  let st = E.newHand(h.setup.sb, h.setup.bb, stacks, h.setup.occ,
                     h.setup.button, h.setup.ante);

  // the initial derived seats must agree before a single message is applied
  const first = h.states[0];
  if (st.sbSeat !== first.sbSeat || st.bbSeat !== first.bbSeat) {
    bad(`hand ${h.idx}: blind seats`,
        `got sb=${st.sbSeat} bb=${st.bbSeat} want sb=${first.sbSeat} bb=${first.bbSeat}`);
    continue;
  }

  let broke = false;
  for (let i = 0; i < h.msgs.length; i++) {
    const [mtype, seat, amount] = h.msgs[i];
    st = E.apply(st, mtype, seat, amount);
    steps++;
    const d = diffState(st, h.states[i], `hand ${h.idx} step ${i} (${mtype} ${seat} ${amount})`);
    if (d) { bad(`hand ${h.idx} replay`, d); broke = true; break; }
    pass++;
  }
  if (broke) continue;

  // showdown ranks from the same cards, then settlement
  const ranks = {};
  for (const [s, cards] of Object.entries(h.holes))
    ranks[Number(s)] = E.eval7([...cards, ...h.board]);
  for (const [s, want] of Object.entries(h.ranks)) {
    if (ranks[Number(s)] === want) pass++;
    else bad(`hand ${h.idx}: rank seat ${s}`, `got ${ranks[Number(s)]} want ${want}`);
  }

  const deltas = E.settle(st, ranks);
  let deltaOk = true;
  for (const [s, want] of Object.entries(h.deltas)) {
    if (deltas[Number(s)] !== want) {
      bad(`hand ${h.idx}: delta seat ${s}`, `got ${deltas[Number(s)]} want ${want}`);
      deltaOk = false;
    }
  }
  if (deltaOk) pass++;

  // chip conservation is the invariant that matters most: settlement must
  // never mint or burn a chip, whatever the side-pot shape
  const sum = Object.values(deltas).reduce((a, b) => a + b, 0);
  if (sum === 0) pass++;
  else bad(`hand ${h.idx}: chip conservation`, `deltas sum to ${sum}, not 0`);

  const so = E.showdownOrder(st);
  if (so.join(',') === h.showdownOrder.join(',')) pass++;
  else bad(`hand ${h.idx}: showdown order`, `got ${so} want ${h.showdownOrder}`);
}

// --------------------------------------------- betLegal vs apply, exhaustively
// Whatever betLegal OFFERS, apply MUST accept -- an offer the gate rejects is
// a UI that lies. (The trace generator asserts the same invariant on the
// Python side; this checks the JS pair.)
{
  let checked = 0;
  for (const h of T.hands.slice(0, 150)) {
    const stacks = {};
    for (const [k, v] of Object.entries(h.setup.stacks)) stacks[Number(k)] = v;
    let st = E.newHand(h.setup.sb, h.setup.bb, stacks, h.setup.occ,
                       h.setup.button, h.setup.ante);
    for (const [mtype, seat, amount] of h.msgs) {
      if (st.phase === 'acting') {
        const who = st.toAct;
        for (const offer of E.betLegal(st, who)) {
          const [verb, ...rest] = offer.split(' ');
          const amts = verb === 'fold' || verb === 'check' ? [0]
            : verb === 'bet' || verb === 'raise'
              ? [Number(rest[0]), Number(rest[1])]      // both ends of the range
              : [Number(rest[0])];
          for (const a of amts) {
            const probe = E.apply(st, 'act', who, `${verb},${a}`);
            if (probe.err === '') checked++;
            else bad(`hand ${h.idx}: betLegal offered "${offer}" @${a}`,
                     `apply rejected it: ${probe.err}`);
          }
        }
      }
      st = E.apply(st, mtype, seat, amount);
    }
  }
  pass += checked > 0 ? 1 : 0;
  if (checked === 0) bad('betLegal/apply cross-check', 'no offers were probed');
  else console.log(`      (betLegal/apply: ${checked} offers probed, all accepted)`);
}

console.log(fails.join('\n'));
console.log(`\nengine conformance: ${T.hands.length} hands, ${steps} message steps`);
console.log(`${fail ? 'FAILED' : 'ALL PASS'} -- ${pass} checks passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
