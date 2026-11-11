//============================================================================
//  Acorn Electron tape: load, gunzip, play. Shared by AcornElectron.sv and
//  vsim/sim.v; the memory behind `mem_*` is SDRAM there and an array here.
//
//  1. A tape download (OSD Tape) is written to memory from address 0.
//  2. If it starts with the gzip magic (1F 8B), rtl/inflate.sv unpacks it
//     to OUT_BASE (UEF files are usually gzipped).
//  3. "UEF File!" + NUL: rtl/uef_player.sv plays the chunks. Anything else
//     is a bit stream (a .cas file, or a .uef that Main_MiSTer has already
//     converted: Main does that for this core, support/uef/uef_reader.cpp),
//     played by the same player in raw mode. Turbo works for both.
//
//  The memory port takes one request at a time (mem_req, held until
//  mem_ack); all users of it run in turn, never together.
//============================================================================

module tape #(parameter CLK_HZ = 16000000, parameter [24:0] OUT_BASE = 25'h0800000)
(
	input             clk,
	input             reset,

	// tape download (hps_io ioctl, index already selected)
	input             load,           // a tape download is in progress
	input             ioctl_wr,
	input      [24:0] ioctl_addr,
	input       [7:0] ioctl_dout,
	output            ioctl_wait,

	input             rewind,         // OSD Rewind tape (level)
	input             motor,          // ULA cassette relay
	input       [4:0] speed,          // 1 = real time, N = N times faster (UEF only)

	// byte memory port
	output reg        mem_req = 0,
	output reg        mem_we = 0,
	output reg [24:0] mem_addr = 0,
	output reg  [7:0] mem_din = 0,
	input             mem_ack,
	input       [7:0] mem_dout,

	output            cas_out,        // tape signal to the ULA
	output reg        is_uef = 0,     // the tape data is UEF chunks (else a bit stream)
	output            ready,          // a tape is loaded and playing / ready to play
	output reg        unpacking = 0,
	output reg        error = 0,      // bad gzip data
	output     [24:0] position,       // for the status display
	output     [24:0] length
);

// ------------------------------------------------------------ load / unpack
localparam [2:0] T_IDLE = 0, T_LOAD = 1, T_INFLATE = 2, T_CHECK = 3, T_PLAY = 4;
reg  [2:0] tstate = T_IDLE;

reg [24:0] size;          // bytes downloaded
reg [24:0] data_base, data_len;
reg [79:0] magic;         // first 10 bytes of the tape data (download or unpacked)
reg  [3:0] magic_n;
reg        old_load;

wire       is_gzip = (magic[7:0] == 8'h1F) && (magic[15:8] == 8'h8B);
wire       is_uef_magic = (magic == {8'h00, "!eliF FEU"});   // "UEF File!\0", little end first

// inflate
reg        inf_start = 0;
wire       inf_busy, inf_done, inf_error;
wire [3:0] inf_code;
wire       inf_in_req;
reg        inf_in_valid = 0;
reg  [7:0] inf_in_data;
wire       inf_out_valid;
reg        inf_out_ready = 0;
wire [7:0] inf_out_data;
wire [23:0] inf_count;
reg [24:0] inf_in_ptr;

inflate inflate
(
	.clk(clk), .reset(reset),
	.start(inf_start), .busy(inf_busy), .done(inf_done), .error(inf_error), .error_code(inf_code),
	.in_req(inf_in_req), .in_valid(inf_in_valid), .in_data(inf_in_data),
	.out_valid(inf_out_valid), .out_ready(inf_out_ready), .out_data(inf_out_data),
	.out_count(inf_count)
);

// player: UEF chunks, or a bit stream from address 0
reg play_d = 0;
always @(posedge clk) play_d <= (tstate == T_PLAY);

wire        uef_req;
wire [24:0] uef_addr;
reg         uef_ack = 0;
reg   [7:0] rd_data;
wire        uef_out;
wire        uef_end;
wire [24:0] uef_pos;

uef_player #(.CLK_HZ(CLK_HZ)) uef_player
(
	.clk(clk), .reset(reset),
	.rewind(rewind || !play_d),   // one clock after T_PLAY, so is_uef is settled
	.start_addr(is_uef ? data_base + 25'd12 : data_base), .end_addr(data_base + data_len),
	.motor(motor), .speed(speed), .raw(!is_uef),
	.mem_req(uef_req), .mem_addr(uef_addr), .mem_ack(uef_ack), .mem_data(rd_data),
	.cas_out(uef_out), .at_end(uef_end), .position(uef_pos)
);

assign ready = (tstate == T_PLAY);
assign cas_out  = uef_out;
assign position = uef_pos - data_base;
assign length   = data_len;

// ------------------------------------------------------------ memory users
// One request at a time. During T_LOAD: download writes (ioctl_wait holds
// hps_io until each is done). T_INFLATE: inflate output writes and input
// reads. T_PLAY: the active player's reads.
reg        busy = 0;            // a mem request is outstanding
reg  [1:0] who;                 // 0 download, 1 inflate in, 2 inflate out, 3 player
reg        dl_pend = 0, out_pend = 0, in_pend = 0, uef_pend = 0;
reg  [7:0] dl_byte, out_byte;
reg [24:0] dl_addr;

assign ioctl_wait = dl_pend | (load & ioctl_wr);   // hold the next byte until this one is written

always @(posedge clk) begin
	inf_start     <= 0;
	inf_in_valid  <= 0;
	inf_out_ready <= 0;
	uef_ack       <= 0;
	old_load      <= load;

	// --- collect requests
	if (load && ioctl_wr) begin dl_pend <= 1; dl_byte <= ioctl_dout; dl_addr <= ioctl_addr; size <= ioctl_addr + 1'd1; end
	if (inf_in_req) in_pend <= 1;
	if (uef_req) uef_pend <= 1;
	if (tstate == T_INFLATE && inf_out_valid && !out_pend && !inf_out_ready) begin
		out_pend <= 1; out_byte <= inf_out_data;
	end

	// --- issue one at a time
	if (!busy && !mem_req) begin
		if (dl_pend) begin
			mem_req <= 1; mem_we <= 1; mem_addr <= dl_addr; mem_din <= dl_byte; who <= 0; busy <= 1;
		end
		else if (out_pend) begin
			mem_req <= 1; mem_we <= 1; mem_addr <= OUT_BASE + inf_count - 1'd1; mem_din <= out_byte; who <= 2; busy <= 1;
		end
		else if (in_pend) begin
			mem_req <= 1; mem_we <= 0; mem_addr <= inf_in_ptr; who <= 1; busy <= 1;
		end
		else if (tstate == T_PLAY && uef_pend) begin
			mem_req <= 1; mem_we <= 0; mem_addr <= uef_addr; who <= 3; busy <= 1;
		end
	end
	if (mem_ack) begin
		mem_req <= 0; busy <= 0;
		case (who)
			0: dl_pend <= 0;
			1: begin in_pend <= 0; inf_in_valid <= 1; inf_in_data <= mem_dout; inf_in_ptr <= inf_in_ptr + 1'd1; end
			2: begin out_pend <= 0; inf_out_ready <= 1; end
			default: begin rd_data <= mem_dout; uef_ack <= 1; uef_pend <= 0; end
		endcase
	end

	// --- magic bytes: the first 10 bytes of the download / of the unpacked data
	if (load && ioctl_wr && ioctl_addr < 10) magic <= {ioctl_dout, magic[79:8]};
	if (tstate == T_INFLATE && out_pend && who == 2 && mem_ack && magic_n < 10) begin
		magic <= {out_byte, magic[79:8]}; magic_n <= magic_n + 1'd1;
	end

	// --- sequence
	case (tstate)
	T_IDLE, T_PLAY: ;
	T_LOAD: if (!load && !dl_pend && !busy) begin
		if (is_gzip) begin
			tstate <= T_INFLATE; unpacking <= 1; inf_start <= 1; inf_in_ptr <= 0;
			magic_n <= 0; magic <= 0;
		end else begin
			data_base <= 0; data_len <= size; tstate <= T_CHECK;
		end
	end
	T_INFLATE: if (inf_done && !out_pend && !busy) begin
		unpacking <= 0; data_base <= OUT_BASE; data_len <= inf_count; tstate <= T_CHECK;
	end else if (inf_error) begin
		unpacking <= 0; error <= 1; tstate <= T_IDLE;
	end
	T_CHECK: begin is_uef <= is_uef_magic; tstate <= T_PLAY; end
	default: tstate <= T_IDLE;
	endcase

	if (load && !old_load) begin
		tstate <= T_LOAD; error <= 0; is_uef <= 0; magic <= 0; size <= 0;
		in_pend <= 0; out_pend <= 0;
	end
	if (reset) begin
		busy <= 0; mem_req <= 0; dl_pend <= 0; in_pend <= 0; out_pend <= 0; uef_pend <= 0;
		if (tstate != T_PLAY) tstate <= T_IDLE;
	end
end

endmodule
