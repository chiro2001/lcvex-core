// lcvex_axi4_pkg.sv
//
// 平台无关的 AMBA AXI4 Full 常量和边界辅助函数。AXI 通道本身保持为
// module 端口，以便 ADDR/DATA/ID 宽度可以独立参数化；本 package 只放
// 不依赖具体宽度的协议编码和 canonical profile 常量。

`timescale 1ns/1ps

package lcvex_axi4_pkg;

  /* verilator lint_off UNUSEDPARAM */

  // AXI4 burst type. B1 master 首版只产生 INCR，但接口保留完整编码。
  localparam logic [1:0] AXI4_BURST_FIXED = 2'b00;
  localparam logic [1:0] AXI4_BURST_INCR  = 2'b01;
  localparam logic [1:0] AXI4_BURST_WRAP  = 2'b10;

  // AXI4 response encoding。
  localparam logic [1:0] AXI4_RESP_OKAY   = 2'b00;
  localparam logic [1:0] AXI4_RESP_EXOKAY = 2'b01;
  localparam logic [1:0] AXI4_RESP_SLVERR = 2'b10;
  localparam logic [1:0] AXI4_RESP_DECERR = 2'b11;

  // AXI4 channel field widths are architectural protocol widths, not the
  // selected data path width.
  localparam int AXI4_LEN_WIDTH  = 8;
  localparam int AXI4_SIZE_WIDTH = 3;
  localparam int AXI4_BURST_WIDTH = 2;
  localparam int AXI4_RESP_WIDTH = 2;

  // LCVEX/Catapult canonical profile。
  localparam int AXI4_CANONICAL_ADDR_WIDTH = 64;
  localparam int AXI4_CANONICAL_DATA_WIDTH = 128;
  localparam int AXI4_CANONICAL_ID_WIDTH   = 4;
  localparam int AXI4_CANONICAL_LINE_BYTES = 64;
  localparam int AXI4_CANONICAL_LINE_BEATS = 4;
  localparam int AXI4_CANONICAL_BEAT_BYTES = 16;
  localparam int AXI4_CANONICAL_BEAT_SIZE  = 4;

  // AXI4 INCR bursts must not cross a 4 KiB boundary. The helper is kept at
  // 64-bit address width because that is the architectural address domain;
  // callers with a narrower ADDR_WIDTH zero-extend their address.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic lcvex_axi4_4k_boundary_ok(
      input logic [63:0] addr,
      input logic [7:0]  len,
      input logic [2:0]  size
  );
    logic [16:0] span_bytes;
    begin
      span_bytes = ({9'd0, len} + 17'd1) << size;
      lcvex_axi4_4k_boundary_ok =
          ({4'd0, 1'b0, addr[11:0]} + span_bytes) <= 17'd4096;
    end
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  function automatic logic lcvex_axi4_is_power_of_two(input int unsigned value);
    begin
      lcvex_axi4_is_power_of_two = (value != 0) && ((value & (value - 1)) == 0);
    end
  endfunction

  /* verilator lint_on UNUSEDPARAM */

endpackage
