# holde-em wire protocol -- v1

**Status: normative, as-built.** This document specifies the holde-em table protocol
completely enough that an independent implementation, in any language, can join a table
hosted by `src/holdem.livecodescript` and play a hand to a co-signed settlement receipt.

It is a **distillation, not a redesign.** Everything here is already implemented and
byte-pinned:

| Source | Role |
|---|---|
| `holdem-spec.md` | the design contract -- why the protocol is shaped this way, the threat model, the deal ladder above Level 0 |
| `src/holdem.livecodescript` | the reference implementation (xTalk / LiveCodeScript) |
| `tools/protocol-kat.py` | the byte-exact conformance vectors (also a second, independent implementation of the crypto path in Python) |
| **this file** | the language-neutral rules an implementer needs, with no xTalk in the way |

Where this document and the reference implementation disagree, **the implementation
wins and this document is a bug.** Where this document and `holdem-spec.md` disagree,
this document is the as-built truth and the spec is the older plan (the spec says so
itself in section 6).

**Scope of v1.** Deal Level 0 (commit-reveal keyed-stream shuffle, spec 7.1), star
topology through a relay host, no-limit hold'em, 2-6 seats. Levels 1 and 2 (deck
oracle, ristretto255 mental poker) are reserved in the vocabulary and specified in
`holdem-spec.md` sections 7.2 and 7.3; they are not part of protocol v1 and an
implementation MUST reject `dealLevel` bodies naming a level it does not implement.

---

## 0. How to read this

- **MUST / MUST NOT / SHOULD / MAY** carry their usual normative force.
- Every construction that produces bytes on the wire has a pinned test vector in
  section 15. If your implementation reproduces those, it interoperates. If it does
  not, it does not -- there is no "close enough" in a hash chain.
- Section 17 is a self-contained pseudocode appendix; sections 5-13 are the prose
  rules those routines implement.

The single most useful thing to build first is section 5 (envelope) plus section 15's
`env0_wire` vector. Everything else is bookkeeping over a chain you can already verify.

---

## 1. Conventions

- `||` is byte concatenation. `TAB` is U+0009. `utf8(s)` is the UTF-8 encoding of the
  text `s`. There are no byte-order marks anywhere.
- **hex** means lowercase base-16, two characters per byte, no prefix, no separators.
  A decoder MUST accept only `[0-9a-fA-F]` and an even length; an encoder MUST emit
  lowercase. Every field this document calls "hex" is validated for shape **before**
  it is decoded -- see section 5.5.
- **Numbers on the wire are decimal ASCII text** with no leading zeros, no thousands
  separators, and no sign except a leading `-` on negative settlement deltas. Chip
  amounts are non-negative integers; there are no fractional chips anywhere (an
  implementation MUST reject a non-integer amount rather than round it -- see 12.5).
- Seats are integers `1..6`. Seat numbers are stable for the life of a table.
- Card indices are integers `1..52` (section 11.1). Card *names* are two characters
  (`"Qs"`, `"Td"`).
- "The host" is the peer relaying and sequencing this table's transcript (section 4.5).
  It is a switchboard, not an authority: it assigns order, and it cannot forge content.

---

## 2. Cryptographic primitives

All three primitives are libsodium's, at libsodium's defaults. Any language binding to
libsodium (or a compatible reimplementation) satisfies this section.

### 2.1 Hash -- `H`

`H(data)` is **BLAKE2b with a 32-byte digest, unkeyed, no salt, no personalization**.

- libsodium: `crypto_generichash(out, 32, in, inlen, NULL, 0)`
- Python: `hashlib.blake2b(data, digest_size=32).digest()`
- Go: `blake2b.Sum256(data)`
- Rust: `blake2b_simd::Params::new().hash_length(32)`
- Node: `crypto.createHash("blake2b512")` is **wrong** -- the digest length is part of
  BLAKE2b's parameter block, so a truncated 512-bit digest is a different function.
  Use a 256-bit-configured BLAKE2b.

This last point catches people. `H("")` MUST equal
`0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8`.

### 2.2 Signature -- `sign` / `verify`

**Ed25519**, detached, RFC 8032, as libsodium implements it.

- `keypair(seed32) -> (pub32, sec64)` is `crypto_sign_seed_keypair`. The 32-byte seed
  is the identity secret; the 64-byte "secret key" is the libsodium expanded form
  (seed || pub). An implementation that keeps only the 32-byte seed and expands on
  demand is equivalent.
- `sign(msg, sec) -> sig64` is `crypto_sign_detached`.
- `verify(sig, msg, pub) -> bool` is `crypto_sign_verify_detached`. It MUST NOT throw
  or panic on a malformed signature -- a bad signature is `false` and nothing else.

Signature malleability is not a concern here because every signature covers a byte
string that is itself committed into a hash chain; a second valid encoding of the same
signature would produce a different chain head and be rejected as a chain break.

### 2.3 Sealed box -- `seal` / `sealOpen`

**libsodium sealed boxes**: `crypto_box_seal` / `crypto_box_seal_open` (X25519 +
XSalsa20-Poly1305, with an ephemeral sender keypair). Anonymous sender, authenticated
ciphertext, 48 bytes of overhead.

- `boxKeypair(seed32) -> (boxPub32, boxSec32)` is `crypto_box_seed_keypair`.
- `seal(msg, recipBoxPub) -> ciphertext`
- `sealOpen(ct, recipBoxPub, recipBoxSec) -> msg`, **which MUST be treated as
  failing on any error** -- a failed open is a dropped, logged message, never a retry
  and never an exception that escapes the receive loop.

Used only for the private lanes: `seedSeal` (seat -> dealer) and `holeDeliver`
(dealer -> seat).

### 2.4 Randomness

Anything unguessable MUST come from the platform CSPRNG (`crypto_randombytes` /
`getrandom` / `crypto.randomBytes`). This applies to:

- the 32-byte long-term identity seed (section 4.1), and
- the 32-byte table id (section 4.3).

Note what is **not** in that list: the per-hand deal seed is *derived*, not drawn
(section 10.1). A general-purpose PRNG (Mersenne, `rand()`, an LCG) MUST NOT be used
for either of the two items above.

### 2.5 Constant-time comparison

Comparisons of secrets, MACs, and signature-adjacent material MUST be constant-time
(`crypto_verify_32` / `sodium_memcmp` / `hmac.compare_digest` / `subtle.ConstantTimeCompare`).

Comparisons of *public* hex text -- chain heads, commitments, seat numbers -- MAY be
ordinary string equality. They are public values; there is no secret to leak by timing.

### 2.6 Domain separation

Every hash and every non-envelope signature in this protocol is domain-separated by a
versioned ASCII tag. The tags are **exact, including the trailing pipe**:

| Tag | Used by | Section |
|---|---|---|
| `HOLDEM-CHAIN-v1\|` | transcript chain head | 5.4 |
| `HOLDEM-SESS-v1\|` | admission token / session binding | 4.4 |
| `HOLDEM-SEEDP-v1\|` | per-hand deal-seed derivation | 10.1 |
| `HOLDEM-SEEDC-v1\|` | deal-seed commitment | 10.2 |
| `HOLDEM-SHUF-v1\|` | shuffle stream key | 10.4 |
| `HOLDEM-SETL-v1\|` | settlement hash | 13.2 |
| `HOLDEM-RCPT-v1\|` | receipt head | 13.3 |
| `HOLDEM-RSIG-v1\|` | receipt signature | 13.3 |
| `HOLDEM-CKPT-v1\|` | checkpoint signature | 13.4 |
| `HOLDEM-CARD-v1\|` | Level 2 card points (reserved, not v1) | 14 |

A new tag version is a consensus break (section 16).

---

## 3. Encoding rules

### 3.1 The three-layer framing

The protocol nests three delimiters, deliberately chosen so no layer can escape into
the one above it:

| Layer | Delimiter | Escaping |
|---|---|---|
| wire envelope | `TAB` | none needed -- every field is hex or a decimal integer |
| message body | `,` between pairs, `=` inside a pair | none needed -- the whole body is hex-encoded into the envelope |
| lists inside a body value | `\|` | none needed -- values are seat numbers, card names, or `seat:delta` |

Because the body is carried as **hex of its UTF-8 bytes**, a body may contain commas,
tabs, or anything else without corrupting the frame. An implementation MUST NOT invent
an escaping scheme; there is nothing to escape.

### 3.2 Body grammar

A body is zero or more `key=value` pairs joined by `,`:

```
body  := pair ("," pair)*
pair  := key "=" value
key   := [A-Za-z][A-Za-z0-9]*
value := any UTF-8 not containing "," or "="
```

Parsers MUST be tolerant of unknown keys (forward compatibility: a future field is
ignored, not a drop) and MUST NOT depend on pair ordering. A duplicate key SHOULD be
resolved to the last occurrence, but a conforming sender never emits one.

A missing or malformed required key is a **drop with a log line**, never a throw
(section 7.6).

---

## 4. Identity, table, admission

### 4.1 Long-term identity

A player holds a 32-byte random **identity seed**, generated once and persisted.

```
idSeed  = randombytes(32)                  -- persisted, never transmitted
(idPub, idSec) = keypair(idSeed)
playerId = hex(idPub)                       -- 64 hex chars; THE identity on the wire
fingerprint = first 8 hex chars of hex(H(idPub))    -- display handle only
```

The long-term key **only ever signs**. It never encrypts, never derives a shared
secret, and never leaves the machine. The identity seed additionally serves as the PRF
key for per-hand deal seeds (section 10.1), which is why it must be persisted rather
than regenerated per session.

### 4.2 Session box key

Per table, a player derives an X25519 keypair for the private lanes:

```
boxSeed = H(utf8("HOLDEM-SESS-v1|" || idSeedHex))
(boxPub, boxSec) = boxKeypair(boxSeed)
```

where `idSeedHex` is the 64-character hex **text** of the identity seed (not its raw
bytes -- see 4.6). The player publishes `hex(boxPub)` in a `join` message; the
`join` envelope's own sender signature, which covers the table id, the sender pubkey,
and the box pub together, **is** the session-key binding required by `holdem-spec.md`
section 5. There is no separate binding message.

An implementation that cannot derive a box key (no sealed-box support) MAY still join
and observe, but cannot be dealt to.

### 4.3 Table id and rendezvous

```
tableId    = randombytes(32)          -- generated by the host
tableCode  = hex(tableId)             -- 64 hex chars; THIS IS THE INVITE
infohash   = first 40 hex chars of hex(H(tableId))    -- 20-byte DHT rendezvous id
```

The table code is the whole invite: whoever holds it can find the swarm and attempt to
join. The DHT carries **zero game data** -- it is a rendezvous only.

### 4.4 Admission token

Every peer publishes a signed admission claim at the transport handshake, so strangers
are dropped before any game message is parsed.

```
tokenMsg  = utf8("HOLDEM-SESS-v1|" || tableCode || "|" || pubHex || "|" || role)
tokenSig  = sign(tokenMsg, idSec)
token     = pubHex TAB role TAB hex(tokenSig)         -- UTF-8 bytes
```

`role` is `"host"` or `"player"`.

A receiver MUST verify the token's signature against the pubkey **carried in the token
itself** and against **its own** table code. A token that fails, or whose table code is
not this table, means the peer is ignored entirely.

**Host adoption is trust-on-first-use.** A joining player adopts as host the first peer
whose verified token declares `role="host"`. A *second*, different host-declaring key
MUST NOT silently replace the first: log it, surface it, keep the pinned host. (This is
the seam where a stronger invite-to-host binding, or the spec 9 host election, will
land; v1 does not have one.)

### 4.5 Roles

- **Player**: signs its own content lines; sends them to the host; folds the sequenced
  chain the host broadcasts.
- **Host**: everything a player does, plus: assigns `seq`, countersigns each envelope,
  broadcasts it to every admitted peer, replays the log to joiners and resyncers,
  emits the host-authored message types (section 8.3), and computes the `settle`.
- **Dealer**: a per-hand role, held by the button seat's player at Level 0. Opens the
  sealed seeds, derives the deck, delivers hole cards, and emits the board.

The host is not the dealer (except by coincidence of seating), and neither role can
forge content: every message carries its author's own signature underneath the host's.

### 4.6 A note on hex-text versus raw bytes

Several derivations hash **hex text** rather than raw bytes. This is deliberate,
as-built, and load-bearing -- an implementation that "cleans it up" by hashing raw bytes
will produce a different, non-interoperable chain.

Hashes over **hex text**: box seed (4.2), per-hand seed (10.1), receipt head (13.3).
Hashes over **raw bytes**: seed commitment (10.2), stream key table id and seed XOR
(10.4), settle hash chain head (13.2), chain head wire (5.4).

Section 15's vectors pin every one of these. If a vector mismatches, this table is the
first place to look.

---

## 5. The transcript envelope

Every game message is exactly one envelope, and one envelope is exactly one transport
payload. The transcript is the chain of envelopes; client state is a pure fold over it.

### 5.1 Layered signatures, and why

The obvious design -- the sender signs everything including its sequence number --
cannot work under a relay that assigns ordering: a sender does not know its `seq` or
the chain head it will land on. So the signatures are layered:

- the **sender** signs the *content* (what it meant), and
- the **host** signs the *sequenced envelope* (where it landed).

The result is that a host can reorder, delay, or drop messages -- and every such act is
attributable, because the host's own signature is on the ordering -- but it can never
forge, alter, or attribute content.

### 5.2 Construction

```
contentLine = v TAB tableHex TAB hand TAB fromHex TAB type TAB bodyHex

  v        = "1"                            protocol version, decimal text
  tableHex = hex(tableId)                   64 hex chars
  hand     = decimal hand number, 0 = table setup / lobby
  fromHex  = hex(senderPub)                 64 hex chars
  type     = a message type from section 8  ASCII, no tab
  bodyHex  = hex(utf8(bodyText))            possibly empty

senderSig = sign(utf8(contentLine), senderSec)

envLine   = contentLine TAB hex(senderSig) TAB seq TAB prevHex

  seq      = decimal, assigned by the host, strictly increasing from 1
  prevHex  = the chain head this envelope extends, 64 hex chars
             genesis = 64 "0" characters

hostSig   = sign(utf8(envLine), hostSec)

wire      = envLine TAB hex(hostSig)
```

A wire line is therefore **exactly 10 TAB-separated fields**:

```
1  v          6  bodyHex
2  tableHex   7  senderSigHex
3  hand       8  seq
4  fromHex    9  prevHex
5  type      10  hostSigHex
```

A wire line contains no newline; the transcript is a sequence of wire lines.

### 5.3 Chain head

```
chainHead(wire) = H(utf8("HOLDEM-CHAIN-v1|" || wire))
```

The head after applying a wire is `hex(chainHead(wire))`. The genesis head, before any
wire, is 64 zero characters. Each envelope's `prev` field MUST equal the head produced
by the immediately preceding envelope.

### 5.4 Verification -- the drop-or-accept rule

Verification is **shape, then signatures, then binding, then ordering**, in that order,
and any failure at any step is a drop with a log line. Nothing about verification may
raise, panic, or unwind past the receive loop: this path runs on attacker-controlled
bytes.

```
verify(wire, expectedFromPubHex, hostPubHex, expectedPrevHex):
    split wire on TAB into the 10 fields (a short line fails here)

    -- shape first: hex decoding of malformed input must never be reached
    if not isHex(fromHex, 64)      -> drop "malformed"
    if not isHex(hostPubHex, 64)   -> drop "malformed"
    if not isHex(senderSigHex,128) -> drop "malformed"
    if not isHex(hostSigHex, 128)  -> drop "malformed"
    if bodyHex nonempty and not isHex(bodyHex, any even length) -> drop "malformed"

    if expectedFromPubHex given and fromHex != it   -> drop "unknown-from"

    if not verify(senderSig, utf8(contentLine), fromPub)  -> drop "bad-sender-sig"
    if not verify(hostSig,   utf8(envLine),     hostPub)  -> drop "bad-host-sig"

    if expectedPrevHex given and prev != it   -> drop "chain-break"

    accept
```

`isHex(s, n)` is a **pure** predicate -- no decoding, no library call that can throw --
and it is what stands between a hostile frame and a hex decoder. Implement it first.

---

## 6. Transport binding

### 6.1 What the protocol needs from a transport

The protocol assumes a **datagram-ish, peer-addressed, unreliable** transport and
nothing more:

- **Message-oriented**: one payload in, one payload out; no stream framing needed.
- **May lose, duplicate, reorder, and redeliver** payloads. All four are handled at the
  protocol layer (section 7) and none of them is an error.
- **Peer-addressed**: the host can send to one peer or to all admitted peers.
- **Handshake-carried token**: the transport MUST deliver each peer's admission token
  (section 4.4) at connect time, or the implementation MUST send it as the first
  payload and treat a peer that has not presented one as unadmitted.
- **Payload cap**: at least 4 KiB. The largest v1 payload is a full-transcript replay
  line (one wire, well under 2 KiB); Level 2 would need 2 KiB for a `shuffleStep`.
- **Latency**: human turn-rate. The reference transport flushes about once per second.
  Nothing in this protocol is frame-rate sensitive.

The transport does **not** need to be authenticated, ordered, encrypted, or reliable.
Every one of those properties is supplied above it: signatures for authenticity,
`seq` for order, sealed boxes for the two private lanes, resync for reliability.

### 6.2 Frames

Payloads are TAB-framed, first field a frame kind:

| Frame | Direction | Payload | Meaning |
|---|---|---|---|
| `c` | player -> host | `c TAB contentLine TAB senderSigHex` | a signed content line awaiting sequencing |
| `w` | host -> peer(s) | `w TAB wire` | a sequenced, countersigned envelope |
| `s?` | player -> host | `s?` | resync request: please replay the transcript |
| `r!` | host -> one peer | `r! TAB headSeq` | a replay of the log up to `headSeq` follows |

`c` and `w` carry signed data and are the protocol proper. `s?` and `r!` are **unsigned
transport control frames** -- they are not transcript messages, they never touch the
chain, and they are constrained accordingly:

- `s?` is honored **only** by a host, **only** from an already-admitted, connected
  peer, and is rate-limited **per peer** to at most one replay per 2 seconds. Without
  that limit, a flood of `s?` amplifies into unbounded full-transcript replays.
- `r!` is honored **only** from the peer handle currently bound to the pinned host key.
  Accepting it from anyone would let a stranger suppress a victim's emissions
  indefinitely (see 7.5).
- A lost `s?` or `r!` MUST degrade to noise, never to a wedge. `s?` is re-sent by the
  next gap; a lost `r!` merely makes catch-up noisier.

The host relays a player's `c` frame by sequencing it and broadcasting the resulting
`w` frame to **everyone, including the original sender**. A sender learns its own
message was accepted by seeing it come back sequenced. A host that is itself the sender
skips the transport and feeds its own content line straight into the relay.

### 6.3 The reference transport (rp1 over BitTorrent)

The reference implementation uses TorrentXT's `rp1` peer-wire extension, with a phantom
BitTorrent swarm on `infohash` (4.3) as the rendezvous:

- host: add the infohash, `btDhtAnnounce`; player: add the infohash, `btDhtGetPeers`.
- the admission token is published via `btRp1SetToken`, arriving in peers'
  `rp1Handshake` events.
- payloads go through `btRp1Send` and are drained by `btRp1Poll` on a 250 ms tick
  (one drain per tick, never per rendered frame).

**None of this is normative.** An implementation MAY use WebSockets, QUIC, plain TCP,
Tor streams, or a unix socket. Two implementations interoperate if they share a
transport and agree on the frames in 6.2; the signed chain is identical either way.
A pure-TCP implementation of this protocol is a legitimate holde-em client -- it just
cannot join a table whose peers are only reachable over rp1.

---

## 7. Ingest and ordering

This is the algorithm that makes an unreliable transport safe. It is stated as
pseudocode because every clause in it fixed a real failure.

### 7.1 State

```
lastSeq      : integer, highest seq applied              (starts 0)
chainHead    : hex, head after the last applied wire     (starts genesis)
log          : ordered list of applied wire lines
buffer       : map seq -> wire, for out-of-order arrivals (bounded, 64 ahead)
hostPubHex   : the pinned host key                        (from 4.4)
roster       : the host-signed member set                 (from 8.3)
syncCooldown : debounce so resync asks at most ~1 per 2 s
```

### 7.2 Ingest

```
ingest(wire):
    if verify(wire, any-sender, hostPubHex, any-prev) != ok:
        log the drop reason; return                      -- forged/corrupt: a real
                                                         -- rejection, never a resync

    if wire.table != our tableHex:  log; return          -- hard drop, NOT a gap
    if wire.v     != "1":           log; return          -- hard drop, NOT a gap
    if wire.seq is not an integer:  log; return

    if wire.seq <= lastSeq:
        return                                           -- duplicate: drop SILENTLY

    if wire.seq > lastSeq + 1:
        if wire.seq <= lastSeq + 64 and buffer has no entry for seq:
            buffer[wire.seq] = wire
        requestResync()                                  -- debounced
        return

    -- wire.seq == lastSeq + 1
    if wire.prev != chainHead:
        log "chain-break"; requestResync(); return

    apply(wire)
    drainBuffer()
```

### 7.3 Why duplicates drop silently

This is the single most important line in the algorithm. The transport redelivers
constantly and the host rebroadcasts; classifying a redelivered wire as a "chain gap"
(because its `prev` no longer matches the advanced head) makes every redelivery trigger
a resync, whose replayed wires trigger further resyncs. The reference implementation
had exactly this storm, and the table never started.

**Classify by `seq` against `lastSeq`. Never by a bare `prev`-versus-head test.**

The same property makes a full replay idempotent: a caught-up client sheds the entire
replayed prefix silently and resumes from its own head.

### 7.4 Apply

```
apply(wire):
    chainHead = hex(H(utf8("HOLDEM-CHAIN-v1|" || wire)))
    lastSeq   = wire.seq
    append wire to log

    -- sender authority (section 8.3): the chain always advances (refusing a
    -- host-authentic link would wedge the table), but an unrostered sender's
    -- BODY does nothing.
    if wire.from != hostPubHex and wire.from not in roster:
        log "unrostered sender -- body ignored"; return

    dispatch(wire.type, wire.from, utf8Decode(unhex(wire.bodyHex)), wire.hand)

drainBuffer():
    while buffer has lastSeq + 1:
        w = buffer.remove(lastSeq + 1)
        if w.prev != chainHead: break        -- no longer chains; leave it for replay
        apply(w)
```

An **unknown message type advances the chain and does nothing else.** This is the
forward-compatibility rule: a v1 client sitting at a table where some peers emit a
future message type stays in sync rather than wedging.

### 7.5 Catch-up suppression

A client MUST NOT act on intermediate states during a replay. When an `r!` frame
announces a replay up to `headSeq`, the client suspends **all protocol emissions**
until `lastSeq >= headSeq`, then reacts once against the complete transcript.

Without this, a reconnecting client walks its own history, sees at each intermediate
state that it "owes" a commit / seal / reveal it already sent, and re-emits every one of
them -- which the host dutifully sequences onto the live chain as fresh duplicates.

A client that never receives `r!` MUST still converge (the presence guards in 9.3 catch
it at the end); it will simply be noisier. `r!` is an optimization with teeth, not a
correctness requirement.

### 7.6 The universal drop rule

Any malformed, unverifiable, out-of-authority, or unparseable input is **dropped and
logged**. It is never an exception that escapes, never a retry, and never a reason to
tear down the connection. The receive loop MUST survive arbitrary bytes from any peer,
including the host.

---

## 8. Message vocabulary

### 8.1 Types in protocol v1

| Type | From | Hand | Body | Meaning |
|---|---|---|---|---|
| `cfg` | host | 0 | `v=1,level=0,sb=1,bb=2,ante=0,stack=400,seats=6,button=1` | signed table configuration; the first envelope |
| `roster` | host | 0 | `pub:role,pub:role,...` sorted ascending | admitted-member presence |
| `join` | player | 0 | `box=<64hex>` | publishes the session box key; the envelope signature is the binding |
| `sit` | host | 0 | `seat=N,pub=<64hex>` | seat assignment, one wire per seated player |
| `handStart` | host | n | `seats=1\|2\|3,button=B` | opens hand n over these seats |
| `dealLevel` | host | n | `level=0,dealer=<seat>,count=N` | names the deal level, this hand's dealer, and the contributor count |
| `seedCommit` | seat | n | `pos=P,commit=<64hex>` | commitment to this seat's deal seed |
| `seedSeal` | seat | n | `pos=P,sealed=<hex>` | the seed, sealed to the dealer's box key |
| `holeDeliver` | dealer | n | `seat=N,sealed=<hex>` | that seat's two cards, sealed to its box key |
| `bidAnte` | seat | n | `amount=N` | forced ante (dead money) |
| `bidSB` | seat | n | `amount=N` | small blind |
| `bidBB` | seat | n | `amount=N` | big blind |
| `act` | seat | n | `verb=V,amount=N` | `V` in `fold check call bet raise allin` |
| `board` | dealer | n | `street=flop,cards=Qs\|Ah\|2d` | a street; `turn`/`river` carry one card |
| `seedReveal` | seat | n | `pos=P,seed=<64hex>` | opens the commitment at hand end |
| `settle` | host | n | `deltas=1:-4\|2:8\|3:-4` | the hand's chip deltas |
| `receipt` | seat | n | `head=<64hex>,sig=<128hex>` | co-signature on the settlement receipt |
| `audit` | seat | n | `result=pass` or `result=fail:<reason>` | this client's deal audit verdict |

**Reserved and not implemented in v1** (see `holdem-spec.md`): `leave`, `stand`,
`shuffleStep`, `unmaskStep`, `ckpt`, `show`, `muck`, `chat`. A v1 client treats them
as unknown types (7.4).

### 8.2 Position versus seat

`seedCommit`, `seedSeal`, and `seedReveal` are indexed by **contributor position**
`pos`, not by seat: `pos` is the 1-based index of the seat in this hand's
**ascending occupied-seat list**. With seats `2,4,6` dealt in, seat 2 is `pos=1`,
seat 4 is `pos=2`, seat 6 is `pos=3`.

This matters because the seed XOR (10.3) is position-indexed, so sparse seating must
pack down to `1..count` identically on every client. A receiver MUST verify that the
claimed `pos` maps to the sender's actual seat, and drop the message otherwise.

### 8.3 Authority matrix -- who may author what

A body is folded **only** if its author is entitled to it. This is enforced at two
points: the host refuses to sequence a content line it should not (so the message never
reaches the chain), and every client re-checks on fold (so a malicious host gains
nothing by relaying it anyway).

| Type | Authored by | Enforcement |
|---|---|---|
| `cfg`, `roster` | the host key only | host refuses to relay from a non-host; clients ignore the body if `from != host` |
| `sit`, `handStart`, `dealLevel`, `settle` | the host key only | clients ignore the body if `from != host` |
| `holeDeliver`, `board` | this hand's dealer (the seat named by `dealLevel`) | clients ignore the body if `from != pubBySeat[dealerSeat]` |
| `seedCommit`, `seedSeal`, `seedReveal` | the seat that owns `pos` | clients verify `seatAtPos(pos) == seatOf(from)` |
| `bidAnte`, `bidSB`, `bidBB`, `act` | the seat that owns the action | seat is resolved from `from` via `seatByPub`; a seat claimed in a body is never trusted |
| `receipt`, `audit` | any seated player, for itself | seat resolved from `from` |
| `join` | any admitted peer, for itself | the envelope signature is the binding |

**A seat number in a body is never authority.** Authority always flows from the
envelope's `from` field through the host-signed `sit` map. This is what makes an
admitted player unable to act for another seat.

### 8.4 Idempotence

Every fold MUST be idempotent. Concretely: a commitment / seal / delivery / reveal /
receipt that is already recorded for its position or seat is **kept, not replaced, and
not double-counted** (the counters `commitN`, `sealN`, `holeN`, `revealN`, `receiptN`
increment only on first record). `board` is deduped by street-versus-count: `flop`
only when 0 cards are on the board, `turn` only at 3, `river` only at 4 -- a
redelivered flop that appended twice would shift every later board slot and corrupt the
audit.

---

## 9. Table and hand lifecycle

### 9.1 Lobby

```
host                                            player
----                                            ------
create table: tableId, infohash
publish admission token (role=host)
cfg           (seq 1, prev = genesis)
                                          <---- joins swarm, publishes token (role=player)
      <---- rp1 handshake, token verified ----
r! + full log replay  ------------------------>
roster        (host re-signs on every membership change)
                                          <---- join  box=<64hex>   (once rostered)
```

A player emits `join` only after it sees itself in a host-signed `roster` and only if
the transcript does not already carry its box key. Both guards are what make a
reconnect replay quiet.

### 9.2 Starting the game

The host, on operator command, with at least 2 and at most 6 joined players:

1. Collect the pubkeys of admitted peers that have published a box key.
2. **Sort them ascending as hex strings** and assign seats `1..N` in that order.
   (Deterministic, so every client could re-derive it; the `sit` wires make it explicit
   and signed regardless.)
3. Emit one `sit` per player.
4. Emit `handStart` then `dealLevel` for hand 1.

Each `sit` seeds that seat's stack from the signed `cfg`'s `stack` value, **only if the
seat has no stack yet** -- stacks otherwise come from settlement, never from a re-sit.

### 9.3 A hand, end to end

Every client folds the same chain into the same state and then emits **only what its
own seat owes next**. Each emission is guarded twice:

- a **presence guard**: is it already in the folded transcript? (replay-proof)
- a **sent flag**: did this run already emit it? (redelivery-proof)

```
host      handStart seats=..,button=B
host      dealLevel level=0,dealer=B,count=N

each seat seedCommit pos=P,commit=H(seed_P)          <-- all N before any seed moves
each seat seedSeal   pos=P,sealed=seal(seedHex -> dealer boxPub)
                                                      (only once commitN == N)
dealer    opens all N seals, checks each against its commitment,
          derives the deck (section 10), then per seat:
dealer    holeDeliver seat=S,sealed=seal("i,j" -> seat S boxPub)

          (only once holeN == N:)
each seat bidAnte amount=min(ante, stack)            if ante > 0
SB seat   bidSB   amount=min(sb, stack)              once all antes are posted
BB seat   bidBB   amount=min(bb, stack)              once it SEES the SB folded
                                                      -- the two posts cannot race

... betting: act wires, engine-validated by every client (section 12) ...
dealer    board street=flop,cards=a|b|c              when the engine says a street is due
dealer    board street=turn,cards=d
dealer    board street=river,cards=e

each seat seedReveal pos=P,seed=<64hex>              at showdown/handdone
                                                      (verified against its commitment)
host      settle deltas=..                           once revealN == N
                                                      (every client recomputes and
                                                       REFUSES a mismatching settle)
each seat receipt head=..,sig=..                     co-signature
each seat audit   result=pass|fail:<reason>          per-client verdict
host      handStart (next hand) after a short beat
```

The ordering constraints that are **normative**, not stylistic:

1. Every `seedCommit` MUST precede every `seedSeal`. This is the entire anti-stacking
   property: the dealer's own seed is committed before it can see anyone else's.
2. `holeDeliver` for all seats MUST precede the blinds, so no chips move before the
   cards exist.
3. The BB MUST NOT post until it has observed the SB's post on the chain.
4. `seedReveal` MUST NOT be emitted before the hand reaches showdown or handdone.
5. `settle` MUST NOT be emitted before every seed is revealed.

### 9.4 Reconnect

A client that reconnects presents its admission token; the host recognizes a known key
on a new peer handle as a reconnect and replays the whole log (prefixed by `r!`).

The client rebuilds from **nothing but its identity seed and box keypair**:

- seat map, stacks, street, pot, and betting state come from folding the chain;
- its **hole cards** come from re-opening the `holeDeliver` ciphertext, which is on the
  chain (that is why the sealed lanes are carried in-band and not out of band);
- its **deal seed** is re-derived, not remembered (10.1) -- which is the whole reason
  the seed is a PRF of `(idSeed, table, hand)` rather than a random draw.

A correct implementation converges byte-for-byte: same chain head, same seat map, same
stacks, same street, and can finish the hand.

---

## 10. The Level 0 deal

Commit-reveal over a keyed stream. Every value below is pinned in section 15.

### 10.1 Per-hand seed derivation

```
seedHex_P = hex(H(utf8("HOLDEM-SEEDP-v1|" || idSeedHex || "|" || tableHex || "|" || hand)))
```

`idSeedHex` and `tableHex` are 64-character **hex text**; `hand` is decimal text.

Three properties, all required:

- **secret**: keyed by the identity seed, which never leaves the machine, so no other
  player can predict it;
- **fresh**: the hand number is in the input, honoring the freshness law -- nothing
  dealing-related is reused across hands;
- **reconstructible**: a client that crashed mid-hand re-derives the exact seed it
  committed and can still seal and reveal. A randomly drawn seed lives only in RAM, and
  losing it wedges the hand's audit forever.

The seed is 32 bytes, handled as its 64-character hex text everywhere in the protocol.

### 10.2 Commitment

```
commit_P = hex(H(utf8("HOLDEM-SEEDC-v1|") || rawBytes(seedHex_P)))
```

Note the asymmetry against 10.1 and it is deliberate: the **commitment hashes the raw
32 seed bytes**, while the derivation hashes hex text.

A `seedReveal` whose `H(domain || seedBytes)` does not equal the recorded commitment
for that position MUST be refused, logged with the position named, and MUST NOT be
stored. This is an attributable cheat, not a transient error.

### 10.3 Seed XOR

```
seedsXor = seedBytes_1 XOR seedBytes_2 XOR ... XOR seedBytes_N     (32 bytes)
```

over contributor positions `1..N` where `N` is `dealLevel`'s `count`. XOR is
order-independent, so no canonical ordering is needed -- but every client MUST include
exactly the `N` positions and no others.

### 10.4 Stream key and stream

```
streamKey = H( utf8("HOLDEM-SHUF-v1|")
             || tableId          (32 raw bytes)
             || utf8("|" || hand || "|")
             || seedsXor         (32 raw bytes) )

block_j   = H(streamKey || uint32be(j))        j = 0, 1, 2, ...
stream    = block_0 || block_1 || block_2 || ...
```

`uint32be(j)` is 4 bytes, big-endian. 16 blocks (512 bytes) covers a 52-card shuffle
with slack; an implementation MUST extend the stream rather than fail if rejection
sampling exhausts it (astronomically unlikely, but not impossible).

### 10.5 Draw and shuffle

```
draw(n):                                   -- uniform in 1..n, no modulo bias
    limit = floor(2^32 / n) * n
    loop:
        w = next 4 stream bytes, big-endian, as an unsigned 32-bit integer
        if w < limit: return (w mod n) + 1
        -- else reject and consume the next 4 bytes

shuffle():
    deck[1..52] = 1..52
    for i = 52 down to 2:
        j = draw(i)
        swap deck[i], deck[j]
    return deck                            -- deck[1] is the top, dealt first
```

Rejection sampling is **not optional**: a plain `w mod n` biases the deck, and the bias
is detectable over a session. Both the loop direction and the 1-based indexing are part
of the pinned output.

### 10.6 Deal assignment

The consumption order is fixed and public -- there are no cut-card arguments:

```
order = occupied seats, rotated to start immediately after the button
for round in 1..2:
    for seat in order:
        holes[seat] += next card
burn 1
flop  = next 3
burn 1
turn  = next 1
burn 1
river = next 1
```

`occupied` is the ascending seat list from `handStart`. Burn cards are consumed but
never revealed in v1; they are recomputable by anyone from the revealed seeds.

### 10.7 Private lanes

- `seedSeal`: the sender seals **`utf8(seedHex)`** -- the 64-character hex text, not
  the raw seed bytes -- to the dealer's `boxPub`, and publishes the ciphertext as hex.
- `holeDeliver`: the dealer seals **`utf8("i,j")`** -- the two card indices as decimal
  text, comma-joined -- to that seat's `boxPub`.

A receiver MUST validate the plaintext after opening (a 64-hex string; two integers in
`1..52`) and treat garbage as a logged drop. Both ciphertexts live on the chain, which
is what makes the transcript self-contained and replay-sufficient.

### 10.8 Dealer duties and abort

The dealer, once every seal is present:

1. opens every seal with its session box key;
2. checks **each** opened seed against its recorded commitment;
3. **aborts the deal, naming the position, if any check fails** -- it MUST NOT deal
   from a seed set that failed its commitments;
4. otherwise derives the deck (10.4-10.6) and emits one `holeDeliver` per seat, skipping
   any seat the transcript already carries a delivery for (so a reconnected dealer
   re-derives without re-sending).

### 10.9 Audit

At hand end, once every seed is revealed, **every client independently**:

1. re-checks every reveal against its commitment;
2. re-derives the deck and the whole assignment from the revealed seeds;
3. compares against what it *witnessed*: its own delivered hole cards, and the board
   wires;
4. emits `audit result=pass` or `result=fail:<reason>`, where `<reason>` names the first
   failing step -- `commit-mismatch-position-P`, `hole-mismatch-seat-S`, `flop-mismatch`,
   `turn-mismatch`, `river-mismatch`, `reveals-incomplete`.

A client can only verify **its own** sealed delivery; another seat's delivery is covered
by that seat's own audit. That is the accepted limit of Level 0, and it is why the
verdict is broadcast rather than kept private.

**What Level 0 does and does not buy.** The dealer cannot *stack* the deck: its seed was
committed before it saw any other. The dealer *can* see every card that hand -- so the
deal rotates every hand, and the reveal exposes mucked cards after the hand (a visible
house rule). Nobody can rewrite a hand after the fact. Card secrecy from the dealer
requires Level 2 (section 14).

---

## 11. Cards and hand evaluation

### 11.1 Card encoding

```
index i in 1..52
rank(i) = (i - 1) div 4 + 2       -- 2..14, ace high
suit(i) = (i - 1) mod 4 + 1       -- 1..4
name(i) = "23456789TJQKA"[(i-1) div 4] || "cdhs"[(i-1) mod 4]
```

So index 1 is `2c`, index 4 is `2s`, index 52 is `As`. Suits are ordered
clubs, diamonds, hearts, spades and are never used for ranking -- the order exists only
to make the index bijective.

### 11.2 Hand ranking

A 5-card hand ranks to a **12-character decimal string**: six 2-digit fields, category
first, then five tiebreak ranks (zero-padded, unused fields `00`). Fixed width means
ordinary string comparison orders hands correctly, and equal strings mean a tie.

| Category | Code | Tiebreak fields |
|---|---|---|
| straight flush | `08` | high rank, then `00000000` |
| four of a kind | `07` | quad rank, kicker, then `000000` |
| full house | `06` | trip rank, pair rank, then `000000` |
| flush | `05` | five ranks descending |
| straight | `04` | high rank, then `00000000` |
| three of a kind | `03` | trip rank, two kickers descending, then `0000` |
| two pair | `02` | high pair, low pair, kicker, then `0000` |
| one pair | `01` | pair rank, three kickers descending, then `00` |
| high card | `00` | five ranks descending |

The **wheel** (A-2-3-4-5) is a straight with high rank **5**, not 14. `A-K-Q-J-9` is not
a straight. A 7-card hand ranks as the maximum over all 21 five-card subsets.

The evaluator's exact output strings are pinned in `tools/evaluator-kat.py` and verified
exhaustively (all 2,598,960 five-card hands collapse to exactly 7,462 distinct classes)
against an independently written reference in `tools/logic-fuzz.py`. An implementation
MAY use any internal representation, and MUST agree on the ordering; only the ordering
crosses the wire, via settlement.

---

## 12. Betting engine

The engine is a deterministic transition function over the message stream. Every client
runs it over the same chain and MUST reach identical state; a message the engine rejects
is **dropped, and the state is unchanged**. A conforming implementation therefore never
needs to trust another client's arithmetic -- including the host's.

### 12.1 Per-hand state

```
occ         ascending list of seats dealt in this hand
buttonSeat  from handStart
sbSeat      2 players: the button IS the small blind; else the next seat after the button
bbSeat      the next seat after sbSeat
street      preflop | flop | turn | river
phase       blinds | acting | runout | showdown | handdone
toAct       seat that owes action, or 0
betCur      the current bet level on this street (a "to" amount)
raiseFull   the size of the largest full bet/raise this street (starts at bb)
aggressor   last full-raiser this street, or 0
sdFirst     who shows first at showdown
per seat:   stack, streetCommitted, handCommitted, folded, allin, acted
```

`acted` means "has acted **since the last full raise**". It is the flag that implements
the under-raise rule (12.4).

### 12.2 Blinds

- `bidAnte` (only when `ante > 0`): amount MUST equal `min(ante, stack)`. Antes are
  **dead money**: they go to `handCommitted` only, **never** `streetCommitted`, so an
  ante does not reduce what a seat still owes to call the blind. A seat short of the
  ante posts what it has and is all-in for it, side-pot eligible up to its contribution.
  A second ante from the same seat is rejected (`bidAnte-duplicate`).
- `bidSB`: from `sbSeat` only, amount MUST equal `min(sb, stack)`. A second `bidSB` is
  rejected (`bidSB-duplicate`) -- the phase stays `blinds` until the BB posts, so
  without this flag a hand-edited transcript could double-charge the small blind and
  still audit clean.
- `bidBB`: from `bbSeat` only, amount MUST equal `min(bb, stack)`. It sets
  `betCur = bb` and `raiseFull = bb` -- **the full big blind, even when posted short** --
  moves the phase to `acting`, and passes action on.

### 12.3 Actions

`act` carries `verb` and `amount`. Amounts are exact, not advisory: a mismatching
amount is a rejection, not a correction. This makes every action self-describing in the
transcript, so a replay needs no engine state to read what happened.

| Verb | `amount` | Legality |
|---|---|---|
| `fold` | ignored | always legal in turn |
| `check` | ignored | only when `streetCommitted == betCur` |
| `call` | MUST equal `min(betCur - streetCommitted, stack)` | only when something is owed |
| `bet` | the **to** amount | only when `betCur == 0` |
| `raise` | the **to** amount | only when `betCur > 0` |
| `allin` | MUST equal `streetCommitted + stack` | always legal in turn |

`bet` and `raise` amounts are **"to" totals for the street**, not increments. All
amounts MUST be integers; a non-integer or non-numeric amount is rejected outright
(`act-bad-amount`) -- a fractional amount flows into the side-pot division and can mint
chips that a replay audit would then stamp as clean.

Common rejections, by name: `act-out-of-phase`, `act-out-of-turn`, `check-facing-bet`,
`call-wrong-amount`, `call-nothing-to-call`, `bet-facing-bet-use-raise`,
`raise-nothing-to-raise-use-bet`, `raise-not-above-bet`, `raise-beyond-stack`,
`raise-below-minimum`, `raise-not-reopened`, `allin-wrong-amount`.

### 12.4 Raising, and the under-raise rule

```
increment = target - betCur
isAllin   = (target - streetCommitted) == stack

reject if increment < raiseFull and not isAllin        -- below the minimum
reject if acted[seat] is true                          -- betting is not open to you
apply the payment; betCur = target; aggressor = seat; acted[seat] = true

if increment >= raiseFull:                             -- a FULL raise
    raiseFull = increment
    acted[other seats] = false                         -- action reopens for everyone
```

An all-in **below** the minimum raise does **not** reopen betting for players who have
already acted: they may call or fold, not re-raise. This is deliberately **per-wager** --
several short all-ins that only *cumulatively* amount to a full raise still do not
reopen. (The TDA's cumulative reading is the stricter tournament rule; the per-wager pin
is simpler, is pinned on both sides of the test suite, and is the as-built behavior.
Changing it is a consensus break, not a preference.)

### 12.5 Street close and advance

A street closes when no seat is pending (in hand, with chips, and either facing a bigger
bet or not yet acted since the last full raise). On close:

```
sdFirst = aggressor, or the first in-hand seat after the button if there was none
reset every seat's streetCommitted and acted
betCur = 0; raiseFull = bb; aggressor = 0

if street == river:                    phase = showdown
else if fewer than 2 seats can still bet:  phase = runout
else:                                  advance the street;
                                       toAct = first pending seat after the button;
                                       phase = acting
```

In `runout`, `board` messages advance the street (there is no more action to take), and
the river's board moves the phase to `showdown`. In normal play the engine has already
advanced at street close, and the `board` message is only the record.

A `fold` that leaves one seat in hand ends the hand immediately: `phase = handdone`,
and that seat takes the pot uncontested (12.6 handles it without ranks).

### 12.6 Showdown order

Last aggressor of the final street first, then clockwise. If there was no aggressor
(or that seat folded), the first in-hand seat clockwise from the button shows first.

---

## 13. Settlement, receipts, audit

### 13.1 The settlement function

Settlement is a **pure function of the folded hand state and the showdown ranks**, and
every client computes it independently. Showdown ranks come from the **revealed seeds**
-- the deck is re-derived, hole cards fall out of the assignment -- never from a player's
claim about its own hand. A player cannot lie about a showdown because it never gets to
assert one.

```
settle(state, ranks) -> delta per seat

for each seat: delta[seat] = -handCommitted[seat]

levels = distinct positive handCommitted values, ascending
prev = 0
for level in levels:
    layer = sum over all seats of max(0, min(handCommitted[seat], level) - prev)
    eligible = unfolded seats with handCommitted >= level

    if eligible is empty:                       -- everyone who covered this layer folded
        refund each contributor its own slice
        prev = level; continue

    best    = max rank among eligible           -- a single eligible seat wins uncontested
    winners = eligible seats with rank == best
    share     = layer div count(winners)
    remainder = layer mod count(winners)
    each winner receives share
    walk the seats clockwise from the button, giving 1 extra chip to each winner
      encountered, until remainder is exhausted
    prev = level
```

Side pots are therefore **layered by all-in level and awarded independently**, and the
odd chip goes to the first winning seat clockwise from the button. Chip conservation is
exact: the deltas sum to zero, always.

The `settle` body renders the deltas over `occ` in ascending seat order:

```
deltas=1:-4|2:8|3:-4
```

### 13.2 The settle hash

```
deltasCSV  = the same pairs, joined with "," instead of "|"     -- "1:-4,2:8,3:-4"
settleHash = hex(H( utf8("HOLDEM-SETL-v1|" || deltasCSV || "|") || chainHeadBytes ))
```

`chainHeadBytes` is the 32 raw bytes of the chain head **after the `settle` wire itself
has been applied** -- the head that includes the settle envelope, not the one before it.

### 13.3 Receipts

```
receiptHead = hex(H(utf8("HOLDEM-RCPT-v1|" || settleHashHex || "|" || prevReceiptHex)))
receiptSig  = sign(utf8("HOLDEM-RSIG-v1|" || receiptHeadHex), idSec)
```

The first hand's `prevReceiptHex` is 64 zeros. Each hand's receipt head commits to its
predecessor, so a table session produces **one countersigned ledger no subset of players
can rewrite**. A hand is **closed** when every seated player's receipt signature over the
same head is on the chain.

A `receipt` whose `head` does not equal the receiver's own computed receipt head, or
whose signature does not verify, is dropped.

Receipts -- not balances, not claimed deltas -- are the interface any future value layer
consumes. See `holdem-spec.md` section 13 before attaching anything of value.

### 13.4 Checkpoints (reserved)

```
ckptSig = sign(utf8("HOLDEM-CKPT-v1|" || chainHeadHex), idSec)
```

A player's signature over the chain head at a street boundary. If two players' `ckpt`
messages sign different heads for the same point, the host forked the transcript --
attributable equivocation. The construction is specified and pinned; the `ckpt` message
type is **not emitted in v1**.

### 13.5 Refusing a bad settle

Every client recomputes `settle` before folding the host's. **A `settle` that disagrees
with the client's own recomputation is refused outright**: no chips move, the hand does
not complete, and the disagreement is surfaced. This is deliberate -- following a
provably wrong host is worse than stalling, and the transcript preserves the evidence
either way.

A `settle` arriving before the reveals are complete is dropped (the client cannot yet
recompute, so it cannot yet consent).

---

## 14. Reserved: Levels 1 and 2

Not part of protocol v1. Specified, with the reasoning, in `holdem-spec.md`:

- **Level 1** (spec 7.2) -- the same protocol with the dealer role held by a non-playing
  machine reachable as a Tor v3 onion service. No wire-format change; a different
  occupant of the dealer seat.
- **Level 2** (spec 7.3) -- ristretto255 mental poker: commutative masking, no dealer at
  all, nobody sees a card they are not entitled to. Adds `shuffleStep` and `unmaskStep`
  to the vocabulary, makes `show`/`muck` meaningful (a showdown reveals the player's
  per-hand scalar), and adds the void-and-audit rule. Requires a ristretto255 surface,
  hash-to-group for card points (`HOLDEM-CARD-v1|`), and per-hand scalars.

An implementation targeting v1 MUST reject `dealLevel` bodies with `level` other than
`0`, rather than silently continuing.

---

## 15. Conformance

### 15.1 Vectors

`tools/protocol-kat.py` is both the vector generator and a second independent
implementation of the crypto path (its embedded Ed25519 is validated against libsodium
vectors on every run, so a bug in it cannot silently re-pin the protocol).

```sh
python3 tools/protocol-kat.py                # verify against the pinned values
python3 tools/protocol-kat.py --json         # emit the vectors as JSON for your tests
python3 tools/protocol-kat.py --print-pinned # regenerate the pinned block
```

All fixtures derive deterministically from tagged strings, so the whole vector set is
reproducible from that file alone:

```
tableId  = H("HOLDEM-KAT-v1|table")
idSeed_i = H("HOLDEM-KAT-v1|identity|" || byte(i))     i = 1,2,3
seed_i   = H("HOLDEM-KAT-v1|seed|"     || byte(i))     i = 1,2,3
hand = 1, occupied = [1,2,3], button = 1, host = identity 1
```

Selected pinned values (the full set is in `PINNED` in that file):

```
table          e52675650d7ad48c7129185efdaec1e2b89cc410d8e4c8e085bcd652187b27d3
idPub_1        b6ef1a19d789c27bea3f6c127db635929541f34907750ee12d0b715c010c7566
idPub_2        833fed8ee30a882bd877555a9df260d4322224fa095513d84972a660e7ad6b10
idPub_3        ad1d6dbbd062cdacf356daf0834471b6246105b17e3b988dd5e7f0db45fb66a6

seed_1         6c10d2dcff41a1a7e8bd9c7530052c7eb91b91808ee5d935e5f56098539eea3c
commit_1       7623721b5a6372fa974ed62f558fce9992259eb2a834ece7bcea66bce970c0e3
seedsXor       73e2b09387940cf29398389f4d4fef74987ffac3c369b68cb522ded044cb00b8
streamKey      e4d91a49ee23982afb804fd386cbd3d2df6370ae0a743b0f461325b94818e40f
streamBlock0   22a256dd9846bb3d40d24d3d5441cdf5415e9fb3532ba99f4f4812630941108d

deck           Ks,4d,3c,Tc,9h,8c,Jd,4h,2c,6d,9d,Th,3d,9s,5s,3h,Qc,2h,9c,8h,7c,Js,
               7s,2d,6s,Ac,8s,As,Kh,2s,Ah,5h,Jh,Jc,4c,7h,6c,8d,Ad,Kd,Qs,Kc,6h,Qd,
               7d,5d,Qh,Ts,5c,3s,4s,Td
holes seat 1   3c,8c          seat 2   Ks,Tc          seat 3   4d,9h
flop           4h,2c,6d       turn     Th             river    9s
burns          Jd,9d,3d

settleHash     68095dcf5a74fac1e1340a1073a466dcf117024257f5c265de21698257b34b6f
receiptHead1   53ed9ccc64863dc05c1b76cd7953e19bba73895b8dd22ea00e6c9ff40f423cef
receiptHead2   0284af24c750eaaaa5a521b87d8f1ab6ce00b0b2be074ce03d24884e004fc910
lobbyCfgBody   v=1,level=0,sb=1,bb=2,ante=0,stack=400,seats=6,button=1
rosterBody     833fed...6b10:player,b6ef1a...7566:host       (sorted ascending)
```

Deal-order signatures pin the wrap-around, sparse-seat, and heads-up cases over the
identity deck `1..52` (`occupied|button`):

```
1,2,3|3        1=1-4;2=2-5;3=3-6 flop=8-9-10 turn=12 river=14
2,4,6|4        2=2-5;4=3-6;6=1-4 flop=8-9-10 turn=12 river=14
1,2|1          1=2-4;2=1-3 flop=6-7-8 turn=10 river=12
3,5|5          3=1-3;5=2-4 flop=6-7-8 turn=10 river=12
1,2,3,4,5,6|4  1=3-9;2=4-10;3=5-11;4=6-12;5=1-7;6=2-8 flop=14-15-16 turn=18 river=20
```

The full envelope vector `env0_wire` (a `cfg` at seq 1 from genesis) is in the KAT file;
reproducing it byte-for-byte proves your content line, signature encoding, field order,
and hex casing all match.

**Note on the KAT's six-envelope transcript**: it is an *envelope-framing* fixture, so
its `seedCommit` bodies are bare commitment hex rather than the `pos=..,commit=..`
grammar of section 8.1. The framing is what is pinned there; the body grammars are
pinned by the reference implementation and this document.

### 15.2 Conformance checklist

An implementation is **wire-conformant** if it:

1. reproduces `env0_wire`, `chain_heads`, and `admit_sig` byte for byte;
2. reproduces `commits`, `seeds_xor`, `stream_key`, `deck`, `holes`, `flop`, `turn`,
   `river`, `burns`, and all five deal-order signatures;
3. reproduces `settle_hash`, `receipt_head1`, `receipt_head2`, `receipt_sigs`,
   `ckpt_sig`, `roster_body`, and `lobby_head2`;
4. drops -- without raising -- every malformed input class in 5.5 and 7.2, including a
   truncated wire, a non-hex body, a wrong-table wire, a wrong-version wire, a bad
   sender signature, a bad host signature, and a stale `seq`;
5. classifies duplicates by `seq` and does not resync on them (7.3);
6. enforces the full authority matrix in 8.3, in particular refusing an out-of-turn
   `act`, a non-host `settle`, a non-dealer `board`, and a `seedReveal` that breaks its
   commitment;
7. refuses a host `settle` that disagrees with its own recomputation (13.5).

An implementation is **game-conformant** if, additionally, its betting engine and
settlement agree with `tools/betting-kat.py` and its evaluator with
`tools/evaluator-kat.py`.

### 15.3 Interop smoke test

The cheapest end-to-end check, and the one worth writing first:

1. Point your client at a reference-implementation host and complete the lobby
   handshake -- you should receive `cfg` and `roster`, and your `join` should come back
   sequenced.
2. Sit through one hand emitting only `seedCommit`, `seedSeal`, blinds, `fold`, and
   `seedReveal`. Folding immediately keeps the betting surface out of the first test.
3. Verify that your recomputed `settle` matches the host's and that your `receipt`
   signature is accepted.

If that passes, the remaining work is the betting engine, which is testable offline
against the KATs with no network at all.

---

## 16. Versioning and consensus changes

The envelope `v` field is `"1"`. A receiver MUST hard-drop an envelope whose `v` is not
a version it implements -- an unrecognized version is not a chain gap and MUST NOT
trigger a resync.

The following are **consensus breaks**: they change the bytes every client hashes and
signs, so every client at a table must update together.

- any change to the envelope field order, delimiter, or hex casing;
- any change to a domain-separation tag (which is why they are versioned);
- any change to the shuffle stream, draw, or deal-assignment order;
- any change to the betting rules that changes a legal action set or an amount
  (including the per-wager under-raise pin in 12.4);
- any change to side-pot layering or the odd-chip rule;
- any change to the settlement or receipt hash inputs.

The following are **not** consensus breaks and MAY be deployed piecemeal: transport
choice, poll cadence, reorder-buffer depth, resync debounce, UI, presentation, seat
assignment heuristics that are anyway made explicit by signed `sit` wires, and new
message types (existing clients advance the chain past what they do not know, per 7.4).

A consensus break requires: a new `v`, regenerated KAT vectors
(`tools/protocol-kat.py --print-pinned`), and an update to this document.

---

## 17. Appendix: reference pseudocode

Language-neutral, ordered so each routine only uses the ones above it.

```
-- primitives ------------------------------------------------------------
H(b)                = blake2b(b, digest_size=32)
sign(msg, sec)      = ed25519_detached(msg, sec)
verify(sig,msg,pub) = ed25519_verify_detached(sig, msg, pub)   -- never throws
seal(msg, pub)      = crypto_box_seal(msg, pub)
sealOpen(ct,pub,sec)= crypto_box_seal_open(ct, pub, sec)       -- failure is a drop

isHex(s, n):
    if len(s) == 0 or len(s) is odd: return false
    if n > 0 and len(s) != n:        return false
    return every char of s is in "0123456789abcdefABCDEF"

-- identity and table ----------------------------------------------------
idSeed          = randombytes(32)                       -- persisted
(idPub, idSec)  = keypair(idSeed)
boxSeed         = H(utf8("HOLDEM-SESS-v1|" + hex(idSeed)))
(boxPub,boxSec) = boxKeypair(boxSeed)
tableId         = randombytes(32)                       -- host only
infohash        = hex(H(tableId))[0:40]

admitToken(tableHex, pubHex, sec, role):
    msg = utf8("HOLDEM-SESS-v1|" + tableHex + "|" + pubHex + "|" + role)
    return utf8(pubHex + TAB + role + TAB + hex(sign(msg, sec)))

-- envelope --------------------------------------------------------------
contentLine(table, hand, from, type, body):
    return "1" +TAB+ table +TAB+ str(hand) +TAB+ from +TAB+ type
                +TAB+ hex(utf8(body))

buildWire(content, senderSec, seq, prevHex, hostSec):
    sSig = hex(sign(utf8(content), senderSec))
    env  = content +TAB+ sSig +TAB+ str(seq) +TAB+ prevHex
    hSig = hex(sign(utf8(env), hostSec))
    return env +TAB+ hSig

chainNext(wire) = hex(H(utf8("HOLDEM-CHAIN-v1|" + wire)))

-- level 0 deal ----------------------------------------------------------
handSeed(idSeedHex, tableHex, hand):
    return hex(H(utf8("HOLDEM-SEEDP-v1|" + idSeedHex + "|" + tableHex
                      + "|" + str(hand))))

seedCommit(seedHex) = hex(H(utf8("HOLDEM-SEEDC-v1|") + unhex(seedHex)))

streamKey(tableId, hand, seedsXor):
    return H(utf8("HOLDEM-SHUF-v1|") + tableId
             + utf8("|" + str(hand) + "|") + seedsXor)

streamBytes(key, nblocks):
    return concat over j in 0..nblocks-1 of H(key + uint32be(j))

draw(stream, offset, n):
    limit = (2^32 div n) * n
    loop:
        w = be32(stream[offset : offset+4]); offset += 4
        if w < limit: return ((w mod n) + 1, offset)

shuffle(stream):
    deck = [1..52]; offset = 0
    for i = 52 down to 2:
        (j, offset) = draw(stream, offset, i)
        swap deck[i], deck[j]                    -- 1-based
    return deck

dealAssign(deck, occupied, button):
    order = occupied rotated to start after button
    p = 0; holes = {}
    repeat 2 times: for s in order: p += 1; holes[s].append(deck[p])
    p += 1                                       -- burn
    flop = deck[p+1 .. p+3]; p += 3
    p += 1                                       -- burn
    turn = deck[p+1];        p += 1
    p += 1                                       -- burn
    river = deck[p+1]
    return (holes, flop, turn, river)

-- settlement ------------------------------------------------------------
settleHash(deltasCSV, chainHeadBytes):
    return hex(H(utf8("HOLDEM-SETL-v1|" + deltasCSV + "|") + chainHeadBytes))

receiptHead(settleHashHex, prevRcptHex):
    return hex(H(utf8("HOLDEM-RCPT-v1|" + settleHashHex + "|" + prevRcptHex)))

receiptSig(rcptHeadHex, sec):
    return hex(sign(utf8("HOLDEM-RSIG-v1|" + rcptHeadHex), sec))

ckptSig(chainHeadHex, sec):
    return hex(sign(utf8("HOLDEM-CKPT-v1|" + chainHeadHex), sec))
```

---

## 18. Implementation notes for porters

Things that bit the reference implementation and will bite yours:

- **Verify before you decode.** `isHex` exists because a hex decoder that throws on
  malformed input, called on unverified wire bytes, turns one hostile frame into a dead
  receive loop. Shape-check every hex field before decoding it.
- **Classify duplicates by `seq`, never by `prev`.** See 7.3. This is the difference
  between a table that starts and one that resync-storms forever.
- **Guard every emission twice** -- presence in the transcript, and a per-run sent flag.
  One guard is not enough: presence alone loses to in-flight messages, the flag alone
  loses to a reconnect.
- **Suspend emissions during catch-up.** See 7.5.
- **Hex text versus raw bytes.** See 4.6. Three of the ten hash constructions hash hex
  text; getting one wrong produces a plausible-looking chain that nobody else agrees
  with.
- **The BLAKE2b digest length is a parameter, not a truncation.** See 2.1.
- **Amounts are exact and integral.** A helpful client that rounds, clamps, or corrects
  an amount desynchronizes from every other client and its "correction" is signed
  evidence of it.
- **Nothing in the receive path may raise.** Drop and log, always.

If your implementation reproduces section 15's vectors, plays one hand against the
reference host, and refuses a lying `settle`, it is a holde-em client.
