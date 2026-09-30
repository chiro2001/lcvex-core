// lcvex_gic.sv
// GICv2 兼容模型（QEMU virt, gic-version=2, 单核无安全扩展）。
// 语义按 QEMU 11.1.0 hw/intc/arm_gic.c 复刻（探针复位值见 handoff 038）：
//   - GICD（0x08000000..0x08010000）：CTLR/TYPER/IIDR/IGROUPR/
//     ISENABLER/ICENABLER/ISPENDR/ICPENDR/ISACTIVER/ICACTIVER/
//     IPRIORITYR/ITARGETSR(单核 RAZ/WI)/ICFGR/SGIR/SPENDSGIR/CPENDSGIR；
//   - GICC（0x08010000..0x08020000）：CTLR/PMR/BPR/IAR/EOIR/RPR/HPPIR/
//     ABPR/IIDR；GICv2m MSI frame（0x08020000..0x08021000）只读探测
//     寄存器按 QEMU 返回，SETSPI_NS 对当前建模 SPI 范围提供最小写入；
//   - CPU 接口：best_irq = enabled && pending && !active，优先级低值高，
//     升序扫描低编号优先；current_pending 需 best_prio < PMR；
//     IRQ 线 = best_prio < PMR && best_prio < running && 组使能；
//     IAR 确认并置 active/清 pending（edge），EOI 清 active；
//   - 复位值（探针）：GICD_CTLR=0 TYPER=0x8 IIDR=0x43b ISENABLER0=0xffff
//     ICFGR0=0xaaaaaaaa；GICC_CTLR/PMR/BPR=0 ABPR=1 IIDR=0x2043b，
//     IAR/HPPIR=0x3ff RPR=0xff（空闲）。

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */
module lcvex_gic #(
    parameter logic [63:0] GICD_BASE = 64'h0000_0000_0800_0000,
    parameter logic [63:0] GICC_BASE = 64'h0000_0000_0801_0000,
    parameter int          NUM_IRQ   = 96
) (
    input  logic                clk,
    input  logic                rst_n,
    // M1-B 从端口（路由上游 -> 本设备）
    input  logic                req_valid,
    input  lcvex_pkg::mem_req_t req,
    output logic                req_accept,
    output logic                rsp_valid,
    output lcvex_pkg::mem_rsp_t rsp,
    input  logic                rsp_ready,
    // 电平输入：PPI 30（非安全物理定时器）/ PPI 27（虚拟定时器）
    input  logic [1:0]          level_ppi,
    // Level-sensitive external IRQs for INTID 32..NUM_IRQ-1, indexed from 0.
    input  logic [NUM_IRQ-32-1:0] level_spi,
    // CPU 中断输出
    output logic                irq,
    output logic                fiq
);

  import lcvex_pkg::*;

  localparam int N = NUM_IRQ;
  localparam logic [9:0] SPURIOUS = 10'd1023;
  localparam logic [63:0] GICV2M_BASE = 64'h0000_0000_0802_0000;
  localparam logic [63:0] GICV2M_TOP  = 64'h0000_0000_0802_1000;

  // ---- 状态 ----
  logic [1:0]  ctlr_r;        // GICD_CTLR（EN_GRP0/1）
  logic [8:0]  cpu_ctlr_r;    // GICC_CTLR（掩 0x21f）
  logic [7:0]  pmr_r;         // GICC_PMR
  logic [2:0]  bpr_r;         // GICC_BPR
  logic [2:0]  abpr_r;        // GICC_ABPR（复位 1，探针）
  logic [N-1:0] enabled_r;
  logic [N-1:0] pending_r;
  logic [N-1:0] active_r;
  logic [N-1:0] edge_r;       // ICFGR bit1（1=edge）
  logic [N-1:0] level_r;      // ICFGR bit0（1=level，QEMU model）
  logic [N-1:0] group_r;      // IGROUPR（0=Group0）
  logic [7:0]  prio_r[N];

  logic        rsp_pending;
  logic [63:0] rdata_r;
  logic        fault_r;

  // ---- 电平输入映射 ----
  function automatic logic level_line(input int i);
    level_line = 1'b0;
    if (i == 30) level_line = level_ppi[0];
    if (i == 27) level_line = level_ppi[1];
    if ((i >= 32) && (i < N)) level_line = level_spi[i-32];
  endfunction

  // QEMU gic_test_pending：pending 位或电平触发线保持
  function automatic logic test_pending(input int i);
    test_pending = pending_r[i] ||
                   (((i == 30) || (i == 27) || (i >= 32)) && level_line(i)) ||
                   (level_r[i] && !edge_r[i] && level_line(i));
  endfunction

  // ---- best_irq（QEMU gic_get_best_irq：低优先级值优先，低编号破平）----
  //
  // 25 MHz 板级 STA 显示原先的 96 次串行比较会形成 143 ns 组合链
  // （soc|board_gic|active_r[0] -> pending_r[30]，-103.394 ns）。这里把
  // 「最低优先级 + 最低编号」编码成一个 key，用平衡锦标赛树归约，功能与
  // QEMU 逐项扫描完全等价（相同优先级取最低编号，未命中时返回 0x100/N）。
  localparam int RED_LEAVES = 128;   // 2^7，必须 >= NUM_IRQ
  localparam int RED_LEVELS = 7;
  localparam int BKEY_W     = 16;    // {sentinel, prio[7:0], index[6:0]}

  logic [8:0]        run_red [0:RED_LEVELS][0:RED_LEAVES-1];
  logic [BKEY_W-1:0] best_red[0:RED_LEVELS][0:RED_LEAVES-1];

  // 组优先级掩码只与 BPR/ABPR 有关，先各算一次，避免 96 次重复移位。
  logic [7:0] gp_mask_bpr;
  logic [7:0] gp_mask_abpr;

  int          best_irq_v;
  logic [8:0]  best_prio_v;
  logic        best_group_v;
  logic [BKEY_W-1:0] best_key_win;
  logic [15:0]       best_winner_index;
  logic [N-1:0]      best_group_shift;

  // ---- 组优先级（QEMU gic_get_group_priority：BPR 掩码）----
  function automatic logic [7:0] group_prio(input int i);
    if (group_r[i] && !cpu_ctlr_r[2]) begin     // CBPR 未置：组1 用 ABPR-1
      group_prio = prio_r[i] & gp_mask_abpr;
    end else begin
      group_prio = prio_r[i] & gp_mask_bpr;
    end
  endfunction

  // ---- running priority：活动中断中最低组优先级；无活动 = 0x100 ----
  logic [8:0] running_prio;
  always_comb begin
    gp_mask_bpr  = ~8'h0 << (int'(bpr_r) + 1);
    gp_mask_abpr = ~8'h0 << (((int'(abpr_r) - 1) & 7) + 1);

    for (int i = 0; i < RED_LEAVES; i++) begin
      run_red[0][i] = (i < N && active_r[i]) ? {1'b0, group_prio(i)} : 9'h100;
      if (i < N && enabled_r[i] && test_pending(i) && !active_r[i]) begin
        best_red[0][i] = {1'b0, prio_r[i], i[6:0]};
      end else begin
        best_red[0][i] = {1'b1, 15'd0};
      end
    end
    for (int lvl = 1; lvl <= RED_LEVELS; lvl++) begin
      automatic int span = RED_LEAVES >> lvl;
      for (int j = 0; j < span; j++) begin
        automatic logic [8:0] lv_a;
        automatic logic [8:0] lv_b;
        automatic logic [BKEY_W-1:0] bk_a;
        automatic logic [BKEY_W-1:0] bk_b;
        lv_a = run_red[lvl-1][2*j];
        lv_b = run_red[lvl-1][2*j+1];
        bk_a = best_red[lvl-1][2*j];
        bk_b = best_red[lvl-1][2*j+1];
        run_red[lvl][j] = (lv_a <= lv_b) ? lv_a : lv_b;
        best_red[lvl][j] = (bk_a <= bk_b) ? bk_a : bk_b;
      end
    end
    running_prio  = run_red[RED_LEVELS][0];
    best_key_win  = best_red[RED_LEVELS][0];
    best_winner_index = {9'd0, best_key_win[6:0]};
    best_irq_v   = best_key_win[BKEY_W-1] ? N : int'(best_winner_index);
    best_prio_v  = best_key_win[BKEY_W-1] ? 9'h100 : {1'b0, best_key_win[14:7]};
    best_group_shift = group_r >> best_winner_index[6:0];
    best_group_v = !best_key_win[BKEY_W-1] && best_group_shift[0];
  end

  // ---- current_pending（QEMU gic_update_internal + 组过滤）----
  logic [9:0] current_pending;
  always_comb begin
    if (!(ctlr_r[0] || ctlr_r[1])) begin
      current_pending = SPURIOUS;              // 分配器未使能
    end else if (best_prio_v < {1'b0, pmr_r}) begin
      if (best_group_v && !cpu_ctlr_r[4]) begin // 组1 需 ACK_CTL（无安全）
        current_pending = 10'd1022;
      end else if (best_irq_v < N) begin
        current_pending = best_irq_v[9:0];
      end else begin
        current_pending = SPURIOUS;
      end
    end else begin
      current_pending = SPURIOUS;
    end
  end

  // ---- IRQ 输出（QEMU gic_update_internal）----
  assign irq = (best_prio_v < {1'b0, pmr_r}) &&
               (best_prio_v < running_prio) &&
               ctlr_r[best_group_v] &&
               cpu_ctlr_r[{3'b000, best_group_v}];
  assign fiq = 1'b0;   // FIQ_EN 未用（GICC_CTLR bit3=0）

  // ---- 寄存器读（32 位字）----
  function automatic logic [31:0] gic_read(input logic [63:0] addr);
    automatic logic [31:0] r = 32'd0;
    if (addr >= GICD_BASE && addr < GICD_BASE + 64'h10000) begin
      automatic int off = int'(addr[15:0]);
      if (off == 32'h000) begin
        r = {30'd0, ctlr_r};
      end else if (off == 32'h004) begin
        r = 32'h0000_0008;                    // GICD_TYPER（探针）
      end else if (off == 32'h008) begin
        r = 32'h0000_043b;                    // GICD_IIDR（探针）
      end else if (off >= 32'h080 && off < 32'h100) begin
        automatic int n = (off - 32'h080) >> 2;
        r = 32'(group_r >> (n * 32));
      end else if (off >= 32'h100 && off < 32'h180) begin
        automatic int n = (off - 32'h100) >> 2;
        r = 32'(enabled_r >> (n * 32));       // ISENABLER 读
      end else if (off >= 32'h180 && off < 32'h200) begin
        automatic int n = (off - 32'h180) >> 2;
        r = 32'(enabled_r >> (n * 32));       // ICENABLER 读=enabled（QEMU）
      end else if (off >= 32'h200 && off < 32'h280) begin
        automatic int n = (off - 32'h200) >> 2;
        r = 32'(pending_r >> (n * 32));       // ISPENDR 读
      end else if (off >= 32'h280 && off < 32'h300) begin
        automatic int n = (off - 32'h280) >> 2;
        r = 32'(pending_r >> (n * 32));       // ICPENDR 读=pending
      end else if (off >= 32'h300 && off < 32'h380) begin
        automatic int n = (off - 32'h300) >> 2;
        r = 32'(active_r >> (n * 32));        // ISACTIVER 读
      end else if (off >= 32'h380 && off < 32'h400) begin
        automatic int n = (off - 32'h380) >> 2;
        r = 32'(active_r >> (n * 32));        // ICACTIVER 读=active
      end else if (off >= 32'h400 && off < 32'h800) begin
        automatic int base = (off - 32'h400);
        for (int i = 0; i < 4; i++) begin
          if (base + i < N) r[i*8 +: 8] = prio_r[base + i];
        end
      end else if (off >= 32'hC00 && off < 32'hD00) begin
        automatic int base = (off - 32'hC00) * 4;
        for (int i = 0; i < 16; i++) begin
          if (base + i < N) begin
            r[i*2 + 0] = level_r[base + i];
            r[i*2 + 1] = edge_r[base + i];
          end
        end
      end
    end else if (addr >= GICC_BASE && addr < GICC_BASE + 64'h10000) begin
      automatic int off = int'(addr[15:0]);
      if (off == 32'h000) begin
        r = {23'd0, cpu_ctlr_r};
      end else if (off == 32'h004) begin
        r = {24'd0, pmr_r};
      end else if (off == 32'h008) begin
        r = {29'd0, bpr_r};
      end else if (off == 32'h00C) begin
        r = gic_acknowledge();               // IAR（含副作用，见下）
      end else if (off == 32'h014) begin
        r = {24'd0, running_prio > 9'h0FF ? 8'hFF : running_prio[7:0]};
      end else if (off == 32'h018) begin
        r = {22'd0, current_pending};
      end else if (off == 32'h01C) begin
        r = {29'd0, abpr_r};
      end else if (off == 32'h0FC) begin
        r = 32'h0002_043b;                   // GICC_IIDR（探针）
      end
    end else if (addr >= GICV2M_BASE && addr < GICV2M_TOP) begin
      automatic int off = int'(addr[11:0]);
      if (off == 32'h008) begin
        // QEMU arm-gicv2m：base-spi=48、num-spi=64。
        r = 32'h0050_0040;                   // MSI_TYPER
      end else if (off == 32'hFCC) begin
        r = 32'h0510_0000;                   // MSI_IIDR (PRODUCT_ID=Q)
      end else if (off >= 32'hFD0 && off <= 32'hFFC) begin
        r = 32'd0;                           // 可选 identification RAZ
      end
    end
    gic_read = r;
  endfunction

  // ---- IAR 确认（QEMU gic_acknowledge_irq；副作用在 always_ff）----
  function automatic logic [31:0] gic_acknowledge();
    automatic logic [9:0] irq_v = current_pending;
    gic_acknowledge = {22'd0, irq_v};
    if (irq_v >= SPURIOUS) begin
      // 0x3ff/0x3fe：无有效中断
    end else if ({1'b0, prio_r[irq_v[6:0]]} >= running_prio) begin
      gic_acknowledge = 32'h3FF;
    end
  endfunction

  assign req_accept = req_valid && !rsp_pending;
  assign rsp_valid  = rsp_pending;
  assign rsp.rdata  = rdata_r;
  assign rsp.fault  = fault_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ctlr_r     <= 2'd0;
      cpu_ctlr_r <= 9'd0;
      pmr_r      <= 8'd0;
      bpr_r      <= 3'd0;
      abpr_r     <= 3'd1;          // 探针：GICC_ABPR 复位 1
      enabled_r  <= '0;
      pending_r  <= '0;
      active_r   <= '0;
      edge_r     <= '0;
      level_r    <= '0;
      group_r    <= '0;
      for (int i = 0; i < N; i++) prio_r[i] <= 8'd0;
      // 复位：SGIs(0-15) 使能（探针 ISENABLER0=0xffff）；
      // 内部中断(0-31) edge（探针 ICFGR0=0xaaaaaaaa）
      enabled_r[15:0] <= 16'hFFFF;
      edge_r[15:0]    <= 16'hFFFF;
      rsp_pending <= 1'b0;
      rdata_r     <= 64'd0;
      fault_r     <= 1'b0;
    end else begin
      if (req_valid && req_accept) begin
        rsp_pending <= 1'b1;
        fault_r     <= 1'b0;
        if (!req.we) begin
          rdata_r <= {32'd0, gic_read(req.addr)};
          // IAR 读副作用：确认（置 active、清 pending）
          if (req.addr >= GICC_BASE &&
              req.addr < GICC_BASE + 64'h10000 &&
              int'(req.addr[15:0]) == 32'h00C) begin
            automatic logic [9:0] irq_v = current_pending;
            if (int'(irq_v) < N &&
                {1'b0, prio_r[irq_v[6:0]]} < running_prio) begin
              active_r[irq_v[6:0]]  <= 1'b1;
              pending_r[irq_v[6:0]] <= 1'b0;   // edge/SGI 清 pending
            end
          end
        end else begin
          rdata_r <= 64'd0;
          // ---- 写副作用（QEMU gic_dist_writeb/writel + gic_cpu_write）----
          if (req.addr >= GICD_BASE && req.addr < GICD_BASE + 64'h10000) begin
            automatic int off = int'(req.addr[15:0]);
            automatic logic [N-1:0] vx =
                {{(N-32){1'b0}}, req.wdata[31:0]};
            if (off == 32'h000) begin
              if (req.strb[0]) ctlr_r <= req.wdata[1:0];  // EN_GRP0|1
            end else if (off >= 32'h080 && off < 32'h100) begin
              automatic int n = (off - 32'h080) >> 2;
              automatic logic [N-1:0] m =
                  {{(N-32){1'b0}}, 32'hFFFFFFFF} << (n * 32);
              automatic logic [N-1:0] bank_value = vx << (n * 32);
              group_r <= (group_r & ~m) | (bank_value & m);
            end else if (off >= 32'h100 && off < 32'h180) begin
              automatic int n = (off - 32'h100) >> 2;
              automatic logic [N-1:0] m =
                  {{(N-32){1'b0}}, 32'hFFFFFFFF} << (n * 32);
              automatic logic [N-1:0] bank_value = vx << (n * 32);
              // ISENABLER：SGIs(0-15) 写强制置位（QEMU value=0xff）
              if (n == 0) begin
                enabled_r <= enabled_r | (bank_value & m) |
                              {{(N-16){1'b0}}, 16'hFFFF};
              end else begin
                enabled_r <= enabled_r | (bank_value & m);
              end
            end else if (off >= 32'h180 && off < 32'h200) begin
              automatic int n = (off - 32'h180) >> 2;
              automatic logic [N-1:0] m =
                  {{(N-32){1'b0}}, 32'hFFFFFFFF} << (n * 32);
              automatic logic [N-1:0] bank_value = vx << (n * 32);
              // ICENABLER：SGIs 写强制忽略（QEMU value=0）
              if (n == 0) begin
                enabled_r <= enabled_r &
                             ~(bank_value & m & ~{{(N-16){1'b0}}, 16'hFFFF});
              end else begin
                enabled_r <= enabled_r & ~(bank_value & m);
              end
            end else if (off >= 32'h200 && off < 32'h280) begin
              automatic int n = (off - 32'h200) >> 2;
              automatic logic [N-1:0] m =
                  {{(N-32){1'b0}}, 32'hFFFFFFFF} << (n * 32);
              automatic logic [N-1:0] bank_value = vx << (n * 32);
              // ISPENDR：SGIs 写强制忽略（QEMU value=0）
              if (n == 0) begin
                pending_r <= pending_r | (bank_value & m &
                             ~{{(N-16){1'b0}}, 16'hFFFF});
              end else begin
                pending_r <= pending_r | (bank_value & m);
              end
            end else if (off >= 32'h280 && off < 32'h300) begin
              automatic int n = (off - 32'h280) >> 2;
              automatic logic [N-1:0] m =
                  {{(N-32){1'b0}}, 32'hFFFFFFFF} << (n * 32);
              automatic logic [N-1:0] bank_value = vx << (n * 32);
              // ICPENDR：SGIs 写强制忽略（QEMU value=0）
              if (n == 0) begin
                pending_r <= pending_r & ~(bank_value & m &
                             ~{{(N-16){1'b0}}, 16'hFFFF});
              end else begin
                pending_r <= pending_r & ~(bank_value & m);
              end
            end else if (off >= 32'h300 && off < 32'h380) begin
              automatic int n = (off - 32'h300) >> 2;
              automatic logic [N-1:0] m =
                  {{(N-32){1'b0}}, 32'hFFFFFFFF} << (n * 32);
              automatic logic [N-1:0] bank_value = vx << (n * 32);
              active_r <= active_r | (bank_value & m); // ISACTIVER
            end else if (off >= 32'h380 && off < 32'h400) begin
              automatic int n = (off - 32'h380) >> 2;
              automatic logic [N-1:0] m =
                  {{(N-32){1'b0}}, 32'hFFFFFFFF} << (n * 32);
              automatic logic [N-1:0] bank_value = vx << (n * 32);
              active_r <= active_r & ~(bank_value & m); // ICACTIVER
            end else if (off >= 32'h400 && off < 32'h800) begin
              automatic int base = (off - 32'h400);
              for (int i = 0; i < 4; i++) begin
                if (base + i < N && req.strb[i]) begin
                  prio_r[base + i] <= req.wdata[i*8 +: 8];
                end
              end
            end else if (off >= 32'hC00 && off < 32'hD00) begin
              automatic int base = (off - 32'hC00) * 4;
              for (int i = 0; i < 16; i++) begin
                if (base + i < N) begin
                  // ICFGR：bit1=edge；SGIs 强制 edge（QEMU value|=0xaa）
                  edge_r[base + i] <= (base + i < 16) ? 1'b1
                                                      : req.wdata[2*i + 1];
                  level_r[base + i] <= req.wdata[2*i];
                end
              end
            end else if (off == 32'hF00) begin
              // GICD_SGIR：irq=v[3:0]，过滤器 v[25:24]
              automatic logic [3:0] sgi = req.wdata[3:0];
              automatic logic [15:0] mask;
              case (req.wdata[25:24])
                2'b00:   mask = {8'd0, req.wdata[23:16]};
                2'b01:   mask = 16'hFFFE;
                2'b10:   mask = 16'h0001;
                default: mask = 16'hFFFF;
              endcase
              if (mask[0]) pending_r[{3'd0, sgi}] <= 1'b1;
            end else if (off >= 32'hF10 && off < 32'hF20) begin
              automatic int sgi = (off - 32'hF10);
              if (req.wdata[0]) pending_r[sgi[6:0]] <= 1'b0;  // CPENDSGIR
            end else if (off >= 32'hF20 && off < 32'hF30) begin
              automatic int sgi = (off - 32'hF20);
              if (req.wdata[0]) pending_r[sgi[6:0]] <= 1'b1;  // SPENDSGIR
            end
          end else if (req.addr >= GICC_BASE &&
                       req.addr < GICC_BASE + 64'h10000) begin
            automatic int off = int'(req.addr[15:0]);
            if (off == 32'h000) begin
              cpu_ctlr_r <= req.wdata[8:0] & 9'h21F;   // GICC_CTLR_V2_MASK
            end else if (off == 32'h004) begin
              pmr_r <= req.wdata[7:0];
            end else if (off == 32'h008) begin
              bpr_r <= req.wdata[2:0];
            end else if (off == 32'h010) begin
              // GICC_EOIR：完成中断（清 active）
              automatic logic [9:0] irq_v = req.wdata[9:0];
              if (int'(irq_v) < N && running_prio != 9'h100) begin
                active_r[irq_v[6:0]] <= 1'b0;
              end
            end else if (off == 32'h01C) begin
              abpr_r <= req.wdata[2:0];
            end
          end else if (req.addr >= GICV2M_BASE && req.addr < GICV2M_TOP) begin
            // GICv2m MSI_SETSPI_NS（offset 0x40）：当前模型只承载
            // NUM_IRQ=96，故 SPI 80..95 可转成 pending，其余忽略。
            automatic int off = int'(req.addr[11:0]);
            if (off == 32'h040) begin
              automatic int spi = int'(req.wdata[9:0]) - 80;
              if (spi >= 0 && spi < (N - 80)) begin
                pending_r[80 + spi] <= 1'b1;
              end
            end
          end
        end
      end
      if (rsp_pending && rsp_ready) begin
        rsp_pending <= 1'b0;
      end
    end
  end

endmodule
