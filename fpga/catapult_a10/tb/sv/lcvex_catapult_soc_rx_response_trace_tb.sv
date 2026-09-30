// T-20260920-013：CPU-originated UART DATA response path trace。
//
// 该测试使用 Quartus 21.4 注册 waitrequest/showahead-OFF 等价模型，先让
// resident monitor 完成长空轮询，再逐字节注入 RX。功能路径仍由真实 SoC
// 实例驱动；本测试只读取 observation-only 状态，不 force 或修改握手。

`timescale 1ns/1ps

module lcvex_catapult_soc_rx_response_trace_tb #(
    parameter string BOOT_IMAGE = "fpga/catapult_a10/boot/build/boot.hex"
);

  import lcvex_pkg::*;
  import lcvex_catapult_soc_pkg::*;

  localparam int unsigned EMPTY_POLLS = 32'd65536;
  localparam int unsigned EMPTY_POLL_TIMEOUT = EMPTY_POLLS * 512;
  localparam int unsigned WAIT_CYCLES = 2000000;

  logic clk = 1'b0;
  logic emif_clk = 1'b0;
  always #20 clk = ~clk;
  always #2 emif_clk = ~emif_clk;

  logic rst_n;
  logic emif_rst_n;
  logic emif_cal_success = 1'b0;
  logic emif_cal_fail = 1'b0;
  logic cal_ready = 1'b0;
  logic cal_failed = 1'b0;

  logic        avalon_read;
  logic        avalon_write;
  logic [24:0] avalon_address;
  logic [511:0] avalon_writedata;
  logic [6:0]  avalon_burstcount;
  logic [63:0] avalon_byteenable;
  logic        avalon_waitrequest_n = 1'b1;
  logic [511:0] avalon_readdata = '0;
  logic        avalon_readdatavalid = 1'b0;

  logic        ju_chipselect;
  logic        ju_read_n;
  logic        ju_write_n;
  logic [0:0]  ju_address;
  logic [31:0] ju_writedata;
  logic [31:0] ju_readdata;
  logic        ju_waitrequest;
  logic        ju_irq;

  logic        epcq_csr_read;
  logic        epcq_csr_write;
  logic [2:0]  epcq_csr_address;
  logic [31:0] epcq_csr_writedata;
  logic        epcq_csr_waitrequest = 1'b0;
  logic [31:0] epcq_csr_readdata = 32'd0;
  logic        epcq_csr_readdatavalid = 1'b0;

  logic        checkpoint_quiesce = 1'b0;
  logic        checkpoint_ack_ready = 1'b0;

  logic        ju_rx_valid = 1'b0;
  logic [7:0]  ju_rx_char = 8'd0;
  logic        ju_rx_ready;
  logic        ju_tx_pop = 1'b1;
  logic        ju_force_waitrequest = 1'b0;
  logic        ju_host_activity = 1'b1;
  logic [31:0] ju_data_read_count;
  logic [31:0] ju_rx_pop_count;
  logic [31:0] ju_tx_event_count;
  logic        ju_tx_event_valid;
  logic [7:0]  ju_tx_event_char;
  logic        ju_tx_drain_valid;
  logic [7:0]  ju_tx_drain_char;

  // Standalone observation-only unit stimulus.  This never drives the SoC
  // functional request/response wires and covers pending/backpressure/fault
  // reset semantics independently of the long monitor run.
  logic        unit_rst_n;
  logic        unit_bridge_req, unit_bridge_valid, unit_bridge_ready;
  logic [31:0] unit_bridge_data;
  logic        unit_bridge_fault;
  logic        unit_poc_req, unit_poc_valid, unit_poc_ready;
  logic [31:0] unit_poc_data;
  logic        unit_poc_fault;
  logic        unit_dmem_req, unit_dmem_valid, unit_dmem_ready;
  logic [31:0] unit_dmem_data;
  logic        unit_dmem_fault;
  logic        unit_tx_valid;
  logic [7:0]  unit_tx_char;
  logic        unit_bridge_pending, unit_poc_pending, unit_dmem_pending;
  logic [7:0]  unit_bridge_count, unit_poc_count, unit_dmem_count;
  logic [31:0] unit_bridge_rsp_data, unit_poc_rsp_data, unit_dmem_rsp_data;
  logic        unit_bridge_fault_sticky, unit_poc_fault_sticky;
  logic        unit_dmem_fault_sticky;
  logic [15:0] unit_tx_count;
  logic        unit_tx_seen;
  logic [7:0]  unit_tx_last_byte;

  lcvex_catapult_soc_rx_observer observation_unit (
      .clk(clk), .rst_n(unit_rst_n),
      .bridge_req_fire(unit_bridge_req),
      .bridge_rsp_valid(unit_bridge_valid),
      .bridge_rsp_ready(unit_bridge_ready),
      .bridge_rsp_data_i(unit_bridge_data),
      .bridge_rsp_fault_i(unit_bridge_fault),
      .poc_req_fire(unit_poc_req),
      .poc_rsp_valid(unit_poc_valid), .poc_rsp_ready(unit_poc_ready),
      .poc_rsp_data_i(unit_poc_data), .poc_rsp_fault_i(unit_poc_fault),
      .dmem_req_fire(unit_dmem_req),
      .dmem_rsp_valid(unit_dmem_valid), .dmem_rsp_ready(unit_dmem_ready),
      .dmem_rsp_data_i(unit_dmem_data),
      .dmem_rsp_fault_i(unit_dmem_fault),
      .tx_valid(unit_tx_valid), .tx_char(unit_tx_char),
      .bridge_pending(unit_bridge_pending), .poc_pending(unit_poc_pending),
      .dmem_pending(unit_dmem_pending), .bridge_count(unit_bridge_count),
      .poc_count(unit_poc_count), .dmem_count(unit_dmem_count),
      .bridge_rsp_data(unit_bridge_rsp_data),
      .poc_rsp_data(unit_poc_rsp_data),
      .dmem_rsp_data(unit_dmem_rsp_data),
      .bridge_fault(unit_bridge_fault_sticky),
      .poc_fault(unit_poc_fault_sticky),
      .dmem_fault(unit_dmem_fault_sticky), .tx_count(unit_tx_count),
      .tx_seen(unit_tx_seen), .tx_last_byte(unit_tx_last_byte)
  );

  lcvex_catapult_soc_top #(
      .BRAM_BYTES(1 << 16), .L1_SETS(64), .L2_SETS(64), .L2_WAYS(1),
      .A64_FP_SIMD(1'b0), .FETCH_FIFO_ENABLE(1), .FETCH_FIFO_DEPTH(2),
      .BOOT_HEX_FILE(BOOT_IMAGE)
  ) dut (
      .clk(clk), .rst_n(rst_n),
      .emif_clk(emif_clk), .emif_rst_n(emif_rst_n),
      .emif_cal_success(emif_cal_success), .emif_cal_fail(emif_cal_fail),
      .cal_ready(cal_ready), .cal_failed(cal_failed),
      .avalon_read(avalon_read), .avalon_write(avalon_write),
      .avalon_address(avalon_address), .avalon_writedata(avalon_writedata),
      .avalon_burstcount(avalon_burstcount),
      .avalon_byteenable(avalon_byteenable),
      .avalon_waitrequest_n(avalon_waitrequest_n),
      .avalon_readdata(avalon_readdata),
      .avalon_readdatavalid(avalon_readdatavalid),
      .ju_chipselect(ju_chipselect), .ju_read_n(ju_read_n),
      .ju_write_n(ju_write_n), .ju_address(ju_address),
      .ju_writedata(ju_writedata), .ju_readdata(ju_readdata),
      .ju_waitrequest(ju_waitrequest), .ju_irq(ju_irq),
      .epcq_csr_read(epcq_csr_read), .epcq_csr_write(epcq_csr_write),
      .epcq_csr_address(epcq_csr_address),
      .epcq_csr_writedata(epcq_csr_writedata),
      .epcq_csr_waitrequest(epcq_csr_waitrequest),
      .epcq_csr_readdata(epcq_csr_readdata),
      .epcq_csr_readdatavalid(epcq_csr_readdatavalid),
      .prog_we(1'b0), .prog_addr(64'd0), .prog_strb(8'd0),
      .prog_wdata(64'd0), .dbg_addr(32'd0), .dbg_rdata(),
      .checkpoint_quiesce(checkpoint_quiesce),
      .checkpoint_ack_valid(), .checkpoint_ack_ready(checkpoint_ack_ready),
      .checkpoint_fault(), .l1_drain_done(), .l1_drain_fault(),
      .l2_drain_ack_valid(), .l2_drain_fault(),
      .commit_valid(), .commit_pc(), .commit_next_pc(), .commit_insn(),
      .commit_gpr_we(), .commit_gpr_rd(), .commit_gpr_wdata(),
      .commit_exc_valid(), .commit_exc_code(), .commit_exc_esr(),
      .commit_exc_far(), .jtag_uart_tx_valid(), .jtag_uart_tx_char(),
      .soc_ddr_read_count(), .soc_ddr_write_count(),
      .timer_phys_irq(), .timer_virt_irq(), .tlb_invalidate(),
      .dbg_dmem_req_valid(), .dbg_dmem_req_ready(), .dbg_dmem_req_addr(),
      .dbg_dmem_req_we(), .dbg_dmem_req_wdata(), .dbg_dmem_rsp_valid(),
      .dbg_poc_req_valid(), .dbg_poc_req_addr(), .dbg_poc_req_we(),
      .dbg_ddr_req_valid(), .dbg_ddr_req_ready(), .dbg_ddr_req_write(),
      .dbg_ddr_req_addr(), .dbg_ddr_u_req_valid(), .dbg_ddr_u_req_we(),
      .dbg_ddr_u_req_accept(), .dbg_bridge_state(),
      .dbg_bridge_req_write_q(), .dbg_ddr_rsp_valid(),
      .dbg_axi_awvalid(), .dbg_axi_awready(), .dbg_axi_wvalid(),
      .dbg_axi_wready(), .dbg_axi_bvalid(), .dbg_axi_bready(),
      .dbg_axi_arvalid(), .dbg_axi_arready(), .dbg_axi_rvalid(),
      .dbg_axi_rready(), .dbg_avalon_read(), .dbg_avalon_write(),
      .dbg_avalon_readdatavalid(), .dbg_avalon_waitrequest_n(),
      .dbg_l1_u_req_we(), .dbg_l1_u_req_addr(), .dbg_l1_u_req_bypass(),
      .dbg_l1_u_req_wdata(), .dbg_arb_req0_we(), .dbg_arb_req0_bypass(),
      .dbg_arb_req0_wdata(), .dbg_l2_u_req_we(), .dbg_l2_u_req_addr(),
      .dbg_l2_u_req_bypass(), .dbg_l2_u_req_wdata(), .dbg_ju_req_wdata()
  );

  lcvex_jtag_uart_vendor_model #(.TX_DEPTH(64), .RX_DEPTH(16)) jtag_model (
      .clk(clk), .rst_n(rst_n),
      .chipselect(ju_chipselect), .read_n(ju_read_n),
      .write_n(ju_write_n), .address(ju_address),
      .writedata(ju_writedata), .readdata(ju_readdata),
      .waitrequest(ju_waitrequest), .irq(ju_irq), .rx_valid(ju_rx_valid),
      .rx_char(ju_rx_char), .rx_ready(ju_rx_ready), .tx_pop(ju_tx_pop),
      .force_waitrequest(ju_force_waitrequest),
      .host_activity(ju_host_activity), .avalon_read_count(),
      .avalon_write_count(), .data_read_count(ju_data_read_count),
      .control_read_count(), .data_write_count(), .control_write_count(),
      .rx_pop_count(ju_rx_pop_count), .tx_push_count(), .tx_wspace(),
      .tx_event_count(ju_tx_event_count), .tx_event_char(ju_tx_event_char),
      .tx_event_valid(ju_tx_event_valid), .tx_drain_valid(ju_tx_drain_valid),
      .tx_drain_char(ju_tx_drain_char)
  );

  integer errors;
  integer checks;
  integer i;
  integer empty_wait_cycles;
  logic [7:0] bridge_count_before;
  logic [7:0] poc_count_before;
  logic [7:0] dmem_count_before;

  task automatic inject_rx(input logic [7:0] value);
    begin
      @(negedge clk);
      ju_rx_char = value;
      ju_rx_valid = 1'b1;
      while (!ju_rx_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      ju_rx_valid = 1'b0;
    end
  endtask

  task automatic observation_unit_contract;
    begin
      unit_rst_n = 1'b0;
      unit_bridge_req = 1'b0;
      unit_bridge_valid = 1'b0;
      unit_bridge_ready = 1'b0;
      unit_bridge_data = 32'd0;
      unit_bridge_fault = 1'b0;
      unit_poc_req = 1'b0;
      unit_poc_valid = 1'b0;
      unit_poc_ready = 1'b0;
      unit_poc_data = 32'd0;
      unit_poc_fault = 1'b0;
      unit_dmem_req = 1'b0;
      unit_dmem_valid = 1'b0;
      unit_dmem_ready = 1'b0;
      unit_dmem_data = 32'd0;
      unit_dmem_fault = 1'b0;
      unit_tx_valid = 1'b0;
      unit_tx_char = 8'd0;
      #1;
      if (unit_bridge_pending || unit_poc_pending || unit_dmem_pending ||
          unit_bridge_count != 0 || unit_poc_count != 0 ||
          unit_dmem_count != 0 || unit_bridge_fault_sticky ||
          unit_poc_fault_sticky || unit_dmem_fault_sticky) begin
        $display("FAIL observer reset state is nonzero");
        errors = errors + 1;
      end
      unit_rst_n = 1'b1;

      // A response held under backpressure must not be consumed or counted.
      @(negedge clk);
      unit_bridge_req = 1'b1;
      @(posedge clk);
      @(negedge clk);
      unit_bridge_req = 1'b0;
      unit_bridge_valid = 1'b1;
      unit_bridge_data = 32'h0000_803f;
      unit_bridge_ready = 1'b0;
      repeat (2) @(posedge clk);
      if (!unit_bridge_pending || unit_bridge_count != 0) begin
        $display("FAIL observer backpressure consumed bridge response");
        errors = errors + 1;
      end
      @(negedge clk);
      unit_bridge_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      unit_bridge_valid = 1'b0;
      unit_bridge_ready = 1'b0;
      if (unit_bridge_pending || unit_bridge_count != 8'd1 ||
          unit_bridge_rsp_data != 32'h0000_803f) begin
        $display("FAIL observer bridge response consume/count/data");
        errors = errors + 1;
      end

      // Empty RVALID=0 response clears pending but cannot overwrite/count.
      unit_poc_req = 1'b1;
      @(posedge clk);
      @(negedge clk);
      unit_poc_req = 1'b0;
      unit_poc_valid = 1'b1;
      unit_poc_ready = 1'b1;
      unit_poc_data = 32'd0;
      @(posedge clk);
      @(negedge clk);
      unit_poc_valid = 1'b0;
      unit_poc_ready = 1'b0;
      if (unit_poc_pending || unit_poc_count != 0 ||
          unit_poc_rsp_data != 0) begin
        $display("FAIL observer empty response changed valid-event state");
        errors = errors + 1;
      end

      // Fault response clears pending and sets sticky fault without counting.
      unit_poc_req = 1'b1;
      @(posedge clk);
      @(negedge clk);
      unit_poc_req = 1'b0;
      unit_poc_valid = 1'b1;
      unit_poc_ready = 1'b1;
      unit_poc_fault = 1'b1;
      @(posedge clk);
      @(negedge clk);
      unit_poc_valid = 1'b0;
      unit_poc_ready = 1'b0;
      unit_poc_fault = 1'b0;
      if (unit_poc_pending || !unit_poc_fault_sticky ||
          unit_poc_count != 0) begin
        $display("FAIL observer fault clear/sticky/count contract");
        errors = errors + 1;
      end

      // Reset while a response is pending must discard the token.
      unit_dmem_req = 1'b1;
      @(posedge clk);
      @(negedge clk);
      unit_dmem_req = 1'b0;
      if (!unit_dmem_pending) begin
        $display("FAIL observer dmem pending was not established");
        errors = errors + 1;
      end
      unit_rst_n = 1'b0;
      #1;
      if (unit_dmem_pending || unit_dmem_count != 0) begin
        $display("FAIL observer reset did not clear dmem pending");
        errors = errors + 1;
      end
      unit_rst_n = 1'b1;
      unit_tx_valid = 1'b1;
      unit_tx_char = 8'h5a;
      @(posedge clk);
      @(negedge clk);
      unit_tx_valid = 1'b0;
      if (unit_tx_count != 16'd1 || !unit_tx_seen ||
          unit_tx_last_byte != 8'h5a) begin
        $display("FAIL observer TX accepted-write accounting");
        errors = errors + 1;
      end
    end
  endtask

  // In the generated Quartus DATA register, the controlled vendor model has
  // TX-not-full (bit13) and activity (bit10) asserted while the popped RX
  // FIFO is already empty (bit12=0).  Thus the full registered word is
  // 0x0000_A400 | byte; keep all 32 bits in the equality check.
  task automatic wait_payload(input logic [7:0] value,
                              input logic [7:0] bridge_before,
                              input logic [7:0] poc_before,
                              input logic [7:0] dmem_before);
    integer cycles;
    logic [31:0] want;
    begin
      want = 32'h0000_A400 | value;
      for (cycles = 0;
           cycles < WAIT_CYCLES &&
           (dut.obs_dmem_rsp_data_q[15:0] != want[15:0]);
           cycles = cycles + 1)
        @(posedge clk);
      if (dut.obs_bridge_rsp_data_q !== want) begin
        $display("FAIL bridge payload byte=%02h got=%08h want=%08h",
                 value, dut.obs_bridge_rsp_data_q, want);
        errors = errors + 1;
      end
      if (dut.obs_poc_rsp_data_q !== want) begin
        $display("FAIL poc payload byte=%02h got=%08h want=%08h",
                 value, dut.obs_poc_rsp_data_q, want);
        errors = errors + 1;
      end
      if (dut.obs_dmem_rsp_data_q !== want) begin
        $display("FAIL dmem payload byte=%02h got=%08h want=%08h",
                 value, dut.obs_dmem_rsp_data_q, want);
        errors = errors + 1;
      end
      if (dut.obs_bridge_count_q != bridge_before + 8'd1 ||
          dut.obs_poc_count_q != poc_before + 8'd1 ||
          dut.obs_dmem_count_q != dmem_before + 8'd1) begin
        $display("FAIL valid-event count delta byte=%02h before=%02h/%02h/%02h after=%02h/%02h/%02h",
                 value, bridge_before, poc_before, dmem_before,
                 dut.obs_bridge_count_q, dut.obs_poc_count_q,
                 dut.obs_dmem_count_q);
        errors = errors + 1;
      end
      if (dut.obs_bridge_fault_q || dut.obs_poc_fault_q ||
          dut.obs_dmem_fault_q) begin
        $display("FAIL sticky fault byte=%02h bridge=%0b poc=%0b dmem=%0b",
                 value, dut.obs_bridge_fault_q, dut.obs_poc_fault_q,
                 dut.obs_dmem_fault_q);
        errors = errors + 1;
      end
      checks = checks + 1;
    end
  endtask

  initial begin
    errors = 0;
    checks = 0;
    observation_unit_contract();
    rst_n = 1'b0;
    emif_rst_n = 1'b0;
    repeat (8) @(posedge clk);
    emif_rst_n = 1'b1;
    @(posedge clk);
    rst_n = 1'b1;

    // Let the resident monitor exercise the real registered DATA-read path.
    // The timeout is bounded so a boot/clock failure cannot hang the test.
    empty_wait_cycles = 0;
    while (ju_data_read_count < EMPTY_POLLS &&
           empty_wait_cycles < EMPTY_POLL_TIMEOUT) begin
      @(posedge clk);
      empty_wait_cycles = empty_wait_cycles + 1;
    end
    if (ju_data_read_count < EMPTY_POLLS) begin
      $display("FAIL bounded empty-poll timeout reads=%0d target=%0d cycles=%0d",
               ju_data_read_count, EMPTY_POLLS, empty_wait_cycles);
      errors = errors + 1;
    end
    if (dut.obs_bridge_count_q != 0 || dut.obs_poc_count_q != 0 ||
        dut.obs_dmem_count_q != 0) begin
      $display("FAIL empty polling created valid-event counts bridge=%0d poc=%0d dmem=%0d",
               dut.obs_bridge_count_q, dut.obs_poc_count_q,
               dut.obs_dmem_count_q);
      errors = errors + 1;
    end

    for (i = 0; i < 4; i = i + 1) begin
      bridge_count_before = dut.obs_bridge_count_q;
      poc_count_before = dut.obs_poc_count_q;
      dmem_count_before = dut.obs_dmem_count_q;
      case (i)
        0: inject_rx(8'h3f); // ?
        1: inject_rx(8'h70); // p
        2: inject_rx(8'h64); // d
        default: inject_rx(8'h5a); // Z
      endcase
      case (i)
        0: wait_payload(8'h3f, bridge_count_before,
                         poc_count_before, dmem_count_before);
        1: wait_payload(8'h70, bridge_count_before,
                         poc_count_before, dmem_count_before);
        2: wait_payload(8'h64, bridge_count_before,
                         poc_count_before, dmem_count_before);
        default: wait_payload(8'h5a, bridge_count_before,
                               poc_count_before, dmem_count_before);
      endcase
    end

    if (dut.obs_bridge_count_q != dut.obs_poc_count_q ||
        dut.obs_poc_count_q != dut.obs_dmem_count_q) begin
      $display("FAIL count mismatch bridge=%0d poc=%0d dmem=%0d",
               dut.obs_bridge_count_q, dut.obs_poc_count_q,
               dut.obs_dmem_count_q);
      errors = errors + 1;
    end
    if (dut.obs_tx_count_q == 0 && ju_tx_event_count == 0) begin
      $display("FAIL no accepted TX observation");
      errors = errors + 1;
    end
    if (errors == 0)
      $display("RX_RESPONSE_TRACE PASS checks=%0d bridge=%0d poc=%0d dmem=%0d",
               checks, dut.obs_bridge_count_q, dut.obs_poc_count_q,
               dut.obs_dmem_count_q);
    else
      $fatal(1, "RX_RESPONSE_TRACE FAIL errors=%0d", errors);
    $finish;
  end
endmodule
