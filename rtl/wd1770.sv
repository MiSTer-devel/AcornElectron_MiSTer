//============================================================================
//  WD1770 floppy disk controller, sector level
//
//  From the Geneve 9640 core (alanswx/Geneve9640_MiSTer rtl/wd1770.sv, b14a299).
//  Electron copy: the image layouts are ADFS's (rtl/plus3.sv): sectors 0..15
//  of 256 bytes; one side = cylinder by cylinder (.adf, ADFS S/M); two sides
//  = interleaved by track, cylinder 0 side 0, cylinder 0 side 1, ... (.adl,
//  ADFS L). The sector buffer is a true dual-port block RAM (registered
//  reads: buf_dout follows buf_addr one clock later). The rest is the
//  Geneve controller unchanged.
//
//  Works on sector-dump images (256-byte sectors). The controller keeps a head
//  position per drive and answers type I-IV commands; sector data goes
//  through a 256-byte buffer filled or drained by the image interface:
//
//    img_rd / img_wr  one-clk request for logical sector img_lsn of drive
//                     img_drive; the outside fills the buffer (buf_wr) or
//                     reads it (buf_addr / buf_dout), then pulses img_ack.
//
//  Single density (dden_n = 1) finds sectors only on 9-sector images,
//  double density only on 16/18-sector images, as on the real medium.
//  Write track (format) parses the ID fields of the track; from then on the
//  drive uses the formatted geometry (sectors per track, density, tracks,
//  sides) instead of the mounted one, until the image changes. The image
//  keeps its old data in the formatted sectors.
//  Head stepping and the sector search take a short fixed time; data bytes
//  are offered at once (DRQ) and never get lost.
//============================================================================

module wd1770 #(
    parameter int CLK_HZ  = 21477272,
    parameter int STEP_US = 200,       // per head step (real drives: 6-20 ms)
    parameter int FIND_US = 300        // to find a sector ID
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        rd,             // read strobe (register addr)
    input  logic        wr,
    input  logic [1:0]  addr,           // 0 status/command, 1 track, 2 sector, 3 data
    input  logic [7:0]  din,
    output logic [7:0]  dout,
    output logic        intrq,
    output logic        drq,

    input  logic [1:0]  drive,          // 1, 2 = selected drive, 0 = none
    input  logic        side,
    input  logic        dden_n,         // 1 = single density (FM)
    input  logic [1:0]  ready,          // image present per drive
    input  logic [1:0]  wprot,          // write protected per drive
    input  logic [1:0][7:0] spt,        // sectors per track
    input  logic [1:0][7:0] tracks,     // tracks per side in the image
    input  logic [1:0][1:0] sides,      // sides in the image

    output logic        img_rd,
    output logic        img_wr,
    output logic [15:0] img_lsn,
    output logic        img_drive,      // 0 = DSK1, 1 = DSK2
    input  logic        img_ack,
    input  logic        buf_wr,
    input  logic [7:0]  buf_addr,
    input  logic [7:0]  buf_din,
    output wire  [7:0]  buf_dout        // sbuf[buf_addr], one clock later
);

localparam int US = CLK_HZ / 1000000;

typedef enum logic [3:0] {
    S_IDLE, S_STEP, S_FIND, S_RDIMG, S_RDDATA, S_WRDATA, S_WRIMG, S_RDADDR, S_WRTRK, S_RDTRK, S_DONE
} state_t;

state_t      st;
logic [7:0]  status, track_r, sector_r, data_r, cmd;
logic [7:0]  headpos [0:1];
logic        dirn;               // 1 = step in
// sector buffer: rtl/dpram.sv, port A the image side, port B the data register
logic [7:0]  sbuf_q;
logic [8:0]  bcnt_d;               // bcnt one clock ago: sbuf_q = sbuf[bcnt] when equal
logic        sbuf_we;
logic [8:0]  bcnt;
logic [31:0] timer;
logic        motor_on;
logic [31:0] motor_timer;
logic        type1;
logic [31:0] index_ctr;
logic [7:0]  ida [0:5];
logic [7:0]  rdaddr_sec;
logic [12:0] trkcnt;
logic        stepped;

// geometry from formatting (write track), per drive
logic [1:0]       fmt_on;
logic [1:0][7:0]  fmt_spt, fmt_tracks;
logic [1:0][1:0]  fmt_sides;
logic [1:0]       fmt_dd;
logic [1:0][7:0]  g_spt_in, g_trk_in;
logic [1:0][1:0]  g_sides_in;
logic [1:0]       g_ready_in;
// track parser
logic [7:0]  wt_prev;
logic [2:0]  wt_id;              // ID bytes still to come (4..1), 0 = scanning
logic [1:0]  wt_idsize;
logic [10:0] wt_skip;            // data field bytes still to skip
logic        wt_wantdata;
logic [7:0]  wt_count;

wire        dsel   = drive != 2'd0;
wire        dn     = (drive == 2'd2);
wire [7:0]  hp     = headpos[dn];
wire [7:0]  d_spt  = fmt_on[dn] ? fmt_spt[dn] : spt[dn];
wire [7:0]  d_trk  = fmt_on[dn] ? fmt_tracks[dn] : tracks[dn];
wire [1:0]  d_sides = fmt_on[dn] ? fmt_sides[dn] : sides[dn];
wire        dens_ok = fmt_on[dn] ? (fmt_dd[dn] == !dden_n) : dden_n ? (d_spt == 8'd9) : (d_spt >= 8'd16);
wire        disk   = dsel && ready[dn];
wire        index  = disk && motor_on && (index_ctr < 32'(CLK_HZ / 250));   // 4 ms of 200 ms

assign sbuf_we = (st == S_WRDATA) && !drq && !(wr || rd);
dpram #(.AW(8)) sbuf
(
    .clk(clk),
    .addr_a(buf_addr), .din_a(buf_din), .we_a(buf_wr), .q_a(buf_dout),          // image side
    .addr_b(bcnt[7:0]), .din_b(data_r), .we_b(sbuf_we), .q_b(sbuf_q)            // data register
);
always_ff @(posedge clk) bcnt_d <= bcnt;
assign img_drive = dn;

always_comb begin
    case (addr)
    2'd0: dout = type1 ? {motor_on, (disk && wprot[dn]), 1'b1, status[4:3], (hp == 8'd0), index, status[0]}
                       : {motor_on, status[6:0]};
    2'd1: dout = track_r;
    2'd2: dout = sector_r;
    default: dout = data_r;
    endcase
end

// ADFS images: single-sided cylinder by cylinder; double-sided interleaved
function automatic logic [15:0] lsn_of(input logic [7:0] cyl, input logic s, input logic [7:0] sec,
                                       input logic [7:0] spt_d, input logic [1:0] sides_d);
    if (sides_d == 2'd2) return 16'((2 * cyl + s) * spt_d + sec);
    else                 return 16'(cyl * spt_d + sec);
endfunction

// Sector present on the medium under the head?
function automatic logic sector_ok(input logic [7:0] sec);
    return disk && dens_ok && (track_r == hp) && (hp < d_trk) && (sec < d_spt)
        && (!side || d_sides == 2'd2);
endfunction

`ifdef WD_DEBUG
always_ff @(posedge clk) begin
    if (wr && addr == 2'd0) $display("WD cmd %02x drive %0d side %0d dden_n %0d trk %0d sec %0d hp %0d ready %b spt %0d", din, drive, side, dden_n, track_r, sector_r, hp, ready, d_spt);
    if (st == S_DONE) $display("WD done status %02x", status);
end
`endif

always_ff @(posedge clk) begin
    img_rd <= 1'b0;
    img_wr <= 1'b0;

    if (reset) begin
        st <= S_IDLE;
        status <= 8'd0;
        track_r <= 8'd0;
        sector_r <= 8'd1;
        data_r <= 8'd0;
        intrq <= 1'b0;
        drq <= 1'b0;
        type1 <= 1'b1;
        motor_on <= 1'b0;
        headpos[0] <= 8'd0;
        headpos[1] <= 8'd0;
        dirn <= 1'b1;
        rdaddr_sec <= 8'd0;
        index_ctr <= 32'd0;
        stepped <= 1'b0;
        motor_timer <= 32'd0;
        timer <= 32'd0;
        fmt_on <= 2'b00;
    end else begin
        // a new image (geometry or presence changes) drops the formatted geometry
        g_spt_in <= spt;
        g_trk_in <= tracks;
        g_sides_in <= sides;
        g_ready_in <= ready;
        for (int i = 0; i < 2; i++)
            if (g_spt_in[i] != spt[i] || g_trk_in[i] != tracks[i] || g_sides_in[i] != sides[i] || g_ready_in[i] != ready[i])
                fmt_on[i] <= 1'b0;

        index_ctr <= (index_ctr >= 32'(CLK_HZ / 5 - 1)) ? 32'd0 : index_ctr + 32'd1;
        if (motor_timer != 32'd0) motor_timer <= motor_timer - 32'd1;
        else if (st == S_IDLE) motor_on <= 1'b0;


        // Register access
        if (rd && addr == 2'd0) intrq <= 1'b0;
        if (rd && addr == 2'd3) drq <= 1'b0;
        if (wr) begin
            case (addr)
            2'd0: begin
                if (din[7:4] == 4'hd) begin
                    // Force interrupt
                    st <= S_IDLE;
                    status[0] <= 1'b0;
                    drq <= 1'b0;
                    if (st == S_IDLE) type1 <= 1'b1;
                    intrq <= (din[3:0] != 4'd0);
                end else if (st == S_IDLE) begin
                    cmd <= din;
                    intrq <= 1'b0;
                    status <= 8'h01;           // busy
                    motor_on <= 1'b1;
                    motor_timer <= 32'(CLK_HZ * 2);
                    timer <= 32'd0;
                    if (!din[7]) begin
                        type1 <= 1'b1;
                        st <= S_STEP;
                    end else begin
                        type1 <= 1'b0;
                        case (din[7:5])
                        3'b100: st <= S_FIND;                         // read sector
                        3'b101: st <= S_FIND;                         // write sector
                        default: case (din[7:4])
                            4'hc: st <= S_RDADDR;
                            4'he: st <= S_RDTRK;
                            default: st <= S_WRTRK;                   // f
                        endcase
                        endcase
                    end
                end
            end
            2'd1: if (st == S_IDLE) track_r <= din;
            2'd2: if (st == S_IDLE) sector_r <= din;
            default: begin
                data_r <= din;
                drq <= 1'b0;
            end
            endcase
        end

        case (st)
        // Type I: restore, seek, step, step in, step out
        S_STEP: begin
            if (timer != 32'd0) timer <= timer - 32'd1;
            else if (stepped || (cmd[7:5] == 3'b000 && (cmd[4] ? (track_r == data_r) : (hp == 8'd0)))) begin
                if (cmd[7:4] == 4'h0) track_r <= 8'd0;          // restore ends on track 0
                if (cmd[2] && !(disk && dens_ok && ((cmd[7:4] == 4'h0) ? hp == 8'd0 : track_r == hp)))
                    status[4] <= 1'b1;                           // verify: seek error
                stepped <= 1'b0;
                st <= S_DONE;
            end else begin
                logic d;
                if (cmd[7:5] == 3'b000) d = cmd[4] ? (data_r > track_r) : 1'b0;
                else if (cmd[7:5] == 3'b010) d = 1'b1;
                else if (cmd[7:5] == 3'b011) d = 1'b0;
                else d = dirn;
                dirn <= d;
                // seek always updates the track register, step only with u = 1
                if ((cmd[7:4] == 4'h1) || (cmd[7:5] != 3'b000 && cmd[4]))
                    track_r <= d ? track_r + 8'd1 : track_r - 8'd1;
                if (dsel) headpos[dn] <= d ? (hp < 8'd83 ? hp + 8'd1 : hp) : (hp != 8'd0 ? hp - 8'd1 : 8'd0);
                if (cmd[7:5] != 3'b000) stepped <= 1'b1;
                timer <= 32'(STEP_US * US);
            end
        end

        // Type II: find the sector
        S_FIND: begin
            if (timer != 32'(FIND_US * US)) timer <= timer + 32'd1;
            else if (!sector_ok(sector_r)) begin
                status[4] <= 1'b1;              // record not found
                st <= S_DONE;
            end else if (cmd[5]) begin
                if (wprot[dn]) begin
                    status[6] <= 1'b1;
                    st <= S_DONE;
                end else begin
                    bcnt <= 9'd0;
                    drq <= 1'b1;
                    status[1] <= 1'b1;
                    st <= S_WRDATA;
                end
            end else begin
                img_rd <= 1'b1;
                img_lsn <= lsn_of(hp, side, sector_r, d_spt, d_sides);
                st <= S_RDIMG;
            end
        end
        S_RDIMG: if (img_ack) begin
            bcnt <= 9'd0;
            st <= S_RDDATA;
        end
        S_RDDATA: begin
            if (!drq && !(wr || rd) && bcnt_d == bcnt) begin   // sbuf_q is sbuf[bcnt]
                if (bcnt == 9'd256) begin
                    status[1] <= 1'b0;
                    if (cmd[4] && sector_ok(sector_r + 8'd1)) begin
                        sector_r <= sector_r + 8'd1;
                        timer <= 32'd0;
                        st <= S_FIND;
                    end else begin
                        if (cmd[4]) status[4] <= 1'b1;
                        st <= S_DONE;
                    end
                end else begin
                    data_r <= sbuf_q;
                    bcnt <= bcnt + 9'd1;
                    drq <= 1'b1;
                    status[1] <= 1'b1;
                end
            end
        end
        S_WRDATA: begin
            if (!drq && !(wr || rd)) begin
                // sbuf[bcnt] <= data_r: port B (sbuf_we)
                if (bcnt == 9'd255) begin
                    status[1] <= 1'b0;
                    img_wr <= 1'b1;
                    img_lsn <= lsn_of(hp, side, sector_r, d_spt, d_sides);
                    st <= S_WRIMG;
                end else begin
                    bcnt <= bcnt + 9'd1;
                    drq <= 1'b1;
                end
            end
        end
        S_WRIMG: if (img_ack) begin
            if (cmd[4] && sector_ok(sector_r + 8'd1)) begin
                sector_r <= sector_r + 8'd1;
                timer <= 32'd0;
                st <= S_FIND;
            end else begin
                if (cmd[4]) status[4] <= 1'b1;
                st <= S_DONE;
            end
        end

        // Type III
        S_RDADDR: begin
            if (timer != 32'(FIND_US * US)) timer <= timer + 32'd1;
            else if (!(disk && dens_ok && hp < d_trk)) begin
                status[4] <= 1'b1;
                st <= S_DONE;
            end else if (bcnt == 9'd0 && !drq) begin
                ida[0] <= hp;
                ida[1] <= {7'd0, side};
                ida[2] <= rdaddr_sec;
                ida[3] <= 8'd1;
                ida[4] <= 8'h00;
                ida[5] <= 8'h00;
                rdaddr_sec <= (rdaddr_sec + 8'd1 >= d_spt) ? 8'd0 : rdaddr_sec + 8'd1;
                bcnt <= 9'd1;
                timer <= 32'(FIND_US * US);
            end else if (!drq && !(wr || rd)) begin
                if (bcnt == 9'd7) begin
                    sector_r <= ida[0];
                    status[1] <= 1'b0;
                    st <= S_DONE;
                end else begin
                    data_r <= ida[bcnt[2:0] - 3'd1];
                    bcnt <= bcnt + 9'd1;
                    drq <= 1'b1;
                    status[1] <= 1'b1;
                end
            end
        end
        S_RDTRK: begin
            // not supported by the image: deliver one empty byte and finish
            status[4] <= 1'b1;
            st <= S_DONE;
        end
        S_WRTRK: begin
            // format: take the track bytes and count the sector IDs in them (an ID mark FE
            // after the A1 sync, written as F5, or in FM after 00; 4 ID bytes; then the data
            // field from its mark FB/F8 on is skipped). The image keeps its data.
            if (!disk || wprot[dn]) begin
                if (disk) status[6] <= 1'b1;
                st <= S_DONE;
            end else if (timer == 32'd0) begin
                trkcnt <= 13'd0;
                drq <= 1'b1;
                status[1] <= 1'b1;
                timer <= 32'd1;
                wt_prev <= 8'h4e;
                wt_id <= 3'd0;
                wt_skip <= 11'd0;
                wt_wantdata <= 1'b0;
                wt_count <= 8'd0;
            end else if (!drq && !(wr || rd)) begin
                // the byte the CPU wrote last (data_r) goes to the track now
                if (trkcnt != 13'd0) begin
                    logic mark;
                    mark = dden_n ? (wt_prev == 8'h00) : (wt_prev == 8'hf5);
                    wt_prev <= data_r;
                    if (wt_skip != 11'd0)
                        wt_skip <= wt_skip - 11'd1;
                    else if (wt_id != 3'd0) begin
                        if (wt_id == 3'd1) wt_idsize <= data_r[1:0];
                        if (wt_id == 3'd2) wt_count <= wt_count + 8'd1;          // sector number byte
                        wt_id <= wt_id - 3'd1;
                    end else if (mark && data_r == 8'hfe) begin
                        wt_id <= 3'd4;
                        wt_wantdata <= 1'b1;
                    end else if (mark && wt_wantdata && (data_r == 8'hfb || data_r == 8'hf8)) begin
                        wt_skip <= 11'd128 << wt_idsize;
                        wt_wantdata <= 1'b0;
                    end
                end
                if (trkcnt == (dden_n ? 13'd3125 : 13'd6250)) begin
                    status[1] <= 1'b0;
                    // this track's layout becomes the drive's geometry
                    if (wt_count != 8'd0) begin
                        if (!fmt_on[dn] || (hp == 8'd0 && !side)) begin
                            fmt_tracks[dn] <= hp + 8'd1;
                            fmt_sides[dn] <= side ? 2'd2 : 2'd1;
                        end else begin
                            if (hp + 8'd1 > fmt_tracks[dn]) fmt_tracks[dn] <= hp + 8'd1;
                            if (side) fmt_sides[dn] <= 2'd2;
                        end
                        fmt_spt[dn] <= wt_count;
                        fmt_dd[dn] <= !dden_n;
                        fmt_on[dn] <= 1'b1;
                    end
                    st <= S_DONE;
                end else begin
                    trkcnt <= trkcnt + 13'd1;
                    drq <= 1'b1;
                end
            end
        end

        S_DONE: begin
            status[0] <= 1'b0;
            drq <= 1'b0;
            intrq <= 1'b1;
            motor_timer <= 32'(CLK_HZ * 2);
            st <= S_IDLE;
        end
        default: ;
        endcase
    end
end

endmodule
