`default_nettype none
module cpu_core #(
    parameter PROG_ADDR_WIDTH = 11,
    parameter PROG_LEN = 2047
) (
    input  wire        clk,
    input  wire [21:0] time_reg,
    input  wire        resetn,
    input  wire        start_req,
    input  wire        step_req,
    input  wire        load_req,
    output reg         loaded,
    output reg         executing,
    output reg  [ 4:0] state_id,
    output reg  [ 7:0] display
);

  // -------------------------------------------------------------------------
  // State encoding (all unique)
  // -------------------------------------------------------------------------
  localparam S_IDLE = 5'd0;
  localparam S_LOAD = 5'd1;

  // Preprocess states (build jump table)
  localparam S_PRE_ADDR = 5'd2;  // set program addr for read (preproc)
  localparam S_PRE_WAIT = 5'd3;  // wait a cycle for prog_rd valid
  localparam S_PRE_READ = 5'd4;  // inspect prog_rd and act
  localparam S_PRE_STACK_WAIT = 5'd5;  // wait for stack_rd after setting stack_addr_reg
  localparam S_PRE_STACK_READ = 5'd6;  // consume stack_rd (popped_addr)
  localparam S_PRE_JUMP_W1 = 5'd7;  // write jump_table[popped_addr] = iptr (']' addr)
  localparam S_PRE_JUMP_W2 = 5'd8;  // write jump_table[iptr] = popped_addr ('[' addr)
  localparam S_PRE_JUMP_DONE = 5'd9;  // advance iptr and continue

  // Fetch/execute states
  localparam S_FETCH_ADDR = 5'd10;  // put iptr to prog_addr_reg and jump_addr_reg
  localparam S_FETCH_WAIT = 5'd11;  // wait for prog_rd and jump_rd valid
  localparam S_EXECUTE = 5'd12;
  // localparam S_UPDATE = 5'd13;

  // Data pointer states
  localparam S_PTR_WRITEBACK = 5'd14;
  localparam S_PTR_READ = 5'd15;
  localparam S_PTR_WAIT = 5'd16;

  localparam S_STEP_WAIT = 5'd17;  // wait for step_req to continue
  localparam S_PTR_WRITE_WAIT = 5'd18;  // wait after writing back cached cell

  localparam S_PTR_READ_SETUP = 5'd19;  // setup read of new cell after pointer move
  localparam S_PTR_READ_WAIT = 5'd20;  // wait for new cell to be valid
  localparam S_ZERO_DATA = 5'd21;  // zero out data memory

  localparam S_PTR_READ_LATCH = 5'd22;  // latch new cell after read wait

  localparam S_WAIT_100 = 5'd23;  // dummy wait state
  localparam S_STACK_WRITE_WAIT1 = 5'd24;  // wait after jump table write
  localparam S_FETCH_LATCH = 5'd25;  // latch fetched instruction and jump table entry

  // -------------------------------------------------------------------------
  // Program memory (synchronous BRAM)
  // -------------------------------------------------------------------------
  // reg  [PROG_ADDR_WIDTH-1:0] prog_addr_reg;
  reg  [7:0] prog_wr;
  reg        prog_we;
  wire [7:0] prog_rd;

  bram_sp #(
      .ADDR_WIDTH(PROG_ADDR_WIDTH),
      .DATA_WIDTH(8)
  ) program_memory (
      .clk(clk),
      .write_enable(prog_we),
      .addr(iptr),
      .data_in(prog_wr),
      .data_out(prog_rd)
  );

  // -------------------------------------------------------------------------
  // Data memory (cached cell)
  // -------------------------------------------------------------------------
  reg  [PROG_ADDR_WIDTH-1:0] data_addr_reg;
  reg  [                7:0] data_wr;
  reg                        data_we;
  wire [                7:0] data_rd;

  bram_sp #(
      .ADDR_WIDTH(PROG_ADDR_WIDTH),
      .DATA_WIDTH(8)
  ) data_memory (
      .clk(clk),
      .write_enable(data_we),
      .addr(data_addr_reg),
      .data_in(data_wr),
      .data_out(data_rd)
  );

  // cached cell invariant: current_cell == data[current_ptr]
  reg  [                7:0] current_cell;
  reg  [PROG_ADDR_WIDTH-1:0] current_ptr;
  reg  [PROG_ADDR_WIDTH-1:0] dptr;
  reg  [PROG_ADDR_WIDTH-1:0] dptr_next;

  // -------------------------------------------------------------------------
  // Bracket stack (push addresses of '[')
  // -------------------------------------------------------------------------
  reg  [PROG_ADDR_WIDTH-2:0] stack_addr_reg;  // at most half the program is [
  reg  [PROG_ADDR_WIDTH-1:0] stack_wr;
  reg                        stack_we;
  wire [PROG_ADDR_WIDTH-1:0] stack_rd;
  reg  [PROG_ADDR_WIDTH-2:0] stack_ptr;

  bram_sp #(
      .ADDR_WIDTH(PROG_ADDR_WIDTH - 1),
      .DATA_WIDTH(PROG_ADDR_WIDTH)
  ) bracket_stack (
      .clk(clk),
      .write_enable(stack_we),
      .addr(stack_addr_reg),
      .data_in(stack_wr),
      .data_out(stack_rd)
  );

  // -------------------------------------------------------------------------
  // Jump table (map '[' <-> ']')
  // -------------------------------------------------------------------------
  reg  [PROG_ADDR_WIDTH-1:0] jump_addr_reg;
  reg  [PROG_ADDR_WIDTH-1:0] jump_wr;
  reg                        jump_we;
  wire [PROG_ADDR_WIDTH-1:0] jump_rd;

  bram_sp #(
      .ADDR_WIDTH(PROG_ADDR_WIDTH),
      .DATA_WIDTH(PROG_ADDR_WIDTH)
  ) jump_table (
      .clk(clk),
      .write_enable(jump_we),
      .addr(jump_addr_reg),
      .data_in(jump_wr),
      .data_out(jump_rd)
  );

  reg [PROG_ADDR_WIDTH-1:0] iptr;
  reg [7:0] inst;
  reg [PROG_ADDR_WIDTH-1:0] jmp;
  reg [7:0] output_reg;
  reg [7:0] exec_count;
  reg [PROG_ADDR_WIDTH-1:0] popped_addr;

  reg [PROG_ADDR_WIDTH-1:0] zero_ptr;
  reg [7:0] current_cell_next;


  wire use_jump_rd = (prog_rd == 8'h5B && current_cell == 0) || 
                   (prog_rd == 8'h5D && current_cell != 0);

  integer i;
  always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      // core state
      state_id          <= S_IDLE;
      loaded            <= 1'b0;
      executing         <= 1'b0;
      display           <= 8'h00;

      // default BRAM control pulses low
      prog_we           <= 1'b0;
      data_we           <= 1'b0;
      stack_we          <= 1'b0;
      jump_we           <= 1'b0;

      // pointers / counters
      iptr              <= {PROG_ADDR_WIDTH{1'b0}};

      // prog_addr_reg     <= {PROG_ADDR_WIDTH{1'b0}};
      dptr              <= {PROG_ADDR_WIDTH{1'b0}};
      dptr_next         <= {PROG_ADDR_WIDTH{1'b0}};
      data_addr_reg     <= {PROG_ADDR_WIDTH{1'b0}};

      current_ptr       <= {PROG_ADDR_WIDTH{1'b0}};
      current_cell      <= 8'h00;
      current_cell_next <= 8'h00;

      stack_ptr         <= {PROG_ADDR_WIDTH - 1{1'b0}};
      stack_addr_reg    <= {PROG_ADDR_WIDTH - 1{1'b0}};
      stack_wr          <= {PROG_ADDR_WIDTH{1'b0}};
      popped_addr       <= {PROG_ADDR_WIDTH{1'b0}};

      jump_addr_reg     <= {PROG_ADDR_WIDTH{1'b0}};
      jump_wr           <= {PROG_ADDR_WIDTH{1'b0}};

      inst              <= 8'h00;
      output_reg        <= 8'h00;
      exec_count        <= 8'h00;

      zero_ptr          <= {PROG_ADDR_WIDTH{1'b0}};
    end else begin
      // default: clear single-cycle write strobes at start of each clock
      prog_we  <= 1'b0;
      data_we  <= 1'b0;
      stack_we <= 1'b0;
      jump_we  <= 1'b0;

      // current_cell_next <= current_cell;

      case (state_id)
        // -------------------------------------------------------------------
        // IDLE: start or load
        // -------------------------------------------------------------------
        S_IDLE: begin
          executing <= 1'b0;
          if (load_req) begin
            loaded <= 1'b0;
            iptr <= {PROG_ADDR_WIDTH{1'b0}};
            // prog_addr_reg <= {PROG_ADDR_WIDTH{1'b0}};
            state_id <= S_LOAD;
          end else if (start_req && loaded) begin
            executing <= 1'b1;
            iptr <= {PROG_ADDR_WIDTH{1'b0}};
            // prog_addr_reg <= {PROG_ADDR_WIDTH{1'b0}};
            exec_count <= 8'h00;

            // initialize data/cache
            dptr <= {PROG_ADDR_WIDTH{1'b0}};
            current_ptr <= {PROG_ADDR_WIDTH{1'b0}};
            current_cell <= 8'h00;

            // preprocessing state init
            stack_ptr <= {PROG_ADDR_WIDTH - 1{1'b0}};
            jump_addr_reg <= {PROG_ADDR_WIDTH{1'b0}};
            popped_addr <= {PROG_ADDR_WIDTH{1'b0}};

            state_id <= S_ZERO_DATA;
          end
        end

        S_ZERO_DATA: begin
          // write zero to every data address
          data_we <= 1'b1;
          data_addr_reg <= zero_ptr;
          data_wr <= 8'h00;
          zero_ptr <= zero_ptr + 1;
          if (zero_ptr == {PROG_ADDR_WIDTH{1'b1}}) begin
            data_we <= 1'b0;
            zero_ptr <= {PROG_ADDR_WIDTH{1'b0}};
            data_addr_reg <= {PROG_ADDR_WIDTH{1'b0}};
            state_id <= S_PRE_ADDR;
          end
        end

        // -------------------------------------------------------------------
        // LOAD: write hardcoded program (one write per cycle)
        // -------------------------------------------------------------------
        S_LOAD: begin
          prog_we <= 1'b1;

          // TODO: CHECK REDUCE STATE?

          // prog_addr_reg <= iptr;

          // // program: +[+.]
          // case (iptr)
          //   0: prog_wr <= 8'h2B;  // +
          //   1: prog_wr <= 8'h5B;  // [
          //   2: prog_wr <= 8'h2B;  // +
          //   3: prog_wr <= 8'h2E;  // .
          //   4: prog_wr <= 8'h5D;  // ]
          //   default: prog_wr <= 8'h00;
          // endcase

          // // program: +.
          // case (iptr)
          //   0: prog_wr <= 8'h2B;  // +
          //   1: prog_wr <= 8'h2E;  // .
          //   default: prog_wr <= 8'h00;
          // endcase

          // // program: multiply 4 and 7: ++++[>+++++++<-.]>.
          // case (iptr)
          //   0: prog_wr <= 8'h2B;  // +
          //   1: prog_wr <= 8'h2B;  // +
          //   2: prog_wr <= 8'h2B;  // +
          //   3: prog_wr <= 8'h2B;  // +
          //   4: prog_wr <= 8'h5B;  // [
          //   5: prog_wr <= 8'h3E;  // >
          //   6: prog_wr <= 8'h2B;  // +
          //   7: prog_wr <= 8'h2B;  // +
          //   8: prog_wr <= 8'h2B;  // +
          //   9: prog_wr <= 8'h2B;  // +
          //   10: prog_wr <= 8'h2B;  // +
          //   11: prog_wr <= 8'h2B;  // +
          //   12: prog_wr <= 8'h2B;  // +
          //   13: prog_wr <= 8'h3C;  // <
          //   14: prog_wr <= 8'h2D;  // -
          //   15: prog_wr <= 8'h5D;  // ]
          //   16: prog_wr <= 8'h3E;  // >
          //   17: prog_wr <= 8'h2E;  // .
          //   default: prog_wr <= 8'h00;
          // endcase

          // // program: multiply 4 and 7: >++++[<+++++++.>-]<.
          // case (iptr)
          //   0: prog_wr <= 8'h3E;  // >
          //   1: prog_wr <= 8'h2B;  // +
          //   2: prog_wr <= 8'h2B;  // +
          //   3: prog_wr <= 8'h2B;  // +
          //   4: prog_wr <= 8'h2B;  // +
          //   5: prog_wr <= 8'h5B;  // [
          //   6: prog_wr <= 8'h3C;  // <
          //   7: prog_wr <= 8'h2B;  // +
          //   8: prog_wr <= 8'h2B;  // +
          //   9: prog_wr <= 8'h2B;  // +
          //   10: prog_wr <= 8'h2B;  // +
          //   11: prog_wr <= 8'h2B;  // +
          //   12: prog_wr <= 8'h2B;  // +
          //   13: prog_wr <= 8'h2B;  // +
          //   14: prog_wr <= 8'h2E;  // .
          //   15: prog_wr <= 8'h3E;  // >
          //   16: prog_wr <= 8'h2D;  // -
          //   17: prog_wr <= 8'h5D;  // ]
          //   18: prog_wr <= 8'h3C;  // <
          //   19: prog_wr <= 8'h2E;  // .
          //   default: prog_wr <= 8'h00;
          // endcase


          // // --- BEGIN AUTO-GENERATED CODE --- // hello world
          // // PROGRAM LENGTH (PROG_LEN) should be set to: 106
          // case (iptr)
          //   0: prog_wr <= 8'h2B;  // +
          //   1: prog_wr <= 8'h2B;  // +
          //   2: prog_wr <= 8'h2B;  // +
          //   3: prog_wr <= 8'h2B;  // +
          //   4: prog_wr <= 8'h2B;  // +
          //   5: prog_wr <= 8'h2B;  // +
          //   6: prog_wr <= 8'h2B;  // +
          //   7: prog_wr <= 8'h2B;  // +
          //   8: prog_wr <= 8'h5B;  // [
          //   9: prog_wr <= 8'h3E;  // >
          //   10: prog_wr <= 8'h2B;  // +
          //   11: prog_wr <= 8'h2B;  // +
          //   12: prog_wr <= 8'h2B;  // +
          //   13: prog_wr <= 8'h2B;  // +
          //   14: prog_wr <= 8'h5B;  // [
          //   15: prog_wr <= 8'h3E;  // >
          //   16: prog_wr <= 8'h2B;  // +
          //   17: prog_wr <= 8'h2B;  // +
          //   18: prog_wr <= 8'h3E;  // >
          //   19: prog_wr <= 8'h2B;  // +
          //   20: prog_wr <= 8'h2B;  // +
          //   21: prog_wr <= 8'h2B;  // +
          //   22: prog_wr <= 8'h3E;  // >
          //   23: prog_wr <= 8'h2B;  // +
          //   24: prog_wr <= 8'h2B;  // +
          //   25: prog_wr <= 8'h2B;  // +
          //   26: prog_wr <= 8'h3E;  // >
          //   27: prog_wr <= 8'h2B;  // +
          //   28: prog_wr <= 8'h3C;  // <
          //   29: prog_wr <= 8'h3C;  // <
          //   30: prog_wr <= 8'h3C;  // <
          //   31: prog_wr <= 8'h3C;  // <
          //   32: prog_wr <= 8'h2D;  // -
          //   33: prog_wr <= 8'h5D;  // ]
          //   34: prog_wr <= 8'h3E;  // >
          //   35: prog_wr <= 8'h2B;  // +
          //   36: prog_wr <= 8'h3E;  // >
          //   37: prog_wr <= 8'h2B;  // +
          //   38: prog_wr <= 8'h3E;  // >
          //   39: prog_wr <= 8'h2D;  // -
          //   40: prog_wr <= 8'h3E;  // >
          //   41: prog_wr <= 8'h3E;  // >
          //   42: prog_wr <= 8'h2B;  // +
          //   43: prog_wr <= 8'h5B;  // [
          //   44: prog_wr <= 8'h3C;  // <
          //   45: prog_wr <= 8'h5D;  // ]
          //   46: prog_wr <= 8'h3C;  // <
          //   47: prog_wr <= 8'h2D;  // -
          //   48: prog_wr <= 8'h5D;  // ]
          //   49: prog_wr <= 8'h3E;  // >
          //   50: prog_wr <= 8'h3E;  // >
          //   51: prog_wr <= 8'h2E;  // .
          //   52: prog_wr <= 8'h3E;  // >
          //   53: prog_wr <= 8'h2D;  // -
          //   54: prog_wr <= 8'h2D;  // -
          //   55: prog_wr <= 8'h2D;  // -
          //   56: prog_wr <= 8'h2E;  // .
          //   57: prog_wr <= 8'h2B;  // +
          //   58: prog_wr <= 8'h2B;  // +
          //   59: prog_wr <= 8'h2B;  // +
          //   60: prog_wr <= 8'h2B;  // +
          //   61: prog_wr <= 8'h2B;  // +
          //   62: prog_wr <= 8'h2B;  // +
          //   63: prog_wr <= 8'h2B;  // +
          //   64: prog_wr <= 8'h2E;  // .
          //   65: prog_wr <= 8'h2E;  // .
          //   66: prog_wr <= 8'h2B;  // +
          //   67: prog_wr <= 8'h2B;  // +
          //   68: prog_wr <= 8'h2B;  // +
          //   69: prog_wr <= 8'h2E;  // .
          //   70: prog_wr <= 8'h3E;  // >
          //   71: prog_wr <= 8'h3E;  // >
          //   72: prog_wr <= 8'h2E;  // .
          //   73: prog_wr <= 8'h3C;  // <
          //   74: prog_wr <= 8'h2D;  // -
          //   75: prog_wr <= 8'h2E;  // .
          //   76: prog_wr <= 8'h3C;  // <
          //   77: prog_wr <= 8'h2E;  // .
          //   78: prog_wr <= 8'h2B;  // +
          //   79: prog_wr <= 8'h2B;  // +
          //   80: prog_wr <= 8'h2B;  // +
          //   81: prog_wr <= 8'h2E;  // .
          //   82: prog_wr <= 8'h2D;  // -
          //   83: prog_wr <= 8'h2D;  // -
          //   84: prog_wr <= 8'h2D;  // -
          //   85: prog_wr <= 8'h2D;  // -
          //   86: prog_wr <= 8'h2D;  // -
          //   87: prog_wr <= 8'h2D;  // -
          //   88: prog_wr <= 8'h2E;  // .
          //   89: prog_wr <= 8'h2D;  // -
          //   90: prog_wr <= 8'h2D;  // -
          //   91: prog_wr <= 8'h2D;  // -
          //   92: prog_wr <= 8'h2D;  // -
          //   93: prog_wr <= 8'h2D;  // -
          //   94: prog_wr <= 8'h2D;  // -
          //   95: prog_wr <= 8'h2D;  // -
          //   96: prog_wr <= 8'h2D;  // -
          //   97: prog_wr <= 8'h2E;  // .
          //   98: prog_wr <= 8'h3E;  // >
          //   99: prog_wr <= 8'h3E;  // >
          //   100: prog_wr <= 8'h2B;  // +
          //   101: prog_wr <= 8'h2E;  // .
          //   102: prog_wr <= 8'h3E;  // >
          //   103: prog_wr <= 8'h2B;  // +
          //   104: prog_wr <= 8'h2B;  // +
          //   105: prog_wr <= 8'h2E;  // .
          //   default: prog_wr <= 8'h00;  // NOP
          // endcase
          // // --- END AUTO-GENERATED CODE ---



          // // --- BEGIN AUTO-GENERATED CODE --- // amber program
          // // PROGRAM LENGTH (PROG_LEN) should be set to: 212
          // case (iptr)
          //   0: prog_wr <= 8'h2D;  // -
          //   1: prog_wr <= 8'h2D;  // -
          //   2: prog_wr <= 8'h2D;  // -
          //   3: prog_wr <= 8'h2D;  // -
          //   4: prog_wr <= 8'h5B;  // [
          //   5: prog_wr <= 8'h2D;  // -
          //   6: prog_wr <= 8'h2D;  // -
          //   7: prog_wr <= 8'h2D;  // -
          //   8: prog_wr <= 8'h2D;  // -
          //   9: prog_wr <= 8'h3E;  // >
          //   10: prog_wr <= 8'h2B;  // +
          //   11: prog_wr <= 8'h3C;  // <
          //   12: prog_wr <= 8'h5D;  // ]
          //   13: prog_wr <= 8'h3E;  // >
          //   14: prog_wr <= 8'h2B;  // +
          //   15: prog_wr <= 8'h2B;  // +
          //   16: prog_wr <= 8'h2E;  // .
          //   17: prog_wr <= 8'h5B;  // [
          //   18: prog_wr <= 8'h2D;  // -
          //   19: prog_wr <= 8'h2D;  // -
          //   20: prog_wr <= 8'h2D;  // -
          //   21: prog_wr <= 8'h3E;  // >
          //   22: prog_wr <= 8'h2B;  // +
          //   23: prog_wr <= 8'h3C;  // <
          //   24: prog_wr <= 8'h5D;  // ]
          //   25: prog_wr <= 8'h3E;  // >
          //   26: prog_wr <= 8'h2B;  // +
          //   27: prog_wr <= 8'h2B;  // +
          //   28: prog_wr <= 8'h2E;  // .
          //   29: prog_wr <= 8'h2D;  // -
          //   30: prog_wr <= 8'h2D;  // -
          //   31: prog_wr <= 8'h2D;  // -
          //   32: prog_wr <= 8'h2D;  // -
          //   33: prog_wr <= 8'h2D;  // -
          //   34: prog_wr <= 8'h2D;  // -
          //   35: prog_wr <= 8'h2D;  // -
          //   36: prog_wr <= 8'h2D;  // -
          //   37: prog_wr <= 8'h2D;  // -
          //   38: prog_wr <= 8'h2D;  // -
          //   39: prog_wr <= 8'h2D;  // -
          //   40: prog_wr <= 8'h2E;  // .
          //   41: prog_wr <= 8'h2B;  // +
          //   42: prog_wr <= 8'h2B;  // +
          //   43: prog_wr <= 8'h2B;  // +
          //   44: prog_wr <= 8'h2E;  // .
          //   45: prog_wr <= 8'h2B;  // +
          //   46: prog_wr <= 8'h2B;  // +
          //   47: prog_wr <= 8'h2B;  // +
          //   48: prog_wr <= 8'h2B;  // +
          //   49: prog_wr <= 8'h2B;  // +
          //   50: prog_wr <= 8'h2B;  // +
          //   51: prog_wr <= 8'h2B;  // +
          //   52: prog_wr <= 8'h2B;  // +
          //   53: prog_wr <= 8'h2B;  // +
          //   54: prog_wr <= 8'h2B;  // +
          //   55: prog_wr <= 8'h2B;  // +
          //   56: prog_wr <= 8'h2B;  // +
          //   57: prog_wr <= 8'h2B;  // +
          //   58: prog_wr <= 8'h2E;  // .
          //   59: prog_wr <= 8'h5B;  // [
          //   60: prog_wr <= 8'h2D;  // -
          //   61: prog_wr <= 8'h2D;  // -
          //   62: prog_wr <= 8'h3E;  // >
          //   63: prog_wr <= 8'h2B;  // +
          //   64: prog_wr <= 8'h2B;  // +
          //   65: prog_wr <= 8'h2B;  // +
          //   66: prog_wr <= 8'h2B;  // +
          //   67: prog_wr <= 8'h2B;  // +
          //   68: prog_wr <= 8'h3C;  // <
          //   69: prog_wr <= 8'h5D;  // ]
          //   70: prog_wr <= 8'h3E;  // >
          //   71: prog_wr <= 8'h2B;  // +
          //   72: prog_wr <= 8'h2B;  // +
          //   73: prog_wr <= 8'h2B;  // +
          //   74: prog_wr <= 8'h2E;  // .
          //   75: prog_wr <= 8'h2D;  // -
          //   76: prog_wr <= 8'h5B;  // [
          //   77: prog_wr <= 8'h2D;  // -
          //   78: prog_wr <= 8'h2D;  // -
          //   79: prog_wr <= 8'h2D;  // -
          //   80: prog_wr <= 8'h3E;  // >
          //   81: prog_wr <= 8'h2B;  // +
          //   82: prog_wr <= 8'h2B;  // +
          //   83: prog_wr <= 8'h3C;  // <
          //   84: prog_wr <= 8'h5D;  // ]
          //   85: prog_wr <= 8'h3E;  // >
          //   86: prog_wr <= 8'h2D;  // -
          //   87: prog_wr <= 8'h2E;  // .
          //   88: prog_wr <= 8'h2B;  // +
          //   89: prog_wr <= 8'h2B;  // +
          //   90: prog_wr <= 8'h2B;  // +
          //   91: prog_wr <= 8'h2B;  // +
          //   92: prog_wr <= 8'h2B;  // +
          //   93: prog_wr <= 8'h2B;  // +
          //   94: prog_wr <= 8'h2B;  // +
          //   95: prog_wr <= 8'h2B;  // +
          //   96: prog_wr <= 8'h2B;  // +
          //   97: prog_wr <= 8'h2B;  // +
          //   98: prog_wr <= 8'h2E;  // .
          //   99: prog_wr <= 8'h2B;  // +
          //   100: prog_wr <= 8'h5B;  // [
          //   101: prog_wr <= 8'h2D;  // -
          //   102: prog_wr <= 8'h2D;  // -
          //   103: prog_wr <= 8'h2D;  // -
          //   104: prog_wr <= 8'h2D;  // -
          //   105: prog_wr <= 8'h3E;  // >
          //   106: prog_wr <= 8'h2B;  // +
          //   107: prog_wr <= 8'h3C;  // <
          //   108: prog_wr <= 8'h5D;  // ]
          //   109: prog_wr <= 8'h3E;  // >
          //   110: prog_wr <= 8'h2B;  // +
          //   111: prog_wr <= 8'h2B;  // +
          //   112: prog_wr <= 8'h2B;  // +
          //   113: prog_wr <= 8'h2E;  // .
          //   114: prog_wr <= 8'h2D;  // -
          //   115: prog_wr <= 8'h2D;  // -
          //   116: prog_wr <= 8'h2D;  // -
          //   117: prog_wr <= 8'h5B;  // [
          //   118: prog_wr <= 8'h2D;  // -
          //   119: prog_wr <= 8'h3E;  // >
          //   120: prog_wr <= 8'h2B;  // +
          //   121: prog_wr <= 8'h2B;  // +
          //   122: prog_wr <= 8'h2B;  // +
          //   123: prog_wr <= 8'h2B;  // +
          //   124: prog_wr <= 8'h3C;  // <
          //   125: prog_wr <= 8'h5D;  // ]
          //   126: prog_wr <= 8'h3E;  // >
          //   127: prog_wr <= 8'h2D;  // -
          //   128: prog_wr <= 8'h2E;  // .
          //   129: prog_wr <= 8'h2D;  // -
          //   130: prog_wr <= 8'h2D;  // -
          //   131: prog_wr <= 8'h2D;  // -
          //   132: prog_wr <= 8'h2D;  // -
          //   133: prog_wr <= 8'h2E;  // .
          //   134: prog_wr <= 8'h5B;  // [
          //   135: prog_wr <= 8'h2D;  // -
          //   136: prog_wr <= 8'h2D;  // -
          //   137: prog_wr <= 8'h2D;  // -
          //   138: prog_wr <= 8'h3E;  // >
          //   139: prog_wr <= 8'h2B;  // +
          //   140: prog_wr <= 8'h3C;  // <
          //   141: prog_wr <= 8'h5D;  // ]
          //   142: prog_wr <= 8'h3E;  // >
          //   143: prog_wr <= 8'h2D;  // -
          //   144: prog_wr <= 8'h2D;  // -
          //   145: prog_wr <= 8'h2D;  // -
          //   146: prog_wr <= 8'h2D;  // -
          //   147: prog_wr <= 8'h2D;  // -
          //   148: prog_wr <= 8'h2E;  // .
          //   149: prog_wr <= 8'h2B;  // +
          //   150: prog_wr <= 8'h5B;  // [
          //   151: prog_wr <= 8'h2D;  // -
          //   152: prog_wr <= 8'h3E;  // >
          //   153: prog_wr <= 8'h2B;  // +
          //   154: prog_wr <= 8'h2B;  // +
          //   155: prog_wr <= 8'h2B;  // +
          //   156: prog_wr <= 8'h3C;  // <
          //   157: prog_wr <= 8'h5D;  // ]
          //   158: prog_wr <= 8'h3E;  // >
          //   159: prog_wr <= 8'h2E;  // .
          //   160: prog_wr <= 8'h2B;  // +
          //   161: prog_wr <= 8'h2B;  // +
          //   162: prog_wr <= 8'h2B;  // +
          //   163: prog_wr <= 8'h2B;  // +
          //   164: prog_wr <= 8'h2B;  // +
          //   165: prog_wr <= 8'h2B;  // +
          //   166: prog_wr <= 8'h2B;  // +
          //   167: prog_wr <= 8'h2B;  // +
          //   168: prog_wr <= 8'h2B;  // +
          //   169: prog_wr <= 8'h2B;  // +
          //   170: prog_wr <= 8'h2B;  // +
          //   171: prog_wr <= 8'h2B;  // +
          //   172: prog_wr <= 8'h2E;  // .
          //   173: prog_wr <= 8'h2E;  // .
          //   174: prog_wr <= 8'h2D;  // -
          //   175: prog_wr <= 8'h2D;  // -
          //   176: prog_wr <= 8'h2D;  // -
          //   177: prog_wr <= 8'h2E;  // .
          //   178: prog_wr <= 8'h5B;  // [
          //   179: prog_wr <= 8'h2B;  // +
          //   180: prog_wr <= 8'h2B;  // +
          //   181: prog_wr <= 8'h3E;  // >
          //   182: prog_wr <= 8'h2D;  // -
          //   183: prog_wr <= 8'h2D;  // -
          //   184: prog_wr <= 8'h2D;  // -
          //   185: prog_wr <= 8'h3C;  // <
          //   186: prog_wr <= 8'h5D;  // ]
          //   187: prog_wr <= 8'h3E;  // >
          //   188: prog_wr <= 8'h2D;  // -
          //   189: prog_wr <= 8'h2D;  // -
          //   190: prog_wr <= 8'h2E;  // .
          //   191: prog_wr <= 8'h2D;  // -
          //   192: prog_wr <= 8'h2D;  // -
          //   193: prog_wr <= 8'h5B;  // [
          //   194: prog_wr <= 8'h2D;  // -
          //   195: prog_wr <= 8'h3E;  // >
          //   196: prog_wr <= 8'h2B;  // +
          //   197: prog_wr <= 8'h2B;  // +
          //   198: prog_wr <= 8'h3C;  // <
          //   199: prog_wr <= 8'h5D;  // ]
          //   200: prog_wr <= 8'h3E;  // >
          //   201: prog_wr <= 8'h2E;  // .
          //   202: prog_wr <= 8'h2D;  // -
          //   203: prog_wr <= 8'h2D;  // -
          //   204: prog_wr <= 8'h2D;  // -
          //   205: prog_wr <= 8'h2D;  // -
          //   206: prog_wr <= 8'h2D;  // -
          //   207: prog_wr <= 8'h2D;  // -
          //   208: prog_wr <= 8'h2D;  // -
          //   209: prog_wr <= 8'h2D;  // -
          //   210: prog_wr <= 8'h2D;  // -
          //   211: prog_wr <= 8'h2E;  // .
          //   default: prog_wr <= 8'h00;  // NOP
          // endcase
          // // --- END AUTO-GENERATED CODE ---


          // --- BEGIN AUTO-GENERATED CODE --- // stress test: https://github.com/rdebath/Brainfuck/blob/master/testing/Bench.b
          // PROGRAM LENGTH (PROG_LEN) should be set to: 74. runs about 16*256^3 instructions.
          case (iptr)
            0: prog_wr <= 8'h2B;  // +
            1: prog_wr <= 8'h2B;  // +
            2: prog_wr <= 8'h2B;  // +
            3: prog_wr <= 8'h2B;  // +
            4: prog_wr <= 8'h2B;  // +
            5: prog_wr <= 8'h2B;  // +
            6: prog_wr <= 8'h2B;  // +
            7: prog_wr <= 8'h2B;  // +
            8: prog_wr <= 8'h5B;  // [
            9: prog_wr <= 8'h2D;  // -
            10: prog_wr <= 8'h3E;  // >
            11: prog_wr <= 8'h2D;  // -
            12: prog_wr <= 8'h5B;  // [
            13: prog_wr <= 8'h2D;  // -
            14: prog_wr <= 8'h3E;  // >
            15: prog_wr <= 8'h2D;  // -
            16: prog_wr <= 8'h5B;  // [
            17: prog_wr <= 8'h2D;  // -
            18: prog_wr <= 8'h3E;  // >
            19: prog_wr <= 8'h2D;  // -
            20: prog_wr <= 8'h5B;  // [
            21: prog_wr <= 8'h2D;  // -
            22: prog_wr <= 8'h5D;  // ]
            23: prog_wr <= 8'h3C;  // <
            24: prog_wr <= 8'h5D;  // ]
            25: prog_wr <= 8'h3C;  // <
            26: prog_wr <= 8'h5D;  // ]
            27: prog_wr <= 8'h3C;  // <
            28: prog_wr <= 8'h5D;  // ]
            29: prog_wr <= 8'h3E;  // >
            30: prog_wr <= 8'h2B;  // +
            31: prog_wr <= 8'h2B;  // +
            32: prog_wr <= 8'h2B;  // +
            33: prog_wr <= 8'h2B;  // +
            34: prog_wr <= 8'h2B;  // +
            35: prog_wr <= 8'h2B;  // +
            36: prog_wr <= 8'h2B;  // +
            37: prog_wr <= 8'h2B;  // +
            38: prog_wr <= 8'h5B;  // [
            39: prog_wr <= 8'h3C;  // <
            40: prog_wr <= 8'h2B;  // +
            41: prog_wr <= 8'h2B;  // +
            42: prog_wr <= 8'h2B;  // +
            43: prog_wr <= 8'h2B;  // +
            44: prog_wr <= 8'h2B;  // +
            45: prog_wr <= 8'h2B;  // +
            46: prog_wr <= 8'h2B;  // +
            47: prog_wr <= 8'h2B;  // +
            48: prog_wr <= 8'h2B;  // +
            49: prog_wr <= 8'h2B;  // +
            50: prog_wr <= 8'h3E;  // >
            51: prog_wr <= 8'h2D;  // -
            52: prog_wr <= 8'h5D;  // ]
            53: prog_wr <= 8'h3C;  // <
            54: prog_wr <= 8'h5B;  // [
            55: prog_wr <= 8'h3E;  // >
            56: prog_wr <= 8'h2B;  // +
            57: prog_wr <= 8'h3E;  // >
            58: prog_wr <= 8'h2B;  // +
            59: prog_wr <= 8'h3C;  // <
            60: prog_wr <= 8'h3C;  // <
            61: prog_wr <= 8'h2D;  // -
            62: prog_wr <= 8'h5D;  // ]
            63: prog_wr <= 8'h3E;  // >
            64: prog_wr <= 8'h2D;  // -
            65: prog_wr <= 8'h2E;  // .
            66: prog_wr <= 8'h3E;  // >
            67: prog_wr <= 8'h2D;  // -
            68: prog_wr <= 8'h2D;  // -
            69: prog_wr <= 8'h2D;  // -
            70: prog_wr <= 8'h2D;  // -
            71: prog_wr <= 8'h2D;  // -
            72: prog_wr <= 8'h2E;  // .
            73: prog_wr <= 8'h3E;  // >
            default: prog_wr <= 8'h00;  // NOP
          endcase
          // --- END AUTO-GENERATED CODE ---

          // // --- BEGIN AUTO-GENERATED CODE ---
          // // PROGRAM LENGTH (PROG_LEN) should be set to: 106
          // case (iptr)
          //   0: prog_wr <= 8'h2B;  // +
          //   1: prog_wr <= 8'h2B;  // +
          //   2: prog_wr <= 8'h2B;  // +
          //   3: prog_wr <= 8'h2B;  // +
          //   4: prog_wr <= 8'h2B;  // +
          //   5: prog_wr <= 8'h2B;  // +
          //   6: prog_wr <= 8'h2B;  // +
          //   7: prog_wr <= 8'h2B;  // +
          //   8: prog_wr <= 8'h5B;  // [
          //   9: prog_wr <= 8'h3E;  // >
          //   10: prog_wr <= 8'h2B;  // +
          //   11: prog_wr <= 8'h2B;  // +
          //   12: prog_wr <= 8'h2B;  // +
          //   13: prog_wr <= 8'h2B;  // +
          //   14: prog_wr <= 8'h5B;  // [
          //   15: prog_wr <= 8'h3E;  // >
          //   16: prog_wr <= 8'h2B;  // +
          //   17: prog_wr <= 8'h2B;  // +
          //   18: prog_wr <= 8'h3E;  // >
          //   19: prog_wr <= 8'h2B;  // +
          //   20: prog_wr <= 8'h2B;  // +
          //   21: prog_wr <= 8'h2B;  // +
          //   22: prog_wr <= 8'h3E;  // >
          //   23: prog_wr <= 8'h2B;  // +
          //   24: prog_wr <= 8'h2B;  // +
          //   25: prog_wr <= 8'h2B;  // +
          //   26: prog_wr <= 8'h3E;  // >
          //   27: prog_wr <= 8'h2B;  // +
          //   28: prog_wr <= 8'h3C;  // <
          //   29: prog_wr <= 8'h3C;  // <
          //   30: prog_wr <= 8'h3C;  // <
          //   31: prog_wr <= 8'h3C;  // <
          //   32: prog_wr <= 8'h2D;  // -
          //   33: prog_wr <= 8'h5D;  // ]
          //   34: prog_wr <= 8'h3E;  // >
          //   35: prog_wr <= 8'h2B;  // +
          //   36: prog_wr <= 8'h3E;  // >
          //   37: prog_wr <= 8'h2B;  // +
          //   38: prog_wr <= 8'h3E;  // >
          //   39: prog_wr <= 8'h2D;  // -
          //   40: prog_wr <= 8'h3E;  // >
          //   41: prog_wr <= 8'h3E;  // >
          //   42: prog_wr <= 8'h2B;  // +
          //   43: prog_wr <= 8'h5B;  // [
          //   44: prog_wr <= 8'h3C;  // <
          //   45: prog_wr <= 8'h5D;  // ]
          //   46: prog_wr <= 8'h3C;  // <
          //   47: prog_wr <= 8'h2D;  // -
          //   48: prog_wr <= 8'h5D;  // ]
          //   49: prog_wr <= 8'h3E;  // >
          //   50: prog_wr <= 8'h3E;  // >
          //   51: prog_wr <= 8'h2E;  // .
          //   52: prog_wr <= 8'h3E;  // >
          //   53: prog_wr <= 8'h2D;  // -
          //   54: prog_wr <= 8'h2D;  // -
          //   55: prog_wr <= 8'h2D;  // -
          //   56: prog_wr <= 8'h2E;  // .
          //   57: prog_wr <= 8'h2B;  // +
          //   58: prog_wr <= 8'h2B;  // +
          //   59: prog_wr <= 8'h2B;  // +
          //   60: prog_wr <= 8'h2B;  // +
          //   61: prog_wr <= 8'h2B;  // +
          //   62: prog_wr <= 8'h2B;  // +
          //   63: prog_wr <= 8'h2B;  // +
          //   64: prog_wr <= 8'h2E;  // .
          //   65: prog_wr <= 8'h2E;  // .
          //   66: prog_wr <= 8'h2B;  // +
          //   67: prog_wr <= 8'h2B;  // +
          //   68: prog_wr <= 8'h2B;  // +
          //   69: prog_wr <= 8'h2E;  // .
          //   70: prog_wr <= 8'h3E;  // >
          //   71: prog_wr <= 8'h3E;  // >
          //   72: prog_wr <= 8'h2E;  // .
          //   73: prog_wr <= 8'h3C;  // <
          //   74: prog_wr <= 8'h2D;  // -
          //   75: prog_wr <= 8'h2E;  // .
          //   76: prog_wr <= 8'h3C;  // <
          //   77: prog_wr <= 8'h2E;  // .
          //   78: prog_wr <= 8'h2B;  // +
          //   79: prog_wr <= 8'h2B;  // +
          //   80: prog_wr <= 8'h2B;  // +
          //   81: prog_wr <= 8'h2E;  // .
          //   82: prog_wr <= 8'h2D;  // -
          //   83: prog_wr <= 8'h2D;  // -
          //   84: prog_wr <= 8'h2D;  // -
          //   85: prog_wr <= 8'h2D;  // -
          //   86: prog_wr <= 8'h2D;  // -
          //   87: prog_wr <= 8'h2D;  // -
          //   88: prog_wr <= 8'h2E;  // .
          //   89: prog_wr <= 8'h2D;  // -
          //   90: prog_wr <= 8'h2D;  // -
          //   91: prog_wr <= 8'h2D;  // -
          //   92: prog_wr <= 8'h2D;  // -
          //   93: prog_wr <= 8'h2D;  // -
          //   94: prog_wr <= 8'h2D;  // -
          //   95: prog_wr <= 8'h2D;  // -
          //   96: prog_wr <= 8'h2D;  // -
          //   97: prog_wr <= 8'h2E;  // .
          //   98: prog_wr <= 8'h3E;  // >
          //   99: prog_wr <= 8'h3E;  // >
          //   100: prog_wr <= 8'h2B;  // +
          //   101: prog_wr <= 8'h2E;  // .
          //   102: prog_wr <= 8'h3E;  // >
          //   103: prog_wr <= 8'h2B;  // +
          //   104: prog_wr <= 8'h2B;  // +
          //   105: prog_wr <= 8'h2E;  // .
          //   default: prog_wr <= 8'h00;  // NOP
          // endcase
          // // --- END AUTO-GENERATED CODE ---


          if (iptr == PROG_LEN) begin
            iptr <= {PROG_ADDR_WIDTH{1'b0}};
            loaded <= 1'b1;
            state_id <= S_IDLE;
          end else begin
            iptr <= iptr + 1;
          end
        end

        // -------------------------------------------------------------------
        // PREPROCESS: set address -> wait -> read -> handle '[' and ']'
        // -------------------------------------------------------------------
        S_PRE_ADDR: begin
          // prog_addr_reg <= iptr;  // request program memory at iptr
          state_id <= S_PRE_READ;
        end

        S_PRE_READ: begin
          // now prog_rd corresponds to iptr
          inst <= prog_rd;

          if (iptr >= PROG_LEN) begin
            iptr <= {PROG_ADDR_WIDTH{1'b0}};
            // preprocessing finished: move to fetch/execute
            state_id <= S_FETCH_ADDR;
          end else if (prog_rd == 8'h5B) begin  // '['
            // push the exact iptr (where '[' is) onto stack
            stack_addr_reg <= stack_ptr;
            stack_wr <= iptr;
            stack_we <= 1'b1;
            stack_ptr <= stack_ptr + 1;

            // continue with next iptr
            iptr <= iptr + 1;
            state_id <= S_PRE_ADDR;
          end else if (prog_rd == 8'h5D) begin  // ']'
            // pop: prepare to read top stack entry (address of matching '[')
            // decrement pointer and set stack read address
            stack_ptr <= stack_ptr - 1;
            stack_addr_reg <= stack_ptr - 1;
            state_id <= S_PRE_STACK_WAIT;
          end else begin
            // ordinary instruction; continue
            iptr <= iptr + 1;
            state_id <= S_PRE_ADDR;
          end
        end

        S_PRE_STACK_WAIT: begin
          state_id <= S_PRE_STACK_READ;
        end

        S_PRE_STACK_READ: begin
          // stack_rd is the matching '[' address
          popped_addr <= stack_rd;

          // write jump_table[stack_rd] = iptr (']' address)
          jump_addr_reg <= stack_rd;
          jump_wr <= iptr;
          jump_we <= 1'b1;

          state_id <= S_PRE_JUMP_W1;
        end

        S_PRE_JUMP_W1: begin
          // write the reverse mapping: jump_table[iptr] = popped_addr
          jump_addr_reg <= iptr;
          jump_wr <= popped_addr;
          jump_we <= 1'b1;

          state_id <= S_PRE_JUMP_DONE;
          // state_id <= S_WAIT_100;
        end

        S_PRE_JUMP_DONE: begin
          // advance to next instruction after ']'
          iptr <= iptr + 1;
          state_id <= S_PRE_ADDR;
        end



        S_FETCH_ADDR: begin
          // set addresses for both program read and jump table read (jump_rd used only for '['/']')
          // prog_addr_reg <= iptr;
          // jump_addr_reg <= iptr;
          exec_count <= exec_count + 1;
          current_cell <= current_cell_next;
          // state_id <= S_FETCH_WAIT;
          state_id <= S_EXECUTE;
        end

        S_EXECUTE: begin
          $strobe("[%0t] EXECUTE IP=%0d INST=%h PTR=%0d CELL=%0h DATA_ADDR=%0d DATA_RD=%0h", $time,
                  iptr, prog_rd, current_ptr, current_cell, data_addr_reg, data_rd);
          case (prog_rd)
            8'h3E: begin  // '>' - increment data pointer
              dptr_next <= dptr + 1;
              // state_id  <= S_PTR_WRITEBACK;
            end

            8'h3C: begin  // '<' - decrement data pointer
              dptr_next <= dptr - 1;
              // state_id  <= S_PTR_WRITEBACK;
            end

            8'h2B: begin  // '+'
              // current_cell <= current_cell + 1;
              current_cell_next <= current_cell + 1;
              // state_id <= S_FETCH_ADDR;
            end

            8'h2D: begin  // '-'
              // current_cell <= current_cell - 1;
              current_cell_next <= current_cell - 1;
              // state_id <= S_FETCH_ADDR;
            end

            8'h2E: begin  // '.'
              output_reg <= current_cell;
              // state_id   <= S_FETCH_ADDR;
            end

            8'h2C: begin  // ',' (input not implemented)
              // state_id <= S_FETCH_ADDR;
            end

            // jumping now implemented by use_jump_rd wire.

            8'h5B: begin  // '[' : if current_cell == 0 -> jump to matching ']' (jump_rd)
              // $strobe("[%0t] could JUMP from '[' at %0d to ']' at %0d because cell==0", $time,
              //         iptr, jmp);
              // if (current_cell == 0) begin
              //   iptr <= jump_rd; // jump_rd contains matching ']' (because we set jump_addr_reg=iptr earlier)
              // end
              // state_id <= S_FETCH_ADDR;
            end

            8'h5D: begin  // ']' : if current_cell != 0 -> jump back to matching '['
              // $strobe("[%0t] could JUMP from ']' at %0d to '[' at %0d because cell!=0", $time,
              //         iptr, jmp);
              // if (current_cell != 0) begin
              //   iptr <= jump_rd;  // jump_rd contains matching '['
              // end
              // state_id <= S_FETCH_ADDR;
            end

            default: begin
              // state_id <= S_FETCH_ADDR;
            end
          endcase

          display <= output_reg;
          // display <= time_reg[21:14];
          if (iptr < PROG_LEN) begin  // todo: edge case where we jump past program??
            iptr <= use_jump_rd ? jump_rd + 1 : iptr + 1;
            jump_addr_reg <= use_jump_rd ? jump_rd + 1 : iptr + 1;
            // state_id <= S_FETCH_ADDR;
            // state_id <= S_STEP_WAIT;

            state_id <= (prog_rd == 8'h3E || prog_rd == 8'h3C) ? S_PTR_WRITEBACK : S_STEP_WAIT;

          end else begin
            // reached end: stop executing
            executing <= 1'b0;
            state_id  <= S_IDLE;
          end
        end

        S_PTR_WRITEBACK: begin
          data_addr_reg <= current_ptr;  // old pointer
          data_wr       <= current_cell;
          data_we       <= 1'b1;
          state_id      <= S_PTR_READ_SETUP;
        end

        S_PTR_READ_SETUP: begin
          $strobe("[%0t] READ_SETUP -> request read addr=%0d", $time, dptr_next);
          dptr          <= dptr_next;  // move logical pointer
          current_ptr   <= dptr_next;
          data_addr_reg <= dptr_next;  // request new address read
          state_id      <= S_PTR_READ_WAIT;
        end

        S_PTR_READ_WAIT: begin
          state_id <= S_PTR_READ_LATCH;
        end

        S_PTR_READ_LATCH: begin
          $strobe("[%0t] READ_LATCH -> got data_rd=%0h for addr=%0d", $time, data_addr_reg,
                  data_rd);
          current_cell_next <= data_rd;
          state_id          <= S_FETCH_ADDR;
        end

        // S_UPDATE: begin
        //   // $strobe("[%0t] S_UPDATE -> current_cell_next=%0h", $time, current_cell_next);
        //   // display <= output_reg;
        //   // // display <= time_reg[21:14];
        //   // if (iptr < PROG_LEN) begin
        //   //   iptr <= iptr + 1;
        //   //   jump_addr_reg <= iptr + 1;
        //   //   state_id <= S_FETCH_ADDR;
        //   //   // state_id <= S_STEP_WAIT;
        //   // end else begin
        //   //   // reached end: stop executing
        //   //   executing <= 1'b0;
        //   //   state_id  <= S_IDLE;
        //   // end
        //   current_cell <= current_cell_next;
        // end

        S_STEP_WAIT: begin
          // if current inst was . then wait for step_req before next fetch
          if (prog_rd == 8'h2E) begin
            if (step_req) begin
              state_id <= S_FETCH_ADDR;
            end
          end else begin
            state_id <= S_FETCH_ADDR;
          end
        end

        default: begin
          state_id <= S_IDLE;
        end
      endcase

    end
  end

endmodule





// `default_nettype none
// module cpu_core #(
//     parameter PROG_ADDR_WIDTH = 10,
//     parameter PROG_LEN = 50
// ) (
//     input  wire       clk,
//     input  wire       resetn,
//     input  wire       start_req,
//     input  wire       load_req,
//     output reg        loaded,
//     output reg        executing,
//     output reg  [3:0] state_id,
//     output reg  [7:0] display
// );

//   localparam IDLE = 4'd0;
//   localparam LOAD = 4'd1;
//   localparam PRE_ADDR = 4'd2;
//   localparam PRE_READ = 4'd3;
//   localparam PRE_STACK_READ = 4'd4;
//   localparam PRE_JUMP_W1 = 4'd5;
//   localparam PRE_JUMP_DONE = 4'd6;
//   localparam FETCH = 4'd7;
//   localparam WAIT_READ = 4'd8;
//   localparam EXECUTE = 4'd10;
//   localparam UPDATE = 4'd11;
//   localparam POINTER_WRITEBACK = 4'd12;
//   localparam POINTER_READ = 4'd13;
//   localparam POINTER_WAIT = 4'd14;

//   // Program memory
//   reg [PROG_ADDR_WIDTH-1:0] iptr;
//   reg [PROG_ADDR_WIDTH-1:0] prog_addr_reg;
//   reg [7:0] prog_wr;
//   reg prog_we;
//   wire [7:0] prog_rd;

//   bram_sp #(
//       .ADDR_WIDTH(PROG_ADDR_WIDTH),
//       .DATA_WIDTH(8)
//   ) program_memory (
//       .clk(clk),
//       .write_enable(prog_we),
//       .addr(prog_addr_reg),
//       .data_in(prog_wr),
//       .data_out(prog_rd)
//   );

//   // Data memory with cached cell
//   reg [PROG_ADDR_WIDTH-1:0] dptr;
//   reg [PROG_ADDR_WIDTH-1:0] dptr_next;
//   reg [PROG_ADDR_WIDTH-1:0] data_addr_reg;
//   reg [7:0] data_wr;
//   reg data_we;
//   wire [7:0] data_rd;

//   // INVARIANT: current_cell always holds the value at current_ptr
//   reg [7:0] current_cell;
//   reg [PROG_ADDR_WIDTH-1:0] current_ptr;

//   bram_sp #(
//       .ADDR_WIDTH(PROG_ADDR_WIDTH),
//       .DATA_WIDTH(8)
//   ) data_memory (
//       .clk(clk),
//       .write_enable(data_we),
//       .addr(data_addr_reg),
//       .data_in(data_wr),
//       .data_out(data_rd)
//   );

//   // Bracket stack
//   reg [PROG_ADDR_WIDTH-1:0] stack_ptr;
//   reg [PROG_ADDR_WIDTH-1:0] stack_addr_reg;
//   reg [PROG_ADDR_WIDTH-1:0] stack_wr;
//   reg stack_we;
//   wire [PROG_ADDR_WIDTH-1:0] stack_rd;

//   bram_sp #(
//       .ADDR_WIDTH(PROG_ADDR_WIDTH),
//       .DATA_WIDTH(PROG_ADDR_WIDTH)
//   ) bracket_stack (
//       .clk(clk),
//       .write_enable(stack_we),
//       .addr(stack_addr_reg),
//       .data_in(stack_wr),
//       .data_out(stack_rd)
//   );

//   // Jump table
//   reg [PROG_ADDR_WIDTH-1:0] jump_addr_reg;
//   reg [PROG_ADDR_WIDTH-1:0] jump_wr;
//   reg jump_we;
//   wire [PROG_ADDR_WIDTH-1:0] jump_rd;

//   bram_sp #(
//       .ADDR_WIDTH(PROG_ADDR_WIDTH),
//       .DATA_WIDTH(PROG_ADDR_WIDTH)
//   ) jump_table (
//       .clk(clk),
//       .write_enable(jump_we),
//       .addr(jump_addr_reg),
//       .data_in(jump_wr),
//       .data_out(jump_rd)
//   );

//   reg [7:0] inst;
//   reg [7:0] output_reg;
//   reg [7:0] exec_count;
//   reg [PROG_ADDR_WIDTH-1:0] popped_addr;


//   // always @(posedge clk) begin
//   //   if (!resetn) $display("[%0t] reset", $time);
//   //   else begin
//   //     $display("[%0t] state=%0d iptr=%0d prog_we=%b loaded=%b", $time, state_id, iptr, prog_we,
//   //              loaded);
//   //   end
//   // end

//   // always @(posedge clk)
//   //   if (resetn)
//   //     $strobe("[%0t] state=%0d iptr=%0d prog_rd=%02h", $time, state_id, iptr, prog_rd);

//   always @(posedge clk or negedge resetn) begin
//     if (!resetn) begin
//       state_id <= IDLE;
//       loaded <= 0;
//       executing <= 0;
//       display <= 8'h00;

//       prog_we <= 0;
//       data_we <= 0;
//       stack_we <= 0;
//       jump_we <= 0;

//       iptr <= 0;
//       prog_addr_reg <= 0;
//       dptr <= 0;
//       dptr_next <= 0;
//       data_addr_reg <= 0;
//       stack_ptr <= 0;
//       stack_addr_reg <= 0;
//       jump_addr_reg <= 0;

//       inst <= 0;
//       output_reg <= 0;
//       exec_count <= 0;
//       popped_addr <= 0;

//       current_cell <= 0;
//       current_ptr <= 0;

//     end else begin
//       prog_we  <= 0;
//       data_we  <= 0;
//       stack_we <= 0;
//       jump_we  <= 0;

//       case (state_id)
//         IDLE: begin
//           executing <= 0;
//           if (load_req) begin
//             loaded <= 0;
//             iptr <= 0;
//             prog_addr_reg <= 0;
//             state_id <= LOAD;
//           end else if (start_req && loaded) begin
//             executing <= 1;
//             iptr <= 0;
//             prog_addr_reg <= 0;
//             exec_count <= 0;

//             // Initialize data pointer and cache (cells start at 0 in Brainfuck)
//             dptr <= 0;
//             current_ptr <= 0;
//             current_cell <= 0;

//             // Prepare preprocessing
//             stack_ptr <= 0;
//             stack_addr_reg <= 0;
//             jump_addr_reg <= 0;
//             popped_addr <= 0;
//             state_id <= PRE_ADDR;
//           end
//         end

//         LOAD: begin
//           prog_we <= 1;
//           prog_addr_reg <= iptr;

//           // // program: +++.
//           // case (iptr)
//           //   0: prog_wr <= 8'h2B;  // +
//           //   1: prog_wr <= 8'h2B;  // +
//           //   2: prog_wr <= 8'h2B;  // +
//           //   3: prog_wr <= 8'h2E;  // .
//           //   default: prog_wr <= 8'h00;
//           // endcase

//           // // program: >>>+++.+.
//           // case (iptr)
//           //   0: prog_wr <= 8'h3E;  // >
//           //   1: prog_wr <= 8'h3E;  // >
//           //   2: prog_wr <= 8'h3E;  // >
//           //   3: prog_wr <= 8'h2B;  // +
//           //   4: prog_wr <= 8'h2B;  // +
//           //   5: prog_wr <= 8'h2B;  // +
//           //   6: prog_wr <= 8'h2E;  // .
//           //   1000: prog_wr <= 8'h2B;  // +
//           //   1001: prog_wr <= 8'h2E;  // .
//           //   default: prog_wr <= 8'h00;
//           // endcase

//           // // program: +++[-.]++.
//           // case (iptr)
//           //   0: prog_wr <= 8'h2B;  // +
//           //   1: prog_wr <= 8'h2B;  // +
//           //   2: prog_wr <= 8'h2B;  // +
//           //   3: prog_wr <= 8'h5B;  // [
//           //   4: prog_wr <= 8'h2D;  // -
//           //   5: prog_wr <= 8'h2E;  // .
//           //   6: prog_wr <= 8'h5D;  // ]
//           //   7: prog_wr <= 8'h2B;  // +
//           //   8: prog_wr <= 8'h2B;  // +
//           //   9: prog_wr <= 8'h2E;  // .
//           //   default: prog_wr <= 8'h00;
//           // endcase


//           // program: +.+.+.[.>.+.+.+.<.-.].>.
//           case (iptr)
//             0: prog_wr <= 8'h2B;  // +
//             1: prog_wr <= 8'h2E;  // .
//             2: prog_wr <= 8'h2B;  // +
//             3: prog_wr <= 8'h2E;  // .
//             4: prog_wr <= 8'h2B;  // +
//             5: prog_wr <= 8'h2E;  // .
//             6: prog_wr <= 8'h5B;  // [
//             7: prog_wr <= 8'h2E;  // .
//             8: prog_wr <= 8'h3E;  // >
//             9: prog_wr <= 8'h2B;  // +
//             10: prog_wr <= 8'h2E;  // .
//             11: prog_wr <= 8'h2B;  // +
//             12: prog_wr <= 8'h2E;  // .
//             13: prog_wr <= 8'h2B;  // +
//             14: prog_wr <= 8'h2E;  // .
//             15: prog_wr <= 8'h3C;  // <
//             16: prog_wr <= 8'h2D;  // -
//             17: prog_wr <= 8'h2E;  // .
//             18: prog_wr <= 8'h5D;  // ]
//             19: prog_wr <= 8'h3E;  // >
//             20: prog_wr <= 8'h2E;  // .
//             default: prog_wr <= 8'h00;
//           endcase

//           // // Program: >++++[<+++++++>-]<.
//           // case (iptr)
//           //   0: prog_wr <= 8'h3E;  // >
//           //   1: prog_wr <= 8'h2B;  // +
//           //   2: prog_wr <= 8'h2B;  // +
//           //   3: prog_wr <= 8'h2B;  // +
//           //   4: prog_wr <= 8'h2B;  // +
//           //   5: prog_wr <= 8'h5B;  // [
//           //   6: prog_wr <= 8'h3C;  // 
//           //   7: prog_wr <= 8'h2B;  // +
//           //   8: prog_wr <= 8'h2B;  // +
//           //   9: prog_wr <= 8'h2B;  // +
//           //   10: prog_wr <= 8'h2B;  // +
//           //   11: prog_wr <= 8'h2B;  // +
//           //   12: prog_wr <= 8'h2B;  // +
//           //   13: prog_wr <= 8'h2B;  // +
//           //   14: prog_wr <= 8'h3E;  // >
//           //   15: prog_wr <= 8'h2D;  // -
//           //   16: prog_wr <= 8'h5D;  // ]
//           //   17: prog_wr <= 8'h3C;  // 
//           //   18: prog_wr <= 8'h2E;  // .
//           //   default: prog_wr <= 8'h00;
//           // endcase

//           if (iptr == PROG_LEN) begin
//             iptr <= 0;
//             loaded <= 1;
//             state_id <= IDLE;
//           end else begin
//             iptr <= iptr + 1;
//           end
//         end

//         PRE_ADDR: begin
//           prog_addr_reg <= iptr;
//           state_id <= PRE_READ;
//         end

//         PRE_READ: begin
//           inst <= prog_rd;
//           if (iptr >= PROG_LEN) begin
//             iptr <= 0;
//             state_id <= FETCH;
//           end else if (prog_rd == 8'h5B) begin  // '['
//             stack_addr_reg <= stack_ptr;
//             // stack_wr <= iptr;
//             stack_wr <= iptr - 1;
//             stack_we <= 1;
//             stack_ptr <= stack_ptr + 1;
//             iptr <= iptr + 1;
//             state_id <= PRE_ADDR;
//           end else if (prog_rd == 8'h5D) begin  // ']'
//             stack_ptr <= stack_ptr - 1;
//             stack_addr_reg <= stack_ptr - 1;
//             state_id <= PRE_STACK_READ;
//           end else begin
//             iptr <= iptr + 1;
//             state_id <= PRE_ADDR;
//           end
//         end

//         PRE_STACK_READ: begin
//           popped_addr <= stack_rd;
//           jump_addr_reg <= iptr;
//           jump_wr <= stack_rd;
//           jump_we <= 1;
//           state_id <= PRE_JUMP_W1;
//           $strobe("[%0t] jump table write: from=%0d to=%0d", $time, iptr, stack_rd);
//         end

//         PRE_JUMP_W1: begin
//           jump_addr_reg <= popped_addr;
//           jump_wr <= iptr;
//           jump_we <= 1;
//           state_id <= PRE_JUMP_DONE;
//           $strobe("[%0t] jump table write: from=%0d to=%0d", $time, popped_addr, iptr);
//           // iptr <= iptr + 1;
//           // state_id <= PRE_ADDR;
//         end

//         PRE_JUMP_DONE: begin
//           iptr <= iptr + 1;
//           state_id <= PRE_ADDR;
//         end

//         FETCH: begin
//           prog_addr_reg <= iptr;
//           jump_addr_reg <= iptr;
//           exec_count <= exec_count + 1;
//           state_id <= WAIT_READ;
//         end

//         WAIT_READ: begin
//           inst <= prog_rd;
//           state_id <= EXECUTE;
//         end

//         EXECUTE: begin
//           case (inst)
//             8'h3E: begin  // '>' - Change pointer
//               dptr_next <= dptr + 1;
//               state_id  <= POINTER_WRITEBACK;
//             end
//             8'h3C: begin  // '<' - Change pointer
//               dptr_next <= dptr - 1;
//               state_id  <= POINTER_WRITEBACK;
//             end
//             8'h2B: begin  // '+' - Increment current cell (cached!)
//               current_cell <= current_cell + 1;
//               state_id <= UPDATE;
//             end
//             8'h2D: begin  // '-' - Decrement current cell (cached!)
//               current_cell <= current_cell - 1;
//               state_id <= UPDATE;
//             end
//             8'h2E: begin  // '.' - Output current cell (cached!)
//               output_reg <= current_cell;
//               state_id   <= UPDATE;
//             end
//             8'h2C: begin  // ','
//               // No input for now
//               state_id <= UPDATE;
//             end
//             8'h5B: begin  // '[' - Check current cell (cached!)
//               if (current_cell == 0) begin
//                 iptr <= jump_rd;
//               end
//               state_id <= UPDATE;
//             end
//             8'h5D: begin  // ']' - Check current cell (cached!)
//               if (current_cell != 0) begin
//                 iptr <= jump_rd;
//               end
//               state_id <= UPDATE;
//             end
//             default: begin
//               state_id <= UPDATE;
//             end
//           endcase
//         end

//         POINTER_WRITEBACK: begin
//           // Write current cached cell back to BRAM at old address
//           data_addr_reg <= current_ptr;
//           data_wr <= current_cell;
//           data_we <= 1;

//           // Update pointers
//           dptr <= dptr_next;
//           current_ptr <= dptr_next;

//           state_id <= POINTER_READ;
//         end

//         POINTER_READ: begin
//           // Set up read of new cell from BRAM
//           data_addr_reg <= current_ptr;
//           state_id <= POINTER_WAIT;
//         end

//         POINTER_WAIT: begin
//           // Latch the new cell value - invariant restored!
//           current_cell <= data_rd;
//           state_id <= UPDATE;
//         end

//         UPDATE: begin
//           if (iptr < PROG_LEN) begin
//             iptr <= iptr + 1;
//             state_id <= FETCH;
//           end else begin
//             executing <= 0;
//             state_id  <= IDLE;
//           end
//           display <= output_reg;
//         end

//         default: state_id <= IDLE;
//       endcase
//     end
//   end
// endmodule
