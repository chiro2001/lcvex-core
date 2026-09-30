// FP-P1 transaction wrapper directed SV test.
// Covers single issue, held response, scalar/NEON raw result, FDIV,
// response backpressure, kill/no ghost, and reset.

`timescale 1ns/1ps
/* verilator lint_off UNUSEDSIGNAL */
module lcvex_fp_exec_tb;
  import lcvex_pkg::*;

  logic          clk = 1'b0;
  logic          rst_n = 1'b0;
  logic          req_valid;
  fp_exec_req_t  req;
  logic          req_ready;
  logic          rsp_valid;
  fp_exec_rsp_t  rsp;
  logic          rsp_ready;
  logic          kill;
  logic          busy;
  logic          issued;
  integer        lat;

  // Keep direct-instance state probes aligned with the R18 scalar FSM.  These
  // are non-architectural test-only encodings; architectural checks below
  // continue to compare raw results and flags.
  localparam logic [3:0] ITER_STATE_PACK_SCAN = 4'd10;
  localparam logic [3:0] ITER_STATE_PACK_PRE  = 4'd11;
  localparam logic [3:0] ITER_STATE_PACK      = 4'd12;
  localparam logic [3:0] ITER_STATE_PACK_RESULT = 4'd13;

  // A direct FP_ITER instance gives this transaction-level test a small
  // valid-drop probe in addition to the wrapper kill/reset coverage below.
  logic         iter_valid;
  fp_op_t       iter_op;
  logic         iter_is_double;
  logic         iter_is_half;
  logic [63:0]  iter_operand_a;
  logic [63:0]  iter_operand_b;
  logic [63:0]  iter_operand_c;
  logic [63:0]  iter_conv_int;
  logic [6:0]   iter_conv_shift;
  logic         iter_conv_is_32;
  logic [31:0]  iter_fpcr;
  logic         iter_kill;
  logic         iter_pause;
  logic         iter_done;
  logic         iter_busy;
  logic [63:0]  iter_result;
  logic [63:0]  iter_int_result;
  logic [31:0]  iter_fpsr_flags;
  logic [3:0]   iter_cmp_nzcv;

  lcvex_fp_scalar #(.FP_ITER(1'b1)) valid_drop_scalar (
      .clk            (clk),
      .rst_n          (rst_n),
      .valid          (iter_valid),
      .op             (iter_op),
      .is_double      (iter_is_double),
      .is_half        (iter_is_half),
      .fcvt_dst_half  (1'b0),
      .rint_mode      (3'd0),
      .operand_a      (iter_operand_a),
      .operand_b      (iter_operand_b),
      .operand_c      (iter_operand_c),
      .conv_int       (iter_conv_int),
      .conv_shift     (iter_conv_shift),
      .conv_is_32     (iter_conv_is_32),
      .fpcr           (iter_fpcr),
      .compare_zero   (1'b0),
      .signal_all_nans(1'b0),
      .iter_kill      (iter_kill),
      .iter_pause     (iter_pause),
      .iter_busy      (iter_busy),
      .iter_done      (iter_done),
      .result         (iter_result),
      .int_result     (iter_int_result),
      .fpsr_flags     (iter_fpsr_flags),
      .cmp_nzcv       (iter_cmp_nzcv),
      .div_busy       (),
      .div_done       ()
  );

  lcvex_fp_exec dut (
      .clk(clk), .rst_n(rst_n),
      .req_valid(req_valid), .req(req), .req_ready(req_ready),
      .rsp_valid(rsp_valid), .rsp(rsp), .rsp_ready(rsp_ready),
      .kill(kill), .busy(busy), .issued(issued)
  );

  task automatic wait_rsp;
    begin
      while (!rsp_valid) @(posedge clk);
    end
  endtask

  task automatic issue_scalar;
    input fp_op_t op;
    input logic dbl;
    input logic [63:0] a;
    input logic [63:0] b;
    input logic [63:0] c;
    input logic [31:0] fpcr;
    input logic we_v;
    input logic we_gpr;
    input logic [4:0] v_rd;
    input logic [4:0] gpr_rd;
    input logic [63:0] want_v;
    input logic [63:0] want_gpr;
    input logic [31:0] want_flags;
    input logic [3:0] want_nzcv;
    input string name;
    begin
      req_valid = 1'b1;
      req = '0;
      req.valid = 1'b1;
      req.kind = FP_EXEC_KIND_SCALAR;
      req.scalar_op = op;
      req.is_double = dbl;
      req.operand_a = {64'd0, a};
      req.operand_b = {64'd0, b};
      req.operand_c = {64'd0, c};
      req.fpcr = fpcr;
      req.v_we = we_v;
      req.gpr_we = we_gpr;
      req.v_rd = v_rd;
      req.gpr_rd = gpr_rd;
      req.fpsr_we = (op != FP_OP_MOV);
      req.nzcv_we = (op == FP_OP_CMP);
      req.tag = 16'h1234;
      $display("TB issue %s before req_ready=%b busy=%b", name, req_ready, busy);
      while (!req_ready) @(posedge clk);
      $display("TB issue %s req_ready high, sending", name);
      @(posedge clk); // accept on this edge
      @(negedge clk);
      req_valid = 1'b0;
      $display("TB issue %s after accept busy=%b", name, busy);
      wait_rsp();
      $display("TB issue %s got rsp", name);
      if (rsp.tag !== 16'h1234) $fatal(1, "%s tag mismatch", name);
      if (rsp.v_we !== we_v) $fatal(1, "%s v_we mismatch", name);
      if (rsp.v_data[63:0] !== want_v) $fatal(1, "%s v_data mismatch: got %016h want %016h",
                                               name, rsp.v_data[63:0], want_v);
      if (rsp.gpr_data !== want_gpr) $fatal(1, "%s gpr mismatch", name);
      if (rsp.fpsr_flags !== want_flags) $fatal(1, "%s flags mismatch got %08h want %08h",
                                                name, rsp.fpsr_flags, want_flags);
      if (rsp.nzcv !== want_nzcv) $fatal(1, "%s nzcv mismatch", name);
      rsp_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      rsp_ready = 1'b0;
      if (rsp_valid || rsp.v_data[63:0] !== want_v ||
          rsp.gpr_data !== want_gpr || rsp.fpsr_flags !== want_flags)
        $fatal(1, "%s response payload was not retained after consume", name);
      $display("PASS %s", name);
    end
  endtask

  // Round17 TX_DONE cleanup cut: rsp_ready must only retire the response
  // ownership state.  The non-architectural accumulator may remain stale
  // until the next request acceptance clears it, removing ready from its
  // clock-enable cone without leaking state between transactions.
  task automatic accumulator_cleanup_probe;
    logic [127:0] held_acc;
    logic [31:0]  held_flags;
    begin
      req_valid = 1'b1;
      req = '0;
      req.valid = 1'b1;
      req.kind = FP_EXEC_KIND_NEON;
      req.neon_op = NEON_FP_OP_FADD;
      req.operand_a = 128'h0000_0000_0000_0000_3f80_0000_7fa0_0001;
      req.operand_b = 128'h0000_0000_0000_0000_4000_0000_3f80_0000;
      req.v_we = 1'b1;
      req.v_rd = 5'd4;
      req.fpsr_we = 1'b1;
      req.tag = 16'hac17;
      while (!req_ready) @(posedge clk);
      @(posedge clk);
      @(negedge clk);
      req_valid = 1'b0;
      wait_rsp();
      @(negedge clk);
      if (rsp.tag !== 16'hac17 ||
          rsp.v_data !== 128'h0000_0000_0000_0000_4040_0000_7fe0_0001 ||
          rsp.fpsr_flags !== 32'h0000_0001)
        $fatal(1, "Round17 accumulator probe response mismatch");
      held_acc = dut.acc;
      held_flags = dut.acc_flags;
      if (held_acc == 128'd0 || held_flags == 32'd0)
        $fatal(1, "Round17 accumulator probe did not create non-zero state");
      repeat (3) begin
        @(posedge clk);
        @(negedge clk);
        if (!rsp_valid || dut.acc !== held_acc || dut.acc_flags !== held_flags)
          $fatal(1, "Round17 held response changed accumulator state");
      end

      rsp_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      rsp_ready = 1'b0;
      if (rsp_valid || dut.acc !== held_acc || dut.acc_flags !== held_flags)
        $fatal(1, "Round17 TX_DONE handshake cleared accumulator state");

      req_valid = 1'b1;
      req = '0;
      req.valid = 1'b1;
      req.kind = FP_EXEC_KIND_SCALAR;
      req.scalar_op = FP_OP_ADD;
      req.operand_a = {64'd0, 64'h0000_0000_3f80_0000};
      req.operand_b = {64'd0, 64'h0000_0000_4000_0000};
      req.v_we = 1'b1;
      req.v_rd = 5'd5;
      req.fpsr_we = 1'b1;
      req.tag = 16'hac18;
      while (!req_ready) @(posedge clk);
      @(posedge clk);
      @(negedge clk);
      req_valid = 1'b0;
      if (dut.acc !== 128'd0 || dut.acc_flags !== 32'd0)
        $fatal(1, "Round17 next request did not clear stale accumulator");
      wait_rsp();
      if (rsp.tag !== 16'hac18 ||
          rsp.v_data[63:0] !== 64'h0000_0000_4040_0000 ||
          rsp.fpsr_flags !== 32'd0)
        $fatal(1, "Round17 request after retained accumulator mismatch");
      rsp_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      rsp_ready = 1'b0;
      $display("PASS Round17 TX_DONE accumulator retain/reissue");
    end
  endtask

  // R18 kill/reissue coverage for the wrapper's three transaction states.
  // A four-slot ordinary FADD first makes slot 0 visible in acc/acc_flags;
  // the kill is then armed only after a non-zero partial payload exists.  The
  // kill must release all ownership/response state while retaining that dead
  // payload, and the replacement request must clear it at acceptance before
  // its first slot can observe it.
  task automatic kill_reissue_acc_state_probe;
    input integer       mode;
    input logic [15:0]  kill_tag;
    input logic [15:0]  reissue_tag;
    input string        name;
    logic [127:0]       held_acc;
    logic [31:0]        held_flags;
    integer             waited;
    begin
      req_valid = 1'b1;
      req = '0;
      req.valid = 1'b1;
      req.kind = FP_EXEC_KIND_NEON;
      req.neon_op = NEON_FP_OP_FADD;
      req.quad = 1'b1;
      req.operand_a = 128'h3f80_0000_3f80_0000_3f80_0000_3f80_0000;
      req.operand_b = 128'h3380_0000_3380_0000_3380_0000_3380_0000;
      req.fpcr = 32'h0040_0000; // round toward +Inf: non-zero IXC flags
      req.v_we = 1'b1;
      req.v_rd = 5'd21;
      req.fpsr_we = 1'b1;
      req.tag = kill_tag;
      while (!req_ready) @(posedge clk);
      @(posedge clk);
      @(negedge clk);
      req_valid = 1'b0;

      // Wait for a state-specific boundary instead of baking in scalar
      // datapath latency.  TX_RUN/TX_SLOT target slot 1 so acc and flags
      // already contain slot 0's result; TX_DONE holds the final response.
      waited = 0;
      while (1) begin
        if ((mode == 0 && dut.state === 2'd1 && dut.slot_idx === 3'd1 &&
             dut.acc !== 128'd0 && dut.acc_flags !== 32'd0) ||
            (mode == 1 && dut.state === 2'd3 && dut.slot_idx === 3'd1 &&
             dut.slot_result_valid && dut.acc !== 128'd0 &&
             dut.acc_flags !== 32'd0) ||
            (mode == 2 && dut.state === 2'd2 && rsp_valid &&
             dut.acc !== 128'd0 && dut.acc_flags !== 32'd0)) begin
          break;
        end
        @(posedge clk);
        #1;
        waited = waited + 1;
        if (waited > 256)
          $fatal(1, "%s timeout waiting for target wrapper state", name);
      end

      // Arm kill on the following falling edge so it is sampled before any
      // possible same-cycle slot update.  The kill branch intentionally has
      // no acc/acc_flags assignments in R18.
      @(negedge clk);
      held_acc = dut.acc;
      held_flags = dut.acc_flags;
      kill = 1'b1;
      @(posedge clk);
      @(negedge clk);
      kill = 1'b0;
      #1;
      if (dut.state !== 2'd0 || rsp_valid || busy || !req_ready ||
          rsp !== '0)
        $fatal(1, "%s kill did not clear wrapper ownership/response", name);
      if (dut.acc !== held_acc || dut.acc_flags !== held_flags ||
          held_acc === 128'd0 || held_flags === 32'd0)
        $fatal(1, "%s kill unexpectedly changed accumulator payload", name);

      // Reissue the same operation with a fresh tag.  The acceptance edge is
      // the required initialization point; inspect it before TX_RUN can
      // complete slot 0 and prove no killed partial result leaks forward.
      req_valid = 1'b1;
      req = '0;
      req.valid = 1'b1;
      req.kind = FP_EXEC_KIND_NEON;
      req.neon_op = NEON_FP_OP_FADD;
      req.quad = 1'b1;
      req.operand_a = 128'h3f80_0000_3f80_0000_3f80_0000_3f80_0000;
      req.operand_b = 128'h3380_0000_3380_0000_3380_0000_3380_0000;
      req.fpcr = 32'h0040_0000;
      req.v_we = 1'b1;
      req.v_rd = 5'd22;
      req.fpsr_we = 1'b1;
      req.tag = reissue_tag;
      while (!req_ready) @(posedge clk);
      @(posedge clk);
      @(negedge clk);
      req_valid = 1'b0;
      if (dut.state !== 2'd1 || dut.acc !== 128'd0 ||
          dut.acc_flags !== 32'd0)
        $fatal(1, "%s accepted request did not initialize accumulator", name);

      waited = 0;
      while (!rsp_valid) begin
        @(posedge clk);
        #1;
        waited = waited + 1;
        if (waited > 256)
          $fatal(1, "%s replacement response timeout", name);
      end
      if (rsp.tag !== reissue_tag ||
          rsp.v_data !== 128'h3f80_0001_3f80_0001_3f80_0001_3f80_0001 ||
          rsp.fpsr_flags !== 32'h0000_0010)
        $fatal(1, "%s replacement response mismatch", name);
      rsp_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      rsp_ready = 1'b0;
      if (rsp_valid)
        $fatal(1, "%s replacement response was consumed more than once", name);
      $display("PASS %s kill/reissue", name);
    end
  endtask


  task automatic issue_neon;
    input neon_fp_op_t  op;
    input logic         half;
    input logic         dbl;
    input logic         quad;
    input logic [2:0]   rint;
    input logic [127:0] a;
    input logic [127:0] b;
    input logic [127:0] c;
    input logic [31:0]  fpcr;
    input logic [127:0] want;
    input logic [31:0]  want_flags;
    input logic         hold;
    input string        name;
    begin
      req_valid = 1'b1;
      req = '0;
      req.valid = 1'b1;
      req.kind = FP_EXEC_KIND_NEON;
      req.neon_op = op;
      req.is_double = dbl;
      req.is_half = half;
      req.quad = quad;
      req.rint_mode = rint;
      req.operand_a = a;
      req.operand_b = b;
      req.operand_c = c;
      req.fpcr = fpcr;
      req.v_we = 1'b1;
      req.v_rd = 5'd4;
      req.fpsr_we = 1'b1;
      req.tag = 16'h5678;
      while (!req_ready) @(posedge clk);
      @(posedge clk);
      @(negedge clk);
      req_valid = 1'b0;
      wait_rsp();
      if (rsp.v_data !== want) $fatal(1, "%s v_data mismatch: got %032h want %032h",
                                              name, rsp.v_data, want);
      if (rsp.fpsr_flags !== want_flags) $fatal(1, "%s flags mismatch got %08h want %08h",
                                                    name, rsp.fpsr_flags, want_flags);
      if (hold) begin
        // Keep rsp_ready low for two more cycles: response must remain stable
        // and the single-owner wrapper must not accept another request.
        if (!rsp_valid) $fatal(1, "%s expected response", name);
        @(posedge clk);
        @(negedge clk);
        if (rsp.v_data !== want || rsp.fpsr_flags !== want_flags)
          $fatal(1, "%s held response changed", name);
        if (req_ready) $fatal(1, "%s accepted new request while held", name);
        @(posedge clk);
        @(negedge clk);
        if (rsp.v_data !== want || rsp.fpsr_flags !== want_flags)
          $fatal(1, "%s held response changed on second cycle", name);
        if (req_ready) $fatal(1, "%s accepted new request while held long", name);
      end
      rsp_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      rsp_ready = 1'b0;
      if (rsp_valid || rsp.v_data !== want || rsp.fpsr_flags !== want_flags)
        $fatal(1, "%s response payload was not retained after consume", name);
      $display("PASS %s", name);
    end
  endtask

  // FP-P3 counted scalar issue: checks raw result and returns request-to-
  // response latency in clock cycles (accepting edge -> first rsp_valid edge).
  task automatic issue_scalar_lat;
    input fp_op_t op;
    input logic half;
    input logic dbl;
    input logic [63:0] a;
    input logic [63:0] b;
    input logic [63:0] c;
    input logic [31:0] fpcr;
    input logic we_v;
    input logic we_gpr;
    input logic [4:0] v_rd;
    input logic [4:0] gpr_rd;
    input logic [63:0] want_v;
    input logic [63:0] want_gpr;
    input logic [31:0] want_flags;
    input logic [3:0] want_nzcv;
    input string name;
    output integer lat;
    begin
      req_valid = 1'b1;
      req = '0;
      req.valid = 1'b1;
      req.kind = FP_EXEC_KIND_SCALAR;
      req.scalar_op = op;
      req.is_half = half;
      req.is_double = dbl;
      req.operand_a = {64'd0, a};
      req.operand_b = {64'd0, b};
      req.operand_c = {64'd0, c};
      req.fpcr = fpcr;
      req.v_we = we_v;
      req.gpr_we = we_gpr;
      req.v_rd = v_rd;
      req.gpr_rd = gpr_rd;
      req.fpsr_we = (op != FP_OP_MOV);
      req.nzcv_we = (op == FP_OP_CMP);
      req.tag = 16'h1234;
      while (!req_ready) @(posedge clk);
      @(posedge clk); // accept on this edge
      @(negedge clk);
      req_valid = 1'b0;
      lat = 0;
      while (!rsp_valid) begin
        @(posedge clk);
        lat = lat + 1;
        if (lat > 1000) $fatal(1, "%s latency timeout", name);
      end
      if (rsp.tag !== 16'h1234) $fatal(1, "%s tag mismatch", name);
      if (rsp.v_we !== we_v) $fatal(1, "%s v_we mismatch", name);
      if (rsp.v_data[63:0] !== want_v) $fatal(1, "%s v_data mismatch: got %016h want %016h",
                                               name, rsp.v_data[63:0], want_v);
      if (rsp.gpr_data !== want_gpr) $fatal(1, "%s gpr mismatch", name);
      if (rsp.fpsr_flags !== want_flags) $fatal(1, "%s flags mismatch got %08h want %08h",
                                                name, rsp.fpsr_flags, want_flags);
      if (rsp.nzcv !== want_nzcv) $fatal(1, "%s nzcv mismatch", name);
      rsp_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      rsp_ready = 1'b0;
      if (rsp_valid) $fatal(1, "%s response was consumed more than once", name);
      $display("PASS %s latency=%0d", name, lat);
    end
  endtask

  task automatic issue_neon_lat;
    input neon_fp_op_t  op;
    input logic         half;
    input logic         dbl;
    input logic         quad;
    input logic [2:0]   rint;
    input logic [127:0] a;
    input logic [127:0] b;
    input logic [127:0] c;
    input logic [31:0]  fpcr;
    input logic [127:0] want;
    input logic [31:0]  want_flags;
    input string        name;
    output integer      lat;
    begin
      req_valid = 1'b1;
      req = '0;
      req.valid = 1'b1;
      req.kind = FP_EXEC_KIND_NEON;
      req.neon_op = op;
      req.is_double = dbl;
      req.is_half = half;
      req.quad = quad;
      req.rint_mode = rint;
      req.operand_a = a;
      req.operand_b = b;
      req.operand_c = c;
      req.fpcr = fpcr;
      req.v_we = 1'b1;
      req.v_rd = 5'd4;
      req.fpsr_we = 1'b1;
      req.tag = 16'h5678;
      while (!req_ready) @(posedge clk);
      @(posedge clk);
      @(negedge clk);
      req_valid = 1'b0;
      lat = 0;
      while (!rsp_valid) begin
        @(posedge clk);
        lat = lat + 1;
        if (lat > 2000) $fatal(1, "%s latency timeout", name);
      end
      if (rsp.v_data !== want) $fatal(1, "%s v_data mismatch: got %032h want %032h",
                                              name, rsp.v_data, want);
      if (rsp.fpsr_flags !== want_flags) $fatal(1, "%s flags mismatch got %08h want %08h",
                                                    name, rsp.fpsr_flags, want_flags);
      rsp_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      rsp_ready = 1'b0;
      $display("PASS %s latency=%0d", name, lat);
    end
  endtask

  task automatic valid_drop_probe;
    begin
      iter_valid = 1'b1;
      iter_op = FP_OP_ADD;
      iter_is_double = 1'b0;
      iter_is_half = 1'b0;
      iter_operand_a = 64'h0000_0000_3f80_0000;
      iter_operand_b = 64'h0000_0000_4000_0000;
      iter_operand_c = 64'd0;
      iter_conv_int = 64'd0;
      iter_conv_shift = 7'd0;
      iter_conv_is_32 = 1'b0;
      iter_fpcr = 32'd0;
      // IT_ARITH has captured the operands at this point; dropping valid must
      // abandon the internal pipeline without producing a stale iter_done.
      @(posedge clk);
      @(negedge clk);
      iter_valid = 1'b0;
      repeat (3) @(posedge clk);
      @(negedge clk);
      if (iter_busy || iter_done)
        $fatal(1, "valid drop left FP_ITER transaction active");

      // Reissue after the drop to prove the abandoned payload cannot leak.
      iter_valid = 1'b1;
      iter_op = FP_OP_ADD;
      iter_operand_a = 64'h0000_0000_4000_0000;
      iter_operand_b = 64'h0000_0000_4040_0000;
      wait (iter_done);
      if (iter_result !== 64'h0000_0000_40a0_0000)
        $fatal(1, "valid-drop reissue mismatch: got %016h", iter_result);
      iter_valid = 1'b0;
      @(posedge clk);
      $display("PASS FP_ITER valid drop/reissue");
    end
  endtask

  // R18 valid-drop coverage: dropping valid in IT_PREP, IT_PACK_PRE, or
  // IT_PACK must abandon the payload without a stale iter_done pulse.  The
  // reissues also prove that a cleared boundary cannot leak old results.
  task automatic valid_drop_pack_probe;
    begin
      iter_valid = 1'b1;
      iter_op = FP_OP_ADD;
      iter_is_double = 1'b0;
      iter_is_half = 1'b0;
      iter_operand_a = 64'h0000_0000_3f80_0000;
      iter_operand_b = 64'h0000_0000_4000_0000;
      iter_operand_c = 64'd0;
      iter_conv_int = 64'd0;
      iter_conv_shift = 7'd0;
      iter_conv_is_32 = 1'b0;
      iter_fpcr = 32'd0;
      // IDLE -> ARITH -> ALIGN -> ADD -> PREP; drop while IT_PREP is
      // active, before round_pack_pre can publish pack_pre.
      repeat (4) @(posedge clk);
      @(negedge clk);
      iter_valid = 1'b0;
      repeat (2) @(posedge clk);
      @(negedge clk);
      if (iter_busy || iter_done)
        $fatal(1, "valid drop in IT_PREP left FP_ITER transaction active");

      iter_valid = 1'b1;
      iter_operand_a = 64'h0000_0000_4000_0000;
      iter_operand_b = 64'h0000_0000_4040_0000;
      wait (iter_done);
      if (iter_result !== 64'h0000_0000_40a0_0000)
        $fatal(1, "IT_PREP valid-drop reissue mismatch: got %016h", iter_result);
      iter_valid = 1'b0;
      @(posedge clk);

      iter_valid = 1'b1;
      iter_operand_a = 64'h0000_0000_3f80_0000;
      iter_operand_b = 64'h0000_0000_4000_0000;
      // The sixth edge enters IT_PACK_PRE after the new IT_PACK_SCAN boundary.
      // Drop valid before the following edge so the boundary is cleared.
      repeat (6) @(posedge clk);
      @(negedge clk);
      iter_valid = 1'b0;
      repeat (2) @(posedge clk);
      @(negedge clk);
      if (iter_busy || iter_done)
        $fatal(1, "valid drop in IT_PACK_PRE left FP_ITER transaction active");

      iter_valid = 1'b1;
      iter_operand_a = 64'h0000_0000_4000_0000;
      iter_operand_b = 64'h0000_0000_4040_0000;
      wait (iter_done);
      if (iter_result !== 64'h0000_0000_40a0_0000)
        $fatal(1, "IT_PACK_PRE valid-drop reissue mismatch: got %016h", iter_result);
      iter_valid = 1'b0;
      @(posedge clk);

      iter_valid = 1'b1;
      iter_operand_a = 64'h0000_0000_3f80_0000;
      iter_operand_b = 64'h0000_0000_4000_0000;
      // The seventh edge enters IT_PACK after the p1 GRS payload is captured.
      // Drop valid before the following edge so the final pack cannot fire.
      repeat (7) @(posedge clk);
      @(negedge clk);
      iter_valid = 1'b0;
      repeat (2) @(posedge clk);
      @(negedge clk);
      if (iter_busy || iter_done)
        $fatal(1, "valid drop in IT_PACK left FP_ITER transaction active");

      iter_valid = 1'b1;
      iter_operand_a = 64'h0000_0000_4000_0000;
      iter_operand_b = 64'h0000_0000_4040_0000;
      wait (iter_done);
      if (iter_result !== 64'h0000_0000_40a0_0000)
        $fatal(1, "IT_PACK valid-drop reissue mismatch: got %016h", iter_result);
      iter_valid = 1'b0;
      @(posedge clk);
      $display("PASS FP_ITER IT_PREP/IT_PACK_PRE/IT_PACK valid drop/reissue");
    end
  endtask

  // R18 kill coverage mirrors valid-drop across IT_PREP, IT_PACK_PRE and
  // IT_PACK.  Kill is asserted before the state-machine edge and valid is
  // withdrawn at the same time, so no transient iter_done is accepted by the
  // direct probe.
  task automatic kill_pack_state_probe;
    begin
      iter_valid = 1'b1;
      iter_op = FP_OP_ADD;
      iter_is_double = 1'b0;
      iter_is_half = 1'b0;
      iter_operand_a = 64'h0000_0000_3f80_0000;
      iter_operand_b = 64'h0000_0000_4000_0000;
      iter_operand_c = 64'd0;
      iter_conv_int = 64'd0;
      iter_conv_shift = 7'd0;
      iter_conv_is_32 = 1'b0;
      iter_fpcr = 32'd0;
      repeat (4) @(posedge clk);
      @(negedge clk);
      iter_valid = 1'b0;
      iter_kill = 1'b1;
      @(posedge clk);
      @(negedge clk);
      iter_kill = 1'b0;
      if (iter_busy || iter_done || iter_result !== 64'd0)
        $fatal(1, "kill in IT_PREP left FP_ITER payload");

      iter_valid = 1'b1;
      iter_operand_a = 64'h0000_0000_3f80_0000;
      iter_operand_b = 64'h0000_0000_4000_0000;
      repeat (6) @(posedge clk);
      @(negedge clk);
      iter_valid = 1'b0;
      iter_kill = 1'b1;
      @(posedge clk);
      @(negedge clk);
      iter_kill = 1'b0;
      if (iter_busy || iter_done || iter_result !== 64'd0)
        $fatal(1, "kill in IT_PACK_PRE left FP_ITER payload");

      iter_valid = 1'b1;
      iter_operand_a = 64'h0000_0000_3f80_0000;
      iter_operand_b = 64'h0000_0000_4000_0000;
      repeat (7) @(posedge clk);
      @(negedge clk);
      iter_valid = 1'b0;
      iter_kill = 1'b1;
      @(posedge clk);
      @(negedge clk);
      iter_kill = 1'b0;
      if (iter_busy || iter_done || iter_result !== 64'd0)
        $fatal(1, "kill in IT_PACK left FP_ITER payload");

      iter_valid = 1'b1;
      iter_operand_a = 64'h0000_0000_4000_0000;
      iter_operand_b = 64'h0000_0000_4040_0000;
      wait (iter_done);
      if (iter_result !== 64'h0000_0000_40a0_0000)
        $fatal(1, "IT_PACK kill reissue mismatch: got %016h", iter_result);
      iter_valid = 1'b0;
      @(posedge clk);
      $display("PASS FP_ITER IT_PREP/IT_PACK_PRE/IT_PACK kill reissue");
    end
  endtask

  // Reset coverage for all states around the new boundary.  The direct
  // scalar instance is reset while IT_PREP, IT_PACK_PRE and IT_PACK are
  // active; no pre-reset payload may assert iter_done after reset release.
  task automatic reset_pack_state_probe;
    begin
      iter_valid = 1'b1;
      iter_op = FP_OP_ADD;
      iter_is_double = 1'b0;
      iter_is_half = 1'b0;
      iter_operand_a = 64'h0000_0000_3f80_0000;
      iter_operand_b = 64'h0000_0000_4000_0000;
      iter_operand_c = 64'd0;
      iter_conv_int = 64'd0;
      iter_conv_shift = 7'd0;
      iter_conv_is_32 = 1'b0;
      iter_fpcr = 32'd0;
      repeat (4) @(posedge clk);
      iter_valid = 1'b0;
      rst_n = 1'b0;
      #2;
      if (iter_busy || iter_done || iter_result !== 64'd0)
        $fatal(1, "reset in IT_PREP left FP_ITER payload");
      rst_n = 1'b1;
      @(negedge clk);
      if (iter_busy || iter_done || iter_result !== 64'd0)
        $fatal(1, "IT_PREP reset release left FP_ITER payload");

      iter_valid = 1'b1;
      iter_operand_a = 64'h0000_0000_3f80_0000;
      iter_operand_b = 64'h0000_0000_4000_0000;
      repeat (6) @(posedge clk);
      iter_valid = 1'b0;
      rst_n = 1'b0;
      #2;
      if (iter_busy || iter_done || iter_result !== 64'd0)
        $fatal(1, "reset in IT_PACK_PRE left FP_ITER payload");
      rst_n = 1'b1;
      @(negedge clk);
      if (iter_busy || iter_done || iter_result !== 64'd0)
        $fatal(1, "IT_PACK_PRE reset release left FP_ITER payload");

      iter_valid = 1'b1;
      iter_operand_a = 64'h0000_0000_3f80_0000;
      iter_operand_b = 64'h0000_0000_4000_0000;
      repeat (7) @(posedge clk);
      iter_valid = 1'b0;
      rst_n = 1'b0;
      #2;
      if (iter_busy || iter_done || iter_result !== 64'd0)
        $fatal(1, "reset in IT_PACK left FP_ITER payload");
      rst_n = 1'b1;
      @(negedge clk);
      if (iter_busy || iter_done || iter_result !== 64'd0)
        $fatal(1, "IT_PACK reset release left FP_ITER payload");

      iter_valid = 1'b1;
      iter_operand_a = 64'h0000_0000_4000_0000;
      iter_operand_b = 64'h0000_0000_4040_0000;
      wait (iter_done);
      if (iter_result !== 64'h0000_0000_40a0_0000)
        $fatal(1, "IT_PACK reset reissue mismatch: got %016h", iter_result);
      iter_valid = 1'b0;
      @(posedge clk);
      $display("PASS FP_ITER IT_PREP/IT_PACK_PRE/IT_PACK reset reissue");
    end
  endtask

  // Wait for the direct scalar instance to reach the requested IT_PACK
  // boundary. The state is intentionally observed hierarchically so the
  // pause probe is not tied to divider/sqrt implementation cycle counts.
  // it_fin_valid_r distinguishes iterative p1 payloads from ordinary pp_pre.
  task automatic wait_iter_pack_state;
    input logic   iterative;
    input integer timeout_cycles;
    integer waited;
    begin
      waited = 0;
      // A preceding probe may have left IT_PACK visible until its state
      // machine's nonblocking assignment reaches the NBA region.  Always
      // cross one complete edge before testing the target, otherwise a new
      // transaction can mistake that stale IT_PACK for its own boundary.
      @(posedge clk);
      #1;
      waited = 1;
      if (iterative) begin
        while (!(valid_drop_scalar.g_iter.it_state_r === ITER_STATE_PACK &&
                 valid_drop_scalar.g_iter.it_fin_valid_r === 1'b1)) begin
          @(posedge clk);
          #1;
          waited = waited + 1;
          if (waited > timeout_cycles)
            $fatal(1, "timeout waiting for iterative IT_PACK (%0d cycles)",
                   timeout_cycles);
        end
      end else begin
        while (!(valid_drop_scalar.g_iter.it_state_r === ITER_STATE_PACK &&
                 valid_drop_scalar.g_iter.it_fin_valid_r === 1'b0)) begin
          @(posedge clk);
          #1;
          waited = waited + 1;
          if (waited > timeout_cycles)
            $fatal(1, "timeout waiting for ordinary IT_PACK (%0d cycles)",
                   timeout_cycles);
        end
      end
    end
  endtask

  // Wait for the ordinary p0 metadata register to be visible in the new
  // IT_PACK_PRE state. This is used by the added boundary pause/kill probes;
  // no implementation-specific arithmetic cycle count is assumed.
  task automatic wait_iter_pack_pre_state;
    input integer timeout_cycles;
    integer waited;
    begin
      waited = 0;
      @(posedge clk);
      #1;
      waited = 1;
      while (!(valid_drop_scalar.g_iter.it_state_r === ITER_STATE_PACK_PRE &&
               valid_drop_scalar.g_iter.it_fin_valid_r === 1'b0)) begin
        @(posedge clk);
        #1;
        waited = waited + 1;
        if (waited > timeout_cycles)
          $fatal(1, "timeout waiting for ordinary IT_PACK_PRE (%0d cycles)",
                 timeout_cycles);
      end
    end
  endtask

  // B1 pause contract for an ordinary pp_pre operation.  Pause is asserted
  // after the p1 edge has entered IT_PACK; changing live operands while the
  // state is held proves that the registered pack_mid payload, rather than
  // the live input bus, supplies the eventual result and flags.
  task automatic pause_roundpack_probe;
    begin
      iter_valid = 1'b1;
      iter_op = FP_OP_ADD;
      iter_is_double = 1'b0;
      iter_is_half = 1'b0;
      iter_operand_a = 64'h0000_0000_3f80_0000;
      iter_operand_b = 64'h0000_0000_3380_0000;
      iter_operand_c = 64'd0;
      iter_conv_int = 64'd0;
      iter_conv_shift = 7'd0;
      iter_conv_is_32 = 1'b0;
      // Round toward +Inf makes the halfway input inexact and gives the
      // payload check a non-zero FPSR result (1.0 + 2^-24 -> 0x3f800001).
      iter_fpcr = 32'h0040_0000;
      iter_pause = 1'b0;
      wait_iter_pack_state(1'b0, 32);
      @(negedge clk);
      if (!iter_busy)
        $fatal(1, "ordinary IT_PACK was not active before pause");
      iter_pause = 1'b1;
      iter_operand_a = 64'h0000_0000_4000_0000;
      iter_operand_b = 64'h0000_0000_4040_0000;
      repeat (2) begin
        @(posedge clk);
        @(negedge clk);
        if (!iter_busy || iter_done || iter_result !== 64'd0 ||
            iter_fpsr_flags !== 32'd0)
          $fatal(1, "ordinary IT_PACK changed or consumed payload while paused");
      end

      iter_pause = 1'b0;
      @(posedge clk);
      #1;
      if (valid_drop_scalar.g_iter.it_state_r !== ITER_STATE_PACK_RESULT ||
          !iter_done || iter_result !== 64'h0000_0000_3f80_0001 ||
          iter_fpsr_flags !== 32'h0000_0010)
        $fatal(1, "ordinary IT_PACK pause release mismatch: result=%016h flags=%08h",
               iter_result, iter_fpsr_flags);
      @(posedge clk);
      @(negedge clk);
      if (iter_done)
        $fatal(1, "ordinary IT_PACK pause release produced multiple done pulses");
      iter_valid = 1'b0;
      @(posedge clk);
      $display("PASS FP_ITER ordinary IT_PACK pause/release");
    end
  endtask

  // B1 pause contract for the added IT_PACK_PRE state.  The live operands are
  // changed while the leading-one metadata is held; release must still round
  // the original halfway input and preserve its inexact flag.
  task automatic pause_pack_pre_probe;
    begin
      iter_valid = 1'b1;
      iter_op = FP_OP_ADD;
      iter_is_double = 1'b0;
      iter_is_half = 1'b0;
      iter_operand_a = 64'h0000_0000_3f80_0000;
      iter_operand_b = 64'h0000_0000_3380_0000;
      iter_operand_c = 64'd0;
      iter_conv_int = 64'd0;
      iter_conv_shift = 7'd0;
      iter_conv_is_32 = 1'b0;
      iter_fpcr = 32'h0040_0000;
      iter_pause = 1'b0;
      wait_iter_pack_pre_state(32);
      @(negedge clk);
      if (!iter_busy)
        $fatal(1, "ordinary IT_PACK_PRE was not active before pause");
      iter_pause = 1'b1;
      iter_operand_a = 64'h0000_0000_4000_0000;
      iter_operand_b = 64'h0000_0000_4040_0000;
      repeat (2) begin
        @(posedge clk);
        @(negedge clk);
        if (valid_drop_scalar.g_iter.it_state_r !== ITER_STATE_PACK_PRE ||
            !iter_busy || iter_done || iter_result !== 64'd0 ||
            iter_fpsr_flags !== 32'd0)
          $fatal(1, "ordinary IT_PACK_PRE changed or consumed payload while paused");
      end

      iter_pause = 1'b0;
      // The first release edge captures pack_mid and enters IT_PACK; the
      // second captures p2 and enters the registered result window.
      @(posedge clk);
      #1;
      if (valid_drop_scalar.g_iter.it_state_r !== ITER_STATE_PACK ||
          iter_done || iter_result !== 64'd0 || iter_fpsr_flags !== 32'd0)
        $fatal(1, "ordinary IT_PACK_PRE release did not enter IT_PACK cleanly");
      @(posedge clk);
      #1;
      if (valid_drop_scalar.g_iter.it_state_r !== ITER_STATE_PACK_RESULT ||
          !iter_done || iter_result !== 64'h0000_0000_3f80_0001 ||
          iter_fpsr_flags !== 32'h0000_0010)
        $fatal(1, "ordinary IT_PACK_PRE pause release mismatch: result=%016h flags=%08h",
               iter_result, iter_fpsr_flags);
      @(posedge clk);
      @(negedge clk);
      if (iter_done)
        $fatal(1, "ordinary IT_PACK_PRE pause release produced multiple done pulses");
      iter_valid = 1'b0;
      @(posedge clk);
      $display("PASS FP_ITER ordinary IT_PACK_PRE pause/release");
    end
  endtask

  // B1 pause contract for the multi-cycle path.  timeout_cycles bounds a
  // hierarchical wait for IT_FIN p1 -> IT_PACK and deliberately does not
  // encode divider/sqrt implementation cycle counts.
  task automatic pause_iterative_probe;
    input fp_op_t     op_arg;
    input integer     timeout_cycles;
    input logic [63:0] a_arg;
    input logic [63:0] b_arg;
    input logic [63:0] changed_a;
    input logic [63:0] changed_b;
    input logic [63:0] want_result;
    input logic [31:0] want_flags;
    input string      name;
    begin
      iter_valid = 1'b1;
      iter_op = op_arg;
      iter_is_double = 1'b0;
      iter_is_half = 1'b0;
      iter_operand_a = a_arg;
      iter_operand_b = b_arg;
      iter_operand_c = 64'd0;
      iter_conv_int = 64'd0;
      iter_conv_shift = 7'd0;
      iter_conv_is_32 = 1'b0;
      iter_fpcr = 32'd0;
      iter_pause = 1'b0;
      wait_iter_pack_state(1'b1, timeout_cycles);
      @(negedge clk);
      if (!iter_busy)
        $fatal(1, "%s IT_PACK was not active before pause", name);
      iter_pause = 1'b1;
      iter_operand_a = changed_a;
      iter_operand_b = changed_b;
      repeat (2) begin
        @(posedge clk);
        @(negedge clk);
        if (!iter_busy || iter_done || iter_result !== 64'd0 ||
            iter_fpsr_flags !== 32'd0)
          $fatal(1, "%s IT_PACK changed or consumed payload while paused", name);
      end

      iter_pause = 1'b0;
      @(posedge clk);
      #1;
      if (valid_drop_scalar.g_iter.it_state_r !== ITER_STATE_PACK_RESULT ||
          !iter_done || iter_result !== want_result ||
          iter_fpsr_flags !== want_flags)
        $fatal(1, "%s IT_PACK pause release mismatch: result=%016h flags=%08h",
               name, iter_result, iter_fpsr_flags);
      @(posedge clk);
      @(negedge clk);
      if (iter_done)
        $fatal(1, "%s IT_PACK pause release produced multiple done pulses", name);
      iter_valid = 1'b0;
      @(posedge clk);
      $display("PASS %s IT_PACK pause/release", name);
    end
  endtask

  // Kill/reset have priority over pause.  The first half checks synchronous
  // iter_kill against an ordinary IT_PACK payload; the second half checks the
  // asynchronous reset path while an iterative IT_PACK payload is paused.
  task automatic pause_priority_probe;
    begin
      iter_valid = 1'b1;
      iter_op = FP_OP_ADD;
      iter_is_double = 1'b0;
      iter_is_half = 1'b0;
      iter_operand_a = 64'h0000_0000_3f80_0000;
      iter_operand_b = 64'h0000_0000_4000_0000;
      iter_operand_c = 64'd0;
      iter_conv_int = 64'd0;
      iter_conv_shift = 7'd0;
      iter_conv_is_32 = 1'b0;
      iter_fpcr = 32'd0;
      iter_pause = 1'b0;
      iter_kill = 1'b0;
      wait_iter_pack_state(1'b0, 32);
      @(negedge clk);
      if (!iter_busy)
        $fatal(1, "ordinary IT_PACK was not active before pause/kill");
      iter_pause = 1'b1;
      iter_valid = 1'b0;
      iter_kill = 1'b1;
      @(posedge clk);
      @(negedge clk);
      iter_kill = 1'b0;
      iter_pause = 1'b0;
      if (iter_busy || iter_done || iter_result !== 64'd0)
        $fatal(1, "iter_kill did not override ordinary IT_PACK pause");

      iter_valid = 1'b1;
      iter_op = FP_OP_SQRT;
      iter_operand_a = 64'h0000_0000_4080_0000;
      iter_operand_b = 64'd0;
      wait_iter_pack_state(1'b1, 120);
      @(negedge clk);
      if (!iter_busy)
        $fatal(1, "iterative IT_PACK was not active before pause/reset");
      iter_pause = 1'b1;
      iter_valid = 1'b0;
      rst_n = 1'b0;
      #2;
      if (iter_busy || iter_done || iter_result !== 64'd0)
        $fatal(1, "reset did not override iterative IT_PACK pause");
      rst_n = 1'b1;
      iter_pause = 1'b0;
      @(negedge clk);
      if (iter_busy || iter_done || iter_result !== 64'd0)
        $fatal(1, "reset release left iterative IT_PACK payload");
      $display("PASS FP_ITER IT_PACK pause kill/reset priority");
    end
  endtask

  task automatic kill_add_state_probe;
    begin
      iter_valid = 1'b1;
      iter_op = FP_OP_ADD;
      iter_is_double = 1'b0;
      iter_is_half = 1'b0;
      iter_operand_a = 64'h0000_0000_3f80_0000;
      iter_operand_b = 64'h0000_0000_4000_0000;
      iter_operand_c = 64'd0;
      iter_conv_int = 64'd0;
      iter_conv_shift = 7'd0;
      iter_conv_is_32 = 1'b0;
      iter_fpcr = 32'd0;
      iter_kill = 1'b0;
      // Kill while IT_ALIGN is active, before add_mid can be consumed.
      @(posedge clk);
      @(posedge clk);
      @(negedge clk);
      iter_kill = 1'b1;
      @(posedge clk);
      @(negedge clk);
      iter_kill = 1'b0;
      if (iter_busy || iter_done)
        $fatal(1, "kill in IT_ALIGN left FP_ITER transaction active");

      // Immediate replacement, then kill while the new IT_ADD state is
      // active, proving both sides of the newly introduced boundary clear.
      iter_valid = 1'b1;
      @(posedge clk);
      @(posedge clk);
      @(posedge clk);
      @(negedge clk);
      iter_kill = 1'b1;
      @(posedge clk);
      @(negedge clk);
      iter_kill = 1'b0;
      if (iter_busy || iter_done)
        $fatal(1, "kill in IT_ADD left FP_ITER transaction active");

      // Reissue once more after both kills and check that no killed payload
      // reaches iter_done.
      iter_valid = 1'b1;
      wait (iter_done);
      if (iter_result !== 64'h0000_0000_4040_0000)
        $fatal(1, "kill-add reissue mismatch: got %016h", iter_result);
      iter_valid = 1'b0;
      @(posedge clk);
      $display("PASS FP_ITER IT_ALIGN/IT_ADD kill reissue");
    end
  endtask

  // Kill an in-flight shared divider and immediately issue a replacement.
  // The replacement must not observe the killed divider's quotient/done pulse.
  task automatic kill_reissue_scalar_div;
    input logic         half;
    input logic         dbl;
    input logic [63:0]  a;
    input logic [63:0]  b;
    input logic [63:0]  want_v;
    input integer       expected_lat;
    input string        name;
    integer             lat;
    begin
      req_valid = 1'b1;
      req = '0;
      req.valid = 1'b1;
      req.kind = FP_EXEC_KIND_SCALAR;
      req.scalar_op = FP_OP_DIV;
      req.is_half = half;
      req.is_double = dbl;
      req.operand_a = {64'd0, a};
      req.operand_b = {64'd0, b};
      req.fpcr = 32'd0;
      req.v_we = 1'b1;
      req.v_rd = 5'd28;
      req.fpsr_we = 1'b1;
      while (!req_ready) @(posedge clk);
      @(posedge clk);
      @(negedge clk);
      req_valid = 1'b0;
      repeat (8) @(posedge clk);
      @(negedge clk);
      if (!busy) $fatal(1, "%s divider was not busy before kill", name);
      kill = 1'b1;
      @(posedge clk);
      @(negedge clk);
      kill = 1'b0;
      #1;
      if (busy || rsp_valid || !req_ready) begin
        $fatal(1, "%s kill did not release divider transaction", name);
      end
      issue_scalar_lat(FP_OP_DIV, half, dbl, a, b, 64'd0, 32'd0,
                       1'b1, 1'b0, 5'd29, 5'd0,
                       want_v, 64'd0, 32'd0, 4'd0, name, lat);
      if (lat != expected_lat)
        $fatal(1, "%s replacement latency got %0d expect %0d",
               name, lat, expected_lat);
    end
  endtask

  // The NEON sequencer also shares this scalar iterative state.  Kill during
  // the first lane and reissue a two-slot sqrt to verify no stale lane result
  // can advance the replacement transaction.
  task automatic kill_reissue_neon_sqrt;
    integer lat;
    begin
      req_valid = 1'b1;
      req = '0;
      req.valid = 1'b1;
      req.kind = FP_EXEC_KIND_NEON;
      req.neon_op = NEON_FP_OP_SQRT;
      req.operand_a = 128'h0000_0000_0000_0000_4110_0000_4080_0000;
      req.operand_b = 128'd0;
      req.operand_c = 128'd0;
      req.fpcr = 32'd0;
      req.v_we = 1'b1;
      req.v_rd = 5'd30;
      req.fpsr_we = 1'b1;
      while (!req_ready) @(posedge clk);
      @(posedge clk);
      @(negedge clk);
      req_valid = 1'b0;
      repeat (8) @(posedge clk);
      @(negedge clk);
      if (!busy) $fatal(1, "NEON sqrt slot was not busy before kill");
      kill = 1'b1;
      @(posedge clk);
      @(negedge clk);
      kill = 1'b0;
      #1;
      if (busy || rsp_valid || !req_ready)
        $fatal(1, "NEON sqrt kill did not release transaction");
      issue_neon_lat(NEON_FP_OP_SQRT, 1'b0, 1'b0, 1'b0, 3'd0,
                     128'h0000_0000_0000_0000_4110_0000_4080_0000,
                     128'd0, 128'd0, 32'd0,
                     128'h0000_0000_0000_0000_4040_0000_4000_0000,
                     32'd0, "NEON FSQRT.2S kill/reissue", lat);
      if (lat != 139)
        $fatal(1, "NEON sqrt replacement latency got %0d expect 139", lat);
    end
  endtask

  initial begin
    $display("TB clk start");
    forever #5 clk = ~clk;
  end

  initial begin
    req_valid = 1'b0;
    req = '0;
    rsp_ready = 1'b0;
    kill = 1'b0;
    iter_valid = 1'b0;
    iter_op = FP_OP_NONE;
    iter_is_double = 1'b0;
    iter_is_half = 1'b0;
    iter_operand_a = 64'd0;
    iter_operand_b = 64'd0;
    iter_operand_c = 64'd0;
    iter_conv_int = 64'd0;
    iter_conv_shift = 7'd0;
    iter_conv_is_32 = 1'b0;
    iter_fpcr = 32'd0;
    iter_kill = 1'b0;
    iter_pause = 1'b0;
    #7 rst_n = 1'b1;
    #1;
    $display("TB start req_ready=%b busy=%b", req_ready, busy);

    valid_drop_probe();
    valid_drop_pack_probe();
    reset_pack_state_probe();
    pause_pack_pre_probe();
    accumulator_cleanup_probe();
    kill_reissue_acc_state_probe(0, 16'hd180, 16'he180, "TX_RUN");
    kill_reissue_acc_state_probe(1, 16'hd181, 16'he181, "TX_SLOT");
    kill_reissue_acc_state_probe(2, 16'hd182, 16'he182, "TX_DONE");
    pause_roundpack_probe();
    pause_iterative_probe(FP_OP_DIV, 400,
                          64'h0000_0000_3f80_0000,
                          64'h0000_0000_4040_0000,
                          64'h0000_0000_4080_0000,
                          64'h0000_0000_3f80_0000,
                          64'h0000_0000_3eaaaaab,
                          32'h0000_0010,
                          "FDIV.S");
    pause_iterative_probe(FP_OP_SQRT, 120,
                          64'h0000_0000_4000_0000, 64'd0,
                          64'h0000_0000_4080_0000, 64'd0,
                          64'h0000_0000_3fb504f3,
                          32'h0000_0010,
                          "FSQRT.S");
    pause_priority_probe();
    kill_add_state_probe();
    kill_pack_state_probe();

    // Single issue and scalar FADD raw.
    issue_scalar(FP_OP_ADD, 1'b0, 64'h3f80_0000, 64'h4000_0000, 64'd0,
                 32'd0, 1'b1, 1'b0, 5'd1, 5'd0,
                 64'h0000_0000_4040_0000, 64'd0, 32'd0, 4'd0, "FADD.S tx");

    // FP_ITER ADD/SUB special and cancellation paths.  These vectors exercise
    // the fields carried by add_mid across the new register boundary.
    issue_scalar(FP_OP_ADD, 1'b0, 64'h7fc1_2345, 64'h3f80_0000, 64'd0,
                 32'd0, 1'b1, 1'b0, 5'd30, 5'd0,
                 64'h0000_0000_7fc1_2345, 64'd0, 32'd0, 4'd0,
                 "FADD.S FP_ITER qNaN payload");
    issue_scalar(FP_OP_ADD, 1'b0, 64'h7fa1_2345, 64'h3f80_0000, 64'd0,
                 32'd0, 1'b1, 1'b0, 5'd31, 5'd0,
                 64'h0000_0000_7fe1_2345, 64'd0, 32'h0000_0001, 4'd0,
                 "FADD.S FP_ITER sNaN quiet");
    issue_scalar(FP_OP_ADD, 1'b0, 64'h7fc1_2345, 64'h3f80_0000, 64'd0,
                 32'h0200_0000, 1'b1, 1'b0, 5'd0, 5'd0,
                 64'h0000_0000_7fc0_0000, 64'd0, 32'd0, 4'd0,
                 "FADD.S FP_ITER DN");
    issue_scalar(FP_OP_ADD, 1'b0, 64'h7f80_0000, 64'hff80_0000, 64'd0,
                 32'd0, 1'b1, 1'b0, 5'd1, 5'd0,
                 64'h0000_0000_7fc0_0000, 64'd0, 32'h0000_0001, 4'd0,
                 "FADD.S FP_ITER inf invalid");
    issue_scalar(FP_OP_ADD, 1'b0, 64'h3f80_0000, 64'hbf80_0000, 64'd0,
                 32'h0080_0000, 1'b1, 1'b0, 5'd2, 5'd0,
                 64'h0000_0000_8000_0000, 64'd0, 32'd0, 4'd0,
                 "FADD.S FP_ITER round-minus cancellation");
    issue_scalar(FP_OP_ADD, 1'b0, 64'h3f80_0000, 64'h0000_0001, 64'd0,
                 32'h0100_0000, 1'b1, 1'b0, 5'd3, 5'd0,
                 64'h0000_0000_3f80_0000, 64'd0, 32'h0000_0080, 4'd0,
                 "FADD.S FP_ITER FZ input");
    issue_scalar(FP_OP_ADD, 1'b0, 64'h3f80_0000, 64'hbf80_0000, 64'd0,
                 32'h0000_0000, 1'b1, 1'b0, 5'd4, 5'd0,
                 64'h0000_0000_0000_0000, 64'd0, 32'd0, 4'd0,
                 "FADD.S FP_ITER RN cancellation");
    issue_scalar(FP_OP_ADD, 1'b0, 64'h3f80_0000, 64'hbf80_0000, 64'd0,
                 32'h0040_0000, 1'b1, 1'b0, 5'd5, 5'd0,
                 64'h0000_0000_0000_0000, 64'd0, 32'd0, 4'd0,
                 "FADD.S FP_ITER RP cancellation");
    issue_scalar(FP_OP_ADD, 1'b0, 64'h3f80_0000, 64'hbf80_0000, 64'd0,
                 32'h0080_0000, 1'b1, 1'b0, 5'd6, 5'd0,
                 64'h0000_0000_8000_0000, 64'd0, 32'd0, 4'd0,
                 "FADD.S FP_ITER RM cancellation");
    issue_scalar(FP_OP_ADD, 1'b0, 64'h3f80_0000, 64'hbf80_0000, 64'd0,
                 32'h00c0_0000, 1'b1, 1'b0, 5'd7, 5'd0,
                 64'h0000_0000_0000_0000, 64'd0, 32'd0, 4'd0,
                 "FADD.S FP_ITER RZ cancellation");
    // Halfway 1.0 + 2^-24: RN ties to even, while RP increments and raises
    // IXC.  This also exercises the rmode/flags payload across add_mid.
    issue_scalar(FP_OP_ADD, 1'b0, 64'h3f80_0000, 64'h3380_0000, 64'd0,
                 32'h0000_0000, 1'b1, 1'b0, 5'd8, 5'd0,
                 64'h0000_0000_3f80_0000, 64'd0, 32'h0000_0010, 4'd0,
                 "FADD.S FP_ITER RN tie");
    issue_scalar(FP_OP_ADD, 1'b0, 64'h3f80_0000, 64'h3380_0000, 64'd0,
                 32'h0040_0000, 1'b1, 1'b0, 5'd9, 5'd0,
                 64'h0000_0000_3f80_0001, 64'd0, 32'h0000_0010, 4'd0,
                 "FADD.S FP_ITER RP tie");

    // Response hold: keep rsp_ready low one extra cycle before consuming.
    issue_scalar(FP_OP_MUL, 1'b0, 64'h3fc0_0000, 64'h4000_0000, 64'd0,
                 32'd0, 1'b1, 1'b0, 5'd2, 5'd0,
                 64'h0000_0000_4040_0000, 64'd0, 32'd0, 4'd0, "FMUL.S tx");

    // FCMP NZCV.
    issue_scalar(FP_OP_CMP, 1'b0, 64'hbf80_0000, 64'h3f80_0000, 64'd0,
                 32'd0, 1'b0, 1'b0, 5'd0, 5'd0,
                 64'd0, 64'd0, 32'd0, 4'b1000, "FCMP.S tx");

    // Scalar FDIV (multi-cycle). 2.0/1.0 = 2.0.
    issue_scalar(FP_OP_DIV, 1'b0, 64'h4000_0000, 64'h3f80_0000, 64'd0,
                 32'd0, 1'b1, 1'b0, 5'd3, 5'd0,
                 64'h0000_0000_4000_0000, 64'd0, 32'd0, 4'd0, "FDIV.S tx");

    // NEON FADD.2S low 64 only.
    begin
      req_valid = 1'b1;
      req = '0;
      req.valid = 1'b1;
      req.kind = FP_EXEC_KIND_NEON;
      req.neon_op = NEON_FP_OP_FADD;
      req.operand_a = 128'h0000_0000_0000_0000_4080_0000_3f80_0000;
      req.operand_b = 128'h0000_0000_0000_0000_4040_0000_4000_0000;
      req.v_we = 1'b1;
      req.v_rd = 5'd4;
      req.fpsr_we = 1'b1;
      req.tag = 16'h5678;
      $display("TB neon before req_ready=%b", req_ready);
      while (!req_ready) @(posedge clk);
      @(posedge clk);
      @(negedge clk);
      req_valid = 1'b0;
      wait_rsp();
      $display("TB neon got rsp");
      if (rsp.v_data[63:0] !== 64'h40e0_0000_4040_0000) $fatal(1, "NEON FADD.2S mismatch");
      rsp_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      rsp_ready = 1'b0;
      $display("PASS NEON FADD.2S tx");
    end

    // NEON 4S/2D/4H/8H slots, FMA operand C, conversions, FCMEQ mask,
    // flags OR, high-zero and held-response backpressure.
    issue_neon(NEON_FP_OP_FSUB, 1'b0, 1'b0, 1'b1, 3'd0,
               128'h4120_0000_4100_0000_40c0_0000_4080_0000,
               128'h4080_0000_4040_0000_4000_0000_3f80_0000,
               128'd0, 32'd0,
               128'h40c0_0000_40a0_0000_4080_0000_4040_0000,
               32'd0, 1'b1, "NEON FSUB.4S slot order/hold");

    issue_neon(NEON_FP_OP_FMUL, 1'b0, 1'b1, 1'b1, 3'd0,
               128'hc000_0000_0000_0000_3ff8_0000_0000_0000,
               128'h4010_0000_0000_0000_4000_0000_0000_0000,
               128'd0, 32'd0,
               128'hc020_0000_0000_0000_4008_0000_0000_0000,
               32'd0, 1'b0, "NEON FMUL.2D");

    issue_neon(NEON_FP_OP_FADD, 1'b1, 1'b0, 1'b0, 3'd0,
               128'h00000000000000003400380040003c00,
               128'h00000000000000003800340042004000,
               128'd0, 32'd0,
               128'h00000000000000003a003a0045004200,
               32'd0, 1'b0, "NEON FADD.4H high-zero");

    issue_neon(NEON_FP_OP_FMUL, 1'b1, 1'b0, 1'b1, 3'd0,
               128'h400044004000380042003c003e004000,
               128'h3c003c004000380040003c0040003c00,
               128'd0, 32'd0,
               128'h400044004400340046003c0042004000,
               32'd0, 1'b0, "NEON FMUL.8H");

    issue_neon(NEON_FP_OP_FMLA, 1'b0, 1'b0, 1'b0, 3'd0,
               128'h4000_0000_4000_0000,
               128'h4080_0000_4080_0000,
               128'h4120_0000_4120_0000,
               32'd0,
               128'h0000_0000_0000_0000_4190_0000_4190_0000,
               32'd0, 1'b0, "NEON FMLA.2S operand C");

    issue_neon(NEON_FP_OP_SCVTF, 1'b0, 1'b0, 1'b0, 3'd0,
               128'hffff_fffe_0000_0001, 128'd0, 128'd0, 32'd0,
               128'h0000_0000_0000_0000_c000_0000_3f80_0000,
               32'd0, 1'b0, "NEON SCVTF.2S sign-extend");

    issue_neon(NEON_FP_OP_FCVTZS, 1'b0, 1'b0, 1'b0, 3'd0,
               128'hc020_0000_4020_0000, 128'd0, 128'd0, 32'd0,
               128'h0000_0000_0000_0000_ffff_fffe_0000_0002,
               32'h0000_0010, 1'b0, "NEON FCVTZS.2S int writeback");

    issue_neon(NEON_FP_OP_FCMEQ, 1'b0, 1'b0, 1'b1, 3'd0,
               128'h7fa0_1234_7fc0_1234_8000_0000_3f80_0000,
               128'h3f80_0000_7fc0_1234_0000_0000_3f80_0000,
               128'd0, 32'd0,
               128'h0000_0000_0000_0000_ffff_ffff_ffff_ffff,
               32'h0000_0001, 1'b0, "NEON FCMEQ.4S mask/flags");

    issue_neon(NEON_FP_OP_FADD, 1'b0, 1'b0, 1'b0, 3'd0,
               128'h0000_0000_0000_0000_3f80_0000_3f80_0000,
               128'h0000_0000_0000_0000_3380_0000_3380_0000,
               128'd0, 32'h0040_0000,
               128'h0000_0000_0000_0000_3f80_0001_3f80_0001,
               32'h0000_0010, 1'b0, "NEON FADD.2S flags OR");

    // ---- FP-P3: iterative FSQRT/FDIV, latency probes and kill/reset ----
    // FP-SHARED-DP-CUT + FP-P3T through round18: each slot result is
    // captured in slot_*_r before the accumulator/response mux, iterative
    // DIV/SQRT retains its IT_FIN result-pipeline cycle, ADD/SUB retains its
    // IT_ADD effective-result register cycle, and ordinary pp_pre operations
    // now crosses IT_PREP -> IT_PACK_SCAN -> IT_PACK_PRE -> IT_PACK before
    // iter_done; iterative DIV/SQRT retains its existing IT_FIN -> IT_PACK.
    lat = 0;
    issue_scalar_lat(FP_OP_DIV, 1'b0, 1'b0, 64'h4000_0000, 64'h3f80_0000, 64'd0,
                     32'd0, 1'b1, 1'b0, 5'd6, 5'd0,
                     64'h0000_0000_4000_0000, 64'd0, 32'd0, 4'd0,
                     "FDIV.S iter", lat);
    if (lat != 262) $fatal(1, "FDIV.S latency table mismatch: got %0d expect 262", lat);
    issue_scalar_lat(FP_OP_SQRT, 1'b0, 1'b0, 64'h4080_0000, 64'd0, 64'd0,
                     32'd0, 1'b1, 1'b0, 5'd7, 5'd0,
                     64'h0000_0000_4000_0000, 64'd0, 32'd0, 4'd0,
                     "FSQRT.S iter", lat);
    if (lat != 70) $fatal(1, "FSQRT.S latency table mismatch: got %0d expect 70", lat);
    issue_scalar_lat(FP_OP_SQRT, 1'b0, 1'b1, 64'h4010_0000_0000_0000, 64'd0, 64'd0,
                     32'd0, 1'b1, 1'b0, 5'd8, 5'd0,
                     64'h4000_0000_0000_0000, 64'd0, 32'd0, 4'd0,
                     "FSQRT.D iter", lat);
    if (lat != 70) $fatal(1, "FSQRT.D latency table mismatch: got %0d expect 70", lat);
    issue_scalar_lat(FP_OP_SQRT, 1'b1, 1'b0, 64'h0000_0000_0000_4400, 64'd0, 64'd0,
                     32'd0, 1'b1, 1'b0, 5'd9, 5'd0,
                     64'h0000_0000_0000_4000, 64'd0, 32'd0, 4'd0,
                     "FSQRT.H iter", lat);
    if (lat != 71) $fatal(1, "FSQRT.H latency table mismatch: got %0d expect 71", lat);
    issue_scalar_lat(FP_OP_DIV, 1'b1, 1'b0, 64'h0000_0000_4000_4200,
                     64'h0000_0000_4000_4000, 64'd0, 32'd0,
                     1'b1, 1'b0, 5'd10, 5'd0,
                     64'h0000_0000_0000_3e00, 64'd0, 32'd0, 4'd0,
                     "FDIV.H iter low-lane", lat);
    if (lat != 519) $fatal(1, "FDIV.H latency table mismatch: got %0d expect 519", lat);
    issue_neon_lat(NEON_FP_OP_SQRT, 1'b0, 1'b0, 1'b0, 3'd0,
                   128'h0000_0000_0000_0000_4110_0000_4080_0000,
                   128'd0, 128'd0, 32'd0,
                   128'h0000_0000_0000_0000_4040_0000_4000_0000,
                   32'd0, "NEON FSQRT.2S iter", lat);
    if (lat != 139) $fatal(1, "NEON FSQRT.2S latency table mismatch: got %0d expect 139", lat);

    // FP-P3T round9: every iterative divider width must clear the underlying
    // divider, not only the scalar FSM, before an immediate replacement.
    kill_reissue_scalar_div(1'b0, 1'b0, 64'h4000_0000, 64'h3f80_0000,
                            64'h0000_0000_4000_0000, 262,
                            "FDIV.S kill/reissue");
    kill_reissue_scalar_div(1'b0, 1'b1,
                            64'h4000_0000_0000_0000,
                            64'h3ff0_0000_0000_0000,
                            64'h4000_0000_0000_0000, 262,
                            "FDIV.D kill/reissue");
    kill_reissue_scalar_div(1'b1, 1'b0, 64'h0000_0000_4400_4400,
                            64'h0000_0000_4000_4000,
                            64'h0000_0000_0000_4000, 519,
                            "FDIV.H kill/reissue");
    kill_reissue_neon_sqrt();

    issue_scalar_lat(FP_OP_ADD, 1'b0, 1'b0, 64'h3f80_0000, 64'h4000_0000, 64'd0,
                     32'd0, 1'b1, 1'b0, 5'd15, 5'd0,
                     64'h0000_0000_4040_0000, 64'd0, 32'd0, 4'd0,
                     "FADD.S lat", lat);
    if (lat != 11) $fatal(1, "FADD.S latency table mismatch: got %0d expect 11", lat);
    $display("measured FADD.S lat=%0d", lat);
    issue_scalar_lat(FP_OP_ADD, 1'b1, 1'b0,
                     64'h0000_0000_0000_3c00,
                     64'h0000_0000_0000_4000, 64'd0,
                     32'd0, 1'b1, 1'b0, 5'd19, 5'd0,
                     64'h0000_0000_0000_4200, 64'd0, 32'd0, 4'd0,
                     "FADD.H lat", lat);
    if (lat != 11) $fatal(1, "FADD.H latency table mismatch: got %0d expect 11", lat);
    $display("measured FADD.H lat=%0d", lat);
    issue_scalar_lat(FP_OP_ADD, 1'b0, 1'b1,
                     64'h3ff0_0000_0000_0000,
                     64'h4000_0000_0000_0000, 64'd0,
                     32'd0, 1'b1, 1'b0, 5'd20, 5'd0,
                     64'h4008_0000_0000_0000, 64'd0, 32'd0, 4'd0,
                     "FADD.D lat", lat);
    if (lat != 11) $fatal(1, "FADD.D latency table mismatch: got %0d expect 11", lat);
    $display("measured FADD.D lat=%0d", lat);

    // FP-P3T round21: MUL keeps the multiplier-product path; FMA adds one
    // private alignment-to-wide-add register cycle in IT_FMA.
    issue_scalar_lat(FP_OP_MUL, 1'b0, 1'b0, 64'h4000_0000, 64'h3fc0_0000, 64'd0,
                     32'd0, 1'b1, 1'b0, 5'd25, 5'd0,
                     64'h0000_0000_4040_0000, 64'd0, 32'd0, 4'd0,
                     "FMUL.S lat", lat);
    $display("measured FMUL.S lat=%0d", lat);
    if (lat != 10) $fatal(1, "FMUL.S latency table mismatch: got %0d expect 10", lat);
    issue_scalar_lat(FP_OP_FMADD, 1'b0, 1'b0, 64'h4000_0000, 64'h4040_0000,
                     64'h3f80_0000,
                     32'd0, 1'b1, 1'b0, 5'd26, 5'd0,
                     64'h0000_0000_40e0_0000, 64'd0, 32'd0, 4'd0,
                     "FMADD.S lat", lat);
    $display("measured FMADD.S lat=%0d", lat);
    if (lat != 11) $fatal(1, "FMADD.S latency table mismatch: got %0d expect 11", lat);
    issue_neon_lat(NEON_FP_OP_FMUL, 1'b0, 1'b0, 1'b0, 3'd0,
                   128'h0000_0000_0000_0000_4040_0000_3f80_0000,
                   128'h0000_0000_0000_0000_4080_0000_4000_0000,
                   128'd0, 32'd0,
                   128'h0000_0000_0000_0000_4140_0000_4000_0000,
                   32'd0, "NEON FMUL.2S lat", lat);
    $display("measured NEON FMUL.2S lat=%0d", lat);
    if (lat != 19) $fatal(1, "NEON FMUL.2S latency table mismatch: got %0d expect 19", lat);

    issue_neon_lat(NEON_FP_OP_FADD, 1'b0, 1'b0, 1'b0, 3'd0,
                   128'h0000_0000_0000_0000_4080_0000_3f80_0000,
                   128'h0000_0000_0000_0000_4040_0000_4000_0000,
                   128'd0, 32'd0,
                   128'h0000_0000_0000_0000_40e0_0000_4040_0000,
                   32'd0, "NEON FADD.2S lat", lat);
    if (lat != 21) $fatal(1, "NEON FADD.2S latency table mismatch: got %0d expect 21", lat);
    $display("measured NEON FADD.2S lat=%0d", lat);
    issue_neon_lat(NEON_FP_OP_FADD, 1'b0, 1'b0, 1'b1, 3'd0,
                   128'h4120_0000_4100_0000_40c0_0000_4080_0000,
                   128'h3f80_0000_4000_0000_4040_0000_4080_0000,
                   128'd0, 32'd0,
                   128'h4130_0000_4120_0000_4110_0000_4100_0000,
                   32'd0, "NEON FADD.4S lat", lat);
    if (lat != 41) $fatal(1, "NEON FADD.4S latency table mismatch: got %0d expect 41", lat);
    $display("measured NEON FADD.4S lat=%0d", lat);

    // R18 also covers the conversion pre-round payloads. FCVT remains
    // single-lane even when its source format is H; NEON SCVTF advances each
    // S slot through the same registered p1/p2 boundary.
    issue_scalar_lat(FP_OP_FCVT, 1'b0, 1'b1,
                     64'h0000_0000_3f80_0000, 64'd0, 64'd0,
                     32'd0, 1'b1, 1'b0, 5'd27, 5'd0,
                     64'h3ff0_0000_0000_0000, 64'd0, 32'd0, 4'd0,
                     "FCVT.S.D lat", lat);
    $display("measured FCVT.S.D lat=%0d", lat);
    if (lat != 8) $fatal(1, "FCVT.S.D latency table mismatch: got %0d expect 8", lat);
    issue_neon_lat(NEON_FP_OP_SCVTF, 1'b0, 1'b0, 1'b0, 3'd0,
                   128'hffff_fffe_0000_0001,
                   128'd0, 128'd0, 32'd0,
                   128'h0000_0000_0000_0000_c000_0000_3f80_0000,
                   32'd0, "NEON SCVTF.2S lat", lat);
    $display("measured NEON SCVTF.2S lat=%0d", lat);
    if (lat != 17) $fatal(1, "NEON SCVTF.2S latency table mismatch: got %0d expect 17", lat);

    // FP-P3T round2: remaining non-iterative ops now use unpack+finish stages.
    issue_scalar_lat(FP_OP_CMP, 1'b0, 1'b0, 64'hbf80_0000, 64'h3f80_0000, 64'd0,
                     32'd0, 1'b0, 1'b0, 5'd0, 5'd0,
                     64'd0, 64'd0, 32'd0, 4'b1000, "FCMP.S lat", lat);
    $display("measured FCMP.S lat=%0d", lat);
    if (lat != 4) $fatal(1, "FCMP.S latency table mismatch: got %0d expect 4", lat);
    issue_scalar_lat(FP_OP_FMIN, 1'b0, 1'b0, 64'h4000_0000, 64'h4040_0000, 64'd0,
                     32'd0, 1'b1, 1'b0, 5'd20, 5'd0,
                     64'h0000_0000_4000_0000, 64'd0, 32'd0, 4'd0,
                     "FMIN.S lat", lat);
    $display("measured FMIN.S lat=%0d", lat);
    if (lat != 5) $fatal(1, "FMIN.S latency table mismatch: got %0d expect 5", lat);
    issue_scalar_lat(FP_OP_FMAX, 1'b0, 1'b0, 64'h4000_0000, 64'h4040_0000, 64'd0,
                     32'd0, 1'b1, 1'b0, 5'd22, 5'd0,
                     64'h0000_0000_4040_0000, 64'd0, 32'd0, 4'd0,
                     "FMAX.S lat", lat);
    $display("measured FMAX.S lat=%0d", lat);
    if (lat != 5) $fatal(1, "FMAX.S latency table mismatch: got %0d expect 5", lat);
    issue_scalar_lat(FP_OP_FCVTZS, 1'b0, 1'b0, 64'h4000_0000, 64'd0, 64'd0,
                     32'd0, 1'b0, 1'b1, 5'd0, 5'd21,
                     64'd0, 64'h0000_0000_0000_0002, 32'd0, 4'd0,
                     "FCVTZS.S lat", lat);
    $display("measured FCVTZS.S lat=%0d", lat);
    if (lat != 5) $fatal(1, "FCVTZS.S latency table mismatch: got %0d expect 5", lat);
    issue_neon_lat(NEON_FP_OP_FRINT, 1'b0, 1'b0, 1'b0, 3'd3,
                   128'h0000_0000_0000_0000_4020_0000_3fc0_0000,
                   128'd0, 128'd0, 32'd0,
                   128'h0000_0000_0000_0000_4000_0000_3f80_0000,
                   32'd0, "NEON FRINTZ.2S lat", lat);
    $display("measured NEON FRINTZ.2S lat=%0d", lat);
    if (lat != 9) $fatal(1, "NEON FRINTZ.2S latency table mismatch: got %0d expect 9", lat);

    issue_scalar_lat(FP_OP_DIV, 1'b0, 1'b0, 64'h3f80_0000, 64'd0, 64'd0,
                     32'd0, 1'b1, 1'b0, 5'd16, 5'd0,
                     64'h0000_0000_7f80_0000, 64'd0, 32'h0000_0002, 4'd0,
                     "FDIV.S iter 1/0", lat);
    issue_scalar_lat(FP_OP_DIV, 1'b0, 1'b0, 64'd0, 64'd0, 64'd0,
                     32'd0, 1'b1, 1'b0, 5'd17, 5'd0,
                     64'h0000_0000_7fc0_0000, 64'd0, 32'h0000_0001, 4'd0,
                     "FDIV.S iter 0/0", lat);
    issue_scalar_lat(FP_OP_SQRT, 1'b0, 1'b0, 64'hbf80_0000, 64'd0, 64'd0,
                     32'd0, 1'b1, 1'b0, 5'd18, 5'd0,
                     64'h0000_0000_7fc0_0000, 64'd0, 32'h0000_0001, 4'd0,
                     "FSQRT.S iter -1", lat);

    // Kill while the iterative square-root engine is mid-flight.
    begin
      req_valid = 1'b1;
      req = '0;
      req.valid = 1'b1;
      req.kind = FP_EXEC_KIND_SCALAR;
      req.scalar_op = FP_OP_SQRT;
      req.operand_a = {64'd0, 64'h4080_0000};
      req.v_we = 1'b1;
      req.v_rd = 5'd11;
      req.fpsr_we = 1'b1;
      while (!req_ready) @(posedge clk);
      @(posedge clk);
      @(negedge clk);
      req_valid = 1'b0;
      repeat (8) @(posedge clk);
      @(negedge clk);
      if (!busy) $fatal(1, "expected busy during FSQRT before kill");
      kill = 1'b1;
      @(posedge clk);
      @(negedge clk);
      kill = 1'b0;
      if (rsp_valid) $fatal(1, "kill during FSQRT left ghost response");
      while (!req_ready) @(posedge clk);
      issue_scalar(FP_OP_ADD, 1'b0, 64'h3f80_0000, 64'h4000_0000, 64'd0,
                   32'd0, 1'b1, 1'b0, 5'd12, 5'd0,
                   64'h0000_0000_4040_0000, 64'd0, 32'd0, 4'd0,
                   "FADD after FSQRT kill");
    end

    // Reset while the iterative FDIV engine is mid-flight.
    begin
      req_valid = 1'b1;
      req = '0;
      req.valid = 1'b1;
      req.kind = FP_EXEC_KIND_SCALAR;
      req.scalar_op = FP_OP_DIV;
      req.operand_a = {64'd0, 64'h4000_0000};
      req.operand_b = {64'd0, 64'h3f80_0000};
      req.v_we = 1'b1;
      req.v_rd = 5'd13;
      req.fpsr_we = 1'b1;
      while (!req_ready) @(posedge clk);
      @(posedge clk);
      @(negedge clk);
      req_valid = 1'b0;
      repeat (8) @(posedge clk);
      @(negedge clk);
      if (!busy) $fatal(1, "expected busy during FDIV before reset");
      rst_n = 1'b0;
      #5;
      rst_n = 1'b1;
      @(negedge clk);
      if (rsp_valid || busy) $fatal(1, "reset during FDIV left transaction");
      while (!req_ready) @(posedge clk);
      issue_scalar(FP_OP_ADD, 1'b0, 64'h3f80_0000, 64'h4000_0000, 64'd0,
                   32'd0, 1'b1, 1'b0, 5'd14, 5'd0,
                   64'h0000_0000_4040_0000, 64'd0, 32'd0, 4'd0,
                   "FADD after FDIV reset");
    end

    // Kill in state DONE: no ghost response after kill.
    begin
      req_valid = 1'b1;
      req = '0;
      req.valid = 1'b1;
      req.kind = FP_EXEC_KIND_SCALAR;
      req.scalar_op = FP_OP_ADD;
      req.operand_a = {64'd0, 64'h3f80_0000};
      req.operand_b = {64'd0, 64'h4000_0000};
      req.v_we = 1'b1;
      req.v_rd = 5'd5;
      req.fpsr_we = 1'b0;
      while (!req_ready) @(posedge clk);
      @(posedge clk);
      @(negedge clk);
      req_valid = 1'b0;
      wait_rsp();
      kill = 1'b1;
      @(posedge clk);
      @(negedge clk);
      kill = 1'b0;
      if (rsp_valid) $fatal(1, "kill left ghost response");
      if (rsp !== '0) $fatal(1, "kill did not clear response payload");
      $display("PASS kill clears transaction");
    end

    // Reset while idle.
    rst_n = 1'b0;
    #5 rst_n = 1'b1;
    if (busy || rsp_valid || (rsp !== '0)) $fatal(1, "reset left transaction/payload");
    $display("PASS reset clears transaction");

    $display("PASS: FP exec transaction wrapper directed vectors");
    $finish;
  end
endmodule
