#!/usr/bin/env python3
"""Pin the kit-mode card atlas against the stack's frame mapping.

The OXT "kit" mode draws cards from the Kenney Playing Cards Pack spritesheet
(assets/cards/, CC0). The stack maps each internal card id to an atlas frame in
heKenneyFrame; this KAT mirrors that rule and asserts every one of the 52 cards
resolves to a frame that ACTUALLY EXISTS in the vendored atlas, that the mapping
is one-to-one, and that every frame rect fits inside the sheet. A wrong frame
name renders a blank or garbage card on the felt -- invisible to every other gate
and un-runnable headless -- so this closes that gap the same way evaluator-kat
closes the evaluator's.

Pure data (regex over the XML + the PNG's IHDR header); no engine, no deps.
"""
import re
import struct
import sys
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
XML = ROOT / "assets" / "cards" / "playingCards.xml"
PNG = ROOT / "assets" / "cards" / "playingCards.png"

RANKS = "23456789TJQKA"                 # mirror kHeRankChars
SUITS = "cdhs"                          # mirror kHeSuitChars
SUIT_NAME = {"c": "Clubs", "d": "Diamonds", "h": "Hearts", "s": "Spades"}


def card_name(idx):
    """mirror heCardName: index 1..52 -> rank+suit, e.g. 52 -> 'As'."""
    rank = (idx - 1) // 4 + 2
    suit = (idx - 1) % 4 + 1
    return RANKS[rank - 2] + SUITS[suit - 1]


def kenney_frame(idx):
    """mirror heKenneyFrame: -> 'card<Suit><Rank>' base name (ten as '10')."""
    n = card_name(idx)
    r, s = n[0], n[1]
    rank = "10" if r == "T" else r
    return "card" + SUIT_NAME[s] + rank


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        raise ValueError("not a PNG: %s" % path)
    return struct.unpack(">II", head[16:24])


def main():
    if not XML.exists() or not PNG.exists():
        print("FAILED -- vendored card atlas missing under assets/cards/.")
        return 1

    frames = {}
    pat = re.compile(r'name="([^"]+)"\s+x="(\d+)"\s+y="(\d+)"\s+width="(\d+)"\s+height="(\d+)"')
    for m in pat.finditer(XML.read_text()):
        name = m.group(1)
        base = name[:-4] if name.endswith(".png") else name
        frames[base] = (int(m.group(2)), int(m.group(3)), int(m.group(4)), int(m.group(5)))

    fails = 0

    # 1. every card id maps to a frame that exists in the atlas
    for idx in range(1, 53):
        fr = kenney_frame(idx)
        if fr not in frames:
            print("FAIL  card %d (%s) -> '%s' is not in the atlas" % (idx, card_name(idx), fr))
            fails += 1

    # 2. the mapping is one-to-one (no two cards share a frame)
    mapped = [kenney_frame(i) for i in range(1, 53)]
    if len(set(mapped)) != 52:
        print("FAIL  card->frame mapping is not one-to-one (%d distinct)" % len(set(mapped)))
        fails += 1

    # 3. every frame rect fits inside the sheet
    w, h = png_size(PNG)
    for name, (x, y, fw, fh) in frames.items():
        if x + fw > w or y + fh > h:
            print("FAIL  frame '%s' rect (%d,%d,%d,%d) exceeds sheet %dx%d"
                  % (name, x, y, fw, fh, w, h))
            fails += 1

    print()
    if fails:
        print("FAILED -- %d atlas/mapping problem(s)." % fails)
        return 1
    print("All 52 cards map to present frames; %d frames fit the %dx%d sheet." % (len(frames), w, h))
    return 0


if __name__ == "__main__":
    sys.exit(main())
