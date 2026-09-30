// lcvex_mmu.sv
// P5a EL1 MMU：4 KiB 页表遍历 + 基础全相联 TLB + 权限检查。
//
// 支持范围（P5a 简化）：
//   - 4 KiB 颗粒，25–48 位输入虚拟地址，TTBR0/TTBR1 双区域
//     （区域划分和 L0/L1/L2 起始级别均按 TCR.T0SZ/T1SZ）；
//   - L0/L1/L2 表描述符与 L3 页描述符；L1（1 GB）/L2（2 MB）块描述符
//     （P6/Linux 前 R1：QEMU 4K 颗粒下 level 1/2 块合法）；
//   - AP/UXN/PXN 权限检查，AF 必须置位（QEMU 一致语义）；
//   - MAIR 属性（M2-4c）：按页描述符 AttrIndx[4:2] 索引 MAIR_EL1 的 8 位
//     属性，Device（memtype 0..3）与 Normal Non-cacheable（0b0100）输出
//     cacheable=0（旁路 L1/L2）；其余 Normal（WT/WB 等）cacheable=1。
//   - 翻译结果 PA 超出 SRAM/已实现 MMIO 窗口视为 fault；
//   - 全相联 TLB（TLB_ENTRIES 项，ASID=0，不区分 I/D）；
//   - TLBI：tlb_invalidate 脉冲整表失效（M2-4b；正在进行的遍历一并中止，
//     由软件保证 DSB/ISB 排空后维护顺序）；abort 仅取消当前请求，保留 TLB，
//     并在已有 PTW response 到达前进入 quarantine，避免 mem_arb 残留响应堵塞。
//
// 握手：core 在 req_valid=1 且 req_accept=1 的周期把请求交给 MMU；
// MMU 处理后 done 输出一个周期（busy && S_IDLE），core 必须在该周期
// 锁存 paddr/fault 并撤销 req_valid。请求先经 S_IDLE 锁存到 req_va_r，
// 再在 S_EVAL 做 TLB/权限/直通判定，因此 TLB 命中/直通为 2 周期出结果，
// 4 级遍历约 9 周期。该切级用于打断 core 的地址生成/前递组合直接打到
// fault_fsc_r。

`timescale 1ns/1ps

/* P5a：TCR 仅使用 T0SZ/T1SZ，MAIR 保留（无 Cache），其余位由核心
 * 保存，这里不做属性建模。 */
/* verilator lint_off UNUSEDSIGNAL */

module lcvex_mmu #(
    parameter int               TLB_ENTRIES = 8,
    parameter logic [63:0]      SRAM_BASE   = 64'h0000_0000_4000_0000,
    parameter logic [63:0]      SRAM_TOP    = 64'h0000_0000_4800_0000,
    parameter logic [63:0]      MMIO_BASE   = 64'h0000_0000_0900_0000,
    parameter logic [63:0]      MMIO_TOP    = 64'h0000_0000_0900_1000,
    parameter logic [63:0]      MMIO2_BASE  = 64'h0000_0000_0800_0000,
    parameter logic [63:0]      MMIO2_TOP   = 64'h0000_0000_0802_1000,
    parameter logic [63:0]      MMIO3_BASE  = 64'h0000_0000_0903_0000,
    parameter logic [63:0]      MMIO3_TOP   = 64'h0000_0000_0903_1000,
    parameter logic [63:0]      MMIO4_BASE  = 64'h0000_0000_0901_0000,
    parameter logic [63:0]      MMIO4_TOP   = 64'h0000_0000_0a02_0000
) (
    input  logic                clk,
    input  logic                rst_n,

    // 翻译请求
    input  logic                req_valid,
    input  logic [63:0]         req_va,
    input  logic                req_is_insn,
    input  logic                req_is_write,
    output logic                req_accept,

    // 结果（done 保持到 req_valid 撤销）
    output logic                done,
    output logic [63:0]         paddr,
    output logic                fault,
    output logic [5:0]          fault_fsc,  // 长格式 FSC（R1：ESR ISS 低 6 位）
    output logic                walking,    // 正在页表遍历（需冻结流水线）
    output logic                cacheable,  // 1=Normal 可缓存（M2-4c）
    output logic [7:0]          par_attr,   // AT PAR[63:56] ATTR
    output logic [1:0]          par_sh,     // AT PAR[8:7] SH

    // MMU 状态
    input  logic                mmu_en,
    input  logic [63:0]         tcr_el1,
    input  logic [63:0]         ttbr0_el1,
    input  logic [63:0]         ttbr1_el1,
    input  logic [63:0]         mair_el1,   // 保留（无 Cache，暂不用于属性）
    input  logic                access_el,  // 1=EL1 0=EL0
    input  logic                pan,        // PSTATE.PAN（仅 EL1 数据权限）
    // TLBI：1 周期脉冲整表失效（M2-4b）
    input  logic                tlb_invalidate,
    // core precise IRQ/flush：取消当前翻译但不清 TLB；若 PTW 已接受，
    // 进入 quarantine 并保持 ptw_rsp_ready 直到旧 response 被消费。
    input  logic                abort,

    // 页表读口（M1-B request/response：valid/ready + rdata/fault）
    output logic                ptw_req_valid,
    output lcvex_pkg::mem_req_t ptw_req,
    input  logic                ptw_req_ready,
    input  logic                ptw_rsp_valid,
    input  lcvex_pkg::mem_rsp_t ptw_rsp,
    output logic                ptw_rsp_ready
);

  import lcvex_pkg::*;

  typedef enum logic [3:0] {
    S_IDLE,
    S_EVAL,      // 请求已锁存，下一拍用 req_va_r 做 TLB/权限/直通判定
    S_L0_REQ, S_L0_WAIT,
    S_L1_REQ, S_L1_WAIT,
    S_L2_REQ, S_L2_WAIT,
    S_L3_REQ, S_L3_WAIT,
    S_COMPLETE,  // 块/页描述符权限与 TLB 填充（统一完成态）
    S_ABORT_WAIT // 已接受 PTW 的旧 response drain，不产生 done/fault
  } state_t;

  state_t state;
  logic [63:0] req_va_r;
  logic [1:0]  walk_level_r;       // 完成描述符所在级别：1=1GB 块 2=2MB 块 3=页
  logic [1:0]  walk_start_level_r; // 本次 walk 的起始级别（TCR 输入地址宽度）
  logic        req_is_insn_r;
  logic        req_is_write_r;
  logic        req_el_r;
  logic        req_pan_r;

  logic [63:0] table_base;
  logic [63:0] desc;
  logic        desc_valid;   // bit0
  logic        desc_block;   // bit1==0 且非 L3（块描述符，暂不支持）
  logic [63:0] next_base;
  logic [1:0]  ap;
  logic        uxn, pxn;

  // TLB
  logic [47:12] tlb_tag[TLB_ENTRIES];
  logic [47:12] tlb_pa[TLB_ENTRIES];
  logic [1:0]   tlb_ap[TLB_ENTRIES];
  logic         tlb_uxn[TLB_ENTRIES];
  logic         tlb_pxn[TLB_ENTRIES];
  logic         tlb_valid[TLB_ENTRIES];
  logic         tlb_cacheable[TLB_ENTRIES];
  logic [7:0]   tlb_par_attr[TLB_ENTRIES];
  logic [1:0]   tlb_par_sh[TLB_ENTRIES];
  logic [1:0]   tlb_level[TLB_ENTRIES];  // 描述符级别（1/2/3，权限 fault 用）
  logic         tlb_hit;
  logic [$clog2(TLB_ENTRIES)-1:0] tlb_hit_idx;
  integer       tlb_fill_idx;

  logic         busy;         // 请求已接收、结果未出
  logic         fault_r;      // 结果锁存
  logic [63:0]  paddr_r;
  logic         cacheable_r;
  logic [5:0]   fault_fsc_r;
  logic [7:0]   par_attr_r;
  logic [1:0]   par_sh_r;

  // ---- 块/页描述符输出地址（R1）----
  // PA = {desc OA[47:N], va[N-1:0]}，N=30(L1 块)/21(L2 块)/12(L3 页)。
  function automatic logic [63:0] desc_pa(input logic [63:0] d,
                                          input logic [63:0] va,
                                          input logic [1:0]  lvl);
    unique case (lvl)
      2'd1: desc_pa = {16'd0, d[47:30], va[29:0]};
      2'd2: desc_pa = {16'd0, d[47:21], va[20:0]};
      default: desc_pa = {16'd0, d[47:12], va[11:0]};
    endcase
  endfunction
  // TLB 记录的 4 KiB 页基址（[47:12]）
  function automatic logic [35:0] desc_pa_page(input logic [63:0] d,
                                               input logic [63:0] va,
                                               input logic [1:0]  lvl);
    unique case (lvl)
      2'd1: desc_pa_page = {d[47:30], va[29:12]};
      2'd2: desc_pa_page = {d[47:21], va[20:12]};
      default: desc_pa_page = d[47:12];
    endcase
  endfunction

  // ---- MAIR 属性（组合）----
  // memtype = attr[3:0]：0..3=Device，4=Normal NC，5..15=Normal 可缓存。
  function automatic logic attr_cacheable(input logic [7:0] attr);
    attr_cacheable = !(attr[3:0] inside {4'b0000, 4'b0001, 4'b0010,
                                         4'b0011, 4'b0100});
  endfunction
  // 页描述符 AttrIndx[4:2] 索引 MAIR_EL1 8 位属性项
  function automatic logic desc_cacheable(input logic [63:0] d);
    logic [7:0] a;
    a = mair_el1[({3'd0, d[4:2]} * 8) +: 8];
    desc_cacheable = attr_cacheable(a);
  endfunction

  // P6：PA 落在 RAM 或 MMIO 窗口内为合法物理地址
  function automatic logic pa_in_window(input logic [63:0] pa);
    pa_in_window = (pa >= SRAM_BASE && pa < SRAM_TOP) ||
                   (pa >= MMIO_BASE && pa < MMIO_TOP) ||
                   (pa >= MMIO2_BASE && pa < MMIO2_TOP) ||
                   (pa >= MMIO3_BASE && pa < MMIO3_TOP) ||
                   (pa >= MMIO4_BASE && pa < MMIO4_TOP);
  endfunction

  // MMIO 强制不可缓存（QEMU 设备访问不缓存）
  function automatic logic pa_cacheable(input logic [63:0] pa,
                                        input logic [63:0] d);
    pa_cacheable = desc_cacheable(d) &&
                   (pa >= SRAM_BASE && pa < SRAM_TOP);
  endfunction

  // QEMU PAREncodeShareability(): Device and Normal-NC force Inner
  // Shareable (SH=2); Normal cacheable pages retain descriptor SH.
  function automatic logic [1:0] desc_par_sh(input logic [63:0] d);
    logic [7:0] attr;
    attr = mair_el1[({3'd0, d[4:2]} * 8) +: 8];
    if ((attr[7:4] == 4'd0) || attr == 8'h44 || attr == 8'h40)
      desc_par_sh = 2'd2;
    else
      desc_par_sh = d[9:8];
  endfunction

  // ---- 区域选择与表基址 ----
  logic [5:0] t0sz, t1sz;
  logic [63:0] t0_end, t1_start;
  logic use_ttbr0;
  logic [6:0] input_size_comb;
  logic [1:0] start_level_comb;
  assign t0sz = tcr_el1[5:0];
  assign t1sz = tcr_el1[21:16];
  assign t0_end   = 64'd1 << (64 - t0sz);
  assign t1_start = ~(64'd1 << (64 - t1sz)) + 64'd1;
  assign use_ttbr0 = (req_va_r < t0_end);
  // 4 KiB granule 的起始级别由输入地址宽度决定：48 位从 L0，
  // 39 位从 L1。Linux arm64 常用 T0SZ/T1SZ=25，若固定从 L0
  // 会把 VA[38:30] 的有效根表项误当作无效的 VA[47:39] 项。
  // 请求已先在 S_IDLE 锁存到 req_va_r，S_EVAL 再按该锁存地址判定，
  // 避免来自 core 的地址生成/前递组合直接打到 fault_fsc_r。
  assign input_size_comb = 7'd64 -
                           {1'b0, (use_ttbr0 ? t0sz : t1sz)};
  always_comb begin
    if (input_size_comb > 7'd39)
      start_level_comb = 2'd0;
    else if (input_size_comb > 7'd30)
      start_level_comb = 2'd1;
    else if (input_size_comb > 7'd21)
      start_level_comb = 2'd2;
    else
      start_level_comb = 2'd3;
  end
  assign table_base = (use_ttbr0 ? ttbr0_el1 : ttbr1_el1) & 64'h0000_FFFF_FFFF_F000;

  // ---- 权限检查（组合）----
  function automatic logic perm_fault(input logic [1:0] ap_in,
                                      input logic uxn_in,
                                      input logic pxn_in,
                                      input logic is_insn_in,
                                      input logic is_write_in,
                                      input logic el_in,
                                      input logic pan_in);
    if (is_insn_in) begin
      // QEMU get_S1prot（AArch64）：
      //   EL0 取指要求 EL0 读权限（AP=01/11）且 UXN=0；
      //   EL1 取指要求 PXN=0 且页面不可被 EL0 写（AP!=01）。
      perm_fault = el_in ? (pxn_in || (ap_in == 2'b01))
                         : (uxn_in || (ap_in != 2'b01 && ap_in != 2'b11));
    end else if (el_in) begin
      // EL1 数据（QEMU simple_ap_to_rw_prot, is_user=0）：
      //   PAN=1 时拒绝 EL0 可访问页（AP=01/11）；否则读全部 AP
      //   允许，写仅 AP=00/01（RW 页）。
      perm_fault = pan_in && (ap_in == 2'b01 || ap_in == 2'b11)
                   ? 1'b1
                   : is_write_in ? (ap_in == 2'b00 || ap_in == 2'b01
                                    ? 1'b0 : 1'b1)
                                 : 1'b0;
    end else begin
      // EL0 数据（simple_ap_to_rw_prot, is_user=1）：
      //   读仅 AP=01/11；写仅 AP=01。
      perm_fault = is_write_in ? (ap_in == 2'b01 ? 1'b0 : 1'b1)
                               : (ap_in == 2'b01 || ap_in == 2'b11
                                  ? 1'b0 : 1'b1);
    end
  endfunction

  // ---- TLB 查找（组合，对输入 req_va 判断；请求被接收时使用）----
  always_comb begin
    tlb_hit = 1'b0;
    tlb_hit_idx = '0;
    for (int i = 0; i < TLB_ENTRIES; i++) begin
      if (tlb_valid[i] && tlb_tag[i] == req_va_r[47:12]) begin
        tlb_hit = 1'b1;
        tlb_hit_idx = i[$clog2(TLB_ENTRIES)-1:0];
      end
    end
  end

  // ---- 主状态机 ----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE;
      busy  <= 1'b0;
      fault_r <= 1'b0;
      paddr_r <= 64'd0;
      cacheable_r <= 1'b1;
      fault_fsc_r <= 6'd0;
      par_attr_r <= 8'd0;
      par_sh_r <= 2'd0;
      walk_level_r <= 2'd3;
      walk_start_level_r <= 2'd0;
      req_va_r <= 64'd0;
      req_is_insn_r <= 1'b0;
      req_is_write_r <= 1'b0;
      req_el_r <= 1'b1;
      req_pan_r <= 1'b0;
      for (int i = 0; i < TLB_ENTRIES; i++) begin
        tlb_valid[i] <= 1'b0;
      end
      tlb_fill_idx <= 0;
    end else begin
      if (tlb_invalidate) begin
        // TLBI：整表失效；中止在途遍历（结果作废，核心不会依赖）。
        for (int i = 0; i < TLB_ENTRIES; i++) begin
          tlb_valid[i] <= 1'b0;
        end
        state    <= S_IDLE;
        busy     <= 1'b0;
        fault_r  <= 1'b0;
        paddr_r  <= 64'd0;
      end else if (abort) begin
        // Precise IRQ/flush abort.  TLB entries are architectural-invisible
        // performance state and must survive; only the current request's
        // result is discarded.  A request in S_*_REQ has not been accepted
        // yet, whereas S_*_WAIT means mem_arb accepted the PTW read.
        fault_r      <= 1'b0;
        paddr_r       <= 64'd0;
        cacheable_r   <= 1'b1;
        fault_fsc_r   <= 6'd0;
        par_attr_r    <= 8'd0;
        par_sh_r      <= 2'd0;
        if (state inside {S_L0_WAIT, S_L1_WAIT, S_L2_WAIT, S_L3_WAIT,
                          S_ABORT_WAIT}) begin
          if (ptw_rsp_valid && ptw_rsp_ready) begin
            // Abort and old response coincide: consume/drop it now and make
            // the next cycle available for the IRQ vector translation.
            state <= S_IDLE;
            busy  <= 1'b0;
          end else begin
            // Keep response-ready asserted in quarantine until the arbiter
            // releases the already accepted read.
            state <= S_ABORT_WAIT;
            busy  <= 1'b1;
          end
        end else begin
          // No accepted PTW exists in ID/EVAL/REQ/COMPLETE; no drain needed.
          state <= S_IDLE;
          busy  <= 1'b0;
        end
      end else begin
        case (state)
          S_IDLE: begin
            // 只锁存请求。TLB/权限/直通判定统一放到 S_EVAL，避免
            // core 的前递/地址生成组合链在同一拍打到 fault_fsc_r 的 D。
            if (req_valid && !busy) begin
              req_va_r <= req_va;
              req_is_insn_r <= req_is_insn;
              req_is_write_r <= req_is_write;
              req_el_r <= access_el;
              req_pan_r <= pan;
              busy <= 1'b1;
              fault_r <= 1'b0;
              paddr_r <= 64'd0;
              cacheable_r <= 1'b1;
              state <= S_EVAL;
            end
          end

          S_EVAL: begin
            if (!mmu_en) begin
              // 直通：VA=PA，无 fault
              paddr_r <= req_va_r;
              cacheable_r <= 1'b1;   // 直接访问统一视为 Normal 可缓存
              fault_fsc_r <= 6'd0;
              par_attr_r <= 8'd0;
              par_sh_r <= 2'd0;
              state <= S_IDLE;
            end else if (tlb_hit) begin
              // TLB 命中：检查权限
              paddr_r <= {16'd0, tlb_pa[tlb_hit_idx], req_va_r[11:0]};
              cacheable_r <= tlb_cacheable[tlb_hit_idx];
              par_attr_r <= tlb_par_attr[tlb_hit_idx];
              par_sh_r <= tlb_par_sh[tlb_hit_idx];
              fault_fsc_r <= perm_fault(tlb_ap[tlb_hit_idx],
                                        tlb_uxn[tlb_hit_idx],
                                        tlb_pxn[tlb_hit_idx],
                                        req_is_insn_r, req_is_write_r,
                                        req_el_r, req_pan_r)
                             ? (6'd12 + {4'd0, tlb_level[tlb_hit_idx]})
                             : 6'd0;
              fault_r <= perm_fault(tlb_ap[tlb_hit_idx],
                                    tlb_uxn[tlb_hit_idx],
                                    tlb_pxn[tlb_hit_idx],
                                    req_is_insn_r, req_is_write_r,
                                    req_el_r, req_pan_r);
              state <= S_IDLE;
            end else if ((64 - (use_ttbr0 ? 32'(t0sz) : 32'(t1sz))) > 48) begin
              // TxSZ 使 inputsize > 48（超出支持范围）：QEMU tsz_oob ->
              // 翻译 fault level 0（FSC=0x04）
              fault_r <= 1'b1;
              fault_fsc_r <= 6'd4;
              state <= S_IDLE;
            end else if (req_va_r >= t0_end && req_va_r < t1_start) begin
              // TTBR0/TTBR1 区域 gap（非 canonical）：同样 level 0 翻译 fault
              fault_r <= 1'b1;
              fault_fsc_r <= 6'd4;
              state <= S_IDLE;
            end else begin
              // TLB 未命中：按 TCR 输入地址宽度选择起始级别。
              walk_start_level_r <= start_level_comb;
              unique case (start_level_comb)
                2'd0: state <= S_L0_REQ;
                2'd1: state <= S_L1_REQ;
                2'd2: state <= S_L2_REQ;
                default: state <= S_L3_REQ;
              endcase
            end
          end

          // 请求被下游接受后进入 WAIT（可变延迟）
          S_L0_REQ: if (ptw_req_ready) state <= S_L0_WAIT;
          S_L1_REQ: if (ptw_req_ready) state <= S_L1_WAIT;
          S_L2_REQ: if (ptw_req_ready) state <= S_L2_WAIT;
          S_L3_REQ: if (ptw_req_ready) state <= S_L3_WAIT;

          S_L0_WAIT: begin
            if (ptw_rsp_valid && ptw_rsp_ready) begin
              if (ptw_rsp.fault || !ptw_rsp.rdata[0] ||
                  !ptw_rsp.rdata[1]) begin
                // 读口 fault / 无效 / L0 块描述符（4K 颗粒下不支持）-> fault
                fault_r <= 1'b1;
                fault_fsc_r <= 6'd4;   // 翻译 fault level 0
                state <= S_IDLE;
              end else begin
                desc <= ptw_rsp.rdata;
                state <= S_L1_REQ;
              end
            end
          end

          S_L1_WAIT, S_L2_WAIT: begin
            if (ptw_rsp_valid && ptw_rsp_ready) begin
              if (ptw_rsp.fault || !ptw_rsp.rdata[0]) begin
                fault_r <= 1'b1;
                fault_fsc_r <= (state == S_L1_WAIT) ? 6'd5 : 6'd6;
                state <= S_IDLE;
              end else if (ptw_rsp.rdata[1]) begin
                // 表描述符：进入下一级
                desc <= ptw_rsp.rdata;
                state <= (state == S_L1_WAIT) ? S_L2_REQ : S_L3_REQ;
              end else begin
                // 块描述符：L1=1 GB（1GB 对齐），L2=2 MB（2MB 对齐）
                desc <= ptw_rsp.rdata;
                walk_level_r <= (state == S_L1_WAIT) ? 2'd1 : 2'd2;
                state <= S_COMPLETE;
              end
            end
          end

          S_L3_WAIT: begin
            if (ptw_rsp_valid && ptw_rsp_ready) begin
              if (ptw_rsp.fault || !ptw_rsp.rdata[0] ||
                  !ptw_rsp.rdata[1]) begin
                // 读口 fault / 无效 / L3 非页描述符 -> fault
                fault_r <= 1'b1;
                fault_fsc_r <= 6'd7;   // 翻译 fault level 3
                state <= S_IDLE;
              end else begin
                desc <= ptw_rsp.rdata;
                walk_level_r <= 2'd3;
                state <= S_COMPLETE;
              end
            end
          end

          S_ABORT_WAIT: begin
            // The abort edge only cancels the owner; once abort is released,
            // consume the already accepted PTW response before reopening the
            // request side.  The response is intentionally ignored.
            if (ptw_rsp_valid && ptw_rsp_ready) begin
              state <= S_IDLE;
              busy  <= 1'b0;
            end
          end

          S_COMPLETE: begin
            // 块/页描述符统一完成：AF（QEMU HA=0 语义）、权限、PA 越界
            // 检查与 TLB 填充。desc/walk_level_r 已在前一级锁存。
            if (!desc[10]) begin
              fault_r <= 1'b1;
              fault_fsc_r <= 6'd8 + {4'd0, walk_level_r};   // AF fault
            end else begin
              paddr_r <= desc_pa(desc, req_va_r, walk_level_r);
              cacheable_r <= pa_cacheable(desc_pa(desc, req_va_r, walk_level_r),
                                          desc);
              par_attr_r <= mair_el1[({3'd0, desc[4:2]} * 8) +: 8];
              par_sh_r <= desc_par_sh(desc);
              fault_fsc_r <= 6'd0;
              fault_r <= perm_fault(desc[7:6], desc[54], desc[53],
                                    req_is_insn_r, req_is_write_r, req_el_r,
                                    req_pan_r);
              if (perm_fault(desc[7:6], desc[54], desc[53],
                             req_is_insn_r, req_is_write_r, req_el_r,
                             req_pan_r)) begin
                fault_fsc_r <= 6'd12 + {4'd0, walk_level_r};  // 权限 fault
              end
              if (!pa_in_window(desc_pa(desc, req_va_r, walk_level_r))) begin
                fault_r <= 1'b1;
                // 输出 PA 不在 RAM/MMIO：QEMU 报同步外部中止（0x10）
                fault_fsc_r <= 6'h10;
              end
              tlb_tag[tlb_fill_idx] <= req_va_r[47:12];
              tlb_pa[tlb_fill_idx]  <= desc_pa_page(desc, req_va_r,
                                                    walk_level_r);
              tlb_ap[tlb_fill_idx]  <= desc[7:6];
              tlb_uxn[tlb_fill_idx] <= desc[54];
              tlb_pxn[tlb_fill_idx] <= desc[53];
              tlb_valid[tlb_fill_idx] <= 1'b1;
              tlb_cacheable[tlb_fill_idx] <=
                  pa_cacheable(desc_pa(desc, req_va_r, walk_level_r), desc);
              tlb_par_attr[tlb_fill_idx] <=
                  mair_el1[({3'd0, desc[4:2]} * 8) +: 8];
              tlb_par_sh[tlb_fill_idx] <= desc_par_sh(desc);
              tlb_level[tlb_fill_idx] <= walk_level_r;
              tlb_fill_idx <= (tlb_fill_idx + 1) % TLB_ENTRIES;
            end
            state <= S_IDLE;
          end

          default: state <= S_IDLE;
        endcase

        // done 输出一个周期后清 busy（core 同步取走结果）
        if (busy && state == S_IDLE) begin
          busy <= 1'b0;
        end
      end
    end
  end

  // ---- 页表读地址与请求 ----
  logic [63:0] level_addr;
  always_comb begin
    level_addr = 64'd0;
    unique case (state)
      S_L0_REQ: level_addr = table_base + {55'd0, req_va_r[47:39]} * 8;
      S_L1_REQ: level_addr = (walk_start_level_r == 2'd1
                              ? table_base
                              : {16'd0, desc[47:12], 12'd0}) +
                             {55'd0, req_va_r[38:30]} * 8;
      S_L2_REQ: level_addr = (walk_start_level_r == 2'd2
                              ? table_base
                              : {16'd0, desc[47:12], 12'd0}) +
                             {55'd0, req_va_r[29:21]} * 8;
      S_L3_REQ: level_addr = (walk_start_level_r == 2'd3
                              ? table_base
                              : {16'd0, desc[47:12], 12'd0}) +
                             {55'd0, req_va_r[20:12]} * 8;
      default: level_addr = 64'd0;
    endcase
  end

  // Abort is combinationally visible at the arbiter boundary so a PTW in
  // S_*_REQ cannot be accepted on the same edge that enters abort handling.
  assign ptw_req_valid = (state inside {S_L0_REQ, S_L1_REQ, S_L2_REQ,
                                        S_L3_REQ}) && !abort;
  assign ptw_req = '{addr: level_addr, we: 1'b0, strb: 8'h00, wdata: '0, maint: MAINT_NONE, bypass: 1'b0};
  assign ptw_rsp_ready = (state inside {S_L0_WAIT, S_L1_WAIT, S_L2_WAIT,
                                        S_L3_WAIT, S_ABORT_WAIT});

  assign req_accept = (state == S_IDLE) && !busy && !done;
  assign done = busy && (state == S_IDLE);
  assign walking = (state inside {S_L0_REQ, S_L0_WAIT, S_L1_REQ, S_L1_WAIT,
                                  S_L2_REQ, S_L2_WAIT, S_L3_REQ, S_L3_WAIT,
                                  S_COMPLETE, S_ABORT_WAIT});
  assign paddr = paddr_r;
  assign fault = fault_r;
  assign cacheable = cacheable_r;
  assign fault_fsc = fault_fsc_r;
  assign par_attr = par_attr_r;
  assign par_sh = par_sh_r;

  // Abort/quarantine protocol invariants.  The request side is suppressed
  // immediately, while an accepted PTW response remains consumable until the
  // MMU returns to S_IDLE.  No aborted result may be exposed as done/fault.
  assert property (@(posedge clk) disable iff (!rst_n)
      abort |-> !ptw_req_valid);
  assert property (@(posedge clk) disable iff (!rst_n)
      state == S_ABORT_WAIT |-> (ptw_rsp_ready && !done));
  assert property (@(posedge clk) disable iff (!rst_n)
      (abort && (state inside {S_L0_WAIT, S_L1_WAIT, S_L2_WAIT, S_L3_WAIT,
                               S_ABORT_WAIT}) && !ptw_rsp_valid)
      |=> (state == S_ABORT_WAIT && ptw_rsp_ready && !done));

endmodule
