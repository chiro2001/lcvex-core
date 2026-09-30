// lcvex_cache_data_ram_tb.sv
// 定向验证：line-wide 写、逐字节 byte-enable、不同地址、同步读延迟、
// 同址读写的 DONT_CARE/串行化约定，以及 reset 后数据不依赖清零。

`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */

module lcvex_cache_data_ram_tb;
  localparam int LINE_BYTES = 64;
  localparam int DEPTH_WORDS = 4;
  localparam int ADDR_W = 2;

  logic clk, rst_n;
  logic rd_en;
  logic [ADDR_W-1:0] rd_addr;
  logic rd_valid;
  logic [LINE_BYTES*8-1:0] rd_data;
  logic wr_en;
  logic [ADDR_W-1:0] wr_addr;
  logic [LINE_BYTES-1:0] wr_byte_en;
  logic [LINE_BYTES*8-1:0] wr_data;
  integer errors;

  lcvex_cache_data_ram #(
      .LINE_BYTES(LINE_BYTES), .DEPTH_WORDS(DEPTH_WORDS)
  ) dut (
      .clk(clk), .rst_n(rst_n),
      .rd_en(rd_en), .rd_addr(rd_addr), .rd_valid(rd_valid),
      .rd_data(rd_data), .wr_en(wr_en), .wr_addr(wr_addr),
      .wr_byte_en(wr_byte_en), .wr_data(wr_data)
  );

  always #5 clk = ~clk;

  task automatic check_ok(input logic condition, input string message);
    if (!condition) begin
      $display("FAIL: %s", message);
      errors = errors + 1;
    end
  endtask

  task automatic line_write(input logic [ADDR_W-1:0] a,
                            input logic [LINE_BYTES-1:0] be,
                            input logic [LINE_BYTES*8-1:0] d);
    begin
      @(negedge clk);
      wr_addr = a; wr_byte_en = be; wr_data = d; wr_en = 1'b1;
      @(posedge clk); #1;
      wr_en = 1'b0; wr_byte_en = '0;
    end
  endtask

  task automatic line_read(input logic [ADDR_W-1:0] a,
                            output logic [LINE_BYTES*8-1:0] d);
    begin
      @(negedge clk);
      rd_addr = a; rd_en = 1'b1;
      @(posedge clk); #1;
      check_ok(rd_valid, "read response is synchronous and valid after one edge");
      d = rd_data;
      @(negedge clk); rd_en = 1'b0;
    end
  endtask

  initial begin
    logic [LINE_BYTES*8-1:0] line0;
    logic [LINE_BYTES*8-1:0] line1;
    logic [LINE_BYTES*8-1:0] got;
    logic [LINE_BYTES-1:0] partial_be;

    clk = 1'b0; rst_n = 1'b0; rd_en = 1'b0; rd_addr = '0;
    wr_en = 1'b0; wr_addr = '0; wr_byte_en = '0; wr_data = '0;
    errors = 0;
    for (int i = 0; i < LINE_BYTES; i++) begin
      line0[i*8 +: 8] = 8'h10 + i;
      line1[i*8 +: 8] = 8'ha0 + i;
    end

    repeat (2) @(posedge clk); #1;
    check_ok(!rd_valid, "reset suppresses read valid");
    rst_n = 1'b1;

    // Full line and independent address must not alias.
    line_write(2'd1, '1, line0);
    line_write(2'd2, '1, line1);
    line_read(2'd1, got);
    check_ok(got == line0, "full line readback");
    line_read(2'd2, got);
    check_ok(got == line1, "different line address readback");

    // Merge a sparse byte write into line 1.
    partial_be = '0;
    partial_be[0] = 1'b1;
    partial_be[7] = 1'b1;
    partial_be[42] = 1'b1;
    line0[0*8 +: 8] = 8'he1;
    line0[7*8 +: 8] = 8'he7;
    line0[42*8 +: 8] = 8'hc2;
    line_write(2'd1, partial_be, line0);
    line_read(2'd1, got);
    check_ok(got == line0, "sparse byte-enable merge");

    // Same-address read/write is a legal but unspecified RAM collision.  The
    // cache controllers never rely on its read value; a following read must
    // see the committed write.
    @(negedge clk);
    rd_addr = 2'd1; rd_en = 1'b1;
    wr_addr = 2'd1; wr_byte_en = '1; wr_data = line1; wr_en = 1'b1;
    @(posedge clk); #1;
    check_ok(rd_valid, "same-address collision still returns a read cycle");
    rd_en = 1'b0; wr_en = 1'b0; wr_byte_en = '0;
    line_read(2'd1, got);
    check_ok(got == line1, "same-address write commits new line");

    if (errors == 0) begin
      $display("PASS: lcvex_cache_data_ram_tb");
      $finish;
    end else $fatal(1, "FAIL: %0d errors", errors);
  end
endmodule
