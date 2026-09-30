// lcvex_c3_sysctrl_tb.sv
// Directed module-level test for the C3 system-control block:
// PSCI-like CPU_ON/OFF, reset, SGI/IPI, SEV/event, and status read.
//
// This is a small M1-B testbench; it does not need a full core.

`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off SYNCASYNCNET */

module lcvex_c3_sysctrl_tb;
  import lcvex_pkg::*;

  localparam int CORE_COUNT = 4;
  localparam logic [63:0] SYS_BASE = 64'h0000_0000_0903_0000;

  logic clk = 1'b0;
  logic rst_n = 1'b0;

  logic req_valid;
  mem_req_t req;
  logic req_accept;
  logic rsp_valid;
  mem_rsp_t rsp;
  logic rsp_ready;

  logic [CORE_COUNT-1:0] start_pulse;
  logic [CORE_COUNT-1:0] stop_pulse;
  logic [CORE_COUNT-1:0] reset_pulse;
  logic [CORE_COUNT-1:0] irq_out;
  logic [CORE_COUNT-1:0] event_out;

  logic [CORE_COUNT-1:0] core_running = 4'b1010;
  logic [CORE_COUNT-1:0] core_stopped = 4'b0101;
  logic [CORE_COUNT-1:0] core_fault = 4'b0000;

  integer errors = 0;

  lcvex_c3_sysctrl #(
      .CORE_COUNT(CORE_COUNT),
      .CORE_ID_W(4),
      .SYS_BASE(SYS_BASE),
      .SYS_TOP(SYS_BASE + 64'h1000)
  ) dut (
      .clk(clk), .rst_n(rst_n),
      .req_valid(req_valid), .req(req),
      .req_accept(req_accept),
      .rsp_valid(rsp_valid), .rsp(rsp), .rsp_ready(rsp_ready),
      .start_pulse(start_pulse),
      .stop_pulse(stop_pulse),
      .reset_pulse(reset_pulse),
      .irq_out(irq_out),
      .event_out(event_out),
      .core_running(core_running),
      .core_stopped(core_stopped),
      .core_fault(core_fault)
  );

  always #5 clk = ~clk;

  task automatic check(input logic cond, input string msg);
    begin
      if (!cond) begin
        $display("FAIL: %s", msg);
        errors = errors + 1;
      end else begin
        $display("PASS: %s", msg);
      end
    end
  endtask

  // Write and check the one-cycle pulse that is visible between the accept
  // edge and the following edge.
  task automatic m1_write_pulse(
      input logic [63:0] addr,
      input logic [63:0] data,
      input int          kind,
      input logic [CORE_COUNT-1:0] expected);
    begin
      @(negedge clk);
      req_valid = 1'b1;
      req = '0;
      req.addr = addr;
      req.we = 1'b1;
      req.strb = 8'h0f;
      req.wdata = data;
      rsp_ready = 1'b0;
      @(posedge clk);       // accept; pulse becomes visible this cycle
      @(negedge clk);       // sample the pulse before it is cleared
      case (kind)
        0: check(start_pulse == expected, "CPU_ON start pulse targets expected cores");
        1: check(stop_pulse == expected, "CPU_OFF stop pulse targets expected core");
        2: check(reset_pulse == expected, "reset pulse targets expected core");
        3: check(event_out == expected, "SEV event pulse targets expected cores");
        default: ; // non-pulse writes (SGI/EOI) do not check a pulse here
      endcase
      @(posedge clk);       // pulse clears / rsp pending
      rsp_ready = 1'b1;
      @(posedge clk);       // consume response
      req_valid = 1'b0;
      rsp_ready = 1'b0;
      @(negedge clk);
    end
  endtask

  initial begin
    req_valid = 1'b0;
    req = '0;
    rsp_ready = 1'b0;
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // CPU_ON for cores 1..3.
    m1_write_pulse(SYS_BASE + 64'h00, 64'h0e, 0, 4'b1110);

    // CPU_OFF for core 2.
    m1_write_pulse(SYS_BASE + 64'h04, 64'h04, 1, 4'b0100);

    // Reset core 0.
    m1_write_pulse(SYS_BASE + 64'h08, 64'h01, 2, 4'b0001);

    // SGI to core 1.
    m1_write_pulse(SYS_BASE + 64'h10, 64'h02, 99, 4'b0000); // no pulse check
    check(irq_out[1], "SGI raises IRQ for core 1");
    check(irq_out[0] == 1'b0 && irq_out[2] == 1'b0 && irq_out[3] == 1'b0,
          "SGI does not raise other cores");

    // EOI clears core 1 IRQ.
    m1_write_pulse(SYS_BASE + 64'h20, 64'h02, 99, 4'b0000);
    check(irq_out == '0, "EOI clears SGI IRQ");

    // SEV/event to all cores.
    m1_write_pulse(SYS_BASE + 64'h14, 64'h0f, 3, 4'b1111);

    // Read status.
    @(negedge clk);
    req_valid = 1'b1;
    req = '0;
    req.addr = SYS_BASE + 64'h18;
    req.we = 1'b0;
    rsp_ready = 1'b0;
    @(posedge clk);
    @(negedge clk);
    check(rsp_valid && rsp.rdata[11:8] == core_fault &&
          rsp.rdata[7:4] == core_stopped && rsp.rdata[3:0] == core_running,
          "status read reflects running/stopped");
    rsp_ready = 1'b1;
    @(posedge clk);
    req_valid = 1'b0;
    rsp_ready = 1'b0;
    @(negedge clk);

    if (errors == 0) $display("LCVEX_C3_SYSCTRL_TB PASS");
    else $display("LCVEX_C3_SYSCTRL_TB FAIL: %0d", errors);
    $finish;
  end

endmodule
