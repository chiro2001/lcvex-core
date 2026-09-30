// lcvex_c2_cluster_tb.sv
// C2 directed module-level TB for the shared-L2 directory MSI cluster.
//
// It uses two synthetic coherent L1 clients so the test can focus on the
// directory/probe protocol: I/S/M transitions, dirty owner data transfer,
// invalidations, fault/abort, reset, and basic message-passing observability.
// It is not a full-SoC or ARM-memory-model claim.

`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off SYNCASYNCNET */

module lcvex_c2_cluster_tb;
  import lcvex_pkg::*;
  import lcvex_cluster_pkg::*;

  localparam int CORE_COUNT = 2;
  localparam int LINE_BYTES = 64;
  localparam int MEM_LINES  = 256;
  localparam int MEM_DEPTH  = MEM_LINES * LINE_BYTES;
  localparam logic [63:0] MEM_BASE = 64'h0;

  logic clk;
  logic rst_n = 1'b0;

  logic [CORE_COUNT-1:0] req_valid = '0;
  logic [CORE_COUNT-1:0] req_ready;
  lcvex_coh_req_t req [CORE_COUNT];
  logic [3:0] req_source_id [CORE_COUNT];
  logic [7:0] req_transaction_id [CORE_COUNT];
  logic [CORE_COUNT-1:0] rsp_valid;
  logic [CORE_COUNT-1:0] rsp_ready = '0;
  lcvex_coh_rsp_t rsp [CORE_COUNT];
  logic [3:0] rsp_source_id [CORE_COUNT];
  logic [7:0] rsp_transaction_id [CORE_COUNT];

  logic [CORE_COUNT-1:0] probe_req_valid;
  logic [CORE_COUNT-1:0] probe_req_ready = '1;
  logic [63:0] probe_req_addr [CORE_COUNT];
  logic [1:0]  probe_req_cmd [CORE_COUNT];
  logic [3:0]  probe_req_source_id [CORE_COUNT];
  logic [7:0]  probe_req_transaction_id [CORE_COUNT];
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

  logic [MEM_LINES-1:0] dir_valid_dbg;
  logic [1:0] dir_state_dbg [MEM_LINES];
  logic [CORE_COUNT-1:0] dir_sharers_dbg [MEM_LINES];
  logic [CORE_COUNT-1:0] dir_owner_dbg [MEM_LINES];
  logic [MEM_LINES-1:0] dir_dirty_dbg;
  logic [MEM_LINES-1:0] dir_pending_dbg;
  logic [3:0] dbg_cur_core;
  logic [1:0] dbg_cur_state;

  lcvex_l2_cluster #(
      .CORE_COUNT(CORE_COUNT),
      .CORE_ID_W(4),
      .SOURCE_ID_W(4),
      .TRANSACTION_ID_W(8),
      .LINE_BYTES(LINE_BYTES),
      .MEM_BASE(MEM_BASE),
      .MEM_LINES(MEM_LINES)
  ) dut (
      .clk(clk), .rst_n(rst_n),
      .req_valid(req_valid), .req_ready(req_ready), .req(req),
      .req_source_id(req_source_id), .req_transaction_id(req_transaction_id),
      .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rsp(rsp),
      .rsp_source_id(rsp_source_id), .rsp_transaction_id(rsp_transaction_id),
      .probe_req_valid(probe_req_valid), .probe_req_ready(probe_req_ready),
      .probe_req_addr(probe_req_addr), .probe_req_cmd(probe_req_cmd),
      .probe_req_source_id(probe_req_source_id),
      .probe_req_transaction_id(probe_req_transaction_id),
      .probe_rsp_valid(probe_rsp_valid), .probe_rsp_ready(probe_rsp_ready),
      .probe_rsp_fault(probe_rsp_fault),
      .probe_rsp_line_valid(probe_rsp_line_valid),
      .probe_rsp_dirty(probe_rsp_dirty), .probe_rsp_data(probe_rsp_data),
      .probe_rsp_addr(probe_rsp_addr),
      .probe_rsp_source_id(probe_rsp_source_id),
      .probe_rsp_transaction_id(probe_rsp_transaction_id),
      .probe_rsp_abort(probe_rsp_abort),
      .poc_req_valid(poc_req_valid), .poc_req(poc_req),
      .poc_req_ready(poc_req_ready), .poc_rsp_valid(poc_rsp_valid),
      .poc_rsp(poc_rsp), .poc_rsp_ready(poc_rsp_ready),
      .dir_valid_dbg(dir_valid_dbg), .dir_state_dbg(dir_state_dbg),
      .dir_sharers_dbg(dir_sharers_dbg), .dir_owner_dbg(dir_owner_dbg),
      .dir_dirty_dbg(dir_dirty_dbg), .dir_pending_dbg(dir_pending_dbg),
      .dbg_cur_core(dbg_cur_core), .dbg_cur_state(dbg_cur_state)
  );

  // ------------------------------------------------------------------
  // Simple PoC BFM.
  // ------------------------------------------------------------------
  logic poc_req_valid;
  mem_req_t poc_req;
  logic poc_req_ready;
  assign poc_req_ready = 1'b1;
  logic poc_rsp_valid;
  mem_rsp_t poc_rsp;
  logic poc_rsp_ready;
  logic [7:0] mem [0:MEM_DEPTH-1];
  logic fault_write_en = 1'b0;
  logic [63:0] fault_write_addr = '0;
  mem_req_t poc_latch;
  logic poc_latch_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      poc_rsp_valid <= 1'b0;
      poc_latch_valid <= 1'b0;
      poc_latch <= '0;
    end else begin
      if (poc_req_valid && poc_req_ready) begin
        poc_latch <= poc_req;
        poc_latch_valid <= 1'b1;
        if (poc_req.we && !(fault_write_en && (poc_req.addr == fault_write_addr))) begin
          for (int i = 0; i < 8; i++) begin
            if (poc_req.strb[i]) mem[poc_req.addr + i] <= poc_req.wdata[i*8 +: 8];
          end
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
    if (poc_latch_valid) begin
      if (poc_latch.we && fault_write_en && (poc_latch.addr == fault_write_addr)) begin
        poc_rsp.fault = 1'b1;
      end else if (!poc_latch.we) begin
        for (int i = 0; i < 8; i++)
          poc_rsp.rdata[i*8 +: 8] = mem[poc_latch.addr + i];
      end
    end
  end

  // ------------------------------------------------------------------
  // Synthetic L1 clients.
  // ------------------------------------------------------------------
  logic [1:0] l1_state [CORE_COUNT]; // I/S/M
  logic [MEM_LINES-1:0] l1_valid [CORE_COUNT];
  logic [MEM_LINES-1:0] l1_dirty [CORE_COUNT];
  logic [7:0] l1_data [CORE_COUNT][MEM_LINES][LINE_BYTES];
  logic [1:0] probe_pending [CORE_COUNT];
  logic [63:0] probe_addr_r [CORE_COUNT];
  logic [1:0] probe_cmd_r [CORE_COUNT];

  task automatic copy_line_to_l1(input int c, input int idx,
                                 input logic [511:0] data);
    begin
      for (int i = 0; i < LINE_BYTES; i++)
        l1_data[c][idx][i] = data[i*8 +: 8];
    end
  endtask

  function automatic logic [511:0] l1_pack(input int c, input int idx);
    logic [511:0] v;
    begin
      v = '0;
      for (int i = 0; i < LINE_BYTES; i++) v[i*8 +: 8] = l1_data[c][idx][i];
      l1_pack = v;
    end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    integer i;
    integer idx;
    if (!rst_n) begin
      for (i = 0; i < CORE_COUNT; i++) begin
        l1_valid[i] <= '0;
        l1_dirty[i] <= '0;
        l1_state[i] <= COH_L1_I;
        probe_pending[i] <= 1'b0;
      end
    end else begin
      for (i = 0; i < CORE_COUNT; i++) begin
        if (probe_req_valid[i] && probe_req_ready[i] && !probe_pending[i]) begin
          probe_pending[i] <= 1'b1;
          probe_addr_r[i] <= probe_req_addr[i];
          probe_cmd_r[i] <= probe_req_cmd[i];
        end else if (probe_pending[i]) begin
          // Response is held until cluster releases ready.
          if (probe_rsp_ready[i] && probe_rsp_valid[i]) begin
            if (!probe_rsp_abort[i]) begin
              idx = probe_addr_r[i] >> 6;
              case (probe_cmd_r[i])
                COH_PROBE_CLEAN: l1_dirty[i][idx] <= 1'b0;
                COH_PROBE_INVALIDATE,
                COH_PROBE_CLEAN_INVALIDATE: begin
                  l1_valid[i][idx] <= 1'b0;
                  l1_dirty[i][idx] <= 1'b0;
                  l1_state[i] <= COH_L1_I;
                end
                default: begin end
              endcase
            end
            probe_pending[i] <= 1'b0;
          end
        end
      end
    end
  end

  // Drive probe responses combinationally from pending state.
  always_comb begin
    for (int i = 0; i < CORE_COUNT; i++) begin
      integer idx;
      idx = probe_addr_r[i] >> 6;
      probe_rsp_valid[i] = (probe_pending[i] && rst_n);
      probe_rsp_fault[i] = 1'b0;
      probe_rsp_line_valid[i] = (probe_pending[i] && l1_valid[i][idx]);
      probe_rsp_dirty[i] = (probe_pending[i] && l1_valid[i][idx] && l1_dirty[i][idx]);
      probe_rsp_data[i] = (probe_pending[i] && l1_valid[i][idx]) ? l1_pack(i, idx) : '0;
      probe_rsp_addr[i] = probe_addr_r[i];
      probe_rsp_source_id[i] = 4'(i);
      probe_rsp_transaction_id[i] = probe_req_transaction_id[i];
    end
  end

  // ------------------------------------------------------------------
  // Task helpers.
  // ------------------------------------------------------------------
  integer errors = 0;
  integer tid = 0;

  task automatic check(input logic cond, input string msg);
    begin
      if (!cond) begin
        $display("FAIL: %s", msg);
        errors = errors + 1;
      end else begin
        $display("PASS: %s", msg);
      end
    end
  endtask

  task automatic reset_dut();
    begin
      rst_n = 1'b0;
      repeat (4) @(posedge clk);
      rst_n = 1'b1;
      repeat (2) @(posedge clk);
    end
  endtask

  task automatic send_req(input int c, input lcvex_coh_cmd_t cmd,
                          input logic [63:0] addr,
                          input logic [511:0] data,
                          output lcvex_coh_rsp_t r);
    begin
      @(negedge clk);
      req[c].cmd = cmd;
      req[c].addr = addr;
      req[c].data = data;
      req_source_id[c] = 4'(c);
      req_transaction_id[c] = 8'(tid);
      tid = tid + 1;
      req_valid[c] = 1'b1;
      // The DUT is in IDLE and grants ready combinationally in this directed
      // test; wait one clock for the handshake, then release the request.
      @(posedge clk);
      #1;
      req_valid[c] = 1'b0;
      while (!rsp_valid[c]) @(negedge clk);
      r = rsp[c];
      rsp_ready[c] = 1'b1;
      @(posedge clk);
      #1;
      rsp_ready[c] = 1'b0;
      // Update the synthetic L1 after the response.
      if (!r.fault) begin
        case (cmd)
          COH_READ_SHARED: begin
            l1_state[c] = COH_L1_S;
            l1_valid[c][addr >> 6] = 1'b1;
            l1_dirty[c][addr >> 6] = 1'b0;
            copy_line_to_l1(c, addr >> 6, r.data);
          end
          COH_READ_UNIQUE: begin
            l1_state[c] = COH_L1_M;
            l1_valid[c][addr >> 6] = 1'b1;
            l1_dirty[c][addr >> 6] = 1'b1;
            if (r.data !== '0) copy_line_to_l1(c, addr >> 6, r.data);
          end
          COH_UPGRADE: begin
            l1_state[c] = COH_L1_M;
            l1_valid[c][addr >> 6] = 1'b1;
            l1_dirty[c][addr >> 6] = 1'b1;
          end
          default: begin end
        endcase
      end
    end
  endtask

  function automatic logic [511:0] make_line(input logic [7:0] base);
    logic [511:0] v;
    begin
      v = '0;
      for (int i = 0; i < LINE_BYTES; i++) v[i*8 +: 8] = base + i;
      make_line = v;
    end
  endfunction

  initial begin
    lcvex_coh_rsp_t r;
    logic [511:0] line;
    integer i;

    clk = 1'b0;
    // Initialize memory.
    for (i = 0; i < MEM_DEPTH; i++) mem[i] = 8'hA0 + (i & 8'h0f);

    reset_dut();

    // No stale response after reset.
    check(rsp_valid == 2'b00, "reset: no stale response");

    // ---- 1. ReadShared I->S ----
    send_req(0, COH_READ_SHARED, 64'h100, '0, r);
    check(!r.fault, "core0 ReadShared no fault");
    check((dir_state_dbg[4] == 2'd1) && (dir_sharers_dbg[4] == 2'b01),
          "ReadShared sets S{0}");
    check(l1_valid[0][4], "L1 core0 line valid after ReadShared");

    // ---- 2. ReadShared S->SS ----
    send_req(1, COH_READ_SHARED, 64'h100, '0, r);
    check(!r.fault, "core1 ReadShared no fault");
    check((dir_sharers_dbg[4] == 2'b11) && (dir_state_dbg[4] == 2'd1),
          "ReadShared adds sharer 1");

    // ---- 3. Upgrade invalidates other sharer ----
    send_req(0, COH_UPGRADE, 64'h100, '0, r);
    check(!r.fault, "core0 Upgrade no fault");
    check((dir_state_dbg[4] == 2'd2) && (dir_owner_dbg[4] == 2'b01) &&
          (dir_dirty_dbg[4] == 1'b1), "Upgrade creates M owner 0");
    check(!l1_valid[1][4], "core1 invalidated by Upgrade");

    // ---- 4. ReadUnique from other core collects dirty owner ----
    // Make core0's line dirty with an observable byte via synthetic L1.
    l1_data[0][4][0] = 8'h55;
    l1_data[0][4][1] = 8'h66;
    send_req(1, COH_READ_UNIQUE, 64'h100, '0, r);
    check(!r.fault, "core1 ReadUnique no fault");
    check((dir_state_dbg[4] == 2'd2) && (dir_owner_dbg[4] == 2'b10),
          "ReadUnique transfers M to core1");
    check((r.data[0*8 +: 8] == 8'h55) && (r.data[1*8 +: 8] == 8'h66),
          "ReadUnique returns dirty owner data");
    check(!l1_valid[0][4], "old core0 invalidated after ReadUnique");
    check(mem[4*64 + 0] == 8'h55 && mem[4*64 + 1] == 8'h66,
          "PoC receives dirty owner writeback");

    // ---- 5. Message-passing pattern: write data on one core, read on other ----
    // Core0 takes M on another line, modifies local line, then core1 reads it.
    send_req(0, COH_READ_UNIQUE, 64'h200, make_line(8'h10), r);
    check(!r.fault, "core0 ReadUnique line B");
    l1_data[0][8][0] = 8'hde;
    l1_data[0][8][1] = 8'had;
    send_req(1, COH_READ_SHARED, 64'h200, '0, r);
    check(!r.fault, "core1 ReadShared line B after dirty owner");
    check((r.data[0*8 +: 8] == 8'hde) && (r.data[1*8 +: 8] == 8'had),
          "message passing: core1 sees core0 dirty data");
    check((dir_state_dbg[8] == 2'd1) && (dir_sharers_dbg[8] == 2'b10),
          "after ReadShared: S{1}");
    check(!l1_valid[0][8], "dirty owner invalidated after data transfer");

    // ---- 5b. WriteBack / Clean maintenance sequences ----
    // WriteBack from an M owner must clear the directory and put data at PoC.
    send_req(0, COH_READ_UNIQUE, 64'h280, make_line(8'h20), r);
    check(!r.fault, "core0 ReadUnique for WriteBack line");
    l1_data[0][10][0] = 8'h11;
    l1_data[0][10][1] = 8'h22;
    send_req(0, COH_WRITEBACK, 64'h280, l1_pack(0, 10), r);
    check(!r.fault, "WriteBack ack");
    check(mem[10*64 + 0] == 8'h11 && mem[10*64 + 1] == 8'h22,
          "WriteBack updates PoC");
    check(dir_valid_dbg[10] == 1'b0, "WriteBack clears directory entry");

    // Clean from an M owner leaves the owner as a clean S sharer.
    send_req(0, COH_READ_UNIQUE, 64'h2c0, make_line(8'h60), r);
    check(!r.fault, "core0 ReadUnique for Clean line");
    l1_data[0][11][0] = 8'h33;
    send_req(0, COH_CLEAN, 64'h2c0, l1_pack(0, 11), r);
    check(!r.fault, "Clean ack");
    check((dir_state_dbg[11] == 2'd1) && (dir_sharers_dbg[11] == 2'b01),
          "Clean leaves S{owner}");
    // A subsequent ReadUnique by the other core invalidates the clean sharer
    // before taking M; this is the directory serialization point used by
    // exclusive/barrier litmus tests at this level.
    send_req(1, COH_READ_UNIQUE, 64'h2c0, '0, r);
    check(!r.fault, "ReadUnique after Clean");
    check((dir_state_dbg[11] == 2'd2) && (dir_owner_dbg[11] == 2'b10),
          "ReadUnique transfers M after invalidating sharer");
    check(!l1_valid[0][11], "old S sharer invalidated before M transfer");

    // ---- 6. Bypass (uncached) path ----
    send_req(0, COH_BYPASS_READ, 64'h300, '0, r);
    check(!r.fault, "bypass read no fault");
    send_req(1, COH_BYPASS_WRITE, 64'h308, make_line(8'h30), r);
    check(!r.fault, "bypass write no fault");
    check(mem[776] == 8'h38, "bypass write reaches PoC");

    // ---- 7. Fault on dirty owner writeback ----
    // Core0 gets M on line C, core1 ReadUnique will try to invalidate it and
    // write the dirty line; inject a PoC write fault so the probe must abort
    // and no new M owner may appear.
    send_req(0, COH_READ_UNIQUE, 64'h400, make_line(8'h40), r);
    check(!r.fault, "core0 ReadUnique line C");
    l1_data[0][16][0] = 8'h99;
    fault_write_en = 1'b1;
    fault_write_addr = 64'h400;   // first beat of line C PoC write
    send_req(1, COH_READ_UNIQUE, 64'h400, '0, r);
    check(r.fault, "ReadUnique returns fault on PoC writeback fault");
    // Conservative: no new M owner for core1; old owner may remain stale in
    // directory, but never a second M.
    check(!(dir_state_dbg[16] == 2'd2 && dir_owner_dbg[16] == 2'b10),
          "fault does not create M owner 1");
    fault_write_en = 1'b0;

    // ---- 8. Reset clears directory and produces no stale response ----
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);
    check(rsp_valid == 2'b00, "reset after fault: no stale response");
    check(dir_valid_dbg == '0, "reset clears directory");

    if (errors == 0) begin
      $display("LCVEX_C2_CLUSTER_TB PASS");
    end else begin
      $display("LCVEX_C2_CLUSTER_TB FAIL: %0d error(s)", errors);
    end
    $finish;
  end

  always #5 clk = ~clk;

endmodule
