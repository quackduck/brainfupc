// `default_nettype none

// module top (
//     input wire clk,  // 12MHz system clock on iCEBreaker
//     input wire resetn,  // Active-low reset (use button if wired)
//     output reg led,  // LED to indicate test success (connect to one of the user LEDs, e.g., pin 9)
//     output wire psram_cs_n,
//     output wire psram_clk,
//     inout wire [3:0] psram_sio
// );

//   // PSRAM pins using SB_IO for bidirectional control
//   wire [3:0] sio_out;
//   wire [3:0] sio_oe;
//   wire [3:0] sio_in;

//   genvar i;
//   generate
//     for (i = 0; i < 4; i = i + 1) begin : sio_gen
//       SB_IO #(
//           .PIN_TYPE(6'b1010_01),  // Input registered, output tri-state
//           .PULLUP  (1'b0)
//       ) sio_io (
//           .PACKAGE_PIN(psram_sio[i]),
//           .OUTPUT_ENABLE(sio_oe[i]),
//           .D_OUT_0(sio_out[i]),
//           .D_IN_0(sio_in[i])
//       );
//     end
//   endgenerate

//   assign psram_clk = clk;  // Use system clock (12MHz, safe for PSRAM)

//   reg cs_n_reg;
//   assign psram_cs_n = cs_n_reg;

//   // FSM states
//   localparam S_IDLE = 0;
//   localparam S_POWERUP_WAIT = 1;
//   localparam S_RESET_EN = 2;
//   localparam S_RESET = 3;
//   localparam S_ENTER_QPI = 4;
//   localparam S_WRITE_CMD = 5;
//   localparam S_WRITE_ADDR = 6;
//   localparam S_WRITE_DATA = 7;
//   localparam S_READ_CMD = 8;
//   localparam S_READ_ADDR = 9;
//   localparam S_DUMMY = 10;
//   localparam S_READ_DATA = 11;
//   localparam S_DONE = 12;

//   reg [ 3:0] state = S_IDLE;
//   reg [15:0] counter = 0;  // General purpose counter (for delays, bit counts)
//   reg [ 7:0] shift_reg = 0;
//   reg [ 2:0] bit_cnt = 0;  // Bits per clock (1 for SPI, 4 for QPI)
//   reg [23:0] addr = 24'h000000;
//   reg [ 7:0] data_wr = 8'hA5;  // Test data to write
//   reg [ 7:0] data_rd = 0;  // Read data

//   reg [ 3:0] sio_oe_reg = 0;
//   reg [ 3:0] sio_out_reg = 0;

//   assign sio_oe  = sio_oe_reg;
//   assign sio_out = sio_out_reg;

//   always @(posedge clk or negedge resetn) begin
//     if (!resetn) begin
//       state <= S_POWERUP_WAIT;
//       cs_n_reg <= 1'b1;
//       sio_oe_reg <= 4'b0000;
//       sio_out_reg <= 4'b0000;
//       counter <= 16'd1800;  // ~150us at 12MHz (12e6 * 150e-6 = 1800)
//       led <= 1'b0;
//       data_rd <= 8'h00;
//     end else begin
//       case (state)
//         S_POWERUP_WAIT: begin
//           cs_n_reg <= 1'b1;
//           if (counter == 0) begin
//             state <= S_RESET_EN;
//           end else begin
//             counter <= counter - 1;
//           end
//         end

//         S_RESET_EN: begin
//           cs_n_reg <= 1'b0;
//           shift_reg <= 8'h66;  // Reset enable
//           bit_cnt <= 3'd1;  // SPI mode
//           sio_oe_reg <= 4'b0001;  // Only SIO0 output
//           counter <= 8;  // 8 bits
//           state <= S_RESET;
//         end

//         S_RESET: begin
//           if (counter == 0) begin
//             cs_n_reg <= 1'b1;
//             counter <= 10;  // Short delay
//             state <= S_RESET_EN;  // Send second command 0x99
//             shift_reg <= 8'h99;  // Reset
//           end else begin
//             sio_out_reg[0] <= shift_reg[7];
//             shift_reg <= {shift_reg[6:0], 1'b0};
//             counter <= counter - 1;
//           end
//         end

//         // After reset, send 0x35 in SPI to enter QPI
//         S_ENTER_QPI: begin
//           cs_n_reg <= 1'b0;
//           shift_reg <= 8'h35;
//           bit_cnt <= 3'd1;
//           sio_oe_reg <= 4'b0001;
//           counter <= 8;
//           state <= S_RESET;  // Reuse shift logic, but update to next state after
//           // Note: After this, state to S_WRITE_CMD
//         end

//         S_WRITE_CMD: begin
//           cs_n_reg <= 1'b0;
//           shift_reg <= 8'h38;  // Quad write command
//           bit_cnt <= 3'd4;  // QPI mode
//           sio_oe_reg <= 4'b1111;  // Quad output
//           counter <= 2;  // 8 bits / 4 = 2 clocks
//           state <= S_WRITE_ADDR;
//         end

//         S_WRITE_ADDR: begin
//           if (counter == 0) begin
//             counter <= 6;  // 24 bits / 4 = 6 clocks
//             state   <= S_WRITE_DATA;
//           end else begin
//             sio_out_reg <= addr[23:20];  // MSB first
//             addr <= {addr[19:0], 4'b0000};
//             counter <= counter - 1;
//           end
//         end

//         S_WRITE_DATA: begin
//           if (counter == 0) begin
//             cs_n_reg <= 1'b1;
//             counter <= 10;  // Delay
//             state <= S_READ_CMD;
//           end else begin
//             sio_out_reg <= data_wr[7:4];  // High nibble first
//             data_wr <= {data_wr[3:0], 4'b0000};
//             counter <= counter - 1;
//             if (counter == 1) begin
//               sio_out_reg <= data_wr[3:0];
//             end
//           end
//         end

//         S_READ_CMD: begin
//           cs_n_reg <= 1'b0;
//           shift_reg <= 8'hEB;  // Quad read command
//           bit_cnt <= 3'd4;
//           sio_oe_reg <= 4'b1111;
//           counter <= 2;  // 8 bits / 4
//           state <= S_READ_ADDR;
//           addr <= 24'h000000;  // Reset addr for read
//         end

//         S_READ_ADDR: begin
//           if (counter == 0) begin
//             counter <= 6;  // 24 bits dummy
//             sio_oe_reg <= 4'b0000;  // Input mode
//             state <= S_DUMMY;
//           end else begin
//             sio_out_reg <= addr[23:20];
//             addr <= {addr[19:0], 4'b0000};
//             counter <= counter - 1;
//           end
//         end

//         S_DUMMY: begin
//           if (counter == 0) begin
//             counter <= 2;  // 8 bits data / 4
//             state   <= S_READ_DATA;
//           end else begin
//             counter <= counter - 1;
//           end
//         end

//         S_READ_DATA: begin
//           if (counter == 0) begin
//             cs_n_reg <= 1'b1;
//             state <= S_DONE;
//           end else begin
//             if (counter == 2) begin
//               data_rd[7:4] <= sio_in;
//             end else if (counter == 1) begin
//               data_rd[3:0] <= sio_in;
//             end
//             counter <= counter - 1;
//           end
//         end

//         S_DONE: begin
//           if (data_rd == 8'hA5) begin
//             led <= 1'b1;
//           end else begin
//             led <= 1'b0;
//           end
//           state <= S_IDLE;
//         end

//         default: state <= S_IDLE;
//       endcase
//     end
//   end

// endmodule






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

  reg [21:0] slow_clk = 0;

  always @(posedge CLK) begin
    slow_clk <= slow_clk + 1;
  end

  // integer slowdown = 0;

  // edge detectors -> single-cycle pulses
  reg db_btn1_last = 0, db_btn2_last = 0, db_btn3_last = 0;
  wire btn1_pulse = db_btn1 & ~db_btn1_last;
  wire btn2_pulse = db_btn2 & ~db_btn2_last;
  wire btn3_pulse = db_btn3 & ~db_btn3_last;
  // always @(posedge slow_clk[slowdown]) begin
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
      .time_reg (slow_clk),
      // .clk      (slow_clk[slowdown]),  // slow clock for visibility
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
