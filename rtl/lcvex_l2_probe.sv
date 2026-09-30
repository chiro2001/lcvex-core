// lcvex_l2_probe.sv
// B3-L2-WB：单客户端 probe/maintenance 握手桥。
//
// 该模块不包含目录或缓存阵列，只负责把一个上游 probe 请求可靠地
// 转发给 L2，并在下游完成后保持响应直到上游消费。这样 CORE_COUNT=1
// 时 probe 端口仍然有稳定的 source_id/transaction_id/owner/sharer 边界，
// 未来扩核时不需要改变握手语义。

`timescale 1ns/1ps

/* verilator lint_off SYNCASYNCNET */
/* verilator lint_off UNUSEDSIGNAL */

module lcvex_l2_probe #(
    parameter int LINE_BYTES       = 64,
    parameter int CORE_COUNT       = 1,
    parameter int SOURCE_ID_W      = 4,
    parameter int TRANSACTION_ID_W = 8
) (
    input  logic                         clk,
    input  logic                         rst_n,

    // 上游 probe client
    input  logic                         req_valid,
    output logic                         req_ready,
    input  logic [63:0]                  req_addr,
    input  logic [1:0]                   req_cmd,
    input  logic [SOURCE_ID_W-1:0]       req_source_id,
    input  logic [TRANSACTION_ID_W-1:0]  req_transaction_id,
    output logic                         rsp_valid,
    input  logic                         rsp_ready,
    output logic                         rsp_fault,
    output logic                         rsp_hit,
    output logic                         rsp_dirty,
    output logic [LINE_BYTES*8-1:0]      rsp_data,
    output logic [63:0]                  rsp_addr,
    output logic [SOURCE_ID_W-1:0]       rsp_source_id,
    output logic [TRANSACTION_ID_W-1:0]  rsp_transaction_id,
    output logic [CORE_COUNT-1:0]        rsp_owner,
    output logic [CORE_COUNT-1:0]        rsp_sharers,

    // L2 probe endpoint
    output logic                         cache_req_valid,
    input  logic                         cache_req_ready,
    output logic [63:0]                  cache_req_addr,
    output logic [1:0]                   cache_req_cmd,
    output logic [SOURCE_ID_W-1:0]       cache_req_source_id,
    output logic [TRANSACTION_ID_W-1:0]  cache_req_transaction_id,
    input  logic                         cache_rsp_valid,
    output logic                         cache_rsp_ready,
    input  logic                         cache_rsp_fault,
    input  logic                         cache_rsp_hit,
    input  logic                         cache_rsp_dirty,
    input  logic [LINE_BYTES*8-1:0]      cache_rsp_data,
    input  logic [63:0]                  cache_rsp_addr,
    input  logic [SOURCE_ID_W-1:0]       cache_rsp_source_id,
    input  logic [TRANSACTION_ID_W-1:0]  cache_rsp_transaction_id,
    input  logic [CORE_COUNT-1:0]        cache_rsp_owner,
    input  logic [CORE_COUNT-1:0]        cache_rsp_sharers
);

  typedef enum logic [1:0] {
    S_IDLE,
    S_FORWARD,
    S_WAIT,
    S_RESPONSE
  } state_t;

  state_t state;
  logic [63:0]                 addr_r;
  logic [1:0]                  cmd_r;
  logic [SOURCE_ID_W-1:0]      source_id_r;
  logic [TRANSACTION_ID_W-1:0] transaction_id_r;
  logic                        fault_r;
  logic                        hit_r;
  logic                        dirty_r;
  logic [LINE_BYTES*8-1:0]     data_r;
  logic [63:0]                 rsp_addr_r;
  logic [CORE_COUNT-1:0]       owner_r;
  logic [CORE_COUNT-1:0]       sharers_r;

  assign req_ready = rst_n && (state == S_IDLE);
  assign rsp_valid = rst_n && (state == S_RESPONSE);

  assign cache_req_valid          = rst_n && (state == S_FORWARD);
  assign cache_req_addr           = addr_r;
  assign cache_req_cmd            = cmd_r;
  assign cache_req_source_id      = source_id_r;
  assign cache_req_transaction_id = transaction_id_r;
  assign cache_rsp_ready          = rst_n && (state == S_WAIT);

  assign rsp_fault          = fault_r;
  assign rsp_hit            = hit_r;
  assign rsp_dirty          = dirty_r;
  assign rsp_data           = data_r;
  assign rsp_addr           = rsp_addr_r;
  assign rsp_source_id      = source_id_r;
  assign rsp_transaction_id = transaction_id_r;
  assign rsp_owner         = owner_r;
  assign rsp_sharers        = sharers_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state          <= S_IDLE;
      addr_r         <= '0;
      cmd_r          <= '0;
      source_id_r    <= '0;
      transaction_id_r <= '0;
      fault_r        <= 1'b0;
      hit_r          <= 1'b0;
      dirty_r        <= 1'b0;
      data_r         <= '0;
      rsp_addr_r     <= '0;
      owner_r        <= '0;
      sharers_r      <= '0;
    end else begin
      case (state)
        S_IDLE: begin
          if (req_valid && req_ready) begin
            addr_r          <= req_addr;
            cmd_r           <= req_cmd;
            source_id_r     <= req_source_id;
            transaction_id_r <= req_transaction_id;
            state           <= S_FORWARD;
          end
        end

        S_FORWARD: begin
          if (cache_req_valid && cache_req_ready) begin
            state <= S_WAIT;
          end
        end

        S_WAIT: begin
          if (cache_rsp_valid && cache_rsp_ready) begin
            fault_r    <= cache_rsp_fault;
            hit_r      <= cache_rsp_hit;
            dirty_r    <= cache_rsp_dirty;
            data_r     <= cache_rsp_data;
            rsp_addr_r <= cache_rsp_addr;
            owner_r    <= cache_rsp_owner;
            sharers_r  <= cache_rsp_sharers;
            // This bridge has one outstanding request. Preserve the
            // upstream identity instead of allowing a downstream endpoint to
            // rewrite it.
            state      <= S_RESPONSE;
          end
        end

        S_RESPONSE: begin
          if (rsp_valid && rsp_ready) begin
            state <= S_IDLE;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  // 单 probe client：请求、转发和响应均不允许重复/重叠。
  assert property (@(posedge clk) disable iff (!rst_n)
      req_ready |-> !rsp_valid);
  assert property (@(posedge clk) disable iff (!rst_n)
      cache_req_valid && !cache_req_ready |=>
          cache_req_valid && $stable(cache_req_addr) &&
          $stable(cache_req_cmd) && $stable(cache_req_source_id) &&
          $stable(cache_req_transaction_id));
  assert property (@(posedge clk) disable iff (!rst_n)
      rsp_valid && !rsp_ready |=>
          (rsp_valid || rsp_ready));

  assert property (@(posedge clk) disable iff (!rst_n)
      cache_rsp_valid && cache_rsp_ready |->
          cache_rsp_source_id == source_id_r &&
          cache_rsp_transaction_id == transaction_id_r);

  /* verilator lint_on UNUSEDSIGNAL */
  /* verilator lint_on SYNCASYNCNET */

endmodule
