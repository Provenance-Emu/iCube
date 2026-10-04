# WiiWare, Virtual Console & Channels

WiiWare, Virtual Console, and other Wii channels don't come on discs. They live in your Wii's internal storage (the NAND), so you dump them from the console itself. iCube accepts the results in two forms: a `.wad` file for a single title, or a BootMii NAND backup for the whole console.

iCube does not provide, link to, or endorse any source of pre-dumped titles or backups. Dump from a Wii you own.

## Which one do you want?

* **One title, ready to play: a `.wad` file.** iCube lists `.wad` files with your other games. Launching one installs it to iCube's emulated Wii NAND temporarily and boots it, so there is nothing else to set up.
* **Everything on the console: a BootMii NAND backup.** This brings over your Wii saves, installed channels, and system files in one go. The file is about 553 MB, and importing it is iPhone and iPad only (not Apple TV), so use it when you want your saves and not just one game.

## Dump a single title to a `.wad`

You need a Wii with the Homebrew Channel installed (see the [Wii Hacks Guide](https://wii.hacks.guide/)) and an SD card or USB drive.

1. Download **Yet Another BlueDump MOD** from the Open Shop Channel at [oscwii.org](https://oscwii.org/) and copy its `apps` folder to the root of the SD card or USB drive.
2. Put the card or drive in the Wii, open the Homebrew Channel, and launch **Yet Another BlueDump MOD**. Press **A** at the first prompt.
3. Choose **Installed Channel Titles**.
4. Highlight the WiiWare, Virtual Console, or channel title you want and press the **1** button.
5. Choose **Backup to WAD**.
6. Answer the three prompts the way the Wii Hacks Guide's [WAD dumping page](https://wii.hacks.guide/dump-wads) does:
   * Fakesign the ticket: **Yes**
   * Fakesign the TMD: **No**
   * Change the output WAD region: **No**
7. Copy the `.wad` from the card or drive to your computer.

Then get it onto iCube like any other game, with **Wi-Fi / Web Import** (under Help in this wiki) or **Import Game** in the library's **Import** menu. Launch it from the library.

## Back up the whole console with BootMii

BootMii writes `nand.bin` (the console's storage) and `keys.bin` (1,024 bytes of keys needed to decrypt it) to the root of the SD card. Depending on how the backup was made, the keys may already be at the end of `nand.bin`. The Wii Hacks Guide has the steps for making the backup: [BootMii Backup](https://wii.hacks.guide/bootmii) and [NAND backup](https://wii.hacks.guide/nand-backup).

### Check the size, then append the keys only if they're missing

Dolphin on a computer asks for `keys.bin` separately. iCube can't, so it accepts exactly two file sizes for this import:

* **553,649,152 bytes:** `nand.bin` already has the keys at the end. Import it as it is.
* **553,648,128 bytes:** the keys are missing. Append `keys.bin` first. The result should be 553,649,152 bytes.

Check your file's size before you touch it (`ls -l` on macOS or Linux, `dir` on Windows, or Get Info in Finder). Don't append `keys.bin` to a 553,649,152-byte file. That makes it 553,650,176 bytes, and iCube rejects it.

To append the keys to a 553,648,128-byte file, on macOS or Linux:

```bash
cat nand.bin keys.bin > nand_with_keys.bin
```

On Windows, in Command Prompt:

```
copy /b nand.bin + keys.bin nand_with_keys.bin
```

### Import it

1. Put the 553,649,152-byte file (`nand.bin`, or `nand_with_keys.bin` if you appended the keys) somewhere the Files app can see it, such as iCloud Drive or **On My iPhone**. iCube opens it with the standard Files picker.
2. In iCube's library, open the **Import** menu and choose **Import BootMii NAND Backup…**. This menu item is on iPhone and iPad only, not Apple TV.
3. Pick the `.bin` file and wait for **Importing NAND backup** to finish.

The import writes the backup's files into iCube's emulated Wii NAND, which by default is the `Wii` folder in the User Folder, replacing any file at the same path. If you've already played Wii games in iCube and want to keep that progress, copy your User Folder somewhere safe first. You can see where it is in **Settings → Debug → Environment → User Folder**.

### Import messages

* **"The decryption keys need to be appended to the NAND backup file."** The file is a bare 553,648,128-byte `nand.bin`. Append `keys.bin` as shown above and import again.
* **"This file does not look like a BootMii NAND backup."** The file size is neither of the two above. Appending the keys to a file that already had them (553,650,176 bytes), a truncated copy, or the wrong `.bin` will all do this.
* **"This file does not contain a valid Wii filesystem."** Usually the keys don't match the backup, or the backup itself is damaged. Make a fresh one.

## Playing a specific title

A NAND import fills the emulated NAND. For a specific WiiWare or Virtual Console title, dump a `.wad`. iCube treats `.wad` as a game file, so it imports and launches like a disc image.
