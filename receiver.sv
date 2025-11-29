module receiver #(
    parameter integer BAUD = 115200,
    parameter integer CLOCK_FREQ = 25_500_000
) (
    input logic clk,
    input logic rst_n,

    input logic start,  // receive next byte.
    output logic busy,  // goes low when received.
    output logic [7:0] data_out,

    // output logic cts_n,  // active low "clear to send"
    input logic rxd_async
);

  localparam integer BIT_PERIOD = CLOCK_FREQ / BAUD; // this does round down which matters at high speeds.

  typedef enum logic [2:0] {
    IDLE,
    START_BIT,
    WAIT_1_BIT,
    DATA_BITS,
    WAIT_1_BIT_AGAIN,
    STOP_BIT
  } state_t;

  state_t state;
  integer baud_cnt;
  logic [2:0] bit_idx;
  logic [7:0] register;

  assign busy = (state != IDLE);


  // logic rxd_async2, rxd;

  // // synchronize rxd
  // always_ff @(posedge clk or negedge rst_n) begin
  //   if (!rst_n) begin
  //     rxd_async2 <= 1'b1;
  //     rxd <= 1'b1;
  //   end else begin
  //     rxd_async2 <= rxd_async;
  //     rxd <= rxd_async2;
  //   end
  // end

  logic rxd;
  assign rxd = rxd_async;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state    <= IDLE;
      baud_cnt <= 0;
      bit_idx  <= 0;
      //   cts_n    <= 1'b1; // not clear to send
      register <= 8'd0;
    end else begin
      case (state)
        IDLE: begin
          baud_cnt <= 0;
          bit_idx  <= 0;
          if (start) begin
            // cts_n <= 1'b0;  // clear to send
            state <= START_BIT;
          end
        end

        START_BIT: begin
          if (rxd == 1'b0) begin
            baud_cnt <= baud_cnt + 1;
            if (baud_cnt == (BIT_PERIOD / 2) - 1) begin // make sure start is on for half bit period
              baud_cnt <= 0;
              state <= WAIT_1_BIT;
            end
          end else begin
            baud_cnt <= 0;
            // wait here for start bit.
          end

        end

        WAIT_1_BIT: begin
          if (baud_cnt == BIT_PERIOD - 1) begin
            baud_cnt <= 0;
            state    <= DATA_BITS;
          end else baud_cnt <= baud_cnt + 1;
        end

        DATA_BITS: begin  // starts in the middle of the first bit.
          register[bit_idx] <= rxd;

          state <= WAIT_1_BIT_AGAIN;
        end

        WAIT_1_BIT_AGAIN: begin
          if (baud_cnt == BIT_PERIOD - 2) begin
            baud_cnt <= 0;
            if (bit_idx == 3'd7) begin
              bit_idx <= 0;
              state   <= STOP_BIT;
            end else begin
              bit_idx <= bit_idx + 1;
              state   <= DATA_BITS;
            end
          end else baud_cnt <= baud_cnt + 1;
        end

        STOP_BIT: begin  // we are in the middle of the stop bit now!!!
          // should we check for the stop bit?

          data_out <= register;

          // ignoring the timing is a hack so that we can receive bytes back-to-back even if cpu takes a couple cycles to process received bytes.
          // at 1.5 Mbaud, we'll be saving ~8 cycles which is ~4 instructions of time.
          // nvm lets not ignore for now.

          if (baud_cnt == (BIT_PERIOD / 2) - 1) begin
            baud_cnt <= 0;
            state    <= IDLE;
          end else baud_cnt <= baud_cnt + 1;
        end

        default: ;
      endcase
    end
  end

endmodule



// // from claude:

// module receiver #(
//     parameter integer BAUD = 115200,
//     parameter integer CLOCK_FREQ = 25_500_000,
//     parameter integer FIFO_DEPTH = 16
// ) (
//     input logic clk,
//     input logic rst_n,

//     input logic start,  // request next byte from FIFO
//     output logic busy,  // high while waiting for byte
//     output logic [7:0] data_out,

//     input logic rxd
// );

//   localparam integer BIT_PERIOD = CLOCK_FREQ / BAUD;
//   localparam integer PTR_WIDTH = $clog2(FIFO_DEPTH);

//   // ============== FIFO ==============
//   logic [7:0] fifo[FIFO_DEPTH-1:0];
//   logic [PTR_WIDTH-1:0] wr_ptr, rd_ptr;
//   logic [PTR_WIDTH:0] count;

//   wire fifo_empty = (count == 0);
//   wire fifo_full = (count == FIFO_DEPTH);

//   // ============== RX State Machine (runs continuously) ==============
//   typedef enum logic [2:0] {
//     RX_IDLE,
//     RX_START_BIT,
//     RX_WAIT_1_BIT,
//     RX_DATA_BITS,
//     RX_WAIT_1_BIT_AGAIN,
//     RX_STOP_BIT
//   } rx_state_t;

//   rx_state_t rx_state;
//   logic [15:0] baud_cnt;
//   logic [2:0] bit_idx;
//   logic [7:0] rx_register;
//   logic rx_byte_ready;

//   // ============== Consumer State ==============
//   logic waiting_for_data;
//   logic start_prev;
//   wire start_pulse = start && !start_prev;

//   assign busy = waiting_for_data;

//   // RX state machine - continuously receives bytes
//   always_ff @(posedge clk or negedge rst_n) begin
//     if (!rst_n) begin
//       rx_state <= RX_IDLE;
//       baud_cnt <= 0;
//       bit_idx <= 0;
//       rx_register <= 8'd0;
//       rx_byte_ready <= 1'b0;
//     end else begin
//       rx_byte_ready <= 1'b0;

//       case (rx_state)
//         RX_IDLE: begin
//           baud_cnt <= 0;
//           bit_idx  <= 0;
//           if (rxd == 1'b0) begin  // start bit detected
//             rx_state <= RX_START_BIT;
//           end
//         end

//         RX_START_BIT: begin
//           if (rxd == 1'b0) begin
//             baud_cnt <= baud_cnt + 1;
//             if (baud_cnt == (BIT_PERIOD / 2) - 1) begin
//               baud_cnt <= 0;
//               rx_state <= RX_WAIT_1_BIT;
//             end
//           end else begin
//             baud_cnt <= 0;
//             rx_state <= RX_IDLE;  // false start
//           end
//         end

//         RX_WAIT_1_BIT: begin
//           if (baud_cnt == BIT_PERIOD - 1) begin
//             baud_cnt <= 0;
//             rx_state <= RX_DATA_BITS;
//           end else baud_cnt <= baud_cnt + 1;
//         end

//         RX_DATA_BITS: begin
//           rx_register[bit_idx] <= rxd;
//           rx_state <= RX_WAIT_1_BIT_AGAIN;
//         end

//         RX_WAIT_1_BIT_AGAIN: begin
//           if (baud_cnt == BIT_PERIOD - 2) begin
//             baud_cnt <= 0;
//             if (bit_idx == 3'd7) begin
//               bit_idx  <= 0;
//               rx_state <= RX_STOP_BIT;
//             end else begin
//               bit_idx  <= bit_idx + 1;
//               rx_state <= RX_DATA_BITS;
//             end
//           end else baud_cnt <= baud_cnt + 1;
//         end

//         RX_STOP_BIT: begin
//           if (baud_cnt == (BIT_PERIOD / 2) - 1) begin
//             baud_cnt <= 0;
//             rx_state <= RX_IDLE;
//             rx_byte_ready <= 1'b1;
//           end else baud_cnt <= baud_cnt + 1;
//         end

//         default: rx_state <= RX_IDLE;
//       endcase
//     end
//   end

//   // FIFO and consumer logic
//   always_ff @(posedge clk or negedge rst_n) begin
//     if (!rst_n) begin
//       wr_ptr <= 0;
//       rd_ptr <= 0;
//       count <= 0;
//       waiting_for_data <= 1'b0;
//       data_out <= 8'd0;
//       start_prev <= 1'b0;
//     end else begin
//       start_prev <= start;

//       // Handle incoming byte from UART
//       if (rx_byte_ready) begin
//         if (waiting_for_data && fifo_empty) begin
//           // consumer waiting and FIFO empty: deliver directly
//           data_out <= rx_register;
//           waiting_for_data <= 1'b0;
//         end else if (!fifo_full) begin
//           // push to FIFO
//           fifo[wr_ptr] <= rx_register;
//           wr_ptr <= wr_ptr + 1;
//           count <= count + 1;
//         end
//         // if FIFO full and no one waiting: byte lost
//       end

//       // Handle consumer request (edge-triggered)
//       if (start_pulse && !waiting_for_data) begin
//         waiting_for_data <= 1'b1;
//       end

//       // Fulfill waiting request from FIFO (only when no new byte arriving)
//       if (waiting_for_data && !fifo_empty && !rx_byte_ready) begin
//         data_out <= fifo[rd_ptr];
//         rd_ptr <= rd_ptr + 1;
//         count <= count - 1;
//         waiting_for_data <= 1'b0;
//       end
//     end
//   end

// endmodule
