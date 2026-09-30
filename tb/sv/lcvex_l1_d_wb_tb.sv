// lcvex_l1_d_wb_tb.sv
// B4 L1 独立 SV scoreboard：write-allocate、partial store、dirty victim、
// L2 probe、fault/reset 保留和 checkpoint local drain。

`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off SYNCASYNCNET */

module lcvex_l1_d_wb_tb;
  import lcvex_pkg::*;

  localparam int LINE_BYTES = 64;
  localparam int SETS = 4;
  localparam int DEPTH = 1 << 16;
  localparam int SOURCE_ID_W = 4;
  localparam int TRANSACTION_ID_W = 8;

  logic clk, rst_n;
  logic u_req_valid;
  mem_req_t u_req;
  logic u_req_ready, u_rsp_valid, u_rsp_ready;
  mem_rsp_t u_rsp;
  logic d_req_valid, d_req_ready, d_rsp_valid, d_rsp_ready;
  mem_req_t d_req;
  mem_rsp_t d_rsp;

  logic l1_probe_req_valid, l1_probe_req_ready;
  logic [63:0] l1_probe_req_addr;
  logic [1:0] l1_probe_req_cmd;
  logic [SOURCE_ID_W-1:0] l1_probe_req_source_id;
  logic [TRANSACTION_ID_W-1:0] l1_probe_req_transaction_id;
  logic l1_probe_rsp_valid, l1_probe_rsp_ready, l1_probe_rsp_fault;
  logic l1_probe_rsp_line_valid, l1_probe_rsp_dirty;
  logic [LINE_BYTES*8-1:0] l1_probe_rsp_data;
  logic [63:0] l1_probe_rsp_addr;
  logic [SOURCE_ID_W-1:0] l1_probe_rsp_source_id;
  logic [TRANSACTION_ID_W-1:0] l1_probe_rsp_transaction_id;
  logic l1_probe_rsp_abort;

  logic checkpoint_quiesce, l1_drain_done, l1_drain_fault;
  logic fault_enable, fault_we_only;
  logic [63:0] fault_addr;
  logic init_we;
  logic [63:0] init_addr, init_wdata;
  logic [7:0] init_strb;
  logic [31:0] accepted_count, response_count, write_count, read_count;
  integer errors;
  integer operations;

  lcvex_l1_d_wb #(
      .LINE_BYTES(LINE_BYTES), .SETS(SETS),
      .SOURCE_ID_W(SOURCE_ID_W), .TRANSACTION_ID_W(TRANSACTION_ID_W)
  ) dut (
      .clk(clk), .rst_n(rst_n),
      .u_req_valid(u_req_valid), .u_req(u_req), .u_req_ready(u_req_ready),
      .u_rsp_valid(u_rsp_valid), .u_rsp(u_rsp), .u_rsp_ready(u_rsp_ready),
      .d_req_valid(d_req_valid), .d_req(d_req), .d_req_ready(d_req_ready),
      .d_rsp_valid(d_rsp_valid), .d_rsp(d_rsp), .d_rsp_ready(d_rsp_ready),
      .l1_probe_req_valid(l1_probe_req_valid),
      .l1_probe_req_ready(l1_probe_req_ready),
      .l1_probe_req_addr(l1_probe_req_addr),
      .l1_probe_req_cmd(l1_probe_req_cmd),
      .l1_probe_req_source_id(l1_probe_req_source_id),
      .l1_probe_req_transaction_id(l1_probe_req_transaction_id),
      .l1_probe_rsp_valid(l1_probe_rsp_valid),
      .l1_probe_rsp_ready(l1_probe_rsp_ready),
      .l1_probe_rsp_fault(l1_probe_rsp_fault),
      .l1_probe_rsp_line_valid(l1_probe_rsp_line_valid),
      .l1_probe_rsp_dirty(l1_probe_rsp_dirty),
      .l1_probe_rsp_data(l1_probe_rsp_data),
      .l1_probe_rsp_addr(l1_probe_rsp_addr),
      .l1_probe_rsp_source_id(l1_probe_rsp_source_id),
      .l1_probe_rsp_transaction_id(l1_probe_rsp_transaction_id),
      .l1_probe_rsp_abort(l1_probe_rsp_abort),
      .checkpoint_quiesce(checkpoint_quiesce),
      .l1_drain_done(l1_drain_done), .l1_drain_fault(l1_drain_fault)
  );

  lcvex_l1_d_wb_bfm #(.DEPTH(DEPTH), .BFM_SEED(32'hd1_056a)) bfm (
      .clk(clk), .rst_n(rst_n), .req_valid(d_req_valid), .req(d_req),
      .req_ready(d_req_ready), .rsp_valid(d_rsp_valid), .rsp(d_rsp),
      .rsp_ready(d_rsp_ready), .fault_enable(fault_enable),
      .fault_addr(fault_addr), .fault_we_only(fault_we_only),
      .init_we(init_we), .init_addr(init_addr), .init_strb(init_strb),
      .init_wdata(init_wdata), .accepted_count(accepted_count),
      .response_count(response_count), .write_count(write_count),
      .read_count(read_count)
  );

  always #5 clk = ~clk;

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
        @(negedge clk); init_we = 1'b1; init_addr = a + c*8;
        init_strb = 8'hff; init_wdata = w;
        @(posedge clk); #1 init_we = 1'b0;
      end
    end
  endtask

  task automatic core_req(input mem_req_t q, output mem_rsp_t r);
    begin
      operations = operations + 1;
      @(negedge clk); u_req = q; u_req_valid = 1'b1;
      while (!u_req_ready) @(negedge clk);
      @(posedge clk); @(negedge clk); u_req_valid = 1'b0;
      while (!u_rsp_valid) @(negedge clk);
      r = u_rsp;
      u_rsp_ready = 1'b0; repeat (2) @(posedge clk);
      check_ok(u_rsp_valid && u_rsp.fault == r.fault &&
               u_rsp.rdata == r.rdata, "response hold payload");
      u_rsp_ready = 1'b1; @(posedge clk); #1;
    end
  endtask

  task automatic probe_req(input logic [63:0] a, input logic [1:0] cmd,
      output logic fault, output logic hit, output logic dirty_o,
      output logic [LINE_BYTES*8-1:0] line);
    begin
      @(negedge clk); l1_probe_req_addr = a; l1_probe_req_cmd = cmd;
      l1_probe_req_source_id = 4'hb; l1_probe_req_transaction_id = 8'h5a;
      l1_probe_req_valid = 1'b1;
      while (!l1_probe_req_ready) @(negedge clk);
      @(posedge clk); @(negedge clk); l1_probe_req_valid = 1'b0;
      while (!l1_probe_rsp_valid) @(negedge clk);
      fault = l1_probe_rsp_fault; hit = l1_probe_rsp_line_valid;
      dirty_o = l1_probe_rsp_dirty; line = l1_probe_rsp_data;
      check_ok(l1_probe_rsp_addr == (a & ~64'h3f), "probe line address");
      check_ok(l1_probe_rsp_source_id == 4'hb &&
               l1_probe_rsp_transaction_id == 8'h5a, "probe ID hold");
      l1_probe_rsp_ready = 1'b0; repeat (2) @(posedge clk);
      check_ok(l1_probe_rsp_valid && l1_probe_rsp_dirty == dirty_o &&
               l1_probe_rsp_data == line, "probe response must hold");
      l1_probe_rsp_ready = 1'b1; @(posedge clk); #1;
    end
  endtask

  task automatic check_meta(input logic [63:0] a, input logic want_valid,
                             input logic want_dirty);
    integer s;
    begin
      s = (a >> 6) & (SETS-1);
      check_ok(dut.valid[s] == want_valid,
               $sformatf("valid line 0x%h expected %0d", a, want_valid));
      if (want_valid)
        check_ok(dut.tags[s] == a >> (6 + $clog2(SETS)),
                 $sformatf("tag line 0x%h", a));
      check_ok(dut.dirty[s] == (want_valid && want_dirty),
               $sformatf("dirty line 0x%h", a));
    end
  endtask

  task automatic check_mem_byte(input logic [63:0] a, input logic [7:0] v);
    check_ok(bfm.mem[a] == v, $sformatf("memory byte 0x%h got %02x", a,
                                        bfm.mem[a]));
  endtask

  task automatic simultaneous_probe_core_req(output mem_rsp_t r);
    begin
      operations = operations + 1;
      @(negedge clk);
      u_req = mkreq(64'h100, 1'b0, 8'h00, 64'd0, MAINT_NONE, 1'b0);
      u_req_valid = 1'b1;
      l1_probe_req_addr = 64'h200;
      l1_probe_req_cmd = 2'd0;
      l1_probe_req_source_id = 4'hc;
      l1_probe_req_transaction_id = 8'h6b;
      l1_probe_req_valid = 1'b1;
      #1;
      check_ok(l1_probe_req_ready && !u_req_ready,
               "simultaneous probe has exclusive acceptance priority");
      @(posedge clk);
      @(negedge clk);
      l1_probe_req_valid = 1'b0;
      check_ok(l1_probe_rsp_valid && !l1_probe_rsp_fault &&
               !l1_probe_rsp_line_valid,
               "simultaneous miss probe produces its response");
      while (!u_req_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      u_req_valid = 1'b0;
      while (!u_rsp_valid) @(negedge clk);
      r = u_rsp;
      check_ok(!r.fault && r.rdata == 64'h1716151413121110,
               "deferred core request is accepted after probe");
      @(posedge clk);
      #1;
    end
  endtask

  initial begin
    mem_rsp_t r;
    logic pf, ph, pd;
    logic [LINE_BYTES*8-1:0] pl;
    errors = 0; operations = 0; clk = 0; rst_n = 0;
    u_req_valid = 0; u_req = '0; u_rsp_ready = 1;
    l1_probe_req_valid = 0; l1_probe_req_addr = 0; l1_probe_req_cmd = 0;
    l1_probe_req_source_id = 0; l1_probe_req_transaction_id = 0;
    l1_probe_rsp_ready = 1; l1_probe_rsp_abort = 0; checkpoint_quiesce = 0;
    fault_enable = 0; fault_addr = 0; fault_we_only = 0;
    init_we = 0; init_addr = 0; init_strb = 0; init_wdata = 0;
    init_line(64'h100, 8'h10);
    init_line(64'h500, 8'h50);
    init_line(64'h900, 8'h90);
    init_line(64'hd00, 8'hd0);
    init_line(64'h1180, 8'ha0);
    init_line(64'h11c0, 8'h80);
    init_line(64'h12c0, 8'hc0);
    init_line(64'h1200, 8'h40);
    init_line(64'h1200, 8'h40);
    repeat (2) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);

    // 0. Probe and upstream requests may arrive together.  The interface
    // must acknowledge only the request selected by the sequential priority;
    // the held core request is accepted after the probe completes.
    simultaneous_probe_core_req(r);

    // 1. Read miss/refill and partial write makes a dirty line.
    core_req(mkreq(64'h100, 0, 0, 0, MAINT_NONE, 0), r);
    check_ok(!r.fault && r.rdata == 64'h1716151413121110, "read allocate");
    core_req(mkreq(64'h138, 0, 0, 0, MAINT_NONE, 0), r);
    check_ok(!r.fault && r.rdata == 64'h4f4e4d4c4b4a4948,
             "read hit final 8-byte cache chunk");
    core_req(mkreq(64'h11b8, 0, 0, 0, MAINT_NONE, 0), r);
    check_ok(!r.fault && r.rdata == 64'hdfdedddcdbdad9d8,
             "read miss final 8-byte cache chunk");
    core_req(mkreq(64'h104, 1, 8'h0f, 64'h8877665544332211,
                    MAINT_NONE, 0), r);
    check_ok(!r.fault, "partial store");
    check_meta(64'h100, 1, 1);

    // 2. Same-set miss writes the complete dirty victim before refill.
    core_req(mkreq(64'h500, 0, 0, 0, MAINT_NONE, 0), r);
    check_ok(!r.fault && r.rdata == 64'h5756555453525150, "dirty victim refill");
    check_mem_byte(64'h100, 8'h10);
    check_mem_byte(64'h104, 8'h11);
    check_mem_byte(64'h107, 8'h44);

    // 3. L2 probe lookup and clean/invalidate commit point.
    core_req(mkreq(64'h500, 1, 8'h03, 64'h000000000000bbaa,
                    MAINT_NONE, 0), r);
    probe_req(64'h500, 2'd0, pf, ph, pd, pl);
    check_ok(!pf && ph && pd, "lookup returns dirty raw line");
    check_ok(pl[0 +: 8] == 8'haa && pl[8 +: 8] == 8'hbb,
             "probe raw bytes");
    probe_req(64'h500, 2'd1, pf, ph, pd, pl);
    check_ok(!pf && ph && pd, "clean response carries pre-clean raw metadata");
    probe_req(64'h500, 2'd0, pf, ph, pd, pl);
    check_ok(!pf && ph && !pd, "clean commits before next lookup");
    probe_req(64'h500, 2'd2, pf, ph, pd, pl);
    check_ok(!pf && ph, "invalidate response reports old line");
    check_meta(64'h500, 0, 0);

    // 4. Writeback fault leaves victim metadata intact; retry is complete.
    core_req(mkreq(64'h900, 0, 0, 0, MAINT_NONE, 0), r);
    core_req(mkreq(64'h901, 1, 8'h01, 64'h000000000000005a,
                    MAINT_NONE, 0), r);
    check_meta(64'h900, 1, 1);
    fault_enable = 1; fault_addr = 64'h900; fault_we_only = 1;
    core_req(mkreq(64'hd00, 0, 0, 0, MAINT_NONE, 0), r);
    check_ok(r.fault, "faulted dirty victim reaches core");
    check_meta(64'h900, 1, 1);
    fault_enable = 0;
    core_req(mkreq(64'hd00, 0, 0, 0, MAINT_NONE, 0), r);
    check_ok(!r.fault, "retry after victim fault");
    check_meta(64'hd00, 1, 0);

    // 5. Local checkpoint drain, then no stale response after reset/release.
    core_req(mkreq(64'hd04, 1, 8'h0f, 64'h1111222233334444,
                    MAINT_NONE, 0), r);
    checkpoint_quiesce = 1;
    while (!l1_drain_done && !l1_drain_fault) @(posedge clk);
    check_ok(l1_drain_done && !l1_drain_fault, "L1 checkpoint drain done");
    check_meta(64'hd00, 1, 0);
    check_mem_byte(64'hd04, 8'h44);
    check_ok(!u_req_ready, "quiesce blocks core request");
    checkpoint_quiesce = 0; repeat (2) @(posedge clk);

    // 6. Drain fault retains dirty line and never reports done.
    core_req(mkreq(64'h100, 1, 8'h01, 64'h000000000000e1,
                    MAINT_NONE, 0), r);
    fault_enable = 1; fault_addr = 64'h100; fault_we_only = 1;
    checkpoint_quiesce = 1;
    while (!l1_drain_done && !l1_drain_fault) @(posedge clk);
    check_ok(l1_drain_fault && !l1_drain_done,
             "drain fault has no success done");
    check_meta(64'h100, 1, 1);
    checkpoint_quiesce = 0; fault_enable = 0; repeat (2) @(posedge clk);

    // 7. An unaligned 8-byte read that starts at byte 58 crosses the 64-byte
    // line. The low six bytes come from the first line; the high two must be
    // fetched through L1 from the adjacent line (including a dirty hit).
    core_req(mkreq(64'h11ba, 0, 8'hff, 0, MAINT_NONE, 0), r);
    check_ok(!r.fault && r.rdata == 64'h8180_dfde_dddc_dbda,
             "cross-line read miss assembles bytes from both lines");
    core_req(mkreq(64'h11c0, 1, 8'hff, 64'h8877_6655_4433_2211,
                    MAINT_NONE, 0), r);
    check_ok(!r.fault, "dirty adjacent line for cross-line read");
    core_req(mkreq(64'h11ba, 0, 8'hff, 0, MAINT_NONE, 0), r);
    check_ok(!r.fault && r.rdata == 64'h2211_dfde_dddc_dbda,
             "cross-line read hit observes dirty adjacent L1 bytes");

    // A conflicting dirty victim in the adjacent-line set must be written
    // back before the cross-line read refills the second line.
    core_req(mkreq(64'h12c0, 0, 8'hff, 0, MAINT_NONE, 0), r);
    check_ok(!r.fault, "fill same-set line to evict dirty adjacent line");
    core_req(mkreq(64'h12c0, 1, 8'hff, 64'h0f0e_0d0c_0b0a_0908,
                    MAINT_NONE, 0), r);
    check_ok(!r.fault, "dirty adjacent-set victim");
    core_req(mkreq(64'h11ba, 0, 8'hff, 0, MAINT_NONE, 0), r);
    check_ok(!r.fault && r.rdata == 64'h2211_dfde_dddc_dbda,
             "cross-line refill writes back dirty second-line victim");
    check_mem_byte(64'h12c0, 8'h08);

    // A fault on the second line is reported for the original read while the
    // already-resident first line remains intact.
    core_req(mkreq(64'h12c0, 0, 8'hff, 0, MAINT_NONE, 0), r);
    check_ok(!r.fault, "prepare adjacent-line read-fault replacement");
    fault_enable = 1; fault_addr = 64'h11c0; fault_we_only = 0;
    core_req(mkreq(64'h11ba, 0, 8'hff, 0, MAINT_NONE, 0), r);
    check_ok(r.fault, "cross-line second-line refill fault reaches core");
    check_meta(64'h1180, 1, 0);
    check_meta(64'h12c0, 1, 0);
    fault_enable = 0;

    // 8. A split store updates both lines; a following cross-line load sees
    // both halves on hit, including the byte lanes that straddle the line.
    core_req(mkreq(64'h11fa, 1, 8'hff, 64'h8877_6655_4433_2211,
                    MAINT_NONE, 0), r);
    check_ok(!r.fault, "cross-line store miss writes both lines");
    core_req(mkreq(64'h11fa, 0, 8'hff, 0, MAINT_NONE, 0), r);
    check_ok(!r.fault && r.rdata == 64'h8877_6655_4433_2211,
             "cross-line store data is visible to L1 hit");
    core_req(mkreq(64'h11fa, 1, 8'hff, 64'h1020_3040_5060_7080,
                    MAINT_NONE, 0), r);
    check_ok(!r.fault, "cross-line store hit rewrites both lines");
    core_req(mkreq(64'h11fa, 0, 8'hff, 0, MAINT_NONE, 0), r);
    check_ok(!r.fault && r.rdata == 64'h1020_3040_5060_7080,
             "cross-line store hit preserves byte order");

    check_ok(accepted_count == response_count, "BFM no lost responses");
    check_ok(write_count >= 16 && read_count >= 32, "WB/refill traffic seen");
    if (errors == 0) begin
      $display("PASS: lcvex_l1_d_wb_tb operations=%0d accepted=%0d",
               operations, accepted_count);
      $finish;
    end else $fatal(1, "FAIL: %0d errors", errors);
  end

endmodule
