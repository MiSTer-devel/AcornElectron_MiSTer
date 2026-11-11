//============================================================================
//  UEF tape player for the Acorn Electron core.
//
//  Reads a plain UEF from memory (one byte per request) and plays it as the
//  cassette signal the ULA decodes. Chunks: &0100 (data), &0104 (defined
//  format data), &0110 (carrier), &0111 (carrier + dummy byte), &0112 /
//  &0116 (gaps), &0113 (base frequency), &0114 (security cycles), &0117
//  (300/1200 baud). Others (&0000-&00FF info, &0115 phase, &0120 ...) are
//  skipped. Spec: refs/docs/tape_formats/UEFSpecs_electrem.txt; gap units
//  as MAME's lib/formats/uef_cas.cpp (&0112 n = n/(2 * base) seconds).
//
//  Timing: everything is built from "quanta" of 1/(4 x base frequency)
//  seconds (1/4800 s at 1200 Hz): a carrier cycle is 1 quantum high + 1 low,
//  a base-frequency cycle 2 + 2. A phase accumulator makes quanta from clk
//  (CLK_HZ) and plays them `speed` times faster for turbo loading.
//
//  The tape only moves while `motor` is on (the ULA's cassette relay).
//  `rewind` goes back to the first chunk.
//
//  raw = 1: the memory holds a plain bit stream instead (a .cas file, or what
//  Main_MiSTer sends for a .uef: it converts UEFs itself for this core,
//  support/uef/uef_reader.cpp): one tape bit per bit, first bit in the MSB,
//  each bit played as a data bit (1 = two carrier cycles, 0 = one slow cycle).
//============================================================================

module uef_player #(parameter CLK_HZ = 16000000)
(
	input             clk,
	input             reset,
	input             rewind,          // level; acts while high
	input      [24:0] start_addr,      // first chunk (after the 12-byte header)
	input      [24:0] end_addr,        // first byte after the file
	input             motor,
	input       [4:0] speed,           // 1 = real time, N = N times faster
	input             raw,             // bit stream instead of UEF chunks

	output reg        mem_req = 0,     // one-clock read request
	output reg [24:0] mem_addr = 0,
	input             mem_ack,         // one clock, with mem_data
	input       [7:0] mem_data,

	output reg        cas_out = 0,     // the tape signal
	output reg        at_end = 0,      // all chunks played
	output     [24:0] position         // read pointer (for a status display)
);

assign position = mem_addr;

// ------------------------------------------------------------- wave unit
// Commands: W_CYC: `w_count` cycles, fast (2x base) or slow (base);
//           W_GAP: `w_count` quanta of silence (low);
//           W_HIGH / W_LOW: one pulse of 1 (fast) or 2 (slow) quanta.
// The producer pulses w_go for one clock when wv_busy is low.
localparam [1:0] W_CYC = 2'd0, W_GAP = 2'd1, W_HIGH = 2'd2, W_LOW = 2'd3;

reg        w_go = 0;
reg  [1:0] w_type;
reg        w_fast;
reg [31:0] w_count;

reg        wv_busy = 0;
reg  [1:0] wv_type;
reg        wv_fast;
reg [31:0] wv_count;      // cycles / quanta left
reg        wv_half;       // W_CYC: 0 = high half, 1 = low half
reg  [1:0] wv_q;          // quanta left in this half / pulse

reg [15:0] base_freq = 1200;
reg [24:0] acc = 0;
wire [24:0] inc = {base_freq, 2'b00} * speed;   // 4 x f x N quanta per second
wire       tick = motor && (acc + inc >= CLK_HZ);

always @(posedge clk) begin
	if (motor) acc <= tick ? acc + inc - CLK_HZ : acc + inc;

	if (w_go) begin
		wv_type <= w_type; wv_fast <= w_fast; wv_count <= w_count;
		wv_half <= 0; wv_q <= w_fast ? 2'd1 : 2'd2;
		wv_busy <= !((w_type == W_CYC || w_type == W_GAP) && w_count == 0);
	end
	else if (wv_busy && tick) begin
		case (wv_type)
		W_GAP: begin
			cas_out <= 0;
			wv_count <= wv_count - 1'd1;
			if (wv_count == 1) wv_busy <= 0;
		end
		W_HIGH, W_LOW: begin
			cas_out <= (wv_type == W_HIGH);
			wv_q <= wv_q - 1'd1;
			if (wv_q == 1) wv_busy <= 0;
		end
		default: begin   // W_CYC: high half then low half
			cas_out <= !wv_half;
			if (wv_q == 1) begin
				wv_q <= wv_fast ? 2'd1 : 2'd2;
				wv_half <= !wv_half;
				if (wv_half) begin
					wv_count <= wv_count - 1'd1;
					if (wv_count == 1) wv_busy <= 0;
				end
			end
			else wv_q <= wv_q - 1'd1;
		end
		endcase
	end
	if (!motor) cas_out <= 0;
	if (reset || rewind) begin wv_busy <= 0; acc <= 0; cas_out <= 0; end
end

// -------------------------------------------------------------- producer
localparam [4:0]
	P_END = 0, P_CHUNK = 1, P_HDR = 2, P_SKIP = 3,
	P_DATA = 4, P_PACK = 5, P_BITS = 6, P_ARGS = 7, P_D104_HDR = 8,
	P_111_BITS = 9, P_SEC_HDR = 10, P_SEC = 11,
	P_FETCH = 12, P_FETCH_WAIT = 13, P_WAVE = 14,
	P_RAW = 15, P_RAW_LOAD = 16, P_RAW_BITS = 17;

reg  [4:0] p_state = P_END, p_ret, p_wret;
reg  [7:0] fbyte;          // the byte just fetched
reg [47:0] hdr;            // chunk id + length, shifted in little endian
reg  [2:0] hdr_n;
reg [15:0] chunk_id;
reg [31:0] chunk_left;     // bytes of the chunk not yet read
reg [31:0] args;           // a chunk's 2- or 4-byte argument
reg  [2:0] sn;
reg [10:0] bits;           // packet bits still to send, LSB first
reg  [3:0] nbits;
reg        slow_baud = 0;  // &0117: 300 baud
reg  [7:0] fmt_bits, fmt_parity;
reg  [1:0] fmt_stop;       // stop bits
reg        fmt_extra;      // &0104 negative stop count: one extra short wave
reg [23:0] sec_n;
reg  [7:0] sec_first, sec_last;
reg  [2:0] sec_bit;
reg        sec_loaded, sec_first_pending;

// IEEE single -> integer part of (value x m)
function [31:0] float_mul(input [31:0] f, input [17:0] m);
	reg [47:0] p; reg [7:0] e;
	begin
		e = f[30:23];
		p = {24'd0, (e == 0) ? 1'b0 : 1'b1, f[22:0]} * m;   // value = p * 2^(e-150)
		if (f[31] || e < 8'd96) float_mul = 0;
		else if (e >= 8'd150) float_mul = 32'hFFFFFFFF;
		else float_mul = p >> (8'd150 - e);
	end
endfunction

// queue one wave command, then go to `ret`
task wave(input [1:0] t, input fast, input [31:0] n, input [4:0] ret);
	begin
		w_type <= t; w_fast <= fast; w_count <= n;
		p_wret <= ret; p_state <= P_WAVE;
	end
endtask

// read the next byte of the file into fbyte, then go to `ret`
task fetch(input [4:0] ret);
	begin
		p_ret <= ret; p_state <= P_FETCH;
	end
endtask

// bits of a data packet: start 0, data LSB first, parity, stop 1s
function [14:0] packet(input [7:0] d_in, input [7:0] nb, input [7:0] parity, input [1:0] nstop);
	reg [7:0] d; reg par; reg [3:0] n; reg [10:0] b; integer i;
	begin
		d = (nb < 8) ? d_in & ((8'd1 << nb) - 1'd1) : d_in;
		par = ^d;
		b = 0; n = 1;                                             // b[0] = 0: start bit
		for (i = 0; i < 8; i = i + 1) if (i < nb) begin b[n] = d[i]; n = n + 1'd1; end
		if (parity == "E") begin b[n] = par;  n = n + 1'd1; end
		if (parity == "O") begin b[n] = ~par; n = n + 1'd1; end
		for (i = 0; i < 3; i = i + 1) if (i < nstop) begin b[n] = 1'b1; n = n + 1'd1; end
		packet = {n, b};
	end
endfunction

wire [31:0] args_n = {fbyte, args[31:8]};   // args with the byte just fetched
wire  [2:0] nargs  = (chunk_id == 16'h0111 || chunk_id == 16'h0113 || chunk_id == 16'h0116) ? 3'd4 : 3'd2;

always @(posedge clk) begin
	mem_req <= 0;
	w_go    <= 0;

	case (p_state)
	P_END: ;

	P_FETCH: begin
		if (mem_addr >= end_addr) begin at_end <= 1; p_state <= P_END; end
		else begin mem_req <= 1; p_state <= P_FETCH_WAIT; end
	end
	P_FETCH_WAIT: if (mem_ack) begin
		fbyte <= mem_data; mem_addr <= mem_addr + 1'd1;
		if (chunk_left) chunk_left <= chunk_left - 1'd1;
		p_state <= p_ret;
	end
	P_WAVE: if (!wv_busy && !w_go) begin w_go <= 1; p_state <= p_wret; end

	// ---- chunk header: id (2 bytes) + length (4 bytes)
	P_CHUNK: begin hdr_n <= 0; chunk_left <= 0; fetch(P_HDR); end
	P_HDR: begin
		hdr <= {fbyte, hdr[47:8]};
		hdr_n <= hdr_n + 1'd1;
		if (hdr_n != 5) fetch(P_HDR);
		else begin
			chunk_id   <= hdr[23:8];                   // bytes 0-1
			chunk_left <= {fbyte, hdr[47:24]};         // bytes 2-5
			sn <= 0; args <= 0;
			fmt_bits <= 8; fmt_parity <= "N"; fmt_stop <= 1; fmt_extra <= 0;
			case (hdr[23:8])
				16'h0100: p_state <= P_DATA;
				16'h0104: begin sn <= 1; fetch(P_D104_HDR); end
				16'h0110, 16'h0111, 16'h0112, 16'h0113, 16'h0116, 16'h0117: begin sn <= 1; fetch(P_ARGS); end
				16'h0114: begin sn <= 1; fetch(P_SEC_HDR); end
				default:  p_state <= P_SKIP;
			endcase
		end
	end
	P_SKIP: if (chunk_left) fetch(P_SKIP); else p_state <= P_CHUNK;

	// ---- &0100 / &0104 data
	P_DATA: if (!chunk_left) p_state <= P_CHUNK; else fetch(P_PACK);
	P_PACK: begin
		{nbits, bits} <= packet(fbyte, fmt_bits, fmt_parity, fmt_stop);
		p_state <= P_BITS;
	end
	P_BITS: if (nbits == 0) begin
		if (fmt_extra) wave(W_CYC, 1'b1, 32'd1, P_DATA);
		else p_state <= P_DATA;
	end else begin
		bits <= bits >> 1; nbits <= nbits - 1'd1;
		if (bits[0]) wave(W_CYC, 1'b1, slow_baud ? 32'd8 : 32'd2, P_BITS);   // 1: two fast cycles
		else         wave(W_CYC, 1'b0, slow_baud ? 32'd4 : 32'd1, P_BITS);   // 0: one slow cycle
	end
	P_D104_HDR: begin   // data bits, parity, stop bits (negative: + one short wave)
		case (sn)
			1: fmt_bits <= fbyte;
			2: fmt_parity <= fbyte;
			default: begin
				fmt_stop  <= fbyte[7] ? 2'(-fbyte) : fbyte[1:0];
				fmt_extra <= fbyte[7];
			end
		endcase
		sn <= sn + 1'd1;
		if (sn == 3) p_state <= P_DATA; else fetch(P_D104_HDR);
	end

	// ---- chunks with a 2- or 4-byte argument
	P_ARGS: begin
		args <= args_n;
		if (sn != nargs) begin sn <= sn + 1'd1; fetch(P_ARGS); end
		else case (chunk_id)
			// after a 2-byte argument it sits in args_n[31:16]
			16'h0110: wave(W_CYC, 1'b1, {16'd0, args_n[31:16]}, P_SKIP);
			16'h0112: wave(W_GAP, 1'b0, {15'd0, args_n[31:16], 1'b0}, P_SKIP);           // n/(2f) s = 2n quanta
			16'h0117: begin slow_baud <= (args_n[31:16] == 16'd300); p_state <= P_SKIP; end
			16'h0113: begin base_freq <= float_mul(args_n, 18'd1); p_state <= P_SKIP; end
			16'h0116: wave(W_GAP, 1'b0, float_mul(args_n, {base_freq, 2'b00}), P_SKIP); // seconds x 4f
			default: begin   // &0111: before cycles, &AA, after cycles
				bits <= {1'b1, 8'hAA, 1'b0}; nbits <= 10;
				wave(W_CYC, 1'b1, {16'd0, args_n[15:0]}, P_111_BITS);
			end
		endcase
	end
	P_111_BITS: if (nbits == 0) wave(W_CYC, 1'b1, {16'd0, args[31:16]}, P_SKIP);
	            else begin
		bits <= bits >> 1; nbits <= nbits - 1'd1;
		if (bits[0]) wave(W_CYC, 1'b1, 32'd2, P_111_BITS);
		else         wave(W_CYC, 1'b0, 32'd1, P_111_BITS);
	end

	// ---- &0114 security cycles: 24-bit count, 'P'/'W' first, 'P'/'W' last,
	// then the cycles, MSB first: 1 = fast cycle, 0 = slow cycle
	P_SEC_HDR: begin
		case (sn)
			1: sec_n[7:0]   <= fbyte;
			2: sec_n[15:8]  <= fbyte;
			3: sec_n[23:16] <= fbyte;
			4: sec_first    <= fbyte;
			default: sec_last <= fbyte;
		endcase
		sn <= sn + 1'd1;
		if (sn == 5) begin sec_bit <= 0; sec_loaded <= 0; sec_first_pending <= 1; p_state <= P_SEC; end
		else fetch(P_SEC_HDR);
	end
	P_SEC: begin
		if (sec_n == 0) p_state <= P_SKIP;
		else if (!sec_loaded) begin sec_loaded <= 1; fetch(P_SEC); end
		else begin
			sec_bit <= sec_bit + 1'd1;
			if (sec_bit == 7) sec_loaded <= 0;
			sec_n <= sec_n - 1'd1;
			sec_first_pending <= 0;
			if (sec_first_pending && sec_first == "P") wave(W_HIGH, fbyte[7 - sec_bit], 32'd1, P_SEC);
			else if (sec_n == 1 && sec_last == "P")    wave(W_LOW,  fbyte[7 - sec_bit], 32'd1, P_SEC);
			else                                       wave(W_CYC,  fbyte[7 - sec_bit], 32'd1, P_SEC);
		end
	end

	// ---- raw bit stream: 8 bits per byte, MSB first
	P_RAW: fetch(P_RAW_LOAD);
	P_RAW_LOAD: begin
		bits <= {3'b000, fbyte[0], fbyte[1], fbyte[2], fbyte[3], fbyte[4], fbyte[5], fbyte[6], fbyte[7]};
		nbits <= 8;
		p_state <= P_RAW_BITS;
	end
	P_RAW_BITS: if (nbits == 0) p_state <= P_RAW;
	            else begin
		bits <= bits >> 1; nbits <= nbits - 1'd1;
		if (bits[0]) wave(W_CYC, 1'b1, 32'd2, P_RAW_BITS);
		else         wave(W_CYC, 1'b0, 32'd1, P_RAW_BITS);
	end

	default: p_state <= P_END;
	endcase

	if (reset || rewind) begin
		p_state <= raw ? P_RAW : P_CHUNK; mem_addr <= start_addr; at_end <= 0;
		base_freq <= 1200; slow_baud <= 0; w_go <= 0;
	end
end

endmodule
