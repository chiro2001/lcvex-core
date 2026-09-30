// lcvex_mem_arb.sv
// M1-B：内存端口仲裁器（单 outstanding）。
// 端口优先级：0=PTW（最高）> 1=数据 > 2=取指（最低）。
// 请求被下游接受后进入 in_flight，响应按选中的端口路由回请求方；
// in_flight 期间不再接受新请求（响应消费后恢复）。

`timescale 1ns/1ps

module lcvex_mem_arb #(
    parameter int PORTS = 3
) (
    input  logic                    clk,
    input  logic                    rst_n,
    // 请求端口（0=PTW 1=数据 2=取指）
    input  logic [PORTS-1:0]        req_valid,
    input  lcvex_pkg::mem_req_t [PORTS-1:0] req,
    output logic [PORTS-1:0]        req_ready,
    // 响应端口
    output logic [PORTS-1:0]        rsp_valid,
    output lcvex_pkg::mem_rsp_t [PORTS-1:0] rsp,
    input  logic [PORTS-1:0]        rsp_ready,
    // 下游（SRAM / 延迟注入器）
    output logic                    mem_req_valid,
    output lcvex_pkg::mem_req_t     mem_req,
    input  logic                    mem_req_accept,
    input  logic                    mem_rsp_valid,
    input  lcvex_pkg::mem_rsp_t     mem_rsp,
    output logic                    mem_rsp_ready
);

  import lcvex_pkg::*;

  logic        in_flight;
  logic [$clog2(PORTS)-1:0] sel_r;

  // 优先级编码：取最高优先级的有效请求
  function automatic logic [$clog2(PORTS)-1:0] prio_sel(input logic [PORTS-1:0] v);
    for (int i = 0; i < PORTS; i++) begin
      if (v[i]) return i[$clog2(PORTS)-1:0];  // 最低索引 = 最高优先级
    end
    return '0;
  endfunction

  logic [$clog2(PORTS)-1:0] sel_comb;
  assign sel_comb = prio_sel(req_valid);

  // 空闲且无 in_flight：把最高优先级请求呈现给下游
  assign mem_req_valid = !in_flight && (|req_valid);
  assign mem_req       = req[sel_comb];

  // 请求接受：只有被选中的端口看到 ready
  always_comb begin
    req_ready = '0;
    if (mem_req_valid && mem_req_accept) begin
      req_ready[sel_comb] = 1'b1;
    end
  end

  // 响应：路由到 in_flight 的端口
  always_comb begin
    rsp_valid = '0;
    rsp       = '{PORTS{'0}};
    if (in_flight && mem_rsp_valid) begin
      rsp_valid[sel_r] = 1'b1;
      rsp[sel_r]       = mem_rsp;
    end
  end
  assign mem_rsp_ready = in_flight && mem_rsp_valid && rsp_ready[sel_r];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      in_flight <= 1'b0;
      sel_r     <= '0;
    end else begin
      if (!in_flight && mem_req_valid && mem_req_accept) begin
        in_flight <= 1'b1;
        sel_r     <= sel_comb;
      end
      if (mem_rsp_ready) begin
        in_flight <= 1'b0;
      end
    end
  end

endmodule
