// lcvex_mem_ram.sv
// M1-B：1-cycle 同步 RAM（默认 128 MiB，QEMU virt 布局）的 request/response 包装。
//
// 协议（见 lcvex_pkg mem_req_t/mem_rsp_t）：
//   - req_valid && req_accept：请求被接收（req_accept=!rsp_pending，
//     单 outstanding）；读在接收后 1 周期返回数据，写在该拍完成副作用；
//   - rsp_valid 从接收后下一拍起保持，直到 rsp_ready 消费（背压保持）；
//   - 地址越出 [SRAM_BASE, SRAM_BASE+DEPTH) 返回 rsp_fault（不执行访问）。
// 该模块与未来 Cache、lcvex_mem_delay（延迟注入）共享同一接口。

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */  // prog_addr 高位未用（越界已由 fault 检查）
/* verilator lint_off UNSIGNED */      // SRAM_BASE=0 实例的常量比较为合法简并
module lcvex_mem_ram #(
    parameter int  DEPTH     = 1 << 27,   // 字节数（默认 128 MiB，QEMU virt RAM）
    parameter logic [63:0] SRAM_BASE = 64'h0000_0000_4000_0000
) (
    input  logic                clk,
    input  logic                rst_n,
    // 请求（主端 -> 从端）
    input  logic                req_valid,
    input  lcvex_pkg::mem_req_t req,
    output logic                req_accept,
    // 响应（从端 -> 主端）
    output logic                rsp_valid,
    output lcvex_pkg::mem_rsp_t rsp,
    input  logic                rsp_ready,
    // 程序加载口（复位期间由测试写入，绕过请求路径）
    input  logic                prog_we,
    input  logic [63:0]         prog_addr,
    input  logic [7:0]          prog_strb,
    input  logic [63:0]         prog_wdata,
    // P6 调试读口（组合异步读，锁步失败诊断用）
    input  logic [31:0]         dbg_addr,
    output logic [63:0]         dbg_rdata
);

  import lcvex_pkg::*;

  localparam int AW = $clog2(DEPTH);
  logic [7:0] sram[DEPTH];

  logic        rsp_pending;   // 已接收请求、响应未消费
  logic [63:0] rdata_r;
  logic        fault_r;

  // 请求访问的最高字节偏移（按 strb 字节使能计算）
  function automatic logic [2:0] hi_byte(input logic [7:0] s);
    for (int i = 7; i >= 0; i--) begin
      if (s[i]) return i[2:0];
    end
    return 3'd0;
  endfunction

  assign req_accept = req_valid && !rsp_pending;
  assign rsp_valid  = rsp_pending;
  assign rsp.rdata  = rdata_r;
  assign rsp.fault  = fault_r;
  always_ff @(posedge clk) begin
    dbg_rdata <= {sram[AW'(dbg_addr) + AW'(7)],
                  sram[AW'(dbg_addr) + AW'(6)],
                  sram[AW'(dbg_addr) + AW'(5)],
                  sram[AW'(dbg_addr) + AW'(4)],
                  sram[AW'(dbg_addr) + AW'(3)],
                  sram[AW'(dbg_addr) + AW'(2)],
                  sram[AW'(dbg_addr) + AW'(1)],
                  sram[AW'(dbg_addr) + AW'(0)]};
  end

  initial begin
    for (int i = 0; i < DEPTH; i++) begin
      sram[i] = 8'h00;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    // 程序加载：复位期间也允许（测试在 rst_n=0 时写入镜像）
    if (prog_we) begin
      for (int i = 0; i < 8; i++) begin
        if (prog_strb[i]) begin
          sram[prog_addr[AW-1:0] + AW'(i)] <= prog_wdata[i*8 +: 8];
        end
      end
    end
    if (!rst_n) begin
      rsp_pending <= 1'b0;
      rdata_r     <= 64'd0;
      fault_r     <= 1'b0;
    end else begin
      if (req_accept) begin
        // 地址越界：不执行访问，响应 fault
        // 越界（低于基址/高于基址+DEPTH）或按 strb 跨度跨出顶端 -> fault
        fault_r     <= (req.addr < SRAM_BASE) ||
                       (req.addr >= (SRAM_BASE + 64'(DEPTH))) ||
                       ((64'(req.addr[AW-1:0]) + 64'(hi_byte(req.strb))) >=
                        64'(DEPTH));
        rsp_pending <= 1'b1;
        if (req.we && !((req.addr < SRAM_BASE) ||
                        (req.addr >= (SRAM_BASE + 64'(DEPTH))) ||
                        ((64'(req.addr[AW-1:0]) +
                          64'(hi_byte(req.strb))) >= 64'(DEPTH)))) begin
          for (int i = 0; i < 8; i++) begin
            if (req.strb[i]) begin
              sram[req.addr[AW-1:0] + AW'(i)] <= req.wdata[i*8 +: 8];
            end
          end
        end
        if (!req.we) begin
          // 读：接收后下一拍输出 ram[addr]
          for (int i = 0; i < 8; i++) begin
            rdata_r[i*8 +: 8] <= sram[req.addr[AW-1:0] + AW'(i)];
          end
        end
      end
      if (rsp_pending && rsp_ready) begin
        rsp_pending <= 1'b0;   // 响应被消费
      end
    end
  end

endmodule
