`timescale 1ns / 1ps `default_nettype none

module tb_top;
  // Clock and reset
  logic CLK = 0;
  always #5 CLK = ~CLK;  // 100 MHz clock -> period 10ns

  // Buttons / reset
  logic BTN_N = 0;  // active-low reset
  logic BTN1 = 0;
  logic BTN2 = 0;
  logic BTN3 = 0;

  // Observables
  logic LED1, LED2, LED3, LED4, LED5;
  logic P1A1, P1A2, P1A3, P1A4, P1A7, P1A8, P1A9, P1A10;

  // Instantiate DUT (named port mapping)
  top uut (
      .CLK  (CLK),
      .BTN_N(BTN_N),
      .BTN1 (BTN1),
      .BTN2 (BTN2),
      .BTN3 (BTN3),
      .LED1 (LED1),
      .LED2 (LED2),
      .LED3 (LED3),
      .LED4 (LED4),
      .LED5 (LED5),
      .P1A1 (P1A1),
      .P1A2 (P1A2),
      .P1A3 (P1A3),
      .P1A4 (P1A4),
      .P1A7 (P1A7),
      .P1A8 (P1A8),
      .P1A9 (P1A9),
      .P1A10(P1A10)
  );

  // Dump waveforms
  initial begin
    $dumpfile("tb_top.vcd");
    $dumpvars(0, tb_top);
  end

  // Print a header once
  initial begin
    $display("=== SIM START ===");
    $display("Note: watch CLK, BTN_N, uut.core.resetn (if present), uut.core.state_id");
    $display("Time   CLK BTN_N BTN3 db_btn3 btn3_pulse core.resetn core.state_id core.iptr");
  end

  // Periodic debug print every 10 cycles
  always @(posedge CLK) begin
    // Print every 1us (100 cycles) to reduce spam; but show first 50 cycles every edge
    if ($time < 1000 || ($time % 1000 == 0)) begin
      // Safe access to nested signals: use hierarchical names that exist in your design.
      $display("%6t  %b    %b     %b    %b       %b         %0d          %0d", $time, CLK, BTN_N,
               BTN3, uut.db_btn3,  // top-level signal
               uut.btn3_pulse,  // top-level pulse (we made it direct in top)
               uut.core.resetn,  // core reset input (if present)
               uut.core.state_id, uut.core.iptr);
      //    $display("");
    end
  end

  // Clean, simple button press (no force/release)
  task press_button_simple(input integer cycles);
    begin
      BTN3 = 1;
      repeat (cycles) @(posedge CLK);
      BTN3 = 0;
      // hold a bit
      repeat (10) @(posedge CLK);
    end
  endtask

  task press_button_start(input integer cycles);
    begin
      BTN1 = 1;
      repeat (cycles) @(posedge CLK);
      BTN1 = 0;
      repeat (10) @(posedge CLK);
    end
  endtask

  integer timeout;

  initial begin
    // INITIAL VALUES
    BTN_N = 0;
    BTN1  = 0;
    BTN2  = 0;
    BTN3  = 0;

    // let some clocks run (use posedge to guarantee time advances)
    repeat (10) @(posedge CLK);

    // Release reset (BTN_N is active low)
    $display("[%0t] Releasing reset (BTN_N <= 1)", $time);
    BTN_N = 1;
    repeat (20) @(posedge CLK);

    // Quick sanity prints
    $display("[%0t] BTN_N=%b, CLK=%b", $time, BTN_N, CLK);

    // Press load button
    $display("[%0t] pressing load (BTN3) for 20 cycles", $time);
    press_button_simple(20);

    // Wait for core.loaded or timeout
    timeout = 0;
    while (uut.core.loaded !== 1 && timeout < 20000) begin
      @(posedge CLK);
      timeout = timeout + 1;
    end
    if (uut.core.loaded === 1) $display("[%0t] core.loaded detected", $time);
    else $display("[%0t] TIMEOUT waiting for core.loaded", $time);

    // Press start/run
    $display("[%0t] pressing start (BTN1) for 20 cycles", $time);
    press_button_start(20);

    // Run for a while and then finish
    repeat (50000) @(posedge CLK);
    $display("[%0t] Final: core.state_id=%0d core.display=%02h", $time, uut.core.state_id,
             uut.core.display);
    $finish;
  end

endmodule
