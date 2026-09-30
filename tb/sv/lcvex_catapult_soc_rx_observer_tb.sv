// T-20260920-013 observation-only token/counter contract test.

`timescale 1ns/1ps

module lcvex_catapult_soc_rx_observer_tb;
  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n;
  logic bridge_req, bridge_valid, bridge_ready, bridge_fault;
  logic poc_req, poc_valid, poc_ready, poc_fault;
  logic dmem_req, dmem_valid, dmem_ready, dmem_fault;
  logic tx_valid;
  logic [7:0] tx_char;
  logic [31:0] bridge_in, poc_in, dmem_in;
  logic bridge_pending, poc_pending, dmem_pending;
  logic [7:0] bridge_count, poc_count, dmem_count;
  logic [31:0] bridge_data, poc_data, dmem_data;
  logic bridge_sticky, poc_sticky, dmem_sticky;
  logic [15:0] tx_count;
  logic tx_seen;
  logic [7:0] tx_last;
  integer errors;

  lcvex_catapult_soc_rx_observer dut (
      .clk(clk), .rst_n(rst_n),
      .bridge_req_fire(bridge_req), .bridge_rsp_valid(bridge_valid),
      .bridge_rsp_ready(bridge_ready), .bridge_rsp_data_i(bridge_in),
      .bridge_rsp_fault_i(bridge_fault), .poc_req_fire(poc_req),
      .poc_rsp_valid(poc_valid), .poc_rsp_ready(poc_ready),
      .poc_rsp_data_i(poc_in), .poc_rsp_fault_i(poc_fault),
      .dmem_req_fire(dmem_req), .dmem_rsp_valid(dmem_valid),
      .dmem_rsp_ready(dmem_ready), .dmem_rsp_data_i(dmem_in),
      .dmem_rsp_fault_i(dmem_fault), .tx_valid(tx_valid),
      .tx_char(tx_char), .bridge_pending(bridge_pending),
      .poc_pending(poc_pending), .dmem_pending(dmem_pending),
      .bridge_count(bridge_count), .poc_count(poc_count),
      .dmem_count(dmem_count), .bridge_rsp_data(bridge_data),
      .poc_rsp_data(poc_data), .dmem_rsp_data(dmem_data),
      .bridge_fault(bridge_sticky), .poc_fault(poc_sticky),
      .dmem_fault(dmem_sticky), .tx_count(tx_count),
      .tx_seen(tx_seen), .tx_last_byte(tx_last)
  );

  task automatic check(input logic cond, input string msg);
    if (!cond) begin
      $display("FAIL %s", msg);
      errors = errors + 1;
    end
  endtask

  initial begin
    errors = 0;
    rst_n = 1'b0;
    bridge_req = 0; bridge_valid = 0; bridge_ready = 0;
    bridge_fault = 0; bridge_in = 0;
    poc_req = 0; poc_valid = 0; poc_ready = 0;
    poc_fault = 0; poc_in = 0;
    dmem_req = 0; dmem_valid = 0; dmem_ready = 0;
    dmem_fault = 0; dmem_in = 0;
    tx_valid = 0; tx_char = 0;
    #1;
    check(!bridge_pending && !poc_pending && !dmem_pending &&
          bridge_count == 0 && poc_count == 0 && dmem_count == 0,
          "reset clears tokens/counts");
    rst_n = 1'b1;

    // Request + response backpressure: no consume/count until READY.
    @(negedge clk); bridge_req = 1'b1;
    @(posedge clk); @(negedge clk); bridge_req = 1'b0;
    bridge_valid = 1'b1; bridge_in = 32'h0000_803f; bridge_ready = 1'b0;
    repeat (2) @(posedge clk);
    check(bridge_pending && bridge_count == 0,
          "backpressured response remains pending and uncounted");
    @(negedge clk); bridge_ready = 1'b1;
    @(posedge clk); @(negedge clk);
    bridge_valid = 1'b0; bridge_ready = 1'b0;
    check(!bridge_pending && bridge_count == 1 && bridge_data == 32'h803f,
          "bridge RVALID response consumes exactly once");

    // Empty response clears token but does not overwrite or count.
    poc_req = 1'b1; @(posedge clk); @(negedge clk); poc_req = 1'b0;
    poc_valid = 1'b1; poc_ready = 1'b1; poc_in = 32'd0;
    @(posedge clk); @(negedge clk); poc_valid = 1'b0; poc_ready = 1'b0;
    check(!poc_pending && poc_count == 0 && poc_data == 0,
          "empty response does not create valid event");

    // Fault response clears token, sets sticky, and does not count.
    poc_req = 1'b1; @(posedge clk); @(negedge clk); poc_req = 1'b0;
    poc_valid = 1'b1; poc_ready = 1'b1; poc_fault = 1'b1;
    @(posedge clk); @(negedge clk);
    poc_valid = 1'b0; poc_ready = 1'b0; poc_fault = 1'b0;
    check(!poc_pending && poc_sticky && poc_count == 0,
          "fault response clears pending and sets sticky fault");

    // Reset while pending discards the observation token.
    dmem_req = 1'b1; @(posedge clk); @(negedge clk); dmem_req = 1'b0;
    check(dmem_pending, "dmem request establishes pending token");
    rst_n = 1'b0; #1;
    check(!dmem_pending && dmem_count == 0,
          "reset clears pending token without count");
    rst_n = 1'b1;
    tx_valid = 1'b1; tx_char = 8'h5a;
    @(posedge clk); @(negedge clk); tx_valid = 1'b0;
    check(tx_count == 1 && tx_seen && tx_last == 8'h5a,
          "accepted TX pulse is observed once");

    if (errors == 0)
      $display("RX_OBSERVER_UNIT PASS");
    else
      $fatal(1, "RX_OBSERVER_UNIT FAIL errors=%0d", errors);
    $finish;
  end
endmodule
