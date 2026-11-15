//============================================================================
//  Sound Expansion cartridge (as MAME bus/electron/cart/sndexp.cpp and
//  sndexp3.cpp): an SN76489 (jt89, rtl/jt89) at 4 MHz, written through a
//  latch: the byte goes to &FC84 (v1/v2, Project Expansions) or &FC98 (v3,
//  Complex Software Systems), a 0->1 on bit 0 of &FC85 / &FC99 writes it to
//  the chip. Both address pairs answer. The cartridge's 8 KB ROM and 8 KB
//  RAM are the OSD Cartridge 1 socket (ROM 2: &8000 ROM, &A000-&BFFF made
//  writable by the core while this is on, sndexp_ram).
//============================================================================

module sndexp
(
	input             clk,             // 16 MHz
	input             reset,
	input             enable,

	input      [15:0] addr,            // CPU bus (ElectronFpga_core expansion port)
	input       [7:0] din,
	input             rnw,
	input             clken,

	output signed [10:0] sound
);

reg  [7:0] latch = 0;
reg        strobe = 0, wr = 0;
reg  [1:0] cdiv = 0;
always @(posedge clk) cdiv <= cdiv + 2'd1;     // 4 MHz chip clock enable

wire wr_cyc = enable && clken && !rnw;
`ifdef SNDEXP_DEBUG
always @(posedge clk) if (clken && !rnw && addr[15:8] == 8'hFC && addr[7:4] >= 4'h8 && addr[7:4] <= 4'h9) $display("SNDEXP W %04x %02x en %0d", addr, din, enable);
always @(posedge clk) if (wr) $display("SNDEXP chip %02x", latch);
`endif
always @(posedge clk) begin
	wr <= 0;
	if (reset) begin latch <= 0; strobe <= 0; end
	else if (wr_cyc) begin
		if (addr == 16'hFC84 || addr == 16'hFC98) latch <= din;
		if (addr == 16'hFC85 || addr == 16'hFC99) begin
			if (din[0] && !strobe) wr <= 1;
			strobe <= din[0];
		end
	end
end

jt89 sn
(
	.rst(reset || !enable),
	.clk(clk),
	.clk_en(cdiv == 2'd0),
	.wr_n(~wr),
	.cs_n(1'b0),
	.din(latch),
	.sound(sound),
	.ready()
);

endmodule
