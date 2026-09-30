// B2c direct-core pipeline test: DUP scalar/element and LD1R. Self-checking.
`timescale 1ns/1ps
/* verilator lint_off DECLFILENAME */
/* verilator lint_off PINCONNECTEMPTY */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off PROCASSINIT */
/* verilator lint_off UNUSEDSIGNAL */
module lcvex_b2c_vector_tb;
  import lcvex_pkg::*;
  localparam logic [63:0] BASE = 64'h0000_0000_4400_0000;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic commit_ready = 1'b1;
  commit_packet_t commit;
  logic imem_req_valid;
  mem_req_t imem_req;
  logic imem_req_ready;
  logic imem_rsp_valid;
  mem_rsp_t imem_rsp;
  logic imem_rsp_ready;
  logic dmem_req_valid;
  mem_req_t dmem_req;
  logic dmem_req_ready;
  logic dmem_rsp_valid;
  mem_rsp_t dmem_rsp;
  logic dmem_rsp_ready;
  logic ptw_req_ready;
  logic ptw_rsp_valid;
  mem_rsp_t ptw_rsp;
  logic ptw_req_valid;
  mem_req_t ptw_req;
  logic ptw_rsp_ready;
  logic [31:0] imem [0:1023];
  logic [63:0] restore_v_lo [0:31] = '{default:64'd0};
  logic [63:0] restore_v_hi [0:31] = '{default:64'd0};
  logic [63:0] fp_v_lo [0:31];
  logic [63:0] fp_v_hi [0:31];
  logic [31:0] fpcr_state, fpsr_state;
  logic [63:0] fp_cpacr;
  integer i;

  assign imem_req_ready = 1'b1;
  assign dmem_req_ready = 1'b1;
  assign ptw_req_ready = 1'b0;
  assign ptw_rsp_valid = 1'b0;
  assign ptw_rsp = '0;

  lcvex_core #(.RESET_PC(BASE)) core (
      .clk(clk), .rst_n(rst_n), .commit_ready(commit_ready), .commit(commit),
      .fpcr_state(fpcr_state), .fpsr_state(fpsr_state),
      .fp_cpacr_el1_state(fp_cpacr), .fp_v_lo(fp_v_lo), .fp_v_hi(fp_v_hi),
      .imem_req_valid(imem_req_valid), .imem_req(imem_req),
      .imem_req_ready(imem_req_ready), .imem_rsp_valid(imem_rsp_valid),
      .imem_rsp(imem_rsp), .imem_rsp_ready(imem_rsp_ready),
      .dmem_req_valid(dmem_req_valid), .dmem_req(dmem_req),
      .dmem_req_ready(dmem_req_ready), .dmem_rsp_valid(dmem_rsp_valid),
      .dmem_rsp(dmem_rsp), .dmem_rsp_ready(dmem_rsp_ready),
      .ptw_req_valid(ptw_req_valid), .ptw_req(ptw_req),
      .ptw_req_ready(ptw_req_ready), .ptw_rsp_valid(ptw_rsp_valid),
      .ptw_rsp(ptw_rsp), .ptw_rsp_ready(ptw_rsp_ready),
      .tlb_invalidate(), .timer_phys_irq(), .timer_virt_irq(), .irq(1'b0),
      .difftest_wait_release(1'b0), .difftest_wait_cntvct_valid(1'b0),
      .difftest_wait_cntvct(64'd0), .difftest_restore_sys_valid(1'b0),
      .difftest_restore_fp_valid(1'b0), .difftest_restore_fpcr(32'd0),
      .difftest_restore_fpsr(32'd0),
      .difftest_restore_fp_v_lo(restore_v_lo), .difftest_restore_fp_v_hi(restore_v_hi),
      .difftest_restore_pc(64'd0), .difftest_restore_sp_el0(64'd0),
      .difftest_restore_sp_el1(64'd0), .difftest_restore_nzcv(4'd0),
      .difftest_restore_el(1'b0), .difftest_restore_sp_sel(1'b0),
      .difftest_restore_daif(4'd0), .difftest_restore_pan(1'b0),
      .difftest_restore_dit(1'b0), .difftest_restore_ssbs(1'b0),
      .difftest_restore_uao(1'b0), .difftest_restore_tco(1'b0),
      .difftest_restore_allint(1'b0), .difftest_restore_elr_el1(64'd0),
      .difftest_restore_spsr_el1(64'd0), .difftest_restore_vbar_el1(64'd0),
      .difftest_restore_sctlr_el1(64'd0), .difftest_restore_tcr_el1(64'd0),
      .difftest_restore_ttbr0_el1(64'd0), .difftest_restore_ttbr1_el1(64'd0),
      .difftest_restore_mair_el1(64'd0), .difftest_restore_esr_el1(32'd0),
      .difftest_restore_far_el1(64'd0), .difftest_restore_par_el1(64'd0),
      .difftest_restore_cpacr_el1(64'd0), .difftest_restore_mdscr_el1(64'd0),
      .difftest_restore_pmuserenr_el0(64'd0), .difftest_restore_cntkctl_el1(64'd0),
      .difftest_restore_tpidr_el0(64'd0), .difftest_restore_tpidrro_el0(64'd0),
      .difftest_restore_tpidr_el1(64'd0), .difftest_restore_pir_el1(64'd0),
      .difftest_restore_pire0_el1(64'd0), .difftest_restore_zcr_el1(64'd0),
      .difftest_restore_smcr_el1(64'd0), .difftest_restore_csselr_el1(64'd0),
      .difftest_restore_tcr2_el1(64'd0), .difftest_restore_contextidr_el1(64'd0),
      .difftest_restore_excl_valid(1'b0),
      .difftest_restore_excl_addr(64'd0), .difftest_restore_excl_data(64'd0),
      .difftest_restore_excl_data_hi(64'd0), .difftest_restore_cntpct(64'd0),
      .difftest_restore_cntp_cval(64'd0), .difftest_restore_cntp_ctl(2'd0),
      .difftest_restore_cntv_cval(64'd0), .difftest_restore_cntv_ctl(2'd0)
  );

  always #5 clk = ~clk;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      imem_rsp_valid <= 1'b0;
      imem_rsp <= '0;
      dmem_rsp_valid <= 1'b0;
      dmem_rsp <= '0;
    end else begin
      imem_rsp_valid <= 1'b0;
      dmem_rsp_valid <= 1'b0;
      if (imem_req_valid && imem_req_ready) begin
        imem_rsp_valid <= 1'b1;
        imem_rsp.fault <= 1'b0;
        if (imem_req.addr >= BASE && imem_req.addr < BASE + 64'd4096)
          imem_rsp.rdata <= {32'd0, imem[int'((imem_req.addr - BASE) >> 2)]};
        else begin
          imem_rsp.rdata <= 64'd0;
          imem_rsp.fault <= 1'b1;
        end
      end
      if (dmem_req_valid && dmem_req_ready) begin
        dmem_rsp_valid <= 1'b1;
        dmem_rsp.rdata <= 64'h1122_3344_5566_7788;
        dmem_rsp.fault <= 1'b0;
      end
    end
  end

  initial begin
    imem = '{default:32'hD503201F};
    imem[0] = 32'hD2A00600; // mov x0,#0x300000
    imem[1] = 32'hD5181040; // msr cpacr_el1,x0
    imem[2] = 32'hD5033FDF; // isb
    imem[3] = 32'hD294B561; // movz x1,#0xA5AB
    imem[4] = 32'hD503201F; // nop
    imem[5] = 32'h4E010C20; // dup v0.16b,w1
    imem[6] = 32'h4E010C27; // dup v7.16b,w1
    imem[7] = 32'hD503201F; // nop
    imem[8] = 32'h4E0704E6; // dup v6.16b,v7.b[3]
    imem[9] = 32'h4E020C22; // dup v2.8h,w1
    imem[10] = 32'h4E040C23; // dup v3.4s,w1
    imem[11] = 32'h4E080C24; // dup v4.2d,w1
    imem[12] = 32'hD2A8800A; // movz x10,#0x4400,lsl#16
    imem[13] = 32'hF282000A; // movk x10,#0x1000
    imem[14] = 32'h4D40C140; // ld1r v0.16b,[x10]
    imem[15] = 32'h4D40C541; // ld1r v1.8h,[x10]
    imem[16] = 32'h4D40C942; // ld1r v2.4s,[x10]
    imem[17] = 32'h4D40CD43; // ld1r v3.2d,[x10]
    imem[18] = 32'h0D40C144; // ld1r v4.8b,[x10]
    imem[19] = 32'h14000000;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (2000) @(posedge clk);
    if (fp_v_lo[0] !== 64'h8888_8888_8888_8888 ||
        fp_v_hi[0] !== 64'h8888_8888_8888_8888)
      $fatal(1, "FAIL V0 LD1R .16B lo=%h hi=%h", fp_v_lo[0], fp_v_hi[0]);
    if (fp_v_lo[1] !== 64'h7788_7788_7788_7788 ||
        fp_v_hi[1] !== 64'h7788_7788_7788_7788)
      $fatal(1, "FAIL V1 LD1R .8H lo=%h hi=%h", fp_v_lo[1], fp_v_hi[1]);
    if (fp_v_lo[2] !== 64'h5566_7788_5566_7788 ||
        fp_v_hi[2] !== 64'h5566_7788_5566_7788)
      $fatal(1, "FAIL V2 LD1R .4S lo=%h hi=%h", fp_v_lo[2], fp_v_hi[2]);
    if (fp_v_lo[3] !== 64'h1122_3344_5566_7788 ||
        fp_v_hi[3] !== 64'h1122_3344_5566_7788)
      $fatal(1, "FAIL V3 LD1R .2D lo=%h hi=%h", fp_v_lo[3], fp_v_hi[3]);
    if (fp_v_lo[4] !== 64'h8888_8888_8888_8888 || fp_v_hi[4] !== 64'd0)
      $fatal(1, "FAIL V4 LD1R .8B lo=%h hi=%h", fp_v_lo[4], fp_v_hi[4]);
    if (fp_v_lo[7] !== 64'hABAB_ABAB_ABAB_ABAB ||
        fp_v_hi[7] !== 64'hABAB_ABAB_ABAB_ABAB)
      $fatal(1, "FAIL V7 DUP .16B lo=%h hi=%h", fp_v_lo[7], fp_v_hi[7]);
    if (fp_v_lo[6] !== 64'hABAB_ABAB_ABAB_ABAB ||
        fp_v_hi[6] !== 64'hABAB_ABAB_ABAB_ABAB)
      $fatal(1, "FAIL V6 DUP .16B lo=%h hi=%h", fp_v_lo[6], fp_v_hi[6]);
    $display("PASS: B2c DUP/LD1R direct pipeline");
    $finish;
  end
  /* verilator lint_on UNUSEDSIGNAL */
  /* verilator lint_on PROCASSINIT */
  /* verilator lint_on WIDTHTRUNC */
  /* verilator lint_on PINCONNECTEMPTY */
  /* verilator lint_on DECLFILENAME */
endmodule
