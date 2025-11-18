`default_nettype none
module cpu_core #(
    parameter int PROG_ADDR_WIDTH = 14,
    parameter logic [PROG_ADDR_WIDTH-1:0] PROG_LEN = 16383
) (
    input logic clk,

    input  logic [13:0] vga_data_addr,
    output logic [ 7:0] vga_cell,

    input logic resetn,
    input logic start_req,
    input logic step_req,
    input logic load_req,

    output logic       loaded,
    output logic       executing,
    output logic [4:0] state_id,
    output logic [7:0] display
);
  typedef enum logic [4:0] {
    S_IDLE,

    // preprocess states
    S_PRE_ADDR,
    S_PRE_READ,
    S_PRE_STACK_WAIT,
    S_PRE_STACK_READ,
    S_PRE_JUMP_W1,
    S_PRE_JUMP_DONE,

    // running
    S_EXEC_WAIT,
    S_EXECUTE,

    // writeback
    S_PTR_WRITEBACK,
    S_STEP_WAIT,
    S_PTR_READ_SETUP,
    S_PTR_READ_WAIT,
    S_ZERO_DATA,
    S_PTR_READ_LATCH

  } state_t;

  logic [               31:0] exec_count;

  logic [PROG_ADDR_WIDTH-1:0] iptr;  // owned by cpu
  logic [                7:0] prog_rd;  // owned by cpu

  logic [               15:0] _prog_rd;
  assign prog_rd = _prog_rd[7:0];  // only lower 8 bits used.

  logic [PROG_ADDR_WIDTH-1:0] loader_addr;  // owned by loader
  logic [                7:0] prog_wr;  // owned by loader
  logic                       prog_we;  // owned by loader

  spram program_memory (
      .clk(clk),
      .we(prog_we ? 4'b1111 : 4'b0000),
      .addr(loaded ? iptr : loader_addr),
      .data_in({8'h00, prog_wr}),
      .data_out(_prog_rd)
  );

  loader #(
      .PROG_ADDR_WIDTH(PROG_ADDR_WIDTH),
      .PROG_LEN(PROG_LEN)
  ) loader_inst (
      .clk(clk),
      .resetn(resetn),
      .load_req(load_req),

      .prog_we(prog_we),
      .prog_addr(loader_addr),
      .prog_wr(prog_wr),
      .loaded(loaded)
  );

  // brainfuck data tape
  logic [PROG_ADDR_WIDTH-1:0] dptr;
  logic [                7:0] data_wr;
  logic                       data_we;
  // logic [               15:0] _data_rd;
  logic [                7:0] data_rd;

  // Dual-port BRAM just for data tape so we can display.
  (* syn_ramstyle = "block_ram" *)
  logic [                7:0] data_mem[0:4096-1];  // unfortunately limited by bram...


  // Port A: CPU side (read/write) // todo: maybe switch this to save on CPU cycles? we dont care too much about vga.
  always_ff @(posedge clk) begin
    if (data_we) data_mem[dptr] <= data_wr;
    data_rd <= data_mem[dptr];
  end

  // Port B: VGA read-only
  logic [7:0] vga_cell_reg;
  assign vga_cell = data_mem[vga_data_addr];

  logic [                7:0] current_cell;  // cached data cell
  logic [PROG_ADDR_WIDTH-1:0] dptr_next;

  // bracket stack, stores addresses of [ to match up with ]. we could save half the memory by noticing that the stack can never store more than (prog_len/2) addresses
  logic [PROG_ADDR_WIDTH-1:0] stack_wr;
  logic                       stack_we;
  logic [               15:0] _stack_rd;
  logic [PROG_ADDR_WIDTH-1:0] stack_rd;
  assign stack_rd = _stack_rd[PROG_ADDR_WIDTH-1:0];

  logic [PROG_ADDR_WIDTH-1:0] stack_ptr;  // at most half the program is [

  spram bracket_stack (
      .clk(clk),
      .we(stack_we ? 4'b1111 : 4'b0000),
      .addr(stack_ptr),
      .data_in({{(16 - PROG_ADDR_WIDTH) {1'b0}}, stack_wr}),
      .data_out(_stack_rd)  // only lower PROG_ADDR_WIDTH bits used
  );

  // jump table stores address of matching bracket for each bracket.
  logic [PROG_ADDR_WIDTH-1:0] jump_addr_reg;
  logic [PROG_ADDR_WIDTH-1:0] jump_wr;
  logic                       jump_we;
  logic [PROG_ADDR_WIDTH-1:0] jump_rd;

  logic [               15:0] _jump_rd;
  assign jump_rd = _jump_rd[PROG_ADDR_WIDTH-1:0];

  spram jump_table (
      .clk(clk),
      .we(jump_we ? 4'b1111 : 4'b0000),
      .addr(jump_addr_reg),
      .data_in({{(16 - PROG_ADDR_WIDTH) {1'b0}}, jump_wr}),
      .data_out(_jump_rd)  // only lower PROG_ADDR_WIDTH bits used
  );

  logic [7:0] last_inst;
  logic [PROG_ADDR_WIDTH-1:0] popped_addr;

  logic [PROG_ADDR_WIDTH-1:0] zero_ptr;
  logic [7:0] current_cell_next;

  // todo: edge case where we jump past program??
  logic use_jump_rd;
  always_comb begin : jump_logic
    use_jump_rd = (prog_rd == 8'h5B && current_cell == 8'h00) ||
                      (prog_rd == 8'h5D && current_cell != 8'h00);
  end

  task automatic do_reset();
    executing         <= '0;
    display           <= '0;

    data_we           <= '0;
    stack_we          <= '0;
    jump_we           <= '0;
    iptr              <= '0;

    dptr              <= '0;
    dptr_next         <= '0;

    current_cell      <= '0;
    current_cell_next <= '0;

    stack_ptr         <= '0;
    stack_wr          <= '0;
    popped_addr       <= '0;

    jump_addr_reg     <= '0;
    jump_wr           <= '0;

    last_inst         <= '0;
    exec_count        <= '0;
    zero_ptr          <= '0;
  endtask

  always_ff @(posedge clk or negedge resetn) begin : cpu_fsm
    if (!resetn) begin
      do_reset();
      state_id <= S_IDLE;
    end else begin
      // these get overridden as needed.
      data_we  <= 1'b0;
      stack_we <= 1'b0;
      jump_we  <= 1'b0;

      case (state_id)
        S_IDLE: begin
          executing <= 1'b0;
          if (start_req && loaded) begin
            do_reset();
            executing <= 1'b1;
            state_id  <= S_ZERO_DATA;
          end
        end

        S_ZERO_DATA: begin // todo: think about edge case: does this actually zero out the last cell?
          data_we <= 1'b1;
          dptr <= zero_ptr;
          data_wr <= 8'h00;
          zero_ptr <= zero_ptr + 1;
          if (zero_ptr == PROG_LEN) begin
            zero_ptr <= {PROG_ADDR_WIDTH{1'b0}};
            dptr <= {PROG_ADDR_WIDTH{1'b0}};
            state_id <= S_PRE_ADDR;
          end
        end


        S_PRE_ADDR: begin
          if (prog_rd == 8'h5B)
            stack_ptr <= stack_ptr + 1; // if we just wrote to stack, increment pointer. somewhat ugly, could replace with a stack_ptr_next or smth.

          state_id <= S_PRE_READ;
        end

        S_PRE_READ: begin
          if (iptr == PROG_LEN) begin
            iptr <= {PROG_ADDR_WIDTH{1'b0}};
            // preprocessing finished: move to fetch/execute
            state_id <= S_EXEC_WAIT;
          end else if (prog_rd == 8'h5B) begin  // [
            stack_wr <= iptr;
            stack_we <= 1'b1;

            iptr <= iptr + 1;
            state_id <= S_PRE_ADDR;
          end else if (prog_rd == 8'h5D) begin  // ]
            stack_ptr <= stack_ptr - 1;  // setup stack pop
            state_id  <= S_PRE_STACK_WAIT;
          end else begin
            iptr <= iptr + 1;
            state_id <= S_PRE_ADDR;
          end
        end

        S_PRE_STACK_WAIT: begin
          state_id <= S_PRE_STACK_READ;
        end

        S_PRE_STACK_READ: begin
          // stack_rd is the [ address
          popped_addr <= stack_rd;

          // write jump_table[stack_rd] = iptr (address of ])
          jump_addr_reg <= stack_rd;
          jump_wr <= iptr;
          jump_we <= 1'b1;

          state_id <= S_PRE_JUMP_W1;
        end

        S_PRE_JUMP_W1: begin
          // write the reverse mapping: jump_table[iptr] = stack_rd
          jump_addr_reg <= iptr;
          jump_wr <= popped_addr;
          jump_we <= 1'b1;

          state_id <= S_PRE_JUMP_DONE;
        end

        S_PRE_JUMP_DONE: begin
          // advance to next instruction after ']'
          iptr <= iptr + 1;
          state_id <= S_PRE_ADDR;
        end

        S_EXEC_WAIT: begin
          current_cell <= current_cell_next;

          state_id <= S_EXECUTE;
        end

        S_EXECUTE: begin  // can be reached either from EXEC_WAIT or PTR_READ_LATCH
          exec_count <= exec_count + 1;
          case (prog_rd)
            8'h3E: begin  // '>' - increment data pointer
              dptr_next <= dptr + 1;  // writeback scheduled
            end

            8'h3C: begin  // '<' - decrement data pointer
              dptr_next <= dptr - 1;  // writeback scheduled
            end

            8'h2B: begin  // '+'
              current_cell_next <= current_cell + 1;
            end

            8'h2D: begin  // '-'
              current_cell_next <= current_cell - 1;
            end

            8'h2E: begin  // '.'
              display <= current_cell;
            end

            8'h2C: begin  // ',' (input not implemented)
            end

            // jumping now implemented by use_jump_rd logic.
            8'h5B: begin  // '['
            end
            8'h5D: begin  // ']'
            end

            default: begin
              // state_id <= S_FETCH_ADDR;
            end
          endcase

          last_inst <= prog_rd;

          if (iptr < PROG_LEN) begin
            iptr <= use_jump_rd ? jump_rd + 1 : iptr + 1;
            jump_addr_reg <= use_jump_rd ? jump_rd + 1 : iptr + 1;

            // todo: skip write and go to read if cell value not changed.
            state_id <= (prog_rd == 8'h3E || prog_rd == 8'h3C) ? S_PTR_WRITEBACK : S_EXEC_WAIT;
            // state_id      <= (prog_rd == 8'h3E || prog_rd == 8'h3C) ? S_PTR_WRITEBACK : S_STEP_WAIT;
          end else begin
            // reached end: stop executing
            executing <= 1'b0;
            state_id  <= S_IDLE;
          end
        end

        S_PTR_WRITEBACK: begin
          data_wr  <= current_cell;
          data_we  <= 1'b1;
          state_id <= S_PTR_READ_SETUP;
        end

        S_PTR_READ_SETUP: begin
          dptr     <= dptr_next;  // request new address read
          state_id <= S_PTR_READ_WAIT;
        end

        S_PTR_READ_WAIT: begin
          state_id <= S_PTR_READ_LATCH;
        end

        S_PTR_READ_LATCH: begin
          current_cell_next <= data_rd;  // i think technically not needed..
          current_cell      <= data_rd;
          state_id          <= S_EXECUTE;
        end

        S_STEP_WAIT: begin  // todo: just merge into exec wait.
          // if we just executed . then wait for step_req before next fetch
          state_id <= (last_inst == 8'h2E && !step_req) ? S_STEP_WAIT : S_EXEC_WAIT;
        end

        default: begin
          state_id <= S_IDLE;
        end
      endcase

    end
  end

endmodule
