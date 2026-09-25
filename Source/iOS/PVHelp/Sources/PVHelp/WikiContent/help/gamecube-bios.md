# GameCube BIOS (IPL)

## Do you actually need this?

**No, not to play games.** iCube can boot straight into a GameCube or Wii
disc without any BIOS file — this is called High-Level Emulation (HLE) and
it's the default. You only need the real GameCube BIOS (called the **IPL**,
short for Initial Program Loader) if you want to:

* Boot to the actual **GameCube Main Menu** (the one with the memory card
  manager and system settings), rather than going straight into a game.
* Get the small extra layer of hardware-accurate boot behavior the IPL
  provides for a handful of picky games.

If you don't have an IPL dump, turn off **"Load GameCube Main Menu"** in
**Settings → Config → GameCube** and everything else works normally.

## What the IPL is

The IPL is a small boot ROM that shipped inside every physical GameCube
console. It's region-specific — there's a separate dump for USA, Europe (PAL),
and Japan (NTSC-J) consoles.

## Where to get one

You must dump the IPL from a GameCube console **you own**. iCube does not
provide, link to, or endorse any source of pre-dumped BIOS files — obtaining
one from anywhere other than your own hardware may be illegal depending on
your local copyright law.

Common dumping methods (searching for the exact steps for your hardware is
recommended, since they change over time):

* A GameCube modchip or exploit that can run homebrew, paired with a BIOS
  dumping tool.
* A Wii capable of running homebrew, which can dump the IPL of a
  Wii-compatible GameCube region in some configurations.

## Where it goes

Once you have a dump named appropriately for your console's region, place it
in iCube's **User Folder**, inside the `GC` subdirectory, in the folder for
your region (e.g. `GC/USA/`, `GC/EUR/`, `GC/JAP/`). You can see the exact
path iCube is using for its User Folder in **Settings → Debug →
Environment → User Folder**.

After copying the file into place, relaunch the game — iCube picks up newly
added BIOS files automatically.

## Still seeing "GameCube BIOS (IPL) isn't installed"?

This message means iCube specifically tried to boot the GameCube Main Menu
(not a game) and couldn't find a matching-region IPL dump. Either:

* Add the correct region's IPL file as described above, or
* Turn off **"Load GameCube Main Menu"** in **Settings → Config → GameCube**
  to boot games directly instead.
