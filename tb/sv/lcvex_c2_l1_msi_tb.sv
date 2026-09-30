// lcvex_c2_l1_msi_tb.sv
// Fast integration test for the C2 per-core coherent L1 wrappers plus the
// shared-L2 MSI cluster.  This is not a full-core run; it exercises the new
// system-level RTL boundary without the heavy lcvex_core elaboration.

`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off SYNCASYNCNET */

module lcvex_c2_l1_msi_tb;
  import lcvex_pkg::*;
  import lcvex_cluster_pkg::*;

  localparam int CORE_COUNT = 2;
  localparam int LINE_BYTES = 64;
  localparam int MEM_LINES = 256;
  localparam int MEM_DEPTH = MEM_LINES * LINE_BYTES;
  localparam logic [63:0] BASE = '0;

  logic clk = 1'b0;
  logic rst_n = 1'b0;

  // Cluster per-core ports.
  logic [CORE_COUNT-1:0] cl_req_valid;
  logic [CORE_COUNT-1:0] cl_req_ready;
  lcvex_coh_req_t cl_req [CORE_COUNT];
  logic [CORE_COUNT-1:0] cl_rsp_valid;
  logic [CORE_COUNT-1:0] cl_rsp_ready;
  lcvex_coh_rsp_t cl_rsp [CORE_COUNT];
  logic [CORE_COUNT-1:0] probe_req_valid;
  logic [CORE_COUNT-1:0] probe_req_ready;
  logic [63:0] probe_req_addr [CORE_COUNT];
  logic [1:0] probe_req_cmd [CORE_COUNT];
  logic [3:0] probe_req_source_id [CORE_COUNT];
  logic [7:0] probe_req_transaction_id [CORE_COUNT];
  logic [CORE_COUNT-1:0] probe_rsp_valid;
  logic [CORE_COUNT-1:0] probe_rsp_ready;
  logic [CORE_COUNT-1:0] probe_rsp_fault;
  logic [CORE_COUNT-1:0] probe_rsp_line_valid;
  logic [CORE_COUNT-1:0] probe_rsp_dirty;
  logic [LINE_BYTES*8-1:0] probe_rsp_data [CORE_COUNT];
  logic [63:0] probe_rsp_addr [CORE_COUNT];
  logic [3:0] probe_rsp_source_id [CORE_COUNT];
  logic [7:0] probe_rsp_transaction_id [CORE_COUNT];
  logic [CORE_COUNT-1:0] probe_rsp_abort;
  logic [3:0] req_source_tie [CORE_COUNT];
  logic [7:0] req_transaction_tie [CORE_COUNT];

  // L1 upstream ports.
  logic [CORE_COUNT-1:0] u_req_valid;
  mem_req_t u_req [CORE_COUNT];
  logic [CORE_COUNT-1:0] u_req_ready;
  logic [CORE_COUNT-1:0] u_rsp_valid;
  mem_rsp_t u_rsp [CORE_COUNT];
  logic [CORE_COUNT-1:0] u_rsp_ready;

  // PoC.
  logic poc_req_valid;
  mem_req_t poc_req;
  logic poc_req_ready;
  logic poc_rsp_valid;
  mem_rsp_t poc_rsp;
  logic poc_rsp_ready;
  logic [7:0] mem [0:MEM_DEPTH-1];
  mem_req_t poc_latch;
  logic poc_latch_valid;

  integer errors = 0;

  lcvex_l2_cluster #(
      .CORE_COUNT(CORE_COUNT), .CORE_ID_W(4), .SOURCE_ID_W(4),
      .TRANSACTION_ID_W(8), .LINE_BYTES(LINE_BYTES),
      .MEM_BASE(BASE), .MEM_LINES(MEM_LINES)
  ) cluster (
      .clk(clk), .rst_n(rst_n),
      .req_valid(cl_req_valid), .req_ready(cl_req_ready),
      .req(cl_req),
      .req_source_id(req_source_tie), .req_transaction_id(req_transaction_tie),
      .rsp_valid(cl_rsp_valid), .rsp_ready(cl_rsp_ready),
      .rsp(cl_rsp), .rsp_source_id(), .rsp_transaction_id(),
      .probe_req_valid(probe_req_valid),
      .probe_req_ready(probe_req_ready),
      .probe_req_addr(probe_req_addr),
      .probe_req_cmd(probe_req_cmd),
      .probe_req_source_id(probe_req_source_id),
      .probe_req_transaction_id(probe_req_transaction_id),
      .probe_rsp_valid(probe_rsp_valid),
      .probe_rsp_ready(probe_rsp_ready),
      .probe_rsp_fault(probe_rsp_fault),
      .probe_rsp_line_valid(probe_rsp_line_valid),
      .probe_rsp_dirty(probe_rsp_dirty),
      .probe_rsp_data(probe_rsp_data),
      .probe_rsp_addr(probe_rsp_addr),
      .probe_rsp_source_id(probe_rsp_source_id),
      .probe_rsp_transaction_id(probe_rsp_transaction_id),
      .probe_rsp_abort(probe_rsp_abort),
      .poc_req_valid(poc_req_valid), .poc_req(poc_req),
      .poc_req_ready(poc_req_ready), .poc_rsp_valid(poc_rsp_valid),
      .poc_rsp(poc_rsp), .poc_rsp_ready(poc_rsp_ready),
      .dir_valid_dbg(), .dir_state_dbg(), .dir_sharers_dbg(),
      .dir_owner_dbg(), .dir_dirty_dbg(), .dir_pending_dbg(),
      .dbg_cur_core(), .dbg_cur_state()
  );

  for (genvar i = 0; i < CORE_COUNT; i++) begin : g_l1
    lcvex_c2_l1_coherent #(
        .LINE_BYTES(LINE_BYTES), .SETS(64), .CORE_ID_W(4),
        .SOURCE_ID_W(4), .TRANSACTION_ID_W(8)
    ) l1 (
        .clk(clk), .rst_n(rst_n),
        .u_req_valid(u_req_valid[i]), .u_req(u_req[i]),
        .u_req_ready(u_req_ready[i]),
        .u_rsp_valid(u_rsp_valid[i]), .u_rsp(u_rsp[i]),
        .u_rsp_ready(u_rsp_ready[i]),
        .cl_req_valid(cl_req_valid[i]), .cl_req_ready(cl_req_ready[i]),
        .cl_req(cl_req[i]), .cl_rsp_valid(cl_rsp_valid[i]),
        .cl_rsp_ready(cl_rsp_ready[i]), .cl_rsp(cl_rsp[i]),
        .probe_req_valid(probe_req_valid[i]),
        .probe_req_ready(probe_req_ready[i]),
        .probe_req_addr(probe_req_addr[i]),
        .probe_req_cmd(probe_req_cmd[i]),
        .probe_req_source_id(probe_req_source_id[i]),
        .probe_req_transaction_id(probe_req_transaction_id[i]),
        .probe_rsp_valid(probe_rsp_valid[i]),
        .probe_rsp_ready(probe_rsp_ready[i]),
        .probe_rsp_fault(probe_rsp_fault[i]),
        .probe_rsp_line_valid(probe_rsp_line_valid[i]),
        .probe_rsp_dirty(probe_rsp_dirty[i]),
        .probe_rsp_data(probe_rsp_data[i]),
        .probe_rsp_addr(probe_rsp_addr[i]),
        .probe_rsp_source_id(probe_rsp_source_id[i]),
        .probe_rsp_transaction_id(probe_rsp_transaction_id[i]),
        .probe_rsp_abort(probe_rsp_abort[i])
    );
  end

  assign poc_req_ready = 1'b1;

  always_comb begin
    for (int ti = 0; ti < CORE_COUNT; ti++) begin
      req_source_tie[ti] = 4'd0;
      req_transaction_tie[ti] = 8'd0;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      poc_rsp_valid <= 1'b0;
      poc_latch_valid <= 1'b0;
    end else begin
      if (poc_req_valid && poc_req_ready) begin
        poc_latch <= poc_req;
        poc_latch_valid <= 1'b1;
        if (poc_req.we) begin
          for (int i = 0; i < 8; i++)
            if (poc_req.strb[i]) mem[poc_req.addr + i] <= poc_req.wdata[i*8 +: 8];
        end
        poc_rsp_valid <= 1'b1;
      end else if (poc_rsp_valid && poc_rsp_ready) begin
        poc_rsp_valid <= 1'b0;
        poc_latch_valid <= 1'b0;
      end
    end
  end

  always_comb begin
    poc_rsp = '0;
    if (poc_latch_valid && !poc_latch.we) begin
      for (int i = 0; i < 8; i++)
        poc_rsp.rdata[i*8 +: 8] = mem[poc_latch.addr + i];
    end
  end

  task automatic check(input logic cond, input string msg);
    begin
      if (!cond) begin $display("FAIL: %s", msg); errors = errors + 1; end
      else $display("PASS: %s", msg);
    end
  endtask

  task automatic reset_dut();
    begin
      rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1; repeat (2) @(posedge clk);
    end
  endtask

  task automatic access(input int c, input logic [63:0] addr, input logic we,
                        input logic [7:0] strb, input logic [63:0] wdata,
                        output mem_rsp_t r);
    begin
      @(negedge clk);
      u_req[c].addr = addr; u_req[c].we = we; u_req[c].strb = strb;
      u_req[c].wdata = wdata; u_req[c].maint = MAINT_NONE; u_req[c].bypass = 0;
      u_req_valid[c] = 1'b1;
      @(posedge clk); #1;
      u_req_valid[c] = 1'b0;
      begin
        int w;
        for (w = 0; w < 2000; w++) begin
          @(negedge clk);
          if (u_rsp_valid[c]) break;
        end
        if (!u_rsp_valid[c]) begin
          $display("TIMEOUT c=%0d addr=%h state0=%0d state1=%0d clstate=%0d",
                   c, addr, g_l1[0].l1.state, g_l1[1].l1.state, cluster.state);
          $display("TIMEOUT c=%0d dirpend=%b clprobe=%b u_rspv=%b cl_reqv=%b cl_reqrdy=%b cl_rspv=%b cl_rspry=%b arb=%0d arbv=%b rr=%0d reqrdy01=%b%b",
                   c, cluster.dir_pending[24], cluster.probe_active,
                   u_rsp_valid[c], cl_req_valid[c], cl_req_ready[c],
                   cl_rsp_valid[c], cl_rsp_ready[c],
                   cluster.arb_sel, cluster.arb_sel_valid, cluster.rr_ptr,
                   cluster.req_ready[0], cluster.req_ready[1], cluster.req_valid[0], cluster.req_valid[1]);
        end
      end
      r = u_rsp[c];
      u_rsp_ready[c] = 1'b1;
      @(posedge clk); #1;
      u_rsp_ready[c] = 1'b0;
    end
  endtask

  task automatic access_bypass(input int c, input logic [63:0] addr,
                               input logic [63:0] wdata, output mem_rsp_t r);
    begin
      @(negedge clk);
      u_req[c].addr = addr; u_req[c].we = 1'b1; u_req[c].strb = 8'hff;
      u_req[c].wdata = wdata; u_req[c].maint = MAINT_NONE; u_req[c].bypass = 1'b1;
      u_req_valid[c] = 1'b1;
      @(posedge clk); #1;
      u_req_valid[c] = 1'b0;
      begin
        int w;
        for (w = 0; w < 2000; w++) begin
          @(negedge clk);
          if (u_rsp_valid[c]) break;
        end
        if (!u_rsp_valid[c]) begin
          $display("TIMEOUT c=%0d addr=%h state0=%0d state1=%0d clstate=%0d",
                   c, addr, g_l1[0].l1.state, g_l1[1].l1.state, cluster.state);
          $display("TIMEOUT c=%0d dirpend=%b clprobe=%b u_rspv=%b cl_reqv=%b cl_reqrdy=%b cl_rspv=%b cl_rspry=%b arb=%0d arbv=%b rr=%0d reqrdy01=%b%b",
                   c, cluster.dir_pending[24], cluster.probe_active,
                   u_rsp_valid[c], cl_req_valid[c], cl_req_ready[c],
                   cl_rsp_valid[c], cl_rsp_ready[c],
                   cluster.arb_sel, cluster.arb_sel_valid, cluster.rr_ptr,
                   cluster.req_ready[0], cluster.req_ready[1], cluster.req_valid[0], cluster.req_valid[1]);
        end
      end
      r = u_rsp[c];
      u_rsp_ready[c] = 1'b1;
      @(posedge clk); #1;
      u_rsp_ready[c] = 1'b0;
    end
  endtask

  initial begin
    mem_rsp_t r;
    integer i;
    for (i = 0; i < MEM_DEPTH; i++) mem[i] = 8'hA0 + (i & 8'h0f);
    reset_dut();

    // Core0 write miss -> RWIT -> M.
    access(0, 64'h100, 1, 8'hff, 64'h0102030405060708, r);
    check(!r.fault, "L1 core0 write miss no fault");

    // Direct dirty eviction: access another line in the same set, then verify
    // the dirty data survives writeback+refill before any other core sees it.
    access(0, 64'h1100, 0, 8'h00, '0, r);
    check(!r.fault, "L1 core0 dirty eviction access no fault");
    access(0, 64'h100, 0, 8'h00, '0, r);
    check(!r.fault && r.rdata == 64'h0102030405060708,
          "L1 core0 dirty data survives direct eviction");

    // Same-line second write must preserve the first bytes.
    access(0, 64'h108, 1, 8'hff, 64'h1111111122222222, r);
    check(!r.fault, "L1 core0 same-line second write no fault");

    // Core1 read of the same line -> cluster gets dirty owner data.
    access(1, 64'h100, 0, 8'h00, '0, r);
    check(!r.fault, "L1 core1 read no fault");
    check(r.rdata == 64'h0102030405060708, "L1 core1 sees core0 dirty data");

    // Core0 read after invalidation must refill from PoC.
    access(0, 64'h100, 0, 8'h00, '0, r);
    check(!r.fault && r.rdata == 64'h0102030405060708, "L1 core0 refills after invalidation");

    // Bypass write.
    access_bypass(1, 64'h200, 64'h1111111122222222, r);
    check(!r.fault, "L1 bypass write no fault");
    check(mem[512] == 8'h22 && mem[519] == 8'h11, "bypass write reaches PoC through L1");

    // 32-bit store must be preserved across the cluster/probe path.
    access(0, 64'h300, 1, 8'h0f, 64'h01020304, r);
    check(!r.fault, "L1 core0 32-bit write no fault");
    access(1, 64'h300, 0, 8'h00, '0, r);
    check(!r.fault && r.rdata[31:0] == 32'h01020304,
          "L1 core1 sees core0 32-bit store");

    // Force a dirty-line eviction on core0 (same set as 0x100, different tag)
    // and verify the dirty data survives through writeback+refill.
    access(0, 64'h1100, 0, 8'h00, '0, r);
    check(!r.fault, "L1 core0 evicting access no fault");
    access(0, 64'h100, 0, 8'h00, '0, r);
    check(!r.fault && r.rdata == 64'h0102030405060708,
          "L1 core0 dirty data survives eviction/refill");

    // S -> M -> ReadShared: core0 has S, core1 takes M with a write, then
    // core0 reads the line.  The dirty data must be written to PoC by the
    // probe path before core0 receives the line.
    access(0, 64'h400, 0, 8'h00, '0, r);
    check(!r.fault, "core0 initial ReadShared for S->M test");
    access(1, 64'h400, 1, 8'hff, 64'h0102030405060708, r);
    check(!r.fault, "core1 ReadUnique write for S->M test");
    access(0, 64'h400, 0, 8'h00, '0, r);
    check(!r.fault && r.rdata == 64'h0102030405060708,
          "core0 sees core1 dirty data after S->M->ReadShared");
    check(mem[1024] == 8'h08 && mem[1031] == 8'h01,
          "PoC receives dirty owner after S->M->ReadShared");

    // Concurrent-like sequence: core1 reads the dirty line before core0 writes
    // another word in the same line; flag bytes must survive.
    access(0, 64'h1200, 1, 8'hff, 64'h0102030405060708, r); // core0 M
    access(1, 64'h1200, 0, 8'h00, '0, r); // core1 takes data, core0 invalidated
    check(!r.fault && r.rdata == 64'h0102030405060708, "core1 read concurrent owner data");
    access(0, 64'h1210, 1, 8'h0f, 64'h00000001, r); // core0 later writes same-line word
    access(0, 64'h1200, 0, 8'h00, '0, r);
    check(!r.fault && r.rdata == 64'h0102030405060708,
          "first word survives after owner invalidation and later same-line write");

    // S-hit write Upgrade must preserve earlier bytes in the line.
    access(0, 64'h500, 0, 8'h00, '0, r);
    access(0, 64'h510, 1, 8'h0f, 64'h00000002, r);
    access(0, 64'h500, 0, 8'h00, '0, r);
    check(!r.fault && r.rdata[31:0] == 32'hA3A2A1A0,
          "S->Upgrade write preserves first word");
    check(mem[1280] == 8'hA0 && mem[1281] == 8'hA1,
          "S->Upgrade write preserves PoC first word");

    // Exact atomic-like same-line sequence with multiple ownership transfers.
    $display("MIN: step1 read0");
    access(0, 64'h600, 0, 8'h00, '0, r);            // core0 S
    $display("MIN: step2 upgrade0");
    access(0, 64'h610, 1, 8'h0f, 64'h00000001, r); // core0 Upgrade flag=1
    $display("MIN: step3 read1");
    access(1, 64'h600, 0, 8'h00, '0, r);            // core1 read, core0 invalidated
    $display("MIN: step4 write1 cell");
    access(1, 64'h600, 1, 8'h0f, 64'h000000de, r); // core1 write cell
    $display("MIN: step5 write1 flag");
    access(1, 64'h610, 1, 8'h0f, 64'h00000002, r); // core1 write flag
    $display("MIN: step6 read0 flag");
    access(0, 64'h610, 0, 8'h00, '0, r);            // core0 read flag
    check(!r.fault && r.rdata[31:0] == 32'h00000002,
          "minimal atomic same-line flag visibility");
    access(0, 64'h600, 0, 8'h00, '0, r);
    check(!r.fault && r.rdata[31:0] == 32'h000000de,
          "minimal atomic same-line cell visibility");

    // Atomic-like same-line case: core1 writes cell=0xde at offset 0 and
    // flag=2 at offset 0x10, then core0 reads flag and cell.
    access(1, 64'h1000, 1, 8'h0f, 64'h000000de, r);
    access(1, 64'h1010, 1, 8'h0f, 64'h00000002, r);
    access(0, 64'h1010, 0, 8'h00, '0, r);
    check(!r.fault && r.rdata[31:0] == 32'h00000002,
          "core0 sees flag=2 from same-line owner");
    access(0, 64'h1000, 0, 8'h00, '0, r);
    check(!r.fault && r.rdata[31:0] == 32'h000000de,
          "core0 sees cell=0xde from same-line owner");
    check(mem[4096] == 8'hde && mem[4112] == 8'h02,
          "PoC receives cell+flag after same-line owner read");

    // Dual-core-like sequence: 0x1000 flag line is evicted, core1 reads it,
    // then core0 writes 0x1010 (same line, different word).  The flag bytes
    // must survive the owner-invalidate + later same-line write.
    access(0, 64'h1000, 1, 8'hff, 64'h0102030405060708, r);
    access(0, 64'h2000, 0, 8'h00, '0, r); // evict flag line (same set)
    access(1, 64'h1000, 0, 8'h00, '0, r); // core1 reads, core0 invalidated
    check(!r.fault && r.rdata == 64'h0102030405060708,
          "core1 reads evicted-then-dirty line");
    access(0, 64'h1010, 1, 8'h0f, 64'h00000001, r); // core0 writes sync word
    access(0, 64'h1000, 0, 8'h00, '0, r);
    check(!r.fault && r.rdata == 64'h0102030405060708,
          "L1 same-line second word write preserves first word after owner invalidation");

    if (errors == 0) $display("LCVEX_C2_L1_MSI_TB PASS");
    else $display("LCVEX_C2_L1_MSI_TB FAIL: %0d", errors);
    $finish;
  end

  always #5 clk = ~clk;

endmodule
