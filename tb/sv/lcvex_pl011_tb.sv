// lcvex_pl011_tb.sv
// PL011 MMIO 模型单元测试（QEMU 11.1.0 pl011.c 语义，探针实证见 handoff 036）。
// 运行：make sim-sv-pl011

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */
module lcvex_pl011_tb;
  import lcvex_pkg::*;

  logic        clk;
  logic        rst_n;
  logic        req_valid;
  mem_req_t    req;
  logic        req_accept;
  logic        rsp_valid;
  mem_rsp_t    rsp;
  logic        rsp_ready;
  logic        tx_valid;
  logic [7:0]  tx_char;

  lcvex_pl011 uart (
      .clk        (clk),
      .rst_n      (rst_n),
      .req_valid  (req_valid),
      .req        (req),
      .req_accept (req_accept),
      .rsp_valid  (rsp_valid),
      .rsp        (rsp),
      .rsp_ready  (rsp_ready),
      .tx_valid   (tx_valid),
      .tx_char    (tx_char)
  );

  always #5 clk = ~clk;  // 100 MHz

  int errs = 0;
  mem_rsp_t rsp_o;
  logic tx_sampled;
  logic [7:0] tx_char_sampled;

  task automatic check_ok(input logic cond, input string msg);
    if (!cond) begin
      $display("FAIL: %s", msg);
      errs++;
    end
  endtask

  task automatic tick(input int n = 1);
    repeat (n) @(posedge clk);
  endtask

  // 一次 32 位字访问（addr 为字节地址，须 4 对齐）
  task automatic word_access(input logic [63:0] addr, input logic we,
                             input logic [31:0] wdata, output mem_rsp_t o);
    req_valid = 1'b1;
    req = '{addr: addr, we: we, strb: we ? 8'h0F : 8'h00,
           wdata: {32'd0, wdata}, maint: MAINT_NONE, bypass: 1'b1};
    rsp_ready = 1'b1;
    wait (req_accept);
    @(posedge clk);
    req_valid = 1'b0;
    wait (rsp_valid);
    o = rsp;
    // TX 脉冲在响应有效当拍仍保持（下一拍撤销），在此采样
    tx_sampled = tx_valid;
    tx_char_sampled = tx_char;
    @(posedge clk);
  endtask

  // 一次 8 字节访问
  task automatic dword_access(input logic [63:0] addr, input logic we,
                              input logic [63:0] wdata, output mem_rsp_t o);
    req_valid = 1'b1;
    req = '{addr: addr, we: we, strb: we ? 8'hFF : 8'h00,
           wdata: wdata, maint: MAINT_NONE, bypass: 1'b1};
    rsp_ready = 1'b1;
    wait (req_accept);
    @(posedge clk);
    req_valid = 1'b0;
    wait (rsp_valid);
    o = rsp;
    tx_sampled = tx_valid;
    tx_char_sampled = tx_char;
    @(posedge clk);
  endtask

  initial begin
    $display("=== lcvex_pl011_tb: PL011 MMIO 模型单元测试 ===");
    clk = 1'b0;
    rst_n = 1'b0;
    req_valid = 1'b0;
    req = '0;
    rsp_ready = 1'b1;
    tick(2);
    rst_n = 1'b1;
    tick(2);

    // ---- 复位值（QEMU 探针实证）----
    word_access(64'h09000018, 1'b0, 32'd0, rsp_o);   // UARTFR
    check_ok(rsp_o.fault == 0 && rsp_o.rdata[31:0] == 32'h90,
             $sformatf("复位 FR 应为 0x90，实际 0x%h", rsp_o.rdata[31:0]));
    word_access(64'h09000030, 1'b0, 32'd0, rsp_o);   // UARTCR
    check_ok(rsp_o.rdata[31:0] == 32'h300,
             $sformatf("复位 CR 应为 0x300，实际 0x%h", rsp_o.rdata[31:0]));
    word_access(64'h09000034, 1'b0, 32'd0, rsp_o);   // UARTIFLS
    check_ok(rsp_o.rdata[31:0] == 32'h12,
             $sformatf("复位 IFLS 应为 0x12，实际 0x%h", rsp_o.rdata[31:0]));
    word_access(64'h09000000, 1'b0, 32'd0, rsp_o);   // UARTDR
    check_ok(rsp_o.rdata[31:0] == 32'd0, "复位 DR 读应为 0");
    word_access(64'h09000004, 1'b0, 32'd0, rsp_o);   // UARTRSR
    check_ok(rsp_o.rdata[31:0] == 32'd0, "复位 RSR 应为 0");
    word_access(64'h0900003C, 1'b0, 32'd0, rsp_o);   // UARTRIS
    check_ok(rsp_o.rdata[31:0] == 32'd0, "复位 RIS 应为 0");

    // ---- 控制寄存器写读回 ----
    word_access(64'h09000030, 1'b1, 32'h301, rsp_o);  // CR = UARTEN|TXE|RXE
    word_access(64'h09000030, 1'b0, 32'd0, rsp_o);
    check_ok(rsp_o.rdata[31:0] == 32'h301, "CR 写读回");
    word_access(64'h0900002C, 1'b1, 32'h30, rsp_o);   // LCR_H = 8N1
    word_access(64'h0900002C, 1'b0, 32'd0, rsp_o);
    check_ok(rsp_o.rdata[31:0] == 32'h30, "LCR_H 写读回");
    word_access(64'h09000024, 1'b1, 32'h27, rsp_o);   // IBRD
    word_access(64'h09000024, 1'b0, 32'd0, rsp_o);
    check_ok(rsp_o.rdata[31:0] == 32'h27, "IBRD 写读回");
    word_access(64'h09000028, 1'b1, 32'h04, rsp_o);   // FBRD
    word_access(64'h09000028, 1'b0, 32'd0, rsp_o);
    check_ok(rsp_o.rdata[31:0] == 32'h04, "FBRD 写读回");
    // IBRD 掩码 0xFFFF、FBRD 掩码 0x3F
    word_access(64'h09000024, 1'b1, 32'h1_0001, rsp_o);
    word_access(64'h09000024, 1'b0, 32'd0, rsp_o);
    check_ok(rsp_o.rdata[31:0] == 32'h1, "IBRD 掩码 0xFFFF");
    word_access(64'h09000028, 1'b1, 32'h40, rsp_o);
    word_access(64'h09000028, 1'b0, 32'd0, rsp_o);
    check_ok(rsp_o.rdata[31:0] == 32'h0, "FBRD 掩码 0x3F");

    // ---- TX：写 UARTDR -> INT_TX，RIS=0x20，MIS 跟随 IMSC ----
    word_access(64'h09000038, 1'b1, 32'h20, rsp_o);   // IMSC |= INT_TX
    word_access(64'h09000000, 1'b1, 32'h41, rsp_o);   // UARTDR = 'A'
    check_ok(tx_sampled && tx_char_sampled == 8'h41,
             $sformatf("TX 脉冲/字符 0x%h", tx_char_sampled));
    word_access(64'h0900003C, 1'b0, 32'd0, rsp_o);    // RIS
    check_ok(rsp_o.rdata[31:0] == 32'h20,
             $sformatf("TX 后 RIS 应为 0x20，实际 0x%h", rsp_o.rdata[31:0]));
    word_access(64'h09000040, 1'b0, 32'd0, rsp_o);    // MIS
    check_ok(rsp_o.rdata[31:0] == 32'h20, "IMSC=INT_TX 时 MIS=0x20");
    word_access(64'h09000018, 1'b0, 32'd0, rsp_o);    // FR 不变
    check_ok(rsp_o.rdata[31:0] == 32'h90, "TX 后 FR 仍 0x90");

    // ---- ICR 清中断 ----
    word_access(64'h09000044, 1'b1, 32'h20, rsp_o);   // ICR = INT_TX
    word_access(64'h0900003C, 1'b0, 32'd0, rsp_o);
    check_ok(rsp_o.rdata[31:0] == 32'd0, "ICR 后 RIS=0");

    // ---- LBE 回环（FEN=0 -> 深度 1）：TX 数据进 RX FIFO ----
    word_access(64'h0900002C, 1'b1, 32'h00, rsp_o);   // LCR_H = 0（FEN 关）
    word_access(64'h09000030, 1'b1, 32'h381, rsp_o);  // CR |= LBE
    word_access(64'h09000000, 1'b1, 32'h42, rsp_o);   // UARTDR = 'B'
    word_access(64'h09000018, 1'b0, 32'd0, rsp_o);    // FR：RXFF（depth=1）
    check_ok(rsp_o.rdata[31:0] == 32'hC0,
             $sformatf("回环后 FR 应为 0xC0，实际 0x%h", rsp_o.rdata[31:0]));
    word_access(64'h09000000, 1'b0, 32'd0, rsp_o);    // DR 读回 'B'
    check_ok(rsp_o.rdata[31:0] == 32'h42,
             $sformatf("DR 读回应为 0x42，实际 0x%h", rsp_o.rdata[31:0]));
    word_access(64'h09000018, 1'b0, 32'd0, rsp_o);    // FR：RXFE 重新置位
    check_ok(rsp_o.rdata[31:0] == 32'h90, "弹空后 FR=0x90");
    word_access(64'h09000000, 1'b0, 32'd0, rsp_o);    // 空读：残留字节
    check_ok(rsp_o.rdata[31:0] == 32'h42, "空 DR 读返回残留 0x42");
    word_access(64'h09000004, 1'b0, 32'd0, rsp_o);    // RSR 仍 0
    check_ok(rsp_o.rdata[31:0] == 32'd0, "RSR 仍 0");

    // ---- FEN 使能：深度 16，多字节回环 ----
    word_access(64'h0900002C, 1'b1, 32'h70, rsp_o);   // LCR_H = FEN|8N1
    word_access(64'h09000000, 1'b1, 32'h31, rsp_o);   // '1'
    word_access(64'h09000000, 1'b1, 32'h32, rsp_o);   // '2'
    word_access(64'h09000000, 1'b1, 32'h33, rsp_o);   // '3'
    word_access(64'h09000018, 1'b0, 32'd0, rsp_o);    // FR：RXFE=0（非满）
    check_ok(rsp_o.rdata[31:0] == 32'h80,
             $sformatf("FEN 回环 3 字节 FR 应为 0x80，实际 0x%h",
                       rsp_o.rdata[31:0]));
    word_access(64'h09000000, 1'b0, 32'd0, rsp_o);
    check_ok(rsp_o.rdata[31:0] == 32'h31, "FIFO 读 1");
    word_access(64'h09000000, 1'b0, 32'd0, rsp_o);
    check_ok(rsp_o.rdata[31:0] == 32'h32, "FIFO 读 2");
    word_access(64'h09000000, 1'b0, 32'd0, rsp_o);
    check_ok(rsp_o.rdata[31:0] == 32'h33, "FIFO 读 3");

    // ---- 8 字节访问：读 FR 高字为下一个字；写 UARTDR 低字 TX ----
    dword_access(64'h09000018, 1'b0, 64'd0, rsp_o);
    check_ok(rsp_o.rdata == 64'h0000_0000_0000_0090,
             $sformatf("8B 读 FR = {word+1, word}，实际 0x%h", rsp_o.rdata));
    dword_access(64'h09000000, 1'b1, 64'h0000_0000_0000_0058, rsp_o);
    // 低字 -> UARTDR（'X'），高字 -> RSR（ECR 写清零，无副作用）
    check_ok(tx_sampled && tx_char_sampled == 8'h58,
             $sformatf("8B 写 UARTDR TX 字符 0x%h", tx_char_sampled));

    // ---- ID 寄存器 ----
    word_access(64'h09000FE0, 1'b0, 32'd0, rsp_o);
    check_ok(rsp_o.rdata[31:0] == 32'h11, "PeripheralID0");
    word_access(64'h09000FE4, 1'b0, 32'd0, rsp_o);
    check_ok(rsp_o.rdata[31:0] == 32'h10, "PeripheralID1");
    word_access(64'h09000FE8, 1'b0, 32'd0, rsp_o);
    check_ok(rsp_o.rdata[31:0] == 32'h14, "PeripheralID2");
    word_access(64'h09000FEC, 1'b0, 32'd0, rsp_o);
    check_ok(rsp_o.rdata[31:0] == 32'h00, "PeripheralID3");
    word_access(64'h09000FF0, 1'b0, 32'd0, rsp_o);
    check_ok(rsp_o.rdata[31:0] == 32'h0D, "PrimeCellID0");
    word_access(64'h09000FF4, 1'b0, 32'd0, rsp_o);
    check_ok(rsp_o.rdata[31:0] == 32'hF0, "PrimeCellID1");
    word_access(64'h09000FF8, 1'b0, 32'd0, rsp_o);
    check_ok(rsp_o.rdata[31:0] == 32'h05, "PrimeCellID2");
    word_access(64'h09000FFC, 1'b0, 32'd0, rsp_o);
    check_ok(rsp_o.rdata[31:0] == 32'hB1, "PrimeCellID3");

    // ---- 未映射字：读 0、写忽略 ----
    word_access(64'h09000008, 1'b0, 32'd0, rsp_o);
    check_ok(rsp_o.rdata[31:0] == 32'd0, "未映射字读 0");

    if (errs == 0) begin
      $display("PASS: lcvex_pl011_tb 全部通过");
      $finish;
    end else begin
      $fatal(1, "FAIL: %0d 处错误", errs);
    end
  end
endmodule
