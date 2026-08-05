// holde-em protocol core -- JavaScript reference port.
//
// A direct transcription of HOLDEM-PROTOCOL.md into browser/Node JS. Every
// primitive comes from libsodium.js (the same library the xTalk reference
// binds to through SodiumXT), so there is no chance of primitive drift --
// notably NOT WebCrypto/Node crypto, neither of which offers BLAKE2b with a
// 32-byte digest (protocol doc section 2.1).
//
// Transport-free by design: this module builds, verifies, and folds bytes.
// Wire them to WebSocket/WebRTC/whatever above it.

import _sodium from 'libsodium-wrappers';

export let sodium = null;
export async function ready() {
  await _sodium.ready;
  sodium = _sodium;
  return sodium;
}

// ---------------------------------------------------------------- primitives
const enc = (s) => sodium.from_string(s);            // utf8
const cat = (...parts) => {
  const n = parts.reduce((a, p) => a + p.length, 0);
  const out = new Uint8Array(n);
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
};

export const H = (bytes) => sodium.crypto_generichash(32, bytes);
export const hex = (bytes) => sodium.to_hex(bytes);
export const unhex = (s) => sodium.from_hex(s);
export const sign = (msg, sec) => sodium.crypto_sign_detached(msg, sec);
export const verify = (sig, msg, pub) => {
  // MUST never throw: a malformed signature is `false` (protocol doc 2.2)
  try { return sodium.crypto_sign_verify_detached(sig, msg, pub); }
  catch { return false; }
};
export const seal = (msg, boxPub) => sodium.crypto_box_seal(msg, boxPub);
export const sealOpen = (ct, boxPub, boxSec) => {
  // failure is a drop, never an exception that escapes the receive loop (2.3)
  try { return sodium.crypto_box_seal_open(ct, boxPub, boxSec); }
  catch { return null; }
};

// Pure predicate -- no decoding. This is what stands between a hostile frame
// and a hex decoder that throws (protocol doc 5.4 / 18).
export function isHex(s, n = 0) {
  if (typeof s !== 'string' || s.length === 0 || s.length % 2 !== 0) return false;
  if (n > 0 && s.length !== n) return false;
  return /^[0-9a-fA-F]+$/.test(s);
}

// ------------------------------------------------------------------- domains
export const D = {
  chain: 'HOLDEM-CHAIN-v1|',
  sess: 'HOLDEM-SESS-v1|',
  seedP: 'HOLDEM-SEEDP-v1|',
  seedC: 'HOLDEM-SEEDC-v1|',
  shuf: 'HOLDEM-SHUF-v1|',
  settle: 'HOLDEM-SETL-v1|',
  rcpt: 'HOLDEM-RCPT-v1|',
  rsig: 'HOLDEM-RSIG-v1|',
  ckpt: 'HOLDEM-CKPT-v1|',
};
export const ENV_V = '1';
export const GENESIS = '0'.repeat(64);

// ------------------------------------------------------------------ identity
export const identityFromSeed = (seed32) => sodium.crypto_sign_seed_keypair(seed32);
export const boxKeyFromIdSeedHex = (idSeedHex) =>
  sodium.crypto_box_seed_keypair(H(enc(D.sess + idSeedHex)));
export const fingerprint = (pub) => hex(H(pub)).slice(0, 8);
export const infohashOf = (tableId) => hex(H(tableId)).slice(0, 40);

export function admitToken(tableHex, pubHex, sec, role) {
  const msg = enc(`${D.sess}${tableHex}|${pubHex}|${role}`);
  return `${pubHex}\t${role}\t${hex(sign(msg, sec))}`;
}

export function admitTokenVerify(token, tableHex) {
  const [pubHex, role, sigHex] = String(token).split('\t');
  if (!isHex(pubHex, 64) || !isHex(sigHex, 128)) return null;
  const msg = enc(`${D.sess}${tableHex}|${pubHex}|${role}`);
  return verify(unhex(sigHex), msg, unhex(pubHex)) ? { pubHex, role } : null;
}

// ------------------------------------------------------------------ envelope
export const contentLine = (tableHex, hand, fromHex, type, body) =>
  [ENV_V, tableHex, String(hand), fromHex, type, hex(enc(body))].join('\t');

export const senderSigHex = (content, senderSec) => hex(sign(enc(content), senderSec));

export function buildWire(content, senderSec, seq, prevHex, hostSec) {
  const env = `${content}\t${senderSigHex(content, senderSec)}\t${seq}\t${prevHex}`;
  return `${env}\t${hex(sign(enc(env), hostSec))}`;
}

export function parseWire(wire) {
  const f = String(wire).split('\t');
  if (f.length !== 10) return null;
  return {
    v: f[0], table: f[1], hand: f[2], from: f[3], type: f[4], bodyHex: f[5],
    senderSig: f[6], seq: f[7], prev: f[8], hostSig: f[9],
    contentLine: f.slice(0, 6).join('\t'),
    envLine: f.slice(0, 9).join('\t'),
  };
}

export const chainNext = (wire) => hex(H(enc(D.chain + wire)));

// Shape, then signatures, then binding -- in that order. Returns "ok" or a
// drop reason; never throws (protocol doc 5.4).
export function verifyWire(wire, expectedFromHex, hostPubHex, expectedPrevHex) {
  const a = parseWire(wire);
  if (!a) return 'drop:malformed';
  if (!isHex(a.from, 64) || !isHex(hostPubHex, 64)) return 'drop:malformed';
  if (!isHex(a.senderSig, 128) || !isHex(a.hostSig, 128)) return 'drop:malformed';
  if (a.bodyHex !== '' && !isHex(a.bodyHex)) return 'drop:malformed';
  if (expectedFromHex && a.from !== expectedFromHex) return 'drop:unknown-from';
  if (!verify(unhex(a.senderSig), enc(a.contentLine), unhex(a.from)))
    return 'drop:bad-sender-sig';
  if (!verify(unhex(a.hostSig), enc(a.envLine), unhex(hostPubHex)))
    return 'drop:bad-host-sig';
  if (expectedPrevHex && a.prev !== expectedPrevHex) return 'drop:chain-break';
  return 'ok';
}

export function bodyText(bodyHex) {
  if (!bodyHex || !isHex(bodyHex)) return '';
  try { return sodium.to_string(unhex(bodyHex)); } catch { return ''; }
}

// key=value pairs joined by "," -- tolerant of unknown keys, order-independent
export function parseBody(text) {
  const out = {};
  for (const pair of String(text).split(',')) {
    const i = pair.indexOf('=');
    if (i > 0) out[pair.slice(0, i)] = pair.slice(i + 1);
  }
  return out;
}

// -------------------------------------------------------------- level 0 deal
export const handSeedHex = (idSeedHex, tableHex, hand) =>
  hex(H(enc(`${D.seedP}${idSeedHex}|${tableHex}|${hand}`)));

// NOTE the asymmetry against handSeedHex and it is load-bearing: the
// commitment hashes the RAW seed bytes, the derivation hashes hex TEXT
// (protocol doc 4.6).
export const seedCommitHex = (seedHex) => hex(H(cat(enc(D.seedC), unhex(seedHex))));

export function xorSeeds(seedHexes) {
  const out = new Uint8Array(32);
  for (const sh of seedHexes) {
    const b = unhex(sh);
    for (let i = 0; i < 32; i++) out[i] ^= b[i];
  }
  return out;
}

export function streamKey(tableId, hand, seedsXor) {
  return H(cat(enc(D.shuf), tableId, enc(`|${hand}|`), seedsXor));
}

function u32be(j) {
  return new Uint8Array([(j >>> 24) & 255, (j >>> 16) & 255, (j >>> 8) & 255, j & 255]);
}

export function streamBytes(key, nblocks) {
  const parts = [];
  for (let j = 0; j < nblocks; j++) parts.push(H(cat(key, u32be(j))));
  return cat(...parts);
}

// uniform in 1..n, rejection-sampled -- NOT optional, a plain `w mod n`
// biases the deck detectably over a session (protocol doc 10.5)
export function draw(stream, offset, n) {
  const limit = Math.floor(0x100000000 / n) * n;
  for (;;) {
    if (offset + 4 > stream.length) throw new Error('stream-exhausted');
    const w = ((stream[offset] * 0x1000000) + (stream[offset + 1] << 16) +
               (stream[offset + 2] << 8) + stream[offset + 3]);
    offset += 4;
    if (w < limit) return [(w % n) + 1, offset];
  }
}

export function shuffleFromStream(stream) {
  const deck = Array.from({ length: 53 }, (_, i) => i); // 1-based; deck[0] unused
  let offset = 0;
  for (let i = 52; i >= 2; i--) {
    const [j, next] = draw(stream, offset, i);
    offset = next;
    [deck[i], deck[j]] = [deck[j], deck[i]];
  }
  return deck.slice(1);
}

export function deckFromStreamKey(key) {
  for (let blocks = 16; blocks <= 256; blocks *= 2) {
    try { return shuffleFromStream(streamBytes(key, blocks)); }
    catch (e) { if (!String(e.message).includes('stream-exhausted')) throw e; }
  }
  throw new Error('stream-exhausted');
}

export const level0Deck = (tableId, hand, seedHexes) =>
  deckFromStreamKey(streamKey(tableId, hand, xorSeeds(seedHexes)));

// occupied seats rotated to start immediately after the button
export function rotateAfter(list, entry) {
  const i = list.indexOf(entry);
  if (i < 0 || i === list.length - 1) return list.slice();
  return list.slice(i + 1).concat(list.slice(0, i + 1));
}

export function dealAssign(deck, occupied, button) {
  const order = rotateAfter(occupied, button);
  const holes = {};
  for (const s of occupied) holes[s] = [];
  let p = 0;
  for (let round = 0; round < 2; round++)
    for (const s of order) holes[s].push(deck[p++]);
  const burns = [deck[p++]];
  const flop = deck.slice(p, p + 3); p += 3;
  burns.push(deck[p++]);
  const turn = deck[p++];
  burns.push(deck[p++]);
  const river = deck[p];
  return { holes, flop, turn, river, burns };
}

// ------------------------------------------------- settlement / receipts
export const settleHashHex = (deltasCSV, chainHeadBytes) =>
  hex(H(cat(enc(`${D.settle}${deltasCSV}|`), chainHeadBytes)));

export const receiptHeadHex = (settleHex, prevRcptHex) =>
  hex(H(enc(`${D.rcpt}${settleHex}|${prevRcptHex}`)));

export const receiptSigHex = (rcptHeadHex, sec) =>
  hex(sign(enc(D.rsig + rcptHeadHex), sec));

export const receiptSigVerify = (sigHex, rcptHeadHex, pubHex) =>
  isHex(sigHex, 128) && isHex(pubHex, 64) &&
  verify(unhex(sigHex), enc(D.rsig + rcptHeadHex), unhex(pubHex));

export const ckptSigHex = (chainHeadHex, sec) =>
  hex(sign(enc(D.ckpt + chainHeadHex), sec));

// canonical lobby roster: "pubHex:role" sorted ascending, comma-joined
export const rosterBody = (members) =>
  members.map(([p, r]) => `${p}:${r}`).sort().join(',');

// ------------------------------------------------------------------- cards
export const RANKS = '23456789TJQKA';
export const SUITS = 'cdhs';
export const cardName = (i) => RANKS[(i - 1) >> 2] + SUITS[(i - 1) % 4];
export const cardIndex = (n) => RANKS.indexOf(n[0]) * 4 + SUITS.indexOf(n[1]) + 1;
export const cardRank = (i) => ((i - 1) >> 2) + 2;
export const cardSuit = (i) => ((i - 1) % 4) + 1;
