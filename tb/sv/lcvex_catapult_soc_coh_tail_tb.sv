`timescale 1ns/1ps

module lcvex_catapult_soc_coh_tail_tb #(
    parameter int L2_SETS = 256,
    parameter int L2_WAYS = 2
);
  import lcvex_pkg::*;

  localparam logic [63:0] TEST_ADDR = 64'h0000_0000_4064_f938;
  localparam logic [63:0] LINE_BASE = TEST_ADDR & ~64'h3f;
  localparam logic [63:0] SCAN_BASE = 64'h0000_0000_4400_5000;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic imem_req_valid;
  mem_req_t imem_req;
  logic imem_req_ready, imem_rsp_valid, imem_rsp_ready;
  mem_rsp_t imem_rsp;
  logic dmem_req_valid;
  mem_req_t dmem_req;
  logic dmem_req_ready, dmem_rsp_valid, dmem_rsp_ready;
  mem_rsp_t dmem_rsp;
  logic ptw_req_valid, ptw_req_ready, ptw_rsp_valid, ptw_rsp_ready;
  mem_req_t ptw_req;
  mem_rsp_t ptw_rsp;
  logic checkpoint_quiesce, checkpoint_ack_valid, checkpoint_ack_ready;
  logic checkpoint_fault, l1_drain_done, l1_drain_fault;
  logic l2_drain_ack_valid, l2_drain_fault;
  logic poc_req_valid, poc_req_ready, poc_rsp_valid, poc_rsp_ready;
  mem_req_t poc_req;
  mem_rsp_t poc_rsp;
  logic dbg_l1_u_req_we, dbg_l1_u_req_bypass;
  logic [63:0] dbg_l1_u_req_addr, dbg_l1_u_req_wdata;
  logic dbg_arb_req0_we, dbg_arb_req0_bypass, dbg_l2_u_req_we;
  logic [63:0] dbg_arb_req0_wdata, dbg_l2_u_req_addr;
  logic dbg_l2_u_req_bypass;
  logic [63:0] dbg_l2_u_req_wdata;

  logic [511:0] backing_line;
  logic poc_pending_q;
  mem_rsp_t poc_rsp_q;
  integer poc_reads;
  integer errors;

  lcvex_catapult_soc_coh #(
      .LINE_BYTES(64), .L1_SETS(64),
      .L2_SETS(L2_SETS), .L2_WAYS(L2_WAYS)
  ) dut (
      .clk, .rst_n,
      .imem_req_valid, .imem_req, .imem_req_ready,
      .imem_rsp_valid, .imem_rsp, .imem_rsp_ready,
      .dmem_req_valid, .dmem_req, .dmem_req_ready,
      .dmem_rsp_valid, .dmem_rsp, .dmem_rsp_ready,
      .ptw_req_valid, .ptw_req, .ptw_req_ready,
      .ptw_rsp_valid, .ptw_rsp, .ptw_rsp_ready,
      .checkpoint_quiesce, .checkpoint_ack_valid,
      .checkpoint_ack_ready, .checkpoint_fault,
      .l1_drain_done, .l1_drain_fault,
      .l2_drain_ack_valid, .l2_drain_fault,
      .poc_req_valid, .poc_req, .poc_req_ready,
      .poc_rsp_valid, .poc_rsp, .poc_rsp_ready,
      .dbg_l1_u_req_we, .dbg_l1_u_req_addr,
      .dbg_l1_u_req_bypass, .dbg_l1_u_req_wdata,
      .dbg_arb_req0_we, .dbg_arb_req0_bypass,
      .dbg_arb_req0_wdata, .dbg_l2_u_req_we,
      .dbg_l2_u_req_addr, .dbg_l2_u_req_bypass,
      .dbg_l2_u_req_wdata
  );

  assign poc_req_ready = !poc_pending_q;
  assign poc_rsp_valid = poc_pending_q;
  assign poc_rsp = poc_rsp_q;

  function automatic logic [63:0] read_backing(input logic [63:0] addr);
    logic [63:0] value;
    int offset;
    begin
      value = '0;
      if (addr >= LINE_BASE && addr < (LINE_BASE + 64)) begin
        offset = int'(addr - LINE_BASE);
        for (int i = 0; i < 8; i++)
          value[i*8 +: 8] = backing_line[(offset+i)*8 +: 8];
      end else if (addr >= SCAN_BASE && addr < (SCAN_BASE + 64'h3000)) begin
        offset = int'(addr - SCAN_BASE);
        for (int i = 0; i < 8; i++)
          value[i*8 +: 8] = scan_byte(offset+i);
      end
      return value;
    end
  endfunction

  function automatic logic [7:0] scan_byte(input integer offset);
    scan_byte = 8'h41 + 8'(offset % 26);
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      poc_pending_q <= 1'b0;
      poc_rsp_q <= '0;
      poc_reads <= 0;
    end else begin
      if (poc_pending_q && poc_rsp_ready)
        poc_pending_q <= 1'b0;

      if (poc_req_valid && poc_req_ready) begin
        poc_rsp_q <= '0;
        if (poc_req.we || (poc_req.addr[2:0] != 3'd0) ||
            !((poc_req.addr >= LINE_BASE &&
               poc_req.addr <= (LINE_BASE + 64'd56)) ||
              (poc_req.addr >= SCAN_BASE &&
               poc_req.addr <= (SCAN_BASE + 64'h2ff8)))) begin
          poc_rsp_q.fault <= 1'b1;
        end else begin
          poc_rsp_q.rdata <= read_backing(poc_req.addr);
          poc_reads <= poc_reads + 1;
        end
        poc_pending_q <= 1'b1;
      end
    end
  end

  task automatic request_dmem(input logic [63:0] addr,
                              output mem_rsp_t result);
    begin
      @(negedge clk);
      dmem_req = '0;
      dmem_req.addr = addr;
      dmem_req_valid = 1'b1;
      while (!dmem_req_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      dmem_req_valid = 1'b0;
      while (!dmem_rsp_valid) @(negedge clk);
      result = dmem_rsp;
      @(posedge clk);
      #1;
    end
  endtask

  task automatic check_ok(input logic condition, input string message);
    if (!condition) begin
      $display("FAIL: %s", message);
      errors = errors + 1;
    end
  endtask

  initial begin
    mem_rsp_t result;
    integer scan_reads_start;
    errors = 0;
    imem_req_valid = 1'b0;
    imem_req = '0;
    imem_rsp_ready = 1'b1;
    dmem_req_valid = 1'b0;
    dmem_req = '0;
    dmem_rsp_ready = 1'b1;
    ptw_req_valid = 1'b0;
    ptw_req = '0;
    ptw_rsp_ready = 1'b1;
    checkpoint_quiesce = 1'b0;
    checkpoint_ack_ready = 1'b1;
    backing_line = '0;
    for (int i = 0; i < 64; i++)
      backing_line[i*8 +: 8] = 8'h40 + 8'(i);
    backing_line[56*8 +: 64] = 64'hc000_0000_ffff_efff;

    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    request_dmem(TEST_ADDR, result);
    check_ok(!result.fault && result.rdata == 64'hc000_0000_ffff_efff,
             "L1/L2 refill returns final DDR line word");
    check_ok(poc_reads == 8,
             $sformatf("first read must fetch one line, got %0d PoC reads",
                       poc_reads));

    request_dmem(TEST_ADDR, result);
    check_ok(!result.fault && result.rdata == 64'hc000_0000_ffff_efff,
             "L1 hit returns final DDR line word");
    check_ok(poc_reads == 8, "L1 hit must not reread PoC");

    // Repeat Linux-style byte-at-a-time reads through the actual Catapult
    // write-back D-L1/L2 path. Two 4 KiB-spaced lines conflict in D-L1; the
    // stress L2 geometry additionally aliases them into one direct-mapped set.
    scan_reads_start = poc_reads;
    for (int byte_index = 0; byte_index < 128; byte_index++) begin
      request_dmem(SCAN_BASE + 64'(byte_index), result);
      check_ok(!result.fault && result.rdata[7:0] == scan_byte(byte_index),
               $sformatf("Catapult cache first scan byte %0d got=%02h expected=%02h fault=%b",
                         byte_index,
                         result.rdata[7:0], scan_byte(byte_index), result.fault));
    end
    check_ok(poc_reads == scan_reads_start + 16,
             $sformatf("two cold scan lines should fetch 16 PoC beats, got %0d",
                       poc_reads - scan_reads_start));

    request_dmem(SCAN_BASE + 64'h1000, result);
    check_ok(!result.fault && result.rdata[7:0] == scan_byte(4096),
             "Catapult D-L1/L2 conflict line zero data");
    request_dmem(SCAN_BASE + 64'h2040, result);
    check_ok(!result.fault && result.rdata[7:0] == scan_byte(8256),
             "Catapult D-L1/L2 conflict line one data");
    check_ok(poc_reads == scan_reads_start + 32,
             $sformatf("two conflict lines should add 16 PoC beats, got %0d",
                       poc_reads - scan_reads_start - 16));

    for (int byte_index = 0; byte_index < 128; byte_index++) begin
      request_dmem(SCAN_BASE + 64'(byte_index), result);
      check_ok(!result.fault && result.rdata[7:0] == scan_byte(byte_index),
               $sformatf("Catapult cache replay byte %0d got=%02h expected=%02h fault=%b",
                         byte_index,
                         result.rdata[7:0], scan_byte(byte_index), result.fault));
    end
    if (L2_SETS == 64 && L2_WAYS == 1) begin
      check_ok(poc_reads == scan_reads_start + 48,
               $sformatf("stress L2 should refetch evicted lines, got %0d PoC beats",
                         poc_reads - scan_reads_start - 32));
    end else begin
      check_ok(poc_reads == scan_reads_start + 32,
               $sformatf("production L2 should serve replay without PoC reads, got %0d extra beats",
                         poc_reads - scan_reads_start - 16));
    end

    if (errors == 0) begin
      $display("PASS: lcvex_catapult_soc_coh_tail_tb tail + byte replay L1/L2=%0d/%0d poc_reads=%0d",
               L2_SETS, L2_WAYS, poc_reads);
      $finish;
    end else begin
      $fatal(1, "FAIL: lcvex_catapult_soc_coh_tail_tb errors=%0d", errors);
    end
  end

  initial begin
    #100000;
    $fatal(1, "timeout: lcvex_catapult_soc_coh_tail_tb");
  end
endmodule
