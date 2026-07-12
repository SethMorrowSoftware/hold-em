script "Holdem"
/*
holdem.livecodescript -- serverless no-limit Texas Hold'em for OXT (holde-em).

ONE self-contained, paste-and-run stack: the hotseat game plus its own
self-test harness (call heRunSelftest in the message box). No second stack,
no required extensions to be playable.

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
verified sound by property tests over tens of thousands of configs.

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

constant kHeVersion = "0.4.0"
constant kHeHarnessV = "5"
constant kUIVersion = "3"

-- card contract (mirrored in tools/evaluator-kat.py): index 1..52,
-- index = (rank - 2) * 4 + suit, rank 2..14, suit 1..4 = c,d,h,s
constant kHeRankChars = "23456789TJQKA"
constant kHeSuitChars = "cdhs"

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

-- table defaults
constant kHeDefaultSeats = 6
constant kHeDefaultSB = 1
constant kHeDefaultBB = 2
constant kHeDefaultStack = 400
constant kHeNextHandDelayMs = 3500

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
local gHasSodiumChk    -- cached extension probe ("", "true", "false")
local gHasKitChk
local gUIMode          -- "flat" or "kit"
local gHudDirty        -- HUD repaints only on change, max 4 Hz (playbook)
local gHudTickOn
local gFlipCtxA        -- per-sprite flip context locks (gotcha 19)
local gAnimBusy

--------------------------------------------------------------------------
-- lifecycle (house law H1: sessions bracket the stack's life)
--------------------------------------------------------------------------

on preOpenStack
   set the rect of this stack to kHeStackRect
   set the title of this stack to "holde-em " & kHeVersion
end preOpenStack

on openStack
   heBuildTable
   heTableNew
   heUISetStatus "Welcome to holde-em " & kHeVersion & ". Press Deal to start a hotseat hand."
   put true into gHudTickOn
   send "heHudTick" to me in kHeHudMs milliseconds
end openStack

on closeStack
   local tMsgLine
   put false into gHudTickOn
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

command heDeriveIdentity pSeedData, @rPubData, @rSecData
   -- ed25519 identity from a 32-byte seed (out params, per the real API)
   sxSignKeypairFromSeed pSeedData, rPubData, rSecData
end heDeriveIdentity

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
   local tRpt, tData, tPub, tSec, tSig, tSealed, tOpened, tMsg, tRecPub, tRecSec
   put "SodiumXT probe (holde-em " & kHeVersion & "):" & return into tRpt
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
      heDeriveIdentity heHash32(textEncode("seed", "utf-8")), tPub, tSec
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
   try
      sxBoxKeypairFromSeed heHash32(textEncode("box", "utf-8")), tRecPub, tRecSec
      put sxSeal(tMsg, tRecPub) into tSealed
      put sxSealOpen(tSealed, tRecPub, tRecSec) into tOpened
      if tOpened is tMsg then
         put "  sxSeal + sxSealOpen: ok (sealed-box roundtrip)" & return after tRpt
      else
         put "  sxSeal/Open: roundtrip mismatch" & return after tRpt
      end if
   catch tErr
      put "  sxSeal/sxSealOpen: THREW: " & tErr & return after tRpt
   end try

   put tRpt
   return tRpt
end heProbeSodium

--------------------------------------------------------------------------
-- TorrentXT transport probe. Starts THE session, enables rp1, adds a phantom
-- swarm on a rendezvous id, and reports; tears the session back down so the
-- probe leaks nothing. Confirms the transport surface on-engine.
--------------------------------------------------------------------------

command heProbeTorrent
   local tRpt, tSession, tHash, tHandle
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
      put "  btSetBool enable_dht: ok" & return after tRpt
      btRp1Enable tSession
      put "  btRp1Enable: ok" & return after tRpt
      if heHasSodium() then
         put char 1 to 40 of heHashHex(textEncode("holde-em-probe-table", "utf-8")) into tHash
      else
         put "0123456789abcdef0123456789abcdef01234567" into tHash
      end if
      put btAddInfohash(tSession, tHash, heTempPath()) into tHandle
      put "  btAddInfohash(" & char 1 to 10 of tHash & "...) -> handle " & tHandle & return after tRpt
      btDhtAnnounce tSession, tHash, 0
      put "  btDhtAnnounce: ok (announced rendezvous id)" & return after tRpt
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
-- text, so no tab can ever leak into the frame.
--------------------------------------------------------------------------

constant kHeGenesisPrev = "0000000000000000000000000000000000000000000000000000000000000000"

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
   return textDecode(heHex2BinD(pBodyHex), "utf-8")
end heEnvBodyText

function heEnvVerify pWireLine, pFromPubHex, pHostPubHex, pExpectedPrevHex
   -- spec 6 verify-or-drop: bad sig / unknown from / chain break => dropped
   -- and logged, no exceptions (including from the host). pFromPubHex is the
   -- admitted pubkey the caller expects for this sender ("" to skip that
   -- check); pExpectedPrevHex is the local chain head ("" to skip).
   local tA
   put heEnvWireParse(pWireLine) into tA
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

   -- histogram: sort groups by (count, rank) descending; LiveCode's sort is
   -- stable, so sorting by rank first then by count yields the two-key order
   repeat with tPos = 1 to 5
      put item tPos of tRankList into tRankVal
      if tCountA[tRankVal] is empty then
         put 0 into tCountA[tRankVal]
      end if
      add 1 to tCountA[tRankVal]
   end repeat
   put empty into tGroupLines
   repeat for each key tRankVal in tCountA
      put tCountA[tRankVal] & comma & tRankVal & return after tGroupLines
   end repeat
   delete char -1 of tGroupLines
   sort lines of tGroupLines numeric descending by item 2 of each
   sort lines of tGroupLines numeric descending by item 1 of each
   put empty into tSizes
   put empty into tGRanks
   repeat for each line tOut in tGroupLines
      put item 1 of tOut & comma after tSizes
      put item 2 of tOut & comma after tGRanks
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
   local tSeed
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

function heBetNewHand pSB, pBB, pStacksA, pOccupiedList, pButtonSeat
   local tStateA, tSeatNum, tCount
   set the itemDelimiter to comma
   put pSB into tStateA["sb"]
   put pBB into tStateA["bb"]
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

function heFoldTranscript pLogTxt
   -- pure fold: replay a transcript and RE-DERIVE everything (engine state,
   -- showdown ranks, settlements); logged settle lines are verified against
   -- the recomputation, so replay is also an audit. Returns "stacksBy"
   -- (array), "handNum", "trace" (per-hand deltas lines), "errors" (lines).
   local tOutA, tLogLine, tType, tBodyTxt, tBodyA, tStateA, tHaveHand
   local tSeatNum, tHolesA, tBoardList, tRanksA, tDeltasA, tDeltasTxt
   local tSevenList, tOccList, tButtonSeat, tSB, tBB, tFromTxt, tStacksTxt
   local tPos, tCardTxt, tOneCard
   set the itemDelimiter to comma
   put 0 into tOutA["handNum"]
   put empty into tOutA["trace"]
   put empty into tOutA["errors"]
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

         case "handStart"
            put tBodyTxt into tBodyA
            split tBodyA by comma and "="
            put tBodyA["seats"] into tOccList
            replace "|" with comma in tOccList
            put tBodyA["button"] into tButtonSeat
            put heBetNewHand(tSB, tBB, tOutA["stacksBy"], tOccList, tButtonSeat) into tStateA
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

command heTableNew
   local tSeatNum
   put empty into gGame
   put kHeDefaultSB into gGame["sb"]
   put kHeDefaultBB into gGame["bb"]
   put 0 into gGame["handNum"]
   put 0 into gGame["buttonSeat"]
   put 0 into gGame["lastBB"]
   put "idle" into gGame["phase"]
   put empty into gGame["log"]
   repeat with tSeatNum = 1 to kHeDefaultSeats
      put kHeDefaultStack into gGame["stacksBy"][tSeatNum]
   end repeat
   put heHexId(16) into gGame["tableId"]
   heLogAppend "cfg", "table", heCfgBody()
   heHudMark
end heTableNew

function heCfgBody
   local tSeatsTxt, tStacksTxt, tSeatNum
   put empty into tSeatsTxt
   put empty into tStacksTxt
   repeat with tSeatNum = 1 to kHeDefaultSeats
      put tSeatNum & "|" after tSeatsTxt
      put gGame["stacksBy"][tSeatNum] & "|" after tStacksTxt
   end repeat
   delete char -1 of tSeatsTxt
   delete char -1 of tStacksTxt
   return "sb=" & gGame["sb"] & ",bb=" & gGame["bb"] \
         & ",seats=" & tSeatsTxt & ",stacks=" & tStacksTxt & ",button=1"
end heCfgBody

function heSeatsAlive
   local tOut, tSeatNum
   put empty into tOut
   repeat with tSeatNum = 1 to kHeDefaultSeats
      if gGame["stacksBy"][tSeatNum] > 0 then
         put tSeatNum & comma after tOut
      end if
   end repeat
   delete char -1 of tOut
   return tOut
end heSeatsAlive

command heHandStart
   local tOccList, tSeatNum, tDeckList, tDealA, tHolePair, tHoleNames
   local tSeatsTxt
   set the itemDelimiter to comma
   if gGame["phase"] is "hand" then
      exit heHandStart
   end if
   put heSeatsAlive() into tOccList
   if heCountItems(tOccList) < 2 then
      heUISetStatus "Game over -- one stack left. Starting a fresh table."
      heTableNew
      exit heHandStart
   end if
   add 1 to gGame["handNum"]
   -- dead-button-aware schedule: the big blind advances to the next live seat
   -- each hand, so eliminations never double- or skip-charge a blind
   put heScheduleButton(tOccList, gGame["lastBB"]) into gGame["buttonSeat"]
   put tOccList into gGame["occ"]
   put "hand" into gGame["phase"]

   put tOccList into tSeatsTxt
   replace comma with "|" in tSeatsTxt
   heLogAppend "handStart", "table", "seats=" & tSeatsTxt & ",button=" & gGame["buttonSeat"]

   -- deal from the integer PRNG (binary-free); CSPRNG-seeded when possible
   put heShuffleDeck(heFreshPrngState()) into tDeckList
   put heDealAssign(tDeckList, tOccList, gGame["buttonSeat"]) into tDealA
   put tDeckList into tDealA["deckList"]
   put heCountItems(tOccList) into tDealA["seatCount"]
   put tDealA into gGame["deal"]

   -- hole delivery (hotseat shows all; Phase 2 seals per seat)
   repeat for each item tSeatNum in tOccList
      put tDealA["holesBy"][tSeatNum] into tHolePair
      put heCardName(item 1 of tHolePair) & "|" & heCardName(item 2 of tHolePair) into tHoleNames
      heLogAppend "holeDeliver", "table", "seat=" & tSeatNum & ",cards=" & tHoleNames
   end repeat

   -- blinds through the engine, then the table is live
   put heBetNewHand(gGame["sb"], gGame["bb"], gGame["stacksBy"], tOccList, gGame["buttonSeat"]) into gGame["state"]
   put gGame["state"]["bbSeat"] into gGame["lastBB"]
   heEngineDo "bidSB", gGame["state"]["sbSeat"], min(gGame["sb"], gGame["stacksBy"][gGame["state"]["sbSeat"]])
   heEngineDo "bidBB", gGame["state"]["bbSeat"], min(gGame["bb"], gGame["stacksBy"][gGame["state"]["bbSeat"]])
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
   heUIPromptToAct
end heActionDo

command heReactToNotes
   local tNoteLine, tNotesTxt
   put gGame["state"]["note"] into tNotesTxt
   repeat for each line tNoteLine in tNotesTxt
      set the itemDelimiter to comma
      switch item 1 of tNoteLine
         case "advance:flop"
            heDealBoard "flop"
            break
         case "advance:turn"
            heDealBoard "turn"
            break
         case "advance:river"
            heDealBoard "river"
            break
         case "runout"
            heRunoutBoards
            break
         case "showdown"
            heHandShowdown
            break
         default
            if tNoteLine begins with "foldwin:" then
               heHandShowdown
            end if
      end switch
   end repeat
end heReactToNotes

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

command heRunoutBoards
   -- no more betting possible: deal the remaining streets; the board
   -- messages advance the engine street by street (fold-determinism)
   local tStateA
   repeat forever
      put gGame["state"] into tStateA
      if tStateA["phase"] is not "runout" then
         exit repeat
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
            exit repeat
      end switch
      put heBetApply(gGame["state"], "board", 0, 0) into gGame["state"]
      heReactToNotes
   end repeat
end heRunoutBoards

command heHandShowdown
   -- settle, receipt line, schedule the next hand
   local tStateA, tRanksA, tSeatNum, tSevenList, tDeltasA, tDeltasTxt
   local tDealA, tInHandList, tBoardIdxList
   set the itemDelimiter to comma
   put gGame["state"] into tStateA
   put gGame["deal"] into tDealA
   put heBetInHandList(tStateA) into tInHandList

   put tDealA["flopList"] & comma & tDealA["turnIx"] & comma & tDealA["riverIx"] into tBoardIdxList
   put empty into tRanksA
   if heCountItems(tInHandList) > 1 then
      repeat for each item tSeatNum in tInHandList
         put tDealA["holesBy"][tSeatNum] & comma & tBoardIdxList into tSevenList
         put heEval7(tSevenList) into tRanksA[tSeatNum]
      end repeat
      heUIShowdownReveal tInHandList, tRanksA
   end if
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
   send "heNextHandTick" to me in kHeNextHandDelayMs milliseconds
end heHandShowdown

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
   set the rect of field "heHeader" to "40,10,984,38"
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

   heKitTryInit
   unlock screen
end heBuildTable

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

command heMakeActionButton pBtnName, pLabelTxt, pLeftX
   create button pBtnName
   set the rect of button pBtnName to pLeftX & ",592" & comma & (pLeftX + 76) & ",624"
   set the label of button pBtnName to pLabelTxt
end heMakeActionButton

command heKitTryInit
   local tIdx
   put "flat" into gUIMode
   put 0 into gAnimBusy
   if not heHasKit() then
      exit heKitTryInit
   end if
   if the uHeAtlasPath of this stack is empty then
      exit heKitTryInit
   end if
   if there is not a file (the uHeAtlasPath of this stack) then
      exit heKitTryInit
   end if
   try
      start using stack "box2dxt-kit"
      b2kSheetLoadAtlas "heCards", the uHeAtlasPath of this stack
      repeat with tIdx = 1 to 52
         b2kSheetEnsureIcon "heCards", heCardName(tIdx)
      end repeat
      b2kSheetEnsureIcon "heCards", "back"
      put "kit" into gUIMode
   catch tKitErr
      put "flat" into gUIMode
   end try
end heKitTryInit

on mouseUp
   local tWho, tSeatNum, tAmt
   put the short name of the target into tWho
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
   heEnableBtn "heBtnDeal", (gGame["phase"] is not "hand")
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
   local tSeatNum, tPos
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
constant kKatIdSeed1 = "629a089485b96c24fef651012c8deae57aa438a7a11c81f3e6a99b5e22f83b38"
constant kKatIdSeed2 = "fa645b9f3778a3b162514e3a00436568aef46b726e10ef563c94e73b2c2cb448"
constant kKatIdSeed3 = "7833fb1675dbb196e2222ad6f93ff30aacd313faf7a7818078e30a47f6890083"
constant kKatIdPub1 = "b6ef1a19d789c27bea3f6c127db635929541f34907750ee12d0b715c010c7566"
constant kKatCfgBody = "v=1,level=0,sb=1,bb=2,seats=3,button=1"
constant kKatEnv0ContentHex = "31096535323637353635306437616434386337313239313835656664616563316532623839636334313064386534633865303835626364363532313837623237643309300962366566316131396437383963323762656133663663313237646236333539323935343166333439303737353065653132643062373135633031306337353636096366670937363364333132633663363537363635366333643330326337333632336433313263363236323364333232633733363536313734373333643333326336323735373437343666366533643331"
constant kKatEnv0SenderSig = "c1d5f49bcc0fb8418830f63cc8be9c6bf7e5fd11a77807af38e672aa7284bba9c9cd58d73976888055851d034d440ab504cd0c9ab984f7df368a5f94225b310b"
constant kKatChainHead6 = "62fcd52b3757f590c33bede7330620853074c1e5c153549244a8dac7287e3778"
constant kKatSettleHash = "68095dcf5a74fac1e1340a1073a466dcf117024257f5c265de21698257b34b6f"

command heRunSelftest
   put empty into gRpt
   put 0 into gPassN
   put 0 into gFailN
   put 0 into gSkipN
   put "holde-em self-test  stack v" & kHeVersion & "  harness v" & kHeHarnessV \
         & return & return after gRpt
   heTestEvaluatorRun
   heTestBettingRun
   heTestScheduleRun
   heTestShuffleRun
   heTestFoldRun
   heTestCryptoRun
   put return & heProbeSodium() after gRpt
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

   heDeriveIdentity heHex2BinD(kKatIdSeed1), tPub, tSec
   heTAssert "crypto: ed25519 identity pubkey from seed", heBin2HexS(tPub), kKatIdPub1

   put heEnvContentLine(kKatTableHex, 0, kKatIdPub1, "cfg", kKatCfgBody) into tContent
   heTAssert "crypto: canonical content-line bytes", \
         heBin2HexS(textEncode(tContent, "utf-8")), kKatEnv0ContentHex
   heTAssert "crypto: sender signature over the content line", \
         heEnvSenderSigHex(tContent, tSec), kKatEnv0SenderSig

   -- rebuild the six-envelope hash chain (host relay = identity 1)
   heDeriveIdentity heHex2BinD(kKatIdSeed1), tHostPub, tHostSec
   put kKatIdSeed1 & return & kKatIdSeed1 & return & kKatIdSeed2 & return \
         & kKatIdSeed3 & return & kKatIdSeed2 & return & kKatIdSeed3 into tSenderSeeds
   put "0,1,1,1,1,1" into tHands
   put "cfg,seedCommit,seedCommit,seedCommit,bidSB,bidBB" into tTypes
   put kKatCfgBody & return & kKatCommit1 & return & kKatCommit2 & return \
         & kKatCommit3 & return & "amount=1" & return & "amount=2" into tBodies
   put kHeGenesisPrev into tPrevHex
   repeat with tSeq = 1 to 6
      heDeriveIdentity heHex2BinD(line tSeq of tSenderSeeds), tPub, tSec
      put heEnvContentLine(kKatTableHex, item tSeq of tHands, heBin2HexS(tPub), \
            item tSeq of tTypes, line tSeq of tBodies) into tContent
      put heWireBuild(tContent, tSec, tSeq, tPrevHex, tHostSec) into tWire
      put heHex2BinD(heChainNextHex(tWire)) into tChainData
      put heChainNextHex(tWire) into tPrevHex
   end repeat
   heTAssert "crypto: six-envelope chain head", tPrevHex, kKatChainHead6
   heTAssert "crypto: settlement receipt hash", \
         heSettleHashHex("1:-4,2:8,3:-4", tChainData), kKatSettleHash

   -- verify-or-drop (spec 6): honest wire accepted, tampered body rejected
   heDeriveIdentity heHex2BinD(kKatIdSeed1), tPub, tSec
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
   heDeriveIdentity heHex2BinD(kKatIdSeed2), tHostPub, tHostSec
   heTAssert "crypto: verify drops an unknown sender", \
         heEnvVerify(tWire, heBin2HexS(tHostPub), heBin2HexS(tPub), kHeGenesisPrev), "drop:unknown-from"
   heTAssert "crypto: verify drops a chain break", \
         heEnvVerify(tWire, heBin2HexS(tPub), heBin2HexS(tPub), kKatChainHead6), "drop:chain-break"
end heTestCryptoRun

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
   local tStacksA, tPos, tSeatNum
   set the itemDelimiter to comma
   put 0 into tPos
   repeat for each item tSeatNum in pOccList
      add 1 to tPos
      put item tPos of pStacksList into tStacksA[tSeatNum]
   end repeat
   return heBetNewHand(pSB, pBB, tStacksA, pOccList, pButtonSeat)
end heTNewHand

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

function heTButtonSchedule pLiveList, pLastBB
   -- returns "button,SB,BB" the way the shell schedules a hand, via the pure
   -- heScheduleButton + heBetNewHand derivation
   local tBtn, tStateA, tStacksA, tSeatNum
   set the itemDelimiter to comma
   repeat for each item tSeatNum in pLiveList
      put 100 into tStacksA[tSeatNum]
   end repeat
   put heScheduleButton(pLiveList, pLastBB) into tBtn
   put heBetNewHand(1, 2, tStacksA, pLiveList, tBtn) into tStateA
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
   put heFoldTranscript(heTKatLog("settle")) into tFoldA
   heTContains "fold: tampered settle line is caught", tFoldA["errors"], "settle-mismatch"
   put heFoldTranscript(heTKatLog("badact")) into tFoldA
   heTContains "fold: wrong-amount action rejected on replay", tFoldA["errors"], "engine-rejected"
end heTestFoldRun
