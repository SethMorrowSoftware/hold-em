// Conformance: the JS port against tools/protocol-kat.py --json.
// Same vectors the xTalk reference is held to. Nothing is hand-copied.

import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import * as P from './holdem-protocol.mjs';

const KAT_PY = path.join(path.dirname(fileURLToPath(import.meta.url)),
                         '..', 'tools', 'protocol-kat.py');
const KAT = JSON.parse(execFileSync('python3', [KAT_PY, '--json'], { encoding: 'utf8' }));

await P.ready();
const { hex, unhex, H } = P;
const enc = (s) => P.sodium.from_string(s);

let pass = 0, fail = 0;
const chk = (label, got, want) => {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) { pass++; console.log(`PASS  ${label}`); }
  else { fail++; console.log(`FAIL  ${label}\n  got  ${g}\n  want ${w}`); }
};

// ---- fixtures, derived exactly as the KAT derives them ----
const tableId = H(enc('HOLDEM-KAT-v1|table'));
const byteTag = (tag, i) => H(P.sodium.from_hex(
  hex(enc(tag)) + i.toString(16).padStart(2, '0')));
const idSeeds  = [1, 2, 3].map((i) => byteTag('HOLDEM-KAT-v1|identity|', i));
const dealSeeds = [1, 2, 3].map((i) => byteTag('HOLDEM-KAT-v1|seed|', i));
const ids = idSeeds.map((s) => P.identityFromSeed(s));
const HAND = 1, OCC = [1, 2, 3], BUTTON = 1;
const hostSec = ids[0].privateKey;

chk('table', hex(tableId), KAT.table);
chk('id_pubs', ids.map((k) => hex(k.publicKey)), KAT.id_pubs);
chk('deal_seeds', dealSeeds.map(hex), KAT.deal_seeds);

// ---- section 2: primitives ----
chk('H(empty) [doc 2.1]', hex(H(new Uint8Array(0))),
    '0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8');

// ---- section 10: the level 0 deal ----
const seedHexes = dealSeeds.map(hex);
chk('commits', seedHexes.map(P.seedCommitHex), KAT.commits);
const sx = P.xorSeeds(seedHexes);
chk('seeds_xor', hex(sx), KAT.seeds_xor);
const key = P.streamKey(tableId, HAND, sx);
chk('stream_key', hex(key), KAT.stream_key);
chk('stream_block0', hex(P.streamBytes(key, 1)), KAT.stream_block0);

const deck = P.level0Deck(tableId, HAND, seedHexes);
chk('deck', deck.map(P.cardName).join(','), KAT.deck);

const d = P.dealAssign(deck, OCC, BUTTON);
chk('holes', Object.fromEntries(OCC.map((s) =>
  [String(s), d.holes[s].map(P.cardName).join(',')])), KAT.holes);
chk('flop', d.flop.map(P.cardName).join(','), KAT.flop);
chk('turn', P.cardName(d.turn), KAT.turn);
chk('river', P.cardName(d.river), KAT.river);
chk('burns', d.burns.map(P.cardName).join(','), KAT.burns);

// synthetic stream: the draw + Fisher-Yates core with no hashing involved
chk('synth_deck', P.shuffleFromStream(unhex(KAT.synth_stream))
    .map(P.cardName).join(','), KAT.synth_deck);

// deal order: wrap-around, sparse seats, heads-up
const IDENT = Array.from({ length: 52 }, (_, i) => i + 1);
const orders = {};
for (const cfg of Object.keys(KAT.deal_orders)) {
  const [occTxt, btn] = cfg.split('|');
  const occ = occTxt.split(',').map(Number);
  const a = P.dealAssign(IDENT, occ, Number(btn));
  orders[cfg] = occ.map((s) => `${s}=${a.holes[s][0]}-${a.holes[s][1]}`).join(';')
    + ` flop=${a.flop.join('-')} turn=${a.turn} river=${a.river}`;
}
chk('deal_orders', orders, KAT.deal_orders);

// ---- section 5: envelope + chain ----
const msgs = [
  [0, 0, 'cfg', 'v=1,level=0,sb=1,bb=2,seats=3,button=1'],
  [0, 1, 'seedCommit', KAT.commits[0]],
  [1, 1, 'seedCommit', KAT.commits[1]],
  [2, 1, 'seedCommit', KAT.commits[2]],
  [1, 1, 'bidSB', 'amount=1'],
  [2, 1, 'bidBB', 'amount=2'],
];
let prev = P.GENESIS;
const heads = [];
let firstWire = null, firstContent = null;
msgs.forEach(([who, hand, type, body], i) => {
  const content = P.contentLine(hex(tableId), hand, hex(ids[who].publicKey), type, body);
  const wire = P.buildWire(content, ids[who].privateKey, i + 1, prev, hostSec);
  if (i === 0) { firstWire = wire; firstContent = content; }
  prev = P.chainNext(wire);
  heads.push(prev);
});
chk('env0_content', firstContent, KAT.env0_content);
chk('env0_sender_sig', P.senderSigHex(firstContent, ids[0].privateKey), KAT.env0_sender_sig);
chk('env0_wire', firstWire, KAT.env0_wire);
chk('chain_heads', heads, KAT.chain_heads);

// ---- section 13: settlement, receipts, checkpoints ----
chk('settle_hash', P.settleHashHex('1:-4,2:8,3:-4', unhex(prev)), KAT.settle_hash);
chk('settle_hash2', P.settleHashHex('1:2,2:-1,3:-1', new Uint8Array(32)), KAT.settle_hash2);
const rh1 = P.receiptHeadHex(KAT.settle_hash, '00'.repeat(32));
const rh2 = P.receiptHeadHex(KAT.settle_hash2, rh1);
chk('receipt_head1', rh1, KAT.receipt_head1);
chk('receipt_head2', rh2, KAT.receipt_head2);
chk('receipt_sigs', ids.map((k) => P.receiptSigHex(rh2, k.privateKey)), KAT.receipt_sigs);
chk('ckpt_sig', P.ckptSigHex(heads[5], ids[1].privateKey), KAT.ckpt_sig);

// ---- sections 4 + 9: admission and lobby ----
const [, admitSig] = P.admitToken(hex(tableId), hex(ids[0].publicKey), hostSec, 'host')
  .split('\t').slice(1);
chk('admit_sig', admitSig, KAT.admit_sig);
chk('roster_body', P.rosterBody([[KAT.id_pubs[0], 'host'], [KAT.id_pubs[1], 'player']]),
    KAT.roster_body);
chk('lobby_cfg_body', 'v=1,level=0,sb=1,bb=2,ante=0,stack=400,seats=6,button=1',
    KAT.lobby_cfg_body);
{
  const c1 = P.contentLine(hex(tableId), 0, KAT.id_pubs[0], 'cfg', KAT.lobby_cfg_body);
  const h1 = P.chainNext(P.buildWire(c1, hostSec, 1, P.GENESIS, hostSec));
  const c2 = P.contentLine(hex(tableId), 0, KAT.id_pubs[0], 'roster', KAT.roster_body);
  chk('lobby_head2', P.chainNext(P.buildWire(c2, hostSec, 2, h1, hostSec)), KAT.lobby_head2);
}

// ---- section 15.2 item 4: hostile input must DROP, never throw ----
const good = KAT.env0_wire, hostPub = KAT.id_pubs[0];
const f = good.split('\t');
const mutate = (i, v) => { const g = f.slice(); g[i] = v; return g.join('\t'); };
const hostile = [
  ['truncated wire', 'only\ttwo', 'drop:malformed'],
  ['empty string', '', 'drop:malformed'],
  ['non-hex body', mutate(5, 'zzzz'), 'drop:malformed'],
  ['short from', mutate(3, 'abcd'), 'drop:malformed'],
  ['non-hex sender sig', mutate(6, 'g'.repeat(128)), 'drop:malformed'],
  ['bad sender sig', mutate(6, '0'.repeat(128)), 'drop:bad-sender-sig'],
  ['bad host sig', mutate(9, '0'.repeat(128)), 'drop:bad-host-sig'],
  ['tampered body', mutate(5, hex(enc('v=1,level=0,sb=1,bb=999999'))), 'drop:bad-sender-sig'],
  ['tampered seq', mutate(7, '99'), 'drop:bad-host-sig'],
];
for (const [label, wire, want] of hostile) {
  let got;
  try { got = P.verifyWire(wire, '', hostPub, ''); }
  catch (e) { got = `THREW:${e.message}`; }
  chk(`hostile: ${label}`, got, want);
}
chk('honest wire verifies', P.verifyWire(good, '', hostPub, P.GENESIS), 'ok');
chk('wrong-prev is a chain break',
    P.verifyWire(good, '', hostPub, 'ff'.repeat(32)), 'drop:chain-break');

// ---- sealed lanes (sections 2.3 / 10.7) ----
{
  const box = P.boxKeyFromIdSeedHex(hex(idSeeds[1]));
  const ct = P.seal(enc('3,8'), box.publicKey);
  chk('sealOpen roundtrip',
      P.sodium.to_string(P.sealOpen(ct, box.publicKey, box.privateKey)), '3,8');
  const junk = new Uint8Array(80);
  chk('sealOpen(junk) returns null, does not throw',
      P.sealOpen(junk, box.publicKey, box.privateKey), null);
}

console.log(`\n${fail ? 'FAILED' : 'ALL PASS'} -- ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
