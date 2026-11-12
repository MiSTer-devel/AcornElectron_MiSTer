#!/bin/bash
# Acorn Electron sim regression. Run from vsim/ after `make`.
#   ./regression.sh            run all tests
#   ./regression.sh --update   also print the screen hashes, to paste in as new goldens
# Screenshots go to out/regression/ for eyeballing.
set -u
cd "$(dirname "$0")"
SIM=./obj_dir/Vemu
OUT=out/regression
mkdir -p "$OUT"
FAIL=0
UPDATE=; [ "${1:-}" = "--update" ] && UPDATE=1

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAIL=1; }

# --- 1. power-on boot to the BASIC prompt ----------------------------------
# Field 100 (2 s): "Acorn Electron / Electron MMFS SWRAM / PRES Plus 1 / BASIC / >"
BOOT_GOLDEN=032c37b145f90fbf
$SIM --headless --stop-at-frame 100 --screenshot 100 --screenshot-dir "$OUT" \
	--screenshot-prefix boot > "$OUT/boot.log" &

# --- 2. Plus 1 and First Byte joystick interfaces ---------------------------
# BASIC reads &FC72 (status: b6 ADC busy/not-ready, b5 fire 1, b4 fire 2,
# active low; b3-0 = 1) and ADC channels 1-4 (&FC70 = 4..7 starts a 40 us
# conversion, a read of &FC70 returns the result) into &70-&74, then &FC72
# again (b6 = 1 after a result read, as on an ADC0844) into &75 and the First
# Byte port &FCC0 (active low: b0 up, b1 down, b2 left, b3 right, b4 fire)
# into &76. Analog: Acorn value = &FF - (128 + stick), centre &7F; the D-pad
# gives full deflection; First Byte takes the D-pad or a stick past half way.
PROG='?&70=?&FC72:?&FC70=4:?&71=?&FC70:?&FC70=5:?&72=?&FC70:?&FC70=6:?&73=?&FC70:?&FC70=7:?&74=?&FC70:?&75=?&FC72:?&76=?&FCC0\n'
# The sims run in parallel; results are checked below.
peek_check() {   # log expected label
	local got
	got=$(awk '/^PEEK/ {printf "%s ", $6}' "$OUT/$1.log"); got=${got% }
	[ "$got" = "$2" ] && pass "$3 ($got)" || fail "$3: got '$got' want '$2'"
}
plus1_run() {   # name args...
	local name=$1; shift
	$SIM --headless --key-hold 2 --key-gap 2 --send-keys "110:$PROG" \
		--peek 600:70,71,72,73,74,75,76 --stop-at-frame 600 "$@" > "$OUT/plus1_$name.log" &
}
plus1_run idle
plus1_run fire1+sticks --joy 100:10 --analog 100:100,-50 --analog2 100:-100,60
plus1_run fire2        --joy2 100:10
plus1_run swapped      --swap-joysticks --joy 100:10 --analog 100:100,-50 --analog2 100:-100,60
plus1_run dpad         --joy 100:0A --joy2 100:05     # 1: left+up, 2: right+down
plus1_run fb_upfire    --joy 100:18

# --- 4. resets: poke &70 and &2000, then BREAK (warm: banner + BASIC keeps
# going), Ctrl-BREAK and power-on reset (cold: both give the same screen).
for k in break ctrl por; do
	case $k in break) X="--osd-break 300";; ctrl) X="--osd-ctrl-break 300";; por) X="--reset-at-frame 300";; esac
	$SIM --headless --key-hold 2 --key-gap 2 --send-keys "110:?&70=170:?&2000=170\n" $X \
		--peek 450:70,2000 --screenshot 450 --screenshot-dir "$OUT" --screenshot-prefix reset_$k \
		--stop-at-frame 450 > "$OUT/reset_$k.log" &
done

# SHIFT-BREAK and Autoboot run MMFS's boot; the sim has no SD card, so MMFS
# prints "Card?" (the plain boot screen has no "Card?").
$SIM --headless --osd-shift-break 120 --stop-at-frame 250 --screenshot 250 --screenshot-dir "$OUT" \
	--screenshot-prefix shift_break > "$OUT/shift_break.log" &
$SIM --headless --autoboot --stop-at-frame 150 --screenshot 150 --screenshot-dir "$OUT" \
	--screenshot-prefix autoboot > "$OUT/autoboot.log" &

# --- 5. PC F1 = FUNC+1 (f1): *KEY1 then F1 runs the string ----------------
$SIM --headless --key-hold 2 --key-gap 2 --send-keys '110:*KEY1?&77=42\n' --send-keys '250:\f1\n' \
	--peek 450:77 --stop-at-frame 450 > "$OUT/fkey.log" &

# --- 5a. Mode 7 (Jafa: 6845 at &FC1C + SAA5050, ROM in slot 15): *MODE7ON,
# BREAK, then teletext colour codes and double height: "RED" red, "GRN"
# green, the top half of a double-height "BIG"; 480 x 250, 12 MHz pixels.
$SIM --headless --key-hold 2 --key-gap 2 --send-keys '110:*MODE7ON\n' --send-keys '170:\k' \
	--send-keys '260:P.CHR$129"RED"CHR$130"GRN"CHR$141"BIG"\n' --screenshot 550 --screenshot-dir "$OUT" \
	--screenshot-prefix mode7 --stop-at-frame 550 > "$OUT/mode7.log" 2>&1 &

# --- 5b. Plus 1 cartridges (OSD Cartridge 1 / 2): Cartridge 2 = BASIC (16 KB)
# fills ROM 0, Cartridge 1 = 16 KB of zeros + BASIC (32 KB) fills ROM 3 (ROM 2
# empty). OSRDRM (&FFB9) reads &8009 of ROMs 0-3 into &70-&73: 'B' = &42 where
# BASIC is, 0 where no cartridge is (main RAM no longer shows through 0/1).
python3 -I -c "import sys; b=open(sys.argv[1],'rb').read(); open(sys.argv[2],'wb').write(b); open(sys.argv[3],'wb').write(bytes(16384)+b)" \
	../roms/Basic2.rom "$OUT/cart_lo.rom" "$OUT/cart_hi.rom"
$SIM --headless --key-hold 2 --key-gap 2 --cart2 "$OUT/cart_lo.rom" --cart1 "$OUT/cart_hi.rom" \
	--send-keys '110:?&F6=9:?&F7=&80:FORI%=0TO3:Y%=I%:?(&70+I%)=USR(&FFB9):NEXT\n' \
	--peek 400:70,71,72,73 --stop-at-frame 400 > "$OUT/cart.log" 2>&1 &

# --- 7. tapes (local software/ only; skipped without it) --------------------
# Boxer as the core gets it on MiSTer: Main_MiSTer converts .uef files to a
# bit stream for this core (tools/main_uef2bits.py does the same), played
# in raw mode at 8x. And the original gzipped UEF from the STH zip through
# the core's own gunzip + UEF player (raw UEF data), also 8x, CHAIN"" to the
# title screen. MAD (0xC0DE's Machine
# Auto Detect, plain UEF) at 8x: prints "Detected: 5" (the MAME timing).
SW=../software
TAPES=0
if [ -f $SW/mister11/tapes/Boxer_E.zip ] && [ -f $SW/free/0xC0DE6502/machine-auto-detect-releases/machine-auto-detect.uef ]; then
	TAPES=1
	python3 -I -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); open(sys.argv[2],'wb').write(z.read('Boxer_E.uef'))" \
		$SW/mister11/tapes/Boxer_E.zip "$OUT/Boxer_gz.uef"
	python3 -I tools/main_uef2bits.py "$OUT/Boxer_gz.uef" "$OUT/Boxer_main.bin" > /dev/null
	$SIM --headless --key-hold 2 --key-gap 2 --tape "$OUT/Boxer_main.bin" --tape-frame 100 --tape-turbo 8 \
		--send-keys '120:*TAPE\nCHAIN""\n' --screenshot 1900 --screenshot-dir "$OUT" \
		--screenshot-prefix tape_boxer_main --stop-at-frame 1900 > "$OUT/tape_boxer_main.log" 2>&1 &
	$SIM --headless --key-hold 2 --key-gap 2 --tape "$OUT/Boxer_gz.uef" --tape-frame 100 --tape-turbo 8 \
		--send-keys '120:*TAPE\nCHAIN""\n' --screenshot 1700 --screenshot-dir "$OUT" \
		--screenshot-prefix tape_boxer --stop-at-frame 1700 > "$OUT/tape_boxer.log" 2>&1 &
	$SIM --headless --key-hold 2 --key-gap 2 --tape $SW/free/0xC0DE6502/machine-auto-detect-releases/machine-auto-detect.uef \
		--tape-frame 100 --tape-turbo 8 --send-keys '120:*TAPE\nCHAIN""\n' --screenshot 700 --screenshot-dir "$OUT" \
		--screenshot-prefix tape_mad --stop-at-frame 700 > "$OUT/tape_mad.log" 2>&1 &
	# Tape status bar mid-load (field 700, relay on, 8x): "TAPE > 1:18/ 3:42 x8"
	# for Main's bit stream; the raw UEF has no total ("TAPE > 1:18 x8");
	# OSD Tape overlay Off hides it.
	for v in on off uef; do
		case $v in on) T="$OUT/Boxer_main.bin"; X=;; off) T="$OUT/Boxer_main.bin"; X=--no-tape-overlay;; uef) T="$OUT/Boxer_gz.uef"; X=;; esac
		$SIM --headless --key-hold 2 --key-gap 2 --tape "$T" --tape-frame 100 --tape-turbo 8 $X \
			--send-keys '120:*TAPE\nCHAIN""\n' --screenshot 700 --screenshot-dir "$OUT" \
			--screenshot-prefix tape_bar_$v --stop-at-frame 700 > "$OUT/tape_bar_$v.log" 2>&1 &
	done
	# Flappy Bird (0xC0DE): a BASIC loader *LOADs the game. The MOS clears the
	# tape interrupt with &40 to &FE05 per byte; that must not page out ROM 12
	# (the Plus 1 latch ignores writes with bits 4-7 set), or the return into
	# AP2's FILEV handler crashes. Field 1000: the attract screen.
	$SIM --headless --key-hold 2 --key-gap 2 --tape $SW/free/0xC0DE6502/flappy-bird-releases/flappy-bird.uef \
		--tape-frame 100 --tape-turbo 8 --send-keys '120:*TAPE\nCHAIN""\n' --screenshot 1000 --screenshot-dir "$OUT" \
		--screenshot-prefix tape_flappy --stop-at-frame 1000 > "$OUT/tape_flappy.log" 2>&1 &
fi

# --- 6a. Plus 3 (local software/ only, for the disc): PRES ADFS 1.15 as ROM
# 13 (in the default image), Plus 3 On, the Acorn Welcome disc (ADFS M .adf)
# in drive 0: *CAT lists !BOOT Help Library Welcome.
P3DISC="$SW/commercial/stairwaytohell_extracted/adfs/WelcomeDisc-ADFS_E/WelcomeDisc-ADFS_E.adf"
PLUS3=0
if [ -f "$P3DISC" ]; then
	PLUS3=1
	$SIM --headless --plus3 --floppy0 "$P3DISC" --key-hold 2 --key-gap 2 \
		--send-keys '120:*CAT\n' --screenshot 300 --screenshot-dir "$OUT" --screenshot-prefix plus3_cat \
		--stop-at-frame 300 > "$OUT/plus3_cat.log" 2>&1 &
fi

# --- 6. OSD CPU speed: a 2000-step FOR loop, centiseconds into &78 --------
for c in 0 1 2; do
	$SIM --headless --key-hold 2 --key-gap 2 --cpu-speed $c \
		--send-keys "110:T%=TIME:FORI=1TO2000:NEXT:?&78=TIME-T%\n" \
		--peek 700:78 --stop-at-frame 700 > "$OUT/speed$c.log" &
done
# --- 3. MODE 0-6: print 50 lines so the screen scrolls through the hardware
# wrap (MODE 5 base &5800: upstream 3892b4ee; wrap: 572fb0d7/53b64b7a).
# Cursor off so the hash does not depend on the blink phase.
MODE_GOLDEN=(   # index = MODE
	[0]=4dc25105100e5a8e [1]=e8ad84fc163e228f [2]=de87472437fca0a7 [3]=1c65b8e7324f0a6e
	[4]=c777a81ae473c827 [5]=6df731bfdb804c53 [6]=7e9ccc3ba881dedd)
for m in 0 1 2 3 4 5 6; do
	$SIM --headless --key-hold 2 --key-gap 2 \
		--send-keys "110:MODE$m:VDU23,1,0;0;0;0;:FORI=1TO50:PRINTI;\" MODE$m\":NEXT\n" \
		--stop-at-frame 1050 --screenshot 1050 --screenshot-dir "$OUT" --screenshot-prefix mode$m \
		> "$OUT/mode$m.log" &
done
wait

h=$(awk '/^SCREENSHOT/ {print $6}' "$OUT/boot.log")
if [ "${1:-}" = "--update" ]; then echo "boot FBHASH $h"; fi
[ "$h" = "$BOOT_GOLDEN" ] && pass "boot screen ($h)" || fail "boot screen: got '$h' want $BOOT_GOLDEN ($OUT/boot_0100.png)"
peek_check plus1_idle         "BF 7F 7F 7F 7F FF FF" "plus1 idle"
peek_check plus1_fire1+sticks "9F 1B B1 E3 43 DF E7" "plus1 fire1+sticks"
peek_check plus1_fire2        "AF 7F 7F 7F 7F EF FF" "plus1 fire2"
peek_check plus1_swapped      "AF E3 43 1B B1 EF FB" "plus1 swapped"
peek_check plus1_dpad         "BF FF FF 00 00 FF FA" "plus1 D-pad"
peek_check plus1_fb_upfire    "9F 7F FF 7F 7F DF EE" "First Byte up+fire"
peek_check reset_break "AA AA" "BREAK keeps RAM"
peek_check reset_ctrl  "AA AA" "Ctrl-BREAK keeps RAM"
peek_check reset_por   "AA AA" "power-on keeps RAM"
hb=$(awk '/^SCREENSHOT/ {print $6}' "$OUT/reset_break.log")
hc=$(awk '/^SCREENSHOT/ {print $6}' "$OUT/reset_ctrl.log")
hp=$(awk '/^SCREENSHOT/ {print $6}' "$OUT/reset_por.log")
[ "$hc" = "$hp" ] && pass "Ctrl-BREAK = power-on screen ($hc)" || fail "Ctrl-BREAK $hc != power-on $hp ($OUT/reset_*_0450.png)"
[ "$hb" != "$hp" ] && pass "BREAK is warm ($hb)" || fail "BREAK gave the cold-start screen"
shot_check() {   # log golden label
	local h; h=$(awk '/^SCREENSHOT/ {print $6}' "$OUT/$1.log")
	[ "${UPDATE:-}" ] && echo "$1 FBHASH $h"
	[ "$h" = "$2" ] && pass "$3 ($h)" || fail "$3: got '$h' want $2 ($OUT/$1_*.png)"
}
shot_check shift_break 8e7a54ac4af27b7b "SHIFT-BREAK boots (Card?)"
shot_check autoboot    8e7a54ac4af27b7b "Autoboot boots (Card?; same screen as SHIFT-BREAK)"
peek_check fkey "2A" "F1 = FUNC+1"
shot_check mode7 03954d3e8c3e5d93 "Mode 7: teletext colours and double height"
peek_check cart "42 00 00 42" "cartridges: ROM 0 = Cartridge 2, ROM 3 = Cartridge 1 upper 16 KB"
if [ $TAPES = 1 ]; then
	shot_check tape_boxer_main ffb8fb706f11f961 "tape: Boxer as Main sends it (bit stream) at 8x to title"
	shot_check tape_boxer ffb8fb706f11f961 "tape: gzipped Boxer UEF (core gunzip) at 8x to title"
	shot_check tape_mad   8ea90fc274b9c1e5 "tape: MAD UEF at 8x (Detected: 5)"
	shot_check tape_bar_on  81685b913388fe7d "tape status bar: bit stream, 1:18/ 3:42 x8"
	shot_check tape_bar_off 6791ada3343a9b31 "tape status bar: Tape overlay Off"
	shot_check tape_bar_uef bbc04f980f638feb "tape status bar: raw UEF, elapsed only"
	shot_check tape_flappy 34cf42aaefe431af "tape: Flappy Bird (*LOAD from BASIC, ROM 12 kept paged) to attract screen"
else
	echo "SKIP  tapes (no ../software)"
fi
if [ $PLUS3 = 1 ]; then
	shot_check plus3_cat ff8e301a84cdd0fb "Plus 3: ADFS *CAT of the Welcome disc"
else
	echo "SKIP  Plus 3 (no ../software)"
fi
peek_check speed0 "90" "CPU speed Normal (cs)"
peek_check speed1 "67" "CPU speed 2 MHz (cs)"
peek_check speed2 "32" "CPU speed 4 MHz (cs)"
for m in 0 1 2 3 4 5 6; do
	h=$(awk '/^SCREENSHOT/ {print $6}' "$OUT/mode$m.log")
	[ "${1:-}" = "--update" ] && echo "mode$m FBHASH $h"
	[ "$h" = "${MODE_GOLDEN[$m]}" ] && pass "MODE $m scroll ($h)" || fail "MODE $m scroll: got '$h' want ${MODE_GOLDEN[$m]} ($OUT/mode${m}_1050.png)"
done

echo
[ $FAIL = 0 ] && echo "ALL PASS" || echo "SOME TESTS FAILED"
exit $FAIL
