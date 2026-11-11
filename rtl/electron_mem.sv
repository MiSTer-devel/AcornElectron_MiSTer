//============================================================================
//  Acorn Electron: external memory map. Shared by AcornElectron.sv and
//  vsim/sim.v; the block RAMs themselves stay in each top (altsyncram there,
//  a behavioural RAM here).
//
//  ElectronFpga_core's ext_A (19 bits): [18] 0 = ROM, 1 = RAM, [17:14] the
//  16 KB slot, [13:0] the offset.
//
//  ROM image (112 KB, roms/ELK.mif, replaced by OSD Load ROM, index 0):
//    0 MMFS (slot 4), 1 MOS (slots 8-9: the core maps C000-FFFF there),
//    2 BASIC (10-11), 3 PRES AP2 (12), 4 Plus 3 ADFS (13, only with the
//    Plus 3 on; blank in the committed image: roms/add_rom.py adds it to a
//    build), 5 blank (14), 6 Mode 7 (15).
//
//  RAM (128 KB):
//    0-3  ROMs 0-3: the Plus 1's cartridge sockets (as MAME's plus1.cpp:
//         ROMs 0/1 = socket 2, ROMs 2/3 = socket 1). Filled by OSD
//         Cartridge 1 (index 3) and Cartridge 2 (index 4): the file's first
//         16 KB is the even ROM, the next 16 KB the odd one. Read only for
//         the CPU (the core's ABR write lock); a slot no cartridge filled
//         reads 0, which the MOS's ROM scan skips.
//    4    MMFS's workspace (B600-BFFF of slot 4)
//    5-6  main RAM, 0000-7FFF (the core puts it at RAM slots 8-9: it used to
//         sit at 0-1, on top of ROMs 0/1)
//============================================================================

module electron_mem
(
	input             clk,

	input      [18:0] mem_addr,        // ElectronFpga_core ext_A
	input             mem_we_n,        // ext_nWE
	input       [7:0] mem_din,         // ext_Din
	output      [7:0] mem_dout,        // to ext_Dout

	// OSD downloads
	input             plus3,           // Plus 3 fitted: ROM 13 (ADFS) answers
	input             rom_download,    // index 0: the 112 KB ROM image
	input       [1:0] cart_download,   // index 3: Cartridge 1, index 4: Cartridge 2
	input             ioctl_wr,
	input      [24:0] ioctl_addr,
	input       [7:0] ioctl_dout,

	// ROM block RAM (114688 x 8, registered address)
	output     [16:0] rom_a,
	output            rom_we,
	output      [7:0] rom_d,
	input       [7:0] rom_q,

	// RAM block RAM (131072 x 8, registered address)
	output reg [16:0] ram_a,
	output            ram_we,
	output      [7:0] ram_d,
	input       [7:0] ram_q
);

// ------------------------------------------------------------------- ROM
reg [2:0] rom_slot;
reg       rom_hit;
always @(*) begin
	rom_hit = 1;
	case (mem_addr[18:14])
		5'b0_01_00: rom_slot = 0;   // MMFS
		5'b0_10_00,
		5'b0_10_01: rom_slot = 1;   // MOS
		5'b0_10_10,
		5'b0_10_11: rom_slot = 2;   // BASIC
		5'b0_11_00: rom_slot = 3;   // PRES AP2
		5'b0_11_01: begin rom_slot = 4; rom_hit = plus3; end   // Plus 3 ADFS
		5'b0_11_10: rom_slot = 5;
		5'b0_11_11: rom_slot = 6;   // Mode 7
		default:    begin rom_slot = 0; rom_hit = 0; end
	endcase
end

assign rom_a  = rom_download ? ioctl_addr[16:0] : {rom_slot, mem_addr[13:0]};
assign rom_we = rom_download & ioctl_wr;
assign rom_d  = ioctl_dout;

// ------------------------------------------------------------------- RAM
// cartridge download: socket 1 -> ROMs 2/3, socket 2 -> ROMs 0/1
wire       cart_load = |cart_download;
wire [1:0] cart_slot = {cart_download[0], ioctl_addr[14]};
wire       cart_we   = cart_load & ioctl_wr & (ioctl_addr[24:15] == 0);

reg  [3:0] cart_valid = 0;         // ROMs 0-3: filled by a cartridge
reg  [1:0] old_cart = 0;
always @(posedge clk) begin
	old_cart <= cart_download;
	if (cart_download[0] & ~old_cart[0]) cart_valid[3:2] <= 2'b00;   // a new cartridge 1
	if (cart_download[1] & ~old_cart[1]) cart_valid[1:0] <= 2'b00;
	if (cart_we) cart_valid[cart_slot] <= 1'b1;
end

reg [2:0] ram_slot;
reg       ram_hit;
always @(*) begin
	ram_hit = 1;
	case (mem_addr[18:14])
		5'b1_00_00: begin ram_slot = 0; ram_hit = cart_valid[0]; end
		5'b1_00_01: begin ram_slot = 1; ram_hit = cart_valid[1]; end
		5'b1_00_10: begin ram_slot = 2; ram_hit = cart_valid[2]; end
		5'b1_00_11: begin ram_slot = 3; ram_hit = cart_valid[3]; end
		5'b1_01_00: ram_slot = 4;   // MMFS workspace
		5'b1_10_00: ram_slot = 5;   // main RAM 0000-3FFF
		5'b1_10_01: ram_slot = 6;   // main RAM 4000-7FFF
		default:    begin ram_slot = 7; ram_hit = 0; end
	endcase
	ram_a = cart_load ? {1'b0, cart_slot, ioctl_addr[13:0]} : {ram_slot, mem_addr[13:0]};
end

reg old_we = 1;
always @(posedge clk) old_we <= mem_we_n;

assign ram_we = cart_load ? cart_we : (mem_addr[18] & old_we & ~mem_we_n);
assign ram_d  = cart_load ? ioctl_dout : mem_din;

// ------------------------------------------------------------------ data
// The data follows the address one clock later (registered BRAM address);
// the core samples it many clocks later, so the hit flags need no delay.
assign mem_dout = mem_addr[18] ? (ram_hit ? ram_q : 8'h00) : (rom_hit ? rom_q : 8'h00);

endmodule
