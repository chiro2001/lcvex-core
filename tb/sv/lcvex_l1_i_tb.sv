// lcvex_l1_i_tb.sv
// M2 单元测试：I-L1 只读直接映射缓存。
// 覆盖：读命中、读未命中填行、冲突替换、下游 fault 上抛。
// 运行：make sim-sv-l1i

`timescale 1ns/1ps

module lcvex_l1_i_tb;
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

  lcvex_l1_i #(.LINE_BYTES(64), .SETS(64)) l1 (
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

  lcvex_mem_ram #(.DEPTH(1 << 16), .SRAM_BASE(64'd0)) ram (
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
    $display("=== lcvex_l1_i_tb: I-L1 只读缓存单元测试 ===");
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

    // RAM 预填 0x100 处 8 字节（模拟镜像中的指令）
    prog_we = 1'b1;
    prog_addr = 64'h100;
    prog_strb = 8'hFF;
    prog_wdata = 64'h1122334455667788;
    @(posedge clk);
    // 预填行尾（off 0x3c，非零块内偏移）4 字节
    prog_addr = 64'h13c;
    prog_strb = 8'h0F;
    prog_wdata = 64'h00000000DEADBEEF;
    @(posedge clk);
    prog_we = 1'b0;

    // 1) 读 miss：填行后返回
    rd_req = '{addr: 64'h100, we: 1'b0, strb: 8'h0F, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    do_req(rd_req, rsp_o);
    check_ok(!rsp_o.fault && rsp_o.rdata[31:0] == 32'h55667788,
             $sformatf("读 miss 填行返回 0x%h", rsp_o.rdata));

    // 2) 读命中：1 拍返回
    do_req(rd_req, rsp_o);
    check_ok(!rsp_o.fault && rsp_o.rdata[31:0] == 32'h55667788,
             "读命中返回缓存数据");

    // 3) 冲突替换：同组异 tag（0x1100, index 4, tag 1）
    rd_req = '{addr: 64'h1100, we: 1'b0, strb: 8'h0F, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    do_req(rd_req, rsp_o);
    check_ok(!rsp_o.fault && rsp_o.rdata[31:0] == 32'd0,
             "冲突替换后读新行（RAM 值 0）");

    // 4) 冲突后旧行重新填行
    rd_req = '{addr: 64'h100, we: 1'b0, strb: 8'h0F, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    do_req(rd_req, rsp_o);
    check_ok(rsp_o.rdata[31:0] == 32'h55667788,
             "冲突驱逐后重新填行");

    // 5) 越界 fault 上抛
    rd_req = '{addr: 64'h40000, we: 1'b0, strb: 8'h0F, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    do_req(rd_req, rsp_o);
    check_ok(rsp_o.fault, "越界读应上抛 fault");

    // 6) 行尾非零偏移取指（off 0x3c, off[2:0]=4）
    rd_req = '{addr: 64'h13c, we: 1'b0, strb: 8'h0F, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    do_req(rd_req, rsp_o);
    check_ok(!rsp_o.fault && rsp_o.rdata[31:0] == 32'hDEADBEEF,
             $sformatf("行尾取指返回 0x%h", rsp_o.rdata));

    // 7) bypass 读：直通下游、不分配行（同 set 已有 0x100 旧行）
    rd_req = '{addr: 64'h110, we: 1'b0, strb: 8'h0F, wdata: '0, maint: MAINT_NONE, bypass: 1'b1};
    do_req(rd_req, rsp_o);
    check_ok(!rsp_o.fault && rsp_o.rdata[31:0] == 32'h0,
             "bypass 读返回下游数据");
    // 8) bypass 读后普通读仍命中原缓存行（bypass 未驱逐/未分配）
    rd_req = '{addr: 64'h100, we: 1'b0, strb: 8'h0F, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    do_req(rd_req, rsp_o);
    check_ok(rsp_o.rdata[31:0] == 32'h55667788,
             "bypass 读后普通读仍命中缓存");

    // 9) IC IVAU：失效单行后读必须 miss 重新填行（RAM 值已更新）
    prog_we = 1'b1;
    prog_addr = 64'h100;
    prog_strb = 8'hFF;
    prog_wdata = 64'hAABBCCDDEEFF0011;
    @(posedge clk);
    prog_we = 1'b0;
    rd_req = '{addr: 64'h100, we: 1'b0, strb: 8'h0F, wdata: '0,
              maint: MAINT_IC_IVAU, bypass: 1'b0};
    do_req(rd_req, rsp_o);          // 失效请求：直接响应，不下发下游
    check_ok(!rsp_o.fault, "IC IVAU 失效响应 fault");
    rd_req = '{addr: 64'h100, we: 1'b0, strb: 8'h0F, wdata: '0,
              maint: MAINT_NONE, bypass: 1'b0};
    do_req(rd_req, rsp_o);          // 失效后必须 miss -> 重新填行
    check_ok(rsp_o.rdata[31:0] == 32'hEEFF0011,
             $sformatf("IC IVAU 后读回新值 0x%h", rsp_o.rdata));

    // 10) IC IALLU：整表失效后同样重新填行
    prog_we = 1'b1;
    prog_addr = 64'h100;
    prog_strb = 8'hFF;
    prog_wdata = 64'h0102030405060708;
    @(posedge clk);
    prog_we = 1'b0;
    rd_req = '{addr: 64'h100, we: 1'b0, strb: 8'h0F, wdata: '0,
              maint: MAINT_IC_IALLU, bypass: 1'b0};
    do_req(rd_req, rsp_o);
    check_ok(!rsp_o.fault, "IC IALLU 失效响应 fault");
    rd_req = '{addr: 64'h100, we: 1'b0, strb: 8'h0F, wdata: '0,
              maint: MAINT_NONE, bypass: 1'b0};
    do_req(rd_req, rsp_o);
    check_ok(rsp_o.rdata[31:0] == 32'h05060708,
             $sformatf("IC IALLU 后读回新值 0x%h", rsp_o.rdata));

    if (errs == 0) begin
      $display("PASS: lcvex_l1_i_tb 全部通过");
      $finish;
    end else begin
      $fatal(1, "FAIL: %0d 处错误", errs);
    end
  end
endmodule
