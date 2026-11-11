//============================================================================
//  gzip / DEFLATE decompressor (RFC 1952 / RFC 1951) for loading .uef files.
//
//  Structured like zlib's contrib/puff/puff.c: canonical Huffman codes are
//  decoded one bit at a time from per-length counts and a sorted symbol
//  list, which keeps the logic small. Speed is a few clocks per bit, plenty
//  for tape images (a 500 KB UEF in well under a second at 16 MHz).
//
//  Input: a byte stream, requested one byte at a time (in_req -> in_valid).
//  After the end of the compressed data the source may return anything.
//  Output: a byte stream (out_valid / out_ready). A 32 KB window in block RAM
//  holds the history for back-references.
//
//  start begins a new gzip member; busy stays high until done or error.
//  The gzip trailer (CRC32, ISIZE) is read and ISIZE is checked against the
//  output length.
//============================================================================

module inflate
(
	input             clk,
	input             reset,

	input             start,
	output reg        busy = 0,
	output reg        done = 0,      // pulses at the end of the member
	output reg        error = 0,     // sticky until the next start
	output reg  [3:0] error_code = 0,

	output reg        in_req = 0,    // one-clock request for the next input byte
	input             in_valid,      // the byte, any number of clocks later
	input       [7:0] in_data,

	output reg        out_valid = 0,
	input             out_ready,
	output reg  [7:0] out_data = 0,
	output reg [23:0] out_count = 0  // bytes written so far
);

// error codes
localparam E_MAGIC = 4'd1, E_METHOD = 4'd2, E_BTYPE = 4'd3, E_STORED = 4'd4,
           E_CODES = 4'd5, E_SYMBOL = 4'd6, E_DIST = 4'd7, E_SIZE = 4'd8;

// ---------------------------------------------------------------- memories
// lengths: 0-287 lit/len code lengths, 288-319 dist, 320-338 code-length codes
// symbols: the same layout, sorted by code
reg  [3:0] len_mem[0:511];
reg  [8:0] sym_mem[0:511];
reg  [7:0] win_mem[0:32767];

reg  [8:0] len_waddr, len_raddr;  reg [3:0] len_wdata; reg len_we = 0;  reg [3:0] len_q;
reg  [8:0] sym_waddr, sym_raddr;  reg [8:0] sym_wdata; reg sym_we = 0;  reg [8:0] sym_q;
reg [14:0] win_waddr, win_raddr;  reg [7:0] win_wdata; reg win_we = 0;  reg [7:0] win_q;

always @(posedge clk) begin
	if (len_we) len_mem[len_waddr] <= len_wdata;
	len_q <= len_mem[len_raddr];
	if (sym_we) sym_mem[sym_waddr] <= sym_wdata;
	sym_q <= sym_mem[sym_raddr];
	if (win_we) win_mem[win_waddr] <= win_wdata;
	win_q <= win_mem[win_raddr];
end

// ------------------------------------------------------------ static tables
function [8:0] len_base(input [4:0] i);   // length codes 257..285
	case (i)
		 0: len_base = 3;   1: len_base = 4;   2: len_base = 5;   3: len_base = 6;
		 4: len_base = 7;   5: len_base = 8;   6: len_base = 9;   7: len_base = 10;
		 8: len_base = 11;  9: len_base = 13; 10: len_base = 15; 11: len_base = 17;
		12: len_base = 19; 13: len_base = 23; 14: len_base = 27; 15: len_base = 31;
		16: len_base = 35; 17: len_base = 43; 18: len_base = 51; 19: len_base = 59;
		20: len_base = 67; 21: len_base = 83; 22: len_base = 99; 23: len_base = 115;
		24: len_base = 131; 25: len_base = 163; 26: len_base = 195; 27: len_base = 227;
		default: len_base = 258;
	endcase
endfunction
function [2:0] len_extra(input [4:0] i);
	len_extra = (i < 8 || i == 28) ? 3'd0 : 3'((i - 4) >> 2);
endfunction
function [14:0] dist_base(input [4:0] i);
	case (i)
		 0: dist_base = 1;     1: dist_base = 2;     2: dist_base = 3;     3: dist_base = 4;
		 4: dist_base = 5;     5: dist_base = 7;     6: dist_base = 9;     7: dist_base = 13;
		 8: dist_base = 17;    9: dist_base = 25;   10: dist_base = 33;   11: dist_base = 49;
		12: dist_base = 65;   13: dist_base = 97;   14: dist_base = 129;  15: dist_base = 193;
		16: dist_base = 257;  17: dist_base = 385;  18: dist_base = 513;  19: dist_base = 769;
		20: dist_base = 1025; 21: dist_base = 1537; 22: dist_base = 2049; 23: dist_base = 3073;
		24: dist_base = 4097; 25: dist_base = 6145; 26: dist_base = 8193; 27: dist_base = 12289;
		28: dist_base = 16385; default: dist_base = 24577;
	endcase
endfunction
function [3:0] dist_extra(input [4:0] i);
	dist_extra = (i < 4) ? 4'd0 : 4'((i - 2) >> 1);
endfunction
function [8:0] clen_order(input [4:0] i);   // code-length code order
	case (i)
		 0: clen_order = 16;  1: clen_order = 17;  2: clen_order = 18;  3: clen_order = 0;
		 4: clen_order = 8;   5: clen_order = 7;   6: clen_order = 9;   7: clen_order = 6;
		 8: clen_order = 10;  9: clen_order = 5;  10: clen_order = 11; 11: clen_order = 4;
		12: clen_order = 12; 13: clen_order = 3;  14: clen_order = 13; 15: clen_order = 2;
		16: clen_order = 14; 17: clen_order = 1;  default: clen_order = 15;
	endcase
endfunction

// ------------------------------------------------------------------- state
localparam [5:0]
	S_IDLE = 0, S_HDR = 1, S_XLEN = 2, S_XSKIP = 3, S_NAME = 4, S_COMMENT = 5, S_HCRC = 6,
	S_BLOCK = 7, S_STORED_LEN = 8, S_STORED_COPY = 9,
	S_FIXED = 10, S_DYN_HDR = 11, S_DYN_CLEN = 12, S_DYN_CLEN_ZERO = 13,
	S_DYN_LENS = 14, S_DYN_REPEAT = 15,
	S_BUILD = 16, S_BUILD_CNT = 17, S_BUILD_OFFS = 18, S_BUILD_SYM = 19, S_BUILD_NEXT = 20,
	S_DECODE = 21, S_DECODE_SYM = 22,
	S_LIT = 23, S_LEN_EXTRA = 24, S_DIST_SYM = 25, S_DIST_EXTRA = 26,
	S_COPY_RD = 27, S_COPY_WAIT = 28, S_COPY_WR = 29, S_OUT = 30,
	S_TRAILER = 31, S_DONE = 32, S_ERROR = 33, S_SYM_WAIT = 34, S_SYM_GET = 35,
	S_STORED_NLEN = 36;

reg  [5:0] state = S_IDLE, ret_state;

// bit buffer, LSB first; kept topped up from the input stream
reg [31:0] bitbuf;
reg  [5:0] bitcnt;
reg        fetching;

// header
reg  [3:0] hdr_n;
reg  [7:0] flg;
reg [15:0] xlen;
reg        last_block;

// dynamic header
reg  [8:0] nlen;      // 257..286
reg  [5:0] ndist;     // 1..30
reg  [4:0] ncode;     // 4..19
reg  [8:0] idx;       // running index
reg  [3:0] prev_len;
reg  [7:0] rep_n;
reg  [3:0] rep_val;

// table build: which table (0 lit/len, 1 dist, 2 code lengths)
reg  [1:0] tbl;
reg  [8:0] b_n, b_sym;
reg  [8:0] b_lbase, b_sbase;
reg  [8:0] cnt [0:2][0:15];
reg  [8:0] offs[0:15];
reg  [4:0] b_l;
reg        b_rd1, b_rd2;   // len_mem reads in flight (2-clock latency)
reg  [8:0] b_sym1, b_sym2; // their symbol numbers

// decoder
reg [15:0] code, first, index;
reg  [4:0] dlen;
reg  [1:0] dec_tbl;
reg  [8:0] symbol;

// match
reg  [8:0] mlen;
reg [14:0] mdist;
reg  [4:0] mcode;

// stored
reg [15:0] slen;

// trailer
reg [31:0] isize;
reg  [3:0] tr_n;

reg [14:0] wptr;

wire [8:0] dec_base = (dec_tbl == 2'd0) ? 9'd0 : (dec_tbl == 2'd1) ? 9'd288 : 9'd320;

integer k;

always @(posedge clk) begin : main
	reg [5:0] use_bits;     // bits consumed this clock
	reg [31:0] buf_n;
	reg  [5:0] cnt_n;
	reg [15:0] c, f, ix, cn;

	use_bits = 0;
	in_req  <= 0;
	len_we  <= 0;
	sym_we  <= 0;
	win_we  <= 0;
	done    <= 0;
	if (out_valid && out_ready) out_valid <= 0;

	case (state)
	S_IDLE: ;

	// ---------------------------------------------------------- gzip header
	S_HDR: if (bitcnt >= 8) begin
		use_bits = 8;
		hdr_n <= hdr_n + 1'd1;
		case (hdr_n)
			0: if (bitbuf[7:0] != 8'h1F) begin error_code <= E_MAGIC;  state <= S_ERROR; end
			1: if (bitbuf[7:0] != 8'h8B) begin error_code <= E_MAGIC;  state <= S_ERROR; end
			2: if (bitbuf[7:0] != 8'h08) begin error_code <= E_METHOD; state <= S_ERROR; end
			3: flg <= bitbuf[7:0];
			9: state <= flg[2] ? S_XLEN : flg[3] ? S_NAME : flg[4] ? S_COMMENT : flg[1] ? S_HCRC : S_BLOCK;
			default: ;
		endcase
	end
	S_XLEN: if (bitcnt >= 16) begin
		use_bits = 16; xlen <= bitbuf[15:0]; state <= S_XSKIP;
	end
	S_XSKIP: if (!xlen) state <= flg[3] ? S_NAME : flg[4] ? S_COMMENT : flg[1] ? S_HCRC : S_BLOCK;
	         else if (bitcnt >= 8) begin use_bits = 8; xlen <= xlen - 1'd1; end
	S_NAME: if (bitcnt >= 8) begin
		use_bits = 8;
		if (!bitbuf[7:0]) state <= flg[4] ? S_COMMENT : flg[1] ? S_HCRC : S_BLOCK;
	end
	S_COMMENT: if (bitcnt >= 8) begin
		use_bits = 8;
		if (!bitbuf[7:0]) state <= flg[1] ? S_HCRC : S_BLOCK;
	end
	S_HCRC: if (bitcnt >= 16) begin use_bits = 16; state <= S_BLOCK; end

	// ---------------------------------------------------------- block header
	S_BLOCK: if (bitcnt >= 3) begin
		use_bits = 3;
		last_block <= bitbuf[0];
		case (bitbuf[2:1])
			2'd0: state <= S_STORED_LEN;
			2'd1: state <= S_FIXED;
			2'd2: state <= S_DYN_HDR;
			2'd3: begin error_code <= E_BTYPE; state <= S_ERROR; end
		endcase
		idx <= 0;
	end

	// ---------------------------------------------------------- stored
	// drop to a byte boundary (bits are added a byte at a time), then
	// LEN, NLEN, LEN bytes
	S_STORED_LEN: if (bitcnt[2:0] != 0) use_bits = {3'd0, bitcnt[2:0]};   // to a byte boundary
	              else if (bitcnt >= 16) begin use_bits = 16; slen <= bitbuf[15:0]; state <= S_STORED_NLEN; end
	S_STORED_NLEN: if (bitcnt >= 16) begin
		use_bits = 16;
		if (bitbuf[15:0] != ~slen) begin error_code <= E_STORED; state <= S_ERROR; end
		else state <= S_STORED_COPY;
	end
	S_STORED_COPY: if (!slen) state <= last_block ? S_TRAILER : S_BLOCK;
	               else if (bitcnt >= 8 && !out_valid) begin
		use_bits = 8;
		slen <= slen - 1'd1;
		out_data <= bitbuf[7:0]; out_valid <= 1; out_count <= out_count + 1'd1;
		win_waddr <= wptr; win_wdata <= bitbuf[7:0]; win_we <= 1; wptr <= wptr + 1'd1;
	end

	// ---------------------------------------------------------- fixed codes
	// lengths: 0-143 8, 144-255 9, 256-279 7, 280-287 8; 30 dist codes of 5
	S_FIXED: begin
		len_we <= 1;
		len_waddr <= idx;
		len_wdata <= (idx < 144) ? 4'd8 : (idx < 256) ? 4'd9 : (idx < 280) ? 4'd7 : (idx < 288) ? 4'd8 : 4'd5;
		idx <= idx + 1'd1;
		if (idx == 9'd317) begin
			nlen <= 288; ndist <= 30;
			tbl <= 0; state <= S_BUILD;
		end
	end

	// ---------------------------------------------------------- dynamic codes
	S_DYN_HDR: if (bitcnt >= 14) begin
		use_bits = 14;
		nlen  <= 9'd257 + bitbuf[4:0];
		ndist <= 6'd1 + bitbuf[9:5];
		ncode <= 5'd4 + bitbuf[13:10];
		idx <= 0;
		state <= S_DYN_CLEN;
	end
	S_DYN_CLEN: if (idx == ncode) begin idx <= ncode; state <= S_DYN_CLEN_ZERO; end
	            else if (bitcnt >= 3) begin
		use_bits = 3;
		len_we <= 1; len_waddr <= 9'd320 + clen_order(idx[4:0]); len_wdata <= {1'b0, bitbuf[2:0]};
		idx <= idx + 1'd1;
	end
	S_DYN_CLEN_ZERO: if (idx == 19) begin
		tbl <= 2; state <= S_BUILD;
	end else begin
		len_we <= 1; len_waddr <= 9'd320 + clen_order(idx[4:0]); len_wdata <= 0;
		idx <= idx + 1'd1;
	end
	// after the code-length table is built: read nlen + ndist lengths
	S_DYN_LENS: if (idx == nlen + ndist) begin
		tbl <= 0; state <= S_BUILD;
	end else begin
		dec_tbl <= 2; ret_state <= S_DYN_REPEAT;
		code <= 0; first <= 0; index <= 0; dlen <= 1;
		state <= S_DECODE;
	end
	S_DYN_REPEAT: begin
		// symbol 0-15: a length; 16: repeat previous 3-6; 17: zeros 3-10; 18: zeros 11-138
		if (rep_n != 0) begin
			len_we <= 1;
			len_waddr <= (idx < nlen) ? idx : 9'd288 + (idx - nlen);
			len_wdata <= rep_val;
			idx <= idx + 1'd1;
			rep_n <= rep_n - 1'd1;
			if (rep_n == 1) state <= S_DYN_LENS;
			if (idx + 1'd1 > nlen + ndist) begin error_code <= E_CODES; state <= S_ERROR; end
		end
		else if (symbol < 16) begin
			len_we <= 1;
			len_waddr <= (idx < nlen) ? idx : 9'd288 + (idx - nlen);
			len_wdata <= symbol[3:0];
			prev_len <= symbol[3:0];
			idx <= idx + 1'd1;
			state <= S_DYN_LENS;
		end
		else if (symbol == 16 && bitcnt >= 2) begin
			use_bits = 2;
			if (idx == 0) begin error_code <= E_CODES; state <= S_ERROR; end
			rep_val <= prev_len; rep_n <= 8'd3 + bitbuf[1:0];
		end
		else if (symbol == 17 && bitcnt >= 3) begin
			use_bits = 3;
			rep_val <= 0; prev_len <= 0; rep_n <= 8'd3 + bitbuf[2:0];
		end
		else if (symbol == 18 && bitcnt >= 7) begin
			use_bits = 7;
			rep_val <= 0; prev_len <= 0; rep_n <= 8'd11 + bitbuf[6:0];
		end
	end

	// ---------------------------------------------------------- table build
	// puff.c construct(): count codes per length, offsets, sorted symbols
	S_BUILD: begin
		b_n     <= (tbl == 0) ? nlen : (tbl == 1) ? {3'd0, ndist} : 9'd19;
		b_lbase <= (tbl == 0) ? 9'd0 : (tbl == 1) ? 9'd288 : 9'd320;
		b_sbase <= (tbl == 0) ? 9'd0 : (tbl == 1) ? 9'd288 : 9'd320;
		for (k = 0; k < 16; k = k + 1) cnt[tbl][k] <= 0;
		b_sym <= 0; b_rd1 <= 0; b_rd2 <= 0;
		state <= S_BUILD_CNT;
	end
	S_BUILD_CNT: begin
		// a read issued now returns len_q two clocks later
		b_rd2 <= b_rd1;
		if (b_rd2) cnt[tbl][len_q] <= cnt[tbl][len_q] + 1'd1;
		if (b_sym < b_n) begin
			len_raddr <= b_lbase + b_sym; b_sym <= b_sym + 1'd1; b_rd1 <= 1;
		end else begin
			b_rd1 <= 0;
			if (!b_rd1 && !b_rd2) begin b_l <= 1; offs[1] <= 0; state <= S_BUILD_OFFS; end
		end
	end
	S_BUILD_OFFS: begin
		if (b_l == 15) begin
			b_sym <= 0; b_rd1 <= 0; b_rd2 <= 0; state <= S_BUILD_SYM;
		end else begin
			offs[b_l + 1] <= offs[b_l] + cnt[tbl][b_l];
			b_l <= b_l + 1'd1;
		end
	end
	S_BUILD_SYM: begin
		b_rd2 <= b_rd1; b_sym2 <= b_sym1;
		if (b_rd2 && len_q != 0) begin
			sym_we <= 1; sym_waddr <= b_sbase + offs[len_q]; sym_wdata <= b_sym2;
			offs[len_q] <= offs[len_q] + 1'd1;
		end
		if (b_sym < b_n) begin
			len_raddr <= b_lbase + b_sym; b_sym1 <= b_sym; b_sym <= b_sym + 1'd1; b_rd1 <= 1;
		end else begin
			b_rd1 <= 0;
			if (!b_rd1 && !b_rd2) state <= S_BUILD_NEXT;
		end
	end
	S_BUILD_NEXT: begin
		if (tbl == 2) begin idx <= 0; state <= S_DYN_LENS; end
		else if (tbl == 0) begin tbl <= 1; state <= S_BUILD; end
		else state <= S_DECODE_SYM;   // both tables ready: decode the block
	end

	// ---------------------------------------------------------- decode
	// puff.c decode(): one bit per step; ret_state gets `symbol`
	S_DECODE: if (bitcnt >= 1) begin
		use_bits = 1;
		c  = code | bitbuf[0];
		cn = {7'd0, cnt[dec_tbl][dlen]};
		if (c < first + cn) begin
			sym_raddr <= dec_base + index + (c - first);
			state <= S_SYM_WAIT;
		end else begin
			index <= index + cn;
			first <= (first + cn) << 1;
			code  <= c << 1;
			dlen  <= dlen + 1'd1;
			if (dlen == 15) begin error_code <= E_SYMBOL; state <= S_ERROR; end
		end
	end
	S_SYM_WAIT: state <= S_SYM_GET;                       // sym_q valid next clock
	S_SYM_GET: begin symbol <= sym_q; state <= ret_state; end

	// next lit/len symbol of a block
	S_DECODE_SYM: begin
		dec_tbl <= 0; ret_state <= S_LIT;
		code <= 0; first <= 0; index <= 0; dlen <= 1;
		state <= S_DECODE;
	end
	S_LIT: begin
		if (symbol < 256) begin
			if (!out_valid) begin
				out_data <= symbol[7:0]; out_valid <= 1; out_count <= out_count + 1'd1;
				win_waddr <= wptr; win_wdata <= symbol[7:0]; win_we <= 1; wptr <= wptr + 1'd1;
				state <= S_DECODE_SYM;
			end
		end
		else if (symbol == 256) state <= last_block ? S_TRAILER : S_BLOCK;
		else if (symbol > 285) begin error_code <= E_SYMBOL; state <= S_ERROR; end
		else begin mcode <= symbol - 9'd257; state <= S_LEN_EXTRA; end
	end
	S_LEN_EXTRA: if (bitcnt >= len_extra(mcode)) begin
		use_bits = len_extra(mcode);
		mlen <= len_base(mcode) + (bitbuf[4:0] & ((5'd1 << len_extra(mcode)) - 1'd1));
		dec_tbl <= 1; ret_state <= S_DIST_SYM;
		code <= 0; first <= 0; index <= 0; dlen <= 1;
		state <= S_DECODE;
	end
	S_DIST_SYM: begin
		if (symbol > 29) begin error_code <= E_DIST; state <= S_ERROR; end
		else begin mcode <= symbol[4:0]; state <= S_DIST_EXTRA; end
	end
	S_DIST_EXTRA: if (bitcnt >= dist_extra(mcode)) begin
		use_bits = dist_extra(mcode);
		mdist <= dist_base(mcode) + (bitbuf[12:0] & ((13'd1 << dist_extra(mcode)) - 1'd1));
		state <= S_COPY_RD;
	end
	S_COPY_RD: if (!out_valid) begin
		if (!mlen) state <= S_DECODE_SYM;
		else begin
			win_raddr <= wptr - mdist;
			state <= S_COPY_WAIT;
		end
	end
	S_COPY_WAIT: state <= S_COPY_WR;
	S_COPY_WR: begin
		out_data <= win_q; out_valid <= 1; out_count <= out_count + 1'd1;
		win_waddr <= wptr; win_wdata <= win_q; win_we <= 1; wptr <= wptr + 1'd1;
		mlen <= mlen - 1'd1;
		state <= S_COPY_RD;
	end

	// ---------------------------------------------------------- trailer
	S_TRAILER: if (bitcnt[2:0] != 0) use_bits = {3'd0, bitcnt[2:0]};
	           else if (bitcnt >= 8) begin
		use_bits = 8;
		tr_n <= tr_n + 1'd1;
		if (tr_n >= 4) isize <= {bitbuf[7:0], isize[31:8]};
		if (tr_n == 7) state <= S_DONE;
	end
	S_DONE: if (!out_valid) begin
		if (isize[23:0] != out_count) begin error_code <= E_SIZE; state <= S_ERROR; end
		else begin done <= 1; busy <= 0; state <= S_IDLE; end
	end
	S_ERROR: begin error <= 1; busy <= 0; state <= S_IDLE; end

	default: state <= S_ERROR;
	endcase

	// ---- bit buffer: consume, then top up a byte at a time
	buf_n = bitbuf >> use_bits;
	cnt_n = bitcnt - use_bits;
	if (in_valid && fetching) begin
		buf_n = buf_n | ({24'd0, in_data} << cnt_n);
		cnt_n = cnt_n + 6'd8;
		fetching <= 0;
	end
	else if (!fetching && cnt_n <= 6'd16 && busy && state != S_IDLE) begin
		in_req <= 1;
		fetching <= 1;
	end
	bitbuf <= buf_n;
	bitcnt <= cnt_n;

	if (start) begin
		state <= S_HDR; busy <= 1; error <= 0; error_code <= 0;
		bitbuf <= 0; bitcnt <= 0; fetching <= 0; in_req <= 0;
		hdr_n <= 0; tr_n <= 0; isize <= 0; out_count <= 0; wptr <= 0; out_valid <= 0;
	end
	if (reset) begin
		state <= S_IDLE; busy <= 0; error <= 0; fetching <= 0; out_valid <= 0;
	end
end

endmodule
