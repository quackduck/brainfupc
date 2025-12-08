`default_nettype none
module cpu_core #(
    parameter int PROG_ADDR_WIDTH = 14  // max prog len is 2^14 = 16384 insts
) (
    input logic clk,

    input  logic [14:0] vga_data_addr,
    output logic [ 7:0] vga_cell,

    input logic resetn,
    input logic step_req,
    input logic fast_req,  // skip waiting for serial tx
    input logic slow_req,
    // todo: add step_req?

    output logic executing,

    input  logic rxd,
    output logic txd,

    output logic LED_GRN_N,
    output logic LED_RED_N

    // output logic [63:0] exec_count
);
  typedef enum logic [4:0] {
    S_IDLE,
    S_ZERO_DATA,
    S_ZDATA_END,
    S_ZERO_PROG,
    S_ZPROG_END,

    // serial load states
    S_SERLD_RX,

    S_WAIT_ONE,  // generic one cycle wait. returns to after_wait state.

    // preprocess states
    S_PRE_READ,
    S_PRE_STACK_INCR,
    S_PRE_JUMP_W1,
    S_PRE_JUMP_W2,

    // S_PRE_EXEC,

    // running
    S_SLOWDOWN,
    S_EXEC_WAIT,
    S_EXECUTE,

    // io while running
    S_TX_OUT,
    S_RX_WAIT,

    // writeback and read. could likely be optimized.
    S_PTR_WRITEBACK,
    S_PTR_READ_SETUP,
    S_PTR_READ_LATCH,

    S_PRINT_RESULT
  } state_t;
  state_t state_id;
  state_t after_wait;


  // localparam integer BAUD = 9600;
  // localparam integer BAUD = 115200;
  // localparam integer BAUD = 1_500_000;  // exactly 17 clock cycles.
  // localparam integer BAUD = 1593750;  // 16 cycles at 25.5MHz
  localparam integer BAUD = 2125000;  // 12 cycles at 25.5MHz
  localparam integer CLOCK_FREQ = 25_500_000;

  logic tx_start;
  logic tx_busy;
  logic [7:0] tx_data;

  transmitter #(
      .BAUD(BAUD),
      .CLOCK_FREQ(CLOCK_FREQ)
  ) tx_inst (
      .clk(clk),
      .rst_n(resetn),
      .start(tx_start),
      .busy(tx_busy),
      .data_in(tx_data),
      .txd(txd)
  );

  logic rx_valid;
  logic [7:0] rx_data;

  receiver #(
      .BAUD(BAUD),
      .CLOCK_FREQ(CLOCK_FREQ)
  ) rx_inst (
      .clk(clk),
      .rst_n(resetn),
      .valid(rx_valid),
      .data_out(rx_data),
      .rxd_async(rxd)
      // .ledn(LED_RED_N)
  );

  logic [PROG_ADDR_WIDTH-1:0] iptr;  // owned by cpu
  logic [                7:0] prog_rd;  // owned by cpu


  logic [               15:0] _prog_rd;
  assign prog_rd = _prog_rd[7:0];  // only lower 8 bits used.

  logic [7:0] prog_wr;
  logic prog_we;

  spram program_memory (  // todo: this stores a 3 bit object in 16 bits... it would at least be easy to do two bytes instead of one.
      .clk(clk),
      .we(prog_we ? 4'b1111 : 4'b0000),
      .addr(iptr),
      .data_in({8'h00, prog_wr}),
      .data_out(_prog_rd)
  );

  // localparam int SLOWDOWN = 10;  // wait 2^(SLOWDOWN+1) cycles when SLOWDOWN != 0. since each inst takes ~2 cycles, this slows by ~2^SLOWDOWN.
  // logic [SLOWDOWN:0] slow_ctr;

  // localparam DIFF = 12;
  localparam DIFF = 10;
  // localparam int DIFF = 6;

  logic [     23:0] slow_ctr;
  logic [     23:0] slow_lim;  // counts 2^DIFF x slower than slow_ctr.
  logic [23+DIFF:0] slow_lim_big;
  assign slow_lim = slow_lim_big[23+DIFF:DIFF];
  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      slow_lim_big <= '0;
    end else begin
      if (slow_req) begin  // incr while slow_req is held down.
        slow_lim_big <= slow_lim_big + 1;
      end else begin
        slow_lim_big <= '0;
      end
    end
  end

  // brainfuck data tape

  logic [14:0] dptr;  // 15 bits, max addr is 32767.
  logic [ 7:0] data_wr;
  logic        data_we;
  logic [ 7:0] data_rd;


  logic [13:0] _data_addr;
  // logic [      15:0] _data_wr;
  logic [ 3:0] _data_we;
  logic [15:0] _data_rd;

  logic        byte_sel;

  logic        cpu_priority;  // set before doing ops with data tape.

  assign _data_addr = cpu_priority ? dptr[13:0] : vga_data_addr[13:0];
  assign byte_sel   = cpu_priority ? dptr[14] : vga_data_addr[14];  // dptr[14];

  assign data_rd    = byte_sel ? _data_rd[15:8] : _data_rd[7:0];
  assign _data_we   = data_we ? (byte_sel ? 4'b1100 : 4'b0011) : 4'b0000;

  assign vga_cell   = data_rd;

  spram data_mem (
      .clk(clk),
      .we(_data_we),
      .addr(_data_addr),
      .data_in({data_wr, data_wr}),
      .data_out(_data_rd)
  );

  logic [                7:0] current_cell;  // cached data cell
  logic [  PROG_ADDR_WIDTH:0] dptr_next;

  // bracket stack, stores addresses of [ to match up with ]. we could save half the memory by noticing that the stack can never store more than (prog_len/2) addresses
  logic [PROG_ADDR_WIDTH-1:0] stack_wr;
  logic                       stack_we;
  logic [               15:0] _stack_rd;
  logic [PROG_ADDR_WIDTH-1:0] stack_rd;
  assign stack_rd = _stack_rd[PROG_ADDR_WIDTH-1:0];

  logic [PROG_ADDR_WIDTH-1:0] stack_ptr;

  spram bracket_stack (
      .clk(clk),
      .we(stack_we ? 4'b1111 : 4'b0000),
      .addr(stack_ptr),
      .data_in({{(16 - PROG_ADDR_WIDTH) {1'b0}}, stack_wr}),
      .data_out(_stack_rd)
  );

  // jump table stores address of matching bracket for each bracket.
  logic [PROG_ADDR_WIDTH-1:0] jump_addr_reg;
  logic [PROG_ADDR_WIDTH-1:0] jump_wr;
  logic                       jump_we;
  logic [PROG_ADDR_WIDTH-1:0] jump_rd;

  logic [               15:0] _jump_rd;
  assign jump_rd = _jump_rd[PROG_ADDR_WIDTH-1:0];

  logic jmp_attach_iptr;

  spram jump_table (
      .clk(clk),
      .we(jmp_attach_iptr ? 4'b0000 : jump_we ? 4'b1111 : 4'b0000),
      .addr(jmp_attach_iptr ? iptr : jump_addr_reg),
      .data_in({{(16 - PROG_ADDR_WIDTH) {1'b0}}, jump_wr}),
      .data_out(_jump_rd)  // only lower PROG_ADDR_WIDTH bits used
  );

  logic [14:0] zero_ptr;
  logic [PROG_ADDR_WIDTH-1:0] load_ptr;

  // todo: edge case where we jump past program??
  logic use_jump_rd;
  always_comb begin : jump_logic
    use_jump_rd = (prog_rd == 8'h5B && current_cell == 8'h00) ||
                      (prog_rd == 8'h5D && current_cell != 8'h00);
  end

  // logic do_blink;
  // logic [23:0] blink_ctr;
  // always_ff @(posedge clk) begin
  //   if (do_blink) begin
  //     blink_ctr <= blink_ctr + 1;
  //     LED_GRN_N <= blink_ctr[23];
  //   end else begin
  //     blink_ctr <= '0;
  //     LED_GRN_N <= 1'b1;  // off
  //   end
  // end

  logic [PROG_ADDR_WIDTH-1:0] temp_iptr;  // just a temp var

  function automatic logic is_valid_inst(input logic [7:0] op);
    is_valid_inst = (op == 8'h3E || op == 8'h3C || op == 8'h2B || op == 8'h2D ||
                     op == 8'h2E || op == 8'h2C || op == 8'h5B || op == 8'h5D);
  endfunction

  always @(posedge clk or negedge resetn) begin : cpu_fsm
    if (!resetn) begin
      state_id <= S_IDLE;
    end else begin
      // these get overridden as needed.
      data_we   <= 1'b0;
      stack_we  <= 1'b0;
      jump_we   <= 1'b0;
      prog_we   <= 1'b0;

      tx_start  <= 1'b0;

      // LED_GRN_N <= 1'b1;  // off
      LED_RED_N <= 1'b1;  // off

      // i've tried to make it so each state preps for the next state when it ends.
      // for most states i separate a state's cleanup and prep using a newline.

      case (state_id)
        S_IDLE: begin
          // do_blink     <= 1'b0;  // helpful for debugging.
          cpu_priority <= 1'b0;  // set early so vga can use data tape.
          executing    <= 1'b0;

          slow_ctr     <= '0;

          load_ptr     <= '0;
          state_id     <= S_ZERO_PROG;
        end

        S_ZERO_PROG: begin  // todo: simplify and remove this by making serld zero rest of prog
          // prog[load_ptr++] = 0
          prog_we  <= 1'b1;
          iptr     <= load_ptr;
          load_ptr <= load_ptr + 1;
          prog_wr  <= 8'h00;

          // if (load_ptr == len-1) // wrote to last addr
          if (load_ptr == '1) state_id <= S_ZPROG_END;
          // if (&load_ptr) state_id <= S_ZPROG_END;
        end

        S_ZPROG_END: begin
          tx_data  <= 8'd82;  // capital R for "ready".
          tx_start <= 1'b1;

          iptr     <= '0;
          load_ptr <= '0;
          state_id <= S_SERLD_RX;
        end

        S_WAIT_ONE: begin
          state_id <= after_wait;
        end

        S_SERLD_RX: begin  // todo: simplify this guy.. ways i can think of need extra states tho
          if (rx_valid || iptr == '1) begin  // wait until rx done, passthrough if we just wrote last addr.
            if (rx_data == 8'h04 || iptr == '1) begin  // ctrl D. iptr holds addr that has just been written to.
              // done loading
              iptr         <= '0;
              load_ptr     <= '0;

              cpu_priority <= 1'b1;  // take control of data tape
              dptr         <= '0;
              zero_ptr     <= '0;
              state_id     <= S_ZERO_DATA;
            end else if (is_valid_inst(rx_data)) begin
              // prog[lptr++] = rx
              prog_we  <= 1'b1;
              iptr     <= load_ptr;
              load_ptr <= load_ptr + 1;
              prog_wr  <= rx_data;
            end
          end
        end

        S_ZERO_DATA: begin
          // data[zptr++] = 0
          data_we  <= 1'b1;
          dptr     <= zero_ptr;
          zero_ptr <= zero_ptr + 1;
          data_wr  <= 8'h00;

          // if (zptr == len-1) // wrote to last addr
          if (zero_ptr == '1) state_id <= S_ZDATA_END;
        end

        S_ZDATA_END: begin
          zero_ptr        <= '0;
          dptr            <= '0;
          cpu_priority    <= 1'b0;  // release data tape

          stack_ptr       <= '0;
          jmp_attach_iptr <= 1'b0;  // make iptr and jump_addr_reg separate
          state_id        <= S_PRE_READ;
        end

        S_PRE_READ: begin
          if (prog_rd == 8'h5B) begin  // [ : stack[sptr++] = iptr
            stack_wr <= iptr;
            stack_we <= 1'b1;

            state_id <= S_PRE_STACK_INCR;
          end else if (prog_rd == 8'h5D) begin  // ] : match = stack[--sptr], jump[iptr] = match, jump[match] = iptr
            stack_ptr  <= stack_ptr - 1;  // setup stack pop
            state_id   <= S_WAIT_ONE;
            after_wait <= S_PRE_JUMP_W1;
          end else begin
            iptr       <= iptr + 1;
            state_id   <= S_WAIT_ONE;
            after_wait <= S_PRE_READ;
          end

          if (iptr == '1) begin  // done preprocessing
            stack_ptr       <= '0;

            iptr            <= '0;
            jmp_attach_iptr <= 1'b1;  // iptr now addresses jump table.
            executing       <= 1'b1;
            current_cell    <= '0;
            // exec_count      <= '0;
            state_id        <= S_EXEC_WAIT;
          end
        end

        S_PRE_STACK_INCR: begin  // could be replaced by use of a separate pointer.
          stack_ptr  <= stack_ptr + 1;

          iptr       <= iptr + 1;
          state_id   <= S_WAIT_ONE;
          after_wait <= S_PRE_READ;
        end

        S_PRE_JUMP_W1: begin
          // stack_rd is the [ address
          // write jump_table[stack_rd] = iptr (address of ])
          jump_addr_reg <= stack_rd;
          jump_wr       <= iptr;
          jump_we       <= 1'b1;

          state_id      <= S_PRE_JUMP_W2;
        end

        S_PRE_JUMP_W2: begin
          // write the reverse mapping: jump_table[iptr] = stack_rd
          jump_addr_reg <= iptr;
          jump_wr       <= stack_rd;
          jump_we       <= 1'b1;

          iptr          <= iptr + 1;
          state_id      <= S_WAIT_ONE;
          after_wait    <= S_PRE_READ;
        end

        S_EXEC_WAIT: begin
          state_id <= slow_req ? S_SLOWDOWN : S_EXECUTE;

          if (!executing) begin
            state_id <= S_IDLE;
          end
        end

        S_SLOWDOWN: begin // doesnt get triggered on PTR_READ_LATCH but thats fine, we just want a slowdown on most insts.
          if (slow_req) begin
            slow_ctr <= slow_ctr + 1;
            // if (slow_ctr == '1) state_id <= S_EXECUTE;
            if (slow_ctr >= slow_lim) begin
              state_id <= S_EXECUTE;
              slow_ctr <= '0;
            end
          end else begin
            slow_ctr <= '0;
            state_id <= S_EXECUTE;
          end
        end

        S_EXECUTE: begin  // can be reached either from EXEC_WAIT or PTR_READ_LATCH
          LED_RED_N <= 1'b0;  // light red on execute.

          // todo: quit at null byte.

          // exec_count <= exec_count + 1;
          case (prog_rd)

            8'h3E, 8'h3C: begin  // > < : inc/dec data pointer
              LED_RED_N    <= 1'b0;  // light red on data pointer move
              dptr_next    <= prog_rd == 8'h3E ? dptr + 1 : dptr - 1;
              cpu_priority <= 1'b1;  // take control of data tape
              // todo: if wanted, by tracking if current_cell changed we can skip write and schedule read, saving one cycle sometimes
              state_id     <= S_PTR_WRITEBACK;  // writeback scheduled
            end

            8'h2B, 8'h2D: begin  // + - : inc/dec current cell
              current_cell <= prog_rd == 8'h2B ? current_cell + 1 : current_cell - 1;
              state_id     <= S_EXEC_WAIT;
            end

            8'h2E: begin  // .
              if (!fast_req) begin
                state_id <= S_TX_OUT;
              end else begin  // skip the wait
                tx_start <= 1'b1;
                tx_data  <= current_cell;
                state_id <= S_EXEC_WAIT;
              end
            end

            8'h2C: begin  // ,
              state_id <= S_RX_WAIT;
            end

            8'h5B, 8'h5D: begin  // [ ] : jumps handled in use_jump_rd logic
              state_id <= S_EXEC_WAIT;
            end

            default: state_id <= S_EXEC_WAIT;  // nop. todo: change to end.
          endcase

          temp_iptr = use_jump_rd ? jump_rd + 1 : iptr + 1;  // blocking!!! temp storage.
          // temp_iptr = use_jump_rd ? jump_rd_plus_1 : iptr_plus_1;  // blocking!!!
          if (temp_iptr != '0) begin  // if next inst isnt first
            iptr <= temp_iptr;
          end else begin
            // reached end
            executing <= 1'b0;  // let this instruction execute, but stop when back to exec_wait
          end
        end

        S_TX_OUT: begin
          if (!tx_busy) begin  // wait until done with prev tx
            tx_start <= 1'b1;
            tx_data  <= current_cell;
            state_id <= S_EXEC_WAIT;
          end
        end

        // S_RX_IN: begin  // we have to wait one cycle for busy to get asserted
        //   state_id <= S_RX_WAIT;
        // end

        S_RX_WAIT: begin
          if (rx_valid) begin
            current_cell <= rx_data;
            state_id     <= S_EXEC_WAIT;
          end
        end

        S_PTR_WRITEBACK: begin
          data_wr  <= current_cell;
          data_we  <= 1'b1;
          state_id <= S_PTR_READ_SETUP;
        end

        S_PTR_READ_SETUP: begin
          dptr       <= dptr_next;  // request new address read

          state_id   <= S_WAIT_ONE;
          after_wait <= S_PTR_READ_LATCH;
        end

        S_PTR_READ_LATCH: begin
          current_cell <= data_rd;
          cpu_priority <= 1'b0;  // release data tape
          state_id     <= S_EXECUTE;
        end

        // S_STEP_WAIT: begin  // todo: just merge into exec wait.
        //   // if we just executed . then wait for step_req before next fetch
        //   state_id <= (last_inst == 8'h2E && !step_req) ? S_STEP_WAIT : S_EXEC_WAIT;
        // end

        default: begin
          state_id <= S_IDLE;
        end
      endcase

    end
  end

endmodule
