script "Holdem"
/*
holdem.livecodescript -- serverless no-limit Texas Hold'em for OXT (holde-em).

ONE self-contained, paste-and-run stack: the hotseat game plus its own
self-test harness (call heRunSelftest in the message box). No second stack,
no required extensions to be playable.

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

constant kHeVersion = "0.2.0"
constant kHeHarnessV = "3"
constant kUIVersion = "2"

-- card contract (mirrored in tools/evaluator-kat.py): index 1..52,
-- index = (rank - 2) * 4 + suit, rank 2..14, suit 1..4 = c,d,h,s
constant kHeRankChars = "23456789TJQKA"
constant kHeSuitChars = "cdhs"

-- Park-Miller MINSTD: x' = 16807 * x mod (2^31 - 1). 16807 * (2^31-1) is
-- about 3.6e13, well under 2^53, so every step is exact in a double.
constant kHeRngMul = 16807
constant kHeRngMod = 2147483647
constant kHeRngMax = 2147483646

-- table defaults
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
-- SodiumXT: probe + a per-call diagnostic. The GAME never depends on any
-- of this; it exists so the deal can draw CSPRNG entropy when available and
-- so heProbeSodium can pinpoint any FFI-boundary failure on this engine.
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

command heProbeSodium
   -- diagnostic: try each sx* call in its own try and report ok/threw so a
   -- failure names the exact handler. Prints to the message box.
   -- On this engine (confirmed 0.2.0): sxRandomUniform / sxRandomBytes /
   -- sxBin2Hex all work; sxHash THROWS. The playable deal deliberately uses
   -- none of the throwing calls. The sxHash block below discriminates WHY
   -- it throws (input type vs handler vs arity), for the Phase 2 crypto deal.
   local tRpt, tTmp, tData, tEnc
   put "SodiumXT probe (holde-em " & kHeVersion & "):" & return into tRpt

   put "-- primitives the game relies on --" & return after tRpt
   try
      put sxRandomUniform(1000) into tTmp
      put "  sxRandomUniform(1000) -> " & tTmp & "  : ok" & return after tRpt
   catch tErr
      put "  sxRandomUniform: THREW: " & tErr & return after tRpt
   end try
   try
      put sxRandomBytes(8) into tData
      put "  sxRandomBytes(8): ok (" & the number of bytes of tData & " bytes)" & return after tRpt
   catch tErr
      put "  sxRandomBytes: THREW: " & tErr & return after tRpt
   end try
   try
      put sxBin2Hex(sxRandomBytes(8)) into tTmp
      put "  sxBin2Hex(sxRandomBytes(8)) -> " & tTmp & "  : ok" & return after tRpt
   catch tErr
      put "  sxBin2Hex(sxRandomBytes): THREW: " & tErr & return after tRpt
   end try

   put "-- sxHash discriminators (Phase 2 crypto deal) --" & return after tRpt
   -- is textEncode itself the thrower, or sxHash?
   try
      put textEncode("holdem", "UTF-8") into tEnc
      put "  textEncode(text): ok (" & the number of bytes of tEnc & " bytes)" & return after tRpt
   catch tErr
      put "  textEncode: THREW: " & tErr & return after tRpt
   end try
   -- sxHash on raw Data straight from sxRandomBytes (no textEncode in play)
   try
      put sxHash(sxRandomBytes(8)) into tData
      put "  sxHash(sxRandomBytes): ok (" & the number of bytes of tData & " bytes)" & return after tRpt
   catch tErr
      put "  sxHash(sxRandomBytes): THREW: " & tErr & return after tRpt
   end try
   -- sxHash on a plain text argument (some wrappers accept text directly)
   try
      put sxHash("holdem") into tData
      put "  sxHash(plainText): ok (" & the number of bytes of tData & " bytes)" & return after tRpt
   catch tErr
      put "  sxHash(plainText): THREW: " & tErr & return after tRpt
   end try
   -- sxHash with an explicit 32-byte output length (libsodium generichash arity)
   try
      put sxHash(sxRandomBytes(8), 32) into tData
      put "  sxHash(data,32): ok (" & the number of bytes of tData & " bytes)" & return after tRpt
   catch tErr
      put "  sxHash(data,32): THREW: " & tErr & return after tRpt
   end try
   -- if any sxHash form worked, is it a valid hash input to sxBin2Hex?
   try
      put sxBin2Hex(sxHash(sxRandomBytes(8))) into tTmp
      put "  sxBin2Hex(sxHash(data)) -> " & tTmp & "  : ok" & return after tRpt
   catch tErr
      put "  sxBin2Hex(sxHash(data)): THREW: " & tErr & return after tRpt
   end try

   put tRpt
   return tRpt
end heProbeSodium

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

function heNextAliveAfter pSeatNum
   local tTry
   put pSeatNum into tTry
   repeat kHeDefaultSeats times
      put tTry mod kHeDefaultSeats + 1 into tTry
      if gGame["stacksBy"][tTry] > 0 then
         return tTry
      end if
   end repeat
   return pSeatNum
end heNextAliveAfter

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
   if gGame["handNum"] is 1 then
      put item 1 of tOccList into gGame["buttonSeat"]
   else
      put heNextAliveAfter(gGame["buttonSeat"]) into gGame["buttonSeat"]
   end if
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
   local tSeatNum, tSpotTxt, tSpotX, tSpotY, tPos
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

   repeat with tSeatNum = 1 to kHeDefaultSeats
      set the itemDelimiter to ";"
      put item tSeatNum of kHeSeatSpots into tSpotTxt
      set the itemDelimiter to comma
      put item 1 of tSpotTxt into tSpotX
      put item 2 of tSpotTxt into tSpotY
      create field ("heSeatName" & tSeatNum)
      set the rect of field ("heSeatName" & tSeatNum) to \
            (tSpotX - 55) & comma & (tSpotY - 12) & comma & (tSpotX + 55) & comma & (tSpotY + 8)
      set the text of field ("heSeatName" & tSeatNum) to "Seat " & tSeatNum
      set the lockText of field ("heSeatName" & tSeatNum) to true
      create field ("heSeatStack" & tSeatNum)
      set the rect of field ("heSeatStack" & tSeatNum) to \
            (tSpotX - 55) & comma & (tSpotY + 8) & comma & (tSpotX + 55) & comma & (tSpotY + 28)
      set the lockText of field ("heSeatStack" & tSeatNum) to true
      heMakeCardSlot "heHole" & tSeatNum & "a", tSpotX - 26, tSpotY - 46
      heMakeCardSlot "heHole" & tSeatNum & "b", tSpotX + 26, tSpotY - 46
   end repeat

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
         (pCenterX - kHeCardW div 2) & comma & (pCenterY - kHeCardH div 2) & comma \
         & (pCenterX + kHeCardW div 2) & comma & (pCenterY + kHeCardH div 2)
   set the lockText of field pSlotName to true
   set the textAlign of field pSlotName to "center"
   set the textSize of field pSlotName to 16
   set the opaque of field pSlotName to true
   set the backgroundColor of field pSlotName to "255,255,255"
   set the visible of field pSlotName to false
end heMakeCardSlot

command heMakeActionButton pBtnName, pLabelTxt, pLeftX
   create button pBtnName
   set the rect of button pBtnName to pLeftX & ",584" & comma & (pLeftX + 76) & ",616"
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
   local tSeatNum, tPotAmt, tSpotTxt, tSpotX, tSpotY, tHandBy
   if there is not a field "hePot" then
      exit heHudRefresh
   end if
   put 0 into tPotAmt
   repeat with tSeatNum = 1 to kHeDefaultSeats
      put heHandByOf(tSeatNum) into tHandBy
      add tHandBy to tPotAmt
      if gGame["stacksBy"][tSeatNum] is a number then
         set the text of field ("heSeatStack" & tSeatNum) to \
               (gGame["stacksBy"][tSeatNum] - tHandBy) & " chips"
      end if
   end repeat
   set the text of field "hePot" to "Pot: " & tPotAmt
   if gGame["buttonSeat"] > 0 then
      set the itemDelimiter to ";"
      put item gGame["buttonSeat"] of kHeSeatSpots into tSpotTxt
      set the itemDelimiter to comma
      put item 1 of tSpotTxt into tSpotX
      put item 2 of tSpotTxt into tSpotY
      set the loc of graphic "heDealerDisc" to (tSpotX + 66) & comma & (tSpotY - 20)
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
   repeat for each item tSeatNum in gGame["occ"]
      heUIShowHole tSeatNum, tDealA["holesBy"][tSeatNum]
   end repeat
   heUISetStatus "Hand " & gGame["handNum"] & " -- blinds posted."
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

command heRunSelftest
   put empty into gRpt
   put 0 into gPassN
   put 0 into gFailN
   put 0 into gSkipN
   put "holde-em self-test  stack v" & kHeVersion & "  harness v" & kHeHarnessV \
         & return & return after gRpt
   heTestEvaluatorRun
   heTestBettingRun
   heTestShuffleRun
   heTestFoldRun
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
