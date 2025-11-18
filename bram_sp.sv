`default_nettype none
module bram_sp #(
    parameter int ADDR_WIDTH = 10,
    parameter int DATA_WIDTH = 8
) (
    input  logic                  clk,
    input  logic                  write_enable,
    input  logic [ADDR_WIDTH-1:0] addr,
    input  logic [DATA_WIDTH-1:0] data_in,
    output logic [DATA_WIDTH-1:0] data_out
);
  reg [DATA_WIDTH-1:0] mem[0:(1<<ADDR_WIDTH)-1];

  always @(posedge clk) begin
    if (write_enable) mem[addr] <= data_in;
    data_out <= mem[addr];  // synchronous read: data available next cycle
  end
endmodule
