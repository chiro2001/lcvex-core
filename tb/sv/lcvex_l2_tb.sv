// lcvex_l2_tb.sv
// M2 单元测试：统一 L2（2-way 组相联，LRU 替换）。
// 覆盖：读 miss 填行、两 way 命中、LRU 替换、写通、写命中行更新、
//       冲突驱逐、下游 fault 上抛。
// 运行：make sim-sv-l2

`timescale 1ns/1ps

module lcvex_l2_tb;
  import lcvex_pkg::*;

  logic clk;
  logic rst_n;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [63:0] dbg_dummy;  // P6 调试读口（未用）
  logic        perf_hit_unused;
  logic        perf_refill_beat_unused;
  /* verilator lint_on UNUSEDSIGNAL */

  logic        u_req_valid;
  mem_req_t    u_req;
  logic        u_req_ready;
  logic        u_rsp_valid;
  mem_rsp_t    u_rsp;
  logic        u_rsp_ready;
  logic        d_req_valid;
  mem_req_t    d_req;
  logic        d_req_ready;
  logic        d_rsp_valid;
  mem_rsp_t    d_rsp;
  logic        d_rsp_ready;
  logic        prog_we;
  logic [63:0] prog_addr;
  logic [7:0]  prog_strb;
  logic [63:0] prog_wdata;

  lcvex_l2 #(.LINE_BYTES(64), .SETS(256), .WAYS(2)) l2 (
      .clk         (clk),
      .rst_n       (rst_n),
      .u_req_valid (u_req_valid),
      .u_req       (u_req),
      .u_req_ready (u_req_ready),
      .u_rsp_valid (u_rsp_valid),
      .u_rsp       (u_rsp),
      .u_rsp_ready (u_rsp_ready),
      .d_req_valid (d_req_valid),
      .d_req       (d_req),
      .d_req_ready (d_req_ready),
      .d_rsp_valid (d_rsp_valid),
      .d_rsp       (d_rsp),
      .d_rsp_ready (d_rsp_ready),
      .perf_hit    (perf_hit_unused),
      .perf_refill_beat (perf_refill_beat_unused)
  );

  lcvex_mem_ram #(.DEPTH(1 << 20), .SRAM_BASE(64'd0)) ram (
      .clk        (clk),
      .rst_n      (rst_n),
      .req_valid  (d_req_valid),
      .req        (d_req),
      .req_accept (d_req_ready),
      .rsp_valid  (d_rsp_valid),
      .rsp        (d_rsp),
      .rsp_ready  (d_rsp_ready),
      .prog_we    (prog_we),
      .prog_addr  (prog_addr),
      .prog_strb  (prog_strb),
      .prog_wdata (prog_wdata),
      .dbg_addr   (32'd0),
      .dbg_rdata  (dbg_dummy)
  );

  always #5 clk = ~clk;  // 100 MHz

  int errs = 0;
  mem_req_t rd_req;
  mem_req_t wr_req;
  mem_rsp_t rsp_o;

  task automatic check_ok(input logic cond, input string msg);
    if (!cond) begin
      $display("FAIL: %s", msg);
      errs++;
    end
  endtask

  task automatic tick(input int n = 1);
    repeat (n) @(posedge clk);
  endtask

  task automatic do_req(input mem_req_t r, output mem_rsp_t o);
    u_req_valid = 1'b1;
    u_req = r;
    u_rsp_ready = 1'b1;
    wait (u_req_ready);
    while (!u_rsp_valid) begin
      @(posedge clk);
    end
    u_req_valid = 1'b0;
    o = u_rsp;
    @(posedge clk);
  endtask

  initial begin
    $display("=== lcvex_l2_tb: 统一 L2 缓存单元测试 ===");
    clk = 1'b0;
    rst_n = 1'b0;
    u_req_valid = 1'b0;
    u_req = '0;
    u_rsp_ready = 1'b1;
    prog_we = 1'b0;
    prog_addr = 64'd0;
    prog_strb = 8'h00;
    prog_wdata = 64'd0;
    tick(2);
    rst_n = 1'b1;
    tick(2);

    // 1) 写 miss：写通到 RAM，不分配
    wr_req = '{addr: 64'h100, we: 1'b1, strb: 8'hFF,
               wdata: 64'h1122334455667788, maint: MAINT_NONE, bypass: 1'b0};
    do_req(wr_req, rsp_o);
    check_ok(rsp_o.fault == 0, "写 miss 响应 fault");

    // 2) 读 miss：填行（way 1）后返回
    rd_req = '{addr: 64'h100, we: 1'b0, strb: 8'hFF, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    do_req(rd_req, rsp_o);
    check_ok(!rsp_o.fault && rsp_o.rdata == 64'h1122334455667788,
             $sformatf("读 miss 填行返回 0x%h", rsp_o.rdata));

    // 3) 读命中
    do_req(rd_req, rsp_o);
    check_ok(rsp_o.rdata == 64'h1122334455667788, "读命中返回缓存数据");

    // 4) 同组异 tag（0x4100，tag 1）：miss 填另一 way
    rd_req = '{addr: 64'h4100, we: 1'b0, strb: 8'hFF, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    do_req(rd_req, rsp_o);
    check_ok(!rsp_o.fault && rsp_o.rdata == 64'd0, "第二 way 填行");

    // 5) 两 way 均可命中
    rd_req = '{addr: 64'h100, we: 1'b0, strb: 8'hFF, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    do_req(rd_req, rsp_o);
    check_ok(rsp_o.rdata == 64'h1122334455667788, "way0 命中");
    rd_req = '{addr: 64'h4100, we: 1'b0, strb: 8'hFF, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    do_req(rd_req, rsp_o);
    check_ok(rsp_o.rdata == 64'd0, "way1 命中");

    // 6) 写命中：更新行 + 写通
    wr_req = '{addr: 64'h100, we: 1'b1, strb: 8'hFF,
               wdata: 64'hDEADBEEFCAFEBABE, maint: MAINT_NONE, bypass: 1'b0};
    do_req(wr_req, rsp_o);
    rd_req = '{addr: 64'h100, we: 1'b0, strb: 8'hFF, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    do_req(rd_req, rsp_o);
    check_ok(rsp_o.rdata == 64'hDEADBEEFCAFEBABE, "写命中后读回新值");

    // 7) LRU 替换：第三个 tag（0x8100, tag 2）替换最近未使用的 way
    rd_req = '{addr: 64'h8100, we: 1'b0, strb: 8'hFF, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    do_req(rd_req, rsp_o);
    check_ok(!rsp_o.fault && rsp_o.rdata == 64'd0, "LRU 替换后读新行");

    // 8) 被替换的 way 重新填行（写通数据在 RAM）
    rd_req = '{addr: 64'h4100, we: 1'b0, strb: 8'hFF, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    do_req(rd_req, rsp_o);
    check_ok(!rsp_o.fault && rsp_o.rdata == 64'd0, "被驱逐 way 重新填行");

    // 9) 保留的 way 仍命中
    rd_req = '{addr: 64'h100, we: 1'b0, strb: 8'hFF, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    do_req(rd_req, rsp_o);
    check_ok(rsp_o.rdata == 64'hDEADBEEFCAFEBABE, "保留 way 命中");

    // 10) 下游 fault 上抛（越界地址）
    rd_req = '{addr: 64'h400000, we: 1'b0, strb: 8'hFF, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    do_req(rd_req, rsp_o);
    check_ok(rsp_o.fault, "越界读应上抛 fault");

    // 11) bypass 写：直通 RAM，不更新已缓存行（同 set 已有旧行）
    wr_req = '{addr: 64'h100, we: 1'b1, strb: 8'hFF,
               wdata: 64'h0102030405060708, maint: MAINT_NONE, bypass: 1'b1};
    do_req(wr_req, rsp_o);
    check_ok(rsp_o.fault == 0, "bypass 写响应 fault");
    // 12) 普通读仍命中旧缓存行（bypass 未触碰行）
    rd_req = '{addr: 64'h100, we: 1'b0, strb: 8'hFF, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    do_req(rd_req, rsp_o);
    check_ok(rsp_o.rdata == 64'hDEADBEEFCAFEBABE,
             "bypass 写后普通读仍命中缓存旧值");
    // 13) bypass 读直通 RAM（绕过缓存行）
    rd_req = '{addr: 64'h100, we: 1'b0, strb: 8'hFF, wdata: '0, maint: MAINT_NONE, bypass: 1'b1};
    do_req(rd_req, rsp_o);
    check_ok(rsp_o.rdata == 64'h0102030405060708,
             $sformatf("bypass 读返回 RAM 新值 0x%h", rsp_o.rdata));

    if (errs == 0) begin
      $display("PASS: lcvex_l2_tb 全部通过");
      $finish;
    end else begin
      $fatal(1, "FAIL: %0d 处错误", errs);
    end
  end
endmodule
