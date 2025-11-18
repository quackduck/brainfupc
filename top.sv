`default_nettype none
module top (
    // input  CLK,
    input  clk12,
    input  BTN_N,  // reset (active low)
    input  BTN1,   // run/once
    input  BTN2,   // debug change
    input  BTN3,   // load program
    output LED1,
    output LED2,
    output LED3,
    output LED4,
    output LED5,

    output vga_h_sync,
    output vga_v_sync,
    output logic [3:0] r,
    output logic [3:0] g,
    output logic [3:0] b

    // output P1A1,
    // P1A2,
    // P1A3,
    // P1A4,
    // P1A7,
    // P1A8,
    // P1A9,
    // P1A10
);
  wire clk_pixel;

  SB_PLL40_PAD #(
      .FEEDBACK_PATH("SIMPLE"),
      .DIVR(4'b0000),
      .DIVF(7'b1000011),
      .DIVQ(3'b101),
      .FILTER_RANGE(3'b001)
  ) pll (
      .PACKAGEPIN(clk12),
      .PLLOUTCORE(clk_pixel),
      .RESETB(1'b1),
      .BYPASS(1'b0)
  );

  //   wire [7:0] seven_segment;
  //   assign {P1A10, P1A9, P1A8, P1A7, P1A4, P1A3, P1A2, P1A1} = seven_segment;

  // debounced signals
  wire db_btn1, db_btn2, db_btn3;
  debounce #(
      .CTR_WIDTH(18)
  ) db1 (
      .clk  (clk_pixel),
      .noisy(BTN1),
      .clean(db_btn1)
  );
  debounce #(
      .CTR_WIDTH(18)
  ) db2 (
      .clk  (clk_pixel),
      .noisy(BTN2),
      .clean(db_btn2)
  );
  debounce #(
      .CTR_WIDTH(18)
  ) db3 (
      .clk  (clk_pixel),
      .noisy(BTN3),
      .clean(db_btn3)
  );

  wire loaded;
  wire [4:0] state_id;
  wire [7:0] display_value;
  wire executing;

  logic [21:0] slow_clk = 0;

  always @(posedge clk_pixel) begin
    slow_clk <= slow_clk + 1;
  end

  // integer slowdown = 0;

  // edge detectors -> single-cycle pulses
  logic db_btn1_last = 0, db_btn2_last = 0, db_btn3_last = 0;
  wire btn1_pulse = db_btn1 & ~db_btn1_last;
  wire btn2_pulse = db_btn2 & ~db_btn2_last;
  wire btn3_pulse = db_btn3 & ~db_btn3_last;
  // always @(posedge slow_clk[slowdown]) begin
  always @(posedge clk_pixel) begin
    db_btn1_last <= db_btn1;
    db_btn2_last <= db_btn2;
    db_btn3_last <= db_btn3;
  end


  // // sim:
  // wire btn3_pulse = db_btn3;  // direct connection
  // wire btn1_pulse = db_btn1;  // direct connection

  wire resetn = BTN_N;  // BTN_N active low, treat as active-high resetn


  logic [13:0] vga_data_addr;
  logic [7:0] vga_cell;

  cpu_core core (
      .clk          (clk_pixel),
      .vga_data_addr(vga_data_addr),
      .vga_cell     (vga_cell),
      //   .time_reg (slow_clk),
      // .clk      (slow_clk[slowdown]),  // slow clock for visibility
      .resetn       (resetn),
      .start_req    (btn1_pulse),
      .step_req     (btn2_pulse),
      .load_req     (btn3_pulse),
      .loaded       (loaded),
      .executing    (executing),
      .state_id     (state_id),
      .display      (display_value)
  );

  // status leds
  assign LED1 = ~(state_id == 5'd0);  // IDLE
  // assign LED2 = (state_id == 3'd1);  // LOAD
  assign LED2 = (state_id == 5'd17);  // STEP WAIT
  assign LED3 = (state_id == 5'd2);  // PREPROCESS (unused now)
  assign LED4 = executing;  // in execution
  assign LED5 = loaded;

  //   // seven-seg
  //   seven_seg_ctrl ssc (
  //       .CLK (CLK),
  //       .din (display_value),
  //     //   .dout(seven_segment)
  //   );

  wire inDisplayArea;
  wire [9:0] CounterX;  // 640
  wire [9:0] CounterY;  // 480

  hvsync_generator syncgen (
      .clk(clk_pixel),
      .vga_h_sync(vga_h_sync),
      .vga_v_sync(vga_v_sync),
      .inDisplayArea(inDisplayArea),
      .CounterX(CounterX),
      .CounterY(CounterY)
  );

  always @(posedge clk_pixel) begin
    vga_data_addr <= {CounterY[9:3], CounterX[9:3]};  // uhhh idk
  end

  always @(posedge clk_pixel) begin
    // if (inDisplayArea) {vga_R, vga_G, vga_B} <= {fb_pixel, fb_pixel, fb_pixel};
    // else {vga_R, vga_G, vga_B} <= 3'b000;

    if (inDisplayArea) begin
      //   vga_R <= frame_counter[21];
      //   vga_G <= frame_counter[22];
      //   vga_B <= fb_pixel;

      //   {vga_R, vga_G, vga_B} <= frame_counter[13:11] + {2'b0, fb_pixel};
      //   {vga_R, vga_G, vga_B} <= CounterX[5:3] + CounterY[5:3];
      //   {r, g, b} <= {CounterX[5:2], CounterY[5:2], CounterX[8:5]};
      //   r <= CounterX[5:2];
      //   g <= CounterY[5:2];
      //   b <= CounterX[8:5];

      r <= vga_cell[7:4];
      g <= vga_cell[3:0];
      b <= 4'b0000;

    end else begin
      r <= 4'b0000;
      g <= 4'b0000;
      b <= 4'b0000;
    end
  end


endmodule
