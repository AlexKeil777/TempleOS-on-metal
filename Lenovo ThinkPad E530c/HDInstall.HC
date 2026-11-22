//Puts TempleOS on the hard disk of a PC booted from the USB stick.  Type
//  HDInstall;
//mkusb.py puts this file in the image as /Misc/HDInstall.HC.Z, loaded at boot.
//
//It is TempleOS's own installer (::/Misc/OSInstall.HC, the one for virtual
//machines: the whole disk becomes drives C: and D:) with another way of
//finding the disk.  TempleOS knows the two standard IDE port ranges and, for
//others, asks the BIOS's PCI services, which this image's kernel leaves alone
//(mkusb.py, source change 6).  So on a PC that puts its IDE channels at ports
//of its own, TempleOS would see no disk at all.  HDInstall() reads the ports
//from the disk controllers themselves, says what it finds there, and hands
//them to the installer.
//
//TempleOS has no AHCI driver: SATA has to be in IDE mode.  In the ThinkPad's
//BIOS setup that is Config, Serial ATA (SATA), SATA Controller Mode Option:
//Compatibility.
//
//The installer's Mount() and DskPrt() were made to be answered by hand.  Here
//HDIPrt() calls what they call, to see whether it worked: on the ThinkPad the
//disk took none of what the disk driver wrote to it, and the installer
//carried on regardless (mkusb.py, source changes 7 and 8).  HDIDiag() is
//what showed that.
//
//Nor does the installer find out whether the disk kept what it was given:
//what TempleOS reads back of that while installing comes out of its disk
//cache.  On the ThinkPad it finished, and the disk didn't start (mkusb.py,
//source change 9).  HDIVerify() reads it back from the disk itself.

#include "::/Misc/OSInstall"

extern I64 ATAGetDevId(CBlkDev *bd,F64 timeout,Bool keep_id_record);
extern U0 ATACmd(CBlkDev *bd,U8 cmd);
extern Bool ATAWaitNotBUSY(CBlkDev *bd,F64 timeout);

I64 hdi_base0,hdi_base1,hdi_unit,	//The hard disk found: its IDE channel's two port ranges, 0 master or 1 slave,
    hdi_gb,				//and its size.
    hdi_bad;				//After an install: how many blocks the disk didn't keep as written.

U0 HDIChannel(I64 base0,I64 base1)
{//Say what is on the IDE channel at these ports.  Note the first hard disk.
  CBlkDev bd;
  I64 i,unit,status=InU8(base0+7);
  U16 *id;
  U8 model[41];
  " IDE ports %04X,%04X: status %02X\n",base0,base1,status;
  if (status==0xFF || status==0x7F)	//Nothing answers there.  7F: the ThinkPad's SATA ports with nothing on them.
    return;
  for (unit=0;unit<2;unit++) {
    MemSet(&bd,0,sizeof(CBlkDev));	//As ATAProbe() does it, but patient, and keeping what the drive says of itself.
    bd.type=BDT_ATAPI;
    bd.base0=base0;
    bd.base1=base1;
    bd.unit=unit;
    bd.blk_size=DVD_BLK_SIZE;
    i=ATAGetDevId(&bd,tS+1.0,TRUE);
    if (i==BDT_ATAPI)
      "  unit %d: CD/DVD drive\n",unit;
    else if (i==BDT_ATA) {
      id=bd.dev_id_record;
      for (i=0;i<40;i++)	//Words 27-46 are its name, the letters swapped in pairs,
	model[i]=id[27+i>>1].u8[1-i&1];
      while (i && model[i-1]==' ')	//with spaces to fill.
	i--;
      model[i]=0;
      if (id[83]&0x400)	//Its size in 512 byte blocks: a 48 bit number,
	i=*(id+100)(I64 *);
      else	//or on old ones a 28 bit one.
	i=*(id+60)(U32 *);
      "  unit %d: %dGB hard disk\n  %s\n",unit,i/1953125,model;
      if (!hdi_base0) {
	hdi_base0=base0;
	hdi_base1=base1;
	hdi_unit=unit;
	hdi_gb=i/1953125;
      }
    }
    Free(bd.dev_id_record);
  }
}

U0 HDIFind()
{//Look for a hard disk on every IDE controller.  hdi_base0 stays 0 if there is none.
  I64 bdf,i,c,base0,base1;
  hdi_base0=0;
  for (bdf=0;bdf<0x10000;bdf++) {	//PCI bus<<8+dev<<3+fun, as in SndHDA.HC.
    c=HdaPci(bdf,8);
    if (c>>24==1) {	//Class 1: a disk controller.
      i=HdaPci(bdf,0);
      "Disk controller %04X:%04X at %02X:%02X.%d,\n type %06X, command %04X\n",
	    i&0xFFFF,i>>16,bdf>>8,bdf>>3&31,bdf&7,c>>8,HdaPci(bdf,4)&0xFFFF;
      if (c>>16&0xFF==1)	//IDE: two channels, each with its ports in two address registers,
	for (i=0x10;i<0x20;i+=8) {
	  base0=HdaPci(bdf,i)&0xFFF8;
	  base1=HdaPci(bdf,i+4)&0xFFFC;
	  if (base0 && base1)	//or with 0 there: at the standard ports.
	    HDIChannel(base0,base1);
	}
      else
	" No TempleOS driver for this type,\n"
	      " only for 0101xx, IDE.  BIOS setup\n"
	      " (F1 at power-on): Config, Serial\n"
	      " ATA, SATA Controller Mode Option:\n"
	      " Compatibility\n";
    }
    i=HdaPci(bdf,0xC)>>16&0xFF;
    if (!(bdf&7) && (i==0xFF || !(i&0x80)))
      bdf+=7;	//No device here, or no functions 1-7.
  }
  if (!hdi_base0) {
    HDIChannel(0x1F0,0x3F4);	//The standard ports.
    HDIChannel(0x170,0x374);
  }
}

Bool HDIPrt()
{//Make drives C: and D: of the disk found.  FALSE if TempleOS's disk driver gives up on it.
  CBlkDev *bd;
  Bool res=FALSE;
  try {
    if (bd=Let2BlkDev('C',FALSE))	//Left from an earlier try.
      BlkDevDel(bd);
    bd=BlkDevNextFreeSlot('C',BDT_ATA);	//As Mount() does it:
    bd->unit=hdi_unit;
    bd->base0=hdi_base0;
    bd->base1=hdi_base1;
    if (BlkDevAdd(bd,,TRUE,TRUE)) {	//the whole disk is C:, unformatted.
      DskPrt('C',0.5,0.5);	//Halve it, format the halves.
      res=Let2Drv('C',FALSE) && Let2Drv('D',FALSE);
    }
  } catch
    PutExcept;
  return res;
}

U0 HDIDiag()
{//What the disk answers when asked the way TempleOS's driver asks, and how long it takes: for whoever has to fix it.
  CBlkDev bd;
  U16 *id;
  U8 buf[BLK_SIZE];
  I64 i,max=0;
  F64 t0=tS;
  MemSet(&bd,0,sizeof(CBlkDev));
  bd.bd_signature=BD_SIGNATURE_VAL;
  bd.type=BDT_ATA;
  bd.flags=BDF_EXT_SIZE;
  bd.base0=hdi_base0;
  bd.base1=hdi_base1;
  bd.unit=hdi_unit;
  bd.blk_size=BLK_SIZE;
  "Disk test: status %02X\n",InU8(bd.base0+ATAR0_STAT);
  for (i=0;i<100;i++)	//The driver waits for the disk by letting the other tasks run.
    Yield;
  " 100 task switches: %dms\n",ToI64(1000*(tS-t0));
  t0=tS;
  i=ATAGetDevId(&bd,tS+5.0,TRUE);
  " identify: %d in %dms\n",i,ToI64(1000*(tS-t0));
  if (id=bd.dev_id_record)
    " words 47:%04X 59:%04X 82:%04X\n       83:%04X 86:%04X\n",id[47],id[59],id[82],id[83],id[86];
  t0=tS;
  OutU8(bd.base1+ATAR1_CTRL,8);	//As ATAReadNativeMax() does it.
  OutU8(bd.base0+ATAR0_SEL,0xEF|bd.unit<<4);
  ATACmd(&bd,ATA_READ_NATIVE_MAX_EXT);
  i=ATAWaitNotBUSY(&bd,tS+5.0);
  max.u8[0]=InU8(bd.base0+ATAR0_SECT);
  max.u8[1]=InU8(bd.base0+ATAR0_LCYL);
  max.u8[2]=InU8(bd.base0+ATAR0_HCYL);
  OutU8(bd.base1+ATAR1_CTRL,0x80);
  max.u8[3]=InU8(bd.base0+ATAR0_SECT);
  max.u8[4]=InU8(bd.base0+ATAR0_LCYL);
  max.u8[5]=InU8(bd.base0+ATAR0_HCYL);
  OutU8(bd.base1+ATAR1_CTRL,8);
  " native max: %d, %X in %dms,\n  status %02X error %02X\n",i,max,ToI64(1000*(tS-t0)),
	InU8(bd.base0+ATAR0_STAT),InU8(bd.base0+ATAR0_FEAT);
  t0=tS;
  try {
    ATAReadBlks(&bd,buf,0,1);
    " block 0: read in %dms, ends %02X%02X\n",ToI64(1000*(tS-t0)),buf[510],buf[511];
  } catch {
    " block 0: not read, status %02X error %02X\n",InU8(bd.base0+ATAR0_STAT),InU8(bd.base0+ATAR0_FEAT);
    Fs->catch_except=TRUE;
  }
  Free(bd.dev_id_record);
}

I64 HDIVerify(CBlkDev *bd)
{//Read every block of this disk that the disk cache has back from the disk.  After an install that is what it wrote, formatting's zeros aside (and, with too little RAM for a cache that size, its first files).  How many differ?
  CCacheBlk *tmpc;
  U8 buf[BLK_SIZE];
  I64 i,cnt=0,bad=0;
  progress1_max=blkdev.cache_size/BLK_SIZE;	//A bar at the top of the screen, as formatting has.
  StrCpy(progress1_desc,"Checking");
  for (tmpc=blkdev.cache_ctrl->next_lru;tmpc!=blkdev.cache_ctrl;tmpc=tmpc->next_lru) {	//Nothing else uses this disk, so the cache stays as it is.
    if (tmpc->dv && tmpc->dv->bd==bd) {
      ATAReadBlks(bd,buf,tmpc->blk,1);
      if (MemCmp(buf,&tmpc->body,BLK_SIZE) && !bad++) {	//Say where the first one is.
	for (i=0;buf[i]==tmpc->body[i];i++);
	"$$RED$$Block %X, byte %d: the disk has %02X,\n"
	      "%02X was written.$$FG$$\n",tmpc->blk,i,buf[i],tmpc->body[i];
      }
      cnt++;
    }
    progress1++;
  }
  *progress1_desc=0;
  progress1=progress1_max=0;
  "%d blocks read back, %d of them not\n"
	"as written.\n",cnt,bad;
  return bad;
}

U0 HDInstall()
{//Erase this PC's hard disk and install TempleOS on it, as drives C: and D:.
  CTask *task;
  U8 *st;
  I64 drv;
  "HDInstall of @BUILT@\n"	//mkusb.py puts in when it made the image: a photo of the screen then says which one it is.
	"Looking for disks:\n";
  HDIFind;
  if (!hdi_base0) {
    "\nNo hard disk that TempleOS can use.\n";
    return;
  }
  "\n$$RED$$This ERASES all of that %dGB disk$$FG$$\n"
	"and makes it TempleOS's C: and D:.\n"
	"Type YES and <ENTER> to do that: ",hdi_gb;
  st=GetStr;
  drv=StrCmp(st,"YES");
  Free(st);
  if (drv)
    return;
  if (!HDIPrt) {
    "\n$$RED$$TempleOS's disk driver gave up on the\n"
	  "disk.$$FG$$  Nothing is installed.  A photo\n"
	  "of the screen now will tell why:\n";
    HDIDiag;
    return;
  }
  task=User;	//OSInstall.HC's VMInstallWiz() from here on: a second window to answer BootHDIns()'s questions in.
  TaskWait(task);
  WinHorz(Fs->win_left,Fs->win_right,task);
  WinVert(Fs->win_top,(Fs->win_top+Fs->win_bottom)>>2-1,task);
  WinVert(task->win_bottom+3,Fs->win_bottom);
  WinToTop(Fs);
  for (drv='C';drv<='D';drv++) {
    InstallDrv(drv);
    XTalkWait(task,"BootHDIns('%C');\n\nB\n0x20000\nC\ns0x%X\n0x%X\n%d\n\n\n",
	  drv,hdi_base0,hdi_base1,hdi_unit);
  }
  BootMHDIns('C');
  WinVert(task->win_top,Fs->win_bottom);
  Kill(task);
  "\nReading back what was written, to check\n"
	"it.  That takes a minute or two.\n";
  if (hdi_bad=HDIVerify(Let2BlkDev('C')))
    "\n$$RED$$The disk didn't keep what TempleOS\n"
	  "wrote to it$$FG$$, so TempleOS may not start\n"
	  "from it.  A photo of the screen now will\n"
	  "tell why.\n";
  else
    "\nDone.  Take the USB stick out, restart\n"
	  "the PC, and press 1 when it says\n"
	  "\"TempleOS Boot Loader\".\n";
}
