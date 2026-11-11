//============================================================================
//  Electron port to MiSTer
//  2019 Dave Wood (oldgit)
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================


module emu
(
	`include "sys/emu_ports.vh"
);


assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = 0;
 
assign LED_POWER = 0;

assign VGA_F1    = 0;
assign BUTTONS = 0;

assign VGA_DISABLE = 0;
assign VGA_SCALER = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

wire [1:0] ar = status[9:8];

// OSD layout: ~/dev2/osd-standard.md, video-standard.md, tape-standard.md.
// Status bits kept from the old menu: 3-5 Scandoubler Fx, 8-9 Aspect ratio,
// 10 Swap joysticks, 12 Tape input, 13 Tape audio, 14 Tape overlay (1 = Off),
// 15 Rewind tape. New: 16-17 CPU speed, 18 Interlace, 19-20 Scale,
// 22 BREAK, 23 Ctrl-BREAK, 24 Autoboot (1 = Off), 25 SHIFT-BREAK, 26 Tape speed (1 = Normal).
`include "build_id.v" 
parameter CONF_STR = {
	"AcornElectron;;",
	"-;",
	"SC0,VHD,Pri. disk (MMB);",
	"H1F2,UEFCAS,Tape;",
	"h1-;",
	"F0,ROM,Load ROM;",
	"-;",
	"P1,Machine;",
	"P2,Video;",
	"P3,Input;",
	"P4,Audio;",
	"P5,Advanced;",
	"-;",
	"h0-,Changes pending;",
	"R0,Apply and reset;",

	"P1O[17:16],CPU speed,Normal,2 MHz,4 MHz;",
	"P1O[26],Tape speed,8x,Normal;",
	"P1-;",
	"P1T[15],Rewind tape;",
	"P1T[22],BREAK;",
	"P1T[23],Ctrl-BREAK;",
	"P1T[25],SHIFT-BREAK (boot);",

	"P2O[18],Interlace,Off,On;",
	"P2-;",
	"P2O[9:8],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P2O[20:19],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"P2O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P2-;",
	"P2O[14],Tape overlay,On,Off;",

	"P3O[10],Swap joysticks,No,Yes;",

	"P4O[13],Tape audio,Off,On;",

	"P5O[24],Autoboot,On,Off;",
	"P5O[12],Tape input,File,ADC;",

	"I,Tape ready (rewound),Tape format not supported;",
	"JA,Fire;",
	"V,v",`BUILD_DATE
};

/////////////////  CLOCKS  ////////////////////////

//wire clk_sys=clk_40; //96mhz
wire clk_sys=clk_16; //96mhz
wire clk_16;
wire clk_24;
wire clk_32;
wire clk_33p3;
wire clk_40;
wire clk_48;
wire clk_96;
wire clk_80;
wire clk_100;
wire clk_64;
// 120 is 80 now?
xtra_pll xtra_pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_33p3),
	.outclk_1(clk_100)
);


pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_16),
	.outclk_1(clk_24),
	.outclk_2(clk_32),
	.outclk_3(clk_40),
	.outclk_4(clk_48),
	.outclk_5(clk_96),
	.outclk_6(clk_80),
	.outclk_7(clk_64),
	.locked(locked)
);

/*
reg vid_clk;
reg [1:0] old_state;
always @(posedge clk_sys) begin
	if (old_state != status[8:7]) begin
		old_state <= status[8:7];
		case (status[8:7])
			'b00: vid_clk <= clk_48;
			'b01: vid_clk <= clk_48;
			'b10: vid_clk <= clk_100;
			'b11: vid_clk <= clk_80;
		endcase
	end
end
*/

/////////////////  HPS  ///////////////////////////

wire [31:0] status;
wire  [1:0] buttons;

wire [15:0] joy1, joy2;
wire [15:0] joya1, joya2;

wire [10:0] ps2_key;

wire        ioctl_download;
wire  [7:0] ioctl_index;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        forced_scandoubler;
wire        direct_video;

wire [21:0] gamma_bus;


wire [31:0] sd_lba[1];
wire        sd_rd;
wire        sd_wr;
wire        sd_ack;
wire  [8:0] sd_buff_addr;
wire  [7:0] sd_buff_dout;
wire  [7:0] sd_buff_din[1];
wire        sd_buff_wr;

wire        img_mounted;
wire        img_readonly;
wire [63:0] img_size;


// tape (instance further down)
wire        casdout, cas_relay;
wire        tape_is_uef, tape_ready, tape_unpacking, tape_error, tape_wait;
wire [24:0] tape_pos, tape_len;
wire        tape_qtick;
reg         tape_info_req = 0;   // OSD info message (below)
reg   [7:0] tape_info = 0;
wire        tape_turbo = ~status[26] & tape_ready & cas_relay;
localparam [4:0] TAPE_TURBO = 5'd8;
wire  [4:0] tape_speed = tape_turbo ? TAPE_TURBO : 5'd1;

assign LED_USER  = cas_relay | ioctl_download | tape_unpacking | (vsd_sel & sd_act);
assign LED_DISK  = {1'b1,~vsd_sel & sd_act};

/////////////////  RESET  /////////////////////////

// Power-on reset: the board's reset, OSD Apply and reset, the USER button, and
// a ROM download (Load ROM / boot.rom). The ULA's power-on flag is set again,
// so the MOS does a cold start. BREAK and Ctrl-BREAK are OSD buttons (P1).
wire rom_download = ioctl_download && ioctl_index == 0;
wire reset = RESET | status[0] | buttons[1] | rom_download;

// The settings the machine runs with, taken from the OSD at every reset
// (osd-standard.md). Video scaling, input and tape monitor rows act at once
// and read status directly.
reg [31:0] cfg;
always @(posedge clk_sys) if (reset) cfg <= status;
wire pending = status[18:16] != cfg[18:16];

wire [1:0] cpu_speed = (cfg[17:16] == 2'd0) ? 2'b01 :   // Normal: 2 MHz ROM, 1 MHz contended RAM
                       (cfg[17:16] == 2'd1) ? 2'b10 :   // 2 MHz, no contention
                                              2'b11;    // 4 MHz

wire osd_break, osd_ctrl, osd_shift;
electron_osd_buttons osd_buttons
(
	.clk(clk_sys),
	.reset(reset),
	.autoboot(~status[24]),
	.btn_break(status[22]),
	.btn_ctrl_break(status[23]),
	.btn_shift_break(status[25]),
	.osd_break(osd_break),
	.osd_ctrl(osd_ctrl),
	.osd_shift(osd_shift)
);

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	.buttons(buttons),
	.status(status),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus),
	.direct_video(direct_video),

	.status_menumask({status[12], pending}),  // bit 1: tape input ADC hides the Tape row

	.ps2_key(ps2_key),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(tape_wait),
	.info_req(tape_info_req),
	.info(tape_info),

	.sd_lba(sd_lba),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),

	.joystick_0(joy1),
	.joystick_1(joy2),
	.joystick_l_analog_0(joya1),
	.joystick_l_analog_1(joya2)
);

////////////////  MEMORY  /////////////////////////

//reg m128 = 0;
//always @(posedge clk_sys) if(reset_req) m128 <= status[4];

// ELK ROM Images

// The first 8 are sideways rams

// 00 00xx empty     
// 00 01xx empty     
// 00 10xx empty     
// 00 11xx empty     
// 01 00xx mmfs_swram.rom         
// 01 01xx empty     
// 01 10xx empty     
// 01 11xx empty     
// 10 00xx os100.rom      
// 10 01xx os100.rom     
// 10 10xx Basic2.rom      
// 10 11xx Basic2.rom      
// 11 00xx pres_ap2_v1_23.rom     
// 11 01xx empty     
// 11 10xx empty
// 11 11xx M7_191.rom    

always_comb begin
	rom_addr[13:0] = mem_addr[13:0];
	case({mem_addr[18:14]})
		'b0_01_00: rom_addr[16:14] =  0; //mmfs_swram.rom        
		'b0_10_00: rom_addr[16:14] =  1; //os100.rom     
		'b0_10_01: rom_addr[16:14] =  1; //os100.rom 
		'b0_10_10: rom_addr[16:14] =  2; //Basic2.rom 
		'b0_10_11: rom_addr[16:14] =  2; //Basic2.rom 
		'b0_11_00: rom_addr[16:14] =  3; //pres_ap2_v1_23.rom      
		'b0_11_01: rom_addr[16:14] =  4; //empty  for future use   
		'b0_11_10: rom_addr[16:14] =  5; //empty  for future use     
		'b0_11_11: rom_addr[16:14] =  6; //M7_191.rom          
		  default: rom_addr[16:14] =  0;
	endcase
end

always_comb begin
	case({mem_addr[18:14]})
		'b0_01_00,
		'b0_10_00,
		'b0_10_01,
		'b0_10_10,
		'b0_10_11,
		'b0_11_00,
		'b0_11_01,
		'b0_11_10,
		'b0_11_11: rom_data = rom_dout;
		  default: rom_data = 0;
	endcase
end

wire        mem_we_n;
wire [18:0] mem_addr;
wire  [7:0] mem_din;
wire  [7:0] ram_dout;
reg  [7:0] ram_data;

reg  [17:0] ram_addr;
reg  [16:0] rom_addr;
wire  [7:0] rom_dout;
reg   [7:0] rom_data;

spram #(8, 17, 114688, "roms/ELK.mif") rom
(
	.clock(clk_sys),
	.address(rom_download ? ioctl_addr[16:0] : rom_addr),
	.data(ioctl_dout),
	.wren(rom_download && ioctl_wr),
	.q(rom_dout)
);

always_comb begin
	ram_addr[13:0] = mem_addr[13:0];
	case({mem_addr[18:14]})
		'b1_00_00: ram_addr[16:14] =  0; //swram        
		'b1_00_01: ram_addr[16:14] =  1; //swram     
		'b1_00_10: ram_addr[16:14] =  2; //swram 
		'b1_00_11: ram_addr[16:14] =  3; //swram 
		'b1_01_00: ram_addr[16:14] =  4; //mmfs_swram.ram 
		'b1_01_01: ram_addr[16:14] =  5; //swram     
		'b1_01_10: ram_addr[16:14] =  6; //swram   
		'b1_01_11: ram_addr[16:14] =  7; //swram           
		  default: ram_addr[16:14] =  0;
	endcase
end

always_comb begin
	case({mem_addr[18:14]})
		'b1_00_00,
		'b1_00_01,
		'b1_00_10,
		'b1_00_11,
		'b1_01_00,
		'b1_01_01,
		'b1_01_10,
		'b1_01_11: ram_data = ram_dout;
		  default: ram_data = 0;
	endcase
end

spram #(8, 17, 131072) ram
(
	.clock(clk_sys),
	.address(ram_addr),
	.data(mem_din),
	.wren(mem_addr[18] & old_we & ~mem_we_n),
	.q(ram_dout)
);

reg old_we;
always @(posedge clk_sys) old_we <= mem_we_n;

///////////////////////////////////////////////////

wire reset_req;

// Joysticks -> Plus 1 ADC / fire and First Byte (rtl/electron_input.sv)
wire [7:0] adc1_x, adc1_y, adc2_x, adc2_y;
wire       fire1, fire2;
wire [4:0] fb_joy;
electron_joy electron_joy
(
	.joy1(joy1), .joy2(joy2), .joya1(joya1), .joya2(joya2),
	.swap(status[10]),
	.adc1_x(adc1_x), .adc1_y(adc1_y), .adc2_x(adc2_x), .adc2_y(adc2_y),
	.fire1(fire1), .fire2(fire2),
	.fb_joy(fb_joy)
);

wire show_cas_overlay = ~status[14];

// analog -127..+127, Y: [15:8], X: [7:0]

ElectronFpga_core Electron
(
	.clk_16M00(clk_16),
	.clk_24M00(clk_24),
	.clk_32M00(clk_32),
	.clk_33M33(clk_33p3),
	.clk_40M00(clk_40),

	.hard_reset_n(~reset),
	.osd_break(osd_break),
	.osd_ctrl(osd_ctrl),
	.osd_shift(osd_shift),
	.cpu_speed(tape_turbo ? 2'b11 : cpu_speed),   // 4 MHz while a turbo load runs
	.tape_speed(tape_speed),

	.ps2_key(ps2_key),

//	.video_sel(clk_sel),
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
	.ext_A(mem_addr),
	.ext_Dout(mem_addr[18] ? ram_data : rom_data),
	.ext_Din(mem_din),

	.SDMISO(sdmiso),
	.SDCLK(sdclk),
	.SDMOSI(sdmosi),
	.SDSS(sdss),

	.caps_led(),
	.motor_led(cas_relay),
	
	.cassette_in(status[12] ? adc_cassette_bit : casdout ),
	.cassette_out(),
	// 00: 15 kHz non-interlaced (312 lines), 01: interlaced (312/313-line
	// fields, the same picture in both). The SVGA modes are not built.
	.vid_mode({1'b0, cfg[18]}),

	.joystick1_x(adc1_x),
	.joystick1_y(adc1_y),
	.joystick1_fire(fire1),
	.joystick2_x(adc2_x),
	.joystick2_y(adc2_y),
	.joystick2_fire(fire2),
	.fb_joy(fb_joy),
	
	
	.h_cnt(h_cnt),
	.v_cnt(v_cnt)
/*
	.m128_mode(m128),
	.copro_mode(|status[6:5])*/
);

// Audio: the ULA's 1-bit square wave, the same on both channels, signed
// around 0 at 3/16 of full scale (was full scale on R, issue #1). OSD Tape
// audio adds the tape signal at a quarter of that. sys DC-blocks the
// output, so a held level is silent.
wire  audio_snl,audio_snr;
wire        tape_bit   = status[12] ? adc_cassette_bit : casdout;
wire [15:0] snd_level  = audio_snl ? 16'h1800 : 16'hE800;            // +/- 0x1800
wire [15:0] tape_level = ~status[13] ? 16'h0000 : tape_bit ? 16'h0600 : 16'hFA00;
wire [15:0] audio_mix  = snd_level + tape_level;

assign AUDIO_L = audio_mix;
assign AUDIO_R = audio_mix;
assign AUDIO_MIX = 0;
assign AUDIO_S = 1;

wire hs, vs, hblank, vblank, ce_pix, clk_sel;
wire [3:0] r,g,b;

assign CLK_VIDEO = clk_64;


reg ce_pix2;
always @(posedge CLK_VIDEO ) begin
   reg [1:0] div;

   div <= div + 1'd1;
   ce_pix2 <= div == 0;
end




wire [2:0] scale = status[5:3];
wire [2:0] sl = scale ? scale - 1'd1 : 3'd0;
wire       scandoubler = (scale || forced_scandoubler);
assign VGA_SL = sl[1:0];



video_mixer #(.GAMMA(1)) video_mixer
(
   .*,

   .CLK_VIDEO(CLK_VIDEO),
   .ce_pix(ce_pix2),

   .hq2x(scale==1),


   .R(o_r),
   .G(o_g),
   .B(o_b),

   .HSync(hs),
   .VSync(vs),
   .HBlank(hblank),
   .VBlank(vblank)
);

video_freak video_freak
(
	.*,
	.VGA_DE_IN(VGA_DE),
	.VGA_DE(),
	// Original: the real shape of the 640 x 256 active picture. 16 MHz pixels
	// on a PAL raster (square-pixel rate 7.375 MHz) have a pixel aspect of
	// 7.375/16, so 640*7.375/16 : 256 = 295:256 (1.15:1).
	.ARX((!ar) ? 12'd295 : (ar - 1'd1)),
	.ARY((!ar) ? 12'd256 : 12'd0),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE({1'b0, status[20:19]})
);





wire freeze_sync;
//////////////////   SD   ///////////////////

wire sdclk;
wire sdmosi;
wire sdmiso = vsd_sel ? vsdmiso : SD_MISO;
wire sdss;

reg vsd_sel = 0;
always @(posedge clk_sys) if(img_mounted) vsd_sel <= |img_size;

wire vsdmiso;
sd_card sd_card
(
	.sd_lba(sd_lba[0]),
	.sd_buff_din(sd_buff_din[0]),
	.*,

	.clk_spi(clk_sys),
	.sdhc(1),
	.sck(sdclk),
	.ss(sdss | ~vsd_sel),
	.mosi(sdmosi),
	.miso(vsdmiso)
);

assign SD_CS   = sdss   |  vsd_sel;
assign SD_SCK  = sdclk  & ~vsd_sel;
assign SD_MOSI = sdmosi & ~vsd_sel;

reg sd_act;

always @(posedge clk_sys) begin
	reg old_mosi, old_miso;
	integer timeout = 0;

	old_mosi <= sdmosi;
	old_miso <= sdmiso;

	sd_act <= 0;
	if(timeout < 2000000) begin
		timeout <= timeout + 1;
		sd_act <= 1;
	end

	if((old_mosi ^ sdmosi) || (old_miso ^ sdmiso)) timeout <= 0;
end





/////////////////////// ADC Module  //////////////////////////////


wire [11:0] adc_data;
wire        adc_sync;
reg [11:0] adc_value;
reg adc_sync_d;

integer ii=0;
reg [11:0] adc_val[0:511];
reg [21:0] adc_total = 0;
reg [11:0] adc_avg;

reg adc_cassette_bit;


// interface to ADC via framework
//
ltc2308 #(1, 48000, 50000000) adc_input		// mono, ADC_RATE = 48000, CLK_RATE = 50000000
(
	.reset(reset),
	.clk(CLK_50M),

	.ADC_BUS(ADC_BUS),
	.dout(adc_data),
	.dout_sync(adc_sync)
);

// when data arrives:
//		- latch it in adc_value
//		- keep track of a running average across 512 samples
//
//		-> this average acts as a high-pass filter above roughly 100 Hz while retaining
//		 	while retaining very high frequency response, for possible future fast-load techniques
//
always @(posedge CLK_50M) begin

	adc_sync_d<=adc_sync;
	if(adc_sync_d ^ adc_sync) begin
		adc_value <= adc_data;					// latch in current value, adc_Value
		
		adc_val[0] <= adc_value;				
		adc_total  <= adc_total - adc_val[511] + adc_value;

		for (ii=0; ii<511; ii=ii+1)
			adc_val[ii+1] <= adc_val[ii];
			
		adc_avg <= adc_total[20:9];			// update average value every fetch
		
		if (adc_value < (adc_avg - 100))		// flip the cassette bit if > 0.1V from average
			adc_cassette_bit <= 1;				// note that original CoCo reversed polarity

		if (adc_value > (adc_avg + 100))
			adc_cassette_bit <= 0;
		
	end
end





wire locked;

// Tape: download -> (gunzip) -> UEF or bit-stream player (rtl/tape.sv).
// Main_MiSTer converts .uef files to a bit stream itself for this core, so
// on MiSTer a .uef arrives like a .cas; raw UEF data plays too.
// OSD Tape speed (P1): the tape plays TAPE_TURBO times faster while the
// motor runs, the ULA's tape receiver counts that much faster, and the CPU
// runs at 4 MHz to keep up; the machine is back to normal when the motor
// stops (tape-standard.md).
wire load_tape = ioctl_download && ioctl_index[5:0] == 2;
wire        tmem_req, tmem_we;
wire [24:0] tmem_addr;
wire  [7:0] tmem_din;
reg         tmem_ack = 0;
reg   [7:0] tmem_dout;

tape #(.CLK_HZ(16000000)) tape
(
	.clk(clk_sys),
	.reset(reset),
	.load(load_tape),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(tape_wait),
	.rewind(status[15]),
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

// OSD info message when a tape has loaded (tape-standard.md rule 5): 1 "Tape
// ready (rewound)" (every new tape starts at its start), 2 "Tape format not
// supported" (bad gzip data).
always @(posedge clk_sys) begin
	reg old_ready = 0, old_error = 0;
	reg [3:0] hold = 0;
	old_ready <= tape_ready; old_error <= tape_error;
	if (hold) hold <= hold - 1'd1; else tape_info_req <= 0;
	if (tape_ready & ~old_ready) begin tape_info <= 8'd1; tape_info_req <= 1; hold <= 4'd15; end
	if (tape_error & ~old_error) begin tape_info <= 8'd2; tape_info_req <= 1; hold <= 4'd15; end
end

// byte requests -> sdram.sv (edge-triggered rd/we, `ready` when done)
wire [15:0] sdram_dout;
wire        sdram_ready;
reg         sdr_we = 0, sdr_rd = 0, sdr_busy = 0;
reg  [24:0] sdr_addr;
reg   [7:0] sdr_din;
reg   [2:0] sdr_wait;

always @(posedge clk_sys) begin
	tmem_ack <= 0;
	sdr_we <= 0;
	sdr_rd <= 0;
	if (!sdr_busy) begin
		if (tmem_req && !tmem_ack) begin
			sdr_addr <= tmem_addr; sdr_din <= tmem_din;
			sdr_we <= tmem_we; sdr_rd <= ~tmem_we;
			sdr_wait <= 3'd3; sdr_busy <= 1;
		end
	end
	else if (sdr_wait) sdr_wait <= sdr_wait - 1'd1;
	else if (sdram_ready) begin tmem_ack <= 1; tmem_dout <= sdram_dout[7:0]; sdr_busy <= 0; end
end

sdram sdram
(
	.*,
	.init(~locked),
	.clk(clk_sys),
	.addr(sdr_addr),
	.wtbt(0),
	.dout(sdram_dout),
	.din({8'h00, sdr_din}),
	.rd(sdr_rd),
	.we(sdr_we),
	.ready(sdram_ready)
);

wire [10:0] h_cnt;
wire [9:0]  v_cnt;

wire [7:0] o_r;
wire [7:0] o_g;
wire [7:0] o_b;

// Tape status bar (rtl/tape_overlay.sv, tape-standard.md rules 19-24):
// "TAPE > m:ss/ m:ss x8" and a progress bar, bottom left, while the relay
// is on. OSD Tape overlay (P2) turns it off.
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

tape_overlay #(.FACTOR(TAPE_TURBO[3:0])) tape_overlay
(
	.clk(CLK_VIDEO),
	.ce_pix(ce_pix2),
	.hblank(hblank),
	.vblank(vblank),
	.enable(show_cas_overlay),
	.status(tape_status_word),
	.req(tape_status_req),
	.ack(tape_status_ack),
	.rgb_in({r, r, g, g, b, b}),
	.rgb_out({o_r, o_g, o_b})
);


endmodule

//////////////////////////////////////////////

module spram #(parameter DATAWIDTH=8, ADDRWIDTH=8, NUMWORDS=1<<ADDRWIDTH, MEM_INIT_FILE="")
(
	input	                 clock,
	input	 [ADDRWIDTH-1:0] address,
	input	 [DATAWIDTH-1:0] data,
	input	                 wren,
	output [DATAWIDTH-1:0] q
);

altsyncram altsyncram_component
(
	.address_a (address),
	.clock0 (clock),
	.data_a (data),
	.wren_a (wren),
	.q_a (q),
	.aclr0 (1'b0),
	.aclr1 (1'b0),
	.address_b (1'b1),
	.addressstall_a (1'b0),
	.addressstall_b (1'b0),
	.byteena_a (1'b1),
	.byteena_b (1'b1),
	.clock1 (1'b1),
	.clocken0 (1'b1),
	.clocken1 (1'b1),
	.clocken2 (1'b1),
	.clocken3 (1'b1),
	.data_b (1'b1),
	.eccstatus (),
	.q_b (),
	.rden_a (1'b1),
	.rden_b (1'b1),
	.wren_b (1'b0)
);

defparam
	altsyncram_component.clock_enable_input_a = "BYPASS",
	altsyncram_component.clock_enable_output_a = "BYPASS",
	altsyncram_component.init_file = MEM_INIT_FILE,
	altsyncram_component.intended_device_family = "Cyclone V",
	altsyncram_component.lpm_type = "altsyncram",
	altsyncram_component.numwords_a = NUMWORDS,
	altsyncram_component.operation_mode = "SINGLE_PORT",
	altsyncram_component.outdata_aclr_a = "NONE",
	altsyncram_component.outdata_reg_a = "UNREGISTERED",
	altsyncram_component.power_up_uninitialized = "FALSE",
	altsyncram_component.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
	altsyncram_component.widthad_a = ADDRWIDTH,
	altsyncram_component.width_a = DATAWIDTH,
	altsyncram_component.width_byteena_a = 1;


endmodule
