// lcvex_mem_delay.sv
// M1-B：内存延迟注入器（0/1/随机），位于仲裁器与 SRAM 之间，
// 用于验证核心在可变内存延迟下无丢失/重复提交。
//
// DELAY_MODE：
//   0 = 组合直通（0 周期）
//   1 = 响应延迟 1 周期
//   2 = 响应延迟随机 0..RAND_MAX 周期（LFSR，SEED 可复现）
// 单 outstanding：请求被上游接收后，直到响应被主端消费前不再接受新请求。

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */  // DELAY_MODE=0 时 clk/rst_n 未用

module lcvex_mem_delay #(
    parameter int DELAY_MODE = 0,
    parameter int RAND_MAX   = 4,
    parameter logic [7:0] SEED = 8'hA5
) (
    input  logic                clk,
    input  logic                rst_n,
    // 上游（仲裁器）
    input  logic                req_valid,
    input  lcvex_pkg::mem_req_t req,
    output logic                req_ready,
    // 下游（SRAM）
    output logic                req_out_valid,
    output lcvex_pkg::mem_req_t req_out,
    input  logic                req_out_ready,
    // 下游响应（SRAM）
    input  logic                rsp_in_valid,
    input  lcvex_pkg::mem_rsp_t rsp_in,
    output logic                rsp_in_ready,
    // 上游响应（仲裁器）
    output logic                rsp_out_valid,
    output lcvex_pkg::mem_rsp_t rsp_out,
    input  logic                rsp_out_ready,
    // 有界性能 probe：纯组合只读镜像，不参与握手或架构状态。
    output logic                probe_req_pending,
    output logic                probe_rsp_pending,
    output logic [31:0]         probe_delay_count,
    output logic [7:0]          probe_lfsr
);

  import lcvex_pkg::*;

  generate
    if (DELAY_MODE == 0) begin : g_passthrough
      assign req_ready     = req_out_ready;
      assign req_out_valid = req_valid;
      assign req_out       = req;
      assign rsp_in_ready  = rsp_out_ready;
      assign rsp_out_valid = rsp_in_valid;
      assign rsp_out       = rsp_in;
      assign probe_req_pending = 1'b0;
      assign probe_rsp_pending = 1'b0;
      assign probe_delay_count = 32'd0;
      assign probe_lfsr = 8'd0;
    end else begin : g_delayed
      logic        req_pending;
      mem_req_t    req_r;
      logic        rsp_pending;    // 已捕获下游响应、延迟中或等待消费
      mem_rsp_t    rsp_r;
      logic [31:0] delay_cnt;
      logic [7:0]  lfsr;

      assign req_ready     = !req_pending && !rsp_pending;
      assign req_out_valid = req_pending;
      assign req_out       = req_r;
      assign rsp_in_ready  = !rsp_pending;
      // 响应在延迟计数到 0 的周期呈现（捕获当拍起算：mode1 即 +1 周期）
      assign rsp_out_valid = rsp_pending && (delay_cnt == 0);
      assign rsp_out       = rsp_r;
      assign probe_req_pending = req_pending;
      assign probe_rsp_pending = rsp_pending;
      assign probe_delay_count = delay_cnt;
      assign probe_lfsr = lfsr;

      function automatic logic [31:0] next_delay(input logic [7:0] l);
        if (DELAY_MODE == 1) begin
          next_delay = 32'd1;
        end else begin
          next_delay = 32'(l % (RAND_MAX + 1));  // 0..RAND_MAX
        end
      endfunction

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          req_pending   <= 1'b0;
          req_r         <= '0;
          rsp_pending   <= 1'b0;
          rsp_r         <= '0;
          delay_cnt     <= 32'd0;
          lfsr          <= SEED;
        end else begin
          // LFSR：每周期推进（随机延迟可复现）
          lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};

          // 请求：从上游接收 -> 保持到 SRAM 接受
          if (req_valid && req_ready) begin
            req_pending <= 1'b1;
            req_r       <= req;
          end
          if (req_pending && req_out_ready) begin
            req_pending <= 1'b0;
          end

          // 响应：捕获 -> 延迟 -> 保持到主端消费
          if (rsp_pending) begin
            if (rsp_out_valid) begin
              if (rsp_out_ready) begin
                rsp_pending <= 1'b0;
              end
            end else begin
              delay_cnt <= delay_cnt - 1;
            end
          end else if (rsp_in_valid) begin
            rsp_pending <= 1'b1;
            rsp_r       <= rsp_in;
            delay_cnt   <= (DELAY_MODE == 1) ? 32'd0
                                             : next_delay(lfsr);
          end
        end
      end
    end
  endgenerate

endmodule

/* verilator lint_on UNUSEDSIGNAL */
