# Acorn Electron Verilator simulation

```bash
cd vsim
make                 # GHDL converts the VHDL core, then Verilator builds obj_dir/Vemu
./regression.sh      # 23 tests: boot, joysticks, resets, F-keys, CPU speed, MODE 0-6 (~2 min, parallel)
./obj_dir/Vemu       # GUI (ImGui window)
./obj_dir/Vemu --help
```

Needs `ghdl` (5.x, with `--synth`), `verilator` (5.x), SDL2 and Python 3.
Run from this directory: `$readmemh` opens `ELK.hex` (made from `../roms/ELK.mif`).

## How it is put together

- `sim.v` is a stand-in for `AcornElectron.sv`: same memory map, reset and
  settings latch, and tape player; the joystick mapping and the OSD BREAK
  buttons are the shared `rtl/electron_input.sv`. hps_io, the PLLs, SDRAM and altsyncram are replaced by
  inputs that `sim_main.cpp` drives and by behavioural RAMs. **Keep it in sync
  with `AcornElectron.sv`.**
- The VHDL (T65, ULA, VIA, keyboard, `ElectronFpga_core`) is turned into
  Verilog by `ghdl --synth` on every build (`obj_dir/gen/electron_core.v`), so
  VHDL edits flow through. `rtl/RAM_32k_DualPort_sim.vhd` replaces the
  altsyncram main RAM. Keep the VHDL GHDL-clean: instantiate entities with
  `entity work.x`, and don't name instances after Verilog keywords.
- One 16 MHz clock (`clk_sys`): video modes 00/01 need nothing else. The
  cassette overlay (64 MHz), ADC tape input and SD card are not in the sim yet.
- `sim/` is the shared MiSTer sim library (from BasicMasterJr_MiSTer/vsim).
  `sim_bus.cpp` is patched so `ioctl_addr` = file size after a download, like
  hps_io since Template 7768007.

## Options (headless)

| Option | |
|---|---|
| `--headless` | no window (or `HEADLESS=1`) |
| `--stop-at-frame <n>` | exit after field n (50 fields = 1 s) |
| `--screenshot <n,n>` / `--screenshot-every <n>` | 640x256 PNGs (one field) to `--screenshot-dir`, `--screenshot-prefix` |
| `--hash` | `FBHASH` every field |
| `--send-keys <frame>:<text>` | type; `\n` RETURN, `\b` DELETE, `\e` ESCAPE, `\k` BREAK (F11), `\K` CTRL-BREAK, `\S` SHIFT-BREAK, `\c` CAPS LOCK, `\f<d>` FUNC+d (PC F-key), `\U\D\L\R`, `\^X` CTRL+X |
| `--key-hold` / `--key-gap` | fields per key / between keys (default 3/3) |
| `--joy` / `--joy2 <frame>:<hex>` | buttons: bit 0 right, 1 left, 2 down, 3 up, 4 Fire |
| `--analog` / `--analog2 <frame>:<x>,<y>` | analog stick, signed -127..127 |
| `--swap-joysticks`, `--interlaced`, `--tape-monitor` | OSD settings |
| `--cpu-speed <0\|1\|2>` | OSD CPU speed: Normal, 2 MHz, 4 MHz |
| `--osd-break <n>` / `--osd-ctrl-break <n>` / `--osd-shift-break <n>` | OSD BREAK / Ctrl-BREAK / SHIFT-BREAK buttons |
| `--autoboot` | OSD Autoboot On (SHIFT-BREAK 300 ms after power-on; Off by default in the sim) |
| `--rom <file>` | 112 KB ROM image (ELK.mif layout) loaded at power-on |
| `--tape <file>` / `--tape-frame <n>` / `--tape-rewind <n>` | OSD tape load / Stop & Rewind |
| `--reset-at-frame <n>` | power-on reset (OSD Apply and reset) |
| `--peek <frame>:<hex,hex>` / `--dump-ram <frame>:<file>` | read main RAM |
| `--trace <f.vcd>` | VCD (build with `make TRACE=1`) |

Typing: letters come out as capitals (CAPS LOCK is on at boot); shifted symbols
follow the Electron keyboard (`"` is SHIFT-2, `:` and `*` are on the PC `'` key).

Speed: about 14 fields/s headless on an M-series Mac (0.27x real time).
