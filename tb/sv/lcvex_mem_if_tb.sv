// lcvex_mem_if_tb.sv
// M1-B 单元测试：lcvex_mem_ram / lcvex_mem_delay / lcvex_mem_arb。
// 覆盖：写读回、背压响应保持、越界/跨顶 fault、1 周期延迟、
// 仲裁优先级（PTW>数据>取指）与响应按端口路由。
// 运行：make sim-sv-memif

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */
module lcvex_mem_if_tb;
  import lcvex_pkg::*;

  logic clk;
  logic rst_n;

  // ---- RAM 直连 ----
  logic        ram_req_valid;
  mem_req_t    ram_req;
  logic        ram_req_accept;
  logic        ram_rsp_valid;
  mem_rsp_t    ram_rsp;
  logic        ram_rsp_ready;
  logic [63:0] dbg_dummy;  // P6 调试读口（未用）

  lcvex_mem_ram #(.DEPTH(1 << 10), .SRAM_BASE(64'd0)) ram (
      .clk        (clk),
      .rst_n      (rst_n),
      .req_valid  (ram_req_valid),
      .req        (ram_req),
      .req_accept (ram_req_accept),
      .rsp_valid  (ram_rsp_valid),
      .rsp        (ram_rsp),
      .rsp_ready  (ram_rsp_ready),
      .prog_we    (1'b0),
      .prog_addr  (64'd0),
      .prog_strb  (8'h00),
      .prog_wdata (64'd0),
      .dbg_addr    (32'd0),
      .dbg_rdata   (dbg_dummy)
  );

  // ---- 仲裁 -> 延迟(1) -> RAM ----
  logic [2:0]     a_req_valid;
  mem_req_t [2:0] a_req;
  logic [2:0]     a_req_ready;
  logic [2:0]     a_rsp_valid;
  mem_rsp_t [2:0] a_rsp;
  logic [2:0]     a_rsp_ready;
  logic           d_req_valid;
  mem_req_t       d_req;
  logic           d_req_ready;
  logic           d_rsp_valid;
  mem_rsp_t       d_rsp;
  logic           d_rsp_ready;
  logic           ram2_req_valid;
  mem_req_t       ram2_req;
  logic           ram2_req_accept;
  logic           ram2_rsp_valid;
  mem_rsp_t       ram2_rsp;
  logic           ram2_rsp_ready;

  lcvex_mem_arb #(.PORTS(3)) arb (
      .clk            (clk),
      .rst_n          (rst_n),
      .req_valid      (a_req_valid),
      .req            (a_req),
      .req_ready      (a_req_ready),
      .rsp_valid      (a_rsp_valid),
      .rsp            (a_rsp),
      .rsp_ready      (a_rsp_ready),
      .mem_req_valid  (d_req_valid),
      .mem_req        (d_req),
      .mem_req_accept (d_req_ready),
      .mem_rsp_valid  (d_rsp_valid),
      .mem_rsp        (d_rsp),
      .mem_rsp_ready  (d_rsp_ready)
  );

  lcvex_mem_delay #(.DELAY_MODE(1)) delay (
      .clk            (clk),
      .rst_n          (rst_n),
      .req_valid      (d_req_valid),
      .req            (d_req),
      .req_ready      (d_req_ready),
      .req_out_valid  (ram2_req_valid),
      .req_out        (ram2_req),
      .req_out_ready  (ram2_req_accept),
      .rsp_in_valid   (ram2_rsp_valid),
      .rsp_in         (ram2_rsp),
      .rsp_in_ready   (ram2_rsp_ready),
      .rsp_out_valid  (d_rsp_valid),
      .rsp_out        (d_rsp),
      .rsp_out_ready  (d_rsp_ready)
  );

  lcvex_mem_ram #(.DEPTH(1 << 10), .SRAM_BASE(64'd0)) ram2 (
      .clk        (clk),
      .rst_n      (rst_n),
      .req_valid  (ram2_req_valid),
      .req        (ram2_req),
      .req_accept (ram2_req_accept),
      .rsp_valid  (ram2_rsp_valid),
      .rsp        (ram2_rsp),
      .rsp_ready  (ram2_rsp_ready),
      .prog_we    (1'b0),
      .prog_addr  (64'd0),
      .prog_strb  (8'h00),
      .prog_wdata (64'd0),
      .dbg_addr    (32'd0),
      .dbg_rdata   (dbg_dummy)
  );

  // ---- 大容量 RAM（P6：128 MiB，QEMU virt 布局 0x40000000..0x48000000）----
  logic        big_req_valid;
  mem_req_t    big_req;
  logic        big_req_accept;
  logic        big_rsp_valid;
  mem_rsp_t    big_rsp;
  logic        big_rsp_ready;

  lcvex_mem_ram #(.DEPTH(1 << 27), .SRAM_BASE(64'h0000_0000_4000_0000)) big (
      .clk        (clk),
      .rst_n      (rst_n),
      .req_valid  (big_req_valid),
      .req        (big_req),
      .req_accept (big_req_accept),
      .rsp_valid  (big_rsp_valid),
      .rsp        (big_rsp),
      .rsp_ready  (big_rsp_ready),
      .prog_we    (1'b0),
      .prog_addr  (64'd0),
      .prog_strb  (8'h00),
      .prog_wdata (64'd0),
      .dbg_addr    (32'd0),
      .dbg_rdata   (dbg_dummy)
  );

  always #5 clk = ~clk;  // 100 MHz

  int errs = 0;
  mem_req_t wr_req;
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

  // RAM 直连请求：发起一次访问并等待响应（rsp_ready 恒 1）
  task automatic ram_access(input mem_req_t r, output mem_rsp_t o);
    ram_req_valid = 1'b1;
    ram_req = r;
    ram_rsp_ready = 1'b1;
    wait (ram_req_accept);
    @(posedge clk);
    ram_req_valid = 1'b0;
    wait (ram_rsp_valid);
    o = ram_rsp;
    @(posedge clk);
  endtask

  // 大容量 RAM 请求（big 实例）
  task automatic big_access(input mem_req_t r, output mem_rsp_t o);
    big_req_valid = 1'b1;
    big_req = r;
    big_rsp_ready = 1'b1;
    wait (big_req_accept);
    @(posedge clk);
    big_req_valid = 1'b0;
    wait (big_rsp_valid);
    o = big_rsp;
    @(posedge clk);
  endtask

  initial begin
    $display("=== lcvex_mem_if_tb: ram/delay/arb 单元测试 ===");
    clk = 1'b0;
    rst_n = 1'b0;
    ram_req_valid = 1'b0;
    ram_req = '0;
    ram_rsp_ready = 1'b1;
    big_req_valid = 1'b0;
    big_req = '0;
    big_rsp_ready = 1'b1;
    a_req_valid = '0;
    a_req = '{3{'0}};
    a_rsp_ready = '1;
    tick(2);
    rst_n = 1'b1;
    tick(2);

    // ---- RAM：写后读 ----
    wr_req = '{addr: 64'h100, we: 1'b1, strb: 8'hFF,
               wdata: 64'h1122334455667788, maint: MAINT_NONE, bypass: 1'b0};
    ram_access(wr_req, rsp_o);
    check_ok(rsp_o.fault == 0, "写响应 fault");
    rd_req = '{addr: 64'h100, we: 1'b0, strb: 8'h00, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    ram_access(rd_req, rsp_o);
    check_ok(rsp_o.fault == 0 && rsp_o.rdata == 64'h1122334455667788,
             $sformatf("读回数据 0x%h 期望 0x1122334455667788",
                       rsp_o.rdata));

    // ---- RAM：背压保持 ----
    ram_req_valid = 1'b1;
    ram_req = '{addr: 64'h100, we: 1'b0, strb: 8'h00, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    ram_rsp_ready = 1'b1;
    wait (ram_req_accept);
    @(posedge clk);
    ram_req_valid = 1'b0;
    ram_rsp_ready = 1'b0;          // 消费端忙
    wait (ram_rsp_valid);
    rsp_o = ram_rsp;
    tick(3);
    check_ok(ram_rsp_valid, "背压期间 rsp_valid 应保持");
    check_ok(ram_rsp.rdata == rsp_o.rdata, "背压期间 rsp 数据应保持");
    ram_req_valid = 1'b1;          // 背压期间请求挂起，不得被接受
    ram_req = '{addr: 64'h200, we: 1'b0, strb: 8'h00, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    tick(1);
    check_ok(!ram_req_accept, "背压期间不应接受新请求");
    ram_req_valid = 1'b0;
    ram_rsp_ready = 1'b1;
    tick(2);
    check_ok(!ram_rsp_valid, "消费后 rsp_valid 应清除");

    // ---- RAM：越界与跨顶 fault ----
    rd_req = '{addr: 64'h400, we: 1'b0, strb: 8'h00, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    ram_access(rd_req, rsp_o);
    check_ok(rsp_o.fault, "越界读应 fault");
    rd_req = '{addr: 64'h3FC, we: 1'b0, strb: 8'hFF, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    ram_access(rd_req, rsp_o);
    check_ok(rsp_o.fault, "跨顶 8 字节读应 fault（回绕防护）");

    // ---- 大容量 RAM（128 MiB）：1 MiB 之上的写读回、TOP-8 与 TOP 边界 ----
    wr_req = '{addr: 64'h0000_0000_4400_0000, we: 1'b1, strb: 8'hFF,
               wdata: 64'hDEADBEEFCAFEBABE, maint: MAINT_NONE, bypass: 1'b0};
    big_access(wr_req, rsp_o);
    check_ok(rsp_o.fault == 0, "64 MiB 偏移写响应 fault");
    rd_req = '{addr: 64'h0000_0000_4400_0000, we: 1'b0, strb: 8'h00,
               wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    big_access(rd_req, rsp_o);
    check_ok(rsp_o.fault == 0 && rsp_o.rdata == 64'hDEADBEEFCAFEBABE,
             $sformatf("64 MiB 偏移读回 0x%h 期望 0xDEADBEEFCAFEBABE",
                       rsp_o.rdata));
    // TOP-8：8 字节整宽访问落在窗口内
    wr_req = '{addr: 64'h0000_0000_47FF_FFF8, we: 1'b1, strb: 8'hFF,
               wdata: 64'h0001020304050607, maint: MAINT_NONE, bypass: 1'b0};
    big_access(wr_req, rsp_o);
    check_ok(rsp_o.fault == 0, "TOP-8 写响应 fault");
    rd_req = '{addr: 64'h0000_0000_47FF_FFF8, we: 1'b0, strb: 8'h00,
               wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    big_access(rd_req, rsp_o);
    check_ok(rsp_o.fault == 0 && rsp_o.rdata == 64'h0001020304050607,
             $sformatf("TOP-8 读回 0x%h 期望 0x0001020304050607",
                       rsp_o.rdata));
    // TOP：越界 -> fault（新边界 0x48000000）
    rd_req = '{addr: 64'h0000_0000_4800_0000, we: 1'b0, strb: 8'h00,
               wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    big_access(rd_req, rsp_o);
    check_ok(rsp_o.fault, "TOP 越界读应 fault");
    wr_req = '{addr: 64'h0000_0000_47FF_FFFC, we: 1'b1, strb: 8'hFF,
               wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    big_access(wr_req, rsp_o);
    check_ok(rsp_o.fault, "TOP 跨顶 8 字节写应 fault");

    // ---- 仲裁+延迟+RAM：三个端口同时请求 ----
    a_req_valid = 3'b111;
    a_req[0] = '{addr: 64'h200, we: 1'b0, strb: 8'h00, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    a_req[1] = '{addr: 64'h100, we: 1'b0, strb: 8'h00, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    a_req[2] = '{addr: 64'h300, we: 1'b0, strb: 8'h00, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
    a_rsp_ready = 3'b111;

    // 优先级：PTW(0) 先被接受
    wait (a_req_ready[0]);
    check_ok(!a_req_ready[1] && !a_req_ready[2],
             "同时请求时只应接受最高优先级端口");
    // 响应只回到端口 0
    wait (a_rsp_valid[0]);
    check_ok(!a_rsp_valid[1] && !a_rsp_valid[2], "响应应按端口路由");
    check_ok(a_rsp[0].rdata == 64'd0, "端口 0 读 0x200 应为 0");
    a_req_valid[0] = 1'b0;   // 释放端口 0，让低优先级端口轮转
    @(posedge clk);

    // 数据(1) 其次
    wait (a_req_ready[1]);
    wait (a_rsp_valid[1]);
    a_req_valid[1] = 1'b0;
    @(posedge clk);

    // 取指(2) 最后
    wait (a_req_ready[2]);
    wait (a_rsp_valid[2]);
    a_req_valid[2] = 1'b0;
    wait (!a_rsp_valid[2]);   // 等响应被消费，避免残留响应阻塞下一请求
    @(posedge clk);
    a_req_valid = '0;

    // ---- 延迟(1)+RAM 往返延迟：接受后 2 拍出现响应 ----
    begin
      automatic int latency = 0;
      a_rsp_ready = 3'b000;    // 先不消费，等响应出现再计时
      a_req_valid = 3'b100;   // 仅取指端口
      a_req[2] = '{addr: 64'h108, we: 1'b0, strb: 8'h00, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
      wait (a_req_ready[2]);
      while (!a_rsp_valid[2]) begin
        tick(1);
        latency++;
      end
      // SRAM 1 拍 + delay 1 拍：ready 置位当拍起 3 拍后响应出现
      check_ok(latency == 3,
               $sformatf("延迟模式 1 往返应 3 拍（实际 %0d）", latency));
      a_rsp_ready = 3'b111;
      tick(2);
      a_req_valid = '0;
      tick(2);
    end

    if (errs == 0) begin
      $display("PASS: lcvex_mem_if_tb 全部通过");
      $finish;
    end else begin
      $fatal(1, "FAIL: %0d 处错误", errs);
    end
  end
endmodule
/* verilator lint_on UNUSEDSIGNAL */
