// lcvex_pl061_tb.sv
// P6：QEMU virt PL061 GPIO @0x09030000 的定向单元测试。

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */

module lcvex_pl061_tb;
  import lcvex_pkg::*;

  logic clk, rst_n;
  logic req_valid, req_accept;
  mem_req_t req;
  logic rsp_valid, rsp_ready;
  mem_rsp_t rsp;
  logic irq;
  int errors = 0;

  lcvex_pl061 dut (
      .clk, .rst_n, .req_valid, .req, .req_accept,
      .rsp_valid, .rsp, .rsp_ready, .irq
  );

  always #5 clk = ~clk;

  task automatic check_ok(input logic cond, input string msg);
    if (!cond) begin
      $display("FAIL: %s", msg);
      errors++;
    end
  endtask

  task automatic mmio_read(input logic [11:0] off, output logic [31:0] data);
    req_valid = 1'b1;
    req = '{addr: 64'h0903_0000 + 64'(off), we: 1'b0, strb: 8'h0f,
            wdata: 64'd0, maint: MAINT_NONE, bypass: 1'b1};
    wait (req_accept);
    @(posedge clk);
    req_valid = 1'b0;
    wait (rsp_valid);
    data = rsp.rdata[31:0];
    @(posedge clk);
  endtask

  task automatic mmio_write(input logic [11:0] off, input logic [31:0] data);
    req_valid = 1'b1;
    req = '{addr: 64'h0903_0000 + 64'(off), we: 1'b1, strb: 8'h0f,
            wdata: {32'd0, data}, maint: MAINT_NONE, bypass: 1'b1};
    wait (req_accept);
    @(posedge clk);
    req_valid = 1'b0;
    wait (rsp_valid);
    @(posedge clk);
  endtask

  logic [31:0] value;
  initial begin
    $display("=== lcvex_pl061_tb: QEMU virt PL061 GPIO ===");
    clk = 1'b0;
    rst_n = 1'b0;
    req_valid = 1'b0;
    req = '0;
    rsp_ready = 1'b1;
    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // QEMU virt 设置 pull-down=0xff；复位输入/方向/中断全为 0。
    mmio_read(12'h3fc, value);
    check_ok(value == 32'd0, "复位 data aperture 应为 0");
    mmio_read(12'h400, value);
    check_ok(value == 32'd0, "GPIO_DIR 复位应为 0");
    mmio_read(12'h418, value);
    check_ok(value == 32'd0 && !irq, "GPIO_MIS/IRQ 复位应为 0");

    // data aperture 的地址 mask 与方向 mask 都应生效。
    mmio_write(12'h400, 32'h0f);
    mmio_write(12'h3fc, 32'h03);
    mmio_read(12'h3fc, value);
    check_ok(value == 32'h03, "GPIO data 输出位应按方向写读");
    mmio_read(12'h00c, value);  // mask=3，只读低两引脚
    check_ok(value == 32'h03, "GPIO data aperture mask 应生效");

    // QEMU pl061_id[]：Peripheral ID 和 PrimeCell ID。
    mmio_read(12'hfe0, value); check_ok(value == 32'h61, "PID0 应为 0x61");
    mmio_read(12'hfe4, value); check_ok(value == 32'h10, "PID1 应为 0x10");
    mmio_read(12'hfe8, value); check_ok(value == 32'h04, "PID2 应为 0x04");
    mmio_read(12'hff0, value); check_ok(value == 32'h0d, "CID0 应为 0x0d");
    mmio_read(12'hffc, value); check_ok(value == 32'hb1, "CID3 应为 0xb1");

    if (errors == 0) begin
      $display("PASS: lcvex_pl061_tb 全部通过");
      $finish;
    end else begin
      $fatal(1, "FAIL: %0d 处错误", errors);
    end
  end
endmodule
