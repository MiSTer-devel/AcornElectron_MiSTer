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
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [48:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	//if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM (USE_FB=1 in qsf)
	// FB_FORMAT:
	//    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
	//    [3]   : 0=16bits 565 1=16bits 1555
	//    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
	//
	// FB_STRIDE either 0 (rounded to 256 bytes) or multiple of pixel size (in bytes)
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	// Palette control for 8bit modes.
	// Ignored for other video modes.
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	//Secondary SDRAM
	//Set all output SDRAM_* signals to Z ASAP if SDRAM2_EN is 0
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);


assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = 0;
 
assign LED_USER  = cas_relay| ioctl_download | (vsd_sel & sd_act);
assign LED_DISK  = {1'b1,~vsd_sel & sd_act};
assign LED_POWER = 0;

assign VGA_F1    = 0;
assign BUTTONS = 0;

assign VGA_SCALER = 0;
assign HDMI_FREEZE = 0;

wire [1:0] ar = status[9:8];

assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;



`include "build_id.v" 
parameter CONF_STR = {
	"AcornElectron;;",
	"-;",
	"S0,VHD;",
//	"OC,Autostart,Yes,No;",
	"-;",
	"O89,Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O35,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;", 
	"OA,Swap Joysticks,No,Yes;",
	"-;",
	"OC,Tape Input,File,ADC;",
	"H0F2,UEF,Load Cassette;",
	"H0TF,Stop & Rewind;",
	"OD,Monitor Tape Sound,No,Yes;",
	"-;",
//	"O4,Model,B(MOS6502),Master(R65SC12);",
//	"O56,Co-Processor,None,MOS65C02;",
//	"O78,VIDEO,sRGB-interlaced,sRGB-non-interlaced,SVGA-50Hz,SVGA-60Hz;",
	"-;",
	"R0,Reset;",
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


hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	.buttons(buttons),
	.status(status),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus),
	.direct_video(direct_video),

	.status_menumask({status[12]}),

	.ps2_key(ps2_key),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),

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

/////////////////  RESET  /////////////////////////

wire reset = RESET | status[0] | buttons[1] ;

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
	.address(reset ? ioctl_addr[16:0] : rom_addr),
	.data(ioctl_dout),
	.wren(!ioctl_index && ioctl_wr && reset),
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

wire [9:0] center_joystick_y1   =  8'd128 + joya1[15:8];
wire [9:0] center_joystick_x1   =  8'd128 + joya1[7:0];
wire [9:0] center_joystick_y2   =  8'd128 + joya2[15:8];
wire [9:0] center_joystick_x2   =  8'd128 + joya2[7:0];

wire [31:0] acorn_joy1 = status[10] ? joy2 : joy1;
wire [31:0] acorn_joy2 = status[10] ? joy1 : joy2;

wire [15:0] acorn_ajoy1 = status[10] ? { (8'hFF - center_joystick_y2[7:0]),(8'hFF - center_joystick_x2[7:0])} : {(8'hFF - center_joystick_y1[7:0]),(8'hFF - center_joystick_x1[7:0])};
wire [15:0] acorn_ajoy2 = status[10] ? {(8'hFF - center_joystick_y1[7:0]),(8'hFF - center_joystick_x1[7:0])} : {(8'hFF - center_joystick_y2[7:0]),(8'hFF - center_joystick_y2[7:0])};

// analog -127..+127, Y: [15:8], X: [7:0]

ElectronFpga_core Electron
(
	.clk_16M00(clk_16),
	.clk_24M00(clk_24),
	.clk_32M00(clk_32),
	.clk_33M33(clk_33p3),
	.clk_40M00(clk_40),

	.hard_reset_n(~reset),

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
	//     -- Format of Video
   //     -- 00 - sRGB - interlaced
   //     -- 01 - sRGB - non interlaced
   //     -- 10 - SVGA - 50Hz
   //     -- 11 - SVGA - 60Hz
	//.vid_mode(2'b11)
	.vid_mode(2'b00), // interlaced
	//.vid_mode(2'b01) // non interlaced
//	.vid_mode(status[8:7])
	

/*
	.keyb_dip({4'd0, ~status[12], ~status[9:7]}),
*/
   // // analog -127..+127, Y: [15:8], X: [7:0]
	.joystick1_x(    acorn_ajoy1[7:0]),
	.joystick1_y(    acorn_ajoy1[15:8]),
	.joystick1_fire( acorn_joy1[4]),

	.joystick2_x(   acorn_ajoy2[7:0]),
	.joystick2_y(   acorn_ajoy2[15:8]),
	.joystick2_fire(acorn_joy2[4]),
	
	
	.h_cnt(h_cnt),
	.v_cnt(v_cnt)
/*
	.m128_mode(m128),
	.copro_mode(|status[6:5])*/
);

wire  audio_snl,audio_snr;
wire [11:0] sound = {12{audio_snl}};
wire [15:0] sound_pad =  {1'b0,sound[11:8], sound[7] ^ (status[13] ? (status[12] ? adc_cassette_bit : casdout) : 1'b0), sound[6:0], 3'b0};

assign AUDIO_L = sound_pad;
assign AUDIO_R = {16{audio_snr}};
assign AUDIO_MIX = 0;
assign AUDIO_S = 0;

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


wire casdout;
wire cas_relay;



wire locked;
wire [24:0] sdram_addr;
wire [7:0] sdram_data;
wire sdram_rd;
wire load_tape = ioctl_index[5:0] == 2;
reg [24:0] tape_end;

sdram sdram
(
	.*,
	.init(~locked),
	.clk(clk_sys),
	.addr(ioctl_download ? ioctl_addr : sdram_addr),
	.wtbt(0),
	.dout(sdram_data),
	.din(ioctl_dout),
	.rd(sdram_rd),
	.we(ioctl_wr & load_tape),
	.ready()
);



always @(posedge clk_sys) begin
 if (load_tape) tape_end <= ioctl_addr;
end

cassette cassette(
  .clk(clk_sys),

  .rewind(status[15] | (load_tape&ioctl_download)),
  .en(cas_relay),
  .sdram_addr(sdram_addr),
  .sdram_data(sdram_data),
  .sdram_rd(sdram_rd),

  .tape_end(tape_end),
  .data(casdout)
//   .status(tape_status)
);

wire [10:0] h_cnt;
wire [9:0]  v_cnt;

wire [7:0] o_r;
wire [7:0] o_g;
wire [7:0] o_b;

//overlay  #( .RGB(24'hEEEE22) ) overlay
overlay  #( .RGB(24'hFFFFFF) ) overlay
(
	.reset(reset),
	.i_r({r,r}),
	.i_g({g,g}),
	.i_b({b,b}),

	.i_clk(clk_64/*clk_sys*/),
	.i_pix(ce_pix2),
	
	.hcnt(h_cnt[9:0]),
	.vcnt(v_cnt),
	
	.o_r(o_r),
	.o_g(o_g),
	.o_b(o_b),
	
	.pos(sdram_addr),
	.max(tape_end),
	.tape_data(sdram_data),

	
	.ena(cas_relay)
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
