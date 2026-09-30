// Direct check of the checked-in Quartus 21.4 JTAG-UART HDL RX IRQ threshold.
// The simulation-only FIFO stub has no host RX source, so force its exposed
// count wires to test the exact production RTL comparator without replacing it.

`timescale 1ns/1ps

module lcvex_jtag_uart_generated_irq_tb;
  logic clk;
  logic rst_n;
  logic av_address;
  logic av_chipselect;
  logic av_read_n;
  logic [31:0] av_readdata;
  logic av_write_n;
  logic [31:0] av_writedata;
  logic av_waitrequest;
  logic av_irq;
  logic dataavailable;
  logic readyfordata;
  integer errors;

  jtag_uart_only_jtag_uart_altera_avalon_jtag_uart_1910_zesttkq dut (
      .av_address(av_address), .av_chipselect(av_chipselect),
      .av_read_n(av_read_n), .av_readdata(av_readdata),
      .av_write_n(av_write_n), .av_writedata(av_writedata),
      .clk(clk), .rst_n(rst_n), .av_irq(av_irq),
      .av_waitrequest(av_waitrequest), .dataavailable(dataavailable),
      .readyfordata(readyfordata)
  );

  always #5 clk = ~clk;

  task automatic check(input logic cond, input string msg);
    if (!cond) begin
      $display("FAIL: %s", msg);
      errors = errors + 1;
    end
  endtask

  task automatic tick(input integer n = 1);
    repeat (n) @(posedge clk);
    #1;
  endtask

  task automatic control_write(input logic [31:0] value);
    begin
      @(negedge clk);
      av_address = 1'b1;
      av_chipselect = 1'b1;
      av_read_n = 1'b1;
      av_write_n = 1'b0;
      av_writedata = value;
      @(posedge clk);
      #1;
      @(negedge clk);
      av_chipselect = 1'b0;
      av_write_n = 1'b1;
      tick(2);
    end
  endtask

  task automatic control_read(output logic [31:0] value);
    begin
      @(negedge clk);
      av_address = 1'b1;
      av_chipselect = 1'b1;
      av_read_n = 1'b0;
      av_write_n = 1'b1;
      @(posedge clk);
      #1 value = av_readdata;
      @(negedge clk);
      av_chipselect = 1'b0;
      av_read_n = 1'b1;
      tick(2);
    end
  endtask

  logic [31:0] control;

  initial begin
    $display("=== generated JTAG-UART first-byte RX IRQ test ===");
    clk = 1'b0;
    rst_n = 1'b0;
    av_address = 1'b0;
    av_chipselect = 1'b0;
    av_read_n = 1'b1;
    av_write_n = 1'b1;
    av_writedata = 32'd0;
    errors = 0;
    control = 32'd0;

    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    // Isolate the generated FIFO threshold logic; the generated file's
    // simulation-only scfifo stub intentionally contains no injected RX data.
    force dut.rfifo_full = 1'b0;
    force dut.rfifo_used = 6'd0;
    tick(3);
    control_write(32'h0000_0001); // CONTROL.RE
    check(!av_irq, "empty RX FIFO does not assert IRQ");

    force dut.rfifo_used = 6'd1;
    tick(2);
    check(av_irq,
          "RX IRQ asserts for one byte with 63 free entries configured");
    control_read(control);
    check(control[8] && control[0],
          "CONTROL reports RX pending and RE for the one-byte FIFO state");

    force dut.rfifo_used = 6'd0;
    tick(2);
    check(!av_irq, "RX IRQ deasserts after the FIFO becomes empty");
    control_write(32'd0);
    check(!av_irq, "clearing RE leaves RX IRQ deasserted");

    release dut.rfifo_full;
    release dut.rfifo_used;
    if (errors != 0)
      $fatal(1, "generated JTAG-UART IRQ test failed with %0d errors", errors);
    $display("GENERATED_JTAG_UART_RX_IRQ_TEST PASS");
    $finish;
  end
endmodule
