// lcvex_mmio_fabric_tb.sv
// P6：C++ MMIO fabric / PL031 的独立 SystemVerilog 验证。

`timescale 1ns/1ps

module lcvex_mmio_fabric_tb;
  import lcvex_pkg::*;

  logic clk, rst_n, retire_valid;
  logic req_valid, req_accept, rsp_valid, rsp_ready, irq;
  mem_req_t req;
  mem_rsp_t rsp;
  int errors = 0;

  lcvex_mmio_fabric dut (
      .clk, .rst_n, .retire_valid, .req_valid, .req, .req_accept,
      .rsp_valid, .rsp, .rsp_ready, .irq
  );

  always #5 clk = ~clk;

  task automatic check_ok(input logic cond, input string msg);
    if (!cond) begin
      $display("FAIL: %s", msg);
      errors++;
    end
  endtask

  task automatic access(input logic [63:0] addr, input logic we,
                        input logic [7:0] strb, input logic [63:0] wdata,
                        output mem_rsp_t result);
    req_valid = 1'b1;
    req = '{addr: addr, we: we, strb: strb, wdata: wdata,
            maint: MAINT_NONE, bypass: 1'b1};
    wait (req_accept);
    @(posedge clk);
    req_valid = 1'b0;
    wait (rsp_valid);
    result = rsp;
    @(posedge clk);
  endtask

  mem_rsp_t result;
  initial begin
    $display("=== lcvex_mmio_fabric_tb: PL031 C++ fabric ===");
    clk = 1'b0;
    rst_n = 1'b0;
    retire_valid = 1'b0;
    req_valid = 1'b0;
    req = '0;
    rsp_ready = 1'b1;
    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // QEMU runner 固定 -rtc base=2000-01-01T00:00:00,clock=vm。
    access(64'h0901_0000, 1'b0, 8'h0f, 64'd0, result);
    check_ok(!result.fault && result.rdata[31:0] == 32'd946684800,
             "PL031 DR 复位值应为固定 RTC base");
    access(64'h0901_0fe0, 1'b0, 8'hff, 64'd0, result);
    check_ok(!result.fault && result.rdata == 64'h0000_0010_0000_0031,
             "PL031 PID0/PID1 应与 QEMU 一致");
    access(64'h0901_0ff0, 1'b0, 8'hff, 64'd0, result);
    check_ok(!result.fault && result.rdata == 64'h0000_00f0_0000_000d,
             "PL031 CID0/CID1 应与 QEMU 一致");
    access(64'h0901_000c, 1'b0, 8'h0f, 64'd0, result);
    check_ok(!result.fault && result.rdata[31:0] == 32'd1,
             "PL031 CR 应恒为 enable");

    // LR 改变数据读值；MR=DR + IMSC=1 在同一虚拟秒触发一次 alarm。
    access(64'h0901_0008, 1'b1, 8'h0f, 64'h0000_0000_1234_5678, result);
    access(64'h0901_0000, 1'b0, 8'h0f, 64'd0, result);
    check_ok(!result.fault && result.rdata[31:0] == 32'h1234_5678,
             "PL031 LR 写后 DR 应更新");
    access(64'h0901_0010, 1'b1, 8'h0f, 64'h1, result);
    access(64'h0901_0004, 1'b1, 8'h0f, 64'h1234_5678, result);
    access(64'h0901_0014, 1'b0, 8'h0f, 64'd0, result);
    check_ok(!result.fault && result.rdata[0] && irq,
             "PL031 同秒 MR 应置 RIS 与 IRQ");
    access(64'h0901_001c, 1'b1, 8'h0f, 64'h1, result);
    access(64'h0901_0018, 1'b0, 8'h0f, 64'd0, result);
    check_ok(!result.fault && !result.rdata[0] && !irq,
             "PL031 ICR 应清 MIS，已触发 alarm 不得重复置位");

    // 已分派到 fabric 而尚无模型的设备必须可复现地回 external fault。
    access(64'h0902_0000, 1'b0, 8'h0f, 64'd0, result);
    check_ok(result.fault, "未建模 fw_cfg 地址必须回 fault");

    if (errors == 0) begin
      $display("PASS: lcvex_mmio_fabric_tb 全部通过");
      $finish;
    end else begin
      $fatal(1, "FAIL: %0d 处错误", errors);
    end
  end
endmodule
