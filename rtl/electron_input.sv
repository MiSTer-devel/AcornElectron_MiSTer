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


// OSD BREAK / Ctrl-BREAK (trigger buttons). BREAK is held for the first
// 50 ms; for Ctrl-BREAK CTRL is held for 300 ms, so the MOS still sees it
// after BREAK is released. Times assume a 16 MHz clk.
module electron_osd_buttons
(
	input             clk,
	input             reset,
	input             btn_break,       // OSD T bits (level, rising edge acts)
	input             btn_ctrl_break,
	output reg        osd_break = 0,
	output reg        osd_ctrl = 0
);

reg  [1:0] old_t;
reg [22:0] cnt = 0;

always @(posedge clk) begin
	old_t <= {btn_ctrl_break, btn_break};
	if (cnt) cnt <= cnt - 1'd1;
	osd_break <= cnt > 23'd4000000;   // 4.8M down to 4.0M: 50 ms
	if (!cnt) osd_ctrl <= 0;
	if (btn_break      & ~old_t[0]) begin cnt <= 23'd4800000; osd_ctrl <= 0; end
	if (btn_ctrl_break & ~old_t[1]) begin cnt <= 23'd4800000; osd_ctrl <= 1; end
	if (reset) begin cnt <= 0; osd_ctrl <= 0; end
end

endmodule
