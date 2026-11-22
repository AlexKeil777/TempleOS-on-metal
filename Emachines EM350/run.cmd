@echo off
rem Boots the unmodified TempleOS ISO in QEMU. Knobs: -m (RAM), -smp (cores). Extra QEMU args pass through, e.g. run.cmd -full-screen
qemu-system-x86_64 -accel whpx -accel tcg -m 2G -smp 2 -cdrom "%~dp0TempleOS.ISO" -boot d -audiodev dsound,id=snd -machine pcspk-audiodev=snd %*
