// End-to-end Catapult DDR read path:
// M1-B line read -> SoC AXI bridge -> AXI master -> 512-bit Avalon adapter.
// Distinct bytes across the complete 64-byte EMIF line catch lane/beat loss.

`timescale 1ns/1ps

module lcvex_catapult_soc_axi_read_path_tb;
  import lcvex_pkg::*;
  import lcvex_axi4_pkg::*;

  localparam logic [63:0] DDR_BASE = 64'h0000_0000_4000_0000;
  localparam logic [63:0] LINE_ADDR = 64'h0000_0000_4000_1000;
  localparam logic [24:0] EMIF_WORD_ADDR = 25'h40;

  logic clk = 1'b0;
  logic rst_n = 1'b0;

  logic u_req_valid = 1'b0;
  mem_req_t u_req = '0;
  logic u_req_accept;
  logic u_rsp_valid;
  mem_rsp_t u_rsp;
  logic u_rsp_ready = 1'b0;

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
  logic [2:0] bridge_state;
  logic bridge_req_write;

  logic awvalid, awready;
  logic [3:0] awid;
  logic [63:0] awaddr;
  logic [7:0] awlen;
  logic [2:0] awsize;
  logic [1:0] awburst;
  logic awlock;
  logic [3:0] awcache;
  logic [2:0] awprot;
  logic [3:0] awqos;
  logic wvalid, wready;
  logic [127:0] wdata;
  logic [15:0] wstrb;
  logic wlast;
  logic bvalid, bready;
  logic [3:0] bid;
  logic [1:0] bresp;
  logic arvalid, arready;
  logic [3:0] arid;
  logic [63:0] araddr;
  logic [7:0] arlen;
  logic [2:0] arsize;
  logic [1:0] arburst;
  logic arlock;
  logic [3:0] arcache;
  logic [2:0] arprot;
  logic [3:0] arqos;
  logic rvalid, rready;
  logic [3:0] rid;
  logic [127:0] rdata;
  logic [1:0] rresp;
  logic rlast;

  logic avalon_read, avalon_write;
  logic [24:0] avalon_address;
  logic [511:0] avalon_writedata;
  logic [6:0] avalon_burstcount;
  logic [63:0] avalon_byteenable;
  logic avalon_waitrequest_n = 1'b1;
  logic [511:0] avalon_readdata = '0;
  logic avalon_readdatavalid = 1'b0;
  logic avalon_timeout_abort;
  integer avalon_read_count = 0;
  integer axi_r_beat_count = 0;

  always #5 clk = ~clk;

  function automatic logic [511:0] patterned_emif_line(
      input logic [24:0] word_address);
    logic [511:0] result;
    for (int byte_index = 0; byte_index < 64; byte_index++)
      result[byte_index*8 +: 8] = 8'(word_address[7:0] + byte_index);
    return result;
  endfunction

  function automatic logic [63:0] expected_m1_word(input integer word_index);
    logic [63:0] result;
    for (int byte_index = 0; byte_index < 8; byte_index++)
      result[byte_index*8 +: 8] = 8'(8'h40 + word_index*8 + byte_index);
    return result;
  endfunction

  lcvex_catapult_soc_axi_bridge #(
      .ADDR_WIDTH(64), .DATA_WIDTH(128), .ID_WIDTH(4), .MAX_BURST_LEN(16)
  ) bridge (
      .clk, .rst_n,
      .u_req_valid, .u_req, .u_req_accept,
      .u_rsp_valid, .u_rsp, .u_rsp_ready,
      .a_req_valid, .a_req_ready, .a_req_write, .a_req_addr, .a_req_id,
      .a_req_len, .a_req_size, .a_req_burst, .a_req_wdata, .a_req_wstrb,
      .a_rsp_valid, .a_rsp_ready, .a_rsp_write, .a_rsp_id, .a_rsp_rdata,
      .a_rsp_resp, .a_rsp_last, .axi_read_count, .axi_write_count,
      .dbg_state(bridge_state), .dbg_req_write_q(bridge_req_write)
  );

  lcvex_axi4_master #(
      .ADDR_WIDTH(64), .DATA_WIDTH(128), .ID_WIDTH(4), .MAX_BURST_LEN(16)
  ) axi_master (
      .clk, .rst_n,
      .req_valid(a_req_valid), .req_ready(a_req_ready),
      .req_write(a_req_write), .req_addr(a_req_addr), .req_id(a_req_id),
      .req_len(a_req_len), .req_size(a_req_size), .req_burst(a_req_burst),
      .req_wdata(a_req_wdata), .req_wstrb(a_req_wstrb),
      .rsp_valid(a_rsp_valid), .rsp_ready(a_rsp_ready),
      .rsp_write(a_rsp_write), .rsp_id(a_rsp_id), .rsp_rdata(a_rsp_rdata),
      .rsp_resp(a_rsp_resp), .rsp_last(a_rsp_last),
      .awvalid, .awready, .awid, .awaddr, .awlen, .awsize, .awburst,
      .awlock, .awcache, .awprot, .awqos,
      .wvalid, .wready, .wdata, .wstrb, .wlast,
      .bvalid, .bready, .bid, .bresp,
      .arvalid, .arready, .arid, .araddr, .arlen, .arsize, .arburst,
      .arlock, .arcache, .arprot, .arqos,
      .rvalid, .rready, .rid, .rdata, .rresp, .rlast
  );

  lcvex_axi4_avalon_adapter #(
      .ADDR_WIDTH(64), .DATA_WIDTH(128), .ID_WIDTH(4),
      .AVALON_TIMEOUT_CYCLES(64)
  ) emif_adapter (
      .cpu_clk(clk), .emif_clk(clk), .cpu_rst_n(rst_n), .emif_rst_n(rst_n),
      .cal_success(1'b1), .cal_fail(1'b0),
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

  // One-cycle-response model of the 512-bit EMIF data port.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      avalon_readdata <= '0;
      avalon_readdatavalid <= 1'b0;
      avalon_read_count <= 0;
      axi_r_beat_count <= 0;
    end else begin
      avalon_readdatavalid <= 1'b0;
      if (avalon_read && avalon_waitrequest_n) begin
        if (avalon_address != EMIF_WORD_ADDR || avalon_burstcount != 7'd1 ||
            avalon_byteenable != 64'hffff_ffff_ffff_ffff)
          $fatal(1, "EMIF read command mismatch addr=%h burst=%0d be=%h",
                 avalon_address, avalon_burstcount, avalon_byteenable);
        avalon_readdata <= patterned_emif_line(avalon_address);
        avalon_readdatavalid <= 1'b1;
        avalon_read_count <= avalon_read_count + 1;
      end
      if (rvalid && rready)
        axi_r_beat_count <= axi_r_beat_count + 1;
    end
  end

  task automatic read_m1_word(input logic [63:0] addr,
                              input integer index,
                              input logic first_request);
    integer wait_cycles;
    begin
      if (first_request) @(negedge clk);
      u_req.addr = addr;
      u_req.we = 1'b0;
      u_req.strb = 8'hff;
      u_req.wdata = 64'd0;
      u_req.maint = MAINT_NONE;
      u_req.bypass = 1'b0;
      u_req_valid = 1'b1;
      wait_cycles = 0;
      #1;
      while (!u_req_accept && wait_cycles < 1000) begin
        @(negedge clk);
        #1;
        wait_cycles++;
      end
      if (!u_req_accept)
        $fatal(1, "M1-B request timeout index=%0d addr=%016h", index, addr);
      @(posedge clk);
      @(negedge clk);
      u_req_valid = 1'b0;
      wait_cycles = 0;
      #1;
      while (!u_rsp_valid && wait_cycles < 1000) begin
        @(negedge clk);
        #1;
        wait_cycles++;
      end
      if (!u_rsp_valid || u_rsp.fault || u_rsp.rdata != expected_m1_word(index))
        $fatal(1, "M1-B read mismatch index=%0d got=%016h expected=%016h fault=%b",
               index, u_rsp.rdata, expected_m1_word(index), u_rsp.fault);
      u_rsp_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      u_rsp_ready = 1'b0;
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    repeat (8) @(posedge clk);

    for (int word_index = 0; word_index < 8; word_index++)
      read_m1_word(LINE_ADDR + 64'(word_index*8), word_index,
                   word_index == 0);

    if (axi_read_count != 1 || axi_r_beat_count != 4 ||
        avalon_read_count != 1 || axi_write_count != 0)
      $fatal(1, "read path transaction count mismatch bridge=%0d axi_r=%0d emif=%0d writes=%0d",
             axi_read_count, axi_r_beat_count, avalon_read_count,
             axi_write_count);

    $display("PASS Catapult M1-B -> AXI4 -> 512-bit Avalon full-line read: 8 x 64-bit words, bytes 0x40..0x7f");
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "Catapult AXI read path testbench timeout");
  end
endmodule
