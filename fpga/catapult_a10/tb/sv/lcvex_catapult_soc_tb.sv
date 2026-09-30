// lcvex_catapult_soc_tb.sv
// B25 bring-up: Catapult A10 resident-monitor system smoke.
//
// 三个定向用例：calibration OK、WAIT 和 FAIL。CPU 始终从同源 64 KiB
// BRAM image 启动并驻留其中；OK 路径必须产生真实 DDR adapter read/write，
// 所有路径必须进入 READY，并通过轮询 JTAG-UART 完成 PONG 和字符回显。
//
// 顶层使用轻量 Avalon EMIF/JTAG-UART/EPCQ 模型；不依赖仿真专用 C++ MMIO。

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off PINMISSING */
/* verilator lint_off WIDTHEXPAND */

module lcvex_catapult_soc_tb #(
    parameter bit LINUX_BOOT_TEST = 1'b0,
    parameter logic A64_FP_SIMD = LINUX_BOOT_TEST ? 1'b0 : 1'b1,
    parameter bit JTAG_VENDOR_TIMING = 1'b0,
    parameter string BOOT_HEX_FILE = "fpga/catapult_a10/boot/build/boot.hex",
    parameter string FLASH_WORDS_MEMH = "",
    parameter logic [63:0] FLASH_PAYLOAD_OFFSET = 64'h0400_0000,
    parameter int FLASH_LINE_CAPACITY = LINUX_BOOT_TEST ? 93_750 : 1,
    parameter int DDR_MODEL_DEPTH_WORDS = LINUX_BOOT_TEST ? (1 << 21) : (1 << 14),
    parameter int LINUX_JTAG_LOG_BYTES = LINUX_BOOT_TEST ? (1 << 20) : 1024,
    parameter int LINUX_BOOT_TIMEOUT_CYCLES = 250_000_000
);

  localparam int RUN_CYCLES_STARTUP = 120000;
  localparam int RUN_CYCLES_COMMAND = 60000;
  localparam int RUN_CYCLES_MICROBENCH = 1000000;
  localparam int RUN_CYCLES_COREMARK_SELF = 24000000;
  localparam int COREMARK_HOST_DRAIN_PERIOD = 65536;
  localparam int LONG_EMPTY_POLLS = 262144;
  localparam int RUN_CYCLES_LONG_POLL = LONG_EMPTY_POLLS * 256;
  localparam int CAL_MODE_WAIT = 0;
  localparam int CAL_MODE_OK   = 1;
  localparam int CAL_MODE_FAIL = 2;
  localparam logic [63:0] PRINTK_TAIL_DESC_PA = 64'h0000_0000_4064_f938;
  localparam logic [63:0] PRINTK_TAIL_LINE_PA = PRINTK_TAIL_DESC_PA & ~64'h3f;
  localparam logic [24:0] PRINTK_TAIL_EMIF_WORD = 25'h001_93e4;
  localparam logic [63:0] PRINTK_NUL_LINE_PA = 64'h0000_0000_4066_ff40;
  localparam logic [24:0] PRINTK_NUL_EMIF_WORD =
      (PRINTK_NUL_LINE_PA - 64'h4000_0000) >> 6;
  localparam logic [63:0] PRINTK_COPY_SOURCE_LINE_PA = 64'h0000_0000_4067_0b40;
  localparam int DMEM_TRACE_DEPTH = 256;

  logic clk = 0;
  logic emif_clk = 0;
  always #20 clk = ~clk;        // B25 logic clock: 25 MHz
  always #1.875 emif_clk = ~emif_clk; // EMIF user model: 266.667 MHz

  logic rst_n;
  logic emif_rst_n;
  logic emif_cal_success;
  logic emif_cal_fail;
  logic cal_ready;
  logic cal_failed;

  logic        avalon_read;
  logic        avalon_write;
  logic [24:0] avalon_address;
  logic [511:0] avalon_writedata;
  logic [6:0]  avalon_burstcount;
  logic [63:0] avalon_byteenable;
  logic        avalon_waitrequest_n;
  logic [511:0] avalon_readdata;
  logic        avalon_readdatavalid;

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
  logic        epcq_csr_waitrequest;
  logic [31:0] epcq_csr_readdata;
  logic        epcq_csr_readdatavalid;
  logic        epcq_mem_read;
  logic [24:0] epcq_mem_address;
  logic [6:0]  epcq_mem_burstcount;
  logic [3:0]  epcq_mem_byteenable;
  logic        epcq_mem_waitrequest;
  logic [31:0] epcq_mem_readdata;
  logic        epcq_mem_readdatavalid;

  logic        prog_we;
  logic [63:0] prog_addr;
  logic [7:0]  prog_strb;
  logic [63:0] prog_wdata;
  logic [31:0] dbg_addr;
  logic [63:0] dbg_rdata;

  logic        checkpoint_quiesce;
  logic        checkpoint_ack_valid;
  logic        checkpoint_ack_ready;
  logic        checkpoint_fault;
  logic        l1_drain_done;
  logic        l1_drain_fault;
  logic        l2_drain_ack_valid;
  logic        l2_drain_fault;

  logic        commit_valid;
  logic [63:0] commit_pc;
  logic [63:0] commit_next_pc;
  logic [31:0] commit_insn;
  logic        commit_gpr_we;
  logic [4:0]  commit_gpr_rd;
  logic [63:0] commit_gpr_wdata;
  logic        commit_exc_valid;
  logic [31:0] commit_exc_code;
  logic [31:0] commit_exc_esr;
  logic [63:0] commit_exc_far;
  logic        jtag_uart_tx_valid;
  logic [7:0]  jtag_uart_tx_char;
  logic [31:0] soc_ddr_read_count;
  logic [31:0] soc_ddr_write_count;
  logic        timer_phys_irq;
  logic        timer_virt_irq;
  logic        tlb_invalidate;
  logic        dbg_dmem_req_valid;
  logic        dbg_dmem_req_ready;
  logic [63:0] dbg_dmem_req_addr;
  logic        dbg_dmem_req_we;
  logic [63:0] dbg_dmem_req_wdata;
  logic        dbg_dmem_rsp_valid;
  logic        dbg_poc_req_valid;
  logic [63:0] dbg_poc_req_addr;
  logic        dbg_poc_req_we;
  logic        dbg_ddr_req_valid;
  logic        dbg_ddr_req_ready;
  logic        dbg_ddr_req_write;
  logic [63:0] dbg_ddr_req_addr;
  logic        dbg_ddr_u_req_valid;
  logic        dbg_ddr_u_req_we;
  logic        dbg_ddr_u_req_accept;
  logic [2:0]  dbg_bridge_state;
  logic        dbg_bridge_req_write_q;
  logic        dbg_ddr_rsp_valid;
  logic        dbg_axi_awvalid;
  logic        dbg_axi_awready;
  logic        dbg_axi_wvalid;
  logic        dbg_axi_wready;
  logic        dbg_axi_bvalid;
  logic        dbg_axi_bready;
  logic        dbg_axi_arvalid;
  logic        dbg_axi_arready;
  logic        dbg_axi_rvalid;
  logic        dbg_axi_rready;
  logic        dbg_avalon_read;
  logic        dbg_avalon_write;
  logic        dbg_avalon_readdatavalid;
  logic        dbg_avalon_waitrequest_n;
  logic        dbg_l1_u_req_we;
  logic [63:0] dbg_l1_u_req_addr;
  logic        dbg_l1_u_req_bypass;
  logic [63:0] dbg_l1_u_req_wdata;
  logic        dbg_arb_req0_we;
  logic        dbg_arb_req0_bypass;
  logic [63:0] dbg_arb_req0_wdata;
  logic        dbg_l2_u_req_we;
  logic [63:0] dbg_l2_u_req_addr;
  logic        dbg_l2_u_req_bypass;
  logic [63:0] dbg_l2_u_req_wdata;
  logic [63:0] dbg_ju_req_wdata;

  logic        emif_ld_we;
  logic [31:0] emif_ld_addr;
  logic [7:0]  emif_ld_data;

  lcvex_catapult_soc_top #(
      .BRAM_BYTES(1 << 16), .L1_SETS(64), .L2_SETS(64), .L2_WAYS(1),
      .A64_FP_SIMD(A64_FP_SIMD),
      .TIMER_REALTIME(LINUX_BOOT_TEST),
      .CNTFRQ_HZ(lcvex_catapult_soc_pkg::SOC_TIMER_HZ),
      .BOOT_HEX_FILE(BOOT_HEX_FILE)
  ) dut (
      .clk(clk), .rst_n(rst_n),
      .emif_clk(emif_clk), .emif_rst_n(emif_rst_n),
      .emif_cal_success(emif_cal_success), .emif_cal_fail(emif_cal_fail),
      .cal_ready(cal_ready), .cal_failed(cal_failed),
      .avalon_read(avalon_read), .avalon_write(avalon_write),
      .avalon_address(avalon_address),
      .avalon_writedata(avalon_writedata),
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
      .epcq_mem_read(epcq_mem_read), .epcq_mem_address(epcq_mem_address),
      .epcq_mem_burstcount(epcq_mem_burstcount),
      .epcq_mem_byteenable(epcq_mem_byteenable),
      .epcq_mem_waitrequest(epcq_mem_waitrequest),
      .epcq_mem_readdata(epcq_mem_readdata),
      .epcq_mem_readdatavalid(epcq_mem_readdatavalid),
      .prog_we(prog_we), .prog_addr(prog_addr),
      .prog_strb(prog_strb), .prog_wdata(prog_wdata),
      .dbg_addr(dbg_addr), .dbg_rdata(dbg_rdata),
      .checkpoint_quiesce(checkpoint_quiesce),
      .checkpoint_ack_valid(checkpoint_ack_valid),
      .checkpoint_ack_ready(checkpoint_ack_ready),
      .checkpoint_fault(checkpoint_fault),
      .l1_drain_done(l1_drain_done), .l1_drain_fault(l1_drain_fault),
      .l2_drain_ack_valid(l2_drain_ack_valid),
      .l2_drain_fault(l2_drain_fault),
      .commit_valid(commit_valid), .commit_pc(commit_pc),
      .commit_next_pc(commit_next_pc), .commit_insn(commit_insn),
      .commit_gpr_we(commit_gpr_we), .commit_gpr_rd(commit_gpr_rd),
      .commit_gpr_wdata(commit_gpr_wdata),
      .commit_exc_valid(commit_exc_valid),
      .commit_exc_code(commit_exc_code),
      .commit_exc_esr(commit_exc_esr),
      .commit_exc_far(commit_exc_far),
      .jtag_uart_tx_valid(jtag_uart_tx_valid),
      .jtag_uart_tx_char(jtag_uart_tx_char),
      .soc_ddr_read_count(soc_ddr_read_count),
      .soc_ddr_write_count(soc_ddr_write_count),
      .timer_phys_irq(timer_phys_irq), .timer_virt_irq(timer_virt_irq),
      .tlb_invalidate(tlb_invalidate),
      .dbg_dmem_req_valid(dbg_dmem_req_valid),
      .dbg_dmem_req_ready(dbg_dmem_req_ready),
      .dbg_dmem_req_addr(dbg_dmem_req_addr),
      .dbg_dmem_req_we(dbg_dmem_req_we),
      .dbg_dmem_req_wdata(dbg_dmem_req_wdata),
      .dbg_dmem_rsp_valid(dbg_dmem_rsp_valid),
      .dbg_poc_req_valid(dbg_poc_req_valid),
      .dbg_poc_req_addr(dbg_poc_req_addr),
      .dbg_poc_req_we(dbg_poc_req_we),
      .dbg_ddr_req_valid(dbg_ddr_req_valid),
      .dbg_ddr_req_ready(dbg_ddr_req_ready),
      .dbg_ddr_req_write(dbg_ddr_req_write),
      .dbg_ddr_req_addr(dbg_ddr_req_addr),
      .dbg_ddr_u_req_valid(dbg_ddr_u_req_valid),
      .dbg_ddr_u_req_we(dbg_ddr_u_req_we),
      .dbg_ddr_u_req_accept(dbg_ddr_u_req_accept),
      .dbg_bridge_state(dbg_bridge_state),
      .dbg_bridge_req_write_q(dbg_bridge_req_write_q),
      .dbg_ddr_rsp_valid(dbg_ddr_rsp_valid),
      .dbg_axi_awvalid(dbg_axi_awvalid),
      .dbg_axi_awready(dbg_axi_awready),
      .dbg_axi_wvalid(dbg_axi_wvalid),
      .dbg_axi_wready(dbg_axi_wready),
      .dbg_axi_bvalid(dbg_axi_bvalid),
      .dbg_axi_bready(dbg_axi_bready),
      .dbg_axi_arvalid(dbg_axi_arvalid),
      .dbg_axi_arready(dbg_axi_arready),
      .dbg_axi_rvalid(dbg_axi_rvalid),
      .dbg_axi_rready(dbg_axi_rready),
      .dbg_avalon_read(dbg_avalon_read),
      .dbg_avalon_write(dbg_avalon_write),
      .dbg_avalon_readdatavalid(dbg_avalon_readdatavalid),
      .dbg_avalon_waitrequest_n(dbg_avalon_waitrequest_n),
      .dbg_l1_u_req_we(dbg_l1_u_req_we),
      .dbg_l1_u_req_addr(dbg_l1_u_req_addr),
      .dbg_l1_u_req_bypass(dbg_l1_u_req_bypass),
      .dbg_l1_u_req_wdata(dbg_l1_u_req_wdata),
      .dbg_arb_req0_we(dbg_arb_req0_we),
      .dbg_arb_req0_bypass(dbg_arb_req0_bypass),
      .dbg_arb_req0_wdata(dbg_arb_req0_wdata),
      .dbg_l2_u_req_we(dbg_l2_u_req_we),
      .dbg_l2_u_req_addr(dbg_l2_u_req_addr),
      .dbg_l2_u_req_bypass(dbg_l2_u_req_bypass),
      .dbg_l2_u_req_wdata(dbg_l2_u_req_wdata),
      .dbg_ju_req_wdata(dbg_ju_req_wdata)
  );

  lcvex_emif_smoke #(
      .DEPTH_WORDS(DDR_MODEL_DEPTH_WORDS),
      .INITIALIZE_ZERO(!LINUX_BOOT_TEST)
  ) emif_model (
      .clk(emif_clk), .rst_n(emif_rst_n),
      .read(avalon_read), .write(avalon_write),
      .address(avalon_address), .writedata(avalon_writedata),
      .burstcount(avalon_burstcount), .byteenable(avalon_byteenable),
      .waitrequest_n(avalon_waitrequest_n),
      .readdata(avalon_readdata),
      .readdatavalid(avalon_readdatavalid),
      .ld_we(emif_ld_we), .ld_addr(emif_ld_addr), .ld_data(emif_ld_data)
  );

  logic        ju_rx_valid;
  logic [7:0]  ju_rx_char;
  logic        ju_rx_ready;
  logic        ju_tx_pop;
  logic        ju_force_waitrequest;
  logic        ju_host_activity;
  logic [31:0] ju_avalon_read_count;
  logic [31:0] ju_avalon_write_count;
  logic [31:0] ju_data_read_count;
  logic [31:0] ju_control_read_count;
  logic [31:0] ju_data_write_count;
  logic [31:0] ju_control_write_count;
  logic [31:0] ju_rx_pop_count;
  logic [31:0] ju_tx_push_count;
  logic [15:0] ju_tx_wspace;
  logic [31:0] ju_tx_event_count;
  logic [7:0]  ju_tx_event_char;
  logic        ju_tx_event_valid;
  logic        ju_tx_drain_valid;
  logic [7:0]  ju_tx_drain_char;

  generate
    if (JTAG_VENDOR_TIMING) begin : gen_vendor_jtag
      lcvex_jtag_uart_vendor_model #(
          .TX_DEPTH(64), .RX_DEPTH(64)
      ) jtag_model (
          .clk(clk), .rst_n(rst_n),
          .chipselect(ju_chipselect), .read_n(ju_read_n),
          .write_n(ju_write_n), .address(ju_address),
          .writedata(ju_writedata), .readdata(ju_readdata),
          .waitrequest(ju_waitrequest), .irq(ju_irq),
          .rx_valid(ju_rx_valid), .rx_char(ju_rx_char),
          .rx_ready(ju_rx_ready), .tx_pop(ju_tx_pop),
          .force_waitrequest(ju_force_waitrequest),
          .host_activity(ju_host_activity),
          .avalon_read_count(ju_avalon_read_count),
          .avalon_write_count(ju_avalon_write_count),
          .data_read_count(ju_data_read_count),
          .control_read_count(ju_control_read_count),
          .data_write_count(ju_data_write_count),
          .control_write_count(ju_control_write_count),
          .rx_pop_count(ju_rx_pop_count), .tx_push_count(ju_tx_push_count),
          .tx_wspace(ju_tx_wspace), .tx_event_count(ju_tx_event_count),
          .tx_event_char(ju_tx_event_char),
          .tx_event_valid(ju_tx_event_valid),
          .tx_drain_valid(ju_tx_drain_valid),
          .tx_drain_char(ju_tx_drain_char)
      );
    end else begin : gen_behavioral_jtag
      lcvex_jtag_uart_model #(
          .TX_DEPTH(64), .RX_DEPTH(16)
      ) jtag_model (
          .clk(clk), .rst_n(rst_n),
          .chipselect(ju_chipselect), .read_n(ju_read_n),
          .write_n(ju_write_n), .address(ju_address),
          .writedata(ju_writedata), .readdata(ju_readdata),
          .waitrequest(ju_waitrequest), .irq(ju_irq),
          .rx_valid(ju_rx_valid), .rx_char(ju_rx_char),
          .rx_ready(ju_rx_ready), .tx_pop(ju_tx_pop),
          .force_waitrequest(ju_force_waitrequest),
          .host_activity(ju_host_activity),
          .avalon_read_count(ju_avalon_read_count),
          .avalon_write_count(ju_avalon_write_count),
          .data_read_count(ju_data_read_count),
          .control_read_count(ju_control_read_count),
          .data_write_count(ju_data_write_count),
          .control_write_count(ju_control_write_count),
          .rx_pop_count(ju_rx_pop_count), .tx_push_count(ju_tx_push_count),
          .tx_wspace(ju_tx_wspace), .tx_event_count(ju_tx_event_count),
          .tx_event_char(ju_tx_event_char),
          .tx_event_valid(ju_tx_event_valid),
          .tx_drain_valid(ju_tx_drain_valid),
          .tx_drain_char(ju_tx_drain_char)
      );
    end
  endgenerate

  lcvex_epcq_csr_smoke epcq_model (
      .clk(clk), .rst_n(rst_n),
      .read(epcq_csr_read), .write(epcq_csr_write),
      .address(epcq_csr_address), .writedata(epcq_csr_writedata),
      .readdata(epcq_csr_readdata), .waitrequest(epcq_csr_waitrequest),
      .readdatavalid(epcq_csr_readdatavalid)
  );

  bit [511:0] flash_lines [0:FLASH_LINE_CAPACITY-1];
  string flash_words_file;
  logic epcq_pending_q;
  logic [24:0] epcq_address_q;
  logic [1:0] epcq_delay_q;

  function automatic logic [31:0] flash_word(input logic [24:0] word_address);
    logic [63:0] physical_byte_address;
    logic [63:0] relative_byte_address;
    logic [63:0] relative_line_address;
    integer relative_index;
    integer word_index;
    begin
      physical_byte_address = 64'(word_address) << 2;
      relative_byte_address = physical_byte_address - FLASH_PAYLOAD_OFFSET;
      relative_line_address = relative_byte_address >> 6;
      if ((physical_byte_address >= FLASH_PAYLOAD_OFFSET) &&
          (relative_line_address < 64'(FLASH_LINE_CAPACITY))) begin
        relative_index = int'(relative_line_address);
        word_index = int'(relative_byte_address[5:2]);
        flash_word = flash_lines[relative_index][word_index*32 +: 32];
      end else begin
        flash_word = 32'd0;
      end
    end
  endfunction

  initial begin
    flash_words_file = FLASH_WORDS_MEMH;
    if ($value$plusargs("FLASH_WORDS_MEMH=%s", flash_words_file)) begin
      // Runtime override permits isolated software candidates to use their
      // own payload without changing the shared testbench build parameters.
    end
    if (LINUX_BOOT_TEST) begin
      if (flash_words_file == "") $fatal(1, "Linux boot simulation requires FLASH_WORDS_MEMH");
      $readmemh(flash_words_file, flash_lines);
      $display("LINUX_FLASH_MODEL 512b_lines=%0d payload_offset=%016h file=%s",
               FLASH_LINE_CAPACITY, FLASH_PAYLOAD_OFFSET, flash_words_file);
    end
  end

  assign epcq_mem_waitrequest = 1'b0;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      epcq_pending_q <= 1'b0;
      epcq_address_q <= 25'd0;
      epcq_delay_q <= 2'd0;
      epcq_mem_readdata <= 32'd0;
      epcq_mem_readdatavalid <= 1'b0;
    end else begin
      epcq_mem_readdatavalid <= 1'b0;
      if (epcq_pending_q) begin
        if (epcq_delay_q == 0) begin
          epcq_mem_readdata <= flash_word(epcq_address_q);
          epcq_mem_readdatavalid <= 1'b1;
          epcq_pending_q <= 1'b0;
        end else begin
          epcq_delay_q <= epcq_delay_q - 2'd1;
        end
      end
      if (epcq_mem_read && !epcq_mem_waitrequest) begin
        if (epcq_pending_q) $fatal(1, "overlapping EPCQ memory reads");
        if (epcq_mem_burstcount != 7'd1 || epcq_mem_byteenable != 4'hf)
          $fatal(1, "EPCQ reader must issue one full 32-bit word");
        epcq_pending_q <= 1'b1;
        epcq_address_q <= epcq_mem_address;
        epcq_delay_q <= 2'd1;
      end
    end
  end

  // The same generated byte HEX used to create boot.mif is loaded by the
  // lcvex_bram_boot parameter above.  No legacy DDR trampoline is injected.
  task automatic reset_dut(input integer cal_mode);
    begin
      rst_n = 1'b0;
      emif_rst_n = 1'b0;
      emif_cal_success = (cal_mode == CAL_MODE_OK);
      emif_cal_fail = (cal_mode == CAL_MODE_FAIL);
      cal_ready = (cal_mode == CAL_MODE_OK);
      cal_failed = (cal_mode == CAL_MODE_FAIL);
      checkpoint_quiesce = 1'b0;
      checkpoint_ack_ready = 1'b0;
      dbg_addr = 32'd0;
      prog_we = 1'b0;
      prog_addr = 64'd0;
      prog_strb = 8'd0;
      prog_wdata = 64'd0;
      emif_ld_we = 1'b0;
      emif_ld_addr = 32'd0;
      emif_ld_data = 8'd0;
      ju_rx_valid = 1'b0;
      ju_rx_char = 8'd0;
      ju_tx_pop = 1'b1;
      ju_force_waitrequest = 1'b0;
      ju_host_activity = 1'b1;
      repeat (8) @(posedge clk);
      emif_rst_n = 1'b1;
      @(posedge clk);
      rst_n = 1'b1;
    end
  endtask

  // ---------------- 观测 ----------------
  integer errors;
  integer jtag_count;
  byte unsigned jtag_chars[0:LINUX_JTAG_LOG_BYTES-1];
  logic pc_outside_bram;
  logic commit_exception_seen;
  logic first_commit_exception_valid;
  logic [63:0] first_commit_exception_pc;
  logic [31:0] first_commit_exception_code;
  logic [31:0] first_commit_exception_esr;
  logic [63:0] first_commit_exception_far;
  logic commit_unknown_seen;
  logic first_commit_seen;
  logic first_commit_wrong;
  logic jtag_event_mismatch;
  logic ju_tx_event_valid_q;
  logic [7:0] ju_tx_event_char_q;
  logic ddr_activity_seen;
  integer bridge_tx_pulse_count;
  integer emif_read_fire_count;
  integer emif_write_fire_count;
  integer commit_count;
  integer linux_el0_commit_count;
  integer linux_el0_trace_count;
  logic   linux_first_el0_valid;
  logic [63:0] linux_first_el0_pc;
  logic [63:0] last_commit_pc;
  logic [63:0] last_commit_next_pc;
  logic [63:0] recent_commit_pc[0:15];
  logic [31:0] recent_commit_insn[0:15];
  logic        recent_commit_gpr_we[0:15];
  logic [4:0]  recent_commit_gpr_rd[0:15];
  logic [63:0] recent_commit_gpr_wdata[0:15];
  integer recent_commit_index;
  logic first_nul_valid_q;
  integer first_nul_index_q;
  logic [7:0] first_nul_char_q;
  logic [63:0] first_nul_commit_pc_q;
  logic [63:0] first_nul_commit_next_pc_q;
  logic [63:0] first_nul_dmem_addr_q;
  logic [63:0] first_nul_dmem_wdata_q;
  logic [63:0] first_nul_dmem_rsp_q;
  logic first_nul_dmem_we_q;
  logic first_nul_dmem_bypass_q;
  logic [63:0] last_dmem_addr_q;
  logic [63:0] last_dmem_wdata_q;
  logic        last_dmem_we_q;
  logic        last_dmem_bypass_q;
  logic [63:0] last_dmem_rsp_data_q;
  integer printk_line_core_store_count;
  integer printk_line_poc_store_count;
  integer printk_line_avalon_store_count;
  logic [63:0] last_l1_req_addr_q;
  logic        last_l1_req_bypass_q;
  logic [63:0] last_l1_down_addr_q;
  logic        last_l1_down_bypass_q;
  logic [63:0] last_poc_req_addr_q;
  logic        last_poc_req_bypass_q;
  logic        target_axi_active_q;
  logic        target_axi_seen_q;
  logic [127:0] target_axi_last_rdata_q;
  logic [24:0] emif_read_addr_q;
  logic        target_avalon_seen_q;
  logic [511:0] target_avalon_data_q;
  logic        dmem_trace_pending_q;
  logic [63:0] dmem_trace_pending_addr_q;
  logic [63:0] dmem_trace_pending_wdata_q;
  logic        dmem_trace_pending_we_q;
  logic        dmem_trace_pending_bypass_q;
  logic [63:0] dmem_trace_pa[0:DMEM_TRACE_DEPTH-1];
  logic [63:0] dmem_trace_wdata[0:DMEM_TRACE_DEPTH-1];
  logic [63:0] dmem_trace_data[0:DMEM_TRACE_DEPTH-1];
  logic        dmem_trace_we[0:DMEM_TRACE_DEPTH-1];
  logic        dmem_trace_bypass[0:DMEM_TRACE_DEPTH-1];
  integer      dmem_trace_index;
  integer      target_dmem_rsp_count;
  logic [63:0] target_dmem_rsp_data_q;
  integer      ptw_req_count_q;
  integer      ptw_rsp_count_q;
  logic [63:0] last_ptw_req_addr_q;
  logic        last_ptw_req_we_q;
  logic [63:0] last_ptw_rsp_data_q;
  logic        last_ptw_rsp_fault_q;
  logic        linux_gic_pending_read_q;
  logic [63:0] linux_gic_pending_addr_q;
  logic [63:0] linux_last_gic_read_addr_q;
  logic [31:0] linux_last_gic_read_data_q;
  integer      linux_gicd_ctlr_read_count;
  integer      linux_gicc_ctlr_read_count;
  integer      linux_gicd_rwp_busy_count;
  integer      linux_gicr_rwp_busy_count;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      dmem_trace_pending_q <= 1'b0;
      dmem_trace_pending_addr_q <= 64'd0;
      dmem_trace_pending_wdata_q <= 64'd0;
      dmem_trace_pending_we_q <= 1'b0;
      dmem_trace_pending_bypass_q <= 1'b0;
      dmem_trace_index <= 0;
      target_dmem_rsp_count <= 0;
      target_dmem_rsp_data_q <= 64'd0;
      ptw_req_count_q <= 0;
      ptw_rsp_count_q <= 0;
      last_ptw_req_addr_q <= 64'd0;
      last_ptw_req_we_q <= 1'b0;
      last_ptw_rsp_data_q <= 64'd0;
      last_ptw_rsp_fault_q <= 1'b0;
      for (int trace_reset = 0; trace_reset < DMEM_TRACE_DEPTH; trace_reset++) begin
        dmem_trace_pa[trace_reset] <= 64'd0;
        dmem_trace_wdata[trace_reset] <= 64'd0;
        dmem_trace_data[trace_reset] <= 64'd0;
        dmem_trace_we[trace_reset] <= 1'b0;
        dmem_trace_bypass[trace_reset] <= 1'b0;
      end
    end else begin
      if (dbg_dmem_req_valid && dbg_dmem_req_ready) begin
        dmem_trace_pending_q <= 1'b1;
        dmem_trace_pending_addr_q <= dbg_dmem_req_addr;
        dmem_trace_pending_wdata_q <= dbg_dmem_req_wdata;
        dmem_trace_pending_we_q <= dbg_dmem_req_we;
        dmem_trace_pending_bypass_q <= dut.dmem_req.bypass;
      end
      if (dbg_dmem_rsp_valid && dut.dmem_rsp_ready &&
          dmem_trace_pending_q) begin
        dmem_trace_pa[dmem_trace_index] <= dmem_trace_pending_addr_q;
        dmem_trace_wdata[dmem_trace_index] <= dmem_trace_pending_wdata_q;
        dmem_trace_data[dmem_trace_index] <= dut.dmem_rsp.rdata;
        dmem_trace_we[dmem_trace_index] <= dmem_trace_pending_we_q;
        dmem_trace_bypass[dmem_trace_index] <= dmem_trace_pending_bypass_q;
        dmem_trace_index <= (dmem_trace_index + 1) % DMEM_TRACE_DEPTH;
        dmem_trace_pending_q <= 1'b0;
        if (dmem_trace_pending_addr_q == PRINTK_TAIL_DESC_PA) begin
          target_dmem_rsp_count <= target_dmem_rsp_count + 1;
          target_dmem_rsp_data_q <= dut.dmem_rsp.rdata;
        end
      end
      if (dut.ptw_req_valid && dut.ptw_req_ready) begin
        ptw_req_count_q <= ptw_req_count_q + 1;
        last_ptw_req_addr_q <= dut.ptw_req.addr;
        last_ptw_req_we_q <= dut.ptw_req.we;
      end
      if (dut.ptw_rsp_valid && dut.ptw_rsp_ready) begin
        ptw_rsp_count_q <= ptw_rsp_count_q + 1;
        last_ptw_rsp_data_q <= dut.ptw_rsp.rdata;
        last_ptw_rsp_fault_q <= dut.ptw_rsp.fault;
      end
    end
  end

  // Capture the live interrupt-controller control reads. A Linux RWP poll
  // can otherwise look like a generic WFIT/udelay loop in the commit trace.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      linux_gic_pending_read_q <= 1'b0;
      linux_gic_pending_addr_q <= 64'd0;
      linux_last_gic_read_addr_q <= 64'd0;
      linux_last_gic_read_data_q <= 32'd0;
      linux_gicd_ctlr_read_count <= 0;
      linux_gicc_ctlr_read_count <= 0;
      linux_gicd_rwp_busy_count <= 0;
      linux_gicr_rwp_busy_count <= 0;
    end else begin
      if (dut.gic_req_valid && dut.gic_req_accept) begin
        linux_gic_pending_read_q <= !dut.gic_req.we;
        linux_gic_pending_addr_q <= dut.gic_req.addr;
      end
      if (dut.gic_rsp_valid && dut.gic_rsp_ready &&
          linux_gic_pending_read_q) begin
        linux_last_gic_read_addr_q <= linux_gic_pending_addr_q;
        linux_last_gic_read_data_q <= dut.gic_rsp.rdata[31:0];
        linux_gic_pending_read_q <= 1'b0;
        if (linux_gic_pending_addr_q == 64'h0800_0000) begin
          linux_gicd_ctlr_read_count <= linux_gicd_ctlr_read_count + 1;
          if (dut.gic_rsp.rdata[31])
            linux_gicd_rwp_busy_count <= linux_gicd_rwp_busy_count + 1;
        end
        if (linux_gic_pending_addr_q == 64'h0801_0000) begin
          linux_gicc_ctlr_read_count <= linux_gicc_ctlr_read_count + 1;
          if (dut.gic_rsp.rdata[3])
            linux_gicr_rwp_busy_count <= linux_gicr_rwp_busy_count + 1;
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      last_dmem_addr_q <= 64'd0;
      last_dmem_wdata_q <= 64'd0;
      last_dmem_we_q <= 1'b0;
      last_dmem_bypass_q <= 1'b0;
      last_dmem_rsp_data_q <= 64'd0;
      last_l1_req_addr_q <= 64'd0;
      last_l1_req_bypass_q <= 1'b0;
      last_l1_down_addr_q <= 64'd0;
      last_l1_down_bypass_q <= 1'b0;
      last_poc_req_addr_q <= 64'd0;
      last_poc_req_bypass_q <= 1'b0;
      target_axi_active_q <= 1'b0;
      target_axi_seen_q <= 1'b0;
      target_axi_last_rdata_q <= 128'd0;
      printk_line_core_store_count <= 0;
      printk_line_poc_store_count <= 0;
    end else begin
      if (dbg_dmem_req_valid && dbg_dmem_req_ready) begin
        last_dmem_addr_q <= dbg_dmem_req_addr;
        last_dmem_wdata_q <= dbg_dmem_req_wdata;
        last_dmem_we_q <= dbg_dmem_req_we;
        last_dmem_bypass_q <= dut.dmem_req.bypass;
        if (dbg_dmem_req_we &&
            dbg_dmem_req_addr >= PRINTK_NUL_LINE_PA &&
            dbg_dmem_req_addr < PRINTK_NUL_LINE_PA + 64) begin
          printk_line_core_store_count <= printk_line_core_store_count + 1;
          if ($test$plusargs("LINUX_TRACE_CROSS_LINE"))
            $display("LINUX_PRINTK_LINE_CORE_STORE count=%0d pc=%016h insn=%08h valid=%b load=%b store=%b size=%0d exmem_va=%016h exmem_pa=%016h exmem_data=%016h pa=%016h strb=%02h wdata=%016h bypass=%b x0=%016h x1=%016h x2=%016h x4=%016h x5=%016h x6=%016h x7=%016h x8=%016h x9=%016h x10=%016h x11=%016h x12=%016h x13=%016h",
                     printk_line_core_store_count, dut.core.exmem_pc,
                     dut.core.exmem_insn, dut.core.exmem_valid,
                     dut.core.exmem_is_load, dut.core.exmem_is_store,
                     dut.core.exmem_mem_size, dut.core.exmem_mem_addr,
                     dut.core.exmem_mem_paddr, dut.core.exmem_mem_wdata,
                     dbg_dmem_req_addr, dut.dmem_req.strb,
                     dbg_dmem_req_wdata, dut.dmem_req.bypass,
                     dut.core.gpr[0], dut.core.gpr[1], dut.core.gpr[2],
                     dut.core.gpr[4], dut.core.gpr[5], dut.core.gpr[6],
                     dut.core.gpr[7], dut.core.gpr[8], dut.core.gpr[9],
                     dut.core.gpr[10], dut.core.gpr[11], dut.core.gpr[12],
                     dut.core.gpr[13]);
        end
      end
      if (dbg_dmem_rsp_valid && dut.dmem_rsp_ready)
        last_dmem_rsp_data_q <= dut.dmem_rsp.rdata;
      if (dut.coh.l1_u_req_valid && dut.coh.l1_u_req_ready) begin
        last_l1_req_addr_q <= dut.coh.l1_u_req.addr;
        last_l1_req_bypass_q <= dut.coh.l1_u_req.bypass;
      end
      if (dut.coh.l1_d_req_valid && dut.coh.l1_d_req_ready) begin
        last_l1_down_addr_q <= dut.coh.l1_d_req.addr;
        last_l1_down_bypass_q <= dut.coh.l1_d_req.bypass;
      end
      if (dut.poc_req_valid && dut.poc_req_ready) begin
        last_poc_req_addr_q <= dut.poc_req.addr;
        last_poc_req_bypass_q <= dut.poc_req.bypass;
        if (dut.poc_req.we && dut.poc_req.addr >= PRINTK_NUL_LINE_PA &&
            dut.poc_req.addr < PRINTK_NUL_LINE_PA + 64) begin
          printk_line_poc_store_count <= printk_line_poc_store_count + 1;
          if ($test$plusargs("LINUX_TRACE_CROSS_LINE"))
            $display("LINUX_PRINTK_LINE_POC_STORE count=%0d pa=%016h strb=%02h wdata=%016h",
                     printk_line_poc_store_count, dut.poc_req.addr,
                     dut.poc_req.strb, dut.poc_req.wdata);
        end
      end
      if (dut.a_req_valid && dut.a_req_ready && !dut.a_req_write &&
          (dut.a_req_addr == PRINTK_TAIL_LINE_PA)) begin
        target_axi_active_q <= 1'b1;
        target_axi_seen_q <= 1'b0;
      end
      if (dut.rvalid && dut.rready && target_axi_active_q) begin
        target_axi_seen_q <= 1'b1;
        target_axi_last_rdata_q <= dut.rdata;
        if (dut.rlast) target_axi_active_q <= 1'b0;
      end
    end
  end

  always_ff @(posedge emif_clk or negedge emif_rst_n) begin
    if (!emif_rst_n) begin
      emif_read_addr_q <= 25'd0;
      target_avalon_seen_q <= 1'b0;
      target_avalon_data_q <= 512'd0;
    end else begin
      if (avalon_read && avalon_waitrequest_n)
        emif_read_addr_q <= avalon_address;
      if (avalon_readdatavalid &&
          (emif_read_addr_q == PRINTK_TAIL_EMIF_WORD)) begin
        target_avalon_seen_q <= 1'b1;
        target_avalon_data_q <= avalon_readdata;
      end
    end
  end

  always_ff @(posedge emif_clk or negedge emif_rst_n) begin
    if (!emif_rst_n) begin
      emif_read_fire_count <= 0;
      emif_write_fire_count <= 0;
      printk_line_avalon_store_count <= 0;
    end else begin
      if (avalon_read && avalon_waitrequest_n)
        emif_read_fire_count <= emif_read_fire_count + 1;
      if (avalon_write && avalon_waitrequest_n)
        emif_write_fire_count <= emif_write_fire_count + 1;
      if (avalon_write && avalon_waitrequest_n &&
          (avalon_address == PRINTK_NUL_EMIF_WORD)) begin
        printk_line_avalon_store_count <= printk_line_avalon_store_count + 1;
        if ($test$plusargs("LINUX_TRACE_CROSS_LINE"))
          $display("LINUX_PRINTK_LINE_AVALON_STORE count=%0d word=%h be=%016h wdata=%0128h",
                   printk_line_avalon_store_count, avalon_address,
                   avalon_byteenable, avalon_writedata);
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      jtag_count <= 0;
      pc_outside_bram <= 1'b0;
      commit_exception_seen <= 1'b0;
      first_commit_exception_valid <= 1'b0;
      first_commit_exception_pc <= 64'd0;
      first_commit_exception_code <= 32'd0;
      first_commit_exception_esr <= 32'd0;
      first_commit_exception_far <= 64'd0;
      commit_unknown_seen <= 1'b0;
      first_commit_seen <= 1'b0;
      first_commit_wrong <= 1'b0;
      jtag_event_mismatch <= 1'b0;
      ju_tx_event_valid_q <= 1'b0;
      ju_tx_event_char_q <= 8'd0;
      ddr_activity_seen <= 1'b0;
      bridge_tx_pulse_count <= 0;
      commit_count <= 0;
      linux_el0_commit_count <= 0;
      linux_el0_trace_count <= 0;
      linux_first_el0_valid <= 1'b0;
      linux_first_el0_pc <= 64'd0;
      last_commit_pc <= 64'd0;
      last_commit_next_pc <= 64'd0;
      recent_commit_index <= 0;
      first_nul_valid_q <= 1'b0;
      first_nul_index_q <= 0;
      first_nul_char_q <= 8'd0;
      first_nul_commit_pc_q <= 64'd0;
      first_nul_commit_next_pc_q <= 64'd0;
      first_nul_dmem_addr_q <= 64'd0;
      first_nul_dmem_wdata_q <= 64'd0;
      first_nul_dmem_rsp_q <= 64'd0;
      first_nul_dmem_we_q <= 1'b0;
      first_nul_dmem_bypass_q <= 1'b0;
      for (int history = 0; history < 16; history++) begin
        recent_commit_pc[history] <= 64'd0;
        recent_commit_insn[history] <= 32'd0;
        recent_commit_gpr_we[history] <= 1'b0;
        recent_commit_gpr_rd[history] <= 5'd0;
        recent_commit_gpr_wdata[history] <= 64'd0;
      end
    end else begin
      // The lightweight model reports its FIFO event in the same acceptance
      // phase as the bridge pulse.  Quartus' registered waitrequest performs
      // the FIFO side effect while waitrequest is high; the bridge observes
      // acceptance and emits tx_valid in the following low phase.  Delay only
      // the vendor event by one cycle before comparing the two interfaces.
      ju_tx_event_valid_q <= ju_tx_event_valid;
      if (ju_tx_event_valid)
        ju_tx_event_char_q <= ju_tx_event_char;
      if (ju_tx_event_valid && jtag_count < LINUX_JTAG_LOG_BYTES) begin
        jtag_chars[jtag_count] <= ju_tx_event_char;
        jtag_count <= jtag_count + 1;
      end else if (ju_tx_event_valid) begin
        jtag_event_mismatch <= 1'b1;
      end
      if (LINUX_BOOT_TEST && $test$plusargs("LINUX_STOP_ON_TX_NUL") &&
          !first_nul_valid_q && ju_tx_event_valid &&
          (ju_tx_event_char == 8'd0) && (jtag_count > 64)) begin
        first_nul_valid_q <= 1'b1;
        first_nul_index_q <= jtag_count;
        first_nul_char_q <= ju_tx_event_char;
        first_nul_commit_pc_q <= last_commit_pc;
        first_nul_commit_next_pc_q <= last_commit_next_pc;
        first_nul_dmem_addr_q <= last_dmem_addr_q;
        first_nul_dmem_wdata_q <= last_dmem_wdata_q;
        first_nul_dmem_rsp_q <= last_dmem_rsp_data_q;
        first_nul_dmem_we_q <= last_dmem_we_q;
        first_nul_dmem_bypass_q <= last_dmem_bypass_q;
      end
      if (JTAG_VENDOR_TIMING) begin
        if (ju_tx_event_valid_q != jtag_uart_tx_valid) begin
          jtag_event_mismatch <= 1'b1;
        end else if (ju_tx_event_valid_q &&
                     (jtag_uart_tx_char != ju_tx_event_char_q)) begin
          jtag_event_mismatch <= 1'b1;
        end
      end else if (ju_tx_event_valid) begin
        if (!jtag_uart_tx_valid ||
            (jtag_uart_tx_char != ju_tx_event_char)) begin
          jtag_event_mismatch <= 1'b1;
        end
      end
      if (jtag_uart_tx_valid) begin
        bridge_tx_pulse_count <= bridge_tx_pulse_count + 1;
      end
      if ((dbg_poc_req_valid &&
           (dbg_poc_req_addr >= 64'h4000_0000) &&
           (dbg_poc_req_addr < 64'h4800_0000)) ||
          dbg_ddr_u_req_valid ||
          avalon_read || avalon_write) begin
        ddr_activity_seen <= 1'b1;
      end
      if (commit_valid) begin
        commit_count <= commit_count + 1;
        if (LINUX_BOOT_TEST && !dut.core.el) begin
          linux_el0_commit_count <= linux_el0_commit_count + 1;
          if (linux_el0_trace_count < 128) begin
            $display("LINUX_EL0_COMMIT index=%0d pc=%016h insn=%08h exc=%b code=%08h esr=%08h far=%016h gpr_we=%b rd=%0d wdata=%016h x0=%016h x1=%016h x2=%016h x8=%016h spsr=%016h elr=%016h",
                     linux_el0_trace_count, commit_pc, commit_insn,
                     commit_exc_valid, commit_exc_code, commit_exc_esr,
                     commit_exc_far, commit_gpr_we, commit_gpr_rd,
                     commit_gpr_wdata, dut.core.gpr[0], dut.core.gpr[1],
                     dut.core.gpr[2], dut.core.gpr[8], dut.core.spsr_el1,
                     dut.core.elr_el1);
            linux_el0_trace_count <= linux_el0_trace_count + 1;
          end
          if (!linux_first_el0_valid) begin
            linux_first_el0_valid <= 1'b1;
            linux_first_el0_pc <= commit_pc;
          end
        end
        last_commit_pc <= commit_pc;
        last_commit_next_pc <= commit_next_pc;
        recent_commit_pc[recent_commit_index] <= commit_pc;
        recent_commit_insn[recent_commit_index] <= commit_insn;
        recent_commit_gpr_we[recent_commit_index] <= commit_gpr_we;
        recent_commit_gpr_rd[recent_commit_index] <= commit_gpr_rd;
        recent_commit_gpr_wdata[recent_commit_index] <= commit_gpr_wdata;
        recent_commit_index <= (recent_commit_index + 1) & 15;
        if ($isunknown({commit_pc, commit_next_pc, commit_exc_valid})) begin
          commit_unknown_seen <= 1'b1;
        end else begin
          // B25 monitor must remain entirely inside the 64 KiB BRAM window.
          if ((commit_pc >= 64'h0000_0000_0001_0000) ||
              (commit_next_pc >= 64'h0000_0000_0001_0000)) begin
            pc_outside_bram <= 1'b1;
          end
          if (!first_commit_seen && (commit_pc != 64'd0)) begin
            first_commit_wrong <= 1'b1;
          end
        end
        first_commit_seen <= 1'b1;
        if (commit_exc_valid) begin
          commit_exception_seen <= 1'b1;
          if (!first_commit_exception_valid) begin
            first_commit_exception_valid <= 1'b1;
            first_commit_exception_pc <= commit_pc;
            first_commit_exception_code <= commit_exc_code;
            first_commit_exception_esr <= commit_exc_esr;
            first_commit_exception_far <= commit_exc_far;
          end
        end
      end
    end
  end

  function automatic logic text_matches_at(input string want,
                                            input integer start_index);
    integer j;
    integer matched;
    begin
      matched = ((start_index >= 0) &&
                 (start_index + want.len() <= jtag_count));
      if (matched != 0) begin
        for (j = 0; j < want.len(); j = j + 1) begin
          if (jtag_chars[start_index+j] != want.getc(j)) begin
            matched = 0;
          end
        end
      end
      text_matches_at = (matched != 0);
    end
  endfunction

  function automatic logic text_contains_from(input string want,
                                               input integer first_index);
    integer start_index;
    begin
      text_contains_from = 1'b0;
      for (start_index = first_index;
           start_index + want.len() <= jtag_count;
           start_index = start_index + 1) begin
        if (text_matches_at(want, start_index))
          text_contains_from = 1'b1;
      end
    end
  endfunction

  task automatic dump_linux_console;
    begin
      $display("LINUX_CONSOLE_TRANSCRIPT_BEGIN bytes=%0d", jtag_count);
      for (int transcript_index = 0; transcript_index < jtag_count;
           transcript_index++)
        $write("%c", jtag_chars[transcript_index]);
      $display("");
      $display("LINUX_CONSOLE_TRANSCRIPT_END");
      $display("LINUX_CONSOLE_HEX_BEGIN bytes=%0d", jtag_count);
      for (int transcript_index = 0; transcript_index < jtag_count;
           transcript_index++)
        $write("%02x ", jtag_chars[transcript_index]);
      $display("");
      $display("LINUX_CONSOLE_HEX_END");
    end
  endtask

  task automatic read_linux_stack_line(input logic [63:0] pa,
                                       output logic [511:0] line,
                                       output logic cache_hit);
    integer set_index;
    integer ddr_index;
    logic [63:0] line_pa;
    begin
      line = 512'd0;
      cache_hit = 1'b0;
      line_pa = pa & ~64'h3f;
      set_index = int'((line_pa >> 6) & 64'h3f);
      if (dut.coh.d_l1.valid[set_index] &&
          (dut.coh.d_l1.tags[set_index] == line_pa[63:12])) begin
        line = dut.coh.d_l1.u_data_ram.mem[set_index];
        cache_hit = 1'b1;
      end else if ((line_pa >= 64'h4000_0000) &&
                   (line_pa < 64'h4800_0000)) begin
        ddr_index = int'((line_pa - 64'h4000_0000) >> 6);
        if (ddr_index < DDR_MODEL_DEPTH_WORDS)
          line = emif_model.mem[ddr_index];
      end
    end
  endtask

  // Compare the first bad printk source line across the actual hierarchy.
  // The first-NUL trace currently identifies PA 0x4066ff40; dump D-L1, L2,
  // and EMIF backing independently to distinguish bad refill data from an
  // earlier dirty write into the printk buffer.
  task automatic dump_linux_line_state(input logic [63:0] pa);
    logic [63:0] line_pa;
    logic [511:0] l1_line;
    logic [511:0] l2_line;
    logic [511:0] ddr_line;
    logic l1_hit;
    logic l2_hit;
    integer l1_set;
    integer l2_set;
    integer ddr_index;
    begin
      line_pa = pa & ~64'h3f;
      l1_set = int'((line_pa >> 6) & 64'h3f);
      l2_set = int'((line_pa >> 6) & 64'h3f);
      ddr_index = int'((line_pa - 64'h4000_0000) >> 6);
      l1_line = dut.coh.d_l1.u_data_ram.mem[l1_set];
      l2_line = dut.coh.l2.u_data_ram.mem[l2_set];
      ddr_line = emif_model.mem[ddr_index];
      l1_hit = dut.coh.d_l1.valid[l1_set] &&
               (dut.coh.d_l1.tags[l1_set] == line_pa[63:12]);
      l2_hit = dut.coh.l2.valid[l2_set][0] &&
               (dut.coh.l2.tags[l2_set][0] == line_pa[63:12]);
      $display("LINUX_FIRST_NUL_LINE pa=%016h l1_set=%0d l1_hit=%b l1_dirty=%b l1_line=%0128h l2_set=%0d l2_hit=%b l2_dirty=%b l2_line=%0128h ddr_index=%0d ddr_line=%0128h",
               line_pa, l1_set, l1_hit, dut.coh.d_l1.dirty[l1_set],
               l1_line, l2_set, l2_hit, dut.coh.l2.dirty[l2_set][0],
               l2_line, ddr_index, ddr_line);
    end
  endtask

  // The corrupted printk buffer is filled by the kernel's 16-byte __memcpy
  // path. Capture the exact LDP response before the later UART byte loop
  // overwrites the bounded dmem history, and compare that source line across
  // D-L1, L2, and EMIF backing at the response boundary.
  always @(posedge clk) begin
    if (rst_n && LINUX_BOOT_TEST &&
        $test$plusargs("LINUX_TRACE_CROSS_LINE") &&
        dbg_dmem_req_valid &&
        dbg_dmem_req_ready && dut.dmem_req.we &&
        (dut.core.exmem_pc >= 64'hffff_ffc0_8000_0000) &&
        (dbg_dmem_req_addr >= PRINTK_COPY_SOURCE_LINE_PA) &&
        (dbg_dmem_req_addr < PRINTK_COPY_SOURCE_LINE_PA + 64)) begin
      $display("LINUX_COPY_SOURCE_STORE pc=%016h insn=%08h va=%016h pa=%016h req_pa=%016h pair=%b pair_part=%b size=%0d strb=%02h wdata=%016h x0=%016h x1=%016h x2=%016h",
               dut.core.exmem_pc, dut.core.exmem_insn,
               dut.core.exmem_mem_addr, dut.core.exmem_mem_paddr,
               dbg_dmem_req_addr, dut.core.exmem_is_pair,
               dut.core.pair_part, dut.core.exmem_mem_size,
               dut.dmem_req.strb, dbg_dmem_req_wdata,
               dut.core.gpr[0], dut.core.gpr[1], dut.core.gpr[2]);
    end
    if (rst_n && LINUX_BOOT_TEST &&
        $test$plusargs("LINUX_TRACE_CROSS_LINE") &&
        dbg_dmem_rsp_valid &&
        dut.dmem_rsp_ready && dut.core.exmem_valid &&
        dut.core.exmem_is_load && dut.core.exmem_is_pair &&
        (dut.core.exmem_pc == 64'hffff_ffc0_8025_2fe4) &&
        (dut.core.exmem_insn == 32'ha941_2428) &&
        (dut.core.exmem_wb_rd == 5'd8) &&
        (dut.core.exmem_wb2_rd == 5'd9) &&
        (dut.core.gpr[0] == 64'hffff_ffc0_8046_ff40)) begin
      $display("LINUX_COPY_LDP_RSP part=%b pc=%016h insn=%08h req_pa=%016h base_va=%016h base_pa=%016h x1=%016h rdata=%016h first_data=%016h",
               dut.core.pair_part, dut.core.exmem_pc,
               dut.core.exmem_insn, dmem_trace_pending_addr_q,
               dut.core.exmem_mem_addr, dut.core.exmem_mem_paddr,
               dut.core.gpr[1], dut.dmem_rsp.rdata,
               dut.core.exmem_rdata_r);
      dump_linux_line_state(dmem_trace_pending_addr_q);
    end
  end

  task automatic dump_linux_timeout_stack;
    logic [63:0] fp0_va;
    logic [63:0] fp0_pa;
    logic [63:0] fp1_va;
    logic [63:0] fp1_pa;
    logic [63:0] lr0;
    logic [63:0] lr1;
    logic [511:0] line0;
    logic [511:0] line1;
    logic hit0;
    logic hit1;
    integer off0;
    integer off1;
    begin
      fp0_va = dut.core.gpr[29];
      fp0_pa = 64'd0;
      fp1_va = 64'd0;
      fp1_pa = 64'd0;
      lr0 = 64'd0;
      lr1 = 64'd0;
      line0 = 512'd0;
      line1 = 512'd0;
      hit0 = 1'b0;
      hit1 = 1'b0;
      off0 = 0;
      off1 = 0;
      // This Linux config has CONFIG_VMAP_STACK disabled, so its kernel
      // frame pointers use the direct linear map. Recover __delay's saved LR
      // and the caller LR from the two adjacent AArch64 frame records.
      if ((fp0_va >= 64'hffff_ff80_0000_0000) &&
          (fp0_va < 64'hffff_ffc0_0000_0000)) begin
        fp0_pa = 64'h4000_0000 + (fp0_va - 64'hffff_ff80_0000_0000);
        read_linux_stack_line(fp0_pa, line0, hit0);
        off0 = int'(fp0_pa[5:0]) * 8;
        fp1_va = line0[off0 +: 64];
        lr0 = line0[off0 + 64 +: 64];
        if ((fp1_va >= 64'hffff_ff80_0000_0000) &&
            (fp1_va < 64'hffff_ffc0_0000_0000)) begin
          fp1_pa = 64'h4000_0000 + (fp1_va - 64'hffff_ff80_0000_0000);
          read_linux_stack_line(fp1_pa, line1, hit1);
          off1 = int'(fp1_pa[5:0]) * 8;
          lr1 = line1[off1 + 64 +: 64];
        end
      end
      $display("LINUX_BOOT_TIMEOUT_STACK fp0_va=%016h fp0_pa=%016h l1hit0=%b saved_fp1=%016h delay_lr=%016h fp1_pa=%016h l1hit1=%b caller_lr=%016h el0_commits=%0d first_el0_pc=%016h",
               fp0_va, fp0_pa, hit0, fp1_va, lr0, fp1_pa, hit1, lr1,
               linux_el0_commit_count, linux_first_el0_pc);
    end
  endtask

  task automatic dump_linux_dmem_trace;
    begin
      $display("LINUX_DMEM_FAULT_TRACE pending=%b pending_addr=%016h last_pa=%016h last_we=%b last_bypass=%b last_wdata=%016h last_rsp=%016h ptw=%0d/%0d ptw_pa=%016h ptw_we=%b ptw_rsp=%016h ptw_fault=%b",
               dmem_trace_pending_q, dmem_trace_pending_addr_q,
               last_dmem_addr_q, last_dmem_we_q, last_dmem_bypass_q,
               last_dmem_wdata_q, last_dmem_rsp_data_q,
               ptw_req_count_q, ptw_rsp_count_q,
               last_ptw_req_addr_q, last_ptw_req_we_q,
               last_ptw_rsp_data_q, last_ptw_rsp_fault_q);
      $display("LINUX_DMEM_FAULT_EXMEM va=%016h pa=%016h trans_pa=%016h mmu_req_va=%016h mmu_pa=%016h mmu_walk=%b",
               dut.core.exmem_mem_addr, dut.core.exmem_mem_paddr,
               dut.core.trans_paddr_r, dut.core.mmu_req_va,
               dut.core.mmu_paddr, dut.core.mmu_walking);
      $display("LINUX_DMEM_FAULT_RING_BEGIN next_slot=%0d", dmem_trace_index);
      for (int dmem_history = 0; dmem_history < DMEM_TRACE_DEPTH;
           dmem_history++) begin
        int dmem_slot;
        dmem_slot = (dmem_trace_index + dmem_history) % DMEM_TRACE_DEPTH;
        $display("LINUX_DMEM_FAULT_RING index=%0d pa=%016h we=%b bypass=%b wdata=%016h rdata=%016h",
                 dmem_history, dmem_trace_pa[dmem_slot],
                 dmem_trace_we[dmem_slot],
                 dmem_trace_bypass[dmem_slot],
                 dmem_trace_wdata[dmem_slot],
                 dmem_trace_data[dmem_slot]);
      end
      $display("LINUX_DMEM_FAULT_RING_END");
    end
  endtask

  task automatic wait_for_linux_text(input string want,
                                     input integer first_index,
                                     input integer max_cycles);
    integer cycles;
    logic found;
    logic [63:0] sample_pc;
    logic [63:0] sample_x0;
    logic [63:0] sample_x1;
    logic [63:0] sample_x2;
    logic [31:0] sample_ddr_reads;
    logic [31:0] sample_ddr_writes;
    integer sample_tx_bytes;
    integer stagnant_progress;
    begin
      found = 1'b0;
      sample_pc = 64'd0;
      sample_x0 = 64'd0;
      sample_x1 = 64'd0;
      sample_x2 = 64'd0;
      sample_ddr_reads = 32'd0;
      sample_ddr_writes = 32'd0;
      sample_tx_bytes = 0;
      stagnant_progress = 0;
      for (cycles = 0; (cycles < max_cycles) && !found; cycles = cycles + 1) begin
        @(posedge clk);
        #1;
        if (LINUX_BOOT_TEST && $test$plusargs("LINUX_STOP_ON_TX_NUL") &&
            first_nul_valid_q) begin
          $display("LINUX_FIRST_NUL index=%0d char=%02h last_commit=%016h/%016h dmem=%016h we=%b bypass=%b wdata=%016h rsp=%016h pc=%016h x0=%016h x1=%016h x2=%016h x3=%016h elr=%016h esr=%08h far=%016h fetch_trans_busy=%b fetch_pc=%016h epoch=%0d ctx_epoch=%0d",
                   first_nul_index_q, first_nul_char_q,
                   first_nul_commit_pc_q, first_nul_commit_next_pc_q,
                   first_nul_dmem_addr_q, first_nul_dmem_we_q,
                   first_nul_dmem_bypass_q, first_nul_dmem_wdata_q,
                   first_nul_dmem_rsp_q, dut.core.if_pc, dut.core.gpr[0],
                   dut.core.gpr[1], dut.core.gpr[2], dut.core.gpr[3],
                   dut.core.elr_el1, dut.core.esr_el1, dut.core.far_el1,
                   dut.core.fetch_trans_busy, dut.core.fetch_pc_r,
                   dut.core.fetch_epoch, dut.core.fetch_ctx_epoch);
          $display("LINUX_FIRST_NUL_COMMIT_RING_BEGIN next_slot=%0d", recent_commit_index);
          for (int history = 0; history < 16; history++) begin
            int history_slot;
            history_slot = (recent_commit_index + history) & 15;
            $display("LINUX_FIRST_NUL_COMMIT slot=%0d pc=%016h insn=%08h gpr_we=%b rd=%0d data=%016h",
                     history_slot, recent_commit_pc[history_slot],
                     recent_commit_insn[history_slot],
                     recent_commit_gpr_we[history_slot],
                     recent_commit_gpr_rd[history_slot],
                     recent_commit_gpr_wdata[history_slot]);
          end
          $display("LINUX_FIRST_NUL_COMMIT_RING_END");
          $display("LINUX_PRINTK_LINE_STORE_COUNTS core=%0d poc=%0d avalon=%0d",
                   printk_line_core_store_count,
                   printk_line_poc_store_count,
                   printk_line_avalon_store_count);
          dump_linux_line_state(64'h0000_0000_4066_ff40);
          dump_linux_dmem_trace();
          dump_linux_console();
          $fatal(1, "LINUX_FIRST_NUL_DIAGNOSTIC_STOP");
        end
        if ((cycles & 4095) == 0)
          found = text_contains_from(want, first_index);
        if (LINUX_BOOT_TEST && (commit_pc < 64'h0000_0000_0001_0000) &&
            commit_valid && commit_exc_valid &&
            (commit_exc_code != lcvex_pkg::EXC_IRQ)) begin
          $display("LINUX_BOOT_SYNC_EXCEPTION pc=%016h code=%08h esr=%08h far=%016h x0=%016h x1=%016h x2=%016h ddr_read=%0d ddr_write=%0d",
                   commit_pc, commit_exc_code, commit_exc_esr, commit_exc_far,
                   dut.core.gpr[0], dut.core.gpr[1], dut.core.gpr[2],
                   soc_ddr_read_count, soc_ddr_write_count);
          $fatal(1, "Linux loader encountered a synchronous exception before marker=%s",
                 want);
        end
        if (LINUX_BOOT_TEST && first_commit_exception_valid &&
            (first_commit_exception_esr[5:0] == 6'h10)) begin
          $display("LINUX_BOOT_EARLY_EXTERNAL_ABORT pc=%016h code=%08h esr=%08h far=%016h",
                   first_commit_exception_pc, first_commit_exception_code,
                   first_commit_exception_esr, first_commit_exception_far);
          dump_linux_dmem_trace();
          dump_linux_console();
          $fatal(1, "Linux encountered a synchronous external abort before marker=%s",
                 want);
        end
        if (LINUX_BOOT_TEST &&
            ((linux_gicd_rwp_busy_count >= 64) ||
             (linux_gicr_rwp_busy_count >= 64))) begin
          $display("LINUX_GIC_RWP_STUCK d_ctlr_reads=%0d d_rwp_busy=%0d c_ctlr_reads=%0d c_rwp_busy=%0d last_addr=%016h last_data=%08h model_d_ctlr=%02h model_c_ctlr=%03h spi33_enabled=%b uart_ctrl_wr=%0d uart_data_rd=%0d pc=%016h elr=%016h x19=%016h x20=%016h x21=%016h x22=%016h x23=%016h",
                   linux_gicd_ctlr_read_count, linux_gicd_rwp_busy_count,
                   linux_gicc_ctlr_read_count, linux_gicr_rwp_busy_count,
                   linux_last_gic_read_addr_q, linux_last_gic_read_data_q,
                   dut.board_gic.ctlr_r, dut.board_gic.cpu_ctlr_r,
                   dut.board_gic.enabled_r[33], ju_control_write_count,
                   ju_data_read_count,
                   last_commit_pc, dut.core.elr_el1, dut.core.gpr[19],
                   dut.core.gpr[20], dut.core.gpr[21], dut.core.gpr[22],
                   dut.core.gpr[23]);
          dump_linux_timeout_stack();
          dump_linux_console();
          $fatal(1, "Linux repeatedly observed GIC RWP set before marker=%s",
                 want);
        end
        if ((cycles != 0) && ((cycles % 25_000_000) == 0)) begin
          if ((last_commit_pc == sample_pc) &&
              (dut.core.gpr[0] == sample_x0) &&
              (dut.core.gpr[1] == sample_x1) &&
              (dut.core.gpr[2] == sample_x2) &&
              (jtag_count == sample_tx_bytes) &&
              (soc_ddr_read_count == sample_ddr_reads) &&
              (soc_ddr_write_count == sample_ddr_writes)) begin
            stagnant_progress = stagnant_progress + 1;
          end else begin
            stagnant_progress = 0;
          end
          $display("LINUX_BOOT_PROGRESS cycles=%0d commits=%0d tx_bytes=%0d pc=%016h x0=%016h x1=%016h x2=%016h x3=%016h x21=%016h x22=%016h x23=%016h ddr_read=%0d ddr_write=%0d ju_wspace=%0d ju_tx_push=%0d ju_ctrl_rd=%0d ju_data_wr=%0d first_exc=%b/%h/%h/%h",
                   cycles, commit_count, jtag_count, last_commit_pc,
                   dut.core.gpr[0], dut.core.gpr[1], dut.core.gpr[2],
                   dut.core.gpr[3], dut.core.gpr[21], dut.core.gpr[22],
                   dut.core.gpr[23], soc_ddr_read_count, soc_ddr_write_count,
                   ju_tx_wspace, ju_tx_push_count, ju_control_read_count,
                   ju_data_write_count,
                   first_commit_exception_valid, first_commit_exception_code,
                   first_commit_exception_esr, first_commit_exception_far);
          if (cycles == 300_000_000) dump_linux_console();
          if (stagnant_progress >= 1) begin
            $display("LINUX_BOOT_STAGNANT cycles=%0d pc=%016h next_pc=%016h insn=%08h x0=%016h x1=%016h x2=%016h x3=%016h x19=%016h x20=%016h x21=%016h x22=%016h x23=%016h x24=%016h x25=%016h x26=%016h x27=%016h x28=%016h x29=%016h x30=%016h elr=%016h esr=%08h far=%016h sctlr=%016h daif=%h ddr_read=%0d ddr_write=%0d",
                     cycles, last_commit_pc, last_commit_next_pc, commit_insn,
                     dut.core.gpr[0], dut.core.gpr[1], dut.core.gpr[2],
                     dut.core.gpr[3], dut.core.gpr[19], dut.core.gpr[20],
                     dut.core.gpr[21], dut.core.gpr[22], dut.core.gpr[23],
                     dut.core.gpr[24], dut.core.gpr[25], dut.core.gpr[26],
                     dut.core.gpr[27], dut.core.gpr[28], dut.core.gpr[29],
                     dut.core.gpr[30], dut.core.elr_el1, dut.core.esr_el1,
                     dut.core.far_el1, dut.core.sctlr_el1, dut.core.daif,
                     soc_ddr_read_count, soc_ddr_write_count);
            $display("LINUX_BOOT_STAGNANT_RING x1=%016h x2=%016h x3=%016h x8=%016h x9=%016h x10=%016h x11=%016h x25=%016h ddr_static_tail_state_pa_4064f938=%016h",
                     dut.core.gpr[1], dut.core.gpr[2], dut.core.gpr[3],
                     dut.core.gpr[8], dut.core.gpr[9], dut.core.gpr[10],
                     dut.core.gpr[11], dut.core.gpr[25],
                     emif_model.mem[18'h193e4][511:448]);
            $display("LINUX_BOOT_STAGNANT_PATH dmem_pa=%016h dmem_we=%b dmem_bypass=%b rsp=%016h trans_pa=%016h exmem_pa=%016h l1_req_pa=%016h l1_bypass=%b l1_down_pa=%016h l1_down_bypass=%b poc_pa=%016h poc_bypass=%b",
                     last_dmem_addr_q, last_dmem_we_q,
                     last_dmem_bypass_q, last_dmem_rsp_data_q,
                     dut.core.trans_paddr_r, dut.core.exmem_mem_paddr,
                     last_l1_req_addr_q, last_l1_req_bypass_q,
                     last_l1_down_addr_q, last_l1_down_bypass_q,
                     last_poc_req_addr_q, last_poc_req_bypass_q);
            $display("LINUX_BOOT_STAGNANT_READPATH axi_seen=%b axi_last_rdata=%032h avalon_seen=%b avalon_tail_word=%016h l1_valid=%b l1_dirty=%b l1_tag=%013h l1_tail_word=%016h l2_valid=%b l2_dirty=%b l2_tag=%013h l2_tail_word=%016h",
                     target_axi_seen_q, target_axi_last_rdata_q,
                     target_avalon_seen_q, target_avalon_data_q[511:448],
                     dut.coh.d_l1.valid[60], dut.coh.d_l1.dirty[60],
                     dut.coh.d_l1.tags[60],
                     dut.coh.d_l1.u_data_ram.mem[60][511:448],
                     dut.coh.l2.valid[60][0], dut.coh.l2.dirty[60][0],
                     dut.coh.l2.tags[60][0],
                     dut.coh.l2.u_data_ram.mem[60][511:448]);
            $display("LINUX_BOOT_STAGNANT_MMU tcr=%016h ttbr1=%016h mair=%016h par=%016h",
                     dut.core.tcr_el1, dut.core.ttbr1_el1,
                     dut.core.mair_el1, dut.core.par_el1);
            $display("LINUX_BOOT_STAGNANT_DMEM_TRACE_BEGIN target_rsp_count=%0d target_rsp=%016h next_slot=%0d",
                     target_dmem_rsp_count, target_dmem_rsp_data_q,
                     dmem_trace_index);
            for (int dmem_history = 0; dmem_history < DMEM_TRACE_DEPTH;
                 dmem_history++) begin
              int dmem_slot;
              dmem_slot = (dmem_trace_index + dmem_history) %
                          DMEM_TRACE_DEPTH;
              $display("LINUX_BOOT_STAGNANT_DMEM index=%0d pa=%016h we=%b bypass=%b rdata=%016h",
                       dmem_history, dmem_trace_pa[dmem_slot],
                       dmem_trace_we[dmem_slot],
                       dmem_trace_bypass[dmem_slot],
                       dmem_trace_data[dmem_slot]);
            end
            $display("LINUX_BOOT_STAGNANT_DMEM_TRACE_END");
            $display("LINUX_BOOT_STAGNANT_RECENT_PC_BEGIN");
            for (int history = 0; history < 16; history++) begin
              int slot;
              slot = (recent_commit_index + history) & 15;
              $display("LINUX_BOOT_STAGNANT_PC index=%0d pc=%016h",
                       history, recent_commit_pc[slot]);
            end
            $display("LINUX_BOOT_STAGNANT_RECENT_PC_END");
            dump_linux_console();
            $fatal(1, "Linux boot made no architectural/device progress for one 25M-cycle interval");
          end
          sample_pc = last_commit_pc;
          sample_x0 = dut.core.gpr[0];
          sample_x1 = dut.core.gpr[1];
          sample_x2 = dut.core.gpr[2];
          sample_tx_bytes = jtag_count;
          sample_ddr_reads = soc_ddr_read_count;
          sample_ddr_writes = soc_ddr_write_count;
        end
      end
      if (!found) begin
        $display("LINUX_BOOT_TIMEOUT_REGS x0=%016h x1=%016h x2=%016h x3=%016h x19=%016h x20=%016h x21=%016h x22=%016h x23=%016h x29=%016h x30=%016h sp_el1=%016h ddr_read=%0d ddr_write=%0d first_exc=%b/%016h/%08h/%08h/%016h",
                 dut.core.gpr[0], dut.core.gpr[1], dut.core.gpr[2],
                 dut.core.gpr[3], dut.core.gpr[19], dut.core.gpr[20],
                 dut.core.gpr[21], dut.core.gpr[22], dut.core.gpr[23],
                 dut.core.gpr[29], dut.core.gpr[30], dut.core.sp_el1,
                 soc_ddr_read_count, soc_ddr_write_count,
                 first_commit_exception_valid, first_commit_exception_pc,
                 first_commit_exception_code, first_commit_exception_esr,
                 first_commit_exception_far);
        $display("LINUX_BOOT_TIMEOUT_STATE elr=%016h spsr=%016h esr=%08h far=%016h sctlr=%016h tcr=%016h ttbr0=%016h ttbr1=%016h ju_wspace=%0d ju_tx_push=%0d ju_tx_events=%0d ju_ctrl_rd=%0d ju_ctrl_wr=%0d ju_data_wr=%0d ju_data_rd=%0d ju_rx_pop=%0d gicd_ctlr_reads=%0d gicd_rwp_busy=%0d gicc_ctlr_reads=%0d gicr_rwp_busy=%0d gic_last_addr=%016h gic_last_data=%08h gicd_ctlr=%02h gicc_ctlr=%03h spi33_enabled=%b el0_commits=%0d first_el0_pc=%016h",
                 dut.core.elr_el1, dut.core.spsr_el1, dut.core.esr_el1,
                 dut.core.far_el1, dut.core.sctlr_el1, dut.core.tcr_el1,
                 dut.core.ttbr0_el1, dut.core.ttbr1_el1, ju_tx_wspace,
                 ju_tx_push_count, ju_tx_event_count, ju_control_read_count,
                 ju_control_write_count, ju_data_write_count, ju_data_read_count,
                 ju_rx_pop_count,
                 linux_gicd_ctlr_read_count, linux_gicd_rwp_busy_count,
                 linux_gicc_ctlr_read_count, linux_gicr_rwp_busy_count,
                 linux_last_gic_read_addr_q, linux_last_gic_read_data_q,
                 dut.board_gic.ctlr_r, dut.board_gic.cpu_ctlr_r,
                 dut.board_gic.enabled_r[33], linux_el0_commit_count,
                 linux_first_el0_pc);
        dump_linux_timeout_stack();
        dump_linux_console();
        $display("LINUX_BOOT_RECENT_PC_BEGIN");
        for (int history = 0; history < 16; history++) begin
          int slot;
          slot = (recent_commit_index + history) & 15;
          $display("LINUX_BOOT_RECENT_PC index=%0d pc=%016h",
                   history, recent_commit_pc[slot]);
        end
        $display("LINUX_BOOT_RECENT_PC_END");
        $fatal(1, "Linux transcript marker timed out marker=%s cycles=%0d commits=%0d tx=%0d pc=%016h exc=%b/%h",
               want, max_cycles, commit_count, jtag_count,
               last_commit_pc, commit_exception_seen, commit_exc_code);
      end
      $display("LINUX_BOOT_MARKER cycles=%0d text=%s", cycles, want);
    end
  endtask

  task automatic send_linux_line(input string line);
    begin
      for (int i = 0; i < line.len(); i++)
        inject_rx_char(line.getc(i));
      inject_rx_char(8'h0d); // canonical ttyJ0 line terminator
    end
  endtask

  function automatic logic is_upper_hex(input logic [7:0] value);
    is_upper_hex = ((value >= 8'h30) && (value <= 8'h39)) ||
                   ((value >= 8'h41) && (value <= 8'h46));
  endfunction

  function automatic logic [31:0] hex32_at(input integer start_index);
    integer j;
    logic [31:0] value;
    logic [7:0] c;
    begin
      value = 32'd0;
      for (j = 0; j < 8; j = j + 1) begin
        c = jtag_chars[start_index + j];
        value = value << 4;
        if ((c >= 8'h30) && (c <= 8'h39))
          value = value | (c - 8'h30);
        else if ((c >= 8'h41) && (c <= 8'h46))
          value = value | (c - 8'h37);
        else
          value = 32'hxxxx_xxxx;
      end
      hex32_at = value;
    end
  endfunction

  task automatic expect_exact(input string want, input integer start_index,
                              input integer max_cycles);
    integer cycles;
    begin
      for (cycles = 0;
           (cycles < max_cycles) &&
           (jtag_count < start_index + want.len());
           cycles = cycles + 1) begin
        @(posedge clk);
        #1;
      end
      if (jtag_count < start_index + want.len()) begin
        $display("FAIL: timed out waiting for exact JTAG text: %s", want);
        errors = errors + 1;
      end else if (!text_matches_at(want, start_index)) begin
        $display("FAIL: JTAG text mismatch at index %0d: %s",
                 start_index, want);
        errors = errors + 1;
      end else if (jtag_count != start_index + want.len()) begin
        $display("FAIL: extra JTAG bytes expected_end=%0d actual=%0d",
                 start_index + want.len(), jtag_count);
        errors = errors + 1;
      end
    end
  endtask

  task automatic expect_page_shape(input string prefix,
                                   input integer field_count,
                                   input integer max_cycles,
                                   output integer page_start);
    integer start_index;
    integer line_len;
    integer field_start;
    integer cycles;
    integer field;
    integer j;
    begin
      start_index = jtag_count;
      page_start = start_index;
      line_len = prefix.len() + 1 + field_count * 8 +
                 (field_count - 1) + 2;
      for (cycles = 0;
           (cycles < max_cycles) &&
           (jtag_count < start_index + line_len);
           cycles = cycles + 1) begin
        @(posedge clk);
        #1;
      end
      if (jtag_count < start_index + line_len) begin
        $display("FAIL: timed out waiting for %s diagnostic page", prefix);
        errors = errors + 1;
      end else begin
        if (!text_matches_at(prefix, start_index) ||
            (jtag_chars[start_index + prefix.len()] != 8'h20)) begin
          $display("FAIL: diagnostic prefix mismatch at index %0d: %s",
                   start_index, prefix);
          errors = errors + 1;
        end
        for (field = 0; field < field_count; field = field + 1) begin
          field_start = start_index + prefix.len() + 1 + field * 9;
          for (j = 0; j < 8; j = j + 1) begin
            if (!is_upper_hex(jtag_chars[field_start + j])) begin
              $display("FAIL: %s field %0d is not uppercase hex", prefix, field);
              errors = errors + 1;
            end
          end
        end
        if ((jtag_chars[start_index + line_len - 2] != 8'h0d) ||
            (jtag_chars[start_index + line_len - 1] != 8'h0a)) begin
          $display("FAIL: %s diagnostic page missing CRLF", prefix);
          errors = errors + 1;
        end
        if (jtag_count != start_index + line_len) begin
          $display("FAIL: %s page emitted extra bytes expected_end=%0d actual=%0d",
                   prefix, start_index + line_len, jtag_count);
          errors = errors + 1;
        end
      end
    end
  endtask

  task automatic expect_rxcpu_software(input integer page_start);
    logic [31:0] getc_event;
    logic [31:0] dispatch_event;
    logic [31:0] putc_event;
    begin
      getc_event = hex32_at(page_start + 6);
      dispatch_event = hex32_at(page_start + 15);
      putc_event = hex32_at(page_start + 24);
      if (getc_event !== 32'h0004_a464) begin
        $display("FAIL: RXCPU getc event=%08h expected=0004A464", getc_event);
        errors = errors + 1;
      end
      if (dispatch_event !== 32'h0004_0464) begin
        $display("FAIL: RXCPU dispatch event=%08h expected=00040464",
                 dispatch_event);
        errors = errors + 1;
      end
      // The host model drains TX continuously: all four command responses
      // and both autonomous pages before RXCPU must write without drops.
      if (putc_event !== 32'h00c2_0000) begin
        $display("FAIL: RXCPU putc event=%08h expected=00c20000", putc_event);
        errors = errors + 1;
      end
    end
  endtask

  task automatic wait_vendor_page(input string prefix,
                                   input integer field_count,
                                   output integer page_start);
    integer reads_before;
    integer pops_before;
    integer chars_before;
    integer commits_before;
    integer target_reads;
    integer cycles;
    begin
      reads_before = ju_data_read_count;
      pops_before = ju_rx_pop_count;
      chars_before = jtag_count;
      commits_before = commit_count;
      target_reads = reads_before + LONG_EMPTY_POLLS;
      for (cycles = 0;
           (cycles < RUN_CYCLES_LONG_POLL) &&
           (ju_data_read_count < target_reads);
           cycles = cycles + 1) begin
        @(posedge clk);
        #1;
      end
      if (ju_data_read_count < target_reads) begin
        $display("FAIL: %s page timed out before=%0d after=%0d target=%0d",
                 prefix, reads_before, ju_data_read_count, target_reads);
        errors = errors + 1;
      end
      if ((ju_rx_pop_count != pops_before) || (jtag_count < chars_before)) begin
        $display("FAIL: %s empty polling side effect pops=%0d/%0d chars_before=%0d actual=%0d",
                 prefix, pops_before, ju_rx_pop_count, chars_before, jtag_count);
        errors = errors + 1;
      end
      if (commit_count <= commits_before) begin
        $display("FAIL: %s empty polling stopped architectural commits", prefix);
        errors = errors + 1;
      end
      expect_page_shape(prefix, field_count, RUN_CYCLES_COMMAND, page_start);
    end
  endtask

  task automatic inject_rx_char(input logic [7:0] value);
    integer cycles;
    begin
      @(negedge clk);
      ju_rx_char = value;
      ju_rx_valid = 1'b1;
      for (cycles = 0; (cycles < 1024) && !ju_rx_ready;
           cycles = cycles + 1) begin
        @(negedge clk);
      end
      if (!ju_rx_ready) begin
        $display("FAIL: RX injection timed out char=0x%02h", value);
        errors = errors + 1;
        ju_rx_valid = 1'b0;
      end else begin
        @(posedge clk);
        @(negedge clk);
        ju_rx_valid = 1'b0;
      end
    end
  endtask

  task automatic send_and_expect(input logic [7:0] value,
                                 input string want,
                                 input integer max_cycles);
    integer start_index;
    integer rx_pops_before;
    begin
      start_index = jtag_count;
      rx_pops_before = ju_rx_pop_count;
      inject_rx_char(value);
      expect_exact(want, start_index, max_cycles);
      if (ju_rx_pop_count != rx_pops_before + 1) begin
        $display("FAIL: RX char 0x%02h pop count before=%0d after=%0d",
                 value, rx_pops_before, ju_rx_pop_count);
        errors = errors + 1;
      end
    end
  endtask

  task automatic run_linux_boot;
    integer response_start;
    integer rx_pops_before;
    begin
      if (!LINUX_BOOT_TEST) $fatal(1, "Linux boot task selected in B25 mode");
      if (flash_words_file == "")
        $fatal(1, "Flash word image is required for Linux boot simulation");
      $display("SOC_LINUX_BOOT start image=%s flash_memh=%s words=%0d",
               BOOT_HEX_FILE, flash_words_file, FLASH_LINE_CAPACITY);
      reset_dut(CAL_MODE_OK);
      wait_for_linux_text("LCVEX Catapult A10 /init ready", 0,
                          LINUX_BOOT_TIMEOUT_CYCLES);
      if ((soc_ddr_read_count == 0) || (soc_ddr_write_count == 0))
        $fatal(1, "Linux reached /init without observed DDR traffic read/write=%0d/%0d",
               soc_ddr_read_count, soc_ddr_write_count);

      response_start = jtag_count;
      rx_pops_before = ju_rx_pop_count;
      send_linux_line("help");
      wait_for_linux_text("commands: help, echo [text], sleep, about",
                          response_start, 5_000_000);
      if (ju_rx_pop_count <= rx_pops_before)
        $fatal(1, "help command was not consumed by the Linux JTAG-UART driver");

      response_start = jtag_count;
      rx_pops_before = ju_rx_pop_count;
      send_linux_line("echo LCVEX_UART_OK");
      wait_for_linux_text("LCVEX_UART_OK", response_start, 5_000_000);
      if (ju_rx_pop_count <= rx_pops_before)
        $fatal(1, "echo command was not consumed by the Linux JTAG-UART driver");
      if (commit_unknown_seen)
        $fatal(1, "unknown instructions retired while Linux was running");

      $display("SOC_LINUX_BOOT PASS commits=%0d tx_bytes=%0d ddr_read=%0d ddr_write=%0d",
               commit_count, jtag_count, soc_ddr_read_count, soc_ddr_write_count);
      $finish(0);
    end
  endtask

  task automatic send_debug_and_expect(input string event_hex,
                                       input integer max_cycles);
    integer start_index;
    integer rx_pops_before;
    integer cycles;
    integer j;
    begin
      start_index = jtag_count;
      rx_pops_before = ju_rx_pop_count;
      inject_rx_char(8'h64);
      for (cycles = 0;
           (cycles < max_cycles) && (jtag_count < start_index + 25);
           cycles = cycles + 1) begin
        @(posedge clk);
        #1;
      end
      if (jtag_count < start_index + 25) begin
        $display("FAIL: timed out waiting for dynamic RXDBG");
        errors = errors + 1;
      end else begin
        if (!text_matches_at("RXDBG ", start_index)) begin
          $display("FAIL: dynamic RXDBG prefix mismatch at %0d", start_index);
          errors = errors + 1;
        end
        for (j = 0; j < 8; j = j + 1) begin
          if (!is_upper_hex(jtag_chars[start_index + 6 + j])) begin
            $display("FAIL: RXDBG read count is not uppercase hex index=%0d value=%02h",
                     j, jtag_chars[start_index + 6 + j]);
            errors = errors + 1;
          end
        end
        if ((jtag_chars[start_index + 14] != 8'h20) ||
            !text_matches_at(event_hex, start_index + 15) ||
            (jtag_chars[start_index + 23] != 8'h0d) ||
            (jtag_chars[start_index + 24] != 8'h0a)) begin
          $display("FAIL: dynamic RXDBG event payload mismatch expected=%s",
                   event_hex);
          errors = errors + 1;
        end
        if (jtag_count != start_index + 25) begin
          $display("FAIL: dynamic RXDBG emitted extra bytes expected_end=%0d actual=%0d",
                   start_index + 25, jtag_count);
          errors = errors + 1;
        end
      end
      if (ju_rx_pop_count != rx_pops_before + 1) begin
        $display("FAIL: debug command pop count before=%0d after=%0d",
                 rx_pops_before, ju_rx_pop_count);
        errors = errors + 1;
      end
    end
  endtask

  task automatic send_coremark_self_and_expect;
    string start_text;
    string self_prefix;
    string iteration_text;
    string suffix;
    integer start_index;
    integer self_index;
    integer final_index;
    integer cycle_digits_index;
    integer cycle_digits_end;
    integer rx_pops_before;
    integer cycles;
    integer j;
    integer done;
    integer nonzero_cycle;
    integer progress_commits;
    integer stalled_cycles;
    integer drain_cycles;
    begin
      start_text = "CMSTART V\r\n";
      self_prefix = "CMSELF PASS seed=0000E9F5 list=0000E714 matrix=00001FD7 state=00008E3A final=";
      iteration_text = " iterations=1 cycles=";
      suffix = " score=INVALID\r\n";
      start_index = jtag_count;
      rx_pops_before = ju_rx_pop_count;
      inject_rx_char("v");
      // The board terminal services the vendor JTAG-UART FIFO asynchronously.
      // Drain only one byte per 65,536 logic cycles in the registered-vendor
      // model so this regression exercises a slow but live host instead of an
      // impossible one-byte-per-clock consumer.
      if (JTAG_VENDOR_TIMING)
        ju_tx_pop = 1'b0;
      else
        ju_tx_pop = 1'b1;
      done = 0;
      progress_commits = commit_count;
      stalled_cycles = 0;
      for (cycles = 0;
           (cycles < RUN_CYCLES_COREMARK_SELF) && (done == 0);
           cycles = cycles + 1) begin
        if (JTAG_VENDOR_TIMING)
          ju_tx_pop = ((cycles % COREMARK_HOST_DRAIN_PERIOD) == 0);
        @(posedge clk);
        #1;
        if (JTAG_VENDOR_TIMING)
          ju_tx_pop = 1'b0;
        else
          ju_tx_pop = 1'b1;
        if (commit_count != progress_commits) begin
          progress_commits = commit_count;
          stalled_cycles = 0;
        end else begin
          stalled_cycles = stalled_cycles + 1;
          if (stalled_cycles >= 100000)
            done = -1;
        end
        if ((jtag_count >= start_index + start_text.len() +
                           self_prefix.len() + 8 + iteration_text.len() +
                           1 + suffix.len()) &&
            text_matches_at(suffix, jtag_count - suffix.len())) begin
          done = 1;
        end
      end
      if (done != 1) begin
        $display("FAIL: CoreMark self-check timed out chars=%0d commits=%0d last_pc=%016h last_next=%016h",
                 jtag_count - start_index, commit_count,
                 last_commit_pc, last_commit_next_pc);
        for (j = 0; j < 16; j = j + 1)
          $display("COREMARK_RECENT_PC slot=%0d pc=%016h",
                   j, recent_commit_pc[(recent_commit_index + j) & 15]);
        $display("COREMARK_PIPE if_pc=%016h ifid=%0b/%016h idex=%0b/%016h exmem=%0b/%016h memwb=%0b/%016h",
                 dut.core.if_pc, dut.core.ifid_valid, dut.core.ifid_pc,
                 dut.core.idex_valid, dut.core.idex_pc,
                 dut.core.exmem_valid, dut.core.exmem_pc,
                 dut.core.memwb_valid, dut.core.memwb_pc);
        $display("COREMARK_DMEM pending=%0b issued=%0b done=%0b pair_part=%0b req=%0b/%0b addr=%016h we=%0b rsp=%0b/%0b",
                 dut.core.dmem_pending, dut.core.dmem_req_issued,
                 dut.core.dmem_done, dut.core.pair_part,
                 dut.dmem_req_valid, dut.dmem_req_ready, dut.dmem_req.addr,
                 dut.dmem_req.we, dut.dmem_rsp_valid, dut.dmem_rsp_ready);
        $display("COREMARK_ROUTE busy=%0b bram_req=%0b/%0b bram_rsp=%0b/%0b bram_pending=%0b",
                 dut.router.busy, dut.bram_req_valid, dut.bram_req_accept,
                 dut.bram_rsp_valid, dut.bram_rsp_ready,
                 dut.bram.u_impl.rsp_pending);
        $display("COREMARK_FETCH pending=%0b got=%0b fifo_count=%0d stall_if=%0b stall_wb=%0b",
                 dut.core.fetch_pending, dut.core.fetch_got_data,
                 dut.core.fetch_fifo_count, dut.core.stall_if,
                 dut.core.stall_wb);
        $display("COREMARK_COH client=%0d l1_state=%0d l1_u_req=%0b/%0b l1_u_rsp=%0b/%0b arb_flight=%0b l2_state=%0d poc=%0b/%0b/%0b",
                 dut.coh.client_state, dut.coh.d_l1.state,
                 dut.coh.l1_u_req_valid, dut.coh.l1_u_req_ready,
                 dut.coh.l1_u_rsp_valid, dut.coh.l1_u_rsp_ready,
                 dut.coh.l1_arb.in_flight, dut.coh.l2.state,
                 dut.poc_req_valid, dut.poc_req_ready, dut.poc_rsp_valid);
        errors = errors + 1;
      end else begin
        self_index = start_index + start_text.len();
        final_index = self_index + self_prefix.len();
        cycle_digits_index = final_index + 8 + iteration_text.len();
        cycle_digits_end = jtag_count - suffix.len();
        if (!text_matches_at(start_text, start_index) ||
            !text_matches_at(self_prefix, self_index) ||
            !text_matches_at(iteration_text, final_index + 8)) begin
          $display("FAIL: CoreMark self-check fixed fields mismatch");
          errors = errors + 1;
        end
        for (j = 0; j < 8; j = j + 1) begin
          if (!is_upper_hex(jtag_chars[final_index + j])) begin
            $display("FAIL: CoreMark final CRC is not uppercase hex");
            errors = errors + 1;
          end
        end
        nonzero_cycle = 0;
        if (cycle_digits_end <= cycle_digits_index) begin
          $display("FAIL: CoreMark self-check has no cycle count");
          errors = errors + 1;
        end
        for (j = cycle_digits_index; j < cycle_digits_end; j = j + 1) begin
          if ((jtag_chars[j] < 8'h30) || (jtag_chars[j] > 8'h39)) begin
            $display("FAIL: CoreMark cycle count is not decimal");
            errors = errors + 1;
          end
          if (jtag_chars[j] != 8'h30)
            nonzero_cycle = 1;
        end
        if (nonzero_cycle == 0) begin
          $display("FAIL: CoreMark self-check cycle count is zero");
          errors = errors + 1;
        end
        $display("SOC_B25_COREMARK_SELF_TRANSCRIPT_BEGIN");
        for (j = start_index; j < jtag_count; j = j + 1)
          $write("%c", jtag_chars[j]);
        $display("SOC_B25_COREMARK_SELF_TRANSCRIPT_END");
      end
      // Restore the normal test host and require the queued tail to drain
      // before the common idle/FIFO health check runs.
      ju_tx_pop = 1'b1;
      for (drain_cycles = 0;
           (drain_cycles < 128) && (ju_tx_wspace != 16'd64);
           drain_cycles = drain_cycles + 1) begin
        @(posedge clk);
        #1;
      end
      if (ju_tx_wspace != 16'd64) begin
        $display("FAIL: paced JTAG host did not drain CoreMark TX tail wspace=%0d",
                 ju_tx_wspace);
        errors = errors + 1;
      end
      if (ju_rx_pop_count != rx_pops_before + 1) begin
        $display("FAIL: CoreMark v command pop count before=%0d after=%0d",
                 rx_pops_before, ju_rx_pop_count);
        errors = errors + 1;
      end
    end
  endtask

  // The hardware failure appeared only after the resident monitor had entered
  // its empty polling loop.  Exercise enough empty vendor DATA transactions to
  // wrap every 8-bit transport/transaction token many times before injecting
  // the first host character.
  task automatic wait_vendor_empty_polls;
    integer reads_before;
    integer pops_before;
    integer commits_before;
    integer chars_before;
    integer target_reads;
    integer cycles;
    begin
      if (JTAG_VENDOR_TIMING) begin
        reads_before = ju_data_read_count;
        pops_before = ju_rx_pop_count;
        commits_before = commit_count;
        chars_before = jtag_count;
        target_reads = reads_before + LONG_EMPTY_POLLS;
        for (cycles = 0;
             (cycles < RUN_CYCLES_LONG_POLL) &&
             (ju_data_read_count < target_reads);
             cycles = cycles + 1) begin
          @(posedge clk);
          #1;
        end
        if (ju_data_read_count < target_reads) begin
          $display("FAIL: vendor empty-poll target timed out before=%0d after=%0d target=%0d",
                   reads_before, ju_data_read_count, target_reads);
          errors = errors + 1;
        end
        if ((ju_rx_pop_count != pops_before) || (jtag_count != chars_before)) begin
          $display("FAIL: empty polling had a side effect pops=%0d/%0d chars=%0d/%0d",
                   pops_before, ju_rx_pop_count, chars_before, jtag_count);
          errors = errors + 1;
        end
        if (commit_count <= commits_before) begin
          $display("FAIL: monitor stopped committing during vendor empty polling");
          errors = errors + 1;
        end
        $display("SOC_B25_VENDOR_EMPTY_POLLS reads=%0d commits=%0d cycles=%0d",
                 ju_data_read_count - reads_before,
                 commit_count - commits_before, cycles);
        expect_exact("RXDBG 00040000 00000000\r\n", chars_before,
                     RUN_CYCLES_COMMAND);
      end
    end
  endtask

  task automatic check_common_health;
    begin
      repeat (2) @(posedge clk);
      #1;
      if (!first_commit_seen || first_commit_wrong) begin
        $display("FAIL: first architectural commit was not PC=0");
        errors = errors + 1;
      end
      if (pc_outside_bram) begin
        $display("FAIL: resident monitor committed outside 64 KiB BRAM");
        errors = errors + 1;
      end
      if (commit_exception_seen) begin
        $display("FAIL: resident monitor took an architectural exception");
        errors = errors + 1;
      end
      if (commit_unknown_seen) begin
        $display("FAIL: resident monitor commit packet contained X state");
        errors = errors + 1;
      end
      if (jtag_event_mismatch) begin
        $display("FAIL: bridge TX pulse disagreed with Avalon model event");
        errors = errors + 1;
      end
      if ((ju_data_write_count != ju_tx_event_count) ||
          (ju_tx_event_count != ju_tx_push_count) ||
          (ju_tx_event_count != bridge_tx_pulse_count) ||
          (ju_tx_event_count != jtag_count)) begin
        $display("FAIL: JTAG TX exactly-once mismatch data=%0d event=%0d push=%0d bridge=%0d captured=%0d",
                 ju_data_write_count, ju_tx_event_count, ju_tx_push_count,
                 bridge_tx_pulse_count, jtag_count);
        errors = errors + 1;
      end
      if ((ju_control_write_count != 0) || (ju_tx_wspace != 16'd64)) begin
        $display("FAIL: JTAG model not idle control_writes=%0d wspace=%0d",
                 ju_control_write_count, ju_tx_wspace);
        errors = errors + 1;
      end
    end
  endtask

  task automatic run_positive;
    integer reads_before;
    integer writes_before;
    integer errors_before;
    integer transcript_start;
    integer transcript_index;
    begin
      errors_before = errors;
      $display("SOC_B25_TEST cal-ok start");
      reset_dut(CAL_MODE_OK);
      expect_exact("LCVEX25 BOOT\r\nCAL-OK\r\nDDR-OK\r\nREADY\r\nRXDBG 00000000 00000000\r\n",
                   0, RUN_CYCLES_STARTUP);
      if ((soc_ddr_read_count == 0) || (soc_ddr_write_count == 0) ||
          (emif_read_fire_count == 0) || (emif_write_fire_count == 0)) begin
        $display("FAIL: DDR-OK lacks real traffic soc_r/w=%0d/%0d emif_r/w=%0d/%0d",
                 soc_ddr_read_count, soc_ddr_write_count,
                 emif_read_fire_count, emif_write_fire_count);
        errors = errors + 1;
      end
      if (emif_model.mem[64][31:0] !== 32'hB007_C0DE) begin
        $display("FAIL: external DDR model magic mismatch value=%02h%02h%02h%02h",
                 emif_model.mem[64][31:24], emif_model.mem[64][23:16],
                 emif_model.mem[64][15:8], emif_model.mem[64][7:0]);
        errors = errors + 1;
      end

      send_and_expect("p", "PONG\r\n", RUN_CYCLES_COMMAND);
      send_and_expect("~", "~", RUN_CYCLES_COMMAND);
      send_and_expect("?", "CLOCK25 CAL-OK DDR-OK\r\n",
                      RUN_CYCLES_COMMAND);

      reads_before = soc_ddr_read_count;
      writes_before = soc_ddr_write_count;
      send_and_expect("m", "DDR-OK\r\n", RUN_CYCLES_COMMAND);
      if ((soc_ddr_read_count <= reads_before) ||
          (soc_ddr_write_count <= writes_before)) begin
        $display("FAIL: m did not rerun real DDR traffic before r=%0d/%0d w=%0d/%0d",
                 reads_before, soc_ddr_read_count,
                 writes_before, soc_ddr_write_count);
        errors = errors + 1;
      end
      send_debug_and_expect("00050164", RUN_CYCLES_COMMAND);
      transcript_start = jtag_count;
      send_and_expect("t", "MBPASS 24 8679CF21\r\n",
                      RUN_CYCLES_MICROBENCH);
      $display("SOC_B25_MICROBENCH_TRANSCRIPT_BEGIN");
      for (transcript_index = transcript_start;
           transcript_index < jtag_count;
           transcript_index = transcript_index + 1)
        $write("%c", jtag_chars[transcript_index]);
      $display("SOC_B25_MICROBENCH_TRANSCRIPT_END");
      send_coremark_self_and_expect();
      check_common_health();
      if (errors == errors_before)
        $display("SOC_B25_TEST cal-ok PASS");
      else
        $display("SOC_B25_TEST cal-ok FAIL new_errors=%0d",
                 errors - errors_before);
    end
  endtask

  task automatic run_no_ddr(input integer cal_mode);
    integer errors_before;
    integer page_start;
    begin
      errors_before = errors;
      $display("SOC_B25_TEST no-ddr start mode=%0d", cal_mode);
      reset_dut(cal_mode);
      if (cal_mode == CAL_MODE_WAIT)
        expect_exact("LCVEX25 BOOT\r\nCAL-WAIT\r\nDDR-FAIL\r\nREADY\r\nRXDBG 00000000 00000000\r\n",
                     0, RUN_CYCLES_STARTUP);
      else
        expect_exact("LCVEX25 BOOT\r\nCAL-FAIL\r\nDDR-FAIL\r\nREADY\r\nRXDBG 00000000 00000000\r\n",
                     0, RUN_CYCLES_STARTUP);
      if ((soc_ddr_read_count != 0) || (soc_ddr_write_count != 0) ||
          (emif_read_fire_count != 0) || (emif_write_fire_count != 0) ||
          ddr_activity_seen) begin
        $display("FAIL: calibration-blocked path issued DDR traffic soc_r/w=%0d/%0d emif_r/w=%0d/%0d seen=%0b",
                 soc_ddr_read_count, soc_ddr_write_count,
                 emif_read_fire_count, emif_write_fire_count,
                 ddr_activity_seen);
        errors = errors + 1;
      end

      if (cal_mode == CAL_MODE_WAIT)
        wait_vendor_empty_polls();
      send_and_expect("p", "PONG\r\n", RUN_CYCLES_COMMAND);
      send_and_expect("Z", "Z", RUN_CYCLES_COMMAND);
      if (cal_mode == CAL_MODE_WAIT)
        send_and_expect("?", "CLOCK25 CAL-WAIT DDR-FAIL\r\n",
                        RUN_CYCLES_COMMAND);
      else
        send_and_expect("?", "CLOCK25 CAL-FAIL DDR-FAIL\r\n",
                        RUN_CYCLES_COMMAND);
      send_debug_and_expect("00040164", RUN_CYCLES_COMMAND);
      if ((cal_mode == CAL_MODE_WAIT) && JTAG_VENDOR_TIMING) begin
        // Startup and the first autonomous period are RXDBG.  The next two
        // periods prove the frozen RXPATH/RXCPU rotation and software packing.
        wait_vendor_page("RXPATH", 4, page_start);
        wait_vendor_page("RXCPU", 4, page_start);
        expect_rxcpu_software(page_start);
      end
      check_common_health();
      if (errors == errors_before)
        $display("SOC_B25_TEST no-ddr mode=%0d PASS", cal_mode);
      else
        $display("SOC_B25_TEST no-ddr mode=%0d FAIL new_errors=%0d",
                 cal_mode, errors - errors_before);
    end
  endtask

  initial begin
    errors = 0;
    prog_we = 1'b0;
    prog_addr = '0;
    prog_strb = 8'h00;
    prog_wdata = '0;
    emif_ld_we = 1'b0;
    emif_ld_addr = '0;
    emif_ld_data = 8'd0;
    ju_rx_valid = 1'b0;
    ju_rx_char = 8'd0;
    ju_tx_pop = 1'b1;
    ju_force_waitrequest = 1'b0;
    ju_host_activity = 1'b1;
    if (LINUX_BOOT_TEST) begin
      run_linux_boot();
    end else begin
      run_positive();
      run_no_ddr(CAL_MODE_WAIT);
      run_no_ddr(CAL_MODE_FAIL);
      if (errors == 0) begin
        $display("SOC_B25_ALL_PASS");
        $finish(0);
      end else begin
        $display("SOC_B25_ALL_FAIL errors=%0d", errors);
        $fatal(1, "SOC_B25_ALL_FAIL");
      end
    end
  end

endmodule


// ---------------------------------------------------------------------------
// 轻量 Avalon-MM 512-bit EMIF 模型（DDR 冒烟窗口，带字节装载口）。
// ---------------------------------------------------------------------------
module lcvex_emif_smoke #(
    parameter int DEPTH_WORDS = 1 << 14,
    parameter bit INITIALIZE_ZERO = 1'b1
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        read,
    input  logic        write,
    input  logic [24:0] address,
    input  logic [511:0] writedata,
    input  logic [6:0]  burstcount,
    input  logic [63:0] byteenable,
    output logic        waitrequest_n,
    output logic [511:0] readdata,
    output logic        readdatavalid,
    input  logic        ld_we,
    input  logic [31:0] ld_addr,
    input  logic [7:0]  ld_data
);

  // Store one 512-bit Avalon beat per element. DEPTH_WORDS selects the
  // simulated DDR aperture (2M entries = the physical 128 MiB board range).
  // The two-state model starts unwritten RAM at zero; Linux must initialize
  // allocated pages.
  bit [511:0] mem[0:DEPTH_WORDS-1];
  logic       read_pending_q;
  logic [511:0] readdata_q;

  integer i;
  initial begin
    if (INITIALIZE_ZERO)
      for (i = 0; i < DEPTH_WORDS; i = i + 1)
        mem[i] = 512'd0;
  end

  assign waitrequest_n = 1'b1;
  assign readdata = readdata_q;
  assign readdatavalid = read_pending_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      read_pending_q <= 1'b0;
      readdata_q     <= '0;
    end else begin
      read_pending_q <= 1'b0;
      if (ld_we && (ld_addr[31:6] < DEPTH_WORDS)) begin
        mem[ld_addr[31:6]][ld_addr[5:0]*8 +: 8] <= ld_data;
      end
      if (write && (address < DEPTH_WORDS[24:0])) begin
        for (int b = 0; b < 64; b++) begin
          if (byteenable[b]) begin
            mem[address][b*8 +: 8] <= writedata[b*8 +: 8];
          end
        end
      end
      if (read && (address < DEPTH_WORDS[24:0])) begin
        read_pending_q <= 1'b1;
        readdata_q <= mem[address];
      end
    end
  end

endmodule


// ---------------------------------------------------------------------------
// 轻量 Avalon JTAG-UART 模型：只捕获 data 寄存器写字节。
// ---------------------------------------------------------------------------
module lcvex_jtag_uart_smoke (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        chipselect,
    input  logic        read_n,
    input  logic        write_n,
    input  logic [0:0]  address,
    input  logic [31:0] writedata,
    output logic [31:0] readdata,
    output logic        waitrequest,
    output logic        tx_valid,
    output logic [7:0]  tx_char
);

  assign waitrequest = 1'b0;
  assign readdata = 32'd0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_valid <= 1'b0;
      tx_char  <= 8'd0;
    end else begin
      tx_valid <= 1'b0;
      if (chipselect && !write_n && address == 1'b0) begin
        tx_valid <= 1'b1;
        tx_char  <= writedata[7:0];
      end
    end
  end

endmodule


// ---------------------------------------------------------------------------
// 轻量 EPCQ/SFL CSR 模型：只读 status，写忽略。
// ---------------------------------------------------------------------------
module lcvex_epcq_csr_smoke (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        read,
    input  logic        write,
    input  logic [2:0]  address,
    input  logic [31:0] writedata,
    output logic [31:0] readdata,
    output logic        waitrequest,
    output logic        readdatavalid
);

  logic read_pending_q;

  assign waitrequest = 1'b0;
  assign readdata = 32'h0000_0001;
  assign readdatavalid = read_pending_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      read_pending_q <= 1'b0;
    end else begin
      read_pending_q <= read;
    end
  end

endmodule
