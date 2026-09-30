// lcvex_c3_cluster4_tb.sv
// C3 module-level directed TB for the generic four-core shared-L2 MSI
// directory.  Uses four synthetic L1 clients so no full lcvex_core is needed.
// This verifies the CORE_COUNT=4 parameterization and multi-sharer
// invalidation path without requiring the heavier full-SoC build.

`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off SYNCASYNCNET */

module lcvex_c3_cluster4_multi_tb;
  import lcvex_pkg::*;
  import lcvex_cluster_pkg::*;

  localparam int CORE_COUNT = 4;
  localparam int LINE_BYTES = 64;
  localparam int MEM_LINES  = 256;
  localparam int MEM_DEPTH  = MEM_LINES * LINE_BYTES;
  localparam logic [63:0] MEM_BASE = 64'h0;

  logic clk = 1'b0;
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

  logic poc_req_valid;
  mem_req_t poc_req;
  logic poc_req_ready = 1'b1;
  logic poc_rsp_valid;
  mem_rsp_t poc_rsp;
  logic poc_rsp_ready;
  logic [7:0] mem [0:MEM_DEPTH-1];
  mem_req_t poc_latch;
  logic poc_latch_valid;

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

  // Tiny PoC BFM.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      poc_rsp_valid <= 1'b0;
      poc_latch_valid <= 1'b0;
      poc_latch <= '0;
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
    if (poc_latch_valid) begin
      if (!poc_latch.we) begin
        for (int i = 0; i < 8; i++)
          poc_rsp.rdata[i*8 +: 8] = mem[poc_latch.addr + i];
      end
    end
  end

  // Synthetic L1 clients.
  logic [1:0] l1_state [CORE_COUNT];
  logic [MEM_LINES-1:0] l1_valid [CORE_COUNT];
  logic [MEM_LINES-1:0] l1_dirty [CORE_COUNT];
  logic [7:0] l1_data [CORE_COUNT][MEM_LINES][LINE_BYTES];
  logic [1:0] probe_pending [CORE_COUNT];
  logic [63:0] probe_addr_r [CORE_COUNT];
  logic [1:0] probe_cmd_r [CORE_COUNT];

  task automatic copy_line_to_l1(input int c, input int idx, input logic [511:0] data);
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
    if (!rst_n) begin
      for (int i = 0; i < CORE_COUNT; i++) begin
        l1_valid[i] <= '0;
        l1_dirty[i] <= '0;
        l1_state[i] <= COH_L1_I;
        probe_pending[i] <= 1'b0;
      end
    end else begin
      for (int i = 0; i < CORE_COUNT; i++) begin
        if (probe_req_valid[i] && probe_req_ready[i] && !probe_pending[i]) begin
          $display("L1%0d probe accepted cmd=%0d", i, probe_req_cmd[i]);
          probe_pending[i] <= 1'b1;
          probe_addr_r[i] <= probe_req_addr[i];
          probe_cmd_r[i] <= probe_req_cmd[i];
        end else if (probe_pending[i]) begin
          if (probe_rsp_ready[i] && probe_rsp_valid[i]) begin
            $display("L1%0d probe response ready cmd=%0d", i, probe_cmd_r[i]);
            if (!probe_rsp_abort[i]) begin
              $display("L1%0d clear addr=%h calc=%0d", i, probe_addr_r[i], int'(probe_addr_r[i] / 64));
              case (probe_cmd_r[i])
                COH_PROBE_CLEAN: l1_dirty[i][int'(probe_addr_r[i] / 64)] <= 1'b0;
                COH_PROBE_INVALIDATE,
                COH_PROBE_CLEAN_INVALIDATE: begin
                  l1_valid[i][int'(probe_addr_r[i] / 64)] <= 1'b0;
                  l1_dirty[i][int'(probe_addr_r[i] / 64)] <= 1'b0;
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

  always_comb begin
    for (int i = 0; i < CORE_COUNT; i++) begin
      probe_rsp_valid[i] = probe_pending[i] && rst_n;
      probe_rsp_fault[i] = 1'b0;
      probe_rsp_line_valid[i] = probe_pending[i] && l1_valid[i][int'(probe_addr_r[i] / 64)];
      probe_rsp_dirty[i] = probe_pending[i] && l1_valid[i][int'(probe_addr_r[i] / 64)] && l1_dirty[i][int'(probe_addr_r[i] / 64)];
      probe_rsp_data[i] = (probe_pending[i] && l1_valid[i][int'(probe_addr_r[i] / 64)]) ? l1_pack(i, int'(probe_addr_r[i] / 64)) : '0;
      probe_rsp_addr[i] = probe_addr_r[i];
      probe_rsp_source_id[i] = 4'(i);
      probe_rsp_transaction_id[i] = probe_req_transaction_id[i];
    end
  end

  always #5 clk = ~clk;

  integer errors = 0;
  integer tid = 0;
  integer cyc = 0;
  integer probe_count = 0;
  always_ff @(posedge clk) begin
    cyc <= cyc + 1;
    for (int i = 0; i < CORE_COUNT; i++) begin
      if (probe_req_valid[i] && probe_req_ready[i]) begin
        probe_count = probe_count + 1;
        $display("PROBE to core %0d", i);
      end
    end
    if (cyc > 500000) begin
      $display("TIMEOUT: LCVEX_C3_CLUSTER4_TB did not complete");
      $finish;
    end
  end
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
      @(posedge clk);
      #1;
      req_valid[c] = 1'b0;
      while (!rsp_valid[c]) @(negedge clk);
      r = rsp[c];
      rsp_ready[c] = 1'b1;
      @(posedge clk);
      #1;
      rsp_ready[c] = 1'b0;
      if (!r.fault) begin
        case (cmd)
          COH_READ_SHARED: begin
            l1_state[c] = COH_L1_S;
            l1_valid[c][int'(addr / 64)] = 1'b1;
            l1_dirty[c][int'(addr / 64)] = 1'b0;
            copy_line_to_l1(c, int'(addr / 64), r.data);
          end
          COH_READ_UNIQUE: begin
            l1_state[c] = COH_L1_M;
            l1_valid[c][int'(addr / 64)] = 1'b1;
            l1_dirty[c][int'(addr / 64)] = 1'b1;
            if (r.data !== '0) copy_line_to_l1(c, int'(addr / 64), r.data);
          end
          COH_UPGRADE: begin
            l1_state[c] = COH_L1_M;
            l1_valid[c][int'(addr / 64)] = 1'b1;
            l1_dirty[c][int'(addr / 64)] = 1'b1;
          end
          default: begin end
        endcase
      end
    end
  endtask

  initial begin
    lcvex_coh_rsp_t r;
    logic [511:0] line;
    $display("LCVEX_C3_CLUSTER4_MULTI_TB start");
    // Initialize PoC memory.
    for (int i = 0; i < MEM_DEPTH; i++) mem[i] = 8'hA0 + (i & 8'h0f);
    reset_dut();

    check(rsp_valid == 4'b0000, "reset: no stale response");

    // Four-core ReadShared: I->S, then S->SSSS.
    send_req(0, COH_READ_SHARED, 64'h100, '0, r);
    check(dir_state_dbg[4] == 2'd1 && dir_sharers_dbg[4] == 4'b0001,
          "core0 ReadShared creates S{0}");
    send_req(1, COH_READ_SHARED, 64'h100, '0, r);
    send_req(2, COH_READ_SHARED, 64'h100, '0, r);
    send_req(3, COH_READ_SHARED, 64'h100, '0, r);
    check(dir_state_dbg[4] == 2'd1 && dir_sharers_dbg[4] == 4'b1111,
          "four cores all become sharers");

    // Multi-sharer Upgrade: core0 invalidates cores 1,2,3 one by one.
    send_req(0, COH_UPGRADE, 64'h100, '0, r);
    check(dir_state_dbg[4] == 2'd2 && dir_owner_dbg[4] == 4'b0001 &&
          dir_dirty_dbg[4] == 1'b1,
          "Upgrade creates M owner 0 after multi-sharer invalidation");
    $display("AFTER UPGRADE l1_valid = %b,%b,%b probe_count=%0d", l1_valid[1][4], l1_valid[2][4], l1_valid[3][4], probe_count);
    check(l1_valid[1][4] == 1'b0 && l1_valid[2][4] == 1'b0 && l1_valid[3][4] == 1'b0,
          "all three other sharers invalidated");

    // Multi-sharer ReadUnique on a second line: core3 invalidates cores 0,1,2.
    send_req(0, COH_READ_SHARED, 64'h200, '0, r);
    send_req(1, COH_READ_SHARED, 64'h200, '0, r);
    send_req(2, COH_READ_SHARED, 64'h200, '0, r);
    send_req(3, COH_READ_SHARED, 64'h200, '0, r);
    check(dir_state_dbg[8] == 2'd1 && dir_sharers_dbg[8] == 4'b1111,
          "second line: four sharers before ReadUnique");
    send_req(3, COH_READ_UNIQUE, 64'h200, '0, r);
    check(dir_state_dbg[8] == 2'd2 && dir_owner_dbg[8] == 4'b1000,
          "ReadUnique transfers M to core3 after multi-sharer invalidation");
    check(l1_valid[0][8] == 1'b0 && l1_valid[1][8] == 1'b0 && l1_valid[2][8] == 1'b0,
          "all three old sharers invalidated by ReadUnique");

    if (errors == 0) $display("LCVEX_C3_CLUSTER4_MULTI_TB PASS");
    else $display("LCVEX_C3_CLUSTER4_MULTI_TB FAIL: %0d", errors);
    $finish;
  end

endmodule
