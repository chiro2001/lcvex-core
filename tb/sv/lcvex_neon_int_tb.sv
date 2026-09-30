// P7-2：Advanced SIMD/Q integer unit raw-bit unit test。
// 此 TB 不调用 host SIMD/float；期望值均为固定宽度十六进制位模式。

`timescale 1ns/1ps

module lcvex_neon_int_tb;
  import lcvex_pkg::*;

  logic                 valid;
  neon_op_t             op;
  logic [1:0]           size;
  logic [6:0]           shift_amt;
  logic                 quad;
  logic [127:0]         operand_a;
  logic [127:0]         operand_b;
  logic [127:0]         result;

  lcvex_neon_int dut (
      .valid(valid), .op(op), .size(size), .shift_amt(shift_amt),
      .quad(quad), .operand_a(operand_a), .operand_b(operand_b),
      .result(result));

  task automatic check(
      input neon_op_t t_op,
      input logic [1:0] t_size,
      input logic [6:0] t_shift,
      input logic [127:0] t_a,
      input logic [127:0] t_b,
      input logic [127:0] t_expect,
      input string name);
    begin
      op = t_op;
      size = t_size;
      shift_amt = t_shift;
      operand_a = t_a;
      operand_b = t_b;
      valid = 1'b1;
      #1;
      if (result !== t_expect)
        $fatal(1, "FAIL %s: got %032h expect %032h", name, result, t_expect);
    end
  endtask

  initial begin
    valid = 1'b0;
    op = NEON_OP_NONE;
    size = 2'd0;
    shift_amt = 7'd0;
    quad = 1'b1;
    operand_a = 128'd0;
    operand_b = 128'd0;

    check(NEON_OP_MOV, 2'd0, 0,
          128'h0011_2233_4455_6677_8899_aabb_ccdd_eeff, 0,
          128'h0011_2233_4455_6677_8899_aabb_ccdd_eeff, "mov");
    check(NEON_OP_AND, 2'd0, 0,
          128'hffff_0000_ffff_0000_ffff_0000_ffff_0000,
          128'h0f0f_0f0f_f0f0_f0f0_00ff_00ff_ff00_ff00,
          128'h0f0f_0000_f0f0_0000_00ff_0000_ff00_0000, "and");
    check(NEON_OP_ORR, 2'd0, 0,
          128'h0000_0000_ffff_0000_0000_0000_ffff_0000,
          128'h0000_ffff_0000_ffff_0000_ffff_0000_ffff,
          128'h0000_ffff_ffff_ffff_0000_ffff_ffff_ffff, "orr");
    check(NEON_OP_EOR, 2'd0, 0,
          128'hffff_0000_ffff_0000_aaaa_aaaa_5555_5555,
          128'h0f0f_0f0f_f0f0_f0f0_aaaa_aaaa_ffff_ffff,
          128'hf0f0_0f0f_0f0f_f0f0_0000_0000_aaaa_aaaa, "eor");
    check(NEON_OP_BIC, 2'd0, 0,
          128'hffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff,
          128'h0000_ffff_0000_ffff_ffff_0000_ffff_0000,
          128'hffff_0000_ffff_0000_0000_ffff_0000_ffff, "bic");
    check(NEON_OP_ORN, 2'd0, 0,
          128'h0000_0000_0000_0000_0000_0000_0000_0000,
          128'hffff_0000_ffff_0000_0000_ffff_0000_ffff,
          128'h0000_ffff_0000_ffff_ffff_0000_ffff_0000, "orn");

    check(NEON_OP_ADD, 2'd0, 0,
          128'hff00_ff00_ff00_ff00_ff00_ff00_ff00_ff00,
          128'h0102_0304_0506_0708_090a_0b0c_0d0e_0f10,
          128'h0002_0204_0406_0608_080a_0a0c_0c0e_0e10, "add.16b");
    check(NEON_OP_ADD, 2'd1, 0,
          128'hffff_0001_ffff_0002_ffff_0003_ffff_0004,
          128'h0001_0002_0003_0004_0005_0006_0007_0008,
          128'h0000_0003_0002_0006_0004_0009_0006_000c, "add.8h");
    check(NEON_OP_SUB, 2'd2, 0,
          128'h0000_0001_0000_0002_0000_0003_0000_0004,
          128'h0000_0005_0000_0006_0000_0007_0000_0008,
          128'hffff_fffc_ffff_fffc_ffff_fffc_ffff_fffc, "sub.4s");
    check(NEON_OP_ADD, 2'd3, 0,
          128'hffff_ffff_ffff_ffff_0000_0000_0000_0001,
          128'h0000_0000_0000_0002_0000_0000_0000_0003,
          128'h0000_0000_0000_0001_0000_0000_0000_0004, "add.2d");

    check(NEON_OP_CMEQ, 2'd0, 0,
          128'h0001_0203_0405_0607_0809_0a0b_0c0d_0e0f,
          128'h0001_0003_0405_ffff_0800_0a0b_ffff_0e0f,
          128'hffff_00ff_ffff_0000_ff00_ffff_0000_ffff, "cmeq.16b");
    check(NEON_OP_CMGE, 2'd1, 0,
          128'hffff_ffff_ffff_ffff_0000_0000_0000_0000,
          128'h0000_0001_ffff_ffff_0000_0000_0000_0001,
          128'h0000_0000_ffff_ffff_ffff_ffff_ffff_0000, "cmge.8h");
    check(NEON_OP_CMGT, 2'd2, 0,
          128'hffff_ffff_0000_0002_0000_0003_8000_0000,
          128'h0000_0000_0000_0001_0000_0003_7fff_ffff,
          128'h0000_0000_ffff_ffff_0000_0000_0000_0000, "cmgt.4s");
    check(NEON_OP_CMHI, 2'd3, 0,
          128'hffff_ffff_0000_0002_0000_0000_0000_0001,
          128'h0000_0000_0000_0001_ffff_ffff_0000_0001,
          128'hffff_ffff_ffff_ffff_0000_0000_0000_0000, "cmhi.2d");
    check(NEON_OP_CMHS, 2'd0, 0,
          128'h0000_0001_0000_0002_0000_0003_0000_0004,
          128'h0000_0001_0000_0001_0000_0004_0000_0004,
          128'hffff_ffff_ffff_ffff_ffff_ff00_ffff_ffff, "cmhs.16b");

    check(NEON_OP_SHL, 2'd1, 3,
          128'h0001_0002_0003_0004_0005_0006_0007_0008, 0,
          128'h0008_0010_0018_0020_0028_0030_0038_0040, "shl.8h");
    check(NEON_OP_SSHR, 2'd2, 2,
          128'h8000_0000_ffff_ffff_0000_0008_0000_0004, 0,
          128'he000_0000_ffff_ffff_0000_0002_0000_0001, "sshr.4s");
    check(NEON_OP_USHR, 2'd3, 4,
          128'h8000_0000_0000_0000_ffff_ffff_ffff_ffff, 0,
          128'h0800_0000_0000_0000_0fff_ffff_ffff_ffff, "ushr.2d");
    check(NEON_OP_SSRA, 2'd0, 1,
          128'h0002_0004_0006_0008_000a_000c_000e_0010,
          128'h0001_0001_0001_0001_0001_0001_0001_0001,
          128'h0002_0003_0004_0005_0006_0007_0008_0009, "ssra.16b");
    check(NEON_OP_USRA, 2'd1, 2,
          128'h0008_000c_0010_0014_0018_001c_0020_0024,
          128'h0001_0001_0001_0001_0001_0001_0001_0001,
          128'h0003_0004_0005_0006_0007_0008_0009_000a, "usra.8h");

    // B2c DUP scalar/element replicate.
    quad = 1'b0;
    check(NEON_OP_DUP_SCALAR, 2'd0, 0,
          128'h0000_0000_0000_0000_0000_0000_0000_00A5, 0,
          128'h0000_0000_0000_0000_A5A5_A5A5_A5A5_A5A5,
          "dup scalar .8b Q=0");
    quad = 1'b1;
    check(NEON_OP_DUP_SCALAR, 2'd1, 0,
          128'h0000_0000_0000_0000_0000_0000_0000_1234, 0,
          128'h1234_1234_1234_1234_1234_1234_1234_1234,
          "dup scalar .8h Q=1");
    check(NEON_OP_DUP_SCALAR, 2'd2, 0,
          128'h0000_0000_0000_0000_0000_0000_0000_DEAD_BEEF, 0,
          128'hDEAD_BEEF_DEAD_BEEF_DEAD_BEEF_DEAD_BEEF,
          "dup scalar .4s Q=1");
    check(NEON_OP_DUP_SCALAR, 2'd3, 0,
          128'h0000_0000_0000_0000_0123_4567_89AB_CDEF, 0,
          128'h0123_4567_89AB_CDEF_0123_4567_89AB_CDEF,
          "dup scalar .2d Q=1");
    check(NEON_OP_DUP_ELEMENT, 2'd0, 7,
          0, 128'h00_01_02_03_04_05_06_07_08_09_0A_0B_0C_0D_0E_0F,
          128'h08_08_08_08_08_08_08_08_08_08_08_08_08_08_08_08,
          "dup element .16b b[7]");
    check(NEON_OP_DUP_ELEMENT, 2'd1, 5,
          0, 128'h0001_0002_0003_0004_0005_0006_0007_0008,
          128'h0003_0003_0003_0003_0003_0003_0003_0003,
          "dup element .8h h[5]");
    check(NEON_OP_DUP_ELEMENT, 2'd2, 2,
          0, 128'h0000_0001_0000_0002_0000_0003_0000_0004,
          128'h0000_0002_0000_0002_0000_0002_0000_0002,
          "dup element .4s s[2]");
    check(NEON_OP_DUP_ELEMENT, 2'd3, 1,
          0, 128'h0000_0000_0000_0001_0000_0000_0000_0002,
          128'h0000_0000_0000_0001_0000_0000_0000_0001,
          "dup element .2d d[1]");

    valid = 1'b0;
    #1;
    if (result !== 128'd0)
      $fatal(1, "FAIL invalid input must produce zero");
    $display("PASS: P7-2 NEON integer raw-bit unit");
    $finish;
  end
endmodule

// P7-2 negative contract test. This BFM intentionally violates the accepted
// downstream contract by returning a fault for the second 8B half after the
// first write has already been accepted. It is built/run with assertions
// enabled: the core SVA above must reject the same trace. The purpose is to
// make the boundary explicit, not to claim arbitrary-fault rollback semantics.
/* verilator lint_off DECLFILENAME */
module lcvex_neon_fault_bfm_tb;
  /* verilator lint_off DECLFILENAME */
  /* verilator lint_off PINCONNECTEMPTY */
  /* verilator lint_off WIDTHTRUNC */
  /* verilator lint_off PROCASSINIT */
  /* verilator lint_off UNUSEDSIGNAL */
  import lcvex_pkg::*;

  localparam logic [63:0] BASE = 64'h0000_0000_4400_0000;
  localparam logic [63:0] Q_ADDR = 64'h0000_0000_4400_2000;

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
  logic [31:0] imem [0:1023];
  logic first_write_seen;
  logic second_fault_seen;
  logic [63:0] restore_v_lo [0:31] = '{default:64'd0};
  logic [63:0] restore_v_hi [0:31] = '{default:64'd0};

  assign imem_req_ready = 1'b1;
  assign dmem_req_ready = 1'b1;
  logic ptw_req_ready;
  logic ptw_rsp_valid;
  mem_rsp_t ptw_rsp;
  assign ptw_req_ready = 1'b0;
  assign ptw_rsp_valid = 1'b0;
  assign ptw_rsp = '0;
  logic ptw_req_valid;
  mem_req_t ptw_req;
  logic ptw_rsp_ready;

  logic [63:0] fp_v_lo [0:31];
  logic [63:0] fp_v_hi [0:31];
  logic [31:0] fpcr_state, fpsr_state;
  logic [63:0] fp_cpacr;

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
      .difftest_wait_release(1'b0),
      .difftest_wait_cntvct_valid(1'b0),
      .difftest_wait_cntvct(64'd0),
      .difftest_restore_sys_valid(1'b0),
      .difftest_restore_fp_valid(1'b0),
      .difftest_restore_fpcr(32'd0), .difftest_restore_fpsr(32'd0),
      .difftest_restore_fp_v_lo(restore_v_lo),
      .difftest_restore_fp_v_hi(restore_v_hi),
      .difftest_restore_pc(64'd0),
      .difftest_restore_sp_el0(64'd0),
      .difftest_restore_sp_el1(64'd0),
      .difftest_restore_nzcv(4'd0), .difftest_restore_el(1'b0),
      .difftest_restore_sp_sel(1'b0), .difftest_restore_daif(4'd0),
      .difftest_restore_pan(1'b0), .difftest_restore_dit(1'b0),
      .difftest_restore_ssbs(1'b0), .difftest_restore_uao(1'b0),
      .difftest_restore_tco(1'b0), .difftest_restore_allint(1'b0),
      .difftest_restore_elr_el1(64'd0),
      .difftest_restore_spsr_el1(64'd0),
      .difftest_restore_vbar_el1(64'd0),
      .difftest_restore_sctlr_el1(64'd0),
      .difftest_restore_tcr_el1(64'd0),
      .difftest_restore_ttbr0_el1(64'd0),
      .difftest_restore_ttbr1_el1(64'd0),
      .difftest_restore_mair_el1(64'd0),
      .difftest_restore_esr_el1(32'd0),
      .difftest_restore_far_el1(64'd0),
      .difftest_restore_par_el1(64'd0),
      .difftest_restore_cpacr_el1(64'd0),
      .difftest_restore_mdscr_el1(64'd0),
      .difftest_restore_pmuserenr_el0(64'd0),
      .difftest_restore_cntkctl_el1(64'd0),
      .difftest_restore_tpidr_el0(64'd0),
      .difftest_restore_tpidrro_el0(64'd0),
      .difftest_restore_tpidr_el1(64'd0),
      .difftest_restore_pir_el1(64'd0),
      .difftest_restore_pire0_el1(64'd0),
      .difftest_restore_zcr_el1(64'd0),
      .difftest_restore_smcr_el1(64'd0),
      .difftest_restore_csselr_el1(64'd0),
      .difftest_restore_tcr2_el1(64'd0),
      .difftest_restore_contextidr_el1(64'd0),
      .difftest_restore_excl_valid(1'b0),
      .difftest_restore_excl_addr(64'd0),
      .difftest_restore_excl_data(64'd0),
      .difftest_restore_excl_data_hi(64'd0),
      .difftest_restore_cntpct(64'd0),
      .difftest_restore_cntp_cval(64'd0),
      .difftest_restore_cntp_ctl(2'd0),
      .difftest_restore_cntv_cval(64'd0),
      .difftest_restore_cntv_ctl(2'd0)
  );

  always #5 clk = ~clk;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      imem_rsp_valid <= 1'b0;
      imem_rsp <= '0;
      dmem_rsp_valid <= 1'b0;
      dmem_rsp <= '0;
      first_write_seen <= 1'b0;
      second_fault_seen <= 1'b0;
    end else begin
      imem_rsp_valid <= 1'b0;
      dmem_rsp_valid <= 1'b0;
      if (imem_req_valid && imem_req_ready) begin
        imem_rsp_valid <= 1'b1;
        imem_rsp.fault <= 1'b0;
        if (imem_req.addr >= BASE &&
            imem_req.addr < BASE + 64'd4096)
          imem_rsp.rdata <= {32'd0,
                             imem[int'((imem_req.addr - BASE) >> 2)]};
        else begin
          imem_rsp.rdata <= 64'd0;
          imem_rsp.fault <= 1'b1;
        end
      end
      if (dmem_req_valid && dmem_req_ready) begin
        dmem_rsp_valid <= 1'b1;
        dmem_rsp.rdata <= 64'd0;
        dmem_rsp.fault <= 1'b0;
        if (dmem_req.we && dmem_req.addr == Q_ADDR) begin
          first_write_seen <= 1'b1;
          $display("FAULT_BFM first request-accept addr=%h wdata=%h",
                   dmem_req.addr, dmem_req.wdata);
        end else if (dmem_req.we && dmem_req.addr == Q_ADDR + 64'd8) begin
          // Deliberate second-half fault: ordinary mem_req has already made
          // the first write irreversible, exposing the documented boundary.
          second_fault_seen <= 1'b1;
          dmem_rsp.fault <= 1'b1;
          $display("FAULT_BFM second response fault addr=%h after first accept",
                   dmem_req.addr);
        end
      end
    end
  end

  initial begin
    imem = '{default:32'hD503201F};
    imem[0] = 32'hD2A00600; // mov x0,#0x300000 (CPACR.FPEN=11)
    imem[1] = 32'hD5181040; // msr cpacr_el1,x0
    imem[2] = 32'hD5033FDF; // isb
    imem[3] = 32'hD2A8800A; // mov x10,#0x44000000
    imem[4] = 32'hF284000A; // movk x10,#0x2000
    imem[5] = 32'h4F05E4A0; // movi v0.16b,#0xa5
    imem[6] = 32'h3D800140; // str q0,[x10]
    imem[7] = 32'h14000000; // b .
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (400) @(posedge clk);
    if (!first_write_seen || !second_fault_seen)
      $fatal(1, "fault BFM did not observe first write + second fault");
    $display("EXPECTED LIMITATION: second-half Q fault is not rollback-safe; first 8B request was already accepted; assertion-enabled core build rejects this downstream behavior.");
    $finish;
  end
  /* verilator lint_on UNUSEDSIGNAL */
  /* verilator lint_on PROCASSINIT */
  /* verilator lint_on WIDTHTRUNC */
  /* verilator lint_on PINCONNECTEMPTY */
  /* verilator lint_on DECLFILENAME */
endmodule
