# holde-em on the web

A JavaScript port of the wire protocol in [`../HOLDEM-PROTOCOL.md`](../HOLDEM-PROTOCOL.md),
for browser and Node clients.

**Status: the protocol core is done and verified. There is no UI yet, and there is a
real transport blocker between a browser and an OXT-hosted table -- read section 3
before planning anything.**

```
web/
  holdem-protocol.mjs   the protocol core: primitives, envelope, chain, Level 0 deal,
                        settlement/receipt hashing, cards. Transport-free.
  conformance.mjs       runs the core against tools/protocol-kat.py --json
  package.json          one dependency: libsodium-wrappers
```

```sh
cd web && npm install && npm test
```

## 1. What is verified

`conformance.mjs` checks the JS core against **the same pinned vectors the xTalk
reference implementation is held to** -- not a hand-copied subset. It reads them live
from `tools/protocol-kat.py --json`, so the vectors cannot drift out of sync with the
Python KAT.

43 assertions, all passing, covering:

- **primitives** -- `H("")` is BLAKE2b-**256**, not a truncated BLAKE2b-512
- **the deal** -- commitments, seed XOR, stream key, stream block 0, the full 52-card
  shuffled deck, hole cards, flop/turn/river, burns, the synthetic-stream deck (the
  draw + Fisher-Yates core with no hashing involved), and all five deal-order
  signatures (wrap-around, sparse seats, heads-up)
- **the envelope** -- content line, sender signature, the full `env0_wire` byte for
  byte, and a six-envelope chain
- **settlement** -- settle hash (both fixtures), the two-hand receipt chain, all three
  receipt signatures, the checkpoint signature
- **admission and lobby** -- admission-token signature, canonical roster body, the
  lobby chain head
- **hostile input** (protocol doc 15.2 item 4) -- truncated wire, empty string, non-hex
  body, short `from`, non-hex signature, bad sender signature, bad host signature,
  tampered body, tampered seq. Each must produce the **exact documented drop reason**
  and must not throw.
- **sealed lanes** -- seal/open roundtrip, and that opening junk returns `null` rather
  than throwing

That satisfies items 1-4 of the protocol doc's conformance checklist. Items 5-7 (seq
classification, the authority matrix, refusing a lying settle) belong to the client
loop, which is not written yet.

**Browser-verified.** The core was also run in headless Chromium 141 via Playwright --
14 assertions covering the same ground -- so "works in a browser" is observed, not
assumed. The browser harness is not committed (it needs Playwright and a static
server); the Node conformance is the CI gate.

## 2. Why libsodium.js and not WebCrypto

The protocol needs BLAKE2b-256, Ed25519, and libsodium sealed boxes. Neither WebCrypto
nor Node's built-in `crypto` can supply that set:

| Primitive | WebCrypto | Node `crypto` | libsodium.js |
|---|---|---|---|
| BLAKE2b-256 | no | **no** -- only `blake2b512` / `blake2s256` | yes |
| Ed25519 detached | recent browsers only | yes | yes |
| `crypto_box_seal` | no | no (no XSalsa20-Poly1305) | yes |

The BLAKE2b row is the trap the protocol doc calls out in section 2.1: BLAKE2b's digest
length is part of its parameter block, so **a truncated BLAKE2b-512 is a different
function**, and a port built on `blake2b512` produces a plausible-looking chain that
nobody else agrees with. `conformance.mjs` asserts `H("")` explicitly for this reason.

libsodium.js is the same library the xTalk reference binds to through SodiumXT, so
there is no chance of primitive drift. It is ~190 KB of WASM-backed JS -- acceptable
for a poker client, and the alternative is auditing three hand-rolled primitives.

## 3. The transport blocker (read this first)

**A browser cannot join a table hosted by the OXT stack today.** The reference host
speaks rp1 -- a BitTorrent peer-wire extension -- and finds peers over the BitTorrent
DHT. A browser can do neither: no raw TCP, no UDP, no DHT participation. This is a
hard limitation of the browser sandbox, not something better JavaScript fixes.

Everything *above* the transport is fine. The protocol was written transport-agnostic
(protocol doc section 6.1 states requirements rather than naming rp1), and this core
proves the crypto and framing port cleanly. So the question is only how bytes move.

Three ways out, in increasing order of cost:

**A. Web-only tables.** Host and join both in the browser, with a dumb WebSocket relay
for fan-out. Fully buildable today with nothing in this directory changed. The relay
needs **no protocol knowledge whatsoever** -- it does not verify signatures, does not
know poker, and cannot cheat, because every envelope is signed end to end and chained.
It is a ~50-line fan-out server. The cost: these tables cannot interoperate with OXT
tables at all.

**B. A bridge.** A process that speaks rp1 on one side and WebSocket on the other,
relaying opaque payloads. It cannot forge anything, for the same reason the relay in A
cannot -- it is a pipe, not an authority. The cost: something must implement rp1 outside
OXT (its framing lives in TorrentXT, not this repo), or the bridge must itself *be* an
OXT stack running in bridge mode.

**C. A WebSocket lane in the OXT stack.** The stack already has engine sockets, so it
could accept browser peers directly and no bridge process would exist. The catch: the
WebSocket handshake requires SHA-1, which SodiumXT does not obviously expose, and house
rule H7 bans bitwise operators -- so a pure-xTalk SHA-1 means writing it in `div`/`mod`
integer arithmetic like the existing `heByteXor`. Doable, genuinely unpleasant.

**A is the recommendation** for getting something playable and elegant quickly; C is
the right long-term answer if browser clients are meant to sit at the same tables as
OXT clients.

## 4. What a full client still needs

The core here handles bytes. A playable client also needs:

1. **A transport adapter** -- swappable; see section 3. The core deliberately does not
   import one.
2. **The ingest loop** -- seq classification, the bounded reorder buffer, resync,
   catch-up suppression (protocol doc section 7). Perhaps 150 lines, and the rules that
   matter are written down, including *why* duplicates must be classified by `seq` and
   never by a bare `prev`-vs-head test.
3. **The betting engine and evaluator** -- ports of `heBetApply`, `heSettleOf`, and
   `heEval7`. These are pure functions with existing KAT coverage
   (`tools/betting-kat.py`, `tools/evaluator-kat.py`), so they are testable offline with
   no network at all. This is the largest remaining chunk and the least risky, because
   every rule is already pinned on both sides.
4. **The react ladder** -- emit only what your seat owes next, each emission behind both
   a presence guard and a sent flag (protocol doc 9.3).
5. **Identity storage.** Note honestly that browser storage is *not* secure storage:
   an identity seed in IndexedDB is exposed to XSS and to anyone with the device. The
   protocol assumes the long-term key never leaves the machine, which a browser honors
   only as well as the page's origin isolation does. A passphrase-wrapped seed
   (`crypto_pwhash` + `secretbox`) is the obvious hardening and is worth doing before
   any table carries anything of value.

## 5. Using the core

```js
import * as P from './holdem-protocol.mjs';
await P.ready();                                   // loads the WASM

const idSeed = P.sodium.randombytes_buf(32);       // persist this
const me = P.identityFromSeed(idSeed);
const box = P.boxKeyFromIdSeedHex(P.hex(idSeed));  // session lane

// verify anything that arrives, before parsing it
const verdict = P.verifyWire(wire, '', hostPubHex, myChainHead);
if (verdict !== 'ok') { drop(verdict); return; }

// fold it
myChainHead = P.chainNext(wire);
const a = P.parseWire(wire);
const body = P.parseBody(P.bodyText(a.bodyHex));
```

Every exported name maps to a numbered section of `../HOLDEM-PROTOCOL.md`; the source
carries the section references inline.
