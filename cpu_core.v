`default_nettype none
module cpu_core #(
    parameter PROG_ADDR_WIDTH = 10,
    parameter PROG_LEN = 10
) (
    input  wire       clk,
    input  wire       resetn,     // 1 => normal, 0 => reset
    input  wire       start_req,
    input  wire       load_req,
    output reg        loaded,
    output reg        executing,
    output reg  [2:0] state_id,
    output reg  [7:0] display     // debug display byte
);

  localparam IDLE = 3'd0;
  localparam LOAD = 3'd1;
  localparam FETCH = 3'd2;
  localparam WAIT_READ = 3'd3;
  localparam DECODE = 3'd4;
  localparam RUN = 3'd5;
  localparam UPDATE = 3'd6;

  reg [PROG_ADDR_WIDTH-1:0] iptr;
  reg [7:0] prog_wr;
  reg prog_we;
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

  reg [PROG_ADDR_WIDTH-1:0] dptr;
  reg [7:0] data_wr;
  reg data_we;
  wire [7:0] data_rd;

  bram_sp #(
      .ADDR_WIDTH(PROG_ADDR_WIDTH),
      .DATA_WIDTH(8)
  ) data_memory (
      .clk(clk),
      .write_enable(data_we),
      .addr(dptr),
      .data_in(data_wr),
      .data_out(data_rd)
  );


  // // maintain a bracket stack. probably overkill to have as a bram.
  // reg [PROG_ADDR_WIDTH-1:0] stack_ptr;
  // reg [PROG_ADDR_WIDTH-1:0] stack_wr;
  // reg stack_we;
  // wire [PROG_ADDR_WIDTH-1:0] stack_rd;
  // bram_sp #(
  //     .ADDR_WIDTH(PROG_ADDR_WIDTH),
  //     .DATA_WIDTH(PROG_ADDR_WIDTH)
  // ) bracket_stack (
  //     .clk(clk),
  //     .write_enable(stack_we),
  //     .addr(stack_ptr),
  //     .data_in(stack_wr),
  //     .data_out(stack_rd)
  // );

  // // jump table:
  // reg [PROG_ADDR_WIDTH-1:0] jump_ptr;
  // reg [PROG_ADDR_WIDTH-1:0] jump_wr;
  // reg jump_we;
  // wire [PROG_ADDR_WIDTH-1:0] jump_rd;
  // bram_sp #(
  //     .ADDR_WIDTH(PROG_ADDR_WIDTH),
  //     .DATA_WIDTH(PROG_ADDR_WIDTH)
  // ) jump_table (
  //     .clk(clk),
  //     .write_enable(jump_we),
  //     .addr(jump_ptr),
  //     .data_in(jump_wr),
  //     .data_out(jump_rd)
  // );


  reg [7:0] inst;
  reg [7:0] output_reg;
  reg [7:0] exec_count;

  always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      state_id <= IDLE;
      loaded <= 0;
      executing <= 0;
      prog_we <= 0;
      data_we <= 0;
      dptr <= 0;
      iptr <= 0;
      output_reg <= 0;
      inst <= 0;
      exec_count <= 0;
      display <= 8'h00;
    end else begin
      // default stops
      prog_we <= 0;
      data_we <= 0;

      case (state_id)
        IDLE: begin
          executing <= 0;
          if (load_req) begin
            loaded <= 0;
            iptr <= 0;
            state_id <= LOAD;
          end else if (start_req && loaded) begin
            executing <= 1;
            iptr <= 0;
            exec_count <= 0;
            state_id <= FETCH;
          end
        end

        LOAD: begin
          // write a fixed program (demo). write a byte per clock cycle.
          prog_we <= 1;
          //   iptr <= load_ptr;
          // Example program: +++++.
          case (iptr)
            0: prog_wr <= 8'h2B;
            1: prog_wr <= 8'h2B;
            2: prog_wr <= 8'h2B;
            3: prog_wr <= 8'h2B;
            4: prog_wr <= 8'h2B;
            5: prog_wr <= 8'h2E;
            default: prog_wr <= 8'h00;
          endcase

          if (iptr == PROG_LEN) begin
            iptr <= 0;
            loaded <= 1;
            state_id <= IDLE;
          end else begin
            iptr <= iptr + 1;
          end
        end

        FETCH: begin
          // set address and go wait one cycle for BRAM to output
          exec_count <= exec_count + 1;
          state_id   <= WAIT_READ;
        end

        WAIT_READ: begin
          // read data available on prog_rd
          inst <= prog_rd;
          state_id <= DECODE;
        end

        DECODE: begin
          // prepare datapath
          //   dptr <= 0;  // we use cell 0 for demo
          state_id <= RUN;
        end

        RUN: begin
          case (inst)
            8'h3E: begin  // '>'
              // increment data pointer
              dptr <= dptr + 1;
            end
            8'h3C: begin  // '<'
              // decrement data pointer
              dptr <= dptr - 1;
            end
            8'h2B: begin  // '+'
              // increment value
              data_wr <= data_rd + 1;
              data_we <= 1;
            end
            8'h2D: begin  // '-'
              // decrement value
              data_wr <= data_rd - 1;
              data_we <= 1;
            end
            8'h2E: begin  // '.'
              output_reg <= data_rd;
            end
            default: begin
            end
          endcase
          state_id <= UPDATE;
        end

        UPDATE: begin
          if (iptr < PROG_LEN) begin
            iptr <= iptr + 1;
            state_id <= FETCH;
          end else begin
            executing <= 0;
            state_id  <= IDLE;
            // expose results on display (for simplicity)
            display   <= output_reg;
          end
        end

        default: state_id <= IDLE;
      endcase
    end
  end
endmodule
