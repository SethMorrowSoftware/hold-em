script "Holdem"
/*
holdem.livecodescript -- serverless no-limit Texas Hold'em for OXT (holde-em).

Phase 1 (hotseat, spec M0) plus the Phase 2c pure seams: the hand evaluator,
the betting engine with side pots, the Level 0 commit-reveal deal, settlement,
the transcript fold, and the canonical envelope codec are all here and all
pure (values in, values out -- house law H5). The UI shell at the bottom is
self-building in the family style and runs in two modes: "kit" (Box2Dxt Kit
sprites and chips, needs an atlas configured) and "flat" (plain fields, no
dependencies), so the game is exercisable before any art lands.

Every algorithm with a byte-exact contract is pinned by the headless CI KATs
(tools/evaluator-kat.py, tools/protocol-kat.py) and re-checked on-engine by
src/holdem-selftest.livecodescript. Change an algorithm here and the KATs
break loudly -- that is the point.

Everything visual, timed, or extension-touching below is verified statically
and needs an OXT pass. The pure sections are pinned by the KATs.
*/

--------------------------------------------------------------------------
-- constants (all of them up here: gotcha 29 -- a constant used above its
-- declaration silently evaluates to nothing at runtime)
--------------------------------------------------------------------------

constant kHeVersion = "0.1.1"
constant kUIVersion = "1"
constant kHeEnvV = "1"

-- domain-separated, versioned hash prefixes (spec 16); the KATs pin the bytes
constant kHeDomainShuf = "HOLDEM-SHUF-v1|"
constant kHeDomainSeedC = "HOLDEM-SEEDC-v1|"
constant kHeDomainChain = "HOLDEM-CHAIN-v1|"
constant kHeDomainSettle = "HOLDEM-SETL-v1|"
constant kHeDomainSess = "HOLDEM-SESS-v1|"
constant kHeDomainCard = "HOLDEM-CARD-v1|"

-- card contract (mirrored in tools/evaluator-kat.py): index 1..52,
-- index = (rank - 2) * 4 + suit, rank 2..14, suit 1..4 = c,d,h,s
constant kHeRankChars = "23456789TJQKA"
constant kHeSuitChars = "cdhs"

-- 2^32 and friends for the rejection-sampled uniform draw
constant kHeTwo32 = 4294967296

-- table defaults (a signed cfg message overrides these at Phase 2)
constant kHeDefaultSeats = 6
constant kHeDefaultSB = 1
constant kHeDefaultBB = 2
constant kHeDefaultStack = 400
constant kHeNextHandDelayMs = 3500

-- UI geometry (flat mode and kit mode share the layout)
constant kHeStackRect = "0,0,1024,660"
constant kHeFeltRect = "32,40,992,560"
constant kHeSeatSpots = "512,510;190,455;150,240;512,115;874,240;834,455"
constant kHeBoardY = 300
constant kHeBoardX0 = 400
constant kHeBoardDX = 56
constant kHeCardW = 46
constant kHeCardH = 64
constant kHeHudMs = 250
constant kHeDealStaggerMs = 70

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
-- lifecycle (house law H1: sessions bracket the stack's life; Phase 1 has
-- no native sessions yet, but the brackets are where Phase 2 will put them)
--------------------------------------------------------------------------

on preOpenStack
   set the rect of this stack to kHeStackRect
   set the title of this stack to "holde-em " & kHeVersion
end preOpenStack

on openStack
   heBuildTable
   heTableNew
   heUISetStatus "Welcome to holde-em. Press Deal to start a hotseat hand."
   put true into gHudTickOn
   send "heHudTick" to me in kHeHudMs milliseconds
end openStack

on closeStack
   local tMsgLine
   put false into gHudTickOn
   -- cancel only our own timers; pendingMessages lines are id,time,name,target
   repeat for each line tMsgLine in the pendingMessages
      if item 3 of tMsgLine begins with "he" then
         cancel item 1 of tMsgLine
      end if
   end repeat
   -- Phase 2: btStopPolling / btStopSession land here (H1)
   pass closeStack
end closeStack

--------------------------------------------------------------------------
-- extension probes (cached; a missing extension is a mode, not an error)
--------------------------------------------------------------------------

function heHasSodium
   if gHasSodiumChk is empty then
      try
         get sxBin2Hex(textEncode("x", "UTF-8"))
         put "true" into gHasSodiumChk
      catch tProbeErr
         put "false" into gHasSodiumChk
      end try
   end if
   return gHasSodiumChk is "true"
end heHasSodium

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

--------------------------------------------------------------------------
-- small pure utilities
--------------------------------------------------------------------------

function heTwoDigits pNum
   if pNum < 10 then
      return "0" & pNum
   end if
   return pNum
end heTwoDigits

function heBin2Hex pData
   -- lowercase hex. Prefer the native converter: the OXT chunk evaluator
   -- has thrown double/binary conversion errors on FFI-bridged binary
   -- (H6), and sxBin2Hex is proven on-engine (the sodium probe uses it).
   -- The script loop remains as the no-sodium fallback for engine-built
   -- binary (textEncode output and the like).
   local tOut, tPos, tByteVal, tHexPair
   if heHasSodium() then
      return toLower(sxBin2Hex(pData))
   end if
   put empty into tOut
   repeat with tPos = 1 to the number of bytes of pData
      put byteToNum(byte tPos of pData) into tByteVal
      put toLower(baseConvert(tByteVal, 10, 16)) into tHexPair
      if the number of chars of tHexPair is 1 then
         put "0" & tHexPair into tHexPair
      end if
      put tHexPair after tOut
   end repeat
   return tOut
end heBin2Hex

function heHex2Bin pHex
   local tOut, tPos
   if heHasSodium() then
      return sxHex2Bin(pHex)
   end if
   put empty into tOut
   repeat with tPos = 1 to the number of chars of pHex step 2
      put numToByte(baseConvert(char tPos to (tPos + 1) of pHex, 16, 10)) after tOut
   end repeat
   return tOut
end heHex2Bin

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
         return item tPos + 1 of pList
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

function heU32BEBytes pNum
   return numToByte(pNum div 16777216 mod 256) \
         & numToByte(pNum div 65536 mod 256) \
         & numToByte(pNum div 256 mod 256) \
         & numToByte(pNum mod 256)
end heU32BEBytes

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
   local tRankVal, tSuitVal
   put offset(char 1 of pName, kHeRankChars) + 1 into tRankVal
   put offset(char 2 of pName, kHeSuitChars) into tSuitVal
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
-- crypto seams (every SodiumXT call in the game goes through these; the
-- ABI-shape assumptions live in exactly one place for the OXT pass)
--------------------------------------------------------------------------

function heHashData pData
   -- sxHash == BLAKE2b-256 unkeyed (equivalence pinned in the KAT header)
   return sxHash(pData)
end heHashData

function heSignPubFromSeed pSeedData
   -- ASSUMPTION for the OXT pass: sxSignKeypairFromSeed returns an array
   -- with "public" and "secret" keys. The self-test prints what it observes
   -- if this shape is wrong; fix here and only here.
   local tPairA
   put sxSignKeypairFromSeed(pSeedData) into tPairA
   return tPairA["public"]
end heSignPubFromSeed

function heSignSecretFromSeed pSeedData
   local tPairA
   put sxSignKeypairFromSeed(pSeedData) into tPairA
   return tPairA["secret"]
end heSignSecretFromSeed

function heSignDetachedOf pMsgData, pSeedData
   return sxSignDetached(pMsgData, heSignSecretFromSeed(pSeedData))
end heSignDetachedOf

function heFingerprintOf pPubData
   -- short display handle: first 8 hex chars of sxHash(pubkey) (spec 5)
   return char 1 to 8 of heBin2Hex(heHashData(pPubData))
end heFingerprintOf

function heRandomSeedData
   -- dealing randomness law (spec 16): sxRandomBytes or nothing. The
   -- engine-random fallback exists ONLY so a hotseat table on a machine
   -- with no SodiumXT still deals; it is labelled practice entropy in the
   -- UI and never acceptable once anything networked exists.
   local tOut
   if heHasSodium() then
      return sxRandomBytes(32)
   end if
   put empty into tOut
   repeat 32 times
      put numToByte(random(256) - 1) after tOut
   end repeat
   return tOut
end heRandomSeedData

--------------------------------------------------------------------------
-- Level 0 deal: commit-reveal keyed-stream shuffle (spec 7.1, pinned by
-- tools/protocol-kat.py). As of v0.1.1 the whole script side works in
-- HEX TEXT: the OXT chunk evaluator threw double/binary conversion
-- errors on FFI-bridged binary (H6), so seeds and the draw stream travel
-- as hex and raw Data exists only at the sx* boundary. Byte semantics
-- are unchanged -- the KAT-pinned decks and commitments are identical.
--------------------------------------------------------------------------

function heSeedCommitOf pSeedHex
   -- commitment = H("HOLDEM-SEEDC-v1|" || seed bytes); the seed travels
   -- script-side as hex and becomes bytes only at the hash boundary
   return heBin2Hex(heHashData(textEncode(kHeDomainSeedC, "UTF-8") & heHex2Bin(pSeedHex)))
end heSeedCommitOf

function heXorSeedsA pSeedsHexA, pCount
   -- XOR of N 32-byte seeds, done entirely in hex text; returns hex
   local tSeatPos, tPairPos, tAcc, tHexTxt, tOutHex, tPairHex
   put empty into tOutHex
   repeat with tPairPos = 1 to 63 step 2
      put 0 into tAcc
      repeat with tSeatPos = 1 to pCount
         put pSeedsHexA[tSeatPos] into tHexTxt
         put bitXOr(tAcc, baseConvert(char tPairPos to (tPairPos + 1) of tHexTxt, 16, 10)) into tAcc
      end repeat
      put toLower(baseConvert(tAcc, 10, 16)) into tPairHex
      if the number of chars of tPairHex is 1 then
         put "0" & tPairHex into tPairHex
      end if
      put tPairHex after tOutHex
   end repeat
   return tOutHex
end heXorSeedsA

function heStreamKeyOf pTableIdData, pHandNum, pXorHex
   -- H("HOLDEM-SHUF-v1|" || table || "|" || decimal(hand) || "|" || seedsXor)
   return heHashData(textEncode(kHeDomainShuf, "UTF-8") & pTableIdData \
         & textEncode("|" & pHandNum & "|", "UTF-8") & heHex2Bin(pXorHex))
end heStreamKeyOf

function heStreamBlocks pKeyData, pBlockCount
   -- the stream is returned as hex text so the draw below only ever
   -- chunks plain chars (H6)
   local tOut, tBlockPos
   put empty into tOut
   repeat with tBlockPos = 0 to pBlockCount - 1
      put heBin2Hex(heHashData(pKeyData & heU32BEBytes(tBlockPos))) after tOut
   end repeat
   return tOut
end heStreamBlocks

function heDrawUniform pStreamHex, pOffset, pRangeN
   -- uniform 1..pRangeN via 32-bit big-endian words read as 8 hex chars,
   -- rejection sampled (no modulo bias). pOffset is a char position into
   -- the hex stream; returns "value,nextOffset". The word is assembled
   -- from two 16-bit halves: baseConvert's 32-bit signedness is not a
   -- documented contract, and 16-bit halves are unambiguous everywhere.
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

function heShuffleFromStream pStreamHex
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
end heShuffleFromStream

function heDeckFromStreamKey pKeyData
   -- 16 blocks (1024 hex chars) covers 51 draws with ~77 words of
   -- rejection slack; the stream is conceptually infinite, so extend on
   -- the astronomically-unlikely exhaustion rather than fail
   local tBlockCount, tDeckList
   put 16 into tBlockCount
   repeat forever
      try
         put heShuffleFromStream(heStreamBlocks(pKeyData, tBlockCount)) into tDeckList
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

function heDealAssign pDeckList, pOccupiedList, pButtonSeat
   -- fixed public consumption order (spec 7.3, adopted at every level):
   -- one card per occupied seat starting left of the button, two rounds,
   -- then burn, flop x3, burn, turn, burn, river
   local tOrder, tPos, tSeatNum, tOutA, tRound
   set the itemDelimiter to comma
   put heRotateAfter(pOccupiedList, pButtonSeat) into tOrder
   put 0 into tPos
   repeat with tRound = 1 to 2
      repeat for each item tSeatNum in tOrder
         add 1 to tPos
         if tOutA["holesBy"][tSeatNum] is empty then
            put item tPos of pDeckList into tOutA["holesBy"][tSeatNum]
         else
            put comma & item tPos of pDeckList after tOutA["holesBy"][tSeatNum]
         end if
      end repeat
   end repeat
   put item (tPos + 1) of pDeckList into tOutA["burnsList"]
   put item (tPos + 2) to (tPos + 4) of pDeckList into tOutA["flopList"]
   put comma & item (tPos + 5) of pDeckList after tOutA["burnsList"]
   put item (tPos + 6) of pDeckList into tOutA["turnIx"]
   put comma & item (tPos + 7) of pDeckList after tOutA["burnsList"]
   put item (tPos + 8) of pDeckList into tOutA["riverIx"]
   return tOutA
end heDealAssign

function heAuditHand pTableIdData, pHandNum, pSeedsHexA, pCommitsA, pCount, pDealA, pOccupiedList, pButtonSeat
   -- end-of-hand audit (spec 7.1 step 5): recompute everything from the
   -- revealed seeds (hex, per H6) and name the first failing step.
   -- Returns "pass" or "fail:<step>". Needs SodiumXT (hashing).
   local tSeatPos, tKeyData, tDeckList, tCheckA, tSeatNum
   set the itemDelimiter to comma
   repeat with tSeatPos = 1 to pCount
      if heSeedCommitOf(pSeedsHexA[tSeatPos]) is not pCommitsA[tSeatPos] then
         return "fail:commit-mismatch-position-" & tSeatPos
      end if
   end repeat
   put heStreamKeyOf(pTableIdData, pHandNum, heXorSeedsA(pSeedsHexA, pCount)) into tKeyData
   put heDeckFromStreamKey(tKeyData) into tDeckList
   put heDealAssign(tDeckList, pOccupiedList, pButtonSeat) into tCheckA
   repeat for each item tSeatNum in pOccupiedList
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
end heAuditHand

--------------------------------------------------------------------------
-- canonical envelope + hash chain (spec 6, layered signatures; byte-pinned
-- by tools/protocol-kat.py). A sender cannot know seq/prev under a relay
-- that assigns ordering, so the sender signs the content line and the host
-- signs the sequenced envelope:
--   contentLine = v TAB tableHex TAB hand TAB fromHex TAB type TAB bodyHex
--   envLine     = contentLine TAB senderSigHex TAB seq TAB prevHex
--   wire        = envLine TAB hostSigHex
--   chainHead   = sxHash("HOLDEM-CHAIN-v1|" || wire); genesis prev = 32 zero bytes
--------------------------------------------------------------------------

function heEnvContentLine pTableHex, pHandNum, pFromTxt, pTypeTxt, pBodyTxt
   return kHeEnvV & tab & pTableHex & tab & pHandNum & tab & pFromTxt \
         & tab & pTypeTxt & tab & heBin2Hex(textEncode(pBodyTxt, "UTF-8"))
end heEnvContentLine

function heEnvParse pContentLine
   local tOutA
   set the itemDelimiter to tab
   put item 1 of pContentLine into tOutA["v"]
   put item 2 of pContentLine into tOutA["table"]
   put item 3 of pContentLine into tOutA["hand"]
   put item 4 of pContentLine into tOutA["from"]
   put item 5 of pContentLine into tOutA["type"]
   put textDecode(heHex2Bin(item 6 of pContentLine), "UTF-8") into tOutA["body"]
   return tOutA
end heEnvParse

function heWireBuild pContentLine, pSenderSeedData, pSeqNum, pPrevHex, pHostSeedData
   -- Phase 2 sending path and the on-engine KAT both use this
   local tSenderSig, tEnvLine, tHostSig
   put heBin2Hex(heSignDetachedOf(textEncode(pContentLine, "UTF-8"), pSenderSeedData)) into tSenderSig
   put pContentLine & tab & tSenderSig & tab & pSeqNum & tab & pPrevHex into tEnvLine
   put heBin2Hex(heSignDetachedOf(textEncode(tEnvLine, "UTF-8"), pHostSeedData)) into tHostSig
   return tEnvLine & tab & tHostSig
end heWireBuild

function heChainNextOf pWireLine
   return heHashData(textEncode(kHeDomainChain & pWireLine, "UTF-8"))
end heChainNextOf

function heSettleHashOf pDeltasCSV, pChainHeadData
   return heBin2Hex(heHashData(textEncode(kHeDomainSettle & pDeltasCSV & "|", "UTF-8") & pChainHeadData))
end heSettleHashOf

--------------------------------------------------------------------------
-- betting engine (spec 8.1) -- a pure state machine over transcript-shaped
-- messages. State travels as an array; heBetApply returns the next state
-- with "err" set (state otherwise unchanged) on any illegal message, and
-- "note" carrying events the shell reacts to ("advance:flop", "runout",
-- "showdown", "foldwin:3").
--
-- State keys: sb bb occ buttonSeat street phase toAct betCur raiseFull
-- aggressor sdFirst err note, and per seat: stackBy streetBy handBy
-- foldedBy allinBy actedBy. "actedBy" means "has acted since the last FULL
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

function heBetCloseStreet pStateA
   -- action closed: reset street bookkeeping and advance, or hand over
   local tStateA, tSeatNum, tInHand
   set the itemDelimiter to comma
   put pStateA into tStateA
   put heBetInHandList(tStateA) into tInHand
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
      -- nobody left who can bet: the board runs out with no more action;
      -- board messages advance the street from here (fold-determinism)
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
   -- THE transition function: every blind, action, and board message --
   -- live play and transcript replay both come through here (plan 1b)
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
         -- fall through to the verb handling below this switch
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
-- button (pinned here, tested in the harness).
--------------------------------------------------------------------------

function heSettleOf pStateA, pRanksA
   -- pRanksA[seat] = heEval7 packed string for every unfolded seat (may be
   -- empty when only one seat remains). Returns deltasA[seat] plus a
   -- "note" key of human-readable pot lines.
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
         -- defensively unreachable (the max committed seat can never have
         -- folded facing nothing); return the layer to its contributors
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
-- transcript (spec 6) -- hotseat actions are appended to a local log and
-- folded, exactly as network messages will be (the Phase 2 seam, plan 1b).
-- Hotseat content lines are unsigned; Phase 2 wraps them in heWireBuild.
--------------------------------------------------------------------------

command heLogAppend pTypeTxt, pFromTxt, pBodyTxt
   local tContentLine
   put heEnvContentLine(gGame["tableHex"], gGame["handNum"], pFromTxt, pTypeTxt, pBodyTxt) into tContentLine
   put tContentLine & return after gGame["log"]
   if heHasSodium() then
      put heChainNextOf(tContentLine) into gGame["chainHeadData"]
   end if
end heLogAppend

function heFoldTranscript pLogTxt
   -- pure fold: replay a transcript from nothing and RE-DERIVE everything
   -- (engine states, showdown ranks, settlements); logged settle lines are
   -- verified against the recomputation, so replay is also an audit.
   -- Returns: "stacksBy" (array), "handNum", "trace" (per-hand deltas
   -- lines), "errors" (lines).
   local tOutA, tEnvA, tLogLine, tBodyA, tStateA, tHaveHand, tSeatNum
   local tHolesA, tBoardList, tRanksA, tDeltasA, tDeltasTxt, tSevenList
   local tOccList, tButtonSeat, tSB, tBB, tHandNum, tSeedsHexA, tCommitsA
   local tVerb, tAmt, tCardTxt, tPos, tOneCard, tFromTxt, tStacksTxt
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
      put heEnvParse(tLogLine) into tEnvA
      set the itemDelimiter to comma

      switch tEnvA["type"]

         case "cfg"
            put tEnvA["body"] into tBodyA
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

         case "seedCommit"
            if tEnvA["hand"] > tOutA["handNum"] then
               -- first message of a new hand: open it (button rotates among
               -- seats that still have chips; hand 1 uses the cfg button)
               put tEnvA["hand"] into tHandNum
               put tHandNum into tOutA["handNum"]
               if tHandNum > 1 then
                  put heFoldNextButton(tOutA, tOccList, tButtonSeat) into tButtonSeat
               end if
               put heFoldOccNow(tOutA, tOccList) into tOccList
               put heBetNewHand(tSB, tBB, tOutA["stacksBy"], tOccList, tButtonSeat) into tStateA
               put "true" into tHaveHand
               put empty into tHolesA
               put empty into tBoardList
               put empty into tRanksA
               put empty into tSeedsHexA
               put empty into tCommitsA
            end if
            put tEnvA["body"] into tCommitsA[tEnvA["from"]]
            break

         case "holeDeliver"
            put tEnvA["body"] into tBodyA
            split tBodyA by comma and "="
            put tBodyA["cards"] into tCardTxt
            replace "|" with comma in tCardTxt
            put heCardIndex(item 1 of tCardTxt) & comma & heCardIndex(item 2 of tCardTxt) \
                  into tHolesA[tBodyA["seat"]]
            break

         case "board"
            put tEnvA["body"] into tBodyA
            split tBodyA by comma and "="
            put tBodyA["cards"] into tCardTxt
            replace "|" with comma in tCardTxt
            repeat for each item tOneCard in tCardTxt
               if tBoardList is empty then
                  put heCardIndex(tOneCard) into tBoardList
               else
                  put comma & heCardIndex(tOneCard) after tBoardList
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
            put tEnvA["body"] into tBodyA
            split tBodyA by comma and "="
            put tEnvA["from"] into tFromTxt
            put char 5 to -1 of tFromTxt into tSeatNum
            if tEnvA["type"] is "act" then
               put heBetApply(tStateA, "act", tSeatNum, tBodyA["verb"] & comma & tBodyA["amount"]) into tStateA
            else
               put heBetApply(tStateA, tEnvA["type"], tSeatNum, tBodyA["amount"]) into tStateA
            end if
            if tStateA["err"] is not empty then
               put "engine-rejected:" & tStateA["err"] & return after tOutA["errors"]
            end if
            break

         case "seedReveal"
            put tEnvA["body"] into tBodyA
            split tBodyA by comma and "="
            put tBodyA["seed"] into tSeedsHexA[tBodyA["seat"]]
            break

         case "settle"
            -- recompute the settlement and verify the logged one matches
            put tEnvA["body"] into tBodyA
            split tBodyA by comma and "="
            put empty into tRanksA
            repeat for each item tSeatNum in heBetInHandList(tStateA)
               if heCountItems(heBetInHandList(tStateA)) > 1 then
                  put tHolesA[tSeatNum] & comma & tBoardList into tSevenList
                  put heEval7(tSevenList) into tRanksA[tSeatNum]
               end if
            end repeat
            put heSettleOf(tStateA, tRanksA) into tDeltasA
            put empty into tDeltasTxt
            repeat for each item tSeatNum in tStateA["occ"]
               put tSeatNum & ":" & tDeltasA[tSeatNum] & "|" after tDeltasTxt
            end repeat
            delete char -1 of tDeltasTxt
            if tBodyA["deltas"] is not tDeltasTxt then
               put "settle-mismatch-hand-" & tEnvA["hand"] & ":logged=" & tBodyA["deltas"] \
                     & ":computed=" & tDeltasTxt & return after tOutA["errors"]
            end if
            repeat for each item tSeatNum in tStateA["occ"]
               add tDeltasA[tSeatNum] to tOutA["stacksBy"][tSeatNum]
            end repeat
            put "hand " & tEnvA["hand"] & ": " & tDeltasTxt & return after tOutA["trace"]
            put "false" into tHaveHand
            break

         case "audit"
         case "chat"
            break

      end switch
   end repeat
   return tOutA
end heFoldTranscript

function heFoldNextButton pOutA, pOccList, pPrevButton
   -- the button moves to the next seat that still has chips
   local tOrder, tSeatNum
   set the itemDelimiter to comma
   put heRotateAfter(pOccList, pPrevButton) into tOrder
   repeat for each item tSeatNum in tOrder
      if pOutA["stacksBy"][tSeatNum] > 0 then
         return tSeatNum
      end if
   end repeat
   return pPrevButton
end heFoldNextButton

function heFoldOccNow pOutA, pOccList
   local tOut, tSeatNum
   set the itemDelimiter to comma
   put empty into tOut
   repeat for each item tSeatNum in pOccList
      if pOutA["stacksBy"][tSeatNum] > 0 then
         put tSeatNum & comma after tOut
      end if
   end repeat
   delete char -1 of tOut
   return tOut
end heFoldOccNow

--------------------------------------------------------------------------
-- hotseat shell -- the impure layer: owns gGame, appends to the log FIRST
-- through the engine (only accepted messages are logged), reacts to notes
--------------------------------------------------------------------------

command heTableNew
   local tSeatNum
   put empty into gGame
   put kHeDefaultSB into gGame["sb"]
   put kHeDefaultBB into gGame["bb"]
   put 0 into gGame["handNum"]
   put 0 into gGame["buttonSeat"]
   put "idle" into gGame["phase"]
   put empty into gGame["log"]
   put empty into gGame["chainHeadData"]
   put 0 into gGame["level"]
   repeat with tSeatNum = 1 to kHeDefaultSeats
      put kHeDefaultStack into gGame["stacksBy"][tSeatNum]
   end repeat
   if heHasSodium() then
      put sxRandomBytes(32) into gGame["tableIdData"]
   else
      put heRandomSeedData() into gGame["tableIdData"]
   end if
   put heBin2Hex(gGame["tableIdData"]) into gGame["tableHex"]
   -- cfg is message zero (spec 6)
   put 0 into gGame["handNum"]
   heLogAppend "cfg", "seat0", heCfgBody()
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
   return "v=1,level=" & gGame["level"] & ",sb=" & gGame["sb"] & ",bb=" & gGame["bb"] \
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
   local tOccList, tSeatNum, tSeedsA, tCommitsA, tXorHex, tKeyData, tPos
   local tDeckList, tDealA, tHoleNames, tCount, tSeatPos, tHolePair
   set the itemDelimiter to comma
   if gGame["phase"] is "hand" then
      exit heHandStart
   end if
   put heSeatsAlive() into tOccList
   if heCountItems(tOccList) < 2 then
      heUISetStatus "Game over -- one stack left. Press Deal for a fresh table."
      heTableNew
      exit heHandStart
   end if
   add 1 to gGame["handNum"]
   if gGame["handNum"] is 1 then
      put item 1 of tOccList into gGame["buttonSeat"]
   else
      put heNextAliveAfter(gGame["buttonSeat"]) into gGame["buttonSeat"]
   end if
   put tOccList into gGame["occ"]
   put "hand" into gGame["phase"]

   -- Level 0 deal, step 1-3 (spec 7.1): commit, (locally) share, shuffle.
   -- In hotseat every seat is this machine, so the sealed-box hop is a
   -- no-op; the commit-reveal code path still runs for real so the audit
   -- audits something real. Seeds travel as hex (H6); fixedSeedsA (the
   -- harness seam) holds hex too.
   put 0 into tPos
   repeat for each item tSeatNum in tOccList
      add 1 to tPos
      if gGame["fixedSeedsA"][tSeatNum] is not empty then
         put gGame["fixedSeedsA"][tSeatNum] into tSeedsA[tPos]
      else
         put heBin2Hex(heRandomSeedData()) into tSeedsA[tPos]
      end if
      if heHasSodium() then
         put heSeedCommitOf(tSeedsA[tPos]) into tCommitsA[tPos]
      else
         put "nocrypto" into tCommitsA[tPos]
      end if
      heLogAppend "seedCommit", "seat" & tSeatNum, tCommitsA[tPos]
   end repeat
   put heCountItems(tOccList) into tCount
   if heHasSodium() then
      put heXorSeedsA(tSeedsA, tCount) into tXorHex
      put heStreamKeyOf(gGame["tableIdData"], gGame["handNum"], tXorHex) into tKeyData
      put heDeckFromStreamKey(tKeyData) into tDeckList
   else
      -- practice-entropy fallback: still a uniform Fisher-Yates, loudly
      -- non-cryptographic (see heRandomSeedData)
      put heShuffleFromStream(hePracticeStream()) into tDeckList
   end if
   put heDealAssign(tDeckList, tOccList, gGame["buttonSeat"]) into tDealA
   put tDeckList into tDealA["deckList"]
   put tCount into tDealA["seatCount"]
   repeat with tSeatPos = 1 to tCount
      put tSeedsA[tSeatPos] into tDealA["seedsA"][tSeatPos]
      put tCommitsA[tSeatPos] into tDealA["commitsA"][tSeatPos]
   end repeat
   put tDealA into gGame["deal"]

   -- step 4: hole delivery (hotseat: plain body; Phase 2 seals per seat)
   repeat for each item tSeatNum in tOccList
      put tDealA["holesBy"][tSeatNum] into tHolePair
      put heCardName(item 1 of tHolePair) & "|" \
            & heCardName(item 2 of tHolePair) into tHoleNames
      heLogAppend "holeDeliver", "seat" & gGame["buttonSeat"], "seat=" & tSeatNum & ",cards=" & tHoleNames
   end repeat

   -- blinds through the engine, then the table is live
   put heBetNewHand(gGame["sb"], gGame["bb"], gGame["stacksBy"], tOccList, gGame["buttonSeat"]) into gGame["state"]
   heEngineDo "bidSB", gGame["state"]["sbSeat"], min(gGame["sb"], gGame["stacksBy"][gGame["state"]["sbSeat"]])
   heEngineDo "bidBB", gGame["state"]["bbSeat"], min(gGame["bb"], gGame["stacksBy"][gGame["state"]["bbSeat"]])
   heUIHandStart
   heHudMark
   heUIPromptToAct
end heHandStart

function heNextAliveAfter pSeatNum
   local tSeatNum, tTry
   put pSeatNum into tTry
   repeat kHeDefaultSeats times
      put tTry mod kHeDefaultSeats + 1 into tTry
      if gGame["stacksBy"][tTry] > 0 then
         return tTry
      end if
   end repeat
   return pSeatNum
end heNextAliveAfter

function hePracticeStream
   -- 1024 hex chars = the same 512 stream bytes, already in the hex form
   -- the draw consumes (H6); practice entropy only, never networked
   local tOut
   put empty into tOut
   repeat 1024 times
      put char random(16) of "0123456789abcdef" after tOut
   end repeat
   return tOut
end hePracticeStream

command heEngineDo pMsgType, pSeatNum, pAmount
   -- one gate for every state transition: apply, then log ONLY if accepted
   local tStateA, tBodyTxt, tVerb
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
   heLogAppend "board", "seat" & gGame["buttonSeat"], "street=" & pStreetName & ",cards=" & tCardsTxt
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
   -- settle, reveal seeds, audit, receipt line, schedule the next hand
   local tStateA, tRanksA, tSeatNum, tSevenList, tDeltasA, tDeltasTxt
   local tDealA, tInHandList, tAuditTxt, tBoardIdxList, tSettleBody, tSeatPos
   local tOccList
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

   -- step 5 (spec 7.1): reveal, audit, and log the result (seeds are hex)
   put tStateA["occ"] into tOccList
   repeat with tSeatPos = 1 to tDealA["seatCount"]
      put item tSeatPos of tOccList into tSeatNum
      heLogAppend "seedReveal", "seat" & tSeatNum, \
            "seat=" & tSeatNum & ",seed=" & tDealA["seedsA"][tSeatPos]
   end repeat
   if heHasSodium() then
      put heAuditHand(gGame["tableIdData"], gGame["handNum"], tDealA["seedsA"], \
            tDealA["commitsA"], tDealA["seatCount"], tDealA, tStateA["occ"], \
            tStateA["buttonSeat"]) into tAuditTxt
   else
      put "skipped-no-sodium" into tAuditTxt
   end if
   heLogAppend "audit", "seat" & gGame["buttonSeat"], "result=" & tAuditTxt

   put "deltas=" & tDeltasTxt into tSettleBody
   if heHasSodium() then
      put ",hash=" & heSettleHashOf(tDeltasTxt, gGame["chainHeadData"]) after tSettleBody
   end if
   heLogAppend "settle", "seat" & gGame["buttonSeat"], tSettleBody

   put "between" into gGame["phase"]
   heUISetStatus "Hand " & gGame["handNum"] & " settled: " & tDeltasTxt \
         & ". Audit: " & tAuditTxt
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
-- UI: self-building chrome (family pattern -- script-only stacks carry no
-- controls, so everything is created at open and tagged with kUIVersion).
-- Two modes: "kit" needs Box2Dxt Kit + an atlas path in the stack custom
-- property uHeAtlasPath; "flat" is pure fields and always works.
-- ALL of this section: verified statically; needs an OXT pass.
--------------------------------------------------------------------------

command heBuildTable
   local tSeatNum, tSpotTxt, tSpotX, tSpotY, tPos
   -- create targets the defaultStack, which is not guaranteed to be us
   -- during openStack in a multi-stack IDE session
   set the defaultStack to the short name of this stack
   if there is a graphic "heFelt" and the uHeUIVersion of this stack is kUIVersion then
      exit heBuildTable
   end if
   lock screen
   heWipeChrome
   set the uHeUIVersion of this stack to kUIVersion

   create graphic "heFelt"
   set the style of graphic "heFelt" to "roundrect"
   set the roundRadius of graphic "heFelt" to 48
   set the rect of graphic "heFelt" to kHeFeltRect
   set the backgroundColor of graphic "heFelt" to "20,90,50"
   set the opaque of graphic "heFelt" to true

   -- six seat plates: name + stack + two hole-card slots each
   repeat with tSeatNum = 1 to kHeDefaultSeats
      set the itemDelimiter to ";"
      put item tSeatNum of kHeSeatSpots into tSpotTxt
      set the itemDelimiter to comma
      put item 1 of tSpotTxt into tSpotX
      put item 2 of tSpotTxt into tSpotY
      create field ("heSeatName" & tSeatNum)
      set the rect of field ("heSeatName" & tSeatNum) to \
            tSpotX - 55 & comma & tSpotY - 12 & comma & tSpotX + 55 & comma & tSpotY + 8
      set the text of field ("heSeatName" & tSeatNum) to "Seat " & tSeatNum
      set the lockText of field ("heSeatName" & tSeatNum) to true
      create field ("heSeatStack" & tSeatNum)
      set the rect of field ("heSeatStack" & tSeatNum) to \
            tSpotX - 55 & comma & tSpotY + 8 & comma & tSpotX + 55 & comma & tSpotY + 28
      set the lockText of field ("heSeatStack" & tSeatNum) to true
      heMakeCardSlot "heHole" & tSeatNum & "a", tSpotX - 26, tSpotY - 46
      heMakeCardSlot "heHole" & tSeatNum & "b", tSpotX + 26, tSpotY - 46
   end repeat

   -- board slots
   repeat with tPos = 1 to 5
      heMakeCardSlot "heBoard" & tPos, kHeBoardX0 + (tPos - 1) * kHeBoardDX, kHeBoardY
   end repeat

   create field "hePot"
   set the rect of field "hePot" to "432,340,592,364"
   set the lockText of field "hePot" to true

   create graphic "heDealerDisc"
   set the style of graphic "heDealerDisc" to "oval"
   set the rect of graphic "heDealerDisc" to "0,0,22,22"
   set the backgroundColor of graphic "heDealerDisc" to "250,250,220"
   set the opaque of graphic "heDealerDisc" to true

   create field "heStatus"
   set the rect of field "heStatus" to "32,620,760,654"
   set the lockText of field "heStatus" to true

   heMakeActionButton "heBtnDeal", "Deal", 780
   heMakeActionButton "heBtnFold", "Fold", 40
   heMakeActionButton "heBtnCheck", "Check", 120
   heMakeActionButton "heBtnCall", "Call", 200
   heMakeActionButton "heBtnBet", "Bet", 280
   heMakeActionButton "heBtnRaise", "Raise", 360
   heMakeActionButton "heBtnAllin", "All-in", 440
   create field "heAmount"
   set the rect of field "heAmount" to "524,588,600,612"
   set the text of field "heAmount" to "0"

   heKitTryInit
   unlock screen
end heBuildTable

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
         pCenterX - kHeCardW div 2 & comma & pCenterY - kHeCardH div 2 & comma \
         & pCenterX + kHeCardW div 2 & comma & pCenterY + kHeCardH div 2
   set the lockText of field pSlotName to true
   set the textAlign of field pSlotName to "center"
   set the textSize of field pSlotName to 16
   set the opaque of field pSlotName to true
   set the backgroundColor of field pSlotName to "255,255,255"
   set the visible of field pSlotName to false
end heMakeCardSlot

command heMakeActionButton pBtnName, pLabelTxt, pLeftX
   create button pBtnName
   set the rect of button pBtnName to pLeftX & ",584" & comma & pLeftX + 76 & ",616"
   set the label of button pBtnName to pLabelTxt
end heMakeActionButton

command heKitTryInit
   -- kit mode is strictly additive: no atlas, no kit, no problem -- flat
   -- mode keeps the game playable. Pool-at-build + pre-warm per playbook.
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
      -- pre-warm every face that can appear (the ~250 ms lazy-slice hitch
      -- landing on the river flip is the one unforgivable jank)
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
   -- one dispatcher, no per-control scripts (message path does the work)
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

command heUISetStatus pTxt
   if there is a field "heStatus" then
      set the text of field "heStatus" to pTxt
   end if
end heUISetStatus

command heUIPromptToAct
   local tSeatNum, tLegalTxt
   if gGame["phase"] is not "hand" then
      exit heUIPromptToAct
   end if
   put gGame["state"]["toAct"] into tSeatNum
   if tSeatNum is 0 then
      exit heUIPromptToAct
   end if
   put heBetLegal(gGame["state"], tSeatNum) into tLegalTxt
   replace return with " / " in tLegalTxt
   heUISetStatus "Seat " & tSeatNum & " to act (" & gGame["state"]["street"] & "): " & tLegalTxt
end heUIPromptToAct

command heHudMark
   put true into gHudDirty
end heHudMark

on heHudTick
   -- HUD refresh at 4 Hz max, and only on change (playbook law)
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
   local tSeatNum, tPotAmt, tSpotTxt, tSpotX, tSpotY
   if there is not a field "hePot" then
      exit heHudRefresh
   end if
   put 0 into tPotAmt
   repeat with tSeatNum = 1 to kHeDefaultSeats
      if gGame["state"]["handBy"][tSeatNum] is a number then
         add gGame["state"]["handBy"][tSeatNum] to tPotAmt
      end if
      if gGame["stacksBy"][tSeatNum] is a number then
         set the text of field ("heSeatStack" & tSeatNum) to gGame["stacksBy"][tSeatNum] - \
               heHandByOf(tSeatNum) & " chips"
      end if
   end repeat
   set the text of field "hePot" to "Pot: " & tPotAmt
   if gGame["buttonSeat"] > 0 then
      set the itemDelimiter to ";"
      put item gGame["buttonSeat"] of kHeSeatSpots into tSpotTxt
      set the itemDelimiter to comma
      put item 1 of tSpotTxt into tSpotX
      put item 2 of tSpotTxt into tSpotY
      set the loc of graphic "heDealerDisc" to tSpotX + 66 & comma & tSpotY - 20
   end if
end heHudRefresh

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
   -- hotseat shows every hole face-up; staggered slides in kit mode
   repeat for each item tSeatNum in gGame["occ"]
      heUIShowHole tSeatNum, tDealA["holesBy"][tSeatNum]
   end repeat
   heUISetStatus "Hand " & gGame["handNum"] & " -- blinds posted."
end heUIHandStart

command heUIShowHole pSeatNum, pIdxPair
   local tSlotName
   set the itemDelimiter to comma
   put "heHole" & pSeatNum & "a" into tSlotName
   heUIShowCardIn tSlotName, item 1 of pIdxPair
   put "heHole" & pSeatNum & "b" into tSlotName
   heUIShowCardIn tSlotName, item 2 of pIdxPair
end heUIShowHole

command heUIShowCardIn pSlotName, pIdx
   -- flat mode: face text in the slot field; kit mode: sprite frame swap +
   -- squash-flip is layered on during the OXT pass (gotchas 19/23/27)
   if there is not a field pSlotName then
      exit heUIShowCardIn
   end if
   set the text of field pSlotName to heCardName(pIdx)
   if heCardSuitVal(pIdx) is 2 or heCardSuitVal(pIdx) is 3 then
      set the textColor of field pSlotName to "200,30,30"
   else
      set the textColor of field pSlotName to "20,20,20"
   end if
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
   local tSeatNum, tTxt
   set the itemDelimiter to comma
   put "Showdown: " into tTxt
   repeat for each item tSeatNum in heShowdownOrderOf(gGame["state"])
      put "seat " & tSeatNum & " (" & pRanksA[tSeatNum] & ") " after tTxt
   end repeat
   heUISetStatus tTxt
end heUIShowdownReveal

command heUIClearCards
   local tSeatNum, tPos
   repeat with tSeatNum = 1 to kHeDefaultSeats
      if there is a field ("heHole" & tSeatNum & "a") then
         set the visible of field ("heHole" & tSeatNum & "a") to false
         set the visible of field ("heHole" & tSeatNum & "b") to false
      end if
   end repeat
   repeat with tPos = 1 to 5
      if there is a field ("heBoard" & tPos) then
         set the visible of field ("heBoard" & tPos) to false
      end if
   end repeat
end heUIClearCards

on b2kFrame
   -- idle cost is one compare (playbook); kit-mode animations land here
   -- during the OXT pass
   if gAnimBusy > 0 then
      -- reserved: deal-slide / flip chaining bookkeeping
   end if
end b2kFrame

on b2kSpriteOnFinish pSpriteId
   -- one-shots fire for whoever started them (gotcha 19): every flip
   -- sequence must gate on its own context lock before chaining
   if gFlipCtxA[pSpriteId] is empty then
      exit b2kSpriteOnFinish
   end if
   -- reserved: face swap + edge->flat second half of the squash flip
   put empty into gFlipCtxA[pSpriteId]
end b2kSpriteOnFinish
