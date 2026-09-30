// lcvex_mmio_fabric.sv
// P6：Verilator DPI 连接的 C++ MMIO fabric。
//
// 该模块是 M1-B 从端，固定在请求被接受后的下一拍给出响应。地址分派、寄存器
// 状态和未建模设备的错误记录由 sim/mmio/lcvex_mmio_fabric.cc 负责；RTL 仅
// 保留事务时序，因而 Cocotb、SV testbench、microbench 与锁步协调器链接同一
// C++ 模型。retire_valid 是已实际提交的一条指令，用于提供与 QEMU
// `-icount shift=0` 对齐的确定性虚拟时间（1 ns/退休指令）。

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */

module lcvex_mmio_fabric (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                retire_valid,
    input  logic                req_valid,
    input  lcvex_pkg::mem_req_t req,
    output logic                req_accept,
    output logic                rsp_valid,
    output lcvex_pkg::mem_rsp_t rsp,
    input  logic                rsp_ready,
    output logic                irq
);

  import lcvex_pkg::*;

  import "DPI-C" function void lcvex_mmio_fabric_reset();
  import "DPI-C" function void lcvex_mmio_fabric_tick(
      input longint unsigned now_ns);
  import "DPI-C" function void lcvex_mmio_fabric_access(
      input  longint unsigned addr,
      input  bit              we,
      input  byte unsigned    strb,
      input  longint unsigned wdata,
      input  longint unsigned now_ns,
      output longint unsigned rdata,
      output bit              fault,
      output bit              irq_level);

  logic                 rsp_pending;
  logic [63:0]          rdata_r;
  logic                 fault_r;
  logic                 irq_r;
  logic [63:0]          virt_ns_r;
  logic [63:0]          dpi_rdata;
  logic                 dpi_fault;
  logic                 dpi_irq;

  assign req_accept = req_valid && !rsp_pending;
  assign rsp_valid  = rsp_pending;
  assign rsp.rdata  = rdata_r;
  assign rsp.fault  = fault_r;
  assign irq        = irq_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lcvex_mmio_fabric_reset();
      rsp_pending <= 1'b0;
      rdata_r     <= 64'd0;
      fault_r     <= 1'b0;
      irq_r       <= 1'b0;
      virt_ns_r   <= 64'd0;
    end else begin
      if (retire_valid) begin
        virt_ns_r <= virt_ns_r + 64'd1;
        lcvex_mmio_fabric_tick(virt_ns_r + 64'd1);
      end
      if (req_valid && req_accept) begin
        lcvex_mmio_fabric_access(req.addr, req.we, req.strb, req.wdata,
                                 virt_ns_r, dpi_rdata, dpi_fault, dpi_irq);
        rsp_pending <= 1'b1;
        rdata_r     <= dpi_rdata;
        fault_r     <= dpi_fault;
        irq_r       <= dpi_irq;
      end
      if (rsp_pending && rsp_ready) begin
        rsp_pending <= 1'b0;
      end
    end
  end

endmodule
