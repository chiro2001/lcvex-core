// lcvex_muldiv_req_tb.sv
// T-20260905-004：乘除请求捕获/launch 边界定向测试。
// 默认作为 Cocotb wrapper 使用；SV 入口通过 -GRUN_SV_SELFTEST=1
// 启用同一组 raw-bit 检查，避免两套测试漂移。

`timescale 1ns/1ps

module lcvex_muldiv_req_tb #(
    parameter bit RUN_SV_SELFTEST = 1'b0
);
  logic        clk;
  logic        rst_n = 1'b0;
  logic        start = 1'b0;
  logic        kill  = 1'b0;
  logic [3:0]  op     = 4'd0;
  logic        is_32  = 1'b0;
  logic [63:0] a      = 64'd0;
  logic [63:0] b      = 64'd0;
  logic [63:0] acc    = 64'd0;
  logic        busy;
  logic        done;
  logic [63:0] result;

  initial clk = 1'b0;
  always #5 clk = ~clk;

  lcvex_muldiv u_muldiv (
      .clk    (clk),
      .rst_n  (rst_n),
      .start  (start),
      .kill   (kill),
      .op     (op),
      .is_32  (is_32),
      .a      (a),
      .b      (b),
      .acc    (acc),
      .busy   (busy),
      .done   (done),
      .result (result)
  );

  task automatic reset_dut;
    begin
      rst_n = 1'b0;
      start = 1'b0;
      kill  = 1'b0;
      repeat (2) @(posedge clk);
      #1;
      if (busy || done || result !== 64'd0)
        $fatal(1, "reset left muldiv state active");
      rst_n = 1'b1;
      @(posedge clk);
      #1;
    end
  endtask

  task automatic check_case(
      input logic [3:0]  t_op,
      input logic        t_is_32,
      input logic [63:0] t_a,
      input logic [63:0] t_b,
      input logic [63:0] t_acc,
      input logic [63:0] t_expect,
      input string       t_name);
    bit seen;
    begin
      @(negedge clk);
      op    = t_op;
      is_32 = t_is_32;
      a     = t_a;
      b     = t_b;
      acc   = t_acc;
      kill  = 1'b0;
      start = 1'b1;
      @(posedge clk);
      #1;
      if (!busy)
        $fatal(1, "FAIL %s: request capture did not assert busy", t_name);

      // Capture 后立即扰动 live 输入；active/result 不能受其影响。
      @(negedge clk);
      start = 1'b0;
      op    = 4'hf;
      is_32 = ~t_is_32;
      a     = 64'hdead_beef_dead_beef;
      b     = 64'h0123_4567_89ab_cdef;
      acc   = 64'hffff_ffff_ffff_ffff;

      seen = 1'b0;
      for (int i = 0; i < 140; i++) begin
        @(posedge clk);
        #1;
        if (done) begin
          seen = 1'b1;
          if (result !== t_expect)
            $fatal(1, "FAIL %s: got %016h expect %016h", t_name,
                   result, t_expect);
          break;
        end
      end
      if (!seen)
        $fatal(1, "FAIL %s: timeout waiting for done", t_name);
      @(posedge clk);
      #1;
      if (busy || done || result !== 64'd0)
        $fatal(1, "FAIL %s: done/result was not a one-cycle outcome", t_name);
    end
  endtask

  task automatic check_kill(input bit kill_active, input string t_name);
    begin
      @(negedge clk);
      op    = 4'd0;
      is_32 = 1'b0;
      a     = 64'h1234_5678_9abc_def0;
      b     = 64'h0000_0000_0000_0003;
      acc   = 64'd0;
      kill  = 1'b0;
      start = 1'b1;
      @(posedge clk);
      #1;
      start = 1'b0;
      if (!busy)
        $fatal(1, "FAIL %s: pending request not busy", t_name);
      if (kill_active) begin
        @(posedge clk);
        #1;
        if (!busy)
          $fatal(1, "FAIL %s: active request not busy", t_name);
      end
      @(negedge clk);
      kill = 1'b1;
      @(posedge clk);
      #1;
      kill = 1'b0;
      if (busy || done || result !== 64'd0)
        $fatal(1, "FAIL %s: kill left an outcome", t_name);
      @(posedge clk);
      #1;
      if (busy || done || result !== 64'd0)
        $fatal(1, "FAIL %s: killed request resurrected", t_name);
    end
  endtask

  generate
    if (RUN_SV_SELFTEST) begin : g_sv_selftest
      initial begin
        reset_dut();
        // MUL/MADD 族：X、W、高半及有/无符号 32x32 语义。
        check_case(4'd0, 1'b0, 64'h0000_0000_0000_1234,
                   64'h0000_0000_0000_0056, 64'd0,
                   64'h0000_0000_0006_1d78, "MUL X");
        check_case(4'd0, 1'b1, 64'hffff_ffff_1234_5678,
                   64'h0000_0000_0000_0005, 64'd0,
                   64'h0000_0000_5b05_b058, "MUL W");
        check_case(4'd3, 1'b0, 64'd3, 64'd4, 64'd7, 64'd19, "MADD X");
        check_case(4'd4, 1'b0, 64'd3, 64'd4, 64'd7,
                   64'hffff_ffff_ffff_fffb, "MSUB X");
        check_case(4'd5, 1'b0, 64'h0000_0000_ffff_fffe,
                   64'd3, 64'd5, 64'hffff_ffff_ffff_ffff, "SMADDL");
        check_case(4'd6, 1'b0, 64'h0000_0000_ffff_fffe,
                   64'd3, 64'd5, 64'd11, "SMSUBL");
        check_case(4'd7, 1'b0, 64'h0000_0000_ffff_ffff,
                   64'd2, 64'd1, 64'h0000_0001_ffff_ffff, "UMADDL");
        check_case(4'd8, 1'b0, 64'h0000_0000_ffff_ffff,
                   64'd2, 64'd1, 64'hffff_fffe_0000_0003, "UMSUBL");
        check_case(4'd9, 1'b0, 64'hffff_ffff_ffff_ffff,
                   64'd2, 64'd0, 64'd1, "UMULH X");
        check_case(4'd10, 1'b0, 64'hffff_ffff_ffff_ffff,
                   64'd2, 64'd0, 64'hffff_ffff_ffff_ffff, "SMULH X");

        // UDIV/SDIV：X/W 及除零；W 结果必须零扩展到 64 位。
        check_case(4'd1, 1'b0, 64'd256, 64'd3, 64'd0, 64'h55, "UDIV X");
        check_case(4'd1, 1'b1, 64'hffff_ffff_0000_0100,
                   64'd3, 64'd0, 64'h0000_0000_0000_0055, "UDIV W");
        check_case(4'd2, 1'b0, 64'hffff_ffff_ffff_ff9c,
                   64'd3, 64'd0, 64'hffff_ffff_ffff_ffdf, "SDIV X");
        check_case(4'd2, 1'b1, 64'hffff_ffff_ffff_ff9c,
                   64'd3, 64'd0, 64'h0000_0000_ffff_ffdf, "SDIV W");
        check_case(4'd1, 1'b0, 64'h1234, 64'd0, 64'd0, 64'd0, "UDIV X div0");
        check_case(4'd2, 1'b0, 64'hffff_ffff_ffff_ff9c,
                   64'd0, 64'd0, 64'd0, "SDIV X div0");
        check_case(4'd1, 1'b1, 64'hffff_ffff_0000_0100,
                   64'd0, 64'd0, 64'd0, "UDIV W div0");
        check_case(4'd2, 1'b1, 64'hffff_ffff_ffff_ff9c,
                   64'd0, 64'd0, 64'd0, "SDIV W div0");

        check_kill(1'b0, "pending kill");
        check_kill(1'b1, "active kill");
        $display("PASS: T-20260905-004 muldiv request capture/launch");
        $finish;
      end
    end
  endgenerate
endmodule
