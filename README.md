# ATC House

A macOS menu bar app that mixes live air traffic control with long house music sets — lofi-ATC, but house.

- **ATC:** paste any [LiveATC](https://www.liveatc.net) player link (`hlisten.php?mount=…`). The app plays LiveATC's own player page in the background; if LiveATC asks for a human check, its page pops up so you can pass it. Or switch to **Recorded** and shuffle archive files you've downloaded into `~/Music/ATC`.
- **House:** 80 hand-picked DJ sets (deep, tech, classic, garage, coffee-shop), streamed via YouTube's embedded player. Add your own by pasting a YouTube link.
- One button starts or pauses both. Separate volume faders, a scrubber, and it remembers where you left off in every set.

## Install

```bash
brew install --cask mitchelmckee/tap/atc-house
```

Requires macOS 14 (Sonoma) or later, Apple Silicon or Intel. The app isn't notarized; the cask clears the Gatekeeper quarantine flag on install.

## Build

```bash
./build.sh            # builds build/ATC House.app and build/ATC-House.zip
./build.sh --install  # also copies it to /Applications
```

Personal project; not affiliated with LiveATC or YouTube. Audio streams come from their services — please respect their terms.
