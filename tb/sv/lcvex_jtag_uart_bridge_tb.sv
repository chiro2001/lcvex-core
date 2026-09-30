// lcvex_jtag_uart_bridge_tb.sv
// B25 JTAG-UART Avalon bridge focused directed test.
//
// The test intentionally instantiates only the bridge and a behavioral
// Avalon slave model.  It therefore isolates the req.addr[2] mapping and the
// request/response protocol from the full SoC, without changing shared SoC
// test infrastructure.

`timescale 1ns/1ps

module lcvex_jtag_uart_bridge_tb #(
    parameter bit VENDOR_TIMING = 1'b0
);
  import lcvex_pkg::*;

  localparam int TX_DEPTH = 4;
  localparam int RX_DEPTH = 4;

  logic clk;
  logic rst_n;
  logic req_valid;
  mem_req_t req;
  logic req_accept;
  logic rsp_valid;
  mem_rsp_t rsp;
  logic rsp_ready;

  logic chipselect;
  logic read_n;
  logic write_n;
  logic [0:0] address;
  logic [31:0] writedata;
  logic [31:0] readdata;
  logic waitrequest;
  logic tx_valid;
  logic [7:0] tx_char;
  logic [31:0] rx_data_read_count_obs;
  logic [15:0] rx_rvalid_count_obs;
  logic rx_seen_obs;
  logic [7:0] rx_last_byte_obs;

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
  logic model_irq;

  lcvex_catapult_soc_jtag_uart dut (
      .clk(clk), .rst_n(rst_n),
      .req_valid(req_valid), .req(req), .req_accept(req_accept),
      .rsp_valid(rsp_valid), .rsp(rsp), .rsp_ready(rsp_ready),
      .chipselect(chipselect), .read_n(read_n), .write_n(write_n),
      .address(address), .writedata(writedata), .readdata(readdata),
      .waitrequest(waitrequest), .tx_valid(tx_valid), .tx_char(tx_char),
      .rx_data_read_count(rx_data_read_count_obs),
      .rx_rvalid_count(rx_rvalid_count_obs),
      .rx_seen(rx_seen_obs), .rx_last_byte(rx_last_byte_obs)
  );

  generate
    if (VENDOR_TIMING) begin : gen_vendor_model
      lcvex_jtag_uart_vendor_model #(
          .TX_DEPTH(TX_DEPTH), .RX_DEPTH(RX_DEPTH)
      ) model (
          .clk(clk), .rst_n(rst_n),
          .chipselect(chipselect), .read_n(read_n), .write_n(write_n),
          .address(address), .writedata(writedata), .readdata(readdata),
          .waitrequest(waitrequest), .irq(model_irq),
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
    end else begin : gen_behavioral_model
      lcvex_jtag_uart_model #(
          .TX_DEPTH(TX_DEPTH), .RX_DEPTH(RX_DEPTH)
      ) model (
          .clk(clk), .rst_n(rst_n),
          .chipselect(chipselect), .read_n(read_n), .write_n(write_n),
          .address(address), .writedata(writedata), .readdata(readdata),
          .waitrequest(waitrequest), .irq(model_irq),
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
    end
  endgenerate

  always #5 clk = ~clk;

  integer errors;
  integer tx_pulse_seen;
  logic [7:0] tx_pulse_last;
  integer model_event_seen;
  integer tx_drain_seen;
  logic [7:0] tx_drain_last;

  always @(posedge clk) begin
    // tx_valid is a registered one-cycle pulse from the bridge.  Sampling at
    // the following edge observes the value that was visible for the cycle.
    if (tx_valid) begin
      tx_pulse_seen <= tx_pulse_seen + 1;
      tx_pulse_last <= tx_char;
    end
    if (tx_event_valid)
      model_event_seen <= model_event_seen + 1;
    if (tx_drain_valid) begin
      tx_drain_seen <= tx_drain_seen + 1;
      tx_drain_last <= tx_drain_char;
    end
  end

  task automatic check_ok(input logic cond, input string msg);
    if (!cond) begin
      $display("FAIL: %s", msg);
      errors = errors + 1;
    end
  endtask

  task automatic tick(input integer n = 1);
    repeat (n) @(posedge clk);
  endtask

  task automatic init_req(input logic [63:0] addr, input logic we,
                          input logic [63:0] wdata);
    req.addr = addr;
    req.we = we;
    req.strb = we ? 8'h0f : 8'h00;
    req.wdata = wdata;
    req.maint = MAINT_NONE;
    req.bypass = 1'b1;
  endtask

  // Submit one request and wait for an immediately consumable response.
  // The request is presented on a falling edge so that every request field is
  // stable before the bridge's next rising edge.
  task automatic access(input logic [63:0] addr, input logic we,
                        input logic [63:0] wdata, output mem_rsp_t result);
    @(negedge clk);
    init_req(addr, we, wdata);
    req_valid = 1'b1;
    while (!req_accept)
      @(posedge clk);
    @(posedge clk);
    // Deassert away from the capture edge.  This avoids a simulator-dependent
    // race between the driver and the bridge's synchronous sampler.
    @(negedge clk);
    req_valid = 1'b0;
    while (!rsp_valid)
      @(posedge clk);
    #1 result = rsp;
    @(negedge clk);
  endtask

  // Submit a request but leave its response held until the caller releases
  // rsp_ready.  The caller samples rsp while rsp_valid remains asserted.
  task automatic access_hold_response(input logic [63:0] addr, input logic we,
                                       input logic [63:0] wdata);
    @(negedge clk);
    init_req(addr, we, wdata);
    req_valid = 1'b1;
    while (!req_accept)
      @(posedge clk);
    @(posedge clk);
    @(negedge clk);
    req_valid = 1'b0;
    while (!rsp_valid)
      @(posedge clk);
  endtask

  task automatic inject_rx(input logic [7:0] c);
    @(negedge clk);
    rx_char = c;
    rx_valid = 1'b1;
    while (!rx_ready)
      @(posedge clk);
    @(posedge clk);
    @(negedge clk);
    rx_valid = 1'b0;
  endtask

  task automatic drain_tx_one;
    @(negedge clk);
    tx_pop = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tx_pop = 1'b0;
  endtask

  mem_rsp_t result;
  mem_rsp_t held_rsp;
  integer reads_before;
  integer writes_before;
  integer pops_before;
  integer pushes_before;
  integer pre_reset_reads;
  integer pre_reset_writes;
  integer pre_reset_rx_pops;
  integer pre_reset_tx_pushes;
  logic [63:0] held_data;
  logic held_fault;

  initial begin
    $display("=== lcvex_jtag_uart_bridge_tb: DATA/CONTROL and Avalon protocol vendor_timing=%0d ===",
             VENDOR_TIMING);
    clk = 1'b0;
    rst_n = 1'b0;
    req_valid = 1'b0;
    req = '0;
    rsp_ready = 1'b1;
    rx_valid = 1'b0;
    rx_char = 8'd0;
    tx_pop = 1'b0;
    force_waitrequest = 1'b0;
    host_activity = 1'b1;
    errors = 0;
    tx_pulse_seen = 0;
    tx_pulse_last = 8'd0;
    model_event_seen = 0;
    tx_drain_seen = 0;
    tx_drain_last = 8'd0;

    // Asynchronous reset must leave the Avalon slave idle and suppress any
    // transaction side effect.
    #1;
    check_ok(!chipselect && read_n && write_n && !tx_valid,
             "reset immediately deasserts Avalon controls and TX pulse");
    check_ok(rx_data_read_count_obs == 0 && rx_rvalid_count_obs == 0 &&
             !rx_seen_obs && rx_last_byte_obs == 0,
             "reset clears all physical RX observation state");
    tick(2);
    check_ok(!req_accept, "reset does not accept a request");
    rst_n = 1'b1;
    tick(2);

    // 1. CONTROL at +4 must use Avalon address 1 and report WSPACE in the
    // upper half-word.  AC (bit 10) is deliberately asserted by the model;
    // it must not be interpreted as TX capacity.
    access(64'h0900_0004, 1'b0, 64'd0, result);
    check_ok(!result.fault, "CONTROL read has no fault");
    check_ok(result.rdata[31:16] == 16'(TX_DEPTH),
             $sformatf("CONTROL.WSPACE starts at %0d, got %0d",
                       TX_DEPTH, result.rdata[31:16]));
    check_ok(tx_wspace == 16'(TX_DEPTH),
             "model WSPACE output agrees with CONTROL.WSPACE");
    check_ok(result.rdata[10] == 1'b1, "CONTROL.AC is visible independently");
    check_ok(control_read_count == 1 && data_read_count == 0,
             "CONTROL read has exactly one Avalon side effect");
    check_ok(rx_data_read_count_obs == 0 && rx_rvalid_count_obs == 0,
             "CONTROL read does not change DATA/RVALID observation counts");

    // 2. DATA writes at the base address must reach Avalon address 0 and
    // generate one TX event with the low byte only.
    access(64'h0900_0000, 1'b1, 64'h1122_3344_0000_005a, result);
    check_ok(!result.fault, "DATA write has no fault");
    check_ok(data_write_count == 1 && control_write_count == 0,
             "DATA write maps to Avalon address 0 exactly once");
    check_ok(tx_event_count == 1 && tx_event_char == 8'h5a,
             "DATA write enqueues one low-byte TX character");
    check_ok(tx_pulse_seen == 1 && tx_pulse_last == 8'h5a,
             "DATA write emits one bridge TX pulse");
    check_ok(model_event_seen == 1,
             "Avalon model observes one TX event");

    // A write to CONTROL is still an Avalon address-1 write and must not
    // create a TX pulse or a DATA side effect.
    access(64'h0900_0004, 1'b1, 64'h0000_00ff, result);
    check_ok(!result.fault && control_write_count == 1 &&
             data_write_count == 1,
             "CONTROL write remains distinct from DATA");
    check_ok(tx_event_count == 1 && tx_pulse_seen == 1,
             "CONTROL write does not generate TX output");

    // 3. Inject repeated characters.  DATA read bit 15 and character bits
    // [7:0] must be preserved; each accepted read pops exactly one character.
    inject_rx(8'h41);
    inject_rx(8'h41);
    reads_before = data_read_count;
    pops_before = rx_pop_count;
    access(64'h0900_0000, 1'b0, 64'd0, result);
    check_ok(result.rdata[15] && result.rdata[7:0] == 8'h41,
             "first DATA read returns RVALID and first repeated character");
    access(64'h0900_0000, 1'b0, 64'd0, result);
    check_ok(result.rdata[15] && result.rdata[7:0] == 8'h41,
             "second DATA read returns RVALID and second repeated character");
    check_ok(data_read_count == reads_before + 2 &&
             rx_pop_count == pops_before + 2,
             "two DATA reads produce two Avalon reads and two RX pops");

    // Empty DATA read must report RVALID=0 and must not pop.
    access(64'h0900_0000, 1'b0, 64'd0, result);
    check_ok(!result.rdata[15] && rx_pop_count == pops_before + 2,
             "empty DATA read has RVALID=0 and no RX pop");
    check_ok(rx_data_read_count_obs == 3 && rx_rvalid_count_obs == 2 &&
             rx_seen_obs && rx_last_byte_obs == 8'h41,
             "observation state counts valid and empty DATA reads exactly");

    // 4. Delayed waitrequest: an Avalon read must remain selected, have no
    // side effect while blocked, then complete once when released.
    inject_rx(8'h52);
    reads_before = data_read_count;
    pops_before = rx_pop_count;
    @(negedge clk);
    force_waitrequest = 1'b1;
    init_req(64'h0900_0000, 1'b0, 64'd0);
    req_valid = 1'b1;
    while (!req_accept)
      @(posedge clk);
    @(posedge clk);
    @(negedge clk);
    req_valid = 1'b0;
    tick(2);
    check_ok(chipselect && !read_n && waitrequest,
             "blocked DATA read keeps Avalon read asserted");
    check_ok(data_read_count == reads_before && rx_pop_count == pops_before,
             "blocked DATA read has no duplicate/pop side effect");
    @(negedge clk);
    force_waitrequest = 1'b0;
    while (!rsp_valid)
      @(posedge clk);
    #1 held_rsp = rsp;
    check_ok(held_rsp.rdata[15] && held_rsp.rdata[7:0] == 8'h52,
             "released delayed DATA read returns queued character");
    check_ok(data_read_count == reads_before + 1 &&
             rx_pop_count == pops_before + 1,
             "released delayed DATA read completes exactly once");
    check_ok(rx_data_read_count_obs == 4 && rx_rvalid_count_obs == 3 &&
             rx_seen_obs && rx_last_byte_obs == 8'h52,
             "delayed DATA completion updates observation state once");
    @(negedge clk);

    // 5. Hold a response with rsp_ready low.  Both rsp_valid and payload
    // must remain stable, and Avalon must not be replayed.
    rsp_ready = 1'b0;
    reads_before = data_read_count;
    access_hold_response(64'h0900_0004, 1'b0, 64'd0);
    #1;
    held_data = rsp.rdata;
    held_fault = rsp.fault;
    tick(3);
    check_ok(rsp_valid && rsp.rdata == held_data && rsp.fault == held_fault,
             "response remains stable while rsp_ready is low");
    check_ok(control_read_count == 2 && data_read_count == reads_before,
             "held response does not duplicate Avalon read");
    rsp_ready = 1'b1;
    tick(1);
    check_ok(!rsp_valid, "held response retires after rsp_ready");
    @(negedge clk);

    // 6. Fill TX FIFO and verify the model-specific full behavior.  The
    // lightweight model deliberately backpressures a full DATA write.  The
    // generated IP instead accepts the Avalon write, sets WOVERFLOW and drops
    // the byte; this distinction is part of the vendor-timing regression.
    // Drain the first DATA write so the model starts this subtest empty.
    drain_tx_one;
    tick(1);
    #1;
    check_ok(tx_drain_seen == 1 && tx_drain_last == 8'h5a,
             "TX host drain pops the first queued character");
    access(64'h0900_0000, 1'b1, 64'h0000_0000_0000_10, result);
    access(64'h0900_0000, 1'b1, 64'h0000_0000_0000_11, result);
    access(64'h0900_0000, 1'b1, 64'h0000_0000_0000_12, result);
    access(64'h0900_0000, 1'b1, 64'h0000_0000_0000_13, result);
    access(64'h0900_0004, 1'b0, 64'd0, result);
    check_ok(result.rdata[31:16] == 0 && result.rdata[10] == 1'b1,
             "CONTROL.WSPACE is zero when TX FIFO is full, AC stays separate");
    check_ok(tx_wspace == 0, "model WSPACE reaches zero when TX FIFO is full");
    pushes_before = tx_push_count;
    writes_before = data_write_count;

    if (VENDOR_TIMING) begin
      access(64'h0900_0000, 1'b1, 64'h0000_0000_0000_7e, result);
      check_ok(!result.fault && data_write_count == writes_before + 1,
               "vendor full write is accepted exactly once");
      check_ok(tx_push_count == pushes_before &&
               tx_event_count == pushes_before,
               "vendor full write overflows without a FIFO push");
      check_ok(tx_pulse_seen == pushes_before + 1,
               "bridge reports the vendor-accepted overflowing write once");
      access(64'h0900_0004, 1'b0, 64'd0, result);
      check_ok(result.rdata[14], "vendor CONTROL reports WOVERFLOW");
      drain_tx_one;
      access(64'h0900_0000, 1'b1, 64'h0000_0000_0000_7e, result);
      check_ok(data_write_count == writes_before + 2 &&
               tx_push_count == pushes_before + 1 &&
               tx_event_char == 8'h7e,
               "vendor write succeeds after host drain");
      check_ok(tx_pulse_seen == pushes_before + 2,
               "vendor overflow and retry each produce one bridge pulse");
      tick(1);
      #1;
      check_ok(tx_drain_seen == 2 && tx_drain_last == 8'h10,
               "vendor host drain pops the oldest queued character");
      check_ok(avalon_read_count == 8 && avalon_write_count == 8 &&
               rx_pop_count == 3 && tx_push_count == 6,
               "vendor pre-reset Avalon/FIFO totals are exact");
    end else begin
      @(negedge clk);
      init_req(64'h0900_0000, 1'b1, 64'h0000_0000_0000_7e);
      req_valid = 1'b1;
      while (!req_accept)
        @(posedge clk);
      @(posedge clk);
      @(negedge clk);
      req_valid = 1'b0;
      tick(2);
      check_ok(chipselect && !write_n && waitrequest && !rsp_valid,
               "full TX write is held for retry under waitrequest");
      check_ok(data_write_count == writes_before &&
               tx_push_count == pushes_before &&
               tx_event_count == tx_pulse_seen,
               "full TX write has no premature Avalon/TX side effect");
      drain_tx_one;
      while (!rsp_valid)
        @(posedge clk);
      #1 held_rsp = rsp;
      check_ok(!held_rsp.fault && data_write_count == writes_before + 1 &&
               tx_push_count == pushes_before + 1 &&
               tx_event_char == 8'h7e,
               "freed TX slot accepts one retried DATA write");
      check_ok(tx_pulse_seen == pushes_before + 1,
               "retried DATA write emits one pulse only");
      tick(1);
      #1;
      check_ok(tx_drain_seen == 2 && tx_drain_last == 8'h10,
               "TX retry drains the oldest queued character exactly once");
      check_ok(avalon_read_count == 7 && avalon_write_count == 7 &&
               rx_pop_count == 3 && tx_push_count == 6,
               "behavioral pre-reset Avalon/FIFO totals are exact");
    end
    pre_reset_reads = avalon_read_count;
    pre_reset_writes = avalon_write_count;
    pre_reset_rx_pops = rx_pop_count;
    pre_reset_tx_pushes = tx_push_count;
    @(negedge clk);

    // 7. Reset during a blocked request.  Reset must drop Avalon controls,
    // clear the pending bridge state, and allow a fresh request afterward.
    force_waitrequest = 1'b1;
    @(negedge clk);
    init_req(64'h0900_0000, 1'b1, 64'h0000_0000_0000_33);
    req_valid = 1'b1;
    while (!req_accept)
      @(posedge clk);
    @(posedge clk);
    @(negedge clk);
    req_valid = 1'b0;
    tick(1);
    rst_n = 1'b0;
    #1;
    check_ok(!chipselect && read_n && write_n && !rsp_valid && !tx_valid,
             "reset cancels blocked request and drops Avalon controls");
    check_ok(data_write_count == 0,
             "reset-cancelled write has no Avalon side effect");
    check_ok(rx_data_read_count_obs == 0 && rx_rvalid_count_obs == 0 &&
             !rx_seen_obs && rx_last_byte_obs == 0,
             "reset clears RX counts, sticky state and last byte");
    rst_n = 1'b1;
    force_waitrequest = 1'b0;
    tick(2);
    access(64'h0900_0000, 1'b1, 64'h0000_0000_0000_33, result);
    check_ok(!result.fault && tx_event_char == 8'h33,
             "fresh post-reset DATA write completes normally");
    check_ok(rx_data_read_count_obs == 0 && rx_rvalid_count_obs == 0 &&
             !rx_seen_obs,
             "DATA write does not change post-reset RX observation state");
    if (VENDOR_TIMING)
      check_ok(model_event_seen + 1 == tx_pulse_seen,
               "only the vendor overflow lacks a FIFO/model event");
    else
      check_ok(model_event_seen == tx_pulse_seen,
               "each accepted DATA write has one model and bridge TX event");

    check_ok(control_read_count == 0,
             "reset clears the model side-effect counters");
    $display("JTAG_UART_TEST %s pre_reset_reads=%0d pre_reset_writes=%0d " ,
             errors == 0 ? "PASS" : "FAIL", pre_reset_reads, pre_reset_writes);
    $display("JTAG_UART_TEST pre_reset_rx_pops=%0d pre_reset_tx_pushes=%0d " ,
             pre_reset_rx_pops, pre_reset_tx_pushes);
    if (errors != 0)
      $fatal(1, "lcvex_jtag_uart_bridge_tb failed with %0d errors", errors);
    $finish;
  end

endmodule
