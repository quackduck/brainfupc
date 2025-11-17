`default_nettype none
module cpu_core #(
    parameter PROG_ADDR_WIDTH = 14,
    parameter PROG_LEN = 16383
) (
    input  wire       clk,
    // input  wire [21:0] time_reg,
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

  reg  [PROG_ADDR_WIDTH-1:0] iptr;
  reg  [                7:0] prog_wr;
  reg                        prog_we;

  wire [               15:0] _prog_rd;
  wire [                7:0] prog_rd = _prog_rd[7:0];  // only lower 8 bits used

  spram_stupid program_memory (
      .clk(clk),
      .write_enable(prog_we),
      .addr(iptr),
      .data_in({8'h00, prog_wr}),
      .data_out(_prog_rd)
  );

  // brainfuck data tape
  reg  [PROG_ADDR_WIDTH-1:0] data_addr_reg;
  reg  [                7:0] data_wr;
  reg                        data_we;
  wire [               15:0] _data_rd;
  wire [                7:0] data_rd = _data_rd[7:0];  // only lower 8 bits used

  spram_stupid data_memory (
      .clk(clk),
      .write_enable(data_we),
      .addr(data_addr_reg),
      .data_in({8'h00, data_wr}),
      .data_out(_data_rd)
  );

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

  // bram_sp #(
  //     .ADDR_WIDTH(PROG_ADDR_WIDTH),
  //     .DATA_WIDTH(PROG_ADDR_WIDTH)
  // ) jump_table (
  //     .clk(clk),
  //     .write_enable(jump_we),
  //     .addr(jump_addr_reg),
  //     .data_in(jump_wr),
  //     .data_out(jump_rd)
  // );

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
      loaded            <= 1'b0;
      executing         <= 1'b0;
      display           <= 8'h00;

      prog_we           <= 1'b0;
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
      prog_we  <= 1'b0;
      data_we  <= 1'b0;
      stack_we <= 1'b0;
      jump_we  <= 1'b0;

      case (state_id)
        S_IDLE: begin
          executing <= 1'b0;
          if (load_req) begin
            loaded <= 1'b0;
            iptr <= {PROG_ADDR_WIDTH{1'b0}};
            state_id <= S_LOAD;
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

        S_LOAD: begin
          prog_we <= 1'b1;

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
          //   1: prog_wr <= 8'h2B;  // +
          //   2: prog_wr <= 8'h2E;  // .
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
