// lcvex_l2_l1_probe_tb.sv
// B4 独立联合 SV TB：D-L1 WB + inclusive L2 + PoC BFM。
// 不连接现有 soc_tb/lcvex_l2_tb/filelist；通过 wrapper 内部 probe 端点
// 记录 L2 主动查询和 checkpoint 的严格先后。

`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off SYNCASYNCNET */

module lcvex_l2_l1_probe_tb;
  import lcvex_pkg::*;

  localparam int LINE_BYTES = 64;
  localparam int DEPTH = 1 << 16;
  localparam int SOURCE_ID_W = 4;
  localparam int TRANSACTION_ID_W = 8;

  logic clk, rst_n;
  logic core_req_valid, core_req_ready, core_rsp_valid, core_rsp_ready;
  mem_req_t core_req;
  mem_rsp_t core_rsp;
  logic [SOURCE_ID_W-1:0] core_source_id, core_rsp_source_id;
  logic [TRANSACTION_ID_W-1:0] core_transaction_id, core_rsp_transaction_id;
  logic ptw_req_valid, ptw_req_ready, ptw_rsp_valid, ptw_rsp_ready;
  mem_req_t ptw_req;
  mem_rsp_t ptw_rsp;
  logic poc_req_valid, poc_req_ready, poc_rsp_valid, poc_rsp_ready;
  mem_req_t poc_req;
  mem_rsp_t poc_rsp;
  logic checkpoint_quiesce, checkpoint_ack_valid, checkpoint_ack_ready;
  logic checkpoint_fault, l1_drain_done, l1_drain_fault;
  logic l2_drain_ack_valid, l2_drain_fault;
  logic fault_enable, fault_we_only;
  logic [63:0] fault_addr;
  logic init_we;
  logic [63:0] init_addr, init_wdata;
  logic [7:0] init_strb;
  logic [31:0] accepted_count, response_count, write_count, read_count;

  integer errors;
  integer operations;
  integer probe_count;
  integer drain_req_count;
  integer probe_clean_count;
  logic saw_probe_before_drain;

  lcvex_l1_coherence #(
      .LINE_BYTES(LINE_BYTES), .L1_SETS(4), .L2_SETS(4), .L2_WAYS(2),
      .SOURCE_ID_W(SOURCE_ID_W), .TRANSACTION_ID_W(TRANSACTION_ID_W)
  ) dut (
      .clk(clk), .rst_n(rst_n),
      .core_req_valid(core_req_valid), .core_req(core_req),
      .core_req_ready(core_req_ready), .core_rsp_valid(core_rsp_valid),
      .core_rsp(core_rsp), .core_rsp_ready(core_rsp_ready),
      .core_source_id(core_source_id), .core_transaction_id(core_transaction_id),
      .core_rsp_source_id(core_rsp_source_id),
      .core_rsp_transaction_id(core_rsp_transaction_id),
      .ptw_req_valid(ptw_req_valid), .ptw_req(ptw_req),
      .ptw_req_ready(ptw_req_ready), .ptw_rsp_valid(ptw_rsp_valid),
      .ptw_rsp(ptw_rsp), .ptw_rsp_ready(ptw_rsp_ready),
      .poc_req_valid(poc_req_valid), .poc_req(poc_req),
      .poc_req_ready(poc_req_ready), .poc_rsp_valid(poc_rsp_valid),
      .poc_rsp(poc_rsp), .poc_rsp_ready(poc_rsp_ready),
      .checkpoint_quiesce(checkpoint_quiesce),
      .checkpoint_ack_valid(checkpoint_ack_valid),
      .checkpoint_ack_ready(checkpoint_ack_ready),
      .checkpoint_fault(checkpoint_fault), .l1_drain_done(l1_drain_done),
      .l1_drain_fault(l1_drain_fault),
      .l2_drain_ack_valid(l2_drain_ack_valid),
      .l2_drain_fault(l2_drain_fault)
  );

  lcvex_l1_d_wb_bfm #(.DEPTH(DEPTH), .BFM_SEED(32'hb4_056a)) poc (
      .clk(clk), .rst_n(rst_n), .req_valid(poc_req_valid), .req(poc_req),
      .req_ready(poc_req_ready), .rsp_valid(poc_rsp_valid), .rsp(poc_rsp),
      .rsp_ready(poc_rsp_ready), .fault_enable(fault_enable),
      .fault_addr(fault_addr), .fault_we_only(fault_we_only),
      .init_we(init_we), .init_addr(init_addr), .init_strb(init_strb),
      .init_wdata(init_wdata), .accepted_count(accepted_count),
      .response_count(response_count), .write_count(write_count),
      .read_count(read_count)
  );

  always #5 clk = ~clk;

  always @(posedge clk) begin
    if (dut.l2_l1_probe_req_valid && dut.l2_l1_probe_req_ready) begin
      probe_count = probe_count + 1;
      if (dut.l2_l1_probe_req_cmd == 2'd1) probe_clean_count = probe_clean_count + 1;
      if (!l2_drain_ack_valid) saw_probe_before_drain = 1'b1;
      $display("TB_L1_PROBE cmd=%0d addr=0x%h t=%0t",
               dut.l2_l1_probe_req_cmd, dut.l2_l1_probe_req_addr, $time);
    end
    if (dut.l2_drain_req_valid && dut.l2_drain_req_ready) begin
      drain_req_count = drain_req_count + 1;
      check_order: assert (l1_drain_done)
        else begin $display("FAIL: L2 drain before L1 done"); errors = errors + 1; end
    end
  end

  function automatic mem_req_t mkreq(input logic [63:0] a, input logic we,
      input logic [7:0] strb, input logic [63:0] wd, input maint_op_t m,
      input logic bypass);
    mem_req_t q;
    begin
      q = '0; q.addr = a; q.we = we; q.strb = strb; q.wdata = wd;
      q.maint = m; q.bypass = bypass; mkreq = q;
    end
  endfunction

  task automatic check_ok(input logic cond, input string msg);
    if (!cond) begin $display("FAIL: %s", msg); errors = errors + 1; end
  endtask

  task automatic init_line(input logic [63:0] a, input logic [7:0] pattern);
    logic [63:0] w;
    begin
      for (int c = 0; c < 8; c++) begin
        w = '0;
        for (int i = 0; i < 8; i++) w[i*8 +: 8] = pattern + c*8 + i;
        @(negedge clk); init_we = 1; init_addr = a + c*8;
        init_strb = 8'hff; init_wdata = w;
        @(posedge clk); #1 init_we = 0;
      end
    end
  endtask

  task automatic core_access(input mem_req_t q, output mem_rsp_t r);
    logic [SOURCE_ID_W-1:0] sid;
    logic [TRANSACTION_ID_W-1:0] tid;
    begin
      operations = operations + 1;
      sid = operations[3:0]; tid = (operations * 8'h37) ^ 8'hc3;
      @(negedge clk); core_req = q; core_source_id = sid;
      core_transaction_id = tid; core_req_valid = 1;
      while (!core_req_ready) @(negedge clk);
      @(posedge clk); @(negedge clk); core_req_valid = 0;
      while (!core_rsp_valid) @(negedge clk);
      check_ok(core_rsp_source_id == sid && core_rsp_transaction_id == tid,
               "core source/transaction round trip");
      r = core_rsp;
      core_rsp_ready = 0; repeat (2) @(posedge clk);
      check_ok(core_rsp_valid && core_rsp.rdata == r.rdata &&
               core_rsp.fault == r.fault, "core response backpressure hold");
      core_rsp_ready = 1; @(posedge clk); #1;
    end
  endtask

  task automatic ptw_access(input mem_req_t q, output mem_rsp_t r);
    begin
      @(negedge clk); ptw_req = q; ptw_req_valid = 1;
      while (!ptw_req_ready) @(negedge clk);
      @(posedge clk); @(negedge clk); ptw_req_valid = 0;
      while (!ptw_rsp_valid) @(negedge clk);
      r = ptw_rsp; ptw_rsp_ready = 1; @(posedge clk); #1;
    end
  endtask

  task automatic check_mem_line(input logic [63:0] a, input logic [7:0] p);
    for (int c = 0; c < 8; c++) begin
      for (int i = 0; i < 8; i++)
        check_ok(poc.mem[a+c*8+i] == p+c*8+i,
                 $sformatf("PoC line 0x%h byte %0d", a, c*8+i));
    end
  endtask

  initial begin
    mem_rsp_t r;
    logic [63:0] expected;
    errors = 0; operations = 0; probe_count = 0; probe_clean_count = 0;
    drain_req_count = 0; saw_probe_before_drain = 0;
    clk = 0; rst_n = 0; core_req_valid = 0; core_req = '0;
    core_rsp_ready = 1; core_source_id = 0; core_transaction_id = 0;
    ptw_req_valid = 0; ptw_req = '0; ptw_rsp_ready = 1;
    checkpoint_quiesce = 0; checkpoint_ack_ready = 1;
    fault_enable = 0; fault_addr = 0; fault_we_only = 0;
    init_we = 0; init_addr = 0; init_strb = 0; init_wdata = 0;
    init_line(64'h100, 8'h10);
    init_line(64'h500, 8'h50);
    init_line(64'h900, 8'h90);
    init_line(64'hd00, 8'hd0);
    repeat (2) @(posedge clk); check_ok(!core_rsp_valid && !ptw_rsp_valid,
                                        "reset has no stale response");
    rst_n = 1; repeat (2) @(posedge clk);

    // 1. First read allocates in both levels; store stays dirty in D-L1.
    core_access(mkreq(64'h100, 0, 0, 0, MAINT_NONE, 0), r);
    check_ok(!r.fault && r.rdata == 64'h1716151413121110,
             "joint read miss/refill");
    core_access(mkreq(64'h104, 1, 8'h0f, 64'h8877665544332211,
                      MAINT_NONE, 0), r);
    check_ok(!r.fault, "joint partial store");

    // 2. PTW is routed through the same D-L1 and sees latest dirty data.
    ptw_access(mkreq(64'h104, 0, 0, 0, MAINT_NONE, 0), r);
    check_ok(!r.fault && r.rdata == 64'h1b1a191844332211,
             "PTW observes D-L1 dirty page-table data");

    // 3. Evicting the D-L1 line sends all beats into L2; no data loss.
    core_access(mkreq(64'h500, 0, 0, 0, MAINT_NONE, 0), r);
    check_ok(!r.fault && r.rdata == 64'h5756555453525150,
             "D-L1 dirty victim then new refill");
    check_ok(dut.d_l1.valid[0] && dut.d_l1.tags[0] == 64'h500 >> 8,
             "D-L1 victim replaced by new line");

    // 4. DC CVAC: local clean first, then L2 actively probes D-L1.
    core_access(mkreq(64'h500, 1, 8'h01, 64'h000000000000a5,
                      MAINT_NONE, 0), r);
    core_access(mkreq(64'h500, 0, 0, 0, MAINT_DC_CVAC, 0), r);
    check_ok(!r.fault, "DC CVAC propagates through L2");
    check_ok(probe_count > 0 && probe_clean_count > 0,
             "L2 emitted D-L1 clean probe");

    // 5. DC CIVAC: clean+invalidate; subsequent load must refill.
    core_access(mkreq(64'h500, 1, 8'h03, 64'h000000000000bbaa,
                      MAINT_NONE, 0), r);
    core_access(mkreq(64'h500, 0, 0, 0, MAINT_DC_CIVAC, 0), r);
    check_ok(!r.fault, "DC CIVAC response");
    core_access(mkreq(64'h500, 0, 0, 0, MAINT_NONE, 0), r);
    check_ok(!r.fault && r.rdata == 64'h575655545352bbaa,
             "post CIVAC refills clean PoC data");

    // 6. IC IVAU is ordered after the DC path and is visible at L2.
    core_access(mkreq(64'h500, 0, 0, 0, MAINT_IC_IVAU, 0), r);
    check_ok(!r.fault, "IC invalidate propagation");

    // 7. checkpoint order and clean-to-PoC.  L1 done must precede L2 req.
    core_access(mkreq(64'h900, 1, 8'hff, 64'h0123456789abcdef,
                      MAINT_NONE, 0), r);
    checkpoint_quiesce = 1;
    while (!checkpoint_ack_valid && !checkpoint_fault) @(posedge clk);
    check_ok(checkpoint_ack_valid && !checkpoint_fault,
             "checkpoint clean-to-PoC ack");
    check_ok(drain_req_count == 1 && l1_drain_done,
             "checkpoint order L1 done then L2 drain");
    checkpoint_ack_ready = 0; repeat (2) @(posedge clk);
    check_ok(checkpoint_ack_valid, "checkpoint ack holds under backpressure");
    checkpoint_ack_ready = 1; @(posedge clk); #1;
    checkpoint_quiesce = 0; repeat (2) @(posedge clk);
    check_ok(poc.mem[64'h900] == 8'hef && poc.mem[64'h907] == 8'h01,
             "checkpoint wrote dirty D-L1 bytes to PoC");

    // 8. L2 drain fault: no success ack and no stale response.
    core_access(mkreq(64'hd00, 1, 8'h01, 64'h0000000000005a,
                      MAINT_NONE, 0), r);
    fault_enable = 1; fault_addr = 64'hd00; fault_we_only = 1;
    checkpoint_quiesce = 1;
    while (!checkpoint_fault && !checkpoint_ack_valid) @(posedge clk);
    check_ok(checkpoint_fault && !checkpoint_ack_valid,
             "checkpoint fault suppresses success ack");
    fault_enable = 0; checkpoint_quiesce = 0; repeat (2) @(posedge clk);
    check_ok(!core_rsp_valid && !ptw_rsp_valid, "fault leaves no stale client rsp");

    check_ok(accepted_count == response_count, "PoC response accounting");
    $display("TB_COUNTS accepted=%0d responses=%0d reads=%0d writes=%0d",
             accepted_count, response_count, read_count, write_count);
    check_ok(write_count >= 8 && read_count >= 32, "joint refill/writeback traffic");
    if (errors == 0) begin
      $display("PASS: lcvex_l2_l1_probe_tb operations=%0d probes=%0d drain=%0d",
               operations, probe_count, drain_req_count);
      $finish;
    end else $fatal(1, "FAIL: %0d errors", errors);
  end

endmodule
