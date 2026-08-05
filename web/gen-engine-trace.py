#!/usr/bin/env python3
"""Emit differential traces from the REFERENCE betting mirror, for web/engine.mjs.

tools/betting-kat.py is a line-for-line Python mirror of the xTalk betting
engine, and tools/logic-fuzz.py already checks that mirror against an
INDEPENDENT reference. So pinning the JS port against this mirror transitively
pins it to the same rules the engine and the fuzz agree on.

The KAT's cases are assertions inside functions rather than dumpable vectors,
so instead of a vector file this driver generates randomized hands with a FIXED
seed, drives the mirror message by message, and dumps every intermediate state.
The JS side replays the identical recorded message sequence and must reproduce
every state exactly -- which is a far broader check than the fixed cases, and
covers the evaluator and settlement at the same time.

Nothing here is a second implementation: it imports the mirror. Usage::

    python3 web/gen-engine-trace.py [--hands N] [--seed S] > trace.json
"""

import importlib.util
import json
import pathlib
import random
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


BK = _load("betting_kat", ROOT / "tools" / "betting-kat.py")
EK = _load("evaluator_kat", ROOT / "tools" / "evaluator-kat.py")


def gen_hand(rng, idx):
    """One randomized hand: setup, the exact message sequence, state after each."""
    nseats = rng.choice([2, 2, 3, 3, 4, 5, 6])
    # sparse seats exercise the wrap-around paths the contiguous cases never do
    seats = sorted(rng.sample(range(1, 7), nseats))
    bb = rng.choice([2, 4, 10, 20])
    sb = bb // 2
    ante = rng.choice([0, 0, 0, 1, bb // 2]) if bb >= 4 else 0
    # wildly uneven stacks are what actually generate layered side pots
    stacks = {s: rng.choice([bb, bb * 2, bb * 3, bb * 7, bb * 20, bb * 50, bb * 100])
              for s in seats}
    button = rng.choice(seats)

    st = BK.new_hand(sb, bb, stacks, seats, button, ante=ante)
    setup = {
        "sb": sb, "bb": bb, "ante": ante, "occ": seats, "button": button,
        "stacks": {str(k): v for k, v in stacks.items()},
    }
    msgs, states = [], []

    def drive(mtype, seat, amount):
        nonlocal st
        nxt = BK.apply_msg(st, mtype, seat, amount)
        msgs.append([mtype, seat, amount])
        states.append(snapshot(nxt))
        st = nxt

    # antes, then SB, then BB -- the ordering the protocol requires (9.3)
    if ante > 0:
        for s in seats:
            drive("bidAnte", s, min(ante, st["stackBy"][s]))
    drive("bidSB", st["sbSeat"], min(sb, st["stackBy"][st["sbSeat"]]))
    drive("bidBB", st["bbSeat"], min(bb, st["stackBy"][st["bbSeat"]]))

    # play to a terminal phase, choosing among the OFFERED legal actions --
    # which also cross-checks bet_legal against apply_msg on every step
    guard = 0
    while st["phase"] in ("acting", "runout") and guard < 400:
        guard += 1
        if st["phase"] == "runout":
            drive("board", 0, 0)
            continue
        seat = st["toAct"]
        legal = BK.bet_legal(st, seat)
        if not legal:
            break
        pick = rng.choice(legal)
        verb, *rest = pick.split()
        if verb in ("fold", "check"):
            amt = 0
        elif verb == "call":
            amt = int(rest[0])
        elif verb == "allin":
            amt = int(rest[0])
        else:                                   # bet / raise MINTO MAXTO
            lo, hi = int(rest[0]), int(rest[1])
            amt = rng.choice([lo, hi, rng.randint(lo, hi)])
        drive("act", seat, "%s,%d" % (verb, amt))
        if st["err"]:
            raise AssertionError("bet_legal offered an action apply_msg rejected: "
                                 "%s -> %s" % (pick, st["err"]))

    # showdown: deal real cards to the seats still in, evaluate, settle
    in_hand = [s for s in seats if st["foldedBy"][s] == "false"]
    deck = list(range(1, 53))
    rng.shuffle(deck)
    board = deck[:5]
    holes, ranks, p = {}, {}, 5
    for s in in_hand:
        holes[s] = deck[p:p + 2]
        p += 2
        # packed(): the 12-char fixed-width string both sides compare, which is
        # also what settle() ranks on (a tuple would order differently)
        ranks[s] = EK.packed(EK.evaluate7(holes[s] + board))

    deltas = BK.settle(st, ranks)
    if sum(deltas.values()) != 0:
        raise AssertionError("mirror settle did not conserve chips")

    return {
        "idx": idx, "setup": setup, "msgs": msgs, "states": states,
        "board": board, "holes": {str(k): v for k, v in holes.items()},
        "ranks": {str(k): v for k, v in ranks.items()},
        "deltas": {str(k): v for k, v in deltas.items()},
        "showdownOrder": BK.showdown_order(st),
        "legalFinal": BK.bet_legal(st, st["toAct"]) if st["toAct"] else [],
    }


def snapshot(st):
    """Every field that must match, with seat maps keyed by string."""
    out = {}
    for k in ("street", "phase", "toAct", "betCur", "raiseFull", "aggressor",
              "sdFirst", "err", "note", "sbSeat", "bbSeat", "sb", "bb", "ante",
              "buttonSeat"):
        out[k] = st[k]
    out["occ"] = list(st["occ"])
    for k in ("stackBy", "streetBy", "handBy", "foldedBy", "allinBy", "actedBy"):
        out[k] = {str(s): st[k][s] for s in st["occ"]}
    for k in ("antePostedBy", "sbPosted"):
        if k in st:
            out[k] = ({str(s): v for s, v in st[k].items()}
                      if isinstance(st[k], dict) else st[k])
    return out


def main():
    args = sys.argv[1:]
    hands = int(args[args.index("--hands") + 1]) if "--hands" in args else 400
    seed = int(args[args.index("--seed") + 1]) if "--seed" in args else 20260805
    rng = random.Random(seed)

    # evaluator vectors straight from the KAT, so the JS evaluator is pinned to
    # the same named hands (royal/wheel/quads/boat/split/...) as the xTalk
    ev = []
    for label, names, expect in EK.VECTORS:
        ev.append({"label": label, "cards": [EK.card_index(n) for n in names.split()],
                   "expect": expect})

    out = {"seed": seed, "evaluator": ev,
           "hands": [gen_hand(rng, i) for i in range(hands)]}
    json.dump(out, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
