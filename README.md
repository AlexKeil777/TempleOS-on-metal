

```
                                                        .'|
                                                      .'  |
                               __..--''^''--..__    .'  .'
   ~v~                    _..--'':::::::::::::''--.'  .'
              -v~     '=========================.'  .'=='
        .-^-.         /\                      .'  .'   /\
                     /  \  v         ~v     .'  .'    /  \
                    /    \      v         .'  .'     /    \
                   _____                    _       ___  ____
                  |_   _|__ _ __ ___  _ __ | | ___ / _ \/ ___|
                    | |/ _ \ '_ ` _ \| '_ \| |/ _ \ | | \___ \
                '   | |  __/ | | | | | |_) | |  __/ |_| |___) |
                 \  |_|\___|_| |_| |_| .__/|_|\___|\___/|____/
                  '-.____.-'  .'  .' |_|           '-.____.-'
                            .'  .'
                          .'  .'
               .-._     .'  .'
               '-._'-._'  .'
                   '-._'-._
                  .'::.'-._'-._
                .'::.'     '-._|
              .'::.'
              '-.'
```




# TempleOS on metal

USB stick images that run [TempleOS](https://templeos.org/) on real PCs instead of in a virtual machine, with its sound coming out of the PC's own speakers (ideally). They don't make TempleOS any prettier. They get Terry A. Davis's operating system running on real hardware, so you can have fun with it - which is exactly what Terry would have wanted.

Tested on an eMachines eM350 netbook and a Lenovo ThinkPad Edge E530c. Just want to boot it? Skip to [Quick start](#quick-start).

## TempleOS and Terry A. Davis

TempleOS is the life's work of one man, Terry A. Davis (1969–2018). Starting in 2003, he spent more than ten years writing all of it, alone and full-time: the boot loaders, the kernel, the file system, the window manager, the editor and its hypertext document format, the graphics, the games, the music program, and HolyC, the dialect of C that everything is written in. HolyC's compiler is also the shell, so whatever you type at the prompt is compiled to machine code and run. As his FAQ puts it, TempleOS "executes no code not written by me at any time except for a few BIOS calls for configuration".

In 1996 Terry began having severe manic episodes, and he was later diagnosed with schizophrenia. He came to believe that God had told him to build a temple, and this operating system, called J Operating System, LoseThos and SparrowOS along the way, is that temple. "TempleOS is God's official temple," says its Charter. Its limits are deliberate: 640x480 in 16 colors, a single voice of sound, no networking, every program running in ring 0 with nothing off limits, and at most 100,000 lines of code, so that one person can learn the whole thing. The Charter sums it up:

> The vision is the same usage model and niche as the Commodore 64 -- a non-networked, simple machine where programming was the goal, not just a means to an end.

His illness also made him paranoid and often hostile online, and it made his last years hard; for a while he was homeless. He died in August 2018, at 48. He called himself the smartest programmer who ever lived. Whatever you make of that, very few people could have built what he built on their own. His community keeps TempleOS available at [templeos.org](https://templeos.org/).

## Not prettier, just running

This repo doesn't try to make TempleOS pretty. It was never meant to be pretty. There are no higher resolutions, no networking and no new look. TempleOS stays 640x480 in 16 colors (in the Charter's words, "a covenant"), ring-0-only, with its one voice of sound - as Terry wanted it. Forks that modernize TempleOS exist, and this isn't one of them. The only changes are the ones it takes for Terry's TempleOS to run on real PCs and be heard on them - this is to honor the man's work and make it more accessible to the world, not to improve it.

The point is to have fun with it: boot it on a real machine, write some HolyC, poke around a kernel where nothing is off limits, play the games. TempleOS's own welcome page says what it is for:

> TempleOS is a x86_64, multi-cored, non-preemptive multi-tasking, ring-0-only, single-address_mapped (identity-mapped), operating system for recreational programming.



TempleOS is 64-bit only, but it boots the old way. Its start-up code runs in 16-bit real mode and asks the PC's BIOS for the memory map and the 640x480 VGA mode, and only then switches to 64-bit. So it needs both a 64-bit CPU and a BIOS, or a UEFI that can still pretend to be one (legacy or "CSM" boot). Not many PCs have both. Terry's FAQ itself says it "can run on some bare metal 64-bit PC's from about 2005-2010".

Even on such a PC, TempleOS has very few drivers:

- **No USB.** The BIOS can start TempleOS from a USB stick, but then TempleOS can't read the stick, so it can't load the rest of itself. It expects a CD or an IDE hard disk.
- **No AHCI.** SATA has to be in IDE mode ("Compatibility" on ThinkPads), or TempleOS doesn't see the hard disk.
- **Only the PC speaker.** All its sound goes to the beeper on the motherboard, which many laptops don't have.
- **Bugs that a VM hides.** QEMU starts TempleOS with zeroed memory. A real BIOS leaves junk behind, and stock TempleOS trips over it.

## What the images add

- **Boots from a USB stick and runs from RAM.** The image's boot sector ([`boot.asm`](<Lenovo%20ThinkPad%20E530c/boot.asm>)) uses the BIOS to copy the whole TempleOS file system off the stick into RAM at 16 MB, then starts the kernel, which is built to use that RAM as drive `A:`. TempleOS still has no USB driver; this works around it.
- **Sound on the real speakers.** [`SndHDA.HC`](<Lenovo%20ThinkPad%20E530c/SndHDA.HC>) plays TempleOS's sound on the HD Audio chip that most PCs since 2005 have, through every speaker, headphone and line-out socket. It plays exactly what TempleOS plays, one square-wave voice, with no interrupts and no timers.
- **Installs to the hard disk.** `HDInstall;` is TempleOS's own installer, but it finds the disk controller by itself. The ThinkPad version also reads back everything it wrote, to check it. The installed TempleOS keeps the sound and the fixes.
- **Fixes for real hardware.** A few changes to TempleOS's own source. Each one is a "Source change" in the folder's `mkusb.py`, with the full story of why.

| # | TempleOS file                  | Change                                                                                                                            | eM350 | ThinkPad |
| :-: | ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------- | :---: | :------: |
| 1 | `Kernel/Mem/BlkPool.HC`      | Start the heap above the RAM disk (USB boot only)                                                                                 |  ✓  |    ✓    |
| 2 | `Kernel/KInts.HC`            | Stock bug: every CPU core but the first looked up its APIC through junk the BIOS left in memory, and crashed at "MultiCore Start" |  ✓  |    ✓    |
| 3 | `Kernel/KStart16.HC`         | Stock bug: the BIOS memory map could be read from the wrong place                                                                 |  ✓  |    ✓    |
| 4 | `Adam/MakeAdam.HC`           | Load the sound driver at boot                                                                                                     |  ✓  |    ✓    |
| 5 | `MakeHome.HC`                | Load `HDInstall` at boot                                                                                                        |  ✓  |    ✓    |
| 6 | `Kernel/KStart32.HC`         | Leave the BIOS's 32-bit PCI services alone; the ThinkPad's UEFI only imitates them                                                |      |    ✓    |
| 7 | `Kernel/BlkDev/DskATA.HC`    | Move disk data 16 bits at a time; Intel's SATA chips since 2011 can't do 32 in IDE mode                                           |      |    ✓    |
| 8 | `Adam/ABlkDev/DskPrt.HC`     | Stock bug: a failed partitioning went on to format the drive TempleOS was running from                                            |      |    ✓    |
| 9 | `Kernel/BlkDev/DskBlkDev.HC` | Read one block per disk command; more went wrong on the ThinkPad                                                                  |      |    ✓    |
| 10 | `Kernel/BlkDev/DskATA.HC`    | Wait the 400 ns the ATA standard gives a disk to report that it's busy                                                            |      |    ✓    |

## Quick start

1. **Pick an image.** If your PC is one of the [tested PCs](#tested-pcs), take the `TempleOS-USB.img` in its folder. For any other PC, start with the [ThinkPad image](<Lenovo%20ThinkPad%20E530c/TempleOS-USB.img>); it has every fix so far.
2. **Flash it** to a USB stick with [Rufus](https://rufus.ie/) in "DD image" mode, [balenaEtcher](https://etcher.balena.io/) or `dd`. The image is 64 MB (Github already screams at me for uploading a file bigger than 50MB but whatever), and everything else on the stick is erased.
3. **Set up the BIOS:** legacy (CSM) boot on, Secure Boot off, and SATA in IDE mode if TempleOS should see the hard disk.
4. **Boot from the stick** with the PC's boot menu (F12 on a ThinkPad). It prints `TempleOS` and a row of dots while it copies itself into RAM, then TempleOS starts.

If it stops at `TempleOS needs a 64-bit CPU`, that PC can't run TempleOS. At `TempleOS disk read error`, the BIOS couldn't read the stick; try another USB port or another stick.

Running from the stick leaves the PC's hard disk alone. **Everything runs from RAM**, though: TempleOS can't write to the stick, so anything you save is gone when you switch off. To keep your work, install TempleOS on the hard disk. Type

```
HDInstall;
```

and then `YES`. **This erases the whole hard disk** and makes it TempleOS's drives `C:` and `D:`. When it says "Done", take the stick out, restart, and press `1` at "TempleOS Boot Loader".

## Tested PCs

| PC                         | Folder                                                   | Boots from USB | Installs to disk |      Sound      |
| -------------------------- | -------------------------------------------------------- | :------------: | :--------------: | :--------------: |
| eMachines eM350 netbook    | [`Emachines EM350`](<Emachines%20EM350/>)               |      yes      |       yes       |    beep boop    |
| Lenovo ThinkPad Edge E530c | [`Lenovo ThinkPad E530c`](<Lenovo%20ThinkPad%20E530c/>) |      yes      |       yes       | no beep boop yet |

✅ works on the real PC · 🧪 passes the QEMU tests in `mkusb.py`, not confirmed on the real PC yet

The ThinkPad's BIOS setup (F1 at power-on) needs:

- Security → Secure Boot: **Disabled** (if it has that)
- Startup → UEFI/Legacy Boot: **Legacy Only**
- Config → Serial ATA (SATA) → SATA Controller Mode Option: **Compatibility**

## Things to try

The prompt is a HolyC compiler, so statements end with `;`.

- `"Hello, world!\n";` prints it: a string on its own is a print statement.
- `Snd(60); Sleep(400); Snd(67); Sleep(400); Snd(72); Sleep(400); Snd;` plays three notes on the real speakers.
- `HdaInit;` shows what the sound driver found, and `hda_vol=20000;` makes it louder (0 to 32767, default 8000).
- `#include "::/Apps/Psalmody/Run"` starts the music program.
- `Cd("::/Demo/Games"); Dir;` lists the games. Right-click one to run it, left-click to open its source.
- Ctrl+M opens the menu, F1 the help.

## Build it yourself

You need Python 3.8 or newer, [QEMU](https://www.qemu.org/) (`qemu-system-x86_64` and `qemu-img`) and [NASM](https://www.nasm.us/) on your `PATH`.

```sh
cd "Lenovo ThinkPad E530c"
python mkusb.py                # build the image, then test it
python mkusb.py --test-only    # only test the image that's there
```

`mkusb.py` never writes to a real disk, only to `TempleOS-USB.img` in its own folder, which it replaces. Each folder's image is the one that was tested on that PC, so a rebuild swaps a known-good image for an untried one. Extra arguments go to QEMU for the test runs, e.g. `-accel whpx` on Windows.

How it works: `mkusb.py` boots the original ISO in QEMU and types one line. TempleOS does the rest itself: it copies its files to a RAM disk, applies the source changes and recompiles its own kernel. `mkusb.py` saves that RAM disk, with `boot.asm` in front, as the image. Then it tests the image on a QEMU PC set up like the real one. It boots the image from a virtual USB stick, records the sound card to check the notes, and checks every command the sound driver sends to a stand-in for that PC's sound chip (built from the Linux codec dump in the folder). Last, it installs TempleOS onto a blank virtual disk of the PC's size and boots that too.

**Another PC?** Copy the ThinkPad folder and change what its tests imitate: the PC's sound chip (dump it under Linux from `/proc/asound/card0/codec#0`), the commands the driver should send it, the RAM, the number of cores and the disk size. If you get TempleOS running on a new PC, a folder for it is welcome here.

## What's in here

- [`TempleOS original/`](<TempleOS%20original/>): Terry's TempleOS V5.03 ISO, unmodified (byte for byte the one [templeos.org](https://templeos.org/) offers)
- [`Emachines EM350/`](<Emachines%20EM350/>): the eM350 image and everything that makes it
- [`Lenovo ThinkPad E530c/`](<Lenovo%20ThinkPad%20E530c/>): the same for the ThinkPad

Each PC's folder holds:

| File                 |                                                          |
| -------------------- | -------------------------------------------------------- |
| `TempleOS-USB.img` | the image to flash                                       |
| `mkusb.py`         | builds and tests the image                               |
| `boot.asm`         | the boot sector that copies TempleOS into RAM            |
| `SndHDA.HC`        | the HD Audio sound driver, in HolyC                      |
| `HDInstall.HC`     | the hard disk installer, in HolyC                        |
| `*-codec.txt`      | the PC's sound chip as Linux describes it, for the tests |

The eM350's folder also has its own copy of the original ISO, which its `mkusb.py` builds from, and `run.cmd`, which boots the unmodified ISO in QEMU on Windows.

## Not done yet

- **A USB driver.** TempleOS still can't read or write the stick once it runs; the image gets around that by loading everything into RAM first. With a driver, it could save to the stick.
- **AHCI.** A PC whose BIOS has no IDE mode can boot the stick, but TempleOS can't see its hard disk.
- **Sound on more controllers.** `SndHDA.HC` uses the HD Audio "immediate command" registers, which Intel's controllers have and the standard doesn't require. If `HdaInit;` says "A codec doesn't answer", that's why.

## Credits

- **Terry A. Davis**, for every line of TempleOS.
- [templeos.org](https://templeos.org/) and the TempleOS community, for keeping it available.
- The people who posted the Linux codec dumps that the sound tests are built from (links in each `*-codec.txt`), and Linux's `ata_piix` driver, which does the same 16-bit disk fix.

TempleOS itself is public domain, and so is this.

RIP Terry
