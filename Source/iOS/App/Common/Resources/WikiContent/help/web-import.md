# Wi-Fi / Web Import

The easiest way to get GameCube and Wii files onto iCube is over Wi-Fi —
no cable, no Finder file-sharing dance, no third-party app required.

## How it works

iCube runs a small web server on your device whenever the app is open (or,
on tvOS, whenever the app is on the first-run/empty-library screen). Any
computer or phone on the **same Wi-Fi network** can open a web page and drop
files directly onto it.

1. Open iCube.
2. Go to **Settings → Network** (or, on tvOS with an empty library, look at
   the on-screen address on the home screen).
3. Note the **Web UI** address shown — it looks like
   `http://192.168.1.23:8080`.
4. On your computer or phone, open that address in a web browser.
5. Drag GameCube/Wii disc images (`.iso`, `.gcm`, `.wbfs`, `.rvz`, etc.) onto
   the page, or use the upload button.

The transfer happens entirely over your local network — nothing leaves your
Wi-Fi, and no internet connection is required once the app is installed.

## Using Finder instead of a browser

iCube also exposes the same folder over WebDAV, so you can mount it as a
network drive:

1. Note the **Finder / WebDAV** address in **Settings → Network**.
2. On a Mac, open Finder and choose **Go → Connect to Server…**.
3. Enter the WebDAV address shown in iCube.
4. Connect as **Guest**.
5. Drag files into the mounted volume like any other folder.

## tvOS

On Apple TV, Wi-Fi import is the primary way to get games onto the device —
there's no Finder file-sharing on tvOS. If your library is empty, the home
screen shows the Web UI address directly; open it from any other device on
the same network and upload from there.

## Troubleshooting

* **Address doesn't load** — make sure the computer/phone and the
  Apple TV/iPhone/iPad are on the *same* Wi-Fi network (not a guest network
  that isolates clients from each other).
* **Address is blank / "Not Running"** — the web server starts when the
  Settings screen (or, on tvOS, the empty-library screen) appears; give it a
  moment, or back out and back in to Settings.
* **Upload finishes but the game doesn't show up** — check that the file
  extension is one iCube recognizes; re-import from the library's import
  menu if needed.
