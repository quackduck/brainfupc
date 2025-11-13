`default_nettype none
module top (
    input  CLK,
    input  BTN_N,  // reset (active low)
    input  BTN1,   // run/once
    input  BTN2,   // debug change
    input  BTN3,   // load program
    output LED1,
    output LED2,
    output LED3,
    output LED4,
    output LED5,
    output P1A1,
    P1A2,
    P1A3,
    P1A4,
    P1A7,
    P1A8,
    P1A9,
    P1A10
);
  wire [7:0] seven_segment;
  assign {P1A10, P1A9, P1A8, P1A7, P1A4, P1A3, P1A2, P1A1} = seven_segment;

  // debounced signals
  wire db_btn1, db_btn2, db_btn3;
  debounce #(
      .CTR_WIDTH(18)
  ) db1 (
      .clk  (CLK),
      .noisy(BTN1),
      .clean(db_btn1)
  );
  debounce #(
      .CTR_WIDTH(18)
  ) db2 (
      .clk  (CLK),
      .noisy(BTN2),
      .clean(db_btn2)
  );
  debounce #(
      .CTR_WIDTH(18)
  ) db3 (
      .clk  (CLK),
      .noisy(BTN3),
      .clean(db_btn3)
  );

  wire loaded;
  wire [4:0] state_id;
  wire [7:0] display_value;
  wire executing;

  // reg [21:0] slow_clk = 0;

  // always @(posedge CLK) begin
  //   slow_clk <= slow_clk + 1;
  // end

  // edge detectors -> single-cycle pulses
  reg db_btn1_last = 0, db_btn2_last = 0, db_btn3_last = 0;
  wire btn1_pulse = db_btn1 & ~db_btn1_last;
  wire btn2_pulse = db_btn2 & ~db_btn2_last;
  wire btn3_pulse = db_btn3 & ~db_btn3_last;
  // always @(posedge slow_clk[21]) begin
  always @(posedge CLK) begin
    db_btn1_last <= db_btn1;
    db_btn2_last <= db_btn2;
    db_btn3_last <= db_btn3;
  end


  // // sim:
  // wire btn3_pulse = db_btn3;  // direct connection
  // wire btn1_pulse = db_btn1;  // direct connection

  wire resetn = BTN_N;  // BTN_N active low, treat as active-high resetn

  cpu_core core (
      .clk      (CLK),
      // .clk      (slow_clk[21]),  // slow clock for visibility
      .resetn   (resetn),
      .start_req(btn1_pulse),
      .step_req (btn2_pulse),
      .load_req (btn3_pulse),
      .loaded   (loaded),
      .executing(executing),
      .state_id (state_id),
      .display  (display_value)
  );

  // status leds
  assign LED1 = ~(state_id == 3'd0);  // IDLE
  assign LED2 = (state_id == 3'd1);  // LOAD
  assign LED3 = (state_id == 3'd2);  // PREPROCESS (unused now)
  assign LED4 = executing;  // in execution
  assign LED5 = loaded;

  // seven-seg
  seven_seg_ctrl ssc (
      .CLK (CLK),
      .din (display_value),
      .dout(seven_segment)
  );
endmodule
