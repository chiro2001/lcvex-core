// lcvex_mmu_tb.sv
// M2-5 Gate D 单元测试：MMU 页表遍历 / TLB hit/miss/fault / 权限 /
// tlb_invalidate / MAIR cacheable。
// 运行：make sim-sv-mmu

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */  // testbench 仅检查部分字段
module lcvex_mmu_tb;
  import lcvex_pkg::*;

  logic clk;
  logic rst_n;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [63:0] dbg_dummy;  // P6 调试读口（未用）

  logic        req_valid;
  logic [63:0] req_va;
  logic        req_is_insn;
  logic        req_is_write;
  logic        req_accept;
  logic        done;
  logic [63:0] paddr;
  logic        fault;
  logic [5:0]  fault_fsc;
  logic        cacheable;
  logic        walking;
  logic [7:0]  par_attr;
  logic [1:0]  par_sh;
  logic        tlb_invalidate;
  logic        abort;

  logic        ptw_req_valid;
  mem_req_t    ptw_req;
  logic        ptw_req_ready;
  logic        ptw_rsp_valid;
  mem_rsp_t    ptw_rsp;
  logic        ptw_rsp_ready;
  logic        ram_rsp_valid;
  mem_rsp_t    ram_rsp;
  logic        ram_rsp_ready;
  logic        hold_ptw_rsp;
  logic        prog_we;
  logic [63:0] prog_addr;
  logic [7:0]  prog_strb;
  logic [63:0] prog_wdata;
  logic [63:0] tcr_el1_sig;
  logic [63:0] ttbr0_el1_sig;
  logic        access_el_sig;
  logic        pan_sig;

  lcvex_mmu #(.TLB_ENTRIES(8),
              .SRAM_BASE(64'h0000_0000_4000_0000),
              .SRAM_TOP (64'h0000_0000_4800_0000)) mmu (
      .clk           (clk),
      .rst_n         (rst_n),
      .req_valid     (req_valid),
      .req_va        (req_va),
      .req_is_insn   (req_is_insn),
      .req_is_write  (req_is_write),
      .req_accept    (req_accept),
      .done          (done),
      .paddr         (paddr),
      .fault         (fault),
      .fault_fsc     (fault_fsc),
      .cacheable     (cacheable),
      .par_attr      (par_attr),
      .par_sh        (par_sh),
      .walking       (walking),
      .mmu_en        (1'b1),
      .tcr_el1       (tcr_el1_sig),
      .ttbr0_el1     (ttbr0_el1_sig),
      .ttbr1_el1     (64'd0),
      .mair_el1      (64'h0000_0000_0000_44FF),  // attr1=44(NC), attr0=FF(WB)
      .access_el     (access_el_sig),
      .pan           (pan_sig),
      .tlb_invalidate(tlb_invalidate),
      .abort         (abort),
      .ptw_req_valid (ptw_req_valid),
      .ptw_req       (ptw_req),
      .ptw_req_ready (ptw_req_ready),
      .ptw_rsp_valid (ptw_rsp_valid),
      .ptw_rsp       (ptw_rsp),
      .ptw_rsp_ready (ptw_rsp_ready)
  );

  // A one-cycle response hold lets the unit test place abort in the
  // S_*_WAIT state without allowing the RAM to consume the old response
  // before the MMU enters S_ABORT_WAIT.
  assign ptw_rsp_valid = ram_rsp_valid && !hold_ptw_rsp;
  assign ptw_rsp       = ram_rsp;
  assign ram_rsp_ready = ptw_rsp_ready && !hold_ptw_rsp;

  lcvex_mem_ram #(.DEPTH(1 << 27), .SRAM_BASE(64'h0000_0000_4000_0000)) ram (
      .clk        (clk),
      .rst_n      (rst_n),
      .req_valid  (ptw_req_valid),
      .req        (ptw_req),
      .req_accept (ptw_req_ready),
      .rsp_valid  (ram_rsp_valid),
      .rsp        (ram_rsp),
      .rsp_ready  (ram_rsp_ready),
      .prog_we    (prog_we),
      .prog_addr  (prog_addr),
      .prog_strb  (prog_strb),
      .prog_wdata (prog_wdata),
      .dbg_addr   (32'd0),
      .dbg_rdata  (dbg_dummy)
  );

  always #5 clk = ~clk;  // 100 MHz

  int errs = 0;
    logic [63:0] pa_o;
  logic fault_o, cb_o;

  task automatic check_ok(input logic cond, input string msg);
    if (!cond) begin
      $display("FAIL: %s", msg);
      errs++;
    end
  endtask

  task automatic tick(input int n = 1);
    repeat (n) @(posedge clk);
  endtask

  // 发起一次翻译请求并等待 done，返回结果
  task automatic do_req(input logic [63:0] va, input logic is_insn,
                        input logic is_write, output logic [63:0] pa,
                        output logic f, output logic cb);
    req_valid = 1'b1;
    req_va = va;
    req_is_insn = is_insn;
    req_is_write = is_write;
    for (int req_wait = 0; req_wait < 200; req_wait++) begin
      if (req_accept)
        break;
      @(posedge clk);
      if (req_wait == 199)
        $fatal(1, "do_req timeout waiting req_accept va=%h state=%0d busy=%b done=%b",
               va, mmu.state, mmu.busy, done);
    end
    @(posedge clk);   // MMU 在该 posedge 采样并接收请求
    #1;
    req_valid = 1'b0;
    for (int done_wait = 0; done_wait < 500; done_wait++) begin
      if (done)
        break;
      @(posedge clk);
      if (done_wait == 499)
        $fatal(1, "do_req timeout waiting done va=%h state=%0d busy=%b walk=%b",
               va, mmu.state, mmu.busy, walking);
    end
    pa = paddr;
    f = fault;
    cb = cacheable;
    @(posedge clk);   // 等待 done 撤销，释放 MMU
  endtask

  initial begin
    $display("=== lcvex_mmu_tb: MMU/TLB 单元测试 ===");
    clk = 1'b0;
    rst_n = 1'b0;
    req_valid = 1'b0;
    req_va = 64'd0;
    req_is_insn = 1'b0;
    req_is_write = 1'b0;
    tlb_invalidate = 1'b0;
    abort = 1'b0;
    hold_ptw_rsp = 1'b0;
    access_el_sig = 1'b1;
    pan_sig = 1'b0;
    prog_we = 1'b0;
    tcr_el1_sig = 64'h0000_0000_0010_0010;
    ttbr0_el1_sig = 64'h0000_0000_4401_0000;
    tick(2);

    // 加载页表：L0[0]->L1；L1[1]->L2；L2[0]->L3（VA 0x40000000），
    // L2[32]->L3b（VA 0x44000000 恒等）
    prog_we = 1'b1;
    prog_addr = 64'h44010000; prog_strb = 8'hFF;
    prog_wdata = 64'h44011003; @(posedge clk);   // L0[0] -> L1
    prog_addr = 64'h44011008; prog_wdata = 64'h44012003; @(posedge clk);  // L1[1]
    prog_addr = 64'h44012000; prog_wdata = 64'h44013003; @(posedge clk);  // L2[0]
    prog_addr = 64'h44012100; prog_wdata = 64'h44014003; @(posedge clk);  // L2[32]
    // L2[1]：2 MB 块描述符（VA 0x40200000 -> PA 0x44000000）
    prog_addr = 64'h44012008; prog_wdata = 64'h440004C1; @(posedge clk);
    // L0[1] -> L1b（0x44015000）；L1b[0]：1 GB 块（VA 0x8000000000 起 ->
    // PA 0x40000000；VA 偏移 0x04000000 落到 SRAM 0x44000000）
    prog_addr = 64'h44010008; prog_wdata = 64'h44015003; @(posedge clk);
    prog_addr = 64'h44015000; prog_wdata = 64'h400004C1; @(posedge clk);
    // L3（VA 0x40000000 区域）：
    //   [0] -> PA 0x44008000, attr0（WB, cacheable=1）
    //   [1] 无效 -> 翻译 fault
    //   [2] -> PA 0x44009000, AP=10（EL1 只读，写 fault）
    //   [3] -> PA 0x4400A000, attr1（NC, cacheable=0）
    prog_addr = 64'h44013000; prog_wdata = 64'h440084C3; @(posedge clk);
    prog_addr = 64'h44013008; prog_wdata = 64'h0000000000000000; @(posedge clk);
    prog_addr = 64'h44013010; prog_wdata = 64'h44009483; @(posedge clk);  // AP=10
    prog_addr = 64'h44013018; prog_wdata = 64'h4400A4C7; @(posedge clk);
    //   [4] -> PA 0x09000000（P6 MMIO 窗口：attr0=WB 但强制不可缓存）
    prog_addr = 64'h44013020; prog_wdata = 64'h090004C3; @(posedge clk);
    //   [5] -> PA 0x08000000（P6 GIC MMIO2：同样不可缓存）
    prog_addr = 64'h44013028; prog_wdata = 64'h080004C3; @(posedge clk);
    // L3b（恒等）：[0] -> PA 0x44000000
    prog_addr = 64'h44014000; prog_wdata = 64'h440004C3; @(posedge clk);
    prog_we = 1'b0;

    rst_n = 1'b1;
    tick(2);

    // 1) TLB miss：4 级遍历 -> PA 0x44008000，可缓存
    do_req(64'h40000000, 1'b0, 1'b0, pa_o, fault_o, cb_o);
    check_ok(!fault_o && pa_o == 64'h44008000 && cb_o == 1'b1,
             $sformatf("TLB miss 翻译 VA->PA 0x%h cacheable=%b",
                       pa_o, cb_o));

    // 2) TLB hit：同 VA 再次翻译，结果一致
    do_req(64'h40000000, 1'b0, 1'b0, pa_o, fault_o, cb_o);
    check_ok(!fault_o && pa_o == 64'h44008000,
             "TLB hit 翻译结果一致");

    // 3) 无效描述符 -> 翻译 fault
    do_req(64'h40001000, 1'b0, 1'b0, pa_o, fault_o, cb_o);
    check_ok(fault_o, "无效描述符应报 fault");

    // 4) AP=10 页面：EL1 读允许、写 fault
    do_req(64'h40002000, 1'b0, 1'b0, pa_o, fault_o, cb_o);
    check_ok(!fault_o && pa_o == 64'h44009000, "AP=10 页面 EL1 读允许");
    do_req(64'h40002000, 1'b0, 1'b1, pa_o, fault_o, cb_o);
    check_ok(fault_o, "AP=10 页面 EL1 写应 fault");

    // 5) attr1（Normal NC）-> cacheable=0
    do_req(64'h40003000, 1'b0, 1'b0, pa_o, fault_o, cb_o);
    check_ok(!fault_o && pa_o == 64'h4400A000 && cb_o == 1'b0,
             $sformatf("Normal NC 页面 cacheable=%b", cb_o));

    // 6) 取指翻译：同 VA 指令访问 -> 相同 PA
    do_req(64'h40000000, 1'b1, 1'b0, pa_o, fault_o, cb_o);
    check_ok(!fault_o && pa_o == 64'h44008000, "取指翻译结果一致");

    // 7) tlb_invalidate：改 L3[0] 后整表失效 -> 重新遍历得新 PA
    prog_we = 1'b1;
    prog_addr = 64'h44013000; prog_strb = 8'hFF;
    prog_wdata = 64'h440094C3;   // VA 0x40000000 -> PA 0x44009000
    @(posedge clk);
    prog_we = 1'b0;
    tlb_invalidate = 1'b1;
    @(posedge clk);
    tlb_invalidate = 1'b0;
    do_req(64'h40000000, 1'b0, 1'b0, pa_o, fault_o, cb_o);
    check_ok(!fault_o && pa_o == 64'h44009000,
             $sformatf("TLBI 后重新遍历得 PA 0x%h", pa_o));

    // 7b) MMIO 翻译（P6）：PA 在 MMIO 窗口 -> 不 fault、cacheable=0
    do_req(64'h40004000, 1'b0, 1'b0, pa_o, fault_o, cb_o);
    check_ok(!fault_o && pa_o == 64'h09000000 && cb_o == 1'b0,
             $sformatf("MMIO 翻译 VA->PA 0x%h cacheable=%b",
                       pa_o, cb_o));
    // 7c) GIC MMIO2 翻译：PA 0x08000000 必须不被误判为越界
    do_req(64'h40005000, 1'b0, 1'b0, pa_o, fault_o, cb_o);
    check_ok(!fault_o && pa_o == 64'h08000000 && cb_o == 1'b0,
             $sformatf("GIC MMIO2 翻译 VA->PA 0x%h cacheable=%b",
                       pa_o, cb_o));

    // 7d) PAN：EL1 访问 AP=11 的 EL0 可访问页必须 fault；TLB hit
    // 与 page-walk 两条路径都使用同一权限判定，清 PAN 后恢复访问。
    tlb_invalidate = 1'b1; @(posedge clk); tlb_invalidate = 1'b0;
    pan_sig = 1'b1;
    do_req(64'h40000000, 1'b0, 1'b0, pa_o, fault_o, cb_o);
    check_ok(fault_o, "PAN=1 page-walk 应拒绝 AP=11 EL0 页");
    do_req(64'h40000000, 1'b0, 1'b0, pa_o, fault_o, cb_o);
    check_ok(fault_o, "PAN=1 TLB hit 应拒绝 AP=11 EL0 页");
    pan_sig = 1'b0;
    do_req(64'h40000000, 1'b0, 1'b0, pa_o, fault_o, cb_o);
    check_ok(!fault_o && pa_o == 64'h44009000,
             "PAN=0 TLB hit 应恢复 AP=11 EL1 访问");

    // 7e) precise abort/quarantine：保留既有 VA0 TLB，同时让一个新的
    // page-walk 先接受 PTW、再在 response 尚未消费时 abort。hold gate
    // 只作用测试 BFM，模拟 mem_arb 已接受读但下游 response 延迟。
    prog_we = 1'b1;
    prog_addr = 64'h44013000;
    prog_strb = 8'hFF;
    prog_wdata = 64'h4400B4C3; // 若 TLB 被误清，VA0 将看到新 PA
    @(posedge clk);
    prog_we = 1'b0;
    prog_strb = 8'd0;
    req_valid = 1'b1;
    req_va = 64'h40001000;       // L3[1] 当前无效，确保发生 page-walk
    req_is_insn = 1'b0;
    req_is_write = 1'b0;
    wait (req_accept);
    @(posedge clk);
    #1;
    req_valid = 1'b0;
    for (int wait_cycles = 0; wait_cycles < 200; wait_cycles++) begin
      if (ptw_rsp_valid && ptw_rsp_ready)
        break;
      @(posedge clk);
      if (wait_cycles == 199)
        $fatal(1, "MMU abort probe timed out waiting accepted PTW response");
    end
    hold_ptw_rsp = 1'b1;
    abort = 1'b1;
    @(posedge clk);
    #1;
    abort = 1'b0;
    check_ok(walking && !ptw_req_valid && ptw_rsp_ready &&
             !done && !fault,
             "abort 后进入 response quarantine（无 done/fault）");
    hold_ptw_rsp = 1'b0;
    @(posedge clk);
    #1;
    check_ok(!walking && !done && !fault && req_accept,
             "旧 PTW response drain 后 MMU 回到可接受状态");
    do_req(64'h40000000, 1'b0, 1'b0, pa_o, fault_o, cb_o);
    check_ok(!fault_o && pa_o == 64'h44009000,
             "IRQ/MMU abort 不清既有 TLB（BBM 映射仍取旧 PA）");


    // 8) L2 块描述符（2 MB）：VA 0x40201000 -> PA 0x44001000
    do_req(64'h40201000, 1'b0, 1'b0, pa_o, fault_o, cb_o);
    check_ok(!fault_o && pa_o == 64'h44001000 && cb_o == 1'b1,
             $sformatf("2MB 块翻译 VA->PA 0x%h", pa_o));
    // 9) L1 块描述符（1 GB）：VA 0x8004001000 -> PA 0x44001000
    do_req(64'h8004001000, 1'b0, 1'b0, pa_o, fault_o, cb_o);
    check_ok(!fault_o && pa_o == 64'h44001000,
             $sformatf("1GB 块翻译 VA->PA 0x%h", pa_o));
    // 10) 块映射下另一 4K 页（TLB 按页记录）：VA 0x40202000 -> PA 0x44002000
    do_req(64'h40202000, 1'b0, 1'b0, pa_o, fault_o, cb_o);
    check_ok(!fault_o && pa_o == 64'h44002000,
             $sformatf("2MB 块另一页 VA->PA 0x%h", pa_o));

    // 11) 39 位输入地址（Linux 常用 T0SZ/T1SZ=25）：起始级别为 L1，
    // 根表项使用 VA[38:30]，不能误从固定的 L0[VA[47:39]] 开始。
    prog_we = 1'b1;
    prog_addr = 64'h44016008; prog_strb = 8'hFF;
    prog_wdata = 64'h0000_0000_44017003; @(posedge clk); // L1[1] -> L2
    prog_addr = 64'h44017010; prog_wdata = 64'h0000_0000_44018003;
    @(posedge clk); // L2[2] -> L3
    prog_addr = 64'h440188A0; prog_wdata = 64'h0000_0000_4400B4C3;
    @(posedge clk); // L3[0x114] -> 0x4400B000
    prog_we = 1'b0;
    tcr_el1_sig = 64'h0000_0000_0019_0019;
    ttbr0_el1_sig = 64'h0000_0000_4401_6000;
    tlb_invalidate = 1'b1; @(posedge clk); tlb_invalidate = 1'b0;
    do_req(64'h0000_0000_4051_4360, 1'b1, 1'b0,
           pa_o, fault_o, cb_o);
    check_ok(!fault_o && pa_o == 64'h4400B360,
             $sformatf("39 位输入地址从 L1 开始翻译 VA->PA 0x%h", pa_o));

    if (errs == 0) begin
      $display("PASS: lcvex_mmu_tb 全部通过");
      $finish;
    end else begin
      $fatal(1, "FAIL: %0d 处错误", errs);
    end
  end
endmodule
