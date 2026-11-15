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
//    .adf/.adm  ADFS S (160 KB, 40 tracks) / M (320 KB, 80 tracks), one side
//    .adl       ADFS L (640 KB, 80 tracks), two sides interleaved by track
//    .ssd       DFS, 10 sectors per track, one side (often cut short)
//    .dsd       DFS, two sides interleaved by track
//  The core never sees the file name, so a mount reads the image's first
//  two blocks: "Hugo" at &201 (the root directory) = ADFS, geometry from
//  the size; else DFS, 80 tracks of 10 sectors (single density), and two
//  sides when the image is larger than the side 0 catalogue's sector count
//  (&106/&107) says one side holds. That sorts all 251 images of MAME's
//  electron_flop list correctly. Sectors past the end of a short image read
//  as zeros (Main_MiSTer), and writes there are dropped.
//  DFS needs a 1770 DFS ROM, e.g. ACP 1770 DFS 2.20 (MAME's ap34 cartridge),
//  loaded as a cartridge (README).
//  rtl/wd1770.sv (from the Geneve 9640 core) is the controller; the sector
//  <-> SD block bridge below is the Geneve core's geneve_disk.sv.
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
	output reg        dfs0 = 0,          // drive 0 holds a DFS disc (.ssd/.dsd): DFS boots (electron_mem)
	output reg  [7:0] ctrl = 8'h20
);

wire fdc_sel  = enable && addr[15:2] == 14'h3F31;   // &FCC4-&FCC7
wire ctrl_sel = enable && addr == 16'hFCC0;
assign sel  = fdc_sel || ctrl_sel;

wire [7:0] fdc_dout;
assign dout = fdc_sel ? fdc_dout : 8'hFF;

`ifdef WD_DEBUG
always @(posedge clk) if (clken && addr[15:4] == 12'hFCC) $display("PLUS3 %s %04x %02x", rnw ? "R" : "W", addr, rnw ? dout : din);
`endif

always @(posedge clk) begin
	// Until the first write the 1770 runs (bit 5 = 1), as in MAME: ACP DFS
	// looks for the chip by writing &5A to the track register and reading it
	// back, before it ever writes the latch.
	if (reset) ctrl <= 8'h20;
	else if (ctrl_sel && clken && !rnw) ctrl <= din;
end

// ------------------------------------------------------------- the 1770
wire        img_rd, img_wr, img_ack, img_drive;
reg         req_rd = 0, req_wr = 0;   // the 1770's one-clock requests, held until served
reg         req_drv = 0;              // (a probe may be running) with their drive
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
// image probe (see the header): a mount sets pend; the probe reads blocks 0/1
reg  [1:0] pend = 0;
reg [31:0] isize [2];
reg        probe = 0, pblk;
reg  [7:0] cat_hi, cat_lo;           // DFS catalogue &106/&107: sectors on side 0
reg [31:0] hugo;                     // bytes &201-&204
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

// ADFS geometry from the image size
function [11:0] geom(input [31:0] size);   // {sides[1:0], tracks[7:0], spare}
	if (size > 32'd327680)      geom = {2'd2, 8'd80, 2'd0};   // ADFS L (.adl)
	else if (size > 32'd163840) geom = {2'd1, 8'd80, 2'd0};   // ADFS M
	else                        geom = {2'd1, 8'd40, 2'd0};   // ADFS S
endfunction

integer d;
reg [11:0] g;
wire [9:0] cat_secs = {cat_hi[1:0], cat_lo};
always @(posedge clk) begin
	g = geom(isize[drv]);
	img_ack_r <= 0;
	if (img_rd) req_rd <= 1'b1;
	if (img_wr) req_wr <= 1'b1;
	if (img_rd || img_wr) req_drv <= img_drive;
	// the probe's bytes, as the block streams in
	if (probe && sd_buff_wr && sd_ack[drv]) begin
		if (!pblk) begin
			if (sd_buff_addr == 9'h106) cat_hi <= sd_buff_dout;
			if (sd_buff_addr == 9'h107) cat_lo <= sd_buff_dout;
		end
		else if (sd_buff_addr >= 9'd1 && sd_buff_addr <= 9'd4) hugo <= {hugo[23:0], sd_buff_dout};
	end
	if (reset) begin
		st <= D_IDLE; sd_rd <= 0; sd_wr <= 0; probe <= 0; req_rd <= 0; req_wr <= 0;
	end
	else case (st)
	D_IDLE: if (req_rd || req_wr) begin
		drv <= req_drv; lsn <= img_lsn; is_write <= req_wr; st <= D_RDREQ;
		req_rd <= 0; req_wr <= 0;
	end
	else if (pend != 2'b00) begin       // probe a new image: block 0, then block 1
		drv <= pend[0] ? 1'b0 : 1'b1;
		probe <= 1'b1; pblk <= 1'b0; lsn <= 16'd0; is_write <= 1'b0;
		st <= D_RDREQ;
	end
	D_RDREQ: begin
		lba_r[drv] <= {17'd0, lsn[15:1]};
		sd_rd[drv] <= 1'b1;
		ack_seen <= 1'b0;
		st <= D_RDWAIT;
	end
	D_RDWAIT: begin
		if (sd_ack[drv]) begin sd_rd[drv] <= 1'b0; ack_seen <= 1'b1; end
		else if (ack_seen && probe) begin
			if (!pblk) begin
				pblk <= 1'b1; lsn <= 16'd2; st <= D_RDREQ;
			end else begin
				if (hugo == "Hugo") begin                  // ADFS
					spt[drv]    <= 8'd16;
					tracks[drv] <= g[9:2];
					sides[drv]  <= g[11:10];
				end else begin                             // DFS: .ssd / .dsd
					if (!drv) dfs0 <= 1'b1;
					spt[drv]    <= 8'd10;
					tracks[drv] <= 8'd80;
					sides[drv]  <= (isize[drv] > {14'd0, cat_secs, 8'd0}) ? 2'd2 : 2'd1;
				end
`ifdef WD_DEBUG
				$display("PLUS3 probe drive %0d size %0d: %s, catalogue %0d sectors", drv, isize[drv],
				         hugo == "Hugo" ? "ADFS" : "DFS", cat_secs);
`endif
				ready[drv] <= 1'b1;
				pend[drv]  <= 1'b0;
				probe      <= 1'b0;
				st <= D_IDLE;
			end
		end
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
	// a mount (last: it wins over a probe of the same drive finishing now)
	for (d = 0; d < 2; d = d + 1)
		if (img_mounted[d]) begin
			ready[d] <= 1'b0;
			if (d == 0) dfs0 <= 1'b0;
			wprot[d] <= img_readonly;
			isize[d] <= img_size[31:0];
			pend[d]  <= (img_size != 64'd0);
		end
end

endmodule
