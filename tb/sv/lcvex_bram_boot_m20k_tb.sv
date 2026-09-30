// Directed timing regression for the synthesis-only M20K boot-RAM wrapper.
// The altera_syncram stub updates q only after the active clock edge, matching
// the timing property that the behavioral byte-array model cannot exercise.

`timescale 1ns/1ps

/* verilator lint_off PROCASSINIT */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off WIDTHEXPAND */

module lcvex_bram_boot_m20k_tb;

  import lcvex_pkg::*;

  localparam int DEPTH_BYTES = 64;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic        rst_n;
  logic        req_valid;
  mem_req_t    req;
  logic        req_accept;
  logic        rsp_valid;
  mem_rsp_t    rsp;
  logic        rsp_ready;
  logic        prog_we;
  logic [63:0] prog_addr;
  logic [7:0]  prog_strb;
  logic [63:0] prog_wdata;
  logic [31:0] dbg_addr;
  logic [63:0] dbg_rdata;
  integer errors;

  lcvex_bram_boot #(
      .DEPTH_BYTES(DEPTH_BYTES),
      .SRAM_BASE(64'h0),
      .BOOT_MIF_FILE("stub-pattern.mif")
  ) dut (
      .clk(clk), .rst_n(rst_n),
      .req_valid(req_valid), .req(req),
      .req_accept(req_accept), .rsp_valid(rsp_valid),
      .rsp(rsp), .rsp_ready(rsp_ready),
      .prog_we(prog_we), .prog_addr(prog_addr),
      .prog_strb(prog_strb), .prog_wdata(prog_wdata),
      .dbg_addr(dbg_addr), .dbg_rdata(dbg_rdata)
  );

  function automatic logic [63:0] stub_word(input logic [31:0] index);
    return 64'h8877_6655_4433_2211 ^ {32'd0, index};
  endfunction

  task automatic check(input logic condition, input string message);
    if (!condition) begin
      $display("FAIL: %s", message);
      errors = errors + 1;
    end
  endtask

  task automatic check_data(
      input logic [63:0] actual,
      input logic [63:0] expected,
      input string message
  );
    if (actual != expected) begin
      $display("FAIL: %s actual=%016h expected=%016h",
               message, actual, expected);
      errors = errors + 1;
    end
  endtask

  task automatic do_read(
      input logic [63:0] address,
      input logic [7:0] strobe,
      input logic [63:0] expected,
      input string message
  );
    begin
      @(negedge clk);
      req_valid = 1'b1;
      req = '{addr: address, we: 1'b0, strb: strobe, wdata: '0,
              maint: MAINT_NONE, bypass: 1'b0};
      rsp_ready = 1'b1;
      #1;
      check(req_accept, {message, " request accepted"});
      @(posedge clk);
      @(negedge clk);
      check(rsp_valid, {message, " response valid"});
      check(!rsp.fault, {message, " no fault"});
      check_data(rsp.rdata, expected,
                 {message, " data matches synchronous q"});
      req_valid = 1'b0;
      @(posedge clk);
    end
  endtask

  task automatic do_write_byte(
      input logic [63:0] address,
      input logic [7:0] value,
      input string message
  );
    begin
      @(negedge clk);
      req_valid = 1'b1;
      req = '{addr: address, we: 1'b1, strb: 8'h01,
              wdata: {56'd0, value}, maint: MAINT_NONE, bypass: 1'b0};
      rsp_ready = 1'b1;
      #1;
      check(req_accept, {message, " request accepted"});
      @(posedge clk);
      @(negedge clk);
      check(rsp_valid, {message, " response valid"});
      check(!rsp.fault, {message, " no fault"});
      req_valid = 1'b0;
      @(posedge clk);
    end
  endtask

  task automatic do_fault_read(
      input logic [63:0] address,
      input logic [7:0] strobe,
      input string message
  );
    begin
      @(negedge clk);
      req_valid = 1'b1;
      req = '{addr: address, we: 1'b0, strb: strobe, wdata: '0,
              maint: MAINT_NONE, bypass: 1'b0};
      rsp_ready = 1'b1;
      #1;
      check(req_accept, {message, " request accepted"});
      @(posedge clk);
      @(negedge clk);
      check(rsp_valid, {message, " response valid"});
      check(rsp.fault, {message, " fault asserted"});
      req_valid = 1'b0;
      @(posedge clk);
    end
  endtask

  initial begin
    logic [63:0] expected;

    errors = 0;
    rst_n = 1'b0;
    req_valid = 1'b0;
    req = '0;
    // Park the live address away from reset PC while reset is asserted.  A
    // correct request interface cannot rely on the RAM having accidentally
    // prefetched address zero before the first accepted request.
    req.addr = 64'h38;
    rsp_ready = 1'b0;
    prog_we = 1'b0;
    prog_addr = '0;
    prog_strb = '0;
    prog_wdata = '0;
    dbg_addr = '0;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // This is the board-critical check.  The old wrapper captures q_a in the
    // same edge that the RAM accepts address zero and therefore returns the
    // reset-time parked word rather than the accepted PC=0 word.
    do_read(64'h00, 8'hff, stub_word(0), "first PC=0-equivalent read");
    do_read(64'h08, 8'hff, stub_word(1), "next aligned word read");
    do_read(64'h12, 8'h01, stub_word(2) >> 16,
            "within-word offset read");

    // Hold a read response while changing the live request input.  q_a must
    // remain associated with the accepted address until rsp_ready retires it.
    @(negedge clk);
    req_valid = 1'b1;
    req = '{addr: 64'h10, we: 1'b0, strb: 8'hff, wdata: '0,
            maint: MAINT_NONE, bypass: 1'b0};
    rsp_ready = 1'b0;
    #1;
    check(req_accept, "backpressured read accepted");
    @(posedge clk);
    @(negedge clk);
    req_valid = 1'b0;
    req.addr = 64'h38;
    check(rsp_valid, "backpressured response valid");
    check_data(rsp.rdata, stub_word(2),
               "backpressured response initial data");
    repeat (3) begin
      @(posedge clk);
      @(negedge clk);
      check(rsp_valid, "backpressured response remains valid");
      check_data(rsp.rdata, stub_word(2),
                 "backpressured response remains stable");
    end
    rsp_ready = 1'b1;
    @(posedge clk);
    @(negedge clk);
    check(!rsp_valid, "backpressured response retires once ready");

    // Byte write rotation remains an accept-edge side effect.
    do_write_byte(64'h1a, 8'haa, "byte write at offset two");
    expected = (stub_word(3) & 64'hffff_ffffff00_ffff) |
               64'h0000_0000_00aa_0000;
    do_read(64'h18, 8'hff, expected, "byte write readback");

    // Port B has the same synchronous q timing and must use the offset that
    // was sampled with the address, not the following cycle's live offset.
    @(negedge clk);
    dbg_addr = 32'h20;
    @(posedge clk);
    @(negedge clk);
    check_data(dbg_rdata, stub_word(4), "first debug word aligned");
    dbg_addr = 32'h2b;
    @(posedge clk);
    @(negedge clk);
    check_data(dbg_rdata, stub_word(5) >> 24,
               "debug word and byte offset aligned");

    do_fault_read(64'h07, 8'h03, "cross-word read");
    do_fault_read(64'h40, 8'h01, "out-of-range read");

    if (errors == 0) begin
      $display("BRAM_M20K_TIMING_TB PASS");
    end else begin
      $display("BRAM_M20K_TIMING_TB FAIL errors=%0d", errors);
      $fatal(1, "M20K timing regression failed");
    end
    $finish;
  end

endmodule
