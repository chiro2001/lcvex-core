// lcvex_core.sv
// LCVEX AArch64 标量核心（P3 顺序流水线）：
//   IF -> ID -> EX -> MEM -> WB/COMMIT，单发射、顺序提交。
//   - forwarding：EX/MEM/WB 写回前递到 ID 的寄存器/SP/NZCV 读视图；
//   - stall：load-use（load 在 EX/MEM 且 ID 依赖其 rd）、MEM 访存与取指
//     争用单端口 SRAM、系统指令等待流水线排空（P4：异常/ERET/MSR 在
//     ID 级提交，先等更老的指令全部提交，避免系统状态转发）；
//   - flush：分支在 ID 解析（decode 用前递后的值算 next_pc），跳转时
//     冲刷 IF/ID 并把 IF PC 重定向到目标。
// P4 系统状态：EL/SP_sel/DAIF/NZCV（PSTATE）、SP_EL0/SP_EL1、ELR_EL1、
// SPSR_EL1、VBAR_EL1。异常指令（UDEF/SVC/IABT/DABT）、ERET 和 MSR 在
// ID 级提交；MRS 走普通流水线写回 GPR。
//   架构状态（GPR/SP/NZCV）只在 WB/COMMIT 更新，每周期至多一个提交，
//   提交包与 docs/COMMIT_PACKET.md 一致。

`timescale 1ns/1ps

module lcvex_core #(
    parameter logic [63:0] RESET_PC  = 64'h0000_0000_4000_0000,
    parameter logic [63:0] SRAM_BASE = 64'h0000_0000_4000_0000,
    parameter logic [63:0] SRAM_TOP  = 64'h0000_0000_4800_0000,
    parameter logic [63:0] MMIO_BASE = 64'h0000_0000_0900_0000,
    parameter logic [63:0] MMIO_TOP  = 64'h0000_0000_0900_1000,
    parameter logic [63:0] MMIO2_BASE = 64'h0000_0000_0800_0000,
    parameter logic [63:0] MMIO2_TOP  = 64'h0000_0000_0802_1000,
    parameter logic [63:0] MMIO3_BASE = 64'h0000_0000_0903_0000,
    parameter logic [63:0] MMIO3_TOP  = 64'h0000_0000_0903_1000,
    // C++ MMIO fabric：PL031/fw_cfg/virtio 等非原生外设。
    parameter logic [63:0] MMIO4_BASE = 64'h0000_0000_0901_0000,
    parameter logic [63:0] MMIO4_TOP  = 64'h0000_0000_0a02_0000,
    parameter logic        A64_FP_SIMD = 1'b1,  // 0=无 FP/NEON（ID 寄存器按 QEMU vfp=off）
    // QEMU lockstep retains instruction-count time. Board mode uses the
    // core clock as the always-running Generic Timer source.
    parameter logic        TIMER_REALTIME = 1'b0,
    parameter logic [63:0] CNTFRQ_HZ = lcvex_pkg::CNTFRQ_EL0_VAL,
    // F1a：默认关闭的本地 2-entry 取指 FIFO。公共 memory ABI 不变；
    // 仅在 feature-on 路径记录非架构 epoch/seq，并在 flush 后排空旧响应。
    parameter int          FETCH_FIFO_ENABLE = 0,
    parameter int          FETCH_FIFO_DEPTH  = 2,
    parameter int          FETCH_EPOCH_W     = 8
) (
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    commit_ready,  // 提交消费者可接收（M1：valid/ready）
    output lcvex_pkg::commit_packet_t commit,
    // P7-0 FP state raw observation. These ports are architectural state
    // snapshots only; normal lockstep never writes them back to the DUT.
    output logic [31:0]             fpcr_state,
    output logic [31:0]             fpsr_state,
    output logic [63:0]             fp_cpacr_el1_state,
    output logic [63:0]             fp_v_lo [0:31],
    output logic [63:0]             fp_v_hi [0:31],
    // ---- M1-B：统一内存 request/response（经 SoC 仲裁器）----
    // 取指（imem）
    output logic                    imem_req_valid,
    output lcvex_pkg::mem_req_t     imem_req,
    input  logic                    imem_req_ready,
    input  logic                    imem_rsp_valid,
    input  lcvex_pkg::mem_rsp_t     imem_rsp,
    output logic                    imem_rsp_ready,
    // 数据 load/store（dmem，EX/MEM）
    output logic                    dmem_req_valid,
    output lcvex_pkg::mem_req_t     dmem_req,
    input  logic                    dmem_req_ready,
    input  logic                    dmem_rsp_valid,
    input  lcvex_pkg::mem_rsp_t     dmem_rsp,
    output logic                    dmem_rsp_ready,
    // 页表遍历（MMU）
    output logic                    ptw_req_valid,
    output lcvex_pkg::mem_req_t     ptw_req,
    input  logic                    ptw_req_ready,
    input  logic                    ptw_rsp_valid,
    input  lcvex_pkg::mem_rsp_t     ptw_rsp,
    output logic                    ptw_rsp_ready,
    // TLBI 整表失效脉冲（M2-4b：维护指令提交前发一个周期）
    output logic                    tlb_invalidate,
    // P6：Generic Timer 中断（供 GIC 使用，非差分提交状态）
    output logic                    timer_phys_irq,
    output logic                    timer_virt_irq,
    // P6：GIC 中断输入（异步异常入口）
    input  logic                    irq,
    // P6 difftest wait-time sideband：只由仿真 SoC/协调器在 QEMU 已报告
    // 等待恢复时驱动；综合/独立 RTL 顶层必须固定为 0。
    input  logic                    difftest_wait_release,
    input  logic                    difftest_wait_cntvct_valid,
    input  logic [63:0]             difftest_wait_cntvct,
    // P6 checkpoint 恢复 sideband（QEMU→Verilator）：仅在复位后的恢复
    // 边界单拍有效。它是验证专用入口，不参与正常执行，更不能用于每条
    // 指令后把 QEMU 状态回灌给 RTL；后者会掩盖真正的实现分歧。
    input  logic                    difftest_restore_sys_valid,
    // P7-0 FP sidecar: 与 system restore 同一时钟沿采样。V 以 little-endian
    // low/high 64-bit halves 传输，避免协调器依赖层级状态。
    input  logic                    difftest_restore_fp_valid,
    input  logic [31:0]             difftest_restore_fpcr,
    input  logic [31:0]             difftest_restore_fpsr,
    input  logic [63:0]             difftest_restore_fp_v_lo [0:31],
    input  logic [63:0]             difftest_restore_fp_v_hi [0:31],
    input  logic [63:0]             difftest_restore_pc,
    input  logic [63:0]             difftest_restore_sp_el0,
    input  logic [63:0]             difftest_restore_sp_el1,
    input  logic [3:0]              difftest_restore_nzcv,
    input  logic                    difftest_restore_el,
    input  logic                    difftest_restore_sp_sel,
    input  logic [3:0]              difftest_restore_daif,
    input  logic                    difftest_restore_pan,
    input  logic                    difftest_restore_dit,
    input  logic                    difftest_restore_ssbs,
    input  logic                    difftest_restore_uao,
    input  logic                    difftest_restore_tco,
    input  logic                    difftest_restore_allint,
    input  logic [63:0]             difftest_restore_elr_el1,
    input  logic [63:0]             difftest_restore_spsr_el1,
    input  logic [63:0]             difftest_restore_vbar_el1,
    input  logic [63:0]             difftest_restore_sctlr_el1,
    input  logic [63:0]             difftest_restore_tcr_el1,
    input  logic [63:0]             difftest_restore_ttbr0_el1,
    input  logic [63:0]             difftest_restore_ttbr1_el1,
    input  logic [63:0]             difftest_restore_mair_el1,
    input  logic [31:0]             difftest_restore_esr_el1,
    input  logic [63:0]             difftest_restore_far_el1,
    input  logic [63:0]             difftest_restore_par_el1,
    input  logic [63:0]             difftest_restore_cpacr_el1,
    input  logic [63:0]             difftest_restore_mdscr_el1,
    input  logic [63:0]             difftest_restore_pmuserenr_el0,
    input  logic [63:0]             difftest_restore_cntkctl_el1,
    input  logic [63:0]             difftest_restore_tpidr_el0,
    input  logic [63:0]             difftest_restore_tpidrro_el0,
    input  logic [63:0]             difftest_restore_tpidr_el1,
    input  logic [63:0]             difftest_restore_pir_el1,
    input  logic [63:0]             difftest_restore_pire0_el1,
    input  logic [63:0]             difftest_restore_zcr_el1,
    input  logic [63:0]             difftest_restore_smcr_el1,
    input  logic [63:0]             difftest_restore_csselr_el1,
    input  logic [63:0]             difftest_restore_tcr2_el1,
    input  logic [63:0]             difftest_restore_contextidr_el1,
    input  logic                    difftest_restore_excl_valid,
    input  logic [63:0]             difftest_restore_excl_addr,
    input  logic [63:0]             difftest_restore_excl_data,
    input  logic [63:0]             difftest_restore_excl_data_hi,
    input  logic [63:0]             difftest_restore_cntpct,
    input  logic [63:0]             difftest_restore_cntp_cval,
    input  logic [1:0]              difftest_restore_cntp_ctl,
    input  logic [63:0]             difftest_restore_cntv_cval,
    input  logic [1:0]              difftest_restore_cntv_ctl
);

  import lcvex_pkg::*;

  // P6 标量目标不实现 ARMv8.3 Pointer Authentication。固定 QEMU
  // difftest 路径同样把 SCTLR_EL1 的四个 PAuth 使能位按 WI 清零：
  // EnIA[31]、EnIB[30]、EnDA[27]、EnDB[13]。高 32 位当前也不实现。
  localparam logic [63:0] SCTLR_EL1_WRITE_MASK =
      64'h0000_0000_37FF_DFFF;

  function automatic logic [7:0] strb_for_size(input logic [1:0] size);
    unique case (size)
      2'd0: strb_for_size = 8'h01;
      2'd1: strb_for_size = 8'h03;
      2'd2: strb_for_size = 8'h0f;
      default: strb_for_size = 8'hff;
    endcase
  endfunction

  // exclusive 值比较掩码：QEMU cmpxchg 只比较 STXR 宽度对应的低位
  //（LDXR X 后 STXR W 只比低 32 位，与 QEMU gen_store_exclusive 一致）。
  function automatic logic [63:0] size_mask(input logic [1:0] size);
    unique case (size)
      2'd0: size_mask = 64'hFF;
      2'd1: size_mask = 64'hFFFF;
      2'd2: size_mask = 64'hFFFF_FFFF;
      default: size_mask = ~64'd0;
    endcase
  endfunction

  function automatic logic pa_window8(input logic [63:0] a);
    pa_window8 =
        ((a >= SRAM_BASE) && (a <= (SRAM_TOP - 64'd8))) ||
        ((a >= MMIO_BASE) && (a <= (MMIO_TOP - 64'd8))) ||
        ((a >= MMIO2_BASE) && (a <= (MMIO2_TOP - 64'd8))) ||
        ((a >= MMIO3_BASE) && (a <= (MMIO3_TOP - 64'd8))) ||
        ((a >= MMIO4_BASE) && (a <= (MMIO4_TOP - 64'd8)));
  endfunction

  function automatic logic is_atomic128_pair(input atomic_op_t op);
    is_atomic128_pair = (op == ATOMIC_CASP) ||
                        (op == ATOMIC_CLRP) ||
                        (op == ATOMIC_SETP) ||
                        (op == ATOMIC_SWPP);
  endfunction

  // ---- 架构状态 ----
  logic [63:0] sp_el0;      // SP_EL0
  logic [63:0] sp_el1;      // SP_EL1
  logic [63:0] sp;          // 当前可见 SP（PSTATE.SP 选银行；EL0 恒 sp_el0）
  logic [3:0]  nzcv;
  logic        el;          // 0=EL0 1=EL1
  logic        sp_sel;      // PSTATE.SP（h=1/t=0）
  logic [3:0]  daif;        // PSTATE.DAIF（bit3=D bit2=A bit1=I bit0=F）
  logic        pstate_pan;  // PSTATE.PAN（P6：保存/恢复，权限语义留待后续）
  logic        pstate_dit;  // PSTATE.DIT（P6：保存/恢复，数据无关时序）
  logic        pstate_ssbs; // PSTATE.SSBS（bit12，Linux 用户态默认置位）
  logic        pstate_uao;  // PSTATE.UAO（bit9）
  logic        pstate_tco;  // PSTATE.TCO（bit25）
  logic        pstate_allint; // PSTATE.ALLINT（bit13，FEAT_NMI）
  logic [63:0] elr_el1;
  logic [63:0] spsr_el1;
  logic [63:0] vbar_el1;
  logic [63:0] sctlr_el1;
  logic [63:0] tcr_el1;
  logic [63:0] ttbr0_el1;
  logic [63:0] ttbr1_el1;
  logic [63:0] mair_el1;
  logic [31:0] esr_el1;     // R1：异常 syndrome
  logic [63:0] far_el1;     // R1：故障地址（abort 类更新）
  // ---- P6：Linux 启动补充系统寄存器（读/写，复位 0）----
  logic [63:0] cpacr_el1;
  // ---- P7-0：FP/Advanced SIMD state boundary ----
  logic [31:0] fpcr_read_data;
  logic [31:0] fpsr_read_data;
  logic [63:0] fp_cpacr_read_data;
  logic [1:0]  fp_cpacr_fpen;
  logic        sys_fpcr_write_accept;
  logic        sys_fpsr_write_accept;
  logic        sys_cpacr_write_accept;
  logic        sys_fp_access_blocked;
  logic        sys_cpacr_write_blocked;
  logic        fp_access_valid;
  logic        fp_access_allowed;
  logic        fp_trap_valid;
  logic [31:0] fp_trap_code;
  logic [31:0] fp_trap_esr;
  logic [127:0] fp_v_state [0:31];
  logic [127:0] difftest_restore_fp_v [0:31];
  logic         fp_commit_effect_valid;
  logic         fp_commit_effect_error;
  logic [2:0]   fp_commit_effect_vec_write_count;
  logic [4:0]   fp_commit_effect_vec_rd0;
  logic [4:0]   fp_commit_effect_vec_rd1;
  logic [4:0]   fp_commit_effect_vec_rd2;
  logic [4:0]   fp_commit_effect_vec_rd3;
  logic [127:0] fp_commit_effect_vec_wdata0;
  logic [127:0] fp_commit_effect_vec_wdata1;
  logic [127:0] fp_commit_effect_vec_wdata2;
  logic [127:0] fp_commit_effect_vec_wdata3;
  logic         fp_commit_effect_fpcr_we;
  logic [31:0]  fp_commit_effect_fpcr_wdata;
  logic         fp_commit_effect_fpsr_we;
  logic [31:0]  fp_commit_effect_fpsr_wdata;
  logic [2:0]   fp_commit_vec_write_count_in;
  logic [4:0]   fp_commit_vec_rd0_in;
  logic [4:0]   fp_commit_vec_rd1_in;
  logic [4:0]   fp_commit_vec_rd2_in;
  logic [4:0]   fp_commit_vec_rd3_in;
  logic [127:0] fp_commit_vec_wdata0_in;
  logic [127:0] fp_commit_vec_wdata1_in;
  logic [127:0] fp_commit_vec_wdata2_in;
  logic [127:0] fp_commit_vec_wdata3_in;
  logic         fp_commit_fpsr_we_in;
  logic [31:0]  fp_commit_fpsr_wdata_in;
  logic [63:0] mdscr_el1;
  logic [63:0] pmuserenr_el0;
  logic [63:0] cntkctl_el1;
  // P6 Generic Timer：计数器每提交 +1（与 QEMU -icount shift=0 一致：
  // CNTPCT = 已执行指令数），CNTVCT = CNTPCT（CNTVOFF_EL2=0）
  logic [63:0] cntpct_r;
  logic [1:0]  cntp_ctl_r;   // bit0=enable bit1=imask（istatus 读时计算）
  logic [63:0] cntp_cval_r;
  logic [1:0]  cntv_ctl_r;
  logic [63:0] cntv_cval_r;
  logic        wfi_idle;
  logic        event_reg;
  logic [63:0] wfi_pc_r;
  logic [31:0] wfi_insn_r;
  logic        wfi_timeout_valid;
  logic [63:0] wfi_timeout_r;
  logic        difftest_wait_release_pending;
  logic        difftest_wait_cntvct_pending;
  logic [63:0] difftest_wait_cntvct_r;
  logic [63:0] tpidr_el0;
  logic [63:0] tpidrro_el0;
  logic [63:0] tpidr_el1;
  logic [63:0] contextidr_el1;  // CONTEXTIDR_EL1：EL1 RW, reset 0
  logic [63:0] tcr2_el1;
  logic [63:0] pir_el1;
  logic [63:0] pire0_el1;
  logic [63:0] par_el1;
  logic [63:0] zcr_el1;       // P6 最小 ZCR_EL1；P8 才实现向量状态
  logic [63:0] smcr_el1;      // P6 最小 SMCR_EL1 LEN；P8 才实现 SME 状态
  logic [63:0] csselr_el1;    // P6 Cache level selector
  logic [63:0] gpr[31];
  // ---- exclusive 监视器（M3）：架构状态，只在提交更新 ----
  // 与 QEMU env->exclusive_addr/val 语义一致：valid=1 表示 LDXR 已
  // 记录；STXR 通过条件 = 地址相等且内存当前值（按 STXR 宽度截取）
  // 与记录值相等；STXR/CLREX/ERET 提交后清，A profile 异常入口不清。
  logic        excl_valid;
  logic [63:0] excl_addr;
  logic [63:0] excl_data;
  logic [63:0] excl_data_hi;   // LDXP 128 位监视器高半

  // CPACR 的架构存储由 lcvex_fp_state 唯一拥有；其余 P6 核心逻辑仍通过
  // 这个同名读视图访问，避免出现两份可在不同沿更新的 FPEN 状态。
  assign cpacr_el1 = fp_cpacr_read_data;

  // 生成 SPSR_EL1：除 NZCV/DAIF/模式外，保留 Linux 当前使用的
  // SSBS/ALLINT/UAO/PAN/DIT/TCO PSTATE 位。用显式位赋值避免大拼接在新增
  // 字段后发生位置漂移。
  function automatic logic [63:0] make_spsr(
      input logic [3:0] flags,
      input logic [3:0] masks,
      input logic       cur_el,
      input logic       cur_sp,
      input logic       pan,
      input logic       dit,
      input logic       ssbs,
      input logic       uao,
      input logic       tco,
      input logic       allint);
    logic [63:0] v;
    begin
      v = 64'd0;
      v[31:28] = flags;
      v[24]    = dit;
      v[22]    = pan;
      v[25]    = tco;
      v[23]    = uao;
      v[12]    = ssbs;
      v[13]    = allint;
      v[9:6]   = masks;
      v[2]     = cur_el;
      v[0]     = cur_sp;
      make_spsr = v;
    end
  endfunction

  // PSTATE.SP（sp_sel）决定 EL1t/EL1h 的可见 SP；EL0 时 sp_sel=0，
  // 表达式退化为 sp_el0（与 ARM 架构一致）。旧实现误用 el 选择，
  // 导致 EL1t ERET 返回后 SP 仍指向 sp_el1（hard_p6_isa 扩展暴露）。
  assign sp = sp_sel ? sp_el1 : sp_el0;
  assign mmu_en = sctlr_el1[0];  // SCTLR_EL1.M（P5a）
  // R1：系统指令（ID 级 MSR）提交前的“前瞻”MMU 状态——提交会写入
  // SCTLR/TCR/TTBR/MAIR，下一条取指翻译须按提交后的状态进行（否则
  // 使能 MMU 或改 TCR/TTBR 后紧接下一条未映射/改译 -> 空流水线取指
  // fault 无法合并提交，且 mmu_en=1 时 MSR 会因 fetch_next_settled
  // 永不满足而死锁）。
  logic sys_msr_at_id;
  logic sys_fetch_context_change;
  logic sys_fetch_context_refresh_needed;
  logic sys_fetch_context_msr_merge;
  logic mmu_en_eff;
  logic [63:0] tcr_eff, ttbr0_eff, ttbr1_eff, mair_eff;
  assign sys_msr_at_id = ifid_valid && d.valid && (d.sys_op == SYS_MSR);
  assign mmu_en_eff = (sys_msr_at_id && d.sys_reg == SREG_SCTLR_EL1)
                      ? d.sys_wdata[0] : mmu_en;
  assign tcr_eff   = (sys_msr_at_id && d.sys_reg == SREG_TCR_EL1)
                     ? d.sys_wdata : tcr_el1;
  assign ttbr0_eff = (sys_msr_at_id && d.sys_reg == SREG_TTBR0_EL1)
                     ? d.sys_wdata : ttbr0_el1;
  assign ttbr1_eff = (sys_msr_at_id && d.sys_reg == SREG_TTBR1_EL1)
                     ? d.sys_wdata : ttbr1_el1;
  assign mair_eff  = (sys_msr_at_id && d.sys_reg == SREG_MAIR_EL1)
                     ? d.sys_wdata : mair_el1;
  // A fetch issued before an ID-level translation-regime MSR is known was
  // evaluated with the old MMU context.  Do not reuse that outcome for the
  // post-MS* next-PC fence; sys_fetch_redirect will quarantine it and issue a
  // fresh request under the effective context.  This is internal metadata,
  // not a public response ID or architectural state.
  assign sys_fetch_context_change = sys_msr_at_id &&
      (d.sys_reg inside {SREG_SCTLR_EL1, SREG_TCR_EL1,
                         SREG_TTBR0_EL1, SREG_TTBR1_EL1,
                         SREG_MAIR_EL1});
  // The IF/ID token records the generation in which this system instruction
  // was fetched.  A context-changing MSR must invalidate any outcome from
  // that same generation exactly once, including a normal/fault FIFO head or
  // an in-flight request.  After sys_fetch_redirect bumps fetch_epoch, a
  // fresh outcome has epoch != ifid_token_epoch and is eligible to settle.
  assign sys_fetch_context_refresh_needed = fetch_fifo_active &&
      sys_fetch_context_change &&
      (d.sys_reg != SREG_SCTLR_EL1 || d.sys_wdata[0]) &&
      mmu_en_eff &&
      (fetch_epoch == ifid_token_epoch);

  // ---- IF 级 ----
  logic [63:0] if_pc;

  // ---- 在途取指（M1-B：imem request/response）----
  logic        fetch_pending;   // 有在途取指请求（已接受、未响应）
  logic        fetch_got_data;  // 取指响应已到、等待 IF/ID 捕获
  logic [31:0] fetch_data_r;    // 取指响应数据缓冲
  logic [63:0] fetch_pc_r;      // 在途取指地址
  logic        fetch_translated;  // MMU 翻译完成、等待 imem 读请求
  logic        capture_now;     // 本周期 IF/ID 捕获在途取指

  // ---- PE-F1a：2-entry fetch FIFO + local epoch/quarantine ----
  // FIFO 只保存取指交付和故障元数据，不携带任何架构状态；commit packet
  // 和单发射流水线保持不变。数组固定为两项，FETCH_FIFO_DEPTH 仅允许
  // 0/2（由任务契约约束），这样 feature-off 不引入可变宽度下标。
  /* verilator lint_off UNUSEDSIGNAL */
  logic [FETCH_EPOCH_W-1:0] fetch_epoch;
  logic [FETCH_EPOCH_W-1:0] fetch_ctx_epoch;
  logic [15:0]              fetch_seq;
  logic [15:0]              fetch_ctx_seq;
  logic                     fetch_stale_mmu;
  logic                     fetch_stale_imem;
  logic                     fetch_fault_pending;
  logic [1:0]               fetch_fifo_valid;
  logic [FETCH_EPOCH_W-1:0] fetch_fifo_epoch_r [0:1];
  logic [15:0]              fetch_fifo_seq_r    [0:1];
  logic [63:0]              fetch_fifo_pc_r     [0:1];
  logic [31:0]              fetch_fifo_insn_r   [0:1];
  logic [5:0]               fetch_fifo_fsc_r    [0:1];
  logic [1:0]               fetch_fifo_fault;
  logic                     fetch_fifo_head;
  logic                     fetch_fifo_tail;
  logic [1:0]               fetch_fifo_count;
  logic [1:0]               fetch_fifo_occupancy;
  logic                     fetch_fifo_push;
  logic                     fetch_fifo_pop;
  logic                     fetch_fifo_flush;
  logic                     fetch_fifo_head_fault;
  logic                     fetch_fifo_space;
  logic                     fetch_fifo_has_target;
  logic                     fetch_fifo_control_flow;
  logic                     ifid_control_flow;
  logic                     fetch_control_fence;
  logic                     frontend_kill;
  logic                     fetch_stale_drain;
  logic                     fetch_stale_rsp_drop;
  logic                     fetch_epoch_bump;
  logic [31:0]              fetch_fifo_push_count;
  logic [31:0]              fetch_fifo_pop_count;
  logic [31:0]              fetch_fifo_flush_count;
  logic [31:0]              fetch_stale_drop_count;
  logic [1:0]               fetch_fifo_peak;
  /* verilator lint_on UNUSEDSIGNAL */

  // T-010：仅按原始 32-bit 编码识别 decode 已支持的控制流指令。该谓词
  // 不计算目标、不判断 taken/not-taken，也不改变 d.next_pc；它只在 F1a
  // FIFO/IFID 已经持有该指令而现有 decode/flush 尚未完成时节流更年轻的
  // 顺序取指。BR family 的保留编码明确排除，避免把非法指令当作 fence。
  function automatic logic raw_control_flow(input logic [31:0] insn);
    raw_control_flow = 1'b0;
    if (insn[30:26] == 5'b00101) begin
      // B / BL
      raw_control_flow = 1'b1;
    end else if (insn[31:25] == 7'b0101010 && !insn[4]) begin
      // B.cond（与 lcvex_decode.sv 的 reserved bit 检查一致）
      raw_control_flow = 1'b1;
    end else if (insn[30:25] == 6'b011010) begin
      // CBZ / CBNZ
      raw_control_flow = 1'b1;
    end else if (insn[30:25] == 6'b011011) begin
      // TBZ / TBNZ
      raw_control_flow = 1'b1;
    end else if (insn[31:25] == 7'b1101011 &&
                 insn[20:16] == 5'b11111 &&
                 insn[15:10] == 6'b000000 &&
                 insn[24:21] inside {4'b0000, 4'b0001, 4'b0010}) begin
      // BR / BLR / RET；其它 BR family 编码是 reserved/invalid。
      raw_control_flow = 1'b1;
    end
  endfunction

  always_comb begin
    fetch_fifo_control_flow = 1'b0;
    if (fetch_fifo_active) begin
      for (int i = 0; i < 2; i++) begin
        if (fetch_fifo_valid[i] && !fetch_fifo_fault[i] &&
            fetch_fifo_epoch_r[i] == fetch_epoch &&
            raw_control_flow(fetch_fifo_insn_r[i]))
          fetch_fifo_control_flow = 1'b1;
      end
    end
  end

  assign ifid_control_flow = fetch_fifo_active && ifid_valid && d.valid && !d.exc &&
                             (ifid_token_epoch == fetch_epoch) &&
                             raw_control_flow(ifid_insn);
  // If the control-flow instruction is already in IF/ID, the existing
  // flush_id result is the decode boundary: a taken instruction redirects and
  // kills, while a not-taken instruction advances sequentially and releases
  // the fence on the following FIFO/IFID transfer.
  assign fetch_control_fence = fetch_fifo_active &&
      (fetch_fifo_control_flow || (ifid_control_flow && !flush_id));

  // ---- IF/ID ----
  logic        ifid_valid;
  logic [63:0] ifid_pc;
  logic [31:0] ifid_insn;

  // T-046 diagnostic token: non-architectural fetch epoch/sequence metadata
  // carried with the instruction through the in-order pipeline.  It is used
  // only by the pre-fix probe/SVA and does not enter commit_packet_t.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [FETCH_EPOCH_W-1:0] ifid_token_epoch;
  logic [15:0]              ifid_token_seq;
  logic [FETCH_EPOCH_W-1:0] idex_token_epoch;
  logic [15:0]              idex_token_seq;
  logic [FETCH_EPOCH_W-1:0] exmem_token_epoch;
  logic [15:0]              exmem_token_seq;
  logic [FETCH_EPOCH_W-1:0] memwb_token_epoch;
  logic [15:0]              memwb_token_seq;
  logic [FETCH_EPOCH_W-1:0] commit_token_epoch;
  logic [15:0]              commit_token_seq;
  logic [FETCH_EPOCH_W-1:0] fetch_fifo_head_epoch_dbg;
  logic [15:0]              fetch_fifo_head_seq_dbg;
  logic [63:0]              fetch_fifo_head_pc_dbg;
  logic                     fetch_fifo_head_valid_dbg;
  logic                     dbg_ifid_to_idex_fire;
  logic                     dbg_idex_to_exmem_fire;
  logic                     dbg_exmem_to_memwb_fire;
  logic                     dbg_commit_fire;
  /* verilator lint_on UNUSEDSIGNAL */

  // ---- ID 组合 ----
  decoded_insn_t d;
  logic [63:0]   gprv[31];   // 前递后的读视图（31 为 XZR=0）
  logic [127:0]  fpv[32];   // 前递后的 V0..V31 raw 读视图
  logic [63:0]   spv;
  logic [3:0]    nzcvv;
  logic          stall_id;
  logic          flush_id;
  logic          load_use;
  logic          fp_load_use;
  logic          mem_busy;
  logic          sys_at_id;    // 系统/异常指令在 ID（先等排空再提交）
  logic          sys_hold;     // 系统/异常指令等待前方流水线排空
  logic          sys_commit;   // 系统/异常指令在 ID 提交
  logic          excl_at_id;   // STXR/STLXR 在 ID（M3）
  logic          excl_drain_ok;  // STXR 前方流水线已排空（监视器已定）
  logic          excl_hold;    // STXR 等待排空
  logic          wb_exc_commit;  // WB 级 dmem 响应 fault 提交（DABT）
  logic          wfi_wake;
  logic          wfi_timeout_wake;
  logic          wfi_irq_take;
  logic          sys_irq_taken; // ID 级系统指令提交后的异步 IRQ
  logic          mmu_abort;     // ordinary IRQ：取消当前 MMU 请求，保留 TLB
  logic [3:0]    sys_daif_after; // 当前 ID 系统指令提交后可见的 DAIF
  logic          sys_allint_after; // 当前 ID 系统指令提交后可见的 ALLINT
  logic          sys_commit_ready;  // 系统指令提交附加条件（排空之外）
  logic          sys_maint_at_id;   // 缓存/TLB 维护指令在 ID
  logic          stall_if;      // IF/IF2 冻结（含 EX 乘除忙）
  logic          imem_req_accept;
  logic          dmem_req_accept;
  logic          dmem_pending;

  // ---- M2-4b：缓存/TLB 维护流程（IC/DC/TLBI 在 ID 级提交）----
  typedef enum logic [2:0] {
    MS_IDLE,       // 无维护流程
    MS_TRANSLATE,  // IC IVAU：等待 VA 数据翻译（MMU 开时）
    MS_REQ,        // 请求已就绪，等待 imem 端口接受
    MS_WAIT,       // 维护请求已发出，等待 I-L1 响应
    MS_DONE,       // 维护完成（TLBI 脉冲已发 / DC 无操作），等待提交
    MS_DCZVA_WRITE // DC ZVA：8 次 8 字节清零写（dmem 端口）
  } maint_state_t;
  maint_state_t maint_state;
  logic         maint_trans_fault;  // IC IVAU 翻译失败（跳过缓存请求，
                                    // 与 QEMU system 模式 NOP 语义一致）
  logic         maint_done;         // 维护流程完成，可提交
  logic         par_update_valid;
  logic [63:0]  par_update_data;
  logic         par_update_pending;
  logic [63:0]  par_update_data_pending;
  logic         maint_va_pending;   // 正在翻译维护 VA（MS_TRANSLATE）
  logic         maint_imem_req_valid;
  lcvex_pkg::mem_req_t maint_imem_req;
  logic [63:0]  maint_req_addr;
  logic         maint_imem_req_accept;
  logic         maint_imem_owner;  // maintenance request owns IMEM port
  logic         maint_imem_req_selected;
  logic         maint_imem_rsp_pending; // accepted maintenance response in flight
  logic         maint_imem_rsp_owner;  // latched maintenance response selection
  logic         maint_imem_rsp_consume;
  logic         fetch_imem_req_valid;
  lcvex_pkg::mem_req_t fetch_imem_req;
  // DC ZVA：清零目标 PA（64B 对齐基址）、写循环索引
  logic [2:0]   maint_zva_idx;
  logic [63:0]  maint_zva_pa;
  logic         maint_zva_active;
  logic         maint_dmem_req_valid;
  logic         maint_dmem_req_accept;
  lcvex_pkg::mem_req_t maint_dmem_req;

  // ---- P5a：数据翻译（load/store 在 ID 翻译）----
  logic        mmu_en;
  logic        mmu_req_valid;
  logic        mmu_req_accept;
  logic        mmu_req_issue;    // 本周期请求被 MMU 接收
  logic [63:0] mmu_req_va;
  logic        mmu_req_is_insn;
  logic        mmu_req_is_write;
  // LDTR/STTR 按 EL0 权限访问（access_el=0）；AT S1E0* 也显式选择
  // EL0 regime，AT S1E1RP/WP 在 PSTATE.PAN=1 时选择 PAN regime。
  logic        mmu_access_el;
  logic        mmu_access_pan;
  // ERET 目标取指在 ERET 提交前发起（sys_fetch_redirect），此时 el 仍是
  // 旧 EL；取指权限必须按 ERET 恢复后的目标 EL（spsr[2]）检查，否则
  // 返回用户页（PXN=1）时被误判 EL1 取指权限 fault。仅当取指地址就是
  // ERET 目标（elr_el1）时适用；合并后的异常向量取指仍按 EL1。
  assign mmu_access_el = (maint_va_pending && d.maint_op == MAINT_AT)
                       ? (d.maint_at_regime == MAINT_AT_E0 ? 1'b0 : 1'b1)
                       : (data_req_valid && d.mem_unpriv) ? 1'b0
                       : (d.sys_op == SYS_ERET && if_pc == elr_el1)
                         ? spsr_el1[2]
                       : el;
  assign mmu_access_pan = (maint_va_pending && d.maint_op == MAINT_AT)
                        ? ((d.maint_at_regime == MAINT_AT_E1_PAN)
                           ? pstate_pan : 1'b0)
                        : ((mmu_access_el && !mmu_req_is_insn) ? pstate_pan
                                                               : 1'b0);
  logic        mmu_cacheable;    // MMU 输出：翻译结果可缓存（M2-4c）
  logic [7:0]  mmu_par_attr;     // AT PAR[63:56] ATTR
  logic [1:0]  mmu_par_sh;       // AT PAR[8:7] SH
  logic        data_req_valid;   // 数据翻译请求（优先）
  logic        mmu_done;
  logic [63:0] mmu_paddr;
  logic        mmu_fault;
  logic [5:0]  mmu_fault_fsc;  // MMU 长格式 FSC（R1）
  logic        mmu_walking;
  // ---- M1-B：dmem 数据请求状态（load/store 在 EX/MEM 停留到响应）----
  logic        dmem_req_issued;    // 数据请求已接受、响应未消费
  logic        dmem_done;          // 数据事务完成、等待 EX/MEM->WB
  logic [63:0] exmem_rdata_r;      // load 响应数据（进 WB）
  logic [63:0] memwb_rdata_r;      // WB 的 load 数据（已注册，不再读实时端口）
  logic [63:0] exmem_rdata2_r;     // LDP 第二响应数据（rt2）
  logic [63:0] memwb_rdata2_r;
  logic        pair_part;          // LDP/STP 第二段访存进行中
  logic        data_trans_active;   // 翻译进行中（冻结流水线）
  logic [63:0] trans_paddr_r;       // 翻译结果
  logic [63:0] trans_paddr2_r;      // LSE128 高半翻译结果
  logic        trans_cacheable_r;   // 翻译结果是否可缓存（M2-4c）
  logic        trans_cacheable2_r;  // LSE128 高半 cache 属性
  logic [5:0]  trans_fsc_r;         // 数据翻译 fault FSC（R1）
  logic        dabt_pending;        // 数据翻译 fault 待提交
  logic        trans_done_flag;     // 当前 IF/ID 指令已请求过翻译
  logic [63:0] trans_done_pc_r;     // 翻译完成绑定的 IF/ID 指令 PC
  logic        atomic128_second_needed; // 跨页 LSE128 需要第二次翻译

  // ---- P5a-2：取指翻译与 IABT 提交合并 ----
  logic        fetch_req_valid;     // 需要翻译 if_pc（MMU on、取指空闲）
  logic        fetch_req_accept;    // 取指请求被 MMU 接收
  logic        fetch_trans_busy;    // 取指翻译进行中（已接收）
  logic        fetch_walk;          // 取指页表遍历（冻结流水线）
  logic [63:0] fetch_pa_r;          // 翻译后物理取指地址
  logic        fetch_cacheable_r;   // 取指翻译是否可缓存（M2-4c）
  logic [5:0]  fetch_fsc_r;         // 取指翻译 fault FSC（R1）
  logic        fetch_faulted;       // 取指翻译 fault（fetch_pc_r=故障 VA）
  logic        fetch_merge_wb;      // WB 提交合并为 IABT
  logic        fetch_next_settled;  // ID 系统指令的 next_pc 取指翻译已定
  logic        sys_fetch_merge;     // ID 系统指令合并为 IABT
  logic        sys_fetch_redirect;  // 系统指令提前重定向取指（ERET/异常）
  logic [31:0] sys_merge_code;      // 合并异常编码
  logic [63:0] sys_merge_elr;       // 合并异常 ELR（故障 VA）
  logic [63:0] exc_vector_core;
  logic        sys_exc;             // 本次系统提交是否为异常
  logic [31:0] sys_exc_code;
  logic [63:0] sys_exc_elr;

  // ---- ID/EX ----
  logic          idex_valid;
  logic [31:0]   idex_insn;
  logic [63:0]   idex_pc;
  // In A64_FP_SIMD=0 no-FP gate builds, many FP/NEON decode fields are
  // intentionally not read by the removed datapath; keep the core lint clean
  // without suppressing unrelated signals globally.
  /* verilator lint_off UNUSEDSIGNAL */
  ex_pipe_t      idex_d;
  /* verilator lint_on UNUSEDSIGNAL */

  // ---- EX 组合 ----
  logic [63:0] alu_result;
  logic        flag_n, flag_z, flag_c, flag_v;
  logic [63:0] ex_wdata;       // EX 写回值（wb_sel 选择后）
  logic [63:0] ex_sp_wdata;
  logic [3:0]  ex_nzcv;
  logic [63:0] fp_ex_result;
  logic [63:0] fp_ex_int_result;
  logic [63:0] fp_ex_int_wdata;
  logic [31:0] fp_ex_flags;
  logic [3:0]  fp_ex_nzcv;
  logic [127:0] fp_ex_wdata;
  logic [31:0] fp_ex_fpsr_wdata;
  logic [127:0] neon_ex_wdata;
  logic [127:0] neon_fp_ex_wdata;
  logic [31:0]  neon_fp_ex_fpsr_wdata;
  /* verilator lint_off UNUSEDSIGNAL */
  logic        fp_div_busy;
  /* verilator lint_on UNUSEDSIGNAL */
  logic        fp_div_done;
  logic        fp_div_is_div;

  // ---- FP-P1：single-owner FP transaction ----
  logic        fp_tx_candidate;
  logic        fp_req_valid;
  fp_exec_req_t fp_req;
  logic        fp_req_ready;
  // The wrapper response has a one-entry elastic boundary in the core.  A
  // response can pass directly into EX/MEM when that slot is available; when
  // an older EX/MEM entry is held by WB/fetch-fault backpressure, the wrapper
  // response is captured here so TX_DONE does not inherit that control cone.
  logic        fp_exec_rsp_valid;
  fp_exec_rsp_t fp_exec_rsp;
  logic        fp_exec_rsp_ready;
  logic        fp_rsp_hold_valid;
  fp_exec_rsp_t fp_rsp_hold;
  logic        fp_rsp_valid;
  fp_exec_rsp_t fp_rsp;
  logic        fp_rsp_ready;
  logic        fp_consume;
  logic        fp_rsp_accept_blocked;
  logic        fp_tx_issued;
  logic        fp_tx_issued_dbg;
  logic        fp_tx_kill;
  logic        fp_tx_busy;
  // The system-commit drain condition excludes every pipeline stage that can
  // own an FP transaction.  Keep this observation local to the assertions;
  // it must not feed the FP handshake or re-create the timing cone being cut.
  logic        fp_tx_active;

  // ---- 多周期乘除（EX 槽）----
  logic        is_muldiv;
  logic        muldiv_busy;
  logic        muldiv_done;
  logic [63:0] muldiv_result;
  logic        muldiv_start;
  logic        muldiv_kill;
  logic        ex_busy;

  // ---- EX/MEM ----
  logic        exmem_valid;
  logic [31:0] exmem_insn;
  logic [63:0] exmem_pc;
  logic [63:0] exmem_next_pc;
  logic [63:0] exmem_wdata;
  logic        exmem_wb_we;
  logic [4:0]  exmem_wb_rd;
  logic        exmem_sp_we;
  logic [63:0] exmem_sp_wdata;
  logic        exmem_nzcv_we;
  logic [3:0]  exmem_nzcv;
  logic        exmem_is_load;
  logic        exmem_is_store;
  logic        exmem_is_ldxr;
  logic        exmem_is_stxr;
  logic        exmem_is_clrex;
  logic        exmem_is_atomic;
  atomic_op_t  exmem_atomic_op;
  logic [63:0] exmem_atomic_cmp;
  logic [63:0] exmem_atomic_cmp2;
  logic        exmem_atomic_store; // CAS 比较成功后实际发出写请求
  logic [1:0]  exmem_mem_size;
  logic        exmem_ldr_sw;
  logic        exmem_ldr_x;
  logic [63:0] exmem_mem_addr;
  logic [63:0] exmem_mem_wdata;
  logic [7:0]  exmem_mem_strb;
  logic [63:0] exmem_mem_paddr;
  logic [63:0] exmem_mem_paddr2;
  logic        exmem_mem_cacheable;
  logic        exmem_mem_cacheable2;
  logic        exmem_is_pair;
  logic [63:0] exmem_mem_wdata2;
  logic        exmem_fp_valid;
  logic        exmem_fp_is_double;
  logic        exmem_fp_wb_we;
  logic [4:0]  exmem_fp_rd;
  logic        exmem_fp_mem_load;
  logic [127:0] exmem_fp_wdata;
  logic [31:0] exmem_fp_fpsr_wdata;
  logic        exmem_fp_fpsr_we;
  logic        exmem_neon_valid;
  logic        exmem_neon_wb_we;
  logic [4:0]  exmem_neon_rd;
  logic        exmem_neon_mem_load;
  logic        exmem_neon_quad;
  logic        exmem_neon_mem_replicate;
  logic [127:0] exmem_neon_wdata;
  logic [4:0]  exmem_wb2_rd;
  logic        exmem_wb2_we;
  logic [63:0] exmem_wb2_extra;
  logic        exmem_wb3_we;
  logic [4:0]  exmem_wb3_rd;
  logic [63:0] exmem_wb3_extra;
  // STXR 两相访存：1=读比较阶段，0=条件写阶段
  logic        stxr_read_phase;
  logic        atomic_read_phase;  // LSE：读旧值阶段=1，随后发新值写请求
  logic [1:0]  atomic_phase;       // CASP：低读/高读/低写/高写
  logic [63:0] exmem_atomic_new;
  logic [63:0] exmem_atomic_new2;
  logic [63:0] exmem_atomic_old_u;
  logic [63:0] exmem_atomic_arg_u;
  logic signed [63:0] exmem_atomic_old_s;
  logic signed [63:0] exmem_atomic_arg_s;
  logic        stxp_cmp_hi;    // STXP 比较阶段：高 64 位读取进行中
  logic        exmem_stxr_pass;     // 监视器+值比较通过（进入写阶段）
  logic        exmem_stxr_result;   // 状态结果（0=通过 1=失败，MEM 决定）

  // ---- MEM/WB ----
  logic        memwb_valid;
  logic [31:0] memwb_insn;
  logic [63:0] memwb_pc;
  logic [63:0] memwb_next_pc;
  logic [63:0] memwb_wdata;
  logic        memwb_wb_we;
  logic [4:0]  memwb_wb_rd;
  logic        memwb_sp_we;
  logic [63:0] memwb_sp_wdata;
  logic        memwb_nzcv_we;
  logic [3:0]  memwb_nzcv;
  logic        memwb_is_load;
  logic [1:0]  memwb_mem_size;
  logic        memwb_ldr_sw;
  logic        memwb_ldr_x;
  logic        memwb_is_store;
  logic        memwb_is_ldxr;
  logic        memwb_is_stxr;
  logic        memwb_is_clrex;
  logic [63:0] memwb_mem_addr;
  logic [63:0] memwb_mem_wdata;
  logic [63:0] memwb_mem_wdata2;
  logic [7:0]  memwb_mem_strb;
  logic        memwb_is_pair;
  logic        memwb_fp_valid;
  logic        memwb_fp_wb_we;
  logic [4:0]  memwb_fp_rd;
  logic [127:0] memwb_fp_wdata;
  logic [31:0] memwb_fp_fpsr_wdata;
  logic        memwb_fp_fpsr_we;
  logic        memwb_neon_valid;
  logic        memwb_neon_wb_we;
  logic [4:0]  memwb_neon_rd;
  logic [127:0] memwb_neon_wdata;
  logic [4:0]  memwb_wb2_rd;
  logic        memwb_wb2_we;
  logic [63:0] memwb_wb2_extra;
  logic        memwb_wb3_we;
  logic [4:0]  memwb_wb3_rd;
  logic [63:0] memwb_wb3_extra;
  logic        memwb_stxr_result;   // STXR 状态结果（进 WB 写回）
  logic        memwb_stxr_fail;     // STXR 失败：提交包抑制存储副作用
  logic [63:0] wb_wdata;       // WB 最终写回值（load 扩展后）
  logic [63:0] wb2_wdata;      // LDP 第二写回值

  // ---- 提交锁存 ----
  logic              commit_valid_r;
  logic [63:0]       commit_pc_r;
  logic [63:0]       commit_next_pc_r;
  logic [31:0]       commit_insn_r;
  logic              commit_gpr_we_r;
  logic [4:0]        commit_gpr_rd_r;
  logic [63:0]       commit_gpr_wdata_r;
  logic              commit_gpr2_we_r;
  logic [4:0]        commit_gpr2_rd_r;
  logic [63:0]       commit_gpr2_wdata_r;
  logic              commit_gpr3_we_r;
  logic [4:0]        commit_gpr3_rd_r;
  logic [63:0]       commit_gpr3_wdata_r;
  logic              commit_sp_we_r;
  logic [63:0]       commit_sp_wdata_r;
  logic              commit_nzcv_we_r;
  logic [3:0]        commit_nzcv_r;
  logic              commit_mem_we_r;
  logic [63:0]       commit_mem_addr_r;
  logic [63:0]       commit_mem_wdata_r;
  logic [7:0]        commit_mem_strb_r;
  logic              commit_mem2_we_r;
  logic [63:0]       commit_mem2_addr_r;
  logic [63:0]       commit_mem2_wdata_r;
  logic [7:0]        commit_mem2_strb_r;
  logic              commit_exc_valid_r;
  logic [31:0]       commit_exc_code_r;
  logic [31:0]       commit_exc_esr_r;
  logic [63:0]       commit_exc_far_r;
  logic              commit_mon_we_r;
  logic              commit_mon_valid_r;
  logic [63:0]       commit_mon_addr_r;
  logic [63:0]       commit_mon_data_r;
  logic [63:0]       commit_mon_data2_r;
  logic [2:0]        commit_vec_write_count_r;
  logic [4:0]        commit_vec_rd0_r;
  logic [4:0]        commit_vec_rd1_r;
  logic [4:0]        commit_vec_rd2_r;
  logic [4:0]        commit_vec_rd3_r;
  logic [127:0]      commit_vec_wdata0_r;
  logic [127:0]      commit_vec_wdata1_r;
  logic [127:0]      commit_vec_wdata2_r;
  logic [127:0]      commit_vec_wdata3_r;
  logic              commit_fpcr_we_r;
  logic [31:0]       commit_fpcr_wdata_r;
  logic              commit_fpsr_we_r;
  logic [31:0]       commit_fpsr_wdata_r;
  logic              memwb_committed_r;  // 当前 WB 条目已提交（防翻译冻结期重提交）
  logic              exmem_exc;          // EX/MEM load/store 响应 fault -> DABT
  logic              memwb_exc;          // 同上，已进 WB

  // ---- M1：WB 提交 valid/ready（显式 commit_fire，不再依赖气泡边沿）----
  // stall_wb：WB 满且消费者未就绪（背压，各上游级保持）。
  // commit_fire：WB 条目未提交且消费者就绪 -> 提交并消费该条目；
  //   与旧“0->1 边沿”同拍（条目进入 WB 的首周期即提交），但改为
  //   显式 valid/ready：连续 WB 有效时可每周期提交一条，消费者忙时
  //   条目保持不丢不重。
  logic stall_wb;
  logic commit_fire;
  logic memwb_fetch_target_settled;
  logic memwb_fetch_wait;
  logic exmem_can_adv;
  logic exmem_can_accept;
  // 取指 fault 合并要求普通提交先等当前 MEM/WB 指令的 next_pc 有已定
  // 结果。否则 taken BR 在目标 MMU walk 期间会先正常退休，随后到达的
  // IABT 只能成为无主 fault FIFO head，错过 fetch_merge_wb。把等待并入
  // WB backpressure 可同时保持 MEM/WB、EX/MEM 和 FIFO pop 的原子性；
  // FIFO-off 仅对明确匹配的 legacy fetch context 启用同一等待。
  assign stall_wb = memwb_valid &&
                    (!commit_ready || memwb_fetch_wait);
  assign commit_fire = memwb_valid && !memwb_committed_r && commit_ready &&
                       !memwb_fetch_wait;
  // EX/MEM 推进条件：WB 可接收、且无翻译/数据事务占用 EX/MEM
  assign exmem_can_adv = !stall_wb && !data_trans_active && !fetch_walk &&
                         !data_mmu_issue && !dmem_pending;
  // EX/MEM is an elastic slot: even when MEM/WB is blocked, an empty EX/MEM
  // may accept exactly one ID/EX result and hold it.  Keep this distinct from
  // exmem_can_adv (which means an existing EX/MEM entry may leave for WB), so
  // every producer uses the same capture handshake and cannot duplicate an
  // ID/EX token while filling the empty slot.
  // Deliberately use the same no-loop subset as branch flush: data_mmu_issue
  // depends on frontend arbitration and cannot feed this signal without
  // closing a flush -> fetch request -> MMU issue -> flush combinational loop.
  assign exmem_can_accept = !fetch_walk && !dmem_pending &&
                            (!exmem_valid || !stall_wb);

  // ERET 目标越界时的异常向量：用 ERET 恢复后的 EL/SP 计算偏移
  logic [63:0] eret_exc_vector;
  assign eret_exc_vector = vbar_el1 +
      (spsr_el1[2] ? (spsr_el1[0] ? 64'h200 : 64'h000) : 64'h400);

  // 系统指令提交后的下一条 PC（异常向量 / ELR / 顺序下一条），
  // 同时驱动取指重定向与提交包，保证两者一致。
  logic [63:0] sys_next_pc;

  // ---- PE-F1a：frontend kill、FIFO 握手和 stale quarantine ----
  // FETCH_FIFO_DEPTH=2 是冻结契约的一部分；depth=0 通过 feature-off 语义
  // 保留旧的单 context 路径，非法的其它值也不会改变公共接口。
  logic fetch_fifo_active;
  assign fetch_fifo_active = (FETCH_FIFO_ENABLE != 0) &&
                             (FETCH_FIFO_DEPTH == 2);
  assign fetch_fifo_occupancy = fetch_fifo_active ? fetch_fifo_count : 2'd0;
  assign fetch_fifo_head_valid_dbg = fetch_fifo_active &&
      (fetch_fifo_count != 2'd0) && fetch_fifo_valid[fetch_fifo_head] &&
      (fetch_fifo_epoch_r[fetch_fifo_head] == fetch_epoch);
  assign fetch_fifo_head_epoch_dbg = fetch_fifo_head_valid_dbg
      ? fetch_fifo_epoch_r[fetch_fifo_head] : '0;
  assign fetch_fifo_head_seq_dbg = fetch_fifo_head_valid_dbg
      ? fetch_fifo_seq_r[fetch_fifo_head] : 16'd0;
  assign fetch_fifo_head_pc_dbg = fetch_fifo_head_valid_dbg
      ? fetch_fifo_pc_r[fetch_fifo_head] : 64'd0;
  assign fetch_stale_drain = fetch_fifo_active &&
                             (fetch_stale_mmu || fetch_stale_imem);

  // 维护开始也属于 frontend kill：IC/TLBI 必须先丢掉年轻 FIFO/IFID，
  // 并把仍在下游的旧事务纳入本地 quarantine。TLBI 另由 MMU 自身取消
  // page walk，因此 metadata block 对该一类不等待不存在的 done。
  assign frontend_kill = fetch_fifo_active &&
      (flush_id || sys_commit || fetch_merge_wb || wb_exc_commit ||
       irq_taken || wfi_irq_take || wfi_wake || sys_fetch_redirect ||
       tlb_invalidate || difftest_restore_sys_valid ||
       (sys_maint_at_id && (maint_state == MS_IDLE) &&
        !memwb_fetch_wait));
  assign fetch_fifo_flush = fetch_fifo_active && frontend_kill;
  assign fetch_epoch_bump = frontend_kill;

  assign fetch_fifo_head_fault = fetch_fifo_active &&
      (fetch_fifo_count != 2'd0) && fetch_fifo_valid[fetch_fifo_head] &&
      (fetch_fifo_epoch_r[fetch_fifo_head] == fetch_epoch) &&
      fetch_fifo_fault[fetch_fifo_head];
  // Keep the pop predicate independent of fetch request issue.  Using
  // `stall_if` here would form a combinational loop through
  // fetch_fifo_space -> fetch_req_valid -> mmu_req_valid -> data_mmu_issue.
  // The expanded predicate below is the same front-end safety set while
  // making data translation/EX-MEM backpressure explicit.
  // `commit_ready` only consumes an already-present architectural commit.
  // Frontend progress is backpressured by `stall_wb` once MEM/WB is full;
  // gating FIFO pop directly on commit_ready would make an otherwise idle
  // IF/ID slot clear when no new FIFO entry is accepted (H-04).
  assign fetch_fifo_pop = fetch_fifo_active && !frontend_kill &&
      !fetch_stale_drain && !sys_at_id &&
      !data_wait_for_translation && !load_use && !fp_load_use &&
      !ex_id_gpr_hazard && !ex_id_sp_hazard && !ex_id_flags_hazard &&
      !ex_id_v_hazard && !exmem_v_hazard &&
      !sys_hold &&
      !(excl_at_id && (idex_valid || exmem_valid || memwb_valid ||
                       data_trans_active || fetch_walk || dmem_pending)) &&
      !data_trans_active && !atomic128_second_needed &&
      !fetch_walk && !stall_wb && !dmem_pending && !ex_busy && !wfi_idle &&
      (fetch_fifo_count != 2'd0) && !fetch_fifo_head_fault;
  assign fetch_fifo_space = !fetch_fifo_active ||
      (fetch_fifo_count < 2'd2) || fetch_fifo_pop;

  // A response without a public ID is current only while the single local
  // context is active and its captured epoch still equals the generation.
  // All responses consumed while kill/quarantine is asserted are dropped.
  logic fetch_imem_rsp_current;
  logic fetch_mmu_fault_current;
  assign fetch_imem_rsp_current = fetch_fifo_active && !frontend_kill &&
      !fetch_stale_imem && fetch_pending &&
      (fetch_ctx_epoch == fetch_epoch) &&
      imem_rsp_valid && imem_rsp_ready;
  assign fetch_mmu_fault_current = fetch_fifo_active && !frontend_kill &&
      !fetch_stale_mmu && fetch_trans_busy &&
      (fetch_ctx_epoch == fetch_epoch) && mmu_done && mmu_fault;
  assign fetch_fifo_push = fetch_fifo_active && !frontend_kill &&
      !fetch_stale_drain && fetch_fifo_space &&
      (fetch_imem_rsp_current || fetch_mmu_fault_current ||
       fetch_fault_pending);
  assign fetch_stale_rsp_drop = fetch_fifo_active &&
      (((fetch_stale_imem || (frontend_kill && fetch_pending)) &&
        imem_rsp_valid && imem_rsp_ready) ||
       ((fetch_stale_mmu ||
         (frontend_kill && fetch_trans_busy && !tlb_invalidate)) &&
        mmu_done));

  always_comb begin
    fetch_fifo_has_target = 1'b0;
    for (int i = 0; i < 2; i++) begin
      if (fetch_fifo_valid[i] && fetch_fifo_epoch_r[i] == fetch_epoch &&
          fetch_fifo_pc_r[i] == d.next_pc)
        fetch_fifo_has_target = 1'b1;
    end
  end

  // A current-epoch FIFO entry (normal or fault), a recorded matching fetch
  // fault, or an instruction already delivered into a younger pipeline stage
  // all constitute a settled outcome for this older MEM/WB entry.  The stage
  // checks matter when a fast target is popped from the FIFO before the older
  // instruction reaches its commit edge.  Fault entries are never popped, so
  // the matching fetch_faulted term is what turns them into an IABT merge.
  // Once an instruction is in IF/ID or a later in-order stage, it has already
  // crossed the fetch delivery boundary; frontend kill clears those stages
  // explicitly, so their PC match is the relevant proof of delivery here.
  always_comb begin
    memwb_fetch_target_settled = 1'b1;
    if (memwb_valid && !memwb_exc) begin
      if (fetch_fifo_active) begin
        memwb_fetch_target_settled = 1'b0;
        for (int i = 0; i < 2; i++) begin
          if (fetch_fifo_valid[i] &&
              fetch_fifo_epoch_r[i] == fetch_epoch &&
              fetch_fifo_pc_r[i] == memwb_next_pc)
            memwb_fetch_target_settled = 1'b1;
        end
        if (fetch_faulted && fetch_ctx_epoch == fetch_epoch &&
            fetch_pc_r == memwb_next_pc)
          memwb_fetch_target_settled = 1'b1;
      end else if (fetch_pc_r == memwb_next_pc &&
                   (fetch_pending || fetch_translated || fetch_trans_busy ||
                    fetch_got_data || fetch_faulted)) begin
        // Legacy single-context mode has no FIFO delivery token.  Only an
        // explicitly matching in-flight context is fenced, and it settles
        // at the actual IMEM response/fault rather than translation alone.
        memwb_fetch_target_settled = fetch_got_data || fetch_faulted;
      end
      if (ifid_valid && ifid_pc == memwb_next_pc)
        memwb_fetch_target_settled = 1'b1;
      if (idex_valid && idex_pc == memwb_next_pc)
        memwb_fetch_target_settled = 1'b1;
      if (exmem_valid && exmem_pc == memwb_next_pc)
        memwb_fetch_target_settled = 1'b1;
    end
  end
  assign memwb_fetch_wait = memwb_valid && !memwb_exc &&
                            !memwb_fetch_target_settled;

  logic [FETCH_EPOCH_W-1:0] fetch_fifo_push_epoch;
  logic [15:0]              fetch_fifo_push_seq;
  logic [63:0]              fetch_fifo_push_pc;
  logic [31:0]              fetch_fifo_push_insn;
  logic                     fetch_fifo_push_fault;
  logic [5:0]               fetch_fifo_push_fsc;
  always_comb begin
    fetch_fifo_push_epoch = fetch_ctx_epoch;
    fetch_fifo_push_seq   = fetch_ctx_seq;
    fetch_fifo_push_pc    = fetch_pc_r;
    fetch_fifo_push_insn  = 32'd0;
    fetch_fifo_push_fault = 1'b1;
    fetch_fifo_push_fsc   = fetch_fsc_r;
    if (fetch_imem_rsp_current) begin
      fetch_fifo_push_epoch = fetch_ctx_epoch;
      fetch_fifo_push_seq   = fetch_ctx_seq;
      fetch_fifo_push_pc    = fetch_pc_r;
      fetch_fifo_push_insn  = imem_rsp.fault ? 32'd0 : imem_rsp.rdata[31:0];
      fetch_fifo_push_fault = imem_rsp.fault;
      fetch_fifo_push_fsc   = imem_rsp.fault ? 6'h10 : 6'd0;
    end else if (fetch_mmu_fault_current) begin
      // fetch_pc_r is captured at translation acceptance, while mmu_fault_fsc
      // is the result for that same request (not the next tail PC).
      fetch_fifo_push_epoch = fetch_ctx_epoch;
      fetch_fifo_push_seq   = fetch_ctx_seq;
      fetch_fifo_push_pc    = fetch_pc_r;
      fetch_fifo_push_insn  = 32'd0;
      fetch_fifo_push_fault = 1'b1;
      fetch_fifo_push_fsc   = mmu_fault_fsc;
    end
  end

  // P7-0 FP sidecar restore uses split 64-bit halves at the core boundary;
  // lcvex_fp_state keeps the architectural V registers as raw 128-bit values.
  genvar fp_i;
  generate
    for (fp_i = 0; fp_i < 32; fp_i = fp_i + 1) begin : g_fp_state_ports
      assign difftest_restore_fp_v[fp_i] = {
          difftest_restore_fp_v_hi[fp_i], difftest_restore_fp_v_lo[fp_i]};
      assign fp_v_lo[fp_i] = fp_v_state[fp_i][63:0];
      assign fp_v_hi[fp_i] = fp_v_state[fp_i][127:64];
    end
  endgenerate

  // P7：FP state access 包括标量 FP、Advanced SIMD 和对应访存；提交阶段再 OR
  // 当前 WB 的 FP 条目，避免 IF/ID 已经进入年轻指令后丢失 FPEN 检查。
  // A retiring FP/NEON WB entry owns this access sample.  Do not OR a
  // younger IF/ID FPEN trap into the same cycle: fp_state uses this signal to
  // validate the older commit effect, and a younger denied access must not
  // suppress an already-authorized V/FPSR update.  The younger trap remains
  // in IF/ID and is re-evaluated on its own system-commit cycle.
  assign fp_access_valid = commit_fire && (memwb_fp_valid || memwb_neon_valid)
                           ? 1'b1
                           : (ifid_valid &&
                              (d.fp_valid || d.neon_valid ||
                               (d.sys_reg inside {SREG_FPCR, SREG_FPSR})));

  // lcvex_fp_state 的 effect 输入来自当前 MEM/WB 条目，而不是 commit
  // register 的上一个周期值。这样 V/FPSR 更新与 commit_fire 同一时钟沿，
  // 且在 commit_ready=0 时不会提前改变架构状态。
  assign fp_commit_vec_write_count_in =
      ((memwb_fp_valid && memwb_fp_wb_we) ||
       (memwb_neon_valid && memwb_neon_wb_we)) && !memwb_exc
          ? 3'd1 : 3'd0;
  assign fp_commit_vec_rd0_in = memwb_neon_valid
                                ? memwb_neon_rd : memwb_fp_rd;
  assign fp_commit_vec_wdata0_in = memwb_neon_valid
                                   ? memwb_neon_wdata : memwb_fp_wdata;
  assign fp_commit_vec_rd1_in = 5'd0;
  assign fp_commit_vec_rd2_in = 5'd0;
  assign fp_commit_vec_rd3_in = 5'd0;
  assign fp_commit_vec_wdata1_in = 128'd0;
  assign fp_commit_vec_wdata2_in = 128'd0;
  assign fp_commit_vec_wdata3_in = 128'd0;
  assign fp_commit_fpsr_we_in = memwb_fp_valid && memwb_fp_fpsr_we &&
                                !memwb_exc;
  assign fp_commit_fpsr_wdata_in = fpsr_state | memwb_fp_fpsr_wdata;

  lcvex_fp_state fp_state (
      .clk                         (clk),
      .rst_n                       (rst_n),
      .current_el                  ({1'b0, el}),
      .fp_access_valid             (fp_access_valid),
      .fp_access_allowed           (fp_access_allowed),
      .fp_trap_valid               (fp_trap_valid),
      .fp_trap_code                (fp_trap_code),
      .fp_trap_esr                 (fp_trap_esr),
      .fpcr_state                  (fpcr_state),
      .fpsr_state                  (fpsr_state),
      .cpacr_el1_state             (fp_cpacr_el1_state),
      .cpacr_fpen                  (fp_cpacr_fpen),
      .fpcr_read_data              (fpcr_read_data),
      .fpsr_read_data              (fpsr_read_data),
      .cpacr_read_data             (fp_cpacr_read_data),
      .v_state                     (fp_v_state),
      .sys_commit_valid            (sys_commit),
      .sys_fpcr_we                 (d.sys_op == SYS_MSR &&
                                    d.sys_reg == SREG_FPCR),
      .sys_fpcr_wdata              (d.sys_wdata[31:0]),
      .sys_fpsr_we                 (d.sys_op == SYS_MSR &&
                                    d.sys_reg == SREG_FPSR),
      .sys_fpsr_wdata              (d.sys_wdata[31:0]),
      .sys_cpacr_we                (d.sys_op == SYS_MSR &&
                                    d.sys_reg == SREG_CPACR_EL1),
      .sys_cpacr_wdata             (d.sys_wdata),
      .sys_fpcr_write_accept       (sys_fpcr_write_accept),
      .sys_fpsr_write_accept       (sys_fpsr_write_accept),
      .sys_cpacr_write_accept      (sys_cpacr_write_accept),
      .sys_fp_access_blocked       (sys_fp_access_blocked),
      .sys_cpacr_write_blocked     (sys_cpacr_write_blocked),
      .commit_valid                (commit_fire),
      .commit_vec_write_count      (fp_commit_vec_write_count_in),
      .commit_vec_rd0              (fp_commit_vec_rd0_in),
      .commit_vec_rd1              (fp_commit_vec_rd1_in),
      .commit_vec_rd2              (fp_commit_vec_rd2_in),
      .commit_vec_rd3              (fp_commit_vec_rd3_in),
      .commit_vec_wdata0           (fp_commit_vec_wdata0_in),
      .commit_vec_wdata1           (fp_commit_vec_wdata1_in),
      .commit_vec_wdata2           (fp_commit_vec_wdata2_in),
      .commit_vec_wdata3           (fp_commit_vec_wdata3_in),
      .commit_fpcr_we              (1'b0),
      .commit_fpcr_wdata           (32'd0),
      .commit_fpsr_we              (fp_commit_fpsr_we_in),
      .commit_fpsr_wdata           (fp_commit_fpsr_wdata_in),
      .commit_effect_valid         (fp_commit_effect_valid),
      .commit_effect_error         (fp_commit_effect_error),
      .commit_effect_vec_write_count(fp_commit_effect_vec_write_count),
      .commit_effect_vec_rd0       (fp_commit_effect_vec_rd0),
      .commit_effect_vec_rd1       (fp_commit_effect_vec_rd1),
      .commit_effect_vec_rd2       (fp_commit_effect_vec_rd2),
      .commit_effect_vec_rd3       (fp_commit_effect_vec_rd3),
      .commit_effect_vec_wdata0    (fp_commit_effect_vec_wdata0),
      .commit_effect_vec_wdata1    (fp_commit_effect_vec_wdata1),
      .commit_effect_vec_wdata2    (fp_commit_effect_vec_wdata2),
      .commit_effect_vec_wdata3    (fp_commit_effect_vec_wdata3),
      .commit_effect_fpcr_we       (fp_commit_effect_fpcr_we),
      .commit_effect_fpcr_wdata    (fp_commit_effect_fpcr_wdata),
      .commit_effect_fpsr_we       (fp_commit_effect_fpsr_we),
      .commit_effect_fpsr_wdata    (fp_commit_effect_fpsr_wdata),
      .difftest_restore_fp_valid   (difftest_restore_fp_valid),
      .difftest_restore_fpcr       (difftest_restore_fpcr),
      .difftest_restore_fpsr       (difftest_restore_fpsr),
      .difftest_restore_v          (difftest_restore_fp_v),
      .difftest_restore_sys_valid  (difftest_restore_sys_valid),
      .difftest_restore_cpacr_el1 (difftest_restore_cpacr_el1)
  );

  lcvex_decode #(
      .SRAM_BASE (SRAM_BASE),
      .SRAM_TOP  (SRAM_TOP),
      .MMIO_BASE (MMIO_BASE),
      .MMIO_TOP  (MMIO_TOP),
      .MMIO2_BASE (MMIO2_BASE),
      .MMIO2_TOP  (MMIO2_TOP),
      .MMIO3_BASE (MMIO3_BASE),
      .MMIO3_TOP  (MMIO3_TOP),
      .MMIO4_BASE (MMIO4_BASE),
      .MMIO4_TOP  (MMIO4_TOP),
      .A64_FP_SIMD (A64_FP_SIMD),
      .CNTFRQ_HZ   (CNTFRQ_HZ)
  ) decode (
      .insn     (ifid_insn),
      .pc       (ifid_pc),
      .gpr      (gprv),
      .v        (fpv),
      .sp       (spv),
      .nzcv     (nzcvv),
      .el       (el),
      .sp_sel   (sp_sel),
      .dit      (pstate_dit),
      .ssbs     (pstate_ssbs),
      .uao      (pstate_uao),
      .pan      (pstate_pan),
      .tco      (pstate_tco),
      .allint   (pstate_allint),
      .vbar_el1 (vbar_el1),
      .elr_el1  (elr_el1),
      .spsr_el1 (spsr_el1),
      .sctlr_el1 (sctlr_el1),
      .tcr_el1   (tcr_el1),
      .ttbr0_el1 (ttbr0_el1),
      .ttbr1_el1 (ttbr1_el1),
      .mair_el1  (mair_el1),
      .esr_el1   (esr_el1),
      .far_el1   (far_el1),
      .sp_el0    (sp_el0),
      .cpacr_el1 (cpacr_el1),
      .fpcr_read_data (fpcr_read_data),
      .fpsr_read_data (fpsr_read_data),
      .fp_access_allowed (fp_access_allowed),
      .mdscr_el1 (mdscr_el1),
      .pmuserenr_el0 (pmuserenr_el0),
      .cntkctl_el1  (cntkctl_el1),
      .tpidr_el0    (tpidr_el0),
      .tpidrro_el0  (tpidrro_el0),
      .tpidr_el1    (tpidr_el1),
      .contextidr_el1 (contextidr_el1),
      .tcr2_el1     (tcr2_el1),
      .pir_el1      (pir_el1),
      .pire0_el1    (pire0_el1),
      .par_el1      (par_el1),
      .daif         (daif),
      .zcr_el1      (zcr_el1),
      .smcr_el1     (smcr_el1),
      .csselr_el1   (csselr_el1),
      .mmu_en   (mmu_en),
      .d        (d)
  );

  // ---- P7-1/2/3：FP/NEON 执行单元真 generate-gate ----
  // A64_FP_SIMD=0 时不仅让 ID 寄存器报告“无 FP/NEON”，而且完全不例化
  // lcvex_fp_scalar / lcvex_neon_int / lcvex_neon_fp，只把 EX 结果和
  // 多周期握手线接为常量，供纯标量 FPGA/Verilator 实验使用。
  // 该分支仍是实验开关：默认 A64_FP_SIMD=1 保持不变；=0 不承诺 FP/NEON
  // 指令语义（软件应通过 ID 寄存器确认无 FP/NEON 并避免执行）。
  generate
    if (A64_FP_SIMD) begin : g_fp_simd_enabled
      // FP-P1：单在途 transaction wrapper。内部仍使用现有 raw-bit
      // scalar/NEON 执行单元；请求在 accept 时锁存全部操作数/FPCR，
      // response 在 backpressure 下保持。
      lcvex_fp_exec fp_exec (
          .clk        (clk),
          .rst_n      (rst_n),
          .req_valid  (fp_req_valid),
          .req        (fp_req),
          .req_ready  (fp_req_ready),
          .rsp_valid  (fp_exec_rsp_valid),
          .rsp        (fp_exec_rsp),
          .rsp_ready  (fp_exec_rsp_ready),
          .kill       (fp_tx_kill),
          .busy       (fp_tx_busy),
          .issued     (fp_tx_issued_dbg)
      );

      // P7-2：Advanced SIMD/Q integer datapath. It is combinational like the
      // scalar ALU; the ID/EX operands are locked until the single commit reaches
      // WB, so commit backpressure cannot change the architectural result.
      lcvex_neon_int neon_int (
          .valid      (idex_valid && idex_d.neon_valid &&
                       !idex_d.neon_mem_load && !idex_d.neon_fp_valid),
          .op         (idex_d.neon_op),
          .size       (idex_d.neon_size),
          .shift_amt  (idex_d.neon_shift),
          .quad       (idex_d.neon_quad),
          .operand_a  (idex_d.neon_operand_a),
          .operand_b  (idex_d.neon_operand_b),
          .result     (neon_ex_wdata)
      );
    end else begin : g_fp_simd_disabled
      assign fp_div_busy     = 1'b0;
      assign fp_div_done     = 1'b0;
      assign neon_ex_wdata   = 128'd0;
      assign fp_req_ready    = 1'b0;
      assign fp_exec_rsp_valid = 1'b0;
      assign fp_exec_rsp       = '0;
      assign fp_tx_busy      = 1'b0;
    end
  endgenerate

  // The wrapper response is either consumed directly or held for the core
  // pipeline.  The core-facing valid/payload pair remains stable across a
  // downstream stall; the wrapper-facing ready is intentionally independent
  // of WB/fetch-fault backpressure and only depends on the empty hold slot.
  // This is a one-entry elastic boundary, not an architectural queue: direct
  // handshakes preserve the existing response-to-EX/MEM latency, while a
  // blocked response was already required to remain in TX_DONE until the
  // same later EX/MEM acceptance edge.
  assign fp_rsp_valid = fp_rsp_hold_valid || fp_exec_rsp_valid;
  assign fp_rsp       = fp_rsp_hold_valid ? fp_rsp_hold : fp_exec_rsp;

  // FP result mirrors from the core-facing response. They are only
  // meaningful while fp_tx_candidate is being consumed; no-FP builds keep
  // them zero through the disabled branch above.
  assign fp_ex_result       = fp_rsp_valid ? fp_rsp.v_data[63:0] : 64'd0;
  assign fp_ex_int_result   = fp_rsp_valid ? fp_rsp.gpr_data : 64'd0;
  assign fp_ex_flags        = fp_rsp_valid ? fp_rsp.fpsr_flags : 32'd0;
  assign fp_ex_nzcv         = fp_rsp_valid ? fp_rsp.nzcv : 4'd0;
  assign neon_fp_ex_wdata   = fp_rsp_valid ? fp_rsp.v_data : 128'd0;
  assign neon_fp_ex_fpsr_wdata = fp_rsp_valid ? fp_rsp.fpsr_flags : 32'd0;

  // FP16 标量写回：
  // - FCVT H->S/H->D（src=H，fcvt_dst_half=0）结果格式是 S/D，按目的
  //   宽度写回；H 高 32 位为零。
  // - FCVT S/D->H（dst=H）只写低 16 位。
  // - 其它 H 指令只写低 16 位。
  // S/D 行为不变（NEP 未实现）。
  assign fp_ex_wdata =
      (idex_d.fp_is_half && idex_d.fp_op == FP_OP_FCVT &&
       !idex_d.fp_fcvt_dst_half)
          ? (idex_d.fp_is_double
             ? {64'd0, fp_ex_result}
             : {96'd0, fp_ex_result[31:0]})
          : (idex_d.fp_is_half
             ? {112'd0, fp_ex_result[15:0]}
             : (idex_d.fp_is_double
                ? {64'd0, fp_ex_result}
                : {96'd0, fp_ex_result[31:0]}));
  // FCVTZS/FCVTZU scalar 目的为 GPR；W 形式结果已在单元内零扩展。
  assign fp_ex_int_wdata = fp_ex_int_result;
  // Carry per-instruction exception bits through the pipeline. The current
  // architectural FPSR is ORed at commit so back-to-back operations preserve
  // all sticky flags.
  assign fp_ex_fpsr_wdata = fp_ex_flags;

  // V forwarding is limited to the architectural state and the MEM/WB
  // registered result.  ID/EX and EX/MEM V forwarding used to let a 128-bit
  // result feed decode and the ID/EX operand_c register in the same cycle.
  // The corresponding ex_id_v_hazard/exmem_v_hazard stalls below keep the
  // decode view precise while inserting the pipeline cut.  FP loads remain
  // covered by fp_load_use and are likewise visible only at MEM/WB.
  always_comb begin
    for (int i = 0; i < 32; i++) begin
      fpv[i] = fp_v_state[i];
      if (memwb_valid && !memwb_committed_r &&
                   memwb_fp_valid && memwb_fp_wb_we &&
                   memwb_fp_rd == i[4:0]) begin
        fpv[i] = memwb_fp_wdata;
      end else if (memwb_valid && !memwb_committed_r &&
                   memwb_neon_valid && memwb_neon_wb_we &&
                   memwb_neon_rd == i[4:0]) begin
        fpv[i] = memwb_neon_wdata;
      end
    end
  end

  // Linux IRQ/内核文本路径会同时保持远超 8 个 4 KiB 页的翻译；
  // QEMU TLB 命中仍可在 PTE 暂时 invalid 的 break-before-make 窗口
  // 继续访问。顺序核采用 64 项全相联 TLB，避免过早淘汰造成与 QEMU
  // 可观察 TLB 语义不一致。
  lcvex_mmu #(
      .TLB_ENTRIES(64),
      .SRAM_BASE (SRAM_BASE),
      .SRAM_TOP  (SRAM_TOP),
      .MMIO_BASE (MMIO_BASE),
      .MMIO_TOP  (MMIO_TOP),
      .MMIO2_BASE(MMIO2_BASE),
      .MMIO2_TOP (MMIO2_TOP),
      .MMIO3_BASE(MMIO3_BASE),
      .MMIO3_TOP (MMIO3_TOP),
      .MMIO4_BASE(MMIO4_BASE),
      .MMIO4_TOP (MMIO4_TOP)
  ) mmu (
      .clk        (clk),
      .rst_n      (rst_n),
      .req_valid  (mmu_req_valid),
      .req_va     (mmu_req_va),
      .req_is_insn(mmu_req_is_insn),
      .req_is_write(mmu_req_is_write),
      .req_accept (mmu_req_accept),
      .done       (mmu_done),
      .paddr      (mmu_paddr),
      .fault      (mmu_fault),
      .fault_fsc  (mmu_fault_fsc),
      .cacheable  (mmu_cacheable),
      .par_attr   (mmu_par_attr),
      .par_sh     (mmu_par_sh),
      .walking    (mmu_walking),
      .mmu_en     (mmu_en_eff),
      .tcr_el1    (tcr_eff),
      .ttbr0_el1  (ttbr0_eff),
      .ttbr1_el1  (ttbr1_eff),
      .mair_el1   (mair_eff),
      .access_el  (mmu_access_el),
      .pan        (mmu_access_pan),
      .ptw_req_valid (ptw_req_valid),
      .ptw_req       (ptw_req),
      .ptw_req_ready (ptw_req_ready),
      .ptw_rsp_valid (ptw_rsp_valid),
      .ptw_rsp       (ptw_rsp),
      .ptw_rsp_ready (ptw_rsp_ready),
      .tlb_invalidate(tlb_invalidate),
      .abort         (mmu_abort)
  );

  // ---- P5a 数据翻译请求与结果 ----
  // 数据翻译请求（优先于取指；M2-4b 含 IC IVAU 维护 VA）
  wire d_atomic128 = d.is_atomic && d.is_pair && (d.mem_size == 2'd3);
  wire d_neon128 = d.neon_valid && d.is_pair && (d.mem_size == 2'd3);
  wire d_mem128 = d_atomic128 || d_neon128;
  wire trans_done_for_ifid = trans_done_flag && (trans_done_pc_r == ifid_pc);
  // A fetch translation may complete on the same edge that a data
  // instruction is waiting in IF/ID. `data_req_valid` is intentionally low
  // while mmu_done is high, so use an instruction-bound predicate for both
  // pipeline stall and FIFO pop; otherwise the data op could be dropped or
  // captured with an uninitialised PA.
  logic data_wait_for_translation;
  assign data_wait_for_translation = ifid_valid && d.valid && mmu_en &&
      !d.exc && (d.is_load || d.is_store) && !trans_done_for_ifid;
  logic data_address_hazard;
  // A page walk latches the effective VA before the memory op enters EX/MEM.
  // Do not launch it from the decode forwarding view while an address source
  // is still being resolved: otherwise `trans_done_pc_r` can mark a stale VA
  // translation complete, and the later load reuses that stale PA after the
  // producer reaches EX/MEM. This is observable in Linux printk's
  // UMULL-indexed descriptor load.
  assign data_address_hazard = load_use || ex_id_gpr_hazard ||
                               ex_id_sp_hazard;
  assign maint_va_pending = (maint_state == MS_TRANSLATE);
  assign data_req_valid = ifid_valid && d.valid && mmu_en &&
                          !d.exc &&
                          ((d.is_load || d.is_store) || maint_va_pending) &&
                          !data_address_hazard &&
                           ((!trans_done_for_ifid && !atomic128_second_needed) ||
                           (atomic128_second_needed && !data_trans_active)) &&
                          !data_trans_active &&
                          !mmu_done && !dabt_pending &&
                          !fetch_stale_drain && !frontend_kill && !irq_taken;
  // 取指翻译请求（MMU on 且取指空闲时；sys_hold 期间也允许，供
  // ID 系统指令的 next_pc 翻译判定）
  assign fetch_req_valid = mmu_en_eff && !fetch_pending && !fetch_got_data &&
                           !fetch_trans_busy && !fetch_translated &&
                           !fetch_faulted && !mem_busy && !flush_id &&
                           !maint_imem_rsp_pending &&
                           !data_trans_active && !sys_commit &&
                           !fetch_merge_wb && !wfi_idle &&
                           !frontend_kill && !irq_taken &&
                           !fetch_stale_drain &&
                           !fetch_control_fence &&
                           (!fetch_fifo_active ||
                            (!fetch_fault_pending && fetch_fifo_space));
  assign mmu_req_valid = data_req_valid || fetch_req_valid;
  // 请求类型以 data_req_valid（而非 d.is_load/d.is_store）为准：数据
  // 翻译完成后 load/store 仍停留在 ID，此刻若取指翻译先发出，不能把
  // 取指请求误标为数据翻译（P5a 遗留 bug：会按 d.mem_addr 取 VA）。
  // maint_va_pending（IC IVAU 维护 VA）也是数据侧翻译。
  assign mmu_req_va = data_req_valid
                      ? (maint_va_pending ? d.maint_va :
                         (atomic128_second_needed
                          ? (d.mem_addr + 64'd8)
                          : d.mem_addr))
                      : if_pc;
  assign mmu_req_is_insn = data_req_valid ? 1'b0 : 1'b1;
  assign mmu_req_is_write = data_req_valid
                            ? (maint_va_pending ? d.maint_write : d.is_store)
                            : 1'b0;
  assign mmu_req_issue = mmu_req_valid && mmu_req_accept;
  // 只有数据侧翻译请求会占住执行/提交流水线；取指翻译与当前
  // ID/EX 指令独立，不能用同一个 issue 脉冲把普通指令永久插泡。
  logic data_mmu_issue;
  assign data_mmu_issue = data_req_valid && mmu_req_issue;
  assign fetch_req_accept = fetch_req_valid && mmu_req_accept &&
                            !data_req_valid;
  assign exc_vector_core = vbar_el1 +
      (el ? (sp_sel ? 64'h200 : 64'h000) : 64'h400);
  // P6：IRQ 向量（EL1h=+0x280、EL1t=+0x80、EL0=+0x480）
  logic [63:0] irq_vector_core;
  assign irq_vector_core = vbar_el1 +
      (el ? (sp_sel ? 64'h280 : 64'h080) : 64'h480);
  // IRQ 在指令边界取走：未屏蔽（DAIF.I=0、ALLINT=0）且当前提交不是同步异常。
  // FEAT_NMI 的 ALLINT 是独立于 DAIF 的总屏蔽位，必须纳入普通、WFI
  // 和系统指令提交后的 pending 判定。QEMU 仅在 SCTLR.NMI=1 时让
  // ALLINT 实际屏蔽 IRQ；SPSR/PSTATE 位本身仍按 FEAT_NMI 可见。
  logic irq_pending_raw;
  wire allint_irq_mask = pstate_allint && sctlr_el1[61];
  assign irq_pending_raw = irq && !daif[1] && !allint_irq_mask;
  // ID 级系统指令同样是架构指令边界。特别是 MSR DAIF/DAIFClr 解开
  // I 位时，QEMU 会在该指令退休后立刻采样 pending IRQ；不能等到下一条
  // 普通 WB 提交。sys_daif_after 是本条系统指令提交后的 PSTATE 视图，
  // 供 IRQ 判定及异常 SPSR 保存共用。
  always_comb begin
    sys_daif_after = daif;
    if (d.sys_op == SYS_MSR && d.sys_reg == SREG_DAIF) begin
      sys_daif_after = d.sys_wdata[9:6];
    end else if (d.sys_op == SYS_DAIF) begin
      sys_daif_after = d.sys_wdata[4]
                       ? (daif | d.sys_wdata[3:0])
                       : (daif & ~d.sys_wdata[3:0]);
    end
  end
  always_comb begin
    sys_allint_after = pstate_allint;
    if (d.sys_op == SYS_ALLINT) begin
      sys_allint_after = d.sys_wdata[0];
    end else if (d.sys_op == SYS_MSR && d.sys_reg == SREG_ALLINT) begin
      sys_allint_after = d.sys_wdata[13];
    end
  end
  // WFI/WFE 在任意 IRQ/事件上唤醒；WFIT/WFET 还可由 CNTVCT 到期唤醒。
  // 只有 I 位未屏蔽时才转入 IRQ 异常入口，超时/事件恢复不产生合成提交。
  assign wfi_timeout_wake = wfi_idle && wfi_timeout_valid &&
                            (timer_count >= wfi_timeout_r);
  assign wfi_wake = wfi_idle &&
                    (irq || event_reg || wfi_timeout_wake ||
                     difftest_wait_release || difftest_wait_release_pending);
  assign wfi_irq_take = wfi_idle && irq_pending_raw;
  // IRQ 取走：普通 WB 提交边界（排除 DABT/取指合并提交，二者优先）
  logic irq_taken;
  // A younger write request is an irreversible architectural side effect:
  // defer ordinary IRQ until the request/transaction reaches its exactly-once
  // commit boundary.  Read responses, by contrast, may be drained and
  // discarded by the IRQ squash.  The mul/div engine is fenced until its done
  // pulse before ordinary IRQ can take the boundary; recovery/exception
  // boundaries use muldiv_kill only for a younger uncommitted ID/EX request.
  logic irq_irrevocable_pending;
  assign irq_irrevocable_pending =
      (exmem_valid &&
       ((dmem_req_issued && dmem_req.we) ||
        (dmem_done &&
         ((exmem_is_store && !exmem_is_atomic) ||
          (exmem_is_atomic && exmem_atomic_store))) ||
        (exmem_is_store && !exmem_is_atomic && exmem_is_pair && pair_part) ||
        (exmem_is_atomic && is_atomic128_pair(exmem_atomic_op) &&
         atomic_phase == 2'd3))) ||
      (maint_state != MS_IDLE && sys_maint_at_id) ||
      (idex_valid && is_muldiv && !muldiv_done);
  assign irq_taken = irq_pending_raw && commit_fire &&
                     !memwb_exc && !fetch_merge_wb &&
                     !irq_irrevocable_pending;
  // RNDR/RNDRRS MRS（S3_3_C2_C4_0/1）提交时置 NZCV=0000（QEMU
  // rndr_readfn 成功语义）；编码唯一，无需在 MEM/WB 携带 sys_reg。
  wire rndr_nzcv_commit = (memwb_insn & 32'hffffffe0) inside
                          {32'hd53b2400, 32'hd53b2420};
  assign sys_exc = d.exc || dabt_pending || sys_fetch_merge;
  assign sys_exc_code = sys_fetch_merge ? sys_merge_code
      : dabt_pending ? (el ? EXC_DABORT_SAME_EL : EXC_DABORT)
      : d.exc_code;
  assign sys_exc_elr = sys_fetch_merge ? sys_merge_elr
      : dabt_pending ? ifid_pc : d.exc_elr;
  // ERET 的 PSTATE/异常目标有单独的恢复规则，P6 当前仍由其后普通边界
  // 接收 IRQ；其余 ID 级系统指令按提交后 DAIF 接收异步 IRQ。
  assign sys_irq_taken = sys_commit && !sys_exc &&
                         (d.sys_op != SYS_ERET) && irq &&
                         !sys_daif_after[1] &&
                         !(sys_allint_after && sctlr_el1[61]);
  assign sys_next_pc = sys_irq_taken ? irq_vector_core
      : (sys_exc || sys_fetch_merge)
        ? (d.sys_op == SYS_ERET ? eret_exc_vector : exc_vector_core)
        : (!mmu_en && d.sys_op == SYS_ERET &&
           (elr_el1 < SRAM_BASE || elr_el1 >= SRAM_TOP))
          ? eret_exc_vector
          : d.next_pc;
  // R1：完整 ESR / FAR。FSC：Translation=0x04+level、AF=0x08+level、
  // Permission=0x0C+level、AddressSize=level、外部中止=0x10；IL 恒 1。
  function automatic logic [31:0] abort_esr(input logic [5:0] ec,
                                            input logic        wnr,
                                            input logic [5:0]  fsc);
    abort_esr = ({ec, 1'b1, 18'd0, wnr, fsc});
  endfunction
  logic [31:0] sys_exc_esr;
  logic [63:0] sys_exc_far;
  assign sys_exc_esr =
      sys_fetch_merge && (sys_merge_code == EXC_PC_ALIGN)
          ? 32'h8a00_0000 :
      sys_fetch_merge ? abort_esr(sys_merge_code[5:0], 1'b0, fetch_fsc_r) :
      dabt_pending ? abort_esr(el ? EXC_DABORT_SAME_EL[5:0] : EXC_DABORT[5:0],
                               d_atomic128 ? 1'b0 : d.is_store, trans_fsc_r) :
      d.neon_align ?
          abort_esr(el ? EXC_DABORT_SAME_EL[5:0]
                    : EXC_DABORT[5:0], d.is_store, 6'h21) :
      d.neon_range ?
          abort_esr(el ? EXC_DABORT_SAME_EL[5:0]
                    : EXC_DABORT[5:0], d.is_store, 6'h10) :
      d.atomic_align ?
          abort_esr(el ? EXC_DABORT_SAME_EL[5:0]
                    : EXC_DABORT[5:0], 1'b0, 6'h21) :
      d.atomic_range ?
          abort_esr(el ? EXC_DABORT_SAME_EL[5:0]
                    : EXC_DABORT[5:0], 1'b0, 6'h10) :
      (d.exc_code == EXC_SVC) ? (32'h5600_0000 |
                                 {16'd0, ifid_insn[20:5]}) :
      (d.exc_code == EXC_FP_ACCESS) ? d.exc_esr :
      (d.exc_code == EXC_SYSREG_TRAP) ? d.exc_esr :
      (d.exc_code inside {EXC_DABORT, EXC_DABORT_SAME_EL})
          // mmu 关闭：地址超 48 位（非 canonical）-> address-size 0，
          // 否则未映射区 -> 同步外部中止 0x10
          ? abort_esr(d.exc_code[5:0], d.is_store,
                      (d.mem_addr[63:48] != 0) ? 6'd0 : 6'h10) :
      (d.exc_code inside {EXC_IABORT, EXC_IABORT_SAME_EL})
          ? abort_esr(d.exc_code[5:0], 1'b0,
                      (d.exc_elr[63:48] != 0) ? 6'd0 : 6'h10) :
      32'h0200_0000;   // UDEF：EC=0、IL=1、ISS=0
  assign sys_exc_far =
      sys_fetch_merge ? fetch_pc_r :
      dabt_pending ? d.mem_addr :
      (d.exc_code inside {EXC_DABORT, EXC_DABORT_SAME_EL}) ? d.mem_addr :
      (d.exc_code inside {EXC_IABORT, EXC_IABORT_SAME_EL}) ? d.exc_elr :
      far_el1;         // UDEF/SVC：FAR 不更新

  // ---- 取指 fault 合并 ----
  assign fetch_walk = fetch_trans_busy && mmu_walking;
  // A data-abort response is architecturally older than any pending fetch
  // fault. It must take the memwb exception path, never be reclassified as
  // a fetch merge (especially important for a partially attempted Q access).
  assign fetch_merge_wb = commit_fire && !memwb_exc && fetch_faulted &&
                          (fetch_pc_r == memwb_next_pc);
  // SCTLR.M=0 is a deliberate regime transition, not an instruction-abort
  // merge.  Even if the old MMU context has already placed a matching fault
  // in the single fetch context/FIFO, the MSR itself must commit normally,
  // clear that old frontend state, and let the next fetch use MMU-off rules.
  logic sys_fetch_merge_allowed;
  assign sys_fetch_merge_allowed =
      !(d.sys_op == SYS_MSR && d.sys_reg == SREG_SCTLR_EL1 &&
        !d.sys_wdata[0]);
  // A pending request or a completed VA->PA translation is not an outcome:
  // the following IMEM access can still return an instruction abort.  The
  // ID-level system fence may open only after a current-epoch FIFO entry for
  // d.next_pc exists, or after the single fetch context has recorded a
  // matching fault.  Do not make this depend on commit/pop/space/stall
  // signals; those are consumers of the settled outcome and would create a
  // protocol loop.
  assign fetch_next_settled = fetch_fifo_active
      ? (!sys_fetch_context_refresh_needed &&
         (fetch_fifo_has_target ||
          (fetch_faulted && fetch_ctx_epoch == fetch_epoch &&
           fetch_pc_r == d.next_pc)))
      : (((fetch_pending || fetch_translated) &&
          fetch_pc_r == d.next_pc) ||
         (fetch_faulted && fetch_pc_r == d.next_pc));
  assign sys_fetch_merge = sys_commit && fetch_faulted &&
                           (fetch_pc_r == d.next_pc) && !d.exc &&
                           sys_fetch_merge_allowed;
  assign sys_fetch_context_msr_merge = sys_fetch_merge &&
      (d.sys_op == SYS_MSR) &&
      (d.sys_reg inside {SREG_SCTLR_EL1, SREG_TCR_EL1,
                         SREG_TTBR0_EL1, SREG_TTBR1_EL1,
                         SREG_MAIR_EL1});
  assign sys_fetch_redirect = sys_at_id && !sys_commit && mmu_en_eff &&
                              (d.exc || d.sys_op == SYS_ERET ||
                               d.sys_op == SYS_BARRIER ||
                               d.sys_op == SYS_MAINT ||
                               d.sys_op == SYS_MSR ||
                               d.sys_op == SYS_ALLINT ||
                               d.sys_op inside {SYS_WFI, SYS_WFE,
                                                 SYS_SEV, SYS_SEVL,
                                                 SYS_WFIT, SYS_WFET}) &&
                              !memwb_fetch_wait &&
                              !fetch_trans_busy &&
                              (sys_fetch_context_refresh_needed ||
                               if_pc != d.next_pc ||
                               (fetch_fifo_active && fetch_fifo_count != 2'd0) ||
                               (fetch_fifo_active &&
                                (fetch_pending || fetch_translated ||
                                 fetch_faulted) &&
                                 fetch_pc_r != d.next_pc)) &&
                              !(fetch_pc_r == d.next_pc &&
                                (fetch_pending || fetch_translated ||
                                 fetch_faulted) &&
                                !sys_fetch_context_refresh_needed);
  assign sys_merge_code =
      (d.sys_op == SYS_ERET && elr_el1[1:0] != 2'b00)
          ? EXC_PC_ALIGN
          : (d.sys_op == SYS_ERET)
            ? (spsr_el1[2] ? EXC_IABORT_SAME_EL : EXC_IABORT)
            : (el ? EXC_IABORT_SAME_EL : EXC_IABORT);
  assign sys_merge_elr = fetch_pc_r;

  lcvex_alu alu (
      .op        (idex_d.alu_op),
      .a         (idex_d.operand_a),
      .b         (idex_d.operand_b),
      .c         (idex_d.operand_c),
      .use_shift (idex_d.use_shift),
      .shift_type(idex_d.shift_type),
      .shift_amt (idex_d.shift_amt),
      .inv_b     (idex_d.inv_b),
      .ccmp_nzcv_else (idex_d.ccmp_nzcv),
      .ccmp_taken     (idex_d.ccmp_taken),
      .cin            (nzcv_alu[1]),
      .is_32     (idex_d.is_32),
      .result    (alu_result),
      .flag_n    (flag_n),
      .flag_z    (flag_z),
      .flag_c    (flag_c),
      .flag_v    (flag_v)
  );

  // ALU 操作码 -> muldiv 内部 op（0=MUL 1=UDIV 2=SDIV 3..8=MADD 族，
  // 9=UMULH，10=SMULH；两者共用 ALU_UMULH 编码，按 bit23 区分）。
  logic [3:0] muldiv_op;
  assign muldiv_op =
      (idex_d.alu_op == ALU_MUL)    ? 4'd0 :
      (idex_d.alu_op == ALU_UDIV)   ? 4'd1 :
      (idex_d.alu_op == ALU_SDIV)   ? 4'd2 :
      (idex_d.alu_op == ALU_MADD)   ? 4'd3 :
      (idex_d.alu_op == ALU_MSUB)   ? 4'd4 :
      (idex_d.alu_op == ALU_SMADDL) ? 4'd5 :
      (idex_d.alu_op == ALU_SMSUBL) ? 4'd6 :
      (idex_d.alu_op == ALU_UMADDL) ? 4'd7 :
      (idex_d.alu_op == ALU_UMSUBL) ? 4'd8 :
      (idex_insn[23] ? 4'd9 : 4'd10);

  lcvex_muldiv muldiv (
      .clk    (clk),
      .rst_n  (rst_n),
      .start  (muldiv_start),
      .kill   (muldiv_kill),
      .op     (muldiv_op),
      .is_32  (idex_d.is_32),
      .a      (idex_d.operand_a),
      .b      (idex_d.operand_b),
      .acc    (idex_d.operand_c),
      .busy   (muldiv_busy),
      .done   (muldiv_done),
      .result (muldiv_result)
  );

  assign is_muldiv = idex_valid &&
                     (idex_d.alu_op inside {ALU_MUL, ALU_UDIV, ALU_SDIV,
                                            ALU_MADD, ALU_MSUB, ALU_SMADDL,
                                            ALU_SMSUBL, ALU_UMADDL,
                                            ALU_UMSUBL, ALU_UMULH});
  assign muldiv_start = is_muldiv && !muldiv_busy && !muldiv_done;
  // 仅取消已有精确恢复/异常边界下的年轻、尚未提交 ID/EX 请求。
  // 普通 branch flush 只清年轻 IF/ID，不能杀当前更老的 muldiv；
  // irq_taken 由 T-051 的不可回滚/完成 fence 独立处理，不能照抄到这里。
  assign muldiv_kill = idex_valid && is_muldiv &&
                       (fetch_merge_wb || wb_exc_commit ||
                        difftest_restore_sys_valid);
  assign fp_div_is_div = idex_valid && idex_d.fp_valid &&
                         (idex_d.fp_op == FP_OP_DIV);

  // FP-P1：只有非访存 scalar/NEON FP 算术/比较/转换进入 transaction。
  // 现有 FP/NEON load/store 继续走既有数据内存路径，不占用 FP owner。
  assign fp_tx_candidate =
      idex_valid &&
      (((idex_d.fp_valid && !idex_d.is_load && !idex_d.is_store)) ||
       idex_d.neon_fp_valid);
  assign fp_req_valid = fp_tx_candidate && !fp_tx_issued;
  assign fp_tx_active = fp_tx_candidate || fp_tx_issued || fp_tx_busy ||
                        fp_rsp_valid;

  always_comb begin
    fp_req = '0;
    fp_req.valid         = fp_tx_candidate;
    fp_req.tag           = idex_token_seq;
    fp_req.pc            = idex_pc;
    fp_req.insn          = idex_insn;
    fp_req.is_double     = idex_d.neon_fp_valid
                           ? idex_d.neon_fp_is_double
                           : idex_d.fp_is_double;
    fp_req.is_half       = idex_d.neon_fp_valid
                           ? idex_d.neon_fp_is_half
                           : idex_d.fp_is_half;
    fp_req.fcvt_dst_half = idex_d.fp_fcvt_dst_half;
    fp_req.rint_mode     = idex_d.neon_fp_valid
                           ? idex_d.neon_fp_rint_mode
                           : idex_d.fp_rint_mode;
    fp_req.quad          = idex_d.neon_fp_quad;
    fp_req.cmp_zero      = idex_d.fp_cmp_zero;
    fp_req.signal_all_nans = idex_d.fp_signal_all_nans;
    fp_req.operand_a     = idex_d.neon_fp_valid
                           ? idex_d.neon_operand_a
                           : idex_d.fp_operand_a;
    fp_req.operand_b     = idex_d.neon_fp_valid
                           ? idex_d.neon_operand_b
                           : idex_d.fp_operand_b;
    fp_req.operand_c     = idex_d.neon_fp_valid
                           ? idex_d.neon_fp_operand_c
                           : idex_d.fp_operand_c;
    fp_req.conv_to_int   = idex_d.fp_conv_to_int;
    fp_req.conv_is_32    = idex_d.fp_conv_is_32;
    fp_req.conv_shift    = idex_d.fp_conv_shift;
    fp_req.conv_int      = idex_d.fp_conv_int;
    fp_req.fpcr          = idex_d.fpcr;
    if (idex_d.neon_fp_valid) begin
      fp_req.kind    = FP_EXEC_KIND_NEON;
      fp_req.neon_op = idex_d.neon_fp_op;
      fp_req.v_we    = idex_d.neon_wb_we;
      fp_req.v_rd    = idex_d.neon_rd;
      fp_req.fpsr_we = 1'b1;
    end else begin
      fp_req.kind      = FP_EXEC_KIND_SCALAR;
      fp_req.scalar_op = idex_d.fp_op;
      fp_req.v_we      = idex_d.fp_wb_we;
      fp_req.v_rd      = idex_d.fp_rd;
      fp_req.gpr_we    = idex_d.fp_conv_to_int && idex_d.wb_we;
      fp_req.gpr_rd    = idex_d.wb_rd;
      fp_req.nzcv_we   = (idex_d.fp_op == FP_OP_CMP);
      fp_req.fpsr_we   = (idex_d.fp_op != FP_OP_MOV);
    end
  end

  // kill 覆盖所有会取消年轻 FP transaction 的 core 边界；reset 由 wrapper
  // 自身异步复位处理。
  // 注意：普通 taken-branch flush_id 只冲刷年轻 IF/ID，不能取消更老的
  // ID/EX/EXMEM FP transaction，因此不纳入 fp_tx_kill。
  // `sys_commit` is intentionally absent.  It is only asserted after the
  // in-order drain has made ID/EX, EX/MEM and MEM/WB empty; the invariant
  // below proves that no FP owner/response can coexist at that boundary.
  // Keeping system commit out of this handshake removes its decode/control
  // cone from the FP wrapper TX_DONE D input.  Precise exception/IRQ/restore
  // boundaries remain real kills because they can cancel a younger FP
  // transaction before the drain boundary is reached.
  assign fp_tx_kill =
      fetch_merge_wb || wb_exc_commit ||
      irq_taken || wfi_irq_take || wfi_wake ||
      difftest_restore_sys_valid;
  // A younger IF/ID data access may start translation while an older FP
  // transaction is still running in ID/EX.  EX/MEM's sequential capture is
  // frozen by each of these translation states, so they must block response
  // acceptance as well.  Keep this term local to the FP response handshake;
  // feeding data_mmu_issue into exmem_can_accept would close the documented
  // frontend/MMU/flush combinational loop.
  assign fp_rsp_accept_blocked = data_trans_active ||
                                 atomic128_second_needed ||
                                 data_mmu_issue;
  // The wrapper-facing handshake is deliberately a separate boundary: a raw
  // TX_DONE response is accepted whenever the one-entry hold is empty.  If
  // EX/MEM cannot accept it on this edge, the hold register captures the
  // payload and presents it below until the core-side handshake completes.
  // Consequently memwb_fetch_wait/stall_wb and all core-side kill logic stay
  // off the wrapper TX_DONE D input.  Kill has priority in both the wrapper
  // and the hold register, so a raw response accepted on a kill edge is
  // discarded atomically and cannot become an architectural response.
  assign fp_exec_rsp_ready = A64_FP_SIMD && !fp_rsp_hold_valid;
  // Core-side response consumption still uses the exact old EX/MEM
  // acceptance predicate.  This preserves ready/valid, held-response,
  // data-MMU overlap and precise kill behavior after the elastic boundary.
  assign fp_rsp_ready = fp_rsp_valid && exmem_can_accept &&
                        !fp_rsp_accept_blocked && !fp_tx_kill;
  assign fp_consume    = fp_rsp_valid && fp_rsp_ready;
  assign ex_busy = (is_muldiv && !muldiv_done) ||
                   fp_tx_candidate || fp_tx_issued || fp_rsp_valid;

  // Wrapper-to-core response boundary.  Directly consumable responses bypass
  // the register, retaining the pre-cut response latency.  A response seen
  // while EX/MEM/WB or data translation is blocked is captured exactly once;
  // its payload is retained until fp_consume.  The payload is intentionally
  // not cleared on consume because fp_rsp_hold_valid already removes it from
  // the valid interface, avoiding a ready-to-payload D fanout.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fp_rsp_hold_valid <= 1'b0;
      fp_rsp_hold       <= '0;
    end else if (fp_tx_kill) begin
      fp_rsp_hold_valid <= 1'b0;
      fp_rsp_hold       <= '0;
    end else if (fp_exec_rsp_valid && fp_exec_rsp_ready) begin
      if (!fp_rsp_ready) begin
        fp_rsp_hold_valid <= 1'b1;
        fp_rsp_hold       <= fp_exec_rsp;
      end
    end else if (fp_rsp_hold_valid && fp_consume) begin
      fp_rsp_hold_valid <= 1'b0;
    end
  end

  // ---- P6 Generic Timer：MRS 读值在 EX 计算 ----
  // QEMU -icount shift=0 下 CNTPCT = 已执行指令数；本指令（N）读值 =
  // 已提交数 + 尚未提交的更老指令数 + 1。F1a 允许更老的指令停留在
  // EX/MEM 或 MEM/WB，cntpct_r 因此尚未包含它们；若只用 cntpct_r+1，
  // 紧邻的后一条 timer/RNDR MRS 会读到 off-by-one 的旧值。执行级可见
  // 计数把这部分在途更老指令一并计入，同时保证 EX 前递值也正确。
  logic [63:0] timer_count;
  assign timer_count = TIMER_REALTIME ? cntpct_r : cntpct_r + 64'd1;
  logic [63:0] timer_ex_count;
  assign timer_ex_count = TIMER_REALTIME ? cntpct_r :
                          cntpct_r + 64'd1 +
                          (exmem_valid ? 64'd1 : 64'd0) +
                          ((memwb_valid && !memwb_committed_r)
                           ? 64'd1 : 64'd0);
  logic [31:0] tval_trunc_p;
  logic [31:0] tval_trunc_v;
  always_comb begin
    // QEMU do_tval_read：返回 (uint32_t)(cval - count)
    tval_trunc_p = 32'(cntp_cval_r - timer_ex_count);
    tval_trunc_v = 32'(cntv_cval_r - timer_ex_count);
  end
  logic [63:0] timer_read;
  always_comb begin
    unique case (idex_d.sys_reg)
      SREG_CNTPCT, SREG_CNTVCT, SREG_CNTPCTSS, SREG_CNTVCTSS:
        timer_read = timer_ex_count;
      SREG_CNTP_TVAL:
        timer_read = {32'd0, tval_trunc_p};
      SREG_CNTP_CTL:
        timer_read = {61'd0,
                      cntp_ctl_r[0] ? (timer_ex_count >= cntp_cval_r) : 1'b0,
                      cntp_ctl_r[1], cntp_ctl_r[0]};
      SREG_CNTP_CVAL:
        timer_read = cntp_cval_r;
      SREG_CNTV_TVAL:
        timer_read = {32'd0, tval_trunc_v};
      SREG_CNTV_CTL:
        timer_read = {61'd0,
                      cntv_ctl_r[0] ? (timer_ex_count >= cntv_cval_r) : 1'b0,
                      cntv_ctl_r[1], cntv_ctl_r[0]};
      SREG_CNTV_CVAL:
        timer_read = cntv_cval_r;
      // RNDR/RNDRRS：difftest 确定性镜像 = 当前指令可见计数（QEMU
      // rndr_readfn 在 lcvex 模式下返回 gt_get_countervalue）
      SREG_RNDR, SREG_RNDRRS:
        timer_read = timer_ex_count;
      default: timer_read = 64'd0;
    endcase
  end

  // ---- EX 写回值 ----
  assign ex_wdata = is_muldiv ? muldiv_result
                  : (idex_d.sys_op == SYS_MRS &&
                     idex_d.sys_reg inside {SREG_CNTPCT, SREG_CNTVCT,
                                            SREG_CNTPCTSS, SREG_CNTVCTSS,
                                            SREG_CNTP_TVAL, SREG_CNTP_CTL,
                                            SREG_CNTP_CVAL, SREG_CNTV_TVAL,
                                            SREG_CNTV_CTL, SREG_CNTV_CVAL,
                                            SREG_RNDR, SREG_RNDRRS})
                    ? timer_read
                    : (idex_d.fp_valid && idex_d.fp_conv_to_int)
                      ? fp_rsp.gpr_data
                    : (idex_d.wb_sel == 2'd1)
                      ? idex_d.wb_extra : alu_result;
  assign ex_sp_wdata = alu_result;
  assign ex_nzcv = (idex_d.fp_valid && idex_d.fp_op == FP_OP_CMP)
                   ? fp_rsp.nzcv : {flag_n, flag_z, flag_c, flag_v};

  // P6：定时器中断输出（供 GIC；非差分提交状态）
  assign timer_phys_irq = cntp_ctl_r[0] && !cntp_ctl_r[1] &&
                          (timer_count >= cntp_cval_r);
  assign timer_virt_irq = cntv_ctl_r[0] && !cntv_ctl_r[1] &&
                          (timer_count >= cntv_cval_r);

  // ---- 前递视图（ID 周期）----
  // EX 级 load 不参与前递（load-use 时 stall，等数据到 WB）
  always_comb begin
    for (int i = 0; i < 31; i++) begin
      gprv[i] = gpr[i];
      if (idex_valid && fp_tx_candidate && fp_rsp_valid &&
          fp_rsp.gpr_we && fp_rsp.gpr_rd == i[4:0]) begin
        gprv[i] = fp_rsp.gpr_data;
      end else if (exmem_valid && exmem_wb3_we &&
                   exmem_wb3_rd == i[4:0]) begin
        // pre/post 基址更新在 EX/MEM 即可前递
        gprv[i] = exmem_wb3_extra;
      end else if (exmem_valid && exmem_wb_we && !exmem_is_load &&
                   !exmem_is_stxr &&
                   exmem_wb_rd == i[4:0]) begin
        // Forward the youngest EX/MEM producer before any older MEM/WB
        // writeback (including wb3).  A younger ALU write to Rn may coexist
        // with an older indexed load's base update; selecting MEM/WB wb3
        // first would make decode use the stale base and compute both the
        // effective address and wb3_extra from it.
        gprv[i] = exmem_wdata;
      end else if (memwb_valid && !memwb_committed_r && memwb_wb3_we &&
                   memwb_wb3_rd == i[4:0]) begin
        gprv[i] = memwb_wb3_extra;
      end else if (memwb_valid && !memwb_committed_r && memwb_wb_we &&
                   memwb_wb_rd == i[4:0]) begin
        // 已提交的 WB 幽灵条目（翻译冻结期保持）不参与前递：load 的
        // wb_wdata 依赖实时 mem_rdata，保持期间端口已复用，可能变成
        // 取指数据；架构状态在提交时已更新，直接读 gpr 即可。
        gprv[i] = wb_wdata;
      end else if (memwb_valid && !memwb_committed_r && memwb_wb2_we &&
                   memwb_wb2_rd == i[4:0]) begin
        // LDP 第二写回（load 数据已注册）
        gprv[i] = wb2_wdata;
      end
    end
  end

  // T-20260902-036：去掉 ID/EX->ID 的 SP/NZCV 组合前递。ID/EX 的
  // ALU/FP 结果在下一拍进入 EX/MEM 寄存器后，由 EX/MEM->ID 的已寄存
  // 前递继续提供正确值；依赖方由 ex_id_sp_hazard/ex_id_flags_hazard
  // 停顿，避免在 decode 读到旧 SP/NZCV。
  assign spv = (exmem_valid && exmem_sp_we)       ? exmem_sp_wdata :
               (memwb_valid && !memwb_committed_r && memwb_sp_we)
                                                 ? memwb_sp_wdata : sp;

  assign nzcvv = (exmem_valid && exmem_nzcv_we)   ? exmem_nzcv :
                 (memwb_valid && !memwb_committed_r && memwb_nzcv_we)
                                                 ? memwb_nzcv : nzcv;

  // ADC/SBC/NGC 的进位输入必须使用前一指令产生的 NZCV，而不是只等
  // 已提交的 nzcv。F1a 允许更深的流水线，前一条 set-flags 指令可能仍在
  // EX/MEM 或 MEM/WB（尚未提交）；用 exmem/memwb 的前递标志才能得到
  // 正确的 C 输入。这里刻意排除当前 ID/EX 自身的 set_flags，避免
  // ADCS/SBCS 把自己的输出进位反灌回输入。
  logic [3:0] nzcv_alu;
  assign nzcv_alu = (exmem_valid && exmem_nzcv_we)   ? exmem_nzcv :
                    (memwb_valid && !memwb_committed_r && memwb_nzcv_we)
                                                  ? memwb_nzcv : nzcv;

  // ---- hazard 检测（ID 周期）----
  function automatic logic id_reads(input logic [4:0] r);
    id_reads = (d.rs1_en && d.rs1 == r) ||
               (d.rs2_en && d.rs2 == r) ||
               (d.rs3_en && d.rs3 == r) ||
               (d.rs4_en && d.rs4 == r) ||
               (d.rs5_en && d.rs5 == r);
  endfunction

  function automatic logic fp_id_reads(input logic [4:0] r);
    fp_id_reads = (d.fp_rn_en && d.fp_rn == r) ||
                  (d.fp_rm_en && d.fp_rm == r) ||
                  (d.fp_ra_en && d.fp_ra == r);
  endfunction

  function automatic logic neon_id_reads(input logic [4:0] r);
    neon_id_reads = (d.neon_rn_en && d.neon_rn == r) ||
                    (d.neon_rm_en && d.neon_rm == r) ||
                    (d.neon_fp_ra_en && d.neon_rd == r);
  endfunction

  // Scalar FP and Advanced SIMD share the V register file.  Keep the reader
  // test in one helper so a scalar/NEON producer cannot bypass the cut just
  // because its consumer is in the other decode family.  In particular,
  // neon_fp_ra_en marks FMLA/FMLS, whose addend is Vd (operand_c).
  function automatic logic v_id_reads(input logic [4:0] r);
    v_id_reads = fp_id_reads(r) || neon_id_reads(r);
  endfunction

  // LDP 双写回：任一目标（rt/rt2）被后续读取即 load-use
  function automatic logic pair_reads(input logic [4:0] r,
                                      input logic [4:0] r2,
                                      input logic we, input logic we2);
    pair_reads = (we && r != 5'd31 && id_reads(r)) ||
                 (we2 && r2 != 5'd31 && id_reads(r2));
  endfunction
  assign load_use =
      // STXR 的状态写回（rs）与 load 一样“晚到”：MEM 阶段才决定结果，
      // EX/MEM 的 ex_wdata 是占位 0，读者必须等 WB 提交后（load-use
      // 停顿 + WB 前递）再译码，否则拿到假值 0。
      (idex_valid && (idex_d.is_load || idex_d.is_stxr) &&
       pair_reads(idex_d.wb_rd, idex_d.wb2_rd,
                  idex_d.wb_we, idex_d.wb2_we)) ||
      (exmem_valid && (exmem_is_load || exmem_is_stxr) &&
       pair_reads(exmem_wb_rd, exmem_wb2_rd,
                  exmem_wb_we, exmem_wb2_we));
  // T-20260902-032：去掉 ID/EX 的普通 GPR ALU 写回组合前递。EX 级 ALU
  // 结果 -> ID 前递 -> 译码地址/异常/取指控制 -> I-L1 响应寄存器 ENA
  // 是 sys_clk_50 setup 最差路径。这里改为让依赖该 ID/EX 结果的当前 IF/ID
  // 指令停顿一拍；下一拍结果进入 EX/MEM 寄存器后再由 EX/MEM->ID 前递，
  // 从而把该组合长链打断为“ALU -> EX/MEM 寄存器”和“EX/MEM 寄存器 ->
  // 译码/取指控制”两段。T-20260902-036 把同一处理扩展到 ID/EX 的
  // pre/post 基址更新（wb3）以及 SP/NZCV 组合前递。
  logic ex_id_gpr_hazard;
  assign ex_id_gpr_hazard =
      ifid_valid && d.valid && idex_valid &&
      (((idex_d.wb_we && !idex_d.is_load && !idex_d.is_stxr &&
         idex_d.wb_rd != 5'd31 && id_reads(idex_d.wb_rd)) ||
        (idex_d.wb3_we && idex_d.wb3_rd != 5'd31 &&
         id_reads(idex_d.wb3_rd))));
  // ID/EX 的 SP/NZCV 结果不再组合前递到 ID；只在当前 IF/ID 有效且 decode
  // 明确消费这些前递视图时停顿，避免读到旧值，也避免空气泡误停顿。
  logic ex_id_sp_hazard;
  assign ex_id_sp_hazard =
      ifid_valid && d.valid && idex_valid && idex_d.sp_we && d.uses_sp;
  logic ex_id_flags_hazard;
  assign ex_id_flags_hazard =
      ifid_valid && d.valid && idex_valid && idex_d.set_flags && d.uses_nzcv;
  // T-20260902-048：切断 ID/EX 与 EX/MEM 的同拍 V 寄存器前递到 decode。
  // 结果只能从 MEM/WB（已寄存）或已更新的架构 FP state 观察；依赖指令
  // 在两个较早级分别停顿一拍，避免向 ID/EX 的 128-bit operand_c 形成
  // exmem_valid -> decode -> idex_d 组合长链。该判定同时覆盖标量 FP、
  // NEON 整数和 NEON FP，故 FMLA/FMLS 的 Vd addend 也不会读旧值。
  logic ex_id_v_hazard;
  assign ex_id_v_hazard =
      ifid_valid && d.valid && idex_valid &&
      (((idex_d.fp_valid && idex_d.fp_wb_we &&
         v_id_reads(idex_d.fp_rd))) ||
       (idex_d.neon_valid && idex_d.neon_wb_we &&
         v_id_reads(idex_d.neon_rd)));
  logic exmem_v_hazard;
  assign exmem_v_hazard =
      ifid_valid && d.valid && exmem_valid &&
      (((exmem_fp_valid && exmem_fp_wb_we &&
         v_id_reads(exmem_fp_rd))) ||
       (exmem_neon_valid && exmem_neon_wb_we &&
         v_id_reads(exmem_neon_rd)));
  assign fp_load_use =
      (idex_valid && idex_d.fp_valid && idex_d.fp_wb_we &&
       idex_d.is_load &&
       (fp_id_reads(idex_d.fp_rd) || neon_id_reads(idex_d.fp_rd))) ||
      (exmem_valid && exmem_fp_valid && exmem_fp_mem_load &&
       exmem_fp_wb_we &&
       (fp_id_reads(exmem_fp_rd) || neon_id_reads(exmem_fp_rd))) ||
      (idex_valid && idex_d.neon_valid && idex_d.neon_wb_we &&
       idex_d.neon_mem_load &&
       (fp_id_reads(idex_d.neon_rd) || neon_id_reads(idex_d.neon_rd))) ||
      (exmem_valid && exmem_neon_valid && exmem_neon_wb_we &&
       exmem_neon_mem_load &&
       (fp_id_reads(exmem_neon_rd) || neon_id_reads(exmem_neon_rd)));
  assign mem_busy = exmem_valid && (exmem_is_load || exmem_is_store);

  // 系统/异常指令：ERET、MSR、屏障、维护指令与异常（UDEF/SVC/IABT/DABT）
  // 在 ID 级提交；先等前方流水线（更老指令）全部排空，避免系统状态
  // 读写顺序错误。
  assign sys_at_id = ifid_valid &&
                     (d.exc || dabt_pending ||
                      (d.sys_op inside {SYS_ERET, SYS_MSR, SYS_BARRIER,
                                        SYS_MAINT, SYS_DAIF, SYS_SPSEL,
                                        SYS_DIT, SYS_WFI, SYS_WFE,
                                        SYS_SEV, SYS_SEVL, SYS_WFIT,
                                        SYS_WFET, SYS_SSBS, SYS_TCO,
                                        SYS_UAO, SYS_PAN, SYS_ALLINT}));
  assign sys_maint_at_id = ifid_valid && d.valid &&
                           (d.sys_op == SYS_MAINT);
  assign sys_commit_ready =
      (d.sys_op == SYS_MAINT)
          ? (maint_done && !maint_imem_rsp_pending &&
             (!mmu_en || fetch_next_settled))
          : (d.sys_op == SYS_MSR)
            ? ((!mmu_en && d.sys_reg != SREG_SCTLR_EL1) ||
               (d.sys_reg == SREG_SCTLR_EL1 && !d.sys_wdata[0]) ||
               fetch_next_settled)
          : (d.sys_op inside {SYS_WFI, SYS_WFE, SYS_SEV, SYS_SEVL,
                              SYS_WFIT, SYS_WFET})
            ? (!mmu_en || fetch_next_settled)
          : (d.exc || !mmu_en || fetch_next_settled);
  // ID system commits are the same architectural commit boundary as WB:
  // commit_ready must gate both the packet and every state update sourced
  // from sys_commit.  Without this term an MSR/trap could update state while
  // its commit packet was not consumable by the downstream checker.
  assign sys_commit = sys_at_id && !idex_valid && !exmem_valid &&
                      !memwb_valid && sys_commit_ready && commit_ready;
  assign sys_hold = sys_at_id && !sys_commit;
  // STXR：等待前方流水线（含在途 LDXR/CLREX/ERET 与未完成访存）全部
  // 排空后再进入 EX——此时监视器为最终提交状态，读比较结果稳定。
  assign excl_at_id = ifid_valid && d.valid && d.is_stxr;
  assign excl_drain_ok = !idex_valid && !exmem_valid && !memwb_valid &&
                         !data_trans_active && !fetch_walk &&
                         !data_mmu_issue && !dmem_pending;
  assign excl_hold = excl_at_id && !excl_drain_ok;
  assign wb_exc_commit = commit_fire && memwb_exc;
  // load-use / 系统指令排空 / 数据翻译：IF/ID 保持、ID/EX 插气泡
  // （flush 必须等前递；翻译请求当拍起冻结，避免未翻译指令进 EX）
  assign stall_id = load_use || fp_load_use || ex_id_gpr_hazard ||
                    ex_id_sp_hazard || ex_id_flags_hazard ||
                    ex_id_v_hazard || exmem_v_hazard ||
                    sys_hold || excl_hold ||
                    data_trans_active || atomic128_second_needed ||
                    data_mmu_issue || data_wait_for_translation || fetch_walk ||
                    fetch_stale_drain ||
                    (idex_valid && !exmem_can_adv) ||
                    (exmem_valid && !exmem_can_adv);
  // 乘除忙 / 页表遍历：全部级冻结（遍历独占 SRAM 端口）
  assign stall_if = stall_id || ex_busy || wfi_idle;
  // 分支 flush：系统指令（异常/ERET）不在此列，ID 级提交时统一重定向。
  // 必须等 EX/MEM 可接收分支才冲刷：若 EX/MEM 正被访存事务/WB 背压/
  // 页表遍历冻结，ID/EX 无法接收分支，此时清 IF/ID 会丢失分支本身
  // （flush 清 IF/ID 但 ID/EX 保持空 -> 指令流断链）。用无组合环的
  // 子条件（dmem_pending/stall_wb/fetch_walk）表达冻结。
  assign flush_id = ifid_valid && d.valid && !d.exc &&
                    (d.sys_op != SYS_ERET) && !load_use &&
                    !ex_id_gpr_hazard && !ex_id_sp_hazard &&
                    !ex_id_flags_hazard && !ex_id_v_hazard &&
                    !exmem_v_hazard && !ex_busy &&
                    !dmem_pending && exmem_can_accept && !fetch_walk &&
                    (d.next_pc != (ifid_pc + 64'd4));
  // ---- M1-B：imem 取指请求/响应 ----
  // 普通取指请求：无在途请求、无已到数据、非 flush/系统提交、管道可接收
  // 时发出；维护请求通常拥有 imem 端口。MMU-on 的维护流程进入 MS_DONE
  // 后不再有维护请求，必须把端口交还普通 fetch，才能让 FIFO 收到
  // next-PC entry 并解除 maint_done/fetch_next_settled 的循环等待。
  assign maint_imem_owner = sys_maint_at_id &&
                            !memwb_fetch_wait &&
                            !(mmu_en && maint_state == MS_DONE);
  // The response owner is registered at request acceptance, rather than
  // inferred from the current IF/ID instruction or maintenance state.  A
  // younger maintenance request may be killed while an older fault/exception
  // redirects the frontend; the already accepted response must still drain
  // through the maintenance slot and must never be presented as a fetch
  // response.  This metadata is also what makes delayed/cache responses safe
  // across a state-machine reset to MS_IDLE.
  assign maint_imem_rsp_owner = maint_imem_rsp_pending;
  assign fetch_imem_req_valid = !fetch_trans_busy && !fetch_faulted &&
                                !fetch_pending && !fetch_got_data &&
                                !maint_imem_rsp_pending &&
                                (!mmu_en_eff || fetch_translated) &&
                                !flush_id && !sys_commit && !fetch_merge_wb &&
                                !sys_fetch_redirect && !mem_busy &&
                                !data_trans_active && !mmu_req_issue &&
                                !fetch_walk && !maint_imem_owner && !wfi_idle &&
                                !frontend_kill && !irq_taken &&
                                !fetch_stale_drain &&
                                !fetch_control_fence &&
                                (!fetch_fifo_active ||
                                 (!fetch_fault_pending && fetch_fifo_space));
  assign fetch_imem_req = '{addr: mmu_en_eff ? fetch_pa_r : if_pc, we: 1'b0,
                            strb: 8'h0F, wdata: '0, maint: MAINT_NONE,
                            bypass: !fetch_cacheable_r};   // 4 字节取指
  // 维护请求（M2-4b）：IC IVAU 按翻译后 PA 失效单行，IC IALLU 整表失效；
  // 只在上游处于 MS_REQ 时驱动（I-L1 空闲才接受）。
  assign maint_req_addr = (d.maint_op == MAINT_IC_IVAU)
                          ? trans_paddr_r : 64'd0;
  assign maint_imem_req_selected = maint_imem_owner &&
                                   (maint_state == MS_REQ) &&
                                   !maint_imem_rsp_pending &&
                                   !fetch_stale_drain && !frontend_kill &&
                                   !fetch_merge_wb && !wb_exc_commit &&
                                   !sys_commit && !sys_fetch_redirect &&
                                   !irq_taken;
  assign maint_imem_req_valid = maint_imem_req_selected;
  assign maint_imem_req = '{addr: maint_req_addr, we: 1'b0, strb: 8'h00,
                            wdata: '0, maint: d.maint_op, bypass: 1'b0};
  assign imem_req_valid = maint_imem_owner ? maint_imem_req_valid
                                           : fetch_imem_req_valid;
  assign imem_req = maint_imem_owner ? maint_imem_req : fetch_imem_req;
  // feature-off 保持旧路径无条件消费；feature-on 在 FIFO 满时施加
  // upstream backpressure，已登记的 maintenance response 以及 stale/kill
  // response 都优先消费以释放单 outstanding/quarantine。
  assign imem_rsp_ready = !fetch_fifo_active ? 1'b1 :
      // A registered maintenance owner has priority over all frontend
      // quarantine signals.  The arbiter is single-outstanding, so a stale
      // fetch response cannot coexist with this response; prioritizing the
      // owner prevents a killed maintenance response from being dropped.
      maint_imem_rsp_owner ? 1'b1 :
      (frontend_kill || fetch_stale_imem) ? 1'b1 :
      (fetch_pending && fetch_fifo_space);
  // 取指 FSM 只在普通取指请求被接受时登记在途（维护请求不算取指）
  assign imem_req_accept = fetch_imem_req_valid && imem_req_ready;
  assign maint_imem_req_accept = maint_imem_req_selected && imem_req_ready;
  assign maint_imem_rsp_consume = maint_imem_rsp_owner &&
                                  imem_rsp_valid && imem_rsp_ready;
  assign capture_now = !fetch_fifo_active && fetch_got_data && !flush_id &&
                       !stall_if && (if_pc == fetch_pc_r);

  // LSE atomic RMW 结果：按访问宽度生成原子写入值。
  always_comb begin
    unique case (exmem_mem_size)
      2'd0: begin
        exmem_atomic_old_u = {56'd0, exmem_rdata_r[7:0]};
        exmem_atomic_arg_u = {56'd0, exmem_mem_wdata[7:0]};
        exmem_atomic_old_s = {{56{exmem_rdata_r[7]}}, exmem_rdata_r[7:0]};
        exmem_atomic_arg_s = {{56{exmem_mem_wdata[7]}}, exmem_mem_wdata[7:0]};
      end
      2'd1: begin
        exmem_atomic_old_u = {48'd0, exmem_rdata_r[15:0]};
        exmem_atomic_arg_u = {48'd0, exmem_mem_wdata[15:0]};
        exmem_atomic_old_s = {{48{exmem_rdata_r[15]}}, exmem_rdata_r[15:0]};
        exmem_atomic_arg_s = {{48{exmem_mem_wdata[15]}}, exmem_mem_wdata[15:0]};
      end
      2'd2: begin
        exmem_atomic_old_u = {32'd0, exmem_rdata_r[31:0]};
        exmem_atomic_arg_u = {32'd0, exmem_mem_wdata[31:0]};
        exmem_atomic_old_s = {{32{exmem_rdata_r[31]}}, exmem_rdata_r[31:0]};
        exmem_atomic_arg_s = {{32{exmem_mem_wdata[31]}}, exmem_mem_wdata[31:0]};
      end
      default: begin
        exmem_atomic_old_u = exmem_rdata_r;
        exmem_atomic_arg_u = exmem_mem_wdata;
        exmem_atomic_old_s = exmem_rdata_r;
        exmem_atomic_arg_s = exmem_mem_wdata;
      end
    endcase
    unique case (exmem_atomic_op)
      ATOMIC_ADD:  exmem_atomic_new = exmem_atomic_old_u + exmem_atomic_arg_u;
      ATOMIC_CLR:  exmem_atomic_new = exmem_atomic_old_u & ~exmem_atomic_arg_u;
      ATOMIC_EOR:  exmem_atomic_new = exmem_atomic_old_u ^ exmem_atomic_arg_u;
      ATOMIC_SET:  exmem_atomic_new = exmem_atomic_old_u | exmem_atomic_arg_u;
      ATOMIC_SMAX: exmem_atomic_new = ($signed(exmem_atomic_old_s) >
                                        $signed(exmem_atomic_arg_s))
                                       ? exmem_atomic_old_u : exmem_atomic_arg_u;
      ATOMIC_SMIN: exmem_atomic_new = ($signed(exmem_atomic_old_s) <
                                        $signed(exmem_atomic_arg_s))
                                       ? exmem_atomic_old_u : exmem_atomic_arg_u;
      ATOMIC_UMAX: exmem_atomic_new = (exmem_atomic_old_u > exmem_atomic_arg_u)
                                       ? exmem_atomic_old_u : exmem_atomic_arg_u;
      ATOMIC_UMIN: exmem_atomic_new = (exmem_atomic_old_u < exmem_atomic_arg_u)
                                       ? exmem_atomic_old_u : exmem_atomic_arg_u;
      ATOMIC_SWP:  exmem_atomic_new = exmem_atomic_arg_u;
      ATOMIC_CLRP: exmem_atomic_new = exmem_atomic_old_u & ~exmem_atomic_arg_u;
      ATOMIC_SETP: exmem_atomic_new = exmem_atomic_old_u | exmem_atomic_arg_u;
      ATOMIC_SWPP: exmem_atomic_new = exmem_atomic_arg_u;
      ATOMIC_CAS, ATOMIC_CASP: exmem_atomic_new = exmem_mem_wdata;
      default:    exmem_atomic_new = exmem_rdata_r;
    endcase
    // W/H/B 原子操作按访问宽度回绕；同时保证提交包中的 Store
    // 数据不带出高位进位。
    exmem_atomic_new = exmem_atomic_new & size_mask(exmem_mem_size);
  end

  // LSE128 高半新值。CASP/SWPP 使用第二个源寄存器；LDCLRP/LDSETP
  // 必须基于高半旧值计算，不能沿用原始 source 高值作为提交数据。
  always_comb begin
    unique case (exmem_atomic_op)
      ATOMIC_CASP, ATOMIC_SWPP: exmem_atomic_new2 = exmem_mem_wdata2;
      ATOMIC_CLRP: exmem_atomic_new2 = exmem_rdata2_r & ~exmem_mem_wdata2;
      ATOMIC_SETP: exmem_atomic_new2 = exmem_rdata2_r | exmem_mem_wdata2;
      default: exmem_atomic_new2 = exmem_mem_wdata2;
    endcase
    exmem_atomic_new2 = exmem_atomic_new2 & size_mask(exmem_mem_size);
  end

  // ---- M1-B：dmem 数据请求/响应 ----
  // load/store 在 EX/MEM 停留到响应被消费（Store 副作用=请求被接受）；
  // 响应数据注册进 exmem_rdata_r，随 EX/MEM->WB 传递。
  // DC ZVA（M2-4b 扩展）：维护写请求（8 次 8 字节清零）独占 dmem 端口。
  // 维护指令在 ID 级等前方排空后提交，EX/MEM 无在途 load/store。
  assign maint_zva_active = (maint_state == MS_DCZVA_WRITE);
  assign maint_dmem_req_valid = maint_zva_active &&
                                !dmem_req_issued && !dmem_done &&
                                !data_trans_active && !fetch_walk && !irq_taken &&
                                !memwb_fetch_wait;
  assign maint_dmem_req = '{addr: maint_zva_pa + 8 * maint_zva_idx,
                            we: 1'b1, strb: 8'hFF, wdata: 64'd0,
                            maint: MAINT_NONE, bypass: 1'b0};
  assign dmem_req_valid = maint_zva_active ? maint_dmem_req_valid
                          : (exmem_valid && (exmem_is_atomic ||
                                             exmem_is_load ||
                                             exmem_is_store) &&
                             !dmem_req_issued && !dmem_done &&
                             !data_trans_active && !fetch_walk && !irq_taken);
  assign dmem_req = maint_zva_active
      ? maint_dmem_req
      : '{addr: exmem_mem_paddr +
                (exmem_is_atomic && is_atomic128_pair(exmem_atomic_op) &&
                 (atomic_phase == 2'd1 || atomic_phase == 2'd3)
                 ? (exmem_mem_paddr2 - exmem_mem_paddr)
                : (exmem_is_pair && pair_part
                 ? (exmem_mem_size == 2'd3
                    ? (exmem_mem_paddr2 - exmem_mem_paddr) : 64'd4)
                 : (exmem_is_stxr && exmem_is_pair && stxr_read_phase &&
                    stxp_cmp_hi)
                   ? (exmem_mem_size == 2'd3 ? 64'd8 : 64'd4)
                 : 64'd0)),
          // STXR 两相：读比较阶段发读（we=0），通过后发写
          we: exmem_is_atomic ?
              (is_atomic128_pair(exmem_atomic_op)
               ? (atomic_phase >= 2'd2) : !atomic_read_phase) :
              (exmem_is_store &&
               !(exmem_is_stxr && stxr_read_phase)),
          strb: exmem_is_atomic ? exmem_mem_strb :
              exmem_is_store ? (exmem_is_pair
                ? (exmem_mem_size == 2'd3 ? 8'hFF : 8'h0F)
                : exmem_mem_strb)
                               : strb_for_size(exmem_mem_size),
          wdata: exmem_is_atomic
                 ? (is_atomic128_pair(exmem_atomic_op)
                    ? ((atomic_phase == 2'd2) ? exmem_atomic_new
                       : (atomic_phase == 2'd3 ? exmem_atomic_new2 : 64'd0))
                    : (atomic_read_phase ? 64'd0 : exmem_atomic_new)) :
                 (exmem_is_pair && pair_part)
                 ? exmem_mem_wdata2 :
                 (exmem_is_stxr && stxr_read_phase)
                 ? 64'd0 : exmem_mem_wdata,
          maint: MAINT_NONE,
          bypass: ((exmem_is_atomic && is_atomic128_pair(exmem_atomic_op) &&
                    (atomic_phase == 2'd1 || atomic_phase == 2'd3)) ||
                   (exmem_is_pair && pair_part))
                  ? !exmem_mem_cacheable2 : !exmem_mem_cacheable};
  assign dmem_req_accept = dmem_req_valid && dmem_req_ready;
  assign maint_dmem_req_accept = maint_dmem_req_valid && dmem_req_ready;
  // 始终消费响应（含被 flush 的遗留响应），避免阻塞仲裁器
  assign dmem_rsp_ready = dmem_rsp_valid;
  // EX/MEM 数据事务进行中（请求待接受或响应待消费）：冻结 EX/MEM 及上游
  assign dmem_pending = dmem_req_valid || dmem_req_issued;

  // ---- WB 最终写回值（load 扩展）----
  always_comb begin
    wb_wdata = memwb_wdata;
    if (memwb_valid && memwb_is_stxr) begin
      // STXR 状态结果：成功 0 / 失败 1（QEMU 写 64 位 0/1）
      wb_wdata = {63'd0, memwb_stxr_result};
    end else if (memwb_valid && memwb_is_load) begin
      unique case (memwb_mem_size)
        2'd0: wb_wdata = memwb_ldr_sw
               ? (memwb_ldr_x
                  ? {{56{memwb_rdata_r[7]}},  memwb_rdata_r[7:0]}
                  : {32'd0, {{24{memwb_rdata_r[7]}}, memwb_rdata_r[7:0]}})
               : {56'd0, memwb_rdata_r[7:0]};
        2'd1: wb_wdata = memwb_ldr_sw
               ? (memwb_ldr_x
                  ? {{48{memwb_rdata_r[15]}}, memwb_rdata_r[15:0]}
                  : {32'd0, {{16{memwb_rdata_r[15]}}, memwb_rdata_r[15:0]}})
               : {48'd0, memwb_rdata_r[15:0]};
        2'd2: wb_wdata = memwb_ldr_sw
               ? {{32{memwb_rdata_r[31]}}, memwb_rdata_r[31:0]}
               : {32'd0, memwb_rdata_r[31:0]};
        2'd3: wb_wdata = memwb_rdata_r;
        default: wb_wdata = memwb_rdata_r;
      endcase
    end
  end

  // LDP 第二写回：W 对零扩展、X 对全 64 位
  always_comb begin
    wb2_wdata = memwb_wb2_extra;
    if (memwb_valid && memwb_is_load && memwb_is_pair) begin
      unique case (memwb_mem_size)
        2'd2: wb2_wdata = (memwb_ldr_sw && memwb_ldr_x)
                         ? {{32{memwb_rdata2_r[31]}}, memwb_rdata2_r[31:0]}
                         : {32'd0, memwb_rdata2_r[31:0]};
        2'd3: wb2_wdata = memwb_rdata2_r;
        default: wb2_wdata = memwb_rdata2_r;
      endcase
    end
  end

  // F1a generation and response quarantine are deliberately local to core.
  // There is no public response ID, so a kill records which of the two legal
  // single-outstanding contexts must be drained before a new request issues.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fetch_epoch          <= '0;
      fetch_stale_mmu      <= 1'b0;
      fetch_stale_imem     <= 1'b0;
      fetch_stale_drop_count <= 32'd0;
    end else if (!fetch_fifo_active) begin
      fetch_epoch          <= '0;
      fetch_stale_mmu      <= 1'b0;
      fetch_stale_imem     <= 1'b0;
      fetch_stale_drop_count <= 32'd0;
    end else begin
      if (frontend_kill) begin
        fetch_epoch <= fetch_epoch + {{(FETCH_EPOCH_W-1){1'b0}}, 1'b1};
        // TLBI synchronously aborts the MMU walk in lcvex_mmu; ordinary IRQ
        // uses the MMU abort/quarantine path and therefore drains to the
        // non-architectural walking state before reopening the frontend.
        if (tlb_invalidate) begin
          fetch_stale_mmu <= 1'b0;
        end else if (fetch_stale_mmu || fetch_trans_busy) begin
          fetch_stale_mmu <= !mmu_done;
        end else begin
          fetch_stale_mmu <= 1'b0;
        end
        if (fetch_stale_imem || fetch_pending)
          fetch_stale_imem <= !(imem_rsp_valid && imem_rsp_ready);
        else
          fetch_stale_imem <= 1'b0;
      end else begin
        // An ordinary IRQ abort is intentionally not an architectural MMU
        // done pulse.  Clear the local fetch quarantine only after the MMU
        // leaves its abort-drain state; normal completions still use done.
        if (fetch_stale_mmu && (mmu_done || !mmu_walking))
          fetch_stale_mmu <= 1'b0;
        if (fetch_stale_imem && imem_rsp_valid && imem_rsp_ready)
          fetch_stale_imem <= 1'b0;
      end
      if (fetch_stale_rsp_drop)
        fetch_stale_drop_count <= fetch_stale_drop_count + 32'd1;
    end
  end

  // Fixed two-entry ring.  Flush has priority over both push and pop.  A
  // simultaneous push+pop keeps occupancy constant and advances both ring
  // pointers, which also permits a response to arrive as the current head is
  // handed to IF/ID.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fetch_fifo_valid       <= 2'b00;
      fetch_fifo_fault       <= 2'b00;
      fetch_fifo_head        <= 1'b0;
      fetch_fifo_tail        <= 1'b0;
      fetch_fifo_count       <= 2'd0;
      fetch_fifo_push_count  <= 32'd0;
      fetch_fifo_pop_count   <= 32'd0;
      fetch_fifo_flush_count <= 32'd0;
      fetch_fifo_peak        <= 2'd0;
      for (int i = 0; i < 2; i++) begin
        fetch_fifo_epoch_r[i] <= '0;
        fetch_fifo_seq_r[i]   <= 16'd0;
        fetch_fifo_pc_r[i]    <= 64'd0;
        fetch_fifo_insn_r[i]  <= 32'd0;
        fetch_fifo_fsc_r[i]   <= 6'd0;
      end
    end else if (!fetch_fifo_active) begin
      fetch_fifo_valid       <= 2'b00;
      fetch_fifo_fault       <= 2'b00;
      fetch_fifo_head        <= 1'b0;
      fetch_fifo_tail        <= 1'b0;
      fetch_fifo_count       <= 2'd0;
      fetch_fifo_push_count  <= 32'd0;
      fetch_fifo_pop_count   <= 32'd0;
      fetch_fifo_flush_count <= 32'd0;
      fetch_fifo_peak        <= 2'd0;
    end else if (frontend_kill) begin
      fetch_fifo_valid       <= 2'b00;
      fetch_fifo_fault       <= 2'b00;
      fetch_fifo_head        <= 1'b0;
      fetch_fifo_tail        <= 1'b0;
      fetch_fifo_count       <= 2'd0;
      fetch_fifo_flush_count <= fetch_fifo_flush_count + 32'd1;
    end else begin
      if (fetch_fifo_pop) begin
        fetch_fifo_valid[fetch_fifo_head] <= 1'b0;
        fetch_fifo_head <= fetch_fifo_head ^ 1'b1;
        fetch_fifo_pop_count <= fetch_fifo_pop_count + 32'd1;
      end
      // Keep push after pop in source order.  When count==2 the ring's tail
      // equals its head, so a simultaneous push+pop must overwrite the slot
      // with the new entry rather than let the pop's valid=0 win.
      if (fetch_fifo_push) begin
        fetch_fifo_valid[fetch_fifo_tail] <= 1'b1;
        fetch_fifo_fault[fetch_fifo_tail] <= fetch_fifo_push_fault;
        fetch_fifo_epoch_r[fetch_fifo_tail] <= fetch_fifo_push_epoch;
        fetch_fifo_seq_r[fetch_fifo_tail]   <= fetch_fifo_push_seq;
        fetch_fifo_pc_r[fetch_fifo_tail]    <= fetch_fifo_push_pc;
        fetch_fifo_insn_r[fetch_fifo_tail]  <= fetch_fifo_push_insn;
        fetch_fifo_fsc_r[fetch_fifo_tail]   <= fetch_fifo_push_fsc;
        fetch_fifo_tail <= fetch_fifo_tail ^ 1'b1;
        fetch_fifo_push_count <= fetch_fifo_push_count + 32'd1;
      end
      unique case ({fetch_fifo_push, fetch_fifo_pop})
        2'b10: begin
          fetch_fifo_count <= fetch_fifo_count + 2'd1;
          if (fetch_fifo_count < 2'd2 &&
              (fetch_fifo_count + 2'd1) > fetch_fifo_peak)
            fetch_fifo_peak <= fetch_fifo_count + 2'd1;
        end
        2'b01: fetch_fifo_count <= fetch_fifo_count - 2'd1;
        default: ;
      endcase
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // IF / IF/ID
      if_pc         <= RESET_PC;
      fetch_pending <= 1'b0;
      fetch_pc_r    <= 64'd0;
      ifid_valid    <= 1'b0;
      ifid_pc    <= 64'd0;
      ifid_insn  <= 32'd0;
      ifid_token_epoch <= '0;
      ifid_token_seq   <= 16'd0;
      // ID/EX
      idex_valid <= 1'b0;
      idex_insn  <= 32'd0;
      idex_pc    <= 64'd0;
      idex_d     <= '0;
      idex_token_epoch <= '0;
      idex_token_seq   <= 16'd0;
      // EX/MEM
      exmem_valid <= 1'b0;
      exmem_insn  <= 32'd0;
      exmem_pc    <= 64'd0;
      exmem_next_pc <= 64'd0;
      exmem_wdata <= 64'd0;
      exmem_wb_we <= 1'b0;
      exmem_wb_rd <= 5'd0;
      exmem_token_epoch <= '0;
      exmem_token_seq   <= 16'd0;
      exmem_sp_we <= 1'b0;
      exmem_sp_wdata <= 64'd0;
      exmem_nzcv_we <= 1'b0;
      exmem_nzcv <= 4'd0;
      exmem_is_load <= 1'b0;
      exmem_is_store <= 1'b0;
      exmem_is_ldxr <= 1'b0;
      exmem_is_stxr <= 1'b0;
      exmem_is_clrex <= 1'b0;
      exmem_is_atomic <= 1'b0;
      exmem_atomic_op <= ATOMIC_ADD;
      exmem_atomic_cmp <= 64'd0;
      exmem_atomic_cmp2 <= 64'd0;
      exmem_atomic_store <= 1'b0;
      exmem_mem_size <= 2'd0;
      exmem_ldr_sw <= 1'b0;
      exmem_ldr_x <= 1'b0;
      exmem_mem_addr <= 64'd0;
      exmem_mem_wdata <= 64'd0;
      exmem_mem_strb <= 8'd0;
      exmem_mem_paddr <= 64'd0;
      exmem_mem_paddr2 <= 64'd0;
      exmem_mem_cacheable <= 1'b1;
      exmem_mem_cacheable2 <= 1'b1;
      exmem_is_pair <= 1'b0;
      exmem_mem_wdata2 <= 64'd0;
      exmem_fp_valid <= 1'b0;
      exmem_fp_is_double <= 1'b0;
      exmem_fp_wb_we <= 1'b0;
      exmem_fp_rd <= 5'd0;
      exmem_fp_mem_load <= 1'b0;
      exmem_fp_wdata <= 128'd0;
      exmem_fp_fpsr_wdata <= 32'd0;
      exmem_fp_fpsr_we <= 1'b0;
      exmem_neon_valid <= 1'b0;
      exmem_neon_wb_we <= 1'b0;
      exmem_neon_rd <= 5'd0;
      exmem_neon_mem_load <= 1'b0;
      exmem_neon_quad <= 1'b0;
      exmem_neon_mem_replicate <= 1'b0;
      exmem_neon_wdata <= 128'd0;
      exmem_wb2_rd <= 5'd0;
      exmem_wb2_we <= 1'b0;
      exmem_wb2_extra <= 64'd0;
      exmem_wb3_we <= 1'b0;
      exmem_wb3_rd <= 5'd0;
      exmem_wb3_extra <= 64'd0;
      stxr_read_phase <= 1'b0;
      atomic_read_phase <= 1'b0;
      atomic_phase <= 2'd0;
      stxp_cmp_hi     <= 1'b0;
      exmem_stxr_pass <= 1'b0;
      exmem_stxr_result <= 1'b0;
      exmem_rdata2_r <= 64'd0;
      memwb_rdata2_r <= 64'd0;
      pair_part <= 1'b0;
      // MEM/WB
      memwb_valid <= 1'b0;
      memwb_insn  <= 32'd0;
      memwb_pc    <= 64'd0;
      memwb_next_pc <= 64'd0;
      memwb_token_epoch <= '0;
      memwb_token_seq   <= 16'd0;
      memwb_wdata <= 64'd0;
      memwb_wb_we <= 1'b0;
      memwb_wb_rd <= 5'd0;
      memwb_sp_we <= 1'b0;
      memwb_sp_wdata <= 64'd0;
      memwb_nzcv_we <= 1'b0;
      memwb_nzcv <= 4'd0;
      memwb_is_load <= 1'b0;
      memwb_mem_size <= 2'd0;
      memwb_ldr_sw <= 1'b0;
      memwb_ldr_x <= 1'b0;
      memwb_is_store <= 1'b0;
      memwb_is_ldxr <= 1'b0;
      memwb_is_stxr <= 1'b0;
      memwb_is_clrex <= 1'b0;
      memwb_mem_addr <= 64'd0;
      memwb_mem_wdata <= 64'd0;
      memwb_mem_strb <= 8'd0;
      memwb_is_pair <= 1'b0;
      memwb_fp_valid <= 1'b0;
      memwb_fp_wb_we <= 1'b0;
      memwb_fp_rd <= 5'd0;
      memwb_fp_wdata <= 128'd0;
      memwb_fp_fpsr_wdata <= 32'd0;
      memwb_fp_fpsr_we <= 1'b0;
      memwb_neon_valid <= 1'b0;
      memwb_neon_wb_we <= 1'b0;
      memwb_neon_rd <= 5'd0;
      memwb_neon_wdata <= 128'd0;
      memwb_wb2_rd <= 5'd0;
      memwb_wb2_we <= 1'b0;
      memwb_wb2_extra <= 64'd0;
      memwb_wb3_we <= 1'b0;
      memwb_wb3_rd <= 5'd0;
      memwb_wb3_extra <= 64'd0;
      memwb_stxr_result <= 1'b0;
      memwb_stxr_fail <= 1'b0;
      // 提交
      commit_valid_r <= 1'b0;
      commit_token_epoch <= '0;
      commit_token_seq   <= 16'd0;
      dbg_ifid_to_idex_fire   <= 1'b0;
      dbg_idex_to_exmem_fire  <= 1'b0;
      dbg_exmem_to_memwb_fire <= 1'b0;
      dbg_commit_fire         <= 1'b0;
      commit_pc_r <= 64'd0;
      commit_next_pc_r <= 64'd0;
      commit_insn_r <= 32'd0;
      commit_gpr_we_r <= 1'b0;
      commit_gpr_rd_r <= 5'd0;
      commit_gpr_wdata_r <= 64'd0;
      commit_gpr2_we_r <= 1'b0;
      commit_gpr2_rd_r <= 5'd0;
      commit_gpr2_wdata_r <= 64'd0;
      commit_gpr3_we_r <= 1'b0;
      commit_gpr3_rd_r <= 5'd0;
      commit_gpr3_wdata_r <= 64'd0;
      commit_sp_we_r <= 1'b0;
      commit_sp_wdata_r <= 64'd0;
      commit_nzcv_we_r <= 1'b0;
      commit_nzcv_r <= 4'd0;
      commit_mem_we_r <= 1'b0;
      commit_mem_addr_r <= 64'd0;
      commit_mem_wdata_r <= 64'd0;
      commit_mem_strb_r <= 8'd0;
      commit_mem2_we_r <= 1'b0;
      commit_mem2_addr_r <= 64'd0;
      commit_mem2_wdata_r <= 64'd0;
      commit_mem2_strb_r <= 8'd0;
      commit_exc_valid_r <= 1'b0;
      commit_exc_code_r <= 32'd0;
      commit_exc_esr_r <= 32'd0;
      commit_exc_far_r <= 64'd0;
      commit_mon_we_r <= 1'b0;
      commit_mon_valid_r <= 1'b0;
      commit_mon_addr_r <= 64'd0;
      commit_mon_data_r <= 64'd0;
      commit_mon_data2_r <= 64'd0;
      commit_vec_write_count_r <= 3'd0;
      commit_vec_rd0_r <= 5'd0;
      commit_vec_rd1_r <= 5'd0;
      commit_vec_rd2_r <= 5'd0;
      commit_vec_rd3_r <= 5'd0;
      commit_vec_wdata0_r <= 128'd0;
      commit_vec_wdata1_r <= 128'd0;
      commit_vec_wdata2_r <= 128'd0;
      commit_vec_wdata3_r <= 128'd0;
      commit_fpcr_we_r <= 1'b0;
      commit_fpcr_wdata_r <= 32'd0;
      commit_fpsr_we_r <= 1'b0;
      commit_fpsr_wdata_r <= 32'd0;
      memwb_committed_r <= 1'b0;
      exmem_exc <= 1'b0;
      memwb_exc <= 1'b0;
      // 架构状态
      sp_el0 <= 64'd0;
      sp_el1 <= 64'd0;
      nzcv   <= 4'b0100;  // 复位 Z=1，与 QEMU 复位状态一致
      el     <= 1'b1;     // 复位 EL1h（QEMU has_el3/el2=false 语义）
      sp_sel <= 1'b1;
      daif   <= 4'b1111;  // 复位 D/A/I/F 全置位，与 QEMU 一致
      pstate_pan <= 1'b0;
      pstate_dit <= 1'b0;
      pstate_ssbs <= 1'b0;
      pstate_uao <= 1'b0;
      pstate_tco <= 1'b0;
      pstate_allint <= 1'b0;
      elr_el1  <= 64'd0;
      spsr_el1 <= 64'd0;
      vbar_el1 <= 64'd0;
      sctlr_el1 <= 64'h0000_0000_00C5_0838;  // QEMU EL1h 复位值（M=0）
      tcr_el1   <= 64'd0;
      ttbr0_el1 <= 64'd0;
      ttbr1_el1 <= 64'd0;
      mair_el1  <= 64'd0;
      esr_el1   <= 32'd0;
      far_el1   <= 64'd0;
      mdscr_el1  <= 64'd0;
      pmuserenr_el0 <= 64'd0;
      cntkctl_el1   <= 64'd0;
      cntpct_r      <= 64'd0;
      cntp_ctl_r    <= 2'd0;
      cntp_cval_r   <= 64'd0;
      cntv_ctl_r    <= 2'd0;
      cntv_cval_r   <= 64'd0;
      wfi_idle      <= 1'b0;
      event_reg     <= 1'b0;
      wfi_pc_r      <= 64'd0;
      wfi_insn_r    <= 32'd0;
      wfi_timeout_valid <= 1'b0;
      wfi_timeout_r     <= 64'd0;
      difftest_wait_release_pending <= 1'b0;
      difftest_wait_cntvct_pending <= 1'b0;
      difftest_wait_cntvct_r <= 64'd0;
      tpidr_el0     <= 64'd0;
      tpidrro_el0   <= 64'd0;
      tpidr_el1     <= 64'd0;
      contextidr_el1 <= 64'd0;
      tcr2_el1      <= 64'd0;
      zcr_el1       <= 64'd0;
      smcr_el1      <= 64'd0;
      csselr_el1    <= 64'd0;
      pir_el1       <= 64'd0;
      pire0_el1     <= 64'd0;
      par_el1       <= 64'd0;
      par_update_pending <= 1'b0;
      par_update_data_pending <= 64'd0;
      excl_valid <= 1'b0;
      excl_addr  <= 64'd0;
      excl_data  <= 64'd0;
      excl_data_hi <= 64'd0;
      data_trans_active <= 1'b0;
      trans_paddr_r <= 64'd0;
      trans_paddr2_r <= 64'd0;
      trans_cacheable_r <= 1'b1;
      trans_cacheable2_r <= 1'b1;
      trans_fsc_r <= 6'd0;
      dabt_pending  <= 1'b0;
      trans_done_flag <= 1'b0;
      trans_done_pc_r <= 64'd0;
      atomic128_second_needed <= 1'b0;
      fetch_trans_busy <= 1'b0;
      fetch_pa_r <= 64'd0;
      fetch_cacheable_r <= 1'b1;
      fetch_fsc_r <= 6'd0;
      fetch_faulted <= 1'b0;
      fetch_translated <= 1'b0;
      fetch_got_data <= 1'b0;
      fetch_data_r <= 32'd0;
      fetch_ctx_epoch <= '0;
      fetch_seq <= 16'd0;
      fetch_ctx_seq <= 16'd0;
      fetch_fault_pending <= 1'b0;
      dmem_req_issued <= 1'b0;
      dmem_done <= 1'b0;
      exmem_rdata_r <= 64'd0;
      memwb_rdata_r <= 64'd0;
      for (int i = 0; i < 31; i++) begin
        gpr[i] <= 64'd0;
      end
    end else begin
      // One-cycle diagnostic transfer pulses; token values are held in the
      // corresponding stage registers and are never part of architectural
      // state or the public commit packet.
      dbg_ifid_to_idex_fire   <= 1'b0;
      dbg_idex_to_exmem_fire  <= 1'b0;
      dbg_exmem_to_memwb_fire <= 1'b0;
      dbg_commit_fire         <= 1'b0;
      if (wfi_wake) begin
        wfi_idle  <= 1'b0;
        event_reg <= 1'b0;
        wfi_timeout_valid <= 1'b0;
      end
      // 显式仿真 sideband：QEMU 的 WAIT_RESUME 已说明真实虚拟时间，或
      // cpu_has_work/event 说明等待立即返回。若等待系统提交尚未在 DUT
      // 可见，先锁存请求，待下一拍 wfi_wake 消费。
      if (difftest_wait_release) begin
        difftest_wait_release_pending <= 1'b1;
        if (difftest_wait_cntvct_valid) begin
          difftest_wait_cntvct_pending <= 1'b1;
          difftest_wait_cntvct_r <= difftest_wait_cntvct;
        end
      end
      if (wfi_wake && (difftest_wait_release ||
                       difftest_wait_release_pending)) begin
        difftest_wait_release_pending <= 1'b0;
        difftest_wait_cntvct_pending <= 1'b0;
      end
      // AT 的翻译结果先锁存为 pending，只有该 AT 在 ID 级真正提交时
      // 才更新 PAR_EL1；翻译完成本身不能让后续指令提前观察到结果。
      if (par_update_valid) begin
        par_update_pending <= 1'b1;
        par_update_data_pending <= par_update_data;
      end
      if (sys_commit && sys_maint_at_id && d.maint_op == MAINT_AT) begin
        if (par_update_pending)
          par_el1 <= par_update_data_pending;
        par_update_pending <= 1'b0;
      end else if (!sys_maint_at_id) begin
        par_update_pending <= 1'b0;
      end
      // ---- P5a 数据翻译状态机 ----
      if (data_req_valid && mmu_req_accept) begin
        data_trans_active <= 1'b1;
        trans_done_pc_r <= ifid_pc;
      end else if (mmu_done && data_trans_active) begin
        data_trans_active <= 1'b0;
        trans_paddr_r <= mmu_paddr;
        trans_cacheable_r <= mmu_cacheable;
        trans_fsc_r <= mmu_fault_fsc;
        trans_done_flag <= 1'b1;
        if (mmu_fault) begin
          // 维护 VA 翻译失败由维护状态机处理（不产生数据异常）；
          // 普通 load/store 翻译失败 -> DABT
          if (!maint_va_pending) begin
            dabt_pending <= 1'b1;
          end
          atomic128_second_needed <= 1'b0;
        end else if (d_mem128 && !atomic128_second_needed &&
                     (d.mem_addr[11:0] > 12'hff0)) begin
          // 16B 访问跨 4KiB 页：低半翻译成功后，先翻译下一页，
          // 只有两半都成功才允许进入 EX/MEM。
          atomic128_second_needed <= 1'b1;
        end else begin
          if (d_mem128) begin
            if (atomic128_second_needed) begin
              trans_paddr2_r <= mmu_paddr;
              trans_cacheable2_r <= mmu_cacheable;
              if (!pa_window8(trans_paddr_r) || !pa_window8(mmu_paddr) ||
                  (trans_paddr_r[3:0] != 4'd0) ||
                  (mmu_paddr[3:0] != 4'd0)) begin
                dabt_pending <= 1'b1;
                trans_fsc_r <= 6'h10;
              end
            end else begin
              trans_paddr2_r <= mmu_paddr + 64'd8;
              trans_cacheable2_r <= mmu_cacheable;
              if (!pa_window8(mmu_paddr) ||
                  !pa_window8(mmu_paddr + 64'd8) ||
                  (mmu_paddr[3:0] != 4'd0)) begin
                dabt_pending <= 1'b1;
                trans_fsc_r <= 6'h10;
              end
            end
          end
          atomic128_second_needed <= 1'b0;
        end
      end
      // 新指令进入 IF/ID、冲刷或合并提交时清除翻译完成标志
      if (capture_now || fetch_fifo_pop || flush_id || sys_commit || fetch_merge_wb ||
          wb_exc_commit || irq_taken ||
          !ifid_valid) begin
        trans_done_flag <= 1'b0;
        atomic128_second_needed <= 1'b0;
      end
      if (sys_commit || fetch_merge_wb || wb_exc_commit || wfi_wake || irq_taken) begin
        dabt_pending <= 1'b0;
        data_trans_active <= 1'b0;
      end
      // Ordinary IRQ is a precise older WB boundary.  Any data translation
      // result that happens to arrive on that edge belongs to a younger
      // instruction and must not survive into the vector stream.
      if (irq_taken) begin
        par_update_pending <= 1'b0;
        trans_paddr_r       <= 64'd0;
        trans_paddr2_r      <= 64'd0;
        trans_cacheable_r   <= 1'b1;
        trans_cacheable2_r  <= 1'b1;
        trans_fsc_r         <= 6'd0;
      end

      // ---- IF：取指地址和在途 context ----
      // feature-off 保留原有“响应捕获后 if_pc += 4”的单 context FSM；
      // feature-on 只在 I-L1 request 被接受时推进 tail PC，响应随后进入
      // FIFO，故 IF/ID stall 不会把 PC 绑定到物理地址或实时端口数据。
      if (fetch_fifo_active) begin
        if (sys_commit || fetch_merge_wb || wb_exc_commit) begin
          if_pc <= sys_commit ? sys_next_pc : exc_vector_core;
        end else if (wfi_irq_take) begin
          if_pc <= irq_vector_core;
        end else if (wfi_wake) begin
          if_pc <= wfi_pc_r + 64'd4;
        end else if (irq_taken) begin
          if_pc <= irq_vector_core;
        end else if (sys_fetch_redirect) begin
          if_pc <= d.next_pc;
        end else if (flush_id) begin
          if_pc <= d.next_pc;
        end else if (imem_req_accept) begin
          if_pc <= if_pc + 64'd4;
        end else begin
          if_pc <= if_pc;
        end

        if (frontend_kill) begin
          fetch_pending  <= 1'b0;
          fetch_got_data <= 1'b0;
          fetch_pc_r     <= 64'd0;
          fetch_translated <= 1'b0;
          fetch_trans_busy <= 1'b0;
          fetch_faulted  <= 1'b0;
          fetch_fault_pending <= 1'b0;
        end else begin
          // MMU fetch translation is still single-outstanding.  The context
          // token is captured at acceptance and retained through I-L1.
          if (fetch_req_accept) begin
            fetch_trans_busy <= 1'b1;
            fetch_pc_r       <= if_pc;
            fetch_ctx_epoch  <= fetch_epoch;
            fetch_ctx_seq    <= fetch_seq;
            fetch_seq        <= fetch_seq + 16'd1;
          end else if (mmu_done && fetch_trans_busy &&
                       !fetch_stale_mmu) begin
            fetch_trans_busy <= 1'b0;
            fetch_translated <= !mmu_fault;
            fetch_fsc_r <= mmu_fault_fsc;
            if (mmu_fault) begin
              fetch_faulted <= 1'b1;
              // If the ring is full, retain the fault token until the older
              // head is popped.  Otherwise FIFO push happens on this edge.
              fetch_fault_pending <= !fetch_fifo_space;
            end else begin
              fetch_pa_r <= mmu_paddr;
              fetch_cacheable_r <= mmu_cacheable;
            end
          end
          if (imem_req_accept) begin
            fetch_pending <= 1'b1;
            fetch_translated <= 1'b0;
            if (!mmu_en_eff) begin
              fetch_pc_r <= if_pc;
              fetch_ctx_epoch <= fetch_epoch;
              fetch_ctx_seq <= fetch_seq;
              fetch_seq <= fetch_seq + 16'd1;
            end
          end
          if (fetch_imem_rsp_current) begin
            fetch_pending <= 1'b0;
            if (imem_rsp.fault) begin
              fetch_faulted <= 1'b1;
              fetch_fsc_r <= 6'h10;
            end
          end
          if (fetch_fault_pending && fetch_fifo_push)
            fetch_fault_pending <= 1'b0;
        end
      end else begin
        // Legacy single-context path (feature-off semantic anchor).
        if (sys_commit || fetch_merge_wb || wb_exc_commit) begin
          // WB 级 DABT 与取指合并提交都重定向到异常向量
          if_pc <= sys_commit ? sys_next_pc : exc_vector_core;
        end else if (wfi_irq_take) begin
          if_pc <= irq_vector_core;
        end else if (wfi_wake) begin
          if_pc <= wfi_pc_r + 64'd4;
        end else if (irq_taken) begin
          // P6：IRQ 取走重定向到 IRQ 向量
          if_pc <= irq_vector_core;
        end else if (sys_fetch_redirect) begin
          if_pc <= d.next_pc;       // ERET/异常：提前重定向（等翻译判定）
        end else if (flush_id) begin
          if_pc <= d.next_pc;       // 分支目标（若端口忙，下一周期取指）
        end else if (capture_now) begin
          if_pc <= if_pc + 64'd4;   // 在途取指被捕获：推进
        end else begin
          if_pc <= if_pc;           // 在途取指未捕获（stall/访存忙）：保持
        end

        // Legacy in-flight fetch registration.
        if (sys_commit || fetch_merge_wb || wb_exc_commit || wfi_wake ||
            irq_taken ||
            sys_fetch_redirect || flush_id || tlb_invalidate) begin
          fetch_pending  <= 1'b0;
          fetch_got_data <= 1'b0;
          fetch_pc_r     <= 64'd0;
          fetch_translated <= 1'b0;
          fetch_trans_busy <= 1'b0;
          fetch_faulted  <= 1'b0;
        end else begin
          if (fetch_req_accept) begin
            fetch_trans_busy <= 1'b1;
            fetch_pc_r <= if_pc;
          end else if (mmu_done && fetch_trans_busy) begin
            fetch_trans_busy <= 1'b0;
            fetch_translated <= 1'b1;
            fetch_pc_r <= if_pc;
            fetch_fsc_r <= mmu_fault_fsc;
            if (mmu_fault) begin
              fetch_faulted <= 1'b1;
            end else begin
              fetch_pa_r <= mmu_paddr;
              fetch_cacheable_r <= mmu_cacheable;
            end
          end
          if (imem_req_accept) begin
            fetch_pending <= 1'b1;
            fetch_translated <= 1'b0;
            if (!mmu_en) begin
              fetch_pc_r <= if_pc;
            end
          end
          if (imem_rsp_valid && imem_rsp_ready && fetch_pending) begin
            fetch_pending  <= 1'b0;
            if (imem_rsp.fault) begin
              fetch_faulted <= 1'b1;
              fetch_fsc_r   <= 6'h10;
            end else begin
              fetch_got_data <= 1'b1;
              fetch_data_r   <= imem_rsp.rdata[31:0];
            end
          end
          if (capture_now) begin
            fetch_got_data <= 1'b0;
          end
        end
      end

      // ---- IF/ID：FIFO head replaces a consumed IF/ID entry ----
      if (fetch_fifo_active) begin
        if (sys_commit || fetch_merge_wb || wb_exc_commit || wfi_wake ||
            wfi_irq_take || irq_taken || flush_id ||
            difftest_restore_sys_valid) begin
          ifid_valid <= 1'b0;
          ifid_token_epoch <= '0;
          ifid_token_seq   <= 16'd0;
        end else if (stall_if) begin
          ;
        end else if (fetch_fifo_pop) begin
          ifid_valid <= 1'b1;
          ifid_pc    <= fetch_fifo_pc_r[fetch_fifo_head];
          ifid_insn  <= fetch_fifo_insn_r[fetch_fifo_head];
          ifid_token_epoch <= fetch_fifo_epoch_r[fetch_fifo_head];
          ifid_token_seq   <= fetch_fifo_seq_r[fetch_fifo_head];
        end else begin
          ifid_valid <= 1'b0;
          ifid_token_epoch <= '0;
          ifid_token_seq   <= 16'd0;
        end
      end else if (sys_commit || fetch_merge_wb || wb_exc_commit || wfi_wake ||
                   irq_taken) begin
        ifid_valid <= 1'b0;       // 系统/合并指令已提交，清除 IF/ID
        ifid_token_epoch <= '0;
        ifid_token_seq   <= 16'd0;
      end else if (flush_id) begin
        ifid_valid <= 1'b0;       // 冲刷错误取指
        ifid_token_epoch <= '0;
        ifid_token_seq   <= 16'd0;
      end else if (stall_if) begin
        ;                         // 冻结 IF/ID（ID 指令保持）
      end else if (capture_now) begin
        ifid_valid <= 1'b1;
        ifid_pc    <= fetch_pc_r;
        ifid_insn  <= fetch_data_r;
        ifid_token_epoch <= fetch_ctx_epoch;
        ifid_token_seq   <= fetch_ctx_seq;
      end else begin
        ifid_valid <= 1'b0;       // 数据未就绪：气泡
        ifid_token_epoch <= '0;
        ifid_token_seq   <= 16'd0;
      end

      // ---- ID/EX ----
      if (irq_taken || fetch_merge_wb || wb_exc_commit ||
          (fp_tx_kill && (fp_tx_candidate || fp_tx_issued))) begin
        idex_valid <= 1'b0;       // 合并/DABT/FP transaction kill：冲刷 ID/EX
        idex_token_epoch <= '0;
        idex_token_seq   <= 16'd0;
        idex_d.mem_paddr2 <= 64'd0;
      end else if (fp_consume) begin
        // FP response 被 EX/MEM 原子接收后，向 ID/EX 插入一个气泡；下一条
        // 指令留在 IF/ID，下一拍正常进入 ID/EX。避免同拍 IF/ID->ID/EX
        // 转移与 EX/MEM 捕获造成同 PC/同 token 瞬间同驻。
        idex_valid <= 1'b0;
        idex_token_epoch <= '0;
        idex_token_seq   <= 16'd0;
      end else if ((ex_busy && !(fp_rsp_valid && fp_rsp_ready)) ||
                   data_trans_active || data_mmu_issue ||
                   fetch_walk || (exmem_valid && !exmem_can_adv)) begin
        ;                         // 乘除/翻译/遍历中：idex 保持
      end else if (stall_id && !flush_id && !sys_commit) begin
        idex_valid <= 1'b0;       // 气泡（同一指令下周期重新译码）
        idex_token_epoch <= '0;
        idex_token_seq   <= 16'd0;
      end else begin
        idex_valid <= ifid_valid && !sys_commit && !dabt_pending &&
                      !fetch_merge_wb &&
                      (!mmu_en || !(d.is_load || d.is_store) ||
                       trans_done_for_ifid);
        if (ifid_valid && !sys_commit && !dabt_pending && !fetch_merge_wb &&
            (!mmu_en || !(d.is_load || d.is_store) ||
             trans_done_for_ifid)) begin
          idex_token_epoch <= ifid_token_epoch;
          idex_token_seq   <= ifid_token_seq;
          dbg_ifid_to_idex_fire <= 1'b1;
        end else begin
          idex_token_epoch <= '0;
          idex_token_seq   <= 16'd0;
        end
        idex_insn  <= ifid_insn;
        idex_pc    <= ifid_pc;
        idex_d.fp_valid          <= d.fp_valid;
        idex_d.fp_op             <= d.fp_op;
        idex_d.fp_is_double      <= d.fp_is_double;
        idex_d.fp_is_half        <= d.fp_is_half;
        idex_d.fp_fcvt_dst_half  <= d.fp_fcvt_dst_half;
        idex_d.fp_rint_mode      <= d.fp_rint_mode;
        idex_d.fp_wb_we          <= d.fp_wb_we;
        idex_d.fp_rd             <= d.fp_rd;
        idex_d.fp_operand_a      <= d.fp_operand_a;
        idex_d.fp_operand_b      <= d.fp_operand_b;
        idex_d.fp_operand_c      <= d.fp_operand_c;
        idex_d.fp_conv_to_int    <= d.fp_conv_to_int;
        idex_d.fp_conv_is_32     <= d.fp_conv_is_32;
        idex_d.fp_conv_shift     <= d.fp_conv_shift;
        idex_d.fp_conv_int       <= d.fp_conv_int;
        idex_d.fp_cmp_zero       <= d.fp_cmp_zero;
        idex_d.fp_signal_all_nans<= d.fp_signal_all_nans;
        idex_d.fpcr              <= fpcr_state;
        idex_d.neon_valid        <= d.neon_valid;
        idex_d.neon_op           <= d.neon_op;
        idex_d.neon_size         <= d.neon_size;
        idex_d.neon_shift        <= d.neon_shift;
        idex_d.neon_wb_we        <= d.neon_wb_we;
        idex_d.neon_rd           <= d.neon_rd;
        idex_d.neon_operand_a    <= d.neon_operand_a;
        idex_d.neon_operand_b    <= d.neon_operand_b;
        idex_d.neon_mem_load     <= d.neon_mem_load;
        idex_d.neon_quad        <= d.neon_quad;
        idex_d.neon_mem_replicate <= d.neon_mem_replicate;
        idex_d.neon_fp_valid     <= d.neon_fp_valid;
        idex_d.neon_fp_op        <= d.neon_fp_op;
        idex_d.neon_fp_is_double <= d.neon_fp_is_double;
        idex_d.neon_fp_is_half   <= d.neon_fp_is_half;
        idex_d.neon_fp_rint_mode <= d.neon_fp_rint_mode;
        idex_d.neon_fp_quad      <= d.neon_fp_quad;
        idex_d.neon_fp_operand_c <= d.neon_fp_operand_c;
        idex_d.alu_op     <= d.alu_op;
        idex_d.is_32      <= d.is_32;
        idex_d.set_flags  <= d.set_flags;
        idex_d.operand_a  <= d.operand_a;
        idex_d.operand_b  <= d.operand_b;
        idex_d.operand_c  <= d.operand_c;
        idex_d.use_shift  <= d.use_shift;
        idex_d.shift_type <= d.shift_type;
        idex_d.shift_amt  <= d.shift_amt;
        idex_d.inv_b      <= d.inv_b;
        idex_d.ccmp_nzcv  <= d.ccmp_nzcv;
        idex_d.ccmp_taken <= d.ccmp_taken;
        idex_d.wb_sel     <= d.wb_sel;
        idex_d.wb_we      <= d.wb_we;
        idex_d.wb_rd      <= d.wb_rd;
        idex_d.wb_extra   <= d.wb_extra;
        idex_d.sp_we      <= d.sp_we;
        idex_d.next_pc    <= d.next_pc;
        idex_d.is_load    <= d.is_load;
        idex_d.is_store   <= d.is_store;
        idex_d.is_pair    <= d.is_pair;
        idex_d.is_ldxr    <= d.is_ldxr;
        idex_d.is_stxr    <= d.is_stxr;
        idex_d.is_clrex   <= d.is_clrex;
        idex_d.is_atomic  <= d.is_atomic;
        idex_d.atomic_op  <= d.atomic_op;
        idex_d.atomic_cmp <= d.atomic_cmp;
        idex_d.atomic_cmp2 <= d.atomic_cmp2;
        idex_d.mem_size   <= d.mem_size;
        idex_d.ldr_sw     <= d.ldr_sw;
        idex_d.ldr_x      <= d.ldr_x;
        idex_d.mem_addr   <= d.mem_addr;
        idex_d.mem_wdata  <= d.mem_wdata;
        idex_d.mem_wdata2 <= d.mem_wdata2;
        idex_d.mem_strb   <= d.mem_strb;
        idex_d.mem_paddr  <= (mmu_en && (d.is_load || d.is_store))
                             ? trans_paddr_r : d.mem_addr;
        // mem_paddr2 不再由 live ID/EX next-state 组合路径产生。保留
        // ex_pipe_t 字段作为兼容 payload，但 PA2 在 EX/MEM 从匹配的
        // 已寄存 mem_paddr（PA1）纯推导为 +8。合法自然对齐的 16B
        // d_mem128 不跨页；GPR pair/LDXP/STXP 的跨页第二翻译与
        // all-or-nothing 限制属于 batch 前既有语义，本 lane 不扩项。
        idex_d.mem_paddr2 <= 64'd0;
        // P6：MMU 关闭时 MMIO 访问强制不可缓存（bypass L1/L2）
        idex_d.mem_cacheable <= (mmu_en && (d.is_load || d.is_store))
                                ? trans_cacheable_r
                                : (d.is_load || d.is_store) &&
                                  ((d.mem_addr >= MMIO_BASE &&
                                   d.mem_addr < MMIO_TOP) ||
                                   (d.mem_addr >= MMIO2_BASE &&
                                    d.mem_addr < MMIO2_TOP) ||
                                   (d.mem_addr >= MMIO3_BASE &&
                                    d.mem_addr < MMIO3_TOP) ||
                                   (d.mem_addr >= MMIO4_BASE &&
                                    d.mem_addr < MMIO4_TOP))
                                  ? 1'b0 : 1'b1;
        idex_d.mem_cacheable2 <= (mmu_en && d_mem128)
                                 ? trans_cacheable2_r
                                 : (d.is_load || d.is_store) &&
                                   ((d.mem_addr >= MMIO_BASE &&
                                     d.mem_addr < MMIO_TOP) ||
                                    (d.mem_addr >= MMIO2_BASE &&
                                     d.mem_addr < MMIO2_TOP) ||
                                    (d.mem_addr >= MMIO3_BASE &&
                                     d.mem_addr < MMIO3_TOP) ||
                                    (d.mem_addr >= MMIO4_BASE &&
                                     d.mem_addr < MMIO4_TOP))
                                   ? 1'b0 : 1'b1;
        idex_d.sys_op  <= d.sys_op;
        idex_d.sys_reg <= d.sys_reg;
        idex_d.wb2_rd     <= d.wb2_rd;
        idex_d.wb2_we     <= d.wb2_we;
        idex_d.wb2_extra  <= d.wb2_extra;
        idex_d.wb3_we     <= d.wb3_we;
        idex_d.wb3_rd     <= d.wb3_rd;
        idex_d.wb3_extra  <= d.wb3_extra;
      end

      // ---- M1-B：dmem 数据请求/响应状态（针对当前 EX/MEM load/store）----
      if (dmem_req_accept) begin
        dmem_req_issued <= 1'b1;
      end
      if (dmem_rsp_valid && dmem_rsp_ready && dmem_req_issued) begin
        dmem_req_issued <= 1'b0;
        if (dmem_rsp.fault) begin
          exmem_exc <= 1'b1;   // 响应 fault：EX/MEM 指令提交为 DABT
          dmem_done <= 1'b1;   // 事务终止（STXR 不再发条件写）
          stxr_read_phase <= 1'b0;
          atomic_read_phase <= 1'b0;
          atomic_phase <= 2'd0;
          stxp_cmp_hi     <= 1'b0;
          exmem_atomic_store <= 1'b0;
        end else if (exmem_is_atomic && is_atomic128_pair(exmem_atomic_op)) begin
          // LSE128 四阶段事务：低/高半先读，随后低/高半写。
          // CASP 需要比较两半；LDCLRP/LDSETP/SWPP 无条件进入写阶段。
          unique case (atomic_phase)
            2'd0: begin
              exmem_rdata_r <= dmem_rsp.rdata;
              atomic_phase <= 2'd1;
            end
            2'd1: begin
              exmem_rdata2_r <= dmem_rsp.rdata;
              if ((exmem_atomic_op != ATOMIC_CASP) ||
                  ((exmem_rdata_r == exmem_atomic_cmp) &&
                   (dmem_rsp.rdata == exmem_atomic_cmp2))) begin
                atomic_phase <= 2'd2;
                exmem_atomic_store <= 1'b1;
              end else begin
                dmem_done <= 1'b1;
                exmem_atomic_store <= 1'b0;
              end
            end
            2'd2: atomic_phase <= 2'd3;
            default: dmem_done <= 1'b1;
          endcase
        end else if (exmem_is_atomic && atomic_read_phase) begin
          // LSE：锁存旧值。LDADD 无条件进入写阶段；CAS 仅在
          // 期望值相等时进入写阶段，否则事务在读响应处完成。
          exmem_rdata_r <= dmem_rsp.rdata;
          if (exmem_atomic_op == ATOMIC_CAS) begin
            if ((dmem_rsp.rdata & size_mask(exmem_mem_size)) ==
                (exmem_atomic_cmp & size_mask(exmem_mem_size))) begin
              atomic_read_phase <= 1'b0;
              exmem_atomic_store <= 1'b1;
            end else begin
              atomic_read_phase <= 1'b0;
              dmem_done <= 1'b1;
              exmem_atomic_store <= 1'b0;
            end
          end else begin
            atomic_read_phase <= 1'b0;
            exmem_atomic_store <= 1'b1;
          end
        end else if (exmem_is_atomic) begin
          // 原子写响应完成，旧值已在 exmem_rdata_r 中等待 WB。
          dmem_done <= 1'b1;
        end else if (exmem_is_stxr && stxr_read_phase) begin
          // STXR/STXP 读比较阶段：地址相等且内存当前值（按宽度截取）
          // 与 LDXR/LDXP 记录值相等才进入写阶段；否则结果=1 直接完成。
          // STXP 为 128 位比较：低半匹配后继续读高半再比较。
          exmem_rdata_r <= dmem_rsp.rdata;
          if (excl_valid && (exmem_mem_addr == excl_addr) &&
              ((dmem_rsp.rdata & size_mask(exmem_mem_size)) ==
               ((exmem_is_pair && stxp_cmp_hi ? excl_data_hi : excl_data)
                & size_mask(exmem_mem_size)))) begin
            if (exmem_is_pair && !stxp_cmp_hi) begin
              stxp_cmp_hi <= 1'b1;   // 低半匹配：继续读高半
            end else if (exmem_is_pair) begin
              stxr_read_phase <= 1'b0;   // 高半也匹配：进入条件写
              exmem_stxr_pass <= 1'b1;
            end else begin
              stxr_read_phase <= 1'b0;   // 通过：下一拍发条件写
              exmem_stxr_pass <= 1'b1;
            end
          end else begin
            dmem_done <= 1'b1;
            exmem_stxr_result <= 1'b1;  // 失败：不写内存
          end
        end
        else if (exmem_is_pair && !pair_part) begin
          // 第一段完成：登记 rdata（LDP rt），发第二段
          if (exmem_is_load) begin
            exmem_rdata_r <= dmem_rsp.rdata;
          end
          pair_part <= 1'b1;
        end else begin
          // 第二段（或单段）完成
          dmem_done <= 1'b1;
          pair_part <= 1'b0;
          if (exmem_is_load) begin
            if (exmem_is_pair) begin
              exmem_rdata2_r <= dmem_rsp.rdata;   // LDP rt2
            end else begin
              exmem_rdata_r <= dmem_rsp.rdata;
            end
          end
          if (exmem_is_stxr) begin
            exmem_stxr_result <= 1'b0;   // 条件写已接受：通过
          end
        end
      end
      // 合并提交或普通 IRQ 冲刷 EX/MEM：清除未完成的数据事务（防遗留
      // 响应错配）。IRQ 的 older MEM/WB 条目仍在下方提交；这里仅清除
      // younger EX/MEM transaction。
      if (irq_taken || fetch_merge_wb || sys_commit || wb_exc_commit) begin
        dmem_req_issued <= 1'b0;
        dmem_done       <= 1'b0;
        exmem_exc       <= 1'b0;
        exmem_rdata_r   <= 64'd0;
        exmem_rdata2_r  <= 64'd0;
        pair_part       <= 1'b0;
        exmem_atomic_store <= 1'b0;
        exmem_stxr_result  <= 1'b0;
        stxr_read_phase <= 1'b0;
        atomic_read_phase <= 1'b0;
        atomic_phase <= 2'd0;
        stxp_cmp_hi     <= 1'b0;
        exmem_stxr_pass <= 1'b0;
      end

      // ---- EX/MEM（乘除未完成/翻译请求/遍历中冻结，完成后捕获结果）----
      // 注意：数据侧翻译请求被接受时也必须冻结 EX/MEM，否则 ID/EX 保持的同一条
      // 指令会被 EX/MEM 再捕获一次（相邻两级同驻，导致重复提交）。
      if (irq_taken || fetch_merge_wb || wb_exc_commit ||
          (fp_tx_kill && exmem_fp_valid && !exmem_is_load && !exmem_is_store)) begin
        exmem_valid <= 1'b0;      // 合并/DABT/FP transaction kill：冲刷 EX/MEM
        exmem_token_epoch <= '0;
        exmem_token_seq   <= 16'd0;
        exmem_mem_paddr2 <= 64'd0;
      end else if (data_trans_active || atomic128_second_needed ||
                   fetch_walk || data_mmu_issue ||
                   dmem_pending) begin
        ;                         // 翻译请求/遍历/数据响应等待：EX/MEM 冻结
      end else if (exmem_valid && !exmem_can_adv) begin
        ;                         // WB 满且消费者忙：EX/MEM 保持
      end else if (idex_valid && fp_tx_candidate && !fp_consume) begin
        // FP transaction 未完成握手：不能把 ID/EX 的 FP 捕获进 EX/MEM。
        // rsp_valid 但 EX/MEM 尚不可接收时也必须留在这里，不能绕过
        // fp_rsp_ready。若 EX/MEM 已有更老的指令且本拍可推进到 MEM/WB，
        // 则让它离开 EX/MEM，避免同一指令同时驻留 EX/MEM 与 MEM/WB。
        if (exmem_valid && exmem_can_adv) begin
          exmem_valid      <= 1'b0;
          exmem_token_epoch <= '0;
          exmem_token_seq   <= 16'd0;
        end
      end else begin
        exmem_valid    <= is_muldiv ? muldiv_done : idex_valid;
        if (idex_valid && (!is_muldiv || muldiv_done)) begin
          exmem_token_epoch <= idex_token_epoch;
          exmem_token_seq   <= idex_token_seq;
          dbg_idex_to_exmem_fire <= 1'b1;
        end else begin
          exmem_token_epoch <= '0;
          exmem_token_seq   <= 16'd0;
        end
        exmem_insn     <= idex_insn;
        exmem_pc       <= idex_pc;
        exmem_next_pc  <= idex_d.next_pc;
        exmem_wdata    <= ex_wdata;
        exmem_wb_we    <= idex_d.wb_we;
        exmem_wb_rd    <= idex_d.wb_rd;
        exmem_sp_we    <= idex_d.sp_we;
        // 访存型 pre/post 的 SP 更新直接采用解码值（非 ALU 结果）。
        // ADD/SUB SP 也使用 sp_we，但其结果来自 ALU，不能被 zero
        // wb3_extra 覆盖。
        exmem_sp_wdata <= (idex_d.sp_we &&
                           (idex_d.is_load || idex_d.is_store))
                          ? idex_d.wb3_extra : ex_sp_wdata;
        exmem_nzcv_we  <= idex_d.set_flags;
        exmem_nzcv     <= ex_nzcv;
        exmem_is_load  <= idex_d.is_load;
        exmem_is_store <= idex_d.is_store;
        exmem_is_pair  <= idex_d.is_pair;
        exmem_is_ldxr  <= idex_d.is_ldxr;
        exmem_is_stxr  <= idex_d.is_stxr;
        exmem_is_clrex <= idex_d.is_clrex;
        exmem_is_atomic <= idex_d.is_atomic;
        exmem_atomic_op <= idex_d.atomic_op;
        exmem_atomic_cmp <= idex_d.atomic_cmp;
        exmem_atomic_cmp2 <= idex_d.atomic_cmp2;
        exmem_atomic_store <= idex_d.is_atomic &&
                              (idex_d.atomic_op != ATOMIC_CAS) &&
                              (idex_d.atomic_op != ATOMIC_CASP);
        stxr_read_phase <= idex_d.is_stxr;
        atomic_read_phase <= idex_d.is_atomic &&
                             !idex_d.is_pair &&
                             (idex_d.atomic_op != ATOMIC_CASP);
        atomic_phase <= 2'd0;
        stxp_cmp_hi     <= 1'b0;
        exmem_stxr_pass <= 1'b0;
        exmem_stxr_result <= 1'b0;
        exmem_mem_size <= idex_d.mem_size;
        exmem_ldr_sw   <= idex_d.ldr_sw;
        exmem_ldr_x    <= idex_d.ldr_x;
        exmem_mem_addr <= idex_d.mem_addr;
        exmem_mem_wdata<= idex_d.mem_wdata;
        exmem_mem_wdata2 <= idex_d.mem_wdata2;
        exmem_mem_strb <= idex_d.mem_strb;
        exmem_mem_paddr<= idex_d.mem_paddr;
        // 同页 pair/128 的高半 PA 从已寄存的 PA1 推导，打断
        // ID/EX live valid/decode -> mem_paddr2 enable 扇出被切断：所有
        // pair 高半 payload 纯由匹配的已寄存 PA1 推导为 +8；W pair 的
        // dmem 请求偏移继续由下面的 mem_size 选择固定为 +4。
        if (idex_valid && idex_d.is_pair) begin
          exmem_mem_paddr2 <= idex_d.mem_paddr + 64'd8;
        end else begin
          exmem_mem_paddr2 <= 64'd0;
        end
        exmem_mem_cacheable <= idex_d.mem_cacheable;
        exmem_mem_cacheable2 <= idex_d.mem_cacheable2;
        // Scalar FP and P7-3 vector FP share the FP state effect slots;
        // integer NEON remains on its independent effect path.
        exmem_fp_valid <= idex_d.fp_valid || idex_d.neon_fp_valid;
        exmem_fp_is_double <= idex_d.fp_valid
                              ? idex_d.fp_is_double
                              : idex_d.neon_fp_is_double;
        exmem_fp_wb_we <= idex_d.fp_valid
                          ? idex_d.fp_wb_we : idex_d.neon_wb_we;
        exmem_fp_rd <= idex_d.fp_valid ? idex_d.fp_rd : idex_d.neon_rd;
        exmem_fp_mem_load <= idex_d.fp_valid && idex_d.is_load;
        exmem_fp_wdata <= fp_tx_candidate ? fp_rsp.v_data : 128'd0;
        exmem_fp_fpsr_wdata <= fp_tx_candidate ? fp_rsp.fpsr_flags : 32'd0;
        exmem_fp_fpsr_we <= fp_tx_candidate ? fp_rsp.fpsr_we : 1'b0;
        exmem_neon_valid <= idex_d.neon_valid && !idex_d.neon_fp_valid;
        exmem_neon_wb_we <= idex_d.neon_wb_we;
        exmem_neon_rd <= idex_d.neon_rd;
        exmem_neon_mem_load <= idex_d.neon_mem_load;
        exmem_neon_quad <= idex_d.neon_quad;
        exmem_neon_mem_replicate <= idex_d.neon_mem_replicate;
        exmem_neon_wdata <= neon_ex_wdata;
        exmem_wb2_rd   <= idex_d.wb2_rd;
        exmem_wb2_we   <= idex_d.wb2_we;
        exmem_wb2_extra <= idex_d.wb2_extra;
        exmem_wb3_we   <= idex_d.wb3_we;
        exmem_wb3_rd   <= idex_d.wb3_rd;
        exmem_wb3_extra <= idex_d.wb3_extra;
        exmem_exc      <= 1'b0;   // 新指令：无响应 fault
        dmem_done      <= 1'b0;   // 新指令：无未完成事务
        pair_part      <= 1'b0;
      end

      // ---- MEM/WB（翻译请求/遍历/数据事务中冻结，其余始终推进）----
      if (irq_taken || fetch_merge_wb || wb_exc_commit) begin
        memwb_valid <= 1'b0;      // 合并提交：冲刷 MEM/WB
        memwb_committed_r <= 1'b0;
        memwb_token_epoch <= '0;
        memwb_token_seq   <= 16'd0;
      end else if (data_trans_active || atomic128_second_needed ||
                   fetch_walk || data_mmu_issue ||
                   dmem_pending) begin
        ;                         // 翻译请求/遍历/数据事务：MEM/WB 冻结
      end else if (stall_wb) begin
        ;                         // 提交消费者忙：WB 保持（不覆盖）
      end else begin
        memwb_valid     <= exmem_valid;
        memwb_committed_r <= 1'b0;  // 新条目未提交（弹出或填充）
        if (exmem_valid) begin
          memwb_token_epoch <= exmem_token_epoch;
          memwb_token_seq   <= exmem_token_seq;
          dbg_exmem_to_memwb_fire <= 1'b1;
        end else begin
          memwb_token_epoch <= '0;
          memwb_token_seq   <= 16'd0;
        end
        memwb_rdata_r   <= exmem_rdata_r;
        memwb_rdata2_r  <= exmem_rdata2_r;
        memwb_exc       <= exmem_exc;
        memwb_insn      <= exmem_insn;
        memwb_pc        <= exmem_pc;
        memwb_next_pc   <= exmem_next_pc;
        memwb_wdata     <= exmem_wdata;
        memwb_wb_we     <= exmem_wb_we;
        memwb_wb_rd     <= exmem_wb_rd;
        memwb_sp_we     <= exmem_sp_we;
        memwb_sp_wdata  <= exmem_sp_wdata;
        memwb_nzcv_we   <= exmem_nzcv_we;
        memwb_nzcv      <= exmem_nzcv;
        memwb_is_load   <= exmem_is_load;
        memwb_mem_size  <= exmem_mem_size;
        memwb_ldr_sw    <= exmem_ldr_sw;
        memwb_ldr_x     <= exmem_ldr_x;
        memwb_is_store  <= exmem_is_store &&
                           (!exmem_is_atomic || exmem_atomic_store);
        memwb_is_pair   <= exmem_is_pair;
        memwb_fp_valid <= exmem_fp_valid;
        memwb_fp_wb_we <= exmem_fp_wb_we;
        memwb_fp_rd <= exmem_fp_rd;
        memwb_fp_wdata <= exmem_fp_mem_load
                          ? (exmem_fp_is_double
                             ? {64'd0, exmem_rdata_r}
                             : {96'd0, exmem_rdata_r[31:0]})
                          : exmem_fp_wdata;
        memwb_fp_fpsr_wdata <= exmem_fp_fpsr_wdata;
        memwb_fp_fpsr_we <= exmem_fp_fpsr_we;
        memwb_neon_valid <= exmem_neon_valid;
        memwb_neon_wb_we <= exmem_neon_wb_we;
        memwb_neon_rd <= exmem_neon_rd;
        if (exmem_neon_mem_load && exmem_neon_mem_replicate) begin
          // B2c LD1R: one memory element of mem_size width is replicated to
          // every active lane. Q=0 leaves the upper 64 bits zero.
          logic [127:0] wb_neon_data;
          logic [63:0] elem;
          integer lanes;
          elem = exmem_rdata_r;
          if (exmem_mem_size == 2'd0) elem = {56'd0, exmem_rdata_r[7:0]};
          else if (exmem_mem_size == 2'd1) elem = {48'd0, exmem_rdata_r[15:0]};
          else if (exmem_mem_size == 2'd2) elem = {32'd0, exmem_rdata_r[31:0]};
          lanes = (exmem_mem_size == 2'd0) ? (exmem_neon_quad ? 16 : 8)
                : (exmem_mem_size == 2'd1) ? (exmem_neon_quad ? 8 : 4)
                : (exmem_mem_size == 2'd2) ? (exmem_neon_quad ? 4 : 2)
                : (exmem_neon_quad ? 2 : 1);
          wb_neon_data = 128'd0;
          // Quartus static elaboration checks the fixed loop bounds, so the
          // 64-bit lane case is written separately instead of producing an
          // out-of-range part-select for unrolled i >= 2.
          unique case (exmem_mem_size)
            2'd0: begin
              for (int i = 0; i < 16; i++) begin
                if (i < lanes) wb_neon_data[i*8 +: 8] = elem[7:0];
              end
            end
            2'd1: begin
              for (int i = 0; i < 8; i++) begin
                if (i < lanes) wb_neon_data[i*16 +: 16] = elem[15:0];
              end
            end
            2'd2: begin
              for (int i = 0; i < 4; i++) begin
                if (i < lanes) wb_neon_data[i*32 +: 32] = elem[31:0];
              end
            end
            default: begin
              wb_neon_data[63:0] = elem;
              if (exmem_neon_quad) wb_neon_data[127:64] = elem;
            end
          endcase
          memwb_neon_wdata <= wb_neon_data;
        end else begin
          memwb_neon_wdata <= exmem_neon_mem_load
                              ? {exmem_rdata2_r, exmem_rdata_r}
                              : exmem_neon_wdata;
        end
        memwb_is_ldxr   <= exmem_is_ldxr;
        memwb_is_stxr   <= exmem_is_stxr;
        memwb_is_clrex  <= exmem_is_clrex;
        memwb_stxr_result <= exmem_stxr_result;
        memwb_stxr_fail <= exmem_is_stxr && !exmem_stxr_pass;
        memwb_mem_addr  <= exmem_mem_addr;
        memwb_mem_wdata <= exmem_is_atomic ? exmem_atomic_new
                                            : exmem_mem_wdata;
        memwb_mem_wdata2 <= (exmem_is_atomic && is_atomic128_pair(exmem_atomic_op))
                            ? exmem_atomic_new2 : exmem_mem_wdata2;
        memwb_mem_strb  <= exmem_mem_strb;
        memwb_wb2_rd    <= exmem_wb2_rd;
        memwb_wb2_we    <= exmem_wb2_we;
        memwb_wb2_extra <= exmem_wb2_extra;
        memwb_wb3_we    <= exmem_wb3_we;
        memwb_wb3_rd    <= exmem_wb3_rd;
        memwb_wb3_extra <= exmem_wb3_extra;
      end

      // ---- WB/COMMIT（架构状态只在提交更新）----
      commit_valid_r <= 1'b0;
      commit_token_epoch <= '0;
      commit_token_seq   <= 16'd0;
      // FP effect fields are per-commit and must not leak from an older
      // system/vector commit into a scalar PRE/COMMIT packet.
      commit_vec_write_count_r <= 3'd0;
      commit_vec_rd0_r <= 5'd0;
      commit_vec_rd1_r <= 5'd0;
      commit_vec_rd2_r <= 5'd0;
      commit_vec_rd3_r <= 5'd0;
      commit_vec_wdata0_r <= 128'd0;
      commit_vec_wdata1_r <= 128'd0;
      commit_vec_wdata2_r <= 128'd0;
      commit_vec_wdata3_r <= 128'd0;
      commit_fpcr_we_r <= 1'b0;
      commit_fpcr_wdata_r <= 32'd0;
      commit_fpsr_we_r <= 1'b0;
      commit_fpsr_wdata_r <= 32'd0;
      if (wfi_irq_take) begin
        // WFI/WFE 已经正常退休并进入 idle；IRQ 唤醒时产生一个合成的
        // 异步异常提交，PC/insn 仍指向等待指令，next_pc 为 IRQ 向量。
        commit_valid_r     <= 1'b1;
        dbg_commit_fire    <= 1'b1;
        commit_pc_r        <= wfi_pc_r;
        commit_next_pc_r   <= irq_vector_core;
        commit_insn_r      <= wfi_insn_r;
        commit_gpr_we_r    <= 1'b0;
        commit_gpr_rd_r    <= 5'd0;
        commit_gpr_wdata_r <= 64'd0;
        commit_gpr2_we_r   <= 1'b0;
        commit_gpr2_rd_r   <= 5'd0;
        commit_gpr2_wdata_r <= 64'd0;
        commit_gpr3_we_r   <= 1'b0;
        commit_gpr3_rd_r   <= 5'd0;
        commit_gpr3_wdata_r <= 64'd0;
        commit_sp_we_r     <= 1'b1;
        commit_sp_wdata_r  <= sp_el1;
        commit_nzcv_we_r   <= 1'b1;
        commit_nzcv_r      <= 4'b0000;
        commit_mem_we_r    <= 1'b0;
        commit_mem_addr_r  <= 64'd0;
        commit_mem_wdata_r <= 64'd0;
        commit_mem_strb_r  <= 8'd0;
        commit_mem2_we_r   <= 1'b0;
        commit_mem2_addr_r <= 64'd0;
        commit_mem2_wdata_r <= 64'd0;
        commit_mem2_strb_r <= 8'd0;
        commit_exc_valid_r <= 1'b1;
        commit_exc_code_r  <= EXC_IRQ;
        commit_exc_esr_r   <= 32'd0;
        commit_exc_far_r   <= 64'd0;
        commit_mon_we_r    <= 1'b0;
        commit_mon_valid_r <= 1'b0;
        commit_mon_addr_r  <= 64'd0;
        commit_mon_data_r  <= 64'd0;
        commit_mon_data2_r <= 64'd0;
        elr_el1           <= wfi_pc_r + 64'd4;
        spsr_el1          <= make_spsr(nzcv, daif, el, sp_sel,
                                       pstate_pan, pstate_dit,
                                       pstate_ssbs, pstate_uao, pstate_tco,
                                       pstate_allint);
        el                <= 1'b1;
        sp_sel            <= 1'b1;
        daif              <= 4'b1111;
        pstate_allint     <= !sctlr_el1[62];
        nzcv              <= 4'b0000;
        wfi_idle          <= 1'b0;
      end else if (sys_commit) begin
        // ---- 系统指令（异常/ERET/MSR）ID 级提交 ----
        // 前方流水线已排空（更老指令全部提交），本指令在此提交并重定向。
        commit_valid_r     <= 1'b1;
        commit_token_epoch <= ifid_token_epoch;
        commit_token_seq   <= ifid_token_seq;
        dbg_commit_fire    <= 1'b1;
        commit_pc_r        <= ifid_pc;
        commit_next_pc_r   <= sys_next_pc;
        commit_insn_r      <= ifid_insn;
        commit_gpr_we_r    <= 1'b0;
        commit_gpr_rd_r    <= 5'd0;
        commit_gpr_wdata_r <= 64'd0;
        commit_gpr2_we_r   <= 1'b0;
        commit_gpr2_rd_r   <= 5'd0;
        commit_gpr2_wdata_r <= 64'd0;
        commit_gpr3_we_r   <= 1'b0;
        commit_gpr3_rd_r   <= 5'd0;
        commit_gpr3_wdata_r <= 64'd0;
        commit_mem_we_r    <= 1'b0;
        commit_mem_addr_r  <= 64'd0;
        commit_mem_wdata_r <= 64'd0;
        commit_mem_strb_r  <= 8'd0;
        commit_mem2_we_r   <= 1'b0;
        commit_mem2_addr_r <= 64'd0;
        commit_mem2_wdata_r <= 64'd0;
        commit_mem2_strb_r  <= 8'd0;
        commit_exc_valid_r <= sys_exc;
        commit_exc_code_r  <= sys_exc_code;
        commit_exc_esr_r   <= sys_exc ? sys_exc_esr : 32'd0;
        commit_exc_far_r   <= sys_exc ? sys_exc_far : 64'd0;
        // 默认：系统指令不改监视器（SVC/UDEF/IABT/DABT/MSR 均不清；
        // A profile 异常入口不清监视器，与 QEMU 实测一致）。
        commit_mon_we_r    <= 1'b0;
        commit_mon_valid_r <= 1'b0;
        commit_mon_addr_r  <= 64'd0;
        commit_mon_data_r  <= 64'd0;
        commit_mon_data2_r <= 64'd0;
        // FPCR/FPSR MSR is an ID-level system commit.  Capture only the
        // accepted write so a denied FP access has no FP effect sideband.
        commit_fpcr_we_r    <= sys_fpcr_write_accept;
        commit_fpcr_wdata_r <= sys_fpcr_write_accept
                               ? (d.sys_wdata[31:0] & FPCR_P7_WRMASK) : 32'd0;
        commit_fpsr_we_r    <= sys_fpsr_write_accept;
        commit_fpsr_wdata_r <= sys_fpsr_write_accept
                               ? (d.sys_wdata[31:0] & FPSR_P7_WRMASK) : 32'd0;
        if (sys_exc) begin
          // 异常入口：保存 ELR/SPSR，PSTATE -> EL1h + DAIF 全置位，
          // NZCV=0（QEMU pstate_write(PSTATE_DAIF|new_mode) 行为）
          // A translation-context MSR still takes architectural effect when
          // its post-write next fetch faults.  The fetch fault is merged into
          // this same MSR commit; do not lose the register write merely
          // because the exception side of the packet is also asserted.
          if (sys_fetch_context_msr_merge) begin
            unique case (d.sys_reg)
              SREG_SCTLR_EL1: sctlr_el1 <= d.sys_wdata & SCTLR_EL1_WRITE_MASK;
              SREG_TCR_EL1:   tcr_el1   <= d.sys_wdata;
              SREG_TTBR0_EL1: ttbr0_el1 <= d.sys_wdata;
              SREG_TTBR1_EL1: ttbr1_el1 <= d.sys_wdata;
              SREG_MAIR_EL1:  mair_el1  <= d.sys_wdata;
              default:        ;
            endcase
          end
          elr_el1  <= sys_exc_elr;
          if (d.sys_op == SYS_ERET && sys_fetch_merge) begin
            // ERET 目标取指 fault：异常发生在 ERET 完成之后、目标 EL
            // 的取指阶段，SPSR 保存 ERET 恢复后的 PSTATE（QEMU 语义）。
            spsr_el1 <= make_spsr(spsr_el1[31:28], spsr_el1[9:6],
                                  spsr_el1[2], spsr_el1[0],
                                  spsr_el1[22], spsr_el1[24],
                                  spsr_el1[12], spsr_el1[23],
                                  spsr_el1[25], spsr_el1[13]);
          end else begin
            spsr_el1 <= make_spsr(nzcv, daif, el, sp_sel,
                                  pstate_pan, pstate_dit,
                                  pstate_ssbs, pstate_uao, pstate_tco,
                                  pstate_allint);
          end
          el       <= 1'b1;
          sp_sel   <= 1'b1;
          daif     <= 4'b1111;
          // QEMU pstate_write(PSTATE_DAIF|new_mode)：入口后 PSTATE 的
          // PAN/DIT 等其它位清零（保存值已在 SPSR 中）。
          pstate_pan <= 1'b0;
          pstate_dit <= 1'b0;
          pstate_ssbs <= 1'b0;
          pstate_uao <= 1'b0;
          pstate_tco <= 1'b0;
          pstate_allint <= !sctlr_el1[62];
          nzcv     <= 4'b0000;
          esr_el1  <= sys_exc_esr;
          far_el1  <= sys_exc_far;
          commit_sp_we_r    <= 1'b1;
          commit_sp_wdata_r <= sp_el1;
          commit_nzcv_we_r  <= 1'b1;
          commit_nzcv_r     <= 4'b0000;
        end else if (d.sys_op == SYS_ERET) begin
          if (elr_el1[1:0] != 2'b00) begin
            // QEMU 对 ERET 到未对齐 PC 报 EC=0x22，而不是 IABT。
            commit_sp_we_r     <= 1'b1;
            commit_sp_wdata_r  <= sp_el1;
            commit_nzcv_we_r   <= 1'b1;
            commit_nzcv_r      <= 4'b0000;
            commit_exc_valid_r <= 1'b1;
            commit_exc_code_r  <= EXC_PC_ALIGN;
            commit_exc_esr_r   <= 32'h8a00_0000;
            commit_exc_far_r   <= elr_el1;
            el       <= 1'b1;
            sp_sel   <= 1'b1;
            daif     <= 4'b1111;
            nzcv     <= 4'b0000;
            esr_el1  <= 32'h8a00_0000;
            far_el1  <= elr_el1;
          end else if (!mmu_en && (elr_el1 < SRAM_BASE || elr_el1 >= SRAM_TOP)) begin
            // ERET 目标越界：合并为指令异常。ELR/SPSR 保持（ELR 已是
            // 目标地址，SPSR 即 ERET 恢复后的 PSTATE），入口偏移按
            // ERET 恢复后的 EL/SP 计算。
            commit_sp_we_r     <= 1'b1;
            commit_sp_wdata_r  <= sp_el1;
            commit_nzcv_we_r   <= 1'b1;
            commit_nzcv_r      <= 4'b0000;
            commit_exc_valid_r <= 1'b1;
            commit_exc_code_r  <= spsr_el1[2] ? EXC_IABORT_SAME_EL
                                              : EXC_IABORT;
            commit_exc_esr_r   <= abort_esr(spsr_el1[2] ? 6'h21 : 6'h20,
                                            1'b0,
                                            (elr_el1[63:48] != 0)
                                            ? 6'd0 : 6'h10);
            commit_exc_far_r   <= elr_el1;
            esr_el1  <= abort_esr(spsr_el1[2] ? 6'h21 : 6'h20, 1'b0,
                                  (elr_el1[63:48] != 0) ? 6'd0 : 6'h10);
            far_el1  <= elr_el1;
            el       <= 1'b1;
            sp_sel   <= 1'b1;
            daif     <= 4'b1111;
            nzcv     <= 4'b0000;
          end else begin
            // ERET：从 SPSR_EL1 恢复 PSTATE/SP，跳转 ELR_EL1
            el       <= spsr_el1[2];
            sp_sel   <= spsr_el1[0];
            daif     <= spsr_el1[9:6];
            pstate_pan <= spsr_el1[22];
            pstate_dit <= spsr_el1[24];
            pstate_ssbs <= spsr_el1[12];
            pstate_uao <= spsr_el1[23];
            pstate_tco <= spsr_el1[25];
            pstate_allint <= spsr_el1[13];
            nzcv     <= spsr_el1[31:28];
            commit_sp_we_r     <= 1'b1;
            // SP 银行由 SPSR.SP（bit0）选择，不是 EL（spsr[2]）：
            // EL1t（SP=0）ERET 后可见 SP 是 sp_el0。
            commit_sp_wdata_r  <= spsr_el1[0] ? sp_el1 : sp_el0;
            commit_nzcv_we_r   <= 1'b1;
            commit_nzcv_r      <= spsr_el1[31:28];
            commit_exc_valid_r <= 1'b0;
            commit_exc_code_r  <= 32'd0;
            commit_exc_esr_r   <= 32'd0;
            commit_exc_far_r   <= 64'd0;
          end
        end else if (d.sys_op inside {SYS_WFI, SYS_WFE, SYS_SEV, SYS_SEVL,
                                      SYS_WFIT, SYS_WFET}) begin
          // 等待/事件指令自身正常退休。WFET 若事件寄存器已置位则消费
          // 事件并继续；WFIT/WFET 只有在 CNTVCT 尚未达到 Xt 时进入
          // idle，超时恢复不产生额外架构提交。
          commit_sp_we_r    <= 1'b0;
          commit_sp_wdata_r <= sp;
          commit_nzcv_we_r  <= 1'b0;
          commit_nzcv_r     <= nzcv;
          if (d.sys_op == SYS_WFI) begin
            wfi_idle   <= 1'b1;
            wfi_pc_r   <= ifid_pc;
            wfi_insn_r <= ifid_insn;
            wfi_timeout_valid <= 1'b0;
          end else if (d.sys_op == SYS_WFE) begin
            if (event_reg) begin
              event_reg <= 1'b0;
              wfi_timeout_valid <= 1'b0;
            end else begin
              wfi_idle   <= 1'b1;
              wfi_pc_r   <= ifid_pc;
              wfi_insn_r <= ifid_insn;
              wfi_timeout_valid <= 1'b0;
            end
          end else if (d.sys_op == SYS_WFIT) begin
            if (timer_count < d.sys_wdata) begin
              wfi_idle   <= 1'b1;
              wfi_pc_r   <= ifid_pc;
              wfi_insn_r <= ifid_insn;
              wfi_timeout_valid <= 1'b1;
              wfi_timeout_r <= d.sys_wdata;
            end else begin
              wfi_timeout_valid <= 1'b0;
            end
          end else if (d.sys_op == SYS_WFET) begin
            if (event_reg) begin
              event_reg <= 1'b0;
              wfi_timeout_valid <= 1'b0;
            end else if (timer_count < d.sys_wdata) begin
              wfi_idle   <= 1'b1;
              wfi_pc_r   <= ifid_pc;
              wfi_insn_r <= ifid_insn;
              wfi_timeout_valid <= 1'b1;
              wfi_timeout_r <= d.sys_wdata;
            end else begin
              wfi_timeout_valid <= 1'b0;
            end
          end else begin
            event_reg <= 1'b1;
            wfi_timeout_valid <= 1'b0;
          end
        end else begin
          // MSR：写系统寄存器（NZCV 写回同时上报）
          commit_sp_we_r    <= 1'b0;
          commit_sp_wdata_r <= sp;
          commit_nzcv_we_r  <= 1'b0;
          commit_nzcv_r     <= nzcv;
          unique case (d.sys_reg)
            SREG_VBAR_EL1:   vbar_el1  <= d.sys_wdata;
            SREG_ELR_EL1:    elr_el1   <= d.sys_wdata;
            SREG_SPSR_EL1:   spsr_el1  <= d.sys_wdata;
            // P6 当前仅实现 SCTLR 低 32 位中的标量控制；高位和 PAuth
            // EnIA/EnIB/EnDA/EnDB 均按固定 QEMU difftest 配置 WI。
            SREG_SCTLR_EL1:  sctlr_el1 <= d.sys_wdata &
                                           SCTLR_EL1_WRITE_MASK;
            SREG_TCR_EL1:    tcr_el1   <= d.sys_wdata;
            SREG_TTBR0_EL1:  ttbr0_el1 <= d.sys_wdata;
            SREG_TTBR1_EL1:  ttbr1_el1 <= d.sys_wdata;
            SREG_MAIR_EL1:   mair_el1  <= d.sys_wdata;
            SREG_ESR_EL1:    esr_el1   <= d.sys_wdata[31:0];
            SREG_FAR_EL1:    far_el1   <= d.sys_wdata;
            SREG_MDSCR_EL1:  mdscr_el1  <= d.sys_wdata;
            // QEMU pmuserenr_write：ARMv8 只保留低 4 位
            SREG_PMUSERENR_EL0: pmuserenr_el0 <= {60'd0, d.sys_wdata[3:0]};
            SREG_CNTKCTL_EL1:   cntkctl_el1  <= d.sys_wdata;
            // P6 Generic Timer（QEMU gt_* 语义）
            SREG_CNTP_CTL:  cntp_ctl_r  <= d.sys_wdata[1:0];
            SREG_CNTP_CVAL: cntp_cval_r <= d.sys_wdata;
            // TVAL 写：cval = count + sext32(value)（QEMU do_tval_write）
            SREG_CNTP_TVAL: cntp_cval_r <= timer_count +
                {{32{d.sys_wdata[31]}}, d.sys_wdata[31:0]};
            SREG_CNTV_CTL:  cntv_ctl_r  <= d.sys_wdata[1:0];
            SREG_CNTV_CVAL: cntv_cval_r <= d.sys_wdata;
            SREG_CNTV_TVAL: cntv_cval_r <= timer_count +
                {{32{d.sys_wdata[31]}}, d.sys_wdata[31:0]};
            SREG_TPIDR_EL0:     tpidr_el0    <= d.sys_wdata;
            SREG_TPIDR_EL1:     tpidr_el1    <= d.sys_wdata;
            SREG_CONTEXTIDR_EL1: contextidr_el1 <= d.sys_wdata;
            SREG_TPIDRRO_EL0:   tpidrro_el0  <= d.sys_wdata;
            // QEMU tcr2_el1_write：只保留 PIE|AIE|A2|FNG0|FNG1（-cpu max）
            SREG_TCR2_EL1:      tcr2_el1     <= d.sys_wdata & 64'h70012;
            SREG_SCTLR2_EL1:    ;             // P6 probe shim：RAZ/WI
            SREG_PAUTH_KEY:     ;             // P6 PAC key shim：RAZ/WI
            SREG_TPIDR2_EL0:    ;             // P6 SME probe shim：RAZ/WI
            // QEMU aa64_dit_write：寄存器形式取 bit24（与立即数
            // SYS_DIT 的 imm[0] 不对称）。
            SREG_DIT:           pstate_dit <= d.sys_wdata[24];
            SREG_SSBS:          pstate_ssbs <= d.sys_wdata[12];
            SREG_UAO:           pstate_uao <= d.sys_wdata[23];
            SREG_PAN:           pstate_pan <= d.sys_wdata[22];
            SREG_TCO:           pstate_tco <= d.sys_wdata[25];
            SREG_ALLINT:        pstate_allint <= d.sys_wdata[13];
            SREG_ISR_EL1:       ;             // P6 RAS shim：RAZ
            SREG_DISR_EL1:      ;             // P6 RAS shim：RAZ/WI
            SREG_PIR_EL1:       pir_el1      <= d.sys_wdata;
            SREG_PIRE0_EL1:     pire0_el1    <= d.sys_wdata;
            SREG_PAR_EL1:       par_el1      <= d.sys_wdata;
            // QEMU zcr_write：当前 P6 只保留 VL 编码低 4 位。
            SREG_ZCR_EL1:       zcr_el1      <= d.sys_wdata & 64'hf;
            // QEMU SME2 的 SMCR_EL1 保留 LEN[3:0] 与 FA64 bit31。
            SREG_SMCR_EL1:      smcr_el1     <= d.sys_wdata &
                                                   64'h0000_0000_8000_000F;
            // QEMU SMIDR_EL1.SMPS=0：SMPRI_EL1 写忽略（RES0）
            SREG_SMPRI_EL1:     ;
            SREG_SMIDR_EL1:     ;   // 只读 ID：写忽略（QEMU PL1_R）
            SREG_AIDR_EL1:      ;   // 只读 ID：写忽略（QEMU PL1_R）
            SREG_DBG_MONITOR_EL1: ; // P6 DBGB/DBGW[n] 关闭 shim：RAZ/WI
            SREG_RNDR, SREG_RNDRRS: ;  // 只读 RNG：写忽略（QEMU PL0_R）
            // QEMU csselr_write：只保留 Level[3:1]+Ind[0] 低 4 位
            SREG_CSSELR_EL1:    csselr_el1   <= d.sys_wdata & 64'hf;
            SREG_DAIF:          daif         <= d.sys_wdata[9:6];
            SREG_SCTLR_EL2:     ;             // el2 关闭：写忽略
            SREG_HCR_EL2:       ;
            SREG_VBAR_EL2:      ;
            SREG_SP_EL0:        sp_el0 <= d.sys_wdata;
            SREG_NZCV: begin
              // NZCV 位于 PSTATE/系统寄存器位域 [31:28]
              nzcv             <= d.sys_wdata[31:28];
              commit_nzcv_we_r <= 1'b1;
              commit_nzcv_r    <= d.sys_wdata[31:28];
            end
            default: ;
          endcase
          // MSR（immediate）：DAIFSet/DAIFClr 与 SPSel（P6）
          if (d.sys_op == SYS_DAIF) begin
            daif <= d.sys_wdata[4] ? (daif | d.sys_wdata[3:0])
                                   : (daif & ~d.sys_wdata[3:0]);
          end else if (d.sys_op == SYS_SPSEL) begin
            sp_sel <= d.sys_wdata[0];
            // SPSel 切换可见 SP：提交包上报新可见 SP（协调器 shadow）
            commit_sp_we_r    <= 1'b1;
            commit_sp_wdata_r <= d.sys_wdata[0] ? sp_el1 : sp_el0;
          end else if (d.sys_op == SYS_DIT) begin
            // PSTATE.DIT：Linux cpu_enable_dit 用 MSR DIT,#1 开启，
            // 异常入口需随 SPSR 保存（make_spsr bit24），否则 IRQ 后
            // 读回 SPSR_EL1 与 QEMU 差 1 bit。
            pstate_dit <= d.sys_wdata[0];
          end else if (d.sys_op == SYS_SSBS) begin
            // PSTATE.SSBS：Linux 为用户态默认置位（ssbs_thread_switch），
            // 异常入口随 SPSR 保存（bit12），否则 SPSR 与 QEMU 差 0x1000。
            pstate_ssbs <= d.sys_wdata[0];
          end else if (d.sys_op == SYS_TCO) begin
            pstate_tco <= d.sys_wdata[0];
          end else if (d.sys_op == SYS_UAO) begin
            pstate_uao <= d.sys_wdata[0];
          end else if (d.sys_op == SYS_PAN) begin
            pstate_pan <= d.sys_wdata[0];
          end else if (d.sys_op == SYS_ALLINT) begin
            pstate_allint <= d.sys_wdata[0];
          end
        end
        // ERET 执行本身清监视器（QEMU exception_return 先 clear 再
        // 取指），覆盖 ERET 成功、ERET 目标越界合并 IABT 与 ERET 后
        // 取指 fault（sys_fetch_merge）三种提交路径。
        if (d.sys_op == SYS_ERET) begin
          commit_mon_we_r    <= 1'b1;
          commit_mon_valid_r <= 1'b0;
          excl_valid <= 1'b0;
        end
        if (sys_irq_taken) begin
          // MSR DAIF/DAIFClr 等 ID 级系统指令提交后发生的 IRQ。异常
          // 属于该系统指令的 COMMIT：PC/insn 保持本条，ELR=顺序下一条，
          // SPSR 保存写后 DAIF，入口强制 EL1h + 全 DAIF mask + NZCV=0。
          commit_next_pc_r   <= irq_vector_core;
          commit_exc_valid_r <= 1'b1;
          commit_exc_code_r  <= EXC_IRQ;
          commit_exc_esr_r   <= 32'd0;
          commit_exc_far_r   <= 64'd0;
          elr_el1  <= d.next_pc;
          spsr_el1 <= make_spsr(nzcv, sys_daif_after, el, sp_sel,
                                pstate_pan, pstate_dit,
                                pstate_ssbs, pstate_uao, pstate_tco,
                                sys_allint_after);
          el       <= 1'b1;
          sp_sel   <= 1'b1;
          daif     <= 4'b1111;
          pstate_pan <= 1'b0;
          pstate_dit <= 1'b0;
          pstate_ssbs <= 1'b0;
          pstate_uao <= 1'b0;
          pstate_tco <= 1'b0;
          pstate_allint <= !sctlr_el1[62];
          nzcv     <= 4'b0000;
          wfi_idle <= 1'b0;
          // SPSel 的提交 SP 已在上面按新可见 SP 上报；其它 ID 级系统
          // 指令不改 SP，上报当前 sp_el1。
          if (d.sys_op != SYS_SPSEL) begin
            commit_sp_we_r    <= 1'b1;
            commit_sp_wdata_r <= sp_el1;
          end
          commit_nzcv_we_r  <= 1'b1;
          commit_nzcv_r     <= 4'b0000;
        end
      end else if (fetch_merge_wb) begin
        // ---- 取指 fault 合并：上一条指令的 next_pc 翻译失败。
        // 该指令已执行（保留 GPR/SP 写回），提交转为 IABT 异常
        // （QEMU 提交流语义：指令先退休，随后取指 fault 合并）----
        if (memwb_wb_we && memwb_wb_rd != 5'd31) begin
          gpr[memwb_wb_rd] <= wb_wdata;
        end
        if (memwb_wb2_we && memwb_wb2_rd != 5'd31) begin
          gpr[memwb_wb2_rd] <= wb2_wdata;
        end
        if (memwb_wb3_we && memwb_wb3_rd != 5'd31) begin
          gpr[memwb_wb3_rd] <= memwb_wb3_extra;
        end
        if (memwb_sp_we) begin
          if (el) begin
            sp_el1 <= memwb_sp_wdata;
          end else begin
            sp_el0 <= memwb_sp_wdata;
          end
        end
        commit_valid_r     <= 1'b1;
        commit_token_epoch <= memwb_token_epoch;
        commit_token_seq   <= memwb_token_seq;
        dbg_commit_fire    <= 1'b1;
        commit_pc_r        <= memwb_pc;
        commit_next_pc_r   <= exc_vector_core;
        commit_insn_r      <= memwb_insn;
        commit_gpr_we_r    <= memwb_wb_we;
        commit_gpr_rd_r    <= memwb_wb_rd;
        commit_gpr_wdata_r <= wb_wdata;
        commit_gpr2_we_r   <= memwb_wb2_we;
        commit_gpr2_rd_r   <= memwb_wb2_rd;
        commit_gpr2_wdata_r <= wb2_wdata;
        commit_gpr3_we_r   <= memwb_wb3_we;
        commit_gpr3_rd_r   <= memwb_wb3_rd;
        commit_gpr3_wdata_r <= memwb_wb3_extra;
        commit_mem_we_r    <= memwb_is_store && !memwb_stxr_fail;
        commit_mem_addr_r  <= memwb_mem_addr;
        commit_mem_wdata_r <= memwb_mem_wdata;
        commit_mem_strb_r  <= memwb_mem_strb;
        // fetch-fault merge still retires the older instruction first.  A
        // Q store is one architectural commit mirrored as mem/mem2; do not
        // drop its second 8B effect merely because the following fetch is an
        // IABT.  This keeps the 1V/2-store ABI identical to normal WB.
        commit_mem2_we_r   <= memwb_is_store && memwb_is_pair &&
                              (memwb_mem_size == 2'd3) &&
                              !memwb_stxr_fail;
        commit_mem2_addr_r <= memwb_mem_addr + 64'd8;
        commit_mem2_wdata_r <= memwb_mem_wdata2;
        commit_mem2_strb_r  <= 8'hFF;
        commit_exc_valid_r <= 1'b1;
        commit_exc_code_r  <= el ? EXC_IABORT_SAME_EL : EXC_IABORT;
        commit_exc_esr_r   <= abort_esr(el ? 6'h21 : 6'h20, 1'b0,
                                        fetch_fsc_r);
        commit_exc_far_r   <= fetch_pc_r;
        // The older instruction still retires before the fetch fault is
        // merged. Preserve its scalar/NEON FP state effect in this packet;
        // fp_state consumes the same commit_fire edge.
        commit_vec_write_count_r <= fp_commit_effect_valid
                                    ? fp_commit_effect_vec_write_count : 3'd0;
        commit_vec_rd0_r <= fp_commit_effect_vec_rd0;
        commit_vec_rd1_r <= fp_commit_effect_vec_rd1;
        commit_vec_rd2_r <= fp_commit_effect_vec_rd2;
        commit_vec_rd3_r <= fp_commit_effect_vec_rd3;
        commit_vec_wdata0_r <= fp_commit_effect_vec_wdata0;
        commit_vec_wdata1_r <= fp_commit_effect_vec_wdata1;
        commit_vec_wdata2_r <= fp_commit_effect_vec_wdata2;
        commit_vec_wdata3_r <= fp_commit_effect_vec_wdata3;
        commit_fpcr_we_r <= fp_commit_effect_fpcr_we;
        commit_fpcr_wdata_r <= fp_commit_effect_fpcr_wdata;
        commit_fpsr_we_r <= fp_commit_effect_fpsr_we;
        commit_fpsr_wdata_r <= fp_commit_effect_fpsr_wdata;
        // 已执行的指令照常更新监视器（QEMU：指令先退休，取指 fault 后
        // 合并提交）：LDXR 记录、STXR/CLREX 清。
        commit_mon_we_r    <= memwb_is_ldxr || memwb_is_stxr ||
                              memwb_is_clrex;
        commit_mon_valid_r <= memwb_is_ldxr;
        commit_mon_addr_r  <= memwb_mem_addr;
        commit_mon_data_r  <= wb_wdata;
        commit_mon_data2_r <= (memwb_is_ldxr && memwb_is_pair)
                                  ? wb2_wdata : 64'd0;
        if (memwb_is_ldxr) begin
          excl_valid <= 1'b1;
          excl_addr  <= memwb_mem_addr;
          excl_data  <= wb_wdata;
          if (memwb_is_pair) begin
            excl_data_hi <= wb2_wdata;
          end
        end else if (memwb_is_stxr || memwb_is_clrex) begin
          excl_valid <= 1'b0;
        end
        elr_el1  <= fetch_pc_r;       // ELR = 故障取指 VA
        esr_el1  <= abort_esr(el ? 6'h21 : 6'h20, 1'b0, fetch_fsc_r);
        far_el1  <= fetch_pc_r;
        spsr_el1 <= make_spsr(memwb_nzcv_we ? memwb_nzcv : nzcv,
                              daif, el, sp_sel, pstate_pan, pstate_dit,
                              pstate_ssbs, pstate_uao, pstate_tco,
                              pstate_allint);
        el       <= 1'b1;
        sp_sel   <= 1'b1;
        daif     <= 4'b1111;
        pstate_allint <= !sctlr_el1[62];
        nzcv     <= 4'b0000;
        commit_sp_we_r    <= 1'b1;
        commit_sp_wdata_r <= sp_el1;
        commit_nzcv_we_r  <= 1'b1;
        commit_nzcv_r     <= 4'b0000;
      end else if (commit_fire && memwb_exc) begin
        // ---- dmem 响应 fault（如 8 字节访问跨 SRAM 顶）-> DABT ----
        // 从端已拒绝访问，无内存副作用；ELR=故障指令 PC。
        commit_valid_r     <= 1'b1;
        commit_token_epoch <= memwb_token_epoch;
        commit_token_seq   <= memwb_token_seq;
        dbg_commit_fire    <= 1'b1;
        commit_pc_r        <= memwb_pc;
        commit_next_pc_r   <= exc_vector_core;
        commit_insn_r      <= memwb_insn;
        commit_gpr_we_r    <= 1'b0;
        commit_gpr_rd_r    <= 5'd0;
        commit_gpr_wdata_r <= 64'd0;
        commit_gpr2_we_r   <= 1'b0;
        commit_gpr2_rd_r   <= 5'd0;
        commit_gpr2_wdata_r <= 64'd0;
        commit_gpr3_we_r   <= 1'b0;
        commit_gpr3_rd_r   <= 5'd0;
        commit_gpr3_wdata_r <= 64'd0;
        commit_mem_we_r    <= 1'b0;
        commit_mem_addr_r  <= 64'd0;
        commit_mem_wdata_r <= 64'd0;
        commit_mem_strb_r  <= 8'd0;
        commit_mem2_we_r   <= 1'b0;
        commit_mem2_addr_r <= 64'd0;
        commit_mem2_wdata_r <= 64'd0;
        commit_mem2_strb_r  <= 8'd0;
        commit_exc_valid_r <= 1'b1;
        commit_exc_code_r  <= el ? EXC_DABORT_SAME_EL : EXC_DABORT;
        commit_exc_esr_r   <= abort_esr(el ? 6'h25 : 6'h24,
                                        memwb_is_store, 6'h10);
        commit_exc_far_r   <= memwb_mem_addr;
        // STXR/LDXR 自身 fault（DABT）：指令未完成，监视器不变
        //（QEMU cmpxchg fault 时 exclusive_addr=-1 不执行）。
        commit_mon_we_r    <= 1'b0;
        commit_mon_valid_r <= 1'b0;
        commit_mon_addr_r  <= 64'd0;
        commit_mon_data_r  <= 64'd0;
        commit_mon_data2_r <= 64'd0;
        elr_el1  <= memwb_pc;
        esr_el1  <= abort_esr(el ? 6'h25 : 6'h24, memwb_is_store, 6'h10);
        far_el1  <= memwb_mem_addr;
        spsr_el1 <= make_spsr(memwb_nzcv_we ? memwb_nzcv : nzcv,
                              daif, el, sp_sel, pstate_pan, pstate_dit,
                              pstate_ssbs, pstate_uao, pstate_tco,
                              pstate_allint);
        el       <= 1'b1;
        sp_sel   <= 1'b1;
        daif     <= 4'b1111;
        pstate_allint <= !sctlr_el1[62];
        nzcv     <= 4'b0000;
        commit_sp_we_r    <= 1'b1;
        commit_sp_wdata_r <= sp_el1;
        commit_nzcv_we_r  <= 1'b1;
        commit_nzcv_r     <= 4'b0000;
        if (data_trans_active || fetch_walk || data_mmu_issue) begin
          memwb_committed_r <= 1'b1;
        end
      end else if (commit_fire) begin
        // 普通提交：valid/ready 消费 WB 条目。条目进入 WB 的首周期提交
        // （与旧边沿同拍）；翻译冻结期间保持的条目由 committed 标志
        // 防重提交；提交消费者忙时（commit_ready=0）条目保持未提交。
        if (memwb_wb_we && memwb_wb_rd != 5'd31) begin
          gpr[memwb_wb_rd] <= wb_wdata;
        end
        if (memwb_wb2_we && memwb_wb2_rd != 5'd31) begin
          gpr[memwb_wb2_rd] <= wb2_wdata;
        end
        if (memwb_wb3_we && memwb_wb3_rd != 5'd31) begin
          gpr[memwb_wb3_rd] <= memwb_wb3_extra;
        end
        if (memwb_sp_we) begin
          if (el) begin
            sp_el1 <= memwb_sp_wdata;
          end else begin
            sp_el0 <= memwb_sp_wdata;
          end
        end
        if (memwb_nzcv_we) begin
          nzcv <= memwb_nzcv;
        end else if (rndr_nzcv_commit) begin
          nzcv <= 4'd0;   // QEMU rndr_readfn 成功：NZCV=0000
        end
        commit_valid_r     <= 1'b1;
        commit_token_epoch <= memwb_token_epoch;
        commit_token_seq   <= memwb_token_seq;
        dbg_commit_fire    <= 1'b1;
        commit_pc_r        <= memwb_pc;
        commit_next_pc_r   <= memwb_next_pc;
        commit_insn_r      <= memwb_insn;
        commit_gpr_we_r    <= memwb_wb_we;
        commit_gpr_rd_r    <= memwb_wb_rd;
        commit_gpr_wdata_r <= wb_wdata;
        commit_gpr2_we_r   <= memwb_wb2_we;
        commit_gpr2_rd_r   <= memwb_wb2_rd;
        commit_gpr2_wdata_r <= wb2_wdata;
        commit_gpr3_we_r   <= memwb_wb3_we;
        commit_gpr3_rd_r   <= memwb_wb3_rd;
        commit_gpr3_wdata_r <= memwb_wb3_extra;
        commit_sp_we_r     <= memwb_sp_we;
        commit_sp_wdata_r  <= memwb_sp_wdata;
        commit_nzcv_we_r   <= memwb_nzcv_we || rndr_nzcv_commit;
        commit_nzcv_r      <= rndr_nzcv_commit ? 4'd0 : memwb_nzcv;
        // Future FP/NEON execution will drive the effect inputs above.  Keep
        // this explicit per-commit forwarding path wired now; P7-0's only
        // non-zero FP effect is the ID-level FPCR/FPSR MSR path.
        commit_vec_write_count_r <= fp_commit_effect_valid
                                    ? fp_commit_effect_vec_write_count : 3'd0;
        commit_vec_rd0_r <= fp_commit_effect_vec_rd0;
        commit_vec_rd1_r <= fp_commit_effect_vec_rd1;
        commit_vec_rd2_r <= fp_commit_effect_vec_rd2;
        commit_vec_rd3_r <= fp_commit_effect_vec_rd3;
        commit_vec_wdata0_r <= fp_commit_effect_vec_wdata0;
        commit_vec_wdata1_r <= fp_commit_effect_vec_wdata1;
        commit_vec_wdata2_r <= fp_commit_effect_vec_wdata2;
        commit_vec_wdata3_r <= fp_commit_effect_vec_wdata3;
        commit_fpcr_we_r <= fp_commit_effect_fpcr_we;
        commit_fpcr_wdata_r <= fp_commit_effect_fpcr_wdata;
        commit_fpsr_we_r <= fp_commit_effect_fpsr_we;
        commit_fpsr_wdata_r <= fp_commit_effect_fpsr_wdata;
        // STXR 失败时无内存副作用（读比较阶段已确定，写阶段未发）
        commit_mem_we_r    <= memwb_is_store && !memwb_stxr_fail;
        commit_mem_addr_r  <= memwb_mem_addr;
        commit_mem_wdata_r <= memwb_mem_wdata;
        commit_mem_strb_r  <= memwb_mem_strb;
        // STP X 对按两个 8 字节存储提交：mem=rt、mem2=rt2，与 QEMU
        // 插件拆分后的两个 8B store 一一对应；W 对仍为单笔 8B
        // （mem_wdata={rt2,rt}，见 decode）。
        commit_mem2_we_r    <= memwb_is_store && memwb_is_pair &&
                              (memwb_mem_size == 2'd3) &&
                              !memwb_stxr_fail;
        commit_mem2_addr_r  <= memwb_mem_addr + 64'd8;
        commit_mem2_wdata_r <= memwb_mem_wdata2;
        commit_mem2_strb_r  <= 8'hFF;
        commit_exc_valid_r <= 1'b0;
        commit_exc_code_r  <= 32'd0;
        commit_exc_esr_r   <= 32'd0;
        commit_exc_far_r   <= 64'd0;
        // exclusive 监视器：LDXR 记录（地址+加载值）、STXR/CLREX 清。
        // STXR 无论成功失败都清（QEMU gen_store_exclusive 末尾恒置
        // exclusive_addr=-1）。
        commit_mon_we_r    <= memwb_is_ldxr || memwb_is_stxr ||
                              memwb_is_clrex;
        commit_mon_valid_r <= memwb_is_ldxr;
        commit_mon_addr_r  <= memwb_mem_addr;
        commit_mon_data_r  <= wb_wdata;
        commit_mon_data2_r <= (memwb_is_ldxr && memwb_is_pair)
                                  ? wb2_wdata : 64'd0;
        if (memwb_is_ldxr) begin
          excl_valid <= 1'b1;
          excl_addr  <= memwb_mem_addr;
          excl_data  <= wb_wdata;
          if (memwb_is_pair) begin
            excl_data_hi <= wb2_wdata;
          end
        end else if (memwb_is_stxr || memwb_is_clrex) begin
          excl_valid <= 1'b0;
        end
        // P6：IRQ 在指令边界取走（覆盖为异步异常提交：ELR=下一条、
        // SPSR=当前 PSTATE、入口 EL1h + DAIF 全置、向量 +0x280/0x80/0x480）
        if (irq_taken) begin
          commit_next_pc_r   <= irq_vector_core;
          commit_exc_valid_r <= 1'b1;
          commit_exc_code_r  <= EXC_IRQ;
          commit_exc_esr_r   <= 32'd0;
          commit_exc_far_r   <= 64'd0;
          elr_el1  <= memwb_next_pc;
          spsr_el1 <= make_spsr(memwb_nzcv_we ? memwb_nzcv : nzcv,
                                daif, el, sp_sel, pstate_pan, pstate_dit,
                                pstate_ssbs, pstate_uao, pstate_tco,
                                pstate_allint);
          el       <= 1'b1;
          sp_sel   <= 1'b1;
          daif     <= 4'b1111;
          pstate_allint <= !sctlr_el1[62];
          pstate_pan <= 1'b0;
          pstate_dit <= 1'b0;
          pstate_ssbs <= 1'b0;
          pstate_uao <= 1'b0;
          pstate_tco <= 1'b0;
          nzcv     <= 4'b0000;
          // 访存指令（LDP/STP pre/post）的 SP 写回随指令提交；IRQ 合并
          // 提交必须上报写回后的 SP，否则 shadow/QEMU 的 SP 差一个步长。
          commit_sp_we_r    <= 1'b1;
          commit_sp_wdata_r <= memwb_sp_we ? memwb_sp_wdata : sp_el1;
          commit_nzcv_we_r  <= 1'b1;
          commit_nzcv_r     <= 4'b0000;
        end
        // 事务/遍历冻结期间 WB 条目不弹出：标记已提交防重提交；
        // FIFO on/off 均可能在 older WB 与 younger EX/MEM data op 之间
        // 形成该边界，故 dmem_pending 必须统一纳入 hold 条件。
        if (data_trans_active || fetch_walk || data_mmu_issue ||
            dmem_pending) begin
          memwb_committed_r <= 1'b1;
        end
      end

      // 验证模式保留 QEMU -icount shift=0：退休指令推进一次，WFI 空闲拍
      // 也推进以确定性测试唤醒。板级模式由每个 core 时钟推进，访存停顿
      // 和 WFI 等待也因此计入真实硬件时间。
      if (wfi_wake && (difftest_wait_release ||
                       difftest_wait_release_pending)) begin
        // 仿真 sideband 给出 QEMU 下一 PRE 前的 CNTVCT；wake 拍不再额外
        // 推进，直接重基准。板级不连接该 sideband。
        if (difftest_wait_cntvct_valid) begin
          cntpct_r <= difftest_wait_cntvct - 64'd1;
        end else if (difftest_wait_cntvct_pending) begin
          cntpct_r <= difftest_wait_cntvct_r - 64'd1;
        end
      end else if (TIMER_REALTIME || sys_commit || commit_fire) begin
        cntpct_r <= cntpct_r + 64'd1;
      end else if (!TIMER_REALTIME && wfi_idle) begin
        // QEMU 的 WFI 会被 Generic Timer 事件唤醒；等待期间没有退休
        // 指令，因此用一个仿真周期推进虚拟计数器，保持可复现的
        // Timer/GIC 唤醒边界。
        cntpct_r <= cntpct_r + 64'd1;
      end

      // checkpoint 恢复是唯一允许从 QEMU 向核心写入架构系统状态的
      // 边界。该分支必须放在主时序块末尾，使其覆盖同拍的 reset 后取指
      // 尝试与 timer 自增；同时清空所有可能刚刚产生的在途取指/提交，令
      // 下一拍必定从 sidecar 的 next_pc 开始。GPR 由协调器的 arch
      // restore 路径在复位保持期间写入；这里专门覆盖 PSTATE、EL1
      // 系统寄存器与 Generic Timer，避免 C++ 绕过端口改 RTL 层级变量。
      if (difftest_restore_sys_valid) begin
        if_pc       <= difftest_restore_pc;
        fetch_pending <= 1'b0;
        fetch_pc_r    <= 64'd0;
        fetch_trans_busy <= 1'b0;
        fetch_translated <= 1'b0;
        fetch_got_data <= 1'b0;
        fetch_faulted <= 1'b0;
        fetch_fault_pending <= 1'b0;
        ifid_valid  <= 1'b0;
        ifid_token_epoch <= '0;
        ifid_token_seq   <= 16'd0;
        idex_valid  <= 1'b0;
        idex_token_epoch <= '0;
        idex_token_seq   <= 16'd0;
        exmem_valid <= 1'b0;
        exmem_token_epoch <= '0;
        exmem_token_seq   <= 16'd0;
        memwb_valid <= 1'b0;
        memwb_token_epoch <= '0;
        memwb_token_seq   <= 16'd0;
        memwb_committed_r <= 1'b0;
        commit_valid_r <= 1'b0;
        commit_token_epoch <= '0;
        commit_token_seq   <= 16'd0;
        par_update_pending <= 1'b0;

        sp_el0     <= difftest_restore_sp_el0;
        sp_el1     <= difftest_restore_sp_el1;
        nzcv       <= difftest_restore_nzcv;
        el         <= difftest_restore_el;
        sp_sel     <= difftest_restore_sp_sel;
        daif       <= difftest_restore_daif;
        pstate_pan <= difftest_restore_pan;
        pstate_dit <= difftest_restore_dit;
        pstate_ssbs <= difftest_restore_ssbs;
        pstate_uao <= difftest_restore_uao;
        pstate_tco <= difftest_restore_tco;
        pstate_allint <= difftest_restore_allint;
        elr_el1    <= difftest_restore_elr_el1;
        spsr_el1   <= difftest_restore_spsr_el1;
        vbar_el1   <= difftest_restore_vbar_el1;
        // restore 与正常 MSR 使用同一架构写掩码，避免旧 sidecar 把本核
        // 未实现的 PAuth 状态注入后在首次 MRS 才暴露差异。
        sctlr_el1  <= difftest_restore_sctlr_el1 &
                      SCTLR_EL1_WRITE_MASK;
        tcr_el1    <= difftest_restore_tcr_el1;
        ttbr0_el1  <= difftest_restore_ttbr0_el1;
        ttbr1_el1  <= difftest_restore_ttbr1_el1;
        mair_el1   <= difftest_restore_mair_el1;
        esr_el1    <= difftest_restore_esr_el1;
        far_el1    <= difftest_restore_far_el1;
        par_el1    <= difftest_restore_par_el1;
        mdscr_el1  <= difftest_restore_mdscr_el1;
        pmuserenr_el0 <= difftest_restore_pmuserenr_el0 & 64'hf;
        cntkctl_el1 <= difftest_restore_cntkctl_el1;
        tpidr_el0  <= difftest_restore_tpidr_el0;
        tpidrro_el0 <= difftest_restore_tpidrro_el0;
        tpidr_el1  <= difftest_restore_tpidr_el1;
        contextidr_el1 <= difftest_restore_contextidr_el1;
        pir_el1    <= difftest_restore_pir_el1;
        pire0_el1  <= difftest_restore_pire0_el1;
        zcr_el1    <= difftest_restore_zcr_el1 & 64'hf;
        smcr_el1   <= difftest_restore_smcr_el1 & 64'h8000_000f;
        csselr_el1 <= difftest_restore_csselr_el1 & 64'hf;
        tcr2_el1   <= difftest_restore_tcr2_el1 & 64'h7_0012;
        excl_valid <= difftest_restore_excl_valid;
        excl_addr  <= difftest_restore_excl_addr;
        excl_data  <= difftest_restore_excl_data;
        excl_data_hi <= difftest_restore_excl_data_hi;

        // sidecar 的 cntpct 是恢复后下一条指令可见值；RTL 内部寄存器
        // 表示“已提交数”，MRS 在 EX 读时加一，故恢复时减一。
        cntpct_r    <= difftest_restore_cntpct - 64'd1;
        cntp_cval_r <= difftest_restore_cntp_cval;
        cntp_ctl_r  <= difftest_restore_cntp_ctl;
        cntv_cval_r <= difftest_restore_cntv_cval;
        cntv_ctl_r  <= difftest_restore_cntv_ctl;
        wfi_idle    <= 1'b0;
        event_reg   <= 1'b0;
        wfi_timeout_valid <= 1'b0;
        difftest_wait_release_pending <= 1'b0;
        difftest_wait_cntvct_pending <= 1'b0;
      end
    end
  end

  // FP-P1 owner/issued 状态。request 被 wrapper 接受时置位；response 被
  // EX/MEM 接收或任何核心 kill 时清位。该状态与 wrapper 内部 state 一起
  // 保证首版严格单在途、不重复 issue。
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fp_tx_issued <= 1'b0;
    end else if (fp_tx_kill) begin
      fp_tx_issued <= 1'b0;
    end else if (fp_req_valid && fp_req_ready) begin
      fp_tx_issued <= 1'b1;
    end else if (fp_rsp_valid && fp_rsp_ready) begin
      fp_tx_issued <= 1'b0;
    end
  end

  // ---- 提交包 ----
  assign commit.valid        = commit_valid_r;
  assign commit.pc           = commit_pc_r;
  assign commit.next_pc      = commit_next_pc_r;
  assign commit.insn         = commit_insn_r;
  assign commit.gpr_we       = commit_gpr_we_r;
  assign commit.gpr_rd       = commit_gpr_rd_r;
  assign commit.gpr_wdata    = commit_gpr_wdata_r;
  assign commit.gpr2_we      = commit_gpr2_we_r;
  assign commit.gpr2_rd      = commit_gpr2_rd_r;
  assign commit.gpr2_wdata   = commit_gpr2_wdata_r;
  assign commit.gpr3_we      = commit_gpr3_we_r;
  assign commit.gpr3_rd      = commit_gpr3_rd_r;
  assign commit.gpr3_wdata   = commit_gpr3_wdata_r;
  assign commit.sp_we        = commit_sp_we_r;
  assign commit.sp_wdata     = commit_sp_wdata_r;
  assign commit.nzcv_we      = commit_nzcv_we_r;
  assign commit.nzcv         = commit_nzcv_r;
  assign commit.mem_we       = commit_mem_we_r;
  assign commit.mem_addr     = commit_mem_addr_r;
  assign commit.mem_wdata    = commit_mem_wdata_r;
  assign commit.mem_strb     = commit_mem_strb_r;
  assign commit.mem2_we      = commit_mem2_we_r;
  assign commit.mem2_addr    = commit_mem2_addr_r;
  assign commit.mem2_wdata   = commit_mem2_wdata_r;
  assign commit.mem2_strb    = commit_mem2_strb_r;
  assign commit.exc_valid    = commit_exc_valid_r;
  assign commit.exc_code     = commit_exc_code_r;
  assign commit.exc_esr      = commit_exc_esr_r;
  assign commit.exc_far      = commit_exc_far_r;
  assign commit.mon_we       = commit_mon_we_r;
  assign commit.mon_valid    = commit_mon_valid_r;
  assign commit.mon_addr     = commit_mon_addr_r;
  assign commit.mon_data     = commit_mon_data_r;
  assign commit.mon_data2    = commit_mon_data2_r;

  // P7-0 FP effect fields are latched at the same edge as commit.valid.
  // Scalar and trap commits retain all-zero FP effects; FPCR/FPSR MSR effects
  // are filled by the ID system-commit path above.
  assign commit.vec_write_count = commit_vec_write_count_r;
  assign commit.vec_rd0         = commit_vec_rd0_r;
  assign commit.vec_rd1         = commit_vec_rd1_r;
  assign commit.vec_rd2         = commit_vec_rd2_r;
  assign commit.vec_rd3         = commit_vec_rd3_r;
  assign commit.vec_wdata0      = commit_vec_wdata0_r;
  assign commit.vec_wdata1      = commit_vec_wdata1_r;
  assign commit.vec_wdata2      = commit_vec_wdata2_r;
  assign commit.vec_wdata3      = commit_vec_wdata3_r;
  assign commit.fpcr_we         = commit_fpcr_we_r;
  assign commit.fpcr_wdata      = commit_fpcr_wdata_r;
  assign commit.fpsr_we         = commit_fpsr_we_r;
  assign commit.fpsr_wdata      = commit_fpsr_wdata_r;

  // ================= M2-4b：缓存/TLB 维护流程状态机 =================
  // 维护指令（IC/DC/TLBI）在 ID 级等待前方排空后提交；本状态机管理
  // IC IVAU 的 VA 翻译、I-L1 失效请求与 TLBI 脉冲。DC 各 op 在写通
  // 层次下为功能无操作（缓存与内存已一致），仅识别并提交。
  assign maint_done = (maint_state == MS_DONE);
  always_comb begin
    par_update_valid = 1'b0;
    par_update_data = par_el1;
    if (sys_maint_at_id && d.maint_op == MAINT_AT) begin
      if (maint_state == MS_IDLE && !mmu_en) begin
        par_update_valid = 1'b1;
        // QEMU virt 的 Normal RAM 在 PAR_EL1 成功结果中带 Inner-shareable
        // 属性位 [9:8]=2'b11，故标志字段为 0xb00（而非仅 0x800）。
        par_update_data = 64'h0000_0000_0000_0b00 |
                          (d.maint_va & ~64'hfff);
      end else if (maint_state == MS_TRANSLATE && mmu_done &&
                   data_trans_active) begin
        par_update_valid = 1'b1;
        if (mmu_fault)
          par_update_data = 64'h0000_0000_0000_0801 |
                            (64'(mmu_fault_fsc) << 1);
        else
          // QEMU do_ats_write(): LPAE + NS + ATTR[63:56] + SH[8:7].
          par_update_data = 64'h0000_0000_0000_0a00 |
                            (64'(mmu_par_sh) << 7) |
                            ({56'd0, mmu_par_attr} << 56) |
                            (mmu_paddr & ~64'hfff);
      end
    end
  end
  // TLBI 仅由维护指令产生；ordinary IRQ 使用独立 mmu_abort，避免清空
  // 既有 TLB。IRQ 同拍若有已接受 PTW，MMU 进入 response quarantine。
  assign tlb_invalidate = (maint_state == MS_IDLE) && sys_maint_at_id &&
                          (d.maint_op == MAINT_TLBI) && !irq_taken &&
                          !memwb_fetch_wait;
  assign mmu_abort = irq_taken;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      maint_state <= MS_IDLE;
      maint_trans_fault <= 1'b0;
      maint_imem_rsp_pending <= 1'b0;
    end else begin
      // Request acceptance creates a durable response owner.  Keep it until
      // the matching response is actually consumed, even if the younger
      // maintenance instruction is flushed and maint_state is reset.  A
      // request and response cannot handshake in the same cycle through the
      // single-outstanding memory fabric, but response-clear is written last
      // for completeness if a future endpoint adds a zero-latency path.
      if (maint_imem_req_accept)
        maint_imem_rsp_pending <= 1'b1;
      if (maint_imem_rsp_consume)
        maint_imem_rsp_pending <= 1'b0;
      if (irq_taken || sys_commit || fetch_merge_wb || !sys_maint_at_id) begin
        maint_state <= MS_IDLE;
        maint_trans_fault <= 1'b0;
      end else if (memwb_fetch_wait) begin
        // A younger maintenance request may not advance while an older
        // fetch-fault merge is fenced.  MS_WAIT is the one exception: an
        // already accepted response is owned by maint_imem_rsp_owner and
        // may complete the request, without accepting a new side effect.
        if (maint_state == MS_WAIT && maint_imem_rsp_consume)
          maint_state <= MS_DONE;
      end else begin
        unique case (maint_state)
          MS_IDLE: begin
            if (d.maint_op == MAINT_AT) begin
              // AT 在 EL1 执行地址翻译并把结果写入 PAR_EL1；MMU 关闭时
              // 为直接映射成功结果，开启时复用数据侧页表遍历。
              if (!mmu_en) begin
                maint_state <= MS_DONE;
              end else begin
                maint_state <= MS_TRANSLATE;
              end
            end else if (d.maint_op inside {MAINT_DC_IVAC, MAINT_DC_ISW,
                                   MAINT_DC_CVAC, MAINT_DC_CVAU,
                                   MAINT_DC_CVAP, MAINT_DC_CIVAC}) begin
              maint_state <= MS_DONE;   // 当前无持久介质/缓存：无操作，直接提交
            end else if (d.maint_op == MAINT_TLBI) begin
              maint_state <= MS_DONE;   // 脉冲本拍已组合发出
            end else if (d.maint_op == MAINT_IC_IALLU) begin
              maint_state <= MS_REQ;    // 整表失效请求（无 VA）
            end else if (d.maint_op == MAINT_DC_ZVA) begin
              // DC ZVA：MMU 开时先数据翻译 VA->PA，随后 8 次清零写
              if (!mmu_en) begin
                maint_zva_pa <= d.maint_va & ~64'd63;
                maint_zva_idx <= 3'd0;
                maint_state <= MS_DCZVA_WRITE;
              end else if (trans_done_flag) begin
                maint_zva_pa <= trans_paddr_r & ~64'd63;
                maint_zva_idx <= 3'd0;
                maint_state <= MS_DCZVA_WRITE;
              end else begin
                maint_state <= MS_TRANSLATE;
              end
            end else begin
              // MAINT_IC_IVAU：MMU 开时先数据翻译 VA->PA
              if (!mmu_en) begin
                maint_state <= MS_REQ;  // 直通：VA=PA
              end else if (trans_done_flag) begin
                maint_state <= maint_trans_fault ? MS_DONE : MS_REQ;
              end else begin
                maint_state <= MS_TRANSLATE;
              end
            end
          end
          MS_TRANSLATE: begin
            // 翻译完成（trans_done_flag 在下一拍可见）：
            // 失败则跳过缓存失效并正常提交（QEMU system 模式对 IC/DC
            // 维护均为 NOP，不产生异常），成功则进入 MS_REQ。
            if (mmu_done && data_trans_active && maint_va_pending &&
                mmu_fault) begin
              maint_trans_fault <= 1'b1;
            end
            if (trans_done_flag) begin
              if (d.maint_op == MAINT_AT) begin
                maint_state <= MS_DONE;
              end else if (d.maint_op == MAINT_DC_ZVA) begin
                if (maint_trans_fault) begin
                  maint_state <= MS_DONE;   // 翻译失败：NOP 提交
                end else begin
                  maint_zva_pa <= trans_paddr_r & ~64'd63;
                  maint_zva_idx <= 3'd0;
                  maint_state <= MS_DCZVA_WRITE;
                end
              end else begin
                maint_state <= maint_trans_fault ? MS_DONE : MS_REQ;
              end
            end
          end
          MS_DCZVA_WRITE: begin
            // 8 次 8 字节清零写：请求被接受后推进索引，写完 8 段提交
            if (maint_dmem_req_accept) begin
              if (maint_zva_idx == 3'd7) begin
                maint_state <= MS_DONE;
              end else begin
                maint_zva_idx <= maint_zva_idx + 3'd1;
              end
            end
          end
          MS_REQ: begin
            if (maint_imem_req_accept) begin
              maint_state <= MS_WAIT;
            end
          end
          MS_WAIT: begin
            if (maint_imem_rsp_consume) begin
              maint_state <= MS_DONE;   // response owner 当拍消费
            end
          end
          MS_DONE: ;   // 等 sys_commit（外层复位回 MS_IDLE）
          default: maint_state <= MS_IDLE;
        endcase
      end
    end
  end

  // ================= M1-C：SVA 断言 =================
  // 运行构建需 --assert（Makefile 已加）；lint 构建跳过。
  /* verilator lint_off SYNCASYNCNET */  // disable iff 与异步复位共存
  // P7-0：FP state sideband 的组合权限/阻断结果必须与当前 access 一致；
  // 这些断言只约束边界，不实现任何 FP/NEON 运算。
  assert property (@(posedge clk) disable iff (!rst_n)
      fp_trap_valid == (fp_access_valid && !fp_access_allowed));
  assert property (@(posedge clk) disable iff (!rst_n)
      fp_trap_valid |-> (fp_trap_code == EXC_FP_ACCESS &&
                         fp_trap_esr == ESR_FP_ACCESS_TRAP));
  assert property (@(posedge clk) disable iff (!rst_n)
      fp_cpacr_fpen == fp_cpacr_read_data[21:20]);
  assert property (@(posedge clk) disable iff (!rst_n)
      !(sys_fp_access_blocked &&
        (sys_fpcr_write_accept || sys_fpsr_write_accept)));
  assert property (@(posedge clk) disable iff (!rst_n)
      !(sys_cpacr_write_blocked && sys_cpacr_write_accept));
  assert property (@(posedge clk) disable iff (!rst_n)
      !fp_commit_effect_error);
  // 提交源定义（互斥）：
  logic wb_dabt, wb_norm;
  assign wb_dabt = commit_fire && memwb_exc;
  assign wb_norm = commit_fire && !memwb_exc && !fetch_merge_wb;

  // 单提交：任意周期至多一个提交源
  assert property (@(posedge clk) disable iff (!rst_n)
      $onehot0({sys_commit, fetch_merge_wb, wb_dabt, wb_norm}));
  // 提交源触发后下一拍必有提交脉冲（反向无伪脉冲由单提交源保证）
  assert property (@(posedge clk) disable iff (!rst_n)
      (sys_commit || fetch_merge_wb || wb_dabt || wb_norm) |=> commit_valid_r);

  // MMU-on maintenance 在流程完成后不再拥有 IMEM 端口；否则 FIFO-on 下
  // fetch_next_settled 只能等待一个永远不会发出的普通取指请求。
  assert property (@(posedge clk) disable iff (!rst_n)
      (fetch_fifo_active && sys_maint_at_id &&
       d.sys_op == SYS_MAINT && mmu_en &&
       (maint_state == MS_DONE) && !fetch_next_settled) |->
          !maint_imem_owner);
  // Maintenance request/response handshakes must use the selected owner;
  // an older fetch-fault WB wait may release ordinary request ownership, but
  // it must never turn a younger MS_REQ/DCZVA/TLBI operation into a side
  // effect.  An already accepted MS_WAIT response has its own explicit
  // response owner and may only complete that pre-existing request.
  assert property (@(posedge clk) disable iff (!rst_n)
      maint_imem_req_valid |-> (maint_imem_owner &&
                                maint_imem_req_selected));
  assert property (@(posedge clk) disable iff (!rst_n)
      maint_imem_req_selected |-> !maint_imem_rsp_pending);
  assert property (@(posedge clk) disable iff (!rst_n)
      maint_imem_req_accept |-> (maint_imem_req_selected &&
                                 maint_imem_req_valid));
  assert property (@(posedge clk) disable iff (!rst_n)
      maint_imem_req_accept |=> maint_imem_rsp_pending);
  assert property (@(posedge clk) disable iff (!rst_n)
      (maint_imem_rsp_pending && !maint_imem_rsp_consume) |=>
          maint_imem_rsp_pending);
  assert property (@(posedge clk) disable iff (!rst_n)
      maint_imem_rsp_consume |-> maint_imem_rsp_owner);
  assert property (@(posedge clk) disable iff (!rst_n)
      (sys_commit && sys_maint_at_id) |-> !maint_imem_rsp_pending);
  assert property (@(posedge clk) disable iff (!rst_n)
      memwb_fetch_wait |-> (!maint_imem_req_valid &&
                            !maint_imem_req_accept &&
                            !maint_imem_req_selected &&
                            !maint_dmem_req_valid &&
                            !maint_dmem_req_accept &&
                            !tlb_invalidate));
  assert property (@(posedge clk) disable iff (!rst_n)
      (memwb_fetch_wait && (maint_state != MS_WAIT)) |=>
          (maint_state == $past(maint_state)));
  assert property (@(posedge clk) disable iff (!rst_n)
      (memwb_fetch_wait && (maint_state == MS_WAIT) &&
       !maint_imem_rsp_consume) |=> (maint_state == MS_WAIT));
  assert property (@(posedge clk) disable iff (!rst_n)
      (memwb_fetch_wait && (maint_state == MS_WAIT) &&
       maint_imem_rsp_consume) |=> (maint_state == MS_DONE));

  // Ordinary IRQ is sampled only at an accepted older WB boundary.  The
  // current edge must not accept a younger data/maintenance request, and the
  // following edge must expose no younger stage, token, or transaction state.
  // WFI/sys_irq_taken use separate architectural paths and are intentionally
  // not folded into this assertion.
  assert property (@(posedge clk) disable iff (!rst_n)
      irq_taken |-> commit_ready);
  assert property (@(posedge clk) disable iff (!rst_n)
      irq_taken |-> !irq_irrevocable_pending);
  assert property (@(posedge clk) disable iff (!rst_n)
      irq_taken |-> (!dmem_req_valid && !dmem_req_accept &&
                     !maint_dmem_req_valid && !maint_dmem_req_accept));
  assert property (@(posedge clk) disable iff (!rst_n)
      irq_taken |=> (!ifid_valid && !idex_valid && !exmem_valid &&
                     !memwb_valid && !fetch_pending &&
                     !fetch_trans_busy && !data_trans_active &&
                     !dabt_pending && !dmem_req_issued && !dmem_done &&
                     !atomic128_second_needed && !pair_part &&
                     !fp_tx_issued && !fp_tx_busy && !fp_rsp_valid &&
                     maint_state == MS_IDLE));

  // 无重复 Store：同一条 store 事务的请求只被接受一次
  assert property (@(posedge clk) disable iff (!rst_n)
      dmem_req_accept |-> !dmem_req_issued);

  // P7-2 单 Q store 采用“完整窗口预检、禁止半途 fault”语义：第一段
  // 8B request 被接受前，低/高物理半段必须已经自然对齐且各自位于可访问
  // 窗口；因此若从端遵守 mem_req 合同，第二段 response 不得再返回 fault。
  // 这条断言禁止把不可回滚的半笔 Q store 当成合法架构语义。
  assert property (@(posedge clk) disable iff (!rst_n)
      (exmem_valid && exmem_neon_valid && exmem_is_store &&
       exmem_is_pair && !pair_part && dmem_req_accept) |->
          (exmem_mem_paddr[3:0] == 4'd0 &&
           exmem_mem_paddr2[2:0] == 3'd0 &&
           pa_window8(exmem_mem_paddr) &&
           pa_window8(exmem_mem_paddr2)));
  assert property (@(posedge clk) disable iff (!rst_n)
      (exmem_valid && exmem_neon_valid && exmem_is_store &&
       exmem_is_pair && dmem_req_issued && dmem_rsp_valid) |->
          !dmem_rsp.fault);

  // A data translation hold and FP response acceptance are mutually
  // exclusive: EX/MEM uses the same hold set and therefore cannot capture a
  // response on such an edge.
  assert property (@(posedge clk) disable iff (!rst_n)
      fp_rsp_accept_blocked |-> !fp_rsp_ready);

  // R19 response elastic-boundary invariants.  A raw wrapper response is
  // always accepted into the empty hold slot, even when the core-side
  // EX/MEM handshake is blocked.  The response is then held until the
  // original core-side acceptance predicate becomes true; a kill may discard
  // it at the precise younger-transaction boundary.
  assert property (@(posedge clk) disable iff (!rst_n)
      (fp_exec_rsp_valid && !fp_rsp_hold_valid)
      |-> fp_exec_rsp_ready);
  assert property (@(posedge clk) disable iff (!rst_n)
      (fp_exec_rsp_valid && fp_exec_rsp_ready && !fp_rsp_ready &&
       !fp_tx_kill)
      |=> fp_rsp_hold_valid);
  assert property (@(posedge clk) disable iff (!rst_n)
      (fp_exec_rsp_valid && fp_exec_rsp_ready && fp_tx_kill)
      |=> !fp_rsp_hold_valid);
  assert property (@(posedge clk) disable iff (!rst_n)
      (fp_rsp_hold_valid && !fp_rsp_ready && !fp_tx_kill)
      |=> fp_rsp_hold_valid);
  assert property (@(posedge clk) disable iff (!rst_n)
      (fp_rsp_hold_valid && fp_rsp_ready)
      |=> !fp_rsp_hold_valid);
  assert property (@(posedge clk) disable iff (!rst_n)
      fp_rsp_hold_valid |-> !fp_exec_rsp_valid);
  // A held response still belongs to the FP instruction occupying ID/EX.
  // Keep the request owner live until core-side consumption and prohibit a
  // second wrapper request while that response is buffered.
  assert property (@(posedge clk) disable iff (!rst_n)
      (fp_rsp_hold_valid && !fp_tx_kill)
      |-> (fp_tx_issued && fp_tx_candidate && !fp_req_valid));
  assert property (@(posedge clk) disable iff (!rst_n)
      (fp_rsp_hold_valid && !fp_tx_kill)
      |-> (fp_rsp_hold.tag == idex_token_seq));
  assert property (@(posedge clk) disable iff (!rst_n)
      (fp_rsp_valid && !fp_rsp_ready && !fp_tx_kill)
      |=> (fp_tx_kill || (fp_rsp_valid && $stable(fp_rsp))));

  // R18: system instructions reach their ID-level commit only after the
  // complete in-order drain.  Therefore a system commit cannot observe an
  // FP request candidate, issued owner, wrapper busy state, or held response.
  // This is the functional proof that permits `sys_commit` to stay out of
  // fp_tx_kill; the assertion intentionally names every owner phase instead
  // of relying only on the aggregate observation.
  assert property (@(posedge clk) disable iff (!rst_n)
      sys_commit |-> !fp_tx_candidate);
  assert property (@(posedge clk) disable iff (!rst_n)
      sys_commit |-> !fp_tx_issued);
  assert property (@(posedge clk) disable iff (!rst_n)
      sys_commit |-> !fp_tx_busy);
  assert property (@(posedge clk) disable iff (!rst_n)
      sys_commit |-> !fp_rsp_valid);
  assert property (@(posedge clk) disable iff (!rst_n)
      sys_commit |-> !fp_tx_active);

  // 取指 fault 合并不改变已退休的 older commit：若该 commit 是 Q store，
  // mem2 必须仍携带第二个连续 8B store。
  assert property (@(posedge clk) disable iff (!rst_n)
      (fetch_merge_wb && memwb_is_store && memwb_is_pair &&
       (memwb_mem_size == 2'd3) && !memwb_stxr_fail) |=>
          (commit_mem2_we_r && commit_mem2_strb_r == 8'hff &&
           commit_mem2_addr_r == (memwb_mem_addr + 64'd8)));

  // 同页 64-bit pair 的第二段地址必须由已寄存 PA1 推导；跨页
  // LSE128/NEON Q 由第二次翻译结果提供，故排除这两类跨页例外。
  assert property (@(posedge clk) disable iff (!rst_n)
      (exmem_valid && exmem_is_pair && (exmem_mem_size == 2'd3) &&
       !((exmem_is_atomic || exmem_neon_valid) &&
         (exmem_mem_addr[11:0] > 12'hff0))) |->
          (exmem_mem_paddr2 == (exmem_mem_paddr + 64'd8)));
  // W pair 的 dmem 第二请求维持既有 +4 选择；PA2 payload 仍按
  // 64-bit 对齐 +8 保存，不改变 mem2/commit 的架构表示。
  assert property (@(posedge clk) disable iff (!rst_n)
      (exmem_valid && exmem_is_pair && (exmem_mem_size != 2'd3) &&
       pair_part && dmem_req_valid) |->
          (dmem_req.addr == (exmem_mem_paddr + 64'd4)));

  // 32 位指令写回高 32 位必须为零（EX 级结果）
  assert property (@(posedge clk) disable iff (!rst_n)
      (idex_valid && idex_d.is_32 && idex_d.wb_we) |->
          (ex_wdata[63:32] == 32'd0));
  // 本核不实现 PAuth，SCTLR 四个 PAuth enable 在任何提交/恢复后都为 0。
  assert property (@(posedge clk) disable iff (!rst_n)
      (sctlr_el1 & ~SCTLR_EL1_WRITE_MASK) == 64'd0);
  assert property (@(posedge clk) disable iff (!rst_n)
      !fetch_fifo_active |-> !fetch_control_fence);

  // F1a ring/epoch invariants.  They are elaborated only for the enabled
  // depth-2 path; the default legacy build therefore has exactly the prior
  // assertion surface and no feature-dependent X state.
  generate
    if (FETCH_FIFO_ENABLE != 0 && FETCH_FIFO_DEPTH == 2) begin : g_f1a_sva
      assert property (@(posedge clk) disable iff (!rst_n)
          frontend_kill |-> (!fetch_fifo_push && !fetch_fifo_pop));
      assert property (@(posedge clk) disable iff (!rst_n)
          fetch_stale_drain |->
            (!fetch_req_accept && !imem_req_accept && !data_mmu_issue));
      assert property (@(posedge clk) disable iff (!rst_n)
          fetch_stale_rsp_drop |-> !fetch_fifo_push);
      assert property (@(posedge clk) disable iff (!rst_n)
          fetch_fifo_count <= 2'd2);
      assert property (@(posedge clk) disable iff (!rst_n)
          fetch_fifo_push |->
            (fetch_fifo_push_epoch == fetch_epoch));
      assert property (@(posedge clk) disable iff (!rst_n)
          fetch_fifo_head_fault |->
            (!fetch_req_accept && !imem_req_accept));
      // A current-epoch control-flow token fences only younger ordinary
      // fetch issue; the existing decode/flush logic remains the sole source
      // of target and taken/not-taken decisions.
      assert property (@(posedge clk) disable iff (!rst_n)
          fetch_control_fence |-> (!fetch_req_accept && !imem_req_accept));
      // The next-fetch fence is an outcome fence, not a request/translation
      // fence: pending or translated alone must never make it settle.
      assert property (@(posedge clk) disable iff (!rst_n)
          fetch_next_settled |->
            (fetch_fifo_has_target ||
             (fetch_faulted && fetch_ctx_epoch == fetch_epoch &&
              fetch_pc_r == d.next_pc)));
      // A normal WB entry cannot retire until its next-PC fetch outcome is
      // settled.  This is the precise branch-target IABT fence: the fault
      // response may arrive several cycles after the target walk starts, but
      // the older entry must remain available for fetch_merge_wb.
      assert property (@(posedge clk) disable iff (!rst_n)
          memwb_fetch_wait |-> (stall_wb && !commit_fire));
      assert property (@(posedge clk) disable iff (!rst_n)
          (commit_fire && memwb_valid && !memwb_exc) |->
            memwb_fetch_target_settled);
      // A translation-context MSR may not reuse an old same-epoch outcome.
      // Once the refresh request is visible and no walk is still in flight,
      // exactly one redirect must bump the local epoch; the next settled
      // outcome must therefore belong to the post-refresh generation.
      assert property (@(posedge clk) disable iff (!rst_n)
          (sys_fetch_context_refresh_needed && !fetch_trans_busy)
          |-> sys_fetch_redirect);
      assert property (@(posedge clk) disable iff (!rst_n)
          (sys_fetch_context_refresh_needed && !fetch_trans_busy)
          |=> (fetch_epoch == ($past(fetch_epoch) + 1'b1) &&
               fetch_epoch != $past(ifid_token_epoch)));
      assert property (@(posedge clk) disable iff (!rst_n)
          sys_fetch_context_refresh_needed |-> !fetch_next_settled);
      assert property (@(posedge clk) disable iff (!rst_n)
          (sys_fetch_context_change &&
           (d.sys_reg != SREG_SCTLR_EL1 || d.sys_wdata[0]) &&
           mmu_en_eff &&
           fetch_next_settled)
          |-> (fetch_epoch != ifid_token_epoch));
      // A fault merged into one of the five translation-context MSRs must
      // retain that MSR's architectural write at the same commit edge.
      assert property (@(posedge clk) disable iff (!rst_n)
          (sys_fetch_context_msr_merge && d.sys_reg == SREG_SCTLR_EL1)
          |=> (sctlr_el1 == ($past(d.sys_wdata) & SCTLR_EL1_WRITE_MASK)));
      assert property (@(posedge clk) disable iff (!rst_n)
          (sys_fetch_context_msr_merge && d.sys_reg == SREG_TCR_EL1)
          |=> (tcr_el1 == $past(d.sys_wdata)));
      assert property (@(posedge clk) disable iff (!rst_n)
          (sys_fetch_context_msr_merge && d.sys_reg == SREG_TTBR0_EL1)
          |=> (ttbr0_el1 == $past(d.sys_wdata)));
      assert property (@(posedge clk) disable iff (!rst_n)
          (sys_fetch_context_msr_merge && d.sys_reg == SREG_TTBR1_EL1)
          |=> (ttbr1_el1 == $past(d.sys_wdata)));
      assert property (@(posedge clk) disable iff (!rst_n)
          (sys_fetch_context_msr_merge && d.sys_reg == SREG_MAIR_EL1)
          |=> (mair_el1 == $past(d.sys_wdata)));
      assert property (@(posedge clk) disable iff (!rst_n)
          (sys_commit && d.sys_op == SYS_MSR &&
           d.sys_reg == SREG_SCTLR_EL1 && !d.sys_wdata[0])
          |-> !sys_fetch_merge);
      assert property (@(posedge clk) disable iff (!rst_n)
          (sys_commit && d.sys_op == SYS_MSR &&
           d.sys_reg == SREG_SCTLR_EL1 && !d.sys_wdata[0])
          |=> (sctlr_el1[0] == 1'b0));
      // A not-ready consumer stalls the frontend only after MEM/WB actually
      // holds an item.  When WB is empty, FIFO/IFID may continue to advance;
      // otherwise a ready transition would turn a valid IFID entry into a
      // bubble without a transfer (H-04).
      assert property (@(posedge clk) disable iff (!rst_n)
          (memwb_valid && !commit_ready) |-> !fetch_fifo_pop);
      // Use the actual FIFO pop fire rather than count!=0: the fire predicate
      // already excludes a fault head, stale entry, system hold, and every
      // other non-consumable condition (H-03 must not trigger this H-04 SVA).
      // A ready-low transition must atomically transfer both sides of the
      // elastic boundary: the sampled IF/ID token enters ID/EX and the
      // sampled FIFO head replaces IF/ID.  The consequent is sampled before
      // the following edge updates state, so a kill decoded from either new
      // pipeline entry cannot hide a bad transfer.
      assert property (@(posedge clk) disable iff (!rst_n)
          (!commit_ready && !memwb_valid && ifid_valid &&
           fetch_fifo_pop && !fetch_fifo_head_fault && !frontend_kill)
          |=> (idex_valid &&
               idex_token_epoch == $past(ifid_token_epoch) &&
               idex_token_seq == $past(ifid_token_seq) &&
               idex_pc == $past(ifid_pc) &&
               ifid_valid &&
               ifid_token_epoch == $past(fetch_fifo_head_epoch_dbg) &&
               ifid_token_seq == $past(fetch_fifo_head_seq_dbg) &&
               ifid_pc == $past(fetch_fifo_head_pc_dbg)));
      assert property (@(posedge clk) disable iff (!rst_n)
          frontend_kill |=>
            (fetch_epoch == ($past(fetch_epoch) + 1'b1)));
      // A younger data transaction may hold this older WB entry in F1a. Once
      // the entry commits while that hold is active, the committed marker must
      // survive the hold so the same token cannot commit again next cycle.
      assert property (@(posedge clk) disable iff (!rst_n)
          (commit_fire && dmem_pending) |=> memwb_committed_r);
      assert property (@(posedge clk) disable iff (!rst_n)
          (commit_fire && dmem_pending) |=> !commit_fire);
      // Diagnostic tokens, rather than PC, identify dynamic instructions.
      // A tight self-loop may legally place different instances of the same
      // PC in adjacent stages, so PC equality cannot prove duplication.  The
      // epoch/sequence checks below keep the actual no-duplicate invariant at
      // every adjacent FIFO-on boundary and at consecutive commits.
      assert property (@(posedge clk) disable iff (!rst_n)
          !(ifid_valid && idex_valid &&
            ifid_token_epoch == idex_token_epoch &&
            ifid_token_seq == idex_token_seq));
      assert property (@(posedge clk) disable iff (!rst_n)
          !(idex_valid && exmem_valid &&
            idex_token_epoch == exmem_token_epoch &&
            idex_token_seq == exmem_token_seq));
      assert property (@(posedge clk) disable iff (!rst_n)
          !(exmem_valid && memwb_valid &&
            exmem_token_epoch == memwb_token_epoch &&
            exmem_token_seq == memwb_token_seq));
      assert property (@(posedge clk) disable iff (!rst_n)
          (dbg_commit_fire && $past(dbg_commit_fire)) |->
            (commit_token_epoch != $past(commit_token_epoch) ||
             commit_token_seq != $past(commit_token_seq)));
    end
  endgenerate
  /* verilator lint_on SYNCASYNCNET */

endmodule
