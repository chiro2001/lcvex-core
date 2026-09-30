// lcvex_l1_d.sv
// M2：D-L1 数据缓存（写通 + no-write-allocate，直接映射，物理地址）。
//
// 固定参数（第一版）：64 B line、64 组（4 KiB）、单阻塞 miss、
// PA tag/index/offset。上游（core.dmem）与下游（arb）均走 M1-B 的
// mem_req/mem_rsp valid/ready 协议，因此可插入现有内存路径而不改核心。
//
// 行为：
//   - 读：命中 -> 1 拍后返回 8 字节；未命中 -> 8 次 8B 下游读填整行，
//     再返回（单阻塞 miss，期间不接受新请求）；
//   - 写：写通（立即发下游写，完成后才向上游响应）；行命中时同步更新
//     行内字节（write-allocate-on-hit），未命中不分配；
//   - 下游响应 fault 原样传回上游（核心转为 DABT），未完成的 refill
//     行标记无效。
//   - Device/不可缓存（M2-4c）：u_req.bypass=1 时直通下游、不命中不分配、
//     响应原样传回（读/写均不触碰缓存行）。

`timescale 1ns/1ps

module lcvex_l1_d #(
    parameter int LINE_BYTES = 64,
    parameter int SETS       = 64
) (
    input  logic                clk,
    input  logic                rst_n,
    // 上游（core.dmem）
    input  logic                u_req_valid,
    input  lcvex_pkg::mem_req_t u_req,
    output logic                u_req_ready,
    output logic                u_rsp_valid,
    output lcvex_pkg::mem_rsp_t u_rsp,
    input  logic                u_rsp_ready,
    // 下游（arb 端口 1）
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

  localparam int IDX_W = $clog2(SETS);          // 组索引位宽
  localparam int OFF_W = $clog2(LINE_BYTES);    // 行内偏移位宽
  localparam int REFILL_REQS = LINE_BYTES / 8;  // 每行 8B 读次数

  typedef enum logic [2:0] {
    S_IDLE,
    S_REFILL,
    S_REFILL_WAIT,
    S_WRITE,
    S_WRITE_WAIT,
    S_BYPASS,
    S_BYPASS_WAIT,
    S_RSP
  } state_t;

  state_t state;
  mem_req_t u_req_r;
  logic    [IDX_W-1:0] idx_r;       // 上游请求的组索引（miss 填行用）
  logic    [63:12]     tag_r;       // 上游请求的 tag
  logic    [OFF_W-1:0] off_r;       // 上游请求的行内偏移
  logic    [2:0]       refill_cnt;
  logic                refill_fault;   // 本次填行遇到下游 fault
  logic                resp_rdata_ok;  // 响应数据有效（读路径）
  logic [63:0]         rsp_data_r;

  // 行存储：有效位 + tag + 字节数组（flat，[set*LINE_BYTES + off]）
  logic        valid[SETS];
  logic [63:12] tag[SETS];
  logic [7:0]  data[SETS * LINE_BYTES];

  // 组合：命中判定与命中读数据
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
  assign d_rsp_ready = (state == S_REFILL_WAIT) || (state == S_WRITE_WAIT) ||
                       (state == S_BYPASS_WAIT);

  // 下游请求：refill 读或写通写
  assign d_req_valid = (state == S_REFILL) || (state == S_WRITE) ||
                       (state == S_BYPASS);
  assign d_req = (state == S_WRITE)
      ? u_req_r
      : (state == S_BYPASS)
        ? u_req_r
        : '{addr: {tag_r, idx_r, 6'd0} + {58'd0, refill_cnt, 3'd0},
           we: 1'b0, strb: 8'h00, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};

  // Qualification with the existing upstream valid/ready/request fields is
  // intentionally left to the enclosing observation layer.
  assign perf_hit = hit;
  assign perf_refill_beat = d_req_valid && d_req_ready &&
                            (state == S_REFILL);

  // 上游响应
  assign u_rsp_valid = (state == S_RSP);
  assign u_rsp.rdata = resp_rdata_ok ? rsp_data_r : 64'd0;
  assign u_rsp.fault = refill_fault;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE;
      u_req_r <= '0;
      idx_r <= '0;
      tag_r <= '0;
      off_r <= '0;
      refill_cnt <= 3'd0;
      refill_fault <= 1'b0;
      resp_rdata_ok <= 1'b0;
      rsp_data_r <= 64'd0;
      for (int s = 0; s < SETS; s++) begin
        valid[s] <= 1'b0;
        tag[s] <= '0;
      end
    end else begin
      case (state)
        S_IDLE: begin
          if (u_req_valid) begin
            u_req_r <= u_req;
            idx_r   <= u_req.addr[IDX_W+OFF_W-1:OFF_W];
            tag_r   <= u_req.addr[63:12];
            off_r   <= u_req.addr[OFF_W-1:0];
            refill_fault <= 1'b0;
            if (u_req.bypass) begin
              // Device/不可缓存：直通下游（读/写均不分配、不更新行）
              state <= S_BYPASS;
            end else if (u_req.we) begin
              // 写通：立即发下游写；行命中同步更新（no-write-allocate）
              if (hit) begin
                for (int i = 0; i < 8; i++) begin
                  if (u_req.strb[i]) begin
                    data[32'(u_req.addr[IDX_W+OFF_W-1:0]) + i] <=
                        u_req.wdata[i*8 +: 8];
                  end
                end
              end
              state <= S_WRITE;
            end else if (hit) begin
              // 读命中：下一拍返回
              rsp_data_r <= rotate8(
                  line_read(idx_comb, u_req.addr[OFF_W-1:3]),
                  u_req.addr[2:0]);
              resp_rdata_ok <= 1'b1;
              state <= S_RSP;
            end else begin
              // 读未命中：单阻塞填行
              refill_cnt <= 3'd0;
              state <= S_REFILL;
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
              // 填行失败：整行无效，向上游报 fault
              valid[idx_r] <= 1'b0;
              resp_rdata_ok <= 1'b0;
              state <= S_RSP;
            end else begin
              // 写入行数据（8 字节）
              for (int i = 0; i < 8; i++) begin
                data[idx_r * LINE_BYTES + refill_cnt*8 + i] <=
                    d_rsp.rdata[i*8 +: 8];
              end
              // 捕获包含请求偏移的 8 字节（行写入结算前读旧值有竞争）
              if (refill_cnt == off_r[OFF_W-1:3]) begin
                rsp_data_r   <= rotate8(d_rsp.rdata, off_r[2:0]);
                resp_rdata_ok <= 1'b1;
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

        S_WRITE: begin
          if (d_req_ready) begin
            state <= S_WRITE_WAIT;
          end
        end

        S_WRITE_WAIT: begin
          if (d_rsp_valid) begin
            if (d_rsp.fault) begin
              refill_fault <= 1'b1;
              // 写通被下游拒绝：行内已更新的数据与内存不一致，作废该行
              valid[idx_r] <= 1'b0;
            end
            resp_rdata_ok <= 1'b0;
            state <= S_RSP;
          end
        end

        S_BYPASS: begin
          if (d_req_ready) begin
            state <= S_BYPASS_WAIT;
          end
        end

        S_BYPASS_WAIT: begin
          if (d_rsp_valid) begin
            // 响应原样传回（读数据或写确认；fault 上抛）
            rsp_data_r    <= d_rsp.rdata;
            refill_fault  <= d_rsp.fault;
            resp_rdata_ok <= 1'b1;
            state <= S_RSP;
          end
        end

        S_RSP: begin
          if (u_rsp_ready) begin
            state <= S_IDLE;
            resp_rdata_ok <= 1'b0;
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
  // 下游响应被消费时必然处于等待响应状态（填行/写通/旁路）
  assert property (@(posedge clk) disable iff (!rst_n)
      (d_rsp_valid && d_rsp_ready) |->
          (state inside {S_REFILL_WAIT, S_WRITE_WAIT, S_BYPASS_WAIT}));
  /* verilator lint_on SYNCASYNCNET */

endmodule
