module hvsync_generator (
    input wire clk,  // 25.175 MHz pixel clock

    output reg       vga_h_sync,
    output reg       vga_v_sync,
    output reg       inDisplayArea,
    output reg [9:0] CounterX,
    output reg [9:0] CounterY        // Changed to 10 bits for consistency
);

  // VGA 640x480 @ 60Hz timing parameters
  // Horizontal timing (pixels)
  localparam H_VISIBLE = 640;
  localparam H_FRONT = 16;
  localparam H_SYNC = 96;
  localparam H_BACK = 48;
  localparam H_TOTAL = H_VISIBLE + H_FRONT + H_SYNC + H_BACK;  // 800

  // Vertical timing (lines)
  localparam V_VISIBLE = 480;
  localparam V_FRONT = 10;
  localparam V_SYNC = 2;
  localparam V_BACK = 33;
  localparam V_TOTAL = V_VISIBLE + V_FRONT + V_SYNC + V_BACK;  // 525

  // Calculated sync pulse positions
  localparam H_SYNC_START = H_VISIBLE + H_FRONT;  // 656
  localparam H_SYNC_END = H_SYNC_START + H_SYNC;  // 752
  localparam V_SYNC_START = V_VISIBLE + V_FRONT;  // 490
  localparam V_SYNC_END = V_SYNC_START + V_SYNC;  // 492

  //////////////////////////////////////////////////
  //   reg [9:0] CounterX;
  //   reg [9:0] CounterY;

  // Counter logic - symmetric for both X and Y
  wire CounterXmaxed = (CounterX == H_TOTAL - 1);
  wire CounterYmaxed = (CounterY == V_TOTAL - 1);

  always @(posedge clk) begin
    if (CounterXmaxed) CounterX <= 0;
    else CounterX <= CounterX + 1;
  end

  always @(posedge clk) begin
    if (CounterXmaxed) begin
      if (CounterYmaxed) CounterY <= 0;
      else CounterY <= CounterY + 1;
    end
  end

  // Sync pulse generation - symmetric structure
  reg vga_HS, vga_VS;

  always @(posedge clk) begin
    vga_HS <= (CounterX >= H_SYNC_START) && (CounterX < H_SYNC_END);
    vga_VS <= (CounterY >= V_SYNC_START) && (CounterY < V_SYNC_END);
  end

  // Display area - when we're in visible region
  //   reg inDisplayArea;
  always @(posedge clk) begin
    inDisplayArea <= (CounterX < H_VISIBLE) && (CounterY < V_VISIBLE);
  end

  // VGA uses negative sync pulses
  assign vga_h_sync = ~vga_HS;
  assign vga_v_sync = ~vga_VS;

endmodule
