# Install Your Own Wii System Files

Wii games run on top of the Wii's system software: the System Menu, the IOS modules, and the channels. iCube does not include any of it, and the App Store version of iCube does not download it either. If a Wii game needs it, iCube uses the files from your own console, which you copy over from a BootMii NAND backup.

This page covers making that backup on a Wii you own and importing it on iPhone, iPad, and Apple TV.

## Why you need this

A Wii game that wants a system title that isn't in iCube's emulated Wii storage (the NAND) stops with a message like **"Could not launch title … because it is missing from the NAND."** The alert has a **How to Install Wii System Files** button that opens this page. In the App Store version you can also open it from the **System** menu in the library (**Install Wii System Files…**). Other builds of iCube have different entries in that menu.

Not every game asks for it. Install the files when one does.

iCube does not provide, link to, or endorse any source of pre-dumped system files. Use a backup of a console you own.

## Dump your NAND with BootMii

You need:

* **A Wii with BootMii installed.** BootMii is part of the Homebrew Channel setup. The [Wii Hacks Guide](https://wii.hacks.guide/) walks through it.
* **An SD card with at least 1 GB free.** BootMii writes to the root of the card.

Then follow the Wii Hacks Guide's [BootMii Backup](https://wii.hacks.guide/bootmii) and [NAND backup](https://wii.hacks.guide/nand-backup) steps. BootMii writes two files:

* **`nand.bin`**, the console's storage. It is 553,648,128 bytes.
* **`keys.bin`**, the keys that decrypt it. It is 1,024 bytes.

Some tools write `nand.bin` with the keys already appended at the end. That file is 553,649,152 bytes, and it needs no `keys.bin`. Check your sizes (`ls -l` on macOS or Linux, `dir` on Windows, or Get Info in Finder) before you start. Copy the files from the card to your computer.

Both files come from your own console. A `nand.bin` and a `keys.bin` from different backups don't work together.

## Before you import

Importing writes your console's files over iCube's emulated Wii storage. A file at the same path is replaced, and that includes the Wii save data of the same games. If you already have Wii saves in iCube that you want to keep, back them up first:

* **iPhone and iPad:** copy iCube's `Wii` folder out through the Files app.
* **Apple TV:** there is no Files app to copy saves out through, so import before you have progress you can't replace.

Quit any running game before you import. The Web UI upload below is refused while a game is running; the iPhone and iPad picker does not check, so make sure the game is closed yourself.

## iPhone and iPad

1. Put the file somewhere the Files app can see it, such as iCloud Drive or **On My iPhone**.
2. In the library, open the **Import** menu in the toolbar and choose **Import BootMii NAND Backup…**.
3. Pick the file and wait for **Importing NAND backup** to close.

The picker takes one file. It must be a `nand.bin` that already has its keys, 553,649,152 bytes. If yours is 553,648,128 bytes, append the keys first. On macOS or Linux:

```bash
cat nand.bin keys.bin > nand_with_keys.bin
```

On Windows, in Command Prompt:

```
copy /b nand.bin + keys.bin nand_with_keys.bin
```

Never append `keys.bin` to a file that already has them. That makes 553,650,176 bytes, and iCube rejects it.

You can also skip the appending and use the upload method from the Apple TV section below. It works on iPhone and iPad too.

## Apple TV

Apple TV has no file picker, so you send the files from a computer on the same Wi-Fi network.

1. On the Apple TV, open iCube and go to **Settings → Sync & Network → Web UI & WebDAV**. It shows the Web UI address.
2. Open that address in a browser on your computer.
3. If your `nand.bin` is 553,648,128 bytes (no keys), **upload `keys.bin` first**. iCube says it received the keys.
4. Upload **`nand.bin`**. The import starts by itself and a message tells you when it's done.

A `nand.bin` that already has its keys (553,649,152 bytes) can be uploaded alone.

The files must be named exactly `keys.bin` and `nand.bin`. A `nand.bin` without keys is refused unless you uploaded `keys.bin` before it, and an upload that's refused is deleted, so upload again once you've fixed the problem.

## Check it worked

* On Apple TV, a message says **Wii NAND backup imported.** On iPhone and iPad, the **Importing NAND backup** box closes without an error.
* Launch the Wii game that gave you the "missing from the NAND" alert. It should boot now.

## Troubleshooting

* **"The decryption keys need to be appended to the NAND backup file."** The file is a bare 553,648,128-byte `nand.bin`. Append `keys.bin` as shown above and pick it again, or upload `keys.bin` and then `nand.bin` from your computer.
* **"This NAND backup has no keys. Upload keys.bin from the same backup first, then upload nand.bin again."** You uploaded a bare `nand.bin` without sending `keys.bin` first. Upload `keys.bin`, then `nand.bin`.
* **"This file does not look like a BootMii NAND backup."** The size is wrong. iCube accepts only 553,648,128 bytes (`nand.bin` alone) and 553,649,152 bytes (with its keys). Keys appended twice (553,650,176 bytes), a truncated copy, or the wrong `.bin` all do this. Copy it again from the card and check the size.
* **`nand.bin` uploads but no import starts.** Its size isn't one of the two above, so iCube doesn't recognise it as a backup and treats it as an ordinary upload. Copy the file from the card again and check its size.
* **"A Wii NAND import can't start right now. Quit the game, then upload nand.bin again."** A game is running. Quit it and try again.
* **"This file does not contain a valid Wii filesystem."** The keys don't match the backup, or the backup is damaged. Make a fresh backup, and use the `keys.bin` from that same one.
* **"The Wii NAND backup couldn't be imported."** The import didn't finish. Check the file and its keys, then try again.

If a game still stops with a missing-title alert after a good import, that title isn't on your console either. Install it on the Wii and make a new backup.

For single WiiWare and Virtual Console titles, see **WiiWare, Virtual Console & Channels**. For discs, see **Dumping GameCube & Wii Discs**.
