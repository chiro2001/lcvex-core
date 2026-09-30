// lcvex_l2_wb_tb.sv
// B3 独立 SV L1：不连接现有 lcvex_l2_tb，使用本文件自己的 model_mem、
// 事务 scoreboard、probe client 和 fault/backpressure BFM。

`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off SYNCASYNCNET */

module lcvex_l2_wb_tb;
  import lcvex_pkg::*;

  localparam int LINE_BYTES = 64;
  localparam int SETS = 4;
  localparam int WAYS = 2;
  localparam int DEPTH = 1 << 16;
  localparam int TAG_W = 64 - 6 - $clog2(SETS);
  localparam int SOURCE_ID_W = 4;
  localparam int TRANSACTION_ID_W = 8;

  localparam logic [63:0] ADDR_A  = 64'h0000_0100;
  localparam logic [63:0] ADDR_X  = 64'h0000_0200;
  localparam logic [63:0] ADDR_C  = 64'h0000_0300;
  localparam logic [63:0] ADDR_D  = 64'h0000_0140;
  localparam logic [63:0] ADDR_Y  = 64'h0000_0280;
  localparam logic [63:0] ADDR_Z  = 64'h0000_0380;
  localparam logic [63:0] ADDR_V  = 64'h0000_0480;
  localparam logic [63:0] ADDR_RF = 64'h0000_01c0;

  logic clk;
  logic rst_n;
  logic u_req_valid;
  mem_req_t u_req;
  logic u_req_ready;
  logic u_rsp_valid;
  mem_rsp_t u_rsp;
  logic u_rsp_ready;
  logic [SOURCE_ID_W-1:0] u_source_id;
  logic [TRANSACTION_ID_W-1:0] u_transaction_id;
  logic [SOURCE_ID_W-1:0] u_rsp_source_id;
  logic [TRANSACTION_ID_W-1:0] u_rsp_transaction_id;

  logic d_req_valid;
  mem_req_t d_req;
  logic d_req_ready;
  logic d_rsp_valid;
  mem_rsp_t d_rsp;
  logic d_rsp_ready;

  logic p_req_valid;
  logic p_req_ready;
  logic [63:0] p_req_addr;
  logic [1:0] p_req_cmd;
  logic [SOURCE_ID_W-1:0] p_req_source_id;
  logic [TRANSACTION_ID_W-1:0] p_req_transaction_id;
  logic p_rsp_valid;
  logic p_rsp_ready;
  logic p_rsp_fault;
  logic p_rsp_hit;
  logic p_rsp_dirty;
  logic [LINE_BYTES*8-1:0] p_rsp_data;
  logic [63:0] p_rsp_addr;
  logic [SOURCE_ID_W-1:0] p_rsp_source_id;
  logic [TRANSACTION_ID_W-1:0] p_rsp_transaction_id;
  logic [0:0] p_rsp_owner;
  logic [0:0] p_rsp_sharers;

  logic cp_req_valid;
  logic cp_req_ready;
  logic [63:0] cp_req_addr;
  logic [1:0] cp_req_cmd;
  logic [SOURCE_ID_W-1:0] cp_req_source_id;
  logic [TRANSACTION_ID_W-1:0] cp_req_transaction_id;
  logic cp_rsp_valid;
  logic cp_rsp_ready;
  logic cp_rsp_fault;
  logic cp_rsp_hit;
  logic cp_rsp_dirty;
  logic [LINE_BYTES*8-1:0] cp_rsp_data;
  logic [63:0] cp_rsp_addr;
  logic [SOURCE_ID_W-1:0] cp_rsp_source_id;
  logic [TRANSACTION_ID_W-1:0] cp_rsp_transaction_id;
  logic [0:0] cp_rsp_owner;
  logic [0:0] cp_rsp_sharers;

  logic fault_enable;
  logic [63:0] fault_addr;
  logic fault_we_only;
  logic init_we;
  logic [63:0] init_addr;
  logic [7:0] init_strb;
  logic [63:0] init_wdata;
  logic [31:0] accepted_count;
  logic [31:0] response_count;
  logic [31:0] write_count;
  logic [31:0] read_count;

  logic [7:0] model_mem [0:DEPTH-1];
  integer errors;
  integer operations;
  integer seed;
  logic [31:0] prng_state;
  logic saw_refill_beat;
  logic saw_writeback_beat;
  logic saw_core_fault;
  logic saw_probe_response;

  lcvex_l2_wb #(
      .LINE_BYTES(LINE_BYTES), .SETS(SETS), .WAYS(WAYS),
      .CORE_COUNT(1), .SOURCE_ID_W(SOURCE_ID_W),
      .TRANSACTION_ID_W(TRANSACTION_ID_W)
  ) dut (
      .clk(clk), .rst_n(rst_n),
      .u_req_valid(u_req_valid), .u_req(u_req), .u_req_ready(u_req_ready),
      .u_source_id(u_source_id), .u_transaction_id(u_transaction_id),
      .u_rsp_valid(u_rsp_valid), .u_rsp(u_rsp), .u_rsp_ready(u_rsp_ready),
      .u_rsp_source_id(u_rsp_source_id),
      .u_rsp_transaction_id(u_rsp_transaction_id),
      .d_req_valid(d_req_valid), .d_req(d_req), .d_req_ready(d_req_ready),
      .d_rsp_valid(d_rsp_valid), .d_rsp(d_rsp), .d_rsp_ready(d_rsp_ready),
      .probe_req_valid(cp_req_valid), .probe_req_ready(cp_req_ready),
      .probe_req_addr(cp_req_addr), .probe_req_cmd(cp_req_cmd),
      .probe_req_source_id(cp_req_source_id),
      .probe_req_transaction_id(cp_req_transaction_id),
      .probe_rsp_valid(cp_rsp_valid), .probe_rsp_ready(cp_rsp_ready),
      .probe_rsp_fault(cp_rsp_fault), .probe_rsp_hit(cp_rsp_hit),
      .probe_rsp_dirty(cp_rsp_dirty), .probe_rsp_data(cp_rsp_data),
      .probe_rsp_addr(cp_rsp_addr), .probe_rsp_source_id(cp_rsp_source_id),
      .probe_rsp_transaction_id(cp_rsp_transaction_id),
      .probe_rsp_owner(cp_rsp_owner), .probe_rsp_sharers(cp_rsp_sharers)
  );

  lcvex_l2_probe #(
      .LINE_BYTES(LINE_BYTES), .CORE_COUNT(1),
      .SOURCE_ID_W(SOURCE_ID_W), .TRANSACTION_ID_W(TRANSACTION_ID_W)
  ) probe (
      .clk(clk), .rst_n(rst_n),
      .req_valid(p_req_valid), .req_ready(p_req_ready),
      .req_addr(p_req_addr), .req_cmd(p_req_cmd),
      .req_source_id(p_req_source_id),
      .req_transaction_id(p_req_transaction_id),
      .rsp_valid(p_rsp_valid), .rsp_ready(p_rsp_ready),
      .rsp_fault(p_rsp_fault), .rsp_hit(p_rsp_hit), .rsp_dirty(p_rsp_dirty),
      .rsp_data(p_rsp_data), .rsp_addr(p_rsp_addr),
      .rsp_source_id(p_rsp_source_id),
      .rsp_transaction_id(p_rsp_transaction_id),
      .rsp_owner(p_rsp_owner), .rsp_sharers(p_rsp_sharers),
      .cache_req_valid(cp_req_valid), .cache_req_ready(cp_req_ready),
      .cache_req_addr(cp_req_addr), .cache_req_cmd(cp_req_cmd),
      .cache_req_source_id(cp_req_source_id),
      .cache_req_transaction_id(cp_req_transaction_id),
      .cache_rsp_valid(cp_rsp_valid), .cache_rsp_ready(cp_rsp_ready),
      .cache_rsp_fault(cp_rsp_fault), .cache_rsp_hit(cp_rsp_hit),
      .cache_rsp_dirty(cp_rsp_dirty), .cache_rsp_data(cp_rsp_data),
      .cache_rsp_addr(cp_rsp_addr), .cache_rsp_source_id(cp_rsp_source_id),
      .cache_rsp_transaction_id(cp_rsp_transaction_id),
      .cache_rsp_owner(cp_rsp_owner), .cache_rsp_sharers(cp_rsp_sharers)
  );

  lcvex_l2_wb_bfm #(.DEPTH(DEPTH), .BFM_SEED(32'h00b3_0551)) bfm (
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

  always @(posedge clk) begin
    if (d_req_valid && d_req_ready) begin
      $display("TB_D_ACCEPT addr=0x%h we=%0d data=0x%h", d_req.addr,
               d_req.we, d_req.wdata);
      if (d_req.we) saw_writeback_beat <= 1'b1;
      else saw_refill_beat <= 1'b1;
    end
    if (u_rsp_valid && u_rsp_ready && u_rsp.fault) saw_core_fault <= 1'b1;
    if (p_rsp_valid && p_rsp_ready) saw_probe_response <= 1'b1;
  end

  function automatic mem_req_t mkreq(
      input logic [63:0] a,
      input logic we,
      input logic [7:0] strb,
      input logic [63:0] wd,
      input maint_op_t maint,
      input logic bypass);
    mem_req_t q;
    begin
      q = '0;
      q.addr = a;
      q.we = we;
      q.strb = strb;
      q.wdata = wd;
      q.maint = maint;
      q.bypass = bypass;
      mkreq = q;
    end
  endfunction

  task automatic check_ok(input logic condition, input string message);
    if (!condition) begin
      $display("FAIL: %s", message);
      errors = errors + 1;
    end
  endtask

  task automatic init_line(input logic [63:0] a, input logic [7:0] pattern);
    logic [63:0] word;
    integer chunk;
    integer i;
    begin
      for (chunk = 0; chunk < 8; chunk = chunk + 1) begin
        word = '0;
        for (i = 0; i < 8; i = i + 1) begin
          word[i*8 +: 8] = pattern + chunk*8 + i;
          model_mem[a + chunk*8 + i] = pattern + chunk*8 + i;
        end
        @(negedge clk);
        init_we = 1'b1;
        init_addr = a + chunk*8;
        init_strb = 8'hff;
        init_wdata = word;
        @(posedge clk);
        #1 init_we = 1'b0;
      end
    end
  endtask

  function automatic logic [63:0] model_word(input logic [63:0] a);
    logic [63:0] word;
    begin
      word = '0;
      for (int i = 0; i < 8; i++) word[i*8 +: 8] = model_mem[a+i];
      model_word = word;
    end
  endfunction

  function automatic logic [63:0] bfm_word(input logic [63:0] a);
    logic [63:0] word;
    begin
      word = '0;
      for (int i = 0; i < 8; i++) word[i*8 +: 8] = bfm.mem[a+i];
      bfm_word = word;
    end
  endfunction

  function automatic logic [31:0] next_rand();
    begin
      prng_state = prng_state * 32'd1664525 + 32'd1013904223;
      next_rand = prng_state;
    end
  endfunction

  task automatic model_store(input logic [63:0] a, input logic [7:0] strb,
                             input logic [63:0] wd);
    for (int i = 0; i < 8; i++) if (strb[i]) model_mem[a+i] = wd[i*8 +: 8];
  endtask

  task automatic core_req(input mem_req_t q, output mem_rsp_t r);
    integer stall;
    integer watchdog;
    logic [SOURCE_ID_W-1:0] expected_source;
    logic [TRANSACTION_ID_W-1:0] expected_transaction;
    begin
      operations = operations + 1;
      expected_source = operations % (1 << SOURCE_ID_W);
      expected_transaction = (operations * 8'h3d) ^ 8'h55;
      $display("TB_CORE_BEGIN op=%0d addr=0x%h we=%0d maint=%0d", operations,
               q.addr, q.we, q.maint);
      @(negedge clk);
      u_req = q;
      u_source_id = expected_source;
      u_transaction_id = expected_transaction;
      u_req_valid = 1'b1;
      while (!u_req_ready) @(negedge clk);
      @(posedge clk); // valid/ready handshake；不要在 NBA 后再采样 ready
      $display("TB_CORE_ACCEPT op=%0d t=%0t", operations, $time);
      @(negedge clk);
      u_req_valid = 1'b0;
      // 以 DUT 的稳定 response state 作为采样点，避免在同一 posedge
      // 的 NBA/combinational delta 中错过 valid 边沿。
      while (dut.state != 4'd9) @(negedge clk);
      $display("TB_CORE_STATE_RSP op=%0d t=%0t valid=%0d", operations,
               $time, u_rsp_valid);
      $display("TB_CORE_RSP op=%0d fault=%0d data=0x%h", operations,
               u_rsp.fault, u_rsp.rdata);
      r = u_rsp;
      check_ok(u_rsp_source_id == expected_source &&
               u_rsp_transaction_id == expected_transaction,
               "core response IDs must be preserved");
      stall = ((operations % 4) == 0) ? 2 : 0;
      u_rsp_ready = 1'b0;
      repeat (stall) @(posedge clk);
      u_rsp_ready = 1'b1;
      @(posedge clk);
      #1;
    end
  endtask

  task automatic probe_req(input logic [63:0] a, input logic [1:0] cmd,
                           output logic fault, output logic hit,
                           output logic dirty_o,
                           output logic [LINE_BYTES*8-1:0] line);
    integer stall;
    logic [SOURCE_ID_W-1:0] expected_source;
    logic [TRANSACTION_ID_W-1:0] expected_transaction;
    begin
      operations = operations + 1;
      expected_source = 4'h3;
      expected_transaction = (operations * 8'h3d) ^ 8'h55;
      @(negedge clk);
      p_req_addr = a;
      p_req_cmd = cmd;
      p_req_source_id = expected_source;
      p_req_transaction_id = expected_transaction;
      p_req_valid = 1'b1;
      while (!p_req_ready) @(negedge clk);
      @(posedge clk); // valid/ready handshake
      @(negedge clk);
      p_req_valid = 1'b0;
      while (!p_rsp_valid) @(negedge clk);
      fault = p_rsp_fault;
      hit = p_rsp_hit;
      dirty_o = p_rsp_dirty;
      line = p_rsp_data;
      $display("TB_PROBE_RSP addr=0x%h cmd=%0d fault=%0d hit=%0d dirty=%0d owner=%0d sharer=%0d",
               a, cmd, fault, hit, dirty_o, p_rsp_owner[0], p_rsp_sharers[0]);
      check_ok(p_rsp_addr == (a & ~64'h3f), "probe response line address");
      check_ok(p_rsp_source_id == expected_source &&
               p_rsp_transaction_id == expected_transaction,
               "probe response IDs must be preserved");
      check_ok((p_rsp_sharers[0] || !p_rsp_hit || cmd == 2'd2) &&
               (p_rsp_owner[0] || !p_rsp_dirty),
               "single-client owner/sharer boundary");
      stall = ((operations % 3) == 0) ? 1 : 0;
      p_rsp_ready = 1'b0;
      repeat (stall) @(posedge clk);
      p_rsp_ready = 1'b1;
      @(posedge clk);
      #1;
    end
  endtask

  task automatic check_cached(input logic [63:0] a, input logic want_valid,
                              input logic want_dirty);
    integer set_no;
    logic [TAG_W-1:0] want_tag;
    logic found;
    begin
      set_no = (a >> 6) & (SETS-1);
      want_tag = a >> (6 + $clog2(SETS));
      found = 1'b0;
      for (int w = 0; w < WAYS; w++) begin
        if (dut.valid[set_no][w] && dut.tags[set_no][w] == want_tag) begin
          found = 1'b1;
          check_ok(want_valid, $sformatf("cache line 0x%h should be valid", a));
          check_ok(dut.dirty[set_no][w] == want_dirty,
                   $sformatf("cache line 0x%h dirty=%0d expected=%0d", a,
                             dut.dirty[set_no][w], want_dirty));
        end
      end
      if (want_valid) check_ok(found, $sformatf("line 0x%h missing", a));
      else if (found) check_ok(!dut.valid[set_no][0] || !dut.valid[set_no][1],
                              $sformatf("line 0x%h unexpectedly active", a));
    end
  endtask

  task automatic check_line_memory(input logic [63:0] a);
    $display("TB_MEM_CHECK line=0x%h actual=0x%h expected=0x%h", a,
             bfm_word(a), model_word(a));
    for (int i = 0; i < LINE_BYTES; i++)
      check_ok(bfm.mem[a+i] == model_mem[a+i],
               $sformatf("memory line 0x%h byte %0d lost", a, i));
  endtask

  initial begin
    mem_rsp_t r;
    logic pfault;
    logic phit;
    logic pdirty;
    logic [LINE_BYTES*8-1:0] pline;
    integer before_count;
    integer rv;
    integer line_no;
    integer off;
    logic [63:0] ra;
    logic [7:0] rs;
    logic [63:0] rw;

    clk = 1'b0;
    rst_n = 1'b0;
    u_req_valid = 1'b0;
    u_req = '0;
    u_rsp_ready = 1'b1;
    u_source_id = '0;
    u_transaction_id = '0;
    p_req_valid = 1'b0;
    p_req_addr = '0;
    p_req_cmd = 2'd0;
    p_req_source_id = '0;
    p_req_transaction_id = '0;
    p_rsp_ready = 1'b1;
    cp_rsp_ready = 1'b0;
    fault_enable = 1'b0;
    fault_addr = '0;
    fault_we_only = 1'b0;
    init_we = 1'b0;
    init_addr = '0;
    init_strb = '0;
    init_wdata = '0;
    errors = 0;
    operations = 0;
    saw_refill_beat = 1'b0;
    saw_writeback_beat = 1'b0;
    saw_core_fault = 1'b0;
    saw_probe_response = 1'b0;
    seed = 32'h0551_2026;
    prng_state = 32'h0551_2026;
    for (int i = 0; i < DEPTH; i++) model_mem[i] = 8'd0;

    // 复位期间装载独立 BFM，验证 reset 不会产生 stale response。
    init_line(ADDR_A, 8'h10);
    init_line(ADDR_X, 8'h20);
    init_line(ADDR_C, 8'h30);
    init_line(ADDR_D, 8'h40);
    init_line(ADDR_Y, 8'h50);
    init_line(ADDR_Z, 8'h60);
    init_line(ADDR_V, 8'h70);
    init_line(ADDR_RF, 8'h80);
    for (int i = 0; i < 32; i++) init_line(64'h800 + i*64, 8'h90 + i);
    $display("TB_INIT_DONE t=%0t", $time);
    repeat (2) @(posedge clk);
    #1;
    check_ok(!u_rsp_valid && !p_rsp_valid, "reset response must stay low");
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // 1. read miss/refill、hit 和随机下游 backpressure。
    $display("TB_STAGE 1 t=%0t", $time);
    before_count = accepted_count;
    core_req(mkreq(ADDR_A+9, 1'b0, 8'h00, '0, MAINT_NONE, 1'b0), r);
    check_ok(!r.fault && r.rdata == model_word(ADDR_A+9),
             $sformatf("read miss data 0x%h", r.rdata));
    check_ok(accepted_count == before_count + 8,
             "read miss must issue exactly 8 refill beats");
    before_count = accepted_count;
    core_req(mkreq(ADDR_A+9, 1'b0, 8'h00, '0, MAINT_NONE, 1'b0), r);
    check_ok(!r.fault && r.rdata == model_word(ADDR_A+9), "read hit data");
    check_ok(accepted_count == before_count, "read hit must not access memory");

    // 2. write miss allocate + partial merge，随后 write hit 继续变 dirty。
    before_count = accepted_count;
    core_req(mkreq(ADDR_D+5, 1'b1, 8'h0f, 64'h8877665544332211,
                   MAINT_NONE, 1'b0), r);
    check_ok(!r.fault, "write miss allocate response");
    model_store(ADDR_D+5, 8'h0f, 64'h8877665544332211);
    check_ok(accepted_count == before_count + 8,
             "write miss must refill before merge");
    before_count = accepted_count;
    core_req(mkreq(ADDR_D+5, 1'b0, 8'h00, '0, MAINT_NONE, 1'b0), r);
    check_ok(!r.fault && r.rdata == model_word(ADDR_D+5),
             "partial write miss merge readback");
    core_req(mkreq(ADDR_D+1, 1'b1, 8'h03, 64'h000000000000bbaa,
                   MAINT_NONE, 1'b0), r);
    check_ok(!r.fault, "write hit dirty response");
    model_store(ADDR_D+1, 8'h03, 64'h000000000000bbaa);
    check_ok(accepted_count == before_count,
             "write hit must not issue write-through beat");
    check_cached(ADDR_D, 1'b1, 1'b1);

    // 3. dirty victim：A 保持 MRU，X 成为 dirty LRU，C miss 必须先 WB 8 beat。
    core_req(mkreq(ADDR_X, 1'b0, 8'h00, '0, MAINT_NONE, 1'b0), r);
    check_ok(!r.fault && r.rdata == model_word(ADDR_X), "fill second way");
    core_req(mkreq(ADDR_X+4, 1'b1, 8'hf0, 64'hde_ad_be_ef_01_02_03_04,
                   MAINT_NONE, 1'b0), r);
    check_ok(!r.fault, "make X dirty");
    model_store(ADDR_X+4, 8'hf0, 64'hde_ad_be_ef_01_02_03_04);
    core_req(mkreq(ADDR_A, 1'b0, 8'h00, '0, MAINT_NONE, 1'b0), r);
    before_count = accepted_count;
    core_req(mkreq(ADDR_C+13, 1'b0, 8'h00, '0, MAINT_NONE, 1'b0), r);
    check_ok(!r.fault && r.rdata == model_word(ADDR_C+13),
             "dirty victim refill response");
    check_ok(accepted_count == before_count + 16,
             "dirty victim must write 8 beats then refill 8 beats");
    check_line_memory(ADDR_X);

    // 4. probe lookup/clean/invalidate 经独立 lcvex_l2_probe bridge。
    probe_req(ADDR_D, 2'd0, pfault, phit, pdirty, pline);
    check_ok(!pfault && phit && pdirty, "probe lookup sees dirty owner");
    for (int i = 0; i < LINE_BYTES; i++)
      check_ok(pline[i*8 +: 8] == model_mem[ADDR_D+i], "probe line data");
    probe_req(ADDR_D, 2'd1, pfault, phit, pdirty, pline);
    check_ok(!pfault && phit && !pdirty, "probe clean completion");
    check_line_memory(ADDR_D);
    probe_req(ADDR_D, 2'd2, pfault, phit, pdirty, pline);
    check_ok(!pfault && phit, "probe invalidate completion");
    before_count = accepted_count;
    core_req(mkreq(ADDR_D+2, 1'b0, 8'h00, '0, MAINT_NONE, 1'b0), r);
    check_ok(!r.fault && r.rdata == model_word(ADDR_D+2),
             "probe invalidated line refills");
    check_ok(accepted_count == before_count + 8, "invalidate must remove line");

    // 5. 核心 DC clean / clean+invalidate maintenance。
    core_req(mkreq(ADDR_D+2, 1'b1, 8'h01, 64'h00000000000000cc,
                   MAINT_NONE, 1'b0), r);
    model_store(ADDR_D+2, 8'h01, 64'hcc);
    core_req(mkreq(ADDR_D, 1'b0, 8'h00, '0, MAINT_DC_CVAC, 1'b0), r);
    check_ok(!r.fault, "DC CVAC response");
    check_line_memory(ADDR_D);
    check_cached(ADDR_D, 1'b1, 1'b0);
    core_req(mkreq(ADDR_D, 1'b0, 8'h00, '0, MAINT_DC_CIVAC, 1'b0), r);
    check_ok(!r.fault, "DC CIVAC response");
    before_count = accepted_count;
    core_req(mkreq(ADDR_D, 1'b0, 8'h00, '0, MAINT_NONE, 1'b0), r);
    check_ok(!r.fault && r.rdata == model_word(ADDR_D), "post CIVAC refill");
    check_ok(accepted_count == before_count + 8, "CIVAC invalidates clean line");

    // 6. writeback fault：部分 beat 已到达也不得清 dirty/tag；关闭 fault 后重试。
    core_req(mkreq(ADDR_Y, 1'b0, 8'h00, '0, MAINT_NONE, 1'b0), r);
    core_req(mkreq(ADDR_Z, 1'b0, 8'h00, '0, MAINT_NONE, 1'b0), r);
    core_req(mkreq(ADDR_Y+1, 1'b1, 8'h01, 64'h5a, MAINT_NONE, 1'b0), r);
    model_store(ADDR_Y+1, 8'h01, 64'h5a);
    core_req(mkreq(ADDR_Z, 1'b0, 8'h00, '0, MAINT_NONE, 1'b0), r);
    fault_enable = 1'b1;
    fault_addr = ADDR_Y;
    fault_we_only = 1'b1;
    core_req(mkreq(ADDR_V+7, 1'b0, 8'h00, '0, MAINT_NONE, 1'b0), r);
    check_ok(r.fault, "writeback fault must reach core");
    check_cached(ADDR_Y, 1'b1, 1'b1);
    check_ok(bfm_word(ADDR_Y) != model_word(ADDR_Y),
             "faulted writeback must not claim complete memory update");
    fault_enable = 1'b0;
    before_count = accepted_count;
    core_req(mkreq(ADDR_V+7, 1'b0, 8'h00, '0, MAINT_NONE, 1'b0), r);
    check_ok(!r.fault && r.rdata == model_word(ADDR_V+7),
             "retry after writeback fault");
    check_ok(accepted_count == before_count + 16,
             "retry must redo complete WB and refill");
    check_line_memory(ADDR_Y);

    // 7. refill fault：不发布新 tag/成功响应，关闭 fault 后必须再次完整 refill。
    fault_enable = 1'b1;
    fault_addr = ADDR_RF + 24;
    fault_we_only = 1'b0;
    core_req(mkreq(ADDR_RF+3, 1'b0, 8'h00, '0, MAINT_NONE, 1'b0), r);
    check_ok(r.fault, "refill fault must reach core");
    check_cached(ADDR_RF, 1'b0, 1'b0);
    fault_enable = 1'b0;
    before_count = accepted_count;
    core_req(mkreq(ADDR_RF+3, 1'b0, 8'h00, '0, MAINT_NONE, 1'b0), r);
    check_ok(!r.fault && r.rdata == model_word(ADDR_RF+3),
             "retry after refill fault");
    check_ok(accepted_count == before_count + 8,
             "refill fault must not turn retry into hit");

    // 8. bypass 与固定 seed 随机读写/替换，model_mem 是本 TB 的唯一期望源。
    core_req(mkreq(64'h3000, 1'b1, 8'hff, 64'h0123456789abcdef,
                   MAINT_NONE, 1'b1), r);
    check_ok(!r.fault, "bypass store");
    model_store(64'h3000, 8'hff, 64'h0123456789abcdef);
    core_req(mkreq(64'h3000, 1'b0, 8'h00, '0, MAINT_NONE, 1'b1), r);
    check_ok(!r.fault && r.rdata == model_word(64'h3000), "bypass load");
    for (int n = 0; n < 64; n++) begin
      rv = next_rand() & 32'h7fff_ffff;
      line_no = rv % 32;
      rv = next_rand() & 32'h7fff_ffff;
      off = rv % 57;
      ra = 64'h800 + line_no*64 + off;
      rv = next_rand() & 32'h7fff_ffff;
      if ((rv & 3) != 0) begin
        rs = rv[7:0] | 8'h01;
        rw = {next_rand(), next_rand()};
        core_req(mkreq(ra, 1'b1, rs, rw, MAINT_NONE, 1'b0), r);
        check_ok(!r.fault, $sformatf("random store %0d", n));
        if (!r.fault) model_store(ra, rs, rw);
      end else begin
        core_req(mkreq(ra, 1'b0, 8'h00, '0, MAINT_NONE, 1'b0), r);
        check_ok(!r.fault && r.rdata == model_word(ra),
                 $sformatf("random load %0d got 0x%h expected 0x%h", n,
                           r.rdata, model_word(ra)));
      end
    end

    // 9. 全局 IC invalidate 先清 dirty，再丢弃 tag；无 dirty 数据可丢失。
    core_req(mkreq(64'd0, 1'b0, 8'h00, '0, MAINT_IC_IALLU, 1'b0), r);
    check_ok(!r.fault, "global invalidate response");
    check_line_memory(ADDR_A);
    check_line_memory(ADDR_D);
    check_line_memory(ADDR_Y);
    for (int i = 0; i < 32; i++) check_line_memory(64'h800 + i*64);
    before_count = accepted_count;
    core_req(mkreq(ADDR_A+1, 1'b0, 8'h00, '0, MAINT_NONE, 1'b0), r);
    check_ok(!r.fault && r.rdata == model_word(ADDR_A+1), "post global refill");
    check_ok(accepted_count == before_count + 8, "global invalidate removes tags");

    check_ok(accepted_count == response_count,
             "BFM accepted and consumed response counts must match");
    check_ok(saw_refill_beat, "scoreboard must observe refill traffic");
    check_ok(saw_writeback_beat, "scoreboard must observe writeback traffic");
    check_ok(saw_core_fault, "scoreboard must observe injected core fault");
    check_ok(saw_probe_response, "scoreboard must observe probe traffic");
    check_ok(write_count > 8, "writeback traffic must be observable");
    check_ok(read_count > 64, "refill traffic must be observable");
    if (errors == 0) begin
      $display("PASS: lcvex_l2_wb_tb seed=0x%08x operations=%0d accepted=%0d",
               32'h0551_2026, operations, accepted_count);
      $finish;
    end else begin
      $fatal(1, "FAIL: %0d errors", errors);
    end
  end

  /* verilator lint_on SYNCASYNCNET */
  /* verilator lint_on UNUSEDSIGNAL */
  /* verilator lint_on WIDTHTRUNC */
  /* verilator lint_on WIDTHEXPAND */

endmodule
