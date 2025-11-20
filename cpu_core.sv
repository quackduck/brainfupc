`default_nettype none
module cpu_core #(
    parameter int PROG_ADDR_WIDTH = 14,
    parameter logic [PROG_ADDR_WIDTH-1:0] PROG_LEN = 16383
) (
    input logic clk,

    input  logic [14:0] vga_data_addr,
    output logic [ 7:0] vga_cell,

    input logic resetn,
    input logic start_req,
    input logic step_req,
    input logic load_req,

    input logic in_display_area,

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
    S_SLOWDOWN,
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
  logic [                7:0] loader_wr;  // owned by loader
  logic                       loader_we;  // owned by loader

  spram program_memory (  // todo: this stores a 3 bit object in 16 bits...
      .clk(clk),
      .we(loader_we ? 4'b1111 : 4'b0000),
      .addr(loaded ? iptr : loader_addr),
      .data_in({8'h00, loader_wr}),
      .data_out(_prog_rd)
  );

  loader #(
      .PROG_ADDR_WIDTH(PROG_ADDR_WIDTH),
      .PROG_LEN(PROG_LEN)
  ) loader_inst (
      .clk(clk),
      .resetn(resetn),
      .load_req(load_req),

      .prog_we(loader_we),
      .prog_addr(loader_addr),
      .prog_wr(loader_wr),
      .loaded(loaded)
  );

  localparam int SLOWDOWN = 2;  // wait 2^(SLOWDOWN+1) cycles when SLOWDOWN != 0. since each inst takes ~2 cycles, this slows by ~2^SLOWDOWN.
  logic [SLOWDOWN:0] slow_ctr = 0;

  // brainfuck data tape

  logic [      14:0] dptr;  // 15 bits, max addr is 32767.
  logic [       7:0] data_wr;
  logic              data_we;
  logic [       7:0] data_rd;


  logic [      13:0] _data_addr;
  // logic [      15:0] _data_wr;
  logic [       3:0] _data_we;
  logic [      15:0] _data_rd;

  logic              byte_sel;

  logic              cpu_priority;  // set before doing ops with data tape.

  // assign _data_addr = in_display_area ? vga_data_addr[13:0] : dptr[13:0];
  // assign byte_sel = in_display_area ? vga_data_addr[14] : dptr[14];  // dptr[14];

  assign _data_addr = cpu_priority ? dptr[13:0] : vga_data_addr[13:0];
  assign byte_sel   = cpu_priority ? dptr[14] : vga_data_addr[14];  // dptr[14];

  assign data_rd    = byte_sel ? _data_rd[15:8] : _data_rd[7:0];
  assign _data_we   = data_we ? (byte_sel ? 4'b1100 : 4'b0011) : 4'b0000;

  assign vga_cell   = data_rd;

  // // Dual-port BRAM just for data tape so we can display.
  // (* syn_ramstyle = "block_ram" *)
  // localparam [PROG_ADDR_WIDTH-1:0] MAX_ADDR = 7167;  // unfortunately limited by bram... ideally 16383 or 30k
  // logic [7:0] data_mem[0:MAX_ADDR];

  // // Port A: CPU side (read/write) // todo: maybe switch this to save on CPU cycles? we dont care too much about vga.
  // always_ff @(posedge clk) begin
  //   if (data_we) data_mem[dptr] <= data_wr;
  //   data_rd <= data_mem[dptr];
  // end

  spram data_mem (
      .clk(clk),
      .we(_data_we),
      .addr(_data_addr),
      .data_in({data_wr, data_wr}),
      .data_out(_data_rd)
  );

  // // Port B: VGA read-only
  // logic [7:0] vga_cell_reg;
  // assign vga_cell = data_mem[vga_data_addr];



  logic [                7:0] current_cell;  // cached data cell
  logic [  PROG_ADDR_WIDTH:0] dptr_next;

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

  logic [14:0] zero_ptr;
  // logic [7:0] current_cell_next;

  // todo: edge case where we jump past program??
  logic use_jump_rd;
  always_comb begin : jump_logic
    use_jump_rd = (prog_rd == 8'h5B && current_cell == 8'h00) ||
                      (prog_rd == 8'h5D && current_cell != 8'h00);
  end

  task automatic do_reset();
    cpu_priority  <= '0;
    executing     <= '0;
    display       <= '0;

    data_we       <= '0;
    stack_we      <= '0;
    jump_we       <= '0;
    iptr          <= '0;

    dptr          <= '0;
    dptr_next     <= '0;

    current_cell  <= '0;

    stack_ptr     <= '0;
    stack_wr      <= '0;
    popped_addr   <= '0;

    jump_addr_reg <= '0;
    jump_wr       <= '0;

    last_inst     <= '0;
    exec_count    <= '0;
    zero_ptr      <= '0;
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
            cpu_priority <= 1'b1;  // take control of data tape
            state_id <= S_ZERO_DATA;
          end
        end

        S_ZERO_DATA: begin
          // // todo: make this work with display area too.
          // if (!in_display_area) begin
          data_we <= 1'b1;
          dptr <= zero_ptr;
          data_wr <= 8'h00;
          zero_ptr <= zero_ptr + 1;
          // end
          if (zero_ptr == '1) begin
            zero_ptr <= '0;
            dptr <= '0;
            cpu_priority <= 1'b0;  // release data tape
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
            iptr <= '0;
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
          state_id <= SLOWDOWN == 0 ? S_EXECUTE : S_SLOWDOWN;
        end

        S_SLOWDOWN: begin // doesnt get triggered on PTR_READ_LATCH but thats fine, we just want a slowdown on most insts.
          if (&slow_ctr[SLOWDOWN:0]) begin
            slow_ctr <= '0;
            state_id <= S_EXECUTE;
          end else begin
            slow_ctr <= slow_ctr + 1;
          end
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
              current_cell <= current_cell + 1;
            end

            8'h2D: begin  // '-'
              current_cell <= current_cell - 1;
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
            // state_id <= (prog_rd == 8'h3E || prog_rd == 8'h3C) ? S_PTR_WRITEBACK : S_EXEC_WAIT;

            if (prog_rd == 8'h3E || prog_rd == 8'h3C) begin
              cpu_priority <= 1'b1;  // take control of data tape
              state_id <= S_PTR_WRITEBACK;
            end else begin
              state_id <= S_EXEC_WAIT;
            end


            // state_id      <= (prog_rd == 8'h3E || prog_rd == 8'h3C) ? S_PTR_WRITEBACK : S_STEP_WAIT;
          end else begin
            // reached end: stop executing
            executing <= 1'b0;
            state_id  <= S_IDLE;
          end
        end

        S_PTR_WRITEBACK: begin
          // if (in_display_area) begin
          //   state_id <= S_PTR_WRITEBACK;  // stay here until we leave display area
          // end else begin
          data_wr  <= current_cell;
          data_we  <= 1'b1;
          state_id <= S_PTR_READ_SETUP;
          // end
        end

        S_PTR_READ_SETUP: begin
          dptr     <= dptr_next;  // request new address read

          // if dptr_next == MAX_ADDR+1, wrap around to 0. if dptr_next == all 1s, wrap to MAX_ADDR. rethink when max_addr changes..
          // dptr <= (dptr_next == MAX_ADDR + 1) ? '0 : (dptr_next == '1) ? MAX_ADDR : dptr_next;

          state_id <= S_PTR_READ_WAIT;


          // if (in_display_area) begin
          //   state_id <= S_PTR_READ_SETUP;  // stay here until we leave display area
          // end else begin
          //   dptr     <= dptr_next;  // request new address read

          //   // if dptr_next == MAX_ADDR+1, wrap around to 0. if dptr_next == all 1s, wrap to MAX_ADDR. rethink when max_addr changes..
          //   // dptr <= (dptr_next == MAX_ADDR + 1) ? '0 : (dptr_next == '1) ? MAX_ADDR : dptr_next;

          //   state_id <= S_PTR_READ_WAIT;
          // end

        end

        S_PTR_READ_WAIT: begin
          state_id <= S_PTR_READ_LATCH;
        end

        S_PTR_READ_LATCH: begin
          current_cell <= data_rd;
          cpu_priority <= 1'b0;  // release data tape
          state_id     <= S_EXECUTE;
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
