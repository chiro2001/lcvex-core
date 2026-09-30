// Directed regression for the Altera JTAG-UART control/IRQ behavior used by
// the Catapult Linux TTY driver.

`timescale 1ns/1ps

module lcvex_jtag_uart_irq_tb;
  localparam int TX_DEPTH = 64;
  localparam int RX_DEPTH = 64;

  logic clk;
  logic rst_n;
  logic chipselect;
  logic read_n;
  logic write_n;
  logic [0:0] address;
  logic [31:0] writedata;
  logic [31:0] readdata;
  logic waitrequest;
  logic irq;
  logic rx_valid;
  logic [7:0] rx_char;
  logic rx_ready;
  logic tx_pop;
  logic force_waitrequest;
  logic host_activity;
  logic [31:0] avalon_read_count;
  logic [31:0] avalon_write_count;
  logic [31:0] data_read_count;
  logic [31:0] control_read_count;
  logic [31:0] data_write_count;
  logic [31:0] control_write_count;
  logic [31:0] rx_pop_count;
  logic [31:0] tx_push_count;
  logic [15:0] tx_wspace;
  logic [31:0] tx_event_count;
  logic [7:0] tx_event_char;
  logic tx_event_valid;
  logic tx_drain_valid;
  logic [7:0] tx_drain_char;
  integer errors;

  lcvex_jtag_uart_vendor_model #(
      .TX_DEPTH(TX_DEPTH), .RX_DEPTH(RX_DEPTH)
  ) dut (
      .clk(clk), .rst_n(rst_n),
      .chipselect(chipselect), .read_n(read_n), .write_n(write_n),
      .address(address), .writedata(writedata), .readdata(readdata),
      .waitrequest(waitrequest), .irq(irq),
      .rx_valid(rx_valid), .rx_char(rx_char), .rx_ready(rx_ready),
      .tx_pop(tx_pop), .force_waitrequest(force_waitrequest),
      .host_activity(host_activity),
      .avalon_read_count(avalon_read_count),
      .avalon_write_count(avalon_write_count),
      .data_read_count(data_read_count),
      .control_read_count(control_read_count),
      .data_write_count(data_write_count),
      .control_write_count(control_write_count),
      .rx_pop_count(rx_pop_count), .tx_push_count(tx_push_count),
      .tx_wspace(tx_wspace), .tx_event_count(tx_event_count),
      .tx_event_char(tx_event_char), .tx_event_valid(tx_event_valid),
      .tx_drain_valid(tx_drain_valid), .tx_drain_char(tx_drain_char)
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

  // The generated 21.4 IP consumes the Avalon operation on the registered
  // waitrequest-high edge, then lowers waitrequest for the bridge response.
  task automatic avalon_write(input logic addr, input logic [31:0] data);
    begin
      @(negedge clk);
      chipselect = 1'b1;
      read_n = 1'b1;
      write_n = 1'b0;
      address = addr;
      writedata = data;
      @(posedge clk);
      #1;
      @(negedge clk);
      chipselect = 1'b0;
      write_n = 1'b1;
      tick(2);
    end
  endtask

  task automatic avalon_read(input logic addr, output logic [31:0] data);
    begin
      @(negedge clk);
      chipselect = 1'b1;
      read_n = 1'b0;
      write_n = 1'b1;
      address = addr;
      @(posedge clk);
      #1 data = readdata;
      @(negedge clk);
      chipselect = 1'b0;
      read_n = 1'b1;
      tick(2);
    end
  endtask

  task automatic inject_rx(input logic [7:0] data);
    begin
      @(negedge clk);
      rx_char = data;
      rx_valid = 1'b1;
      while (!rx_ready) @(posedge clk);
      @(posedge clk);
      #1;
      @(negedge clk);
      rx_valid = 1'b0;
      tick(1);
    end
  endtask

  task automatic drain_tx_one;
    begin
      @(negedge clk);
      tx_pop = 1'b1;
      @(posedge clk);
      #1;
      @(negedge clk);
      tx_pop = 1'b0;
      tick(2);
    end
  endtask

  logic [31:0] control;
  integer i;

  initial begin
    $display("=== lcvex_jtag_uart_irq_tb: Altera control/IRQ semantics ===");
    clk = 1'b0;
    rst_n = 1'b0;
    chipselect = 1'b0;
    read_n = 1'b1;
    write_n = 1'b1;
    address = 1'b0;
    writedata = 32'd0;
    rx_valid = 1'b0;
    rx_char = 8'd0;
    tx_pop = 1'b0;
    force_waitrequest = 1'b0;
    host_activity = 1'b0;
    errors = 0;
    control = 32'd0;

    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    tick(3);
    check(!irq, "reset leaves both JTAG-UART interrupt enables clear");

    // Control bit 1 enables TX IRQ; the 64-entry generated IP asserts it when
    // the write FIFO is almost empty (8 or fewer bytes queued).
    avalon_read(1'b1, control);
    check(control[31:16] == 16'd64 && !control[9] && !control[8] &&
          !control[1] && !control[0],
          "reset CONTROL exposes WSPACE and cleared status/enable fields");
    avalon_write(1'b1, 32'h0000_0002);
    check(irq, "WE enables the TX almost-empty interrupt");
    avalon_read(1'b1, control);
    check(control[9] && !control[8] && control[1] && !control[0],
          "CONTROL reports TX pending and WE in their Altera bit positions");

    for (i = 0; i < 9; i = i + 1)
      avalon_write(1'b0, 32'(i));
    check(tx_wspace == 16'd55 && !irq,
          "TX IRQ deasserts above the almost-empty threshold");
    avalon_read(1'b1, control);
    check(!control[9] && control[1] && control[31:16] == 16'd55,
          "CONTROL reflects queued TX data and no pending TX interrupt");
    drain_tx_one();
    check(tx_wspace == 16'd56 && irq,
          "TX IRQ reasserts when draining returns FIFO occupancy to eight");
    avalon_write(1'b1, 32'd0);
    check(!irq, "clearing WE suppresses the TX pending interrupt");

    // The Catapult-generated IP is configured with 63 free entries as the RX
    // threshold, so a blocking Linux TTY read is awakened by the first byte.
    avalon_write(1'b1, 32'h0000_0001);
    check(!irq, "RE alone does not assert while RX FIFO is empty");
    inject_rx(8'hA5);
    check(irq, "RX IRQ asserts for the first byte in the FIFO");
    avalon_read(1'b1, control);
    check(control[8] && !control[9] && control[0] && !control[1],
          "CONTROL reports RX pending and RE in their Altera bit positions");
    avalon_read(1'b0, control);
    check(control[15] && control[7:0] == 8'hA5,
          "DATA read returns RVALID and the oldest queued RX byte");
    check(!irq, "RX IRQ deasserts after FIFO occupancy falls below threshold");

    avalon_write(1'b1, 32'd0);
    check(!irq, "clearing RE suppresses the RX pending interrupt");
    rst_n = 1'b0;
    #1;
    check(!irq, "reset clears IRQ state asynchronously");
    if (errors != 0)
      $fatal(1, "lcvex_jtag_uart_irq_tb failed with %0d errors", errors);
    $display("JTAG_UART_IRQ_MODEL_TEST PASS tx_push=%0d rx_pop=%0d",
             tx_push_count, rx_pop_count);
    $finish;
  end
endmodule
