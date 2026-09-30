// lcvex_axi4_tb.sv
//
// 独立 AXI4 Full 闭环：master -> 随机 slave/BFM -> master response。
// lcvex_axi4_tb 是可执行的 SV 定向回归；lcvex_axi4_cocotb_tb 复用同一
// endpoint 作为 Cocotb 顶层，避免依赖现有 SoC/filelist/Makefile。

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off UNUSEDSIGNAL */
module lcvex_axi4_endpoint #(
    parameter int ADDR_WIDTH = 64,
    parameter int DATA_WIDTH = 128,
    parameter int ID_WIDTH = 4,
    parameter int MAX_BURST_LEN = 16,
    parameter int MEM_BYTES = 65536,
    parameter int unsigned SEED = 32'h1b1_a4f7
) (
    input logic clk,
    input logic rst_n,
    input logic cfg_random_stall,
    input logic cfg_block_aw,
    input logic cfg_block_w,
    input logic cfg_block_ar,
    input logic cfg_write_error,
    input logic cfg_read_error,

    input logic req_valid,
    output logic req_ready,
    input logic req_write,
    input logic [ADDR_WIDTH-1:0] req_addr,
    input logic [ID_WIDTH-1:0] req_id,
    input logic [7:0] req_len,
    input logic [2:0] req_size,
    input logic [1:0] req_burst,
    input logic [DATA_WIDTH*MAX_BURST_LEN-1:0] req_wdata,
    input logic [(DATA_WIDTH/8)*MAX_BURST_LEN-1:0] req_wstrb,

    output logic rsp_valid,
    input logic rsp_ready,
    output logic rsp_write,
    output logic [ID_WIDTH-1:0] rsp_id,
    output logic [DATA_WIDTH-1:0] rsp_rdata,
    output logic [1:0] rsp_resp,
    output logic rsp_last
);

  localparam int BYTE_LANES = DATA_WIDTH / 8;

  logic awvalid;
  logic awready;
  logic [ID_WIDTH-1:0] awid;
  logic [ADDR_WIDTH-1:0] awaddr;
  logic [7:0] awlen;
  logic [2:0] awsize;
  logic [1:0] awburst;
  logic awlock;
  logic [3:0] awcache;
  logic [2:0] awprot;
  logic [3:0] awqos;

  logic wvalid;
  logic wready;
  logic [DATA_WIDTH-1:0] wdata;
  logic [BYTE_LANES-1:0] wstrb;
  logic wlast;

  logic bvalid;
  logic bready;
  logic [ID_WIDTH-1:0] bid;
  logic [1:0] bresp;

  logic arvalid;
  logic arready;
  logic [ID_WIDTH-1:0] arid;
  logic [ADDR_WIDTH-1:0] araddr;
  logic [7:0] arlen;
  logic [2:0] arsize;
  logic [1:0] arburst;
  logic arlock;
  logic [3:0] arcache;
  logic [2:0] arprot;
  logic [3:0] arqos;

  logic rvalid;
  logic rready;
  logic [ID_WIDTH-1:0] rid;
  logic [DATA_WIDTH-1:0] rdata;
  logic [1:0] rresp;
  logic rlast;

  lcvex_axi4_master #(
      .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH), .ID_WIDTH(ID_WIDTH),
      .MAX_BURST_LEN(MAX_BURST_LEN)
  ) master (
      .clk, .rst_n,
      .req_valid, .req_ready, .req_write, .req_addr, .req_id, .req_len,
      .req_size, .req_burst, .req_wdata, .req_wstrb,
      .rsp_valid, .rsp_ready, .rsp_write, .rsp_id, .rsp_rdata, .rsp_resp,
      .rsp_last,
      .awvalid, .awready, .awid, .awaddr, .awlen, .awsize, .awburst,
      .awlock, .awcache, .awprot, .awqos,
      .wvalid, .wready, .wdata, .wstrb, .wlast,
      .bvalid, .bready, .bid, .bresp,
      .arvalid, .arready, .arid, .araddr, .arlen, .arsize, .arburst,
      .arlock, .arcache, .arprot, .arqos,
      .rvalid, .rready, .rid, .rdata, .rresp, .rlast
  );

  lcvex_axi4_bfm #(
      .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH), .ID_WIDTH(ID_WIDTH),
      .MAX_BURST_LEN(MAX_BURST_LEN), .MEM_BYTES(MEM_BYTES), .SEED(SEED)
  ) slave (
      .clk, .rst_n, .cfg_random_stall, .cfg_block_aw, .cfg_block_w,
      .cfg_block_ar, .cfg_write_error, .cfg_read_error,
      .awvalid, .awready, .awid, .awaddr, .awlen, .awsize, .awburst,
      .awlock, .awcache, .awprot, .awqos,
      .wvalid, .wready, .wdata, .wstrb, .wlast,
      .bvalid, .bready, .bid, .bresp,
      .arvalid, .arready, .arid, .araddr, .arlen, .arsize, .arburst,
      .arlock, .arcache, .arprot, .arqos,
      .rvalid, .rready, .rid, .rdata, .rresp, .rlast
  );

  lcvex_axi4_sva #(
      .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH), .ID_WIDTH(ID_WIDTH)
  ) protocol_sva (
      .clk, .rst_n,
      .awvalid, .awready, .awid, .awaddr, .awlen, .awsize, .awburst,
      .awlock, .awcache, .awprot, .awqos,
      .wvalid, .wready, .wdata, .wstrb, .wlast,
      .bvalid, .bready, .bid, .bresp,
      .arvalid, .arready, .arid, .araddr, .arlen, .arsize, .arburst,
      .arlock, .arcache, .arprot, .arqos,
      .rvalid, .rready, .rid, .rdata, .rresp, .rlast
  );

endmodule


module lcvex_axi4_tb;
  import lcvex_axi4_pkg::*;

  localparam int ADDR_WIDTH = 64;
  localparam int DATA_WIDTH = 128;
  localparam int ID_WIDTH = 4;
  localparam int MAX_BURST_LEN = 16;
  localparam int BYTE_LANES = DATA_WIDTH / 8;

  logic clk;
  logic rst_n;
  logic cfg_random_stall;
  logic cfg_block_aw;
  logic cfg_block_w;
  logic cfg_block_ar;
  logic cfg_write_error;
  logic cfg_read_error;

  logic req_valid;
  logic req_ready;
  logic req_write;
  logic [ADDR_WIDTH-1:0] req_addr;
  logic [ID_WIDTH-1:0] req_id;
  logic [7:0] req_len;
  logic [2:0] req_size;
  logic [1:0] req_burst;
  logic [DATA_WIDTH*MAX_BURST_LEN-1:0] req_wdata;
  logic [BYTE_LANES*MAX_BURST_LEN-1:0] req_wstrb;

  logic rsp_valid;
  logic rsp_ready;
  logic rsp_write;
  logic [ID_WIDTH-1:0] rsp_id;
  logic [DATA_WIDTH-1:0] rsp_rdata;
  logic [1:0] rsp_resp;
  logic rsp_last;

  int errors;

  lcvex_axi4_endpoint endpoint (
      .clk, .rst_n, .cfg_random_stall, .cfg_block_aw, .cfg_block_w,
      .cfg_block_ar, .cfg_write_error, .cfg_read_error,
      .req_valid, .req_ready, .req_write, .req_addr, .req_id, .req_len,
      .req_size, .req_burst, .req_wdata, .req_wstrb,
      .rsp_valid, .rsp_ready, .rsp_write, .rsp_id, .rsp_rdata, .rsp_resp,
      .rsp_last
  );

  always #5 clk = ~clk;

  task automatic check_ok(input logic condition, input string message);
    if (!condition) begin
      $display("FAIL: %s", message);
      errors++;
    end
  endtask

  task automatic clear_command;
    begin
      req_valid = 1'b0;
      req_write = 1'b0;
      req_addr = '0;
      req_id = '0;
      req_len = '0;
      req_size = '0;
      req_burst = AXI4_BURST_INCR;
      req_wdata = '0;
      req_wstrb = '0;
    end
  endtask

  task automatic send_command(
      input logic write,
      input logic [63:0] addr,
      input logic [ID_WIDTH-1:0] id,
      input logic [7:0] len,
      input logic [2:0] size,
      input logic [1:0] burst,
      input logic [DATA_WIDTH*MAX_BURST_LEN-1:0] data,
      input logic [BYTE_LANES*MAX_BURST_LEN-1:0] strb
  );
    begin
      req_write = write;
      req_addr = addr;
      req_id = id;
      req_len = len;
      req_size = size;
      req_burst = burst;
      req_wdata = data;
      req_wstrb = strb;
      req_valid = 1'b1;
      while (!req_ready) begin
        @(posedge clk);
      end
      @(posedge clk);
      req_valid = 1'b0;
    end
  endtask

  task automatic wait_write_response(
      input logic [ID_WIDTH-1:0] expected_id,
      output logic [1:0] response
  );
    begin
      response = AXI4_RESP_OKAY;
      while (!rsp_valid) begin
        @(posedge clk);
      end
      check_ok(rsp_write, "写响应必须来自 B 通道");
      check_ok(rsp_id == expected_id, "BID 必须匹配 AWID");
      check_ok(rsp_last, "B 响应的 rsp_last 必须为 1");
      response = rsp_resp;
      @(posedge clk);
    end
  endtask

  task automatic wait_read_response(
      input logic [ID_WIDTH-1:0] expected_id,
      input logic [7:0] expected_len,
      output logic [DATA_WIDTH*MAX_BURST_LEN-1:0] data,
      output logic [1:0] response
  );
    int beat;
    logic finished;
    begin
      data = '0;
      response = AXI4_RESP_OKAY;
      beat = 0;
      finished = 1'b0;
      while (!finished) begin
        while (!rsp_valid) begin
          @(posedge clk);
        end
        check_ok(!rsp_write, "读响应必须来自 R 通道");
        check_ok(rsp_id == expected_id, "RID 必须匹配 ARID");
        if (beat < MAX_BURST_LEN) begin
          data[beat*DATA_WIDTH +: DATA_WIDTH] = rsp_rdata;
        end
        response = rsp_resp;
        if (rsp_last) begin
          check_ok(beat == expected_len,
                   $sformatf("R LAST beat=%0d 期望=%0d", beat, expected_len));
          finished = 1'b1;
        end else begin
          check_ok(beat < expected_len, "R 非 LAST beat 不得超过 LEN");
          beat++;
        end
        @(posedge clk);
      end
    end
  endtask

  task automatic do_write(
      input logic [63:0] addr,
      input logic [ID_WIDTH-1:0] id,
      input logic [7:0] len,
      input logic [2:0] size,
      input logic [1:0] burst,
      input logic [DATA_WIDTH*MAX_BURST_LEN-1:0] data,
      input logic [BYTE_LANES*MAX_BURST_LEN-1:0] strb,
      output logic [1:0] response
  );
    begin
      send_command(1'b1, addr, id, len, size, burst, data, strb);
      wait_write_response(id, response);
    end
  endtask

  task automatic do_read(
      input logic [63:0] addr,
      input logic [ID_WIDTH-1:0] id,
      input logic [7:0] len,
      input logic [2:0] size,
      input logic [1:0] burst,
      output logic [DATA_WIDTH*MAX_BURST_LEN-1:0] data,
      output logic [1:0] response
  );
    begin
      send_command(1'b0, addr, id, len, size, burst, '0, '0);
      wait_read_response(id, len, data, response);
    end
  endtask

  logic [DATA_WIDTH*MAX_BURST_LEN-1:0] tx_data;
  logic [BYTE_LANES*MAX_BURST_LEN-1:0] tx_strb;
  logic [DATA_WIDTH*MAX_BURST_LEN-1:0] rx_data;
  logic [1:0] response;

  initial begin
    errors = 0;
    clk = 1'b0;
    rst_n = 1'b0;
    cfg_random_stall = 1'b0;
    cfg_block_aw = 1'b0;
    cfg_block_w = 1'b0;
    cfg_block_ar = 1'b0;
    cfg_write_error = 1'b0;
    cfg_read_error = 1'b0;
    rsp_ready = 1'b1;
    clear_command();

    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // Canonical 128-bit, 64B line = four-beat INCR burst.
    tx_data = '0;
    tx_strb = '0;
    for (int i = 0; i < 64; i++) begin
      tx_data[i*8 +: 8] = 8'h40 + i[7:0];
      tx_strb[i] = 1'b1;
    end
    cfg_random_stall = 1'b1;
    do_write(64'h0000_0000_0000_1000, 4'h2, 8'd3, 3'd4,
             AXI4_BURST_INCR, tx_data, tx_strb, response);
    check_ok(response == AXI4_RESP_OKAY, "canonical line 写应 OKAY");
    do_read(64'h0000_0000_0000_1000, 4'h2, 8'd3, 3'd4,
            AXI4_BURST_INCR, rx_data, response);
    check_ok(response == AXI4_RESP_OKAY, "canonical line 读应 OKAY");
    check_ok(rx_data[64*8-1:0] == tx_data[64*8-1:0],
             "canonical line 四拍数据必须逐字节读回");

    // AW/W independent handshakes: hold AWREADY low, accept W first.
    cfg_random_stall = 1'b0;
    cfg_block_aw = 1'b1;
    tx_data = '0;
    tx_strb = '0;
    tx_data[127:0] = 128'h0123_4567_89ab_cdef_ffeeddcc_bbaa9988;
    tx_strb[15:0] = 16'hffff;
    send_command(1'b1, 64'h200, 4'h3, 8'd0, 3'd4, AXI4_BURST_INCR,
                 tx_data, tx_strb);
    wait (endpoint.master.wvalid && endpoint.master.wready);
    check_ok(endpoint.master.awvalid && !endpoint.master.awready,
             "AW 被阻塞时 WVALID 仍必须独立握手");
    @(posedge clk);
    check_ok(!endpoint.master.wvalid && endpoint.master.awvalid,
             "W 完成后 AWVALID 必须保持");
    cfg_block_aw = 1'b0;
    wait_write_response(4'h3, response);
    check_ok(response == AXI4_RESP_OKAY, "W-before-AW 写应 OKAY");

    // Opposite direction: accept AW while W is held, then release W.
    cfg_block_w = 1'b1;
    send_command(1'b1, 64'h220, 4'h4, 8'd0, 3'd4, AXI4_BURST_INCR,
                 tx_data, tx_strb);
    wait (endpoint.master.awvalid && endpoint.master.awready);
    @(posedge clk);
    check_ok(endpoint.master.wvalid && !endpoint.master.wready,
             "WREADY 背压时 WVALID/payload 必须保持");
    cfg_block_w = 1'b0;
    wait_write_response(4'h4, response);

    // WSTRB and a narrow two-byte transfer at a non-zero bus lane.
    tx_data = '0;
    tx_strb = '0;
    tx_data[23:16] = 8'hbe;
    tx_data[31:24] = 8'hef;
    tx_strb[2] = 1'b1;
    tx_strb[3] = 1'b1;
    do_write(64'h302, 4'h5, 8'd0, 3'd1, AXI4_BURST_INCR,
             tx_data, tx_strb, response);
    check_ok(response == AXI4_RESP_OKAY, "窄写应 OKAY");
    do_read(64'h300, 4'h5, 8'd0, 3'd4, AXI4_BURST_INCR,
            rx_data, response);
    check_ok(rx_data[31:16] == 16'hefbe,
             "窄写 WSTRB 应只更新目标 byte lane");

    // Slave error response and R-channel error response are propagated.
    cfg_write_error = 1'b1;
    do_write(64'h340, 4'h6, 8'd0, 3'd4, AXI4_BURST_INCR,
             tx_data, tx_strb, response);
    check_ok(response == AXI4_RESP_SLVERR, "BRESP SLVERR 必须上送");
    cfg_write_error = 1'b0;
    cfg_read_error = 1'b1;
    do_read(64'h300, 4'h6, 8'd0, 3'd4, AXI4_BURST_INCR,
            rx_data, response);
    check_ok(response == AXI4_RESP_SLVERR, "RRESP SLVERR 必须上送");
    cfg_read_error = 1'b0;

    // Local preflight DECERR: no illegal AXI request may cross 4 KiB.
    do_write(64'h0000_0000_0000_0ffc, 4'h7, 8'd0, 3'd4,
             AXI4_BURST_INCR, tx_data, tx_strb, response);
    check_ok(response == AXI4_RESP_DECERR, "跨 4KiB 写必须本地 DECERR");
    send_command(1'b0, 64'h0000_0000_0000_0ff0, 4'h7, 8'd3, 3'd4,
                 AXI4_BURST_INCR, '0, '0);
    wait_read_response(4'h7, 8'd0, rx_data, response);
    check_ok(response == AXI4_RESP_DECERR, "跨 4KiB 读必须本地 DECERR");
    do_read(64'h400, 4'h7, 8'd0, 3'd7, AXI4_BURST_INCR,
            rx_data, response);
    check_ok(response == AXI4_RESP_DECERR, "超总线 SIZE 必须本地 DECERR");
    do_read(64'h400, 4'h7, 8'd0, 3'd4, AXI4_BURST_FIXED,
            rx_data, response);
    check_ok(response == AXI4_RESP_DECERR, "非 INCR burst 必须本地 DECERR");

    // Reset aborts an incomplete transaction and does not leak B/R later.
    cfg_block_aw = 1'b1;
    send_command(1'b1, 64'h380, 4'h8, 8'd0, 3'd4, AXI4_BURST_INCR,
                 tx_data, tx_strb);
    wait (endpoint.master.wvalid && endpoint.master.wready);
    @(posedge clk);
    rst_n = 1'b0;
    repeat (3) @(posedge clk);
    check_ok(!endpoint.master.awvalid && !endpoint.master.wvalid &&
             !rsp_valid, "reset 必须中止通道和响应");
    rst_n = 1'b1;
    cfg_block_aw = 1'b0;
    cfg_random_stall = 1'b1;
    repeat (2) @(posedge clk);
    do_write(64'h3c0, 4'h9, 8'd0, 3'd4, AXI4_BURST_INCR,
             tx_data, tx_strb, response);
    check_ok(response == AXI4_RESP_OKAY, "reset 后新写事务应唯一完成");

    if (errors == 0) begin
      $display("PASS: lcvex_axi4_tb 全部 AXI4 Full 场景通过 (seed=0x%08x)",
               32'h1b1_a4f7);
      $finish;
    end else begin
      $fatal(1, "FAIL: %0d 处错误", errors);
    end
  end
endmodule


// Cocotb 顶层只提供同一 RTL/BFM/SVA 闭环，不含 SV directed initial。
module lcvex_axi4_cocotb_tb #(
    parameter int unsigned SEED = 32'h1b1_a4f7
);
  localparam int ADDR_WIDTH = 64;
  localparam int DATA_WIDTH = 128;
  localparam int ID_WIDTH = 4;
  localparam int MAX_BURST_LEN = 16;
  localparam int BYTE_LANES = DATA_WIDTH / 8;

  logic clk;
  logic rst_n;
  logic cfg_random_stall;
  logic cfg_block_aw;
  logic cfg_block_w;
  logic cfg_block_ar;
  logic cfg_write_error;
  logic cfg_read_error;
  logic req_valid;
  logic req_ready;
  logic req_write;
  logic [ADDR_WIDTH-1:0] req_addr;
  logic [ID_WIDTH-1:0] req_id;
  logic [7:0] req_len;
  logic [2:0] req_size;
  logic [1:0] req_burst;
  logic [DATA_WIDTH*MAX_BURST_LEN-1:0] req_wdata;
  logic [BYTE_LANES*MAX_BURST_LEN-1:0] req_wstrb;
  logic rsp_valid;
  logic rsp_ready;
  logic rsp_write;
  logic [ID_WIDTH-1:0] rsp_id;
  logic [DATA_WIDTH-1:0] rsp_rdata;
  logic [1:0] rsp_resp;
  logic rsp_last;

  // Stable top-level observation points for Cocotb channel assertions.
  logic dbg_awvalid;
  logic dbg_awready;
  logic dbg_wvalid;
  logic dbg_wready;
  logic [DATA_WIDTH-1:0] dbg_wdata;
  logic [BYTE_LANES-1:0] dbg_wstrb;
  logic dbg_wlast;
  logic dbg_arvalid;
  logic dbg_arready;
  logic dbg_bvalid;
  logic dbg_bready;
  logic dbg_rvalid;
  logic dbg_rready;

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    cfg_random_stall = 1'b1;
    cfg_block_aw = 1'b0;
    cfg_block_w = 1'b0;
    cfg_block_ar = 1'b0;
    cfg_write_error = 1'b0;
    cfg_read_error = 1'b0;
    req_valid = 1'b0;
    req_write = 1'b0;
    req_addr = '0;
    req_id = '0;
    req_len = '0;
    req_size = '0;
    req_burst = 2'b01;
    req_wdata = '0;
    req_wstrb = '0;
    rsp_ready = 1'b1;
  end
  always #5 clk = ~clk;

  lcvex_axi4_endpoint #(.SEED(SEED)) endpoint (
      .clk, .rst_n, .cfg_random_stall, .cfg_block_aw, .cfg_block_w,
      .cfg_block_ar, .cfg_write_error, .cfg_read_error,
      .req_valid, .req_ready, .req_write, .req_addr, .req_id, .req_len,
      .req_size, .req_burst, .req_wdata, .req_wstrb,
      .rsp_valid, .rsp_ready, .rsp_write, .rsp_id, .rsp_rdata, .rsp_resp,
      .rsp_last
  );

  assign dbg_awvalid = endpoint.awvalid;
  assign dbg_awready = endpoint.awready;
  assign dbg_wvalid = endpoint.wvalid;
  assign dbg_wready = endpoint.wready;
  assign dbg_wdata = endpoint.wdata;
  assign dbg_wstrb = endpoint.wstrb;
  assign dbg_wlast = endpoint.wlast;
  assign dbg_arvalid = endpoint.arvalid;
  assign dbg_arready = endpoint.arready;
  assign dbg_bvalid = endpoint.bvalid;
  assign dbg_bready = endpoint.bready;
  assign dbg_rvalid = endpoint.rvalid;
  assign dbg_rready = endpoint.rready;
endmodule
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on WIDTHEXPAND */
/* verilator lint_on DECLFILENAME */
