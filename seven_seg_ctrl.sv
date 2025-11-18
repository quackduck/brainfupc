module seven_seg_ctrl (
    input CLK,
    input [7:0] din,
    output logic [7:0] dout
);
  logic [6:0] lsb_digit;
  logic [6:0] msb_digit;

  seven_seg_hex msb_nibble (
      .din (din[7:4]),
      .dout(msb_digit)
  );

  seven_seg_hex lsb_nibble (
      .din (din[3:0]),
      .dout(lsb_digit)
  );

  logic [9:0] clkdiv = 0;
  logic clkdiv_pulse = 0;
  logic msb_not_lsb = 0;

  always @(posedge CLK) begin
    clkdiv <= clkdiv + 1;
    clkdiv_pulse <= &clkdiv;
    msb_not_lsb <= msb_not_lsb ^ clkdiv_pulse;

    if (clkdiv_pulse) begin
      if (msb_not_lsb) begin
        dout[6:0] <= ~msb_digit;
        dout[7]   <= 0;
      end else begin
        dout[6:0] <= ~lsb_digit;
        dout[7]   <= 1;
      end
    end
  end
endmodule
