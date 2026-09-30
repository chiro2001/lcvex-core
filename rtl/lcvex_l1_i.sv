// lcvex_l1_i.sv
// M2：I-L1 指令缓存（只读，直接映射，物理地址）。
// 与 lcvex_l1_d 对称但无写路径：64 B line / 64 组（4 KiB）、单阻塞
// miss、读命中 1 拍返回、未命中 8 次 8B 下游读填整行后返回。
// 上游（core.imem）与下游（arb 端口 2）均走 M1-B 协议。
// M2-4b：维护请求（u_req.maint）按 PA 失效单行（MAINT_IC_IVAU）或整表
// 失效（MAINT_IC_IALLU），直接响应、不下发下游（L2 写通、行与 SRAM
// 一致，无需动作）。
// M2-4c：u_req.bypass=1（Device/不可缓存）时直通下游读、不分配行。

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */  // 只读缓存不使用 u_req 的写字段
module lcvex_l1_i #(
    parameter int LINE_BYTES = 64,
    parameter int SETS       = 64
) (
    input  logic                clk,
    input  logic                rst_n,
    // 上游（core.imem）
    input  logic                u_req_valid,
    input  lcvex_pkg::mem_req_t u_req,
    output logic                u_req_ready,
    output logic                u_rsp_valid,
    output lcvex_pkg::mem_rsp_t u_rsp,
    input  logic                u_rsp_ready,
    // 下游（arb 端口 2）
    output logic                d_req_valid,
    output lcvex_pkg::mem_req_t d_req,
    input  logic                d_req_ready,
    input  logic                d_rsp_valid,
    input  lcvex_pkg::mem_rsp_t d_rsp,
    output logic                d_rsp_ready,
    // Read-only performance observation. These are pure combinational views;
    // they add no architectural/cache state and have no reset value.
    output logic                perf_hit,
    output logic                perf_refill_beat
);

  import lcvex_pkg::*;

  localparam int IDX_W = $clog2(SETS);
  localparam int OFF_W = $clog2(LINE_BYTES);
  localparam int REFILL_REQS = LINE_BYTES / 8;

  typedef enum logic [2:0] {
    S_IDLE,
    S_REFILL,
    S_REFILL_WAIT,
    S_BYPASS,
    S_BYPASS_WAIT,
    S_RSP
  } state_t;

  state_t state;
  logic    [IDX_W-1:0] idx_r;
  logic    [63:12]     tag_r;
  logic    [OFF_W-1:0] off_r;
  logic    [2:0]       refill_cnt;
  logic                refill_fault;
  logic [63:0]         rsp_data_r;

  logic        valid[SETS];
  logic [63:12] tag[SETS];
  logic [7:0]  data[SETS * LINE_BYTES];

  logic hit;
  logic [IDX_W-1:0] idx_comb;
  assign idx_comb = u_req.addr[IDX_W+OFF_W-1:OFF_W];
  assign hit = valid[idx_comb] && (tag[idx_comb] == u_req.addr[63:12]);

  // 读行内 8 字节（chunk 为块索引，即 off[5:3]）
  function automatic logic [63:0] line_read(
      input logic [IDX_W-1:0] set,
      input logic [OFF_W-1:3] chunk);
    logic [63:0] v;
    for (int i = 0; i < 8; i++) begin
      v[i*8 +: 8] = data[32'(set) * LINE_BYTES + 32'(chunk) * 8 + i];
    end
    return v;
  endfunction

  // 把 8 字节块按请求偏移 off6[2:0] 字节数右旋，使请求字节落在低位
  function automatic logic [63:0] rotate8(
      input logic [63:0] chunk,
      input logic [2:0]  off_low);
    logic [63:0] v;
    for (int b = 0; b < 8; b++) begin
      v[b*8 +: 8] = chunk[((b + 32'(off_low)) % 8) * 8 +: 8];
    end
    rotate8 = v;
  endfunction

  assign u_req_ready = (state == S_IDLE);
  assign d_rsp_ready = (state == S_REFILL_WAIT) || (state == S_BYPASS_WAIT);
  assign d_req_valid = (state == S_REFILL) || (state == S_BYPASS);
  assign d_req = (state == S_BYPASS)
      ? u_req
      : '{addr: {tag_r, idx_r, 6'd0} + {58'd0, refill_cnt, 3'd0},
         we: 1'b0, strb: 8'h00, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};

  // Qualification with the existing upstream valid/ready/request fields is
  // intentionally left to the enclosing observation layer.
  assign perf_hit = hit;
  assign perf_refill_beat = d_req_valid && d_req_ready &&
                            (state == S_REFILL);

  assign u_rsp_valid = (state == S_RSP);
  assign u_rsp.rdata = rsp_data_r;
  assign u_rsp.fault = refill_fault;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE;
      idx_r <= '0;
      tag_r <= '0;
      off_r <= '0;
      refill_cnt <= 3'd0;
      refill_fault <= 1'b0;
      rsp_data_r <= 64'd0;
      for (int s = 0; s < SETS; s++) begin
        valid[s] <= 1'b0;
        tag[s] <= '0;
      end
    end else begin
      case (state)
        S_IDLE: begin
          if (u_req_valid) begin
            refill_fault <= 1'b0;
            if (u_req.bypass) begin
              // Device/不可缓存：直通下游读，不分配行
              state <= S_BYPASS;
            end else if (u_req.maint == MAINT_IC_IALLU) begin
              // 整表失效：清空全部有效位，直接响应（无下游流量）
              for (int s = 0; s < SETS; s++) begin
                valid[s] <= 1'b0;
              end
              rsp_data_r <= 64'd0;
              state <= S_RSP;
            end else if (u_req.maint == MAINT_IC_IVAU) begin
              // 单行失效：按 PA 的组索引清有效位（tag 不匹配的行本就不命中）
              valid[u_req.addr[IDX_W+OFF_W-1:OFF_W]] <= 1'b0;
              rsp_data_r <= 64'd0;
              state <= S_RSP;
            end else begin
              idx_r <= u_req.addr[IDX_W+OFF_W-1:OFF_W];
              tag_r <= u_req.addr[63:12];
              off_r <= u_req.addr[OFF_W-1:0];
              if (hit) begin
              rsp_data_r <= rotate8(
                  line_read(idx_comb, u_req.addr[OFF_W-1:3]),
                  u_req.addr[2:0]);
                state <= S_RSP;
              end else begin
                refill_cnt <= 3'd0;
                state <= S_REFILL;
              end
            end
          end
        end

        S_REFILL: begin
          if (d_req_ready) begin
            state <= S_REFILL_WAIT;
          end
        end

        S_REFILL_WAIT: begin
          if (d_rsp_valid) begin
            if (d_rsp.fault) begin
              refill_fault <= 1'b1;
              valid[idx_r] <= 1'b0;   // 填行失败：行作废，向上游报 fault
              rsp_data_r <= 64'd0;
              state <= S_RSP;
            end else begin
              for (int i = 0; i < 8; i++) begin
                data[idx_r * LINE_BYTES + refill_cnt*8 + i] <=
                    d_rsp.rdata[i*8 +: 8];
              end
              // 捕获包含请求偏移的 8 字节（行写入结算前读旧值有竞争）
              if (refill_cnt == off_r[OFF_W-1:3]) begin
                rsp_data_r <= rotate8(d_rsp.rdata, off_r[2:0]);
              end
              if (refill_cnt == 3'(REFILL_REQS - 1)) begin
                valid[idx_r] <= 1'b1;
                tag[idx_r]   <= tag_r;
                state <= S_RSP;
              end else begin
                refill_cnt <= refill_cnt + 1;
                state <= S_REFILL;
              end
            end
          end
        end

        S_BYPASS: begin
          if (d_req_ready) begin
            state <= S_BYPASS_WAIT;
          end
        end

        S_BYPASS_WAIT: begin
          if (d_rsp_valid) begin
            rsp_data_r    <= d_rsp.rdata;
            refill_fault  <= d_rsp.fault;
            state <= S_RSP;
          end
        end

        S_RSP: begin
          if (u_rsp_ready) begin
            state <= S_IDLE;
          end
        end
        default: state <= S_IDLE;
      endcase
    end
  end

  // ===== M2-5 Gate D：握手 SVA =====
  /* verilator lint_off SYNCASYNCNET */  // disable iff 与异步复位共存
  // 单 outstanding：响应期间不接受新请求
  assert property (@(posedge clk) disable iff (!rst_n)
      u_req_ready |-> !u_rsp_valid);
  // 下游响应被消费时必然处于等待响应状态（读/旁路）
  assert property (@(posedge clk) disable iff (!rst_n)
      (d_rsp_valid && d_rsp_ready) |->
          (state inside {S_REFILL_WAIT, S_BYPASS_WAIT}));
  // 维护请求被接受后下一拍直接响应（无下游流量）
  assert property (@(posedge clk) disable iff (!rst_n)
      (u_req_valid && u_req_ready && u_req.maint != MAINT_NONE) |=>
          (state == S_RSP));
  // IC IVAU 接受后目标行失效（无缓存命中残留）
  assert property (@(posedge clk) disable iff (!rst_n)
      (u_req_valid && u_req_ready && u_req.maint == MAINT_IC_IVAU) |=>
          !valid[idx_r]);
  /* verilator lint_on SYNCASYNCNET */

endmodule
