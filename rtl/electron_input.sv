//============================================================================
//  Acorn Electron: MiSTer joysticks -> Plus 1 / First Byte, and the OSD
//  BREAK / Ctrl-BREAK buttons. Shared by AcornElectron.sv and vsim/sim.v.
//============================================================================

// Joysticks. MiSTer joy bits: 0 right, 1 left, 2 down, 3 up, 4 Fire.
// Analog sticks are signed -127..127 (X [7:0], Y [15:8]).
//
// Plus 1 ADC (&FC70): &FF = left/up, &00 = right/down, centre &7F
// (255 - (128 + v)). The D-pad pushes an axis to full deflection, so a pad
// without a stick works too.
//
// First Byte (&FCC0): one digital stick, player 1: the D-pad, or the analog
// stick pushed past half way.
module electron_joy
(
	input      [15:0] joy1,        // hps_io joystick_0 / _1
	input      [15:0] joy2,
	input      [15:0] joya1,       // hps_io joystick_l_analog_0 / _1
	input      [15:0] joya2,
	input             swap,        // OSD Swap joysticks

	output      [7:0] adc1_x,      // Plus 1 channels 1-4
	output      [7:0] adc1_y,
	output      [7:0] adc2_x,
	output      [7:0] adc2_y,
	output            fire1,       // Plus 1 fire buttons (active high)
	output            fire2,
	output      [4:0] fb_joy       // First Byte: 4 fire, 3 right, 2 left, 1 down, 0 up
);

wire [15:0] pjoy1  = swap ? joy2  : joy1;
wire [15:0] pjoy2  = swap ? joy1  : joy2;
wire [15:0] pjoya1 = swap ? joya2 : joya1;
wire [15:0] pjoya2 = swap ? joya1 : joya2;

function [7:0] adc_axis(input [7:0] v, input neg, input pos);  // neg: left/up
	adc_axis = neg ? 8'hFF : pos ? 8'h00 : 8'hFF - (8'd128 + v);
endfunction

assign adc1_x = adc_axis(pjoya1[7:0],  pjoy1[1], pjoy1[0]);
assign adc1_y = adc_axis(pjoya1[15:8], pjoy1[3], pjoy1[2]);
assign adc2_x = adc_axis(pjoya2[7:0],  pjoy2[1], pjoy2[0]);
assign adc2_y = adc_axis(pjoya2[15:8], pjoy2[3], pjoy2[2]);
assign fire1  = pjoy1[4];
assign fire2  = pjoy2[4];

wire signed [7:0] ax1 = pjoya1[7:0];
wire signed [7:0] ay1 = pjoya1[15:8];
assign fb_joy = { pjoy1[4],                     // fire
                  pjoy1[0] | (ax1 >  8'sd63),   // right
                  pjoy1[1] | (ax1 < -8'sd63),   // left
                  pjoy1[2] | (ay1 >  8'sd63),   // down
                  pjoy1[3] | (ay1 < -8'sd63) }; // up

endmodule


// OSD BREAK / Ctrl-BREAK / SHIFT-BREAK (trigger buttons) and Autoboot.
// BREAK is held for the first 50 ms; CTRL or SHIFT stays down until the MOS
// has read the keyboard for its boot decision: its reset code scans SHIFT
// with JSR &E7D1 at &DA56 and goes on at &DA59 (MOS 1.00), after every
// ROM's reset service calls. That can take well over a second: with the
// Plus 3 on, ADFS / DFS read the disc first (slow SD round trips through
// Main_MiSTer), and a fixed 300 ms or 1 s hold missed it - SHIFT-BREAK then
// did not boot. 3 s timeout, for a replaced MOS (Load ROM).
// A SHIFT-BREAK that swaps the Plus 3's ADFS and DFS (cold_boot) is a cold
// start (AcornElectron.sv), and a cold start does not reliably boot (ADFS
// on hardware did not): it is sent as a plain BREAK, and once the MOS is
// through its reset (&DA59) a warm SHIFT-BREAK follows 0.5 s later.
// SHIFT+F11 on the keyboard (F11 = BREAK) is taken as the same SHIFT-BREAK,
// so a quick tap boots too (the keyboard's own SHIFT is long up when the
// MOS looks).
// Autoboot presses SHIFT-BREAK 1.5 s after a power-on
// reset (MMFS only boots on SHIFT-BREAK, not on SHIFT held at power-on).
// Not sooner: the MOS's cold start takes about 0.8 s, and a BREAK in the
// middle of it leaves the keyboard workspace half set up (with the Plus 3's
// ADFS or the JAFA Mode 7 ROM the machine then typed its FUNC keywords).
// Times assume a 16 MHz clk.
module electron_osd_buttons
(
	input             clk,
	input             reset,           // power-on reset
	input             autoboot,        // OSD Autoboot
	input      [15:0] cpu_addr,        // the MOS's boot key scan done: CPU at &DA59
	input             cold_boot,       // the next BREAK swaps ADFS / DFS (a cold start)
	input             btn_break,       // OSD T bits (level, rising edge acts)
	input             btn_ctrl_break,
	input             btn_shift_break,
	input      [10:0] ps2_key,         // [7:0] code, [8] ext, [9] pressed, [10] toggle
	output reg        osd_break = 0,
	output reg        osd_ctrl = 0,
	output reg        osd_shift = 0
);

reg  [2:0] old_t;
reg [25:0] cnt = 0;
reg [24:0] boot_wait = 0;
reg        again = 0;                // SHIFT-BREAK again after this cold start

// keyboard SHIFT+F11
reg        old_ps2 = 0, lshift = 0, rshift = 0, kb_sb = 0;
always @(posedge clk) begin
	old_ps2 <= ps2_key[10];
	kb_sb <= 0;
	if (ps2_key[10] != old_ps2 && !ps2_key[8]) begin
		if (ps2_key[7:0] == 8'h12) lshift <= ps2_key[9];
		if (ps2_key[7:0] == 8'h59) rshift <= ps2_key[9];
		if (ps2_key[7:0] == 8'h78 && ps2_key[9] && (lshift || rshift)) kb_sb <= 1;
	end
end

wire auto_shift_break = (boot_wait == 25'd1);
wire scanned = !osd_break && cpu_addr == 16'hDA59;   // after BREAK is let go

always @(posedge clk) begin
	old_t <= {btn_shift_break, btn_ctrl_break, btn_break};
	if (cnt) cnt <= cnt - 1'd1;
	if (boot_wait) boot_wait <= boot_wait - 1'd1;
	osd_break <= cnt > 26'd47200000;   // 48.0M down to 47.2M: 50 ms
	if (!cnt || scanned) begin cnt <= 0; osd_ctrl <= 0; osd_shift <= 0; end
	if (btn_break       & ~old_t[0]) begin cnt <= 26'd48000000; osd_ctrl <= 0; osd_shift <= 0; end
	if (btn_ctrl_break  & ~old_t[1]) begin cnt <= 26'd48000000; osd_ctrl <= 1; osd_shift <= 0; end
	if ((btn_shift_break & ~old_t[2]) | auto_shift_break | kb_sb)
	                                 begin cnt <= 26'd48000000; osd_ctrl <= 0; osd_shift <= ~cold_boot; again <= cold_boot; end
	if (again && scanned) begin again <= 0; boot_wait <= 25'd8000000; end   // 0.5 s
	if (reset) begin
		cnt <= 0; osd_ctrl <= 0; osd_shift <= 0; again <= 0;
		boot_wait <= autoboot ? 25'd24000000 : 25'd0;  // 1.5 s after the reset ends
	end
end

endmodule
