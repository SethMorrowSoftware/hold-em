#!/usr/bin/env python3
"""Known-answer cases for the betting engine + settlement (spec 8.1, 8.3).

A faithful Python mirror of the pure xTalk state machine in
``src/holdem.livecodescript`` (heBetNewHand / heBetApply / heSettleOf /
heShowdownOrderOf): same state keys, same error strings, same notes, same
transitions, ported line-for-line so a rules bug shows up in CI instead of on
an OXT pass. The self-test harness runs these exact scenarios on-engine and
must observe these exact outcomes.

The rules pinned here (all classic, all fiddly, spec 8.1):

  * min-raise = size of the largest prior full bet/raise of the street
  * an all-in below the min-raise does NOT reopen betting for players who
    already acted since the last full raise (they may call or fold only)
  * side pots layer by all-in amounts; each layer awarded independently
  * heads-up: the button posts the small blind, acts first pre-flop and
    last post-flop
  * showdown order: last aggressor of the final street first, then clockwise
  * odd chips go to the first winner clockwise from the button

Usage::

    python3 tools/betting-kat.py

Exit status is non-zero on any failure (CI gate).
"""

import sys

FAILS = []


def check(label, observed, expected):
    if observed == expected:
        print("PASS  %-52s %s" % (label, observed))
    else:
        print("FAIL  %-52s observed=%r expected=%r" % (label, observed, expected))
        FAILS.append(label)


# --------------------------------------------------------------------------
# The engine mirror. State keys and semantics match the xTalk exactly;
# booleans are the strings "true"/"false" like xTalk custom-property law.
# --------------------------------------------------------------------------

def new_hand(sb, bb, stacks, occ, button):
    st = {
        "sb": sb, "bb": bb, "occ": list(occ), "buttonSeat": button,
        "street": "preflop", "phase": "blinds", "toAct": 0,
        "betCur": 0, "raiseFull": bb, "aggressor": 0, "sdFirst": 0,
        "err": "", "note": "",
        "stackBy": {s: stacks[s] for s in occ},
        "streetBy": {s: 0 for s in occ},
        "handBy": {s: 0 for s in occ},
        "foldedBy": {s: "false" for s in occ},
        "allinBy": {s: "false" for s in occ},
        "actedBy": {s: "false" for s in occ},
    }
    if len(occ) == 2:
        st["sbSeat"] = button           # heads-up: the button IS the SB
    else:
        st["sbSeat"] = _next_in(occ, button)
    st["bbSeat"] = _next_in(occ, st["sbSeat"])
    return st


def _next_in(lst, entry):
    i = lst.index(entry)
    return lst[(i + 1) % len(lst)]


def _rotate_after(lst, entry):
    i = lst.index(entry)
    return lst[i + 1:] + lst[:i + 1]


def _in_hand(st):
    return [s for s in st["occ"] if st["foldedBy"][s] == "false"]


def _pending(st, s):
    if st["foldedBy"][s] == "true" or st["allinBy"][s] == "true":
        return False
    if st["streetBy"][s] < st["betCur"]:
        return True
    return st["actedBy"][s] == "false"


def _next_pending(st, after):
    for s in _rotate_after(st["occ"], after):
        if _pending(st, s):
            return s
    return 0


def _live_count(st):
    return len([s for s in st["occ"]
                if st["foldedBy"][s] == "false" and st["allinBy"][s] == "false"])


def _pay(st, s, amount):
    st["stackBy"][s] -= amount
    st["streetBy"][s] += amount
    st["handBy"][s] += amount
    if st["stackBy"][s] == 0:
        st["allinBy"][s] = "true"


def _first_in_hand_after(st, after):
    for s in _rotate_after(st["occ"], after):
        if st["foldedBy"][s] == "false":
            return s
    return 0


def _close_street(st):
    if st["aggressor"] > 0:
        st["sdFirst"] = st["aggressor"]
    else:
        st["sdFirst"] = _first_in_hand_after(st, st["buttonSeat"])
    for s in st["occ"]:
        st["streetBy"][s] = 0
        st["actedBy"][s] = "false"
    st["betCur"] = 0
    st["raiseFull"] = st["bb"]
    st["aggressor"] = 0
    if st["street"] == "river":
        st["phase"] = "showdown"
        st["toAct"] = 0
        st["note"] += "showdown\n"
        return st
    if _live_count(st) <= 1:
        st["phase"] = "runout"
        st["toAct"] = 0
        st["note"] += "runout\n"
        return st
    st["street"] = {"preflop": "flop", "flop": "turn", "turn": "river"}[st["street"]]
    st["toAct"] = _next_pending(st, st["buttonSeat"])
    st["phase"] = "acting"
    st["note"] += "advance:%s\n" % st["street"]
    return st


def _after_action(st, s):
    nxt = _next_pending(st, s)
    if nxt == 0:
        return _close_street(st)
    st["toAct"] = nxt
    return st


def apply_msg(state, mtype, seat, amount):
    import copy
    st = copy.deepcopy(state)
    st["err"] = ""
    st["note"] = ""

    if mtype == "bidSB":
        if st["phase"] != "blinds":
            st["err"] = "bidSB-out-of-phase"
            return st
        if seat != st["sbSeat"]:
            st["err"] = "bidSB-wrong-seat"
            return st
        pay = min(st["sb"], st["stackBy"][seat])
        if amount != pay:
            st["err"] = "bidSB-wrong-amount"
            return st
        _pay(st, seat, pay)
        return st

    if mtype == "bidBB":
        if st["phase"] != "blinds":
            st["err"] = "bidBB-out-of-phase"
            return st
        if seat != st["bbSeat"]:
            st["err"] = "bidBB-wrong-seat"
            return st
        pay = min(st["bb"], st["stackBy"][seat])
        if amount != pay:
            st["err"] = "bidBB-wrong-amount"
            return st
        _pay(st, seat, pay)
        st["betCur"] = st["bb"]      # the BB is the opening bet even if short
        st["raiseFull"] = st["bb"]
        st["phase"] = "acting"
        return _after_action(st, seat)

    if mtype == "board":
        if st["phase"] == "runout":
            st["street"] = {"preflop": "flop", "flop": "turn", "turn": "river"}.get(
                st["street"], st["street"])
            if st["street"] == "river":
                st["phase"] = "showdown"
                st["note"] += "showdown\n"
        return st

    if mtype != "act":
        st["err"] = "unknown-message:" + mtype
        return st

    verb, amt = (amount.split(",") + ["0"])[:2]
    amt = int(amt) if amt not in ("", None) else 0
    if st["phase"] != "acting":
        st["err"] = "act-out-of-phase"
        return st
    if seat != st["toAct"]:
        st["err"] = "act-out-of-turn"
        return st

    if verb == "fold":
        st["foldedBy"][seat] = "true"
        st["actedBy"][seat] = "true"
        if len(_in_hand(st)) == 1:
            st["phase"] = "handdone"
            st["toAct"] = 0
            st["note"] += "foldwin:%d\n" % _in_hand(st)[0]
            return st
        return _after_action(st, seat)

    if verb == "check":
        if st["streetBy"][seat] < st["betCur"]:
            st["err"] = "check-facing-bet"
            return st
        st["actedBy"][seat] = "true"
        return _after_action(st, seat)

    if verb == "call":
        owe = st["betCur"] - st["streetBy"][seat]
        if owe <= 0:
            st["err"] = "call-nothing-to-call"
            return st
        pay = min(owe, st["stackBy"][seat])
        if amt != pay:
            st["err"] = "call-wrong-amount"
            return st
        _pay(st, seat, pay)
        st["actedBy"][seat] = "true"
        return _after_action(st, seat)

    if verb in ("bet", "raise", "allin"):
        if verb == "allin":
            target = st["streetBy"][seat] + st["stackBy"][seat]
            if amt != target:
                st["err"] = "allin-wrong-amount"
                return st
            if target <= st["betCur"]:
                _pay(st, seat, st["stackBy"][seat])
                st["actedBy"][seat] = "true"
                return _after_action(st, seat)
        else:
            target = amt
            if verb == "bet" and st["betCur"] > 0:
                st["err"] = "bet-facing-bet-use-raise"
                return st
            if verb == "raise" and st["betCur"] == 0:
                st["err"] = "raise-nothing-to-raise-use-bet"
                return st
        if target <= st["betCur"]:
            st["err"] = "raise-not-above-bet"
            return st
        pay = target - st["streetBy"][seat]
        if pay > st["stackBy"][seat]:
            st["err"] = "raise-beyond-stack"
            return st
        is_allin = pay == st["stackBy"][seat]
        increment = target - st["betCur"]
        if increment < st["raiseFull"] and not is_allin:
            st["err"] = "raise-below-minimum"
            return st
        if st["actedBy"][seat] == "true":
            st["err"] = "raise-not-reopened"
            return st
        _pay(st, seat, pay)
        st["betCur"] = target
        st["aggressor"] = seat
        st["actedBy"][seat] = "true"
        if increment >= st["raiseFull"]:
            st["raiseFull"] = increment
            for s in st["occ"]:
                if s != seat:
                    st["actedBy"][s] = "false"
        return _after_action(st, seat)

    st["err"] = "unknown-verb:" + verb
    return st


def showdown_order(st):
    first = st["sdFirst"]
    if first == 0 or st["foldedBy"][first] == "true":
        first = _first_in_hand_after(st, st["buttonSeat"])
    order = [first] + _rotate_after(st["occ"], first)
    out = []
    for s in order:
        if st["foldedBy"][s] == "false" and s not in out:
            out.append(s)
    return out


def settle(st, ranks):
    deltas = {s: -st["handBy"][s] for s in st["occ"]}
    levels = sorted({st["handBy"][s] for s in st["occ"] if st["handBy"][s] > 0})
    prev = 0
    for level in levels:
        layer = sum(max(0, min(st["handBy"][s], level) - prev) for s in st["occ"])
        eligible = [s for s in st["occ"]
                    if st["foldedBy"][s] == "false" and st["handBy"][s] >= level]
        if not eligible:
            for s in st["occ"]:
                c = min(st["handBy"][s], level) - prev
                if c > 0:
                    deltas[s] += c
            prev = level
            continue
        if len(eligible) == 1:
            winners = eligible
        else:
            best = max(ranks[s] for s in eligible)
            winners = [s for s in eligible if ranks[s] == best]
        share, rem = divmod(layer, len(winners))
        for s in winners:
            deltas[s] += share
        for s in _rotate_after(st["occ"], st["buttonSeat"]):
            if rem == 0:
                break
            if s in winners:
                deltas[s] += 1
                rem -= 1
        prev = level
    return deltas


# --------------------------------------------------------------------------
# The pinned scenarios (each one is duplicated on-engine in the harness)
# --------------------------------------------------------------------------

def run_blinds(st):
    st = apply_msg(st, "bidSB", st["sbSeat"], min(st["sb"], st["stackBy"][st["sbSeat"]]))
    assert st["err"] == "", st["err"]
    st = apply_msg(st, "bidBB", st["bbSeat"], min(st["bb"], st["stackBy"][st["bbSeat"]]))
    assert st["err"] == "", st["err"]
    return st


def case_min_raise():
    st = run_blinds(new_hand(1, 2, {1: 100, 2: 100, 3: 100}, [1, 2, 3], 1))
    check("preflop first to act is left of BB", st["toAct"], 1)
    bad = apply_msg(st, "act", 1, "raise,3")
    check("raise to 3 under min (bb=2) rejected", bad["err"], "raise-below-minimum")
    st = apply_msg(st, "act", 1, "raise,4")
    check("raise to 4 (min) accepted", st["err"], "")
    bad = apply_msg(st, "act", 2, "raise,5")
    check("re-raise to 5 under min rejected", bad["err"], "raise-below-minimum")
    st = apply_msg(st, "act", 2, "raise,6")
    check("re-raise to 6 (last full raise = 2) accepted", st["err"], "")
    check("raiseFull tracks the full raise", st["raiseFull"], 2)


def case_under_raise_no_reopen():
    # flop: seat2 checks, seat3 bets 10 (full), seat1 calls, seat2 goes all-in
    # for 11 (under-raise): action does NOT reopen for seat3 or seat1
    st = run_blinds(new_hand(1, 2, {1: 100, 2: 13, 3: 100}, [1, 2, 3], 1))
    for seat, msg in ((1, "call,2"), (2, "call,1"), (3, "check,0")):
        st = apply_msg(st, "act", seat, msg)
        assert st["err"] == "", st["err"]
    check("flop reached", st["street"], "flop")
    check("flop first to act", st["toAct"], 2)
    st = apply_msg(st, "act", 2, "check,0")
    st = apply_msg(st, "act", 3, "bet,10")
    check("flop bet of 10 accepted", st["err"], "")
    st = apply_msg(st, "act", 1, "call,10")
    st = apply_msg(st, "act", 2, "allin,11")
    check("under-raise all-in accepted", st["err"], "")
    check("betCur moves to 11", st["betCur"], 11)
    check("raiseFull stays 10 after under-raise", st["raiseFull"], 10)
    bad = apply_msg(st, "act", 3, "raise,25")
    check("seat3 already acted: raise rejected", bad["err"], "raise-not-reopened")
    st = apply_msg(st, "act", 3, "call,1")
    bad = apply_msg(st, "act", 1, "raise,25")
    check("seat1 already acted: raise rejected", bad["err"], "raise-not-reopened")
    st = apply_msg(st, "act", 1, "call,1")
    check("street closes to turn", st["street"], "turn")


def case_three_way_side_pots():
    st = run_blinds(new_hand(1, 2, {1: 100, 2: 50, 3: 20}, [1, 2, 3], 1))
    st = apply_msg(st, "act", 1, "allin,100")
    check("open shove accepted", st["err"], "")
    st = apply_msg(st, "act", 2, "allin,50")
    check("short call-allin accepted", st["err"], "")
    st = apply_msg(st, "act", 3, "allin,20")
    check("shorter call-allin accepted", st["err"], "")
    check("hand runs out (no more betting)", st["phase"], "runout")
    for _ in range(3):
        st = apply_msg(st, "board", 0, 0)
    check("board runout reaches showdown", st["phase"], "showdown")
    # seat3 best, seat2 middle, seat1 worst
    deltas = settle(st, {1: "011413120900", 2: "021104140000", 3: "031413120000"})
    check("main pot 60 to seat3, side 60 to seat2, 50 back",
          deltas, {1: -50, 2: 10, 3: 40})


def case_heads_up_order():
    st = new_hand(1, 2, {2: 100, 5: 100}, [2, 5], 2)
    check("heads-up: button posts SB", st["sbSeat"], 2)
    check("heads-up: other seat posts BB", st["bbSeat"], 5)
    st = run_blinds(st)
    check("heads-up: button acts first preflop", st["toAct"], 2)
    st = apply_msg(st, "act", 2, "call,1")
    st = apply_msg(st, "act", 5, "check,0")
    check("heads-up flop", st["street"], "flop")
    check("heads-up: non-button acts first postflop", st["toAct"], 5)


def case_bb_option():
    st = run_blinds(new_hand(1, 2, {1: 100, 2: 100, 3: 100}, [1, 2, 3], 1))
    st = apply_msg(st, "act", 1, "call,2")
    st = apply_msg(st, "act", 2, "call,1")
    check("action returns to the BB (option)", st["toAct"], 3)
    st = apply_msg(st, "act", 3, "raise,6")
    check("BB may raise its option", st["err"], "")
    check("limpers must respond", st["toAct"], 1)


def case_fold_win_uncalled():
    st = run_blinds(new_hand(1, 2, {1: 100, 2: 100}, [1, 2], 1))
    st = apply_msg(st, "act", 1, "raise,6")
    st = apply_msg(st, "act", 2, "fold,0")
    check("fold ends the hand", st["phase"], "handdone")
    deltas = settle(st, {})
    check("uncalled raise returned to the winner", deltas, {1: 2, 2: -2})


def case_split_odd_chip_and_order():
    st = run_blinds(new_hand(1, 2, {1: 100, 2: 100, 3: 100}, [1, 2, 3], 1))
    for seat, msg in ((1, "call,2"), (2, "call,1"), (3, "check,0")):
        st = apply_msg(st, "act", seat, msg)
    st = apply_msg(st, "act", 2, "bet,9")
    st = apply_msg(st, "act", 3, "call,9")
    st = apply_msg(st, "act", 1, "call,9")
    for seat in (2, 3, 1):
        st = apply_msg(st, "act", seat, "check,0")   # turn
    st = apply_msg(st, "act", 2, "check,0")          # river: 3 bets, others call
    st = apply_msg(st, "act", 3, "bet,2")
    st = apply_msg(st, "act", 1, "call,2")
    st = apply_msg(st, "act", 2, "call,2")
    check("river close reaches showdown", st["phase"], "showdown")
    check("river aggressor shows first", showdown_order(st), [3, 1, 2])
    # seats 1 and 2 split (identical rank), seat 3 worse; pot = 39
    deltas = settle(st, {1: "041400000000", 2: "041400000000", 3: "011413120900"})
    check("odd chip to first winner after the button",
          deltas, {1: 6, 2: 7, 3: -13})


def case_blind_allin_runout():
    st = new_hand(1, 2, {4: 1, 6: 2}, [4, 6], 4)
    st = apply_msg(st, "bidSB", 4, 1)
    check("short SB posts all-in", st["allinBy"][4], "true")
    st = apply_msg(st, "bidBB", 6, 2)
    check("both blinds all-in: instant runout", st["phase"], "runout")


def case_check_around():
    st = run_blinds(new_hand(1, 2, {1: 30, 2: 30, 3: 30}, [1, 2, 3], 1))
    for seat, msg in ((1, "call,2"), (2, "call,1"), (3, "check,0")):
        st = apply_msg(st, "act", seat, msg)
    for seat in (2, 3, 1):
        st = apply_msg(st, "act", seat, "check,0")
    check("checked-around flop advances to turn", st["street"], "turn")
    bad = apply_msg(st, "act", 3, "check,0")
    check("out-of-turn check rejected", bad["err"], "act-out-of-turn")


def main():
    case_min_raise()
    case_under_raise_no_reopen()
    case_three_way_side_pots()
    case_heads_up_order()
    case_bb_option()
    case_fold_win_uncalled()
    case_split_odd_chip_and_order()
    case_blind_allin_runout()
    case_check_around()
    print()
    if FAILS:
        print("FAILED -- %d betting case(s) wrong." % len(FAILS))
        return 1
    print("All betting cases passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
