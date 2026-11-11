# Acorn Electron

Port by David Wood - oldgit




## Introduction

This is a port of [ElctronFPGA](https://github.com/hoglet67/ElectronFpga) by David Banks, Mike Sterling. They have a good
description of the project here:   [Acorn Electron FPGA Project](https://www.mups.co.uk/post/2017/07/acorn-electron-fpga-project/)

## MMC Operation

Look for the ELK version of the beeb.mb and put it on the sdcard as boot.vhd

## Cassette Operation

The core starts in the MMC game menu (OSD Advanced: Autoboot). Press F10
(f0, the menu's EXIT) for the BASIC prompt, or set Autoboot Off. Load a
`.uef` or `.cas` file with the OSD Tape row, then type:

```
*TAPE
CHAIN""
```

Most games load with `CHAIN""`; a few say `*RUN` on their inlay.

- **Tape speed** (Machine page): `8x` (default) or `Normal`. While the
  cassette motor runs, the tape and the machine run 8 times faster, so the
  loader sees exactly what it expects; the moment the motor stops, the
  machine is back at normal speed.
- **Tape status bar** (Video page: Tape overlay): while the motor runs, the
  bottom-left corner shows `TAPE > elapsed/ total x8` and a progress bar.
  Times are tape time (1200 baud), so a 3:42 tape loads in under 30 s at 8x.
- **Rewind tape** (Machine page) goes back to the start; loading a new
  tape always starts at the start.
- Gzipped UEFs (as in the Stairway to Hell archive) load as they are.


## Notes from David Wood:


I used the front end for the BBC Micro by Sorgelig and adapted it for this port.

On start up you will need to ctrl-Break to clear the garbage on the screen. -- fix me

Put the Electron version of beeb.mb in games as boot.vhd (Acorn Electron Games & Magazines BEEB.MMB)


I cannot get used to the Func Number for Function Keys. -- Func = Caps Lock


I never had an Electron and the only time I saw one was when it was being used as a door stop
in the 'One Step Beyond' shop in Norwich.

