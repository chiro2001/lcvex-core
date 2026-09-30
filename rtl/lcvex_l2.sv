// lcvex_l2.sv
// M2：统一 L2 缓存（I/D 共享，2-way 组相联，LRU 替换）。
//
// 固定参数：64 B line、256 组 x 2 way = 32 KiB，物理地址
// tag/index/offset，单阻塞 miss。上游接仲裁器（PTW/I-L1/D-L1 的请求），
// 下游接延迟注入器/SRAM。读写均走 M1-B 协议：
//   - 读命中 1 拍返回（按请求偏移 rotate8）；未命中从 LRU way 替换并
//     8 次 8B 下游读填行；
//   - 写通：下游写完成后才响应；行命中同步更新，未命中不分配；
//   - 下游 fault 上抛，未完成填行/写通作废对应行。
//   - Device/不可缓存（M2-4c）：u_req.bypass=1 时直通下游、不分配不更新。

`timescale 1ns/1ps

module lcvex_l2 #(
    parameter int LINE_BYTES = 64,
    parameter int SETS       = 256,
    parameter int WAYS       = 2
) (
    input  logic                clk,
    input  logic                rst_n,
    // 上游（仲裁器）
    input  logic                u_req_valid,
    input  lcvex_pkg::mem_req_t u_req,
    output logic                u_req_ready,
    output logic                u_rsp_valid,
    output lcvex_pkg::mem_rsp_t u_rsp,
    input  logic                u_rsp_ready,
    // 下游（延迟注入器 / SRAM）
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
  localparam int WAY_W = $clog2(WAYS);
  localparam int TAG_W = 64 - (IDX_W + OFF_W);   // tag 位宽（不含 index/off）

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
  logic    [IDX_W-1:0] idx_r;
  logic    [TAG_W-1:0] tag_r;
  logic    [OFF_W-1:0] off_r;
  logic    [WAY_W-1:0] way_r;         // 本次访问选中的 way
  logic    [2:0]       refill_cnt;
  logic                refill_fault;
  logic                write_hit_r;   // 本次写是否命中（fault 时行一致性）
  logic                resp_rdata_ok;
  logic [63:0]         rsp_data_r;

  logic        valid[SETS][WAYS];
  logic [TAG_W-1:0] tag[SETS][WAYS];
  logic [7:0]  data[SETS * WAYS * LINE_BYTES];
  logic        mru[SETS];             // 1=way1 最近使用（2-way LRU）

  // ---- 命中/替换（组合）----
  logic [IDX_W-1:0] idx_comb;
  logic hit_way0, hit_way1, hit;
  logic [WAY_W-1:0] sel_way, repl_way;
  assign idx_comb = u_req.addr[IDX_W+OFF_W-1:OFF_W];
  assign hit_way0 = valid[idx_comb][0] &&
                    (tag[idx_comb][0] == u_req.addr[63:OFF_W+IDX_W]);
  assign hit_way1 = valid[idx_comb][1] &&
                    (tag[idx_comb][1] == u_req.addr[63:OFF_W+IDX_W]);
  assign hit = hit_way0 || hit_way1;
  assign sel_way = hit_way1 ? 1'b1 : 1'b0;
  assign repl_way = mru[idx_comb] ? 1'b0 : 1'b1;  // 替换最近未使用的 way

  // 读行内 8 字节（chunk 为块索引，即 off[5:3]）
  function automatic logic [63:0] line_read(
      input logic [IDX_W-1:0] set,
      input logic [WAY_W-1:0] way,
      input logic [OFF_W-1:3] chunk);
    logic [63:0] v;
    for (int i = 0; i < 8; i++) begin
      v[i*8 +: 8] = data[32'(set) * (WAYS * LINE_BYTES) +
                          32'(way) * LINE_BYTES + 32'(chunk) * 8 + i];
    end
    return v;
  endfunction

  // 把 8 字节块按请求偏移 off[2:0] 字节数右旋，使请求字节落在低位
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
      way_r <= '0;
      refill_cnt <= 3'd0;
      refill_fault <= 1'b0;
      write_hit_r <= 1'b0;
      resp_rdata_ok <= 1'b0;
      rsp_data_r <= 64'd0;
      for (int s = 0; s < SETS; s++) begin
        mru[s] <= 1'b0;
        for (int w = 0; w < WAYS; w++) begin
          valid[s][w] <= 1'b0;
          tag[s][w] <= '0;
        end
      end
    end else begin
      case (state)
        S_IDLE: begin
          if (u_req_valid) begin
            u_req_r <= u_req;
            idx_r   <= u_req.addr[IDX_W+OFF_W-1:OFF_W];
            tag_r   <= u_req.addr[63:OFF_W+IDX_W];
            off_r   <= u_req.addr[OFF_W-1:0];
            refill_fault <= 1'b0;
            if (u_req.bypass) begin
              // Device/不可缓存：直通下游（读/写均不分配、不更新行）
              state <= S_BYPASS;
            end else if (u_req.we) begin
              write_hit_r <= hit;
              if (hit) begin
                way_r <= sel_way;
              end
              if (hit) begin
                for (int i = 0; i < 8; i++) begin
                  if (u_req.strb[i]) begin
                    data[32'(idx_comb) * (WAYS * LINE_BYTES) +
                         32'(sel_way) * LINE_BYTES +
                         32'(u_req.addr[OFF_W-1:0]) + i] <=
                        u_req.wdata[i*8 +: 8];
                  end
                end
                mru[idx_comb] <= sel_way;
              end
              state <= S_WRITE;
            end else if (hit) begin
              rsp_data_r <= rotate8(
                  line_read(idx_comb, sel_way, u_req.addr[OFF_W-1:3]),
                  u_req.addr[2:0]);
              resp_rdata_ok <= 1'b1;
              mru[idx_comb] <= sel_way;
              state <= S_RSP;
            end else begin
              way_r <= repl_way;
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
              valid[idx_r][way_r] <= 1'b0;
              resp_rdata_ok <= 1'b0;
              state <= S_RSP;
            end else begin
              for (int i = 0; i < 8; i++) begin
                data[32'(idx_r) * (WAYS * LINE_BYTES) +
                     32'(way_r) * LINE_BYTES +
                     32'(refill_cnt) * 8 + i] <=
                    d_rsp.rdata[i*8 +: 8];
              end
              if (refill_cnt == off_r[OFF_W-1:3]) begin
                rsp_data_r   <= rotate8(d_rsp.rdata, off_r[2:0]);
                resp_rdata_ok <= 1'b1;
              end
              if (refill_cnt == 3'(REFILL_REQS - 1)) begin
                valid[idx_r][way_r] <= 1'b1;
                tag[idx_r][way_r]   <= tag_r;
                mru[idx_r]          <= way_r;
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
              if (write_hit_r) begin
                valid[idx_r][way_r] <= 1'b0;  // 写通被拒：行与内存不一致
              end
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
