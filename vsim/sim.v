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
//    * no cassette overlay (it runs on clk_64), no ADC tape input
//    * no SD card yet: SDMISO idles high, MMFS sees no card
//    * CE_PIXEL is every clk_sys: the ULA's pixel clock is 16 MHz
//============================================================================

module emu (
	input             clk_sys,          // 16 MHz, toggled by sim_main.cpp
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
wire reset = reset_in | rom_download;

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
// Same map as AcornElectron.sv. ext_A[18] = 1: sideways RAM, else ROM.

wire        mem_we_n;
wire [18:0] mem_addr;
wire  [7:0] mem_din;
reg  [16:0] rom_addr;
reg  [16:0] ram_addr;
reg   [7:0] rom_data, ram_data;
wire  [7:0] rom_dout, ram_dout;

always @(*) begin
	rom_addr[13:0] = mem_addr[13:0];
	case (mem_addr[18:14])
		5'b0_01_00: rom_addr[16:14] = 0; // mmfs_swram.rom
		5'b0_10_00: rom_addr[16:14] = 1; // os100.rom
		5'b0_10_01: rom_addr[16:14] = 1;
		5'b0_10_10: rom_addr[16:14] = 2; // Basic2.rom
		5'b0_10_11: rom_addr[16:14] = 2;
		5'b0_11_00: rom_addr[16:14] = 3; // pres_ap2_v1_23.rom
		5'b0_11_01: rom_addr[16:14] = 4;
		5'b0_11_10: rom_addr[16:14] = 5;
		5'b0_11_11: rom_addr[16:14] = 6; // M7_191.rom
		default:    rom_addr[16:14] = 0;
	endcase
	case (mem_addr[18:14])
		5'b0_01_00, 5'b0_10_00, 5'b0_10_01, 5'b0_10_10, 5'b0_10_11,
		5'b0_11_00, 5'b0_11_01, 5'b0_11_10, 5'b0_11_11: rom_data = rom_dout;
		default: rom_data = 8'h00;
	endcase
	ram_addr[13:0] = mem_addr[13:0];
	ram_addr[16:14] = mem_addr[16:14];          // slots 0-7 (b1_0x_xx)
	ram_data = (mem_addr[18:17] == 2'b10) ? ram_dout : 8'h00;
end

// 112 KB ROM image, written by an ioctl index 0 download
sim_spram #(8, 17, 114688, "ELK.hex") rom
(
	.clock(clk_sys),
	.address(rom_download ? ioctl_addr[16:0] : rom_addr),
	.data(ioctl_dout),
	.wren(rom_download && ioctl_wr),
	.q(rom_dout)
);

reg old_we;
always @(posedge clk_sys) old_we <= mem_we_n;

sim_spram #(8, 17, 131072, "") ram
(
	.clock(clk_sys),
	.address(ram_addr),
	.data(mem_din),
	.wren(mem_addr[18] & old_we & ~mem_we_n),
	.q(ram_dout)
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

wire hs, vs, hblank, vblank, ce_pix;
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
	.clk_24M00(1'b0),
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

	.audio_l(audio_snl),
	.audio_r(audio_snr),

	.ext_nOE(),
	.ext_nWE(mem_we_n),
	.ext_nCS(),
	.ext_A(mem_addr),
	.ext_Dout(mem_addr[18] ? ram_data : rom_data),
	.ext_Din(mem_din),

	.SDMISO(1'b1),
	.SDCLK(),
	.SDMOSI(),
	.SDSS(),

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

assign VGA_R = {r, r};
assign VGA_G = {g, g};
assign VGA_B = {b, b};
assign VGA_HS = hs;
assign VGA_VS = vs;
assign VGA_HB = hblank;
assign VGA_VB = vblank;
assign CE_PIXEL = 1'b1;

// ------------------------------------------------------------------- audio
// Same as AcornElectron.sv (unbalanced on purpose until the audio fix lands).

wire [11:0] sound = {12{audio_snl}};
wire [15:0] sound_pad = {1'b0, sound[11:8], sound[7] ^ (tape_monitor ? casdout : 1'b0), sound[6:0], 3'b0};
assign AUDIO_L = sound_pad;
assign AUDIO_R = {16{audio_snr}};

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
	.length(tape_len)
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
