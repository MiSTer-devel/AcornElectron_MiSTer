//============================================================================
//  True dual-port block RAM, one clock, 8-bit ports: q follows the address
//  one clock later (registered address, unregistered output; a write reads
//  back the new data). An explicit altsyncram, as sys/sd_card.sv does:
//  Quartus will not infer this from behavioural code ("unsupported
//  read-during-write behavior"). The sim uses vsim/rtl/altsyncram_sim.v.
//============================================================================

module dpram #(parameter AW = 8)
(
	input           clk,

	input  [AW-1:0] addr_a,
	input     [7:0] din_a,
	input           we_a,
	output    [7:0] q_a,

	input  [AW-1:0] addr_b,
	input     [7:0] din_b,
	input           we_b,
	output    [7:0] q_b
);

altsyncram ram
(
	.clock0(clk), .address_a(addr_a), .data_a(din_a), .wren_a(we_a), .q_a(q_a),
	.clock1(clk), .address_b(addr_b), .data_b(din_b), .wren_b(we_b), .q_b(q_b),
	.aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
	.byteena_a(1'b1), .byteena_b(1'b1),
	.clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
	.eccstatus(), .rden_a(1'b1), .rden_b(1'b1)
);
defparam
	ram.numwords_a = 1 << AW, ram.widthad_a = AW, ram.width_a = 8,
	ram.numwords_b = 1 << AW, ram.widthad_b = AW, ram.width_b = 8,
	ram.address_reg_b = "CLOCK1",
	ram.clock_enable_input_a = "BYPASS", ram.clock_enable_input_b = "BYPASS",
	ram.clock_enable_output_a = "BYPASS", ram.clock_enable_output_b = "BYPASS",
	ram.indata_reg_b = "CLOCK1",
	ram.intended_device_family = "Cyclone V",
	ram.lpm_type = "altsyncram",
	ram.operation_mode = "BIDIR_DUAL_PORT",
	ram.outdata_aclr_a = "NONE", ram.outdata_aclr_b = "NONE",
	ram.outdata_reg_a = "UNREGISTERED", ram.outdata_reg_b = "UNREGISTERED",
	ram.power_up_uninitialized = "FALSE",
	ram.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
	ram.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
	ram.width_byteena_a = 1, ram.width_byteena_b = 1,
	ram.wrcontrol_wraddress_reg_b = "CLOCK1";

endmodule
