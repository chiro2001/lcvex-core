// lcvex_decode.sv
// AArch64 解码器（P2 子集）：
//   NOP / ADD·SUB·ADDS·SUBS·CMP·CMN（立即数、移位寄存器）
//   AND·ORR·EOR·ANDS（移位寄存器）/ MOVN·MOVZ·MOVK
//   B / BL / B.cond / CBZ / CBNZ / TBZ / TBNZ / BR / BLR / RET
//   LDR·STR（unsigned immediate，8/16/32/64 位）/ LDRSW / ADR / ADRP
//   SVC / HVC(SMCCC/PSCI 最小子集) / ERET / MRS / MSR
//   （VBAR_EL1·ELR_EL1·SPSR_EL1·NZCV）
//
// 输出 decoded_insn_t，XZR/SP 语义：
//   ADD/SUB 立即数：Rn/Rd=31 表示 SP；移位寄存器形式：Rn/Rd=31 为 XZR。
// P4 异常语义：
//   - 未识别/保留编码 -> d.exc=1, exc_code=EXC_UDEF（不再停住）；
//   - 取指地址超出 SRAM -> IABT；Load/Store 地址超出 SRAM -> DABT；
//   - SVC -> d.exc=1, exc_code=EXC_SVC，next_pc=异常向量；
//   - ERET/MSR 在 ID 级提交（由核心实现），MRS 走普通流水线写回。

`timescale 1ns/1ps

module lcvex_decode #(
    parameter logic [63:0] SRAM_BASE = 64'h0000_0000_4000_0000,
    parameter logic [63:0] SRAM_TOP  = 64'h0000_0000_4800_0000,
    parameter logic [63:0] MMIO_BASE = 64'h0000_0000_0900_0000,
    parameter logic [63:0] MMIO_TOP  = 64'h0000_0000_0900_1000,
    parameter logic [63:0] MMIO2_BASE = 64'h0000_0000_0800_0000,
    parameter logic [63:0] MMIO2_TOP  = 64'h0000_0000_0802_1000,
    parameter logic [63:0] MMIO3_BASE = 64'h0000_0000_0903_0000,
    parameter logic [63:0] MMIO3_TOP  = 64'h0000_0000_0903_1000,
    parameter logic [63:0] MMIO4_BASE = 64'h0000_0000_0901_0000,
    parameter logic [63:0] MMIO4_TOP  = 64'h0000_0000_0a02_0000,
    parameter logic        A64_FP_SIMD = 1'b1,  // 0=无 FP/NEON（ID 寄存器按 QEMU vfp=off）
    parameter logic [63:0] CNTFRQ_HZ = lcvex_pkg::CNTFRQ_EL0_VAL
) (
    input  logic [31:0]            insn,
    input  logic [63:0]            pc,
    input  logic [63:0]            gpr[31],
    input  logic [127:0]           v[32],
    input  logic [63:0]            sp,
    input  logic [3:0]             nzcv,
    input  logic                   el,       // 0=EL0 1=EL1
    input  logic                   sp_sel,   // PSTATE.SP（h=1/t=0）
    input  logic                   dit,      // PSTATE.DIT（P6 数据无关时序）
    input  logic                   ssbs,     // PSTATE.SSBS（bit12）
    input  logic                   uao,      // PSTATE.UAO（bit9）
    input  logic                   pan,      // PSTATE.PAN（bit22）
    input  logic                   tco,      // PSTATE.TCO（bit25）
    input  logic                   allint,   // PSTATE.ALLINT（bit13）
    input  logic [63:0]            vbar_el1,
    input  logic [63:0]            elr_el1,
    input  logic [63:0]            spsr_el1,
    input  logic [63:0]            sctlr_el1,
    input  logic [63:0]            tcr_el1,
    input  logic [63:0]            ttbr0_el1,
    input  logic [63:0]            ttbr1_el1,
    input  logic [63:0]            mair_el1,
    input  logic [31:0]            esr_el1,
    input  logic [63:0]            far_el1,
    input  logic [63:0]            sp_el0,       // P6：MRS sp_el0
    input  logic [63:0]            cpacr_el1,
    input  logic [31:0]            fpcr_read_data,
    input  logic [31:0]            fpsr_read_data,
    input  logic                   fp_access_allowed,
    input  logic [63:0]            mdscr_el1,
    input  logic [63:0]            pmuserenr_el0,
    input  logic [63:0]            cntkctl_el1,
    input  logic [63:0]            tpidr_el0,
    input  logic [63:0]            tpidrro_el0,
    input  logic [63:0]            tpidr_el1,
    input  logic [63:0]            contextidr_el1,
    input  logic [63:0]            tcr2_el1,
    input  logic [63:0]            pir_el1,
    input  logic [63:0]            pire0_el1,
    input  logic [63:0]            par_el1,
    input  logic [3:0]             daif,
    input  logic [63:0]            zcr_el1,
    input  logic [63:0]            smcr_el1,
    input  logic [63:0]            csselr_el1,
    input  logic                   mmu_en,     // SCTLR_EL1.M（P5a）
    output lcvex_pkg::decoded_insn_t d
);

  import lcvex_pkg::*;

  function automatic logic cond_taken(input logic [3:0] cond,
                                      input logic [3:0] flags);
    logic n, z, c, vflag;
    n = flags[3];
    z = flags[2];
    c = flags[1];
    vflag = flags[0];
    unique case (cond)
      4'h0: cond_taken = z;
      4'h1: cond_taken = !z;
      4'h2: cond_taken = c;
      4'h3: cond_taken = !c;
      4'h4: cond_taken = n;
      4'h5: cond_taken = !n;
      4'h6: cond_taken = vflag;
      4'h7: cond_taken = !vflag;
      4'h8: cond_taken = c && !z;
      4'h9: cond_taken = !c || z;
      4'ha: cond_taken = (n == vflag);
      4'hb: cond_taken = (n != vflag);
      4'hc: cond_taken = !z && (n == vflag);
      4'hd: cond_taken = z || (n != vflag);
      4'he, 4'hf: cond_taken = 1'b1;   // 0xe=AL；0xf QEMU 亦按无条件处理
      default:   cond_taken = 1'b0;
    endcase
  endfunction

  function automatic logic [7:0] strb_for_size(input logic [1:0] size);
    unique case (size)
      2'd0: strb_for_size = 8'h01;
      2'd1: strb_for_size = 8'h03;
      2'd2: strb_for_size = 8'h0f;
      default: strb_for_size = 8'hff;
    endcase
  endfunction

  // LSE128 是单个 16B 原子访问；在发起任何读/写前检查整个访问窗口。
  // MMU 打开时虚拟地址范围由核心在两次翻译完成后检查，MMU 关闭时
  // 这里即可拒绝越过 SRAM/MMIO 窗口的访问。
  function automatic logic atomic128_window_ok(input logic [63:0] a);
    atomic128_window_ok =
        ((a >= SRAM_BASE) && (a <= (SRAM_TOP - 64'd16))) ||
        ((a >= MMIO_BASE) && (a <= (MMIO_TOP - 64'd16))) ||
        ((a >= MMIO2_BASE) && (a <= (MMIO2_TOP - 64'd16))) ||
        ((a >= MMIO3_BASE) && (a <= (MMIO3_TOP - 64'd16))) ||
        ((a >= MMIO4_BASE) && (a <= (MMIO4_TOP - 64'd16)));
  endfunction

  // P7-2 单 Q 访存在本任务中固定为自然对齐的完整 16B 访问。两条
  // 8B request 只是内部总线镜像，架构上仍是一条 Q load/store；因此在
  // 发出第一段请求前就检查整个窗口，避免 fault 后留下半笔 Store。
  function automatic logic neon128_window_ok(input logic [63:0] a);
    neon128_window_ok =
        ((a >= SRAM_BASE) && (a <= (SRAM_TOP - 64'd16))) ||
        ((a >= MMIO_BASE) && (a <= (MMIO_TOP - 64'd16))) ||
        ((a >= MMIO2_BASE) && (a <= (MMIO2_TOP - 64'd16))) ||
        ((a >= MMIO3_BASE) && (a <= (MMIO3_TOP - 64'd16))) ||
        ((a >= MMIO4_BASE) && (a <= (MMIO4_TOP - 64'd16)));
  endfunction

  // AArch64 逻辑立即数（位掩码）解码（QEMU logic_imm_decode_wmask 语义）。
  // 返回值为 {valid, mask}，不使用 output/inout 参数。这样 mask 的 65
  // 个返回位由同一个纯函数在所有路径上完整赋值，避免 Quartus 21.4 对
  // “output 参数承载的 automatic local”推断出 imm[63] 无驱动。
  //
  // N:immr:imms 的 len 是 {N,~imms} 最高置位的位置。len=6 表示 64
  // 位元素，len=1..5 表示 2..32 位元素；len=0 和 S==levels 是保留
  // 编码。旋转和元素复制均使用有界移位/常量宽度拼接：没有 break、变
  // 步长循环或 64 位宽度的未定义移位。
  function automatic logic [64:0] logic_imm_decode(
      input logic       immn,
      input logic [5:0] immr,
      input logic [5:0] imms);
    logic [2:0]  len;
    logic [6:0]  element_size;
    logic [5:0]  levels;
    logic [5:0]  s_field;
    logic [5:0]  r_field;
    logic [6:0]  ones_shift;
    logic [63:0] element_mask;
    logic [63:0] ones;
    logic [63:0] rotated;
    logic [63:0] mask;
    logic        valid;

    begin
      // Defaults also cover X/unknown inputs and every reserved encoding.
      len          = 3'd0;
      element_size = 7'd0;
      levels       = 6'd0;
      s_field      = 6'd0;
      r_field      = 6'd0;
      ones_shift   = 7'd63;
      element_mask = 64'd0;
      ones         = 64'd0;
      rotated      = 64'd0;
      mask         = 64'd0;
      valid        = 1'b0;
      logic_imm_decode = 65'd0;

      // Fixed priority selection for len. For N=0, the highest one in
      // ~imms[5:0] determines the element size; N=1 always gives len=6.
      if (immn) begin
        len = 3'd6;
      end else begin
        casez (~imms)
          6'b1?????: len = 3'd5;
          6'b01????: len = 3'd4;
          6'b001???: len = 3'd3;
          6'b0001??: len = 3'd2;
          6'b00001?: len = 3'd1;
          default:   len = 3'd0;
        endcase
      end

      // The table supplies both levels and the element mask without
      // constructing (1 << 64). It also bounds all later rotation shifts.
      case (len)
        3'd6: begin
          element_size = 7'd64;
          levels       = 6'h3f;
          element_mask = 64'hffff_ffff_ffff_ffff;
        end
        3'd5: begin
          element_size = 7'd32;
          levels       = 6'h1f;
          element_mask = 64'h0000_0000_ffff_ffff;
        end
        3'd4: begin
          element_size = 7'd16;
          levels       = 6'h0f;
          element_mask = 64'h0000_0000_0000_ffff;
        end
        3'd3: begin
          element_size = 7'd8;
          levels       = 6'h07;
          element_mask = 64'h0000_0000_0000_00ff;
        end
        3'd2: begin
          element_size = 7'd4;
          levels       = 6'h03;
          element_mask = 64'h0000_0000_0000_000f;
        end
        3'd1: begin
          element_size = 7'd2;
          levels       = 6'h01;
          element_mask = 64'h0000_0000_0000_0003;
        end
        default: begin
          element_size = 7'd0;
          levels       = 6'd0;
          element_mask = 64'd0;
        end
      endcase

      s_field    = imms & levels;
      r_field    = immr & levels;
      valid      = (len >= 3'd1) && (s_field != levels);
      ones_shift = 7'd63 - {1'b0, s_field};
      // For every possible s_field this shifts by 0..63, never by 64.
      // Valid encodings additionally have s_field < levels.
      ones       = 64'hffff_ffff_ffff_ffff >> ones_shift;

      if (valid) begin
        if (r_field == 6'd0) begin
          rotated = ones & element_mask;
        end else begin
          // valid len/r_field bounds make element_size-r_field lie in 1..63.
          rotated = ((ones >> r_field) |
                     (ones << (element_size - {1'b0, r_field}))) &
                    element_mask;
        end

        // Replicate the selected element with constant-width concatenations.
        // rotated is already masked, so no bit outside the selected element
        // can enter the replication.
        case (len)
          3'd6: mask = rotated;
          3'd5: mask = {2{rotated[31:0]}};
          3'd4: mask = {4{rotated[15:0]}};
          3'd3: mask = {8{rotated[7:0]}};
          3'd2: mask = {16{rotated[3:0]}};
          3'd1: mask = {32{rotated[1:0]}};
          default: mask = 64'd0;
        endcase
      end

      logic_imm_decode = {valid, mask};
    end
  endfunction

  // XZR 读：31 恒为 0（gpr 只有 0..30，不能越界访问）
  function automatic logic [63:0] rdg(input logic [4:0] i);
    rdg = (i == 5'd31) ? 64'd0 : gpr[i];
  endfunction

  // Quartus Prime 21.4 不支持“函数调用结果直接部分选择”的 SV 语法，
  // 这里用辅助函数做等价改写（本地可综合适配，语义与 rdg 一致）。
  // rdg_low 返回低 width 位（width<=32）的零扩展结果；调用点只使用固定宽度。
  function automatic logic [31:0] rdg_low(
      input logic [4:0] i,
      input logic [5:0] width);
    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0] rv;
    /* verilator lint_on UNUSEDSIGNAL */
    begin
      rv = rdg(i);
      unique case (width)
        6'd6:  rdg_low = {26'd0, rv[5:0]};
        6'd8:  rdg_low = {24'd0, rv[7:0]};
        6'd16: rdg_low = {16'd0, rv[15:0]};
        6'd32: rdg_low = rv[31:0];
        default: rdg_low = rv[31:0];
      endcase
    end
  endfunction

  function automatic logic rdg_bit(input logic [4:0] i, input logic [5:0] b);
    logic [63:0] rv;
    begin
      rv = rdg(i);
      rdg_bit = rv[b];
    end
  endfunction

  // 变量移位量只取低 6 位；单独返回 [5:0] 避免在调用点做截断。
  function automatic logic [5:0] rdg_low6(input logic [4:0] i);
    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0] rv;
    /* verilator lint_on UNUSEDSIGNAL */
    begin
      rv = rdg(i);
      rdg_low6 = rv[5:0];
    end
  endfunction

  // AArch64 VFPExpandImm()。imm8 的 sign/exponent/6-bit fraction 直接
  // 映射到 S/D/H raw encoding；这是位域展开，不依赖 host 浮点环境。
  // H 形式按 QEMU vfp_expand_imm(MO_16)：imm8[5:0]<<6，exp 字段
  // 0b11110（bit6=1）或 0b10000（bit6=0）。
  function automatic logic [63:0] fp_expand_imm(
      input logic [7:0] imm8, input logic dbl);
    logic [15:0] h;
    begin
      h = (imm8[7] ? 16'h8000 : 16'h0000) |
          (dbl
             ? (imm8[6] ? 16'h3fc0 : 16'h4000) | {10'd0, imm8[5:0]}
             : (imm8[6] ? 16'h3e00 : 16'h4000) |
               ({10'd0, imm8[5:0]} << 3));
      fp_expand_imm = dbl ? (64'(h) << 48) : (64'(h) << 16);
    end
  endfunction

  function automatic logic [15:0] fp_expand_imm_h(input logic [7:0] imm8);
    begin
      fp_expand_imm_h = (imm8[7] ? 16'h8000 : 16'h0000) |
                        (imm8[6] ? 16'h3000 : 16'h4000) |
                        ({10'd0, imm8[5:0]} << 6);
    end
  endfunction

  logic [63:0] target;
  logic [63:0] exc_vector;

  // QEMU target/arm/helper.c::gt_counter_access/gt_timer_access 语义：
  // EL0 的物理/虚拟计数器由 CNTKCTL_EL1[0]/[1] 门控，物理/虚拟
  // TVAL/CTL/CVAL 由 [9]/[8] 门控。CNTFRQ_EL0 虽是 PL0_R，但 QEMU
  // 仍通过 gt_cntfrq_access 要求 CNTKCTL[1:0] 至少一个置位。FEAT_ECV
  // 的 CNTPCTSS/CNTVCTSS 与对应计数器共享同一 gate。
  function automatic logic timer_el0_access_ok(
      input sys_reg_t sys_reg, input logic [1:0] counter_ctl,
      input logic [1:0] timer_ctl);
    unique case (sys_reg)
      SREG_CNTPCT, SREG_CNTPCTSS: timer_el0_access_ok = counter_ctl[0];
      SREG_CNTVCT, SREG_CNTVCTSS: timer_el0_access_ok = counter_ctl[1];
      SREG_CNTP_TVAL, SREG_CNTP_CTL, SREG_CNTP_CVAL:
        timer_el0_access_ok = timer_ctl[1];
      SREG_CNTV_TVAL, SREG_CNTV_CTL, SREG_CNTV_CVAL:
        timer_el0_access_ok = timer_ctl[0];
      SREG_CNTFRQ: timer_el0_access_ok = |counter_ctl;
      default: timer_el0_access_ok = 1'b1;
    endcase
  endfunction

  // 异常向量：低 EL（EL0）→EL1 偏移 0x400；同 EL 且 SP_ELx（h）偏移
  // 0x200，t 模式 0x000（当前只支持 h，保留语义）。
  assign exc_vector = vbar_el1 + (el ? (sp_sel ? 64'h200 : 64'h000)
                                     : 64'h400);

  always_comb begin
    // 默认：合法 NOP 语义（不写、不跳、next=pc+4）
    d = '0;
    d.valid = 1'b1;
    d.next_pc = pc + 64'd4;

    if (insn == 32'hD503201F) begin
      // NOP
    end else if (((insn & 32'hffe0_fc00) == 32'h4e00_0c00) ||
                 ((insn & 32'hffe0_fc00) == 32'h4e00_0400)) begin
      // B2c: DUP scalar/element replicate. The imm5 field encodes both the
      // element size and the source lane index (scalar forms use imm5=1/2/4/8).
      // The mask includes bits[23:21]==000 because the three-same unsupported
      // families (SQADD and friends) also share bits[15:10] with DUP_general;
      // without that fixed part a vector SQADD like 0x4E220C20 would be
      // mis-decoded as DUP scalar.
      automatic logic [31:0] dup_base = insn & 32'hffe0_fc00;
      automatic logic [4:0]  dup_rd = insn[4:0];
      automatic logic [4:0]  dup_src = insn[9:5];
      automatic logic [4:0]  dup_imm5 = insn[20:16];
      automatic logic [1:0]  dup_size;
      automatic logic [6:0]  dup_index;
      automatic logic        dup_ok = 1'b1;
      if (dup_base == 32'h4e00_0c00) begin
        // DUP Vd.<T>, Rn/Wn/Xn
        unique case (dup_imm5)
          5'd1: dup_size = 2'd0;
          5'd2: dup_size = 2'd1;
          5'd4: dup_size = 2'd2;
          5'd8: dup_size = 2'd3;
          default: dup_ok = 1'b0;
        endcase
        dup_index = 7'd0;
        if (dup_ok && !insn[30] && dup_size == 2'd3)
          dup_ok = 1'b0;   // DUP .1D is not a valid Advanced SIMD form.
        if (dup_ok) begin
          d.neon_valid = 1'b1;
          d.neon_op = NEON_OP_DUP_SCALAR;
          d.neon_wb_we = 1'b1;
          d.neon_rd = dup_rd;
          d.neon_size = dup_size;
          d.neon_quad = insn[30];
          d.neon_rn_en = 1'b0;
          d.neon_rm_en = 1'b0;
          d.neon_operand_a = {64'd0, rdg(dup_src)};
          d.neon_operand_b = 128'd0;
          d.neon_shift = 7'd0;
          d.rs1 = dup_src;
          d.rs1_en = (dup_src != 5'd31);
        end
      end else begin
        // DUP Vd.<T>, Vn.<T>[index]
        if (dup_imm5[0]) begin dup_size = 2'd0; dup_index = {3'b000, dup_imm5[4:1]}; end
        else if (dup_imm5[1]) begin dup_size = 2'd1; dup_index = {4'b0000, dup_imm5[4:2]}; end
        else if (dup_imm5[2]) begin dup_size = 2'd2; dup_index = {5'b00000, dup_imm5[4:3]}; end
        else if (dup_imm5[3]) begin dup_size = 2'd3; dup_index = {6'b000000, dup_imm5[4]}; end
        else dup_ok = 1'b0;
        if (dup_ok) begin
          unique case (dup_size)
            2'd0: if (dup_index > 7'd15) dup_ok = 1'b0;
            2'd1: if (dup_index > 7'd7)  dup_ok = 1'b0;
            2'd2: if (dup_index > 7'd3)  dup_ok = 1'b0;
            default: if (dup_index > 7'd1) dup_ok = 1'b0;
          endcase
          if (!insn[30] && dup_size == 2'd3)
            dup_ok = 1'b0;   // DUP .1D is not a valid Advanced SIMD form.
        end
        if (dup_ok) begin
          d.neon_valid = 1'b1;
          d.neon_op = NEON_OP_DUP_ELEMENT;
          d.neon_wb_we = 1'b1;
          d.neon_rd = dup_rd;
          d.neon_size = dup_size;
          d.neon_quad = insn[30];
          d.neon_rn = dup_src;
          d.neon_rn_en = 1'b1;
          d.neon_rm_en = 1'b0;
          d.neon_operand_a = 128'd0;
          d.neon_operand_b = v[dup_src];
          d.neon_shift = dup_index;
          d.rs1 = 5'd31;
          d.rs1_en = 1'b0;
        end
      end
      if (!dup_ok) begin
        d.valid = 1'b0;
        d.neon_valid = 1'b0;
        d.neon_wb_we = 1'b0;
      end
    end else if ((insn & 32'h3fff_f000) == 32'h0d40_c000) begin
      // B2c: LD1R {Vt.<T>}, [Xn] -- load one element and replicate to all
      // active lanes. Only the single-register replicate-load form is wired
      // in this batch; LD2R/LD3R/LD4R and structured stores remain deferred
      // until the multi-store commit ABI is expanded.
      automatic logic [1:0]  lr_size = insn[11:10];
      automatic logic [4:0]  lr_rn = insn[9:5];
      automatic logic [4:0]  lr_rt = insn[4:0];
      automatic logic [63:0] lr_base = (lr_rn == 5'd31) ? sp : gpr[lr_rn];
      d.neon_valid = 1'b1;
      d.neon_op = NEON_OP_MOV;
      d.neon_mem_load = 1'b1;
      d.neon_mem_replicate = 1'b1;
      d.neon_wb_we = 1'b1;
      d.neon_rd = lr_rt;
      d.neon_size = lr_size;
      d.neon_quad = insn[30];
      d.neon_rn_en = 1'b0;
      d.neon_rm_en = 1'b0;
      d.neon_operand_a = 128'd0;
      d.neon_operand_b = 128'd0;
      d.is_load = 1'b1;
      d.is_store = 1'b0;
      d.is_pair = 1'b0;
      d.mem_size = lr_size;
      d.mem_addr = lr_base;
      d.mem_strb = strb_for_size(lr_size);
      if (!insn[30] && lr_size == 2'd3) begin
        // There is no LD1R .1D form; Q=0 with a 64-bit element is reserved.
        d.valid = 1'b0;
        d.neon_valid = 1'b0;
        d.neon_wb_we = 1'b0;
        d.is_load = 1'b0;
      end
      d.rs1 = lr_rn;
      d.rs1_en = (lr_rn != 5'd31);
    end else if ((insn & 32'hFFE0_001F) inside {32'hD400_0002,
                                                   32'hD400_0003}) begin
      // HVC/SMC：QEMU virt 的 PSCI conduit 由 DT 选择为 HVC。PSCI
      // hostcall 在 QEMU 中直接返回 x0 并继续到 pc+4；这里采用同一条
      // 普通提交路径，避免把 hostcall 误当成同步异常。支持的函数与
      // QEMU 11.1 tcg/psci.c 对齐：VERSION、FEATURES、MIGRATE_INFO_TYPE、
      // AFFINITY_INFO、CPU_ON，以及未知函数的 NOT_SUPPORTED。
      // SYSTEM_RESET/SYSTEM_OFF 在 QEMU 侧执行整机复位/关机，架构状态
      // 不再连续；差分协议（DISCON kind=4）把这类 HVC 定义为窗口终止
      // 事件，RTL 的 NOT_SUPPORTED 返回不参与比较。
      automatic logic [31:0] fn = 32'(rdg(5'd0));
      automatic logic [31:0] feat = 32'(rdg(5'd1));
      automatic logic [63:0] ret;
      ret = 64'hFFFF_FFFF_FFFF_FFFF;  // PSCI_RET_NOT_SUPPORTED (-1)
      unique case (fn)
        32'h8400_0000, 32'hC400_0000: ret = 64'h0000_0000_0001_0001;
        // QEMU 无 Trusted OS；其 v0.2 实现返回
        // QEMU_PSCI_0_2_RET_TOS_MIGRATION_NOT_REQUIRED = 2。
        32'h8400_0006, 32'hC400_0006: ret = 64'd2;
        32'h8400_0004, 32'hC400_0004:
          ret = (rdg(5'd1) == 64'd0 && rdg(5'd2) == 0)
              ? 64'd0 : 64'hFFFF_FFFF_FFFF_FFFE;
        32'h8400_0003, 32'hC400_0003:
          // QEMU virt 单核 CPU0 的 MPIDR 为 0，已经上电，再次 CPU_ON
          // 返回 ALREADY_ON；其它 MPIDR 在单核配置中不存在。
          ret = (rdg(5'd1) == 64'd0)
              ? 64'hFFFF_FFFF_FFFF_FFFC : 64'hFFFF_FFFF_FFFF_FFFE;
        32'h8400_000A, 32'hC400_000A: begin
          // PSCI_FEATURES：QEMU 对已实现函数返回 0，其余 -1。
          unique case (feat)
            32'h8400_0000, 32'h8400_0001, 32'h8400_0002,
            32'h8400_0003, 32'h8400_0004, 32'h8400_0006,
            32'h8400_0008, 32'h8400_0009, 32'h8400_000A,
            32'hC400_0001, 32'hC400_0002, 32'hC400_0003,
            32'hC400_0004:
              ret = 64'd0;
            default: ret = 64'hFFFF_FFFF_FFFF_FFFF;
          endcase
        end
        default: ret = 64'hFFFF_FFFF_FFFF_FFFF;
      endcase
      d.wb_sel = 2'd1;
      d.wb_we = 1'b1;
      d.wb_rd = 5'd0;
      d.wb_extra = ret;
      // x0 是函数号读源；登记后可在 load-use / 前递边界稳定取值。
      d.rs1 = 5'd0;
      d.rs1_en = 1'b1;
    end else if (insn[31:22] == 10'b1101010000 && insn[4:0] == 5'b00001) begin
      // SVC #imm16
      d.exc = 1'b1;
      d.exc_code = EXC_SVC;
      d.exc_elr = pc + 64'd4;
      d.next_pc = exc_vector;
    end else if (insn == 32'hD69F03E0) begin
      // ERET（EL0 执行 ERET 为未定义指令）
      if (el) begin
        d.sys_op = SYS_ERET;
        d.next_pc = elr_el1;
      end else begin
        d.valid = 1'b0;
      end
    end else if (insn == 32'hD5033F5F) begin
      // CLREX：清 exclusive 监视器。无访存、无写回，只在提交时清
      // （架构状态只在 commit 更新）；QEMU 的 CLREX 即
      // exclusive_addr = -1。
      d.is_clrex = 1'b1;
    end else if (insn == 32'hD503207F) begin
      // WFI：指令本身正常退休，随后由核心进入 idle；不要按 NOP
      // 处理，否则无法与 QEMU 的 halt/Timer IRQ 边界对齐。
      d.sys_op = SYS_WFI;
    end else if (insn == 32'hD503205F) begin
      // WFE：单核事件寄存器或 IRQ 唤醒；等待语义在提交后生效。
      d.sys_op = SYS_WFE;
    end else if (insn == 32'hD503209F) begin
      d.sys_op = SYS_SEV;
    end else if (insn == 32'hD50320BF) begin
      d.sys_op = SYS_SEVL;
    end else if ((insn & 32'hFFFF_FFE0) == 32'hD503_1020) begin
      // WFIT Xt：FEAT_WFxT 的超时等待。超时值来自 Xt，作为 ID 级
      // 依赖登记；核心在提交时按 CNTVCT 判断是否真正进入 idle。
      d.sys_op = SYS_WFIT;
      d.sys_wdata = rdg(insn[4:0]);
      d.rs1 = insn[4:0];
      d.rs1_en = (insn[4:0] != 5'd31);
    end else if ((insn & 32'hFFFF_FFE0) == 32'hD503_1000) begin
      // WFET Xt：事件寄存器优先消费，否则等待 CNTVCT 超时/IRQ。
      d.sys_op = SYS_WFET;
      d.sys_wdata = rdg(insn[4:0]);
      d.rs1 = insn[4:0];
      d.rs1_en = (insn[4:0] != 5'd31);
    end else if ((insn & 32'hFFFFF01F) == 32'hD503201F &&
                 !(insn inside {32'hD503205F, 32'hD503207F,
                                32'hD503209F, 32'hD50320BF})) begin
      // HINT 空间（排除 WFE/WFI/SEV/SEVL 事件语义，留待实现）：
      // YIELD 与未实现特性的提示编码行为等同 NOP（PACIASP/PACIBSP/AUTIASP/
      // AUTIBSP 在 SCTLR EnIA/EnIB=0 时；PSSBT/PSSBB 无 SPE 时；BTI
      // 在 SCTLR.BT=0 时）。QEMU 对 0xD503233F（paciasp）提交为空操作，
      // 与其对齐（原 UDEF 缺口 seq=5691354；同时补上 BTI j 缺失覆盖）。
    end else if ((insn & 32'hFFFFF800) inside {32'h04BF5000,
                                                32'h04BF5800}) begin
      // RDVL/RDSVL：Linux 只用它探测向量长度。QEMU zcr_write 的长度为
      // (LEN+1)*16 字节；P8 再把该值接到真实 Z/P 状态。
      if (!el) begin
        d.valid = 1'b0;
      end else begin
        automatic logic signed [5:0] imm6 = insn[10:5];
        automatic logic [3:0] len_raw;
        automatic logic [3:0] len_eff;
        // RDVL 用 ZCR LEN（QEMU sve_vq.map = 0..15 全支持）；
        // RDSVL 用 SMCR LEN，但 QEMU -cpu max 的 sme_vq.map 只有
        // 2 的幂 VQ（128/256/512/1024/2048），写后按“最高支持档”
        // 取整（见 QEMU sve_vqm1_for_el_sm + SVE_VQ_POW2_MAP）。
        len_raw = insn[11] ? smcr_el1[3:0] : zcr_el1[3:0];
        if (!insn[11]) begin
          len_eff = len_raw;
        end else begin
          unique case (len_raw)
            4'h0:            len_eff = 4'd0;
            4'h1, 4'h2:      len_eff = 4'd1;
            4'h3, 4'h4, 4'h5, 4'h6: len_eff = 4'd3;
            4'h7, 4'h8, 4'h9, 4'hA, 4'hB,
            4'hC, 4'hD, 4'hE: len_eff = 4'd7;
            4'hF:            len_eff = 4'd15;
            default:         len_eff = 4'd7;
          endcase
        end
        d.sys_op = SYS_MRS;
        d.sys_reg = SREG_RDVL;
        d.wb_sel = 2'd1;
        d.wb_rd = insn[4:0];
        d.wb_we = (insn[4:0] != 5'd31);
        d.wb_extra = 64'($signed(imm6)) *
                     ((({60'd0, len_eff} + 64'd1) * 64'd16));
      end
    end else if ((insn & 32'hfffffeff) == 32'hd501401f) begin
      // MSR ALLINT, #imm（FEAT_NMI）：d501401f/d501411f。
      // ALLINT 仅在 EL1 可访问；EL0 访问按 QEMU 归类为 UDEF。
      if (!el) begin
        d.valid = 1'b0;
      end else begin
        d.sys_op = SYS_ALLINT;
        d.sys_wdata = {63'd0, insn[8]};
      end
    end else if (insn[31:22] == 10'b1101010100 && insn[20:19] == 2'b00 &&
                 insn[4:0] == 5'b11111 &&
                 ((insn[18:16] == 3'd0 && insn[15:12] == 4'd4 &&
                   insn[7:5] inside {3'd3, 3'd4, 3'd5}) ||
                  (insn[18:16] == 3'd3 && insn[15:12] == 4'd4 &&
                   insn[7:5] inside {3'd1, 3'd2, 3'd4, 3'd6, 3'd7}))) begin
      // MSR（immediate）：SPSel / PAN/UAO/SBSS/DIT/TCO/DAIF（P6）；
      // ALLINT 使用独立的 op1=001 编码分支。
      // 编码：op0=00；SPSel op1=000 CRn=4 CRm=0 op2=101；DAIFSet
      // op1=011 CRn=4 op2=110、DAIFClr op2=111（掩码在 CRm[3:0]）。
      // 注意：op0=00 也覆盖 DMB/DSB/ISB 等屏障，必须精确匹配这两个
      // 模式，其余编码落入屏障分支或 UDEF。
      automatic logic [2:0] op1 = insn[18:16];
      automatic logic [3:0] crn = insn[15:12];
      automatic logic [3:0] crm = insn[11:8];
      automatic logic [2:0] op2 = insn[7:5];
      // SPSel 的 imm 是 CRm[0]；QEMU 对 CRm[3:1] 不设限（& PSTATE_SP）。
      if (op1 == 3'd0 && crn == 4'd4 && op2 == 3'd5) begin
        if (!el) begin
          d.valid = 1'b0;   // SPSel 在 EL0 为未定义指令（QEMU 语义）
        end else begin
          d.sys_op = SYS_SPSEL;
          d.sys_wdata = {63'd0, insn[8]};   // SPSel imm = CRm[0]
        end
      end else if ((op1 == 3'd3 && crn == 4'd4 &&
                    op2 inside {3'd1, 3'd2, 3'd4}) ||
                   (op1 == 3'd0 && crn == 4'd4 &&
                    op2 inside {3'd3, 3'd4})) begin
        // PSTATE 立即数写：SSBS(op2=1)/DIT(op2=2)/TCO(op2=4) 与
        // UAO(op2=3)/PAN(op2=4) 各占独立 op，避免旧 lump 互相污染。
        if (op1 == 3'd3) begin
          d.sys_op = (op2 == 3'd1) ? SYS_SSBS
                   : (op2 == 3'd2) ? SYS_DIT : SYS_TCO;
        end else begin
          d.sys_op = (op2 == 3'd3) ? SYS_UAO : SYS_PAN;
        end
        d.sys_wdata = {63'd0, insn[8]};
      end else begin
        d.sys_op = SYS_DAIF;
        d.sys_wdata = {59'd0, (op2 == 3'd6), crm};
        // sys_wdata[4]=1 置位 / 0 清除；sys_wdata[3:0]=DAIF 掩码
      end
    end else if ((insn & 32'hffffffe0) inside {32'hd5381280,
                                                32'hd53812c0}) begin
      // SMCR_EL1（op2=6，S3_0_C1_C2_6）与 SMPRI_EL1（op2=4，
      // S3_0_C1_C2_4）：P6 仅需让 Linux 的 SME 探测按 QEMU 语义
      // 继续。QEMU 11.1 SMIDR_EL1.SMPS=0，SMPRI_EL1 为 RES0；
      // SMCR_EL1 返回已保存的 LEN。真正的 SME 向量状态留在 P8。
      d.sys_op = SYS_MRS;
      d.sys_reg = (insn[7:5] == 3'd6) ? SREG_SMCR_EL1 : SREG_SMPRI_EL1;
      d.wb_sel = 2'd1;
      d.wb_rd = insn[4:0];
      d.wb_we = (insn[4:0] != 5'd31);
      d.wb_extra = (insn[7:5] == 3'd6) ? smcr_el1 : 64'd0;
    end else if (insn[31:22] == 10'b1101010100 &&
                 insn[20:19] != 2'b00) begin
      // MRS / MSR（SYS 编码，见 QEMU a64.decode SYS 模式）
      automatic logic [1:0] op0 = insn[20:19];
      automatic logic [2:0] op1 = insn[18:16];
      automatic logic [3:0] crn = insn[15:12];
      automatic logic [3:0] crm = insn[11:8];
      automatic logic [2:0] op2 = insn[7:5];
      automatic logic [4:0] rt  = insn[4:0];
      d.sys_reg = SREG_NONE;
      if (op0 == 2'b01) begin
        // M2-4b：缓存/TLB 维护指令（SYS 空间 op0=01）。
        // 编码见 QEMU helper.c v8_cp_reginfo（探针实测全部被 QEMU 接受）：
        //   IC IALLUIS (1,0,7,1,0) / IC IALLU (1,0,7,5,0)
        //   IC IVAU (1,3,7,5,1)    / DC IVAC (1,0,7,6,1)
        //   DC ISW (1,0,7,6,2)     / DC CVAC (1,3,7,10,1)
        //   DC CVAU (1,3,7,11,1)   / DC CIVAC (1,3,7,14,1)
        //   TLBI VMALLE1IS (1,0,8,3,0) / VMALLE1 (1,0,8,7,0)
        //   TLBI VAE1IS (1,0,8,1,0)
        automatic maint_op_t mop;
        automatic logic el0_maint_class;
        mop = MAINT_NONE;
        d.maint_at_regime = MAINT_AT_E1;
        // Each maintenance tuple is matched in full.  In particular, op1=4
        // is the EL2 TLBI/AT space and must not alias the implemented EL1
        // forms when QEMU has EL2 disabled.
        if (crn == 4'd7 && crm == 4'd8 && op1 == 3'd0 &&
            op2 inside {3'd0, 3'd1, 3'd2, 3'd3}) begin
          mop = MAINT_AT;
          d.maint_at_regime = (op2 >= 3'd2) ? MAINT_AT_E0 : MAINT_AT_E1;
        end else if (crn == 4'd7 && crm == 4'd9 && op1 == 3'd0 &&
                     op2 inside {3'd0, 3'd1}) begin
          mop = MAINT_AT;
          // QEMU selects the PAN translation regime for the P forms only
          // when PSTATE.PAN is set; the core applies that gate at MMU input.
          d.maint_at_regime = MAINT_AT_E1_PAN;
        end else if (crn == 4'd7 && crm == 4'd1 && op1 == 3'd0 &&
                     op2 == 3'd0) mop = MAINT_IC_IALLU;   // IC IALLUIS
        else if (crn == 4'd7 && crm == 4'd5 && op1 == 3'd0 &&
                 op2 == 3'd0) mop = MAINT_IC_IALLU;       // IC IALLU
        else if (crn == 4'd7 && crm == 4'd5 && op1 == 3'd3 &&
                 op2 == 3'd1) mop = MAINT_IC_IVAU;        // IC IVAU
        else if (crn == 4'd7 && crm == 4'd6 && op1 == 3'd0 &&
                 op2 == 3'd1) mop = MAINT_DC_IVAC;        // DC IVAC
        else if (crn == 4'd7 && crm == 4'd6 && op1 == 3'd0 &&
                 op2 == 3'd2) mop = MAINT_DC_ISW;         // DC ISW
        else if (crn == 4'd7 && crm == 4'd10 && op1 == 3'd3 &&
                 op2 == 3'd1) mop = MAINT_DC_CVAC;        // DC CVAC
        else if (crn == 4'd7 && crm == 4'd11 && op1 == 3'd3 &&
                 op2 == 3'd1) mop = MAINT_DC_CVAU;        // DC CVAU
        else if (crn == 4'd7 && crm == 4'd12 && op1 == 3'd3 &&
                 op2 == 3'd1) mop = MAINT_DC_CVAP;        // DC CVAP (v8.2)
        else if (crn == 4'd7 && crm == 4'd14 && op1 == 3'd3 &&
                 op2 == 3'd1) mop = MAINT_DC_CIVAC;       // DC CIVAC
        else if (crn == 4'd7 && crm == 4'd4 && op1 == 3'd3 &&
                 op2 == 3'd1) mop = MAINT_DC_ZVA;         // DC ZVA
        else if (crn == 4'd8 && op1 == 3'd0 &&
                 crm inside {4'd3, 4'd7} &&
                 op2 inside {3'd0, 3'd1, 3'd2, 3'd3, 3'd5, 3'd7})
          mop = MAINT_TLBI;
        // TLBI EL1 全集（P6 对齐 QEMU tlb-insns.c：VMALLE1/VAE1/ASIDE1/
        // VAAE1/VALE1/VAALE1 各含 IS 与非 IS 变体）。DUT 统一按整表失效
        // 超集语义（架构允许），op2=4/6 在 QEMU 表外保留 UDEF。
        if (mop != MAINT_NONE) begin
          // QEMU PL0 cache operations trap to EL1 (EC=0x18) when UCI=0;
          // PL1-only AT/TLBI/IC-IALLU/DC-IVAC/ISW remain UDEF at EL0.
          el0_maint_class = (mop inside {MAINT_IC_IVAU, MAINT_DC_CVAU,
                                         MAINT_DC_CVAC, MAINT_DC_CIVAC,
                                         MAINT_DC_CVAP, MAINT_DC_ZVA});
          if (!el && mop == MAINT_AT) begin
            d.valid = 1'b0;   // AT is PL1_W
          end else if (!el && !el0_maint_class) begin
            d.valid = 1'b0;   // remaining maintenance forms are PL1-only
          end else if (!el &&
                       ((mop == MAINT_DC_ZVA && !sctlr_el1[14]) ||
                        (mop != MAINT_DC_ZVA && !sctlr_el1[26]))) begin
            // QEMU aa64_zva_access：EL0 DC ZVA 由 SCTLR_EL1.DZE(bit14)
            // 门控；其它 EL0 cache operations 由 SCTLR_EL1.UCI(bit26)
            // 门控。未打开时 System Register Trap EC=0x18，不是 UDEF。
            d.sys_op = SYS_NONE;
            d.maint_op = MAINT_NONE;
            d.exc = 1'b1;
            d.exc_code = EXC_SYSREG_TRAP;
            d.exc_elr = pc;
            // syn_aa64_sysregtrap(): EC=0x18, IL=1, ISS layout matches the
            // timer gate path above, including Rt and direction.
            d.exc_esr = 32'h6200_0000 |
                        (insn[21] ? 32'h0000_0001 : 32'd0) |
                        ({28'd0, crm} << 1) |
                        ({27'd0, rt} << 5) |
                        ({28'd0, crn} << 10) |
                        ({29'd0, op1} << 14) |
                        ({29'd0, op2} << 17) |
                        ({30'd0, op0} << 20);
          end else begin
            d.sys_op   = SYS_MAINT;
            d.maint_op = mop;
            d.maint_va = rdg(rt);  // IC IVAU / DC * 用 Xt 作为维护 VA
            d.maint_write = (mop == MAINT_AT) && op2[0];
            d.rs1 = rt;
            d.rs1_en = (rt != 5'd31);
          end
        end else begin
          d.valid = 1'b0;   // SYS 空间中未识别编码 -> UDEF
        end
      end else begin
        if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd12 && crm == 4'd0 &&
            op2 == 3'd0) begin
          d.sys_reg = SREG_VBAR_EL1;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd12 &&
                     crm == 4'd1 && op2 inside {3'd0, 3'd1}) begin
          d.sys_reg = (op2 == 3'd0) ? SREG_ISR_EL1 : SREG_DISR_EL1;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd4 &&
                     crm == 4'd0 && op2 == 3'd1) begin
          d.sys_reg = SREG_ELR_EL1;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd4 &&
                     crm == 4'd0 && op2 == 3'd0) begin
          d.sys_reg = SREG_SPSR_EL1;
        end else if (op0 == 2'b11 && op1 == 3'd3 && crn == 4'd4 &&
                     crm == 4'd2 && op2 == 3'd0) begin
          d.sys_reg = SREG_NZCV;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd1 &&
                     crm == 4'd0 && op2 == 3'd0) begin
          d.sys_reg = SREG_SCTLR_EL1;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd2 &&
                     crm == 4'd0 && op2 == 3'd2) begin
          d.sys_reg = SREG_TCR_EL1;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd2 &&
                     crm == 4'd0 && op2 == 3'd0) begin
          d.sys_reg = SREG_TTBR0_EL1;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd2 &&
                     crm == 4'd0 && op2 == 3'd1) begin
          d.sys_reg = SREG_TTBR1_EL1;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd10 &&
                     crm == 4'd2 && op2 == 3'd0) begin
          d.sys_reg = SREG_MAIR_EL1;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd5 &&
                     crm == 4'd2 && op2 == 3'd0) begin
          d.sys_reg = SREG_ESR_EL1;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd6 &&
                     crm == 4'd0 && op2 == 3'd0) begin
          d.sys_reg = SREG_FAR_EL1;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd4 &&
                     crm == 4'd2 && op2 == 3'd2) begin
          d.sys_reg = SREG_CURRENTEL;          // 只读
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd0 && op2 == 3'd0) begin
          d.sys_reg = SREG_MIDR_EL1;           // 只读 ID
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd0 && op2 == 3'd6) begin
          d.sys_reg = SREG_REVIDR_EL1;         // 只读 ID，QEMU=0
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd0 && op2 == 3'd5) begin
          d.sys_reg = SREG_MPIDR_EL1;          // 只读（virt 单核 0x80000000）
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd7 &&
                     crm == 4'd4 && op2 == 3'd0) begin
          d.sys_reg = SREG_PAR_EL1;            // AT 结果寄存器
        end else if (op0 == 2'b11 && op1 == 3'd3 && crn == 4'd4 &&
                     crm == 4'd2 && op2 == 3'd1) begin
          d.sys_reg = SREG_DAIF;               // PSTATE.DAIF
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd4 && op2 == 3'd0) begin
          d.sys_reg = SREG_ID_PFR0;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd4 && op2 == 3'd1) begin
          d.sys_reg = SREG_ID_PFR1;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd4 && op2 == 3'd2) begin
          d.sys_reg = SREG_ID_PFR2_AA64;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd5 && op2 == 3'd0) begin
          d.sys_reg = SREG_ID_DFR0;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd5 && op2 == 3'd1) begin
          d.sys_reg = SREG_ID_DFR1;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd5 && op2 == 3'd4) begin
          d.sys_reg = SREG_ID_AFR0_AA64;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd5 && op2 == 3'd5) begin
          d.sys_reg = SREG_ID_AFR1_AA64;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd6 && op2 == 3'd0) begin
          d.sys_reg = SREG_ID_ISAR0;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd6 && op2 == 3'd1) begin
          d.sys_reg = SREG_ID_ISAR1;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd6 && op2 == 3'd2) begin
          d.sys_reg = SREG_ID_ISAR2;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd6 && op2 == 3'd3) begin
          d.sys_reg = SREG_ID_ISAR3_AA64;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd7 && op2 == 3'd0) begin
          d.sys_reg = SREG_ID_MMFR0;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd7 && op2 == 3'd1) begin
          d.sys_reg = SREG_ID_MMFR1;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd7 && op2 == 3'd2) begin
          d.sys_reg = SREG_ID_MMFR2;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd7 && op2 == 3'd3) begin
          d.sys_reg = SREG_ID_MMFR3;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd7 && op2 == 3'd4) begin
          d.sys_reg = SREG_ID_MMFR4_AA64;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd4 && op2 == 3'd4) begin
          d.sys_reg = SREG_ID_ZFR0;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd4 && op2 == 3'd5) begin
          d.sys_reg = SREG_ID_SMFR0;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd4 && op2 == 3'd7) begin
          d.sys_reg = SREG_ID_FPFR0_AA64;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd1 && op2 == 3'd0) begin
          d.sys_reg = SREG_ID_PFR0_A32;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd1 && op2 == 3'd1) begin
          d.sys_reg = SREG_ID_PFR1_A32;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd1 && op2 == 3'd2) begin
          d.sys_reg = SREG_ID_DFR0_A32;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd1 && op2 == 3'd3) begin
          d.sys_reg = SREG_ID_AFR0_A32;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd1 && op2 == 3'd4) begin
          d.sys_reg = SREG_ID_MMFR0_A32;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd1 && op2 == 3'd5) begin
          d.sys_reg = SREG_ID_MMFR1_A32;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd1 && op2 == 3'd6) begin
          d.sys_reg = SREG_ID_MMFR2_A32;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd1 && op2 == 3'd7) begin
          d.sys_reg = SREG_ID_MMFR3_A32;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd2 && op2 == 3'd0) begin
          d.sys_reg = SREG_ID_ISAR0_A32;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd2 && op2 == 3'd1) begin
          d.sys_reg = SREG_ID_ISAR1_A32;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd2 && op2 == 3'd2) begin
          d.sys_reg = SREG_ID_ISAR2_A32;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd2 && op2 == 3'd3) begin
          d.sys_reg = SREG_ID_ISAR3_A32;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd2 && op2 == 3'd4) begin
          d.sys_reg = SREG_ID_ISAR4_A32;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd2 && op2 == 3'd5) begin
          d.sys_reg = SREG_ID_ISAR5_A32;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd2 && op2 == 3'd6) begin
          d.sys_reg = SREG_ID_MMFR4_A32;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd2 && op2 == 3'd7) begin
          d.sys_reg = SREG_ID_ISAR6_A32;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd3 && op2 == 3'd0) begin
          d.sys_reg = SREG_MVFR0_A32;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd3 && op2 == 3'd1) begin
          d.sys_reg = SREG_MVFR1_A32;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd3 && op2 == 3'd2) begin
          d.sys_reg = SREG_MVFR2_A32;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd3 && op2 == 3'd4) begin
          d.sys_reg = SREG_ID_PFR2_A32;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd3 && op2 == 3'd5) begin
          d.sys_reg = SREG_ID_DFR1_A32;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd3 && op2 == 3'd6) begin
          d.sys_reg = SREG_ID_MMFR5_A32;
        end else if (op0 == 2'b11 && op1 == 3'd1 && crn == 4'd0 &&
                     crm == 4'd0 && op2 == 3'd1) begin
          d.sys_reg = SREG_CLIDR_EL1;
        end else if (op0 == 2'b11 && op1 == 3'd2 && crn == 4'd0 &&
                     crm == 4'd0 && op2 == 3'd0) begin
          // CSSELR_EL1 = S3_2_C0_C0_0（QEMU opc1=2）；低位 Level/Ind 可写
          d.sys_reg = SREG_CSSELR_EL1;
        end else if (op0 == 2'b11 && op1 == 3'd1 && crn == 4'd0 &&
                     crm == 4'd0 && op2 == 3'd6) begin
          // SMIDR_EL1 = S3_1_C0_C0_6：QEMU IMPLEMENTOR/REVISION/SMPS=0
          d.sys_reg = SREG_SMIDR_EL1;
        end else if (op0 == 2'b11 && op1 == 3'd1 && crn == 4'd0 &&
                     crm == 4'd0 && op2 == 3'd7) begin
          // AIDR_EL1 = S3_1_C0_C0_7：QEMU IMPDEF 恒 0
          d.sys_reg = SREG_AIDR_EL1;
        end else if (op0 == 2'b11 && op1 == 3'd3 && crn == 4'd2 &&
                     crm == 4'd4 && op2 inside {3'd0, 3'd1}) begin
          // RNDR/RNDRRS（S3_3_C2_C4_0/1）：真实值随机无法差分，
          // P6 与 QEMU fork 钩子一致返回“当前指令可见计数”；
          // NZCV=0000 由核心在提交时置位（QEMU rndr_readfn 语义）。
          d.sys_reg = (op2 == 3'd0) ? SREG_RNDR : SREG_RNDRRS;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd1 &&
                     crm == 4'd2 && op2 == 3'd0) begin
          d.sys_reg = SREG_ZCR_EL1;            // P6：仅保存 VL 控制低 4 位
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd1 &&
                     crm == 4'd0 && op2 == 3'd3) begin
          d.sys_reg = SREG_SCTLR2_EL1;         // P6 probe shim：RAZ/WI
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd2 &&
                     crm inside {4'd1, 4'd2, 4'd3} && op2 <= 3'd3) begin
          // APIA/B, APDA/B、APGA key low/high：P6 先作 RAZ/WI，
          // PACIASP/PACIBSP 已按 NOP 兼容；不把 key 状态伪装成架构可见。
          d.sys_reg = SREG_PAUTH_KEY;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd1 &&
                     crm == 4'd2 && op2 inside {3'd4, 3'd6}) begin
          // P6：op2=6 为 SMCR_EL1（有状态），op2=4 为 SMPRI_EL1（RES0）
          d.sys_reg = (op2 == 3'd6) ? SREG_SMCR_EL1 : SREG_SMPRI_EL1;
        end else if (op0 == 2'b11 && op1 == 3'd3 && crn == 4'd0 &&
                     crm == 4'd0 && op2 == 3'd1) begin
          d.sys_reg = SREG_CTR_EL0;            // 只读
        end else if (op0 == 2'b11 && op1 == 3'd3 && crn == 4'd0 &&
                     crm == 4'd0 && op2 == 3'd7) begin
          d.sys_reg = SREG_DCZID_EL0;          // 只读（P6 Linux 启动）
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd1 &&
                     crm == 4'd0 && op2 == 3'd2) begin
          d.sys_reg = SREG_CPACR_EL1;   // QEMU：op2=2（S3_0_C1_C0_2）
        end else if (op0 == 2'b11 && op1 == 3'd3 && crn == 4'd4 &&
                     crm == 4'd4 && op2 inside {3'd0, 3'd1}) begin
          // P7-0：FPCR/FPSR（S3_3_C4_C4_0/1）。权限由 FPEN 决定，
          // 不能落入普通 EL0 system-register UDEF 路径。
          d.sys_reg = (op2 == 3'd0) ? SREG_FPCR : SREG_FPSR;
        end else if (op0 == 2'b10 && op1 == 3'd0 && crn == 4'd0 &&
                     crm == 4'd2 && op2 == 3'd2) begin
          d.sys_reg = SREG_MDSCR_EL1;
        end else if (op0 == 2'b11 && op1 == 3'd3 && crn == 4'd9 &&
                     crm == 4'd14 && op2 == 3'd0) begin
          d.sys_reg = SREG_PMUSERENR_EL0;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd14 &&
                     crm == 4'd1 && op2 == 3'd0) begin
          d.sys_reg = SREG_CNTKCTL_EL1;
        end else if (op0 == 2'b11 && op1 == 3'd3 && crn == 4'd14 &&
                     crm == 4'd0 && op2 == 3'd0) begin
          d.sys_reg = SREG_CNTFRQ;   // 只读：QEMU virt 1GHz
        end else if (op0 == 2'b11 && op1 == 3'd3 && crn == 4'd13 &&
                     crm == 4'd0 && op2 == 3'd2) begin
          d.sys_reg = SREG_TPIDR_EL0;
        end else if (op0 == 2'b11 && op1 == 3'd3 && crn == 4'd13 &&
                     crm == 4'd0 && op2 == 3'd3) begin
          d.sys_reg = SREG_TPIDRRO_EL0;
        end else if (op0 == 2'b11 && op1 == 3'd3 && crn == 4'd13 &&
                     crm == 4'd0 && op2 == 3'd5) begin
          d.sys_reg = SREG_TPIDR2_EL0;        // P6 SME probe shim：RAZ/WI
        end else if (op0 == 2'b11 && op1 == 3'd3 && crn == 4'd4 &&
                     crm == 4'd2 && op2 == 3'd5) begin
          d.sys_reg = SREG_DIT;               // P6 PSTATE.DIT shim
        end else if (op0 == 2'b11 && op1 == 3'd3 && crn == 4'd4 &&
                     crm == 4'd2 && op2 == 3'd1) begin
          d.sys_reg = SREG_SSBS;              // PSTATE.SSBS（bit12）
        end else if (op0 == 2'b11 && op1 == 3'd3 && crn == 4'd4 &&
                     crm == 4'd2 && op2 == 3'd4) begin
          d.sys_reg = SREG_TCO;               // PSTATE.TCO（bit25）
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd4 &&
                     crm == 4'd3 && op2 == 3'd0) begin
          d.sys_reg = SREG_ALLINT;             // PSTATE.ALLINT（bit13）
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd4 &&
                     crm == 4'd2 && op2 == 3'd3) begin
          d.sys_reg = SREG_UAO;               // PSTATE.UAO（bit9）
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd4 &&
                     crm == 4'd2 && op2 == 3'd4) begin
          d.sys_reg = SREG_PAN;               // PSTATE.PAN（bit22）
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd13 &&
                     crm == 4'd0 && op2 == 3'd1) begin
          // CONTEXTIDR_EL1（S3_0_C13_C0_1）：EL1 RW，reset 0。
          d.sys_reg = SREG_CONTEXTIDR_EL1;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd13 &&
                     crm == 4'd0 && op2 == 3'd4) begin
          d.sys_reg = SREG_TPIDR_EL1;   // per-cpu 指针（QEMU S3_0_C13_C0_4）
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd2 &&
                     crm == 4'd0 && op2 == 3'd3) begin
          d.sys_reg = SREG_TCR2_EL1;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd10 &&
                     crm == 4'd2 && op2 == 3'd3) begin
          d.sys_reg = SREG_PIR_EL1;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd10 &&
                     crm == 4'd2 && op2 == 3'd2) begin
          d.sys_reg = SREG_PIRE0_EL1;
        end else if (op0 == 2'b11 && op1 == 3'd4 && crn == 4'd1 &&
                     crm == 4'd0 && op2 == 3'd0) begin
          d.sys_reg = SREG_SCTLR_EL2;
        end else if (op0 == 2'b11 && op1 == 3'd4 && crn == 4'd1 &&
                     crm == 4'd1 && op2 == 3'd0) begin
          d.sys_reg = SREG_HCR_EL2;
        end else if (op0 == 2'b11 && op1 == 3'd4 && crn == 4'd12 &&
                     crm == 4'd0 && op2 == 3'd0) begin
          d.sys_reg = SREG_VBAR_EL2;
        end else if (op0 == 2'b11 && op1 == 3'd0 && crn == 4'd4 &&
                     crm == 4'd1 && op2 == 3'd0) begin
          d.sys_reg = SREG_SP_EL0;   // QEMU：MRS/MSR sp_el0 = S3_0_C4_C1_0
        end else if (op0 == 2'b10 && op1 == 3'd0 && crn == 4'd1 &&
                     (crm == 4'd0 || crm == 4'd1 || crm == 4'd3) &&
                     op2 == 3'd4) begin
          // OSLAR_EL1/OSLSR_EL1/OSDLR_EL1（S2_0_C1_C*_4）：QEMU debug
          // helper；OSLAR 只写，OSLSR 只读，OSDLR RAZ/WI。P6 不实现外部
          // debug 机制，OSLSR 只读复位值 10（QEMU resetvalue）。
          unique case (crm)
            4'd0: d.sys_reg = SREG_OSLAR_EL1;
            4'd1: d.sys_reg = SREG_OSLSR_EL1;
            default: d.sys_reg = SREG_OSDLR_EL1;
          endcase
        end else if (op0 == 2'b10 && op1 == 3'd0 && crn == 4'd0 &&
                     op2 inside {3'd4, 3'd5, 3'd6, 3'd7}) begin
          // DBGBVR[n]/DBGBCR[n]/DBGWVR[n]/DBGWCR[n]（S2_0_C0_Cn_4..7）。
          // Linux early boot 顺序写 0 关闭所有 hardware breakpoint/watchpoint。
          // P6 尚未实现外部 debug 机制，在该关闭用法下统一 RAZ/WI；P9 再
          // 引入有状态比较器与调试异常。crm 是硬件槽位 n，全部接受。
          d.sys_reg = SREG_DBG_MONITOR_EL1;
        end else if (op0 == 2'b11 && op1 == 3'd3 && crn == 4'd14 &&
                     crm == 4'd0 && op2 == 3'd1) begin
          d.sys_reg = SREG_CNTPCT;    // P6 Generic Timer（只读）
        end else if (op0 == 2'b11 && op1 == 3'd3 && crn == 4'd14 &&
                     crm == 4'd0 && op2 == 3'd2) begin
          d.sys_reg = SREG_CNTVCT;
        end else if (op0 == 2'b11 && op1 == 3'd3 && crn == 4'd14 &&
                     crm == 4'd0 && op2 == 3'd5) begin
          d.sys_reg = SREG_CNTPCTSS;  // FEAT_ECV self-synchronizing view
        end else if (op0 == 2'b11 && op1 == 3'd3 && crn == 4'd14 &&
                     crm == 4'd0 && op2 == 3'd6) begin
          d.sys_reg = SREG_CNTVCTSS;  // FEAT_ECV self-synchronizing view
        end else if (op0 == 2'b11 && op1 == 3'd3 && crn == 4'd14 &&
                     crm == 4'd2 && op2 == 3'd0) begin
          d.sys_reg = SREG_CNTP_TVAL;
        end else if (op0 == 2'b11 && op1 == 3'd3 && crn == 4'd14 &&
                     crm == 4'd2 && op2 == 3'd1) begin
          d.sys_reg = SREG_CNTP_CTL;
        end else if (op0 == 2'b11 && op1 == 3'd3 && crn == 4'd14 &&
                     crm == 4'd2 && op2 == 3'd2) begin
          d.sys_reg = SREG_CNTP_CVAL;
        end else if (op0 == 2'b11 && op1 == 3'd3 && crn == 4'd14 &&
                     crm == 4'd3 && op2 == 3'd0) begin
          d.sys_reg = SREG_CNTV_TVAL;
        end else if (op0 == 2'b11 && op1 == 3'd3 && crn == 4'd14 &&
                     crm == 4'd3 && op2 == 3'd1) begin
          d.sys_reg = SREG_CNTV_CTL;
        end else if (op0 == 2'b11 && op1 == 3'd3 && crn == 4'd14 &&
                     crm == 4'd3 && op2 == 3'd2) begin
          d.sys_reg = SREG_CNTV_CVAL;
        end else begin
          d.valid = 1'b0;  // 其他系统寄存器暂不支持 -> UDEF
        end
        // 定时器 EL0 访问不是 UDEF：QEMU gt_* accessfn 在 gate 未置位时
        // 产生 System Register Trap（EC=0x18），并保留 SYS/MRS/MSR 的
        // ISS。这样异常会走真实 EL0->EL1 同步向量，不能静默读 0/写入。
        if (d.valid && !el && (d.sys_reg inside {
              SREG_CNTFRQ, SREG_CNTPCT, SREG_CNTVCT,
              SREG_CNTPCTSS, SREG_CNTVCTSS,
              SREG_CNTP_TVAL, SREG_CNTP_CTL, SREG_CNTP_CVAL,
              SREG_CNTV_TVAL, SREG_CNTV_CTL, SREG_CNTV_CVAL}) &&
            !timer_el0_access_ok(d.sys_reg, cntkctl_el1[1:0],
                                 cntkctl_el1[9:8])) begin
          d.exc = 1'b1;
          d.exc_code = EXC_SYSREG_TRAP;
          d.exc_elr = pc;
          // syn_aa64_sysregtrap(): EC=0x18, IL=1, ISS layout is
          // ISREAD[0], CRM[4:1], RT[9:5], CRN[13:10], OP1[16:14],
          // OP2[19:17], OP0[21:20].
          d.exc_esr = 32'h6200_0000 |
                      (insn[21] ? 32'h0000_0001 : 32'd0) |
                      ({28'd0, crm} << 1) |
                      ({27'd0, rt} << 5) |
                      ({28'd0, crn} << 10) |
                      ({29'd0, op1} << 14) |
                      ({29'd0, op2} << 17) |
                      ({30'd0, op0} << 20);
        end
        // P7-0：FPCR/FPSR 是 FP access，不是普通 system-register trap。
        // 禁止访问在 ID 级作为同步 FP access exception 提交；该指令不产生
        // MRS 写回或 MSR 状态写入，完整 syndrome 由上游提交包保留。
        if (d.valid && (d.sys_reg inside {SREG_FPCR, SREG_FPSR}) &&
            !fp_access_allowed) begin
          d.exc = 1'b1;
          d.exc_code = EXC_FP_ACCESS;
          d.exc_esr = ESR_FP_ACCESS_TRAP;
          d.exc_elr = pc;
        end
        // EL0 访问其它系统寄存器仍为未定义指令（NZCV 除外；EL1
        // 权限矩阵和既有 ID/CTR/DCZID 例外保持不变）。
        // EL0 可读的只读寄存器（CTR_EL0/DCZID_EL0/ID 寄存器）豁免；
        // 其余系统寄存器 EL0 访问为未定义指令
        if (d.sys_reg != SREG_NONE && d.sys_reg != SREG_NZCV && !el &&
            !(d.sys_reg inside {SREG_CTR_EL0, SREG_DCZID_EL0,
                                SREG_MIDR_EL1, SREG_ID_PFR0, SREG_ID_PFR1,
                                SREG_ID_DFR0, SREG_ID_DFR1, SREG_ID_ISAR0,
                                SREG_ID_ISAR1, SREG_ID_MMFR0, SREG_ID_MMFR1,
                                SREG_ID_MMFR2, SREG_ID_MMFR3,
                                SREG_ID_ZFR0,
                                SREG_FPCR, SREG_FPSR,
                                SREG_CNTFRQ, SREG_CNTPCT, SREG_CNTVCT,
                                SREG_CNTPCTSS, SREG_CNTVCTSS,
                                SREG_CNTP_TVAL, SREG_CNTP_CTL, SREG_CNTP_CVAL,
                                SREG_CNTV_TVAL, SREG_CNTV_CTL,
                                SREG_CNTV_CVAL})) begin
          d.valid = 1'b0;
        end
      end
      if (d.valid && d.sys_op != SYS_MAINT) begin
        if (d.sys_reg == SREG_OSLAR_EL1 && insn[21]) begin
          // QEMU debug_helper.c：OSLAR_EL1 是 PL1_W（write-only），
          // 没有 readfn；MRS OSLAR_EL1 应为 UDEF，而不是读 0。
          // MSR OSLAR_EL1 仍然允许（写路径 shim 忽略副作用）。
          d.valid = 1'b0;
        end else if (d.sys_reg == SREG_OSLSR_EL1 && !insn[21]) begin
          // QEMU debug_helper.c：OSLSR_EL1 是 PL1_R（read-only），
          // MSR OSLSR_EL1 应为 UDEF。
          d.valid = 1'b0;
        end else if (insn[21]) begin
          // MRS：读系统寄存器 -> 普通 GPR 写回（wb_extra）
          d.sys_op = SYS_MRS;
          d.wb_sel = 2'd1;
          unique case (d.sys_reg)
            SREG_VBAR_EL1: d.wb_extra = vbar_el1;
            SREG_ELR_EL1:  d.wb_extra = elr_el1;
            SREG_SPSR_EL1: d.wb_extra = spsr_el1;
            SREG_NZCV:     d.wb_extra = 64'(nzcv) << 28;  // [31:28]
            SREG_SCTLR_EL1: d.wb_extra = sctlr_el1 &
                                           64'h0000_0000_FFFF_FFFF;
            SREG_TCR_EL1:   d.wb_extra = tcr_el1;
            SREG_TTBR0_EL1: d.wb_extra = ttbr0_el1;
            SREG_TTBR1_EL1: d.wb_extra = ttbr1_el1;
            SREG_MAIR_EL1:  d.wb_extra = mair_el1;
            SREG_ESR_EL1:   d.wb_extra = {32'd0, esr_el1};
            SREG_FAR_EL1:   d.wb_extra = far_el1;
            SREG_CURRENTEL: d.wb_extra = 64'(el) << 2;   // EL<<2
            SREG_MIDR_EL1:  d.wb_extra = MIDR_EL1_VAL;
            SREG_REVIDR_EL1: d.wb_extra = REVIDR_EL1_VAL;
            SREG_MPIDR_EL1: d.wb_extra = 64'h8000_0000;
            SREG_PAR_EL1:   d.wb_extra = par_el1;
            SREG_DAIF:      d.wb_extra = {54'd0, daif, 6'd0};
            SREG_ID_PFR0:   d.wb_extra = A64_FP_SIMD ? ID_AA64PFR0_VAL
                                                     : ID_AA64PFR0_NOFP_VAL;
            SREG_ID_PFR1:   d.wb_extra = ID_AA64PFR1_VAL;
            SREG_ID_PFR2_AA64: d.wb_extra = ID_AA64PFR2_VAL;
            SREG_ID_DFR0:   d.wb_extra = ID_AA64DFR0_VAL;
            SREG_ID_DFR1:   d.wb_extra = ID_AA64DFR1_VAL;
            SREG_ID_AFR0_AA64: d.wb_extra = ID_AA64AFR0_VAL;
            SREG_ID_AFR1_AA64: d.wb_extra = ID_AA64AFR1_VAL;
            SREG_ID_ISAR0:  d.wb_extra = A64_FP_SIMD ? ID_AA64ISAR0_VAL
                                                     : ID_AA64ISAR0_NOFP_VAL;
            SREG_ID_ISAR1:  d.wb_extra = A64_FP_SIMD ? ID_AA64ISAR1_VAL
                                                     : ID_AA64ISAR1_NOFP_VAL;
            SREG_ID_ISAR2:  d.wb_extra = ID_AA64ISAR2_VAL;
            SREG_ID_ISAR3_AA64: d.wb_extra = ID_AA64ISAR3_VAL;
            SREG_ID_MMFR0:  d.wb_extra = ID_AA64MMFR0_VAL;
            SREG_ID_MMFR1:  d.wb_extra = ID_AA64MMFR1_VAL;
            SREG_ID_MMFR2:  d.wb_extra = ID_AA64MMFR2_VAL;
            SREG_ID_MMFR3:  d.wb_extra = ID_AA64MMFR3_VAL;
            SREG_ID_MMFR4_AA64: d.wb_extra = ID_AA64MMFR4_VAL;
            SREG_ID_ZFR0:   d.wb_extra = ID_AA64ZFR0_VAL;
            SREG_ID_SMFR0:  d.wb_extra = ID_AA64SMFR0_VAL;
            SREG_ID_FPFR0_AA64: d.wb_extra = ID_AA64FPFR0_VAL;
            SREG_ID_DFR0_A32: d.wb_extra = ID_DFR0_A32_VAL;
            SREG_ID_DFR1_A32: d.wb_extra = ID_DFR1_A32_VAL;
            SREG_ID_PFR0_A32: d.wb_extra = ID_PFR0_A32_VAL;
            SREG_ID_PFR1_A32: d.wb_extra = ID_PFR1_A32_VAL;
            SREG_ID_AFR0_A32: d.wb_extra = ID_AFR0_A32_VAL;
            SREG_ID_MMFR0_A32: d.wb_extra = ID_MMFR0_A32_VAL;
            SREG_ID_MMFR1_A32: d.wb_extra = ID_MMFR1_A32_VAL;
            SREG_ID_MMFR2_A32: d.wb_extra = ID_MMFR2_A32_VAL;
            SREG_ID_MMFR3_A32: d.wb_extra = ID_MMFR3_A32_VAL;
            SREG_ID_ISAR0_A32: d.wb_extra = ID_ISAR0_A32_VAL;
            SREG_ID_ISAR1_A32: d.wb_extra = ID_ISAR1_A32_VAL;
            SREG_ID_ISAR2_A32: d.wb_extra = ID_ISAR2_A32_VAL;
            SREG_ID_ISAR3_A32: d.wb_extra = ID_ISAR3_A32_VAL;
            SREG_ID_ISAR4_A32: d.wb_extra = ID_ISAR4_A32_VAL;
            SREG_ID_ISAR5_A32: d.wb_extra = A64_FP_SIMD ? ID_ISAR5_A32_VAL
                                                        : ID_ISAR5_A32_NOFP_VAL;
            SREG_ID_MMFR4_A32: d.wb_extra = ID_MMFR4_A32_VAL;
            SREG_ID_ISAR6_A32: d.wb_extra = A64_FP_SIMD ? ID_ISAR6_A32_VAL
                                                        : ID_ISAR6_A32_NOFP_VAL;
            SREG_MVFR0_A32: d.wb_extra = A64_FP_SIMD ? MVFR0_A32_VAL
                                                     : MVFR0_A32_NOFP_VAL;
            SREG_MVFR1_A32: d.wb_extra = A64_FP_SIMD ? MVFR1_A32_VAL
                                                     : MVFR1_A32_NOFP_VAL;
            SREG_MVFR2_A32: d.wb_extra = A64_FP_SIMD ? MVFR2_A32_VAL
                                                     : MVFR2_A32_NOFP_VAL;
            SREG_ID_PFR2_A32: d.wb_extra = ID_PFR2_A32_VAL;
            SREG_ID_MMFR5_A32: d.wb_extra = ID_MMFR5_A32_VAL;
            SREG_CLIDR_EL1: d.wb_extra = CLIDR_EL1_VAL;
            SREG_ZCR_EL1: d.wb_extra = zcr_el1;
            SREG_SMCR_EL1: d.wb_extra = smcr_el1;
            SREG_SMPRI_EL1: d.wb_extra = 64'd0;   // QEMU SMPS=0：RES0
            SREG_SMIDR_EL1: d.wb_extra = 64'd0;   // QEMU IMPLEMENTOR=0
            SREG_AIDR_EL1:  d.wb_extra = 64'd0;   // QEMU IMPDEF RAZ
            // RNDR/RNDRRS：EX 用 timer_count 覆盖（与 CNTPCT 同拍）
            SREG_RNDR, SREG_RNDRRS: d.wb_extra = 64'd0;
            SREG_CSSELR_EL1: d.wb_extra = csselr_el1;
            SREG_CTR_EL0:   d.wb_extra = CTR_EL0_VAL;
            SREG_DCZID_EL0: d.wb_extra = DCZID_EL0_VAL;
            SREG_CNTFRQ:    d.wb_extra = CNTFRQ_HZ;
            SREG_CPACR_EL1: d.wb_extra = cpacr_el1;
            SREG_FPCR:      d.wb_extra = {32'd0, fpcr_read_data};
            SREG_FPSR:      d.wb_extra = {32'd0, fpsr_read_data};
            SREG_MDSCR_EL1: d.wb_extra = mdscr_el1;
            SREG_PMUSERENR_EL0: d.wb_extra = pmuserenr_el0;
            SREG_CNTKCTL_EL1:   d.wb_extra = cntkctl_el1;
            SREG_TPIDR_EL0:     d.wb_extra = tpidr_el0;
            SREG_TPIDRRO_EL0:   d.wb_extra = tpidrro_el0;
            SREG_TPIDR_EL1:     d.wb_extra = tpidr_el1;
            SREG_CONTEXTIDR_EL1: d.wb_extra = contextidr_el1;
            SREG_TCR2_EL1:      d.wb_extra = tcr2_el1;
            SREG_SCTLR2_EL1:    d.wb_extra = 64'd0;
            SREG_PAUTH_KEY:     d.wb_extra = 64'd0;
            SREG_TPIDR2_EL0:   d.wb_extra = 64'd0;
            // QEMU aa64_dit_read 返回 PSTATE 位原位置（bit24）。
            SREG_DIT:          d.wb_extra = dit ? 64'h0100_0000 : 64'd0;
            // QEMU aa64_*_read 同样返回 PSTATE 位原位置。
            SREG_SSBS:         d.wb_extra = ssbs ? 64'h0000_1000 : 64'd0;
            SREG_UAO:          d.wb_extra = uao  ? 64'h0000_0200 : 64'd0;
            SREG_PAN:          d.wb_extra = pan  ? 64'h0040_0000 : 64'd0;
            SREG_TCO:          d.wb_extra = tco  ? 64'h0200_0000 : 64'd0;
            SREG_ALLINT:       d.wb_extra = allint ? 64'h0000_2000 : 64'd0;
            SREG_ISR_EL1:      d.wb_extra = 64'd0;
            SREG_DISR_EL1:     d.wb_extra = 64'd0;
            SREG_PIR_EL1:       d.wb_extra = pir_el1;
            SREG_PIRE0_EL1:     d.wb_extra = pire0_el1;
            SREG_SCTLR_EL2:     d.wb_extra = 64'd0;   // el2 关闭：读 0
            SREG_HCR_EL2:       d.wb_extra = 64'd0;
            SREG_VBAR_EL2:      d.wb_extra = 64'd0;
            SREG_SP_EL0:        d.wb_extra = sp_el0;
            SREG_OSDLR_EL1:     d.wb_extra = 64'd0;
            SREG_OSLAR_EL1:     d.wb_extra = 64'd0;
            // QEMU OSLSR_EL1.resetvalue = 10（0xA）；只读。
            SREG_OSLSR_EL1:     d.wb_extra = 64'd10;
            SREG_DBG_MONITOR_EL1: d.wb_extra = 64'd0;
            // P6 Generic Timer：读值在 EX 计算（计数器随提交变化），
            // 此处占位，EX 级覆盖（见 lcvex_core.sv timer_read）
            SREG_CNTPCT:        d.wb_extra = 64'd0;
            SREG_CNTVCT:        d.wb_extra = 64'd0;
            SREG_CNTPCTSS:      d.wb_extra = 64'd0;
            SREG_CNTVCTSS:      d.wb_extra = 64'd0;
            SREG_CNTP_TVAL:     d.wb_extra = 64'd0;
            SREG_CNTP_CTL:      d.wb_extra = 64'd0;
            SREG_CNTP_CVAL:     d.wb_extra = 64'd0;
            SREG_CNTV_TVAL:     d.wb_extra = 64'd0;
            SREG_CNTV_CTL:      d.wb_extra = 64'd0;
            SREG_CNTV_CVAL:     d.wb_extra = 64'd0;
            default:       d.wb_extra = 64'd0;
          endcase
          d.wb_rd = rt;
          d.wb_we = (rt != 5'd31);
        end else begin
          // MSR：写系统寄存器 -> ID 级提交
          d.sys_op = SYS_MSR;
          d.sys_wdata = rdg(rt);
          d.rs1 = rt;
          d.rs1_en = (rt != 5'd31);
        end
      end
    end else if (insn[31:12] == 20'b11010101000000110011 &&
                 insn[4:0] == 5'b11111 &&
                 ((insn[7:5] inside {3'b100, 3'b101, 3'b110}) ||
                  (insn[7:5] == 3'b111 && insn[11:8] == 4'd0))) begin
      // 屏障：DSB(op2=100)/DMB(101)/ISB(110)/SB(111)，rt=11111。
      // QEMU a64.decode：DSB/DMB 接受任意 domain/types 选项，ISB 接受任意
      // CRm；SB 仅接受 CRm==0000（0xD50330FF）。CRm 非 0 的 op2=111 编码
      // 落在未分配系统空间，应保持 UDEF。
      // 顺序核 + 内存握手下，屏障在 ID 级等前方流水线（含未完成访存）
      // 排空后提交，并把取指重定向到 next_pc 重新取（ISB 冲刷语义）。
      d.sys_op = SYS_BARRIER;
    end else if (insn[31:24] == 8'h1f &&
                 insn[23:22] inside {2'b00, 2'b01, 2'b11}) begin
      // P7-4/B2a：标量 fused multiply-add 四族（FMADD/FMSUB/FNMADD/FNMSUB，
      // FP32/FP64/FP16）。esz=10（保留）不接入；负号映射与 QEMU
      // do_fmadd 一致：bit21=neg_a、bit15=neg_n。
      automatic logic [4:0] rd = insn[4:0];
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] rm = insn[20:16];
      automatic logic [4:0] ra = insn[14:10];
      d.fp_valid = 1'b1;
      d.fp_is_half = (insn[23:22] == 2'b11);
      d.fp_is_double = (insn[23:22] == 2'b01);
      d.fp_wb_we = 1'b1;
      d.fp_rd = rd;
      d.fp_rn = rn;
      d.fp_rn_en = 1'b1;
      d.fp_rm = rm;
      d.fp_rm_en = 1'b1;
      d.fp_ra = ra;
      d.fp_ra_en = 1'b1;
      d.fp_operand_a = v[rn];
      d.fp_operand_b = v[rm];
      d.fp_operand_c = v[ra];
      unique case ({insn[21], insn[15]})
        2'b00: d.fp_op = FP_OP_FMADD;
        2'b01: d.fp_op = FP_OP_FMSUB;
        2'b10: d.fp_op = FP_OP_FNMADD;
        default: d.fp_op = FP_OP_FNMSUB;
      endcase
    end else if (insn[31:24] == 8'h1e && insn[21] &&
                 insn[14:10] == 5'b10000 &&
                 ({insn[23:22], insn[20:15]} inside {
                    {2'b00, 6'b000101},   // S -> D
                    {2'b00, 6'b000111},   // S -> H
                    {2'b01, 6'b000100},   // D -> S
                    {2'b01, 6'b000111},   // D -> H
                    {2'b11, 6'b000100},   // H -> S
                    {2'b11, 6'b000101}})) begin  // H -> D
      // P7-4/P7-5：FCVT 全格式。esz=bits[23:22] 是源格式；op 选目的：
      // 000100->S、000101->D、000111->H。esz=10（保留）保持 UDEF。
      automatic logic [4:0] rd = insn[4:0];
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [1:0] esz = insn[23:22];
      automatic logic [5:0] op6 = insn[20:15];
      d.fp_valid = 1'b1;
      d.fp_op = FP_OP_FCVT;
      d.fp_is_half = (esz == 2'b11);         // 源为 H
      d.fp_fcvt_dst_half = (op6 == 6'b000111);
      // is_double 是“目的 D”或“S/D->H 的源 D”（供执行单元选源格式）。
      d.fp_is_double = (op6 == 6'b000101) ||
                       ((op6 == 6'b000111) && (esz == 2'b01));
      d.fp_wb_we = 1'b1;
      d.fp_rd = rd;
      d.fp_rn = rn;
      d.fp_rn_en = 1'b1;
      d.fp_operand_a = v[rn];
    end else if (insn[31:24] == 8'h1e && insn[21] &&
                 insn[14:10] == 5'b10000 &&
                 (insn[20:15] inside {6'b000011,
                                      6'b001000, 6'b001001, 6'b001010,
                                      6'b001011, 6'b001100, 6'b001110,
                                      6'b001111})) begin
      // P7-5：标量 one-source FSQRT/FRINTN/P/M/Z/A/X/I。esz=00/01/11；
      // esz=10（保留）保持 UDEF。FMOV（op=000000）仍由下方寄存器块处理。
      automatic logic [1:0] esz = insn[23:22];
      automatic logic [5:0] op6 = insn[20:15];
      automatic logic [4:0] rd = insn[4:0];
      automatic logic [4:0] rn = insn[9:5];
      if (esz == 2'b10) begin
        d.valid = 1'b0;
      end else begin
        d.fp_valid = 1'b1;
        d.fp_is_half = (esz == 2'b11);
        d.fp_is_double = (esz == 2'b01);
        d.fp_wb_we = 1'b1;
        d.fp_rd = rd;
        d.fp_rn = rn;
        d.fp_rn_en = 1'b1;
        d.fp_operand_a = v[rn];
        if (op6 == 6'b000011) begin
          d.fp_op = FP_OP_SQRT;
        end else begin
          d.fp_op = FP_OP_FRINT;
          unique case (op6)
            6'b001000: d.fp_rint_mode = 3'd0; // FRINTN
            6'b001001: d.fp_rint_mode = 3'd1; // FRINTP
            6'b001010: d.fp_rint_mode = 3'd2; // FRINTM
            6'b001011: d.fp_rint_mode = 3'd3; // FRINTZ
            6'b001100: d.fp_rint_mode = 3'd4; // FRINTA
            6'b001110: d.fp_rint_mode = 3'd5; // FRINTX
            default:   d.fp_rint_mode = 3'd6; // FRINTI
          endcase
        end
      end
    end else if (insn[31:24] == 8'h1e && insn[21] &&
                 insn[12:10] == 3'b100 && insn[9:5] == 5'd0 &&
                 insn[23:22] inside {2'b00, 2'b01, 2'b11}) begin
      // P7-1/P7-5：FMOV immediate（S/D/H）。FPCR/NZCV 不受影响，标量
      // 写回清除 Vd 高 64 位（FPCR.NEP=0，且 NEP 不在 P7 mask 内）。
      automatic logic [4:0] rd = insn[4:0];
      automatic logic [1:0] esz = insn[23:22];
      d.fp_valid = 1'b1;
      d.fp_op = FP_OP_MOV;
      d.fp_is_half = (esz == 2'b11);
      d.fp_is_double = (esz == 2'b01);
      d.fp_wb_we = 1'b1;
      d.fp_rd = rd;
      d.fp_operand_a = '0;
      if (esz == 2'b11)
        d.fp_operand_a[15:0] = fp_expand_imm_h(insn[20:13]);
      else
        d.fp_operand_a[63:0] = fp_expand_imm(insn[20:13], esz[0]);
    end else if (insn[23:22] inside {2'b00, 2'b01, 2'b11} &&
                 (insn & 32'hff20_fc00) inside {
                   32'h1e20_4000, 32'h1e60_4000, 32'h1ee0_4000,  // FMOV
                   32'h1e20_2800, 32'h1e60_2800, 32'h1ee0_2800,  // FADD
                   32'h1e20_3800, 32'h1e60_3800, 32'h1ee0_3800,  // FSUB
                   32'h1e20_0800, 32'h1e60_0800, 32'h1ee0_0800,  // FMUL
                   32'h1e20_1800, 32'h1e60_1800, 32'h1ee0_1800,  // FDIV
                   32'h1e20_4800, 32'h1e60_4800, 32'h1ee0_4800,  // FMAX
                   32'h1e20_5800, 32'h1e60_5800, 32'h1ee0_5800,  // FMIN
                   32'h1e20_6800, 32'h1e60_6800, 32'h1ee0_6800,  // FMAXNM
                   32'h1e20_7800, 32'h1e60_7800, 32'h1ee0_7800,  // FMINNM
                   32'h1e20_2000, 32'h1e60_2000, 32'h1ee0_2000}) begin  // FCMP
      // P7-1/P7-5：FP32/FP64/FP16 标量寄存器操作。mask 保留 esz 位，
      // esz=10（保留）及其它 SIMD/FP 编码不会被误接入。
      automatic logic [4:0] rd = insn[4:0];
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] rm = insn[20:16];
      automatic logic [31:0] base = insn & 32'hff20_fc00;
      d.fp_valid = 1'b1;
      d.fp_is_half = (insn[23:22] == 2'b11);
      d.fp_is_double = insn[22];
      d.fp_rd = rd;
      d.fp_rn = rn;
      d.fp_rn_en = 1'b1;
      d.fp_rm = rm;
      d.fp_rm_en = 1'b1;
      d.fp_operand_a = v[rn];
      d.fp_operand_b = v[rm];
      if (base inside {32'h1e20_4000, 32'h1e60_4000,
                       32'h1ee0_4000}) begin
        if (rm != 5'd0) begin
          // FMOV (scalar register) has a fixed zero field at [20:16].
          d.valid = 1'b0;
          d.fp_valid = 1'b0;
        end else begin
          d.fp_op = FP_OP_MOV;
          d.fp_wb_we = 1'b1;
          d.fp_rm_en = 1'b0;
        end
      end else if (base inside {32'h1e20_2800, 32'h1e60_2800,
                                32'h1ee0_2800}) begin
        d.fp_op = FP_OP_ADD;
        d.fp_wb_we = 1'b1;
      end else if (base inside {32'h1e20_3800, 32'h1e60_3800,
                                32'h1ee0_3800}) begin
        d.fp_op = FP_OP_SUB;
        d.fp_wb_we = 1'b1;
      end else if (base inside {32'h1e20_0800, 32'h1e60_0800,
                                32'h1ee0_0800}) begin
        d.fp_op = FP_OP_MUL;
        d.fp_wb_we = 1'b1;
      end else if (base inside {32'h1e20_1800, 32'h1e60_1800,
                                32'h1ee0_1800}) begin
        d.fp_op = FP_OP_DIV;
        d.fp_wb_we = 1'b1;
      end else if (base inside {32'h1e20_4800, 32'h1e60_4800,
                                32'h1ee0_4800}) begin
        d.fp_op = FP_OP_FMAX;
        d.fp_wb_we = 1'b1;
      end else if (base inside {32'h1e20_5800, 32'h1e60_5800,
                                32'h1ee0_5800}) begin
        d.fp_op = FP_OP_FMIN;
        d.fp_wb_we = 1'b1;
      end else if (base inside {32'h1e20_6800, 32'h1e60_6800,
                                32'h1ee0_6800}) begin
        d.fp_op = FP_OP_FMAXNM;
        d.fp_wb_we = 1'b1;
      end else if (base inside {32'h1e20_7800, 32'h1e60_7800,
                                32'h1ee0_7800}) begin
        d.fp_op = FP_OP_FMINNM;
        d.fp_wb_we = 1'b1;
      end else begin
        // FCMP register/zero。P7-1 只选择 quiet FCMP；FCMPE(e=1) 保持
        // unsupported，避免把未选编码误宣称为完整 FP compare 集合。
        if (insn[4] || (insn[3] && rm != 5'd0)) begin
          d.valid = 1'b0;
          d.fp_valid = 1'b0;
        end else begin
          d.fp_op = FP_OP_CMP;
          d.fp_wb_we = 1'b0;
          d.set_flags = 1'b1;
          d.fp_cmp_zero = insn[3];
          if (insn[3]) begin
            d.fp_operand_b = '0;
            d.fp_rm_en = 1'b0;
          end
          end
        end
    end else if (insn[30:24] == 7'h1e &&
                 insn[23:22] inside {2'b00, 2'b01} &&
                 insn[21:16] inside {6'b100010, 6'b100011,
                                     6'b000010, 6'b000011,
                                     6'b111000, 6'b111001,
                                     6'b011000, 6'b011001}) begin
      // P7-4：标量整数/定点转换。
      // 100010/100011 = SCVTF/UCVTF（整数 -> FP，整数形式）；
      // 000010/000011 = 同族的定点形式（scale 1..32/1..64）；
      // 111000/111001 = FCVTZS/FCVTZU（FP -> 整数，整数形式）；
      // 011000/011001 = 同族的定点形式。整数形式要求 bits[15:10]==0。
      automatic logic         sf = insn[31];
      automatic logic [5:0]   op6 = insn[21:16];
      automatic logic [4:0]   rd = insn[4:0];
      automatic logic [4:0]   rn = insn[9:5];
      automatic logic         is_fixed = op6 inside {6'b000010, 6'b000011,
                                                     6'b011000, 6'b011001};
      automatic logic         to_fp = op6 inside {6'b100010, 6'b100011,
                                                  6'b000010, 6'b000011};
      automatic logic [6:0]   scale;
      automatic logic [63:0]  int_val;
      if (is_fixed) begin
        // W 定点形式 bit15 固定为 1（QEMU @fcvt32）；X 的 6-bit scale
        // 字段含 bit15。
        if (!sf && !insn[15]) begin
          d.valid = 1'b0;
        end else begin
          scale = sf ? 7'(7'd64 - 7'(insn[15:10]))
                     : 7'(7'd32 - 7'(insn[14:10]));
        end
      end else begin
        if (insn[15:10] != 0) begin
          d.valid = 1'b0;
        end else begin
          scale = 7'd0;
        end
      end
      if (d.valid) begin
        d.fp_valid = 1'b1;
        d.fp_is_double = insn[22];
        d.fp_rn = rn;
        d.fp_rn_en = 1'b1;
        d.fp_conv_shift = scale;
        d.fp_conv_is_32 = !sf;
        d.fp_conv_to_int = !to_fp;
        if (to_fp) begin
          // 整数 -> FP：目的 V。W 源按有/无符号扩展后送 64 位。
          d.fp_wb_we = 1'b1;
          d.fp_rd = rd;
          d.rs1 = rn;
          d.rs1_en = (rn != 5'd31);
          if (!sf) begin
            if (op6[0])
              int_val = {32'd0, gpr[rn][31:0]};       // UCVTF
            else
              int_val = {{32{gpr[rn][31]}}, gpr[rn][31:0]}; // SCVTF
          end else begin
            int_val = gpr[rn];
          end
          d.fp_operand_a = '0;
          d.fp_operand_b = '0;
          d.fp_operand_c = '0;
          d.fp_conv_int = int_val;
          d.fp_op = op6[0] ? FP_OP_UCVTF : FP_OP_SCVTF;
        end else begin
          // FP -> 整数：目的 GPR（W 零扩展由 EX 完成），V 不写。
          d.fp_wb_we = 1'b0;
          d.fp_rd = rd;
          d.wb_we = (rd != 5'd31);
          d.wb_rd = rd;
          d.fp_operand_a = v[rn];
          d.fp_operand_b = '0;
          d.fp_operand_c = '0;
          d.fp_op = op6[0] ? FP_OP_FCVTZU : FP_OP_FCVTZS;
        end
      end
    end else if ((insn & 32'hbfa0_fc00) inside {
                   32'h0e20_d400,  // FADD
                   32'h0ea0_d400,  // FSUB
                   32'h2e20_dc00,  // FMUL
                   32'h0e20_e400,  // FCMEQ (quiet compare)
                   32'h0e20_cc00,  // FMLA (P7-4)
                   32'h0ea0_cc00,  // FMLS (P7-4)
                   // P7-5：4H/8H FP16 three-same（bit22=1 是 H 形状）。
                   32'h0e00_1400,  // FADD 4H/8H（mask 清 bit22）
                   32'h0e80_1400,  // FSUB 4H/8H
                   32'h2e00_1c00,  // FMUL 4H/8H
                   32'h0e00_2400,  // FCMEQ 4H/8H
                   32'h0e00_0c00,  // FMLA 4H/8H（B2a）
                   32'h0e80_0c00,  // FMLS 4H/8H（B2a）
                   // P7-5：2S/4S/2D min/max。
                   32'h0e20_f400, 32'h0e60_f400,  // FMAX
                   32'h0ea0_f400, 32'h0ee0_f400,  // FMIN
                   32'h0e20_c400, 32'h0e60_c400,  // FMAXNM
                   32'h0ea0_c400, 32'h0ee0_c400}) begin // FMINNM
      // P7-3/P7-4/P7-5：受限 Advanced SIMD 浮点 three-same。Q=0 仅接受
      // 2S/4H，Q=1 接受 4S/8H/2D；FP vector 的 bit23 是 opcode 的一部分，
      // double 由 bit22 判定（FSUB 的 2D 编码为 size=11），FP16 形状由
      // base 判定。只接入 FCMEQ；FCMGE/FCMGT 和其它未选 compare 保持
      // UDEF。P7-4 增加 FMLA/FMLS（S/D）；B2a 再把向量 H FMLA/FMLS 接入
      // 同一 three-same 族（4H/8H）。Q(bit30) and D(bit22) select the
      // shape, not the operation family; keep the opcode bits while
      // ignoring both shape bits in the match.
      automatic logic [31:0] base = insn & 32'hbfa0_fc00;
      automatic logic         quad = insn[30];
      automatic logic         dbl  = insn[22];
      automatic logic         half = base inside {32'h0e00_1400,
                                                  32'h0e80_1400,
                                                  32'h2e00_1c00,
                                                  32'h0e00_2400,
                                                  32'h0e00_0c00,
                                                  32'h0e80_0c00};
      automatic logic [4:0]   rd = insn[4:0];
      automatic logic [4:0]   rn = insn[9:5];
      automatic logic [4:0]   rm = insn[20:16];
      d.neon_valid = 1'b1;
      d.neon_fp_valid = 1'b1;
      d.neon_wb_we = 1'b1;
      d.neon_rd = rd;
      d.neon_rn = rn;
      d.neon_rm = rm;
      d.neon_rn_en = 1'b1;
      d.neon_rm_en = 1'b1;
      d.neon_size = half ? 2'd1 : (dbl ? 2'd3 : 2'd2);
      d.neon_fp_is_half = half;
      d.neon_fp_is_double = dbl && !half;
      d.neon_fp_quad = quad;
      d.neon_fp_operand_c = v[rd];
      d.neon_fp_ra_en = (base inside {32'h0e20_cc00, 32'h0ea0_cc00,
                                       32'h0e00_0c00, 32'h0e80_0c00});
      d.neon_operand_a = v[rn];
      d.neon_operand_b = v[rm];
      if (!quad && dbl && !half) begin
        // D.2 is not a valid shape in this encoding family; it would
        // otherwise be mistaken for a scalar-looking vector operation.
        d.valid = 1'b0;
        d.neon_valid = 1'b0;
        d.neon_fp_valid = 1'b0;
      end else begin
        unique case (base)
          32'h0e20_d400, 32'h0e00_1400:
            d.neon_fp_op = NEON_FP_OP_FADD;
          32'h0ea0_d400, 32'h0e80_1400:
            d.neon_fp_op = NEON_FP_OP_FSUB;
          32'h2e20_dc00, 32'h2e00_1c00:
            d.neon_fp_op = NEON_FP_OP_FMUL;
          32'h0e20_e400, 32'h0e00_2400:
            d.neon_fp_op = NEON_FP_OP_FCMEQ;
          32'h0e20_cc00, 32'h0e00_0c00:
            d.neon_fp_op = NEON_FP_OP_FMLA;
          32'h0ea0_cc00, 32'h0e80_0c00:
            d.neon_fp_op = NEON_FP_OP_FMLS;
          32'h0e20_f400, 32'h0e60_f400:
            d.neon_fp_op = NEON_FP_OP_FMAX;
          32'h0ea0_f400, 32'h0ee0_f400:
            d.neon_fp_op = NEON_FP_OP_FMIN;
          32'h0e20_c400, 32'h0e60_c400:
            d.neon_fp_op = NEON_FP_OP_FMAXNM;
          default:       d.neon_fp_op = NEON_FP_OP_FMINNM;
        endcase
      end
    end else if ((insn & 32'hbfbf_fc00) inside {
                   32'h0e21_d800,  // SCVTF（向量整数 -> FP）
                   32'h2e21_d800,  // UCVTF
                   32'h0ea1_b800,  // FCVTZS（向量 FP -> 整数）
                   32'h2ea1_b800,  // FCVTZU
                   // P7-5：two-register misc sqrt/rint（H/S/D）。
                   32'h2eb9_f800, 32'h2ea1_f800, 32'h2ee1_f800,  // FSQRT（H mask 清 bit22）
                   32'h0e39_8800, 32'h0e21_8800, 32'h0e61_8800,  // FRINTN
                   32'h0eb9_8800, 32'h0ea1_8800, 32'h0ee1_8800,  // FRINTP
                   32'h0e39_9800, 32'h0e21_9800, 32'h0e61_9800,  // FRINTM
                   32'h0eb9_9800, 32'h0ea1_9800, 32'h0ee1_9800,  // FRINTZ
                   32'h2e39_8800, 32'h2e21_8800, 32'h2e61_8800,  // FRINTA
                   32'h2e39_9800, 32'h2e21_9800, 32'h2e61_9800,  // FRINTX
                   32'h2eb9_9800, 32'h2ea1_9800, 32'h2ee1_9800}) begin // FRINTI
      // P7-4/P7-5：向量 two-register miscellaneous。转换族仅 S/D
      // （esz=insn[22]）；sqrt/rint 支持 H/S/D（H 形状由 base 判定，
      // bit22 在 H 族中是 opcode 的一部分）。Q=0 仅 2S/4H，Q=1 为
      // 4S/2D/8H；Q=0 的 D 形式保持 UDEF。
      automatic logic [31:0] base = insn & 32'hbfbf_fc00;
      automatic logic         quad = insn[30];
      automatic logic         dbl  = insn[22];
      automatic logic         half = base inside {32'h2eb9_f800,
                                                  32'h0e39_8800,
                                                  32'h0eb9_8800,
                                                  32'h0e39_9800,
                                                  32'h0eb9_9800,
                                                  32'h2e39_8800,
                                                  32'h2e39_9800,
                                                  32'h2eb9_9800};
      automatic logic [4:0]   rd = insn[4:0];
      automatic logic [4:0]   rn = insn[9:5];
      d.neon_valid = 1'b1;
      d.neon_fp_valid = 1'b1;
      d.neon_wb_we = 1'b1;
      d.neon_rd = rd;
      d.neon_rn = rn;
      d.neon_rn_en = 1'b1;
      d.neon_size = half ? 2'd1 : (dbl ? 2'd3 : 2'd2);
      d.neon_fp_is_half = half;
      d.neon_fp_is_double = dbl && !half;
      d.neon_fp_quad = quad;
      d.neon_operand_a = v[rn];
      d.neon_fp_ra_en = 1'b0;
      d.neon_fp_operand_c = '0;
      if (!quad && dbl && !half) begin
        // D.2 不是该族合法形状。
        d.valid = 1'b0;
        d.neon_valid = 1'b0;
        d.neon_fp_valid = 1'b0;
      end else begin
        unique case (base)
          32'h0e21_d800: d.neon_fp_op = NEON_FP_OP_SCVTF;
          32'h2e21_d800: d.neon_fp_op = NEON_FP_OP_UCVTF;
          32'h0ea1_b800: d.neon_fp_op = NEON_FP_OP_FCVTZS;
          32'h2ea1_b800: d.neon_fp_op = NEON_FP_OP_FCVTZU;
          32'h2eb9_f800, 32'h2ea1_f800, 32'h2ee1_f800:
            d.neon_fp_op = NEON_FP_OP_SQRT;
          32'h0e39_8800, 32'h0e21_8800, 32'h0e61_8800: begin
            d.neon_fp_op = NEON_FP_OP_FRINT;
            d.neon_fp_rint_mode = 3'd0;   // FRINTN
          end
          32'h0eb9_8800, 32'h0ea1_8800, 32'h0ee1_8800: begin
            d.neon_fp_op = NEON_FP_OP_FRINT;
            d.neon_fp_rint_mode = 3'd1;   // FRINTP
          end
          32'h0e39_9800, 32'h0e21_9800, 32'h0e61_9800: begin
            d.neon_fp_op = NEON_FP_OP_FRINT;
            d.neon_fp_rint_mode = 3'd2;   // FRINTM
          end
          32'h0eb9_9800, 32'h0ea1_9800, 32'h0ee1_9800: begin
            d.neon_fp_op = NEON_FP_OP_FRINT;
            d.neon_fp_rint_mode = 3'd3;   // FRINTZ
          end
          32'h2e39_8800, 32'h2e21_8800, 32'h2e61_8800: begin
            d.neon_fp_op = NEON_FP_OP_FRINT;
            d.neon_fp_rint_mode = 3'd4;   // FRINTA
          end
          32'h2e39_9800, 32'h2e21_9800, 32'h2e61_9800: begin
            d.neon_fp_op = NEON_FP_OP_FRINT;
            d.neon_fp_rint_mode = 3'd5;   // FRINTX
          end
          default: begin
            d.neon_fp_op = NEON_FP_OP_FRINT;
            d.neon_fp_rint_mode = 3'd6;   // FRINTI
          end
        endcase
      end
    end else if (insn[28:23] == 6'b100010) begin
      // ADD/ADDS/SUB/SUBS（立即数）；Rn/Rd=31 为 SP
      automatic logic [11:0] imm12 = insn[21:10];
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] rd = insn[4:0];
      d.is_32 = ~insn[31];
      d.alu_op = insn[30] ? ALU_SUB : ALU_ADD;
      d.set_flags = insn[29];
      d.operand_a = (rn == 5'd31) ? sp : gpr[rn];
      // 立即数移位 sh=insn[22]：0=无移位，1=LSL#12（QEMU a64.decode
      // ADD_i/SUB_i 的 sh 仅 1 位）。bit23 已被 insn[28:23]==100010
      // 限定为 0；bit23=1 的编码属 ADDG/SUBG（MTE）指令族，不在支持
      // 范围，落入默认分支 UDEF。
      d.operand_b = insn[22] ? {40'd0, imm12, 12'd0} : {52'd0, imm12};
      d.rs1 = rn;
      d.rs1_en = (rn != 5'd31);
      d.wb_rd = rd;
      d.wb_we = (rd != 5'd31);
      // ADD/SUB（S=0）Rd=31 写 SP；ADDS/SUBS（S=1）Rd=31 为 XZR 丢弃
      d.sp_we = (rd == 5'd31) && !insn[29];
    end else if (insn[28:23] == 6'b100101) begin
      // MOVN/MOVZ/MOVK（宽立即数）
      automatic logic [1:0] opc = insn[30:29];
      automatic logic [1:0] hw = insn[22:21];
      automatic logic [15:0] imm16 = insn[20:5];
      automatic logic [4:0] rd = insn[4:0];
      automatic logic [63:0] shift = {58'd0, hw, 4'd0};  // hw * 16
      automatic logic [63:0] imm16x = 64'(imm16);
      automatic logic [63:0] old = rdg(rd);
      automatic logic [63:0] val;
      d.is_32 = ~insn[31];
      unique case (opc)
        2'd0: val = ~(imm16x << shift);                   // MOVN
        2'd2: val = imm16x << shift;                      // MOVZ
        2'd3: val = (old & ~(64'hFFFF << shift)) |
                    (imm16x << shift);                    // MOVK
        default: begin
          // opc=01 为保留编码：未定义指令（不能当写零）
          d.valid = 1'b0;
          val = 64'd0;
        end
      endcase
      d.wb_sel = 2'd1;
      d.wb_extra = d.is_32 ? {32'd0, val[31:0]} : val;
      d.rs1 = rd;
      d.rs1_en = (opc == 2'd3) && (rd != 5'd31);  // MOVK 读旧值
      d.wb_rd = rd;
      d.wb_we = (rd != 5'd31);
      // 32 位宽立即数只允许 hw=0/1，其余为保留编码
      if (d.is_32 && hw > 2'd1) begin
        d.valid = 1'b0;
      end
    end else if (insn[28:23] == 6'b100100) begin
      // 逻辑立即数（位掩码）：AND/ORR/EOR/ANDS；ORR Rn=31 即 MOV 别名。
      // M3：编译器对任意 32 位常量常用（如 mov w3, #0xf0f0f0f0）。
      automatic logic [1:0] opc = insn[30:29];
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] rd = insn[4:0];
      automatic logic [5:0] immr, imms;
      automatic logic [63:0] imm;
      automatic logic [64:0] imm_decode;
      automatic logic imm_ok;
      if (insn[31]) begin
        immr = insn[21:16];
        imms = insn[15:10];
        imm_decode = logic_imm_decode(insn[22], immr, imms);
        imm_ok = imm_decode[64];
      end else begin
        // 32 位形式 immr/imms 仍为 6 位字段（bit21/bit15 参与编码），
        // 仅 immn（bit22）固定为 0
        immr = insn[21:16];
        imms = insn[15:10];
        imm_decode = logic_imm_decode(1'b0, immr, imms);
        imm_ok = (insn[22] == 1'b0) && imm_decode[64];
      end
      imm = imm_decode[63:0];
      if (!imm_ok) begin
        d.valid = 1'b0;   // 保留位掩码编码 -> UDEF
      end else begin
        d.is_32 = ~insn[31];
        d.alu_op = (opc == 2'd3) ? ALU_AND
                                 : alu_op_t'(6'd2 + {4'd0, opc});
        d.set_flags = (opc == 2'd3);
        d.operand_a = rdg(rn);
        d.operand_b = imm;
        d.rs1 = rn;
        d.rs1_en = (rn != 5'd31);
        d.wb_rd = rd;
        d.wb_we = (rd != 5'd31);
      end
    end else if (insn[28:23] == 6'b100110 && insn[30:29] != 2'b11) begin
      // 位域：SBFM(00)/BFM(01)/UBFM(10)。LSR/LSL/ASR 立即数与
      // SXTB/SXTH/SXTW/UBFX 均由编译器频繁生成；BFM（M3）为位域插入，
      // 字段外保留旧 Rd（BFI/BFXIL 别名）。
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] rd = insn[4:0];
      automatic logic [5:0] immr, imms;
      if (insn[31]) begin
        immr = insn[21:16];
        imms = insn[15:10];
      end else begin
        immr = {1'b0, insn[20:16]};
        imms = {1'b0, insn[14:10]};
      end
      if (!insn[31] && (insn[22] || insn[21] || insn[15])) begin
        d.valid = 1'b0;   // 32 位形式 N/immr[5]/imms[5] 必须为 0
      end else if (insn[30:29] == 2'd1) begin
        // BFM（含 BFI/BFXIL 别名）：deposit 到旧 Rd，字段外位保留。
        d.is_32 = ~insn[31];
        d.alu_op = ALU_BFM;
        d.operand_a = rdg(rn);
        d.operand_b = 64'({immr, imms});
        d.operand_c = rdg(rd);   // 旧 Rd（rs3 前递/load-use 一并处理）
        d.rs1 = rn;
        d.rs1_en = (rn != 5'd31);
        d.rs3 = rd;
        d.rs3_en = (rd != 5'd31);
        d.wb_rd = rd;
        d.wb_we = (rd != 5'd31);
      end else begin
        d.is_32 = ~insn[31];
        d.alu_op = (insn[30:29] == 2'd0) ? ALU_SBFM : ALU_UBFM;
        d.operand_a = rdg(rn);
        d.operand_b = 64'({immr, imms});
        d.rs1 = rn;
        d.rs1_en = (rn != 5'd31);
        d.wb_rd = rd;
        d.wb_we = (rd != 5'd31);
      end
    end else if (insn[28:23] == 6'b100111 && insn[30:29] == 2'b00 &&
                 !insn[21]) begin
      // EXTR（32/64 位，QEMU a64.decode extract）：从 {Rn,Rm} 的 lsb
      // 处截取。64 位：N=1、imm=insn[15:10]；32 位：N=0、bit10=0、
      // imm=insn[15:11]。Linux alternatives 把 ror #imm 补丁成 EXTR。
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] rm = insn[20:16];
      automatic logic [4:0] rd = insn[4:0];
      automatic logic [5:0] lsb;
      // QEMU a64.decode：W 形式固定位是 bit15（=0），imm 为 bits[14:10]
      if (!insn[31] && (insn[22] || insn[15])) begin
        d.valid = 1'b0;   // 32 位形式 N 与 bit15 必须为 0
      end else begin
        lsb = insn[31] ? insn[15:10] : {1'b0, insn[14:10]};
        d.is_32 = ~insn[31];
        d.alu_op = ALU_EXTR;
        d.operand_a = rdg(rn);
        d.operand_b = rdg(rm);
        d.operand_c = {58'd0, lsb};
        d.rs1 = rn;
        d.rs1_en = (rn != 5'd31);
        d.rs2 = rm;
        d.rs2_en = (rm != 5'd31);
        d.wb_rd = rd;
        d.wb_we = (rd != 5'd31);
      end
    end else if (insn[30:26] == 5'b00101) begin
      // B / BL
      target = pc + ({{38{insn[25]}}, insn[25:0]} << 2);
      d.next_pc = target;
      if (insn[31]) begin
        d.wb_sel = 2'd1;
        d.wb_extra = pc + 64'd4;
        d.wb_rd = 5'd30;
        d.wb_we = 1'b1;
      end
    end else if (insn[31:25] == 7'b0101010 && insn[4] == 1'b0) begin
      // B.cond
      automatic logic [3:0] cond = insn[3:0];
      target = pc + ({{45{insn[23]}}, insn[23:5]} << 2);
      d.next_pc = cond_taken(cond, nzcv) ? target : pc + 64'd4;
    end else if (insn[30:25] == 6'b011010) begin
      // CBZ / CBNZ
      automatic logic [4:0] rt = insn[4:0];
      automatic logic zero;
      zero = insn[31] ? (rdg(rt) == 64'd0) : (rdg_low(rt, 6'd32) == 32'd0);
      d.rs1 = rt;
      d.rs1_en = (rt != 5'd31);
      target = pc + ({{45{insn[23]}}, insn[23:5]} << 2);
      d.next_pc = (zero == ~insn[24]) ? target : pc + 64'd4;
    end else if (insn[30:25] == 6'b011011) begin
      // TBZ / TBNZ
      automatic logic [4:0] rt = insn[4:0];
      automatic logic [5:0] bit_idx = {insn[31], insn[23:19]};
      d.rs1 = rt;
      d.rs1_en = (rt != 5'd31);
      target = pc + ({{50{insn[18]}}, insn[18:5]} << 2);
      d.next_pc = (rdg_bit(rt, bit_idx) == insn[24]) ? target : pc + 64'd4;
    end else if (insn[31:25] == 7'b1101011 &&
                 insn[20:16] == 5'b11111 &&
                 insn[15:10] == 6'b000000) begin
      // BR / BLR / RET
      unique case (insn[24:21])
        4'b0000: begin                                          // BR
          d.next_pc = rdg(insn[9:5]);
          d.rs1 = insn[9:5];
          d.rs1_en = (insn[9:5] != 5'd31);
        end
        4'b0001: begin                                          // BLR
          d.next_pc = rdg(insn[9:5]);
          d.rs1 = insn[9:5];
          d.rs1_en = (insn[9:5] != 5'd31);
          d.wb_sel = 2'd1;
          d.wb_extra = pc + 64'd4;
          d.wb_rd = 5'd30;
          d.wb_we = 1'b1;
        end
        4'b0010: begin                                           // RET
          // RET Xn：跳转 Rn（bits[9:5]）；Rm 恒为 11111。
          // 内核用 ret x28 / ret x30（默认 x30 的旧实现漏掉非 x30）
          d.next_pc = rdg(insn[9:5]);
          d.rs1 = insn[9:5];
          d.rs1_en = (insn[9:5] != 5'd31);
        end
        default: d.valid = 1'b0;
      endcase
    end else if (insn[29:24] == 6'b011000) begin
      // LDR（literal，PC 相对）：opc=00 LDR W / 01 LDR X / 10 LDRSW /
      // 11 PRFM（按 NOP）。addr = pc + SignExtend(imm19)<<2；
      // PC 恒 4 字节对齐，imm<<2 保持对齐（64 位加载需 8 对齐）。
      automatic logic [1:0] opc = insn[31:30];
      automatic logic [4:0] rt = insn[4:0];
      automatic logic [63:0] imm = {{45{insn[23]}}, insn[23:5]} << 2;
      d.mem_addr = pc + imm;
      if (opc == 2'd3) begin
        ;   // PRFM literal 按 NOP（无缓存提示语义，与 QEMU 一致）
      end else if (opc == 2'd0) begin
        // LDR W：32 位零扩展
        d.is_load = 1'b1;
        d.mem_size = 2'd2;
        d.wb_sel = 2'd2;
        d.wb_rd = rt;
        d.wb_we = (rt != 5'd31);
      end else if (opc == 2'd1) begin
        // LDR X：64 位
        d.is_load = 1'b1;
        d.mem_size = 2'd3;
        d.wb_sel = 2'd2;
        d.wb_rd = rt;
        d.wb_we = (rt != 5'd31);
      end else begin
        // LDRSW：32 位符号扩展
        d.is_load = 1'b1;
        d.mem_size = 2'd2;
        d.ldr_sw = 1'b1;
        d.ldr_x = 1'b1;
        d.wb_sel = 2'd2;
        d.wb_rd = rt;
        d.wb_we = (rt != 5'd31);
      end
    end else if (insn[31:24] == 8'h19 && insn[21] &&
                 (insn[15:10] inside {6'b000100, 6'b001100, 6'b100000})) begin
      // LSE128 LDCLRP/LDSETP/SWPP。QEMU a64.decode 的 rt2 是 bits[20:16]
      // （不是 rt+1）；a/r 在单核 full-barrier 模型中忽略。小端下 rt
      // 是低 64 位、rt2 是高 64 位。QEMU 只拒绝 rt/rt2=31 或相等，
      // rn=31 明确表示 SP。
      automatic logic [5:0] op6 = insn[15:10];
      automatic logic [4:0] rt2 = insn[20:16];
      automatic logic [4:0] rn  = insn[9:5];
      automatic logic [4:0] rt  = insn[4:0];
      automatic logic [63:0] base = (rn == 5'd31) ? sp : gpr[rn];
      d.is_atomic = 1'b1;
      d.is_load = 1'b1;
      d.is_store = 1'b1;
      d.is_pair = 1'b1;
      d.is_32 = 1'b0;
      d.mem_size = 2'd3;
      d.mem_addr = base;
      d.mem_strb = 8'hFF;
      d.mem_wdata = rdg(rt);
      d.mem_wdata2 = rdg(rt2);
      d.rs1 = rn;
      d.rs1_en = (rn != 5'd31);
      d.rs2 = rt;
      d.rs2_en = (rt != 5'd31);
      d.rs3 = rt2;
      d.rs3_en = (rt2 != 5'd31);
      d.wb_sel = 2'd2;
      d.wb_rd = rt;
      d.wb_we = (rt != 5'd31);
      d.wb2_rd = rt2;
      d.wb2_we = (rt2 != 5'd31);
      unique case (op6)
        6'b000100: d.atomic_op = ATOMIC_CLRP;
        6'b001100: d.atomic_op = ATOMIC_SETP;
        6'b100000: d.atomic_op = ATOMIC_SWPP;
        default: begin
          d.valid = 1'b0;
          d.is_atomic = 1'b0;
        end
      endcase
      if ((rt == 5'd31) || (rt2 == 5'd31) || (rt == rt2)) begin
        d.valid = 1'b0;
        d.is_atomic = 1'b0;
      end
    end else if (((insn & 32'hffe0_fc00) inside {
                   32'h4e20_1c00, 32'h4ea0_1c00, 32'h6e20_1c00,
                   32'h4e60_1c00, 32'h4ee0_1c00}) ||
                 ((insn & 32'hff20_fc00) inside {
                   32'h4e20_8400, 32'h6e20_8400,
                   32'h6e20_8c00, 32'h4e20_3c00, 32'h4e20_3400,
                   32'h6e20_3400, 32'h6e20_3c00})) begin
      // P7-2：Q register-form integer operations. The fixed-mask values
      // select only the canonical three-same families below; Q=1 is part of
      // the mask, so D-register forms and unrelated scalar encodings remain
      // UDEF. size is B/H/S/D for arithmetic and compare; logical forms are
      // byte-wise and ignore the architectural size bits.
      automatic logic is_logical = (insn & 32'hffe0_fc00) inside {
          32'h4e20_1c00, 32'h4ea0_1c00, 32'h6e20_1c00,
          32'h4e60_1c00, 32'h4ee0_1c00};
      automatic logic [31:0] base = is_logical
                                     ? (insn & 32'hffe0_fc00)
                                     : (insn & 32'hff20_fc00);
      automatic logic [4:0] rd = insn[4:0];
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] rm = insn[20:16];
      d.neon_valid = 1'b1;
      d.neon_wb_we = 1'b1;
      d.neon_rd = rd;
      d.neon_rn = rn;
      d.neon_rm = rm;
      d.neon_rn_en = 1'b1;
      d.neon_rm_en = 1'b1;
      d.neon_size = insn[23:22];
      d.neon_operand_a = v[rn];
      d.neon_operand_b = v[rm];
      unique case (base)
        32'h4e20_1c00: d.neon_op = NEON_OP_AND;
        32'h4ea0_1c00: d.neon_op = NEON_OP_ORR;
        32'h6e20_1c00: d.neon_op = NEON_OP_EOR;
        32'h4e60_1c00: d.neon_op = NEON_OP_BIC;
        32'h4ee0_1c00: d.neon_op = NEON_OP_ORN;
        32'h4e20_8400: d.neon_op = NEON_OP_ADD;
        32'h6e20_8400: d.neon_op = NEON_OP_SUB;
        32'h6e20_8c00: d.neon_op = NEON_OP_CMEQ;
        32'h4e20_3c00: d.neon_op = NEON_OP_CMGE;
        32'h4e20_3400: d.neon_op = NEON_OP_CMGT;
        32'h6e20_3400: d.neon_op = NEON_OP_CMHI;
        32'h6e20_3c00: d.neon_op = NEON_OP_CMHS;
        default: begin
          d.valid = 1'b0;
          d.neon_valid = 1'b0;
        end
      endcase
    end else if ((insn & 32'hff00_fc00) inside {
                   32'h4f00_5400, 32'h4f00_0400, 32'h6f00_0400,
                   32'h4f00_1400, 32'h6f00_1400} &&
                 insn[23] == 1'b0) begin
      // P7-2：Q immediate non-saturating shifts. immh:immb encodes the
      // element size and the shift distance. The highest set bit of immh
      // selects B/H/S/D; the complete immh:immb range is then checked below
      // (right shift distances 1..8/16/32/64, left shift 0..7/15/31/63).
      automatic logic [31:0] base = insn & 32'hff00_fc00;
      automatic logic [6:0] encoded = {insn[22:19], insn[18:16]};
      automatic logic [1:0] sz;
      automatic logic [6:0] distance;
      automatic logic shift_ok;
      automatic logic immh_ok;
      automatic logic [4:0] rd = insn[4:0];
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [2:0] immh_hi = insn[22:20];
      // immh is the upper four bits of immh:immb, not a one-hot field.
      // Its highest set bit selects B/H/S/D; lower set bits are part of the
      // encoded distance. Only immh=0 is invalid (the range checks below
      // reject distances outside the selected element width).
      immh_ok = (insn[22:19] != 4'd0);
      sz = 2'd0;
      if (immh_hi[2]) sz = 2'd3;
      else if (immh_hi[1]) sz = 2'd2;
      else if (immh_hi[0]) sz = 2'd1;
      else sz = 2'd0;
      distance = 7'd0;
      shift_ok = 1'b0;
      if (immh_ok) begin
        if (base == 32'h4f00_5400) begin
          distance = encoded - (7'd8 << sz);
          shift_ok = (distance < (7'd8 << sz));
        end else begin
          distance = (7'd16 << sz) - encoded;
          shift_ok = (distance != 7'd0) &&
                     (distance <= (7'd8 << sz));
        end
      end
      if (!immh_ok || !shift_ok) begin
        d.valid = 1'b0;
      end else begin
        d.neon_valid = 1'b1;
        d.neon_wb_we = 1'b1;
        d.neon_rd = rd;
        d.neon_rn = rn;
        d.neon_rm = rd;       // SSRA/USRA read the old destination.
        d.neon_rn_en = 1'b1;
        d.neon_rm_en = (base == 32'h4f00_1400 ||
                        base == 32'h6f00_1400);
        d.neon_size = sz;
        d.neon_shift = distance;
        d.neon_operand_a = v[rn];
        d.neon_operand_b = v[rd];
        unique case (base)
          32'h4f00_5400: d.neon_op = NEON_OP_SHL;
          32'h4f00_0400: d.neon_op = NEON_OP_SSHR;
          32'h6f00_0400: d.neon_op = NEON_OP_USHR;
          32'h4f00_1400: d.neon_op = NEON_OP_SSRA;
          default:       d.neon_op = NEON_OP_USRA;
        endcase
      end
    end else if ((insn & 32'hff80_fc00) inside {
                   32'h4f00_0400, 32'h4f00_8400,
                   32'h4f00_e400} && insn[22:19] == 4'd0) begin
      // P7-2：MOVI Q, #imm8 的无符号 byte/halfword/word 形式。imm8
      // 位于 [18:16]:[9:5]；只选 zero-extended .16B/.8H/.4S，避免把
      // modified-immediate 的其它 cmode（MSL、逻辑/浮点布局等）伪装成
      // 普通 move。
      automatic logic [3:0] cmode = insn[15:12];
      automatic logic [7:0] imm8 = {insn[18:16], insn[9:5]};
      d.neon_valid = 1'b1;
      d.neon_op = NEON_OP_MOV;
      d.neon_wb_we = 1'b1;
      d.neon_rd = insn[4:0];
      d.neon_size = (cmode == 4'he) ? 2'd0 :
                    (cmode == 4'h8) ? 2'd1 : 2'd2;
      d.neon_operand_a = 128'd0;
      d.neon_operand_b = 128'd0;
      d.neon_rn_en = 1'b0;
      d.neon_rm_en = 1'b0;
      unique case (cmode)
        4'he: for (int i = 0; i < 16; i++)
                d.neon_operand_a[i * 8 +: 8] = imm8;
        4'h8: for (int i = 0; i < 8; i++)
                d.neon_operand_a[i * 16 +: 16] = {8'd0, imm8};
        default: for (int i = 0; i < 4; i++)
                   d.neon_operand_a[i * 32 +: 32] = {24'd0, imm8};
      endcase
    end else if ((insn & 32'hffc0_0000) inside {
                   32'h3d80_0000, 32'h3dc0_0000}) begin
      // P7-2：single Q unsigned-offset load/store. The architectural 16B
      // transaction is mirrored as two consecutive 8B requests by core;
      // no multi-register/structured/lane/pair encoding is accepted here.
      automatic logic is_load_q = insn[22];
      automatic logic [11:0] imm12 = insn[21:10];
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] rt = insn[4:0];
      automatic logic [63:0] base = (rn == 5'd31) ? sp : gpr[rn];
      d.neon_valid = 1'b1;
      d.neon_op = NEON_OP_MOV;
      d.neon_mem_load = is_load_q;
      d.neon_wb_we = is_load_q;
      d.neon_rd = rt;
      d.neon_rn = rt;
      d.neon_rm = rt;
      d.neon_rn_en = 1'b0;
      d.neon_rm_en = !is_load_q;
      d.neon_operand_a = is_load_q ? 128'd0 : v[rt];
      d.neon_operand_b = is_load_q ? 128'd0 : v[rt];
      d.is_load = is_load_q;
      d.is_store = !is_load_q;
      d.is_pair = 1'b1;
      d.mem_size = 2'd3;
      d.mem_addr = base + (64'(imm12) << 4);
      d.mem_strb = 8'hff;
      d.mem_wdata = v[rt][63:0];
      d.mem_wdata2 = v[rt][127:64];
      d.rs1 = rn;
      d.rs1_en = (rn != 5'd31);
    end else if (insn[31:30] inside {2'b10, 2'b11} &&
                 (insn & 32'h3f00_0000) == 32'h3d00_0000 &&
                 insn[23] == 1'b0 && insn[23:22] inside {2'b00, 2'b01}) begin
      // P7-1：基础单寄存器 FP scalar unsigned-offset load/store。
      // 0xbd.. 是 S，0xfd.. 是 D；bit22=L，imm12 按元素宽度缩放。
      // 与 SIMD Q/结构化访存分离，后者保持 unsupported/UDEF。
      automatic logic        is_load_fp = insn[22];
      automatic logic        dbl = insn[30];
      automatic logic [11:0] imm12 = insn[21:10];
      automatic logic [4:0]  rn = insn[9:5];
      automatic logic [4:0]  rt = insn[4:0];
      automatic logic [63:0] base = (rn == 5'd31) ? sp : gpr[rn];
      d.fp_valid = 1'b1;
      d.fp_op = FP_OP_MOV;
      d.fp_is_double = dbl;
      d.fp_rd = rt;
      d.fp_rn = rt;
      d.fp_rn_en = !is_load_fp;
      d.fp_operand_a = is_load_fp ? '0 : v[rt];
      d.rs1 = rn;
      d.rs1_en = (rn != 5'd31);
      d.mem_addr = base + (64'(imm12) << (dbl ? 3 : 2));
      d.mem_size = dbl ? 2'd3 : 2'd2;
      d.mem_strb = dbl ? 8'hff : 8'h0f;
      if (is_load_fp) begin
        d.is_load = 1'b1;
        d.fp_wb_we = 1'b1;
      end else begin
        d.is_store = 1'b1;
        d.mem_wdata = dbl ? v[rt][63:0] : {32'd0, v[rt][31:0]};
        d.fp_wb_we = 1'b0;
      end
    end else if ((insn & 32'hffa07c00) == 32'h48207c00) begin
      // LSE128 CASP/CASPA/CASPL/CASPAL：Rs:Rs+1 为比较值，
      // Rt:Rt+1 为新值；单核模型下复用原子四阶段事务（低读→高读
      // →低写→高写）。QEMU 只接受偶数寄存器对，奇数编码按 UDEF。
      automatic logic [4:0] rs = insn[20:16];
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] rt = insn[4:0];
      automatic logic [63:0] base = (rn == 5'd31) ? sp : gpr[rn];
      if (rs[0] || rt[0]) begin
        d.valid = 1'b0;
      end else begin
        d.is_atomic = 1'b1;
        d.atomic_op = ATOMIC_CASP;
        d.is_load = 1'b1;
        d.is_store = 1'b1;         // 比较成功时产生两段 Store
        d.is_pair = 1'b1;
        d.is_32 = 1'b0;
        d.mem_size = 2'd3;
        d.mem_addr = base;
        d.mem_strb = 8'hFF;
        d.mem_wdata = rdg(rt);
        d.mem_wdata2 = rdg(rt + 5'd1);
        d.atomic_cmp = rdg(rs);
        d.atomic_cmp2 = rdg(rs + 5'd1);
        d.rs1 = rn;
        d.rs1_en = (rn != 5'd31);
        d.rs2 = rs;
        d.rs2_en = (rs != 5'd31);
        d.rs3 = rs + 5'd1;
        d.rs3_en = (rs + 5'd1 != 5'd31);
        d.rs4 = rt;
        d.rs4_en = (rt != 5'd31);
        d.rs5 = rt + 5'd1;
        d.rs5_en = (rt + 5'd1 != 5'd31);
        d.wb_sel = 2'd2;
        d.wb_rd = rs;
        d.wb_we = (rs != 5'd31);
        d.wb2_rd = rs + 5'd1;
        d.wb2_we = (rs + 5'd1 != 5'd31);
      end
    end else if ((insn & 32'h3fa07c00) == 32'h08a07c00) begin
      // LSE CAS/CASA/CASL/CASAL：读旧值写回 Rs；仅比较相等时把 Rt
      // 写回内存。Acquire/release 位在单发射顺序模型中不改变事务顺序。
      automatic logic [1:0] size = insn[31:30];
      automatic logic [4:0] rs = insn[20:16];
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] rt = insn[4:0];
      automatic logic [63:0] base = (rn == 5'd31) ? sp : gpr[rn];
      d.is_atomic = 1'b1;
      d.atomic_op = ATOMIC_CAS;
      d.is_load = 1'b1;            // 返回旧值，写回 Rs
      d.is_store = 1'b1;           // 比较成功时产生一次 Store
      d.is_32 = (size != 2'd3);
      d.mem_size = size;
      d.mem_addr = base;
      d.mem_strb = strb_for_size(size);
      d.mem_wdata = rdg(rt);       // 比较成功时的新值 Rt
      d.atomic_cmp = rdg(rs);      // 比较值 Rs
      d.rs1 = rn;
      d.rs1_en = (rn != 5'd31);
      d.rs2 = rs;
      d.rs2_en = (rs != 5'd31);
      d.rs3 = rt;
      d.rs3_en = (rt != 5'd31);
      d.wb_sel = 2'd2;
      d.wb_rd = rs;
      d.wb_we = (rs != 5'd31);
    end else if ((insn & 32'h3f200c00) == 32'h38200000) begin
      // LSE LDADD/LDCLR/LDEOR/LDSET/LDSMAX/LDSMIN/LDUMAX/LDUMIN/SWP
      // 及 Rt=XZR 的 ST* 别名。单核顺序模型下统一执行“读旧值→计算
      // →写新值”两阶段事务；a/r acquire/release 位不改变事务顺序。
      automatic logic [1:0] size = insn[31:30];
      automatic logic [4:0] rs = insn[20:16];
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] rt = insn[4:0];
      automatic logic [3:0] op = insn[15:12];
      automatic logic [63:0] base = (rn == 5'd31) ? sp : gpr[rn];
      d.is_atomic = 1'b1;
      unique case (op)
        4'd0: d.atomic_op = ATOMIC_ADD;
        4'd1: d.atomic_op = ATOMIC_CLR;
        4'd2: d.atomic_op = ATOMIC_EOR;
        4'd3: d.atomic_op = ATOMIC_SET;
        4'd4: d.atomic_op = ATOMIC_SMAX;
        4'd5: d.atomic_op = ATOMIC_SMIN;
        4'd6: d.atomic_op = ATOMIC_UMAX;
        4'd7: d.atomic_op = ATOMIC_UMIN;
        4'd8: d.atomic_op = ATOMIC_SWP;
        default: begin
          d.valid = 1'b0;
          d.is_atomic = 1'b0;
        end
      endcase
      d.is_load = (rt != 5'd31);    // ST* 别名不返回旧值
      d.is_store = 1'b1;
      d.is_32 = (size != 2'd3);
      d.mem_size = size;
      d.mem_addr = base;
      d.mem_strb = strb_for_size(size);
      d.mem_wdata = rdg(rs);       // 操作源 Rs
      d.atomic_cmp = 64'd0;
      d.rs1 = rn;
      d.rs1_en = (rn != 5'd31);
      d.rs2 = rs;
      d.rs2_en = (rs != 5'd31);
      d.wb_sel = 2'd2;
      d.wb_rd = rt;
      d.wb_we = (rt != 5'd31);
    end else if (insn[29:27] == 3'b111 && insn[26] == 1'b0 &&
                 insn[25:24] == 2'b01) begin
      // LDR/STR（unsigned immediate，bits[25:24]=01）；Rn=31 为 SP
      automatic logic [1:0] size = insn[31:30];
      automatic logic [1:0] opc = insn[23:22];
      automatic logic [11:0] imm12 = insn[21:10];
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] rt = insn[4:0];
      automatic logic [63:0] base = (rn == 5'd31) ? sp : gpr[rn];
      automatic logic [63:0] imm12x = 64'(imm12);
      d.rs1 = rn;
      d.rs1_en = (rn != 5'd31);
      d.mem_size = size;
      d.mem_addr = base + (imm12x << size);
      d.mem_strb = strb_for_size(size);
      unique case (opc)
        2'b00: begin  // STR
          d.is_store = 1'b1;
          d.rs2 = rt;
          d.rs2_en = (rt != 5'd31);
          // 提交包 mem_wdata 记录实际写入的数据（按宽度截取）
          unique case (size)
            2'd0: d.mem_wdata = {32'd0, rdg_low(rt, 6'd8)};
            2'd1: d.mem_wdata = {32'd0, rdg_low(rt, 6'd16)};
            2'd2: d.mem_wdata = {32'd0, rdg_low(rt, 6'd32)};
            default: d.mem_wdata = rdg(rt);
          endcase
        end
        2'b01: begin  // LDR
          d.is_load = 1'b1;
          d.wb_sel = 2'd2;
          d.wb_rd = rt;
          d.wb_we = (rt != 5'd31);
        end
        2'b10: begin  // LDRSB X / LDRSH X / LDRSW / PRFM（64 位符号扩展）
          if (size == 2'd3) begin
            ;   // PRFM 按 NOP（无缓存提示语义，与 QEMU 一致）
          end else begin
            d.is_load = 1'b1;
            d.ldr_sw = 1'b1;
            d.ldr_x = 1'b1;
            d.wb_sel = 2'd2;
            d.wb_rd = rt;
            d.wb_we = (rt != 5'd31);
          end
        end
        2'b11: begin  // LDRSB W / LDRSH W（32 位符号扩展 + 零扩展）
          if (size inside {2'd0, 2'd1}) begin
            d.is_load = 1'b1;
            d.ldr_sw = 1'b1;
            d.ldr_x = 1'b0;
            d.wb_sel = 2'd2;
            d.wb_rd = rt;
            d.wb_we = (rt != 5'd31);
          end else begin
            d.valid = 1'b0;
          end
        end
        default: d.valid = 1'b0;
      endcase
    end else if (insn[29:27] == 3'b111 && insn[26] == 1'b0 &&
                 insn[25:24] == 2'b00 && insn[21] == 1'b1 &&
                 insn[11:10] == 2'b10) begin
      // LDR/STR（寄存器偏移，M3）：mem[rn + ext(rm,opt) << S?sz:0]。
      // opc=00 STR；01 LDR（sz3=64 位，其余零扩展）；10/11 LDRSB/LDRSH/
      // LDRSW（符号扩展）；opc=10 且 sz=3 为 PRFM（按 NOP）。
      automatic logic [1:0] size = insn[31:30];
      automatic logic [1:0] opc = insn[23:22];
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] rt = insn[4:0];
      automatic logic [4:0] rm = insn[20:16];
      automatic logic [2:0] opt = insn[15:13];
      automatic logic       s = insn[12];
      automatic logic [63:0] base = (rn == 5'd31) ? sp : gpr[rn];
      automatic logic [63:0] off, rmv = rdg(rm);
      // 扩展（opt[1:0]：0=8 位 1=16 位 2=32 位 3=64 位；opt[2]=符号）
      unique case (opt[1:0])
        2'd0: off = opt[2] ? {{56{rmv[7]}},  rmv[7:0]}
                           : {56'd0, rmv[7:0]};
        2'd1: off = opt[2] ? {{48{rmv[15]}}, rmv[15:0]}
                           : {48'd0, rmv[15:0]};
        2'd2: off = opt[2] ? {{32{rmv[31]}}, rmv[31:0]}
                           : {32'd0, rmv[31:0]};
        default: off = rmv;
      endcase
      off = off << (s ? size : 2'd0);
      d.rs1 = rn;
      d.rs1_en = (rn != 5'd31);
      // rm（索引）也是读源：登记 rs2，防止 load/STXR 晚写回时读到
      // 陈旧索引值（与 addsub-ext 同理）
      d.rs2 = rm;
      d.rs2_en = (rm != 5'd31);
      d.mem_size = size;
      d.mem_addr = base + off;
      d.mem_strb = strb_for_size(size);
      if (opc == 2'd0) begin
        // STR / STRB / STRH / STRW
        d.is_store = 1'b1;
        // Keep rs2 for the address index (Rm); store data Rt is a second
        // dependency.  Overwriting rs2 here drops the adjacent producer ->
        // register-offset address hazard (for example mov x23,#7 followed
        // by strh w0,[x20,x23,lsl#1]).
        d.rs3 = rt;
        d.rs3_en = (rt != 5'd31);
        unique case (size)
          2'd0: d.mem_wdata = {32'd0, rdg_low(rt, 6'd8)};
          2'd1: d.mem_wdata = {32'd0, rdg_low(rt, 6'd16)};
          2'd2: d.mem_wdata = {32'd0, rdg_low(rt, 6'd32)};
          default: d.mem_wdata = rdg(rt);
        endcase
      end else if (opc == 2'd1) begin
        // LDR / LDRB / LDRH / LDRW（零扩展）
        d.is_load = 1'b1;
        d.wb_sel = 2'd2;
        d.wb_rd = rt;
        d.wb_we = (rt != 5'd31);
      end else if (opc == 2'd2) begin
        // opc=10：LDRSB/LDRSH X（size 0/1）、LDRSW（size 2）、
        // PRFM（size 3，按 NOP）；全部 64 位符号扩展
        if (size == 2'd3) begin
          ;   // PRFM
        end else begin
          d.is_load = 1'b1;
          d.ldr_sw = 1'b1;
          d.ldr_x = 1'b1;
          d.wb_sel = 2'd2;
          d.wb_rd = rt;
          d.wb_we = (rt != 5'd31);
        end
      end else if (size inside {2'd0, 2'd1}) begin
        // opc=11：LDRSB/LDRSH W（32 位符号扩展，高 32 位清零）
        d.is_load = 1'b1;
        d.ldr_sw = 1'b1;
        d.ldr_x = 1'b0;
        d.wb_sel = 2'd2;
        d.wb_rd = rt;
        d.wb_we = (rt != 5'd31);
      end else begin
        d.valid = 1'b0;
      end
    end else if (insn[29:27] == 3'b111 && insn[26] == 1'b0 &&
                 insn[25:24] == 2'b00 && insn[21] == 1'b0 &&
                 insn[11:10] inside {2'b00, 2'b01, 2'b10, 2'b11}) begin
      // LDUR/STUR（非缩放 9 位有符号偏移，P6 Linux 启动用）与
      // LDR/STR 单寄存器 pre/post-index、LDTR/STTR（非特权访问）：
      //   bits[11:10]=00：unscaled，mem[rn + sign_extend(imm9)]，无写回；
      //   bits[11:10]=01：post-index，mem[rn]，随后 rn += imm9；
      //   bits[11:10]=10：unprivileged（LDTR/STTR），mem[rn+imm9]，
      //                    无写回，权限按 EL0（QEMU 语义）；
      //   bits[11:10]=11：pre-index，mem[rn + imm9]，同时 rn += imm9。
      // opc=00 STUR/STRB 01 LDUR/LDRB 10 LDURSB/LDURSH X/LDURSW/PRFUM
      // 11 LDURSB/LDURSH W。
      automatic logic [1:0] size = insn[31:30];
      automatic logic [1:0] opc = insn[23:22];
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] rt = insn[4:0];
      automatic logic       pre  = (insn[11:10] == 2'b11);
      automatic logic       post = (insn[11:10] == 2'b01);
      automatic logic [63:0] base = (rn == 5'd31) ? sp : gpr[rn];
      automatic logic [63:0] imm9 = {{55{insn[20]}}, insn[20:12]};
      automatic logic [63:0] eff  = post ? base : (base + imm9);
      d.mem_unpriv = (insn[11:10] == 2'b10);
      d.rs1 = rn;
      d.rs1_en = (rn != 5'd31);
      d.mem_size = size;
      d.mem_addr = eff;
      d.mem_strb = strb_for_size(size);
      // pre/post 基址更新：rn <= base + imm9（SP 走 sp 写回通道）
      if (pre || post) begin
        if (rn == 5'd31) begin
          d.sp_we = 1'b1;
        end else begin
          d.wb3_we = 1'b1;
          d.wb3_rd = rn;
        end
        d.wb3_extra = base + imm9;
      end
      if (opc == 2'd0) begin
        d.is_store = 1'b1;
        d.rs2 = rt;
        d.rs2_en = (rt != 5'd31);
        unique case (size)
          2'd0: d.mem_wdata = {32'd0, rdg_low(rt, 6'd8)};
          2'd1: d.mem_wdata = {32'd0, rdg_low(rt, 6'd16)};
          2'd2: d.mem_wdata = {32'd0, rdg_low(rt, 6'd32)};
          default: d.mem_wdata = rdg(rt);
        endcase
      end else if (opc == 2'd1) begin
        d.is_load = 1'b1;
        d.wb_sel = 2'd2;
        d.wb_rd = rt;
        d.wb_we = (rt != 5'd31);
      end else if (opc == 2'd2) begin
        if (size == 2'd3) begin
          ;   // PRFUM 按 NOP
        end else begin
          d.is_load = 1'b1;
          d.ldr_sw = 1'b1;
          d.ldr_x = 1'b1;
          d.wb_sel = 2'd2;
          d.wb_rd = rt;
          d.wb_we = (rt != 5'd31);
        end
      end else if (size inside {2'd0, 2'd1}) begin
        d.is_load = 1'b1;
        d.ldr_sw = 1'b1;
        d.ldr_x = 1'b0;
        d.wb_sel = 2'd2;
        d.wb_rd = rt;
        d.wb_we = (rt != 5'd31);
      end else begin
        d.valid = 1'b0;
      end
    end else if ((((insn[30:27] == 4'b0101) &&
                   (insn[31:30] inside {2'b00, 2'b10})) ||
                  ((insn[30:27] == 4'b1101) &&
                   (insn[31:30] == 2'b01))) &&
                 insn[26] == 1'b0 &&
                 (insn[25:23] inside {3'b000, 3'b001, 3'b010, 3'b011})) begin
      // LDP/STP（GPR 对，M3）与 LDPSW（P6 Linux）：imm:s7 rt2 rn rt。
      //   寻址模式：000/010=offset（000 为 non-temporal，语义同 offset），
      //   001=post-index，011=pre-index；L=insn[22]（1=LDP 0=STP）。
      // 32 位对每元素 4 字节，64 位对每元素 8 字节。
      automatic logic        l = insn[22];
      automatic logic        ldpsw = (insn[31:30] == 2'b01);
      automatic logic        pre  = (insn[25:23] == 3'b011);
      automatic logic        post = (insn[25:23] == 3'b001);
      automatic logic [6:0]  imm7 = insn[21:15];
      automatic logic [63:0] imm  = {{57{imm7[6]}}, imm7} <<
                                    (insn[31] ? 3 : 2);
      automatic logic [4:0]  rn  = insn[9:5];
      automatic logic [4:0]  rt  = insn[4:0];
      automatic logic [4:0]  rt2 = insn[14:10];
      automatic logic [63:0] base = (rn == 5'd31) ? sp : gpr[rn];
      automatic logic [63:0] eff  = post ? base : (base + imm);
      d.rs1 = rn;
      d.rs1_en = (rn != 5'd31);
      d.is_pair = 1'b1;
      // LDPSW 与 W LDP 一样按两个 4 字节访问，但每个结果都符号扩展到 X。
      // size=01 的 store 编码为保留，仍按 UDEF 处理。
      d.mem_size = insn[31] ? 2'd3 : 2'd2;
      d.mem_addr = eff;
      // 提交包按 QEMU 插件语义报单条成对存储（X=16B、W=8B），
      // strb 统一 0xFF；实际 dmem 每段 strb 由核心按元素宽度计算。
      d.mem_strb = 8'hFF;
      // pre/post 基址更新：rn <= base + imm
      if (pre || post) begin
        if (rn == 5'd31) begin
          d.sp_we = 1'b1;        // SP 基址经 sp 写回通道
        end else begin
          d.wb3_we = 1'b1;
          d.wb3_rd = rn;
        end
        d.wb3_extra = base + imm;
      end
      if (ldpsw && !l) begin
        d.valid = 1'b0;
      end else if (l) begin
        // LDP：rt = mem[eff]，rt2 = mem[eff+8/4]
        d.is_load = 1'b1;
        d.ldr_sw = ldpsw;
        d.ldr_x  = ldpsw;
        d.wb_sel = 2'd2;
        d.wb_rd = rt;
        d.wb_we = (rt != 5'd31);
        d.wb2_rd = rt2;
        d.wb2_we = (rt2 != 5'd31);
      end else begin
        // STP：mem[eff] = rt，mem[eff+8/4] = rt2
        d.is_store = 1'b1;
        d.rs2 = rt;
        d.rs2_en = (rt != 5'd31);
        // rt2 也是读源：登记 rs3，使 load-use/前递对 rt2 生效
        //（否则 in-flight 写 rt2 时读到陈旧值，随机回归曾暴露）。
        d.rs3 = rt2;
        d.rs3_en = (rt2 != 5'd31);
        // 提交包按 QEMU 插件语义表示单条成对存储：
        //   X 对 -> u128.low = rt；W 对 -> 64 位组合 {rt2, rt}
        // 实际 dmem 仍分两段写（strb 截断保证段 0 只写 rt）。
        d.mem_wdata = insn[31] ? rdg(rt)
                               : {rdg_low(rt2, 6'd32), rdg_low(rt, 6'd32)};
        d.mem_wdata2 = insn[31] ? rdg(rt2) : {32'd0, rdg_low(rt2, 6'd32)};
      end
    end else if (insn[29:24] == 6'b001000 &&
                 insn[23:21] inside {3'b000, 3'b001, 3'b010,
                                     3'b011, 3'b100, 3'b110}) begin
      // LDXR/LDAXR（bits[23:21]=010）与 STXR/STLXR（000），单寄存器
      // exclusive；LDXP/LDAXP（011）与 STXP/STLXP（001）为 128 位成对
      // 形式（内核 cmpxchg128 使用）。size=insn[31:30]；lasr=insn[15]
      // （acquire/release 变体，单核顺序语义与普通版相同）。编码与
      // QEMU a64.decode @stxr 一致；STLR/LDAR（100/110）按普通顺序
      // load/store 处理（单发射顺序核无需额外栅栏）。
      automatic logic [1:0] size = insn[31:30];
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] rt = insn[4:0];
      automatic logic [4:0] rt2 = insn[14:10];
      automatic logic [63:0] base = (rn == 5'd31) ? sp : gpr[rn];
      automatic logic        pair = insn[23:21] inside {3'b001, 3'b011};
      d.mem_size = size;
      d.mem_addr = base;
      d.mem_strb = strb_for_size(size);
      d.rs1 = rn;
      d.rs1_en = (rn != 5'd31);
      if (insn[23:21] inside {3'b010, 3'b011, 3'b110}) begin
        // LDXR/LDAXR：普通 load，提交时记录监视器（地址 + 加载值）。
        // LDXP/LDAXP：成对 load，监视器记录 128 位值。
        d.is_load = 1'b1;
        d.is_pair = pair;
        d.is_ldxr = (insn[23:21] inside {3'b010, 3'b011});
        d.wb_sel = 2'd2;
        d.wb_rd = rt;
        d.wb_we = (rt != 5'd31);
        if (pair) begin
          d.wb2_rd = rt2;
          d.wb2_we = (rt2 != 5'd31);
        end
      end else begin
        // STXR/STLXR：状态寄存器 rs=bits[20:16]（0=通过 1=失败），
        // 数据寄存器 rt（STXP 还有 rt2）。提交时清监视器；实际写按
        // 读比较结果条件发生（STXP 为 128 位比较，两段读）。
        d.is_store = 1'b1;
        d.is_pair = pair;
        d.is_stxr = (insn[23:21] inside {3'b000, 3'b001});
        d.rs2 = rt;
        d.rs2_en = (rt != 5'd31);
        if (pair) begin
          d.rs3 = rt2;
          d.rs3_en = (rt2 != 5'd31);
          // 与 STP 相同：X 对两段 8B；W 对单笔 8B {rt2,rt}
          d.mem_wdata  = insn[31] ? rdg(rt)
                                  : {rdg_low(rt2, 6'd32), rdg_low(rt, 6'd32)};
          d.mem_wdata2 = insn[31] ? rdg(rt2) : {32'd0, rdg_low(rt2, 6'd32)};
        end else begin
        unique case (size)
          2'd0: d.mem_wdata = {32'd0, rdg_low(rt, 6'd8)};
          2'd1: d.mem_wdata = {32'd0, rdg_low(rt, 6'd16)};
          2'd2: d.mem_wdata = {32'd0, rdg_low(rt, 6'd32)};
          default: d.mem_wdata = rdg(rt);
        endcase
        end
        if (insn[23:21] inside {3'b000, 3'b001}) begin
          d.wb_rd = insn[20:16];
          d.wb_we = (insn[20:16] != 5'd31);
          d.wb_sel = 2'd1;   // WB 级由 stxr 结果覆盖
        end
      end
    end else if (insn[28:24] == 5'b10000) begin
      // ADR / ADRP
      automatic logic [63:0] imm =
          {{43{insn[23]}}, insn[23:5], insn[30:29]};
      d.wb_sel = 2'd1;
      d.wb_extra = insn[31] ? ((pc & ~64'hFFF) + (imm << 12))
                            : (pc + imm);
      d.wb_rd = insn[4:0];
      d.wb_we = (insn[4:0] != 5'd31);
    end else if (insn[28:24] == 5'b11010 &&
                 insn[23:21] == 3'b100 &&
                 (insn[30:29] inside {2'b00, 2'b10}) &&
                 insn[11] == 1'b0) begin
      // CSEL/CSINC/CSINV/CSNEG（Data-processing 2-source 条件选择）：
      //   insn[30:29]=00 && op=0 -> CSEL（条件真取 Rn，假取 Rm）
      //   insn[30:29]=00 && op=1 -> CSINC（假取 Rm+1）
      //   insn[30:29]=10 && op=0 -> CSINV（假取 ~Rm）
      //   insn[30:29]=10 && op=1 -> CSNEG（假取 -Rm）
      //   条件在 ID 级按当前（前递）NZCV 求值，与 B.cond 同一函数；
      //   顺序单发射下等价于 EX 级按架构 NZCV 选择。
      automatic logic [3:0] cond = insn[15:12];
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] rm = insn[20:16];
      automatic logic [4:0] rd = insn[4:0];
      automatic logic [63:0] sel_rm = rdg(rm);
      automatic logic [63:0] sel_else;
      automatic logic cs_inv = (insn[30:29] == 2'b10);  // 1=CSINV/CSNEG
      automatic logic cs_op  = insn[10];                // 1=CSINC/CSNEG
      d.is_32 = ~insn[31];
      unique case ({cs_inv, cs_op})
        2'b00: sel_else = sel_rm;                   // CSEL
        2'b01: sel_else = d.is_32
                    ? {32'd0, sel_rm[31:0] + 32'd1}
                    : (sel_rm + 64'd1);             // CSINC
        2'b10: sel_else = d.is_32
                    ? {32'd0, ~sel_rm[31:0]}
                    : ~sel_rm;                      // CSINV
        default: sel_else = d.is_32
                    ? {32'd0, ~sel_rm[31:0] + 32'd1}
                    : (~sel_rm + 64'd1);            // CSNEG
      endcase
      d.alu_op = ALU_CSEL;
      d.operand_a = cond_taken(cond, nzcv) ? rdg(rn) : sel_else;
      d.rs1 = rn;
      d.rs1_en = (rn != 5'd31);
      d.rs2 = rm;
      d.rs2_en = (rm != 5'd31);
      d.wb_rd = rd;
      d.wb_we = (rd != 5'd31);
    end else if (insn[30:21] == 10'b0011010110 &&
                 insn[15:12] == 4'b0010) begin
      // LSLV/LSRV/ASRV/RORV：变量移位（P6 Linux 启动实证缺口）
      // 编码：sf 0 0 11010110 Rm 001010 Rn Rd，opc=insn[11:10]
      automatic logic [1:0] vop = insn[11:10];
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] rm = insn[20:16];
      automatic logic [4:0] rd = insn[4:0];
      d.is_32 = ~insn[31];
      // ALU 移位对象是 operand_b；变量移位量来自 Rm（含前递视图）
      d.operand_a = rdg(rn);
      d.operand_b = rdg(rn);
      d.use_shift = 1'b1;
      d.shift_amt = rdg_low6(rm);
      d.shift_type = vop;              // 0=LSL 1=LSR 2=ASR 3=ROR
      unique case (vop)
        2'd0: d.alu_op = ALU_LSL;
        2'd1: d.alu_op = ALU_LSR;
        2'd2: d.alu_op = ALU_ASR;
        default: d.alu_op = ALU_ROR;
      endcase
      d.rs1 = rn;
      d.rs1_en = (rn != 5'd31);
      d.rs2 = rm;
      d.rs2_en = (rm != 5'd31);
      d.wb_rd = rd;
      d.wb_we = (rd != 5'd31);
    end else if (insn[30:21] == 10'b0011010110 &&
                 insn[15:11] == 5'b00001) begin
      // UDIV / SDIV（Data-processing 2-source）
      d.is_32 = ~insn[31];
      d.alu_op = insn[10] ? ALU_SDIV : ALU_UDIV;
      d.operand_a = rdg(insn[9:5]);
      d.operand_b = rdg(insn[20:16]);
      d.rs1 = insn[9:5];
      d.rs1_en = (insn[9:5] != 5'd31);
      d.rs2 = insn[20:16];
      d.rs2_en = (insn[20:16] != 5'd31);
      d.wb_rd = insn[4:0];
      d.wb_we = (insn[4:0] != 5'd31);
    end else if (insn[28:21] == 8'b11010000 &&
                 insn[15:10] == 6'b000000) begin
      // ADC/ADCS/SBC/SBCS（带进位/借位；op=bits[30:29]，NGC/NGCS 即
      // Rn=31 的 SBC/SBCS）。Linux syscall 返回路径用 ngc x0,xzr 计算
      // -1 错误码，此前缺失导致 UDEF。
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] rd = insn[4:0];
      d.is_32 = ~insn[31];
      d.alu_op = insn[30] ? ALU_SBC : ALU_ADC;
      d.set_flags = insn[29];
      d.operand_a = rdg(rn);        // NGC/NGCS：Rn=31 -> XZR=0
      d.operand_b = rdg(insn[20:16]);
      d.rs1 = rn;
      d.rs1_en = (rn != 5'd31);
      d.rs2 = insn[20:16];
      d.rs2_en = (insn[20:16] != 5'd31);
      d.wb_rd = rd;
      d.wb_we = (rd != 5'd31);
    end else if (insn[30:21] == 10'b0011011000 &&
                 insn[15] == 1'b0 && insn[14:10] == 5'b11111) begin
      // MUL（MADD Rd, Rn, Rm, XZR；Data-processing 3-source）
      d.is_32 = ~insn[31];
      d.alu_op = ALU_MUL;
      d.operand_a = rdg(insn[9:5]);
      d.operand_b = rdg(insn[20:16]);
      d.rs1 = insn[9:5];
      d.rs1_en = (insn[9:5] != 5'd31);
      d.rs2 = insn[20:16];
      d.rs2_en = (insn[20:16] != 5'd31);
      d.wb_rd = insn[4:0];
      d.wb_we = (insn[4:0] != 5'd31);
    end else if (insn[31] == 1'b1 &&
                 insn[30:23] == 8'b00110110 &&
                 insn[22:21] == 2'b10 &&
                 insn[15:10] == 6'b011111) begin
      // SMULH：64x64 有符号乘积的高 64 位。与 UMULH 共用
      // ALU_UMULH 标记，core 依据 bit23 选择 muldiv 的 signed-high op。
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] rm = insn[20:16];
      automatic logic [4:0] rd = insn[4:0];
      d.is_32 = 1'b0;
      d.alu_op = ALU_UMULH;
      d.operand_a = rdg(rn);
      d.operand_b = rdg(rm);
      d.rs1 = rn;
      d.rs1_en = (rn != 5'd31);
      d.rs2 = rm;
      d.rs2_en = (rm != 5'd31);
      d.wb_rd = rd;
      d.wb_we = (rd != 5'd31);
    end else if (insn[31] == 1'b1 &&
                 insn[30:23] == 8'b00110111 &&
                 insn[22:21] == 2'b10 &&
                 insn[15:10] == 6'b011111) begin
      // UMULH（Data-processing 3-source）：64x64 无符号乘积的高 64 位。
      // 编码与 MADD 族共享高位主类，但 bit22=1、Ra/副操作字段为全 1；
      // 单独识别以避免落入 UDEF 或 MADD 解码。
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] rm = insn[20:16];
      automatic logic [4:0] rd = insn[4:0];
      d.is_32 = 1'b0;
      d.alu_op = ALU_UMULH;
      d.operand_a = rdg(rn);
      d.operand_b = rdg(rm);
      d.rs1 = rn;
      d.rs1_en = (rn != 5'd31);
      d.rs2 = rm;
      d.rs2_en = (rm != 5'd31);
      d.wb_rd = rd;
      d.wb_we = (rd != 5'd31);
    end else if (insn[30:29] == 2'b00 &&
                 (insn[28:23] inside {6'b110110, 6'b110111}) &&
                 insn[22] == 1'b0) begin
      // 乘加族（Data-processing 3-source，M3）：
      //   bit21=0：MADD/MSUB（Rd = Rn*Rm +/- Ra，32/64 位）；
      //   bit21=1 bit23=0：SMADDL/SMSUBL（有符号 32x32 -> 64）；
      //   bit21=1 bit23=1：UMADDL/UMSUBL（无符号 32x32 -> 64）；
      //   bit15=0 加 / 1 减（MSUB 族）。
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] rm = insn[20:16];
      automatic logic [4:0] ra = insn[14:10];
      automatic logic [4:0] rd = insn[4:0];
      d.is_32 = ~insn[31];
      if (insn[21] == 1'b0) begin
        d.alu_op = insn[15] ? ALU_MSUB : ALU_MADD;
      end else if (insn[23] == 1'b0) begin
        d.alu_op = insn[15] ? ALU_SMSUBL : ALU_SMADDL;
      end else begin
        d.alu_op = insn[15] ? ALU_UMSUBL : ALU_UMADDL;
      end
      d.operand_a = rdg(rn);
      d.operand_b = rdg(rm);
      d.operand_c = rdg(ra);
      d.rs1 = rn;
      d.rs1_en = (rn != 5'd31);
      d.rs2 = rm;
      d.rs2_en = (rm != 5'd31);
      d.rs3 = ra;
      d.rs3_en = (ra != 5'd31);
      d.wb_rd = rd;
      d.wb_we = (rd != 5'd31);
    end else if (insn[28:24] == 5'b01010) begin
      // AND/ORR/EOR/ANDS 与取反族 BIC/ORN/EON/BICS（bit21=1，
      // 含 MVN=ORN xzr 别名）；移位寄存器形式
      automatic logic [1:0] opc = insn[30:29];
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] rd = insn[4:0];
      d.is_32 = ~insn[31];
      d.inv_b = insn[21];   // 1=BIC/ORN/EON/BICS（b 取反）
      d.use_shift = 1'b1;
      d.shift_type = insn[23:22];
      d.shift_amt = insn[15:10];
      d.operand_a = rdg(rn);
      d.operand_b = rdg(insn[20:16]);
      d.rs1 = rn;
      d.rs1_en = (rn != 5'd31);
      d.rs2 = insn[20:16];
      d.rs2_en = (insn[20:16] != 5'd31);
      unique case (opc)
        2'd0: d.alu_op = ALU_AND;
        2'd1: d.alu_op = ALU_ORR;
        2'd2: d.alu_op = ALU_EOR;
        2'd3: begin
          d.alu_op = ALU_AND;
          d.set_flags = 1'b1;
        end
        default: d.valid = 1'b0;
      endcase
      // BASE-DP-018：logical shifted-register ROR（shift_type=3）是合法
      // 编码；ADD/SUB shifted-register 的 shift_type=3 仍是保留/UDEF。
      if (d.is_32 && d.shift_amt >= 6'd32) d.valid = 1'b0;  // W 移位 < 32
      d.wb_rd = rd;
      d.wb_we = (rd != 5'd31);
    end else if (insn[28:24] == 5'b01011 && insn[21] == 1'b0) begin
      // ADD/ADDS/SUB/SUBS（移位寄存器，bit21=0）；Rn/Rd=31 为 XZR。
      // bit21=1 为扩展寄存器形式（下方分支支持）
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] rd = insn[4:0];
      d.is_32 = ~insn[31];
      d.alu_op = insn[30] ? ALU_SUB : ALU_ADD;
      d.set_flags = insn[29];
      d.use_shift = 1'b1;
      d.shift_type = insn[23:22];
      d.shift_amt = insn[15:10];
      d.operand_a = rdg(rn);
      d.operand_b = rdg(insn[20:16]);
      d.rs1 = rn;
      d.rs1_en = (rn != 5'd31);
      d.rs2 = insn[20:16];
      d.rs2_en = (insn[20:16] != 5'd31);
      if (d.shift_type == 2'd3) d.valid = 1'b0;  // ROR 暂不支持
      if (d.is_32 && d.shift_amt >= 6'd32) d.valid = 1'b0;  // W 移位 < 32
      d.wb_rd = rd;
      d.wb_we = (rd != 5'd31);
    end else if (insn[28:21] == 8'b01011001) begin
      // ADD/ADDS/SUB/SUBS（扩展寄存器，M3）：Rd = Rn +/- ext(Rm,st)<<sa。
      // st=选项（0/1/2/3=8/16/32/64 位扩展，bit2=符号），sa=移位（0..4，
      // 5..7 保留 -> UDEF）；非 S 形式 Rn/Rd=31 为 SP。
      automatic logic [1:0] op = insn[30:29];
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] rd = insn[4:0];
      automatic logic [4:0] rm = insn[20:16];
      automatic logic [2:0] st = insn[15:13];
      automatic logic [2:0] sa = insn[12:10];
      automatic logic [63:0] off, rmv = rdg(rm);
      if (sa > 3'd4) begin
        d.valid = 1'b0;   // QEMU：sa>4 未分配编码
      end else begin
        unique case (st[1:0])
          2'd0: off = st[2] ? {{56{rmv[7]}},  rmv[7:0]}
                            : {56'd0, rmv[7:0]};
          2'd1: off = st[2] ? {{48{rmv[15]}}, rmv[15:0]}
                            : {48'd0, rmv[15:0]};
          2'd2: off = st[2] ? {{32{rmv[31]}}, rmv[31:0]}
                            : {32'd0, rmv[31:0]};
          default: off = rmv;
        endcase
        off = off << sa;
        d.is_32 = ~insn[31];
        d.alu_op = op[1] ? ALU_SUB : ALU_ADD;
        d.set_flags = op[0];
        d.operand_a = (!op[0] && rn == 5'd31) ? sp : rdg(rn);
        d.operand_b = off;
        d.rs1 = rn;
        d.rs1_en = (rn != 5'd31);
        // rm（扩展源）也是读源：登记 rs2，防止 load/STXR 晚写回时
        // 读到陈旧值（随机回归：sub w7, w4, w1, uxth #4 复现）
        d.rs2 = rm;
        d.rs2_en = (rm != 5'd31);
        d.wb_rd = rd;
        d.wb_we = (rd != 5'd31);
        // 非 S 形式 Rd=31 写 SP（与 ADD/SUB imm 一致）
        d.sp_we = (rd == 5'd31) && !op[0];
      end
    end else if (insn[30:21] == 10'b1011010110 && insn[20:16] == 5'b00000 &&
                 insn[15:10] inside {6'b000000, 6'b000001, 6'b000010, 6'b000011,
                                     6'b000100, 6'b000101}) begin
      // RBIT/REV16/REV32/REV/CLZ/CLS（Data-processing 1-source，P6）。
      // 编码：sf 1011010110 00000 opc2 rn rd；与 QEMU a64.decode
      // REV16/REV32/REV64/CLZ/CLS 一致（REV32 的 W 形式 QEMU 同接受）。
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] rd = insn[4:0];
      d.is_32 = ~insn[31];
      unique case (insn[15:10])
        6'b000000: d.alu_op = ALU_RBIT;
        6'b000001: d.alu_op = ALU_REV16;
        6'b000010: d.alu_op = ALU_REV32;
        6'b000011: d.alu_op = ALU_REV;
        6'b000100: d.alu_op = ALU_CLZ;
        default:   d.alu_op = ALU_CLS;
      endcase
      d.operand_a = rdg(rn);
      d.rs1 = rn;
      d.rs1_en = (rn != 5'd31);
      d.wb_rd = rd;
      d.wb_we = (rd != 5'd31);
    end else if ((insn & 32'h7fe0_f000) inside {32'h1ac0_4000,
                                                 32'h1ac0_5000}) begin
      // CRC32/CRC32C（ARMv8 CRC extension）：sf=0 的 B/H/W 与 sf=1 的 X
      // 数据形式，结果均写 Wd 并零扩展。size=bits[11:10]（0/1/2/3），
      // bit12=1 选择 Castagnoli CRC32C。QEMU virt -cpu max 支持此组。
      automatic logic [4:0] rm = insn[20:16];
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] rd = insn[4:0];
      d.alu_op = ALU_CRC;
      d.is_32 = 1'b1;
      d.operand_a = rdg(rn);       // Wn seed（ALU 取低 32 位）
      d.operand_b = rdg(rm);       // B/H/W/X data（低字节优先）
      d.shift_amt = {4'd0, insn[11:10]};
      d.inv_b = insn[12];          // 1=CRC32C，复用未使用的控制位
      d.rs1 = rn;
      d.rs1_en = (rn != 5'd31);
      d.rs2 = rm;
      d.rs2_en = (rm != 5'd31);
      d.wb_rd = rd;
      d.wb_we = (rd != 5'd31);
    end else if (insn[29:21] == 9'b1_11010010 && insn[10] == 1'b0 &&
                 insn[4] == 1'b0) begin
      // CCMP/CCMN（条件比较，立即数或寄存器；只更新 NZCV，P6）。
      // 编码：sf op S 11010010 imm5/rm cond imm 0 rn 0 nzcv，与 QEMU
      // a64.decode CCMP 一致。条件满足时 NZCV=比较结果，否则=立即数。
      automatic logic [4:0] rn = insn[9:5];
      automatic logic [4:0] y  = insn[20:16];
      automatic logic [3:0] cond = insn[15:12];
      automatic logic [63:0] operand;
      d.is_32 = ~insn[31];
      // bit30=op：1=CCMP（减法）0=CCMN（加法），与 QEMU trans_CCMP
      // （a->op -> gen_sub_CC）一致。
      d.alu_op = insn[30] ? ALU_CCMP : ALU_CCMN;
      d.set_flags = 1'b1;
      if (insn[11]) begin
        operand = {59'd0, y};               // 立即数：imm5 零扩展（0..31，
                                            // QEMU tcg_constant_i64 语义）
      end else begin
        operand = rdg(y);                    // 寄存器形式
        d.rs2 = y;
        d.rs2_en = (y != 5'd31);
      end
      d.operand_a = rdg(rn);
      d.operand_b = operand;
      d.rs1 = rn;
      d.rs1_en = (rn != 5'd31);
      d.ccmp_nzcv = insn[3:0];
      d.ccmp_taken = cond_taken(cond, nzcv);
      d.wb_we = 1'b0;
    end else begin
      d.valid = 1'b0;
    end

    // ---- P4 异常后处理（顺序：分支 IABT > 取指 IABT > UDEF > DABT）。
    // P5a：MMU 开启时地址范围检查失效（VA 可合法落在 SRAM 外，
    // 翻译后的 PA 检查由 MMU/核心负责），仅保留 UDEF。----
    if (d.valid && d.is_atomic && d.is_pair && d.mem_size == 2'd3 &&
        !d.exc && d.mem_addr[3:0] != 4'd0) begin
      // check_atomic_align(..., MO_128)：对齐 fault，FSC=0x21 由核心
      // 的 commit ESR 路径编码；优先级高于地址窗口 fault。
      d.exc = 1'b1;
      d.atomic_align = 1'b1;
      d.exc_code = el ? EXC_DABORT_SAME_EL : EXC_DABORT;
      d.exc_elr = pc;
      d.next_pc = exc_vector;
    end else if (!mmu_en && d.valid && !d.exc && d.sys_op != SYS_ERET &&
        (d.next_pc != (pc + 64'd4)) &&
        (d.next_pc < SRAM_BASE || d.next_pc >= SRAM_TOP)) begin
      // 分支/跳转目标越界：QEMU 在取指时 fault，提交合并到分支指令，
      // ELR=目标地址（ERET 由核心在 sys_commit 处理）
      d.exc = 1'b1;
      d.exc_code = el ? EXC_IABORT_SAME_EL : EXC_IABORT;
      d.exc_elr = d.next_pc;
      d.next_pc = exc_vector;
    end else if (!mmu_en && (pc < SRAM_BASE || pc >= SRAM_TOP)) begin
      // 取指地址超出 SRAM：指令异常（覆盖其他解码结果）
      d.exc = 1'b1;
      d.exc_code = el ? EXC_IABORT_SAME_EL : EXC_IABORT;
      d.exc_elr = pc;
      d.next_pc = exc_vector;
    end else if (d.valid && (d.fp_valid || d.neon_valid) &&
                 !fp_access_allowed) begin
      // P7：标量 FP 与 Advanced SIMD 共享 FPEN access trap；trap 优先
      // 于数据地址检查，且不进入 EX/MEM。
      // access trap；trap 优先于数据地址检查，且不进入 EX/MEM。
      d.exc = 1'b1;
      d.exc_code = EXC_FP_ACCESS;
      d.exc_esr = ESR_FP_ACCESS_TRAP;
      d.exc_elr = pc;
      d.next_pc = exc_vector;
    end else if (!d.valid) begin
      // 未识别/保留编码：未定义指令异常
      d.exc = 1'b1;
      d.exc_code = EXC_UDEF;
      d.exc_elr = pc;
      d.next_pc = exc_vector;
    end else if (d.valid && d.neon_valid && d.is_pair &&
                 d.mem_size == 2'd3 && !d.exc &&
                 d.mem_addr[3:0] != 4'd0) begin
      // P7-2 单 Q 访问的自然 16B 对齐边界；两段内部请求不能把非对齐
      // 访问降级为两个看似合法的 8B 访问。
      d.exc = 1'b1;
      d.neon_align = 1'b1;
      d.exc_code = el ? EXC_DABORT_SAME_EL : EXC_DABORT;
      d.exc_elr = pc;
      d.next_pc = exc_vector;
    end else if (!mmu_en && d.valid && d.neon_valid && d.is_pair &&
                 d.mem_size == 2'd3 && !neon128_window_ok(d.mem_addr)) begin
      // 在第一段 request 前验证完整 16B 物理窗口，避免 fault 后产生
      // 半笔 Q store；MMU 开启时由核心在两次翻译完成后做相同检查。
      d.exc = 1'b1;
      d.neon_range = 1'b1;
      d.exc_code = el ? EXC_DABORT_SAME_EL : EXC_DABORT;
      d.exc_elr = pc;
      d.next_pc = exc_vector;
    end else if (!mmu_en && d.valid && d.is_atomic && d.is_pair &&
                 d.mem_size == 2'd3 && !atomic128_window_ok(d.mem_addr)) begin
      // 16B 访问窗口越过 SRAM/MMIO 顶端时，任何读写请求前直接 DABT。
      d.exc = 1'b1;
      d.atomic_range = 1'b1;
      d.exc_code = el ? EXC_DABORT_SAME_EL : EXC_DABORT;
      d.exc_elr = pc;
      d.next_pc = exc_vector;
    end else if (!mmu_en && (d.is_load || d.is_store) &&
                 !((d.mem_addr >= SRAM_BASE && d.mem_addr < SRAM_TOP) ||
                   (d.mem_addr >= MMIO_BASE && d.mem_addr < MMIO_TOP) ||
                   (d.mem_addr >= MMIO2_BASE && d.mem_addr < MMIO2_TOP) ||
                   (d.mem_addr >= MMIO3_BASE && d.mem_addr < MMIO3_TOP) ||
                   (d.mem_addr >= MMIO4_BASE && d.mem_addr < MMIO4_TOP))) begin
      // Load/Store 地址超出 RAM/MMIO（UART/GIC）：数据异常
      d.exc = 1'b1;
      d.exc_code = el ? EXC_DABORT_SAME_EL : EXC_DABORT;
      d.exc_elr = pc;
      d.next_pc = exc_vector;
    end

    // T-20260902-036：记录 ID 级组合是否读取前递后的 SP/NZCV。
    // 这些标记只用于核心的 ID/EX->ID 前递切级 hazard，不进入 ex_pipe_t。
    d.uses_sp = 1'b0;
    d.uses_nzcv = 1'b0;
    if (d.valid) begin
      // 所有以 [Rn] 为基址的访存/原子指令，Rn=31 表示 SP。
      if ((d.is_load || d.is_store || d.is_atomic) &&
          (insn[9:5] == 5'd31)) begin
        d.uses_sp = 1'b1;
      end
      // ADD/SUB immediate 与 extended-register 形式中 Rn=31 表示 SP；
      // shifted-register 形式 Rn=31 仍是 XZR，不在这里列入。
      if (((insn[28:23] == 6'b100010) ||
           (insn[28:21] == 8'b01011001)) &&
          (insn[9:5] == 5'd31)) begin
        d.uses_sp = 1'b1;
      end
      // B.cond、条件选择、条件比较和 MRS NZCV 在 decode 读取 NZCV。
      if (((insn[31:25] == 7'b0101010) && (insn[4] == 1'b0)) ||
          (d.alu_op inside {ALU_CSEL, ALU_CCMP, ALU_CCMN}) ||
          (d.sys_op == SYS_MRS && d.sys_reg == SREG_NZCV)) begin
        d.uses_nzcv = 1'b1;
      end
    end
  end

endmodule
