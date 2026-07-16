# Card art — Kenney "Playing Cards Pack" (CC0)

`playingCards.png` + `playingCards.xml` are the 52-card face spritesheet from the
**Kenney Playing Cards Pack**, used for the OXT (Box2Dxt "kit" mode) card rendering.

- **Author:** Kenney (kenney.nl)
- **License:** **CC0 1.0 Universal** (public domain dedication) — no attribution
  required, but credited here anyway. See https://creativecommons.org/publicdomain/zero/1.0/
- **Source:** https://kenney.nl/assets/playing-cards-pack
- **Format:** a Starling/TextureAtlas XML (`<TextureAtlas>` / `<SubTexture>`) over a
  1024x2048 RGBA sheet; each card is 140x190. Frame names are `card<Suit><Rank>.png`
  (e.g. `cardSpades10.png`, `cardHeartsA.png`), plus one `cardJoker.png`. There is no
  card-back frame in this face sheet (Kenney ships backs in a separate `playingCardBacks`
  sheet); the stack draws its own back in kit mode until a back sheet is added.

The only local change from the upstream file is the atlas's `imagePath`, repointed
from `sheet.png` to the vendored `playingCards.png` so a loader that resolves the
image relative to the XML finds it.

## How the stack uses it

The stack maps its internal card ids to these frame names in `heKenneyFrame`
(`src/holdem.livecodescript`), and `tools/atlas-kat.py` pins in CI that all 52 cards
resolve to frames that actually exist in this atlas. To enable kit-mode card art in
OXT, point the stack's `uHeAtlasPath` custom property at `playingCards.xml` (or the
`.png`, per the Box2Dxt `b2kSheetLoadAtlas` contract) and install the Box2Dxt Kit.
