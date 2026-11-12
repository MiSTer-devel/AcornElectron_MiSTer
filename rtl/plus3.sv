//============================================================================
//  Acorn Plus 3: WD1770 floppy interface for the Electron (as MAME's
//  bus/electron/plus3.cpp; Acorn Plus 3 User Guide).
//
//  &FCC0  write: drive control latch: bit 0 drive 0, bit 1 drive 1, bit 2
//         side, bit 3 density (1 = single), bit 5 1770 reset (0 = reset).
//         Reads &FF.
//  &FCC4-&FCC7  WD1770 (status/command, track, sector, data). INTRQ and DRQ
//         are not wired to the CPU: ADFS polls the status register.
//  The ADFS ROM is ROM 13 here (rtl/electron_mem.sv; the real Plus 3 has it
//  in ROM 4, where this core keeps MMFS).
//
//  Drives are two MiSTer image slots, 256-byte-sector dumps:
//    .adf  ADFS S (160 KB, 40 tracks) / M (320 KB, 80 tracks), one side
//    .adl  ADFS L (640 KB, 80 tracks), two sides interleaved by track
//  rtl/wd1770.sv (from the Geneve 9640 core) is the controller; the sector
//  <-> SD block bridge below is the Geneve core's geneve_disk.sv with the
//  geometry taken from the image size (ADFS images carry none we can trust).
//============================================================================

module plus3 #(parameter int CLK_HZ = 16000000)
(
	input             clk,
	input             reset,
	input             enable,            // Plus 3 fitted (OSD, latched at reset)

	// CPU bus (ElectronFpga_core expansion port)
	input      [15:0] addr,
	input       [7:0] din,               // CPU data out
	input             rnw,
	input             clken,             // one clock per CPU cycle, at its end
	output      [7:0] dout,
	output            sel,               // Plus 3 drives the data bus

	// hps_io image slots for drive 0 and drive 1
	input       [1:0] img_mounted,
	input             img_readonly,
	input      [63:0] img_size,
	output     [31:0] sd_lba [2],
	output reg  [1:0] sd_rd = 0,
	output reg  [1:0] sd_wr = 0,
	input       [1:0] sd_ack,
	input       [8:0] sd_buff_addr,
	input       [7:0] sd_buff_dout,
	output      [7:0] sd_buff_din [2],
	input             sd_buff_wr,

	output            busy,              // disk activity (LED)
	output reg  [7:0] ctrl = 8'h00
);

wire fdc_sel  = enable && addr[15:2] == 14'h3F31;   // &FCC4-&FCC7
wire ctrl_sel = enable && addr == 16'hFCC0;
assign sel  = fdc_sel || ctrl_sel;

wire [7:0] fdc_dout;
assign dout = fdc_sel ? fdc_dout : 8'hFF;

always @(posedge clk) begin
	if (reset) ctrl <= 8'h00;
	else if (ctrl_sel && clken && !rnw) ctrl <= din;
end

// ------------------------------------------------------------- the 1770
wire        img_rd, img_wr, img_ack, img_drive;
wire [15:0] img_lsn;
wire        buf_wr;
wire  [7:0] buf_addr, buf_din, buf_dout;
reg   [1:0] ready = 0, wprot = 0;
reg   [1:0][7:0] spt = 0, tracks = 0;
reg   [1:0][1:0] sides = 0;

wd1770 #(.CLK_HZ(CLK_HZ)) wd1770
(
	.clk(clk),
	.reset(reset || !enable || !ctrl[5]),
	.rd(fdc_sel && clken && rnw),
	.wr(fdc_sel && clken && !rnw),
	.addr(addr[1:0]),
	.din(din),
	.dout(fdc_dout),
	.intrq(),
	.drq(),
	.drive(ctrl[0] ? 2'd1 : ctrl[1] ? 2'd2 : 2'd0),
	.side(ctrl[2]),
	.dden_n(ctrl[3]),
	.ready(ready),
	.wprot(wprot),
	.spt(spt),
	.tracks(tracks),
	.sides(sides),
	.img_rd(img_rd),
	.img_wr(img_wr),
	.img_lsn(img_lsn),
	.img_drive(img_drive),
	.img_ack(img_ack),
	.buf_wr(buf_wr),
	.buf_addr(buf_addr),
	.buf_din(buf_din),
	.buf_dout(buf_dout)
);

// --------------------------------------------- sectors <-> SD blocks
// ADFS sectors are 256 bytes, SD blocks 512: a read loads the block and
// copies its half into the 1770's buffer; a write loads the block, replaces
// the half and writes the block back. blk is a true dual-port block RAM:
// port A the SD side, port B the copies (both reads registered).
wire [7:0] blk_qa, blk_qb;
reg [31:0] lba_r [2];
assign sd_lba[0] = lba_r[0];
assign sd_lba[1] = lba_r[1];
assign sd_buff_din[0] = blk_qa;
assign sd_buff_din[1] = blk_qa;

localparam [2:0] D_IDLE = 0, D_RDREQ = 1, D_RDWAIT = 2, D_COPYOUT = 3, D_COPYIN = 4, D_WRREQ = 5, D_WRWAIT = 6, D_ACK = 7;
reg  [2:0] st = D_IDLE;
reg        drv, is_write, ack_seen;
reg [15:0] lsn;
reg  [8:0] cnt;
reg        img_ack_r = 0;
assign img_ack  = img_ack_r;
assign busy     = (st != D_IDLE);

// The copies run cnt 0..256 and use the byte that arrives one clock late:
//   out: blk_qb = blk[half, cnt-1] -> 1770 buffer[cnt-1]
//   in:  buf_dout = 1770 buffer[cnt-1] -> blk[half, cnt-1]
assign buf_addr = (st == D_COPYOUT) ? cnt[7:0] - 8'd1 : cnt[7:0];
assign buf_wr   = (st == D_COPYOUT) && cnt != 9'd0;
assign buf_din  = blk_qb;
wire       blk_we_b = (st == D_COPYIN) && cnt != 9'd0;
wire [8:0] blk_a_b  = {lsn[0], blk_we_b ? cnt[7:0] - 8'd1 : cnt[7:0]};

dpram #(.AW(9)) blk
(
	.clk(clk),
	.addr_a(sd_buff_addr), .din_a(sd_buff_dout), .we_a(sd_buff_wr && sd_ack != 2'b00), .q_a(blk_qa),   // SD side
	.addr_b(blk_a_b), .din_b(buf_dout), .we_b(blk_we_b), .q_b(blk_qb)                                // the copies
);

// geometry from the image size
function [11:0] geom(input [31:0] size);   // {sides[1:0], tracks[7:0], spare}
	if (size > 32'd327680)      geom = {2'd2, 8'd80, 2'd0};   // ADFS L (.adl)
	else if (size > 32'd163840) geom = {2'd1, 8'd80, 2'd0};   // ADFS M
	else                        geom = {2'd1, 8'd40, 2'd0};   // ADFS S
endfunction

integer d;
reg [11:0] g;
always @(posedge clk) begin
	g = geom(img_size[31:0]);
	img_ack_r <= 0;
	for (d = 0; d < 2; d = d + 1)
		if (img_mounted[d]) begin
			ready[d]  <= (img_size != 64'd0);
			wprot[d]  <= img_readonly;
			spt[d]    <= 8'd16;
			tracks[d] <= g[9:2];
			sides[d]  <= g[11:10];
		end
	if (reset) begin
		st <= D_IDLE; sd_rd <= 0; sd_wr <= 0;
	end
	else case (st)
	D_IDLE: if (img_rd || img_wr) begin
		drv <= img_drive; lsn <= img_lsn; is_write <= img_wr; st <= D_RDREQ;
	end
	D_RDREQ: begin
		lba_r[drv] <= {17'd0, lsn[15:1]};
		sd_rd[drv] <= 1'b1;
		ack_seen <= 1'b0;
		st <= D_RDWAIT;
	end
	D_RDWAIT: begin
		if (sd_ack[drv]) begin sd_rd[drv] <= 1'b0; ack_seen <= 1'b1; end
		else if (ack_seen) begin cnt <= 9'd0; st <= is_write ? D_COPYIN : D_COPYOUT; end
	end
	D_COPYOUT: begin   // block half -> 1770 buffer
		cnt <= cnt + 9'd1;
		if (cnt == 9'd256) st <= D_ACK;
	end
	D_COPYIN: begin    // 1770 buffer -> block half
		cnt <= cnt + 9'd1;
		if (cnt == 9'd256) st <= D_WRREQ;
	end
	D_WRREQ: begin
		sd_wr[drv] <= 1'b1;
		ack_seen <= 1'b0;
		st <= D_WRWAIT;
	end
	D_WRWAIT: begin
		if (sd_ack[drv]) begin sd_wr[drv] <= 1'b0; ack_seen <= 1'b1; end
		else if (ack_seen) st <= D_ACK;
	end
	default: begin     // D_ACK
		img_ack_r <= 1'b1;
		st <= D_IDLE;
	end
	endcase
end

endmodule
