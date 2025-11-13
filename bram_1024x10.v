// module bram_1024x10 (
//     input clk,
//     input write_enable,
//     input [9:0] addr,
//     input [9:0] data_in,
//     output reg [9:0] data_out
// );
//   (* ram_style = "block" *)
//   reg [9:0] ram[0:1023];

//   integer i;
//   initial begin
//     for (i = 0; i < 1024; i = i + 1) begin
//       ram[i] = 10'h000;
//     end
//   end

//   always @(posedge clk) begin
//     if (write_enable) begin
//       ram[addr] <= data_in;
//     end
//     data_out <= ram[addr];
//   end
// endmodule
