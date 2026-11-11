//============================================================================
//  Tape status bar for the Acorn Electron core (~/dev2/tape-standard.md
//  rules 19-24; from the PC-8001 and Sharp X1 cores' overlays).
//
//  While a tape is loaded and the cassette relay is on, the bottom-left
//  corner of the picture shows
//
//      TAPE > 0:09/ 1:42 x8
//      [=========----------]
//
//  - elapsed time in the tape's own timebase: quanta of 1/(4 x 1200 Hz)
//    that rtl/uef_player.sv actually played (`qtick`), so turbo does not
//    change it;
//  - total time for a bit stream (what Main_MiSTer sends for a .uef, or a
//    .cas): every byte is 8 bits of 4 quanta, 150 bytes a second. A raw UEF
//    (sim) has no cheap total: elapsed only, as rule 19 allows;
//  - x8 only while turbo is on;
//  - a 64-step bar, bytes read / tape size.
//
//  tape_status (clk_sys) packs it into one word and hands it to tape_overlay
//  (the video clock) with a toggle handshake. The overlay is mixed into the
//  ULA's RGB before video_mixer; it never changes the machine.
//============================================================================

module tape_status #(
	parameter integer QPS = 4800,         // quanta per tape second
	parameter integer BPS = 150           // bit stream bytes per tape second
)(
	input             clk,
	input             loaded,             // a tape is ready to play
	input             playing,            // cassette relay on
	input             fast,               // turbo active
	input             qtick,              // one quantum of tape played
	input      [24:0] position,           // bytes read (back to the start on rewind)
	input      [24:0] length,             // bytes on the tape
	input             timed,              // the total time is known (bit stream)

	output reg [42:0] status = 0,         // held while req != ack
	output reg        req = 0,
	input             ack                 // asynchronous
);

function [15:0] bcd_tick(input [15:0] t);   // m1 m0 s1 s0, saturating at 99:59
	reg [15:0] n;
	begin
		n = t;
		if (t != 16'h9959) begin
			if (t[3:0] != 4'd9) n[3:0] = t[3:0] + 4'd1;
			else begin
				n[3:0] = 0;
				if (t[7:4] != 4'd5) n[7:4] = t[7:4] + 4'd1;
				else begin
					n[7:4] = 0;
					if (t[11:8] != 4'd9) n[11:8] = t[11:8] + 4'd1;
					else begin n[11:8] = 0; n[15:12] = t[15:12] + 4'd1; end
				end
			end
		end
		bcd_tick = n;
	end
endfunction

reg [15:0] elapsed = 0, total = 0;
reg [12:0] frac = 0;
reg [24:0] last_pos = 0, last_len = 0, rem = 0, cell_count = 0;
reg  [6:0] fill = 0;
reg        computing = 0;
reg  [1:0] ack_s = 0;

wire [24:0] cell_bytes = (length[24:6] == 0) ? 25'd1 : {6'd0, length[24:6]};
wire [42:0] pack = {timed, loaded, playing, fast, fill, elapsed, total};

always @(posedge clk) begin
	ack_s <= {ack_s[0], ack};
	last_pos <= position;

	// elapsed time and the bar restart when the tape goes back (load, rewind)
	if (position < last_pos) begin
		elapsed <= 0; frac <= 0; fill <= 0; cell_count <= 0;
	end
	else begin
		if (qtick) begin
			if (frac == QPS - 1) begin frac <= 0; elapsed <= bcd_tick(elapsed); end
			else frac <= frac + 1'd1;
		end
		if (position != last_pos) begin
			if (cell_count + 1'd1 >= cell_bytes) begin
				cell_count <= 0;
				if (fill != 7'd64) fill <= fill + 1'd1;
			end
			else cell_count <= cell_count + 1'd1;
		end
	end

	// total time: one second of bytes off per clock after a new length
	last_len <= length;
	if (length != last_len) begin rem <= length; total <= 0; computing <= 1; end
	else if (computing) begin
		if (rem >= BPS) begin rem <= rem - BPS[24:0]; total <= bcd_tick(total); end
		else computing <= 0;
	end

	if (req == ack_s[1] && pack != status) begin
		status <= pack;
		req <= ~req;
	end
end

endmodule


module tape_overlay #(parameter [3:0] FACTOR = 4'd8)
(
	input             clk,                // video clock
	input             ce_pix,
	input             hblank,
	input             vblank,
	input             enable,             // OSD Tape overlay On
	input      [42:0] status,             // from tape_status, stable while req != ack
	input             req,
	output reg        ack = 0,
	input      [23:0] rgb_in,
	output reg [23:0] rgb_out
);

localparam integer CHARS = 21;

reg  [1:0] req_s = 0;
reg [42:0] shown = 0;
reg [10:0] x = 0, width = 0;
reg  [9:0] y = 0, height = 0;
reg        line_active = 0, old_hblank = 0, old_vblank = 0;

// measure the active picture every frame (rule 23)
always @(posedge clk) begin
	req_s <= {req_s[0], req};
	if (req_s[1] != ack) begin shown <= status; ack <= req_s[1]; end
	if (ce_pix) begin
		old_hblank <= hblank; old_vblank <= vblank;
		if (!hblank && !vblank) begin x <= x + 1'd1; line_active <= 1; end
		if (hblank && !old_hblank) begin
			if (line_active) begin width <= x; y <= y + 1'd1; end
			x <= 0; line_active <= 0;
		end
		if (vblank && !old_vblank) begin height <= y; y <= 0; end
	end
end

wire        timed   = shown[42];
wire        visible = enable && shown[41] && shown[40];
wire        fast    = shown[39];
wire  [6:0] fill    = shown[38:32];
wire [15:0] elapsed = shown[31:16];
wire [15:0] total   = shown[15:0];

// doubled on pictures at least 512 wide / 300 lines (rule 21)
wire        sx = (width  >= 11'd512);
wire        sy = (height >= 10'd300);
localparam [10:0] BOX_W = CHARS * 8 + 4;
localparam  [9:0] BOX_H = 18;
wire [10:0] x0 = 11'd4;
wire  [9:0] y0 = height - (sy ? {BOX_H[8:0], 1'b0} : BOX_H) - 10'd4;
wire [10:0] dx = x - x0;
wire  [9:0] dy = y - y0;
wire [10:0] lx = sx ? {1'b0, dx[10:1]} : dx;
wire  [9:0] ly = sy ? {1'b0, dy[9:1]} : dy;
wire        in_box = (x >= x0) && (y >= y0) && (lx < BOX_W) && (ly < BOX_H);

// text row at ly 2..9: codes 0-9 digits, 10 ':', 11 '/', 12 T, 13 A,
// 14 P, 15 E, 16 x, 17 play, 18 space
wire [10:0] tx  = lx - 11'd2;
wire  [9:0] ty  = ly - 10'd2;
wire  [4:0] col = tx[7:3];

function [4:0] digit(input [3:0] d, input blank_zero);
	digit = (blank_zero && d == 0) ? 5'd18 : {1'b0, d};
endfunction

reg [4:0] code;
always @(*) begin
	case (col)
		5'd0:  code = 5'd12;  5'd1: code = 5'd13;  5'd2: code = 5'd14;  5'd3: code = 5'd15;
		5'd4:  code = 5'd18;  5'd5: code = 5'd17;  5'd6: code = 5'd18;
		5'd7:  code = digit(elapsed[15:12], 1'b1);  5'd8: code = {1'b0, elapsed[11:8]};
		5'd9:  code = 5'd10;  5'd10: code = {1'b0, elapsed[7:4]};  5'd11: code = {1'b0, elapsed[3:0]};
		5'd12: code = timed ? 5'd11 : 5'd18;
		5'd13: code = timed ? digit(total[15:12], 1'b1) : 5'd18;
		5'd14: code = timed ? {1'b0, total[11:8]} : 5'd18;
		5'd15: code = timed ? 5'd10 : 5'd18;
		5'd16: code = timed ? {1'b0, total[7:4]} : 5'd18;
		5'd17: code = timed ? {1'b0, total[3:0]} : 5'd18;
		5'd19: code = fast ? 5'd16 : 5'd18;
		5'd20: code = fast ? {1'b0, FACTOR} : 5'd18;
		default: code = 5'd18;
	endcase
end

function [7:0] glyph(input [4:0] c, input [2:0] r);
	reg [63:0] g;
	begin
		case (c)
			5'd0:  g = 64'h3C666E7666663C00;  5'd1:  g = 64'h1838181818187E00;
			5'd2:  g = 64'h3C66060C30607E00;  5'd3:  g = 64'h3C66061C06663C00;
			5'd4:  g = 64'h0C1C3C6C7E0C0C00;  5'd5:  g = 64'h7E607C0606663C00;
			5'd6:  g = 64'h1C30607C66663C00;  5'd7:  g = 64'h7E060C1830303000;
			5'd8:  g = 64'h3C66663C66663C00;  5'd9:  g = 64'h3C66663E060C3800;
			5'd10: g = 64'h0018180018180000;  5'd11: g = 64'h02060C1830604000;
			5'd12: g = 64'h7E18181818181800;  5'd13: g = 64'h183C66667E666600;
			5'd14: g = 64'h7C66667C60606000;  5'd15: g = 64'h7E60607C60607E00;
			5'd16: g = 64'h0000663C183C6600;  5'd17: g = 64'h4060707870604000;
			default: g = 64'h0;
		endcase
		glyph = g[63 - 8 * r -: 8];
	end
endfunction

wire [7:0] glyph_row = glyph(code, ty[2:0]);
wire       text_on   = (ty < 10'd8) && (tx < CHARS * 8) && glyph_row[3'd7 - tx[2:0]];
// progress bar at ly 12..15, 128 px for 64 steps
wire       bar_area  = (ly >= 10'd12) && (ly < 10'd16) && (lx >= 11'd2) && (lx < 11'd130);
wire       bar_on    = bar_area && ((lx - 11'd2) < {3'd0, fill, 1'b0});

always @(*) begin
	rgb_out = rgb_in;
	if (visible && in_box)
		rgb_out = text_on ? 24'hFFFFFF : bar_on ? 24'h44CC44 : bar_area ? 24'h333333 : 24'h000000;
end

endmodule
