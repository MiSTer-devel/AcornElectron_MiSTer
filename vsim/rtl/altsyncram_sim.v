// Behavioural altsyncram for the Verilator sim: just enough for
// sys/sd_card.sv's true dual-port sector buffer (registered addresses,
// unregistered outputs, both ports the same width). Not used by Quartus.
module altsyncram #(
	parameter numwords_a = 2048, widthad_a = 11, width_a = 8,
	parameter numwords_b = 2048, widthad_b = 11, width_b = 8,
	parameter address_reg_b = "CLOCK1",
	parameter clock_enable_input_a = "BYPASS", clock_enable_input_b = "BYPASS",
	parameter clock_enable_output_a = "BYPASS", clock_enable_output_b = "BYPASS",
	parameter indata_reg_b = "CLOCK1", intended_device_family = "Cyclone V",
	parameter lpm_type = "altsyncram", operation_mode = "BIDIR_DUAL_PORT",
	parameter outdata_aclr_a = "NONE", outdata_aclr_b = "NONE",
	parameter outdata_reg_a = "UNREGISTERED", outdata_reg_b = "UNREGISTERED",
	parameter power_up_uninitialized = "FALSE",
	parameter read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
	parameter read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
	parameter width_byteena_a = 1, width_byteena_b = 1,
	parameter wrcontrol_wraddress_reg_b = "CLOCK1"
)(
	input                      clock0,
	input      [widthad_a-1:0] address_a,
	input        [width_a-1:0] data_a,
	input                      wren_a,
	output reg   [width_a-1:0] q_a,
	input                      clock1,
	input      [widthad_b-1:0] address_b,
	input        [width_b-1:0] data_b,
	input                      wren_b,
	output reg   [width_b-1:0] q_b,
	input aclr0, aclr1, addressstall_a, addressstall_b, byteena_a, byteena_b,
	input clocken0, clocken1, clocken2, clocken3, rden_a, rden_b,
	output eccstatus
);
reg [width_a-1:0] mem [0:numwords_a-1];
always @(posedge clock0) begin
	if (wren_a) mem[address_a] <= data_a;
	q_a <= wren_a ? data_a : mem[address_a];
end
always @(posedge clock1) begin
	if (wren_b) mem[address_b] <= data_b;
	q_b <= wren_b ? data_b : mem[address_b];
end
assign eccstatus = 1'b0;
endmodule
