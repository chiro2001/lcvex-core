// lcvex_catapult_soc_status_tb.sv
// Directed contract test for calibration and physical JTAG-RX observation
// registers in the PLAT_STATUS window.

`timescale 1ns/1ps

module lcvex_catapult_soc_status_tb;
  import lcvex_pkg::*;
  import lcvex_catapult_soc_pkg::*;

  logic clk;
  logic rst_n;
  logic req_valid;
  mem_req_t req;
  logic req_accept;
  logic rsp_valid;
  mem_rsp_t rsp;
  logic rsp_ready;
  logic cal_ready;
  logic cal_failed;
  logic [31:0] jtag_data_read_count;
  logic [15:0] jtag_rvalid_count;
  logic jtag_rx_seen;
  logic [7:0] jtag_last_rx_byte;
  logic [31:0] jtag_bridge_rsp_data;
  logic [31:0] jtag_poc_rsp_data;
  logic [31:0] jtag_dmem_rsp_data;
  logic [31:0] jtag_path_events;
  logic [31:0] jtag_tx_events;
  integer errors;
  mem_rsp_t result;
  logic [63:0] cycle_before;
  logic [63:0] cycle_after;

  lcvex_catapult_soc_status dut (
      .clk(clk), .rst_n(rst_n),
      .req_valid(req_valid), .req(req), .req_accept(req_accept),
      .rsp_valid(rsp_valid), .rsp(rsp), .rsp_ready(rsp_ready),
      .cal_ready(cal_ready), .cal_failed(cal_failed),
      .jtag_data_read_count(jtag_data_read_count),
      .jtag_rvalid_count(jtag_rvalid_count),
      .jtag_rx_seen(jtag_rx_seen), .jtag_last_rx_byte(jtag_last_rx_byte),
      .jtag_bridge_rsp_data(jtag_bridge_rsp_data),
      .jtag_poc_rsp_data(jtag_poc_rsp_data),
      .jtag_dmem_rsp_data(jtag_dmem_rsp_data),
      .jtag_path_events(jtag_path_events),
      .jtag_tx_events(jtag_tx_events)
  );

  always #5 clk = ~clk;

  task automatic check_ok(input logic cond, input string msg);
    if (!cond) begin
      $display("FAIL: %s", msg);
      errors = errors + 1;
    end
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

  task automatic access(input logic [63:0] addr, input logic we,
                        input logic [63:0] wdata, output mem_rsp_t value);
    @(negedge clk);
    init_req(addr, we, wdata);
    req_valid = 1'b1;
    #1;
    if (!req_accept)
      $fatal(1, "status request was not ready addr=%016h", addr);
    @(posedge clk);
    #1;
    if (!rsp_valid)
      $fatal(1, "status response missing after acceptance addr=%016h", addr);
    value = rsp;
    @(negedge clk);
    req_valid = 1'b0;
    @(posedge clk);
    @(negedge clk);
  endtask

  task automatic access_hold(input logic [63:0] addr);
    @(negedge clk);
    init_req(addr, 1'b0, 64'd0);
    req_valid = 1'b1;
    #1;
    if (!req_accept)
      $fatal(1, "held status request was not ready addr=%016h", addr);
    @(posedge clk);
    #1;
    if (!rsp_valid)
      $fatal(1, "held status response missing addr=%016h", addr);
    @(negedge clk);
    req_valid = 1'b0;
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    req_valid = 1'b0;
    req = '0;
    rsp_ready = 1'b1;
    cal_ready = 1'b0;
    cal_failed = 1'b0;
    jtag_data_read_count = 32'h89ab_cdef;
    jtag_rvalid_count = 16'h1234;
    jtag_rx_seen = 1'b1;
    jtag_last_rx_byte = 8'h5a;
    jtag_bridge_rsp_data = 32'h0000_803f;
    jtag_poc_rsp_data = 32'h0000_803f;
    jtag_dmem_rsp_data = 32'h0000_803f;
    jtag_path_events = {8'h03, 8'h02, 8'h01, 5'd0, 1'b1, 1'b0, 1'b1};
    jtag_tx_events = {16'h0042, 7'd0, 1'b1, 8'h5a};
    errors = 0;

    #1;
    check_ok(!req_accept && !rsp_valid,
             "reset suppresses requests and responses");
    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    access(SOC_PLAT_STATUS_BASE + SOC_STATUS_CAL_OFFSET,
           1'b0, 64'd0, result);
    check_ok(!result.fault && result.rdata == 64'h0000_0000_0000_0100,
             "base status preserves version and CAL-WAIT encoding");

    cal_ready = 1'b1;
    access(SOC_PLAT_STATUS_BASE + SOC_STATUS_CAL_OFFSET,
           1'b0, 64'd0, result);
    check_ok(result.rdata == 64'h0000_0000_0000_0105,
             "base status preserves cal_ready/ddr_en bits");

    access(SOC_PLAT_STATUS_BASE + SOC_STATUS_JTAG_READ_COUNT_OFFSET,
           1'b0, 64'd0, result);
    check_ok(result.rdata == 64'h0000_0000_89ab_cdef,
             "+0x8 returns the full DATA-read count");

    access(SOC_PLAT_STATUS_BASE + SOC_STATUS_JTAG_RX_EVENT_OFFSET,
           1'b0, 64'd0, result);
    check_ok(result.rdata == 64'h0000_0000_1234_015a,
             "+0x10 packs RVALID count, seen sticky and last byte");

    access(SOC_PLAT_STATUS_BASE + SOC_STATUS_JTAG_BRIDGE_RSP_OFFSET,
           1'b0, 64'd0, result);
    check_ok(result.rdata == 64'h0000_0000_0000_803f,
             "+0x18 returns bridge DATA response low 32 bits");
    access(SOC_PLAT_STATUS_BASE + SOC_STATUS_JTAG_POC_RSP_OFFSET,
           1'b0, 64'd0, result);
    check_ok(result.rdata == 64'h0000_0000_0000_803f,
             "+0x20 returns PoC DATA response low 32 bits");
    access(SOC_PLAT_STATUS_BASE + SOC_STATUS_JTAG_DMEM_RSP_OFFSET,
           1'b0, 64'd0, result);
    check_ok(result.rdata == 64'h0000_0000_0000_803f,
             "+0x28 returns core dmem response low 32 bits");
    access(SOC_PLAT_STATUS_BASE + SOC_STATUS_JTAG_PATH_EVENTS_OFFSET,
           1'b0, 64'd0, result);
    check_ok(result.rdata == 64'h0000_0000_0302_0105,
             "+0x30 packs path counts and dmem/PoC/bridge faults");
    access(SOC_PLAT_STATUS_BASE + SOC_STATUS_JTAG_TX_EVENT_OFFSET,
           1'b0, 64'd0, result);
    check_ok(result.rdata == 64'h0000_0000_0042_015a,
             "+0x38 packs accepted TX count, seen sticky and last byte");

    access(SOC_PLAT_STATUS_BASE + SOC_STATUS_CYCLE_COUNT_OFFSET,
           1'b0, 64'd0, result);
    cycle_before = result.rdata;
    repeat (5) @(posedge clk);
    access(SOC_PLAT_STATUS_BASE + SOC_STATUS_CYCLE_COUNT_OFFSET,
           1'b0, 64'd0, result);
    cycle_after = result.rdata;
    check_ok(cycle_after > cycle_before,
             "+0x40 cycle counter is 64-bit and monotonic");
    access(SOC_PLAT_STATUS_BASE + SOC_STATUS_CYCLE_COUNT_OFFSET,
           1'b1, 64'hffff_ffff_ffff_ffff, result);
    access(SOC_PLAT_STATUS_BASE + SOC_STATUS_CYCLE_COUNT_OFFSET,
           1'b0, 64'd0, result);
    check_ok(result.rdata > cycle_after,
             "+0x40 cycle counter is read-only and not overwritten");

    access(SOC_PLAT_STATUS_BASE + 64'h3c, 1'b0, 64'd0, result);
    check_ok(result.rdata == 64'd0,
             "unassigned PLAT_STATUS offsets read as zero");

    access(SOC_PLAT_STATUS_BASE + SOC_STATUS_JTAG_BRIDGE_RSP_OFFSET,
           1'b1, 64'hffff_ffff, result);
    access(SOC_PLAT_STATUS_BASE + SOC_STATUS_JTAG_BRIDGE_RSP_OFFSET,
           1'b0, 64'd0, result);
    check_ok(result.rdata == 64'h0000_0000_0000_803f,
             "writes are ignored and new response registers remain read-only");

    rsp_ready = 1'b0;
    access_hold(SOC_PLAT_STATUS_BASE + SOC_STATUS_JTAG_DMEM_RSP_OFFSET);
    #1 result = rsp;
    jtag_dmem_rsp_data = 32'hdead_beef;
    repeat (3) @(posedge clk);
    #1;
    check_ok(rsp_valid && rsp.rdata == result.rdata && !rsp.fault,
             "response remains stable under backpressure");
    rst_n = 1'b0;
    #1;
    check_ok(!rsp_valid && !req_accept,
             "reset cancels a pending response under backpressure");
    rst_n = 1'b1;
    rsp_ready = 1'b1;
    repeat (2) @(posedge clk);

    rst_n = 1'b0;
    #1;
    check_ok(!rsp_valid && !req_accept,
             "reset clears a completed status transaction");
    check_ok(dut.cycle_counter_q == 64'd0,
             "reset value of the cycle counter is zero");

    $display("CATAPULT_STATUS_OBSERVABILITY_TEST %s",
             errors == 0 ? "PASS" : "FAIL");
    if (errors != 0)
      $fatal(1, "status observability test failed with %0d errors", errors);
    $finish;
  end

endmodule
