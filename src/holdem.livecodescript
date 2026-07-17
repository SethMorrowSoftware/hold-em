script "Holdem"
/*
holdem.livecodescript -- serverless no-limit Texas Hold'em for OXT (holde-em).

ONE self-contained, paste-and-run stack: the hotseat game plus its own
self-test harness (call heRunSelftest in the message box). No second stack,
no required extensions to be playable.

v0.13.1 -- kit setup debugging. heProbeKit now does LIVE checks (not the cached
heHasKit) so it reflects the current state right after you load the Kit, reports
whether the "box2dxt-kit" stack is loaded AND whether the b2k* handlers are on the
message path, and names the exact gap + the fix (the Kit is a SEPARATE stack, not
pasted into this script). New heKitReload clears the cached probe, removes pooled
sprites, and re-runs heKitTryInit -- the message-box command to run after loading the
Kit / saving the stack / moving the assets (heKitTryInit only runs at first build, so
a freshly-added Kit needs this).

v0.13.0 -- actually RENDER the Kenney card art in kit mode (against the real
Box2Dxt kit API, read from the sibling repo -- not guessed). Two things were
missing: (1) b2kSheetLoadAtlas takes the PNG path (the .xml is its optional 2nd
arg) -- the loader was passing the .xml, so the sheet never loaded; fixed, and it
now passes PNG + sibling .xml explicitly. (2) Nothing drew sprites: the display
path still wrote flat glyph fields. Now heKitTryInit resolves the frame ".png"
suffix at load (b2kSheetHasFrame -- gotcha 24), scales the sheet to the slot width
(b2kSheetFrameSize), pre-warms every face, and POOLS one bodiless b2kSpriteNew over
each card slot; heUIShowCardIn swaps the pooled sprite's frame (b2kSpriteSetFrame)
and shows it (hiding the flat field), heUIClearCards hides them between hands. Every
kit call is guarded -- any hiccup falls back to the flat glyph card, never breaks a
deal. New heProbeKit diagnostic (run it in the message box) reports Kit presence,
the resolved atlas path + existence, loaded frame counts, the suffix, UI mode, and
the pooled sprite count. Backs sheet is loaded + sized too (face-down is a follow-up).
NEEDS AN OXT PASS to confirm sprite anchor/scale/z-order; degrades to flat if not.

v0.12.2 -- auto-locate the card atlas. heKitTryInit now defaults the atlas + backs
paths to assets/cards/ sitting NEXT TO the saved stack file (heStackFolder derives
the folder from the stack's own filename), so dropping the assets folder beside the
stack just works with no path to configure. An explicit uHeAtlasPath/uHeBacksPath
still overrides; an unsaved paste-and-run stack (no folder) needs the manual path or
a one-time save. Placement documented in assets/cards/NOTICE.md.

v0.12.1 -- card backs. Vendored the Kenney "Playing Cards Pack" card-back sheet
(assets/cards/playingCardBacks.png + .xml, CC0; 15 designs blue/green/red x5) for
face-down cards, alongside the faces. Added the kHeCardBackFrame constant (default
"cardBack_red2") and a guarded backs-atlas load in heKitTryInit (via uHeBacksPath).
tools/atlas-kat.py now also pins that the chosen back frame exists in the backs
atlas and that all back rects fit the sheet. Note: Kenney's card collection has
cards/backs/jokers/dice but NO poker chips -- chips stay procedural (a colored disc)
unless a dedicated CC0 chip pack is added.

v0.12.0 -- real card art (kit mode). Vendored the Kenney "Playing Cards Pack"
spritesheet (assets/cards/playingCards.png + .xml, CC0) -- the 52-card TextureAtlas
Box2Dxt's foreign-sheet loader parses. Added heKenneyFrame, mapping each internal
card id to its atlas frame (As -> cardSpadesA, Ts -> cardSpades10), and repointed
heKitTryInit's icon pre-warm at those real frame names (the old loop warmed "7s"/
"back", which exist in no Kenney atlas and threw). tools/atlas-kat.py pins in CI
that all 52 cards resolve to frames present in the atlas and that every frame rect
fits the sheet. The atlas load path + frame ".png" suffix + the actual card-sprite
RENDER wiring (b2kSprite*) still need the Box2Dxt api-reference and an OXT pass;
kit mode falls back to the flat glyph cards until then. Point uHeAtlasPath at the
vendored atlas to enable it.

v0.11.1 -- OXT-pass fix: the History panel folded to pot 0 / settle-MISMATCH on
every hand after an online Create/Join. Root cause: the online lobby and the
hotseat game share gGame["log"], but a hotseat line is 4 tab-fields
(handNum|from|type|body) while an online wire is a 10-field signed envelope whose
3rd field is the hand number, not the type. heTableCreate/heTableJoin clears the
log and appends a wire cfg (which carries sb/bb but NO per-seat stacks); leaving
to hotseat then appended hands onto a log with no readable hotseat cfg, so the
fold seeded heBetNewHand with empty stakes/stacks, every blind was rejected, the
pot stayed 0, and the (correct, non-zero) live settle lines all showed MISMATCH.
The live game itself was always correct. Fix: heBtnLeave starts a fresh hotseat
table (clean cfg) unless the log is already a clean hotseat transcript
(heLogIsCleanHotseat), so a peek at the lobby and back preserves a running game.
Harness v28.

v0.11.0 -- deep-dive alpha-readiness audit (9-dimension adversarial review).
Fixes two shipped-path defects the KATs could not see (they mirror the pure
engine, not the impure driver): (P0) heHandStart capped the blind from the
PRE-ante bankroll while the engine validates against the POST-ante stack, so a
blind seat short after its ante had its SB/BB rejected -- dropping the small
blind or wedging the hand in tournament (ante) play; now capped from the engine
stack, pinned by new heTestAnteRun asserts. (P1) a Deal click during the
"between" result-pause left the prior hand's heNextHandTick pending, which could
auto-deal an extra hand -- heCancelPacedSteps now sweeps in-flight paced sends at
heHandStart. Online transport (lobby-only) hardened: envelope table-id/version
bound on ingest; roster/cfg folded only from the host key (relay + ingest);
per-peer "s?" replay rate-limit; heNetStop cancels the poll tick (no forked poll
loop); stale peer handle pruned on reconnect; trust-on-first-use host-key pinning
with a conflict warning; throw-safe rp1 dispatch. CI gates hardened: the vacuous
evaluator-kat antisymmetry tautology replaced with a real check, and
check-livecodescript now catches gotcha 29 (constant used above its declaration)
and gotcha 11 (local inside a block). The "provably unstackable" wording is
corrected to "tamper-evident / consistent with the revealed seeds" -- adversarial
unstackability against a cheating dealer needs independent per-player seeds
(spec 7.1 online deal), still future work. Harness v27.

v0.5.1-0.5.6 -- audit hardening + provability. A four-way audit (protocol,
pure-logic, OXT-dialect, coverage) drove: restored dropped deal KAT constants
that silently broke heTestDealRun + a new gate for undeclared k-constants;
verify-or-drop can no longer throw on a malformed frame (heIsHex before every
decode, H4); chain-gap recovery so a lost rp1 wire no longer wedges a client
(heNetRequestSync + s? replay, spec 9); tools/logic-fuzz.py proving the RULES
against independent references (exhaustive evaluator = 7462 classes + exact
category frequencies + 5/7-card order-isomorphism; peel-based settlement; whole
-game conservation). heRank5 no longer depends on a stable sort (precomputed
composite key). Auditable HAND HISTORY: heFoldTranscript emits a per-hand record
(board/pot/winner/showdown/deltas) with a re-verified settle verdict, surfaced
in a History panel with a "Copy transcript" export, independently pinned by
tools/fold-kat.py. All verified statically / by KAT; the History panel, the
heRank5 sort, and the transport need an OXT pass.

v0.5.0 -- Phase 2e: the online LOBBY. Create or join a table over the DHT and
watch the real transport work end to end -- peers admit-or-drop at handshake
(signed session tokens), the host catches every new joiner up by replaying the
whole signed wire log from genesis (spec 9 reconnect seam), and a signed,
hash-chained cfg + roster presence pair propagates to everyone so each client
verifies (or drops) it and the roster stays in agreement. The overlay shows the
live peer roster and a network-activity feed of every verify/drop verdict. The
new heTestLobbyRun section machine-checks the exact presence wires (canonical
roster body, cfg+roster chain head, verify-or-drop, out-of-order chain break)
against tools/protocol-kat.py with no network -- so CI pins the code path the
transport carries. The lobby transport itself is verified statically and needs
an OXT pass (two machines, one invite code).

v0.4.0 -- Phase 2 (online) foundation. The sxHash mystery is resolved: it
needs an OUTPUT-LENGTH argument, sxHash(data, 32) -- calling it with one arg
was the throw that blocked every earlier crypto attempt. With that fixed the
crypto seams are correct against SodiumXT's real API (sxSignKeypairFromSeed
is a command with out-params; sxSeal/sxSealOpen for hole delivery), and the
signed, hash-chained transcript envelope (spec 6) is implemented and pinned
by tools/protocol-kat.py, re-checked on-engine by heTestCryptoRun. heProbe-
Sodium / heProbeTorrent exercise the full crypto + transport surface. The
online transport wiring (rendezvous, rp1, live deal) is the next increment.

v0.3.0 -- richer chip-forward table UI (per-seat panels with names, chip
totals, bets-in-front, dealer/blind badges, folded/all-in/acting/winner
states, pot display, quick-bet buttons, suit-glyph cards) and a
dead-button-aware blind schedule (the big blind always advances to the next
live seat, so eliminations never double- or skip-charge a blind -- TDA rule
10). The math (side pots, chip conservation, min-raise, PRNG, evaluator) is
verified sound by tools/logic-fuzz.py, which checks the evaluator EXHAUSTIVELY
(all 2,598,960 five-card hands) and fuzzes settlement + whole games against
independently-written references (not the KAT mirrors) over ~90k configs.

v0.2.0 -- binary-free playable path. The first OXT passes hit repeated
double/binary conversion errors wherever script code touched FFI-bridged
binary (SodiumXT Data) through the chunk/arithmetic evaluator. This version
removes that entire class from the playable path:

  * The deal's randomness is a pure-INTEGER PRNG (Park-Miller MINSTD: only
    +, *, and mod, every product < 2^53 so it is exact in a double). It is
    seeded from sxRandomUniform when SodiumXT is present -- sxRandomUniform
    returns an integer, so no binary ever crosses into script -- and from
    engine time+random as a labelled practice fallback otherwise.
  * The transcript stores plain text; no hashing, hex, or textEncode on the
    playable path.
  * Nothing in a played hand calls sxHash / sxRandomBytes / sxBin2Hex.

The cryptographic Level 0 deal (spec 7.1: commit-reveal keyed-stream shuffle,
end-of-hand audit) is the value-path target and stays specced and KAT-pinned
in tools/, but it is deferred here until the SodiumXT surface is confirmed on
this engine -- run heProbeSodium to see exactly which sx* calls work. Wiring
it back in is a Phase-2 step behind a confirmed probe.

The pure logic -- evaluator, betting engine + side pots, settlement,
transcript fold -- is values-in/values-out (house law H5) and machine-pinned
by tools/evaluator-kat.py and tools/betting-kat.py; heRunSelftest re-checks
the same vectors on-engine. Everything visual is verified statically and
needs an OXT pass.
*/

--------------------------------------------------------------------------
-- constants (all up here: gotcha 29 -- a constant used above its
-- declaration silently evaluates to nothing at runtime)
--------------------------------------------------------------------------

constant kHeVersion = "0.13.1"
constant kHeHarnessV = "28"
constant kUIVersion = "7"

-- card contract (mirrored in tools/evaluator-kat.py): index 1..52,
-- index = (rank - 2) * 4 + suit, rank 2..14, suit 1..4 = c,d,h,s
constant kHeRankChars = "23456789TJQKA"
constant kHeSuitChars = "cdhs"
-- kit-mode card back: which frame of the Kenney playingCardBacks atlas to draw for
-- face-down cards (blue/green/red 1..5). Pinned present by tools/atlas-kat.py; the
-- OXT pass can swap it once the real designs are visible.
constant kHeCardBackFrame = "cardBack_red2"

-- Park-Miller MINSTD: x' = 16807 * x mod (2^31 - 1). 16807 * (2^31-1) is
-- about 3.6e13, well under 2^53, so every step is exact in a double.
constant kHeRngMul = 16807
constant kHeRngMod = 2147483647
constant kHeRngMax = 2147483646

-- Phase 2 (online) protocol: domain-separated, versioned hash tags (spec 16)
-- and the canonical envelope version. Pinned in tools/protocol-kat.py.
constant kHeEnvV = "1"
constant kHeDomainSeedC = "HOLDEM-SEEDC-v1|"
constant kHeDomainShuf = "HOLDEM-SHUF-v1|"
constant kHeDomainChain = "HOLDEM-CHAIN-v1|"
constant kHeDomainSettle = "HOLDEM-SETL-v1|"
constant kHeDomainSess = "HOLDEM-SESS-v1|"
-- host-trust hardening (spec 6 checkpoints, 8.3 settlement receipts)
constant kHeDomainCkpt = "HOLDEM-CKPT-v1|"
constant kHeDomainRcpt = "HOLDEM-RCPT-v1|"
constant kHeDomainRsig = "HOLDEM-RSIG-v1|"
constant kHeGenesisPrev = "0000000000000000000000000000000000000000000000000000000000000000"
constant kHeTwo32 = 4294967296

-- table defaults. kHeDefaultSeats is the MAX seats the layout builds (6 spots);
-- the host can seat fewer (kHeMinSeats..kHeMaxSeats) per table via the config.
constant kHeDefaultSeats = 6
constant kHeMinSeats = 2
constant kHeMaxSeats = 6
constant kHeDefaultSB = 1
constant kHeDefaultBB = 2
constant kHeDefaultAnte = 0
constant kHeDefaultStack = 400
-- blind-level schedule (tournament option). One level = "sb/bb/ante"; levels are
-- ";"-separated. A literal single-line string (gotcha 6: constants must be
-- literal, so no & lf building). The level advances every kHeDefaultLevelEvery
-- hands when levelMode is "hands"; "off" holds the fixed stakes forever.
constant kHeDefaultLevels = "1/2/0;2/4/0;3/6/0;5/10/0;10/20/0;15/30/0;25/50/0;50/100/10"
constant kHeDefaultLevelEvery = 8
constant kHeDefaultLevelMinutes = 10
-- table pacing (spec 11: physics/timing is cosmetic; these are the "deal feel"
-- beats so a hand does not flash by or end abruptly). These are the NORMAL-speed
-- defaults; the host picks fast/normal/slow and heSpeedPace scales them into the
-- gGame["pace*"] values the schedule handlers actually read (per-tick, not
-- per-frame). Verified statically; the actual feel needs an OXT pass to dial in.
constant kHeNextHandDelayMs = 2600  -- result shown, then the next hand deals
constant kHeStreetRevealMs = 750    -- beat after betting closes before a street lands
constant kHeRunoutStepMs = 1050     -- beat between streets when an all-in runs out
constant kHeShowdownHoldMs = 2900   -- hold on the revealed showdown before settling
constant kHeFoldHoldMs = 1400       -- shorter beat on a fold-win (no cards to read)

-- UI geometry (flat mode and kit mode share the layout)
constant kHeStackRect = "0,0,1024,690"
constant kHeFeltRect = "40,48,984,566"
constant kHeSeatSpots = "512,516;196,470;150,250;512,120;874,250;828,470"
constant kHeBoardY = 300
constant kHeBoardX0 = 404
constant kHeBoardDX = 58
constant kHeCardW = 50
constant kHeCardH = 70
constant kHeHudMs = 250
constant kHeTableCenter = "512,300"

-- fun seat names (hotseat: one human plays all seats) + palette
constant kHeSeatNames = "You,Ada,Boris,Cleo,Dax,Eve"
constant kHeFeltColor = "18,104,66"
constant kHeFeltRim = "116,74,38"
constant kHePanelColor = "14,64,44"
constant kHePanelActive = "196,150,44"
constant kHeChipColor = "196,58,58"
constant kHeGoldColor = "244,206,96"
constant kHeInk = "24,24,24"
constant kHeRed = "196,36,36"
constant kHeWhite = "246,246,246"

--------------------------------------------------------------------------
-- script-local state (g prefix per the family convention)
--------------------------------------------------------------------------

local gGame            -- the whole table: see heTableNew for the key map
local gCfg             -- persistent table configuration: survives heTableNew so
                       -- the host's chosen stakes/stacks/seats/levels/speed carry
                       -- from one table to the next. See heCfgDefaults for keys.
local gHasSodiumChk    -- cached extension probe ("", "true", "false")
local gHasKitChk
local gUIMode          -- "flat" or "kit"
local gHudDirty        -- HUD repaints only on change, max 4 Hz (playbook)
local gHudTickOn
local gFlipCtxA        -- per-sprite flip context locks (gotcha 19)
local gAnimBusy
-- kit-mode card rendering: gSlotCenter[slotName]->"x,y" (recorded as slots build),
-- gCardSpr[slotName]->the Box2Dxt sprite's long id, gKitSuffix is "" or ".png" (the
-- Kenney frame-name suffix as this sheet actually exposes it, resolved at load).
local gSlotCenter
local gCardSpr
local gKitSuffix

--------------------------------------------------------------------------
-- lifecycle (house law H1: sessions bracket the stack's life)
--------------------------------------------------------------------------

on preOpenStack
   set the rect of this stack to kHeStackRect
   set the title of this stack to "holde-em " & kHeVersion
end preOpenStack

on openStack
   heCfgDefaults
   heBuildTable
   heTableNew
   -- open on the lobby so the first choice is host / join / hotseat
   heLobbyShow
   heUISetStatus "Create or join an online table, or press Leave to play hotseat."
   put true into gHudTickOn
   send "heHudTick" to me in kHeHudMs milliseconds
end openStack

on closeStack
   local tMsgLine
   put false into gHudTickOn
   -- H1: never leave a TorrentXT session running after close
   heNetStop
   -- cancel only our own timers; pendingMessages lines are id,time,name,target
   -- (gotcha 5: set the delimiter before parsing -- closeStack inherits it)
   set the itemDelimiter to comma
   repeat for each line tMsgLine in the pendingMessages
      if item 3 of tMsgLine begins with "he" then
         cancel item 1 of tMsgLine
      end if
   end repeat
   pass closeStack
end closeStack

--------------------------------------------------------------------------
-- SodiumXT crypto seams (Phase 2). Every sx* call the online protocol makes
-- goes through one of these wrappers, so the ABI shape lives in exactly one
-- place. CORRECTED against SodiumXT docs/api-reference.md (the v0.2.0 crash
-- was calling sxHash with one argument; it needs an output length):
--   sxHash(pData, pOutLen) -> Data          (BLAKE2b, pOutLen bytes)
--   sxSignKeypairFromSeed pSeed, out rPub, out rSec   (COMMAND, out params)
--   sxSignDetached(pMsg, pSec) -> Data ; sxSignVerifyDetached(sig,msg,pub)->Bool
--   sxSeal(pMsg, pRecipPub) -> Data ; sxSealOpen(sealed, pub, sec) -> Data
-- Everything crosses as Data: textEncode strings before hashing/signing;
-- textDecode(..., "ascii") the hex helpers back to script text (H3/H6: raw
-- Data only ever appears inside an sx* call argument, never chunked).
--------------------------------------------------------------------------

function heHasSodium
   local tProbeErr
   if gHasSodiumChk is empty then
      try
         get sxRandomUniform(2)
         put "true" into gHasSodiumChk
      catch tProbeErr
         put "false" into gHasSodiumChk
      end try
   end if
   return gHasSodiumChk is "true"
end heHasSodium

function heHash32 pData
   -- 32-byte BLAKE2b digest as Data (the output-length arg is mandatory)
   return sxHash(pData, 32)
end heHash32

function heHashHex pData
   -- lowercase-hex string of the 32-byte digest, for transcript text fields
   return textDecode(sxBin2Hex(sxHash(pData, 32)), "ascii")
end heHashHex

function heHashDomHex pTagTxt, pData
   -- domain-separated digest, hex: H(utf8(tag) || data). pData is Data.
   return textDecode(sxBin2Hex(sxHash(textEncode(pTagTxt, "utf-8") & pData, 32)), "ascii")
end heHashDomHex

function heBin2HexS pData
   -- Data -> lowercase-hex String (sxBin2Hex returns ASCII Data)
   return textDecode(sxBin2Hex(pData), "ascii")
end heBin2HexS

function heHex2BinD pHexTxt
   -- hex String -> Data
   return sxHex2Bin(textEncode(pHexTxt, "ascii"))
end heHex2BinD

function heIsHex pTxt, pLen
   -- true iff pTxt is even-length hex (optionally exactly pLen chars). PURE --
   -- no FFI -- so it can gate sxHex2Bin, which THROWS on malformed input. Every
   -- hex field lifted off an untrusted wire must pass this before heHex2BinD, or
   -- one hostile/corrupt frame throws uncaught in the poll loop (house law H4:
   -- verify-or-drop must never raise). pLen 0 = "any even length".
   local tLen, tCh
   put the number of chars of pTxt into tLen
   if tLen is 0 or (tLen mod 2) is not 0 then
      return false
   end if
   if pLen is not empty and pLen is not 0 and tLen is not pLen then
      return false
   end if
   repeat for each char tCh in pTxt
      if offset(tCh, "0123456789abcdefABCDEF") is 0 then
         return false
      end if
   end repeat
   return true
end heIsHex

-- Identity keys are derived by calling sxSignKeypairFromSeed directly into
-- plain locals at each site (the proven-safe form -- same as
-- sxBoxKeypairFromSeed in heProbeSodium). No @-reference wrapper, so there is
-- no script indirection between the foreign out-param and a real variable.

function heSignDetachedD pMsgData, pSecData
   return sxSignDetached(pMsgData, pSecData)
end heSignDetachedD

function heVerifyDetached pSigData, pMsgData, pPubData
   -- never throws; a bad signature is false (spec 6 verify-or-drop)
   return sxSignVerifyDetached(pSigData, pMsgData, pPubData)
end heVerifyDetached

function heFingerprintOf pPubData
   -- display handle: first 8 hex chars of H(pubkey) (spec 5)
   return char 1 to 8 of heHashHex(pPubData)
end heFingerprintOf

command heProbeSodium
   -- diagnostic: exercise every crypto seam the online protocol needs, each
   -- in its own try, reporting ok / THREW. Prints to the message box. With
   -- the corrected signatures this should be all-ok on an engine with
   -- SodiumXT installed; run it once to confirm the Phase 2 surface is live.
   -- tErr and tOuterErr MUST be declared: an undeclared catch variable throws on
   -- strict OXT, which is why this probe blew up only once SodiumXT was installed
   -- (with it absent the handler returns before any catch can fire).
   local tRpt, tData, tPub, tSec, tSig, tSealed, tOpened, tMsg, tRecPub, tRecSec
   local tErr, tOuterErr
   -- the version is stamped in so a STALE paste identifies itself: if the line
   -- below does not say "v0.10.1" (or later) in OXT, the running stack is an old
   -- paste and needs re-pasting -- that alone explains a probe that still throws.
   put "SodiumXT probe (holde-em " & kHeVersion & ", harness v" & kHeHarnessV & "):" & return into tRpt
   -- ONE outer guard around the whole body -- including the heHasSodium check --
   -- so nothing here can ever escape and abort a harness run; whatever throws is
   -- reported into the probe text instead of killing it
   try
      if not heHasSodium() then
         put "  SodiumXT not installed (sxRandomUniform threw)." & return after tRpt
         put tRpt
         return tRpt
      end if
      put textEncode("holde-em probe", "utf-8") into tMsg

      try
         put heBin2HexS(heHash32(textEncode("", "utf-8"))) into tData
         put "  sxHash(empty,32) -> " & tData & return after tRpt
      catch tErr
         put "  sxHash: THREW: " & tErr & return after tRpt
      end try
      try
         sxSignKeypairFromSeed heHash32(textEncode("seed", "utf-8")), tPub, tSec
         put "  sxSignKeypairFromSeed: ok  pub=" & char 1 to 16 of heBin2HexS(tPub) & "..." & return after tRpt
      catch tErr
         put "  sxSignKeypairFromSeed: THREW: " & tErr & return after tRpt
      end try
      try
         put heSignDetachedD(tMsg, tSec) into tSig
         if heVerifyDetached(tSig, tMsg, tPub) then
            put "  sxSignDetached + verify: ok (roundtrip verified)" & return after tRpt
         else
            put "  sxSignDetached: FAILED verify (unexpected)" & return after tRpt
         end if
         if not heVerifyDetached(tSig, textEncode("tampered", "utf-8"), tPub) then
            put "  verify rejects a tampered message: ok" & return after tRpt
         else
            put "  verify accepted a tampered message: BAD" & return after tRpt
         end if
      catch tErr
         put "  sxSignDetached/verify: THREW: " & tErr & return after tRpt
      end try
      -- the sealed-box surface (sxBoxKeypairFromSeed / sxSeal / sxSealOpen) is
      -- SodiumXT Phase 4; a build that ships sign+hash but not box makes these
      -- "can't find handler". That is EXPECTED on such a build and does not break
      -- the game -- hole-card sealing is future work, and heIdentitySetup guards
      -- the box key so a join still succeeds.
      try
         sxBoxKeypairFromSeed heHash32(textEncode("box", "utf-8")), tRecPub, tRecSec
         put sxSeal(tMsg, tRecPub) into tSealed
         put sxSealOpen(tSealed, tRecPub, tRecSec) into tOpened
         if sxMemEqual(tOpened, tMsg) then
            put "  sxSeal + sxSealOpen: ok (sealed-box roundtrip)" & return after tRpt
         else
            put "  sxSeal/Open: roundtrip mismatch" & return after tRpt
         end if
      catch tErr
         put "  box surface (sxBoxKeypairFromSeed/sxSeal/sxSealOpen): THREW: " & tErr \
               & " -- ok if this SodiumXT build has no Phase 4 box handlers yet" & return after tRpt
      end try
   catch tOuterErr
      put "  probe aborted (unguarded): " & tOuterErr & return after tRpt
   end try

   -- heProbeSodium is a COMMAND, so it must NOT be called with function-call
   -- syntax heProbeSodium() -- that throws (the harness hit exactly this). Like
   -- the test sections, it appends its report to gRpt; the harness runs it via
   -- heRunSection, and a standalone `heProbeSodium` echoes the report too.
   put return & tRpt after gRpt
   put tRpt
   return tRpt
end heProbeSodium

--------------------------------------------------------------------------
-- TorrentXT transport probe. Starts THE session, enables rp1, adds a phantom
-- swarm on a rendezvous id, and reports; tears the session back down so the
-- probe leaks nothing. Confirms the transport surface on-engine.
--------------------------------------------------------------------------

command heProbeTorrent
   -- capture "the result" immediately after each bt* command (gotcha 27):
   -- per the docs only btStartSession throws, the rest report via the result
   local tRpt, tSession, tHash, tHandle, tRC, tErr
   put "TorrentXT probe (holde-em " & kHeVersion & "):" & return into tRpt
   try
      put btStartSession() into tSession
   catch tErr
      put "  btStartSession THREW (ABI mismatch?): " & tErr & return after tRpt
      put tRpt
      return tRpt
   end try
   if tSession is 0 or tSession is empty then
      put "  btStartSession failed: " & btLastError() & return after tRpt
      put tRpt
      return tRpt
   end if
   put "  btStartSession -> session " & tSession & return after tRpt
   try
      btSetBool tSession, "enable_dht", true
      put the result into tRC
      put "  btSetBool enable_dht -> " & heRcTxt(tRC) & return after tRpt
      btRp1Enable tSession
      put the result into tRC
      put "  btRp1Enable -> " & heRcTxt(tRC) & return after tRpt
      if heHasSodium() then
         put char 1 to 40 of heHashHex(textEncode("holde-em-probe-table", "utf-8")) into tHash
      else
         put "0123456789abcdef0123456789abcdef01234567" into tHash
      end if
      put btAddInfohash(tSession, tHash, heTempPath()) into tHandle
      if tHandle > 0 then
         put "  btAddInfohash(" & char 1 to 10 of tHash & "...) -> handle " & tHandle & return after tRpt
      else
         put "  btAddInfohash FAILED: " & btLastError() & return after tRpt
      end if
      btDhtAnnounce tSession, tHash, 0
      put the result into tRC
      put "  btDhtAnnounce -> " & heRcTxt(tRC) & return after tRpt
   catch tErr
      put "  transport call THREW: " & tErr & return after tRpt
   end try
   btStopSession tSession
   put "  btStopSession: ok (session torn down)" & return after tRpt
   put tRpt
   return tRpt
end heProbeTorrent

function heTempPath
   -- a scratch save path for the phantom swarm (no content is stored)
   return "he_rendezvous"
end heTempPath

function heRcTxt pRC
   -- a bt* command reports 0/negative via the result; label it for the probe
   if pRC is empty or pRC is 0 then
      return "ok"
   end if
   if pRC < 0 then
      return "FAILED (" & pRC & "): " & btLastError()
   end if
   return "rc=" & pRC
end heRcTxt

--------------------------------------------------------------------------
-- Online transcript: the canonical signed, hash-chained envelope (spec 6),
-- byte-pinned in tools/protocol-kat.py. Layered signatures -- a sender
-- cannot sign seq/prev it does not know under a relay that assigns ordering,
-- so the SENDER signs the content line and the HOST signs the sequenced
-- envelope it relays:
--   contentLine = v TAB tableHex TAB hand TAB fromHex TAB type TAB bodyHex
--   envLine     = contentLine TAB senderSigHex TAB seq TAB prevHex
--   wire        = envLine TAB hostSigHex             (one wire line = one rp1 payload)
--   chainHead   = H("HOLDEM-CHAIN-v1|" || utf8(wire)); genesis prev = 64 zero hex
-- All binary fields travel as lowercase hex; bodies are hex of their UTF-8
-- text, so no tab can ever leak into the frame. (kHeGenesisPrev -- the
-- 64-zero-hex genesis prev -- lives in the top constant block.)
--------------------------------------------------------------------------

function heEnvContentLine pTableHex, pHandNum, pFromHex, pTypeTxt, pBodyTxt
   return kHeEnvV & tab & pTableHex & tab & pHandNum & tab & pFromHex \
         & tab & pTypeTxt & tab & heBin2HexS(textEncode(pBodyTxt, "utf-8"))
end heEnvContentLine

function heEnvSenderSigHex pContentLine, pSenderSecData
   return heBin2HexS(heSignDetachedD(textEncode(pContentLine, "utf-8"), pSenderSecData))
end heEnvSenderSigHex

function heWireBuild pContentLine, pSenderSecData, pSeqNum, pPrevHex, pHostSecData
   -- the host's send path: countersign the sequenced envelope
   local tSenderSig, tEnvLine, tHostSig
   put heEnvSenderSigHex(pContentLine, pSenderSecData) into tSenderSig
   put pContentLine & tab & tSenderSig & tab & pSeqNum & tab & pPrevHex into tEnvLine
   put heBin2HexS(heSignDetachedD(textEncode(tEnvLine, "utf-8"), pHostSecData)) into tHostSig
   return tEnvLine & tab & tHostSig
end heWireBuild

function heChainNextHex pWireLine
   return heHashHex(textEncode(kHeDomainChain & pWireLine, "utf-8"))
end heChainNextHex

function heSettleHashHex pDeltasCSV, pChainHeadData
   -- H("HOLDEM-SETL-v1|" || deltas || "|" || chainHead); chainHead is Data
   return heBin2HexS(heHash32(textEncode(kHeDomainSettle & pDeltasCSV & "|", "utf-8") & pChainHeadData))
end heSettleHashHex

-- Host-trust hardening (spec 6 checkpoints, spec 8.3 settlement receipts),
-- KAT-pinned in tools/protocol-kat.py. A ckpt is a player's signature over the
-- chain head at a street boundary: if two players' ckpts sign DIFFERENT heads,
-- the host forked -- attributable equivocation. A settlement receipt is every
-- seated player's signature over a receipt head that hash-chains hand to hand,
-- so the ledger is multi-signed and no subset can rewrite it. All hex text; the
-- signature payloads are ASCII, so no FFI-bridged binary reaches the chunk
-- evaluator (H6). Sig verification never throws (heVerifyDetached returns false).

function heCkptSigHex pChainHeadHex, pSecData
   -- a player signs "HOLDEM-CKPT-v1|<chainHead>" to checkpoint the transcript
   return heBin2HexS(heSignDetachedD(textEncode(kHeDomainCkpt & pChainHeadHex, "utf-8"), pSecData))
end heCkptSigHex

function heCkptVerify pSigHex, pChainHeadHex, pPubHex
   if not heIsHex(pSigHex, 128) or not heIsHex(pPubHex, 64) then
      return false
   end if
   return heVerifyDetached(heHex2BinD(pSigHex), textEncode(kHeDomainCkpt & pChainHeadHex, "utf-8"), heHex2BinD(pPubHex))
end heCkptVerify

function heReceiptHeadHex pSettleHashHex, pPrevRcptHex
   -- H("HOLDEM-RCPT-v1|" || settleHash || "|" || prevReceipt) -- receipts chain
   -- hand to hand; the genesis predecessor is kHeGenesisPrev (64 zeros)
   return heHashDomHex(kHeDomainRcpt, textEncode(pSettleHashHex & "|" & pPrevRcptHex, "utf-8"))
end heReceiptHeadHex

function heReceiptSigHex pRcptHeadHex, pSecData
   -- a seated player signs "HOLDEM-RSIG-v1|<receiptHead>"; the collected
   -- signatures over one receipt head form the settlement receipt (spec 8.3)
   return heBin2HexS(heSignDetachedD(textEncode(kHeDomainRsig & pRcptHeadHex, "utf-8"), pSecData))
end heReceiptSigHex

function heReceiptSigVerify pSigHex, pRcptHeadHex, pPubHex
   if not heIsHex(pSigHex, 128) or not heIsHex(pPubHex, 64) then
      return false
   end if
   return heVerifyDetached(heHex2BinD(pSigHex), textEncode(kHeDomainRsig & pRcptHeadHex, "utf-8"), heHex2BinD(pPubHex))
end heReceiptSigVerify

function heEnvWireParse pWireLine
   -- split a wire line into its fields and rebuild the two signed spans
   local tA, tSaved, tLine
   put pWireLine into tLine
   put the itemDelimiter into tSaved
   set the itemDelimiter to tab
   put item 1 of tLine into tA["v"]
   put item 2 of tLine into tA["table"]
   put item 3 of tLine into tA["hand"]
   put item 4 of tLine into tA["from"]
   put item 5 of tLine into tA["type"]
   put item 6 of tLine into tA["bodyHex"]
   put item 7 of tLine into tA["senderSig"]
   put item 8 of tLine into tA["seq"]
   put item 9 of tLine into tA["prev"]
   put item 10 of tLine into tA["hostSig"]
   put item 1 to 6 of tLine into tA["contentLine"]
   put item 1 to 9 of tLine into tA["envLine"]
   set the itemDelimiter to tSaved
   return tA
end heEnvWireParse

function heEnvBodyText pBodyHex
   -- an empty body is empty text; a malformed (non-hex) body drops to empty
   -- rather than throwing in sxHex2Bin. heEnvVerify lets an empty bodyHex pass,
   -- so this is the last guard before a host-crafted body reaches the decoder
   -- (H4: inbound bytes are untrusted, verify-or-drop must never raise).
   if pBodyHex is empty or not heIsHex(pBodyHex, 0) then
      return ""
   end if
   return textDecode(heHex2BinD(pBodyHex), "utf-8")
end heEnvBodyText

function heEnvVerify pWireLine, pFromPubHex, pHostPubHex, pExpectedPrevHex
   -- spec 6 verify-or-drop: bad sig / unknown from / chain break => dropped
   -- and logged, no exceptions (including from the host). pFromPubHex is the
   -- admitted pubkey the caller expects for this sender ("" to skip that
   -- check); pExpectedPrevHex is the local chain head ("" to skip).
   local tA, tFrom, tSenderSig, tHostSig, tBodyHex
   put heEnvWireParse(pWireLine) into tA
   -- shape-check every hex field BEFORE any decode: heHex2BinD (sxHex2Bin)
   -- throws on malformed hex, and this path runs on untrusted inbound bytes,
   -- so a bad frame must become a clean drop, never an uncaught throw (H4).
   put tA["from"] into tFrom
   put tA["senderSig"] into tSenderSig
   put tA["hostSig"] into tHostSig
   put tA["bodyHex"] into tBodyHex
   if not heIsHex(tFrom, 64) or not heIsHex(pHostPubHex, 64) \
         or not heIsHex(tSenderSig, 128) or not heIsHex(tHostSig, 128) then
      return "drop:malformed"
   end if
   if tBodyHex is not empty and not heIsHex(tBodyHex, 0) then
      return "drop:malformed"
   end if
   if pFromPubHex is not empty and tA["from"] is not pFromPubHex then
      return "drop:unknown-from"
   end if
   if not heVerifyDetached(heHex2BinD(tA["senderSig"]), \
         textEncode(tA["contentLine"], "utf-8"), heHex2BinD(tA["from"])) then
      return "drop:bad-sender-sig"
   end if
   if not heVerifyDetached(heHex2BinD(tA["hostSig"]), \
         textEncode(tA["envLine"], "utf-8"), heHex2BinD(pHostPubHex)) then
      return "drop:bad-host-sig"
   end if
   if pExpectedPrevHex is not empty and tA["prev"] is not pExpectedPrevHex then
      return "drop:chain-break"
   end if
   return "ok"
end heEnvVerify

--------------------------------------------------------------------------
-- Level 0 deal (spec 7.1): commit-reveal keyed-stream shuffle. Byte-pinned
-- in tools/protocol-kat.py. Every player commits H("HOLDEM-SEEDC-v1"||seed),
-- shares its seed to the dealer sealed, and the shuffle is a Fisher-Yates
-- draw from stream = H("HOLDEM-SHUF-v1"||table||"|"||hand||"|"||XOR(seeds)),
-- so the dealer cannot stack the deck (its own seed was committed first).
-- The stream is materialised as HEX text and every draw chunks plain hex
-- chars, so no FFI-bridged binary ever reaches the script chunk evaluator
-- (H6): raw Data appears only inside sxHash arguments. Seeds travel as hex.
--------------------------------------------------------------------------

function heByteXor pA, pB
   -- XOR of two byte values (0..255) using ONLY integer arithmetic (div, mod,
   -- add, multiply) -- no bitwise operator, so nothing can trip the engine's
   -- double/binary conversion. Walks the 8 bits low to high.
   -- (locals are tWorkA/tWorkB, NOT tAb -- "tAb" is the tab constant, gotcha 2.)
   local tResult, tBitVal, tWorkA, tWorkB
   put 0 into tResult
   put 1 into tBitVal
   put pA into tWorkA
   put pB into tWorkB
   repeat 8 times
      if (tWorkA mod 2) is not (tWorkB mod 2) then
         add tBitVal to tResult
      end if
      put tWorkA div 2 into tWorkA
      put tWorkB div 2 into tWorkB
      put tBitVal * 2 into tBitVal
   end repeat
   return tResult
end heByteXor

function heXorSeedsHex pSeedsHexA, pCount
   -- XOR of pCount 32-byte seeds (each a 64-hex string), done in hex; returns hex
   local tPairPos, tSeatPos, tAcc, tHexTxt, tOutHex, tPairHex, tByteVal
   put empty into tOutHex
   repeat with tPairPos = 1 to 63 step 2
      put 0 into tAcc
      repeat with tSeatPos = 1 to pCount
         put pSeedsHexA[tSeatPos] into tHexTxt
         put baseConvert(char tPairPos to (tPairPos + 1) of tHexTxt, 16, 10) into tByteVal
         put heByteXor(tAcc, tByteVal) into tAcc
      end repeat
      put toLower(baseConvert(tAcc, 10, 16)) into tPairHex
      if the number of chars of tPairHex is 1 then
         put "0" & tPairHex into tPairHex
      end if
      put tPairHex after tOutHex
   end repeat
   return tOutHex
end heXorSeedsHex

function heU32BEData pNum
   -- 4-byte big-endian Data (built from arithmetic, fed straight into sxHash)
   return numToByte(pNum div 16777216 mod 256) & numToByte(pNum div 65536 mod 256) \
         & numToByte(pNum div 256 mod 256) & numToByte(pNum mod 256)
end heU32BEData

function heStreamKeyData pTableData, pHandNum, pXorHex
   -- H("HOLDEM-SHUF-v1|" || table || "|" || decimal(hand) || "|" || seedsXor)
   return heHash32(textEncode(kHeDomainShuf, "utf-8") & pTableData \
         & textEncode("|" & pHandNum & "|", "utf-8") & heHex2BinD(pXorHex))
end heStreamKeyData

function heStreamBlocksHex pKeyData, pBlockCount
   -- hex text of block_j = H(key || uint32be(j)), j = 0 .. pBlockCount-1
   local tOut, tBlockPos
   put empty into tOut
   repeat with tBlockPos = 0 to pBlockCount - 1
      put heBin2HexS(heHash32(pKeyData & heU32BEData(tBlockPos))) after tOut
   end repeat
   return tOut
end heStreamBlocksHex

function heDrawUniform pStreamHex, pOffset, pRangeN
   -- uniform 1..pRangeN via 32-bit BE words (8 hex chars each), rejection
   -- sampled (no modulo bias). The word is two 16-bit halves so baseConvert's
   -- 32-bit signedness is never a factor. Returns "value,nextOffset".
   local tLimit, tWordVal
   put (kHeTwo32 div pRangeN) * pRangeN into tLimit
   repeat forever
      if pOffset + 7 > the number of chars of pStreamHex then
         throw "he-stream-exhausted"
      end if
      put baseConvert(char pOffset to (pOffset + 3) of pStreamHex, 16, 10) * 65536 \
            + baseConvert(char (pOffset + 4) to (pOffset + 7) of pStreamHex, 16, 10) into tWordVal
      add 8 to pOffset
      if tWordVal < tLimit then
         return (tWordVal mod pRangeN) + 1 & comma & pOffset
      end if
   end repeat
end heDrawUniform

function heShuffleFromStreamHex pStreamHex
   -- Fisher-Yates over deck[1..52]; deck 1 is the top, dealt first
   local tDeckA, tPos, tSwapPos, tDrawPair, tHold, tOut, tOffset, tLoopI
   set the itemDelimiter to comma
   repeat with tPos = 1 to 52
      put tPos into tDeckA[tPos]
   end repeat
   put 1 into tOffset
   repeat with tLoopI = 52 down to 2
      put heDrawUniform(pStreamHex, tOffset, tLoopI) into tDrawPair
      put item 1 of tDrawPair into tSwapPos
      put item 2 of tDrawPair into tOffset
      put tDeckA[tLoopI] into tHold
      put tDeckA[tSwapPos] into tDeckA[tLoopI]
      put tHold into tDeckA[tSwapPos]
   end repeat
   put empty into tOut
   repeat with tPos = 1 to 52
      put tDeckA[tPos] & comma after tOut
   end repeat
   delete char -1 of tOut
   return tOut
end heShuffleFromStreamHex

function heDeckFromStreamKey pKeyData
   -- 16 blocks (1024 hex chars) covers 51 draws with slack; extend on the
   -- astronomically-unlikely stream exhaustion rather than fail
   local tBlockCount, tDeckList, tShufErr
   put 16 into tBlockCount
   repeat forever
      try
         put heShuffleFromStreamHex(heStreamBlocksHex(pKeyData, tBlockCount)) into tDeckList
         return tDeckList
      catch tShufErr
         if tShufErr contains "he-stream-exhausted" and tBlockCount < 256 then
            put tBlockCount * 2 into tBlockCount
         else
            throw tShufErr
         end if
      end try
   end repeat
end heDeckFromStreamKey

function heLevel0Deck pTableData, pHandNum, pSeedsHexA, pCount
   -- the full Level 0 shuffled deck from committed seeds
   return heDeckFromStreamKey(heStreamKeyData(pTableData, pHandNum, heXorSeedsHex(pSeedsHexA, pCount)))
end heLevel0Deck

function heSeedCommitHex pSeedHex
   -- H("HOLDEM-SEEDC-v1|" || seed bytes), hex (spec 7.1 step 1)
   return heHashDomHex(kHeDomainSeedC, heHex2BinD(pSeedHex))
end heSeedCommitHex

function heAuditDeal pTableData, pHandNum, pSeedsHexA, pCommitsA, pCount, pDealA, pOccList, pButton
   -- end-of-hand audit (spec 7.1 step 5): recompute the whole deal from the
   -- revealed seeds and name the FIRST failing step. Returns "pass"/"fail:..".
   local tSeatPos, tDeckList, tCheckA, tSeatNum
   set the itemDelimiter to comma
   repeat with tSeatPos = 1 to pCount
      if heSeedCommitHex(pSeedsHexA[tSeatPos]) is not pCommitsA[tSeatPos] then
         return "fail:commit-mismatch-position-" & tSeatPos
      end if
   end repeat
   put heLevel0Deck(pTableData, pHandNum, pSeedsHexA, pCount) into tDeckList
   put heDealAssign(tDeckList, pOccList, pButton) into tCheckA
   repeat for each item tSeatNum in pOccList
      if tCheckA["holesBy"][tSeatNum] is not pDealA["holesBy"][tSeatNum] then
         return "fail:hole-mismatch-seat-" & tSeatNum
      end if
   end repeat
   if tCheckA["flopList"] is not pDealA["flopList"] then
      return "fail:flop-mismatch"
   end if
   if tCheckA["turnIx"] is not pDealA["turnIx"] then
      return "fail:turn-mismatch"
   end if
   if tCheckA["riverIx"] is not pDealA["riverIx"] then
      return "fail:river-mismatch"
   end if
   return "pass"
end heAuditDeal

function heAuditDealsFromLog pLogTxt
   -- replay a transcript and RE-DERIVE every Level 0 deal from the revealed
   -- seeds, confirming the committed keyed-stream shuffle produced exactly the
   -- cards that were dealt -- so the deal is provably CONSISTENT with the revealed
   -- seeds (tamper-evident), checkable by anyone holding the log. (Unstackability
   -- against a cheating dealer needs independent per-player seeds -- spec 7.1 online
   -- deal -- not the single-party seeds generated here.) Only the dealt streets are
   -- compared (a hand folded pre-flop has no board to check). Needs SodiumXT
   -- (recomputes commitments + shuffle). Returns "N/M deals verified" then one
   -- line per Level 0 hand; "no Level 0 deals in this transcript" if none.
   local tLine, tType, tBodyTxt, tBodyA, tOut, tVerified, tTotal
   local tHandNum, tOccList, tButton, tTableHex, tCount, tSeedsA, tCommitsA
   local tHolesA, tBoardList, tPos, tSeatNum, tLevel0, tCardTxt, tOneCard
   local tDeckList, tCheckA, tVerdict, tBoardN
   if not heHasSodium() then
      return "deal audit needs SodiumXT (it recomputes the committed shuffle)."
   end if
   set the itemDelimiter to comma
   put 0 into tVerified
   put 0 into tTotal
   put empty into tOut
   put "false" into tLevel0
   repeat for each line tLine in pLogTxt
      if tLine is empty then
         next repeat
      end if
      put heLogField(tLine, 3) into tType
      put heLogField(tLine, 4) into tBodyTxt
      set the itemDelimiter to comma
      switch tType
         case "handStart"
            put tBodyTxt into tBodyA
            split tBodyA by comma and "="
            put tBodyA["seats"] into tOccList
            replace "|" with comma in tOccList
            put tBodyA["button"] into tButton
            put heLogField(tLine, 1) into tHandNum
            put "false" into tLevel0
            put empty into tSeedsA
            put empty into tCommitsA
            put empty into tHolesA
            put empty into tBoardList
            break
         case "dealLevel"
            put tBodyTxt into tBodyA
            split tBodyA by comma and "="
            put "true" into tLevel0
            put tBodyA["table"] into tTableHex
            put tBodyA["count"] into tCount
            break
         case "seedCommit"
            put tBodyTxt into tBodyA
            split tBodyA by comma and "="
            put tBodyA["commit"] into tCommitsA[tBodyA["pos"]]
            break
         case "seedReveal"
            put tBodyTxt into tBodyA
            split tBodyA by comma and "="
            put tBodyA["seed"] into tSeedsA[tBodyA["pos"]]
            break
         case "holeDeliver"
            put tBodyTxt into tBodyA
            split tBodyA by comma and "="
            put tBodyA["cards"] into tCardTxt
            replace "|" with comma in tCardTxt
            put heCardIndex(item 1 of tCardTxt) & comma & heCardIndex(item 2 of tCardTxt) into tHolesA[tBodyA["seat"]]
            break
         case "board"
            put tBodyTxt into tBodyA
            split tBodyA by comma and "="
            put tBodyA["cards"] into tCardTxt
            replace "|" with comma in tCardTxt
            repeat for each item tOneCard in tCardTxt
               if tBoardList is empty then
                  put heCardIndex(tOneCard) into tBoardList
               else
                  put tBoardList & comma & heCardIndex(tOneCard) into tBoardList
               end if
            end repeat
            break
         case "settle"
            if tLevel0 is "true" then
               add 1 to tTotal
               put heAuditDealLog(tTableHex, tHandNum, tSeedsA, tCommitsA, tCount, tOccList, tButton, tHolesA, tBoardList) into tVerdict
               if tVerdict is "pass" then
                  add 1 to tVerified
                  put "hand " & tHandNum & ": deal-verified (committed shuffle re-derived)" & return after tOut
               else
                  put "hand " & tHandNum & ": deal-FAILED " & tVerdict & return after tOut
               end if
            end if
            break
      end switch
   end repeat
   if tTotal is 0 then
      return "no Level 0 deals in this transcript (practice PRNG deal)."
   end if
   return tVerified & "/" & tTotal & " deals verified" & return & tOut
end heAuditDealsFromLog

function heAuditDealLog pTableHex, pHandNum, pSeedsHexA, pCommitsA, pCount, pOccList, pButton, pHolesA, pBoardList
   -- verify one Level 0 hand from the log: commits bind the seeds, the deck
   -- re-derives, and the dealt holes (always) plus whatever board streets were
   -- revealed match. Returns "pass" or "fail:...".
   local tSeatPos, tDeckList, tCheckA, tSeatNum, tBoardN
   set the itemDelimiter to comma
   repeat with tSeatPos = 1 to pCount
      if heSeedCommitHex(pSeedsHexA[tSeatPos]) is not pCommitsA[tSeatPos] then
         return "fail:commit-mismatch-position-" & tSeatPos
      end if
   end repeat
   put heLevel0Deck(heHex2BinD(pTableHex), pHandNum, pSeedsHexA, pCount) into tDeckList
   put heDealAssign(tDeckList, pOccList, pButton) into tCheckA
   repeat for each item tSeatNum in pOccList
      if tCheckA["holesBy"][tSeatNum] is not pHolesA[tSeatNum] then
         return "fail:hole-mismatch-seat-" & tSeatNum
      end if
   end repeat
   put the number of items of pBoardList into tBoardN
   if tBoardN >= 3 and (item 1 to 3 of pBoardList) is not tCheckA["flopList"] then
      return "fail:flop-mismatch"
   end if
   if tBoardN >= 4 and (item 4 of pBoardList) is not tCheckA["turnIx"] then
      return "fail:turn-mismatch"
   end if
   if tBoardN >= 5 and (item 5 of pBoardList) is not tCheckA["riverIx"] then
      return "fail:river-mismatch"
   end if
   return "pass"
end heAuditDealLog

--------------------------------------------------------------------------
-- Online transport (Phase 2a/2b, spec 3/4/5/10). Peers meet on the DHT via
-- a phantom swarm keyed by the table code, talk over rp1, and route every
-- game message through the host (a star topology, spec 4): a player signs a
-- content line and sends it to the host; the host assigns seq + prev,
-- countersigns, and rebroadcasts the sequenced wire; everyone verifies-or-
-- drops and folds it. The admission-token, envelope, and fold logic are pure
-- and KAT-pinned; the bt*/session/rp1 calls are seams that NEED AN OXT PASS.
--
-- gGame online keys: online session isHost tableIdHex infohashHex idPubHex
-- idSecData boxPubData boxSecData seqCounter chainHeadHex hostPubHex, plus
-- arrays peerPubA[peer]->pubHex, peerByPub[pubHex]->peer, admittedA[pubHex].
--------------------------------------------------------------------------

function heIdentitySeedHex
   -- persistent identity seed (32 bytes, hex), generated once and stored in a
   -- stack custom property; long-term keys only ever sign (spec 5)
   local tSeedHex
   put the uHeIdentitySeed of this stack into tSeedHex
   if the number of chars of tSeedHex is not 64 then
      if heHasSodium() then
         put heBin2HexS(sxRandomBytes(32)) into tSeedHex
      else
         put heHexId(64) into tSeedHex
      end if
      set the uHeIdentitySeed of this stack to tSeedHex
   end if
   return tSeedHex
end heIdentitySeedHex

command heIdentitySetup
   -- derive and cache the long-term ed25519 identity and a fresh per-table
   -- X25519 session box key (private hole-card lanes seal to the box key)
   local tSeedData, tSeedHex, tPub, tSec, tBoxPub, tBoxSec, tBoxErr
   put heIdentitySeedHex() into tSeedHex
   put heHex2BinD(tSeedHex) into tSeedData
   sxSignKeypairFromSeed tSeedData, tPub, tSec
   put heBin2HexS(tPub) into gGame["idPubHex"]
   put tSec into gGame["idSecData"]
   put heFingerprintOf(tPub) into gGame["idFingerprint"]
   -- The per-table X25519 box key is for the FUTURE sealed hole-card lanes; the
   -- current lobby (ed25519 identity + admission tokens) never reads it. It is
   -- derived best-effort and GUARDED: sxBoxKeypairFromSeed is a SodiumXT Phase 4
   -- (public-key box) handler, and a build that ships the sign/hash surface but
   -- not the box surface yet makes it "can't find handler" -- which must not break
   -- a guest join (H4: an unbuilt/absent seam never breaks the working path). The
   -- signature is correct per SodiumXT docs/api-reference.md
   -- (sxBoxKeypairFromSeed pSeed, out rPub, out rSec); it simply may be absent.
   -- NB: the seed is hashed from a TEXT input (domain + seed hex), never a binary
   -- & of two Data values (H6 corollary).
   put empty into gGame["boxPubData"]
   put empty into gGame["boxSecData"]
   try
      sxBoxKeypairFromSeed heHash32(textEncode(kHeDomainSess & tSeedHex, "utf-8")), tBoxPub, tBoxSec
      put tBoxPub into gGame["boxPubData"]
      put tBoxSec into gGame["boxSecData"]
   catch tBoxErr
      -- box lane unavailable on this SodiumXT build; not needed by the lobby yet
   end try
end heIdentitySetup

function heAdmitTokenData pTableHex, pPubHex, pSecData, pRole
   -- signed admission claim (spec 5): sign over
   -- "HOLDEM-SESS-v1|<table>|<pub>|<role>", framed pubHex TAB role TAB sigHex,
   -- published in btRp1SetToken so peers drop strangers at handshake and a
   -- joining player adopts only a self-declared host (role "host")
   local tSigHex
   put heBin2HexS(heSignDetachedD(textEncode(kHeDomainSess & pTableHex & "|" & pPubHex & "|" & pRole, "utf-8"), pSecData)) into tSigHex
   return textEncode(pPubHex & tab & pRole & tab & tSigHex, "utf-8")
end heAdmitTokenData

function heAdmitTokenVerify pTokenData, pTableHex
   -- returns the admitted pubHex if the token is well-formed and its signature
   -- verifies, else "" (the peer is a stranger and is ignored)
   local tTok, tPubHex, tRole, tSigHex, tSaved
   put textDecode(pTokenData, "utf-8") into tTok
   put the itemDelimiter into tSaved
   set the itemDelimiter to tab
   put item 1 of tTok into tPubHex
   put item 2 of tTok into tRole
   put item 3 of tTok into tSigHex
   set the itemDelimiter to tSaved
   -- a stranger's token is untrusted: reject malformed hex before decoding it
   -- (sxHex2Bin throws) -- 64-char pub and 128-char detached sig (H4)
   if not heIsHex(tPubHex, 64) or not heIsHex(tSigHex, 128) then
      return ""
   end if
   if heVerifyDetached(heHex2BinD(tSigHex), \
         textEncode(kHeDomainSess & pTableHex & "|" & tPubHex & "|" & tRole, "utf-8"), heHex2BinD(tPubHex)) then
      return tPubHex
   end if
   return ""
end heAdmitTokenVerify

function heAdmitTokenRole pTokenData
   -- the role field of a token ("host"/"player"), for host adoption
   local tTok, tRole, tSaved
   put textDecode(pTokenData, "utf-8") into tTok
   put the itemDelimiter into tSaved
   set the itemDelimiter to tab
   put item 2 of tTok into tRole
   set the itemDelimiter to tSaved
   return tRole
end heAdmitTokenRole

function heRosterBody pMembersList
   -- canonical lobby-presence body (spec 9): each member as "pubHex:role",
   -- sorted ascending, comma-joined -- the exact mirror of roster_body in
   -- tools/protocol-kat.py. pMembersList is return-delimited "pubHex TAB role"
   -- lines; sorting makes every peer sign/verify identical bytes. All chunks
   -- are of plain locals (H6-safe); the body is hex-encoded into the envelope
   -- so its commas never reach the tab-framed wire.
   local tLine, tPubHex, tRoleTxt, tPairs, tSaved
   put the itemDelimiter into tSaved
   set the itemDelimiter to tab
   put empty into tPairs
   repeat for each line tLine in pMembersList
      put item 1 of tLine into tPubHex
      put item 2 of tLine into tRoleTxt
      put tPubHex & ":" & tRoleTxt & return after tPairs
   end repeat
   set the itemDelimiter to tSaved
   if tPairs is not empty then
      delete char -1 of tPairs
   end if
   sort lines of tPairs
   replace return with comma in tPairs
   return tPairs
end heRosterBody

function heLobbyCfgBody
   -- the table cfg the host signs into the transcript at create time; a clean,
   -- canonical string (pinned as kKatLobbyCfgBody) so joiners verify it byte
   -- for byte. Level 0 is the online deal ladder rung this build targets.
   return "v=1,level=0,sb=" & gGame["sb"] & ",bb=" & gGame["bb"] \
         & ",seats=" & kHeDefaultSeats & ",button=1"
end heLobbyCfgBody

function heReadableErr pErr
   -- pull the human-readable message out of a LiveCode execution-error struct
   -- (lines of errNo,line,col[,text]); a thrown extension error carries the real
   -- reason as the text field of one of those lines. Returns the first line's
   -- text that reads like a sentence, else the raw error unchanged.
   local tLine, tTxt
   set the itemDelimiter to comma
   repeat for each line tLine in pErr
      if the number of items of tLine >= 4 then
         put item 4 to -1 of tLine into tTxt
         if the number of chars of tTxt > 10 and tTxt contains space then
            return tTxt
         end if
      end if
   end repeat
   return pErr
end heReadableErr

command heNetStart
   -- start THE TorrentXT session, enable rp1, publish our admission token,
   -- and arm the poll drain. NEEDS AN OXT PASS. Requires tableIdHex + identity
   -- already set (heTableCreate/heTableJoin do that first).
   local tSession, tRole, tErr, tRp1Err
   if gGame["online"] is "true" then
      exit heNetStart
   end if
   try
      put btStartSession() into tSession
   catch tErr
      -- btStartSession is the one bt* handler that throws, and the usual cause is
      -- an ABI mismatch between TorrentXT's bundled native library and its .lcb
      -- binding (reinstall/repackage TorrentXT so they match). Surface the
      -- readable reason, not the raw LiveCode error struct.
      heUISetStatus "TorrentXT session failed to start: " & heReadableErr(tErr) \
            & "  --  reinstall/rebuild TorrentXT so its native library matches its binding. Hotseat still works."
      exit heNetStart
   end try
   if tSession is 0 or tSession is empty then
      heUISetStatus "Network start failed: " & btLastError()
      exit heNetStart
   end if
   put tSession into gGame["session"]
   if gGame["isHost"] is "true" then
      put "host" into tRole
   else
      put "player" into tRole
   end if
   -- rp1 is TorrentXT's peer-wire messaging plugin (ABI v8+); a build that ships
   -- the session/DHT surface but not rp1 makes btRp1Enable "can't find handler".
   -- The online game needs rp1, so if the transport setup can't complete, tear the
   -- session back down and report it clearly rather than crash the join (H4/H1).
   try
      btSetBool tSession, "enable_dht", true
      btRp1Enable tSession
      btRp1SetToken tSession, heAdmitTokenData(gGame["tableIdHex"], gGame["idPubHex"], gGame["idSecData"], tRole)
   catch tRp1Err
      heUISetStatus "This TorrentXT build has no rp1 peer messaging (needs the rp1 plugin, ABI v8+): " \
            & tRp1Err & ".  Online is unavailable on this build; hotseat still works."
      try
         btStopSession tSession
      catch tErr
      end try
      put empty into gGame["session"]
      exit heNetStart
   end try
   put "true" into gGame["online"]
   send "heNetPollTick" to me in 250 milliseconds
end heNetStart

command heNetStop
   local tMsgLine
   if gGame["online"] is not "true" then
      exit heNetStop
   end if
   put "false" into gGame["online"]
   -- cancel the outstanding poll tick before tearing the session down: the online
   -- flag alone let a stale tick (scheduled before the stop) revive itself, so a
   -- re-create/re-join forked a SECOND poll loop that never died (H2). Sweep our
   -- own poll send. (gotcha 5: pendingMessages is comma-delimited id,time,name,..)
   set the itemDelimiter to comma
   repeat for each line tMsgLine in the pendingMessages
      if item 3 of tMsgLine is "heNetPollTick" then
         cancel item 1 of tMsgLine
      end if
   end repeat
   btStopSession gGame["session"]
end heNetStop

command heNetJoinSwarm pIsHost
   -- add the phantom swarm on the table's rendezvous id, then announce (host)
   -- or discover (player) on the DHT (spec 10). The DHT carries zero game data.
   -- Only runs when heNetStart brought the transport fully up (online true), so a
   -- build that failed the rp1 setup never reaches these DHT calls; guarded anyway.
   local tSession, tSwarmErr
   if gGame["online"] is not "true" then
      exit heNetJoinSwarm
   end if
   put gGame["session"] into tSession
   try
      get btAddInfohash(tSession, gGame["infohashHex"], heTempPath())
      if pIsHost then
         btDhtAnnounce tSession, gGame["infohashHex"], 0
      else
         btDhtGetPeers tSession, gGame["infohashHex"]
      end if
   catch tSwarmErr
      heUISetStatus "DHT rendezvous unavailable on this TorrentXT build: " & tSwarmErr
   end try
end heNetJoinSwarm

function heTableInfohash pTableHex
   -- the DHT rendezvous id is the first 40 hex (20 bytes) of H(tableId) (spec 10)
   return char 1 to 40 of heHashHex(heHex2BinD(pTableHex))
end heTableInfohash

command heTableCreate
   -- become the host of a fresh table; the 64-hex table code IS the invite.
   -- online play needs the crypto -- guard so a Sodium-less engine gets a
   -- friendly status, not a hard throw out of heIdentitySetup (H4/UX)
   if not heHasSodium() then
      heUISetStatus "Online tables need SodiumXT installed. You can still play hotseat."
      exit heTableCreate
   end if
   -- tear down any prior session first so a re-create starts a clean swarm
   heNetStop
   heIdentitySetup
   if heHasSodium() then
      put heBin2HexS(sxRandomBytes(32)) into gGame["tableIdHex"]
   else
      put heHexId(64) into gGame["tableIdHex"]
   end if
   put heTableInfohash(gGame["tableIdHex"]) into gGame["infohashHex"]
   put "true" into gGame["isHost"]
   put gGame["idPubHex"] into gGame["hostPubHex"]
   put 0 into gGame["handNum"]
   put 0 into gGame["seqCounter"]
   put kHeGenesisPrev into gGame["chainHeadHex"]
   put empty into gGame["peerPubA"]
   put empty into gGame["peerByPub"]
   put empty into gGame["admittedA"]
   put empty into gGame["roleByPub"]
   put empty into gGame["log"]
   put empty into gGame["netLog"]
   put 0 into gGame["syncCooldown"]
   -- the host must admit ITSELF so heHostRelay accepts the host's own actions
   put "true" into gGame["admittedA"][gGame["idPubHex"]]
   put "host" into gGame["roleByPub"][gGame["idPubHex"]]
   heNetStart
   if gGame["online"] is not "true" then
      exit heTableCreate   -- transport unavailable; heNetStart set the status
   end if
   heNetJoinSwarm true
   -- seed the transcript with a signed table cfg (seq 1, from genesis); late
   -- joiners replay it and verify the host's key before anything else
   heNetSendAction "cfg", heLobbyCfgBody()
   heUISetStatus "Table created. Share this invite code: " & gGame["tableIdHex"]
end heTableCreate

command heTableJoin pCodeTxt
   -- join an existing table from its invite code
   local tCode
   if not heHasSodium() then
      heUISetStatus "Online tables need SodiumXT installed. You can still play hotseat."
      exit heTableJoin
   end if
   put word 1 of pCodeTxt into tCode
   if not heIsHex(tCode, 64) then
      heUISetStatus "Invite code must be 64 hex characters."
      exit heTableJoin
   end if
   -- tear down any prior session first so a re-join starts clean
   heNetStop
   heIdentitySetup
   put tCode into gGame["tableIdHex"]
   put heTableInfohash(tCode) into gGame["infohashHex"]
   put "false" into gGame["isHost"]
   put empty into gGame["hostPubHex"]
   put 0 into gGame["handNum"]
   put kHeGenesisPrev into gGame["chainHeadHex"]
   put empty into gGame["peerPubA"]
   put empty into gGame["peerByPub"]
   put empty into gGame["admittedA"]
   put empty into gGame["roleByPub"]
   put empty into gGame["log"]
   put empty into gGame["netLog"]
   put 0 into gGame["syncCooldown"]
   -- admit ourselves as a player so the local roster shows our own seat
   put "true" into gGame["admittedA"][gGame["idPubHex"]]
   put "player" into gGame["roleByPub"][gGame["idPubHex"]]
   heNetStart
   if gGame["online"] is not "true" then
      exit heTableJoin   -- transport unavailable; heNetStart set the status
   end if
   heNetJoinSwarm false
   heUISetStatus "Joining table " & char 1 to 12 of tCode & "... waiting for the host."
end heTableJoin

on heNetPollTick
   -- one poll drain per tick (H2): rp1 events for gameplay, plus btPoll to
   -- keep the engine's own event queue clear. Never per-frame.
   local tEvents, tEv, tPollErr
   if gGame["online"] is not "true" then
      exit heNetPollTick
   end if
   -- age the resync debounce one tick (heNetRequestSync sets it to 8)
   if gGame["syncCooldown"] > 0 then
      subtract 1 from gGame["syncCooldown"]
   end if
   put btRp1Poll(gGame["session"]) into tEvents
   -- an inbound rp1 event is attacker-controlled: a single throwing dispatch must
   -- drop-and-log (H4), never abort the drain or -- worse -- skip the re-arm below
   -- and silently kill the poll loop (deep-dive transport). The re-arm always runs.
   repeat for each element tEv in tEvents
      try
         heNetOnRp1 tEv
      catch tPollErr
         put "poll   dropped a throwing rp1 event: " & tPollErr & return after gGame["netLog"]
      end try
   end repeat
   get btPoll(gGame["session"])
   send "heNetPollTick" to me in 250 milliseconds
end heNetPollTick

command heNetOnRp1 pEvA
   -- dispatch one drained rp1 event (an array with name/peer/payload/token)
   switch pEvA["name"]
      case "rp1Handshake"
         heNetOnHandshake pEvA["peer"], pEvA["token"]
         break
      case "rp1Message"
         heNetOnMessage pEvA["peer"], pEvA["payload"]
         break
   end switch
end heNetOnRp1

command heNetOnHandshake pPeer, pTokenData
   -- admit-or-drop (spec 5): a peer whose token does not verify against this
   -- table is ignored, before any game message is accepted from it
   local tPubHex, tRoleTxt, tIsNew, tOldPeer, tReconnect, tPeersA, tHostShort
   put heAdmitTokenVerify(pTokenData, gGame["tableIdHex"]) into tPubHex
   if tPubHex is empty then
      put "drop   handshake from an unadmitted peer" & return after gGame["netLog"]
      heLobbyRefresh
      exit heNetOnHandshake
   end if
   put heAdmitTokenRole(pTokenData) into tRoleTxt
   put (gGame["admittedA"][tPubHex] is not "true") into tIsNew
   -- a known key handshaking on a NEW peer handle is a reconnect: it needs the
   -- transcript replayed too, not just first-time joiners (spec 9)
   put gGame["peerByPub"][tPubHex] into tOldPeer
   put (tOldPeer is not empty and tOldPeer is not pPeer) into tReconnect
   -- on reconnect, drop the stale handle so peerPubA holds only live peers and
   -- heNetBroadcast never sends to a dead handle (deep-dive transport). Delete via
   -- a plain local array (the supported form; avoids a nested-subscript delete).
   if tReconnect then
      put gGame["peerPubA"] into tPeersA
      delete variable tPeersA[tOldPeer]
      put tPeersA into gGame["peerPubA"]
   end if
   put tPubHex into gGame["peerPubA"][pPeer]
   put pPeer into gGame["peerByPub"][tPubHex]
   put "true" into gGame["admittedA"][tPubHex]
   put tRoleTxt into gGame["roleByPub"][tPubHex]
   -- adopt as host only a peer whose token DECLARES role "host" -- the phantom
   -- swarm connects players to each other too, so "first peer" is not the host.
   -- Trust-on-first-use: pin the first host key and surface (do NOT silently
   -- swap to) any later, DIFFERENT host-declaring key -- attributable, and the
   -- seam where a real invite<->host binding will reject it outright. Full host
   -- election / host loss is spec 9 / a later increment.
   if gGame["isHost"] is not "true" and tRoleTxt is "host" then
      if gGame["hostPubHex"] is empty then
         put tPubHex into gGame["hostPubHex"]
      else if gGame["hostPubHex"] is not tPubHex then
         -- copy the trusted host key out before chunking it (H6: never chunk an
         -- array element directly)
         put gGame["hostPubHex"] into tHostShort
         put "WARN   ignored a second host-declaring key " & char 1 to 12 of tPubHex \
               & " (already trust " & char 1 to 12 of tHostShort & ")" & return after gGame["netLog"]
      end if
   end if
   if tIsNew then
      put "+peer  " & char 1 to 12 of tPubHex & "  (" & tRoleTxt & ")" & return after gGame["netLog"]
   end if
   -- host: catch a peer up on the whole transcript (spec 9 replay) on first
   -- join OR reconnect, then re-sign and broadcast the roster so presence agrees
   if gGame["isHost"] is "true" and (tIsNew or tReconnect) then
      heNetReplayLogTo pPeer
      if tIsNew then
         heHostEmitRoster
      end if
   end if
   heLobbyRefresh
end heNetOnHandshake

command heNetOnMessage pPeer, pPayloadData
   -- payload kinds (tab-framed): "c" = a player's signed content line to the
   -- host; "w" = a host-relayed sequenced wire to everyone. Verify-or-drop.
   local tPayload, tKind, tRest, tSaved, tPeerPub
   put textDecode(pPayloadData, "utf-8") into tPayload
   put the itemDelimiter into tSaved
   set the itemDelimiter to tab
   put item 1 of tPayload into tKind
   put item 2 to -1 of tPayload into tRest
   set the itemDelimiter to tSaved
   switch tKind
      case "c"
         if gGame["isHost"] is "true" then
            heHostRelay pPeer, tRest
         end if
         break
      case "w"
         heNetIngestWire tRest
         break
      case "s?"
         -- a peer asks us (the host) to replay the transcript so it can catch
         -- up from a chain gap (spec 9). Only honor it from an admitted,
         -- connected peer, so an unknown socket cannot trigger a replay.
         put gGame["peerPubA"][pPeer] into tPeerPub
         if gGame["isHost"] is "true" and tPeerPub is not empty then
            -- rate-limit replays PER PEER: at most one per ~2s, so a flood of "s?"
            -- cannot amplify into unbounded full-transcript replays (deep-dive DoS).
            -- Keyed by the peer's pubkey (stable across handle churn), timed off the
            -- engine clock so no per-tick decrement is needed.
            if gGame["replayMsByPub"][tPeerPub] is not empty \
                  and (the milliseconds - gGame["replayMsByPub"][tPeerPub]) < 2000 then
               exit heNetOnMessage
            end if
            put the milliseconds into gGame["replayMsByPub"][tPeerPub]
            put "sync!  replaying transcript to " & char 1 to 8 of tPeerPub & return after gGame["netLog"]
            heNetReplayLogTo pPeer
            heLobbyRefresh
         end if
         break
   end switch
end heNetOnMessage

command heHostRelay pPeer, pContentAndSig
   -- host path: take a player's (contentLine TAB senderSig), assign seq + prev,
   -- countersign, advance the chain, and broadcast the sequenced wire to all.
   -- The content's own sender signature is checked before it is relayed.
   local tContent, tSenderSig, tSaved, tFromHex, tEnvLine, tHostSig, tWire, tTypeTxt
   put the itemDelimiter into tSaved
   set the itemDelimiter to tab
   -- contentLine is items 1..6, senderSig is item 7 of pContentAndSig
   put item 1 to 6 of pContentAndSig into tContent
   put item 7 of pContentAndSig into tSenderSig
   put item 4 of tContent into tFromHex
   put item 5 of tContent into tTypeTxt
   set the itemDelimiter to tSaved
   -- a player packet is untrusted: reject malformed hex before decoding it
   -- (sxHex2Bin throws) so a corrupt "c" frame cannot kill the host relay (H4)
   if not heIsHex(tFromHex, 64) or not heIsHex(tSenderSig, 128) then
      exit heHostRelay
   end if
   -- host-authority: cfg/roster are host-authored presence; never sequence and
   -- relay them for a non-host sender, so an admitted player cannot forge table
   -- config or roster through the relay (deep-dive transport). The host emits
   -- these from its own key (heNetSendAction uses gGame["idPubHex"]).
   if (tTypeTxt is "cfg" or tTypeTxt is "roster") and tFromHex is not gGame["hostPubHex"] then
      exit heHostRelay
   end if
   -- verify the sender actually signed this content (host cannot forge content)
   if not heVerifyDetached(heHex2BinD(tSenderSig), textEncode(tContent, "utf-8"), heHex2BinD(tFromHex)) then
      exit heHostRelay
   end if
   if gGame["admittedA"][tFromHex] is not "true" then
      exit heHostRelay
   end if
   add 1 to gGame["seqCounter"]
   put tContent & tab & tSenderSig & tab & gGame["seqCounter"] & tab & gGame["chainHeadHex"] into tEnvLine
   put heBin2HexS(heSignDetachedD(textEncode(tEnvLine, "utf-8"), gGame["idSecData"])) into tHostSig
   put tEnvLine & tab & tHostSig into tWire
   heNetBroadcast "w" & tab & tWire
   heNetIngestWire tWire
end heHostRelay

command heNetIngestWire pWire
   -- everyone's inbound path: verify-or-drop against the host key and local
   -- chain head, then advance the chain and fold the message (spec 6/8).
   local tVerdict, tA, tTypeTxt, tSeqTxt
   put heEnvVerify(pWire, empty, gGame["hostPubHex"], gGame["chainHeadHex"]) into tVerdict
   if tVerdict is not "ok" then
      -- drop and log; a bad/replayed/reordered message is not an exception
      put tVerdict && char 1 to 24 of pWire & return after gGame["netLog"]
      -- a chain break means we missed a wire (rp1 is lossy/reorders): ask the
      -- host to replay the transcript so we catch up, instead of wedging here
      -- forever (spec 9). Debounced in heNetRequestSync. Other drops are real
      -- rejections and must NOT trigger a resync.
      if tVerdict is "drop:chain-break" then
         heNetRequestSync
      end if
      heLobbyRefresh
      exit heNetIngestWire
   end if
   put heEnvWireParse(pWire) into tA
   -- bind the envelope to THIS table and protocol version before folding it. Both
   -- fields sit inside the host-signed span, but a receiver still has to ENFORCE
   -- them: otherwise a host-signed wire for another table, or a downgraded envelope
   -- version, would be accepted onto our chain (deep-dive transport). A mismatch is
   -- a hard drop, NOT a chain gap, so it never triggers a resync.
   if tA["table"] is not gGame["tableIdHex"] then
      put "drop:wrong-table " & char 1 to 24 of pWire & return after gGame["netLog"]
      heLobbyRefresh
      exit heNetIngestWire
   end if
   if tA["v"] is not kHeEnvV then
      put "drop:bad-version " & char 1 to 24 of pWire & return after gGame["netLog"]
      heLobbyRefresh
      exit heNetIngestWire
   end if
   put heChainNextHex(pWire) into gGame["chainHeadHex"]
   put pWire & return after gGame["log"]
   put tA["type"] into tTypeTxt
   put tA["seq"] into tSeqTxt
   put "ok     " & tTypeTxt & " seq " & tSeqTxt & return after gGame["netLog"]
   -- lobby presence bodies drive the roster/cfg display; gameplay wires drive
   -- the betting engine (the deal increment). tA fields are plain locals now,
   -- so heEnvBodyText chunks only plain text (H6-safe). roster/cfg are HOST-
   -- authored presence (spec 9): fold them only when the wire's own sender is the
   -- host, so an admitted player cannot forge table config/roster by getting a
   -- content line relayed (the host relays any admitted sender's content).
   if tTypeTxt is "roster" or tTypeTxt is "cfg" then
      if tA["from"] is gGame["hostPubHex"] then
         if tTypeTxt is "roster" then
            put heEnvBodyText(tA["bodyHex"]) into gGame["rosterBody"]
         else
            put heEnvBodyText(tA["bodyHex"]) into gGame["cfgBody"]
         end if
      else
         put "drop   non-host " & tTypeTxt & " body ignored" & return after gGame["netLog"]
      end if
   end if
   heLobbyRefresh
end heNetIngestWire

command heNetSendAction pTypeTxt, pBodyTxt
   -- a player emits a signed content line to the host (or, if we are the host,
   -- straight into the relay). The host sequences and countersigns it.
   local tContent, tSenderSig, tPacket
   put heEnvContentLine(gGame["tableIdHex"], gGame["handNum"], gGame["idPubHex"], pTypeTxt, pBodyTxt) into tContent
   put heEnvSenderSigHex(tContent, gGame["idSecData"]) into tSenderSig
   put tContent & tab & tSenderSig into tPacket
   if gGame["isHost"] is "true" then
      heHostRelay 0, tPacket
   else
      heNetSendToHost "c" & tab & tPacket
   end if
end heNetSendAction

command heNetSendToHost pPayloadTxt
   local tHostPeer
   put gGame["peerByPub"][gGame["hostPubHex"]] into tHostPeer
   if tHostPeer is empty then
      exit heNetSendToHost
   end if
   get btRp1Send(gGame["session"], tHostPeer, textEncode(pPayloadTxt, "utf-8"))
end heNetSendToHost

command heNetRequestSync
   -- recover from a chain gap: ask the host to replay the transcript (spec 9)
   -- instead of wedging on drop:chain-break forever. Debounced by a tick
   -- cooldown so a burst of dropped wires -- or a lost request -- re-asks at
   -- most once every ~2 s, never floods the host. The host never self-syncs.
   if gGame["isHost"] is "true" then
      exit heNetRequestSync
   end if
   if gGame["syncCooldown"] > 0 then
      exit heNetRequestSync
   end if
   if gGame["hostPubHex"] is empty then
      exit heNetRequestSync
   end if
   put 8 into gGame["syncCooldown"]
   put "sync?  requested transcript replay (chain gap)" & return after gGame["netLog"]
   heNetSendToHost "s?"
end heNetRequestSync

command heNetBroadcast pPayloadTxt
   -- host sends to every admitted peer (star topology, spec 4)
   local tPeer, tData
   put textEncode(pPayloadTxt, "utf-8") into tData
   repeat for each key tPeer in gGame["peerPubA"]
      get btRp1Send(gGame["session"], tPeer, tData)
   end repeat
end heNetBroadcast

command heNetSendWireTo pPeer, pWire
   -- targeted replay of one sequenced wire to a single peer (star topology).
   -- Same "w" framing as a broadcast so the receiver's heNetOnMessage path is
   -- identical whether the wire arrived live or as catch-up.
   get btRp1Send(gGame["session"], pPeer, textEncode("w" & tab & pWire, "utf-8"))
end heNetSendWireTo

command heNetReplayLogTo pPeer
   -- spec 9 reconnect seam: replay the whole signed wire log to a freshly
   -- handshaked peer, in order, so it advances its chain from genesis and
   -- catches up. Turn-rate, not frame-rate; a lobby log is a few lines.
   local tWireLine, tLog
   put gGame["log"] into tLog
   repeat for each line tWireLine in tLog
      if tWireLine is not empty then
         heNetSendWireTo pPeer, tWireLine
      end if
   end repeat
end heNetReplayLogTo

command heHostEmitRoster
   -- host-only: re-sign and broadcast the current roster whenever the admitted
   -- set changes (spec 9 presence). Every client sorts the members identically
   -- (heRosterBody), so the signed bytes match everywhere.
   local tKeyPub, tRoleTxt, tMembers
   if gGame["isHost"] is not "true" then
      exit heHostEmitRoster
   end if
   put empty into tMembers
   repeat for each key tKeyPub in gGame["admittedA"]
      put gGame["roleByPub"][tKeyPub] into tRoleTxt
      if tRoleTxt is empty then
         put "player" into tRoleTxt
      end if
      put tKeyPub & tab & tRoleTxt & return after tMembers
   end repeat
   if tMembers is not empty then
      delete char -1 of tMembers
   end if
   heNetSendAction "roster", heRosterBody(tMembers)
end heHostEmitRoster

--------------------------------------------------------------------------
-- small pure utilities
--------------------------------------------------------------------------

function heTwoDigits pNum
   if pNum < 10 then
      return "0" & pNum
   end if
   return pNum
end heTwoDigits

function heCountItems pList
   set the itemDelimiter to comma
   if pList is empty then
      return 0
   end if
   return the number of items of pList
end heCountItems

function heNextInList pList, pEntry
   -- circular successor of pEntry in a comma list
   local tPos, tCount
   set the itemDelimiter to comma
   put the number of items of pList into tCount
   repeat with tPos = 1 to tCount
      if item tPos of pList is pEntry then
         if tPos is tCount then
            return item 1 of pList
         end if
         return item (tPos + 1) of pList
      end if
   end repeat
   return item 1 of pList
end heNextInList

function heRotateAfter pList, pEntry
   -- the list re-ordered to start just after pEntry (deal / action order)
   local tPos, tCount, tOut
   set the itemDelimiter to comma
   put the number of items of pList into tCount
   repeat with tPos = 1 to tCount
      if item tPos of pList is pEntry then
         if tPos is tCount then
            return pList
         end if
         put item (tPos + 1) to tCount of pList & comma & item 1 to tPos of pList into tOut
         return tOut
      end if
   end repeat
   return pList
end heRotateAfter

function heNextLiveAfterPos pLiveList, pPos
   -- next live seat strictly after physical position pPos, circular over the
   -- live seats -- works even when pPos itself is not live (a busted seat).
   -- pLiveList must be ascending.
   local tSeatNum
   set the itemDelimiter to comma
   repeat for each item tSeatNum in pLiveList
      if tSeatNum > pPos then
         return tSeatNum
      end if
   end repeat
   return item 1 of pLiveList
end heNextLiveAfterPos

function hePrevLiveBeforePos pLiveList, pPos
   -- previous live seat strictly before physical position pPos, circular
   local tSeatNum, tPrev
   set the itemDelimiter to comma
   put item -1 of pLiveList into tPrev
   repeat for each item tSeatNum in pLiveList
      if tSeatNum < pPos then
         put tSeatNum into tPrev
      end if
   end repeat
   return tPrev
end hePrevLiveBeforePos

function heScheduleButton pLiveList, pLastBB
   -- dead-button-aware blind schedule (TDA rule 10, simplified to always post
   -- a live small blind): the big blind ALWAYS advances to the next live seat
   -- clockwise from the previous big blind, so nobody posts it twice running
   -- and no live seat skips it across an elimination. Returns the button seat;
   -- heBetNewHand then derives SB = next live after button, BB = next after SB
   -- (heads-up: button IS the SB), which reproduces this schedule exactly.
   local tBB, tSB
   set the itemDelimiter to comma
   if pLastBB is 0 then
      return item 1 of pLiveList
   end if
   put heNextLiveAfterPos(pLiveList, pLastBB) into tBB
   put hePrevLiveBeforePos(pLiveList, tBB) into tSB
   if heCountItems(pLiveList) is 2 then
      return tSB
   end if
   return hePrevLiveBeforePos(pLiveList, tSB)
end heScheduleButton

function heHexId pLen
   -- a random lowercase-hex id built char by char (no binary, no FFI): a
   -- display/table handle only, not dealing- or key-related
   local tOut, tI
   put empty into tOut
   repeat pLen times
      put char (random(16)) of "0123456789abcdef" after tOut
   end repeat
   return tOut
end heHexId

--------------------------------------------------------------------------
-- cards (contract pinned in tools/evaluator-kat.py)
--------------------------------------------------------------------------

function heCardRankVal pIdx
   return (pIdx - 1) div 4 + 2
end heCardRankVal

function heCardSuitVal pIdx
   return (pIdx - 1) mod 4 + 1
end heCardSuitVal

function heCardName pIdx
   local tRankPos, tSuitPos
   put (pIdx - 1) div 4 + 1 into tRankPos
   put (pIdx - 1) mod 4 + 1 into tSuitPos
   return char tRankPos of kHeRankChars & char tSuitPos of kHeSuitChars
end heCardName

function heCardIndex pName
   local tRankVal, tSuitVal, tNameTxt
   put pName into tNameTxt
   put offset(char 1 of tNameTxt, kHeRankChars) + 1 into tRankVal
   put offset(char 2 of tNameTxt, kHeSuitChars) into tSuitVal
   return (tRankVal - 2) * 4 + tSuitVal
end heCardIndex

--------------------------------------------------------------------------
-- hand evaluator (spec 8.2) -- pure, pinned by tools/evaluator-kat.py.
-- Result: 12-char packed string, six 2-digit fields, category then five
-- tiebreak ranks; fixed width so plain numeric comparison orders hands.
--------------------------------------------------------------------------

function heRank5 pFive
   -- pFive: comma list of exactly five card indices
   local tRankList, tSuitList, tPos, tIdx, tFlush, tDistinct, tHighStraight
   local tCountA, tRankVal, tGroupLines, tSizes, tGRanks, tOut
   set the itemDelimiter to comma
   put empty into tRankList
   put empty into tSuitList
   repeat for each item tIdx in pFive
      put heCardRankVal(tIdx) & comma after tRankList
      put heCardSuitVal(tIdx) & comma after tSuitList
   end repeat
   delete char -1 of tRankList
   delete char -1 of tSuitList
   sort items of tRankList numeric descending

   -- flush: all five suits equal
   put true into tFlush
   repeat with tPos = 2 to 5
      if item tPos of tSuitList is not item 1 of tSuitList then
         put false into tFlush
      end if
   end repeat

   -- straight: five distinct ranks spanning 4, or the wheel (A-5-4-3-2)
   put empty into tDistinct
   repeat with tPos = 1 to 5
      if item tPos of tRankList is not among the items of tDistinct then
         put item tPos of tRankList & comma after tDistinct
      end if
   end repeat
   delete char -1 of tDistinct
   put 0 into tHighStraight
   if the number of items of tDistinct is 5 then
      if (item 1 of tDistinct) - (item 5 of tDistinct) is 4 then
         put item 1 of tDistinct into tHighStraight
      else if tDistinct is "14,5,4,3,2" then
         put 5 into tHighStraight
      end if
   end if

   if tFlush and tHighStraight > 0 then
      return "08" & heTwoDigits(tHighStraight) & "00000000"
   end if

   -- histogram: sort groups by (count, rank) descending in ONE pass. The sort
   -- key is PRECOMPUTED as item 1 (count * 100 + rank; rank <= 14 < 100, so
   -- count dominates and rank breaks ties), then we sort by that single field
   -- with the proven "by item 1 of each" form. So correctness depends neither
   -- on LiveCode's sort being stable NOR on an arithmetic sort-by expression --
   -- both are removed. Each line is "sortKey,count,rank" (frequencies +
   -- order-isomorphism pinned in tools/logic-fuzz.py).
   repeat with tPos = 1 to 5
      put item tPos of tRankList into tRankVal
      if tCountA[tRankVal] is empty then
         put 0 into tCountA[tRankVal]
      end if
      add 1 to tCountA[tRankVal]
   end repeat
   put empty into tGroupLines
   repeat for each key tRankVal in tCountA
      put (tCountA[tRankVal] * 100 + tRankVal) & comma & tCountA[tRankVal] & comma & tRankVal & return after tGroupLines
   end repeat
   delete char -1 of tGroupLines
   sort lines of tGroupLines numeric descending by item 1 of each
   put empty into tSizes
   put empty into tGRanks
   repeat for each line tOut in tGroupLines
      put item 2 of tOut & comma after tSizes
      put item 3 of tOut & comma after tGRanks
   end repeat
   delete char -1 of tSizes
   delete char -1 of tGRanks

   if item 1 of tSizes is 4 then
      return "07" & heTwoDigits(item 1 of tGRanks) & heTwoDigits(item 2 of tGRanks) & "000000"
   end if
   if item 1 of tSizes is 3 and item 2 of tSizes is 2 then
      return "06" & heTwoDigits(item 1 of tGRanks) & heTwoDigits(item 2 of tGRanks) & "000000"
   end if
   if tFlush then
      put "05" into tOut
      repeat with tPos = 1 to 5
         put heTwoDigits(item tPos of tRankList) after tOut
      end repeat
      return tOut
   end if
   if tHighStraight > 0 then
      return "04" & heTwoDigits(tHighStraight) & "00000000"
   end if
   if item 1 of tSizes is 3 then
      return "03" & heTwoDigits(item 1 of tGRanks) & heTwoDigits(item 2 of tGRanks) \
            & heTwoDigits(item 3 of tGRanks) & "0000"
   end if
   if item 1 of tSizes is 2 and item 2 of tSizes is 2 then
      return "02" & heTwoDigits(item 1 of tGRanks) & heTwoDigits(item 2 of tGRanks) \
            & heTwoDigits(item 3 of tGRanks) & "0000"
   end if
   if item 1 of tSizes is 2 then
      return "01" & heTwoDigits(item 1 of tGRanks) & heTwoDigits(item 2 of tGRanks) \
            & heTwoDigits(item 3 of tGRanks) & heTwoDigits(item 4 of tGRanks) & "00"
   end if
   put "00" into tOut
   repeat with tPos = 1 to 5
      put heTwoDigits(item tPos of tRankList) after tOut
   end repeat
   return tOut
end heRank5

function heEval7 pSeven
   -- best 5 of 7 by exhaustive 21-combination scan: the dumbest correct
   -- algorithm, identical to the CI mirror, nothing clever to get wrong
   local tSkipA, tSkipB, tPos, tFive, tRank, tBest
   set the itemDelimiter to comma
   put empty into tBest
   repeat with tSkipA = 1 to 6
      repeat with tSkipB = tSkipA + 1 to 7
         put empty into tFive
         repeat with tPos = 1 to 7
            if tPos is not tSkipA and tPos is not tSkipB then
               put item tPos of pSeven & comma after tFive
            end if
         end repeat
         delete char -1 of tFive
         put heRank5(tFive) into tRank
         if tBest is empty or tRank > tBest then
            put tRank into tBest
         end if
      end repeat
   end repeat
   return tBest
end heEval7

--------------------------------------------------------------------------
-- the deal: pure-integer PRNG shuffle (binary-free). Randomness law kept in
-- spirit -- CSPRNG entropy (sxRandomUniform) seeds it when SodiumXT is
-- present; engine time+random is a labelled practice fallback only.
--------------------------------------------------------------------------

function heFreshPrngState
   -- returns a MINSTD seed in 1..kHeRngMax
   local tSeed, tErr
   put 0 into tSeed
   if heHasSodium() then
      try
         repeat 3 times
            put (tSeed * 32768 + (sxRandomUniform(32768) mod 32768)) mod kHeRngMod into tSeed
         end repeat
      catch tErr
         put 0 into tSeed
      end try
   end if
   if tSeed <= 0 then
      -- practice entropy: engine time + random(), non-cryptographic
      put (the milliseconds) mod kHeRngMod into tSeed
      repeat 3 times
         put (tSeed * 131 + random(32768)) mod kHeRngMod into tSeed
      end repeat
   end if
   return (tSeed mod kHeRngMax) + 1
end heFreshPrngState

function heRngStep pState
   return (kHeRngMul * pState) mod kHeRngMod
end heRngStep

function heDrawInt pState, pRangeN
   -- uniform 1..pRangeN with rejection sampling (no modulo bias); returns
   -- "value,newState". Pure integer arithmetic, all products < 2^53.
   local tLimit, tS, tV
   put (kHeRngMax div pRangeN) * pRangeN into tLimit
   put pState into tS
   repeat forever
      put heRngStep(tS) into tS
      put tS - 1 into tV
      if tV < tLimit then
         return ((tV mod pRangeN) + 1) & comma & tS
      end if
   end repeat
end heDrawInt

function heShuffleDeck pState
   -- Fisher-Yates over deck[1..52]; deck 1 is the top, dealt first
   local tDeckA, tPos, tSwapPos, tDrawPair, tHold, tOut, tState
   set the itemDelimiter to comma
   repeat with tPos = 1 to 52
      put tPos into tDeckA[tPos]
   end repeat
   put pState into tState
   repeat with tPos = 52 down to 2
      put heDrawInt(tState, tPos) into tDrawPair
      put item 1 of tDrawPair into tSwapPos
      put item 2 of tDrawPair into tState
      put tDeckA[tPos] into tHold
      put tDeckA[tSwapPos] into tDeckA[tPos]
      put tHold into tDeckA[tSwapPos]
   end repeat
   put empty into tOut
   repeat with tPos = 1 to 52
      put tDeckA[tPos] & comma after tOut
   end repeat
   delete char -1 of tOut
   return tOut
end heShuffleDeck

function heDealAssign pDeckList, pOccupiedList, pButtonSeat
   -- fixed public consumption order (spec 7.3, adopted at every level):
   -- one card per occupied seat starting left of the button, two rounds,
   -- then burn, flop x3, burn, turn, burn, river
   local tOrder, tPos, tSeatNum, tOutA, tRound, tHoleTxt
   set the itemDelimiter to comma
   put heRotateAfter(pOccupiedList, pButtonSeat) into tOrder
   put 0 into tPos
   repeat with tRound = 1 to 2
      repeat for each item tSeatNum in tOrder
         add 1 to tPos
         put tOutA["holesBy"][tSeatNum] into tHoleTxt
         if tHoleTxt is empty then
            put item tPos of pDeckList into tOutA["holesBy"][tSeatNum]
         else
            put tHoleTxt & comma & item tPos of pDeckList into tOutA["holesBy"][tSeatNum]
         end if
      end repeat
   end repeat
   put item (tPos + 1) of pDeckList into tOutA["burnsList"]
   put item (tPos + 2) to (tPos + 4) of pDeckList into tOutA["flopList"]
   put tOutA["burnsList"] & comma & item (tPos + 5) of pDeckList into tOutA["burnsList"]
   put item (tPos + 6) of pDeckList into tOutA["turnIx"]
   put tOutA["burnsList"] & comma & item (tPos + 7) of pDeckList into tOutA["burnsList"]
   put item (tPos + 8) of pDeckList into tOutA["riverIx"]
   return tOutA
end heDealAssign

--------------------------------------------------------------------------
-- betting engine (spec 8.1) -- a pure state machine over transcript-shaped
-- messages. State travels as an array; heBetApply returns the next state
-- with "err" set (state otherwise unchanged) on any illegal message, and
-- "note" carrying events the shell reacts to ("advance:flop", "runout",
-- "showdown", "foldwin:3"). "actedBy" means "has acted since the last FULL
-- raise" -- the flag that makes under-raise all-ins not reopen betting.
--------------------------------------------------------------------------

function heBetNewHand pSB, pBB, pAnte, pStacksA, pOccupiedList, pButtonSeat
   local tStateA, tSeatNum, tCount
   set the itemDelimiter to comma
   put pSB into tStateA["sb"]
   put pBB into tStateA["bb"]
   put pAnte into tStateA["ante"]
   put pOccupiedList into tStateA["occ"]
   put pButtonSeat into tStateA["buttonSeat"]
   put "preflop" into tStateA["street"]
   put "blinds" into tStateA["phase"]
   put 0 into tStateA["toAct"]
   put 0 into tStateA["betCur"]
   put pBB into tStateA["raiseFull"]
   put 0 into tStateA["aggressor"]
   put 0 into tStateA["sdFirst"]
   put empty into tStateA["err"]
   put empty into tStateA["note"]
   repeat for each item tSeatNum in pOccupiedList
      put pStacksA[tSeatNum] into tStateA["stackBy"][tSeatNum]
      put 0 into tStateA["streetBy"][tSeatNum]
      put 0 into tStateA["handBy"][tSeatNum]
      put "false" into tStateA["foldedBy"][tSeatNum]
      put "false" into tStateA["allinBy"][tSeatNum]
      put "false" into tStateA["actedBy"][tSeatNum]
   end repeat
   put heCountItems(pOccupiedList) into tCount
   if tCount is 2 then
      -- heads-up: the button IS the small blind (spec 8.1)
      put pButtonSeat into tStateA["sbSeat"]
   else
      put heNextInList(pOccupiedList, pButtonSeat) into tStateA["sbSeat"]
   end if
   put heNextInList(pOccupiedList, tStateA["sbSeat"]) into tStateA["bbSeat"]
   return tStateA
end heBetNewHand

function heBetInHandList pStateA
   local tOut, tSeatNum
   set the itemDelimiter to comma
   put empty into tOut
   repeat for each item tSeatNum in pStateA["occ"]
      if pStateA["foldedBy"][tSeatNum] is "false" then
         put tSeatNum & comma after tOut
      end if
   end repeat
   delete char -1 of tOut
   return tOut
end heBetInHandList

function heBetSeatPending pStateA, pSeatNum
   -- a seat owes action if it is in hand, has chips, and either faces a
   -- bigger bet or has not acted since the last full raise
   if pStateA["foldedBy"][pSeatNum] is "true" then
      return false
   end if
   if pStateA["allinBy"][pSeatNum] is "true" then
      return false
   end if
   if pStateA["streetBy"][pSeatNum] < pStateA["betCur"] then
      return true
   end if
   return pStateA["actedBy"][pSeatNum] is "false"
end heBetSeatPending

function heBetNextPending pStateA, pAfterSeat
   local tOrder, tSeatNum
   set the itemDelimiter to comma
   put heRotateAfter(pStateA["occ"], pAfterSeat) into tOrder
   repeat for each item tSeatNum in tOrder
      if heBetSeatPending(pStateA, tSeatNum) then
         return tSeatNum
      end if
   end repeat
   return 0
end heBetNextPending

function heBetLiveCount pStateA
   -- in-hand seats that still have chips behind (can still bet)
   local tCount, tSeatNum
   set the itemDelimiter to comma
   put 0 into tCount
   repeat for each item tSeatNum in pStateA["occ"]
      if pStateA["foldedBy"][tSeatNum] is "false" and pStateA["allinBy"][tSeatNum] is "false" then
         add 1 to tCount
      end if
   end repeat
   return tCount
end heBetLiveCount

function heBetPay pStateA, pSeatNum, pAmount
   -- move pAmount from behind to the street; flags all-in at zero behind
   local tStateA
   put pStateA into tStateA
   subtract pAmount from tStateA["stackBy"][pSeatNum]
   add pAmount to tStateA["streetBy"][pSeatNum]
   add pAmount to tStateA["handBy"][pSeatNum]
   if tStateA["stackBy"][pSeatNum] is 0 then
      put "true" into tStateA["allinBy"][pSeatNum]
   end if
   return tStateA
end heBetPay

function heBetPayDead pStateA, pSeatNum, pAmount
   -- post dead money (antes): into the pot (handBy) only, NEVER the street bet,
   -- so an ante does not reduce what a seat still owes to call the blind. A seat
   -- short of the full ante posts what it has and is all-in for it (side-pot
   -- eligible up to its contribution, exactly like a short blind).
   local tStateA
   put pStateA into tStateA
   subtract pAmount from tStateA["stackBy"][pSeatNum]
   add pAmount to tStateA["handBy"][pSeatNum]
   if tStateA["stackBy"][pSeatNum] is 0 then
      put "true" into tStateA["allinBy"][pSeatNum]
   end if
   return tStateA
end heBetPayDead

function heBetFirstInHandAfter pStateA, pAfterSeat
   local tOrder, tSeatNum
   set the itemDelimiter to comma
   put heRotateAfter(pStateA["occ"], pAfterSeat) into tOrder
   repeat for each item tSeatNum in tOrder
      if pStateA["foldedBy"][tSeatNum] is "false" then
         return tSeatNum
      end if
   end repeat
   return 0
end heBetFirstInHandAfter

function heBetCloseStreet pStateA
   -- action closed: reset street bookkeeping and advance, or hand over
   local tStateA, tSeatNum
   set the itemDelimiter to comma
   put pStateA into tStateA
   -- remember who shows first if this closes the final betting round
   if tStateA["aggressor"] > 0 then
      put tStateA["aggressor"] into tStateA["sdFirst"]
   else
      put heBetFirstInHandAfter(tStateA, tStateA["buttonSeat"]) into tStateA["sdFirst"]
   end if
   repeat for each item tSeatNum in tStateA["occ"]
      put 0 into tStateA["streetBy"][tSeatNum]
      put "false" into tStateA["actedBy"][tSeatNum]
   end repeat
   put 0 into tStateA["betCur"]
   put tStateA["bb"] into tStateA["raiseFull"]
   put 0 into tStateA["aggressor"]
   if tStateA["street"] is "river" then
      put "showdown" into tStateA["phase"]
      put 0 into tStateA["toAct"]
      put "showdown" & return after tStateA["note"]
      return tStateA
   end if
   if heBetLiveCount(tStateA) <= 1 then
      -- nobody left who can bet: the board runs out with no more action
      put "runout" into tStateA["phase"]
      put 0 into tStateA["toAct"]
      put "runout" & return after tStateA["note"]
      return tStateA
   end if
   switch tStateA["street"]
      case "preflop"
         put "flop" into tStateA["street"]
         break
      case "flop"
         put "turn" into tStateA["street"]
         break
      case "turn"
         put "river" into tStateA["street"]
         break
   end switch
   put heBetNextPending(tStateA, tStateA["buttonSeat"]) into tStateA["toAct"]
   put "acting" into tStateA["phase"]
   put "advance:" & tStateA["street"] & return after tStateA["note"]
   return tStateA
end heBetCloseStreet

function heBetAfterAction pStateA, pSeatNum
   -- find the next actor after pSeatNum, or close the street
   local tStateA, tNextSeat
   put pStateA into tStateA
   put heBetNextPending(tStateA, pSeatNum) into tNextSeat
   if tNextSeat is 0 then
      return heBetCloseStreet(tStateA)
   end if
   put tNextSeat into tStateA["toAct"]
   return tStateA
end heBetAfterAction

function heBetApply pStateA, pMsgType, pSeatNum, pAmount
   -- THE transition function: every blind, action, and board message
   local tStateA, tOwe, tPay, tTargetAmt, tIncrement, tSeatNum, tIsAllin
   local tVerb, tAmt
   set the itemDelimiter to comma
   put pStateA into tStateA
   put empty into tStateA["err"]
   put empty into tStateA["note"]

   switch pMsgType

      case "bidAnte"
         -- every seat posts the ante as dead money before the blinds; a seat
         -- short of the ante posts what it has (all-in for the ante)
         if tStateA["phase"] is not "blinds" then
            put "bidAnte-out-of-phase" into tStateA["err"]
            return tStateA
         end if
         put min(tStateA["ante"], tStateA["stackBy"][pSeatNum]) into tPay
         if pAmount is not tPay then
            put "bidAnte-wrong-amount" into tStateA["err"]
            return tStateA
         end if
         put heBetPayDead(tStateA, pSeatNum, tPay) into tStateA
         return tStateA

      case "bidSB"
         if tStateA["phase"] is not "blinds" then
            put "bidSB-out-of-phase" into tStateA["err"]
            return tStateA
         end if
         if pSeatNum is not tStateA["sbSeat"] then
            put "bidSB-wrong-seat" into tStateA["err"]
            return tStateA
         end if
         put min(tStateA["sb"], tStateA["stackBy"][pSeatNum]) into tPay
         if pAmount is not tPay then
            put "bidSB-wrong-amount" into tStateA["err"]
            return tStateA
         end if
         put heBetPay(tStateA, pSeatNum, tPay) into tStateA
         return tStateA

      case "bidBB"
         if tStateA["phase"] is not "blinds" then
            put "bidBB-out-of-phase" into tStateA["err"]
            return tStateA
         end if
         if pSeatNum is not tStateA["bbSeat"] then
            put "bidBB-wrong-seat" into tStateA["err"]
            return tStateA
         end if
         put min(tStateA["bb"], tStateA["stackBy"][pSeatNum]) into tPay
         if pAmount is not tPay then
            put "bidBB-wrong-amount" into tStateA["err"]
            return tStateA
         end if
         put heBetPay(tStateA, pSeatNum, tPay) into tStateA
         -- the big blind is the opening bet even when posted short
         put tStateA["bb"] into tStateA["betCur"]
         put tStateA["bb"] into tStateA["raiseFull"]
         put "acting" into tStateA["phase"]
         put heBetAfterAction(tStateA, pSeatNum) into tStateA
         return tStateA

      case "board"
         -- board messages only move state during a runout; in normal play
         -- the engine advanced at street close and this is just the record
         if tStateA["phase"] is "runout" then
            switch tStateA["street"]
               case "preflop"
                  put "flop" into tStateA["street"]
                  break
               case "flop"
                  put "turn" into tStateA["street"]
                  break
               case "turn"
                  put "river" into tStateA["street"]
                  break
            end switch
            if tStateA["street"] is "river" then
               put "showdown" into tStateA["phase"]
               put "showdown" & return after tStateA["note"]
            end if
         end if
         return tStateA

      case "act"
         break

      default
         put "unknown-message:" & pMsgType into tStateA["err"]
         return tStateA
   end switch

   -- act messages: pAmount item 1 is the verb, item 2 the amount
   put item 1 of pAmount into tVerb
   put item 2 of pAmount into tAmt
   if tAmt is empty then
      put 0 into tAmt
   end if
   if tStateA["phase"] is not "acting" then
      put "act-out-of-phase" into tStateA["err"]
      return tStateA
   end if
   if pSeatNum is not tStateA["toAct"] then
      put "act-out-of-turn" into tStateA["err"]
      return tStateA
   end if

   switch tVerb

      case "fold"
         put "true" into tStateA["foldedBy"][pSeatNum]
         put "true" into tStateA["actedBy"][pSeatNum]
         if heCountItems(heBetInHandList(tStateA)) is 1 then
            put "handdone" into tStateA["phase"]
            put 0 into tStateA["toAct"]
            put "foldwin:" & heBetInHandList(tStateA) & return after tStateA["note"]
            return tStateA
         end if
         return heBetAfterAction(tStateA, pSeatNum)

      case "check"
         if tStateA["streetBy"][pSeatNum] < tStateA["betCur"] then
            put "check-facing-bet" into tStateA["err"]
            return tStateA
         end if
         put "true" into tStateA["actedBy"][pSeatNum]
         return heBetAfterAction(tStateA, pSeatNum)

      case "call"
         put tStateA["betCur"] - tStateA["streetBy"][pSeatNum] into tOwe
         if tOwe <= 0 then
            put "call-nothing-to-call" into tStateA["err"]
            return tStateA
         end if
         put min(tOwe, tStateA["stackBy"][pSeatNum]) into tPay
         if tAmt is not tPay then
            put "call-wrong-amount" into tStateA["err"]
            return tStateA
         end if
         put heBetPay(tStateA, pSeatNum, tPay) into tStateA
         put "true" into tStateA["actedBy"][pSeatNum]
         return heBetAfterAction(tStateA, pSeatNum)

      case "bet"
      case "raise"
      case "allin"
         -- unified aggressive path; "allin" resolves its own target
         if tVerb is "allin" then
            put tStateA["streetBy"][pSeatNum] + tStateA["stackBy"][pSeatNum] into tTargetAmt
            if tAmt is not tTargetAmt then
               put "allin-wrong-amount" into tStateA["err"]
               return tStateA
            end if
            if tTargetAmt <= tStateA["betCur"] then
               -- an all-in that cannot even match the bet is a call for less
               put heBetPay(tStateA, pSeatNum, tStateA["stackBy"][pSeatNum]) into tStateA
               put "true" into tStateA["actedBy"][pSeatNum]
               return heBetAfterAction(tStateA, pSeatNum)
            end if
         else
            put tAmt into tTargetAmt
            if tVerb is "bet" and tStateA["betCur"] > 0 then
               put "bet-facing-bet-use-raise" into tStateA["err"]
               return tStateA
            end if
            if tVerb is "raise" and tStateA["betCur"] is 0 then
               put "raise-nothing-to-raise-use-bet" into tStateA["err"]
               return tStateA
            end if
         end if
         if tTargetAmt <= tStateA["betCur"] then
            put "raise-not-above-bet" into tStateA["err"]
            return tStateA
         end if
         put tTargetAmt - tStateA["streetBy"][pSeatNum] into tPay
         if tPay > tStateA["stackBy"][pSeatNum] then
            put "raise-beyond-stack" into tStateA["err"]
            return tStateA
         end if
         put tPay is tStateA["stackBy"][pSeatNum] into tIsAllin
         put tTargetAmt - tStateA["betCur"] into tIncrement
         if tIncrement < tStateA["raiseFull"] and not tIsAllin then
            put "raise-below-minimum" into tStateA["err"]
            return tStateA
         end if
         if tStateA["actedBy"][pSeatNum] is "true" then
            -- betting was never reopened for this seat (an under-raise
            -- all-in happened since it acted): it may only call or fold
            put "raise-not-reopened" into tStateA["err"]
            return tStateA
         end if
         put heBetPay(tStateA, pSeatNum, tPay) into tStateA
         put tTargetAmt into tStateA["betCur"]
         put pSeatNum into tStateA["aggressor"]
         put "true" into tStateA["actedBy"][pSeatNum]
         if tIncrement >= tStateA["raiseFull"] then
            -- a FULL raise reopens action for everyone else
            put tIncrement into tStateA["raiseFull"]
            repeat for each item tSeatNum in tStateA["occ"]
               if tSeatNum is not pSeatNum then
                  put "false" into tStateA["actedBy"][tSeatNum]
               end if
            end repeat
         end if
         return heBetAfterAction(tStateA, pSeatNum)

      default
         put "unknown-verb:" & tVerb into tStateA["err"]
         return tStateA
   end switch
end heBetApply

function heBetLegal pStateA, pSeatNum
   -- for the UI: one action per line -- "fold", "check", "call N",
   -- "bet MIN MAX", "raise MINTO MAXTO", "allin N"
   local tOut, tOwe, tMinTo, tMaxTo
   put empty into tOut
   if pStateA["phase"] is not "acting" or pStateA["toAct"] is not pSeatNum then
      return tOut
   end if
   put pStateA["betCur"] - pStateA["streetBy"][pSeatNum] into tOwe
   put "fold" & return after tOut
   if tOwe <= 0 then
      put "check" & return after tOut
   else
      put "call " & min(tOwe, pStateA["stackBy"][pSeatNum]) & return after tOut
   end if
   put pStateA["streetBy"][pSeatNum] + pStateA["stackBy"][pSeatNum] into tMaxTo
   if pStateA["actedBy"][pSeatNum] is "false" and tMaxTo > pStateA["betCur"] then
      put min(pStateA["betCur"] + pStateA["raiseFull"], tMaxTo) into tMinTo
      if pStateA["betCur"] is 0 then
         put "bet " & tMinTo && tMaxTo & return after tOut
      else
         put "raise " & tMinTo && tMaxTo & return after tOut
      end if
   end if
   -- a shove above the bet is a raise: only legal if betting is (re)open
   -- for this seat; a shove at or under the bet is just a call for less
   if pStateA["actedBy"][pSeatNum] is "false" or tMaxTo <= pStateA["betCur"] then
      put "allin " & tMaxTo & return after tOut
   end if
   delete char -1 of tOut
   return tOut
end heBetLegal

function heShowdownOrderOf pStateA
   -- last aggressor of the final street first, then clockwise (spec 8.1)
   local tOut, tSeatNum, tOrder, tFirstSeat
   set the itemDelimiter to comma
   put pStateA["sdFirst"] into tFirstSeat
   if tFirstSeat is 0 or pStateA["foldedBy"][tFirstSeat] is "true" then
      put heBetFirstInHandAfter(pStateA, pStateA["buttonSeat"]) into tFirstSeat
   end if
   put tFirstSeat & comma & heRotateAfter(pStateA["occ"], tFirstSeat) into tOrder
   put empty into tOut
   repeat for each item tSeatNum in tOrder
      if pStateA["foldedBy"][tSeatNum] is "false" and tSeatNum is not among the items of tOut then
         put tSeatNum & comma after tOut
      end if
   end repeat
   delete char -1 of tOut
   return tOut
end heShowdownOrderOf

--------------------------------------------------------------------------
-- settlement (spec 8.3) -- deltas are a pure function of the transcript.
-- Layered side pots: each distinct all-in level is its own pot, awarded
-- independently; the odd chip goes to the first winner clockwise from the
-- button (pinned in tools/betting-kat.py).
--------------------------------------------------------------------------

function heSettleOf pStateA, pRanksA
   local tDeltasA, tSeatNum, tLevelsList, tLevelVal, tPrevLevel, tLayerAmt
   local tEligibleList, tBestRank, tWinnersList, tShare, tRemainder, tOrder
   local tContrib, tWinCount, tNoteTxt
   set the itemDelimiter to comma
   put empty into tNoteTxt
   repeat for each item tSeatNum in pStateA["occ"]
      put 0 into tDeltasA[tSeatNum]
      subtract pStateA["handBy"][tSeatNum] from tDeltasA[tSeatNum]
   end repeat

   -- distinct positive commitment levels, ascending
   put empty into tLevelsList
   repeat for each item tSeatNum in pStateA["occ"]
      if pStateA["handBy"][tSeatNum] > 0 and pStateA["handBy"][tSeatNum] is not among the items of tLevelsList then
         put pStateA["handBy"][tSeatNum] & comma after tLevelsList
      end if
   end repeat
   delete char -1 of tLevelsList
   sort items of tLevelsList numeric ascending

   put 0 into tPrevLevel
   repeat for each item tLevelVal in tLevelsList
      -- the layer pot: every seat contributes its slice of this level
      put 0 into tLayerAmt
      repeat for each item tSeatNum in pStateA["occ"]
         put min(pStateA["handBy"][tSeatNum], tLevelVal) - tPrevLevel into tContrib
         if tContrib > 0 then
            add tContrib to tLayerAmt
         end if
      end repeat
      -- eligible: unfolded seats fully covering this level
      put empty into tEligibleList
      repeat for each item tSeatNum in pStateA["occ"]
         if pStateA["foldedBy"][tSeatNum] is "false" and pStateA["handBy"][tSeatNum] >= tLevelVal then
            put tSeatNum & comma after tEligibleList
         end if
      end repeat
      delete char -1 of tEligibleList
      if tEligibleList is empty then
         repeat for each item tSeatNum in pStateA["occ"]
            put min(pStateA["handBy"][tSeatNum], tLevelVal) - tPrevLevel into tContrib
            if tContrib > 0 then
               add tContrib to tDeltasA[tSeatNum]
            end if
         end repeat
         put tLevelVal into tPrevLevel
         next repeat
      end if
      -- winners: best rank among the eligible
      put empty into tBestRank
      repeat for each item tSeatNum in tEligibleList
         if tBestRank is empty or pRanksA[tSeatNum] > tBestRank then
            put pRanksA[tSeatNum] into tBestRank
         end if
      end repeat
      put empty into tWinnersList
      repeat for each item tSeatNum in tEligibleList
         if pRanksA[tSeatNum] is tBestRank or heCountItems(tEligibleList) is 1 then
            put tSeatNum & comma after tWinnersList
         end if
      end repeat
      delete char -1 of tWinnersList
      put heCountItems(tWinnersList) into tWinCount
      put tLayerAmt div tWinCount into tShare
      put tLayerAmt mod tWinCount into tRemainder
      repeat for each item tSeatNum in tWinnersList
         add tShare to tDeltasA[tSeatNum]
      end repeat
      -- odd chips: first winner(s) clockwise from the button
      put heRotateAfter(pStateA["occ"], pStateA["buttonSeat"]) into tOrder
      repeat for each item tSeatNum in tOrder
         if tRemainder is 0 then
            exit repeat
         end if
         if tSeatNum is among the items of tWinnersList then
            add 1 to tDeltasA[tSeatNum]
            subtract 1 from tRemainder
         end if
      end repeat
      put "pot " & tLayerAmt & " to " & tWinnersList & return after tNoteTxt
      put tLevelVal into tPrevLevel
   end repeat
   put tNoteTxt into tDeltasA["note"]
   return tDeltasA
end heSettleOf

--------------------------------------------------------------------------
-- transcript -- plain-text bodies, no hashing/hex/binary. Hotseat actions
-- are appended to a local log and folded, exactly as network messages will
-- be (the Phase 2 seam). The signed canonical envelope is a Phase 2 item
-- (its bytes are specced + KAT-pinned in tools/protocol-kat.py).
--------------------------------------------------------------------------

function heLogLine pHandNum, pFromTxt, pTypeTxt, pBodyTxt
   -- tab-delimited; body is plain text (never contains a tab)
   return pHandNum & tab & pFromTxt & tab & pTypeTxt & tab & pBodyTxt
end heLogLine

function heLogField pLine, pIdx
   local tSaved, tOut
   put the itemDelimiter into tSaved
   set the itemDelimiter to tab
   put item pIdx of pLine into tOut
   set the itemDelimiter to tSaved
   return tOut
end heLogField

command heLogAppend pTypeTxt, pFromTxt, pBodyTxt
   put heLogLine(gGame["handNum"], pFromTxt, pTypeTxt, pBodyTxt) & return after gGame["log"]
end heLogAppend

function heLogIsCleanHotseat pLogTxt
   -- true iff pLogTxt begins with a 4-field hotseat line whose type is "cfg" (not
   -- an online WIRE envelope, and not empty). The online lobby and the hotseat game
   -- share gGame["log"] but in two incompatible formats: a hotseat line is
   -- handNum TAB from TAB type TAB body (4 tab fields), while an online wire is a
   -- 10-field signed envelope whose 3rd field is the hand number, NOT the type. A
   -- hotseat History fold reads field 3 as the type and needs a hotseat "cfg" line
   -- (which carries sb/bb/ante AND per-seat stacks) to seed heBetNewHand. So when
   -- heTableCreate/heTableJoin has clobbered the log with a wire cfg (which carries
   -- no stacks), leaving the lobby to hotseat must start a fresh hotseat table.
   -- Pure (takes the log as a parameter) so it can be pinned in the harness.
   local tFirst, tSaved
   put line 1 of pLogTxt into tFirst
   if tFirst is empty then
      return false
   end if
   put the itemDelimiter into tSaved
   set the itemDelimiter to tab
   if the number of items of tFirst is 4 and item 3 of tFirst is "cfg" then
      set the itemDelimiter to tSaved
      return true
   end if
   set the itemDelimiter to tSaved
   return false
end heLogIsCleanHotseat

function heFoldTranscript pLogTxt
   -- pure fold: replay a transcript and RE-DERIVE everything (engine state,
   -- showdown ranks, settlements); logged settle lines are verified against
   -- the recomputation, so replay is also an audit. Returns "stacksBy"
   -- (array), "handNum", "trace" (per-hand deltas lines), "errors" (lines).
   local tOutA, tLogLine, tType, tBodyTxt, tBodyA, tStateA, tHaveHand
   local tSeatNum, tHolesA, tBoardList, tRanksA, tDeltasA, tDeltasTxt
   local tSevenList, tOccList, tButtonSeat, tSB, tBB, tAnte, tFromTxt, tStacksTxt
   local tPos, tCardTxt, tOneCard
   local tHistLine, tBoardNames, tPotTotal, tWinnersTxt, tShownTxt, tHolePair, tAuditPart
   set the itemDelimiter to comma
   put 0 into tOutA["handNum"]
   put empty into tOutA["trace"]
   put empty into tOutA["errors"]
   put empty into tOutA["history"]
   put "false" into tHaveHand
   put empty into tBoardList

   repeat for each line tLogLine in pLogTxt
      if tLogLine is empty then
         next repeat
      end if
      put heLogField(tLogLine, 3) into tType
      put heLogField(tLogLine, 4) into tBodyTxt
      set the itemDelimiter to comma

      switch tType

         case "cfg"
            put tBodyTxt into tBodyA
            split tBodyA by comma and "="
            put tBodyA["sb"] into tSB
            put tBodyA["bb"] into tBB
            put tBodyA["ante"] into tAnte    -- absent in pre-ante transcripts
            if tAnte is empty then
               put 0 into tAnte
            end if
            put tBodyA["seats"] into tOccList
            replace "|" with comma in tOccList
            put tBodyA["button"] into tButtonSeat
            put tBodyA["stacks"] into tStacksTxt
            replace "|" with comma in tStacksTxt
            put 0 into tPos
            repeat for each item tSeatNum in tOccList
               add 1 to tPos
               put item tPos of tStacksTxt into tOutA["stacksBy"][tSeatNum]
            end repeat
            break

         case "level"
            -- tournament level change: subsequent hands use these stakes/ante
            put tBodyTxt into tBodyA
            split tBodyA by comma and "="
            put tBodyA["sb"] into tSB
            put tBodyA["bb"] into tBB
            put tBodyA["ante"] into tAnte
            if tAnte is empty then
               put 0 into tAnte
            end if
            break

         case "handStart"
            put tBodyTxt into tBodyA
            split tBodyA by comma and "="
            put tBodyA["seats"] into tOccList
            replace "|" with comma in tOccList
            put tBodyA["button"] into tButtonSeat
            put heBetNewHand(tSB, tBB, tAnte, tOutA["stacksBy"], tOccList, tButtonSeat) into tStateA
            put "true" into tHaveHand
            put empty into tHolesA
            put empty into tBoardList
            put empty into tRanksA
            put heLogField(tLogLine, 1) into tOutA["handNum"]
            break

         case "holeDeliver"
            put tBodyTxt into tBodyA
            split tBodyA by comma and "="
            put tBodyA["cards"] into tCardTxt
            replace "|" with comma in tCardTxt
            put heCardIndex(item 1 of tCardTxt) & comma & heCardIndex(item 2 of tCardTxt) \
                  into tHolesA[tBodyA["seat"]]
            break

         case "board"
            put tBodyTxt into tBodyA
            split tBodyA by comma and "="
            put tBodyA["cards"] into tCardTxt
            replace "|" with comma in tCardTxt
            repeat for each item tOneCard in tCardTxt
               if tBoardList is empty then
                  put heCardIndex(tOneCard) into tBoardList
               else
                  put tBoardList & comma & heCardIndex(tOneCard) into tBoardList
               end if
            end repeat
            put heBetApply(tStateA, "board", 0, 0) into tStateA
            break

         case "bidAnte"
         case "bidSB"
         case "bidBB"
         case "act"
            if tHaveHand is not "true" then
               put "action-before-hand" & return after tOutA["errors"]
               next repeat
            end if
            put tBodyTxt into tBodyA
            split tBodyA by comma and "="
            put heLogField(tLogLine, 2) into tFromTxt
            put char 5 to -1 of tFromTxt into tSeatNum
            if tType is "act" then
               put heBetApply(tStateA, "act", tSeatNum, tBodyA["verb"] & comma & tBodyA["amount"]) into tStateA
            else
               put heBetApply(tStateA, tType, tSeatNum, tBodyA["amount"]) into tStateA
            end if
            if tStateA["err"] is not empty then
               put "engine-rejected:" & tStateA["err"] & return after tOutA["errors"]
            end if
            break

         case "settle"
            put tBodyTxt into tBodyA
            split tBodyA by comma and "="
            put empty into tRanksA
            if heCountItems(heBetInHandList(tStateA)) > 1 then
               repeat for each item tSeatNum in heBetInHandList(tStateA)
                  put tHolesA[tSeatNum] & comma & tBoardList into tSevenList
                  put heEval7(tSevenList) into tRanksA[tSeatNum]
               end repeat
            end if
            put heSettleOf(tStateA, tRanksA) into tDeltasA
            put empty into tDeltasTxt
            repeat for each item tSeatNum in tStateA["occ"]
               put tSeatNum & ":" & tDeltasA[tSeatNum] & "|" after tDeltasTxt
            end repeat
            delete char -1 of tDeltasTxt
            if tBodyA["deltas"] is not tDeltasTxt then
               put "settle-mismatch-hand-" & heLogField(tLogLine, 1) & ":logged=" & tBodyA["deltas"] \
                     & ":computed=" & tDeltasTxt & return after tOutA["errors"]
            end if
            repeat for each item tSeatNum in tStateA["occ"]
               add tDeltasA[tSeatNum] to tOutA["stacksBy"][tSeatNum]
            end repeat
            put "hand " & heLogField(tLogLine, 1) & ": " & tDeltasTxt & return after tOutA["trace"]
            -- auditable hand-history line, folded from the transcript (which IS
            -- the record). "settle-verified" means the logged payout equalled the
            -- independent recomputation on this replay -- the audit, per hand.
            put empty into tBoardNames
            repeat for each item tOneCard in tBoardList
               put heCardName(tOneCard) & comma after tBoardNames
            end repeat
            if tBoardNames is not empty then
               delete char -1 of tBoardNames        -- trailing comma
               replace comma with space in tBoardNames
            end if
            put 0 into tPotTotal
            put empty into tWinnersTxt
            put empty into tShownTxt
            repeat for each item tSeatNum in tStateA["occ"]
               add tStateA["handBy"][tSeatNum] to tPotTotal
               if tDeltasA[tSeatNum] > 0 then
                  put tSeatNum & comma after tWinnersTxt
               end if
               if tRanksA[tSeatNum] is not empty then
                  put tHolesA[tSeatNum] into tHolePair
                  put tSeatNum & "=" & heCardName(item 1 of tHolePair) && heCardName(item 2 of tHolePair) \
                        && heHandLabel(tRanksA[tSeatNum]) & ", " after tShownTxt
               end if
            end repeat
            if tWinnersTxt is not empty then
               delete char -1 of tWinnersTxt
            end if
            if tShownTxt is not empty then
               delete char -1 of tShownTxt           -- trailing space, then...
               delete char -1 of tShownTxt           -- ...trailing comma (two proven deletes)
            end if
            put "hand " & heLogField(tLogLine, 1) & ": board " & tBoardNames \
                  & "; pot " & tPotTotal & "; winner seat " & tWinnersTxt into tHistLine
            if tShownTxt is not empty then
               put "; showdown " & tShownTxt after tHistLine
            end if
            put "; deltas " & tDeltasTxt into tAuditPart
            if tBodyA["deltas"] is tDeltasTxt then
               put tAuditPart & "; settle-verified" after tHistLine
            else
               put tAuditPart & "; settle-MISMATCH" after tHistLine
            end if
            put tHistLine & return after tOutA["history"]
            put "false" into tHaveHand
            break

         case "chat"
            break

      end switch
   end repeat
   return tOutA
end heFoldTranscript

--------------------------------------------------------------------------
-- hotseat shell -- the impure layer: owns gGame, appends to the log through
-- the engine (only accepted messages are logged), reacts to notes
--------------------------------------------------------------------------

command heCfgDefaults
   -- seed the persistent table configuration. Called once at openStack and any
   -- time gCfg is found empty; the settings panel (heApplyCfg) overwrites keys.
   put kHeDefaultStack into gCfg["startStack"]
   put kHeDefaultSB into gCfg["sb"]
   put kHeDefaultBB into gCfg["bb"]
   put kHeDefaultAnte into gCfg["ante"]
   put kHeDefaultSeats into gCfg["numSeats"]
   put "off" into gCfg["levelMode"]        -- "off" (cash) | "hands" | "time"
   put kHeDefaultLevels into gCfg["levels"]
   put kHeDefaultLevelEvery into gCfg["levelEvery"]      -- hands per level (hands mode)
   put kHeDefaultLevelMinutes into gCfg["levelMinutes"]  -- minutes per level (time mode)
   put "normal" into gCfg["speed"]          -- "fast" | "normal" | "slow"
end heCfgDefaults

command heCfgEnsure
   -- lazily fill gCfg so any entry point (a stale paste, a test) has a config
   if gCfg["numSeats"] is empty then
      heCfgDefaults
   end if
end heCfgEnsure

function heSpeedMult pSpeed
   -- fast deals in half the time, slow stretches the beats out
   switch pSpeed
      case "fast"
         return 0.5
      case "slow"
         return 1.6
   end switch
   return 1.0
end heSpeedMult

command heSpeedPace pSpeed
   -- scale the NORMAL-speed pacing constants into the live gGame["pace*"] values
   -- the schedule handlers read. trunc keeps them whole milliseconds.
   local tM
   put heSpeedMult(pSpeed) into tM
   put trunc(kHeNextHandDelayMs * tM) into gGame["paceNextHand"]
   put trunc(kHeStreetRevealMs * tM) into gGame["paceReveal"]
   put trunc(kHeRunoutStepMs * tM) into gGame["paceRunout"]
   put trunc(kHeShowdownHoldMs * tM) into gGame["paceShowdown"]
   put trunc(kHeFoldHoldMs * tM) into gGame["paceFold"]
end heSpeedPace

command heTableNew
   local tSeatNum, tErr
   heCfgEnsure
   put empty into gGame
   put gCfg["sb"] into gGame["sb"]
   put gCfg["bb"] into gGame["bb"]
   put gCfg["ante"] into gGame["ante"]
   put gCfg["numSeats"] into gGame["numSeats"]
   put gCfg["levelMode"] into gGame["levelMode"]
   put gCfg["levels"] into gGame["levels"]
   put gCfg["levelEvery"] into gGame["levelEvery"]
   put gCfg["levelMinutes"] into gGame["levelMinutes"]
   put gCfg["speed"] into gGame["speed"]
   put 0 into gGame["curLevel"]
   put the milliseconds into gGame["tableStartMs"]   -- clock zero for time-based levels
   heSpeedPace gCfg["speed"]
   put 0 into gGame["handNum"]
   put 0 into gGame["buttonSeat"]
   put 0 into gGame["lastBB"]
   put "idle" into gGame["phase"]
   put empty into gGame["log"]
   -- seat 1..numSeats with the opening stack; unseated spots stay absent from
   -- stacksBy, so heSeatsAlive / the deal / settlement never touch them
   repeat with tSeatNum = 1 to gGame["numSeats"]
      put gCfg["startStack"] into gGame["stacksBy"][tSeatNum]
   end repeat
   put heHexId(16) into gGame["tableId"]
   -- a 32-byte crypto table id (hex) is the domain for the Level 0 committed
   -- deal (spec 7.1). Present only with SodiumXT; its absence makes heHandStart
   -- fall back to the labelled practice PRNG.
   put empty into gGame["tableIdHex"]
   if heHasSodium() then
      try
         put heBin2HexS(sxRandomBytes(32)) into gGame["tableIdHex"]
      catch tErr
         put empty into gGame["tableIdHex"]
      end try
   end if
   heLogAppend "cfg", "table", heCfgBody()
   heHudMark
end heTableNew

command heApplyCfg pStartStack, pSB, pBB, pAnte, pNumSeats, pLevelMode, pLevelEvery, pLevelMinutes, pSpeed
   -- the settings panel calls this with validated values, then heTableNew to
   -- start a fresh table on the new configuration. Kept separate so config
   -- persists across tables (gCfg) independent of live game state (gGame).
   heCfgEnsure
   put pStartStack into gCfg["startStack"]
   put pSB into gCfg["sb"]
   put pBB into gCfg["bb"]
   put pAnte into gCfg["ante"]
   put pNumSeats into gCfg["numSeats"]
   put pLevelMode into gCfg["levelMode"]
   put pLevelEvery into gCfg["levelEvery"]
   put pLevelMinutes into gCfg["levelMinutes"]
   put pSpeed into gCfg["speed"]
end heApplyCfg

function heCfgBody
   -- the table cfg logged to the transcript at create time. key=value pairs, so
   -- new keys (ante, level) are backward-compatible with heFoldTranscript's parse.
   local tSeatsTxt, tStacksTxt, tSeatNum
   put empty into tSeatsTxt
   put empty into tStacksTxt
   repeat with tSeatNum = 1 to gGame["numSeats"]
      put tSeatNum & "|" after tSeatsTxt
      put gGame["stacksBy"][tSeatNum] & "|" after tStacksTxt
   end repeat
   delete char -1 of tSeatsTxt
   delete char -1 of tStacksTxt
   return "sb=" & gGame["sb"] & ",bb=" & gGame["bb"] & ",ante=" & gGame["ante"] \
         & ",seats=" & tSeatsTxt & ",stacks=" & tStacksTxt & ",button=1" \
         & ",levelMode=" & gGame["levelMode"] & ",speed=" & gGame["speed"]
end heCfgBody

function heLevelFor pHandNum, pLevelsTxt, pHandsPerLevel
   -- tournament blind schedule: pLevelsTxt is "sb/bb/ante;sb/bb/ante;...". The
   -- active level advances every pHandsPerLevel hands (1-based) and clamps at the
   -- last level. Returns "sb,bb,ante". Pure -- KAT-pinned in betting-kat.py.
   local tEvery, tIdx
   put pHandsPerLevel into tEvery
   if tEvery < 1 then
      put 1 into tEvery
   end if
   put trunc((pHandNum - 1) / tEvery) + 1 into tIdx
   return heLevelForPeriod(tIdx, pLevelsTxt)
end heLevelFor

function heLevelForPeriod pPeriodIdx, pLevelsTxt
   -- return the "sb,bb,ante" for a 1-based period index, clamped to the last
   -- level. Shared by hand-count and (future) time-based schedules. Saves and
   -- restores the itemDelimiter so it never leaks ";" to the caller (gotcha 5).
   local tSaved, tLevels, tCount, tIdx, tLevel
   put the itemDelimiter into tSaved
   set the itemDelimiter to ";"
   put pLevelsTxt into tLevels
   put the number of items of tLevels into tCount
   if tCount < 1 then
      set the itemDelimiter to tSaved
      return "1,2,0"
   end if
   put pPeriodIdx into tIdx
   if tIdx > tCount then
      put tCount into tIdx
   end if
   if tIdx < 1 then
      put 1 into tIdx
   end if
   put item tIdx of tLevels into tLevel
   set the itemDelimiter to tSaved
   replace "/" with comma in tLevel
   return tLevel
end heLevelForPeriod

function heSeatsAlive
   local tOut, tSeatNum
   put empty into tOut
   repeat with tSeatNum = 1 to gGame["numSeats"]
      if gGame["stacksBy"][tSeatNum] > 0 then
         put tSeatNum & comma after tOut
      end if
   end repeat
   delete char -1 of tOut
   return tOut
end heSeatsAlive

function heLevelCount pLevelsTxt
   -- number of levels in a "sb/bb/ante;..." schedule (saves/restores delimiter)
   local tSaved, tTxt, tN
   put the itemDelimiter into tSaved
   set the itemDelimiter to ";"
   put pLevelsTxt into tTxt
   put the number of items of tTxt into tN
   set the itemDelimiter to tSaved
   return tN
end heLevelCount

command heApplyLevel
   -- set this hand's sb/bb/ante from the tournament schedule when one is active.
   -- The level's PERIOD index comes from hands played (levelMode "hands") or wall-
   -- clock minutes since the table opened (levelMode "time"); "off" holds fixed
   -- stakes. Logs a "level" line only when the index changes (curLevel tracks it).
   local tLvl, tIdx, tEvery, tElapsedMs, tPerMs, tCount
   switch gGame["levelMode"]
      case "hands"
         put gGame["levelEvery"] into tEvery
         if tEvery < 1 then
            put 1 into tEvery
         end if
         put trunc((gGame["handNum"] - 1) / tEvery) + 1 into tIdx
         break
      case "time"
         put gGame["levelMinutes"] into tEvery
         if tEvery < 1 then
            put 1 into tEvery
         end if
         put the milliseconds - gGame["tableStartMs"] into tElapsedMs
         put tEvery * 60000 into tPerMs
         put trunc(tElapsedMs / tPerMs) + 1 into tIdx
         break
      default
         exit heApplyLevel
   end switch
   -- clamp the index to the schedule so curLevel settles at the top (no log spam)
   put heLevelCount(gGame["levels"]) into tCount
   if tCount < 1 then
      exit heApplyLevel
   end if
   if tIdx > tCount then
      put tCount into tIdx
   end if
   if tIdx < 1 then
      put 1 into tIdx
   end if
   put heLevelForPeriod(tIdx, gGame["levels"]) into tLvl
   set the itemDelimiter to comma
   put item 1 of tLvl into gGame["sb"]
   put item 2 of tLvl into gGame["bb"]
   put item 3 of tLvl into gGame["ante"]
   if tIdx is not gGame["curLevel"] then
      put tIdx into gGame["curLevel"]
      heLogAppend "level", "table", "level=" & tIdx & ",sb=" & gGame["sb"] \
            & ",bb=" & gGame["bb"] & ",ante=" & gGame["ante"]
   end if
end heApplyLevel

command heHandStart
   local tOccList, tSeatNum, tDeckList, tDealA, tHolePair, tHoleNames
   local tSeatsTxt, tDealCount, tPos, tTableData, tSeedsA, tCommitsA, tDealErr
   set the itemDelimiter to comma
   -- only start from a settled table: "idle" (fresh/after clear) or "between"
   -- (result shown). Any active or animating phase (hand/reveal/runout/
   -- showdown) means a Deal click or a stale next-hand send must be ignored so
   -- a paced sequence is never interrupted or a hand double-dealt.
   if gGame["phase"] is not "idle" and gGame["phase"] is not "between" then
      exit heHandStart
   end if
   -- a Deal click during the "between" result-pause starts here while the prior
   -- hand's heNextHandTick is still pending; cancel any in-flight paced step so a
   -- stale timer cannot fire into this hand and auto-deal an unrequested one
   -- (deep-dive P1). The HUD/network poll loops are free-running and untouched.
   heCancelPacedSteps
   put heSeatsAlive() into tOccList
   if heCountItems(tOccList) < 2 then
      heUISetStatus "Game over -- one stack left. Starting a fresh table."
      heTableNew
      exit heHandStart
   end if
   add 1 to gGame["handNum"]
   -- tournament option: when a blind schedule is active, THIS hand's sb/bb/ante
   -- come from the level for the hand number (levels rise as hands are played).
   -- Logged only when the level actually changes so the transcript stays terse.
   heApplyLevel
   set the itemDelimiter to comma   -- heApplyLevel parses with ";" (gotcha 5)
   -- dead-button-aware schedule: the big blind advances to the next live seat
   -- each hand, so eliminations never double- or skip-charge a blind
   put heScheduleButton(tOccList, gGame["lastBB"]) into gGame["buttonSeat"]
   put tOccList into gGame["occ"]
   put "hand" into gGame["phase"]

   put tOccList into tSeatsTxt
   replace comma with "|" in tSeatsTxt
   heLogAppend "handStart", "table", "seats=" & tSeatsTxt & ",button=" & gGame["buttonSeat"]

   -- deal the deck. When SodiumXT is present, use the Level 0 COMMITTED
   -- keyed-stream shuffle (spec 7.1): a per-contributor seed is committed, then
   -- revealed, and the deck is a hash of the XOR of the seeds -- so the shuffle is
   -- fixed by the commitments and provably consistent with the revealed seeds on
   -- replay (tamper-evident). The whole crypto path is wrapped in a try, so ANY
   -- failure falls back to the labelled practice PRNG and the playable path can
   -- never break. NOTE seeds are generated LOCALLY here (one node holds them all --
   -- in hotseat, one human): this is the auditable, tamper-evident machinery, NOT
   -- an adversarial unstackability guarantee against a cheating dealer. That needs
   -- independent per-player seeds, each committed before any reveal, and arrives
   -- with online play (spec 7.1).
   put heCountItems(tOccList) into tDealCount
   put "practice" into gGame["dealMode"]
   put empty into gGame["dealSeedsA"]
   put empty into gGame["dealCommitsA"]
   if heHasSodium() and gGame["tableIdHex"] is not empty then
      try
         put heHex2BinD(gGame["tableIdHex"]) into tTableData
         put empty into tSeedsA
         put empty into tCommitsA
         put 0 into tPos
         repeat for each item tSeatNum in tOccList
            add 1 to tPos
            put heBin2HexS(sxRandomBytes(32)) into tSeedsA[tPos]
            put heSeedCommitHex(tSeedsA[tPos]) into tCommitsA[tPos]
         end repeat
         put heLevel0Deck(tTableData, gGame["handNum"], tSeedsA, tDealCount) into tDeckList
         put tSeedsA into gGame["dealSeedsA"]
         put tCommitsA into gGame["dealCommitsA"]
         put "level0" into gGame["dealMode"]
      catch tDealErr
         put "practice" into gGame["dealMode"]
      end try
   end if
   if gGame["dealMode"] is "practice" then
      put heShuffleDeck(heFreshPrngState()) into tDeckList
   end if
   put heDealAssign(tDeckList, tOccList, gGame["buttonSeat"]) into tDealA
   put tDeckList into tDealA["deckList"]
   put tDealCount into tDealA["seatCount"]
   put tDealA into gGame["deal"]

   -- record the deal provenance in the transcript so the deal is auditable on
   -- replay: the binding commit for each contributor, then the reveal. Anyone
   -- with the transcript can re-derive the deck and confirm it was not stacked
   -- (heAuditDealsFromLog / tools/fold-kat.py do exactly this).
   if gGame["dealMode"] is "level0" then
      heLogAppend "dealLevel", "table", "level=0,table=" & gGame["tableIdHex"] & ",count=" & tDealCount
      put 0 into tPos
      repeat for each item tSeatNum in tOccList
         add 1 to tPos
         heLogAppend "seedCommit", "seat" & tSeatNum, "pos=" & tPos & ",commit=" & gGame["dealCommitsA"][tPos]
      end repeat
      put 0 into tPos
      repeat for each item tSeatNum in tOccList
         add 1 to tPos
         heLogAppend "seedReveal", "seat" & tSeatNum, "pos=" & tPos & ",seed=" & gGame["dealSeedsA"][tPos]
      end repeat
   end if

   -- hole delivery (hotseat shows all; Phase 2 seals per seat)
   repeat for each item tSeatNum in tOccList
      put tDealA["holesBy"][tSeatNum] into tHolePair
      put heCardName(item 1 of tHolePair) & "|" & heCardName(item 2 of tHolePair) into tHoleNames
      heLogAppend "holeDeliver", "table", "seat=" & tSeatNum & ",cards=" & tHoleNames
   end repeat

   -- antes (if any) then blinds, all through the engine, then the table is live.
   -- Antes are dead money posted by every seat before the blinds; a bidAnte for
   -- each seat keeps them in the signed transcript so the fold can re-derive the
   -- pot (heFoldTranscript handles bidAnte the same as the engine).
   put heBetNewHand(gGame["sb"], gGame["bb"], gGame["ante"], gGame["stacksBy"], tOccList, gGame["buttonSeat"]) into gGame["state"]
   put gGame["state"]["bbSeat"] into gGame["lastBB"]
   if gGame["ante"] > 0 then
      repeat for each item tSeatNum in tOccList
         heEngineDo "bidAnte", tSeatNum, min(gGame["ante"], gGame["stacksBy"][tSeatNum])
      end repeat
   end if
   -- cap each blind by the seat's POST-ante engine stack, not the pre-ante
   -- bankroll gGame["stacksBy"]: the ante loop above already moved the antes into
   -- gGame["state"]["stackBy"] (via heBetPayDead), and heBetApply validates the
   -- blind against that post-ante stack. Using gGame["stacksBy"] here made a seat
   -- that is short AFTER its ante over-post the blind, so the engine rejected it
   -- with bidSB/bidBB-wrong-amount -- silently dropping the small blind or wedging
   -- the hand in tournament (ante) play (deep-dive P0).
   heEngineDo "bidSB", gGame["state"]["sbSeat"], min(gGame["sb"], gGame["state"]["stackBy"][gGame["state"]["sbSeat"]])
   heEngineDo "bidBB", gGame["state"]["bbSeat"], min(gGame["bb"], gGame["state"]["stackBy"][gGame["state"]["bbSeat"]])
   heUIHandStart
   heHudMark
   heUIPromptToAct
end heHandStart

command heEngineDo pMsgType, pSeatNum, pAmount
   -- one gate for every state transition: apply, then log ONLY if accepted
   local tStateA, tVerb
   put heBetApply(gGame["state"], pMsgType, pSeatNum, pAmount) into tStateA
   if tStateA["err"] is not empty then
      heUISetStatus "Rejected: " & tStateA["err"]
      exit heEngineDo
   end if
   put tStateA into gGame["state"]
   switch pMsgType
      case "bidAnte"
      case "bidSB"
      case "bidBB"
         heLogAppend pMsgType, "seat" & pSeatNum, "amount=" & pAmount
         break
      case "act"
         set the itemDelimiter to comma
         put item 1 of pAmount into tVerb
         heLogAppend "act", "seat" & pSeatNum, "verb=" & tVerb & ",amount=" & item 2 of pAmount
         break
   end switch
   heReactToNotes
end heEngineDo

command heActionDo pSeatNum, pVerb, pAmount
   if gGame["phase"] is not "hand" then
      exit heActionDo
   end if
   heEngineDo "act", pSeatNum, pVerb & comma & pAmount
   heHudMark
   -- only prompt the next actor if the action stayed on the same street; a
   -- street close / runout / showdown handed off to a paced step that will
   -- prompt (or settle) on its own timer, and phase is no longer "hand".
   if gGame["phase"] is "hand" then
      heUIPromptToAct
   end if
end heActionDo

command heReactToNotes
   -- the engine transition is instant; its VISIBLE consequences are paced so a
   -- hand plays out like real dealing instead of flashing to the result. Each
   -- consequence hands off to a timer-driven step and returns; nothing here
   -- deals a card or settles synchronously. A single act produces at most one
   -- of these notes (a street close, a runout, or a showdown), so the first
   -- match wins and we stop.
   local tNoteLine, tNotesTxt
   put gGame["state"]["note"] into tNotesTxt
   repeat for each line tNoteLine in tNotesTxt
      set the itemDelimiter to comma
      switch item 1 of tNoteLine
         case "advance:flop"
            heScheduleReveal "flop"
            exit repeat
         case "advance:turn"
            heScheduleReveal "turn"
            exit repeat
         case "advance:river"
            heScheduleReveal "river"
            exit repeat
         case "runout"
            heScheduleRunout
            exit repeat
         case "showdown"
            heScheduleShowdown
            exit repeat
         default
            if tNoteLine begins with "foldwin:" then
               heScheduleShowdown
               exit repeat
            end if
      end switch
   end repeat
end heReactToNotes

command heCancelPacedSteps
   -- cancel any in-flight paced schedule send (reveal / runout / showdown /
   -- next-hand) so a stale timer from a prior hand can never fire into a later
   -- one. Only these hand-paced steps are swept; the free-running HUD and network
   -- poll loops (heHudTick / heNetPollTick) are deliberately left alone. Called at
   -- the top of heHandStart. (gotcha 5: pendingMessages is comma-delimited
   -- id,time,name,target -- set the delimiter before parsing.)
   local tMsgLine, tName
   set the itemDelimiter to comma
   repeat for each line tMsgLine in the pendingMessages
      put item 3 of tMsgLine into tName
      if tName is "heRevealStep" or tName is "heRunoutStep" \
            or tName is "heSettleStep" or tName is "heNextHandTick" then
         cancel item 1 of tMsgLine
      end if
   end repeat
end heCancelPacedSteps

command heScheduleReveal pStreetName
   -- betting closed and the next street is due: hold a beat with the buttons
   -- inert (the "reveal" phase is non-actionable), then land the board and
   -- reopen the action. gGame["state"] already advanced inside heBetApply;
   -- this only paces the visual reveal.
   put pStreetName into gGame["revealStreet"]
   put "reveal" into gGame["phase"]
   heHudMark
   send "heRevealStep" to me in hePaceMs("paceReveal", kHeStreetRevealMs) milliseconds
end heScheduleReveal

function hePaceMs pKey, pDefaultMs
   -- the speed-scaled beat for a schedule step, defaulting to the normal-speed
   -- constant if a hand somehow starts before heSpeedPace ran
   if gGame[pKey] is a number then
      return gGame[pKey]
   end if
   return pDefaultMs
end hePaceMs

on heRevealStep
   -- guarded against stale sends (playbook: defer world changes, then gate on
   -- our own phase lock so a Deal/new-hand cannot let a late reveal double-fire)
   if gGame["phase"] is not "reveal" then
      exit heRevealStep
   end if
   heDealBoard gGame["revealStreet"]
   put "hand" into gGame["phase"]
   heHudMark
   heUIPromptToAct
end heRevealStep

command heDealBoard pStreetName
   local tDealA, tCardsTxt, tIdxList, tIdx
   set the itemDelimiter to comma
   put gGame["deal"] into tDealA
   switch pStreetName
      case "flop"
         put tDealA["flopList"] into tIdxList
         break
      case "turn"
         put tDealA["turnIx"] into tIdxList
         break
      case "river"
         put tDealA["riverIx"] into tIdxList
         break
   end switch
   put empty into tCardsTxt
   repeat for each item tIdx in tIdxList
      put heCardName(tIdx) & "|" after tCardsTxt
   end repeat
   delete char -1 of tCardsTxt
   heLogAppend "board", "table", "street=" & pStreetName & ",cards=" & tCardsTxt
   heUIShowBoardStreet pStreetName, tIdxList
   heHudMark
end heDealBoard

command heScheduleRunout
   -- no more betting possible (all-in with at most one live better): run the
   -- remaining streets out ONE AT A TIME on a timer so the board comes like a
   -- real all-in, not all at once. heRunoutStep deals a street, advances the
   -- engine, and reschedules itself until the engine reaches showdown.
   put "runout" into gGame["phase"]
   heHudMark
   send "heRunoutStep" to me in hePaceMs("paceRunout", kHeRunoutStepMs) milliseconds
end heScheduleRunout

on heRunoutStep
   local tStateA
   if gGame["phase"] is not "runout" then
      exit heRunoutStep
   end if
   put gGame["state"] into tStateA
   if tStateA["phase"] is not "runout" then
      -- engine has dealt the last street: hold, then settle
      heScheduleShowdown
      exit heRunoutStep
   end if
   switch tStateA["street"]
      case "preflop"
         heDealBoard "flop"
         break
      case "flop"
         heDealBoard "turn"
         break
      case "turn"
         heDealBoard "river"
         break
      default
         heScheduleShowdown
         exit heRunoutStep
   end switch
   -- the board message advances the engine street by street (fold-determinism)
   put heBetApply(gGame["state"], "board", 0, 0) into gGame["state"]
   heHudMark
   send "heRunoutStep" to me in hePaceMs("paceRunout", kHeRunoutStepMs) milliseconds
end heRunoutStep

command heScheduleShowdown
   -- reveal the contested hands (or just hold on a fold-win), then settle after
   -- a beat so the result registers instead of the hand ending abruptly. The
   -- ranks needed by the settlement are stashed for heHandSettle.
   local tStateA, tRanksA, tSeatNum, tSevenList
   local tDealA, tInHandList, tBoardIdxList, tHoldMs
   set the itemDelimiter to comma
   put "showdown" into gGame["phase"]
   put gGame["state"] into tStateA
   put gGame["deal"] into tDealA
   put heBetInHandList(tStateA) into tInHandList
   put tDealA["flopList"] & comma & tDealA["turnIx"] & comma & tDealA["riverIx"] into tBoardIdxList
   put empty into tRanksA
   put hePaceMs("paceFold", kHeFoldHoldMs) into tHoldMs
   if heCountItems(tInHandList) > 1 then
      -- a contested showdown: reveal every shown hand and hold long enough to read it
      repeat for each item tSeatNum in tInHandList
         put tDealA["holesBy"][tSeatNum] & comma & tBoardIdxList into tSevenList
         put heEval7(tSevenList) into tRanksA[tSeatNum]
      end repeat
      heUIShowdownReveal tInHandList, tRanksA
      put hePaceMs("paceShowdown", kHeShowdownHoldMs) into tHoldMs
   end if
   put tRanksA into gGame["showdownRanks"]
   heHudMark
   send "heSettleStep" to me in tHoldMs milliseconds
end heScheduleShowdown

on heSettleStep
   -- guarded against stale sends: only the showdown we set up may settle
   if gGame["phase"] is not "showdown" then
      exit heSettleStep
   end if
   heHandSettle
end heSettleStep

command heHandSettle
   -- settle from the stashed showdown ranks, log the deltas, schedule next hand
   local tStateA, tRanksA, tSeatNum, tDeltasA, tDeltasTxt
   set the itemDelimiter to comma
   put gGame["state"] into tStateA
   put gGame["showdownRanks"] into tRanksA
   put heSettleOf(tStateA, tRanksA) into tDeltasA

   put empty into tDeltasTxt
   repeat for each item tSeatNum in tStateA["occ"]
      put tSeatNum & ":" & tDeltasA[tSeatNum] & "|" after tDeltasTxt
      add tDeltasA[tSeatNum] to gGame["stacksBy"][tSeatNum]
   end repeat
   delete char -1 of tDeltasTxt
   heLogAppend "settle", "table", "deltas=" & tDeltasTxt

   put "between" into gGame["phase"]
   heUISetStatus "Hand " & gGame["handNum"] & " settled: " & tDeltasTxt
   heHudMark
   send "heNextHandTick" to me in hePaceMs("paceNextHand", kHeNextHandDelayMs) milliseconds
end heHandSettle

on heNextHandTick
   -- guarded against stale sends (playbook: defer world changes, then gate)
   if gGame["phase"] is not "between" then
      exit heNextHandTick
   end if
   put "idle" into gGame["phase"]
   heUIClearCards
   heHandStart
end heNextHandTick

--------------------------------------------------------------------------
-- UI: self-building chrome (family pattern). Two modes: "kit" needs Box2Dxt
-- Kit + an atlas path in uHeAtlasPath; "flat" is pure fields and always
-- works. All verified statically; needs an OXT pass.
--------------------------------------------------------------------------

function heHasKit
   if gHasKitChk is empty then
      if there is a stack "box2dxt-kit" then
         put "true" into gHasKitChk
      else
         put "false" into gHasKitChk
      end if
   end if
   return gHasKitChk is "true"
end heHasKit

command heBuildTable
   local tSeatNum, tSpotTxt, tSpotX, tSpotY, tPos, tBetX, tBetY, tName
   set the defaultStack to the short name of this stack
   if there is a graphic "heFelt" and the uHeUIVersion of this stack is kUIVersion then
      exit heBuildTable
   end if
   lock screen
   heWipeChrome
   set the uHeUIVersion of this stack to kUIVersion
   set the backgroundColor of this stack to "26,32,30"

   -- felt: a wooden rim behind, green oval-ish table on top
   create graphic "heFeltRim"
   set the style of graphic "heFeltRim" to "roundrect"
   set the roundRadius of graphic "heFeltRim" to 90
   set the rect of graphic "heFeltRim" to "32,40,992,574"
   set the backgroundColor of graphic "heFeltRim" to kHeFeltRim
   set the opaque of graphic "heFeltRim" to true
   create graphic "heFelt"
   set the style of graphic "heFelt" to "roundrect"
   set the roundRadius of graphic "heFelt" to 80
   set the rect of graphic "heFelt" to kHeFeltRect
   set the backgroundColor of graphic "heFelt" to kHeFeltColor
   set the opaque of graphic "heFelt" to true

   -- header + pot
   create field "heHeader"
   set the rect of field "heHeader" to "40,10,884,38"
   set the lockText of field "heHeader" to true
   set the textAlign of field "heHeader" to "center"
   set the textSize of field "heHeader" to 15
   set the textFont of field "heHeader" to "Helvetica"
   set the textColor of field "heHeader" to kHeGoldColor
   set the borderWidth of field "heHeader" to 0
   set the opaque of field "heHeader" to true
   set the backgroundColor of field "heHeader" to "26,32,30"

   create graphic "hePotChip"
   set the style of graphic "hePotChip" to "oval"
   set the rect of graphic "hePotChip" to "498,236,526,258"
   set the backgroundColor of graphic "hePotChip" to kHeGoldColor
   set the opaque of graphic "hePotChip" to true
   create field "hePot"
   set the rect of field "hePot" to "412,262,612,296"
   set the lockText of field "hePot" to true
   set the textAlign of field "hePot" to "center"
   set the textSize of field "hePot" to 20
   set the textColor of field "hePot" to kHeGoldColor
   set the opaque of field "hePot" to true
   set the backgroundColor of field "hePot" to kHeFeltColor
   set the borderWidth of field "hePot" to 0

   -- board slots
   repeat with tPos = 1 to 5
      heMakeCardSlot "heBoard" & tPos, kHeBoardX0 + (tPos - 1) * kHeBoardDX, kHeBoardY
   end repeat

   -- per-seat: panel, name, stack, badge, state, bet chip+amount, hole cards
   repeat with tSeatNum = 1 to kHeDefaultSeats
      set the itemDelimiter to ";"
      put item tSeatNum of kHeSeatSpots into tSpotTxt
      set the itemDelimiter to comma
      put item 1 of tSpotTxt into tSpotX
      put item 2 of tSpotTxt into tSpotY
      put item tSeatNum of kHeSeatNames into tName

      create graphic ("hePanel" & tSeatNum)
      set the style of graphic ("hePanel" & tSeatNum) to "roundrect"
      set the roundRadius of graphic ("hePanel" & tSeatNum) to 14
      set the rect of graphic ("hePanel" & tSeatNum) to \
            (tSpotX - 76) & comma & (tSpotY - 4) & comma & (tSpotX + 76) & comma & (tSpotY + 54)
      set the backgroundColor of graphic ("hePanel" & tSeatNum) to kHePanelColor
      set the opaque of graphic ("hePanel" & tSeatNum) to true

      heMakeLabel "heSeatName" & tSeatNum, (tSpotX - 72) & comma & (tSpotY - 2) & comma & (tSpotX + 72) & comma & (tSpotY + 22), tName, kHeWhite, 14
      heMakeLabel "heSeatStack" & tSeatNum, (tSpotX - 72) & comma & (tSpotY + 24) & comma & (tSpotX + 72) & comma & (tSpotY + 50), "", kHeGoldColor, 15
      heMakeLabel "heSeatBadge" & tSeatNum, (tSpotX + 20) & comma & (tSpotY - 26) & comma & (tSpotX + 76) & comma & (tSpotY - 6), "", kHeInk, 11
      heMakeLabel "heSeatState" & tSeatNum, (tSpotX - 54) & comma & (tSpotY - 74) & comma & (tSpotX + 54) & comma & (tSpotY - 54), "", kHeGoldColor, 12

      put tSpotX + trunc((512 - tSpotX) * 0.42) into tBetX
      put tSpotY + trunc((300 - tSpotY) * 0.42) into tBetY
      create graphic ("heSeatChip" & tSeatNum)
      set the style of graphic ("heSeatChip" & tSeatNum) to "oval"
      set the rect of graphic ("heSeatChip" & tSeatNum) to \
            (tBetX - 11) & comma & (tBetY - 11) & comma & (tBetX + 11) & comma & (tBetY + 11)
      set the backgroundColor of graphic ("heSeatChip" & tSeatNum) to kHeChipColor
      set the opaque of graphic ("heSeatChip" & tSeatNum) to true
      set the visible of graphic ("heSeatChip" & tSeatNum) to false
      heMakeLabel "heSeatBet" & tSeatNum, (tBetX - 26) & comma & (tBetY + 12) & comma & (tBetX + 26) & comma & (tBetY + 30), "", kHeWhite, 12

      heMakeCardSlot "heHole" & tSeatNum & "a", tSpotX - 28, tSpotY - 40
      heMakeCardSlot "heHole" & tSeatNum & "b", tSpotX + 28, tSpotY - 40
   end repeat

   create field "heDealerDisc"
   set the rect of field "heDealerDisc" to "0,0,26,26"
   set the lockText of field "heDealerDisc" to true
   set the textAlign of field "heDealerDisc" to "center"
   set the textSize of field "heDealerDisc" to 12
   set the textColor of field "heDealerDisc" to kHeInk
   set the backgroundColor of field "heDealerDisc" to kHeWhite
   set the text of field "heDealerDisc" to "D"
   set the visible of field "heDealerDisc" to false

   create field "heStatus"
   set the rect of field "heStatus" to "40,632,984,672"
   set the lockText of field "heStatus" to true
   set the textSize of field "heStatus" to 13
   set the opaque of field "heStatus" to true
   set the backgroundColor of field "heStatus" to "26,32,30"
   set the textColor of field "heStatus" to kHeWhite
   set the borderWidth of field "heStatus" to 0

   heMakeActionButton "heBtnFold", "Fold", 40
   heMakeActionButton "heBtnCheck", "Check", 120
   heMakeActionButton "heBtnCall", "Call", 200
   heMakeActionButton "heBtnBet", "Bet", 280
   heMakeActionButton "heBtnRaise", "Raise", 360
   heMakeActionButton "heBtnAllin", "All-in", 440
   create field "heAmount"
   set the rect of field "heAmount" to "528,596,600,620"
   set the textAlign of field "heAmount" to "center"
   set the text of field "heAmount" to "0"
   heMakeActionButton "heBtnMin", "Min", 608
   heMakeActionButton "heBtnHalf", "1/2 Pot", 688
   heMakeActionButton "heBtnPot", "Pot", 768
   heMakeActionButton "heBtnDeal", "Deal", 848
   heMakeActionButton "heBtnOnline", "Lobby", 928
   create button "heBtnHistory"
   set the rect of button "heBtnHistory" to "892,8,980,36"
   set the label of button "heBtnHistory" to "History"
   create button "heBtnSettings"
   set the rect of button "heBtnSettings" to "792,8,884,36"
   set the label of button "heBtnSettings" to "Settings"

   heBuildLobby
   heBuildHistory
   heBuildSettings
   heKitTryInit
   unlock screen
end heBuildTable

command heBuildLobby
   -- the online lobby overlay: Create/Join a table, watch peers connect over
   -- the DHT, and see every signed presence message verify or drop. Built
   -- hidden; heLobbyShow/heLobbyHide toggle it as one unit. NEEDS AN OXT PASS.
   create graphic "heLobbyBg"
   set the style of graphic "heLobbyBg" to "roundrect"
   set the roundRadius of graphic "heLobbyBg" to 16
   set the rect of graphic "heLobbyBg" to "192,84,832,556"
   set the backgroundColor of graphic "heLobbyBg" to "20,26,24"
   set the borderColor of graphic "heLobbyBg" to kHeGoldColor
   set the borderWidth of graphic "heLobbyBg" to 2
   set the opaque of graphic "heLobbyBg" to true

   heMakeLabel "heLobbyTitle", "212,94,812,124", \
         "holde-em online -- serverless table over the DHT", kHeGoldColor, 16
   create button "heBtnCreate"
   set the rect of button "heBtnCreate" to "232,134,432,170"
   set the label of button "heBtnCreate" to "Create Table"
   create button "heBtnJoin"
   set the rect of button "heBtnJoin" to "592,134,792,170"
   set the label of button "heBtnJoin" to "Join Table"

   heMakeLabel "heJoinLabel", "212,182,812,204", \
         "paste a 64-hex invite code, then Join -- or Create to host", kHeWhite, 11
   create field "heJoinCode"
   set the rect of field "heJoinCode" to "232,208,712,238"
   set the lockText of field "heJoinCode" to false
   set the textSize of field "heJoinCode" to 12
   set the textAlign of field "heJoinCode" to "center"
   create button "heBtnCopyCode"
   set the rect of button "heBtnCopyCode" to "724,206,792,240"
   set the label of button "heBtnCopyCode" to "Copy"

   heMakeLabel "heLobbyId", "212,246,812,270", "", kHeWhite, 12
   heMakeLabel "heLobbyTable", "212,272,812,296", "", kHeGoldColor, 12
   heMakeLabel "heRosterHdr", "212,304,502,326", "Players at this table", kHeWhite, 12
   heMakeLabel "heNetHdr", "522,304,812,326", "Network activity (verify / drop)", kHeWhite, 12

   create field "heLobbyRoster"
   set the rect of field "heLobbyRoster" to "212,328,502,510"
   set the lockText of field "heLobbyRoster" to true
   set the textSize of field "heLobbyRoster" to 12
   set the opaque of field "heLobbyRoster" to true
   set the backgroundColor of field "heLobbyRoster" to "14,18,16"
   set the textColor of field "heLobbyRoster" to kHeWhite
   set the borderWidth of field "heLobbyRoster" to 0

   create field "heLobbyNet"
   set the rect of field "heLobbyNet" to "522,328,812,510"
   set the lockText of field "heLobbyNet" to true
   set the textSize of field "heLobbyNet" to 11
   set the opaque of field "heLobbyNet" to true
   set the backgroundColor of field "heLobbyNet" to "14,18,16"
   set the textColor of field "heLobbyNet" to "150,220,150"
   set the borderWidth of field "heLobbyNet" to 0

   create button "heBtnLeave"
   set the rect of button "heBtnLeave" to "232,516,472,548"
   set the label of button "heBtnLeave" to "Leave (play hotseat)"

   heLobbyHide
end heBuildLobby

command heLobbyShow
   heHistHide
   heSettingsHide
   heLobbySetVisible true
   heLobbyRefresh
end heLobbyShow

command heLobbyHide
   heLobbySetVisible false
end heLobbyHide

command heLobbySetVisible pOn
   -- toggle the whole overlay by concrete type (by-name generic "control"
   -- references are not reliably valid in strict OXT; field/button/graphic are)
   local tFields, tButtons, tNm
   if there is a graphic "heLobbyBg" then
      set the visible of graphic "heLobbyBg" to pOn
   end if
   put "heLobbyTitle,heJoinLabel,heJoinCode,heLobbyId,heLobbyTable," \
         & "heRosterHdr,heNetHdr,heLobbyRoster,heLobbyNet" into tFields
   put "heBtnCreate,heBtnJoin,heBtnCopyCode,heBtnLeave" into tButtons
   set the itemDelimiter to comma
   repeat for each item tNm in tFields
      if there is a field tNm then
         set the visible of field tNm to pOn
      end if
   end repeat
   repeat for each item tNm in tButtons
      if there is a button tNm then
         set the visible of button tNm to pOn
      end if
   end repeat
end heLobbySetVisible

function heLobbyVisible
   if there is a graphic "heLobbyBg" then
      return the visible of graphic "heLobbyBg"
   end if
   return false
end heLobbyVisible

--------------------------------------------------------------------------
-- Settings overlay: the host configures the table (opening chips, blinds,
-- ante, player count, blind schedule, deal speed), then Apply starts a fresh
-- table on the new config. Built hidden; one unit like the lobby/history.
-- All verified statically; needs an OXT pass.
--------------------------------------------------------------------------

command heBuildSettings
   create graphic "heSetBg"
   set the style of graphic "heSetBg" to "roundrect"
   set the roundRadius of graphic "heSetBg" to 16
   set the rect of graphic "heSetBg" to "192,84,832,556"
   set the backgroundColor of graphic "heSetBg" to "20,26,24"
   set the borderColor of graphic "heSetBg" to kHeGoldColor
   set the borderWidth of graphic "heSetBg" to 2
   set the opaque of graphic "heSetBg" to true

   heMakeLabel "heSetTitle", "212,94,812,124", \
         "Table settings -- play the game you want", kHeGoldColor, 16
   heMakeLabel "heSetHint", "212,126,812,148", \
         "the host sets these; Apply starts a fresh table on the new config", kHeWhite, 11

   heMakeSettingRow "heSetStack", "Starting chips", 158
   heMakeSettingRow "heSetSB", "Small blind", 196
   heMakeSettingRow "heSetBB", "Big blind", 234
   heMakeSettingRow "heSetAnte", "Ante (0 for none)", 272
   heMakeSettingRow "heSetSeats", "Players (2-6)", 310

   heMakeLabel "heSetLevelLbl", "232,346,540,374", "Blinds", kHeWhite, 13
   create button "heBtnSetLevel"
   set the rect of button "heBtnSetLevel" to "560,344,792,376"
   set the label of button "heBtnSetLevel" to "Fixed (cash game)"

   -- interval row: meaning follows the blind mode (hands per level / minutes per
   -- level); ignored when blinds are fixed. Its label repaints with the mode.
   heMakeLabel "heSetIntervalLbl", "232,386,540,414", "Raise interval", kHeWhite, 13
   create field "heSetInterval"
   set the rect of field "heSetInterval" to "560,384,792,416"
   set the textAlign of field "heSetInterval" to "center"
   set the textSize of field "heSetInterval" to 14
   set the lockText of field "heSetInterval" to false

   heMakeLabel "heSetSpeedLbl", "232,426,540,454", "Deal speed", kHeWhite, 13
   create button "heBtnSetSpeed"
   set the rect of button "heBtnSetSpeed" to "560,424,792,456"
   set the label of button "heBtnSetSpeed" to "Normal"

   heMakeLabel "heSetLevelInfo", "212,462,812,492", \
         "a rising schedule turns the table into a tournament", kHeGoldColor, 11

   create button "heBtnSetApply"
   set the rect of button "heBtnSetApply" to "232,502,472,540"
   set the label of button "heBtnSetApply" to "Apply & New Table"
   create button "heBtnSetCancel"
   set the rect of button "heBtnSetCancel" to "592,502,792,540"
   set the label of button "heBtnSetCancel" to "Cancel"

   heSettingsHide
end heBuildSettings

command heMakeSettingRow pFieldName, pLabelTxt, pTopY
   heMakeLabel (pFieldName & "Lbl"), "232," & pTopY & ",540," & (pTopY + 28), pLabelTxt, kHeWhite, 13
   create field pFieldName
   set the rect of field pFieldName to "560," & (pTopY - 2) & ",792," & (pTopY + 30)
   set the textAlign of field pFieldName to "center"
   set the textSize of field pFieldName to 14
   set the lockText of field pFieldName to false
end heMakeSettingRow

command heSettingsShow
   heLobbyHide
   heHistHide
   heSettingsSetVisible true
   heSettingsRefresh
end heSettingsShow

command heSettingsHide
   heSettingsSetVisible false
end heSettingsHide

command heSettingsSetVisible pOn
   local tFields, tButtons, tNm
   set the itemDelimiter to comma
   if there is a graphic "heSetBg" then
      set the visible of graphic "heSetBg" to pOn
   end if
   put "heSetTitle,heSetHint,heSetLevelInfo,heSetStackLbl,heSetSBLbl,heSetBBLbl," \
         & "heSetAnteLbl,heSetSeatsLbl,heSetLevelLbl,heSetIntervalLbl,heSetSpeedLbl," \
         & "heSetStack,heSetSB,heSetBB,heSetAnte,heSetSeats,heSetInterval" into tFields
   put "heBtnSetLevel,heBtnSetSpeed,heBtnSetApply,heBtnSetCancel" into tButtons
   repeat for each item tNm in tFields
      if there is a field tNm then
         set the visible of field tNm to pOn
      end if
   end repeat
   repeat for each item tNm in tButtons
      if there is a button tNm then
         set the visible of button tNm to pOn
      end if
   end repeat
end heSettingsSetVisible

function heSettingsVisible
   if there is a graphic "heSetBg" then
      return the visible of graphic "heSetBg"
   end if
   return false
end heSettingsVisible

command heSettingsRefresh
   -- populate the fields/buttons from the persistent config
   heCfgEnsure
   if there is not a field "heSetStack" then
      exit heSettingsRefresh
   end if
   set the text of field "heSetStack" to gCfg["startStack"]
   set the text of field "heSetSB" to gCfg["sb"]
   set the text of field "heSetBB" to gCfg["bb"]
   set the text of field "heSetAnte" to gCfg["ante"]
   set the text of field "heSetSeats" to gCfg["numSeats"]
   set the label of button "heBtnSetLevel" to heSettingsLevelLabel(gCfg["levelMode"])
   set the label of button "heBtnSetSpeed" to heSettingsSpeedLabel(gCfg["speed"])
   heSettingsIntervalRefresh
end heSettingsRefresh

command heSettingsIntervalRefresh
   -- the interval field + its label follow the blind mode
   if there is not a field "heSetInterval" then
      exit heSettingsIntervalRefresh
   end if
   set the text of field "heSetIntervalLbl" to heSettingsIntervalLabel(gCfg["levelMode"])
   if gCfg["levelMode"] is "time" then
      set the text of field "heSetInterval" to gCfg["levelMinutes"]
   else
      set the text of field "heSetInterval" to gCfg["levelEvery"]
   end if
end heSettingsIntervalRefresh

command heSettingsIntervalStash
   -- read the interval field into the gCfg key for the CURRENT mode, so cycling
   -- the mode never discards what the host typed. A bad value is left for Apply
   -- to reject rather than silently overwriting the stored one.
   local tVal
   if there is not a field "heSetInterval" then
      exit heSettingsIntervalStash
   end if
   put word 1 of the text of field "heSetInterval" into tVal
   if not heSettingsNumOk(tVal, 1) then
      exit heSettingsIntervalStash
   end if
   if gCfg["levelMode"] is "time" then
      put tVal into gCfg["levelMinutes"]
   else
      put tVal into gCfg["levelEvery"]
   end if
end heSettingsIntervalStash

function heSettingsLevelLabel pMode
   switch pMode
      case "hands"
         return "Rising, by hands played"
      case "time"
         return "Rising, on a timer"
   end switch
   return "Fixed (cash game)"
end heSettingsLevelLabel

function heSettingsIntervalLabel pMode
   switch pMode
      case "hands"
         return "Hands per level"
      case "time"
         return "Minutes per level"
   end switch
   return "Raise interval (n/a for cash)"
end heSettingsIntervalLabel

function heSettingsSpeedLabel pSpeed
   switch pSpeed
      case "fast"
         return "Fast"
      case "slow"
         return "Slow"
   end switch
   return "Normal"
end heSettingsSpeedLabel

command heSettingsCycle pWhich
   -- advance an enum choice and re-label its button (live on gCfg; number fields
   -- stage until Apply)
   heCfgEnsure
   switch pWhich
      case "level"
         -- off -> by hands -> on a timer -> off. Stash the current interval field
         -- back to the right gCfg key before switching, so cycling never loses it.
         heSettingsIntervalStash
         switch gCfg["levelMode"]
            case "off"
               put "hands" into gCfg["levelMode"]
               break
            case "hands"
               put "time" into gCfg["levelMode"]
               break
            default
               put "off" into gCfg["levelMode"]
         end switch
         set the label of button "heBtnSetLevel" to heSettingsLevelLabel(gCfg["levelMode"])
         heSettingsIntervalRefresh
         break
      case "speed"
         switch gCfg["speed"]
            case "normal"
               put "fast" into gCfg["speed"]
               break
            case "fast"
               put "slow" into gCfg["speed"]
               break
            default
               put "normal" into gCfg["speed"]
         end switch
         set the label of button "heBtnSetSpeed" to heSettingsSpeedLabel(gCfg["speed"])
         break
   end switch
end heSettingsCycle

command heSettingsApply
   -- validate the number fields, commit to the config, then start a fresh table
   local tStack, tSB, tBB, tAnte, tSeats, tInterval
   heSettingsIntervalStash
   put word 1 of the text of field "heSetStack" into tStack
   put word 1 of the text of field "heSetSB" into tSB
   put word 1 of the text of field "heSetBB" into tBB
   put word 1 of the text of field "heSetAnte" into tAnte
   put word 1 of the text of field "heSetSeats" into tSeats
   put word 1 of the text of field "heSetInterval" into tInterval
   if not heSettingsNumOk(tStack, 1) or not heSettingsNumOk(tSB, 0) \
         or not heSettingsNumOk(tBB, 1) or not heSettingsNumOk(tAnte, 0) \
         or not heSettingsNumOk(tSeats, kHeMinSeats) then
      heUISetStatus "Settings: every field must be a whole number (chips>=1, seats>=2)."
      exit heSettingsApply
   end if
   if (gCfg["levelMode"] is "hands" or gCfg["levelMode"] is "time") \
         and not heSettingsNumOk(tInterval, 1) then
      heUISetStatus "Settings: the blind interval must be a whole number of at least 1."
      exit heSettingsApply
   end if
   -- clamp / normalise: BB is at least the SB, seats within the layout
   if tBB < tSB then
      put tSB into tBB
   end if
   if tSeats > kHeMaxSeats then
      put kHeMaxSeats into tSeats
   end if
   if tSeats < kHeMinSeats then
      put kHeMinSeats into tSeats
   end if
   if tAnte >= tStack then
      heUISetStatus "Settings: the ante must be smaller than the starting stack."
      exit heSettingsApply
   end if
   heApplyCfg tStack, tSB, tBB, tAnte, tSeats, gCfg["levelMode"], \
         gCfg["levelEvery"], gCfg["levelMinutes"], gCfg["speed"]
   heSettingsHide
   heTableNew
   heUIClearCards
   heUISetStatus "New table: " & tSeats & " seats, " & tStack & " chips, blinds " \
         & tSB & "/" & tBB & ".  Press Deal."
end heSettingsApply

function heSettingsNumOk pVal, pMin
   -- a whole, non-negative number at least pMin
   if pVal is not a number then
      return false
   end if
   if pVal is not trunc(pVal) then
      return false
   end if
   return pVal >= pMin
end heSettingsNumOk

command heLobbyRefresh
   -- repaint identity, table line, roster, and the recent net activity from
   -- gGame -- called on every handshake and every ingested wire. No-op if the
   -- overlay is not built or not visible.
   local tRoleTxt, tKeyPub, tRoster, tSeatRole, tNet, tNetAll, tCount
   local tMyPub, tTableId
   if not (there is a field "heLobbyRoster") then
      exit heLobbyRefresh
   end if
   if not heLobbyVisible() then
      exit heLobbyRefresh
   end if
   -- copy array elements to plain locals before chunking them (house gotcha H6)
   put gGame["idPubHex"] into tMyPub
   put gGame["tableIdHex"] into tTableId
   -- identity
   if gGame["idFingerprint"] is empty then
      set the text of field "heLobbyId" to "You: identity is generated when you Create or Join."
   else
      set the text of field "heLobbyId" to \
            "You: " & gGame["idFingerprint"] & "   key " & char 1 to 12 of tMyPub
   end if
   -- table / role / online line
   if gGame["online"] is "true" then
      if gGame["isHost"] is "true" then
         put "host" into tRoleTxt
      else
         put "player" into tRoleTxt
      end if
      set the text of field "heLobbyTable" to \
            "Table " & char 1 to 16 of tTableId & "   role " & tRoleTxt & "   -- online --"
   else
      set the text of field "heLobbyTable" to "Not connected. Create a table to host, or Join with a code."
   end if
   -- roster from the admitted set (+ roles); the host key is marked
   put empty into tRoster
   repeat for each key tKeyPub in gGame["admittedA"]
      put gGame["roleByPub"][tKeyPub] into tSeatRole
      if tSeatRole is empty then
         put "player" into tSeatRole
      end if
      if tKeyPub is gGame["idPubHex"] then
         put "* " after tRoster
      else
         put "  " after tRoster
      end if
      put char 1 to 12 of tKeyPub & "   " & tSeatRole & return after tRoster
   end repeat
   if tRoster is empty then
      put "(no one yet)" into tRoster
   end if
   set the text of field "heLobbyRoster" to tRoster
   -- last ~14 lines of network activity, newest at the bottom
   put gGame["netLog"] into tNetAll
   put the number of lines of tNetAll into tCount
   if tCount > 14 then
      put line (tCount - 13) to tCount of tNetAll into tNet
   else
      put tNetAll into tNet
   end if
   set the text of field "heLobbyNet" to tNet
end heLobbyRefresh

command heBuildHistory
   -- the hand-history overlay: the folded, re-verified transcript. Built
   -- hidden; heHistShow/heHistHide toggle it. NEEDS AN OXT PASS.
   create graphic "heHistBg"
   set the style of graphic "heHistBg" to "roundrect"
   set the roundRadius of graphic "heHistBg" to 16
   set the rect of graphic "heHistBg" to "192,84,832,556"
   set the backgroundColor of graphic "heHistBg" to "20,26,24"
   set the borderColor of graphic "heHistBg" to kHeGoldColor
   set the borderWidth of graphic "heHistBg" to 2
   set the opaque of graphic "heHistBg" to true

   heMakeLabel "heHistTitle", "212,94,812,124", \
         "hand history -- replayed from the transcript & re-verified", kHeGoldColor, 15
   heMakeLabel "heHistAudit", "212,128,812,150", "", kHeWhite, 12

   create field "heHistList"
   set the rect of field "heHistList" to "212,158,812,502"
   set the lockText of field "heHistList" to true
   set the textSize of field "heHistList" to 12
   set the opaque of field "heHistList" to true
   set the backgroundColor of field "heHistList" to "14,18,16"
   set the textColor of field "heHistList" to kHeWhite
   set the borderWidth of field "heHistList" to 0

   create button "heBtnHistVerify"
   set the rect of button "heBtnHistVerify" to "212,510,352,544"
   set the label of button "heBtnHistVerify" to "Re-verify"
   create button "heBtnHistExport"
   set the rect of button "heBtnHistExport" to "360,510,540,544"
   set the label of button "heBtnHistExport" to "Copy transcript"
   create button "heBtnHistClose"
   set the rect of button "heBtnHistClose" to "712,510,812,544"
   set the label of button "heBtnHistClose" to "Close"

   heHistHide
end heBuildHistory

command heHistShow
   heLobbyHide
   heSettingsHide
   heHistSetVisible true
   heHistRefresh
end heHistShow

command heHistHide
   heHistSetVisible false
end heHistHide

command heHistSetVisible pOn
   local tFields, tButtons, tNm
   if there is a graphic "heHistBg" then
      set the visible of graphic "heHistBg" to pOn
   end if
   put "heHistTitle,heHistAudit,heHistList" into tFields
   put "heBtnHistVerify,heBtnHistExport,heBtnHistClose" into tButtons
   set the itemDelimiter to comma
   repeat for each item tNm in tFields
      if there is a field tNm then
         set the visible of field tNm to pOn
      end if
   end repeat
   repeat for each item tNm in tButtons
      if there is a button tNm then
         set the visible of button tNm to pOn
      end if
   end repeat
end heHistSetVisible

function heHistVisible
   if there is a graphic "heHistBg" then
      return the visible of graphic "heHistBg"
   end if
   return false
end heHistVisible

command heHistRefresh
   -- fold the current transcript and show the per-hand history plus TWO audits:
   -- the settlement (the fold re-derives every payout and compares it to the
   -- logged one) and, for Level 0 hands, the DEAL (heAuditDealsFromLog
   -- re-derives the committed shuffle from the revealed seeds). An all-verified
   -- transcript is the legitimacy proof.
   local tFold, tHistTxt, tErrs, tAuditTxt, tDealAudit
   if not (there is a field "heHistList") then
      exit heHistRefresh
   end if
   put heFoldTranscript(gGame["log"]) into tFold
   put tFold["history"] into tHistTxt
   put tFold["errors"] into tErrs
   put heAuditDealsFromLog(gGame["log"]) into tDealAudit
   if tHistTxt is empty then
      put "No completed hands yet. Play a hand (Deal), then re-open History." into tHistTxt
   end if
   set the text of field "heHistList" to tHistTxt & return & return \
         & "-- deal audit (commit-reveal shuffle) --" & return & tDealAudit
   if tErrs is empty then
      put "AUDIT PASSED -- every hand's settlement matched the independent replay." into tAuditTxt
      set the textColor of field "heHistAudit" to "150,220,150"
   else
      put "AUDIT FAILED -- " & line 1 of tErrs into tAuditTxt
      set the textColor of field "heHistAudit" to kHeRed
   end if
   set the text of field "heHistAudit" to tAuditTxt
end heHistRefresh

command heMakeLabel pName, pRect, pText, pColor, pSize
   create field pName
   set the rect of field pName to pRect
   set the lockText of field pName to true
   set the textAlign of field pName to "center"
   set the textSize of field pName to pSize
   set the textColor of field pName to pColor
   set the borderWidth of field pName to 0
   set the opaque of field pName to false
   set the text of field pName to pText
end heMakeLabel

command heWipeChrome
   local tPos
   repeat with tPos = the number of controls of card 1 down to 1
      if the short name of control tPos of card 1 begins with "he" then
         delete control tPos of card 1
      end if
   end repeat
end heWipeChrome

command heMakeCardSlot pSlotName, pCenterX, pCenterY
   create field pSlotName
   set the rect of field pSlotName to \
         (pCenterX - kHeCardW div 2) & comma & (pCenterY - kHeCardH div 2) & comma \
         & (pCenterX + kHeCardW div 2) & comma & (pCenterY + kHeCardH div 2)
   set the lockText of field pSlotName to true
   set the textAlign of field pSlotName to "center"
   set the textSize of field pSlotName to 22
   set the textStyle of field pSlotName to "bold"
   set the opaque of field pSlotName to true
   set the backgroundColor of field pSlotName to kHeWhite
   set the borderWidth of field pSlotName to 1
   set the borderColor of field pSlotName to "60,60,60"
   set the visible of field pSlotName to false
   -- remember the centre so heKitTryInit can pool a card sprite over this slot
   put pCenterX & comma & pCenterY into gSlotCenter[pSlotName]
end heMakeCardSlot

function heSuitGlyph pSuitVal
   -- built from codepoints so the source stays ASCII (no glyphs in the file)
   switch pSuitVal
      case 1
         return numToCodepoint(9827)  -- clubs
      case 2
         return numToCodepoint(9830)  -- diamonds
      case 3
         return numToCodepoint(9829)  -- hearts
      case 4
         return numToCodepoint(9824)  -- spades
   end switch
   return "?"
end heSuitGlyph

function heCardFace pIdx
   -- rank + suit glyph, e.g. A + spade; ten shows as "10"
   local tName, tRankCh, tRankTxt
   put heCardName(pIdx) into tName
   put char 1 of tName into tRankCh
   if tRankCh is "T" then
      put "10" into tRankTxt
   else
      put tRankCh into tRankTxt
   end if
   return tRankTxt & heSuitGlyph(heCardSuitVal(pIdx))
end heCardFace

function heKenneyFrame pIdx
   -- map an internal card id (1..52) to its Kenney "Playing Cards Pack" atlas frame
   -- BASE name (no extension), for kit-mode card art. heCardName gives rank+suit
   -- ("As","Ts","7c"); Kenney names frames card<Suit><Rank>: c->Clubs d->Diamonds
   -- h->Hearts s->Spades, ten as "10". So 52 (As) -> "cardSpadesA", Ts -> "cardSpades10".
   -- The vendored atlas (assets/cards/playingCards.xml, CC0) carries the ".png" suffix
   -- on its SubTexture names; whether Box2Dxt keeps or strips it on load is a
   -- per-sheet question (gotcha 24) resolved on the OXT pass. Pinned by tools/atlas-kat.py.
   local tName, tRankCh, tSuitCh, tSuitTxt, tRankTxt
   put heCardName(pIdx) into tName
   put char 1 of tName into tRankCh
   put char 2 of tName into tSuitCh
   switch tSuitCh
      case "c"
         put "Clubs" into tSuitTxt
         break
      case "d"
         put "Diamonds" into tSuitTxt
         break
      case "h"
         put "Hearts" into tSuitTxt
         break
      case "s"
         put "Spades" into tSuitTxt
         break
   end switch
   if tRankCh is "T" then
      put "10" into tRankTxt
   else
      put tRankCh into tRankTxt
   end if
   return "card" & tSuitTxt & tRankTxt
end heKenneyFrame

command heMakeActionButton pBtnName, pLabelTxt, pLeftX
   create button pBtnName
   set the rect of button pBtnName to pLeftX & ",592" & comma & (pLeftX + 76) & ",624"
   set the label of button pBtnName to pLabelTxt
end heMakeActionButton

function heStackFolder
   -- the folder that holds the SAVED stack file, so an assets/ folder sitting next
   -- to the stack is found automatically. Empty when the stack was pasted into the
   -- message box and never saved (there is no file to be relative to) -- then set
   -- uHeAtlasPath/uHeBacksPath by hand, or just save the stack once. LiveCode reports
   -- filenames with "/" separators on every platform, so item 1 to -2 is the folder.
   local tFile
   put the filename of this stack into tFile
   if tFile is empty then
      return ""
   end if
   set the itemDelimiter to "/"
   return item 1 to -2 of tFile
end heStackFolder

function heSwapExt pPath, pNewExt
   -- pPath with its trailing ".<ext>" replaced by pNewExt (e.g. ".xml"), so a .png
   -- atlas path yields its sibling TextureAtlas .xml. Copied to a local before the
   -- chunk (H6). A folder name containing a "." is a rare cosmetic edge, not a crash.
   local tBase
   put pPath into tBase
   set the itemDelimiter to "."
   if the number of items of tBase > 1 then
      delete last item of tBase
   end if
   return tBase & pNewExt
end heSwapExt

command heKitTryInit
   local tIdx, tKitErr, tBacksErr, tPng, tXml, tBackPng, tBackXml, tDir
   local tSlot, tCtr, tSpr, tFrameW
   put "flat" into gUIMode
   put 0 into gAnimBusy
   put empty into gCardSpr
   put empty into gKitSuffix
   if not heHasKit() then
      exit heKitTryInit
   end if
   -- resolve the atlas PNG path. b2kSheetLoadAtlas takes the PNG (its sibling .xml is
   -- the optional 2nd arg). An explicit uHeAtlasPath/uHeBacksPath override wins (a .xml
   -- override is accepted and swapped to .png); otherwise default to assets/cards/ NEXT
   -- TO the saved stack -- so dropping the assets folder beside the stack just works.
   -- A pasted, unsaved stack has no folder, so it stays on the flat cards.
   put the uHeAtlasPath of this stack into tPng
   put the uHeBacksPath of this stack into tBackPng
   put heStackFolder() into tDir
   if tPng is empty and tDir is not empty then
      put tDir & "/assets/cards/playingCards.png" into tPng
   end if
   if tBackPng is empty and tDir is not empty then
      put tDir & "/assets/cards/playingCardBacks.png" into tBackPng
   end if
   if tPng ends with ".xml" then
      put heSwapExt(tPng, ".png") into tPng
   end if
   if tBackPng ends with ".xml" then
      put heSwapExt(tBackPng, ".png") into tBackPng
   end if
   if tPng is empty or there is not a file (tPng) then
      exit heKitTryInit
   end if
   put heSwapExt(tPng, ".xml") into tXml
   put heSwapExt(tBackPng, ".xml") into tBackXml
   try
      start using stack "box2dxt-kit"
      set the itemDelimiter to comma
      -- persist the sheets: cards never change, so a saved stack carries the sliced
      -- art and any teardown reloads it as a no-op (Kit guidance).
      b2kSheetPersist true
      b2kSheetLoadAtlas "heCards", tPng, tXml
      -- Kenney frames are card<Suit><Rank>; some atlas loaders keep the ".png" on the
      -- frame key and some strip it (gotcha 24) -- ask the sheet which it is.
      if b2kSheetHasFrame("heCards", "cardSpadesA.png") then
         put ".png" into gKitSuffix
      else
         put empty into gKitSuffix
      end if
      -- scale the sheet so a Kenney card (140 px wide) displays at the slot width,
      -- then pre-warm every face (a lazy first slice costs ~250 ms mid-hand).
      put item 1 of b2kSheetFrameSize("heCards", "cardSpadesA" & gKitSuffix) into tFrameW
      if tFrameW is not a number or tFrameW is 0 then
         put 140 into tFrameW
      end if
      b2kSheetScale "heCards", kHeCardW / tFrameW
      repeat with tIdx = 1 to 52
         b2kSheetEnsureIcon "heCards", heKenneyFrame(tIdx) & gKitSuffix
      end repeat
      -- pool ONE bodiless sprite over each card slot (pooled at build, never mid-hand);
      -- heUIShowCardIn swaps its frame and shows it. Positioned at the slot centre.
      repeat for each key tSlot in gSlotCenter
         put gSlotCenter[tSlot] into tCtr
         b2kSpriteNew "heCards", heKenneyFrame(1) & gKitSuffix, item 1 of tCtr, item 2 of tCtr
         put the result into tSpr
         b2kSpriteMoveTo tSpr, item 1 of tCtr, item 2 of tCtr
         set the visible of tSpr to false
         put tSpr into gCardSpr[tSlot]
      end repeat
      -- the backs sheet (face-down cards): load + size + pre-warm the chosen back.
      -- Guarded so a missing/failed backs sheet never costs us the loaded faces.
      try
         if tBackPng is not empty and there is a file (tBackPng) then
            b2kSheetLoadAtlas "heCardBacks", tBackPng, tBackXml
            b2kSheetScale "heCardBacks", kHeCardW / tFrameW
            b2kSheetEnsureIcon "heCardBacks", kHeCardBackFrame & gKitSuffix
         end if
      catch tBacksErr
      end try
      put "kit" into gUIMode
   catch tKitErr
      put "flat" into gUIMode
   end try
end heKitTryInit

command heProbeKit
   -- diagnostic (run in the message box): is kit-mode card art wired up? Does LIVE
   -- checks (not the cached heHasKit -- you may have just added the Kit), so it always
   -- reflects the current state. Names the exact gap and what to do about it.
   local tOut, tDir, tPng, tErr, tHasStack, tHandlers
   put "holde-em kit probe  stack v" & kHeVersion & return & return into tOut
   -- 1. is the Kit reachable? Two ways: a loaded stack named "box2dxt-kit" (the normal
   --    install), OR the b2k* handlers already on the message path.
   put (there is a stack "box2dxt-kit") into tHasStack
   put "false" into tHandlers
   -- b2kSheetFrames on an unknown sheet returns 0 (no throw) IF the Kit handlers are
   -- on the message path; if the Kit is absent the call throws "can't find handler".
   try
      get b2kSheetFrames("__he_probe__")
      put "true" into tHandlers
   catch tErr
   end try
   put "stack \"box2dxt-kit\" loaded: " & tHasStack & return after tOut
   put "b2k* handlers on the message path: " & tHandlers & return after tOut
   if tHasStack is false and tHandlers is false then
      put return & "==> The Box2Dxt Kit is NOT loaded. It is a SEPARATE stack named" & return after tOut
      put "    \"box2dxt-kit\" -- open its box2dxt-kit.livecodescript in OXT (File > Open" & return after tOut
      put "    Stack), do not paste it into this script. Then run heKitReload." & return after tOut
      put tOut
      return tOut
   end if
   -- 2. the atlas
   put the uHeAtlasPath of this stack into tPng
   if tPng is empty then
      put heStackFolder() into tDir
      if tDir is empty then
         put "atlas path: this stack is UNSAVED (no folder) and uHeAtlasPath is unset --" & return after tOut
         put "  save the stack to a file with assets/cards next to it, or set uHeAtlasPath." & return after tOut
      else
         put tDir & "/assets/cards/playingCards.png" into tPng
      end if
   end if
   if tPng is not empty then
      if tPng ends with ".xml" then
         put heSwapExt(tPng, ".png") into tPng
      end if
      put "atlas PNG: " & tPng & return after tOut
      put "  file exists: " & (there is a file (tPng)) & return after tOut
   end if
   -- 3. what the last heKitTryInit achieved
   put "current UI mode: " & gUIMode & "   frame suffix: '" & gKitSuffix & "'" & return after tOut
   put "card sprites pooled: " & the number of lines of the keys of gCardSpr & return after tOut
   try
      put "heCards frames loaded: " & b2kSheetFrames("heCards") after tOut
      put "   heCardBacks: " & b2kSheetFrames("heCardBacks") & return after tOut
   catch tErr
      put "sheets: not loaded yet" & return after tOut
   end try
   if gUIMode is not "kit" then
      put return & "==> kit mode is OFF. If the checks above look right, run heKitReload" & return after tOut
      put "    to (re)build the card sprites, then run heProbeKit again." & return after tOut
   else
      put return & "==> kit mode is ON. If cards still look flat, it is a sprite anchor/" & return after tOut
      put "    scale/z-order detail -- send me this probe output and a screenshot." & return after tOut
   end if
   put tOut
   return tOut
end heProbeKit

command heKitReload
   -- force a fresh Kit probe + card-sprite rebuild -- run this in the message box after
   -- loading the Box2Dxt Kit, saving the stack, or moving the assets. Clears the cached
   -- extension probe, removes any pooled sprites, then re-runs heKitTryInit and reports.
   local tSlot, tSpr, tRmErr
   put empty into gHasKitChk
   if gCardSpr is an array then
      repeat for each key tSlot in gCardSpr
         put gCardSpr[tSlot] into tSpr
         try
            b2kSpriteRemove tSpr
         catch tRmErr
         end try
      end repeat
   end if
   put empty into gCardSpr
   heKitTryInit
   heUIClearCards
   put "kit reload done -- UI mode is now: " & gUIMode & \
         "   (run heProbeKit for details)"
end heKitReload

on mouseUp
   local tWho, tSeatNum, tAmt, tCodeTxt
   put the short name of the target into tWho
   -- lobby routing first: these act whether or not the overlay is up
   switch tWho
      case "heBtnOnline"
         heLobbyShow
         exit mouseUp
      case "heBtnCreate"
         heTableCreate
         exit mouseUp
      case "heBtnJoin"
         put word 1 of the text of field "heJoinCode" into tCodeTxt
         heTableJoin tCodeTxt
         exit mouseUp
      case "heBtnCopyCode"
         if gGame["tableIdHex"] is empty then
            heUISetStatus "No table yet -- Create one first."
         else
            set the clipboardData["text"] to gGame["tableIdHex"]
            heUISetStatus "Invite code copied to the clipboard."
         end if
         exit mouseUp
      case "heBtnLeave"
         heNetStop
         -- returning to hotseat: if the transcript was clobbered by an online
         -- create/join (it now leads with a signed WIRE, or was emptied), start a
         -- fresh hotseat table so gGame["log"] carries a real hotseat cfg (with
         -- stakes AND stacks) for the History fold. A clean in-progress hotseat
         -- game (log begins with a 4-field hotseat "cfg") is preserved -- so a
         -- peek at the lobby and back does not wipe a running game. (deep-dive:
         -- the lobby wire log and the hotseat transcript share gGame["log"].)
         if not heLogIsCleanHotseat(gGame["log"]) then
            heTableNew
         end if
         heLobbyHide
         heUISetStatus "Back to hotseat. Press Deal to play, or Lobby to go online."
         exit mouseUp
      case "heBtnHistory"
         heHistShow
         exit mouseUp
      case "heBtnHistVerify"
         heHistRefresh
         exit mouseUp
      case "heBtnHistExport"
         set the clipboardData["text"] to gGame["log"]
         heUISetStatus "Signed transcript copied -- the portable, replayable proof of every hand."
         exit mouseUp
      case "heBtnHistClose"
         heHistHide
         exit mouseUp
      case "heBtnSettings"
         heSettingsShow
         exit mouseUp
      case "heBtnSetLevel"
         heSettingsCycle "level"
         exit mouseUp
      case "heBtnSetSpeed"
         heSettingsCycle "speed"
         exit mouseUp
      case "heBtnSetApply"
         heSettingsApply
         exit mouseUp
      case "heBtnSetCancel"
         heSettingsHide
         exit mouseUp
   end switch
   -- while an overlay is up, the table/action buttons are inert
   if heLobbyVisible() or heHistVisible() or heSettingsVisible() then
      exit mouseUp
   end if
   if tWho is "heBtnDeal" then
      heHandStart
      exit mouseUp
   end if
   if gGame["phase"] is not "hand" then
      exit mouseUp
   end if
   put gGame["state"]["toAct"] into tSeatNum
   if tSeatNum is 0 then
      exit mouseUp
   end if
   -- quick-bet buttons only fill the amount box; the player still commits
   switch tWho
      case "heBtnMin"
         set the text of field "heAmount" to heQuickAmount(tSeatNum, "min")
         exit mouseUp
      case "heBtnHalf"
         set the text of field "heAmount" to heQuickAmount(tSeatNum, "half")
         exit mouseUp
      case "heBtnPot"
         set the text of field "heAmount" to heQuickAmount(tSeatNum, "pot")
         exit mouseUp
   end switch
   put word 1 of the text of field "heAmount" into tAmt
   if tAmt is not a number then
      put 0 into tAmt
   end if
   switch tWho
      case "heBtnFold"
         heActionDo tSeatNum, "fold", 0
         break
      case "heBtnCheck"
         heActionDo tSeatNum, "check", 0
         break
      case "heBtnCall"
         heActionDo tSeatNum, "call", heCallAmountFor(tSeatNum)
         break
      case "heBtnBet"
         heActionDo tSeatNum, "bet", tAmt
         break
      case "heBtnRaise"
         heActionDo tSeatNum, "raise", tAmt
         break
      case "heBtnAllin"
         heActionDo tSeatNum, "allin", \
               gGame["state"]["streetBy"][tSeatNum] + gGame["state"]["stackBy"][tSeatNum]
         break
   end switch
end mouseUp

function heCallAmountFor pSeatNum
   local tOwe
   put gGame["state"]["betCur"] - gGame["state"]["streetBy"][pSeatNum] into tOwe
   return min(tOwe, gGame["state"]["stackBy"][pSeatNum])
end heCallAmountFor

function heQuickAmount pSeatNum, pKind
   -- a convenience "raise to" amount, clamped to [minTo, maxTo]. Pot-sized
   -- uses the pot after this player calls (standard pot-raise definition).
   local tState, tOwe, tPotAfter, tMaxTo, tMinTo, tTo, tSeat
   set the itemDelimiter to comma
   put gGame["state"] into tState
   put tState["betCur"] - tState["streetBy"][pSeatNum] into tOwe
   put 0 into tPotAfter
   repeat for each item tSeat in tState["occ"]
      add tState["handBy"][tSeat] to tPotAfter
   end repeat
   add tOwe to tPotAfter
   put tState["streetBy"][pSeatNum] + tState["stackBy"][pSeatNum] into tMaxTo
   put min(tState["betCur"] + tState["raiseFull"], tMaxTo) into tMinTo
   switch pKind
      case "half"
         put tState["betCur"] + tOwe + (tPotAfter div 2) into tTo
         break
      case "pot"
         put tState["betCur"] + tOwe + tPotAfter into tTo
         break
      default
         put tMinTo into tTo
   end switch
   if tTo < tMinTo then
      put tMinTo into tTo
   end if
   if tTo > tMaxTo then
      put tMaxTo into tTo
   end if
   return tTo
end heQuickAmount

command heUISetStatus pTxt
   if there is a field "heStatus" then
      set the text of field "heStatus" to pTxt
   end if
end heUISetStatus

command heUIPromptToAct
   local tSeatNum, tLegalTxt, tLine, tHasCheck, tHasCall, tHasBet, tHasRaise
   local tHasAllin, tCallAmt, tName
   set the itemDelimiter to comma
   if gGame["phase"] is not "hand" then
      exit heUIPromptToAct
   end if
   put gGame["state"]["toAct"] into tSeatNum
   if tSeatNum is 0 then
      exit heUIPromptToAct
   end if
   put heBetLegal(gGame["state"], tSeatNum) into tLegalTxt
   put false into tHasCheck
   put false into tHasCall
   put false into tHasBet
   put false into tHasRaise
   put false into tHasAllin
   put heCallAmountFor(tSeatNum) into tCallAmt
   repeat for each line tLine in tLegalTxt
      switch word 1 of tLine
         case "check"
            put true into tHasCheck
            break
         case "call"
            put true into tHasCall
            break
         case "bet"
            put true into tHasBet
            break
         case "raise"
            put true into tHasRaise
            break
         case "allin"
            put true into tHasAllin
            break
      end switch
   end repeat
   heEnableBtn "heBtnCheck", tHasCheck
   heEnableBtn "heBtnCall", tHasCall
   heEnableBtn "heBtnBet", tHasBet
   heEnableBtn "heBtnRaise", tHasRaise
   heEnableBtn "heBtnAllin", tHasAllin
   heEnableBtn "heBtnFold", true
   if there is a button "heBtnCall" then
      if tHasCall then
         set the label of button "heBtnCall" to "Call " & tCallAmt
      else
         set the label of button "heBtnCall" to "Call"
      end if
   end if
   -- seed the amount box with the minimum legal bet/raise-to
   if (tHasBet or tHasRaise) and there is a field "heAmount" then
      set the text of field "heAmount" to heQuickAmount(tSeatNum, "min")
   end if
   put item tSeatNum of kHeSeatNames into tName
   heUISetStatus tName & " to act  --  " & toUpper(gGame["state"]["street"]) \
         & ".  Pot " & heCurrentPot() & ".  To call: " & tCallAmt
end heUIPromptToAct

command heEnableBtn pBtnName, pOn
   if there is not a button pBtnName then
      exit heEnableBtn
   end if
   set the disabled of button pBtnName to not pOn
end heEnableBtn

command heDisableActions
   local tBtn
   set the itemDelimiter to comma
   repeat for each item tBtn in "heBtnFold,heBtnCheck,heBtnCall,heBtnBet,heBtnRaise,heBtnAllin,heBtnMin,heBtnHalf,heBtnPot"
      heEnableBtn tBtn, false
   end repeat
   if there is a button "heBtnCall" then
      set the label of button "heBtnCall" to "Call"
   end if
end heDisableActions

function heCurrentPot
   local tSeatNum, tPot
   set the itemDelimiter to comma
   put 0 into tPot
   if gGame["phase"] is "hand" then
      repeat for each item tSeatNum in gGame["state"]["occ"]
         add gGame["state"]["handBy"][tSeatNum] to tPot
      end repeat
   end if
   return tPot
end heCurrentPot

command heHudMark
   put true into gHudDirty
end heHudMark

on heHudTick
   if gHudTickOn is not true then
      exit heHudTick
   end if
   if gHudDirty is true then
      put false into gHudDirty
      heHudRefresh
   end if
   send "heHudTick" to me in kHeHudMs milliseconds
end heHudTick

command heHudRefresh
   local tSeatNum, tPotAmt, tSpotTxt, tSpotX, tSpotY, tHandBy, tInHand, tStreetBy
   local tActing, tSbSeat, tBbSeat, tBadge
   if there is not a field "hePot" then
      exit heHudRefresh
   end if
   set the itemDelimiter to comma
   put heCurrentPot() into tPotAmt
   set the text of field "hePot" to "POT  " & tPotAmt
   set the visible of graphic "hePotChip" to (tPotAmt > 0)
   set the text of field "heHeader" to heHeaderTxt()
   -- Deal is offered only from a settled table; during reveal/runout/showdown
   -- beats it stays inert so a click cannot cut a paced sequence short
   heEnableBtn "heBtnDeal", (gGame["phase"] is "idle" or gGame["phase"] is "between")
   if gGame["phase"] is not "hand" then
      heDisableActions
   end if

   put 0 into tActing
   put 0 into tSbSeat
   put 0 into tBbSeat
   if gGame["phase"] is "hand" then
      put gGame["state"]["toAct"] into tActing
      put gGame["state"]["sbSeat"] into tSbSeat
      put gGame["state"]["bbSeat"] into tBbSeat
   end if

   repeat with tSeatNum = 1 to kHeDefaultSeats
      -- tables smaller than the 6-spot layout hide their unused seats entirely
      if tSeatNum > gGame["numSeats"] then
         heSeatChromeVisible tSeatNum, false
         next repeat
      end if
      heSeatChromeVisible tSeatNum, true
      put heHandByOf(tSeatNum) into tHandBy
      -- chip TOTAL behind (always visible, even between hands)
      if gGame["stacksBy"][tSeatNum] is a number then
         set the text of field ("heSeatStack" & tSeatNum) to \
               (gGame["stacksBy"][tSeatNum] - tHandBy)
      end if
      -- bet in front this street
      put 0 into tStreetBy
      if gGame["phase"] is "hand" and gGame["state"]["streetBy"][tSeatNum] is a number then
         put gGame["state"]["streetBy"][tSeatNum] into tStreetBy
      end if
      if tStreetBy > 0 then
         set the text of field ("heSeatBet" & tSeatNum) to tStreetBy
         set the visible of graphic ("heSeatChip" & tSeatNum) to true
      else
         set the text of field ("heSeatBet" & tSeatNum) to ""
         set the visible of graphic ("heSeatChip" & tSeatNum) to false
      end if
      -- role badge (D / SB / BB), acting highlight, folded / all-in state
      put "" into tBadge
      if tSeatNum is tSbSeat then
         put "SB" into tBadge
      end if
      if tSeatNum is tBbSeat then
         put "BB" into tBadge
      end if
      set the text of field ("heSeatBadge" & tSeatNum) to tBadge
      heSeatFace tSeatNum, (tSeatNum is tActing)
   end repeat

   -- dealer button disc
   if gGame["buttonSeat"] > 0 then
      set the itemDelimiter to ";"
      put item gGame["buttonSeat"] of kHeSeatSpots into tSpotTxt
      set the itemDelimiter to comma
      put item 1 of tSpotTxt into tSpotX
      put item 2 of tSpotTxt into tSpotY
      set the loc of field "heDealerDisc" to (tSpotX - 92) & comma & (tSpotY + 24)
      set the visible of field "heDealerDisc" to true
   else
      set the visible of field "heDealerDisc" to false
   end if
end heHudRefresh

command heSeatChromeVisible pSeatNum, pOn
   -- show or hide a whole seat's persistent chrome, so a table configured for
   -- fewer than the 6 layout spots does not display ghost seats
   local tCtl
   set the itemDelimiter to comma
   if there is a graphic ("hePanel" & pSeatNum) then
      set the visible of graphic ("hePanel" & pSeatNum) to pOn
   end if
   repeat for each item tCtl in "heSeatName,heSeatStack,heSeatBadge,heSeatState,heSeatBet"
      if there is a field (tCtl & pSeatNum) then
         set the visible of field (tCtl & pSeatNum) to pOn
      end if
   end repeat
   if not pOn then
      -- unseated: also drop the bet chip and any hole cards
      if there is a graphic ("heSeatChip" & pSeatNum) then
         set the visible of graphic ("heSeatChip" & pSeatNum) to false
      end if
      if there is a field ("heHole" & pSeatNum & "a") then
         set the visible of field ("heHole" & pSeatNum & "a") to false
         set the visible of field ("heHole" & pSeatNum & "b") to false
      end if
   end if
end heSeatChromeVisible

command heSeatFace pSeatNum, pActing
   -- panel colour + state label: acting (gold), folded (dim), all-in (gold text)
   local tState, tFolded, tAllin
   put "false" into tFolded
   put "false" into tAllin
   if gGame["phase"] is "hand" then
      put gGame["state"] into tState
      put tState["foldedBy"][pSeatNum] into tFolded
      put tState["allinBy"][pSeatNum] into tAllin
   end if
   if pActing then
      set the backgroundColor of graphic ("hePanel" & pSeatNum) to kHePanelActive
   else
      set the backgroundColor of graphic ("hePanel" & pSeatNum) to kHePanelColor
   end if
   if tFolded is "true" then
      set the text of field ("heSeatState" & pSeatNum) to "FOLDED"
      set the textColor of field ("heSeatState" & pSeatNum) to "150,150,150"
   else if tAllin is "true" then
      set the text of field ("heSeatState" & pSeatNum) to "ALL-IN"
      set the textColor of field ("heSeatState" & pSeatNum) to kHeGoldColor
   else
      set the text of field ("heSeatState" & pSeatNum) to ""
   end if
end heSeatFace

function heHeaderTxt
   local tTxt
   put "holde-em " & kHeVersion into tTxt
   if gGame["handNum"] > 0 then
      put "     Hand " & gGame["handNum"] after tTxt
   end if
   if gGame["phase"] is "hand" then
      put "     " & toUpper(gGame["state"]["street"]) after tTxt
   end if
   put "     Blinds " & gGame["sb"] & "/" & gGame["bb"] after tTxt
   if gGame["ante"] > 0 then
      put "     Ante " & gGame["ante"] after tTxt
   end if
   if gGame["levelMode"] is "hands" and gGame["curLevel"] > 0 then
      put "     Level " & gGame["curLevel"] after tTxt
   end if
   return tTxt
end heHeaderTxt

function heHandByOf pSeatNum
   if gGame["phase"] is "hand" and gGame["state"]["handBy"][pSeatNum] is a number then
      return gGame["state"]["handBy"][pSeatNum]
   end if
   return 0
end heHandByOf

command heUIHandStart
   local tSeatNum, tDealA
   heUIClearCards
   put gGame["deal"] into tDealA
   set the itemDelimiter to comma
   repeat for each item tSeatNum in gGame["occ"]
      heUIShowHole tSeatNum, tDealA["holesBy"][tSeatNum]
   end repeat
   heUISetStatus "Hand " & gGame["handNum"] & " dealt -- blinds " & gGame["sb"] & "/" & gGame["bb"] & " posted."
end heUIHandStart

command heUIShowHole pSeatNum, pIdxPair
   local tSlotName, tPair
   set the itemDelimiter to comma
   put pIdxPair into tPair
   put "heHole" & pSeatNum & "a" into tSlotName
   heUIShowCardIn tSlotName, item 1 of tPair
   put "heHole" & pSeatNum & "b" into tSlotName
   heUIShowCardIn tSlotName, item 2 of tPair
end heUIShowHole

command heUIShowCardIn pSlotName, pIdx
   local tSpr, tShowErr
   -- kit mode: swap this slot's pooled sprite to the card's Kenney frame and show it,
   -- hiding the flat field beneath. Guarded so a kit hiccup falls back to the flat
   -- glyph card and never breaks the deal.
   if gUIMode is "kit" and gCardSpr[pSlotName] is not empty then
      try
         put gCardSpr[pSlotName] into tSpr
         b2kSpriteSetFrame tSpr, heKenneyFrame(pIdx) & gKitSuffix
         set the visible of tSpr to true
         if there is a field pSlotName then
            set the visible of field pSlotName to false
         end if
         exit heUIShowCardIn
      catch tShowErr
      end try
   end if
   if there is not a field pSlotName then
      exit heUIShowCardIn
   end if
   set the text of field pSlotName to heCardFace(pIdx)
   if heCardSuitVal(pIdx) is 2 or heCardSuitVal(pIdx) is 3 then
      set the textColor of field pSlotName to kHeRed
   else
      set the textColor of field pSlotName to kHeInk
   end if
   set the backgroundColor of field pSlotName to kHeWhite
   set the visible of field pSlotName to true
end heUIShowCardIn

command heUIShowBoardStreet pStreetName, pIdxList
   local tIdx, tPos
   set the itemDelimiter to comma
   switch pStreetName
      case "flop"
         put 1 into tPos
         break
      case "turn"
         put 4 into tPos
         break
      case "river"
         put 5 into tPos
         break
   end switch
   repeat for each item tIdx in pIdxList
      heUIShowCardIn "heBoard" & tPos, tIdx
      add 1 to tPos
   end repeat
end heUIShowBoardStreet

command heUIShowdownReveal pInHandList, pRanksA
   local tSeatNum, tTxt, tName, tBest, tOrder
   set the itemDelimiter to comma
   put heShowdownOrderOf(gGame["state"]) into tOrder
   -- best rank among those who showed -> winner highlight
   put empty into tBest
   repeat for each item tSeatNum in pInHandList
      if tBest is empty or pRanksA[tSeatNum] > tBest then
         put pRanksA[tSeatNum] into tBest
      end if
   end repeat
   put "Showdown -- " into tTxt
   repeat for each item tSeatNum in tOrder
      put item tSeatNum of kHeSeatNames into tName
      put tName & " (" & heHandLabel(pRanksA[tSeatNum]) & ")   " after tTxt
      if pRanksA[tSeatNum] is tBest and there is a field ("heSeatState" & tSeatNum) then
         set the text of field ("heSeatState" & tSeatNum) to "WINNER"
         set the textColor of field ("heSeatState" & tSeatNum) to kHeGoldColor
      end if
   end repeat
   heUISetStatus tTxt
end heUIShowdownReveal

function heHandLabel pPacked
   -- turn a packed rank into a human category name for the status line
   local tCat
   put char 1 to 2 of pPacked into tCat
   switch tCat
      case "08"
         return "straight flush"
      case "07"
         return "four of a kind"
      case "06"
         return "full house"
      case "05"
         return "flush"
      case "04"
         return "straight"
      case "03"
         return "three of a kind"
      case "02"
         return "two pair"
      case "01"
         return "one pair"
      default
         return "high card"
   end switch
end heHandLabel

command heUIClearCards
   local tSeatNum, tPos, tSlot, tSpr
   -- kit mode: hide every pooled card sprite between hands
   if gUIMode is "kit" then
      repeat for each key tSlot in gCardSpr
         put gCardSpr[tSlot] into tSpr
         set the visible of tSpr to false
      end repeat
   end if
   repeat with tSeatNum = 1 to kHeDefaultSeats
      if there is a field ("heHole" & tSeatNum & "a") then
         set the visible of field ("heHole" & tSeatNum & "a") to false
         set the visible of field ("heHole" & tSeatNum & "b") to false
      end if
      if there is a field ("heSeatState" & tSeatNum) then
         set the text of field ("heSeatState" & tSeatNum) to ""
      end if
      if there is a field ("heSeatBet" & tSeatNum) then
         set the text of field ("heSeatBet" & tSeatNum) to ""
         set the visible of graphic ("heSeatChip" & tSeatNum) to false
      end if
      if there is a field ("heSeatBadge" & tSeatNum) then
         set the text of field ("heSeatBadge" & tSeatNum) to ""
      end if
      if there is a graphic ("hePanel" & tSeatNum) then
         set the backgroundColor of graphic ("hePanel" & tSeatNum) to kHePanelColor
      end if
   end repeat
   repeat with tPos = 1 to 5
      if there is a field ("heBoard" & tPos) then
         set the visible of field ("heBoard" & tPos) to false
      end if
   end repeat
end heUIClearCards

on b2kFrame
   if gAnimBusy > 0 then
      -- reserved: deal-slide / flip chaining bookkeeping (OXT pass)
   end if
end b2kFrame

on b2kSpriteOnFinish pSpriteId
   if gFlipCtxA[pSpriteId] is empty then
      exit b2kSpriteOnFinish
   end if
   put empty into gFlipCtxA[pSpriteId]
end b2kSpriteOnFinish

--------------------------------------------------------------------------
-- self-test harness (folded in -- run heRunSelftest in the message box).
-- Self-diagnosing asserts print what was OBSERVED. kHeHarnessV is in the
-- header; bump it on every engine-behavior change.
--------------------------------------------------------------------------

local gRpt, gPassN, gFailN, gSkipN

constant kKatSeed1Deck = "8h,4d,6s,Qd,2c,2d,6d,7d,Ad,Jd,8d,5c,5d,Ts,Tc,7c,8c,Ac,3c,Js,6c,Ah,9d,Jh,2h,As,9s,Kc,8s,4c,Qc,5h,Th,7s,2s,Kh,5s,Qh,9c,4s,Jc,3d,Kd,9h,3s,Qs,3h,Td,Ks,7h,6h,4h"

-- Phase 2 crypto KAT vectors (generated by tools/protocol-kat.py --gen-xtalk;
-- BLAKE2b-256 + ed25519, the corrected SodiumXT calls)
constant kKatHashEmpty = "0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8"
constant kKatTableHex = "e52675650d7ad48c7129185efdaec1e2b89cc410d8e4c8e085bcd652187b27d3"
constant kKatSeed1 = "6c10d2dcff41a1a7e8bd9c7530052c7eb91b91808ee5d935e5f56098539eea3c"
constant kKatSeed2 = "f7badd5dc86a8a5dce0984ef43bcb7ec228398e08a854a8a8c455ff895dc8a49"
constant kKatSeed3 = "e848bf12b0bf2708b52c20053ef674e603e7f3a3c7092533dc92e1b0828960cd"
constant kKatCommit1 = "7623721b5a6372fa974ed62f558fce9992259eb2a834ece7bcea66bce970c0e3"
constant kKatCommit2 = "83726c97707155ba2e81f0e5f673dd9e10dfde06e1c8f643bdd8539403aace51"
constant kKatCommit3 = "5f043c34bfb7a626581eb8653c88503a5a8524c9b47bdc2e09e37780005e0308"
-- keyed-stream deal vectors (spec 7.1) -- these were dropped from the block
-- when the lobby constants were added, which silently broke heTestDealRun
-- (undeclared names evaluate to their own text, then heHex2BinD throws). The
-- full set is emitted by tools/protocol-kat.py --gen-xtalk; keep it complete.
constant kKatSeedsXor = "73e2b09387940cf29398389f4d4fef74987ffac3c369b68cb522ded044cb00b8"
constant kKatStreamKey = "e4d91a49ee23982afb804fd386cbd3d2df6370ae0a743b0f461325b94818e40f"
constant kKatDeck = "Ks,4d,3c,Tc,9h,8c,Jd,4h,2c,6d,9d,Th,3d,9s,5s,3h,Qc,2h,9c,8h,7c,Js,7s,2d,6s,Ac,8s,As,Kh,2s,Ah,5h,Jh,Jc,4c,7h,6c,8d,Ad,Kd,Qs,Kc,6h,Qd,7d,5d,Qh,Ts,5c,3s,4s,Td"
constant kKatHole1 = "3c,8c"
constant kKatHole2 = "Ks,Tc"
constant kKatHole3 = "4d,9h"
constant kKatFlop = "4h,2c,6d"
constant kKatTurn = "Th"
constant kKatRiver = "9s"
constant kKatSynthStream = "8eaba859db2f1a2a3bce5e381fc1afa1339dc9b7a8a1bbc550277e756dabdffcf7390d23167268d1523ac24f71f476cd47cd1fcd31cfa7ec51ef45c7853978859f7a10230ff86f287f1ead8ec6ac797f6f3d3a1eb75bcb435b5f491b81077775b47c0dcf3cc1d1c8f329c4e1cdae9c6e21f3825454f5c04a21fde75572ef04e25e36672b9e4ce78b4333da7090746ff00b8e32e7ad161f033523cb6f5ba2b10af1a1ebf6c815e54e4fe5efed623198c302732bf6e40ed8856a89e15d78f564614531b8f684aa727e51ea968727a22eb6e14bd588d502b2637bd73d59a8518eaf7a2311d555dd86147e83af7f1e9ef7c9baf253b851bbb48abecdea0b27f90761a67fb810022c6eae480866f19839deb884a4ec819be41bcb605df7dd1ee2efcdaab49eef76d4a98b6be858d3324ac616f2b1f58fc9a1749a6164e2a0e276d62d1815d6a042c78b82f3b0d1ff78852cf8778ba3e127411f0121775056de9e5f8e4253f98b54e627e74cf8c2a38c83edd7d6272de4eb6bd645ebcae1f1701bda866beadc5968e757a8f902e2be46933346dcb794676fd609e14f67d20432796eb492a0c86910f10e51c5c02e5a9fa95f407283b3d0abfb8357cc5f94fe4416b5984eb07e046975e1c15edece5c9e80fd6de3d43d6831a310fe9d74e0c5bb9e438da44bffd728a284795046da833ffb8fdd16128b7fdee7ef76e434e035c7471d52"
constant kKatSynthDeck = "Ac,Kc,3d,5h,Kh,5d,Qc,3h,2h,5c,8c,4h,4d,Tc,7h,Qs,6c,Ts,6h,7d,Th,6s,Kd,3c,Jc,9s,4c,Ah,5s,2d,8s,As,2s,Ad,9d,Qh,8d,Jh,Qd,Jd,2c,6d,7s,Ks,7c,Js,8h,3s,4s,9h,9c,Td"
constant kKatIdSeed1 = "629a089485b96c24fef651012c8deae57aa438a7a11c81f3e6a99b5e22f83b38"
constant kKatIdSeed2 = "fa645b9f3778a3b162514e3a00436568aef46b726e10ef563c94e73b2c2cb448"
constant kKatIdSeed3 = "7833fb1675dbb196e2222ad6f93ff30aacd313faf7a7818078e30a47f6890083"
constant kKatIdPub1 = "b6ef1a19d789c27bea3f6c127db635929541f34907750ee12d0b715c010c7566"
constant kKatCfgBody = "v=1,level=0,sb=1,bb=2,seats=3,button=1"
constant kKatEnv0ContentHex = "31096535323637353635306437616434386337313239313835656664616563316532623839636334313064386534633865303835626364363532313837623237643309300962366566316131396437383963323762656133663663313237646236333539323935343166333439303737353065653132643062373135633031306337353636096366670937363364333132633663363537363635366333643330326337333632336433313263363236323364333232633733363536313734373333643333326336323735373437343666366533643331"
constant kKatEnv0SenderSig = "c1d5f49bcc0fb8418830f63cc8be9c6bf7e5fd11a77807af38e672aa7284bba9c9cd58d73976888055851d034d440ab504cd0c9ab984f7df368a5f94225b310b"
constant kKatChainHead6 = "62fcd52b3757f590c33bede7330620853074c1e5c153549244a8dac7287e3778"
constant kKatSettleHash = "68095dcf5a74fac1e1340a1073a466dcf117024257f5c265de21698257b34b6f"
constant kKatAdmitSig = "17cf45eeecf27a3e9b63e1e0ff47ae1ea337430cb135fb499944a60681fcd1e949a7a88f532b2f888c0ea32364e93e9aa2f569419f27e8034b695a4ee94d5e0b"
constant kKatIdPub2 = "833fed8ee30a882bd877555a9df260d4322224fa095513d84972a660e7ad6b10"
constant kKatLobbyCfgBody = "v=1,level=0,sb=1,bb=2,seats=6,button=1"
constant kKatRosterBody = "833fed8ee30a882bd877555a9df260d4322224fa095513d84972a660e7ad6b10:player,b6ef1a19d789c27bea3f6c127db635929541f34907750ee12d0b715c010c7566:host"
constant kKatLobbyHead2 = "54c4df80d160eaaef52536a8ff6f2a7e09caccc629e1c467fe382eedc8a23509"
constant kKatCkptSig = "08c7f29409998d642657b9a084802b7ca3a136d696e881b545ed4e5a750fdb6d14e4967f401977aca416f03c0d4f03f98b3acc53e61266f3d8cee9912639e20f"
constant kKatSettleHash2 = "5e716ce9022f4c47d99e081b52be3a8bb5f9f1f56d3def18577c2f7ac9de8df5"
constant kKatRcptHead1 = "53ed9ccc64863dc05c1b76cd7953e19bba73895b8dd22ea00e6c9ff40f423cef"
constant kKatRcptHead2 = "0284af24c750eaaaa5a521b87d8f1ab6ce00b0b2be074ce03d24884e004fc910"
constant kKatRcptSig1 = "222929a8ce05e0d45cab6658d9e67d882d6cfa1f91c35cda8e07a58763c4b1fb6c733e23d116f04ed91960c0ad386541139fed43e1632df341175021d70b1700"
constant kKatRcptSig2 = "20a21d334da7d32b00bf3a17920350ebaad0773121fc3f2d9feba041360d9548fb527c555cab8039985439bed3af73d17656b939942a6bc3a793630275070706"
constant kKatRcptSig3 = "429a37ee32d74fd2d09b1b3a86fccc383c7e773ef52670ed07e4ede7e2e10f9ab4b791d630d0b44bdb6c405ed5238cc0bbab9d40129d3673c2c39f1d5d1a9c09"

command heRunSelftest
   put empty into gRpt
   put 0 into gPassN
   put 0 into gFailN
   put 0 into gSkipN
   put "holde-em self-test  stack v" & kHeVersion & "  harness v" & kHeHarnessV \
         & return & return after gRpt
   -- each section runs inside a guard so a first-contact runtime fault in one
   -- is reported (with its error) and the rest still run -- the harness never
   -- dies with an opaque "error in function handler", it tells you where
   heRunSection "heTestEvaluatorRun"
   heRunSection "heTestBettingRun"
   heRunSection "heTestAnteRun"
   heRunSection "heTestLevelRun"
   heRunSection "heTestLegalRun"
   heRunSection "heTestScheduleRun"
   heRunSection "heTestShuffleRun"
   heRunSection "heTestFoldRun"
   heRunSection "heTestCryptoRun"
   heRunSection "heTestReceiptRun"
   heRunSection "heTestDealRun"
   heRunSection "heTestDealOrderRun"
   heRunSection "heTestLobbyRun"
   heRunSection "heTestNetSim"
   heRunSection "heProbeSodium"
   put return & "==== " & gPassN & " pass, " & gFailN & " fail, " & gSkipN & " skip ====" \
         & return after gRpt
   if gFailN > 0 then
      put "RESULT: FAILED" & return after gRpt
   else
      put "RESULT: green" & return after gRpt
   end if
   put gRpt
   return gRpt
end heRunSelftest

command heRunSection pName
   -- run one test section under a guard: a runtime fault is caught, counted as a
   -- FAIL with its error text, and the remaining sections still run. Keeps a
   -- first-contact arithmetic error in a new section from aborting the harness.
   local tErr
   try
      do pName
   catch tErr
      add 1 to gFailN
      put "FAIL  " & pName & " THREW: " & tErr & return after gRpt
   end try
end heRunSection

command heTAssert pLabel, pObserved, pExpected
   if pObserved is pExpected then
      add 1 to gPassN
      put "PASS  " & pLabel & return after gRpt
   else
      add 1 to gFailN
      put "FAIL  " & pLabel & return after gRpt
      put "      observed: " & pObserved & return after gRpt
      put "      expected: " & pExpected & return after gRpt
   end if
end heTAssert

command heTContains pLabel, pObserved, pNeedle
   if pObserved contains pNeedle then
      add 1 to gPassN
      put "PASS  " & pLabel & return after gRpt
   else
      add 1 to gFailN
      put "FAIL  " & pLabel & return after gRpt
      put "      observed: " & pObserved & return after gRpt
      put "      expected to contain: " & pNeedle & return after gRpt
   end if
end heTContains

command heTSkip pLabel, pWhy
   add 1 to gSkipN
   put "SKIP  " & pLabel & " (" & pWhy & ")" & return after gRpt
end heTSkip

command heTestDealRun
   -- on-engine mirror of the Level 0 keyed-stream deal (spec 7.1), pinned in
   -- tools/protocol-kat.py. SKIPs without SodiumXT. Exercises the real
   -- commit-reveal dealing protocol the online game uses.
   local tSeedsA, tXorHex, tKeyData, tDeckList, tDealA, tCommitsA, tTableData
   local tDealLog, tHoles1, tHoles2, tHoles3, tFlopP, tAuditOut
   put return & "-- 7. Level 0 keyed-stream deal (spec 7.1, crypto path)" & return after gRpt
   if not heHasSodium() then
      heTSkip "deal: Level 0 keyed-stream", "SodiumXT not installed"
      exit heTestDealRun
   end if
   set the itemDelimiter to comma
   put kKatSeed1 into tSeedsA[1]
   put kKatSeed2 into tSeedsA[2]
   put kKatSeed3 into tSeedsA[3]
   heTAssert "deal: seeds XOR", heXorSeedsHex(tSeedsA, 3), kKatSeedsXor
   put heHex2BinD(kKatTableHex) into tTableData
   put heStreamKeyData(tTableData, 1, kKatSeedsXor) into tKeyData
   heTAssert "deal: stream key", heBin2HexS(tKeyData), kKatStreamKey
   put heDeckFromStreamKey(tKeyData) into tDeckList
   heTAssert "deal: full shuffled deck (52 cards)", heTNamesOf(tDeckList), kKatDeck
   put heDealAssign(tDeckList, "1,2,3", 1) into tDealA
   heTAssert "deal: hole cards seat 1", heTNamesOf(tDealA["holesBy"][1]), kKatHole1
   heTAssert "deal: hole cards seat 2", heTNamesOf(tDealA["holesBy"][2]), kKatHole2
   heTAssert "deal: hole cards seat 3", heTNamesOf(tDealA["holesBy"][3]), kKatHole3
   heTAssert "deal: flop", heTNamesOf(tDealA["flopList"]), kKatFlop
   heTAssert "deal: turn", heCardName(tDealA["turnIx"]), kKatTurn
   heTAssert "deal: river", heCardName(tDealA["riverIx"]), kKatRiver
   -- end-of-hand audit: honest deal passes; a corrupted commit is named
   put heSeedCommitHex(kKatSeed1) into tCommitsA[1]
   put heSeedCommitHex(kKatSeed2) into tCommitsA[2]
   put heSeedCommitHex(kKatSeed3) into tCommitsA[3]
   heTAssert "deal: seed commitment 1", tCommitsA[1], kKatCommit1
   heTAssert "deal: audit passes the honest deal", \
         heAuditDeal(tTableData, 1, tSeedsA, tCommitsA, 3, tDealA, "1,2,3", 1), "pass"
   put kKatCommit1 into tCommitsA[2]
   heTAssert "deal: audit names a corrupted commit", \
         heAuditDeal(tTableData, 1, tSeedsA, tCommitsA, 3, tDealA, "1,2,3", 1), \
         "fail:commit-mismatch-position-2"

   -- audit-from-TRANSCRIPT (mirror of tools/fold-kat.py): build the canned
   -- Level 0 log heHandStart would write and confirm heAuditDealsFromLog
   -- re-derives the committed shuffle from the revealed seeds -- proving the
   -- played deal is verifiable by anyone with the transcript, and that a
   -- tampered revealed seed is caught.
   put kKatHole1 into tHoles1
   replace comma with "|" in tHoles1
   put kKatHole2 into tHoles2
   replace comma with "|" in tHoles2
   put kKatHole3 into tHoles3
   replace comma with "|" in tHoles3
   put kKatFlop into tFlopP
   replace comma with "|" in tFlopP
   put heLogLine(0, "table", "cfg", "sb=1,bb=2,seats=1|2|3,stacks=400|400|400,button=1") & return into tDealLog
   put heLogLine(1, "table", "handStart", "seats=1|2|3,button=1") & return after tDealLog
   put heLogLine(1, "table", "dealLevel", "level=0,table=" & kKatTableHex & ",count=3") & return after tDealLog
   put heLogLine(1, "seat1", "seedCommit", "pos=1,commit=" & kKatCommit1) & return after tDealLog
   put heLogLine(1, "seat2", "seedCommit", "pos=2,commit=" & kKatCommit2) & return after tDealLog
   put heLogLine(1, "seat3", "seedCommit", "pos=3,commit=" & kKatCommit3) & return after tDealLog
   put heLogLine(1, "seat1", "seedReveal", "pos=1,seed=" & kKatSeed1) & return after tDealLog
   put heLogLine(1, "seat2", "seedReveal", "pos=2,seed=" & kKatSeed2) & return after tDealLog
   put heLogLine(1, "seat3", "seedReveal", "pos=3,seed=" & kKatSeed3) & return after tDealLog
   put heLogLine(1, "table", "holeDeliver", "seat=1,cards=" & tHoles1) & return after tDealLog
   put heLogLine(1, "table", "holeDeliver", "seat=2,cards=" & tHoles2) & return after tDealLog
   put heLogLine(1, "table", "holeDeliver", "seat=3,cards=" & tHoles3) & return after tDealLog
   put heLogLine(1, "table", "board", "street=flop,cards=" & tFlopP) & return after tDealLog
   put heLogLine(1, "table", "board", "street=turn,cards=" & kKatTurn) & return after tDealLog
   put heLogLine(1, "table", "board", "street=river,cards=" & kKatRiver) & return after tDealLog
   put heLogLine(1, "table", "settle", "deltas=1:0|2:0|3:0") & return after tDealLog
   put heAuditDealsFromLog(tDealLog) into tAuditOut
   heTContains "deal: audit-from-transcript re-derives the committed shuffle", tAuditOut, "1/1 deals verified"
   heTContains "deal: audit-from-transcript marks the hand deal-verified", tAuditOut, "hand 1: deal-verified"
   replace ("pos=2,seed=" & kKatSeed2) with ("pos=2,seed=" & kKatSeed1) in tDealLog
   put heAuditDealsFromLog(tDealLog) into tAuditOut
   heTContains "deal: audit-from-transcript catches a tampered seed", tAuditOut, "deal-FAILED"
end heTestDealRun

function heTIdentityDeck
   -- deck 1..52 where each card's value IS its position, so a deal signature
   -- reads the card->seat mapping directly
   local tOut, tI
   put empty into tOut
   repeat with tI = 1 to 52
      put tI & comma after tOut
   end repeat
   delete char -1 of tOut
   return tOut
end heTIdentityDeck

function heTDealSig pDeckList, pOccList, pButton
   -- "seat=h1-h2;... flop=f-f-f turn=t river=r" from heDealAssign, matching
   -- tools/protocol-kat.py deal_signature over the identity deck (all chunks
   -- are of plain locals -- H6-safe)
   local tDealA, tSeatNum, tHole, tOut, tFlop
   set the itemDelimiter to comma
   put heDealAssign(pDeckList, pOccList, pButton) into tDealA
   put empty into tOut
   repeat for each item tSeatNum in pOccList
      put tDealA["holesBy"][tSeatNum] into tHole
      put tSeatNum & "=" & (item 1 of tHole) & "-" & (item 2 of tHole) & ";" after tOut
   end repeat
   delete char -1 of tOut
   put tDealA["flopList"] into tFlop
   put tOut & " flop=" & (item 1 of tFlop) & "-" & (item 2 of tFlop) & "-" & (item 3 of tFlop) \
         & " turn=" & tDealA["turnIx"] & " river=" & tDealA["riverIx"] into tOut
   return tOut
end heTDealSig

command heTestDealOrderRun
   -- pin the card->seat deal mapping (spec 7.1) for configs the main deal KAT
   -- never covers: button not first, non-contiguous seats, heads-up, full ring.
   -- On-engine mirror of tools/protocol-kat.py deal_orders (identity deck).
   local tDeck
   put return & "-- 12. deal order: card->seat mapping across seat configs" & return after gRpt
   put heTIdentityDeck() into tDeck
   heTAssert "deal-order: 3-handed, button 3 (button not first)", \
         heTDealSig(tDeck, "1,2,3", 3), "1=1-4;2=2-5;3=3-6 flop=8-9-10 turn=12 river=14"
   heTAssert "deal-order: non-contiguous seats 2,4,6 button 4", \
         heTDealSig(tDeck, "2,4,6", 4), "2=2-5;4=3-6;6=1-4 flop=8-9-10 turn=12 river=14"
   heTAssert "deal-order: heads-up 1,2 button 1", \
         heTDealSig(tDeck, "1,2", 1), "1=2-4;2=1-3 flop=6-7-8 turn=10 river=12"
   heTAssert "deal-order: heads-up non-contiguous 3,5 button 5", \
         heTDealSig(tDeck, "3,5", 5), "3=1-3;5=2-4 flop=6-7-8 turn=10 river=12"
   heTAssert "deal-order: full ring 1-6 button 4", \
         heTDealSig(tDeck, "1,2,3,4,5,6", 4), \
         "1=3-9;2=4-10;3=5-11;4=6-12;5=1-7;6=2-8 flop=14-15-16 turn=18 river=20"
end heTestDealOrderRun

command heTestLobbyRun
   -- on-engine mirror of the online lobby's signed-presence + reconnect path
   -- (spec 9), pinned in tools/protocol-kat.py. Two in-process identities:
   -- the host (idSeed1) opens a table and signs a cfg (seq 1, from genesis),
   -- then a roster (seq 2) once a player (idSeed2) has joined; a late joiner
   -- replays both from genesis and must land on kKatLobbyHead2. This checks
   -- the exact wires the transport carries, with no network. SKIPs w/o SodiumXT.
   local tPub, tSec, tHostPubHex, tContent, tWire1, tWire2, tWire3, tHead1, tHead2, tHead3
   local tMembers, tMembersRev, tRoster, tClientHead, tVerdict
   put return & "-- 8. Online lobby: signed presence + transcript replay (spec 9)" & return after gRpt
   if not heHasSodium() then
      heTSkip "lobby: signed presence + replay", "SodiumXT not installed"
      exit heTestLobbyRun
   end if
   set the itemDelimiter to comma

   -- canonical roster body: sorting (not input order) fixes the signed bytes
   put kKatIdPub1 & tab & "host" & return & kKatIdPub2 & tab & "player" into tMembers
   put kKatIdPub2 & tab & "player" & return & kKatIdPub1 & tab & "host" into tMembersRev
   put heRosterBody(tMembers) into tRoster
   heTAssert "lobby: canonical roster body", tRoster, kKatRosterBody
   heTAssert "lobby: roster body is order-independent", heRosterBody(tMembersRev), kKatRosterBody

   -- host builds the two presence wires (host is sender AND relay for presence)
   sxSignKeypairFromSeed heHex2BinD(kKatIdSeed1), tPub, tSec
   put heBin2HexS(tPub) into tHostPubHex
   put heEnvContentLine(kKatTableHex, 0, tHostPubHex, "cfg", kKatLobbyCfgBody) into tContent
   put heWireBuild(tContent, tSec, 1, kHeGenesisPrev, tSec) into tWire1
   put heChainNextHex(tWire1) into tHead1
   put heEnvContentLine(kKatTableHex, 0, tHostPubHex, "roster", tRoster) into tContent
   put heWireBuild(tContent, tSec, 2, tHead1, tSec) into tWire2
   put heChainNextHex(tWire2) into tHead2
   heTAssert "lobby: presence chain head after cfg+roster", tHead2, kKatLobbyHead2

   -- a joiner replays from genesis: cfg verifies at genesis, roster at head1
   heTAssert "lobby: joiner verifies the cfg wire (from genesis)", \
         heEnvVerify(tWire1, tHostPubHex, tHostPubHex, kHeGenesisPrev), "ok"
   heTAssert "lobby: joiner verifies the roster wire (chained)", \
         heEnvVerify(tWire2, tHostPubHex, tHostPubHex, tHead1), "ok"
   -- out-of-order replay is a chain break: the roster cannot land before the cfg
   heTAssert "lobby: roster before cfg is a chain break", \
         heEnvVerify(tWire2, tHostPubHex, tHostPubHex, kHeGenesisPrev), "drop:chain-break"

   -- resync recovery (spec 9): a client that ingested w1 then MISSED w2 wedges
   -- on w3 (drop:chain-break) -- but a full-log replay recovers it. Replayed w1
   -- drops (already have it), w2 lands on head1, w3 on head2: head reaches head3.
   -- This pins the recovery logic heNetRequestSync/heNetReplayLogTo rely on.
   put heEnvContentLine(kKatTableHex, 0, tHostPubHex, "roster", tRoster) into tContent
   put heWireBuild(tContent, tSec, 3, tHead2, tSec) into tWire3
   put heChainNextHex(tWire3) into tHead3
   put tHead1 into tClientHead
   -- w3 arrives with w2 still missing -> chain break, head does not move
   heTAssert "resync: gapped client drops the ahead-of-gap wire", \
         heEnvVerify(tWire3, tHostPubHex, tHostPubHex, tClientHead), "drop:chain-break"
   -- host replays the whole log; step the client head exactly as ingest would
   put heEnvVerify(tWire1, tHostPubHex, tHostPubHex, tClientHead) into tVerdict
   heTAssert "resync: replayed already-seen wire drops cleanly", tVerdict, "drop:chain-break"
   put heEnvVerify(tWire2, tHostPubHex, tHostPubHex, tClientHead) into tVerdict
   if tVerdict is "ok" then
      put heChainNextHex(tWire2) into tClientHead
   end if
   heTAssert "resync: missing wire now applies", tVerdict, "ok"
   put heEnvVerify(tWire3, tHostPubHex, tHostPubHex, tClientHead) into tVerdict
   if tVerdict is "ok" then
      put heChainNextHex(tWire3) into tClientHead
   end if
   heTAssert "resync: client recovers to the current chain head", tClientHead, tHead3
end heTestLobbyRun

command heTestNetSim
   -- single-machine LOOPBACK of the online message orchestration -- no rp1, no
   -- second machine. We drive the REAL stateful handlers (heHostRelay,
   -- heNetIngestWire) against gGame and route the bytes each side would send by
   -- hand, so seq-assignment, verify-or-drop, chain-advance, and resync recovery
   -- are proven on ONE machine before a networked OXT pass. btRp1Send is never
   -- reached (the host has no live peers, so heNetBroadcast is a no-op and the
   -- resync request finds no host peer). gGame is saved and restored so the sim
   -- never disturbs the live game. SKIPs without SodiumXT.
   local tSaved, tHostPub, tHostSec, tPlayPub, tPlaySec, tHostPubHex, tPlayPubHex
   local tCfgWire, tWire2, tWire3, tHostLog, tContent, tSenderSig, tPacket
   local tHead1, tHead2, tHead3, tBadPub, tBadSec
   local tPriorCfg, tForgedWire, tPriorHead, tWrongTable, tWrongWire
   put return & "-- 10. Online orchestration loopback (single machine, no rp1)" & return after gRpt
   if not heHasSodium() then
      heTSkip "netsim: online orchestration", "SodiumXT not installed"
      exit heTestNetSim
   end if
   set the itemDelimiter to comma
   put gGame into tSaved

   sxSignKeypairFromSeed heHex2BinD(kKatIdSeed1), tHostPub, tHostSec
   sxSignKeypairFromSeed heHex2BinD(kKatIdSeed2), tPlayPub, tPlaySec
   put heBin2HexS(tHostPub) into tHostPubHex
   put heBin2HexS(tPlayPub) into tPlayPubHex

   -- ===== HOST context =====
   put empty into gGame
   put "true" into gGame["online"]
   put "true" into gGame["isHost"]
   put tHostPubHex into gGame["idPubHex"]
   put tHostSec into gGame["idSecData"]
   put tHostPubHex into gGame["hostPubHex"]
   put kKatTableHex into gGame["tableIdHex"]
   put 0 into gGame["handNum"]
   put 0 into gGame["seqCounter"]
   put 0 into gGame["syncCooldown"]
   put kHeGenesisPrev into gGame["chainHeadHex"]
   put "true" into gGame["admittedA"][tHostPubHex]
   put "true" into gGame["admittedA"][tPlayPubHex]     -- as if the player already handshook
   put "host" into gGame["roleByPub"][tHostPubHex]
   put "player" into gGame["roleByPub"][tPlayPubHex]

   -- host emits a cfg (seq 1): heNetSendAction -> heHostRelay -> local ingest
   heNetSendAction "cfg", kKatLobbyCfgBody
   put gGame["log"] into tHostLog
   heTAssert "netsim: host relayed + logged its own cfg (seq 1)", the number of lines of tHostLog, 1
   put line 1 of tHostLog into tCfgWire
   put gGame["chainHeadHex"] into tHead1

   -- a player's signed action arrives; the host relays it (seq 2). This is the
   -- real star-topology path minus the rp1 hop (peerPubA is empty, no broadcast).
   put heEnvContentLine(kKatTableHex, 0, tPlayPubHex, "act", "verb=check,amount=0") into tContent
   put heEnvSenderSigHex(tContent, tPlaySec) into tSenderSig
   put tContent & tab & tSenderSig into tPacket
   heHostRelay 0, tPacket
   put gGame["log"] into tHostLog
   heTAssert "netsim: host verified + relayed a player action (seq 2)", the number of lines of tHostLog, 2
   put line 2 of tHostLog into tWire2
   put gGame["chainHeadHex"] into tHead2

   -- host emits a third wire (seq 3)
   heNetSendAction "cfg", kKatLobbyCfgBody
   put gGame["log"] into tHostLog
   put line 3 of tHostLog into tWire3
   put gGame["chainHeadHex"] into tHead3

   -- a validly-signed action from an UNADMITTED key must be dropped by the relay
   -- (admission is enforced, not just the signature) -- no new wire is produced
   sxSignKeypairFromSeed heHex2BinD(kKatIdSeed3), tBadPub, tBadSec
   put heEnvContentLine(kKatTableHex, 0, heBin2HexS(tBadPub), "act", "verb=bet,amount=99") into tContent
   put heEnvSenderSigHex(tContent, tBadSec) into tSenderSig
   put tContent & tab & tSenderSig into tPacket
   heHostRelay 0, tPacket
   put gGame["log"] into tHostLog
   heTAssert "netsim: host drops an unadmitted sender (no new wire)", the number of lines of tHostLog, 3

   -- ===== PLAYER context =====
   put empty into gGame
   put "true" into gGame["online"]
   put "false" into gGame["isHost"]
   put tPlayPubHex into gGame["idPubHex"]
   put tPlaySec into gGame["idSecData"]
   put tHostPubHex into gGame["hostPubHex"]
   put kKatTableHex into gGame["tableIdHex"]
   put 0 into gGame["syncCooldown"]
   put kHeGenesisPrev into gGame["chainHeadHex"]

   -- player ingests the host cfg wire -> chain advances, cfg body stashed
   heNetIngestWire tCfgWire
   heTAssert "netsim: player accepts host cfg + advances chain to head1", gGame["chainHeadHex"], tHead1
   heTAssert "netsim: player stashed the cfg body", gGame["cfgBody"], kKatLobbyCfgBody

   -- GAP: player misses wire 2, receives wire 3 -> chain break, head unchanged
   heNetIngestWire tWire3
   heTAssert "netsim: player drops the ahead-of-gap wire (chain unchanged)", gGame["chainHeadHex"], tHead1

   -- RESYNC replay: host replays 2 then 3 -> player recovers to head3
   heNetIngestWire tWire2
   heNetIngestWire tWire3
   heTAssert "netsim: player recovers to the host chain head after replay", gGame["chainHeadHex"], tHead3

   -- host-authority on ingest (deep-dive [1]/[6]): a wire whose cfg content is
   -- authored by a NON-host key -- even if it is otherwise valid and host-signed --
   -- must NOT overwrite the cfg body. Build one from the player key and confirm the
   -- stashed cfg is untouched.
   put gGame["cfgBody"] into tPriorCfg
   put heEnvContentLine(kKatTableHex, 0, tPlayPubHex, "cfg", "v=1,level=0,sb=999,bb=999,seats=6,button=1") into tContent
   put heWireBuild(tContent, tPlaySec, 4, gGame["chainHeadHex"], tHostSec) into tForgedWire
   heNetIngestWire tForgedWire
   heTAssert "netsim: a non-host cfg body is not folded (host-authority)", gGame["cfgBody"], tPriorCfg

   -- table binding on ingest (deep-dive [4]/[5]): a host-signed wire for a DIFFERENT
   -- table is dropped and the chain does not advance.
   put gGame["chainHeadHex"] into tPriorHead
   put "1111111111111111111111111111111111111111111111111111111111111111" into tWrongTable
   put heEnvContentLine(tWrongTable, 0, tHostPubHex, "cfg", kKatLobbyCfgBody) into tContent
   put heWireBuild(tContent, tHostSec, 5, tPriorHead, tHostSec) into tWrongWire
   heNetIngestWire tWrongWire
   heTAssert "netsim: a wire for another table is dropped (chain unchanged)", gGame["chainHeadHex"], tPriorHead

   put tSaved into gGame
end heTestNetSim

command heTestCryptoRun
   -- on-engine mirror of tools/protocol-kat.py (spec 6 + 7.1 crypto). SKIPs
   -- cleanly without SodiumXT; all-green confirms the online transcript
   -- foundation runs on this engine with the corrected sxHash/sign calls.
   local tPub, tSec, tHostPub, tHostSec, tContent, tWire, tPrevHex, tChainData
   local tSenderSeeds, tHands, tTypes, tBodies, tSeq, tTampered
   put return & "-- 6. SodiumXT crypto: hash / identity / signed envelope (spec 6)" & return after gRpt
   if not heHasSodium() then
      heTSkip "crypto: all SodiumXT KATs", "SodiumXT not installed"
      exit heTestCryptoRun
   end if
   set the itemDelimiter to comma

   heTAssert "crypto: sxHash(empty,32) is BLAKE2b-256", heHashHex(textEncode("", "utf-8")), kKatHashEmpty
   heTAssert "crypto: domain-separated seed commit 1", \
         heHashDomHex(kHeDomainSeedC, heHex2BinD(kKatSeed1)), kKatCommit1
   heTAssert "crypto: domain-separated seed commit 2", \
         heHashDomHex(kHeDomainSeedC, heHex2BinD(kKatSeed2)), kKatCommit2
   heTAssert "crypto: domain-separated seed commit 3", \
         heHashDomHex(kHeDomainSeedC, heHex2BinD(kKatSeed3)), kKatCommit3

   sxSignKeypairFromSeed heHex2BinD(kKatIdSeed1), tPub, tSec
   heTAssert "crypto: ed25519 identity pubkey from seed", heBin2HexS(tPub), kKatIdPub1

   put heEnvContentLine(kKatTableHex, 0, kKatIdPub1, "cfg", kKatCfgBody) into tContent
   heTAssert "crypto: canonical content-line bytes", \
         heBin2HexS(textEncode(tContent, "utf-8")), kKatEnv0ContentHex
   heTAssert "crypto: sender signature over the content line", \
         heEnvSenderSigHex(tContent, tSec), kKatEnv0SenderSig

   -- rebuild the six-envelope hash chain (host relay = identity 1)
   sxSignKeypairFromSeed heHex2BinD(kKatIdSeed1), tHostPub, tHostSec
   put kKatIdSeed1 & return & kKatIdSeed1 & return & kKatIdSeed2 & return \
         & kKatIdSeed3 & return & kKatIdSeed2 & return & kKatIdSeed3 into tSenderSeeds
   put "0,1,1,1,1,1" into tHands
   put "cfg,seedCommit,seedCommit,seedCommit,bidSB,bidBB" into tTypes
   put kKatCfgBody & return & kKatCommit1 & return & kKatCommit2 & return \
         & kKatCommit3 & return & "amount=1" & return & "amount=2" into tBodies
   put kHeGenesisPrev into tPrevHex
   repeat with tSeq = 1 to 6
      sxSignKeypairFromSeed heHex2BinD(line tSeq of tSenderSeeds), tPub, tSec
      put heEnvContentLine(kKatTableHex, item tSeq of tHands, heBin2HexS(tPub), \
            item tSeq of tTypes, line tSeq of tBodies) into tContent
      put heWireBuild(tContent, tSec, tSeq, tPrevHex, tHostSec) into tWire
      put heChainNextHex(tWire) into tPrevHex
      put heHex2BinD(tPrevHex) into tChainData
   end repeat
   heTAssert "crypto: six-envelope chain head", tPrevHex, kKatChainHead6
   heTAssert "crypto: settlement receipt hash", \
         heSettleHashHex("1:-4,2:8,3:-4", tChainData), kKatSettleHash

   -- verify-or-drop (spec 6): honest wire accepted, tampered body rejected
   sxSignKeypairFromSeed heHex2BinD(kKatIdSeed1), tPub, tSec
   put heEnvContentLine(kKatTableHex, 0, heBin2HexS(tPub), "cfg", kKatCfgBody) into tContent
   put heWireBuild(tContent, tSec, 1, kHeGenesisPrev, tSec) into tWire
   heTAssert "crypto: verify accepts an honest wire", \
         heEnvVerify(tWire, heBin2HexS(tPub), heBin2HexS(tPub), kHeGenesisPrev), "ok"
   put tWire into tTampered
   set the itemDelimiter to tab
   put heBin2HexS(textEncode("v=1,level=0,sb=9,bb=9,seats=3,button=1", "utf-8")) into item 6 of tTampered
   set the itemDelimiter to comma
   heTAssert "crypto: verify drops a tampered body", \
         heEnvVerify(tTampered, heBin2HexS(tPub), heBin2HexS(tPub), kHeGenesisPrev), "drop:bad-sender-sig"
   -- expect a DIFFERENT admitted key than the wire's actual signer
   sxSignKeypairFromSeed heHex2BinD(kKatIdSeed2), tHostPub, tHostSec
   heTAssert "crypto: verify drops an unknown sender", \
         heEnvVerify(tWire, heBin2HexS(tHostPub), heBin2HexS(tPub), kHeGenesisPrev), "drop:unknown-from"
   heTAssert "crypto: verify drops a chain break", \
         heEnvVerify(tWire, heBin2HexS(tPub), heBin2HexS(tPub), kKatChainHead6), "drop:chain-break"
   -- H4: a malformed (non-hex) field must DROP cleanly, never throw out of the
   -- poll loop. Corrupt the from-key to non-hex and confirm the verdict.
   put tWire into tTampered
   set the itemDelimiter to tab
   put "zznothexzz" into item 4 of tTampered
   set the itemDelimiter to comma
   heTAssert "crypto: verify drops a malformed hex field (no throw)", \
         heEnvVerify(tTampered, empty, heBin2HexS(tPub), kHeGenesisPrev), "drop:malformed"
   heTAssert "crypto: heIsHex rejects odd-length and non-hex", \
         heIsHex("abc", 0) & "," & heIsHex("zz", 0) & "," & heIsHex("ab", 0), "false,false,true"

   -- admission token (spec 5): host-role signature pinned, and the verify
   -- roundtrip returns the admitted pubkey for a good token, "" for a wrong
   -- table, and the role is recoverable for host adoption
   sxSignKeypairFromSeed heHex2BinD(kKatIdSeed1), tPub, tSec
   heTAssert "admit: host-token signature", \
         heBin2HexS(heSignDetachedD(textEncode(kHeDomainSess & kKatTableHex & "|" & kKatIdPub1 & "|host", "utf-8"), tSec)), \
         kKatAdmitSig
   heTAssert "admit: verify accepts a good token", \
         heAdmitTokenVerify(heAdmitTokenData(kKatTableHex, kKatIdPub1, tSec, "host"), kKatTableHex), kKatIdPub1
   heTAssert "admit: verify rejects a wrong-table token", \
         heAdmitTokenVerify(heAdmitTokenData(kKatTableHex, kKatIdPub1, tSec, "host"), kKatChainHead6), ""
   heTAssert "admit: role is recoverable", \
         heAdmitTokenRole(heAdmitTokenData(kKatTableHex, kKatIdPub1, tSec, "host")), "host"
end heTestCryptoRun

command heTestReceiptRun
   -- on-engine mirror of the host-trust hardening (spec 6 checkpoints + 8.3
   -- settlement receipts), pinned in tools/protocol-kat.py. Three players are
   -- simulated with the KAT identities, so the MULTI-PARTY signed ledger is
   -- verified on one machine. SKIPs without SodiumXT.
   local tPub1, tSec1, tPub2, tSec2, tPub3, tSec3, tSh2, tRh1, tRh2, tSig1, tSig2, tSig3
   put return & "-- 13. Host trust: checkpoints + multi-signed settlement receipts" & return after gRpt
   if not heHasSodium() then
      heTSkip "receipts: ckpt + settlement receipts", "SodiumXT not installed"
      exit heTestReceiptRun
   end if
   set the itemDelimiter to comma
   sxSignKeypairFromSeed heHex2BinD(kKatIdSeed1), tPub1, tSec1
   sxSignKeypairFromSeed heHex2BinD(kKatIdSeed2), tPub2, tSec2
   sxSignKeypairFromSeed heHex2BinD(kKatIdSeed3), tPub3, tSec3

   -- ckpt: a player signs the transcript head; a fork or a wrong signer fails
   heTAssert "ckpt: player signs the chain head", heCkptSigHex(kKatChainHead6, tSec2), kKatCkptSig
   heTAssert "ckpt: verify accepts the signer", \
         heCkptVerify(kKatCkptSig, kKatChainHead6, heBin2HexS(tPub2)), "true"
   heTAssert "ckpt: verify rejects a different signer", \
         heCkptVerify(kKatCkptSig, kKatChainHead6, heBin2HexS(tPub1)), "false"
   heTAssert "ckpt: verify rejects a forked (different) head", \
         heCkptVerify(kKatCkptSig, kKatRcptHead1, heBin2HexS(tPub2)), "false"

   -- settlement receipt chain: hand 1 then hand 2, each receipt chained to the last
   put heSettleHashHex("1:2,2:-1,3:-1", heHex2BinD(kHeGenesisPrev)) into tSh2
   heTAssert "receipt: hand-2 settlement digest", tSh2, kKatSettleHash2
   put heReceiptHeadHex(kKatSettleHash, kHeGenesisPrev) into tRh1
   heTAssert "receipt: hand-1 receipt head (from genesis)", tRh1, kKatRcptHead1
   put heReceiptHeadHex(tSh2, tRh1) into tRh2
   heTAssert "receipt: hand-2 receipt head (chained to hand 1)", tRh2, kKatRcptHead2

   -- all three seated players sign the hand-2 receipt head
   put heReceiptSigHex(tRh2, tSec1) into tSig1
   put heReceiptSigHex(tRh2, tSec2) into tSig2
   put heReceiptSigHex(tRh2, tSec3) into tSig3
   heTAssert "receipt: player 1 signature", tSig1, kKatRcptSig1
   heTAssert "receipt: player 2 signature", tSig2, kKatRcptSig2
   heTAssert "receipt: player 3 signature", tSig3, kKatRcptSig3
   heTAssert "receipt: all three signatures verify (ledger multi-signed)", \
         heReceiptSigVerify(tSig1, tRh2, heBin2HexS(tPub1)) and \
         heReceiptSigVerify(tSig2, tRh2, heBin2HexS(tPub2)) and \
         heReceiptSigVerify(tSig3, tRh2, heBin2HexS(tPub3)), "true"
   -- a signature over the WRONG (rolled-back) head is rejected
   heTAssert "receipt: a signature over a rolled-back head is rejected", \
         heReceiptSigVerify(tSig1, tRh1, heBin2HexS(tPub1)), "false"
   -- a forged co-signer (player 3's sig checked against player 1's key) is rejected
   heTAssert "receipt: a forged co-signer is rejected", \
         heReceiptSigVerify(tSig3, tRh2, heBin2HexS(tPub1)), "false"
end heTestReceiptRun

function heTIdxOf pNamesTxt
   local tOut, tNameTxt, tNames
   set the itemDelimiter to comma
   put pNamesTxt into tNames
   replace comma with space in tNames
   put empty into tOut
   repeat for each word tNameTxt in tNames
      put heCardIndex(tNameTxt) & comma after tOut
   end repeat
   delete char -1 of tOut
   return tOut
end heTIdxOf

function heTNamesOf pIdxList
   local tOut, tIdx
   set the itemDelimiter to comma
   put empty into tOut
   repeat for each item tIdx in pIdxList
      put heCardName(tIdx) & comma after tOut
   end repeat
   delete char -1 of tOut
   return tOut
end heTNamesOf

function heTVectors
   local tVecs
   put empty into tVecs
   put "As Ks Qs Js Ts 2c 3d|081400000000|royal flush" & return after tVecs
   put "9h 8h 7h 6h 5h Ad Kc|080900000000|straight flush 9 high" & return after tVecs
   put "Ah 2h 3h 4h 5h Kd Qc|080500000000|wheel straight flush high=5" & return after tVecs
   put "Ah 2h 3h 4h 5h Kh Qh|080500000000|steel wheel not outranked by flush" & return after tVecs
   put "Qc Qd Qh Qs Ad 2c 3c|071214000000|quads with best kicker" & return after tVecs
   put "8c 8d 8h 8s Kd 2c 2d|070813000000|quads on board, kicker decides" & return after tVecs
   put "Ac Ad Ah Kc Kd Kh Qs|061413000000|boat over boat: two trips" & return after tVecs
   put "2c 2d 2h 3c 3d Ah Kh|060203000000|boat: low trips high pair" & return after tVecs
   put "9h 8h 6h 5h 2h 7c Td|050908060502|flush beats mixed straight" & return after tVecs
   put "Ah Qh Th 8h 6h 4h 2h|051412100806|flush best five of seven suited" & return after tVecs
   put "As Kd Qh Js Tc 2c 3d|041400000000|broadway straight" & return after tVecs
   put "As Kd Qh Js Tc 4h 5s|041400000000|board plays: same broadway" & return after tVecs
   put "Ad 2c 3h 4s 5d Kc Qh|040500000000|wheel straight mixed suits" & return after tVecs
   put "2c 3d 4h 5s 6c 7d 8h|040800000000|seven-card run picks best high" & return after tVecs
   put "8c 7d 6h 5s 4c 8d 4d|040800000000|straight through paired board" & return after tVecs
   put "Ac Kd Qh Js 9c 2d 3h|001413121109|A-K-Q-J-9 is no straight" & return after tVecs
   put "Ac Ad Ah Kc Qd 9s 2c|031413120000|trips with two kickers" & return after tVecs
   put "Ac Ad Kc Kd Qc Qd 2h|021413120000|two pair from three pairs" & return after tVecs
   put "9c 9d 8c 8d 2h 2s Ac|020908140000|two pair lone ace outkicks" & return after tVecs
   put "Jc Jd 4c 4d 9h 8s Ah|021104140000|plain two pair ace kicker" & return after tVecs
   put "Ac Ad Kc Qd 9s 5h 2c|011413120900|one pair three kickers" & return after tVecs
   put "7c 7d 7h 4c 4d 4h As|060704000000|full house from two trips low" & return after tVecs
   put "2c 2d 2h 2s Ac 7d 5h|070214000000|quads of deuces ace kicker" & return after tVecs
   put "Kh Jh Th 9h 8h 7h 2c|081100000000|six-card flush hides a J-high SF" & return after tVecs
   put "2c 3d 4h 5s 6c Ac Kd|040600000000|6-high straight chosen over the wheel" & return after tVecs
   put "Ac Ad Ah Kc Kd Qc Qd|061413000000|boat picks the higher of two pairs" & return after tVecs
   return tVecs
end heTVectors

command heTestEvaluatorRun
   local tVecLine, tExpect, tLabel, tIdxList, tBase, tPermLines, tPermLine
   local tPermuted, tPos, tResA, tPairI, tPairJ, tBad, tVecCount, tA, tBv
   put "-- 1. evaluator (spec 8.2)" & return after gRpt
   repeat for each line tVecLine in heTVectors()
      set the itemDelimiter to "|"
      put item 2 of tVecLine into tExpect
      put item 3 of tVecLine into tLabel
      put heTIdxOf(item 1 of tVecLine) into tIdxList
      heTAssert "eval: " & tLabel, heEval7(tIdxList), tExpect
   end repeat

   put "7,6,5,4,3,2,1" & return & "4,5,6,7,1,2,3" & return \
         & "2,4,6,1,3,5,7" & return & "5,1,7,3,6,2,4" into tPermLines
   put 0 into tBad
   repeat for each line tVecLine in heTVectors()
      set the itemDelimiter to "|"
      put heTIdxOf(item 1 of tVecLine) into tIdxList
      set the itemDelimiter to comma
      put heEval7(tIdxList) into tBase
      repeat for each line tPermLine in tPermLines
         put empty into tPermuted
         repeat for each item tPos in tPermLine
            put item tPos of tIdxList & comma after tPermuted
         end repeat
         delete char -1 of tPermuted
         if heEval7(tPermuted) is not tBase then
            add 1 to tBad
         end if
      end repeat
   end repeat
   heTAssert "eval: order independence (24 hands x 4 permutations)", tBad, 0

   put 0 into tPos
   repeat for each line tVecLine in heTVectors()
      set the itemDelimiter to "|"
      add 1 to tPos
      put heEval7(heTIdxOf(item 1 of tVecLine)) into tResA[tPos]
   end repeat
   put tPos into tVecCount
   put 0 into tBad
   repeat with tPairI = 1 to tVecCount - 1
      repeat with tPairJ = tPairI + 1 to tVecCount
         put tResA[tPairI] > tResA[tPairJ] into tA
         put tResA[tPairJ] > tResA[tPairI] into tBv
         if tResA[tPairI] is tResA[tPairJ] then
            if tA or tBv then
               add 1 to tBad
            end if
         else
            if tA is tBv then
               add 1 to tBad
            end if
         end if
      end repeat
   end repeat
   heTAssert "eval: antisymmetry over all vector pairs", tBad, 0
end heTestEvaluatorRun

function heTNewHand pSB, pBB, pStacksList, pOccList, pButtonSeat
   -- ante-free wrapper for the existing betting cases; heTNewHandAnte adds antes
   local tStacksA, tPos, tSeatNum
   set the itemDelimiter to comma
   put 0 into tPos
   repeat for each item tSeatNum in pOccList
      add 1 to tPos
      put item tPos of pStacksList into tStacksA[tSeatNum]
   end repeat
   return heBetNewHand(pSB, pBB, 0, tStacksA, pOccList, pButtonSeat)
end heTNewHand

function heTNewHandAnte pSB, pBB, pAnte, pStacksList, pOccList, pButtonSeat
   local tStacksA, tPos, tSeatNum
   set the itemDelimiter to comma
   put 0 into tPos
   repeat for each item tSeatNum in pOccList
      add 1 to tPos
      put item tPos of pStacksList into tStacksA[tSeatNum]
   end repeat
   return heBetNewHand(pSB, pBB, pAnte, tStacksA, pOccList, pButtonSeat)
end heTNewHandAnte

function heTBlinds pStateA
   local tStateA
   put heBetApply(pStateA, "bidSB", pStateA["sbSeat"], \
         min(pStateA["sb"], pStateA["stackBy"][pStateA["sbSeat"]])) into tStateA
   put heBetApply(tStateA, "bidBB", tStateA["bbSeat"], \
         min(tStateA["bb"], tStateA["stackBy"][tStateA["bbSeat"]])) into tStateA
   return tStateA
end heTBlinds

function heTAct pStateA, pSeatNum, pVerbAmt, pExpectErr, pLabel
   local tStateA
   put heBetApply(pStateA, "act", pSeatNum, pVerbAmt) into tStateA
   heTAssert pLabel, tStateA["err"], pExpectErr
   if tStateA["err"] is empty then
      return tStateA
   end if
   return pStateA
end heTAct

function heTDeltasTxt pDeltasA, pOccList
   local tOut, tSeatNum
   set the itemDelimiter to comma
   put empty into tOut
   repeat for each item tSeatNum in pOccList
      put tSeatNum & ":" & pDeltasA[tSeatNum] & "|" after tOut
   end repeat
   delete char -1 of tOut
   return tOut
end heTDeltasTxt

command heTestBettingRun
   local tStateA, tDeltasA, tRanksA
   put return & "-- 2. betting engine (spec 8.1) + settlement (8.3)" & return after gRpt
   set the itemDelimiter to comma

   put heTBlinds(heTNewHand(1, 2, "100,100,100", "1,2,3", 1)) into tStateA
   heTAssert "bet: preflop first to act is left of BB", tStateA["toAct"], 1
   put heTAct(tStateA, 1, "raise,3", "raise-below-minimum", "bet: raise under min rejected") into tStateA
   put heTAct(tStateA, 1, "raise,4", empty, "bet: min raise accepted") into tStateA
   put heTAct(tStateA, 2, "raise,5", "raise-below-minimum", "bet: re-raise under min rejected") into tStateA
   put heTAct(tStateA, 2, "raise,6", empty, "bet: re-raise at min accepted") into tStateA
   heTAssert "bet: raiseFull tracks the full raise", tStateA["raiseFull"], 2

   put heTBlinds(heTNewHand(1, 2, "100,13,100", "1,2,3", 1)) into tStateA
   put heTAct(tStateA, 1, "call,2", empty, "bet: limp accepted") into tStateA
   put heTAct(tStateA, 2, "call,1", empty, "bet: sb completes") into tStateA
   put heTAct(tStateA, 3, "check,0", empty, "bet: bb checks option") into tStateA
   heTAssert "bet: flop reached", tStateA["street"], "flop"
   put heTAct(tStateA, 2, "check,0", empty, "bet: flop check") into tStateA
   put heTAct(tStateA, 3, "bet,10", empty, "bet: flop bet 10") into tStateA
   put heTAct(tStateA, 1, "call,10", empty, "bet: flop call") into tStateA
   put heTAct(tStateA, 2, "allin,11", empty, "bet: under-raise all-in accepted") into tStateA
   heTAssert "bet: raiseFull stays 10 after under-raise", tStateA["raiseFull"], 10
   put heTAct(tStateA, 3, "raise,25", "raise-not-reopened", "bet: bettor cannot re-raise under-raise") into tStateA
   put heTAct(tStateA, 3, "call,1", empty, "bet: bettor calls the extra") into tStateA
   put heTAct(tStateA, 1, "call,1", empty, "bet: caller calls the extra") into tStateA
   heTAssert "bet: street closes to turn", tStateA["street"], "turn"

   put heTBlinds(heTNewHand(1, 2, "100,50,20", "1,2,3", 1)) into tStateA
   put heTAct(tStateA, 1, "allin,100", empty, "pot: open shove") into tStateA
   put heTAct(tStateA, 2, "allin,50", empty, "pot: short call-allin") into tStateA
   put heTAct(tStateA, 3, "allin,20", empty, "pot: shorter call-allin") into tStateA
   heTAssert "pot: hand runs out", tStateA["phase"], "runout"
   put heBetApply(tStateA, "board", 0, 0) into tStateA
   put heBetApply(tStateA, "board", 0, 0) into tStateA
   put heBetApply(tStateA, "board", 0, 0) into tStateA
   heTAssert "pot: runout reaches showdown", tStateA["phase"], "showdown"
   put empty into tRanksA
   put "011413120900" into tRanksA[1]
   put "021104140000" into tRanksA[2]
   put "031413120000" into tRanksA[3]
   put heSettleOf(tStateA, tRanksA) into tDeltasA
   heTAssert "pot: main 60 to s3, side 60 to s2, 50 back to s1", \
         heTDeltasTxt(tDeltasA, tStateA["occ"]), "1:-50|2:10|3:40"

   put heTNewHand(1, 2, "100,100", "2,5", 2) into tStateA
   heTAssert "hu: button posts SB", tStateA["sbSeat"], 2
   heTAssert "hu: other seat posts BB", tStateA["bbSeat"], 5
   put heTBlinds(tStateA) into tStateA
   heTAssert "hu: button acts first preflop", tStateA["toAct"], 2
   put heTAct(tStateA, 2, "call,1", empty, "hu: button completes") into tStateA
   put heTAct(tStateA, 5, "check,0", empty, "hu: bb checks") into tStateA
   heTAssert "hu: non-button acts first postflop", tStateA["toAct"], 5

   put heTBlinds(heTNewHand(1, 2, "100,100", "1,2", 1)) into tStateA
   put heTAct(tStateA, 1, "raise,6", empty, "fw: open raise") into tStateA
   put heTAct(tStateA, 2, "fold,0", empty, "fw: fold") into tStateA
   heTAssert "fw: fold ends the hand", tStateA["phase"], "handdone"
   put empty into tRanksA
   put heSettleOf(tStateA, tRanksA) into tDeltasA
   heTAssert "fw: uncalled raise returned", heTDeltasTxt(tDeltasA, tStateA["occ"]), "1:2|2:-2"

   put heTBlinds(heTNewHand(1, 2, "100,100,100", "1,2,3", 1)) into tStateA
   put heTAct(tStateA, 1, "call,2", empty, "split: limp") into tStateA
   put heTAct(tStateA, 2, "call,1", empty, "split: sb completes") into tStateA
   put heTAct(tStateA, 3, "check,0", empty, "split: bb checks") into tStateA
   put heTAct(tStateA, 2, "bet,9", empty, "split: flop bet") into tStateA
   put heTAct(tStateA, 3, "call,9", empty, "split: flop call 1") into tStateA
   put heTAct(tStateA, 1, "call,9", empty, "split: flop call 2") into tStateA
   put heTAct(tStateA, 2, "check,0", empty, "split: turn check 1") into tStateA
   put heTAct(tStateA, 3, "check,0", empty, "split: turn check 2") into tStateA
   put heTAct(tStateA, 1, "check,0", empty, "split: turn check 3") into tStateA
   put heTAct(tStateA, 2, "check,0", empty, "split: river check") into tStateA
   put heTAct(tStateA, 3, "bet,2", empty, "split: river bet") into tStateA
   put heTAct(tStateA, 1, "call,2", empty, "split: river call 1") into tStateA
   put heTAct(tStateA, 2, "call,2", empty, "split: river call 2") into tStateA
   heTAssert "split: river aggressor shows first", heShowdownOrderOf(tStateA), "3,1,2"
   put empty into tRanksA
   put "041400000000" into tRanksA[1]
   put "041400000000" into tRanksA[2]
   put "011413120900" into tRanksA[3]
   put heSettleOf(tStateA, tRanksA) into tDeltasA
   heTAssert "split: odd chip to first winner after button", \
         heTDeltasTxt(tDeltasA, tStateA["occ"]), "1:6|2:7|3:-13"

   put heTNewHand(1, 2, "1,2", "4,6", 4) into tStateA
   put heBetApply(tStateA, "bidSB", 4, 1) into tStateA
   heTAssert "blind: short SB posts all-in", tStateA["allinBy"][4], "true"
   put heBetApply(tStateA, "bidBB", 6, 2) into tStateA
   heTAssert "blind: both blinds all-in -> runout", tStateA["phase"], "runout"
end heTestBettingRun

command heTestAnteRun
   -- antes are dead money: into the pot (handBy), NEVER the street bet, so a seat
   -- still owes the full blind. Mirror of betting-kat case_antes / conservation.
   local tStateA, tDeltasA, tRanksA, tSeatNum
   put return & "-- 2b. antes (dead money) + chip conservation" & return after gRpt
   set the itemDelimiter to comma

   put heTNewHandAnte(1, 2, 1, "100,100,100", "1,2,3", 1) into tStateA
   repeat with tSeatNum = 1 to 3
      put heBetApply(tStateA, "bidAnte", tSeatNum, 1) into tStateA
   end repeat
   heTAssert "ante: dead money in the pot (s1 handBy)", tStateA["handBy"][1], 1
   heTAssert "ante: not on the street bet (s1 streetBy)", tStateA["streetBy"][1], 0
   put heTBlinds(tStateA) into tStateA
   heTAssert "ante: SB total = ante + small blind", tStateA["handBy"][2], 2
   heTAssert "ante: BB total = ante + big blind", tStateA["handBy"][3], 3
   put heTAct(tStateA, 1, "fold,0", empty, "ante: utg folds") into tStateA
   put heTAct(tStateA, 2, "fold,0", empty, "ante: sb folds") into tStateA
   heTAssert "ante: fold-around ends the hand", tStateA["phase"], "handdone"
   put empty into tRanksA
   put heSettleOf(tStateA, tRanksA) into tDeltasA
   heTAssert "ante: dead money folds into the winner's pot", \
         heTDeltasTxt(tDeltasA, tStateA["occ"]), "1:-1|2:-2|3:3"

   put heTNewHandAnte(1, 2, 5, "100,100,1", "1,2,3", 1) into tStateA
   repeat with tSeatNum = 1 to 3
      put heBetApply(tStateA, "bidAnte", tSeatNum, min(5, tStateA["stackBy"][tSeatNum])) into tStateA
   end repeat
   heTAssert "ante: short seat posts what it has", tStateA["handBy"][3], 1
   heTAssert "ante: short seat all-in for the ante", tStateA["allinBy"][3], "true"

   put heTNewHandAnte(5, 10, 2, "200,200,200", "1,2,3", 1) into tStateA
   repeat with tSeatNum = 1 to 3
      put heBetApply(tStateA, "bidAnte", tSeatNum, 2) into tStateA
   end repeat
   put heTBlinds(tStateA) into tStateA
   put heTAct(tStateA, 1, "allin,198", empty, "ante: s1 all-in 198") into tStateA
   put heTAct(tStateA, 2, "allin,198", empty, "ante: s2 all-in 198") into tStateA
   put heTAct(tStateA, 3, "allin,198", empty, "ante: s3 all-in 198") into tStateA
   heTAssert "ante: three-way all-in runs out", tStateA["phase"], "runout"
   put heBetApply(tStateA, "board", 0, 0) into tStateA
   put heBetApply(tStateA, "board", 0, 0) into tStateA
   put heBetApply(tStateA, "board", 0, 0) into tStateA
   put empty into tRanksA
   put "011413120900" into tRanksA[1]
   put "021104140000" into tRanksA[2]
   put "081400000000" into tRanksA[3]
   put heSettleOf(tStateA, tRanksA) into tDeltasA
   heTAssert "ante: winner scoops the 600 pot (each put in its whole 200)", \
         heTDeltasTxt(tDeltasA, tStateA["occ"]), "1:-200|2:-200|3:400"

   -- P0 regression pin (deep-dive): a blind-position seat that is short AFTER its
   -- ante must be posted from the POST-ante stack, which is exactly what heHandStart
   -- now caps by (gGame["state"]["stackBy"]). Seat 2 = SB, starts 55, ante 10 ->
   -- post-ante stack 45, so its all-in small blind is 45, not min(50, pre-ante 55).
   put heTNewHandAnte(50, 100, 10, "400,55,400", "1,2,3", 1) into tStateA
   repeat with tSeatNum = 1 to 3
      put heBetApply(tStateA, "bidAnte", tSeatNum, min(10, tStateA["stackBy"][tSeatNum])) into tStateA
   end repeat
   heTAssert "ante: short SB seat is short after its ante", tStateA["stackBy"][2], 45
   put heBetApply(tStateA, "bidSB", 2, min(50, tStateA["stackBy"][2])) into tStateA
   heTAssert "ante: short SB posts from the post-ante stack (heHandStart P0 fix)", tStateA["err"], empty
   heTAssert "ante: short SB is all-in for ante + short blind", tStateA["handBy"][2], 55
   -- and the OLD pre-ante cap (the bug the fix removes) is what the engine rejects:
   put heTNewHandAnte(50, 100, 10, "400,55,400", "1,2,3", 1) into tStateA
   repeat with tSeatNum = 1 to 3
      put heBetApply(tStateA, "bidAnte", tSeatNum, min(10, tStateA["stackBy"][tSeatNum])) into tStateA
   end repeat
   put heBetApply(tStateA, "bidSB", 2, min(50, 55)) into tStateA
   heTAssert "ante: a pre-ante blind cap is rejected (regression guard)", \
         tStateA["err"], "bidSB-wrong-amount"
end heTestAnteRun

command heTestLevelRun
   -- tournament blind schedule: pure level selection by hand number (heLevelFor).
   -- Mirror of betting-kat case_levels.
   local tLv
   put return & "-- 2c. tournament blind levels (heLevelFor)" & return after gRpt
   put "1/2/0;2/4/0;3/6/0;5/10/0;10/20/0;15/30/0;25/50/0;50/100/10" into tLv
   heTAssert "level: hand 1 is level 1", heLevelFor(1, tLv, 8), "1,2,0"
   heTAssert "level: last hand of level 1", heLevelFor(8, tLv, 8), "1,2,0"
   heTAssert "level: first hand of level 2", heLevelFor(9, tLv, 8), "2,4,0"
   heTAssert "level: hand 20 is level 3", heLevelFor(20, tLv, 8), "3,6,0"
   heTAssert "level: hand 25 is level 4", heLevelFor(25, tLv, 8), "5,10,0"
   heTAssert "level: top level carries an ante", heLevelFor(57, tLv, 8), "50,100,10"
   heTAssert "level: clamps at the final level", heLevelFor(9999, tLv, 8), "50,100,10"
   heTAssert "level: every=1 advances each hand", heLevelFor(3, tLv, 1), "3,6,0"
   heTAssert "level: period 1 is level 1", heLevelForPeriod(1, tLv), "1,2,0"
   heTAssert "level: period 4 is level 4", heLevelForPeriod(4, tLv), "5,10,0"
   heTAssert "level: period clamps at the top", heLevelForPeriod(999, tLv), "50,100,10"
   heTAssert "level: count of the default schedule", heLevelCount(tLv), 8
end heTestLevelRun

function heTLegalAllAccepted pStateA, pSeatNum
   -- replay every line heBetLegal offers through heBetApply (the gate); returns
   -- "ok" iff all are accepted, else the first rejected action. bet/raise offer
   -- a MIN and a MAX (words 2 and 3) -- both must be accepted.
   local tMenu, tLine, tVerb, tRes
   put heBetLegal(pStateA, pSeatNum) into tMenu
   repeat for each line tLine in tMenu
      put word 1 of tLine into tVerb
      switch tVerb
         case "fold"
         case "check"
            put heBetApply(pStateA, "act", pSeatNum, tVerb & ",0") into tRes
            break
         case "call"
         case "allin"
            put heBetApply(pStateA, "act", pSeatNum, tVerb & comma & word 2 of tLine) into tRes
            break
         case "bet"
         case "raise"
            put heBetApply(pStateA, "act", pSeatNum, tVerb & comma & word 2 of tLine) into tRes
            if tRes["err"] is empty then
               put heBetApply(pStateA, "act", pSeatNum, tVerb & comma & word 3 of tLine) into tRes
            end if
            break
      end switch
      if tRes["err"] is not empty then
         return "rejected:" & tLine & "(" & tRes["err"] & ")"
      end if
   end repeat
   return "ok"
end heTLegalAllAccepted

command heTestLegalRun
   -- heBetLegal must offer exactly the actions heBetApply accepts (the gate).
   -- On-engine mirror of the legal-consistency fuzz in tools/logic-fuzz.py: for
   -- reachable states, every action heBetLegal offers is replayed through
   -- heBetApply and must be accepted. A bug here would show a player an illegal
   -- move or hide a legal one -- a fairness bug.
   local tStateA, tSeatNum
   put return & "-- 11. heBetLegal: every offered action is accepted (spec 8.1)" & return after gRpt
   set the itemDelimiter to comma
   -- preflop, 3-handed, 100 each, button 1: first-to-act faces the big blind
   put heTNewHand(1, 2, "100,100,100", "1,2,3", 1) into tStateA
   put heTBlinds(tStateA) into tStateA
   put tStateA["toAct"] into tSeatNum
   heTAssert "legal: preflop first-to-act menu is non-empty", \
         (heBetLegal(tStateA, tSeatNum) is not empty), "true"
   heTAssert "legal: every preflop action offered is accepted", \
         heTLegalAllAccepted(tStateA, tSeatNum), "ok"
   -- the next seat now faces a raise (re-raise decision)
   put heTAct(tStateA, tSeatNum, "raise,6", "", "legal: setup a raise to 6") into tStateA
   put tStateA["toAct"] into tSeatNum
   heTAssert "legal: every action offered facing a raise is accepted", \
         heTLegalAllAccepted(tStateA, tSeatNum), "ok"
   -- a short stack that cannot cover a full raise: menu still all-accepted
   put heTNewHand(1, 2, "3,100,100", "1,2,3", 1) into tStateA
   put heTBlinds(tStateA) into tStateA
   put tStateA["toAct"] into tSeatNum
   heTAssert "legal: short-stack menu is all accepted", \
         heTLegalAllAccepted(tStateA, tSeatNum), "ok"
end heTestLegalRun

function heTButtonSchedule pLiveList, pLastBB
   -- returns "button,SB,BB" the way the shell schedules a hand, via the pure
   -- heScheduleButton + heBetNewHand derivation
   local tBtn, tStateA, tStacksA, tSeatNum
   set the itemDelimiter to comma
   repeat for each item tSeatNum in pLiveList
      put 100 into tStacksA[tSeatNum]
   end repeat
   put heScheduleButton(pLiveList, pLastBB) into tBtn
   put heBetNewHand(1, 2, 0, tStacksA, pLiveList, tBtn) into tStateA
   return tBtn & comma & tStateA["sbSeat"] & comma & tStateA["bbSeat"]
end heTButtonSchedule

command heTestScheduleRun
   local tSeq, tLastBB, tRound, tOne
   set the itemDelimiter to comma
   put return & "-- 2b. blind schedule (dead-button; TDA rule 10)" & return after gRpt
   -- 3-handed no-bust: button and BB each advance one seat per hand
   put empty into tSeq
   put 0 into tLastBB
   repeat with tRound = 1 to 4
      put heTButtonSchedule("1,2,3", tLastBB) into tOne
      put tOne & ";" after tSeq
      put item 3 of tOne into tLastBB
   end repeat
   delete char -1 of tSeq
   heTAssert "sched: 3-handed no-bust rotation", tSeq, "1,2,3;2,3,1;3,1,2;1,2,3"
   -- seat 1 busts after button=1/BB=3: heads-up must not post BB twice for seat 3
   heTAssert "sched: bust-to-HU no double BB", heTButtonSchedule("2,3", 3), "3,3,2"
   -- seats 2,3 bust after button=1/BB=3: BB advances to the survivor (seat 4)
   heTAssert "sched: double-bust BB advances to survivor", heTButtonSchedule("1,4,5,6", 3), "6,1,4"
end heTestScheduleRun

command heTestShuffleRun
   local tDeckList, tDealA, tPos, tSeenA, tDup, tSecond
   set the itemDelimiter to comma
   put return & "-- 3. integer shuffle (binary-free deal)" & return after gRpt

   -- draw bounds: every draw is within 1..n
   heTAssert "draw: minstd step is deterministic", heRngStep(1), 16807
   heTAssert "draw: uniform in range returns value,state", item 1 of heDrawInt(1, 52) is a number, "true"

   -- pinned deck for a fixed seed (mirrored in tools; MINSTD from seed 1)
   put heShuffleDeck(1) into tDeckList
   heTAssert "shuffle: seed 1 matches the pinned deck", heTNamesOf(tDeckList), kKatSeed1Deck

   -- permutation property: all 52 present, none twice
   put 0 into tDup
   repeat with tPos = 1 to 52
      if tSeenA[item tPos of tDeckList] is "true" then
         add 1 to tDup
      end if
      put "true" into tSeenA[item tPos of tDeckList]
   end repeat
   heTAssert "shuffle: seed 1 deck is a permutation of 52", (tDup is 0) and (the number of items of tDeckList is 52), "true"

   -- determinism: same seed -> same deck
   put heShuffleDeck(20260712) into tSecond
   heTAssert "shuffle: same seed reproduces the deck", heShuffleDeck(20260712), tSecond

   -- deal assignment on the pinned deck (3 seats, button 1 -> order 2,3,1)
   put heDealAssign(tDeckList, "1,2,3", 1) into tDealA
   heTAssert "deal: seat 1 gets cards 3 and 6 off the top", \
         heTNamesOf(tDealA["holesBy"][1]), (heCardName(item 3 of tDeckList)) & comma & (heCardName(item 6 of tDeckList))
   heTAssert "deal: flop is deck 8-10 after two rounds + burn", \
         heTNamesOf(tDealA["flopList"]), \
         (heCardName(item 8 of tDeckList)) & comma & (heCardName(item 9 of tDeckList)) & comma & (heCardName(item 10 of tDeckList))

   -- keyed-stream shuffle CORE, cross-checked WITHOUT SodiumXT: feed the fixed
   -- synthetic hex stream (tools/protocol-kat.py SYNTH_STREAM) straight through
   -- the rejection-sampling draw + Fisher-Yates and compare to the pinned deck.
   -- This pins heDrawUniform (modulo-bias/off-by-one) + heShuffleFromStreamHex
   -- on every engine, even one with no crypto installed (that is exactly why
   -- SYNTH_STREAM exists -- it needs no hashing).
   heTAssert "shuffle: synthetic keyed-stream deck (no crypto)", \
         heTNamesOf(heShuffleFromStreamHex(kKatSynthStream)), kKatSynthDeck
end heTestShuffleRun

function heTKatLog pTamper
   -- canned hotseat session, plain-text transcript (binary-free): holes
   -- s1=3d5d s2=Ac5h s3=KcKh, board 3h2h5c4hTc; folds to 442/394/364
   local tLog
   put empty into tLog
   put heLogLine(0, "table", "cfg", "sb=1,bb=2,seats=1|2|3,stacks=400|400|400,button=1") & return after tLog
   put heLogLine(1, "table", "handStart", "seats=1|2|3,button=1") & return after tLog
   put heLogLine(1, "table", "holeDeliver", "seat=1,cards=3d|5d") & return after tLog
   put heLogLine(1, "table", "holeDeliver", "seat=2,cards=Ac|5h") & return after tLog
   put heLogLine(1, "table", "holeDeliver", "seat=3,cards=Kc|Kh") & return after tLog
   put heLogLine(1, "seat2", "bidSB", "amount=1") & return after tLog
   put heLogLine(1, "seat3", "bidBB", "amount=2") & return after tLog
   put heLogLine(1, "seat1", "act", "verb=raise,amount=6") & return after tLog
   put heLogLine(1, "seat2", "act", "verb=call,amount=5") & return after tLog
   if pTamper is "badact" then
      put heLogLine(1, "seat3", "act", "verb=call,amount=7") & return after tLog
   end if
   put heLogLine(1, "seat3", "act", "verb=call,amount=4") & return after tLog
   put heLogLine(1, "table", "board", "street=flop,cards=3h|2h|5c") & return after tLog
   put heLogLine(1, "seat2", "act", "verb=check,amount=0") & return after tLog
   put heLogLine(1, "seat3", "act", "verb=bet,amount=10") & return after tLog
   put heLogLine(1, "seat1", "act", "verb=call,amount=10") & return after tLog
   put heLogLine(1, "seat2", "act", "verb=fold,amount=0") & return after tLog
   put heLogLine(1, "table", "board", "street=turn,cards=4h") & return after tLog
   put heLogLine(1, "seat3", "act", "verb=check,amount=0") & return after tLog
   put heLogLine(1, "seat1", "act", "verb=check,amount=0") & return after tLog
   put heLogLine(1, "table", "board", "street=river,cards=Tc") & return after tLog
   put heLogLine(1, "seat3", "act", "verb=bet,amount=20") & return after tLog
   put heLogLine(1, "seat1", "act", "verb=call,amount=20") & return after tLog
   if pTamper is "settle" then
      put heLogLine(1, "table", "settle", "deltas=1:52|2:-16|3:-36") & return after tLog
   else
      put heLogLine(1, "table", "settle", "deltas=1:42|2:-6|3:-36") & return after tLog
   end if
   return tLog
end heTKatLog

function heTFoldTxt pFoldA
   return pFoldA["stacksBy"][1] & "/" & pFoldA["stacksBy"][2] & "/" & pFoldA["stacksBy"][3] \
         & " hand=" & pFoldA["handNum"] & " errs=[" & pFoldA["errors"] & "]"
end heTFoldTxt

command heTestFoldRun
   local tFoldA, tFoldB
   put return & "-- 4. transcript fold: determinism + replay-as-audit" & return after gRpt
   put heFoldTranscript(heTKatLog(empty)) into tFoldA
   heTAssert "fold: canned session settles to the pinned stacks", \
         heTFoldTxt(tFoldA), "442/394/364 hand=1 errs=[]"
   put heFoldTranscript(heTKatLog(empty)) into tFoldB
   heTAssert "fold: folding twice is identical", heTFoldTxt(tFoldB), heTFoldTxt(tFoldA)
   heTContains "fold: per-hand trace recorded", tFoldA["trace"], "hand 1: 1:42|2:-6|3:-36"
   heTContains "history: board, pot, and winner recorded", tFoldA["history"], \
         "hand 1: board 3h 2h 5c 4h Tc; pot 78; winner seat 1"
   heTContains "history: showdown names the winning hand", tFoldA["history"], "1=3d 5d two pair"
   heTContains "history: settlement marked verified on replay", tFoldA["history"], "settle-verified"
   put heFoldTranscript(heTKatLog("settle")) into tFoldA
   heTContains "history: tampered settle shows MISMATCH not verified", tFoldA["history"], "settle-MISMATCH"
   put heFoldTranscript(heTKatLog("settle")) into tFoldA
   heTContains "fold: tampered settle line is caught", tFoldA["errors"], "settle-mismatch"
   put heFoldTranscript(heTKatLog("badact")) into tFoldA
   heTContains "fold: wrong-amount action rejected on replay", tFoldA["errors"], "engine-rejected"

   -- deep-dive (OXT-pass finding): the online lobby and the hotseat game share
   -- gGame["log"] in two incompatible formats -- a 4-field hotseat line vs a
   -- 10-field signed wire. A hotseat log clobbered by an online create/join folds
   -- to pot 0 / settle-MISMATCH (no hotseat cfg -> no stakes/stacks). heBtnLeave
   -- now starts a fresh hotseat table whenever heLogIsCleanHotseat is false; pin
   -- its recognition of a clean hotseat log vs a wire-led / empty one.
   heTAssert "log: a hotseat cfg-led log is recognized as clean", \
         heLogIsCleanHotseat(heLogLine(0, "table", "cfg", "sb=1,bb=2,ante=0,seats=1|2,stacks=400|400,button=1") \
         & return & heLogLine(1, "table", "handStart", "seats=1|2,button=1")), true
   heTAssert "log: a wire-envelope-led log is NOT a clean hotseat log", \
         heLogIsCleanHotseat("1" & tab & "aa" & tab & "0" & tab & "bb" & tab & "cfg" & tab & "cc" \
         & tab & "dd" & tab & "1" & tab & "ee" & tab & "ff"), false
   heTAssert "log: an empty log is not a clean hotseat log", heLogIsCleanHotseat(empty), false
end heTestFoldRun
