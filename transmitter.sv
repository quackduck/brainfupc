module transmitter #(
    parameter integer BAUD = 115200,
    parameter integer CLOCK_FREQ = 25_500_000
) (
    input logic clk,
    input logic rst_n,

    input logic start,
    output logic busy,
    input logic [7:0] data_in,

    // input  logic rts_n,  // active low "request to send"
    output logic txd
);

  localparam integer BIT_PERIOD = CLOCK_FREQ / BAUD;

  typedef enum logic [1:0] {
    IDLE,
    START_BIT,
    DATA_BITS,
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
      txd      <= 1'b1;
    end else begin
      case (state)
        IDLE: begin
          txd <= 1'b1;
          baud_cnt <= 0;
          bit_idx <= 0;
          //   if (start && !rts_n) begin
          if (start) begin
            register <= data_in;
            state <= START_BIT;
          end
        end

        START_BIT: begin
          txd <= 1'b0;

          if (baud_cnt == BIT_PERIOD - 1) begin
            baud_cnt <= 0;
            state    <= DATA_BITS;
          end else baud_cnt <= baud_cnt + 1;
        end

        DATA_BITS: begin
          txd <= register[bit_idx];

          if (baud_cnt == BIT_PERIOD - 1) begin
            baud_cnt <= 0;
            if (bit_idx == 3'd7) begin
              bit_idx <= 0;
              state   <= STOP_BIT;
            end else begin
              bit_idx <= bit_idx + 1;
            end
          end else baud_cnt <= baud_cnt + 1;
        end

        STOP_BIT: begin
          txd <= 1'b1;

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
