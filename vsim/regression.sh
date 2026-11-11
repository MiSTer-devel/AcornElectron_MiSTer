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
shot_check autoboot    c3f63c738653f105 "Autoboot boots (Card?)"
peek_check fkey "2A" "F1 = FUNC+1"
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
