`default_nettype none

module loader #(
    parameter integer PROG_ADDR_WIDTH,
    parameter integer PROG_LEN
) (
    input logic clk,
    input logic resetn,
    // input logic load_req,

    output logic                       prog_we,
    output logic [PROG_ADDR_WIDTH-1:0] prog_addr,
    output logic [                7:0] prog_wr,
    output logic                       loaded
);

  typedef enum logic [1:0] {
    IDLE,
    LOADING,
    DONE
  } state_t;

  logic [1:0] state;

  // logic [23:0] ram_wakeup_wait;
  logic [8:0] ram_wakeup_wait;  // i can't find any documentation suggesting spram needs this. so idk.

  // always_comb begin
  //   `include "prog_rom.sv"
  // end

  always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      state <= IDLE;
      prog_we <= '0;
      prog_addr <= '0;
      loaded <= '0;
      // ram_wakeup_wait <= '0;
    end else begin

      prog_we <= 1'b0;  // default

      case (state)
        IDLE: begin
          prog_we <= 1'b0;
          loaded  <= 1'b0;

          if (ram_wakeup_wait == '1) begin  // ram takes a couple moments to be ready.
            prog_addr <= '0;
            state <= LOADING;
          end else ram_wakeup_wait <= ram_wakeup_wait + 1;
        end

        LOADING: begin
          prog_we <= 1'b1;

          // possibly use bram here with initial file. copy into sram? or maybe just store prog in bram?

          `include "prog_rom.sv"

          if (prog_addr == PROG_LEN) state <= DONE;

          prog_addr <= prog_addr + 1;
        end

        DONE: begin
          loaded <= 1'b1;
          state  <= DONE;
        end

        default: begin
          state <= IDLE;
        end
      endcase
    end
  end

endmodule
