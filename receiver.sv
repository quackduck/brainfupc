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
    input logic rxd
);

  localparam integer BIT_PERIOD = CLOCK_FREQ / BAUD;

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

        STOP_BIT: begin
          // should we check for the stop bit?

          data_out <= register;

          if (baud_cnt == BIT_PERIOD - 1) begin
            baud_cnt <= 0;
            state    <= IDLE;
          end else baud_cnt <= baud_cnt + 1;
        end

        default: ;
      endcase
    end
  end

endmodule
