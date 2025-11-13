module seven_seg_hex (
    input [3:0] din,
    output reg [6:0] dout
);
  always @*
    case (din)
      4'h0: dout = 7'b0111111;
      4'h1: dout = 7'b0000110;
      4'h2: dout = 7'b1011011;
      4'h3: dout = 7'b1001111;
      4'h4: dout = 7'b1100110;
      4'h5: dout = 7'b1101101;
      4'h6: dout = 7'b1111101;
      4'h7: dout = 7'b0000111;
      4'h8: dout = 7'b1111111;
      4'h9: dout = 7'b1101111;
      4'hA: dout = 7'b1110111;
      4'hB: dout = 7'b1111100;
      4'hC: dout = 7'b0111001;
      4'hD: dout = 7'b1011110;
      4'hE: dout = 7'b1111001;
      4'hF: dout = 7'b1110001;
      default: dout = 7'b1000000;
    endcase
endmodule
