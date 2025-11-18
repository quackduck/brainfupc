`default_nettype none
module debounce #(
    parameter int CTR_WIDTH = 16  // number of bits in counter: sets debounce time
) (
    input  logic clk,
    input  logic noisy,  // raw button signal (active high)
    output logic clean   // stable debounced output
);

  // // for sim, just pass through
  // always @(posedge clk) begin
  //   clean <= noisy;
  // end

  logic [CTR_WIDTH-1:0] counter = 0;
  logic sync_0 = 0, sync_1 = 0;

  // 2-FF synchronizer to avoid metastability
  always @(posedge clk) begin
    sync_0 <= noisy;
    sync_1 <= sync_0;
  end

  // debounce counter
  always @(posedge clk) begin
    if (sync_1 == clean) counter <= 0;  // stable, reset counter
    else begin
      counter <= counter + 1;  // input differs, increment counter
      if (&counter)  // when counter overflows (all 1’s)
        clean <= sync_1;  // accept new value
    end
  end
endmodule
