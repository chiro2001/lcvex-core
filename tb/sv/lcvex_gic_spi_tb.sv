`timescale 1ns/1ps

module lcvex_gic_spi_tb;
  import lcvex_pkg::*;

  localparam logic [63:0] GICD_BASE = 64'h0800_0000;
  localparam logic [63:0] GICC_BASE = 64'h0801_0000;
  localparam logic [9:0]  UART_INTID = 10'd33;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic req_valid = 1'b0;
  mem_req_t req = '0;
  logic req_accept;
  logic rsp_valid;
  mem_rsp_t rsp;
  logic rsp_ready = 1'b0;
  logic [1:0] level_ppi = '0;
  logic [63:0] level_spi = '0;
  logic irq;
  logic fiq;
  logic [31:0] read_data;

  lcvex_gic #(.NUM_IRQ(96)) dut (
      .clk(clk), .rst_n(rst_n),
      .req_valid(req_valid), .req(req), .req_accept(req_accept),
      .rsp_valid(rsp_valid), .rsp(rsp), .rsp_ready(rsp_ready),
      .level_ppi(level_ppi), .level_spi(level_spi), .irq(irq), .fiq(fiq)
  );

  always #5 clk = ~clk;

  task automatic access(input logic write_en,
                        input logic [63:0] address,
                        input logic [31:0] value,
                        output logic [31:0] result);
    begin
      @(negedge clk);
      req.addr = address;
      req.we = write_en;
      req.strb = 8'h0f;
      req.wdata = {32'd0, value};
      req.maint = MAINT_NONE;
      req.bypass = 1'b1;
      req_valid = 1'b1;
      do @(posedge clk); while (!req_accept);
      @(negedge clk);
      req_valid = 1'b0;
      while (!rsp_valid) @(negedge clk);
      result = 32'(rsp.rdata);
      rsp_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      rsp_ready = 1'b0;
    end
  endtask

  initial begin
    logic [31:0] iar;
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    level_spi[1] = 1'b1; // INTID 32 + SPI index 1 = 33
    repeat (2) @(negedge clk);
    if (irq !== 1'b0) $fatal(1, "SPI asserted before distributor enable");

    access(1'b1, GICD_BASE + 32'h000, 32'h1, read_data); // GICD group 0
    access(1'b1, GICC_BASE + 32'h000, 32'h1, read_data); // CPU group 0
    access(1'b1, GICC_BASE + 32'h004, 32'hff, read_data); // priority mask
    access(1'b1, GICD_BASE + 32'h104, 32'h2, read_data); // enable INTID 33
    repeat (2) @(negedge clk);
    if (!dut.enabled_r[33])
      $fatal(1, "ISENABLER1 did not enable INTID 33: enabled=%h", dut.enabled_r);
    if (!dut.test_pending(33))
      $fatal(1, "level SPI 33 did not enter pending selection: line=%b",
             dut.level_line(33));
    if (irq !== 1'b1)
      $fatal(1, "enabled level SPI 33 did not assert IRQ: dctlr=%b cctlr=%h pmr=%h group=%b best=%0d prio=%h",
             dut.ctlr_r, dut.cpu_ctlr_r, dut.pmr_r, dut.best_group_v,
             dut.best_irq_v, dut.best_prio_v);

    access(1'b0, GICC_BASE + 32'h00c, 32'd0, iar);
    if (iar[9:0] !== UART_INTID)
      $fatal(1, "IAR returned INTID %0d, expected %0d", iar[9:0], UART_INTID);
    if (irq !== 1'b0) $fatal(1, "active SPI reasserted before EOI");

    access(1'b1, GICC_BASE + 32'h010, 32'(UART_INTID), read_data);
    if (irq !== 1'b1) $fatal(1, "asserted level SPI did not pend again after EOI");
    level_spi[1] = 1'b0;
    repeat (2) @(negedge clk);
    if (irq !== 1'b0) $fatal(1, "deasserted UART SPI remained pending");

    access(1'b0, GICC_BASE + 32'h00c, 32'd0, iar);
    if (iar[9:0] !== 10'd1023)
      $fatal(1, "empty IAR returned INTID %0d, expected spurious 1023", iar[9:0]);

    $display("LCVEX_GIC_SPI_TB PASS");
    $finish;
  end
endmodule
