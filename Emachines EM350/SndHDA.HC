//HD Audio driver: TempleOS sound on the PC's real speakers.
//mkusb.py puts this file in the image as /Adam/SndHDA.HC.Z, run at boot.
//
//All the sound TempleOS has is Snd(ona): one square wave on the PC speaker.
//HdaInit() makes every HD Audio controller (the sound chip of most PCs since
//2005) play one buffer in a loop, forever, on every speaker, headphone and
//line-out socket.  Then it makes the kernel's Snd() jump to HdaSnd(), which
//just fills that buffer with a whole number of cycles of the note.  So there
//are no interrupts and no timers, and a note costs nothing while it sounds.
//
//HdaInit() prints what it finds.  At boot that scrolls by; to read it, type
//  HdaInit;
//Too loud or too quiet?  hda_vol=20000;  (0-32767) works from the next note.
//
//Mind HolyC's operator precedence: << >> bind tightest, then * / %, then &,
//then ^, then |, then + -, then comparisons.

#define HDA_FRAMES	65536	//Buffer length: 1.4s.  Notes get rounded to 48000/65536=0.7Hz.

I64 hda_vol=8000,	//Loudness, 0-32767.
    hda_cad,hda_fg,	//Codec being set up, and its audio function group.
    hda_timeouts;
U8  *hda;		//Registers of the controller being set up.
U32 *hda_buf=NULL;	//HDA_FRAMES stereo 16 bit samples, then the list that tells a controller where they are.

U32 HdaPci(I64 bdf,I64 rg)
{//Read PCI config register rg of bus<<8+dev<<3+fun.  Not with PCIReadU32(): that needs a PCI BIOS.
  U32 res;
  PUSHFD
  CLI
  OutU32(0xCF8,0x80000000|bdf<<8|rg);
  res=InU32(0xCFC);
  POPFD
  return res;
}

Bool HdaWait(U8 *rg,I64 mask,I64 val)
{//Wait for bits of a controller register, 100ms at most: hardware that isn't there mustn't hang the boot.
  I64 i;
  for (i=0;i<10000;i++) {
    if (*rg(U32 *)&mask==val)
      return TRUE;
    Busy(10);
  }
  return FALSE;
}

U32 HdaCmd(I64 nid,I64 verb,I64 val=0)
{//Send a "verb" to widget nid of the codec and return its answer.
//Verbs are 12 bits with 8 bits of val, or 0x200,0x300 with 16 bits of val.
//ponytail: uses the "immediate command" registers, which Intel's controllers
//have but the standard doesn't demand.  One without them needs the CORB/RIRB
//rings here instead; HdaInit() then says "A codec doesn't answer".
  if (hda_timeouts<3) {
    HdaWait(hda+0x68,1,0);
    *(hda+0x68)(U16 *)=2;	//Forget the last answer,
    *(hda+0x60)(U32 *)=hda_cad<<28|nid<<20|verb<<8|val;
    *(hda+0x68)(U16 *)=1;	//send, and wait for the new one.
    if (HdaWait(hda+0x68,2,2))
      return *(hda+0x64)(U32 *);
    hda_timeouts++;
  }
  return 0;
}

I64 HdaGain(I64 nid,I64 param)
{//The setting that means 0dB on a widget's input (param 0xD) or output (0x12) volume.
  if (!(HdaCmd(nid,0xF00,9)&8))
    nid=hda_fg;	//It has no volume control of its own kind: the function group's standard one.
  return HdaCmd(nid,0xF00,param)&0x7F;
}

I64 HdaConns(I64 nid,U8 *lst)
{//List the widgets that feed widget nid.  Returns how many: 32 at most.
  I64 i,c,n=HdaCmd(nid,0xF00,0xE),cnt=0;
  if (n&0x80)
    n=0;	//A list of 16 bit entries, for codecs with over 127 widgets.  Never met one.
  for (i=0;i<n && cnt<32;i++) {
    c=HdaCmd(nid,0xF02,i&~3);	//Four entries per answer.
    c=c.u8[i&3];
    if (c&0x80) {	//"And everything from the previous entry up to this one."
      c&=0x7F;
      while (cnt && cnt<31 && lst[cnt-1]+1<c) {
	lst[cnt]=lst[cnt-1]+1;
	cnt++;
      }
    }
    lst[cnt++]=c;
  }
  return cnt;
}

Bool HdaPath(I64 nid,I64 depth=0)
{//Open a way for sound from a DAC to widget nid.  FALSE if there is none.
  U8 lst[32];
  I64 i,n,caps=HdaCmd(nid,0xF00,9),type=caps>>20&15;
  if (caps&0x200 || depth>5)	//Digital (S/PDIF, HDMI), or going round in circles.
    return FALSE;
  if (!type) {	//A DAC.
    HdaCmd(nid,0x200,0x11);	//It gets 48kHz, 16 bit, stereo
    HdaCmd(nid,0x706,0x10);	//from stream 1.
  } else {	//Only mixers (2), selectors (3) and the socket we start from (4) pass sound on.
    if (type!=2 && type!=3 && (type!=4 || depth))
      return FALSE;
    n=HdaConns(nid,lst);
    for (i=0;i<n;i++)
      if (HdaPath(lst[i],depth+1))
	break;
    if (i==n)
      return FALSE;
    if (type==2)
      HdaCmd(nid,0x300,0x7000|i<<8|HdaGain(nid,0xD));	//Mixer: unmute that input, both channels.
    else if (n>1)
      HdaCmd(nid,0x701,i);	//Selector or socket: switch to that input.
  }
  if (caps&4)
    HdaCmd(nid,0x300,0xB000|HdaGain(nid,0x12));	//Unmute its output, both channels.
  "%02X>",nid;
  return TRUE;
}

I64 HdaCodec()
{//Make every speaker, headphone and line-out socket of codec hda_cad play stream 1.  Returns how many.
  I64 i,nid,end,fg_end,caps,cfg,res=0;
  i=HdaCmd(0,0xF00,4);	//Function groups: first<<16+how many.
  fg_end=i>>16&0xFF+i&0xFF;
  for (hda_fg=i>>16&0xFF;hda_fg<fg_end;hda_fg++)
    if (HdaCmd(hda_fg,0xF00,5)&0xFF==1) {	//An audio one, not a modem.
      HdaCmd(hda_fg,0x705);	//Power it on,
      Sleep(20);
      i=HdaCmd(hda_fg,0xF00,4);	//Widgets: first<<16+how many.
      end=i>>16&0xFF+i&0xFF;
      for (nid=i>>16&0xFF;nid<end;nid++)
	HdaCmd(nid,0x705);	//and all its widgets.
      for (nid=i>>16&0xFF;nid<end;nid++)
	if (HdaCmd(nid,0xF00,9)>>20&15==4) {	//A socket ("pin").
	  caps=HdaCmd(nid,0xF00,0xC);
	  cfg=HdaCmd(nid,0xF1C);	//What the PC's maker says is wired to it,
	  i=cfg>>20&15;	//0 line out, 1 speaker, 2 headphones, 3... other things,
	  if (caps&0x10000)
	    HdaCmd(nid,0x70C,2);	//Its external amplifier, if any: on.
	  if (caps&0x10 && cfg>>30!=1 && i<3) {	//and cfg>>30==1: nothing at all.
	    " ";
	    if (HdaPath(nid)) {
	      HdaCmd(nid,0x707,0x40+(i==2)<<7);	//Output on; headphone amplifier too.
	      "%s\n",LstSub(i,"line out\0speaker\0headphones\0");
	      res++;
	    } else
	      "%02X: no DAC\n",nid;
	  }
	}
    }
  return res;
}

I64 HdaStart(I64 bdf)
{//Set up the controller at PCI bus<<8+dev<<3+fun.  Returns how many sockets play.
  I64 i=HdaPci(bdf,0),res=0,bar=HdaPci(bdf,0x10),*bdl=hda_buf+HDA_FRAMES;
  U8 *sd;
  "HD Audio controller %04X:%04X at %02X:%02X.%d\n",
	i&0xFFFF,i>>16,bdf>>8,bdf>>3&31,bdf&7;
  if (!(bar&~0xF) || bar&6==4 && HdaPci(bdf,0x14)) {
    " has no address below 4GB\n";
    return 0;
  }
  hda=dev.uncached_alias+bar&~0xF;
  PUSHFD
  CLI
  OutU32(0xCF8,0x80000000|bdf<<8|4);
  OutU16(0xCFC,InU16(0xCFC)|6);	//Let it answer and let it read memory.
  if (i&0xFFFF==0x8086) {	//Intel's: traffic class 0.  Linux does it, against "playback static".
    OutU32(0xCF8,0x80000000|bdf<<8|0x44);
    OutU8(0xCFC,InU8(0xCFC)&~7);
  }
  POPFD

  sd=hda+0x80+0x20*(*hda(U16 *)>>8&15);	//Its first output stream; the input streams come first.
  *sd(U32 *)=0;	//Stop that, should it be playing for us already,
  *(hda+8)(U32 *)=0;	//reset the controller and with it the codecs,
  HdaWait(hda+8,1,0);
  Sleep(2);
  *(hda+8)(U32 *)=1;	//and let them wake up.
  if (!HdaWait(hda+8,1,1)) {
    " stays in reset\n";
    return 0;
  }
  Sleep(10);

  hda_timeouts=0;
  for (hda_cad=0;hda_cad<15;hda_cad++)
    if (*(hda+0xE)(U16 *)>>hda_cad&1) {	//A codec reported in at this address.
      " Codec %08X\n",HdaCmd(0,0xF00);
      res+=HdaCodec;
    }
  if (hda_timeouts)
    " A codec doesn't answer\n";

  bdl[0]=hda_buf;	//The buffer as a list of two halves: just one piece isn't allowed.
  bdl[1]=bdl[3]=HDA_FRAMES*2;
  bdl[2]=hda_buf(U8 *)+HDA_FRAMES*2;
  *sd(U32 *)=1;	//Reset the stream,
  HdaWait(sd,1,1);
  *sd(U32 *)=0;
  HdaWait(sd,1,0);
  *sd(U32 *)=1<<20;	//make it stream 1,
  *(sd+8)(U32 *)=HDA_FRAMES*4;	//this many bytes long,
  *(sd+0xC)(U16 *)=1;	//in pieces 0 to 1,
  *(sd+0x12)(U16 *)=0x11;	//of 48kHz, 16 bit, stereo,
  *(sd+0x18)(U32 *)=bdl;
  *(sd+0x1C)(U32 *)=0;
  *sd(U32 *)=1<<20|2;	//and start it.
  i=*(sd+4)(U32 *);	//Where in the buffer it is.
  Sleep(20);
  if (*(sd+4)(U32 *)==i) {
    " The controller doesn't play\n";
    return 0;
  }
  return res;
}

U0 HdaTone(F64 freq)
{//Fill the buffer with a square wave.  A whole number of cycles, so that it can loop.
  I64 i,a=0,b,r=0,v=hda_vol,n=2*ToI64(freq*HDA_FRAMES/48000+0.5);	//Half cycles.
  for (i=1;i<=n;i++) {
    b=i*HDA_FRAMES/n;
    MemSetU32(hda_buf+a,(v&0xFFFF)*0x10001,b-a);	//Left and right the same.
    if (r)	//The wave flipped r/n into the first sample: that gets the average,
      hda_buf[a]=(v*(n-2*r)/n&0xFFFF)*0x10001;	//or high notes have ghost notes (aliasing).
    r=i*HDA_FRAMES%n;
    a=b;
    v=-v;
  }
  if (!n)
    MemSetU32(hda_buf,0,HDA_FRAMES);
}

U0 HdaSnd(I8 ona=0)
{//The kernel's Snd(), with the buffer in place of the PC speaker.
  CSndData *d;
  if (!Bt(&sys_semas[SEMA_MUTE],0) &&
	!LBts(&sys_semas[SEMA_SND],0)) { //Mutex. Just throw-out if in use
    if (ona!=scrncast.ona) {
      scrncast.ona=ona;
      HdaTone(Ona2Freq(ona));
    }
    if (!IsDbgMode && scrncast.record) {
      d=ACAlloc(sizeof(CSndData));
      d->ona=ona;
      d->tS=tS;
      QueIns(d,scrncast.snd_head.last);
    }
    LBtr(&sys_semas[SEMA_SND],0);
  }
}

U0 HdaInit()
{//Send sound to every HD Audio controller in this PC.
//ponytail: nothing stops the controllers again.  Should a PC play noise while
//it reboots (its BIOS not resetting them), Reboot() needs a hook like Snd()'s.
  I64 bdf,i,res=0;
  U8 *old=&Snd,*hook=&HdaSnd;
  Snd;
  if (!hda_buf)	//In the code heap: that is below 2GB, where every controller can reach.
    hda_buf=CAllocAligned(HDA_FRAMES*4+32,0x1000,adam_task->code_heap);
  for (bdf=0;bdf<0x10000;bdf++) {
    if (HdaPci(bdf,8)>>16==0x403)	//Class: multimedia, HD Audio.
      res+=HdaStart(bdf);
    i=HdaPci(bdf,0xC)>>16&0xFF;
    if (!(bdf&7) && (i==0xFF || !(i&0x80)))
      bdf+=7;	//No device here, or no functions 1-7.
  }
  if (res) {
    *old=0xE9;	//Make the kernel's Snd() a JMP to HdaSnd().
    *(old+1)(I32 *)=hook-old-5;
    "Snd() now plays there, not on the PC speaker\n";
  } else
    "No HD Audio output found: Snd() stays on the PC speaker\n";
}

HdaInit;
