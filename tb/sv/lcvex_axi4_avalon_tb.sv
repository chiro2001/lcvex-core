// lcvex_axi4_avalon_tb.sv
//
// 独立 B2 SV 闭环：AXI driver -> adapter -> 双时钟 Avalon BFM。Cocotb
// 使用同一个 endpoint wrapper，因此两套验证观察相同的 EMIF payload。

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off WIDTHEXPAND */

module lcvex_axi4_avalon_endpoint #(
    parameter int unsigned BFM_SEED = 32'hb2_054,
    parameter int unsigned AVALON_TIMEOUT_CYCLES = 32
) (
    input logic cpu_clk,
    input logic emif_clk,
    input logic cpu_rst_n,
    input logic emif_rst_n,
    input logic cal_success,
    input logic cal_fail,
    input logic cfg_random_wait,
    input logic cfg_force_wait,
    input logic [3:0] cfg_read_delay,
    input logic cfg_drop_readdatavalid,
    input logic cfg_preserve_read_pending,

    input logic awvalid,
    output logic awready,
    input logic [3:0] awid,
    input logic [63:0] awaddr,
    input logic [7:0] awlen,
    input logic [2:0] awsize,
    input logic [1:0] awburst,
    input logic awlock,
    input logic [3:0] awcache,
    input logic [2:0] awprot,
    input logic [3:0] awqos,
    input logic wvalid,
    output logic wready,
    input logic [127:0] wdata,
    input logic [15:0] wstrb,
    input logic wlast,
    output logic bvalid,
    input logic bready,
    output logic [3:0] bid,
    output logic [1:0] bresp,
    input logic arvalid,
    output logic arready,
    input logic [3:0] arid,
    input logic [63:0] araddr,
    input logic [7:0] arlen,
    input logic [2:0] arsize,
    input logic [1:0] arburst,
    input logic arlock,
    input logic [3:0] arcache,
    input logic [2:0] arprot,
    input logic [3:0] arqos,
    output logic rvalid,
    input logic rready,
    output logic [3:0] rid,
    output logic [127:0] rdata,
    output logic [1:0] rresp,
    output logic rlast,

    output logic avalon_read,
    output logic avalon_write,
    output logic [24:0] avalon_address,
    output logic [511:0] avalon_writedata,
    output logic [6:0] avalon_burstcount,
    output logic [63:0] avalon_byteenable,
    output logic avalon_waitrequest_n,
    output logic [511:0] avalon_readdata,
    output logic avalon_readdatavalid,
    output logic [31:0] write_accept_count,
    output logic [31:0] read_accept_count,
    output logic [31:0] duplicate_response_count,
    output logic avalon_timeout_abort
);

  logic bfm_rst_n;
  assign bfm_rst_n = cpu_rst_n & emif_rst_n;

  lcvex_axi4_avalon_adapter #(
      .AVALON_TIMEOUT_CYCLES(AVALON_TIMEOUT_CYCLES)
  ) adapter (
      .cpu_clk, .emif_clk, .cpu_rst_n, .emif_rst_n, .cal_success, .cal_fail,
      .awvalid, .awready, .awid, .awaddr, .awlen, .awsize, .awburst,
      .awlock, .awcache, .awprot, .awqos,
      .wvalid, .wready, .wdata, .wstrb, .wlast,
      .bvalid, .bready, .bid, .bresp,
      .arvalid, .arready, .arid, .araddr, .arlen, .arsize, .arburst,
      .arlock, .arcache, .arprot, .arqos,
      .rvalid, .rready, .rid, .rdata, .rresp, .rlast,
      .avalon_read, .avalon_write, .avalon_address, .avalon_writedata,
      .avalon_burstcount, .avalon_byteenable, .avalon_waitrequest_n,
      .avalon_readdata, .avalon_readdatavalid, .avalon_timeout_abort
  );

  lcvex_avalon_emif_bfm #(.SEED(BFM_SEED)) bfm (
      .clk(emif_clk), .rst_n(bfm_rst_n), .cfg_random_wait,
      .cfg_force_wait, .cfg_read_delay, .cfg_drop_readdatavalid,
      .cfg_preserve_read_pending,
      .av_read(avalon_read), .av_write(avalon_write),
      .av_address(avalon_address), .av_writedata(avalon_writedata),
      .av_burstcount(avalon_burstcount), .av_byteenable(avalon_byteenable),
      .av_waitrequest_n(avalon_waitrequest_n),
      .av_readdata(avalon_readdata),
      .av_readdatavalid(avalon_readdatavalid),
      .write_accept_count, .read_accept_count, .duplicate_response_count
  );

  lcvex_axi4_avalon_sva protocol_sva (
      // Keep checker epoch state across an EMIF-only reset so a deliberately
      // preserved backend response is recognized as the old read being
      // drained, rather than flagged as a spurious readdatavalid.
      .clk(emif_clk), .rst_n(cpu_rst_n), .emif_rst_n(emif_rst_n), .cal_fail,
      .avalon_read, .avalon_write, .avalon_address, .avalon_writedata,
      .avalon_burstcount, .avalon_byteenable,
      .waitrequest_n(avalon_waitrequest_n),
      .readdatavalid(avalon_readdatavalid),
      .timeout_abort(avalon_timeout_abort)
  );

endmodule


// Cocotb top-level: no initial stimulus, all transaction inputs/outputs are
// visible as ports and can be driven with two independent Clock objects.
module lcvex_axi4_avalon_cocotb_tb #(
    parameter int unsigned BFM_SEED = 32'hb2_054,
    parameter int unsigned AVALON_TIMEOUT_CYCLES = 32
) (
    input logic cpu_clk,
    input logic emif_clk,
    input logic cpu_rst_n,
    input logic emif_rst_n,
    input logic cal_success,
    input logic cal_fail,
    input logic cfg_random_wait,
    input logic cfg_force_wait,
    input logic [3:0] cfg_read_delay,
    input logic cfg_drop_readdatavalid,
    input logic cfg_preserve_read_pending,
    input logic awvalid,
    output logic awready,
    input logic [3:0] awid,
    input logic [63:0] awaddr,
    input logic [7:0] awlen,
    input logic [2:0] awsize,
    input logic [1:0] awburst,
    input logic awlock,
    input logic [3:0] awcache,
    input logic [2:0] awprot,
    input logic [3:0] awqos,
    input logic wvalid,
    output logic wready,
    input logic [127:0] wdata,
    input logic [15:0] wstrb,
    input logic wlast,
    output logic bvalid,
    input logic bready,
    output logic [3:0] bid,
    output logic [1:0] bresp,
    input logic arvalid,
    output logic arready,
    input logic [3:0] arid,
    input logic [63:0] araddr,
    input logic [7:0] arlen,
    input logic [2:0] arsize,
    input logic [1:0] arburst,
    input logic arlock,
    input logic [3:0] arcache,
    input logic [2:0] arprot,
    input logic [3:0] arqos,
    output logic rvalid,
    input logic rready,
    output logic [3:0] rid,
    output logic [127:0] rdata,
    output logic [1:0] rresp,
    output logic rlast,
    output logic avalon_read,
    output logic avalon_write,
    output logic [24:0] avalon_address,
    output logic [511:0] avalon_writedata,
    output logic [6:0] avalon_burstcount,
    output logic [63:0] avalon_byteenable,
    output logic avalon_waitrequest_n,
    output logic [511:0] avalon_readdata,
    output logic avalon_readdatavalid,
    output logic [31:0] write_accept_count,
    output logic [31:0] read_accept_count,
    output logic [31:0] duplicate_response_count,
    output logic avalon_timeout_abort
);

  lcvex_axi4_avalon_endpoint #(
      .BFM_SEED(BFM_SEED),
      .AVALON_TIMEOUT_CYCLES(AVALON_TIMEOUT_CYCLES)
  ) endpoint (.*);

endmodule


module lcvex_axi4_avalon_tb #(
    parameter int unsigned AVALON_TIMEOUT_CYCLES = 32
);
  import lcvex_axi4_pkg::*;

  logic cpu_clk, emif_clk;
  logic cpu_rst_n, emif_rst_n;
  logic cal_success, cal_fail;
  logic cfg_random_wait, cfg_force_wait;
  logic cfg_drop_readdatavalid, cfg_preserve_read_pending;
  logic [3:0] cfg_read_delay;
  logic awvalid, awready, wvalid, wready, bvalid, bready;
  logic [3:0] awid, bid;
  logic [63:0] awaddr;
  logic [7:0] awlen;
  logic [2:0] awsize;
  logic [1:0] awburst, bresp;
  logic awlock;
  logic [3:0] awcache, awqos;
  logic [2:0] awprot;
  logic [127:0] wdata;
  logic [15:0] wstrb;
  logic wlast;
  logic arvalid, arready, rvalid, rready;
  logic [3:0] arid, rid;
  logic [63:0] araddr;
  logic [7:0] arlen;
  logic [2:0] arsize;
  logic [1:0] arburst, rresp;
  logic arlock;
  logic [3:0] arcache, arqos;
  logic [2:0] arprot;
  logic [127:0] rdata;
  logic rlast;
  logic avalon_read, avalon_write, avalon_waitrequest_n, avalon_readdatavalid;
  logic [24:0] avalon_address;
  logic [511:0] avalon_writedata, avalon_readdata;
  logic [6:0] avalon_burstcount;
  logic [63:0] avalon_byteenable;
  logic avalon_timeout_abort;
  logic [31:0] write_accept_count, read_accept_count, duplicate_response_count;
  integer errors;

  lcvex_axi4_avalon_endpoint #(
      .AVALON_TIMEOUT_CYCLES(AVALON_TIMEOUT_CYCLES)
  ) endpoint (
      .cpu_clk, .emif_clk, .cpu_rst_n, .emif_rst_n, .cal_success, .cal_fail,
      .cfg_random_wait, .cfg_force_wait, .cfg_read_delay,
      .cfg_drop_readdatavalid, .cfg_preserve_read_pending,
      .awvalid, .awready, .awid, .awaddr, .awlen, .awsize, .awburst,
      .awlock, .awcache, .awprot, .awqos,
      .wvalid, .wready, .wdata, .wstrb, .wlast,
      .bvalid, .bready, .bid, .bresp,
      .arvalid, .arready, .arid, .araddr, .arlen, .arsize, .arburst,
      .arlock, .arcache, .arprot, .arqos,
      .rvalid, .rready, .rid, .rdata, .rresp, .rlast,
      .avalon_read, .avalon_write, .avalon_address, .avalon_writedata,
      .avalon_burstcount, .avalon_byteenable, .avalon_waitrequest_n,
      .avalon_readdata, .avalon_readdatavalid,
      .avalon_timeout_abort,
      .write_accept_count, .read_accept_count, .duplicate_response_count
  );

  always #5 cpu_clk = ~cpu_clk;
  always #3 emif_clk = ~emif_clk;

  task automatic check(input logic condition, input string message);
    if (!condition) begin
      $display("FAIL: %s", message);
      errors++;
    end
  endtask

  task automatic clear_axi;
    begin
      awvalid = 0; awid = 0; awaddr = 0; awlen = 0; awsize = 0;
      awburst = AXI4_BURST_INCR; awlock = 0; awcache = 0; awprot = 0; awqos = 0;
      wvalid = 0; wdata = 0; wstrb = 0; wlast = 0;
      arvalid = 0; arid = 0; araddr = 0; arlen = 0; arsize = 0;
      arburst = AXI4_BURST_INCR; arlock = 0; arcache = 0; arprot = 0; arqos = 0;
    end
  endtask

  task automatic send_aw(
      input logic [63:0] addr, input logic [3:0] id, input logic [7:0] len,
      input logic [2:0] size, input logic [1:0] burst);
    begin
      awaddr = addr; awid = id; awlen = len; awsize = size; awburst = burst;
      awvalid = 1;
      while (!awready) @(posedge cpu_clk);
      @(posedge cpu_clk);
      awvalid = 0;
    end
  endtask

  task automatic send_w(
      input logic [127:0] data, input logic [15:0] strb, input logic last);
    begin
      wdata = data; wstrb = strb; wlast = last; wvalid = 1;
      while (!wready) @(posedge cpu_clk);
      @(posedge cpu_clk);
      wvalid = 0;
    end
  endtask

  // Single-channel helpers for reset-collection tests.  Holding VALID until
  // the following falling edge avoids an active-region race with the DUT
  // always_ff when READY is already high at launch.
  task automatic send_aw_clean(
      input logic [63:0] addr, input logic [3:0] id, input logic [7:0] len,
      input logic [2:0] size, input logic [1:0] burst);
    begin
      @(negedge cpu_clk);
      awaddr = addr; awid = id; awlen = len; awsize = size; awburst = burst;
      awvalid = 1;
      while (!awready) @(posedge cpu_clk);
      @(posedge cpu_clk);
      @(negedge cpu_clk);
      awvalid = 0;
    end
  endtask

  task automatic send_w_clean(
      input logic [127:0] data, input logic [15:0] strb, input logic last);
    begin
      @(negedge cpu_clk);
      wdata = data; wstrb = strb; wlast = last; wvalid = 1;
      while (!wready) @(posedge cpu_clk);
      @(posedge cpu_clk);
      @(negedge cpu_clk);
      wvalid = 0;
    end
  endtask

  task automatic do_write(
      input logic [63:0] addr, input logic [3:0] id, input logic [7:0] len,
      input logic [2:0] size, input logic [1:0] burst,
      input logic [127:0] d0, input logic [127:0] d1,
      input logic [127:0] d2, input logic [127:0] d3,
      input logic [15:0] s0, input logic [15:0] s1,
      input logic [15:0] s2, input logic [15:0] s3,
      output logic [1:0] response);
    begin
      fork
        send_aw(addr, id, len, size, burst);
        begin
          send_w(d0, s0, len == 0);
          if (len >= 1) send_w(d1, s1, len == 1);
          if (len >= 2) send_w(d2, s2, len == 2);
          if (len >= 3) send_w(d3, s3, 1'b1);
        end
      join
      bready = 1;
      while (!bvalid) @(posedge cpu_clk);
      check(bid == id, "BID mismatch");
      check(rlast === 1'b0, "R LAST must not alias B channel");
      response = bresp;
      @(posedge cpu_clk);
    end
  endtask

  task automatic do_read(
      input logic [63:0] addr, input logic [3:0] id, input logic [7:0] len,
      input logic [2:0] size, input logic [1:0] burst,
      output logic [127:0] d0, output logic [127:0] d1,
      output logic [127:0] d2, output logic [127:0] d3,
      output logic [1:0] response);
    int beat;
    begin
      @(negedge cpu_clk);
      araddr = addr; arid = id; arlen = len; arsize = size; arburst = burst;
      arvalid = 1; rready = 1;
      while (!arready) @(posedge cpu_clk);
      @(posedge cpu_clk);
      @(negedge cpu_clk);
      arvalid = 0;
      beat = 0;
      while (1) begin
        while (!rvalid) @(posedge cpu_clk);
        check(rid == id, "RID mismatch");
        check(!rresp[1] || rlast, "error response must terminate read");
        if (beat == 0) d0 = rdata;
        if (beat == 1) d1 = rdata;
        if (beat == 2) d2 = rdata;
        if (beat == 3) d3 = rdata;
        response = rresp;
        if (rlast) begin
          check(beat == (rresp == AXI4_RESP_DECERR ? 0 : len),
                "RLAST beat mismatch");
          @(posedge cpu_clk);
          break;
        end
        beat++;
        @(posedge cpu_clk);
      end
      arvalid = 0;
    end
  endtask

  logic [127:0] d0, d1, d2, d3;
  logic [1:0] response;
  logic [63:0] expected_be;
  initial begin
    errors = 0;
    cpu_clk = 0; emif_clk = 0;
    cpu_rst_n = 0; emif_rst_n = 0;
    cal_success = 0; cal_fail = 0;
    cfg_random_wait = 0; cfg_force_wait = 0; cfg_read_delay = 0;
    cfg_drop_readdatavalid = 0; cfg_preserve_read_pending = 0;
    bready = 0; rready = 0;
    clear_axi();
    repeat (3) @(posedge cpu_clk);
    cpu_rst_n = 1;
    // Release the EMIF reset independently, then keep calibration low for a
    // few cycles to exercise the not-ready backpressure contract.
    emif_rst_n = 1;
    repeat (2) @(posedge emif_clk);
    // Not-ready must backpressure both command channels.
    check(!awready && !arready && !wready, "calibration not-ready must backpressure");
    cal_success = 1;
    repeat (4) @(posedge cpu_clk);
    check(awready && arready, "calibration success must enable AXI");

    cfg_random_wait = 1;
    d0 = 128'h0706_0504_0302_0100_0f0e_0d0c_0b0a_0908;
    d1 = 128'h1716_1514_1312_1110_1f1e_1d1c_1b1a_1918;
    d2 = 128'h2726_2524_2322_2120_2f2e_2d2c_2b2a_2928;
    d3 = 128'h3736_3534_3332_3130_3f3e_3d3c_3b3a_3938;
    do_write(64'h4000_1000, 4'h1, 3, 4, AXI4_BURST_INCR,
             d0, d1, d2, d3, 16'hffff, 16'hffff, 16'hffff, 16'hffff, response);
    check(response == AXI4_RESP_OKAY, "canonical write must be OKAY");
    check(write_accept_count == 1, "one AXI line must make one Avalon write");
    check(avalon_address == 25'h40, "Avalon address must use 64B word units");
    do_read(64'h4000_1000, 4'h1, 3, 4, AXI4_BURST_INCR,
            d0, d1, d2, d3, response);
    check(response == AXI4_RESP_OKAY, "canonical read must be OKAY");
    check(read_accept_count == 1, "one AXI line must make one Avalon read");
    check(d0 == 128'h0706_0504_0302_0100_0f0e_0d0c_0b0a_0908 &&
          d1 == 128'h1716_1514_1312_1110_1f1e_1d1c_1b1a_1918 &&
          d2 == 128'h2726_2524_2322_2120_2f2e_2d2c_2b2a_2928 &&
          d3 == 128'h3736_3534_3332_3130_3f3e_3d3c_3b3a_3938,
          "4-beat line data mismatch");

    // Narrow B1 lane-form WSTRB at address +2; Avalon byteenable must select
    // line bytes 2/3, not 4/5.
    cfg_random_wait = 0;
    do_write(64'h4000_1202, 4'h2, 0, 1, AXI4_BURST_INCR,
             128'h0000_0000_0000_0000_0000_0000_efbe_0000,
             0, 0, 0, 16'h000c, 0, 0, 0, response);
    check(response == AXI4_RESP_OKAY, "narrow write must be OKAY");
    do_read(64'h4000_1200, 4'h2, 0, 4, AXI4_BURST_INCR,
            d0, d1, d2, d3, response);
    check(d0[31:16] == 16'hefbe, "narrow WSTRB lane mapping mismatch");

    // Cross-line and outside-window errors are local and must not increment
    // the Avalon write/read accept counters.
    expected_be = write_accept_count;
    do_write(64'h4000_1030, 4'h3, 1, 4, AXI4_BURST_INCR,
             d0, d1, 0, 0, 16'hffff, 16'hffff, 0, 0, response);
    check(response == AXI4_RESP_DECERR, "cross-line write must be DECERR");
    check(write_accept_count == expected_be, "cross-line write reached Avalon");
    do_read(64'h4800_0000, 4'h3, 0, 4, AXI4_BURST_INCR,
            d0, d1, d2, d3, response);
    check(response == AXI4_RESP_DECERR, "outside-window read must be DECERR");

    // Hold an Avalon write under active-low waitrequest and check payload.
    cfg_force_wait = 1;
    fork
      begin
        do_write(64'h4000_1400, 4'h4, 0, 4, AXI4_BURST_INCR,
                 d0, 0, 0, 0, 16'hffff, 0, 0, 0, response);
      end
      begin
        wait (avalon_write && !avalon_waitrequest_n);
        repeat (3) @(posedge emif_clk);
        check(avalon_write && !avalon_waitrequest_n, "write must be held by waitrequest_n");
        check(avalon_address == 25'h50 && avalon_byteenable == 64'hffff,
              "held Avalon payload changed");
        cfg_force_wait = 0;
      end
    join

    // EMIF-only reset while AXI write collection is incomplete must pause
    // the already accepted channel, not discard or duplicate it. Preserve
    // the BFM counters so the no-side-effect checks span each reset.
    cfg_preserve_read_pending = 1;
    expected_be = write_accept_count;
    @(negedge cpu_clk);
    send_aw_clean(64'h4000_1e00, 4'hb, 0, 4, AXI4_BURST_INCR);
    check(!avalon_write, "AW-first partial write reached Avalon before W");
    emif_rst_n = 0;
    repeat (4) @(posedge cpu_clk);
    repeat (3) begin
      @(posedge emif_clk);
      check(!avalon_write, "AW-first reset emitted Avalon write");
    end
    check(!wready, "AW-first reset must gate WREADY");
    emif_rst_n = 1;
    repeat (4) @(posedge cpu_clk);
    check(wready, "AW-first reset release must restore WREADY");
    @(negedge cpu_clk);
    send_w_clean(128'h1122_3344_5566_7788_99aa_bbcc_ddee_ff00,
           16'hffff, 1'b1);
    bready = 1;
    while (!bvalid) @(posedge cpu_clk);
    check(bid == 4'hb && bresp == AXI4_RESP_OKAY,
          "AW-first resumed write response mismatch");
    @(posedge cpu_clk);
    bready = 0;
    check(write_accept_count == expected_be + 1,
          "AW-first resumed write side effect count mismatch");

    expected_be = write_accept_count;
    @(negedge cpu_clk);
    send_w_clean(128'hffee_ddcc_bbaa_9988_7766_5544_3322_1100,
           16'hffff, 1'b1);
    check(!avalon_write, "W-first partial write reached Avalon before AW");
    emif_rst_n = 0;
    repeat (4) @(posedge cpu_clk);
    repeat (3) begin
      @(posedge emif_clk);
      check(!avalon_write, "W-first reset emitted Avalon write");
    end
    check(!awready, "W-first reset must gate AWREADY");
    emif_rst_n = 1;
    repeat (4) @(posedge cpu_clk);
    check(awready, "W-first reset release must restore AWREADY");
    @(negedge cpu_clk);
    send_aw_clean(64'h4000_2000, 4'hc, 0, 4, AXI4_BURST_INCR);
    bready = 1;
    while (!bvalid) @(posedge cpu_clk);
    check(bid == 4'hc && bresp == AXI4_RESP_OKAY,
          "W-first resumed write response mismatch");
    @(posedge cpu_clk);
    bready = 0;
    check(write_accept_count == expected_be + 1,
          "W-first resumed write side effect count mismatch");
    check(duplicate_response_count == 0,
          "partial reset writes produced duplicate response");
    cfg_preserve_read_pending = 0;

    // Exercise the SVA reset split with an Avalon read command already
    // asserted under waitrequest. EMIF-only reset is allowed to withdraw the
    // stalled command (the hold state is cleared), but the accepted AXI read
    // must still receive one DECERR and the next epoch must re-arm cleanly.
    cfg_preserve_read_pending = 1;
    cfg_force_wait = 1;
    expected_be = read_accept_count;
    araddr = 64'h4000_2100; arid = 4'hd; arlen = 0; arsize = 4;
    arburst = AXI4_BURST_INCR; arvalid = 1; rready = 0;
    while (!arready) @(posedge cpu_clk);
    @(posedge cpu_clk);
    @(negedge cpu_clk);
    arvalid = 0;
    wait (avalon_read && !avalon_waitrequest_n);
    @(negedge emif_clk);
    emif_rst_n = 0;
    repeat (4) @(posedge cpu_clk);
    while (!rvalid) @(posedge cpu_clk);
    check(rid == 4'hd && rresp == AXI4_RESP_DECERR && rlast,
          "stalled-command EMIF reset must return one DECERR R beat");
    repeat (3) @(posedge cpu_clk);
    check(rvalid && rid == 4'hd && rresp == AXI4_RESP_DECERR && rlast,
          "stalled-command DECERR R payload must hold");
    rready = 1;
    @(posedge cpu_clk);
    rready = 0;
    emif_rst_n = 1;
    cfg_force_wait = 0;
    repeat (4) @(posedge cpu_clk);
    cfg_read_delay = 0;
    do_read(64'h4000_2f00, 4'he, 0, 4, AXI4_BURST_INCR,
            d0, d1, d2, d3, response);
    check(response == AXI4_RESP_OKAY && rid == 4'he &&
          d0 == 128'hcb_ca_c9_c8_c7_c6_c5_c4_c3_c2_c1_c0_bf_be_bd_bc,
          "stalled-command reset re-arm must return new data");
    check(read_accept_count == expected_be + 1,
          "stalled-command reset must not count an unaccepted old read");
    check(duplicate_response_count == 0,
          "stalled-command reset must not duplicate response");
    cfg_preserve_read_pending = 0;

    // A permanently stalled Avalon write must not leave the AXI master
    // waiting forever. It has no accepted backend side effect, so the
    // bounded completion is one DECERR and no Avalon write count increment.
    expected_be = write_accept_count;
    cfg_force_wait = 1;
    do_write(64'h4000_1500, 4'h7, 0, 4, AXI4_BURST_INCR,
             d0, 0, 0, 0, 16'hffff, 0, 0, 0, response);
    check(response == AXI4_RESP_DECERR,
          "permanent waitrequest must timeout DECERR");
    check(write_accept_count == expected_be,
          "timed-out write must not reach Avalon");
    cfg_force_wait = 0;

    // An accepted read with no readdatavalid is an error, not success. Once
    // the test backend is allowed to release its pending response, the
    // adapter must drain it and only then re-arm the next epoch.
    expected_be = read_accept_count;
    cfg_drop_readdatavalid = 1;
    cfg_read_delay = 0;
    do_read(64'h4000_1a00, 4'h8, 0, 4, AXI4_BURST_INCR,
            d0, d1, d2, d3, response);
    check(response == AXI4_RESP_DECERR,
          "missing readdatavalid must timeout DECERR");
    check(read_accept_count == expected_be + 1,
          "timed-out read must have exactly one Avalon acceptance");
    repeat (3) @(posedge cpu_clk);
    check(!rvalid, "timed-out read must not duplicate R after handshake");
    cfg_drop_readdatavalid = 0;
    repeat (4) @(posedge emif_clk);
    @(negedge cpu_clk);
    do_read(64'h4000_1c00, 4'h9, 0, 4, AXI4_BURST_INCR,
            d0, d1, d2, d3, response);
    check(response == AXI4_RESP_OKAY,
          "post-drain read must re-arm with OKAY");
    check(rid == 4'h9 && d0 == 128'h7f7e_7d7c_7b7a_7978_7776_7574_7372_7170,
          "post-drain read must return the new line data");
    check(duplicate_response_count == 0,
          "late read response must not duplicate AXI response");

    // EMIF-only reset while a read is in flight must preserve the CPU-side
    // context and return DECERR. The backend keeps its pending response so
    // the reset-epoch DRAIN path is exercised. Hold RVALID stable while the
    // backend response is drained before accepting the next epoch.
    cfg_preserve_read_pending = 1;
    cfg_read_delay = 8;
    expected_be = read_accept_count;
    araddr = 64'h4000_1b00; arid = 4'ha; arlen = 0; arsize = 4;
    arburst = AXI4_BURST_INCR; arvalid = 1; rready = 0;
    while (!arready) @(posedge cpu_clk);
    @(posedge cpu_clk);
    @(negedge cpu_clk);
    arvalid = 0;
    wait (avalon_read && avalon_waitrequest_n);
    @(posedge emif_clk);
    @(negedge emif_clk);
    emif_rst_n = 0;
    repeat (4) @(posedge cpu_clk);
    while (!rvalid) @(posedge cpu_clk);
    check(rid == 4'ha && rresp == AXI4_RESP_DECERR && rlast,
          "EMIF-only reset must return one DECERR R beat");
    check(rdata == 0, "error R beat must not expose stale line data");
    repeat (3) @(posedge cpu_clk);
    check(rvalid && rid == 4'ha && rresp == AXI4_RESP_DECERR && rlast,
          "R payload must hold while backpressured");
    emif_rst_n = 1;
    repeat (3) @(posedge emif_clk);
    cfg_read_delay = 0;
    do_read(64'h4000_1d00, 4'hb, 0, 4, AXI4_BURST_INCR,
            d0, d1, d2, d3, response);
    check(response == AXI4_RESP_OKAY && rid == 4'hb &&
          d0 == 128'h83_82_81_80_7f_7e_7d_7c_7b_7a_79_78_77_76_75_74,
          "EMIF reset re-arm must return the new line data");
    check(read_accept_count == expected_be + 2,
          "EMIF reset path must issue old and new reads exactly once");
    check(duplicate_response_count == 0,
          "EMIF reset late response must not duplicate R");
    cfg_preserve_read_pending = 0;
    cal_fail = 0;
    cpu_rst_n = 0;
    emif_rst_n = 0;
    // Keep CPU reset asserted for three cpu_clk edges (and EMIF reset for
    // the same interval), covering the two-emif_clk cpu_rst_n synchronizer
    // stages before the next epoch is released.
    repeat (3) @(posedge cpu_clk);
    cpu_rst_n = 1;
    emif_rst_n = 1;
    repeat (4) @(posedge cpu_clk);
    cal_success = 1;

    // A reset across both domains between an accepted read and readdatavalid
    // flushes the BFM and both CDC FIFOs; no old R response may appear after
    // release, and a fresh read must still complete exactly once.
    cfg_read_delay = 15;
    araddr = 64'h4000_1600; arid = 4'h5; arlen = 0; arsize = 4;
    arburst = AXI4_BURST_INCR; arvalid = 1; rready = 1;
    while (!arready) @(posedge cpu_clk);
    @(posedge cpu_clk);
    @(negedge cpu_clk);
    arvalid = 0;
    wait (avalon_read && avalon_waitrequest_n);
    @(posedge emif_clk);
    cpu_rst_n = 0;
    emif_rst_n = 0;
    repeat (3) @(posedge cpu_clk);
    cpu_rst_n = 1;
    emif_rst_n = 1;
    repeat (4) @(posedge cpu_clk);
    check(!rvalid, "reset must flush old R response");
    cfg_read_delay = 4;
    do_read(64'h4000_1600, 4'h5, 0, 4, AXI4_BURST_INCR,
            d0, d1, d2, d3, response);
    check(response == AXI4_RESP_OKAY, "delayed readdatavalid read must complete");
    cpu_rst_n = 0;
    repeat (2) @(posedge cpu_clk);
    cpu_rst_n = 1;
    repeat (4) @(posedge cpu_clk);

    // Calibration failure is sticky, returns local DECERR and emits no Avalon.
    cal_fail = 1;
    repeat (4) @(posedge cpu_clk);
    check(!avalon_read && !avalon_write, "cal_fail must suppress Avalon");
    expected_be = write_accept_count;
    do_write(64'h4000_1800, 4'h6, 0, 4, AXI4_BURST_INCR,
             d0, 0, 0, 0, 16'hffff, 0, 0, 0, response);
    check(response == AXI4_RESP_DECERR, "cal_fail write must be DECERR");
    check(write_accept_count == expected_be, "cal_fail write reached Avalon");
    check(duplicate_response_count == 0, "BFM saw duplicate response");

    if (errors == 0) begin
      $display("PASS: B2 AXI4/Avalon SV regression writes=%0d reads=%0d",
               write_accept_count, read_accept_count);
    end else begin
      $display("FAIL: B2 regression errors=%0d", errors);
      $fatal(1);
    end
    $finish;
  end

endmodule

/* verilator lint_on WIDTHEXPAND */
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on DECLFILENAME */
