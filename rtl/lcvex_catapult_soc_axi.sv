// lcvex_catapult_soc_axi.sv
// B5-SoC/Boot: M1-B 8B 内存请求 <-> AXI4 Full burst 命令桥。
//
// 该桥把 L2 的 M1-B PoC 端口接到 B1 的 lcvex_axi4_master 命令接口：
//   - 读：行首（offset 0）请求合并为 4-beat/64B INCR 读突发并缓存整行，
//     后续 7 个顺序 8B 请求直接由行缓冲返回；非行首读使用单 beat。
//   - 写：当前 L2 逐 beat 写回，协议要求每个 8B 请求都有响应，因此先按
//     单 beat 8B 事务转换（64B 突发合并留给后续优化，功能语义不变）。
//   - maint 请求不下 AXI，直接回 OK（L2 已在缓存层处理维护）。
// 错误：AXI RESP != OKAY 向上游传播为 M1-B fault。

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off DECLFILENAME */

module lcvex_catapult_soc_axi_bridge #(
    parameter int ADDR_WIDTH = 64,
    parameter int DATA_WIDTH = 128,
    parameter int ID_WIDTH   = 4,
    parameter int MAX_BURST_LEN = 16
) (
    input  logic clk,
    input  logic rst_n,

    // M1-B 上游（L2 PoC / SoC 路由）。
    input  logic                        u_req_valid,
    input  lcvex_pkg::mem_req_t         u_req,
    output logic                        u_req_accept,
    output logic                        u_rsp_valid,
    output lcvex_pkg::mem_rsp_t         u_rsp,
    input  logic                        u_rsp_ready,

    // AXI4 master 命令/响应（直连 lcvex_axi4_master）。
    output logic                        a_req_valid,
    input  logic                        a_req_ready,
    output logic                        a_req_write,
    output logic [ADDR_WIDTH-1:0]       a_req_addr,
    output logic [ID_WIDTH-1:0]         a_req_id,
    output logic [7:0]                  a_req_len,
    output logic [2:0]                  a_req_size,
    output logic [1:0]                  a_req_burst,
    output logic [DATA_WIDTH*MAX_BURST_LEN-1:0] a_req_wdata,
    output logic [(DATA_WIDTH/8)*MAX_BURST_LEN-1:0] a_req_wstrb,
    input  logic                        a_rsp_valid,
    output logic                        a_rsp_ready,
    input  logic                        a_rsp_write,
    input  logic [ID_WIDTH-1:0]         a_rsp_id,
    input  logic [DATA_WIDTH-1:0]       a_rsp_rdata,
    input  logic [1:0]                  a_rsp_resp,
    input  logic                        a_rsp_last,

    // 观测计数（每接受一个 AXI 事务 +1）。
    output logic [31:0]                 axi_read_count,
    output logic [31:0]                 axi_write_count,
    // 调试观测。
    output logic [2:0]                  dbg_state,
    output logic                        dbg_req_write_q
);

  import lcvex_pkg::*;
  import lcvex_axi4_pkg::*;

  localparam int LINE_BYTES = 64;
  localparam int LINE_BEATS  = LINE_BYTES / (DATA_WIDTH / 8);

  typedef enum logic [2:0] {
    S_IDLE,
    S_ISSUE,
    S_READ_WAIT,
    S_WRITE_WAIT,
    S_RSP,
    S_LINE_SERVE
  } state_t;

  state_t state_q;
  logic [63:0] req_addr_q;
  logic        req_write_q;
  logic        req_maint_q;
  logic [63:0] req_wdata_q;
  logic [7:0]  req_strb_q;
  logic        line_active_q;
  logic        line_fault_q;
  logic [2:0]  line_off_q;      // 已可返回的 8B 块数
  logic [3:0]  r_beat_q;
  logic [LINE_BYTES*8-1:0] line_buf_q;
  logic [DATA_WIDTH-1:0]   single_rdata_q;
  logic [63:0] rsp_data_r;
  logic        rsp_fault_r;
  logic [31:0] read_count_q;
  logic [31:0] write_count_q;

  logic is_line_read;
  logic is_single_read;
  logic is_write;
  logic line_serve_match;

  assign is_line_read = !req_write_q && !req_maint_q &&
                        (req_addr_q[5:0] == 6'd0);
  assign is_single_read = !req_write_q && !req_maint_q &&
                          !is_line_read;
  assign is_write = req_write_q && !req_maint_q;

  // M1-B carries byte strobes for the actual scalar width. Keep narrow
  // requests narrow on AXI as well: forcing every write to AWSIZE=3 makes a
  // 32-bit access at byte offset 12 cross a 16-byte AXI beat and return SLVERR.
  function automatic logic [2:0] size_from_strb(input logic [7:0] strb);
    unique case (strb)
      8'h01:   size_from_strb = 3'd0;
      8'h03:   size_from_strb = 3'd1;
      8'h0f:   size_from_strb = 3'd2;
      8'hff:   size_from_strb = 3'd3;
      default: size_from_strb = 3'd7; // deliberately rejected by AXI window check
    endcase
  endfunction

  assign line_serve_match = (state_q == S_LINE_SERVE) && u_req_valid &&
                            !u_req.we && (u_req.maint == MAINT_NONE) &&
                            (u_req.addr ==
                             ({req_addr_q[63:6], 6'd0} +
                              {61'd0, line_off_q, 3'd0}));

  // ---- 上游接受 ----
  assign u_req_accept = u_req_valid &&
                        ((state_q == S_IDLE) || line_serve_match);

  always_comb begin
    a_req_valid = 1'b0;
    a_req_write = 1'b0;
    a_req_addr  = req_addr_q[ADDR_WIDTH-1:0];
    a_req_id    = '0;
    a_req_len   = 8'd0;
    a_req_size  = 3'd3;
    a_req_burst = AXI4_BURST_INCR;
    a_req_wdata = '0;
    a_req_wstrb = '0;

    if (state_q == S_ISSUE) begin
      a_req_valid = 1'b1;
      a_req_write = req_write_q;
      if (is_line_read) begin
        a_req_len  = 8'd3;
        a_req_size = 3'd4;
      end else if (is_single_read) begin
        a_req_len  = 8'd0;
        a_req_size = size_from_strb(req_strb_q);
      end else if (is_write) begin
        a_req_len  = 8'd0;
        a_req_size = size_from_strb(req_strb_q);
        // The Avalon adapter accepts normalized narrow AXI WSTRB in low lanes
        // and relocates those bytes from AWADDR. M1-B write data/strobes are
        // relative to req.addr, so do not pre-select a 64-bit half here.
        a_req_wdata[63:0] = req_wdata_q;
        a_req_wstrb[7:0] = req_strb_q;
      end
    end
  end

  // ---- 上游响应 ----
  assign u_rsp_valid = (state_q == S_RSP);
  assign u_rsp.rdata = rsp_data_r;
  assign u_rsp.fault = rsp_fault_r;
  assign a_rsp_ready = (state_q == S_READ_WAIT) ||
                       (state_q == S_WRITE_WAIT);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q        <= S_IDLE;
      req_addr_q     <= '0;
      req_write_q    <= 1'b0;
      req_maint_q    <= 1'b0;
      req_wdata_q    <= '0;
      req_strb_q     <= '0;
      line_active_q  <= 1'b0;
      line_fault_q   <= 1'b0;
      line_off_q     <= 3'd0;
      r_beat_q       <= 4'd0;
      line_buf_q     <= '0;
      single_rdata_q <= '0;
      rsp_data_r     <= '0;
      rsp_fault_r    <= 1'b0;
      read_count_q   <= '0;
      write_count_q  <= '0;
    end else begin
      // 计数在 AXI 接受沿更新。
      if (a_req_valid && a_req_ready) begin
        if (a_req_write) begin
          write_count_q <= write_count_q + 32'd1;
        end else begin
          read_count_q <= read_count_q + 32'd1;
        end
      end

      case (state_q)
        S_IDLE: begin
          if (u_req_valid) begin
            req_addr_q  <= u_req.addr;
            req_write_q <= u_req.we;
            req_maint_q <= (u_req.maint != MAINT_NONE);
            req_wdata_q <= u_req.wdata;
            req_strb_q  <= u_req.strb;
            if (u_req.maint != MAINT_NONE) begin
              rsp_data_r  <= 64'd0;
              rsp_fault_r <= 1'b0;
              state_q <= S_RSP;
            end else if (u_req.we) begin
              state_q <= S_ISSUE;
            end else if (u_req.addr[5:0] == 6'd0) begin
              line_active_q <= 1'b1;
              line_fault_q  <= 1'b0;
              line_off_q    <= 3'd0;
              r_beat_q      <= 4'd0;
              state_q       <= S_ISSUE;
            end else begin
              r_beat_q <= 4'd0;
              state_q  <= S_ISSUE;
            end
          end
        end

        S_ISSUE: begin
          if (a_req_valid && a_req_ready) begin
            if (req_write_q) begin
              state_q <= S_WRITE_WAIT;
            end else begin
              r_beat_q <= 4'd0;
              state_q  <= S_READ_WAIT;
            end
          end
        end

        S_READ_WAIT: begin
          if (a_rsp_valid) begin
            if (is_line_read) begin
              line_buf_q[r_beat_q*DATA_WIDTH +: DATA_WIDTH] <= a_rsp_rdata;
            end else begin
              single_rdata_q <= a_rsp_rdata;
            end
            if (a_rsp_resp != AXI4_RESP_OKAY) begin
              line_fault_q <= 1'b1;
            end
            if (a_rsp_last) begin
              if (is_line_read) begin
                // Line fills return the requested offset-zero word first.  At
                // a_rsp_last the live bus carries the final 128-bit beat, so
                // take word zero from the already captured line buffer.
                rsp_data_r  <= line_buf_q[63:0];
                rsp_fault_r <= line_fault_q ||
                               (a_rsp_resp != AXI4_RESP_OKAY);
                line_off_q  <= 3'd1;
              end else begin
                // The adapter returns the containing 128-bit AXI lane. Shift
                // the addressed byte to bit zero so byte/half/word loads at
                // offsets 1..15 reach the core's size-extension mux correctly.
                rsp_data_r <= 64'(a_rsp_rdata >> (8 * req_addr_q[3:0]));
                rsp_fault_r <= (a_rsp_resp != AXI4_RESP_OKAY);
                line_active_q <= 1'b0;
              end
              state_q <= S_RSP;
            end else begin
              r_beat_q <= r_beat_q + 4'd1;
            end
          end
        end

        S_WRITE_WAIT: begin
          if (a_rsp_valid) begin
            rsp_data_r  <= 64'd0;
            rsp_fault_r <= (a_rsp_resp != AXI4_RESP_OKAY);
            state_q <= S_RSP;
          end
        end

        S_RSP: begin
          if (u_rsp_ready) begin
            // line_off_q names the next 8-byte word to serve.  Keep the line
            // active through offset 7; S_LINE_SERVE clears it after accepting
            // that final word.
            if (line_active_q) begin
              state_q <= S_LINE_SERVE;
            end else begin
              state_q <= S_IDLE;
            end
          end
        end

        S_LINE_SERVE: begin
          if (u_req_valid && !u_req.we &&
              (u_req.maint == MAINT_NONE) &&
              (u_req.addr ==
               ({req_addr_q[63:6], 6'd0} + {61'd0, line_off_q, 3'd0}))) begin
            rsp_data_r <= line_buf_q[{line_off_q, 3'd0}*8 +: 64];
            rsp_fault_r <= line_fault_q;
            line_off_q  <= line_off_q + 3'd1;
            if (line_off_q == 3'd7) begin
              line_active_q <= 1'b0;
            end
            state_q <= S_RSP;
          end else begin
            // 非顺序/写请求：丢弃行缓冲，回到 IDLE 重新处理当前请求。
            line_active_q <= 1'b0;
            state_q       <= S_IDLE;
          end
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

  assign axi_read_count  = read_count_q;
  assign axi_write_count = write_count_q;
  assign dbg_state       = state_q;
  assign dbg_req_write_q = req_write_q;

endmodule
