# Third-party notices

Sundog includes code from other open-source projects. Each file keeps its original copyright and license header.

## UxPlay

- Project: https://github.com/FDH2/UxPlay
- Version: commit 4c6e017

### playfair

- Files: `Sources/CFairPlay/playfair/`
- Purpose: the FairPlay handshake for AirPlay screen mirroring.
- License: GNU General Public License, version 3. See `Sources/CFairPlay/playfair/LICENSE.md`.

### FairPlay reply tables

- File: `Sources/CFairPlay/fairplay.c`
- Source: `lib/fairplay_playfair.c` by Juho Vähä-Herttua.
- License: GNU Lesser General Public License, version 2.1 or later.
- Changes: Sundog removed the logger and the state structure.

The AirPlay protocol steps in `Sources/Sundog/AirPlay/` follow the receiver behavior of UxPlay.
