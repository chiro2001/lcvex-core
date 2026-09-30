// Focused regression for the Catapult M1-B to AXI command bridge.
//
// A line fill is four 128-bit AXI beats but eight 64-bit M1-B responses.
// Distinct data in every 64-bit word catches both an incorrect first response
// sourced from the final AXI beat and loss of the final buffered word.

`timescale 1ns/1ps

module lcvex_catapult_soc_axi_bridge_tb;
  import lcvex_pkg::*;
  import lcvex_axi4_pkg::*;

  localparam logic [63:0] LINE0 = 64'h0000_0000_0000_1000;
  localparam logic [63:0] LINE1 = 64'h0000_0000_0000_1040;
  localparam logic [63:0] LINE2 = 64'h0000_0000_0000_1080;

  logic clk;
  logic rst_n;
  logic u_req_valid;
  mem_req_t u_req;
  logic u_req_accept;
  logic u_rsp_valid;
  mem_rsp_t u_rsp;
  logic u_rsp_ready;
  logic a_req_valid;
  logic a_req_ready;
  logic a_req_write;
  logic [63:0] a_req_addr;
  logic [3:0] a_req_id;
  logic [7:0] a_req_len;
  logic [2:0] a_req_size;
  logic [1:0] a_req_burst;
  logic [2047:0] a_req_wdata;
  logic [255:0] a_req_wstrb;
  logic a_rsp_valid;
  logic a_rsp_ready;
  logic a_rsp_write;
  logic [3:0] a_rsp_id;
  logic [127:0] a_rsp_rdata;
  logic [1:0] a_rsp_resp;
  logic a_rsp_last;
  logic [31:0] axi_read_count;
  logic [31:0] axi_write_count;
  logic [2:0] dbg_state;
  logic dbg_req_write_q;
  logic [63:0] expected_write_data;
  logic [7:0] expected_write_strb;
  integer errors;

  lcvex_catapult_soc_axi_bridge dut (
      .clk, .rst_n,
      .u_req_valid, .u_req, .u_req_accept,
      .u_rsp_valid, .u_rsp, .u_rsp_ready,
      .a_req_valid, .a_req_ready, .a_req_write, .a_req_addr, .a_req_id,
      .a_req_len, .a_req_size, .a_req_burst, .a_req_wdata, .a_req_wstrb,
      .a_rsp_valid, .a_rsp_ready, .a_rsp_write, .a_rsp_id,
      .a_rsp_rdata, .a_rsp_resp, .a_rsp_last,
      .axi_read_count, .axi_write_count, .dbg_state, .dbg_req_write_q
  );

  always #5 clk = ~clk;

  function automatic logic [63:0] line_word(input integer index);
    line_word = 64'hA500_0000_0000_0000 + index;
  endfunction

  task automatic check(input logic condition, input string message);
    if (condition !== 1'b1) begin
      $display("FAIL: %s", message);
      errors = errors + 1;
    end
  endtask

  task automatic issue_upstream(input logic [63:0] addr,
                                input logic write,
                                output integer wait_cycles);
    begin
      // Callers are already at a negedge.  Drive immediately so a sequential
      // line request is present on the first S_LINE_SERVE cycle; a bubble is
      // deliberately defined by the bridge as line-buffer invalidation.
      u_req.addr = addr;
      u_req.we = write;
      u_req.strb = 8'hFF;
      u_req.wdata = 64'h1122_3344_5566_7788;
      if (write) begin
        expected_write_data = 64'h1122_3344_5566_7788;
        expected_write_strb = 8'hff;
      end
      u_req.maint = MAINT_NONE;
      u_req.bypass = 1'b1;
      u_req_valid = 1'b1;
      wait_cycles = 0;
      #1;
      while (!u_req_accept && (wait_cycles < 32)) begin
        @(negedge clk);
        #1;
        wait_cycles = wait_cycles + 1;
      end
      check(u_req_accept, "upstream request acceptance timeout");
      if (u_req_accept) begin
        @(posedge clk);
      end
      @(negedge clk);
      u_req_valid = 1'b0;
    end
  endtask

  task automatic issue_upstream_sized(input logic [63:0] addr,
                                      input logic write,
                                      input logic [7:0] strb,
                                      input logic [63:0] wdata,
                                      output integer wait_cycles);
    begin
      u_req.addr = addr;
      u_req.we = write;
      u_req.strb = strb;
      u_req.wdata = wdata;
      if (write) begin
        expected_write_data = wdata;
        expected_write_strb = strb;
      end
      u_req.maint = MAINT_NONE;
      u_req.bypass = 1'b1;
      u_req_valid = 1'b1;
      wait_cycles = 0;
      #1;
      while (!u_req_accept && (wait_cycles < 32)) begin
        @(negedge clk);
        #1;
        wait_cycles = wait_cycles + 1;
      end
      check(u_req_accept, "sized upstream request acceptance timeout");
      if (u_req_accept) @(posedge clk);
      @(negedge clk);
      u_req_valid = 1'b0;
    end
  endtask

  task automatic expect_axi_command(input logic write,
                                    input logic [63:0] addr,
                                    input logic [7:0] len,
                                    input logic [2:0] size);
    integer cycles;
    begin
      cycles = 0;
      #1;
      while (!a_req_valid && (cycles < 32)) begin
        @(negedge clk);
        #1;
        cycles = cycles + 1;
      end
      check(a_req_valid, "AXI command timeout");
      check(a_req_write == write, "AXI command direction mismatch");
      check(a_req_addr == addr, "AXI command address mismatch");
      check(a_req_len == len, "AXI command length mismatch");
      check(a_req_size == size, "AXI command size mismatch");
      check(a_req_burst == AXI4_BURST_INCR, "AXI command burst mismatch");
      if (write) begin
        check(a_req_wdata[63:0] == expected_write_data,
              "normalized write data mismatch");
        check(a_req_wstrb[7:0] == expected_write_strb,
              "normalized write strobe mismatch");
      end
      @(posedge clk);
      @(negedge clk);
    end
  endtask

  task automatic send_axi_response(input logic [127:0] data,
                                   input logic [1:0] response,
                                   input logic last,
                                   input logic write);
    begin
      a_rsp_rdata = data;
      a_rsp_resp = response;
      a_rsp_last = last;
      a_rsp_write = write;
      a_rsp_valid = 1'b1;
      #1;
      check(a_rsp_ready, "bridge did not accept AXI response");
      @(posedge clk);
      @(negedge clk);
      a_rsp_valid = 1'b0;
    end
  endtask

  task automatic send_line(input integer first_index,
                           input integer fault_beat);
    integer beat;
    logic [1:0] response;
    begin
      for (beat = 0; beat < 4; beat = beat + 1) begin
        response = (beat == fault_beat) ? AXI4_RESP_SLVERR : AXI4_RESP_OKAY;
        send_axi_response(
            {line_word(first_index + beat*2 + 1),
             line_word(first_index + beat*2)},
            response, beat == 3, 1'b0);
      end
    end
  endtask

  task automatic expect_upstream_response(input logic [63:0] data,
                                          input logic fault,
                                          input logic hold_response);
    integer cycles;
    logic [63:0] held_data;
    logic held_fault;
    begin
      cycles = 0;
      #1;
      while (!u_rsp_valid && (cycles < 32)) begin
        @(negedge clk);
        #1;
        cycles = cycles + 1;
      end
      check(u_rsp_valid, "upstream response timeout");
      check(u_rsp.rdata == data, "upstream response data mismatch");
      check(u_rsp.fault == fault, "upstream response fault mismatch");
      if (hold_response && u_rsp_valid) begin
        held_data = u_rsp.rdata;
        held_fault = u_rsp.fault;
        repeat (3) begin
          @(posedge clk);
          @(negedge clk);
          #1;
          check(u_rsp_valid, "response dropped under backpressure");
          check((u_rsp.rdata == held_data) && (u_rsp.fault == held_fault),
                "response changed under backpressure");
        end
      end
      u_rsp_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      u_rsp_ready = 1'b0;
    end
  endtask

  initial begin
    integer wait_cycles;
    integer offset;

    clk = 1'b0;
    rst_n = 1'b0;
    u_req_valid = 1'b0;
    u_req = '0;
    u_rsp_ready = 1'b0;
    a_req_ready = 1'b1;
    a_rsp_valid = 1'b0;
    a_rsp_write = 1'b0;
    a_rsp_id = '0;
    a_rsp_rdata = '0;
    a_rsp_resp = AXI4_RESP_OKAY;
    a_rsp_last = 1'b0;
    errors = 0;

    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    // Happy line fill: offset zero is returned from beat zero, then all seven
    // buffered words are served without another AXI command.
    issue_upstream(LINE0, 1'b0, wait_cycles);
    check(wait_cycles == 0, "idle line request was delayed");
    expect_axi_command(1'b0, LINE0, 8'd3, 3'd4);
    send_line(0, -1);
    expect_upstream_response(line_word(0), 1'b0, 1'b1);
    for (offset = 1; offset < 8; offset = offset + 1) begin
      issue_upstream(LINE0 + offset*8, 1'b0, wait_cycles);
      check(wait_cycles == 0, "sequential buffered request was delayed");
      check(!a_req_valid, "sequential buffered request reissued AXI");
      expect_upstream_response(line_word(offset), 1'b0, 1'b0);
    end
    check(axi_read_count == 1, "full line generated more than one AXI read");

    // A non-OK response before the final beat remains sticky for all buffered
    // words even when the final AXI beat itself is OKAY.
    issue_upstream(LINE1, 1'b0, wait_cycles);
    expect_axi_command(1'b0, LINE1, 8'd3, 3'd4);
    send_line(16, 1);
    expect_upstream_response(line_word(16), 1'b1, 1'b0);
    issue_upstream(LINE1 + 8, 1'b0, wait_cycles);
    expect_upstream_response(line_word(17), 1'b1, 1'b0);

    // A write that does not match the next buffered read invalidates the line,
    // is retried from IDLE, and becomes one normal AXI write transaction.
    issue_upstream(LINE1 + 32, 1'b1, wait_cycles);
    check(wait_cycles > 0, "mismatched write did not invalidate buffered line");
    expect_axi_command(1'b1, LINE1 + 32, 8'd0, 3'd3);
    send_axi_response('0, AXI4_RESP_OKAY, 1'b1, 1'b1);
    expect_upstream_response(64'd0, 1'b0, 1'b0);
    check(axi_write_count == 1, "write retry count mismatch");

    // A 32-bit write at byte offset 12 must be issued as a 4-byte AXI beat;
    // an unconditional 8-byte AWSIZE crosses the 16-byte AXI lane boundary.
    issue_upstream_sized(LINE1 + 64'd12, 1'b1, 8'h0f,
                         64'h0000_0000_dead_beef, wait_cycles);
    expect_axi_command(1'b1, LINE1 + 64'd12, 8'd0, 3'd2);
    send_axi_response('0, AXI4_RESP_OKAY, 1'b1, 1'b1);
    expect_upstream_response(64'd0, 1'b0, 1'b0);
    check(axi_write_count == 2, "narrow write transaction count mismatch");

    // A non-sequential read also invalidates the buffered line and is issued
    // as a single-beat read; addr[3] selects the upper 64-bit result.
    issue_upstream(LINE2, 1'b0, wait_cycles);
    expect_axi_command(1'b0, LINE2, 8'd3, 3'd4);
    send_line(32, -1);
    expect_upstream_response(line_word(32), 1'b0, 1'b0);
    issue_upstream(LINE2 + 24, 1'b0, wait_cycles);
    check(wait_cycles > 0, "non-sequential read did not invalidate line");
    expect_axi_command(1'b0, LINE2 + 24, 8'd0, 3'd3);
    send_axi_response({64'hCAFE_BABE_DEAD_BEEF,
                       64'h0123_4567_89AB_CDEF},
                      AXI4_RESP_OKAY, 1'b1, 1'b0);
    expect_upstream_response(64'hCAFE_BABE_DEAD_BEEF, 1'b0, 1'b0);

    // For a W load at offset 12, use a 4-byte read and extract the addressed
    // byte lane rather than rejecting it as a crossing 8-byte AXI transfer.
    issue_upstream_sized(LINE2 + 64'd12, 1'b0, 8'h0f, 64'd0,
                         wait_cycles);
    expect_axi_command(1'b0, LINE2 + 64'd12, 8'd0, 3'd2);
    send_axi_response({32'hCAFE_BABE, 96'd0}, AXI4_RESP_OKAY, 1'b1, 1'b0);
    expect_upstream_response(64'h0000_0000_CAFE_BABE, 1'b0, 1'b0);
    check(axi_read_count == 5, "AXI read transaction count mismatch");

    if (errors == 0) begin
      $display("LCVEX_CATAPULT_SOC_AXI_BRIDGE_PASS");
      $finish(0);
    end else begin
      $fatal(1, "LCVEX_CATAPULT_SOC_AXI_BRIDGE_FAIL errors=%0d", errors);
    end
  end

endmodule
