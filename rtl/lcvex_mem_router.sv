// lcvex_mem_router.sv
// M1-B 地址路由：按地址把请求分发到 RAM 或 MMIO（PL011/GIC/PL061），
// 均不命中时回 fault。位于延迟注入器之后，上游为仲裁/L2/延迟链。
//
// 组合转发：请求当拍直达所选从端（与直连 RAM 延迟相同，不引入气泡），
// 仅在接受当拍锁存目标选择用于响应路由；响应保持到上游消费，背压
// 沿 M1-B valid/ready 向上游传播。单 outstanding。

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */
module lcvex_mem_router #(
    parameter logic [63:0] SRAM_BASE = 64'h0000_0000_4000_0000,
    parameter logic [63:0] SRAM_TOP  = 64'h0000_0000_4800_0000,
    parameter logic [63:0] MMIO_BASE = 64'h0000_0000_0900_0000,
    parameter logic [63:0] MMIO_TOP  = 64'h0000_0000_0900_1000,
    parameter logic [63:0] MMIO2_BASE = 64'h0000_0000_0800_0000,
    parameter logic [63:0] MMIO2_TOP  = 64'h0000_0000_0802_1000,
    parameter logic [63:0] MMIO3_BASE = 64'h0000_0000_0903_0000,
    parameter logic [63:0] MMIO3_TOP  = 64'h0000_0000_0903_1000,
    // C++ fabric 地址窗。PL061 的 MMIO3 优先解码，保持原生 RTL。
    parameter logic [63:0] MMIO4_BASE = 64'h0000_0000_0901_0000,
    parameter logic [63:0] MMIO4_TOP  = 64'h0000_0000_0a02_0000,
    parameter logic [63:0] MMIO5_BASE = 64'hffff_ffff_ffff_f000,
    parameter logic [63:0] MMIO5_TOP  = 64'hffff_ffff_ffff_ffff,
    parameter logic [63:0] MMIO6_BASE = 64'hffff_ffff_ffff_f000,
    parameter logic [63:0] MMIO6_TOP  = 64'hffff_ffff_ffff_ffff
) (
    input  logic                clk,
    input  logic                rst_n,
    // 上游（延迟注入器）
    input  logic                req_valid,
    input  lcvex_pkg::mem_req_t req,
    output logic                req_ready,
    output logic                rsp_out_valid,
    output lcvex_pkg::mem_rsp_t rsp_out,
    input  logic                rsp_out_ready,
    // 下游 RAM
    output logic                ram_req_valid,
    output lcvex_pkg::mem_req_t ram_req,
    input  logic                ram_req_accept,
    input  logic                ram_rsp_valid,
    input  lcvex_pkg::mem_rsp_t ram_rsp,
    output logic                ram_rsp_ready,
    // 下游 MMIO
    output logic                mmio_req_valid,
    output lcvex_pkg::mem_req_t mmio_req,
    input  logic                mmio_req_accept,
    input  logic                mmio_rsp_valid,
    input  lcvex_pkg::mem_rsp_t mmio_rsp,
    output logic                mmio_rsp_ready,
    // 下游 MMIO2（GIC）
    output logic                mmio2_req_valid,
    output lcvex_pkg::mem_req_t mmio2_req,
    input  logic                mmio2_req_accept,
    input  logic                mmio2_rsp_valid,
    input  lcvex_pkg::mem_rsp_t mmio2_rsp,
    output logic                mmio2_rsp_ready,
    // 下游 MMIO3（PL061 GPIO）
    output logic                mmio3_req_valid,
    output lcvex_pkg::mem_req_t mmio3_req,
    input  logic                mmio3_req_accept,
    input  logic                mmio3_rsp_valid,
    input  lcvex_pkg::mem_rsp_t mmio3_rsp,
    output logic                mmio3_rsp_ready,
    // 下游 MMIO4（Verilator C++ fabric：PL031/fw_cfg/virtio）
    output logic                mmio4_req_valid,
    output lcvex_pkg::mem_req_t mmio4_req,
    input  logic                mmio4_req_accept,
    input  logic                mmio4_rsp_valid,
    input  lcvex_pkg::mem_rsp_t mmio4_rsp,
    output logic                mmio4_rsp_ready,
    // Board GIC target; unused in the standalone virt/P6 SoC model.
    output logic                mmio5_req_valid,
    output lcvex_pkg::mem_req_t mmio5_req,
    input  logic                mmio5_req_accept,
    input  logic                mmio5_rsp_valid,
    input  lcvex_pkg::mem_rsp_t mmio5_rsp,
    output logic                mmio5_rsp_ready,
    // Read-only board EPCQ memory aperture.
    output logic                mmio6_req_valid,
    output lcvex_pkg::mem_req_t mmio6_req,
    input  logic                mmio6_req_accept,
    input  logic                mmio6_rsp_valid,
    input  lcvex_pkg::mem_rsp_t mmio6_rsp,
    output logic                mmio6_rsp_ready
);

  import lcvex_pkg::*;

  typedef enum logic [2:0] {
    TGT_NONE  = 3'd0,
    TGT_RAM   = 3'd1,
    TGT_MMIO  = 3'd2,
    TGT_MMIO2 = 3'd3,
    TGT_MMIO3 = 3'd4,
    TGT_MMIO4 = 3'd5,
    TGT_MMIO5 = 3'd6,
    TGT_MMIO6 = 3'd7
  } tgt_t;

  logic     busy;    // 响应在途（消费前不再接受新请求）
  tgt_t     tgt_r;   // 接受当拍锁存的目标（响应路由）

  function automatic tgt_t decode_addr(input logic [63:0] a);
    if (a >= SRAM_BASE && a < SRAM_TOP) begin
      decode_addr = TGT_RAM;
    end else if (a >= MMIO_BASE && a < MMIO_TOP) begin
      decode_addr = TGT_MMIO;
    end else if (a >= MMIO2_BASE && a < MMIO2_TOP) begin
      decode_addr = TGT_MMIO2;
    end else if (a >= MMIO3_BASE && a < MMIO3_TOP) begin
      decode_addr = TGT_MMIO3;
    end else if (a >= MMIO4_BASE && a < MMIO4_TOP) begin
      decode_addr = TGT_MMIO4;
    end else if (a >= MMIO5_BASE && a < MMIO5_TOP) begin
      decode_addr = TGT_MMIO5;
    end else if (a >= MMIO6_BASE && a < MMIO6_TOP) begin
      decode_addr = TGT_MMIO6;
    end else begin
      decode_addr = TGT_NONE;
    end
  endfunction

  // 请求：组合转发到所选从端；NONE 直接接受（下一拍回 fault）
  assign ram_req_valid  = req_valid && (decode_addr(req.addr) == TGT_RAM);
  assign ram_req        = req;
  assign mmio_req_valid = req_valid && (decode_addr(req.addr) == TGT_MMIO);
  assign mmio_req       = req;
  assign mmio2_req_valid = req_valid && (decode_addr(req.addr) == TGT_MMIO2);
  assign mmio2_req       = req;
  assign mmio3_req_valid = req_valid && (decode_addr(req.addr) == TGT_MMIO3);
  assign mmio3_req       = req;
  assign mmio4_req_valid = req_valid && (decode_addr(req.addr) == TGT_MMIO4);
  assign mmio4_req       = req;
  assign mmio5_req_valid = req_valid && (decode_addr(req.addr) == TGT_MMIO5);
  assign mmio5_req       = req;
  assign mmio6_req_valid = req_valid && (decode_addr(req.addr) == TGT_MMIO6);
  assign mmio6_req       = req;
  assign req_ready      = !busy &&
      (decode_addr(req.addr) == TGT_RAM  ? ram_req_accept :
       decode_addr(req.addr) == TGT_MMIO ? mmio_req_accept :
       decode_addr(req.addr) == TGT_MMIO2 ? mmio2_req_accept :
       decode_addr(req.addr) == TGT_MMIO3 ? mmio3_req_accept :
       decode_addr(req.addr) == TGT_MMIO4 ? mmio4_req_accept :
       decode_addr(req.addr) == TGT_MMIO5 ? mmio5_req_accept :
       decode_addr(req.addr) == TGT_MMIO6 ? mmio6_req_accept : 1'b1);

  // 响应：按锁存目标路由；NONE 回 fault
  logic rsp_target_valid;
  assign rsp_target_valid = (tgt_r == TGT_RAM)  ? ram_rsp_valid :
                            (tgt_r == TGT_MMIO) ? mmio_rsp_valid :
                            (tgt_r == TGT_MMIO2) ? mmio2_rsp_valid :
                            (tgt_r == TGT_MMIO3) ? mmio3_rsp_valid :
                            (tgt_r == TGT_MMIO4) ? mmio4_rsp_valid :
                            (tgt_r == TGT_MMIO5) ? mmio5_rsp_valid :
                            (tgt_r == TGT_MMIO6) ? mmio6_rsp_valid : 1'b1;
  assign rsp_out_valid = busy && rsp_target_valid;
  assign rsp_out = (tgt_r == TGT_RAM)  ? ram_rsp :
                   (tgt_r == TGT_MMIO) ? mmio_rsp :
                   (tgt_r == TGT_MMIO2) ? mmio2_rsp :
                   (tgt_r == TGT_MMIO3) ? mmio3_rsp :
                   (tgt_r == TGT_MMIO4) ? mmio4_rsp :
                   (tgt_r == TGT_MMIO5) ? mmio5_rsp :
                   (tgt_r == TGT_MMIO6) ? mmio6_rsp :
                   '{rdata: 64'd0, fault: 1'b1};
  assign ram_rsp_ready  = busy && (tgt_r == TGT_RAM)  && rsp_out_ready;
  assign mmio_rsp_ready = busy && (tgt_r == TGT_MMIO) && rsp_out_ready;
  assign mmio2_rsp_ready = busy && (tgt_r == TGT_MMIO2) && rsp_out_ready;
  assign mmio3_rsp_ready = busy && (tgt_r == TGT_MMIO3) && rsp_out_ready;
  assign mmio4_rsp_ready = busy && (tgt_r == TGT_MMIO4) && rsp_out_ready;
  assign mmio5_rsp_ready = busy && (tgt_r == TGT_MMIO5) && rsp_out_ready;
  assign mmio6_rsp_ready = busy && (tgt_r == TGT_MMIO6) && rsp_out_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 1'b0;
      tgt_r <= TGT_NONE;
    end else begin
      if (req_valid && req_ready) begin
        busy <= 1'b1;
        tgt_r <= decode_addr(req.addr);
      end
      if (busy && rsp_out_valid && rsp_out_ready) begin
        busy <= 1'b0;
      end
    end
  end

endmodule
