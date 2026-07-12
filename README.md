# holde-em

**Serverless online no-limit Texas Hold'em for OpenXTalk (OXT) and the xTalk family**
(also LiveCode 9.6.3+). No accounts, no server: players meet over the BitTorrent DHT,
every action lives in a signed, hash-chained transcript, and the deal runs on a
security ladder that tops out at a **ristretto255 mental-poker shuffle** — nobody, not
even the table host, can see a card they are not entitled to, and every completed hand
is verifiable after the fact.

Built by composing the OXT extension family:

| Extension | Provides |
|---|---|
| [TorrentXT](https://github.com/SethMorrowSoftware/TorrentXT) | rp1 peer messaging, DHT rendezvous (the table code IS the invite), BEP44 signed standings |
| [SodiumXT](https://github.com/SethMorrowSoftware/SodiumXT) | identities, sealed lanes, commitments, randomness — and (planned) the ristretto255 surface the mental-poker deal needs |
| [OnionXT](https://github.com/SethMorrowSoftware/OnionXT) | optional: anonymous tables over Tor, and onion-hosted deck oracles |
| [Box2Dxt](https://github.com/SethMorrowSoftware/Box2Dxt) | the Kit: spritesheet card animation and physics chips |

## Status

**Phase 2 online lobby + Phase 1 hotseat, one paste-and-run stack.**
`src/holdem.livecodescript` is the whole thing — the hotseat game, the online lobby, its
self-test (`heRunSelftest` in the message box), and SodiumXT/TorrentXT diagnostics
(`heProbeSodium` / `heProbeTorrent`) — in a single self-building stack with no required
extensions to be playable hotseat. The table shows per-seat names, chip totals, bets in
front, dealer/blind badges, and fold/all-in/acting/winner states, with quick-bet
controls. The deal is a pure-integer PRNG shuffle so the playable path never touches FFI
binary; the cryptographic Level 0 deal (spec 7.1) is KAT-pinned and drives the online
path.

With **SodiumXT + TorrentXT** installed, the stack opens on an **online lobby**: Create a
table (its 64-hex code is the invite) or Join one, and peers meet over the BitTorrent
DHT. Every peer admits-or-drops others at handshake against a signed session token; the
host catches each new joiner up by replaying the whole signed, hash-chained wire log from
genesis (the spec 9 reconnect seam); and a signed `cfg` + `roster` presence pair
propagates so every client verifies (or drops) it and the roster stays in agreement. The
overlay shows the live peer roster and a feed of every verify/drop verdict. The presence
wires are machine-pinned in `tools/protocol-kat.py` and re-checked on-engine by
`heTestLobbyRun`; the transport itself is verified statically and needs an OXT pass (two
machines, one code). Online betting/dealing orchestration builds on this confirmed
transport next.

The math is **verified sound** by `tools/logic-fuzz.py`, which checks the committed logic
against *independently-written* references (not the line-for-line KAT mirrors): the
evaluator is verified **exhaustively** over all 2,598,960 five-card hands (exactly 7462
equivalence classes, order-isomorphic to a second evaluator), and side-pot settlement and
whole games (chip conservation, no negative stacks, termination) are fuzzed over ~90k
random configs with fixed seeds — zero defects. Blind scheduling uses a dead-button-aware
rule (the big blind always advances to the next live seat, so eliminations never double-
or skip-charge a blind). All of this runs headless in CI (`tools/*-kat.py` +
`tools/logic-fuzz.py`). Everything visual is "verified statically; needs an OXT pass".

- **[holdem-spec.md](holdem-spec.md)** — the design contract: threat model, the
  three-level deal protocol ladder, the transcript, settlement receipts, and the honest
  non-goals (read section 13 before ever thinking about real stakes).
- **[IMPLEMENTATION-PLAN.md](IMPLEMENTATION-PLAN.md)** — the build order, Phase 0
  (bootstrap) through Phase 5 (hardening), with exit criteria per phase.
- **[CLAUDE.md](CLAUDE.md)** — the engineering playbook: everything about OXT /
  LiveCodeScript / LCB, the required extensions and their APIs, and every carried
  lesson from the sibling repos.

## Development

There is no headless way to compile or run a `.livecodescript`; the automated safety
net is the static gate — run it after every script edit:

```sh
python3 tools/check-livecodescript.py
```

Everything else (anything visual, timed, or extension-touching) is "verified
statically; needs an OXT pass" until a human confirms it in the IDE. See CLAUDE.md for
the full workflow.

---

*Seeded from the [Box2Dxt](https://github.com/SethMorrowSoftware/Box2Dxt) repository
(`docs/holde-em/`), where the spec was first developed.*
