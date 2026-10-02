# Dumping GameCube & Wii Discs

iCube plays disc images, so before you can play a game you own, you need a copy of its disc as a file. This page covers the standard way to make one on a real Wii, how to join and shrink the result, and how to check it came out clean.

iCube does not provide, link to, or endorse any source of pre-dumped games. Dump discs you own, from hardware you own.

## What you need

* **A Wii with the Homebrew Channel installed.** The [Wii Hacks Guide](https://wii.hacks.guide/) walks through installing it.
* **GameCube discs need a Wii that can read them.** The original Wii (model RVL-001, the one with GameCube controller ports) can. The Wii Family Edition, the Wii mini, and the Wii U's vWii cannot read GameCube discs at all, so they can dump Wii discs only.
* **An SD card or USB drive formatted FAT32** with at least 4.7 GB free for a Wii disc. A dual-layer Wii disc needs 8.5 GB. GameCube discs are up to 1.4 GB.
* **CleanRip**, a homebrew disc dumper. Its project page is on [WiiBrew](https://wiibrew.org/wiki/CleanRip), and the Wii Hacks Guide has a [dumping walkthrough](https://wii.hacks.guide/dump-games) that links the current download.

## Dump with CleanRip

1. Copy CleanRip's `apps` folder to the root of the SD card or USB drive.
2. Put the card or drive in the Wii, boot it, and open **CleanRip** from the Homebrew Channel.
3. When it asks whether to calculate checksums, choose **Yes**. You'll want them in the verify step below.
4. Choose where to write the dump (SD card or USB), then choose **FAT (FAT32)** as the file system.
5. If your Wii is online, choose **Yes** when it offers to download the `redump.org` database files. CleanRip uses them to check the dump against known-good discs.
6. Insert the disc and press **A**.

A GameCube disc produces one file. A Wii disc produces several part files, because FAT32 can't hold a single file larger than 4 GiB. The part names and the folder they land in depend on your CleanRip version, so check the card.

A disc that plays fine can still throw an unrecovered read error during a dump. Clean the disc, restart CleanRip, and try again.

## Join the part files

Skip this for GameCube discs. For a Wii disc, join the parts into one `.iso` before importing. Order matters: the first part goes first. The names below are placeholders for whatever CleanRip wrote.

On macOS or Linux:

```bash
cat game.part0.iso game.part1.iso game.part2.iso > game.iso
```

On Windows, in Command Prompt:

```
copy /b game.part0.iso + game.part1.iso + game.part2.iso game.iso
```

A full single-layer Wii disc image is about 4.7 GB and a dual-layer one is about 8.5 GB. If your joined file is well short of that, a part is missing or out of order.

## Shrink it to RVZ

A raw `.iso` works, but a Wii disc is 4.7 GB or more. `.rvz` is Dolphin's compressed format, loads quickly, and converts back to a byte-exact `.iso` whenever you want one. See [Supported Formats](https://icube-emu.com/guide/formats/) for how it compares to the others.

In Dolphin on your Mac or PC, right-click the game in the list and choose **Convert File…**. Pick format `RVZ`, block size 128 KiB, and compression `zstd` at level 5. Dolphin proposes that block size, method, and level by default. Higher levels only make the conversion slower.

From a terminal, `dolphin-tool` does the same job:

```bash
dolphin-tool convert -i game.iso -o game.rvz -f rvz -b 131072 -c zstd -l 5
```

Avoid scrubbing during conversion. RVZ already compresses unused space well, so scrubbing saves little and throws data away.

## Check the dump

In Dolphin, right-click the game, choose **Properties**, and open the **Verify** tab. Tick CRC32, MD5, and SHA-1 and run it. If Dolphin has the `redump.org` data, it tells you if your hashes match a known disc. A mismatch can mean a bad read, so dump the disc again before assuming it's a different release.

## Get it onto iCube

Copy the `.iso` or `.rvz` to your device with **Wi-Fi / Web Import** (under Help in this wiki), or use **Import Game** in the library's **Import** menu on iPhone and iPad.

## Other ways to dump

You can also read Wii and GameCube discs in a PC drive if the drive has patched firmware, but the compatible drives are few and dual-layer discs may fail. CleanRip is the more reliable route. The [Provenance wiki's ripping guide](https://wiki.provenance-emu.com/installation-and-usage/roms/ripping-roms) covers the drive method and other systems.

For WiiWare, Virtual Console, and other channel titles, see **WiiWare, Virtual Console & Channels**.
