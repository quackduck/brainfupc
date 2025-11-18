`default_nettype none
module cpu_core #(
    parameter PROG_ADDR_WIDTH = 14,
    parameter PROG_LEN = 16383
) (
    input wire clk,
    // input  wire [21:0] time_reg,

    input  wire [13:0] vga_data_addr,
    output wire [ 7:0] vga_cell,

    input  wire       resetn,
    input  wire       start_req,
    input  wire       step_req,
    input  wire       load_req,
    output reg        loaded,
    output reg        executing,
    output reg  [4:0] state_id,
    output reg  [7:0] display
);

  localparam S_IDLE = 5'd0;
  localparam S_LOAD = 5'd1;

  // preprocess states
  localparam S_PRE_ADDR = 5'd2;
  localparam S_PRE_READ = 5'd4;
  localparam S_PRE_STACK_WAIT = 5'd5;
  localparam S_PRE_STACK_READ = 5'd6;
  localparam S_PRE_JUMP_W1 = 5'd7;
  localparam S_PRE_JUMP_DONE = 5'd9;

  // running
  localparam S_EXEC_WAIT = 5'd10;
  localparam S_EXECUTE = 5'd12;

  // writeback states
  localparam S_PTR_WRITEBACK = 5'd14;
  localparam S_STEP_WAIT = 5'd17;
  localparam S_PTR_READ_SETUP = 5'd19;
  localparam S_PTR_READ_WAIT = 5'd20;
  localparam S_ZERO_DATA = 5'd21;
  localparam S_PTR_READ_LATCH = 5'd22;

  reg  [PROG_ADDR_WIDTH-1:0] iptr;  // owned by cpu
  wire [               15:0] _prog_rd;  // owned by cpu
  wire [                7:0] prog_rd = _prog_rd[7:0];  // only lower 8 bits used.

  reg  [PROG_ADDR_WIDTH-1:0] loader_addr;  // owned by loader
  reg  [                7:0] prog_wr;  // owned by loader
  reg                        prog_we;  // owned by loader

  spram_stupid program_memory (
      .clk(clk),
      .write_enable(prog_we),
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
  reg  [PROG_ADDR_WIDTH-1:0] data_addr_reg;
  reg  [                7:0] data_wr;
  reg                        data_we;
  // wire [               15:0] _data_rd;
  wire [                7:0] data_rd;

  // spram_stupid data_memory (
  //     .clk(clk),
  //     .write_enable(data_we),
  //     .addr(data_addr_reg),
  //     .data_in({8'h00, data_wr}),
  //     .data_out(_data_rd)
  // );

  // Dual-port BRAM just for data tape so we can display.
  (* syn_ramstyle = "block_ram" *)
  reg  [                7:0] data_mem      [0:4096];

  // Port A: CPU side (read/write) // todo: maybe switch this to save on CPU cycles? we dont care too much about vga.
  always @(posedge clk) begin
    if (data_we) data_mem[data_addr_reg] <= data_wr;
    data_rd <= data_mem[data_addr_reg];  // or use separate read addr if you want
  end

  // Port B: VGA read-only
  // assign vga_cell = data_mem[vga_data_addr];
  always @(posedge clk) begin
    vga_cell <= data_mem[vga_data_addr];
  end

  reg  [                7:0] current_cell;  // cached data cell
  reg  [PROG_ADDR_WIDTH-1:0] current_ptr;
  reg  [PROG_ADDR_WIDTH-1:0] dptr;
  reg  [PROG_ADDR_WIDTH-1:0] dptr_next;


  // bracket stack, stores addresses of [ to match up with ]. we could save half the memory by noticing that the stack can never store more than (prog_len/2) addresses
  reg  [PROG_ADDR_WIDTH-1:0] stack_addr_reg;
  reg  [PROG_ADDR_WIDTH-1:0] stack_wr;
  reg                        stack_we;
  wire [               15:0] _stack_rd;
  wire [PROG_ADDR_WIDTH-1:0] stack_rd = _stack_rd[PROG_ADDR_WIDTH-1:0];
  reg  [PROG_ADDR_WIDTH-1:0] stack_ptr;  // at most half the program is [

  spram_stupid bracket_stack (
      .clk(clk),
      .write_enable(stack_we),
      .addr(stack_ptr),
      .data_in({{(16 - PROG_ADDR_WIDTH) {1'b0}}, stack_wr}),
      .data_out(_stack_rd)  // only lower PROG_ADDR_WIDTH bits used
  );

  // jump table stores address of matching bracket for each bracket.
  reg  [PROG_ADDR_WIDTH-1:0] jump_addr_reg;
  reg  [PROG_ADDR_WIDTH-1:0] jump_wr;
  reg                        jump_we;
  wire [               15:0] _jump_rd;
  wire [PROG_ADDR_WIDTH-1:0] jump_rd = _jump_rd[PROG_ADDR_WIDTH-1:0];

  spram_stupid jump_table (
      .clk(clk),
      .write_enable(jump_we),
      .addr(jump_addr_reg),
      .data_in({{(16 - PROG_ADDR_WIDTH) {1'b0}}, jump_wr}),
      .data_out(_jump_rd)  // only lower PROG_ADDR_WIDTH bits used
  );

  reg [7:0] last_inst;
  reg [7:0] exec_count;
  reg [PROG_ADDR_WIDTH-1:0] popped_addr;

  reg [PROG_ADDR_WIDTH-1:0] zero_ptr;
  reg [7:0] current_cell_next;

  reg use_jump_rd;

  integer i;
  always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      state_id          <= S_IDLE;
      // loaded            <= 1'b0;
      executing         <= 1'b0;
      display           <= 8'h00;

      // prog_we           <= 1'b0;
      data_we           <= 1'b0;
      stack_we          <= 1'b0;
      jump_we           <= 1'b0;

      iptr              <= {PROG_ADDR_WIDTH{1'b0}};

      dptr              <= {PROG_ADDR_WIDTH{1'b0}};
      dptr_next         <= {PROG_ADDR_WIDTH{1'b0}};
      data_addr_reg     <= {PROG_ADDR_WIDTH{1'b0}};

      current_ptr       <= {PROG_ADDR_WIDTH{1'b0}};
      current_cell      <= 8'h00;
      current_cell_next <= 8'h00;

      stack_ptr         <= {PROG_ADDR_WIDTH{1'b0}};
      stack_wr          <= {PROG_ADDR_WIDTH{1'b0}};
      popped_addr       <= {PROG_ADDR_WIDTH{1'b0}};

      jump_addr_reg     <= {PROG_ADDR_WIDTH{1'b0}};
      jump_wr           <= {PROG_ADDR_WIDTH{1'b0}};

      last_inst         <= 8'h00;
      exec_count        <= 8'h00;

      zero_ptr          <= {PROG_ADDR_WIDTH{1'b0}};
    end else begin
      // these get overriden as needed.
      // prog_we  <= 1'b0;
      data_we  <= 1'b0;
      stack_we <= 1'b0;
      jump_we  <= 1'b0;

      case (state_id)
        S_IDLE: begin
          executing <= 1'b0;
          if (load_req) begin
            // loaded <= 1'b0;
            // iptr <= {PROG_ADDR_WIDTH{1'b0}};
            // state_id <= S_LOAD;
          end else if (start_req && loaded) begin
            executing         <= 1'b1;
            // iptr <= {PROG_ADDR_WIDTH{1'b0}};
            // // prog_addr_reg <= {PROG_ADDR_WIDTH{1'b0}};
            // exec_count <= 8'h00;

            // // initialize data/cache
            // dptr <= {PROG_ADDR_WIDTH{1'b0}};
            // current_ptr <= {PROG_ADDR_WIDTH{1'b0}};
            // current_cell <= 8'h00;

            // // preprocessing state init
            // stack_ptr <= {PROG_ADDR_WIDTH - 1{1'b0}};
            // jump_addr_reg <= {PROG_ADDR_WIDTH{1'b0}};
            // popped_addr <= {PROG_ADDR_WIDTH{1'b0}};



            // loaded            <= 1'b0;
            executing         <= 1'b0;
            display           <= 8'h00;

            // pointers / counters
            iptr              <= {PROG_ADDR_WIDTH{1'b0}};

            dptr              <= {PROG_ADDR_WIDTH{1'b0}};
            dptr_next         <= {PROG_ADDR_WIDTH{1'b0}};
            data_addr_reg     <= {PROG_ADDR_WIDTH{1'b0}};

            current_ptr       <= {PROG_ADDR_WIDTH{1'b0}};
            current_cell      <= 8'h00;
            current_cell_next <= 8'h00;

            stack_ptr         <= {PROG_ADDR_WIDTH{1'b0}};
            stack_wr          <= {PROG_ADDR_WIDTH{1'b0}};
            popped_addr       <= {PROG_ADDR_WIDTH{1'b0}};

            jump_addr_reg     <= {PROG_ADDR_WIDTH{1'b0}};
            jump_wr           <= {PROG_ADDR_WIDTH{1'b0}};

            last_inst         <= 8'h00;
            exec_count        <= 8'h00;

            zero_ptr          <= {PROG_ADDR_WIDTH{1'b0}};

            state_id          <= S_ZERO_DATA;
          end
        end

        S_ZERO_DATA: begin
          data_we <= 1'b1;
          data_addr_reg <= zero_ptr;
          data_wr <= 8'h00;
          zero_ptr <= zero_ptr + 1;
          if (zero_ptr == {PROG_ADDR_WIDTH{1'b1}}) begin
            zero_ptr <= {PROG_ADDR_WIDTH{1'b0}};
            data_addr_reg <= {PROG_ADDR_WIDTH{1'b0}};
            state_id <= S_PRE_ADDR;
          end
        end

        // S_LOAD: begin
        //   // prog_we <= 1'b1;

        //   // // // program: +[+.]
        //   // // case (iptr)
        //   // //   0: prog_wr <= 8'h2B;  // +
        //   // //   1: prog_wr <= 8'h5B;  // [
        //   // //   2: prog_wr <= 8'h2B;  // +
        //   // //   3: prog_wr <= 8'h2E;  // .
        //   // //   4: prog_wr <= 8'h5D;  // ]
        //   // //   default: prog_wr <= 8'h00;
        //   // // endcase
        //   // `include "prog_rom.v"  // generated case stmt

        //   // if (iptr == PROG_LEN) begin
        //   //   iptr <= {PROG_ADDR_WIDTH{1'b0}};
        //   //   loaded <= 1'b1;
        //   //   state_id <= S_IDLE;
        //   // end else begin
        //   //   iptr <= iptr + 1;
        //   // end

        //   // things used: prog_we, prog_wr, iptr, loaded
        //   // start signal, done signal?


        // end


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
          exec_count <= exec_count + 1;
          current_cell <= current_cell_next;

          state_id <= S_EXECUTE;
        end

        S_EXECUTE: begin
          case (prog_rd)
            8'h3E: begin  // '>' - increment data pointer
              dptr_next <= dptr + 1;
            end

            8'h3C: begin  // '<' - decrement data pointer
              dptr_next <= dptr - 1;
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

            // jumping now implemented by use_jump_rd wire.
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
            // todo: edge case where we jump past program??
            use_jump_rd = ((prog_rd == 8'h5B && current_cell == 8'h00) || (prog_rd == 8'h5D && current_cell != 8'h00));
            iptr <= use_jump_rd ? jump_rd + 1 : iptr + 1;
            jump_addr_reg <= use_jump_rd ? jump_rd + 1 : iptr + 1;
            state_id <= (prog_rd == 8'h3E || prog_rd == 8'h3C) ? S_PTR_WRITEBACK : S_EXEC_WAIT; // todo: skip write and go to read if cell value not changed.
            // state_id      <= (prog_rd == 8'h3E || prog_rd == 8'h3C) ? S_PTR_WRITEBACK : S_STEP_WAIT;
          end else begin
            // reached end: stop executing
            executing <= 1'b0;
            state_id  <= S_IDLE;
          end
        end

        S_PTR_WRITEBACK: begin
          data_addr_reg <= current_ptr;
          data_wr       <= current_cell;
          data_we       <= 1'b1;
          state_id      <= S_PTR_READ_SETUP;
        end

        S_PTR_READ_SETUP: begin
          dptr          <= dptr_next;  // move logical pointer
          current_ptr   <= dptr_next;
          data_addr_reg <= dptr_next;  // request new address read
          state_id      <= S_PTR_READ_WAIT;
        end

        S_PTR_READ_WAIT: begin
          state_id <= S_PTR_READ_LATCH;
        end

        S_PTR_READ_LATCH: begin
          current_cell_next <= data_rd;
          state_id          <= S_EXEC_WAIT;
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


module spram_stupid (
    input  wire        clk,
    input  wire        write_enable,
    input  wire [13:0] addr,
    input  wire [15:0] data_in,
    output reg  [15:0] data_out
);
  spram spram_inst (
      .clk(clk),
      .we(write_enable ? 4'b1111 : 4'b0000),
      .addr(addr),
      .data_in(data_in),
      .data_out(data_out)
  );
endmodule
