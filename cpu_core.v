`default_nettype none
module cpu_core #(
    parameter PROG_ADDR_WIDTH = 10,
    parameter PROG_LEN = 108
) (
    input  wire       clk,
    input  wire       resetn,
    input  wire       start_req,
    input  wire       step_req,
    input  wire       load_req,
    output reg        loaded,
    output reg        executing,
    output reg  [4:0] state_id,
    output reg  [7:0] display
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
  localparam S_UPDATE = 5'd13;

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
  reg  [PROG_ADDR_WIDTH-1:0] prog_addr_reg;
  reg  [                7:0] prog_wr;
  reg                        prog_we;
  wire [                7:0] prog_rd;

  bram_sp #(
      .ADDR_WIDTH(PROG_ADDR_WIDTH),
      .DATA_WIDTH(8)
  ) program_memory (
      .clk(clk),
      .write_enable(prog_we),
      .addr(prog_addr_reg),
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
  reg  [PROG_ADDR_WIDTH-1:0] stack_addr_reg;
  reg  [PROG_ADDR_WIDTH-1:0] stack_wr;
  reg                        stack_we;
  wire [PROG_ADDR_WIDTH-1:0] stack_rd;
  reg  [PROG_ADDR_WIDTH-1:0] stack_ptr;

  bram_sp #(
      .ADDR_WIDTH(PROG_ADDR_WIDTH),
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

  // -------------------------------------------------------------------------
  // Control + misc regs
  // -------------------------------------------------------------------------
  reg     [PROG_ADDR_WIDTH-1:0] iptr;
  reg     [                7:0] inst;
  reg     [PROG_ADDR_WIDTH-1:0] jmp;
  reg     [                7:0] output_reg;
  reg     [                7:0] exec_count;
  reg     [PROG_ADDR_WIDTH-1:0] popped_addr;

  reg     [PROG_ADDR_WIDTH-1:0] zero_ptr;
  reg     [                7:0] current_cell_next;

  // -------------------------------------------------------------------------
  // Reset / default initialization
  // -------------------------------------------------------------------------
  integer                       i;
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

      prog_addr_reg     <= {PROG_ADDR_WIDTH{1'b0}};
      dptr              <= {PROG_ADDR_WIDTH{1'b0}};
      dptr_next         <= {PROG_ADDR_WIDTH{1'b0}};
      data_addr_reg     <= {PROG_ADDR_WIDTH{1'b0}};

      current_ptr       <= {PROG_ADDR_WIDTH{1'b0}};
      current_cell      <= 8'h00;
      current_cell_next <= 8'h00;

      stack_ptr         <= {PROG_ADDR_WIDTH{1'b0}};
      stack_addr_reg    <= {PROG_ADDR_WIDTH{1'b0}};
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
            prog_addr_reg <= {PROG_ADDR_WIDTH{1'b0}};
            state_id <= S_LOAD;
          end else if (start_req && loaded) begin
            executing <= 1'b1;
            iptr <= {PROG_ADDR_WIDTH{1'b0}};
            prog_addr_reg <= {PROG_ADDR_WIDTH{1'b0}};
            exec_count <= 8'h00;

            // initialize data/cache
            dptr <= {PROG_ADDR_WIDTH{1'b0}};
            current_ptr <= {PROG_ADDR_WIDTH{1'b0}};
            current_cell <= 8'h00;

            // preprocessing state init
            stack_ptr <= {PROG_ADDR_WIDTH{1'b0}};
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
          prog_addr_reg <= iptr;

          // // program: +++.>++.<.>.>.
          // case (iptr)
          //   0: prog_wr <= 8'h2B;  // +
          //   1: prog_wr <= 8'h2B;  // +
          //   2: prog_wr <= 8'h2B;  // +
          //   3: prog_wr <= 8'h2E;  // .
          //   4: prog_wr <= 8'h3E;  // >
          //   5: prog_wr <= 8'h2B;  // +
          //   6: prog_wr <= 8'h2B;  // +
          //   7: prog_wr <= 8'h2E;  // .
          //   8: prog_wr <= 8'h3C;  // <
          //   9: prog_wr <= 8'h2E;  // .
          //   10: prog_wr <= 8'h3E;  // >
          //   11: prog_wr <= 8'h2E;  // .
          //   12: prog_wr <= 8'h3E;  // >
          //   13: prog_wr <= 8'h2E;  // .
          //   default: prog_wr <= 8'h00;
          // endcase

          // // program: +++.>++.<.>.
          // case (iptr)
          //   0: prog_wr <= 8'h2B;  // +
          //   1: prog_wr <= 8'h2B;  // +
          //   2: prog_wr <= 8'h2B;  // +
          //   3: prog_wr <= 8'h2E;  // .
          //   4: prog_wr <= 8'h3E;  // >
          //   5: prog_wr <= 8'h2B;  // +
          //   6: prog_wr <= 8'h2B;  // +
          //   7: prog_wr <= 8'h2E;  // .
          //   8: prog_wr <= 8'h3C;  // <
          //   9: prog_wr <= 8'h2E;  // .
          //   10: prog_wr <= 8'h3E;  // >
          //   11: prog_wr <= 8'h2E;  // .
          //   default: prog_wr <= 8'h00;
          // endcase

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


          // --- BEGIN AUTO-GENERATED CODE ---
          // PROGRAM LENGTH (PROG_LEN) should be set to: 106
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
            9: prog_wr <= 8'h3E;  // >
            10: prog_wr <= 8'h2B;  // +
            11: prog_wr <= 8'h2B;  // +
            12: prog_wr <= 8'h2B;  // +
            13: prog_wr <= 8'h2B;  // +
            14: prog_wr <= 8'h5B;  // [
            15: prog_wr <= 8'h3E;  // >
            16: prog_wr <= 8'h2B;  // +
            17: prog_wr <= 8'h2B;  // +
            18: prog_wr <= 8'h3E;  // >
            19: prog_wr <= 8'h2B;  // +
            20: prog_wr <= 8'h2B;  // +
            21: prog_wr <= 8'h2B;  // +
            22: prog_wr <= 8'h3E;  // >
            23: prog_wr <= 8'h2B;  // +
            24: prog_wr <= 8'h2B;  // +
            25: prog_wr <= 8'h2B;  // +
            26: prog_wr <= 8'h3E;  // >
            27: prog_wr <= 8'h2B;  // +
            28: prog_wr <= 8'h3C;  // <
            29: prog_wr <= 8'h3C;  // <
            30: prog_wr <= 8'h3C;  // <
            31: prog_wr <= 8'h3C;  // <
            32: prog_wr <= 8'h2D;  // -
            33: prog_wr <= 8'h5D;  // ]
            34: prog_wr <= 8'h3E;  // >
            35: prog_wr <= 8'h2B;  // +
            36: prog_wr <= 8'h3E;  // >
            37: prog_wr <= 8'h2B;  // +
            38: prog_wr <= 8'h3E;  // >
            39: prog_wr <= 8'h2D;  // -
            40: prog_wr <= 8'h3E;  // >
            41: prog_wr <= 8'h3E;  // >
            42: prog_wr <= 8'h2B;  // +
            43: prog_wr <= 8'h5B;  // [
            44: prog_wr <= 8'h3C;  // <
            45: prog_wr <= 8'h5D;  // ]
            46: prog_wr <= 8'h3C;  // <
            47: prog_wr <= 8'h2D;  // -
            48: prog_wr <= 8'h5D;  // ]
            49: prog_wr <= 8'h3E;  // >
            50: prog_wr <= 8'h3E;  // >
            51: prog_wr <= 8'h2E;  // .
            52: prog_wr <= 8'h3E;  // >
            53: prog_wr <= 8'h2D;  // -
            54: prog_wr <= 8'h2D;  // -
            55: prog_wr <= 8'h2D;  // -
            56: prog_wr <= 8'h2E;  // .
            57: prog_wr <= 8'h2B;  // +
            58: prog_wr <= 8'h2B;  // +
            59: prog_wr <= 8'h2B;  // +
            60: prog_wr <= 8'h2B;  // +
            61: prog_wr <= 8'h2B;  // +
            62: prog_wr <= 8'h2B;  // +
            63: prog_wr <= 8'h2B;  // +
            64: prog_wr <= 8'h2E;  // .
            65: prog_wr <= 8'h2E;  // .
            66: prog_wr <= 8'h2B;  // +
            67: prog_wr <= 8'h2B;  // +
            68: prog_wr <= 8'h2B;  // +
            69: prog_wr <= 8'h2E;  // .
            70: prog_wr <= 8'h3E;  // >
            71: prog_wr <= 8'h3E;  // >
            72: prog_wr <= 8'h2E;  // .
            73: prog_wr <= 8'h3C;  // <
            74: prog_wr <= 8'h2D;  // -
            75: prog_wr <= 8'h2E;  // .
            76: prog_wr <= 8'h3C;  // <
            77: prog_wr <= 8'h2E;  // .
            78: prog_wr <= 8'h2B;  // +
            79: prog_wr <= 8'h2B;  // +
            80: prog_wr <= 8'h2B;  // +
            81: prog_wr <= 8'h2E;  // .
            82: prog_wr <= 8'h2D;  // -
            83: prog_wr <= 8'h2D;  // -
            84: prog_wr <= 8'h2D;  // -
            85: prog_wr <= 8'h2D;  // -
            86: prog_wr <= 8'h2D;  // -
            87: prog_wr <= 8'h2D;  // -
            88: prog_wr <= 8'h2E;  // .
            89: prog_wr <= 8'h2D;  // -
            90: prog_wr <= 8'h2D;  // -
            91: prog_wr <= 8'h2D;  // -
            92: prog_wr <= 8'h2D;  // -
            93: prog_wr <= 8'h2D;  // -
            94: prog_wr <= 8'h2D;  // -
            95: prog_wr <= 8'h2D;  // -
            96: prog_wr <= 8'h2D;  // -
            97: prog_wr <= 8'h2E;  // .
            98: prog_wr <= 8'h3E;  // >
            99: prog_wr <= 8'h3E;  // >
            100: prog_wr <= 8'h2B;  // +
            101: prog_wr <= 8'h2E;  // .
            102: prog_wr <= 8'h3E;  // >
            103: prog_wr <= 8'h2B;  // +
            104: prog_wr <= 8'h2B;  // +
            105: prog_wr <= 8'h2E;  // .
            default: prog_wr <= 8'h00;  // NOP
          endcase
          // --- END AUTO-GENERATED CODE ---


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
          prog_addr_reg <= iptr;  // request program memory at iptr
          state_id <= S_PRE_WAIT;
        end

        S_PRE_WAIT: begin
          // one cycle for prog_rd to become valid
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
          // one-cycle wait for stack_rd (synchronous BRAM)
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
          $strobe("[%6t] PRE: mapping '[' at %0d -> ']' at %0d", $time, popped_addr, iptr);
        end

        S_STACK_WRITE_WAIT1: begin
          // delay for jump table write to complete
          state_id <= S_PRE_JUMP_W1;
        end

        S_PRE_JUMP_W1: begin
          // write the reverse mapping: jump_table[iptr] = popped_addr
          jump_addr_reg <= iptr;
          jump_wr <= popped_addr;
          jump_we <= 1'b1;

          $strobe("[%6t] PRE: mapping ']' at %0d -> '[' at %0d", $time, iptr, popped_addr);

          // state_id <= S_PRE_JUMP_DONE;
          state_id <= S_WAIT_100;
        end

        S_WAIT_100: begin
          state_id <= S_PRE_JUMP_DONE;
        end

        S_PRE_JUMP_DONE: begin
          // advance to next instruction after ']'
          iptr <= iptr + 1;
          state_id <= S_PRE_ADDR;
        end

        // -------------------------------------------------------------------
        // FETCH/EXECUTE: read inst and jump table (when needed) with a wait cycle
        // -------------------------------------------------------------------
        S_FETCH_ADDR: begin
          // set addresses for both program read and jump table read (jump_rd used only for '['/']')
          prog_addr_reg <= iptr;
          jump_addr_reg <= iptr;
          exec_count <= exec_count + 1;
          state_id <= S_FETCH_WAIT;
        end

        S_FETCH_WAIT: begin
          state_id <= S_FETCH_LATCH;
        end

        S_FETCH_LATCH: begin
          // now prog_rd and jump_rd are valid for iptr
          inst <= prog_rd;
          jmp <= jump_rd;
          state_id <= S_EXECUTE;
        end


        S_EXECUTE: begin
          $strobe("[%0t] EXECUTE IP=%0d INST=%h PTR=%0d CELL=%0h DATA_ADDR=%0d DATA_RD=%0h", $time,
                  iptr, prog_rd, current_ptr, current_cell, data_addr_reg, data_rd);
          case (inst)
            8'h3E: begin  // '>' - increment data pointer
              dptr_next <= dptr + 1;
              state_id  <= S_PTR_WRITEBACK;
            end

            8'h3C: begin  // '<' - decrement data pointer
              dptr_next <= dptr - 1;
              state_id  <= S_PTR_WRITEBACK;
            end

            8'h2B: begin  // '+'
              // current_cell <= current_cell + 1;
              current_cell_next <= current_cell + 1;
              state_id <= S_UPDATE;
            end

            8'h2D: begin  // '-'
              // current_cell <= current_cell - 1;
              current_cell_next <= current_cell - 1;
              state_id <= S_UPDATE;
            end

            8'h2E: begin  // '.'
              output_reg <= current_cell;
              state_id   <= S_UPDATE;
            end

            8'h2C: begin  // ',' (input not implemented)
              state_id <= S_UPDATE;
            end

            8'h5B: begin  // '[' : if current_cell == 0 -> jump to matching ']' (jump_rd)
              $strobe("[%0t] could JUMP from '[' at %0d to ']' at %0d because cell==0", $time,
                      iptr, jmp);
              if (current_cell == 0) begin
                iptr <= jmp; // jump_rd contains matching ']' (because we set jump_addr_reg=iptr earlier)
              end
              state_id <= S_UPDATE;
            end

            8'h5D: begin  // ']' : if current_cell != 0 -> jump back to matching '['
              $strobe("[%0t] could JUMP from ']' at %0d to '[' at %0d because cell!=0", $time,
                      iptr, jmp);
              if (current_cell != 0) begin
                iptr <= jmp;  // jump_rd contains matching '['
              end
              state_id <= S_UPDATE;
            end

            default: begin
              state_id <= S_UPDATE;
            end
          endcase
        end

        // --- WRITEBACK: write cached cell to old address ---
        S_PTR_WRITEBACK: begin
          $strobe(
              "[%0t] WRITEBACK start: write_addr=%0d write_data=%0h (current_ptr=%0d dptr_next=%0d)",
              $time, current_ptr, current_cell, current_ptr, dptr_next);
          data_addr_reg <= current_ptr;  // old pointer
          data_wr       <= current_cell;
          data_we       <= 1'b1;
          state_id      <= S_PTR_WRITE_WAIT;
        end

        // --- WAIT: let BRAM register the write ---
        S_PTR_WRITE_WAIT: begin
          data_we  <= 1'b0;  // turn off write
          state_id <= S_PTR_READ_SETUP;
        end

        // --- READ_SETUP: prepare to read new cell from new pointer ---
        S_PTR_READ_SETUP: begin
          $strobe("[%0t] READ_SETUP -> request read addr=%0d", $time, dptr_next);
          dptr          <= dptr_next;  // move logical pointer
          current_ptr   <= dptr_next;
          data_addr_reg <= dptr_next;  // request new address read
          state_id      <= S_PTR_READ_WAIT;
        end

        // --- READ_WAIT: wait one cycle for BRAM output ---
        S_PTR_READ_WAIT: begin
          // $strobe("[%0t] READ_WAIT -> got data_rd=%0h for addr=%0d, current_cell(before)=%0h",
          //         $time, data_rd, data_addr_reg, current_cell);
          // current_cell <= data_rd;  // latch new cell value
          // current_cell_next <= data_rd;
          state_id <= S_PTR_READ_LATCH;
          // $strobe("[%0t] READ_WAIT -> current cell after update=%0h", $time, current_cell);
        end

        S_PTR_READ_LATCH: begin
          $strobe("[%0t] READ_LATCH -> got data_rd=%0h for addr=%0d", $time, data_addr_reg,
                  data_rd);
          current_cell_next <= data_rd;
          state_id          <= S_UPDATE;
        end

        S_UPDATE: begin
          $strobe("[%0t] S_UPDATE -> current_cell_next=%0h", $time, current_cell_next);
          display <= output_reg;
          // normal advance
          if (iptr < PROG_LEN) begin
            iptr <= iptr + 1;
            // state_id <= S_FETCH_ADDR;
            state_id <= S_STEP_WAIT;
          end else begin
            // reached program end: stop executing
            executing <= 1'b0;
            state_id  <= S_IDLE;
          end
          current_cell <= current_cell_next;
        end

        S_STEP_WAIT: begin
          // if (step_req) begin
          state_id <= S_FETCH_ADDR;
          // end
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
