// lcvex_crc_tb.sv
// P6：CRC32/CRC32C B/H/W/X 的独立 ALU 单元测试。

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */

module lcvex_crc_tb;
  import lcvex_pkg::*;

  logic [63:0] a, b, c, result;
  logic use_shift, inv_b, is_32;
  logic [1:0] shift_type;
  logic [5:0] shift_amt;
  logic [3:0] ccmp_nzcv_else;
  logic ccmp_taken;
  alu_op_t op;
  logic flag_n, flag_z, flag_c, flag_v;
  int errors = 0;

  lcvex_alu dut (
      .op, .a, .b, .c, .use_shift, .shift_type, .shift_amt, .inv_b,
      .ccmp_nzcv_else, .ccmp_taken, .is_32, .cin(1'b0),
      .result, .flag_n, .flag_z, .flag_c, .flag_v
  );

  task automatic check_crc(input logic [1:0] size, input logic castagnoli,
                           input logic [31:0] want, input string name);
    shift_amt = {4'd0, size};
    inv_b = castagnoli;
    #1;
    if (result !== {32'd0, want}) begin
      $display("FAIL: %s result=0x%h want=0x%08h", name, result, want);
      errors++;
    end
  endtask

  initial begin
    $display("=== lcvex_crc_tb: CRC32/CRC32C ===");
    op = ALU_CRC;
    a = 64'h0000_0000_ffff_ffff;
    b = 64'h0123_4567_89ab_cdef;
    c = 64'd0;
    use_shift = 1'b0;
    shift_type = 2'd0;
    ccmp_nzcv_else = 4'd0;
    ccmp_taken = 1'b0;
    is_32 = 1'b1;

    // CRC32 IEEE，data=ef/cdef/89abcdef/0123456789abcdef。
    check_crc(2'd0, 1'b0, 32'h1d48_ef9b, "crc32b");
    check_crc(2'd1, 1'b0, 32'h8215_bc2e, "crc32h");
    check_crc(2'd2, 1'b0, 32'h1047_2a38, "crc32w");
    check_crc(2'd3, 1'b0, 32'hbbc4_1db8, "crc32x");
    // CRC32C Castagnoli。
    check_crc(2'd0, 1'b1, 32'h10a1_3890, "crc32cb");
    check_crc(2'd1, 1'b1, 32'hee1d_3738, "crc32ch");
    check_crc(2'd2, 1'b1, 32'hee8c_8012, "crc32cw");
    check_crc(2'd3, 1'b1, 32'h9a4f_27dc, "crc32cx");

    if (errors == 0) begin
      $display("PASS: lcvex_crc_tb 全部通过");
      $finish;
    end else begin
      $fatal(1, "FAIL: %0d 处错误", errors);
    end
  end
endmodule
