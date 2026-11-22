#!/usr/bin/env python3
"""Build TempleOS-USB.img, a BIOS-bootable USB image of TempleOS.ISO that runs from RAM,
for the Lenovo ThinkPad Edge E530c.

TempleOS has no USB driver, so after a USB boot it can't read its own files.
Here the boot sector (boot.asm) copies the whole file system into RAM at 16MB
through the BIOS, and a kernel configured to mount RAM drive A: at that address
takes over.  TempleOS makes all of it itself: we boot the stock ISO in QEMU,
type one line, and it runs BUILD_HC below.  Then we boot the result as a USB
stick and run TEST_HC.  The image also gets SndHDA.HC, a driver that plays
TempleOS's sound on the PC's sound chip instead of the PC speaker, and
HDInstall.HC, which installs TempleOS from the stick onto a PC's hard disk.
Last, the stick's TempleOS does that to a blank disk (see INSTALL_HC), and we
boot and test the disk too.

    python mkusb.py          # needs qemu-system-x86_64 and nasm on PATH

Only writes TempleOS-USB.img next to this file, never a physical disk.  Flash
it to a stick yourself (Rufus in "DD image" mode, balenaEtcher, dd).

The ThinkPad's setup (F1 at power-on) has to say this, or it won't start the
stick, or TempleOS won't find the hard disk:
    Security > Secure Boot: Disabled (if it has that)
    Startup > UEFI/Legacy Boot: Legacy Only
    Config > Serial ATA (SATA) > SATA Controller Mode Option: Compatibility

Made from ../Emachines EM350/mkusb.py, whose image that netbook runs.  What
differs: where the ISO is, source changes 6 to 10, HDInstall.HC checking what
it gets, testing the disk when that is nothing and reading back what it wrote,
when run() types, and the PC the tests imitate (the ThinkPad's sound codec, 4
Intel CPUs, over 4GB of RAM, its 250GB disk on an IDE controller at the
standard ports, at first taking no writes; and data may only go through I/O
ports 16 bits at a time, and off a disk one block a command).
"""
import array, json, os, re, socket, struct, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ISO = os.path.join(HERE, "..", "TempleOS original", "TempleOS.ISO")
IMG = os.path.join(HERE, "TempleOS-USB.img")
BLKS = 131072             # size of drive A: in 512-byte blocks: 64MB, ~46MB of it free
CHUNK = 64                # = CHUNK in boot.asm
SCRIPT_ADDR = 0x10000000  # guest RAM where QEMU preloads our HolyC; TempleOS doesn't get near it
DATA_ADDR = 0x10100000    # and a file for it: SndHDA.HC for the build, a sound codec for the test
CODEC = os.path.join(HERE, "e530-codec.txt")  # the ThinkPad's sound codec, as Linux describes it
MEM = "4352M"             # RAM of the PCs the tests boot: over 4GB, as in the ThinkPad, which TempleOS splits into its
                          # two heaps differently from less.  QEMU puts 3GB of this below the 4GB line, the rest above
DISK = 488397168 * 512    # the ThinkPad's disk, a 250GB SSD, in bytes

PRELUDE = """
*@ADDR@(U8 *)=0; //Run once, even if the ExePutS line gets typed again.

U0 UsbLog(U8 *fmt,...)
{//printf to QEMU's debug console (port 0xE9), which mkusb.py reads.
  U8 *buf=StrPrintJoin(NULL,fmt,argc,argv),*p=buf;
  while (*p)
    OutU8(0xE9,*p++);
  Free(buf);
}
UsbLog("HELLO\\n");
"""

# For the tests of the image: nothing may move data through an I/O port 32 bits at a time any more, or ask a disk
# for more than one block in a read command.  The disk driver did both, and the ThinkPad's disk controller can't
# do the one and gets the other wrong (source changes 7 and 9); QEMU's can, so the driver has to be caught at it.
THINKPAD_HC = """
U0 UsbPio32(U8 *buf,I64 cnt,I64 port)
{//Stands in for the kernel's RepInU32() and RepOutU32().
  no_warn buf,cnt;
  UsbLog("PIO32 at port %X\\n",port);
}
U8 *usb_p=&RepInU32;
*usb_p=0xE9;	//JMP UsbPio32
*(usb_p+1)(I32 *)=&UsbPio32-usb_p-5;
usb_p=&RepOutU32;
*usb_p=0xE9;
*(usb_p+1)(I32 *)=&UsbPio32-usb_p-5;

U8 usb_rd[5];
U0 UsbReadBlks(CBlkDev *bd,U8 *buf,I64 blk,I64 cnt)
{//Stands in front of the kernel's ATAReadBlks(), the disk driver's one way to a read command.
  if (cnt>1)
    UsbLog("MULTI %d blocks in one read command, from %X\\n",cnt,blk);
  MemCpy(&ATAReadBlks,usb_rd,5);
  ATAReadBlks(bd,buf,blk,cnt);
  usb_p=&ATAReadBlks;
  *usb_p=0xE9;
  *(usb_p+1)(I32 *)=&UsbReadBlks-usb_p-5;
}
MemCpy(usb_rd,&ATAReadBlks,5);
usb_p=&ATAReadBlks;
*usb_p=0xE9;
*(usb_p+1)(I32 *)=&UsbReadBlks-usb_p-5;
"""

BUILD_HC = PRELUDE + """
U0 UsbPatch(U8 *filename,U8 *old,U8 *rep,U8 *hdr,I64 cnt)
{//Prepend hdr to a source file and replace all cnt occurrences of old.
  U8 *src=FileRead(filename),*dst=MAlloc(2*StrLen(src)+StrLen(hdr)+1),
	*s=src,*d=dst,*p;
  StrCpy(d,hdr);
  d+=StrLen(hdr);
  while (p=StrFind(old,s)) {
    MemCpy(d,s,p-s);
    d+=p-s;
    StrCpy(d,rep);
    d+=StrLen(rep);
    s=p+StrLen(old);
    cnt--;
  }
  StrCpy(d,s);
  if (cnt)
    throw('UsbPatch');
  FileWrite(filename,dst,StrLen(dst));
  Free(src);
  Free(dst);
}

U0 UsbBuild()
{
  CBlkDev *bd;
  CDrv *dv;
  CDirEntry de;
  I64 i;

//RAM drive A: with a copy of the CD.  Like Mount() does it, but zeroed
  //so no stray memory ends up in the image.
  bd=BlkDevNextFreeSlot('A',BDT_RAM);
  bd->RAM_dsk=ACAlloc(@BLKS@<<BLK_SIZE_BITS);
  bd->max_blk=@BLKS@-1;
  bd->drv_offset=19<<2+(DVD_BLK_SIZE*2+DVD_BOOT_LOADER_SIZE)/BLK_SIZE;
  BlkDevAdd(bd,,FALSE,TRUE);
  CopyTree("T:/","A:/");

//Source change 1: the boot sector preloads A: right above the 16MB
  //line, where the code heap normally starts.  Start the heap after it.
  //Only in a kernel that boots from a RAM drive: one installed on a hard disk
  //from this stick is compiled from the same source, and has nothing there.
  UsbPatch("A:/Kernel/Mem/BlkPool.HC.Z","SYS_16MEG_AREA_LIMIT","USB_RAMDSK_END",
	"#exe {StreamPrint(\\"#define USB_RAMDSK_END (SYS_16MEG_AREA_LIMIT+%d*BLK_SIZE)\\\\n\\","
	"@BLKS@*(Let2BlkDevType(kernel_cfg->boot_drv_let)==BDT_RAM));}; "
	"//USB boot: RAM drive A: is preloaded below this.\\n",3);

//Source change 2, a stock TempleOS bug real PCs trip over: in kernel asm
  //"&dev" is dev's offset in the kernel file, not its address, so every core
  //but the first looked up its APIC through whatever the BIOS left in low
  //memory and crashed at "MultiCore Start".  [&dev] is RIP-relative, so right.
  UsbPatch("A:/Kernel/KInts.HC.Z","MOV\\tEAX,&dev","LEA\\tRAX,[&dev]",
	"//USB boot: LEA RAX,[&dev] was MOV EAX,&dev, which reads the wrong address.\\n",2);

//Source change 3, the same kind of bug: the kernel's 16 bit start-up code says
  //[SI] where the assembler makes it [ESI], and reads the BIOS's memory map
  //from the wrong place if a boot loader leaves the top half of ESI set.
  //boot.asm does, on purpose; what a BIOS leaves TempleOS's hard disk boot
  //loaders with is anyone's guess.
  UsbPatch("A:/Kernel/KStart16.HC.Z","\\tMOV\\tSI,MEM_E820",
	"\\tXOR\\tESI,ESI\\n\\tMOV\\tSI,MEM_E820",
	"//USB boot: XOR ESI,ESI added, as [SI] is really [ESI] here.\\n",1);

//Source change 4: TempleOS only has the PC speaker.  SndHDA.HC, which QEMU
  //preloaded at @DATA@, plays its sound on the sound chip.  Adam runs it at boot.
  FileWrite("A:/Adam/SndHDA.HC.Z",@DATA@(U8 *),StrLen(@DATA@(U8 *)));
  UsbPatch("A:/Adam/MakeAdam.HC.Z","#include \\"ASnd\\"",
	"#include \\"ASnd\\"\\n#include \\"SndHDA\\"","",1);

//Source change 5: HDInstall.HC, preloaded after SndHDA.HC.  It puts TempleOS on
  //a hard disk that TempleOS's own installer can't find.  Loaded at boot, so
  //that typing HDInstall; is all it takes.
  FileWrite("A:/Misc/HDInstall.HC.Z",(@DATA@+0x100000)(U8 *),
	StrLen((@DATA@+0x100000)(U8 *)));
  UsbPatch("A:/MakeHome.HC.Z","#include \\"/Adam/Opt/Utils/MakeUtils\\"",
	"#include \\"/Adam/Opt/Utils/MakeUtils\\"\\n#include \\"::/Misc/HDInstall\\"","",1);

//Source change 6: at every boot the kernel searches the BIOS for 32 bit PCI
  //services, calls into what it finds, and later asks them whether to switch a
  //timer chip (the HPET) on.  The netbook's BIOS has none and nothing is missed:
  //SndHDA.HC and HDInstall.HC read PCI themselves.  The ThinkPad's BIOS is UEFI
  //firmware imitating one, so don't search: then it is as on the netbook.
  UsbPatch("A:/Kernel/KStart32.HC.Z","\\tCALL\\tSYS_FIND_PCIBIOS_SERVICE_DIR\\n","",
	"//USB boot: CALL SYS_FIND_PCIBIOS_SERVICE_DIR taken out, to leave the BIOS's PCI services alone.\\n",1);

//Source change 7: the disk driver moves a block through a drive's data port
  //32 bits at a time.  The ThinkPad's SATA chip (Intel 7 series, in IDE mode)
  //doesn't take that: after the first block written so, the disk went on
  //waiting for data and ignored every command.  Linux has it down as a fault
  //of these chips and does what this does (ata_piix.c, PIIX_FLAG_PIO16): 16
  //bits at a time, which is what an IDE data port was made for.
  UsbPatch("A:/Kernel/BlkDev/DskATA.HC.Z","RepInU32(buf,avail>>2,","RepInU16(buf,avail>>1,",
	"//USB boot: RepInU16() and RepOutU16() were RepInU32() and RepOutU32(), "
	"which Intel's SATA chips since 2011 can't do in IDE mode.\\n",1);
  UsbPatch("A:/Kernel/BlkDev/DskATA.HC.Z","RepOutU32(buf,U32s_avail,","RepOutU16(buf,U32s_avail<<1,","",2);

//Source change 8, a stock TempleOS bug met on the way: when a disk's new
  //partitions don't turn up (here, because they never got written), DskPrt()
  //goes on to format "drive 0", which is the drive one is on.  That was the
  //stick's own drive A:.
  UsbPatch("A:/Adam/ABlkDev/DskPrt.HC.Z","  BlkDevAdd(bd,,FALSE,TRUE);\\n",
	"  if (!BlkDevAdd(bd,,FALSE,TRUE))\\n    throw('BlkDev');\\n",
	"//USB boot: throw('BlkDev') added: BlkDevAdd() failing left drive 0, the current one, to be formatted.\\n",1);

//Source change 9: the disk driver has a hard disk send up to 128 blocks for
  //one command and takes each as soon as the disk says there is one to take
  //(DRQ), never mind whether it also says it is busy (BSY), which the ATA
  //standard says to wait out first, and gives a disk 400ns to say.  QEMU's
  //disks and the netbook's get by.  Not the ThinkPad's, by what happened
  //there: installed, TempleOS stopped at "Loading Compiler", a file's chain of
  //blocks cut short.  This fits that, down to the error message, when QEMU's
  //disk is made to act so: of a read command for several blocks only the
  //first comes right, and the controller, left holding data, takes no new
  //command.  What is written then goes nowhere, until a read of one block
  //gets junk for an answer and all is well again.  Installing reads several
  //blocks a thousand times (what was in blocks it is about to fill), and so
  //lost a quarter of what it wrote, without a sign: all it reads back to use
  //comes out of TempleOS's disk cache.  The driver always wrote one block a
  //command.  Now it reads that way too, which is how every read went that is
  //known to have worked on the ThinkPad.
  //ponytail: slower, every block paying for a command.  Should that matter,
  //have ATAGetRes() wait for BSY to go between blocks instead, and try that
  //on the ThinkPad itself.
  UsbPatch("A:/Kernel/BlkDev/DskBlkDev.HC.Z","bd->max_reads=128;\\n\\tbd->max_writes=1;",
	"bd->max_reads=1;\\n\\tbd->max_writes=1;",
	"//USB boot: a hard disk's max_reads=1 was 128.  More than a block a command seems to go wrong on the ThinkPad.\\n",1);

//Source change 10, the same haste after a write: the driver asks at once
  //whether the disk is busy with the block it was just given, and the disk
  //has those 400ns to say so.  Asking four times first is the usual way to
  //wait them out.  A precaution: nothing points to this having cost a write.
  //Whether one gets lost, HDInstall now checks (HDIVerify() in HDInstall.HC).
  UsbPatch("A:/Kernel/BlkDev/DskATA.HC.Z","Bool ATAWaitNotBUSY(CBlkDev *bd,F64 timeout)\\n{\\n  I64 i;\\n",
	"Bool ATAWaitNotBUSY(CBlkDev *bd,F64 timeout)\\n{\\n  I64 i;\\n"
	"  for (i=0;i<4;i++)\\t//USB boot: added, the 400ns a disk has to say that it is busy.\\n"
	"    InU8(bd->base0+ATAR0_STAT);\\n","",1);

//Kernel config: boot drive A, drive A = RAM disk at 16MB of @BLKS@ blocks,
  //no other drives, default disk cache, no options.  See KCfg.HC and Mount2().
  Drv('A');
  FlushMsgs;
  In("AA0x%X\\n@BLKS@\\n\\n\\n\\n",SYS_16MEG_AREA_LIMIT);
  if (Cmp("/Kernel/Kernel","Kernel",,':'))
    throw('UsbCmp');
  Move("/Kernel/Kernel.BIN.Z","/0000Boot/0000Kernel.BIN.C");
  if (!FileFind("/0000Boot/0000Kernel.BIN.C",&de))
    throw('UsbKern');

//Last allocated block, from the allocation bitmap, so only that much gets loaded.
  dv=Let2Drv('A');
  i=dv->size+dv->drv_offset-dv->data_area;
  while (--i>=0 && !Bt(bd->RAM_dsk+dv->fat1<<BLK_SIZE_BITS,i));
  UsbLog("IMG %d %d %d %d %d\\n",bd->RAM_dsk,dv->data_area+i+1,de.clus,de.size,
	SYS_16MEG_AREA_LIMIT);
}

U0 UsbMain()
{
  try
    UsbBuild;
  catch {
    UsbLog("FAIL %c\\n",Fs->except_ch);
    Fs->catch_except=TRUE;
  }
}
UsbMain;
"""

TEST_HC = PRELUDE + THINKPAD_HC + """
U32 UsbCodecCmd(I64 nid,I64 verb,I64 val=0)
{//Stands in for SndHDA.HC's HdaCmd(): answers like the ThinkPad E530's codec,
//from the table mkusb.py made of Linux's description of it (16 U32s a widget:
//what it is, pin abilities, input and output volume, pin wiring, input count,
//inputs), and reports what the driver tells that codec to change.
  U32 *w=@DATA@(U32 *)+nid<<4;
  if (verb==0xF00)
    switch (val) {
      case 4:
	if (!nid) return 0x10001;	//Function group 1,
	if (nid==1) return 0x100016;	//with widgets 0x10-0x25.
	return 0;
      case 5:    return nid==1;	//It is an audio one.
      case 9:    return w[0];
      case 0xC:  return w[1];
      case 0xD:  return w[2];
      case 0x12: return w[3];
      case 0xE:  return w[5];
      default:   return 0;
    }
  if (verb==0xF1C)
    return w[4];
  if (verb==0xF02)
    return w[6+val]|w[7+val]<<8|w[8+val]<<16|w[9+val]<<24;
  UsbLog("VERB %02X %03X %X\\n",nid,verb,val);
  return 0;
}

U0 UsbTest()
{
  CMemBlk *m,*head=NULL;
  U8 *lo=SYS_16MEG_AREA_LIMIT,*hi=lo+@BLKS@<<BLK_SIZE_BITS,*st,*res="OK";
  I64 mb=0,overlap=0,errs;

//Sound: three notes, which mkusb.py looks for in QEMU's recording of its
  //sound card.  Then the driver has to set up a fake of the ThinkPad's codec.
  Snd(60);
  Sleep(300);
  Snd(67);
  Sleep(300);
  Snd(72);
  Sleep(300);
  Snd;
  st=&HdaCmd;
  *st=0xE9;	//JMP UsbCodecCmd
  *(st+1)(I32 *)=&UsbCodecCmd-st-5;
  hda_cad=0;
  HdaCodec;

//File system must check out and be writable.
  errs=DskChk(':');
  FileWrite("::/Tmp/UsbTest.TXT","TempleOS",8);
  st=FileRead("::/Tmp/UsbTest.TXT");
  if (!st || StrCmp(st,"TempleOS"))
    errs++;
  Del("::/Tmp/UsbTest.TXT");

//A USB boot's heap must never hand out its RAM disk, the 64MB at 16MB; a hard
  //disk boot's heap should use them.  Take all memory, 1MB at a time.
  PUSHFD
  CLI
  while (m=MemPagAlloc(0x100000>>MEM_PAG_BITS)) {
    if (m(U8 *)<hi && m(U8 *)+m->pags<<MEM_PAG_BITS>lo)
      overlap++;
    m->next=head;
    head=m;
    mb++;
  }
  while (m=head) {
    head=m->next;
    MemPagFree(m);
  }
  POPFD

  if (errs || !mb)
    res="FAILED";
  UsbLog("TEST %s boot drive %c: %dMB heap, %dMB of it where a USB boot has "
	"its RAM disk, %d file system errors, %d cores, BIOS PCI services at %X\\n",
	res,blkdev.boot_drv_let,mb,overlap,errs,mp_cnt,sys_pci_services);
}
UsbTest;
"""

# To put TempleOS on the hard disk of a real PC booted from the stick, type  HDInstall;  and then YES.  It
# ERASES the whole disk, makes drives C: and D: of it, and wants the BIOS to run SATA in IDE mode, which the
# ThinkPad's calls "Compatibility": TempleOS can't use AHCI.  Here HDInstall.HC meets QEMU's own PC: an IDE
# controller that leaves its address registers 0, its two channels being at the standard ports.  The ThinkPad's
# does that too.  (One that says in those registers where its channels are, as the netbook's does, is what
# ../Emachines EM350/mkusb.py tests.)
#
# First, though, the disk takes no writes, so that its new partitions don't turn up.  That is what happened on the
# ThinkPad (source change 7), and TempleOS's own installer then formatted the drive it was running from, the
# stick's A:, before failing (source change 8).  HDInstall has to stop and leave A: as it is.
#
# After the real install HDInstall reads back what it wrote (on the ThinkPad it said "Done" and the disk didn't
# start, source change 9): that must come out right, and wrong by one block once one byte on the disk is changed.
# The byte is in drive C:'s boot block, so that the boot test of the disk fails too if it isn't put back.
INSTALL_HC = PRELUDE + THINKPAD_HC + """
U32 *usb_wr=&ATAWriteBlks,usb_old=*usb_wr;
*usb_wr=0x20C2;	//RET1 32: the disk driver's ATAWriteBlks() does nothing.
FlushMsgs;
In("YES\\n");
HDInstall;
*usb_wr=usb_old;
UsbLog("DEAD: drive C %d, A:/Kernel %d\\n",Let2Drv('C',FALSE)!=NULL,FileFind("A:/Kernel",,FUF_JUST_DIRS));
FlushMsgs;
In("YES\\n");
HDInstall;

CBlkDev *usb_bd=Let2BlkDev('C');
I64 usb_blk=Let2Drv('C')->drv_offset,usb_bad;
U8 usb_buf[BLK_SIZE];
ATAReadBlks(usb_bd,usb_buf,usb_blk,1);
usb_buf[100]^=1;
ATAWriteBlks(usb_bd,usb_buf,usb_blk,1);
usb_bad=HDIVerify(usb_bd);
usb_buf[100]^=1;
ATAWriteBlks(usb_bd,usb_buf,usb_blk,1);
UsbLog("INS done: %d blocks not as written, %d with one changed\\n",hdi_bad,usb_bad);
"""


def esc(path):
    return path.replace(",", ",,")  # QEMU option syntax


def blob(tmp, name, data, addr):
    """QEMU arguments that preload bytes at an address in guest RAM."""
    path = os.path.join(tmp, name)
    open(path, "wb").write(data)
    return ["-device", f"loader,file={esc(path)},addr={addr:#x},force-raw=on"]


def vm(tmp, holyc, *args):
    """Start QEMU with HolyC source preloaded in guest RAM. Returns (process, qmp, debug log)."""
    log = os.path.join(tmp, "debugcon.log")
    src = holyc.replace("@ADDR@", hex(SCRIPT_ADDR)).replace("@DATA@", hex(DATA_ADDR)).replace("@BLKS@", str(BLKS))
    open(log, "wb").close()
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    proc = subprocess.Popen([
        "qemu-system-x86_64", "-display", "none",
        "-qmp", f"tcp:127.0.0.1:{port},server=on,wait=off",
        "-debugcon", "file:" + esc(log),
        *blob(tmp, "script.HC", src.encode("ascii") + b"\0", SCRIPT_ADDR), *args])
    for _ in range(100):
        try:
            sock = socket.create_connection(("127.0.0.1", port))
            break
        except OSError:
            time.sleep(0.1)
    chan = sock.makefile("rw")

    def qmp(cmd, **kw):
        chan.write(json.dumps({"execute": cmd, "arguments": kw}) + "\n")
        chan.flush()
        while True:  # skip async events
            reply = json.loads(chan.readline())
            if "error" in reply:
                raise RuntimeError(f"{cmd}: {reply['error']['desc']}")
            if "return" in reply:
                return reply["return"]

    chan.readline()  # greeting
    qmp("qmp_capabilities")
    return proc, qmp, log


def run(qmp, log, tag, timeout=900, first=""):
    """Type `ExePutS(addr);` at the TempleOS prompt until the script reports in; return its `tag` line."""
    # /Once.HC asks one or two y/n questions first. "//n" answers one, and is a comment at the prompt.
    line = f"//n\n//n\nExePutS({SCRIPT_ADDR:#x});\n"
    qcode = {"(": ["shift", "9"], ")": ["shift", "0"], ";": ["semicolon"], "/": ["slash"], "\n": ["ret"]}
    out = lambda: open(log, "rb").read().decode("latin1")
    peek = lambda addr: int(qmp("human-monitor-command", **{"command-line": f"xp /1wx {addr:#x}"}).split()[1], 16)
    start = time.time()

    def wait(pattern, secs):
        end = time.time() + secs
        while time.time() < end:
            if m := re.search(pattern, out(), re.M):
                return m.group()
            time.sleep(0.25)

    def type_(text):
        for ch in text:
            if "HELLO" in out():
                break
            keys = qcode.get(ch) or (["shift", ch.lower()] if ch.isupper() else [ch])
            qmp("send-key", keys=[{"type": "qcode", "data": k} for k in keys])
            time.sleep(0.15)

    # Not a key while TempleOS boots: one that lands in front of what its first window is told to run makes that
    # a syntax error, and until the boot is over an error means the debugger, with all other tasks stopped.  The
    # kernel is at 0x7C00, "TOSB" in its header, and says in sys_run_level at 0x7C30 how far it is: bit 18 is
    # "booted".  While there is no kernel yet, `first` is for a boot loader's menu.
    while time.time() - start < 300:
        if peek(0x7C04) != 0x42534F54:
            type_(first)
        elif peek(0x7C30) >> 18 & 1:
            break
        time.sleep(1)
    while not wait("HELLO", 8):
        if time.time() - start > 300:
            break
        type_(line)
    result = wait(f"^({tag}|FAIL|PIO32|MULTI).*\n", timeout) if "HELLO" in out() else None
    if not result or not result.startswith(tag):
        shot = os.path.join(HERE, "mkusb-failed.png")
        qmp("screendump", filename=shot, format="png")
        sys.exit(f"TempleOS said: {result or 'nothing'}. Screenshot: {shot}")
    return result.strip()


def build(tmp):
    print("Building in QEMU: TempleOS copies itself to a RAM disk and recompiles its kernel...", flush=True)
    files = []  # our HolyC, for BUILD_HC to copy into the image: one every MB from DATA_ADDR
    for name in "SndHDA.HC", "HDInstall.HC":
        text = open(os.path.join(HERE, name), "rb").read().replace(b"\r", b"") + b"\0"
        text = text.replace(b"@BUILT@", time.strftime("%Y-%m-%d %H:%M").encode())  # HDInstall says which image it is
        files += blob(tmp, name, text, DATA_ADDR + len(files) // 2 * 0x100000)
    proc, qmp, log = vm(tmp, BUILD_HC, "-m", "2G", "-cdrom", ISO, "-boot", "d", *files)
    try:
        addr, used, kernel_blk, kernel_bytes, base = map(int, run(qmp, log, "IMG").split()[1:])
        dump = os.path.join(tmp, "ramdsk.bin")
        qmp("pmemsave", val=addr, size=BLKS * 512, filename=dump)
    finally:
        proc.kill()
        proc.wait()  # or Windows won't let the temp dir go
    img = bytearray(open(dump, "rb").read())
    assert img[88 * 512 + 3] == 0x88, "no RedSea file system in the RAM disk dump"
    assert img[kernel_blk * 512 + 4:kernel_blk * 512 + 8] == b"TOSB", "kernel not where TempleOS said"
    sects = -(-used // CHUNK) * CHUNK
    boot = os.path.join(tmp, "boot.bin")
    subprocess.run(["nasm", "-f", "bin", f"-DRAMDSK_BASE={base}", f"-DIMG_SECTS={sects}",
                    f"-DKERNEL_BLK={kernel_blk}", f"-DKERNEL_BYTES={kernel_bytes}", f"-DDISK_SECTS={BLKS}",
                    "-o", boot, os.path.join(HERE, "boot.asm")], check=True)
    img[:512] = open(boot, "rb").read()
    open(IMG, "wb").write(img)
    print(f"{IMG}: {len(img) >> 20}MB, {sects * 512 / 2**20:.1f}MB loaded at boot, "
          f"kernel {kernel_bytes} bytes at block {kernel_blk}")


def codec_table(path):
    """Linux's /proc/asound dump of a sound codec as the table TEST_HC's UsbCodecCmd() answers from."""
    widgets, nid = {}, 0
    for line in open(path):
        if m := re.match(r"Node (\w+) .* wcaps (\w+)", line):
            nid = int(m[1], 16)
            widgets[nid] = [int(m[2], 16), 0, 0, 0, 0, 0]
        elif m := re.match(r" +Amp-(In|Out) caps: ofs=(\w+), nsteps=(\w+), stepsize=(\w+), mute=(\w+)", line):
            ofs, steps, size, mute = (int(x, 16) for x in m.groups()[1:])
            widgets[nid][2 + (m[1] == "Out")] = mute << 31 | size << 16 | steps << 8 | ofs
        elif m := re.match(r" +(Pincap|Pin Default|Connection:) (\w+)", line):
            widgets[nid][{"Pincap": 1, "Pin Default": 4, "Connection:": 5}[m[1]]] = int(m[2], 0)
        elif re.fullmatch(r"\s+(0x\w+\*?\s+)+", line):  # the connections themselves
            widgets[nid] += [int(x.rstrip("*"), 16) for x in line.split()]
    return b"".join(struct.pack("<16I", *(widgets.get(n, []) + [0] * 16)[:16]) for n in range(max(widgets) + 1))


def tones(path):
    """Pitch in Hz of each 50ms of the left channel of QEMU's WAV recording, from its rising zero crossings."""
    data = open(path, "rb").read()  # by hand: QEMU leaves the header's lengths 0, which the wave module won't read
    channels, rate = struct.unpack_from("<HI", data, 22)
    left = array.array("h", data[44:len(data) - (len(data) - 44) % (2 * channels)])[::channels]
    for at in range(0, len(left) - rate // 20, rate // 20):
        up = [i for i in range(at + 1, at + rate // 20) if left[i - 1] < 0 <= left[i]]
        yield (len(up) - 1) * rate / (up[-1] - up[0]) if len(up) > 1 else 0


def install(tmp, *args):
    """Have the stick's TempleOS install itself on a blank IDE disk the size of the ThinkPad's. Returns QEMU's disk arguments."""
    print("Installing from the USB stick onto a blank hard disk in QEMU, with HDInstall...", flush=True)
    hd = os.path.join(tmp, "hd.qcow2")
    subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", hd, str(DISK)], check=True)
    disk = ["-drive", f"file={esc(hd)},format=qcow2,if=ide"]
    proc, qmp, log = vm(tmp, INSTALL_HC, "-m", MEM, *disk, *args)
    try:
        result = run(qmp, log, "INS")
        qmp("quit")  # not kill: QEMU still has to finish the disk file
        proc.wait(30)
    finally:
        proc.kill()
        proc.wait()
    # The first HDInstall, on the disk that takes no writes: no drive C: may be left, and A: must still have its files.
    if "\nDEAD: drive C 0, A:/Kernel 1\n" not in open(log, encoding="latin1").read():
        sys.exit("Install test FAILED: HDInstall didn't stop, or drive A: got formatted, when the disk took no writes")
    if result != "INS done: 0 blocks not as written, 1 with one changed":
        sys.exit(f"Install test FAILED: HDInstall's reading back of the disk is off. {result}")
    return disk


def test(tmp, what, drive, *args, first=""):
    """Boot a PC like the target (4 CPUs, HD Audio, MEM of RAM) off `args`, run TEST_HC, check what it reports and plays."""
    print(f"Boot-testing {what} in QEMU...", flush=True)
    wav = os.path.join(tmp, "sound.wav")
    proc, qmp, log = vm(tmp, TEST_HC, "-m", MEM, "-smp", "4", "-audiodev", f"wav,id=snd,path={esc(wav)}",
                        "-device", "intel-hda", "-device", "hda-output,audiodev=snd",
                        # Intel's name on the CPU: QEMU's own choice says AMD, for which its BIOS lists a reserved
                        # area just below 1TB, and TempleOS maps everything up to the end of the BIOS's list.
                        "-cpu", "qemu64,vendor=GenuineIntel",
                        # A real BIOS leaves its junk in low memory, QEMU hands it over zeroed.  That hid the
                        # stray pointer the KInts.HC patch in BUILD_HC is about, so fake the junk.
                        *blob(tmp, "junk.bin", b"\xCC" * (0x7C00 - 0x500), 0x500),
                        *blob(tmp, "codec.bin", codec_table(CODEC), DATA_ADDR), *args)
    try:
        result = run(qmp, log, "TEST", first=first)
        qmp("quit")  # not kill: QEMU still has to write out the end of the recording
        proc.wait(30)
    finally:
        proc.kill()
        proc.wait()
    print(result)
    # Right drive?  All 4 CPUs?  The PCI services that QEMU's BIOS has, not looked for (source change 6)?  And the
    # 64MB at 16MB must be heap exactly when no RAM disk (drive A:) is there.
    m = re.search(r"boot drive (\w): \d+MB heap, (\d+)MB of it .* 4 cores, BIOS PCI services at 0$", result)
    if not result.startswith("TEST OK") or not m or m[1] != drive or (m[2] == "0") != (drive == "A"):
        sys.exit(f"Boot test FAILED: wanted boot drive {drive}, 4 cores and no BIOS PCI services")

    # The notes TEST_HC played (ona 60, 67, 72) must be in the recording, in that order, each within 1%.
    notes, heard = [440.0, 659.3, 880.0], []
    for hz in tones(wav):
        note = next((n for n in notes if abs(hz - n) < n / 100), None)
        if note and heard[-1:] != [note]:
            heard.append(note)
    # And the ThinkPad's codec must have been told exactly this, worked out by hand from e530-codec.txt: all of
    # it is powered on, DAC 10 plays stream 1 at 0dB, headphone socket 19 and speaker 1F listen to it and are
    # switched on, and the amplifier switches of 1B and 1D (EAPD) are on.  Linux leaves the codec like that too,
    # but for giving the headphones DAC 11.
    verbs = set(re.findall(r"^VERB (.+)$", open(log, encoding="latin1").read(), re.M))
    want = {f"{nid:02X} 705 0" for nid in [1, *range(0x10, 0x26)]} | set(re.findall(r"\w+ \w+ \w+", """
        10 200 11, 10 706 10, 10 300 B04A, 1B 70C 2, 1D 70C 2,
        19 701 0, 19 707 C0, 1F 701 0, 1F 707 40"""))
    print(f"Sound: QEMU's sound card played {heard} Hz; the E530's codec got {len(verbs)} commands")
    if heard != notes or verbs != want:
        sys.exit(f"Sound test FAILED: wanted {notes} Hz, and the codec commands differ in {sorted(verbs ^ want)}")


if __name__ == "__main__":
    more = [a for a in sys.argv[1:] if a != "--test-only"]  # extra arguments go to QEMU, e.g. -accel whpx
    with tempfile.TemporaryDirectory() as tmp:
        if "--test-only" not in sys.argv:
            build(tmp)
        stick = ["-device", "usb-ehci", "-drive", f"if=none,id=stick,format=raw,readonly=on,file={esc(IMG)}",
                 "-device", "usb-storage,drive=stick,bootindex=0"]
        test(tmp, "the image as a USB stick", "A", *stick, *more)
        disk = install(tmp, *stick, *more)
        test(tmp, "the hard disk it installed itself on", "C", *disk, *more, first="1;")  # 1: "Drive C" in the boot menu
