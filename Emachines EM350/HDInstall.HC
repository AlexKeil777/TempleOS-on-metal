//Puts TempleOS on the hard disk of a PC booted from the USB stick.  Type
//  HDInstall;
//mkusb.py puts this file in the image as /Misc/HDInstall.HC.Z, loaded at boot.
//
//It is TempleOS's own installer (::/Misc/OSInstall.HC, the one for virtual
//machines: the whole disk becomes drives C: and D:) with another way of
//finding the disk.  TempleOS knows the two standard IDE port ranges and, for
//others, asks the BIOS's PCI services.  On a PC whose BIOS has none and puts
//its IDE channels at ports of its own, TempleOS sees no disk at all.
//HDInstall() reads the ports from the disk controllers themselves, says what
//it finds there, and hands them to the installer.
//
//TempleOS has no AHCI driver: SATA has to be in IDE mode (BIOS setup).

#include "::/Misc/OSInstall"

extern I64 ATAGetDevId(CBlkDev *bd,F64 timeout,Bool keep_id_record);

I64 hdi_base0,hdi_base1,hdi_unit,	//The hard disk found: its IDE channel's two port ranges, 0 master or 1 slave,
    hdi_gb;				//and its size.

U0 HDIChannel(I64 base0,I64 base1)
{//Say what is on the IDE channel at these ports.  Note the first hard disk.
  CBlkDev bd;
  I64 i,unit,status=InU8(base0+7);
  U16 *id;
  U8 model[41];
  " IDE ports %04X,%04X: status %02X\n",base0,base1,status;
  if (status==0xFF)	//Nothing answers there.
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
	      " only for 0101xx, IDE: look for a\n"
	      " SATA mode setting in the BIOS setup\n";
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

U0 HDInstall()
{//Erase this PC's hard disk and install TempleOS on it, as drives C: and D:.
  CTask *task;
  U8 *st;
  I64 drv;
  "PCI BIOS %X.  Looking for disks:\n",sys_pci_services;
  HDIFind;
  if (!hdi_base0) {
    "\nNo hard disk that TempleOS can use.\n";
    return;
  }
  "\n$$RED$$This ERASES all of that %dGB disk$$FG$$\n"
	"and makes it TempleOS's C: and D:.\n"
	"Type YES and <ENTER> to do that: ",hdi_gb;
  st=GetStr;
  if (!StrCmp(st,"YES")) {
    task=User;	//OSInstall.HC's VMInstallWiz() from here on, but giving the ports instead of picking from a probe.
    TaskWait(task);
    WinHorz(Fs->win_left,Fs->win_right,task);
    WinVert(Fs->win_top,(Fs->win_top+Fs->win_bottom)>>2-1,task);
    WinVert(task->win_bottom+3,Fs->win_bottom);
    WinToTop(Fs);
    XTalkWait(task,"DskPrt(,0.5,0.5);\nC\ns0x%X\n0x%X\n%dY",
	  hdi_base0,hdi_base1,hdi_unit);
    for (drv='C';drv<='D';drv++) {
      InstallDrv(drv);
      XTalkWait(task,"BootHDIns('%C');\n\nB\n0x20000\nC\ns0x%X\n0x%X\n%d\n\n\n",
	    drv,hdi_base0,hdi_base1,hdi_unit);
    }
    BootMHDIns('C');
    WinVert(task->win_top,Fs->win_bottom);
    Kill(task);
    "\nDone.  Take the USB stick out, restart\n"
	  "the PC, and press 1 when it says\n"
	  "\"TempleOS Boot Loader\".\n";
  }
  Free(st);
}
