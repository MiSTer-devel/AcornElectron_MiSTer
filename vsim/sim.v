`timescale 1ns / 1ps
//============================================================================
//  Simulation top (Verilator) for the Acorn Electron core.
//
//  Stands in for AcornElectron.sv: same memory map, joystick mapping and
//  tape player, but hps_io, the PLLs, the SDRAM and altsyncram are replaced
//  by things sim_main.cpp can drive. Keep it in sync with AcornElectron.sv.
//
//  The VHDL core (T65, ULA, VIA, keyboard) is converted to Verilog by GHDL
//  (see Makefile): obj_dir/gen/electron_core.v, top module ElectronFpga_core.
//
//  Deliberate differences from AcornElectron.sv:
//    * one 16 MHz clock (clk_sys = clk_16). vid_mode 00/01 only use that;
//      the 24/32/33/40 MHz inputs are tied low (Mode 7 / SVGA are off).
//    * the tape memory is a behavioural 4 MB array instead of SDRAM
//    * the tape status bar runs on clk_sys (AcornElectron.sv: clk_64 with a
//      1-in-4 pixel enable; same pixels); no ADC tape input
//    * SD card: sys/sd_card.sv as AcornElectron.sv; sim_main.cpp answers the
//      hps_io block protocol from an image (--sd), else no card
//    * video out on clk_48 as AcornElectron.sv: CE_PIXEL every 3rd clock
//      (16 MHz ULA pixels), every 4th in Mode 7 (12 MHz SAA5050 pixels)
//============================================================================

module emu (
	input             clk_sys,          // 16 MHz, toggled by sim_main.cpp
	input             clk_24,           // 24 MHz: the SAA5050 (Mode 7)
	input             clk_48,           // 48 MHz: video out (CLK_VIDEO)
	input             reset_in,         // board / OSD Apply and reset

	input      [10:0] ps2_key,          // [7:0] code, [8] ext, [9] pressed, [10] toggle
	input      [31:0] joystick_0,       // hps_io joystick_0 (bit 4 = Fire)
	input      [31:0] joystick_1,
	input      [15:0] joystick_l_analog_0, // signed Y [15:8], X [7:0]
	input      [15:0] joystick_l_analog_1,
	input             swap_joysticks,   // OSD status[10]
	input             vid_interlaced,   // OSD status[18] Interlace (latched at reset)
	input       [1:0] osd_cpu_speed,    // OSD status[17:16] CPU speed (latched at reset)
	input             btn_break,        // OSD status[22] BREAK
	input             btn_ctrl_break,   // OSD status[23] Ctrl-BREAK
	input             btn_shift_break,  // OSD status[25] SHIFT-BREAK
	input             autoboot,         // OSD status[24] Autoboot (On = 1 here)
	input             tape_rewind,      // OSD status[15] Rewind tape
	input             tape_monitor,     // OSD status[13]
	input             tape_overlay_off, // OSD status[14] Tape overlay Off
	input             tape_fast,        // OSD Tape speed: Nx (status[26] = 0)
	input       [4:0] tape_turbo_n,     // N (AcornElectron.sv: TAPE_TURBO)

	// HPS file transfer: index 0 = ROM (resets the machine), 2 = tape
	input             ioctl_download,
	input             ioctl_wr,
	input      [24:0] ioctl_addr,
	input       [7:0] ioctl_dout,
	input       [7:0] ioctl_index,
	output            ioctl_wait,

	output      [7:0] VGA_R,
	output      [7:0] VGA_G,
	output      [7:0] VGA_B,
	output            VGA_HS,
	output            VGA_VS,
	output            VGA_HB,
	output            VGA_VB,
	output            CE_PIXEL,

	// SD card image (hps_io block protocol, driven by sim_main.cpp --sd)
	input             img_mounted,
	input      [63:0] img_size,
	output     [31:0] sd_lba,
	output            sd_rd,
	output            sd_wr,
	input             sd_ack,
	input       [8:0] sd_buff_addr,
	input       [7:0] sd_buff_dout,
	output      [7:0] sd_buff_din,
	input             sd_buff_wr,

	// sys video_mixer + video_calc, as on MiSTer: what Main reads (--vcheck)
	input       [4:0] vc_par,
	output     [15:0] vc_dout,
	output      [4:0] dbg_sd,           // SD: vsd_sel, ss, sck, mosi, miso

	output     [15:0] AUDIO_L,
	output     [15:0] AUDIO_R,

	// debug taps for sim_main.cpp
	output     [15:0] dbg_cpu_addr,
	output     [18:0] dbg_cpu,          // DO, R_W_n, Sync, Enable, DI
	output     [18:0] dbg_mem_addr,
	output            dbg_mem_we_n,
	output      [7:0] dbg_mem_din,
	output            dbg_cas_relay,
	output            dbg_casdout,
	output     [24:0] dbg_tape_addr,
	output     [24:0] dbg_tape_end
);


// ------------------------------------------------------------------- reset
// As AcornElectron.sv: a ROM download is a power-on reset; settings latch at reset.
wire rom_download = ioctl_download && ioctl_index == 0;
wire [1:0] cart_download = {ioctl_download && ioctl_index == 4, ioctl_download && ioctl_index == 3};   // Cartridge 1 / 2
wire reset = reset_in | rom_download | (|cart_download);

reg       cfg_interlace;
reg [1:0] cfg_speed;
always @(posedge clk_sys) if (reset) begin cfg_interlace <= vid_interlaced; cfg_speed <= osd_cpu_speed; end
wire [1:0] cpu_speed = (cfg_speed == 2'd0) ? 2'b01 : (cfg_speed == 2'd1) ? 2'b10 : 2'b11;

wire osd_break, osd_ctrl, osd_shift;
electron_osd_buttons osd_buttons
(
	.clk(clk_sys),
	.reset(reset),
	.autoboot(autoboot),
	.btn_break(btn_break),
	.btn_ctrl_break(btn_ctrl_break),
	.btn_shift_break(btn_shift_break),
	.osd_break(osd_break),
	.osd_ctrl(osd_ctrl),
	.osd_shift(osd_shift)
);

// ------------------------------------------------------------------ memory
// The same map as AcornElectron.sv (rtl/electron_mem.sv).

wire        mem_we_n;
wire [18:0] mem_addr;
wire  [7:0] mem_din, mem_dout;
wire [16:0] rom_a, ram_a;
wire        rom_we, ram_we;
wire  [7:0] rom_d, ram_d, rom_q, ram_q;

electron_mem electron_mem
(
	.clk(clk_sys),
	.mem_addr(mem_addr), .mem_we_n(mem_we_n), .mem_din(mem_din), .mem_dout(mem_dout),
	.rom_download(rom_download), .cart_download(cart_download),
	.ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
	.rom_a(rom_a), .rom_we(rom_we), .rom_d(rom_d), .rom_q(rom_q),
	.ram_a(ram_a), .ram_we(ram_we), .ram_d(ram_d), .ram_q(ram_q)
);

// 112 KB ROM image, written by an ioctl index 0 download
sim_spram #(8, 17, 114688, "ELK.hex") rom
(
	.clock(clk_sys),
	.address(rom_a),
	.data(rom_d),
	.wren(rom_we),
	.q(rom_q)
);

sim_spram #(8, 17, 131072, "") ram
(
	.clock(clk_sys),
	.address(ram_a),
	.data(ram_d),
	.wren(ram_we),
	.q(ram_q)
);

// --------------------------------------------------------------- joysticks
// The same module as AcornElectron.sv (rtl/electron_input.sv).

wire [7:0] adc1_x, adc1_y, adc2_x, adc2_y;
wire       fire1, fire2;
wire [4:0] fb_joy;
electron_joy electron_joy
(
	.joy1(joystick_0[15:0]), .joy2(joystick_1[15:0]),
	.joya1(joystick_l_analog_0), .joya2(joystick_l_analog_1),
	.swap(swap_joysticks),
	.adc1_x(adc1_x), .adc1_y(adc1_y), .adc2_x(adc2_x), .adc2_y(adc2_y),
	.fire1(fire1), .fire2(fire2),
	.fb_joy(fb_joy)
);

// -------------------------------------------------------------------- core

wire hs, vs, hblank, vblank, ce_pix, mode7;
wire [3:0] r, g, b;
wire audio_snl, audio_snr;
wire cas_relay;
wire casdout;
wire [10:0] h_cnt;
wire [9:0]  v_cnt;
wire [15:0] cpu_addr;

ElectronFpga_core Electron
(
	.clk_16M00(clk_sys),
	.clk_24M00(clk_24),
	.clk_32M00(1'b0),
	.clk_33M33(1'b0),
	.clk_40M00(1'b0),

	.hard_reset_n(~reset),
	.osd_break(osd_break),
	.osd_ctrl(osd_ctrl),
	.osd_shift(osd_shift),
	.cpu_speed(tape_turbo ? 2'b11 : cpu_speed),
	.tape_speed(tape_speed),
	.ps2_key(ps2_key),

	.video_cepix(ce_pix),
	.video_red(r),
	.video_green(g),
	.video_blue(b),
	.video_vblank(vblank),
	.video_hblank(hblank),
	.video_vsync(vs),
	.video_hsync(hs),
	.video_mode7(mode7),

	.audio_l(audio_snl),
	.audio_r(audio_snr),

	.ext_nOE(),
	.ext_nWE(mem_we_n),
	.ext_nCS(),
	.ext_A(mem_addr),
	.ext_Dout(mem_dout),
	.ext_Din(mem_din),

	.SDMISO(sdmiso),
	.SDCLK(sdclk),
	.SDMOSI(sdmosi),
	.SDSS(sdss),

	.caps_led(),
	.motor_led(cas_relay),

	.cassette_in(casdout),
	.cassette_out(),

	.vid_mode({1'b0, cfg_interlace}),

	.test(),
	.avr_RxD(1'b1),
	.avr_TxD(),
	.cpu_addr(cpu_addr),
	.cpu_dbg(dbg_cpu),

	.joystick1_x(adc1_x),
	.joystick1_y(adc1_y),
	.joystick1_fire(fire1),
	.joystick2_x(adc2_x),
	.joystick2_y(adc2_y),
	.joystick2_fire(fire2),
	.fb_joy(fb_joy),

	.h_cnt(h_cnt),
	.v_cnt(v_cnt)
);

// Tape status bar (rtl/tape_overlay.sv), as AcornElectron.sv
wire [42:0] tape_status_word;
wire        tape_status_req, tape_status_ack;

tape_status tape_status
(
	.clk(clk_sys),
	.loaded(tape_ready),
	.playing(cas_relay),
	.fast(tape_turbo),
	.qtick(tape_qtick),
	.position(tape_pos),
	.length(tape_len),
	.timed(~tape_is_uef),
	.status(tape_status_word),
	.req(tape_status_req),
	.ack(tape_status_ack)
);

// Video out, as AcornElectron.sv: clk_48 with a 16 MHz (ULA) or 12 MHz
// (Mode 7) pixel enable; registered here so sim_main samples one set.
reg  [1:0] pdiv = 0;
reg        ce48 = 0;
always @(posedge clk_48) begin
	pdiv <= (pdiv == (mode7 ? 2'd3 : 2'd2)) ? 2'd0 : pdiv + 1'd1;
	ce48 <= (pdiv == 0);
end
wire [23:0] ov_rgb;

tape_overlay #(.FACTOR(4'd8)) tape_overlay
(
	.clk(clk_48),
	.ce_pix(ce48),
	.hblank(hblank),
	.vblank(vblank),
	.enable(~tape_overlay_off),
	.status(tape_status_word),
	.req(tape_status_req),
	.ack(tape_status_ack),
	.rgb_in({r, r, g, g, b, b}),
	.rgb_out(ov_rgb)
);

reg [23:0] vo_rgb;
reg        vo_hs, vo_vs, vo_hb, vo_vb, vo_ce = 0;
always @(posedge clk_48) begin
	vo_ce <= ce48;
	if (ce48) begin vo_rgb <= ov_rgb; vo_hs <= hs; vo_vs <= vs; vo_hb <= hblank; vo_vb <= vblank; end
end
assign {VGA_R, VGA_G, VGA_B} = vo_rgb;
assign VGA_HS = vo_hs;
assign VGA_VS = vo_vs;
assign VGA_HB = vo_hb;
assign VGA_VB = vo_vb;
assign CE_PIXEL = vo_ce;

// The framework's own video path up to its measurement: sys/video_mixer.sv
// (GAMMA off), sync_fix and video_calc (extracted from sys/ by the Makefile).
// Main shows a new resolution only when video_calc reports a stable one.
wire [7:0] vm_r, vm_g, vm_b;
wire       vm_ce, vm_hs, vm_vs, vm_de;
wire [21:0] vm_gamma;
video_mixer #(.GAMMA(0)) video_mixer
(
	.CLK_VIDEO(clk_48), .CE_PIXEL(vm_ce), .ce_pix(ce48),
	.scandoubler(1'b0), .hq2x(1'b0), .gamma_bus(vm_gamma),
	.R(ov_rgb[23:16]), .G(ov_rgb[15:8]), .B(ov_rgb[7:0]),
	.HSync(hs), .VSync(vs), .HBlank(hblank), .VBlank(vblank),
	.HDMI_FREEZE(1'b0), .freeze_sync(),
	.VGA_R(vm_r), .VGA_G(vm_g), .VGA_B(vm_b), .VGA_VS(vm_vs), .VGA_HS(vm_hs), .VGA_DE(vm_de)
);
wire vm_vs_fix, vm_hs_fix;
sync_fix sync_v(clk_48, vm_vs, vm_vs_fix);
sync_fix sync_h(clk_48, vm_hs, vm_hs_fix);
video_calc video_calc
(
	.clk_100(clk_48), .clk_vid(clk_48), .clk_sys(clk_sys),
	.ce_pix(vm_ce), .de(vm_de), .hs(vm_hs_fix), .vs(vm_vs_fix), .vs_hdmi(1'b0), .f1(1'b0),
	.new_vmode(1'b0), .video_rotated(1'b0),
	.par_num(vc_par), .dout(vc_dout)
);

// ------------------------------------------------------------------- audio
// Same as AcornElectron.sv.

wire [15:0] snd_level  = audio_snl ? 16'h1800 : 16'hE800;   // as AcornElectron.sv (AUDIO_S = 1)
wire [15:0] tape_level = ~tape_monitor ? 16'h0000 : casdout ? 16'h0600 : 16'hFA00;
assign AUDIO_L = snd_level + tape_level;
assign AUDIO_R = snd_level + tape_level;

// -------------------------------------------------------------------- tape
// The same rtl/tape.sv as AcornElectron.sv; a 4 MB array with an SDRAM-like
// delay stands in for the SDRAM (download at 0, gunzipped data at 8 MB).

wire        load_tape = ioctl_download && ioctl_index[5:0] == 2;
wire        tmem_req, tmem_we;
wire [24:0] tmem_addr;
wire  [7:0] tmem_din;
reg         tmem_ack = 0;
reg   [7:0] tmem_dout;
wire        tape_is_uef, tape_ready, tape_unpacking, tape_error;
wire [24:0] tape_pos, tape_len;
wire        tape_qtick;
wire        tape_turbo = tape_fast & tape_ready & cas_relay;
wire  [4:0] tape_speed = tape_turbo ? tape_turbo_n : 5'd1;
reg   [7:0] tape_mem[0:4194303];
reg   [2:0] tmem_delay = 0;

always @(posedge clk_sys) begin
	tmem_ack <= 0;
	if (tmem_req && !tmem_ack) begin
		if (tmem_delay == 3'd6) begin
			if (tmem_we) tape_mem[{tmem_addr[23], tmem_addr[20:0]}] <= tmem_din;
			tmem_dout <= tape_mem[{tmem_addr[23], tmem_addr[20:0]}];
			tmem_ack <= 1;
			tmem_delay <= 0;
		end
		else tmem_delay <= tmem_delay + 1'd1;
	end
end

tape #(.CLK_HZ(16000000)) tape
(
	.clk(clk_sys),
	.reset(reset),
	.load(load_tape),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	.rewind(tape_rewind),
	.motor(cas_relay),
	.speed(tape_speed),
	.mem_req(tmem_req),
	.mem_we(tmem_we),
	.mem_addr(tmem_addr),
	.mem_din(tmem_din),
	.mem_ack(tmem_ack),
	.mem_dout(tmem_dout),
	.cas_out(casdout),
	.is_uef(tape_is_uef),
	.ready(tape_ready),
	.unpacking(tape_unpacking),
	.error(tape_error),
	.position(tape_pos),
	.length(tape_len),
	.qtick(tape_qtick)
);

// ---------------------------------------------------------------- SD card
// As AcornElectron.sv: MMFS's SPI card is sys/sd_card.sv on the image.
wire sdclk, sdmosi, sdss, vsdmiso;
reg  vsd_sel = 0;
always @(posedge clk_sys) if (img_mounted) vsd_sel <= |img_size;
wire sdmiso = vsd_sel ? vsdmiso : 1'b1;
assign dbg_sd = {vsd_sel, sdss, sdclk, sdmosi, sdmiso};

sd_card sd_card
(
	.clk_sys(clk_sys), .reset(reset),
	.sdhc(1'b1), .img_mounted(img_mounted), .img_size(img_size),
	.sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr),
	.clk_spi(clk_sys), .ss(sdss | ~vsd_sel), .sck(sdclk), .mosi(sdmosi), .miso(vsdmiso)
);

// ------------------------------------------------------------------- debug

assign dbg_cpu_addr  = cpu_addr;
assign dbg_mem_addr  = mem_addr;
assign dbg_mem_we_n  = mem_we_n;
assign dbg_mem_din   = mem_din;
assign dbg_cas_relay = cas_relay;
assign dbg_casdout   = casdout;
assign dbg_tape_addr = tape_pos;
assign dbg_tape_end  = tape_len;

endmodule

// altsyncram SINGLE_PORT with unregistered output: address is registered,
// q follows one clock later.
module sim_spram #(parameter DATAWIDTH=8, ADDRWIDTH=8, NUMWORDS=1<<ADDRWIDTH, MEM_INIT_FILE="")
(
	input                  clock,
	input  [ADDRWIDTH-1:0] address,
	input  [DATAWIDTH-1:0] data,
	input                  wren,
	output [DATAWIDTH-1:0] q
);

reg [DATAWIDTH-1:0] mem[0:NUMWORDS-1] /* verilator public */;
reg [ADDRWIDTH-1:0] addr_r;

initial if (MEM_INIT_FILE != "") $readmemh(MEM_INIT_FILE, mem);

always @(posedge clock) begin
	if (wren) mem[address] <= data;
	addr_r <= address;
end

assign q = mem[addr_r];

endmodule
