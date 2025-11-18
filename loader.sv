`default_nettype none

module loader #(
    parameter integer PROG_ADDR_WIDTH,
    parameter integer PROG_LEN
) (
    input wire clk,
    input wire resetn,
    input wire load_req,

    output logic                       prog_we,
    output logic [PROG_ADDR_WIDTH-1:0] prog_addr,
    output logic [                7:0] prog_wr,
    output logic                       loaded
);

  typedef enum logic [1:0] {
    IDLE    = 2'b00,
    LOADING = 2'b01,
    DONE    = 2'b10
  } state_t;

  logic [1:0] state;

  always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      state <= IDLE;
      prog_we <= 1'b0;
      prog_addr <= {PROG_ADDR_WIDTH{1'b0}};
      prog_wr <= 8'h00;
      loaded <= 1'b0;
    end else begin
      case (state)
        IDLE: begin
          prog_we <= 1'b0;
          loaded  <= 1'b0;

          if (load_req) begin
            prog_addr <= {PROG_ADDR_WIDTH{1'b0}};
            state <= LOADING;
          end
        end

        LOADING: begin
          prog_we <= 1'b1;

          `include "prog_rom.sv"

          if (prog_addr == PROG_LEN) begin
            state   <= DONE;
            prog_we <= 1'b0;
            loaded  <= 1'b1;
          end else begin
            prog_addr <= prog_addr + 1;
          end
        end

        DONE: begin
        end

        default: begin
          state <= IDLE;
        end
      endcase
    end
  end

endmodule
