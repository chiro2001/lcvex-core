// lcvex_neon_fp.sv
//
// P7-3/P7-5：受限 Advanced SIMD 浮点执行单元。
//
// 每个活动 lane 复用 P7-1/P7-5 的 raw IEEE-754 标量单元。这样 vector FP
// 与 scalar FP 共享 DN/FZ/FZ16/RMode、NaN quieting、舍入和 FPSR flag 语义，
// 但结果仍在固定宽度的 V raw bits 上合并；本模块不使用 host float、
// real、epsilon 或 SIMD 浮点库。
//
// 支持（P7-3）：FADD/FSUB/FMUL、FCMEQ（quiet equal compare）、FMLA/FMLS、
// SCVTF/UCVTF/FCVTZS/FCVTZU（整数形式）的 2S/4S/2D 形式。
// 支持（P7-5）：2S/4S/2D FSQRT/FMIN/FMAX/FMINNM/FMAXNM/FRINT*；4H/8H
// FADD/FSUB/FMUL/FCMEQ（每个 32-bit 槽两个 16-bit lane）。
// 2S 是 64-bit D view，按架构清零 Vd[127:64]；4S/2D/4H/8H 写满 128 bit。
// 向量 H FMLA/FMLS 已由 B2a 接入；向量 H FCVT、FCMGE/FCMGT、定点向量转换、by-element、
// estimate、其它未列族在 decoder 中保持 UDEF，不在这里静默降级。
//
// FP-P2 起，发布配置（lcvex_core）不再例化本 4-lane 组合参考模块；核心
// 唯一的 FP 执行入口是下方的 lcvex_fp_exec，它用一个共享 64-bit lane engine
// 按时序 slot 处理标量与 NEON FP。本模块仅保留作为现有 P7-3/4/5
// standalone raw-bit SV 测试的参考 formatter，不进入 release hierarchy。

`timescale 1ns/1ps

module lcvex_neon_fp (
    input  logic                         valid,
    input  lcvex_pkg::neon_fp_op_t       op,
    input  logic                         is_double,
    input  logic                         is_half,
    input  logic                         quad,
    input  logic [2:0]                   rint_mode,
    input  logic [127:0]                 operand_a,
    input  logic [127:0]                 operand_b,
    input  logic [127:0]                 operand_c,   // FMLA/FMLS addend=Vd
    input  logic [31:0]                  fpcr,
    output logic [127:0]                 result,
    output logic [31:0]                  fpsr_flags
);

  import lcvex_pkg::*;

  fp_op_t       scalar_op;
  logic         scalar_valid [0:3];
  logic [63:0]  scalar_a     [0:3];
  logic [63:0]  scalar_b     [0:3];
  logic [63:0]  scalar_c     [0:3];
  logic [63:0]  scalar_conv_int [0:3];
  logic [63:0]  scalar_result [0:3];
  logic [63:0]  scalar_int    [0:3];
  logic [31:0]  scalar_flags  [0:3];
  logic [3:0]   scalar_cmp    [0:3];
  /* verilator lint_off UNUSEDSIGNAL */
  // Only present to consume the new lcvex_fp_scalar divider ports in
  // NEON lane instances; NEON FP does not currently issue FDIV.
  logic [3:0]   scalar_div_busy;
  logic [3:0]   scalar_div_done;
  logic [3:0]   scalar_iter_busy;
  logic [3:0]   scalar_iter_done;
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    unique case (op)
      NEON_FP_OP_FADD:  scalar_op = FP_OP_ADD;
      NEON_FP_OP_FSUB:  scalar_op = FP_OP_SUB;
      NEON_FP_OP_FMUL:  scalar_op = FP_OP_MUL;
      NEON_FP_OP_FCMEQ: scalar_op = FP_OP_CMP;
      NEON_FP_OP_FMLA:  scalar_op = FP_OP_FMADD;
      NEON_FP_OP_FMLS:  scalar_op = FP_OP_FMSUB;   // Vd - Vn*Vm
      NEON_FP_OP_SCVTF: scalar_op = FP_OP_SCVTF;
      NEON_FP_OP_UCVTF: scalar_op = FP_OP_UCVTF;
      NEON_FP_OP_FCVTZS: scalar_op = FP_OP_FCVTZS;
      NEON_FP_OP_FCVTZU: scalar_op = FP_OP_FCVTZU;
      NEON_FP_OP_SQRT:  scalar_op = FP_OP_SQRT;
      NEON_FP_OP_FMIN:  scalar_op = FP_OP_FMIN;
      NEON_FP_OP_FMAX:  scalar_op = FP_OP_FMAX;
      NEON_FP_OP_FMINNM: scalar_op = FP_OP_FMINNM;
      NEON_FP_OP_FMAXNM: scalar_op = FP_OP_FMAXNM;
      NEON_FP_OP_FRINT: scalar_op = FP_OP_FRINT;
      default:          scalar_op = FP_OP_NONE;
    endcase

    for (int i = 0; i < 4; i++) begin
      scalar_valid[i] = valid &&
                        (is_double ? (i < 2) :
                         (quad ? (i < 4) : (i < 2)));
      if (is_half) begin
        // 每个标量单元处理一个 32-bit 槽内的两个 16-bit lane。
        scalar_a[i] = {32'd0, operand_a[i * 32 +: 32]};
        scalar_b[i] = {32'd0, operand_b[i * 32 +: 32]};
        scalar_c[i] = {32'd0, operand_c[i * 32 +: 32]};
        scalar_conv_int[i] = 64'd0;
      end else if (is_double) begin
        // Only lanes 0 and 1 exist for 2D; keep i*64 slices statically in
        // range. Higher lanes are invalid and are given zero don't-care inputs
        // (scalar_valid is already false for them).
        if (i < 2) begin
          scalar_a[i] = operand_a[i * 64 +: 64];
          scalar_b[i] = operand_b[i * 64 +: 64];
          scalar_c[i] = operand_c[i * 64 +: 64];
          scalar_conv_int[i] = operand_a[i * 64 +: 64];
        end else begin
          scalar_a[i] = 64'd0;
          scalar_b[i] = 64'd0;
          scalar_c[i] = 64'd0;
          scalar_conv_int[i] = 64'd0;
        end
      end else begin
        scalar_a[i] = {32'd0, operand_a[i * 32 +: 32]};
        scalar_b[i] = {32'd0, operand_b[i * 32 +: 32]};
        scalar_c[i] = {32'd0, operand_c[i * 32 +: 32]};
        // SCVTF 是 signed 32 位整数：必须符号扩展后交给标量单元。
        if (op == NEON_FP_OP_SCVTF)
          scalar_conv_int[i] = {{32{operand_a[i * 32 + 31]}},
                                operand_a[i * 32 +: 32]};
        else
          scalar_conv_int[i] = {32'd0, operand_a[i * 32 +: 32]};
      end
    end
  end

  genvar lane;
  generate
    for (lane = 0; lane < 4; lane = lane + 1) begin : g_scalar_lane
      lcvex_fp_scalar scalar_lane (
          .clk            (1'b0),
          .rst_n          (1'b1),
          .valid          (scalar_valid[lane]),
          .op             (scalar_op),
          .is_double      (is_double),
          .is_half        (is_half),
          .fcvt_dst_half  (1'b0),
          .rint_mode      (rint_mode),
          .operand_a      (scalar_a[lane]),
          .operand_b      (scalar_b[lane]),
          .operand_c      (scalar_c[lane]),
          .conv_int       (scalar_conv_int[lane]),
          .conv_shift     (7'd0),
          .conv_is_32     (!is_double && !is_half),
          .fpcr           (fpcr),
          .compare_zero   (1'b0),
          .signal_all_nans(1'b0),
          .iter_kill      (1'b0),
          .iter_pause     (1'b0),
          .result         (scalar_result[lane]),
          .int_result     (scalar_int[lane]),
          .fpsr_flags     (scalar_flags[lane]),
          .cmp_nzcv       (scalar_cmp[lane]),
          .div_busy       (scalar_div_busy[lane]),
          .div_done       (scalar_div_done[lane]),
          .iter_busy      (scalar_iter_busy[lane]),
          .iter_done      (scalar_iter_done[lane])
      );
    end
  endgenerate

  always_comb begin
    result = 128'd0;
    fpsr_flags = 32'd0;
    for (int i = 0; i < 4; i++) begin
      if (scalar_valid[i]) begin
        fpsr_flags = fpsr_flags | scalar_flags[i];
        if (is_half) begin
          // 32-bit 槽内两个 16-bit lane 已由标量单元打包（FCMEQ 为
          // 全 1/全 0 掩码）。
          result[i * 32 +: 32] = scalar_result[i][31:0];
        end else if (op inside {NEON_FP_OP_FCVTZS, NEON_FP_OP_FCVTZU}) begin
          if (is_double) begin
            if (i < 2)
              result[i * 64 +: 64] = scalar_int[i];
          end else begin
            result[i * 32 +: 32] = scalar_int[i][31:0];
          end
        end else if (is_double) begin
          // Only lanes 0 and 1 are valid for 2D; guard the slice so Quartus
          // does not see a statically out-of-range i*64 part-select.
          if (i < 2) begin
            if (op == NEON_FP_OP_FCMEQ)
              result[i * 64 +: 64] = (scalar_cmp[i] == 4'b0110)
                                      ? 64'hffff_ffff_ffff_ffff : 64'd0;
            else
              result[i * 64 +: 64] = scalar_result[i];
          end
        end else begin
          if (op == NEON_FP_OP_FCMEQ)
            result[i * 32 +: 32] = (scalar_cmp[i] == 4'b0110)
                                   ? 32'hffff_ffff : 32'd0;
          else
            result[i * 32 +: 32] = scalar_result[i][31:0];
        end
      end
    end
  end

endmodule


// ---- FP-P2：共享 64-bit lane engine + slot sequencer ----
// 该模块在 FP-P1 的 clocked transaction 接口内实现单 lane 执行：
// 标量 H/S/D 使用 1 个 slot；NEON 2S/4S/2D/4H/8H 按 32-bit/64-bit lane
// 依次送入同一个 lcvex_fp_scalar 实例。每个 slot 的结果写入 128-bit
// accumulator，FPSR flags 逐 slot OR；只有最后一个 slot 完成后才产生
// 一次 held response。接口、单在途/held response/reset/kill 语义与 FP-P1
// 保持一致。
/* verilator lint_off DECLFILENAME */
module lcvex_fp_exec (
    input  logic                         clk,
    input  logic                         rst_n,
    // request 握手：只在 wrapper 完全空闲时 ready。
    input  logic                         req_valid,
    input  lcvex_pkg::fp_exec_req_t      req,
    output logic                         req_ready,
    // held response：rsp_valid 持续到 rsp_valid && rsp_ready 才释放。
    output logic                         rsp_valid,
    output lcvex_pkg::fp_exec_rsp_t      rsp,
    input  logic                         rsp_ready,
    // kill/reset 优于内部推进；kill 清空未提交 transaction。
    input  logic                         kill,
    output logic                         busy,
    output logic                         issued
);
  import lcvex_pkg::*;

  typedef enum logic [1:0] {
    TX_IDLE = 2'd0,
    TX_RUN  = 2'd1,
    TX_DONE = 2'd2,
    TX_SLOT = 2'd3
  } tx_state_t;

  tx_state_t        state;
  fp_exec_req_t     req_r;
  fp_exec_rsp_t     rsp_r;
  logic [2:0]       slot_idx;
  logic [2:0]       slot_count;
  logic [127:0]     acc;
  logic [31:0]      acc_flags;

  // Per-slot capture registers.  The scalar engine result is frozen here on
  // slot_done, and the accumulator/response mux is driven from these
  // registered values on the following cycle.  This breaks the
  // slot/operand mux -> scalar datapath -> accumulator/response mux chain.
  logic             slot_result_valid;
  logic [63:0]      slot_result_r;
  logic [63:0]      slot_int_result_r;
  logic [31:0]      slot_fpsr_r;
  logic [3:0]       slot_cmp_nzcv_r;

  // 共享 64-bit lane engine 输入/输出。
  logic             slot_valid;
  fp_op_t           slot_op;
  logic             slot_is_double;
  logic             slot_is_half;
  logic             slot_conv_is_32;
  logic [63:0]      slot_a;
  logic [63:0]      slot_b;
  logic [63:0]      slot_c;
  logic [63:0]      slot_conv_int;
  logic [63:0]      scalar_result;
  logic [63:0]      scalar_int_result;
  logic [31:0]      scalar_fpsr;
  logic [3:0]       scalar_cmp_nzcv;
  logic             scalar_div_busy;
  logic             scalar_div_done;
  logic             scalar_iter_busy;
  logic             scalar_iter_done;

  // slot 推进、写回与 flags OR。
  logic             slot_done;
  logic [127:0]     acc_next;
  logic [31:0]      flags_next;

  // In FP_ITER mode scalar_div_busy/done are aliases of the iterative FSM,
  // but req_ready only needs the generic iterative busy because kill can
  // immediately cancel the internal engine (no drain-wait).
  assign req_ready    = (state == TX_IDLE) && !kill &&
                        !scalar_iter_busy;
  assign rsp_valid    = (state == TX_DONE);
  assign busy         = (state != TX_IDLE) || scalar_iter_busy;
  assign issued       = (state == TX_RUN) || (state == TX_SLOT) ||
                        (state == TX_DONE) || scalar_iter_busy;
  assign rsp          = rsp_r;

  always_comb begin
    slot_count = 3'd0;
    if (req_r.kind == FP_EXEC_KIND_SCALAR) begin
      slot_count = 3'd1;
    end else if (req_r.kind == FP_EXEC_KIND_NEON) begin
      if (req_r.is_half)
        slot_count = req_r.quad ? 3'd4 : 3'd2;
      else if (req_r.is_double)
        slot_count = 3'd2;
      else
        slot_count = req_r.quad ? 3'd4 : 3'd2;
    end
  end

  always_comb begin
    slot_valid = 1'b0;
    slot_op    = FP_OP_NONE;
    slot_is_double = 1'b0;
    slot_is_half   = 1'b0;
    slot_conv_is_32 = 1'b0;
    slot_a = 64'd0;
    slot_b = 64'd0;
    slot_c = 64'd0;
    slot_conv_int = 64'd0;

    slot_valid = (state == TX_RUN) && (slot_idx < slot_count);

    if (req_r.kind == FP_EXEC_KIND_SCALAR) begin
      slot_op          = req_r.scalar_op;
      slot_is_double   = req_r.is_double;
      slot_is_half     = req_r.is_half;
      slot_a           = req_r.operand_a[63:0];
      slot_b           = req_r.operand_b[63:0];
      slot_c           = req_r.operand_c[63:0];
      slot_conv_int    = req_r.conv_int;
      slot_conv_is_32  = req_r.conv_is_32;
    end else if (req_r.kind == FP_EXEC_KIND_NEON) begin
      unique case (req_r.neon_op)
        NEON_FP_OP_FADD:   slot_op = FP_OP_ADD;
        NEON_FP_OP_FSUB:   slot_op = FP_OP_SUB;
        NEON_FP_OP_FMUL:   slot_op = FP_OP_MUL;
        NEON_FP_OP_FCMEQ:  slot_op = FP_OP_CMP;
        NEON_FP_OP_FMLA:   slot_op = FP_OP_FMADD;
        NEON_FP_OP_FMLS:   slot_op = FP_OP_FMSUB;
        NEON_FP_OP_SCVTF:  slot_op = FP_OP_SCVTF;
        NEON_FP_OP_UCVTF:  slot_op = FP_OP_UCVTF;
        NEON_FP_OP_FCVTZS: slot_op = FP_OP_FCVTZS;
        NEON_FP_OP_FCVTZU: slot_op = FP_OP_FCVTZU;
        NEON_FP_OP_SQRT:   slot_op = FP_OP_SQRT;
        NEON_FP_OP_FMIN:   slot_op = FP_OP_FMIN;
        NEON_FP_OP_FMAX:   slot_op = FP_OP_FMAX;
        NEON_FP_OP_FMINNM: slot_op = FP_OP_FMINNM;
        NEON_FP_OP_FMAXNM: slot_op = FP_OP_FMAXNM;
        NEON_FP_OP_FRINT:  slot_op = FP_OP_FRINT;
        default:            slot_op = FP_OP_NONE;
      endcase
      slot_is_double = req_r.is_double;
      slot_is_half   = req_r.is_half;

      if (req_r.is_half) begin
        // 一个 32-bit H slot 由 shared scalar 单元的 is_half 路径处理，
        // 一次计算两个 16-bit lane 并打包到 result[31:0]。
        unique case (slot_idx)
          3'd0: slot_a = {32'd0, req_r.operand_a[31:0]};
          3'd1: slot_a = {32'd0, req_r.operand_a[63:32]};
          3'd2: slot_a = {32'd0, req_r.operand_a[95:64]};
          3'd3: slot_a = {32'd0, req_r.operand_a[127:96]};
          default: slot_a = 64'd0;
        endcase
        unique case (slot_idx)
          3'd0: slot_b = {32'd0, req_r.operand_b[31:0]};
          3'd1: slot_b = {32'd0, req_r.operand_b[63:32]};
          3'd2: slot_b = {32'd0, req_r.operand_b[95:64]};
          3'd3: slot_b = {32'd0, req_r.operand_b[127:96]};
          default: slot_b = 64'd0;
        endcase
        unique case (slot_idx)
          3'd0: slot_c = {32'd0, req_r.operand_c[31:0]};
          3'd1: slot_c = {32'd0, req_r.operand_c[63:32]};
          3'd2: slot_c = {32'd0, req_r.operand_c[95:64]};
          3'd3: slot_c = {32'd0, req_r.operand_c[127:96]};
          default: slot_c = 64'd0;
        endcase
        slot_conv_is_32 = 1'b0;
      end else if (req_r.is_double) begin
        unique case (slot_idx)
          3'd0: begin
            slot_a = req_r.operand_a[63:0];
            slot_b = req_r.operand_b[63:0];
            slot_c = req_r.operand_c[63:0];
            slot_conv_int = req_r.operand_a[63:0];
          end
          3'd1: begin
            slot_a = req_r.operand_a[127:64];
            slot_b = req_r.operand_b[127:64];
            slot_c = req_r.operand_c[127:64];
            slot_conv_int = req_r.operand_a[127:64];
          end
          default: begin
            slot_a = 64'd0;
            slot_b = 64'd0;
            slot_c = 64'd0;
            slot_conv_int = 64'd0;
          end
        endcase
        slot_conv_is_32 = 1'b0;
      end else begin
        unique case (slot_idx)
          3'd0: begin
            slot_a = {32'd0, req_r.operand_a[31:0]};
            slot_b = {32'd0, req_r.operand_b[31:0]};
            slot_c = {32'd0, req_r.operand_c[31:0]};
            if (req_r.neon_op == NEON_FP_OP_SCVTF)
              slot_conv_int = {{32{req_r.operand_a[31]}},
                               req_r.operand_a[31:0]};
            else if (req_r.neon_op == NEON_FP_OP_UCVTF)
              slot_conv_int = {32'd0, req_r.operand_a[31:0]};
          end
          3'd1: begin
            slot_a = {32'd0, req_r.operand_a[63:32]};
            slot_b = {32'd0, req_r.operand_b[63:32]};
            slot_c = {32'd0, req_r.operand_c[63:32]};
            if (req_r.neon_op == NEON_FP_OP_SCVTF)
              slot_conv_int = {{32{req_r.operand_a[63]}},
                               req_r.operand_a[63:32]};
            else if (req_r.neon_op == NEON_FP_OP_UCVTF)
              slot_conv_int = {32'd0, req_r.operand_a[63:32]};
          end
          3'd2: begin
            slot_a = {32'd0, req_r.operand_a[95:64]};
            slot_b = {32'd0, req_r.operand_b[95:64]};
            slot_c = {32'd0, req_r.operand_c[95:64]};
            if (req_r.neon_op == NEON_FP_OP_SCVTF)
              slot_conv_int = {{32{req_r.operand_a[95]}},
                               req_r.operand_a[95:64]};
            else if (req_r.neon_op == NEON_FP_OP_UCVTF)
              slot_conv_int = {32'd0, req_r.operand_a[95:64]};
          end
          3'd3: begin
            slot_a = {32'd0, req_r.operand_a[127:96]};
            slot_b = {32'd0, req_r.operand_b[127:96]};
            slot_c = {32'd0, req_r.operand_c[127:96]};
            if (req_r.neon_op == NEON_FP_OP_SCVTF)
              slot_conv_int = {{32{req_r.operand_a[127]}},
                               req_r.operand_a[127:96]};
            else if (req_r.neon_op == NEON_FP_OP_UCVTF)
              slot_conv_int = {32'd0, req_r.operand_a[127:96]};
          end
          default: begin
            slot_a = 64'd0;
            slot_b = 64'd0;
            slot_c = 64'd0;
            slot_conv_int = 64'd0;
          end
        endcase
        slot_conv_is_32 = 1'b1;
      end
    end
  end

  lcvex_fp_scalar #(.FP_ITER(1'b1)) scalar_unit (
      .clk            (clk),
      .rst_n          (rst_n),
      .valid          (slot_valid),
      .op             (slot_op),
      .is_double      (slot_is_double),
      .is_half        (slot_is_half),
      .fcvt_dst_half  (req_r.kind == FP_EXEC_KIND_SCALAR ? req_r.fcvt_dst_half : 1'b0),
      .rint_mode      (req_r.rint_mode),
      .operand_a      (slot_a),
      .operand_b      (slot_b),
      .operand_c      (slot_c),
      .conv_int       (slot_conv_int),
      .conv_shift     (req_r.conv_shift),
      .conv_is_32     (slot_conv_is_32),
      .fpcr           (req_r.fpcr),
      .compare_zero   (req_r.kind == FP_EXEC_KIND_SCALAR ? req_r.cmp_zero : 1'b0),
      .signal_all_nans(req_r.kind == FP_EXEC_KIND_SCALAR ? req_r.signal_all_nans : 1'b0),
      .iter_kill      (kill),
      .iter_pause     (1'b0),
      .iter_busy      (scalar_iter_busy),
      .iter_done      (scalar_iter_done),
      .result         (scalar_result),
      .int_result     (scalar_int_result),
      .fpsr_flags     (scalar_fpsr),
      .cmp_nzcv       (scalar_cmp_nzcv),
      .div_busy       (scalar_div_busy),
      .div_done       (scalar_div_done)
  );

  // 当前 slot 是否已完成。在 FP_ITER 共享引擎中，scalar 对所有非迭代
  // 运算组合产生 iter_done=1，对 FDIV/FSQRT 在迭代状态机完成时产生
  // iter_done=1；因此这里统一用 iter_done 驱动 slot 推进。
  always_comb begin
    slot_done = 1'b0;
    if (slot_valid)
      slot_done = scalar_iter_done;
  end

  // 构造当前 slot 写入 accumulator 的 128-bit 切片，并计算 flags OR。
  // Only the captured slot result (slot_result_valid) is used here; the live
  // scalar_unit outputs belong to the same-cycle prepare/finish path and are
  // frozen into slot_*_r before this mux sees them.
  always_comb begin
    acc_next   = acc;
    flags_next = acc_flags | slot_fpsr_r;
    if (slot_result_valid) begin
      if (req_r.kind == FP_EXEC_KIND_NEON) begin
        if (req_r.is_half) begin
          // scalar 单元已把每个 32-bit H slot 的两个 16-bit 结果打包到
          // result[31:0]（FCMEQ 也是 16-bit 全 1/全 0 掩码）。
          unique case (slot_idx)
            3'd0: acc_next[31:0]   = slot_result_r[31:0];
            3'd1: acc_next[63:32]  = slot_result_r[31:0];
            3'd2: acc_next[95:64]  = slot_result_r[31:0];
            3'd3: acc_next[127:96] = slot_result_r[31:0];
            default: ;
          endcase
        end else if (req_r.is_double) begin
          if (req_r.neon_op == NEON_FP_OP_FCVTZS ||
              req_r.neon_op == NEON_FP_OP_FCVTZU) begin
            unique case (slot_idx)
              3'd0: acc_next[63:0]   = slot_int_result_r;
              3'd1: acc_next[127:64] = slot_int_result_r;
              default: ;
            endcase
          end else if (req_r.neon_op == NEON_FP_OP_FCMEQ) begin
            unique case (slot_idx)
              3'd0: acc_next[63:0]   = (slot_cmp_nzcv_r == 4'b0110)
                                       ? 64'hffff_ffff_ffff_ffff : 64'd0;
              3'd1: acc_next[127:64] = (slot_cmp_nzcv_r == 4'b0110)
                                       ? 64'hffff_ffff_ffff_ffff : 64'd0;
              default: ;
            endcase
          end else begin
            unique case (slot_idx)
              3'd0: acc_next[63:0]   = slot_result_r;
              3'd1: acc_next[127:64] = slot_result_r;
              default: ;
            endcase
          end
        end else begin
          if (req_r.neon_op == NEON_FP_OP_FCVTZS ||
              req_r.neon_op == NEON_FP_OP_FCVTZU) begin
            unique case (slot_idx)
              3'd0: acc_next[31:0]   = slot_int_result_r[31:0];
              3'd1: acc_next[63:32]  = slot_int_result_r[31:0];
              3'd2: acc_next[95:64]  = slot_int_result_r[31:0];
              3'd3: acc_next[127:96] = slot_int_result_r[31:0];
              default: ;
            endcase
          end else if (req_r.neon_op == NEON_FP_OP_FCMEQ) begin
            unique case (slot_idx)
              3'd0: acc_next[31:0]   = (slot_cmp_nzcv_r == 4'b0110)
                                       ? 32'hffff_ffff : 32'd0;
              3'd1: acc_next[63:32]  = (slot_cmp_nzcv_r == 4'b0110)
                                       ? 32'hffff_ffff : 32'd0;
              3'd2: acc_next[95:64]  = (slot_cmp_nzcv_r == 4'b0110)
                                       ? 32'hffff_ffff : 32'd0;
              3'd3: acc_next[127:96] = (slot_cmp_nzcv_r == 4'b0110)
                                       ? 32'hffff_ffff : 32'd0;
              default: ;
            endcase
          end else begin
            unique case (slot_idx)
              3'd0: acc_next[31:0]   = slot_result_r[31:0];
              3'd1: acc_next[63:32]  = slot_result_r[31:0];
              3'd2: acc_next[95:64]  = slot_result_r[31:0];
              3'd3: acc_next[127:96] = slot_result_r[31:0];
              default: ;
            endcase
          end
        end
      end
    end
  end

  fp_exec_rsp_t rsp_comb;
  always_comb begin
    rsp_comb = '0;
    rsp_comb.tag = req_r.tag;
    if (req_r.kind == FP_EXEC_KIND_SCALAR) begin
      rsp_comb.v_we     = req_r.v_we;
      rsp_comb.v_rd     = req_r.v_rd;
      rsp_comb.gpr_we   = req_r.gpr_we;
      rsp_comb.gpr_rd   = req_r.gpr_rd;
      rsp_comb.gpr_data = slot_int_result_r;
      rsp_comb.nzcv_we  = req_r.nzcv_we;
      rsp_comb.nzcv     = slot_cmp_nzcv_r;
      rsp_comb.fpsr_we  = req_r.fpsr_we;
      rsp_comb.fpsr_flags = slot_fpsr_r;
      // 沿用 core 的 scalar 写回格式：H->S/D 转换、H 写回、S/D 零扩展。
      if (req_r.is_half && (req_r.scalar_op == FP_OP_FCVT) &&
          !req_r.fcvt_dst_half) begin
        rsp_comb.v_data = req_r.is_double
                          ? {64'd0, slot_result_r}
                          : {96'd0, slot_result_r[31:0]};
      end else if (req_r.is_half) begin
        rsp_comb.v_data = {112'd0, slot_result_r[15:0]};
      end else if (req_r.is_double) begin
        rsp_comb.v_data = {64'd0, slot_result_r};
      end else begin
        rsp_comb.v_data = {96'd0, slot_result_r[31:0]};
      end
    end else if (req_r.kind == FP_EXEC_KIND_NEON) begin
      rsp_comb.v_we       = req_r.v_we;
      rsp_comb.v_rd       = req_r.v_rd;
      rsp_comb.v_data     = acc_next;
      rsp_comb.fpsr_we    = req_r.fpsr_we;
      rsp_comb.fpsr_flags = flags_next;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state             <= TX_IDLE;
      req_r             <= '0;
      rsp_r             <= '0;
      slot_idx          <= 3'd0;
      acc               <= 128'd0;
      acc_flags         <= 32'd0;
      slot_result_valid <= 1'b0;
      slot_result_r     <= 64'd0;
      slot_int_result_r <= 64'd0;
      slot_fpsr_r       <= 32'd0;
      slot_cmp_nzcv_r   <= 4'd0;
    end else if (kill) begin
      state             <= TX_IDLE;
      req_r             <= '0;
      rsp_r             <= '0;
      slot_idx          <= 3'd0;
      // acc/acc_flags are non-architectural dead payload once kill drops
      // ownership back to TX_IDLE.  Retain them here to keep core kill
      // control off their D enables; reset still supplies deterministic zero
      // and the next accepted request reinitializes both before TX_RUN.
      slot_result_valid <= 1'b0;
      slot_result_r     <= 64'd0;
      slot_int_result_r <= 64'd0;
      slot_fpsr_r       <= 32'd0;
      slot_cmp_nzcv_r   <= 4'd0;
    end else begin
      unique case (state)
        TX_IDLE: begin
          if (req_valid && req_ready) begin
            req_r             <= req;
            slot_idx          <= 3'd0;
            acc               <= 128'd0;
            acc_flags         <= 32'd0;
            slot_result_valid <= 1'b0;
            state             <= TX_RUN;
          end
        end
        TX_RUN: begin
          // Freeze this slot's scalar outputs.  The accumulator update and
          // final response mux are deferred to TX_SLOT so the slot/operand
          // mux -> shared datapath is not directly coupled to the response
          // register in one combinational cone.
          if (slot_done) begin
            slot_result_r     <= scalar_result;
            slot_int_result_r <= scalar_int_result;
            slot_fpsr_r       <= scalar_fpsr;
            slot_cmp_nzcv_r   <= scalar_cmp_nzcv;
            slot_result_valid <= 1'b1;
            state             <= TX_SLOT;
          end
        end
        TX_SLOT: begin
          if (slot_result_valid) begin
            if (slot_idx == (slot_count - 3'd1)) begin
              rsp_r             <= rsp_comb;
              state             <= TX_DONE;
            end else begin
              acc               <= acc_next;
              acc_flags         <= flags_next;
              slot_idx          <= slot_idx + 3'd1;
              state             <= TX_RUN;
            end
            slot_result_valid <= 1'b0;
          end else begin
            // Safety: a TX_SLOT entry with no captured result should not
            // occur; recover to idle rather than hanging.
            state             <= TX_IDLE;
            slot_result_valid <= 1'b0;
          end
        end
        TX_DONE: begin
          if (rsp_ready) begin
            state             <= TX_IDLE;
            req_r             <= '0;
            // The response payload is intentionally retained after the
            // handshake.  Clearing the whole response register here would
            // put the consumer's ready/exmem_can_adv control signal on every
            // payload bit's D path.  rsp_valid is already deasserted by the
            // state transition; the stale payload has no architectural
            // meaning and is overwritten when the next transaction reaches
            // TX_DONE.  The non-architectural accumulator/flags are retained
            // for the same reason: the next request acceptance in TX_IDLE
            // reinitializes both before any slot can observe them. Reset/kill
            // above still clear them to a known value.
            slot_idx          <= 3'd0;
            slot_result_valid <= 1'b0;
          end
        end
        default: state <= TX_IDLE;
      endcase
    end
  end

  // R18 kill/reissue invariants.  A kill releases transaction ownership and
  // clears all externally visible/captured payload, while deliberately
  // leaving the non-architectural accumulator payload unchanged.  The next
  // accepted request must clear that payload before the first TX_RUN slot.
  assert property (@(posedge clk) disable iff (!rst_n)
      (kill && (state inside {TX_RUN, TX_SLOT, TX_DONE}))
      |=> (state == TX_IDLE && !rsp_valid && !slot_result_valid &&
           $stable(acc) && $stable(acc_flags)));
  assert property (@(posedge clk) disable iff (!rst_n)
      (req_valid && req_ready)
      |=> (state == TX_RUN && acc == 128'd0 && acc_flags == 32'd0));

endmodule
/* verilator lint_on DECLFILENAME */
