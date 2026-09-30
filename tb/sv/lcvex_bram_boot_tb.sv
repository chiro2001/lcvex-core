// lcvex_bram_boot_tb.sv
// Directed BRAM boot wrapper testbench.
//
// This TB drives the main lcvex_bram_boot wrapper (which selects the
// behavioral fallback outside SYNTHESIS) and checks:
//   1. prog_we byte loading through the program port;
//   2. read/write the same address;
//   3. partial byte-enable writes preserve untouched bytes;
//   4. within-word unaligned read/write and debug read-port behavior;
//   5. fault on out-of-range address is still reported.
//
// The full SoC boot smoke (JTAG-UART marker + DDR jump) is covered separately
// by fpga/catapult_a10/tools/run_soc_smoke.sh.

`timescale 1ns/1ps

/* verilator lint_off PROCASSINIT */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off WIDTHEXPAND */

module lcvex_bram_boot_tb;

  import lcvex_pkg::*;

  localparam int DEPTH_BYTES = 256;
  localparam int AW = $clog2(DEPTH_BYTES);

  logic clk = 0;
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
      .BOOT_HEX_FILE("")
  ) dut (
      .clk(clk), .rst_n(rst_n),
      .req_valid(req_valid), .req(req),
      .req_accept(req_accept), .rsp_valid(rsp_valid),
      .rsp(rsp), .rsp_ready(rsp_ready),
      .prog_we(prog_we), .prog_addr(prog_addr),
      .prog_strb(prog_strb), .prog_wdata(prog_wdata),
      .dbg_addr(dbg_addr), .dbg_rdata(dbg_rdata)
  );

  task automatic do_prog_write(
      input logic [63:0] addr,
      input logic [7:0]  strb,
      input logic [63:0] wdata
  );
    begin
      @(negedge clk);
      prog_we    = 1'b1;
      prog_addr  = addr;
      prog_strb  = strb;
      prog_wdata = wdata;
      @(posedge clk);
      @(negedge clk);
      prog_we = 1'b0;
    end
  endtask

  task automatic do_req(
      input mem_req_t m,
      output mem_rsp_t resp,
      output logic ok
  );
    begin
      ok = 1'b1;
      @(negedge clk);
      req_valid = 1'b1;
      req       = m;
      rsp_ready = 1'b1;
      #1;
      if (!req_accept) begin
        $display("FAIL: request not accepted addr=%h we=%b strb=%h",
                 m.addr, m.we, m.strb);
        ok = 1'b0;
      end
      @(posedge clk);          // request accepted; response pending
      @(negedge clk);          // sample response
      if (!rsp_valid) begin
        $display("FAIL: no response addr=%h we=%b", m.addr, m.we);
        ok = 1'b0;
      end
      resp = rsp;
      req_valid = 1'b0;
      @(posedge clk);          // rsp_ready remains 1, response is retired
      // rsp_ready deliberately stays 1 so the DUT sees it at this edge.
    end
  endtask

  task automatic check(
      input logic cond,
      input string msg
  );
    begin
      if (!cond) begin
        $display("FAIL: %s", msg);
        errors = errors + 1;
      end
    end
  endtask

  task automatic run_tests;
    mem_req_t m;
    mem_rsp_t resp;
    logic ok;
    begin
      // Reset and load a few bytes via prog_we.
      rst_n = 1'b0;
      req_valid = 1'b0;
      req = '0;
      rsp_ready = 1'b0;
      prog_we = 1'b0;
      prog_addr = '0;
      prog_strb = 8'h00;
      prog_wdata = '0;
      dbg_addr = 32'd0;
      repeat (4) @(posedge clk);

      // prog_we: byte 0x10 = 0xAB, byte 0x11 = 0xCD.
      do_prog_write(64'h10, 8'h01, 64'h00000000000000AB);
      do_prog_write(64'h11, 8'h01, 64'h00000000000000CD);

      // debug read after program write (registered one cycle later).
      @(negedge clk);
      dbg_addr = 32'h10;
      @(posedge clk);
      @(negedge clk);
      check(dbg_rdata[7:0] == 8'hAB, "debug read byte0 after prog");
      check(dbg_rdata[15:8] == 8'hCD, "debug read byte1 after prog");

      rst_n = 1'b1;
      @(posedge clk);

      // Read the two programmed bytes at byte address 0x10.
      m = '{addr: 64'h10, we: 1'b0, strb: 8'h03, wdata: '0,
           maint: MAINT_NONE, bypass: 1'b0};
      do_req(m, resp, ok);
      check(ok, "read addr 0x10 response accepted");
      check(resp.rdata[7:0] == 8'hAB, "read 0x10 byte0");
      check(resp.rdata[15:8] == 8'hCD, "read 0x10 byte1");
      check(resp.fault == 1'b0, "read 0x10 no fault");

      // Read/write same address: full 64-bit write then read back.
      m = '{addr: 64'h20, we: 1'b1, strb: 8'hFF, wdata: 64'h1122334455667788,
           maint: MAINT_NONE, bypass: 1'b0};
      do_req(m, resp, ok);
      check(ok, "write 0x20 accepted");
      check(resp.fault == 1'b0, "write 0x20 no fault");

      m = '{addr: 64'h20, we: 1'b0, strb: 8'hFF, wdata: '0,
           maint: MAINT_NONE, bypass: 1'b0};
      do_req(m, resp, ok);
      check(ok, "read 0x20 accepted");
      check(resp.rdata == 64'h1122334455667788, "readback 0x20 full word");
      check(resp.fault == 1'b0, "read 0x20 no fault");

      // Partial write: only bytes 1 and 6 of the word at 0x28.
      m = '{addr: 64'h28, we: 1'b1, strb: 8'h42,
           wdata: 64'h00EE00000000DD00, maint: MAINT_NONE, bypass: 1'b0};
      // strb[1] -> byte 1 = 0xDD, strb[6] -> byte 6 = 0xEE.
      do_req(m, resp, ok);
      check(ok, "partial write 0x28 accepted");
      check(resp.fault == 1'b0, "partial write 0x28 no fault");

      m = '{addr: 64'h28, we: 1'b0, strb: 8'hFF, wdata: '0,
           maint: MAINT_NONE, bypass: 1'b0};
      do_req(m, resp, ok);
      check(ok, "read 0x28 accepted");
      check(resp.rdata[7:0] == 8'h00, "partial write keeps byte0");
      check(resp.rdata[15:8] == 8'hDD, "partial write byte1");
      check(resp.rdata[55:48] == 8'hEE, "partial write byte6");
      check(resp.rdata[63:0] == 64'h00EE00000000DD00,
            "partial write full word mask");

      // Within-word unaligned write/read through the request path.
      // Address 0x41 maps to word 8 (0x40), byte lane 1.
      m = '{addr: 64'h41, we: 1'b1, strb: 8'h01, wdata: 64'h000000000000CC,
           maint: MAINT_NONE, bypass: 1'b0};
      do_req(m, resp, ok);
      check(ok, "unaligned write 0x41 accepted");
      check(resp.fault == 1'b0, "unaligned write 0x41 no fault");

      m = '{addr: 64'h41, we: 1'b0, strb: 8'h01, wdata: '0,
           maint: MAINT_NONE, bypass: 1'b0};
      do_req(m, resp, ok);
      check(ok, "unaligned read 0x41 accepted");
      check(resp.rdata[7:0] == 8'hCC, "unaligned read 0x41 byte0");
      check(resp.rdata[63:8] == 56'd0, "unaligned read 0x41 upper bytes zero");

      // Debug read at same unaligned address.
      @(negedge clk);
      dbg_addr = 32'h41;
      @(posedge clk);
      @(negedge clk);
      check(dbg_rdata[7:0] == 8'hCC, "debug read 0x41 byte0");

      // Out-of-range request still returns fault.
      m = '{addr: 64'h1000, we: 1'b0, strb: 8'h01, wdata: '0,
           maint: MAINT_NONE, bypass: 1'b0};
      do_req(m, resp, ok);
      check(ok, "out-of-range read accepted");
      check(resp.fault == 1'b1, "out-of-range read fault");

      // End of test.
      @(negedge clk);
      if (errors == 0) $display("BRAM_BOOT_TB PASS");
      else $display("BRAM_BOOT_TB FAIL errors=%0d", errors);
    end
  endtask

  initial begin
    errors = 0;
    run_tests();
    $finish;
  end

endmodule
