#!/bin/bash
# Acorn Electron sim regression. Run from vsim/ after `make`.
#   ./regression.sh            run all tests
#   ./regression.sh --update   print the boot hash to paste in as the new golden
# Screenshots go to out/regression/ for eyeballing.
set -u
cd "$(dirname "$0")"
SIM=./obj_dir/Vemu
OUT=out/regression
mkdir -p "$OUT"
FAIL=0

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAIL=1; }

# --- 1. power-on boot to the BASIC prompt ----------------------------------
# Field 100 (2 s): "Acorn Electron / Electron MMFS SWRAM / PRES Plus 1 / BASIC / >"
BOOT_GOLDEN=032c37b145f90fbf
$SIM --headless --stop-at-frame 100 --screenshot 100 --screenshot-dir "$OUT" \
	--screenshot-prefix boot > "$OUT/boot.log" &

# --- 2. Plus 1 joystick interface ------------------------------------------
# BASIC reads &FC72 (status: b5 fire 1, b4 fire 2, active low; b3-0 = 1) and
# ADC channels 1-4 (&FC70 = 4..7 selects, a read of &FC70 returns the result)
# into &70-&74. Analog: Acorn value = &FF - (128 + stick), centre &7F.
PROG='?&70=?&FC72:?&FC70=4:?&71=?&FC70:?&FC70=5:?&72=?&FC70:?&FC70=6:?&73=?&FC70:?&FC70=7:?&74=?&FC70\n'
# The sims run in parallel; results are checked below.
plus1_run() {   # name args...
	local name=$1; shift
	$SIM --headless --key-hold 2 --key-gap 2 --send-keys "110:$PROG" \
		--peek 560:70,71,72,73,74 --stop-at-frame 560 "$@" > "$OUT/plus1_$name.log" &
}
plus1_check() {   # name expected
	local got
	got=$(awk '/^PEEK/ {printf "%s ", $6}' "$OUT/plus1_$1.log"); got=${got% }
	[ "$got" = "$2" ] && pass "plus1 $1 ($got)" || fail "plus1 $1: got '$got' want '$2'"
}
plus1_run idle
plus1_run fire1+sticks --joy 100:10 --analog 100:100,-50 --analog2 100:-100,60
plus1_run fire2        --joy2 100:10
plus1_run swapped      --swap-joysticks --joy 100:10 --analog 100:100,-50 --analog2 100:-100,60
wait

h=$(awk '/^SCREENSHOT/ {print $6}' "$OUT/boot.log")
if [ "${1:-}" = "--update" ]; then echo "boot FBHASH $h"; fi
[ "$h" = "$BOOT_GOLDEN" ] && pass "boot screen ($h)" || fail "boot screen: got '$h' want $BOOT_GOLDEN ($OUT/boot_0100.png)"
plus1_check idle         "BF 7F 7F 7F 7F"
plus1_check fire1+sticks "9F 1B B1 E3 43"
plus1_check fire2        "AF 7F 7F 7F 7F"
plus1_check swapped      "AF E3 43 1B B1"

echo
[ $FAIL = 0 ] && echo "ALL PASS" || echo "SOME TESTS FAILED"
exit $FAIL
