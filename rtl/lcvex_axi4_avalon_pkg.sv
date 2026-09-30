// lcvex_axi4_avalon_pkg.sv
//
// B2-EMIF 的平台适配层常量和地址边界辅助函数。Avalon 的 address 是
// 512-bit word address；它不是 AXI byte address，也不暴露到通用 L2。

`timescale 1ns/1ps

package lcvex_axi4_avalon_pkg;

  /* verilator lint_off UNUSEDPARAM */
  /* verilator lint_off UNUSEDSIGNAL */

  import lcvex_axi4_pkg::*;

  localparam int AVALON_DATA_WIDTH = 512;
  localparam int AVALON_WORD_BYTES = 64;
  localparam int AVALON_BYTEENABLE_WIDTH = 64;
  localparam int AVALON_ADDRESS_WIDTH = 25;
  localparam int AXI_LINE_BYTES = AXI4_CANONICAL_LINE_BYTES;
  localparam int AXI_LINE_OFFSET_WIDTH = 6;

  localparam logic [63:0] AXI_AVALON_BASE_ADDR = 64'h0000_0000_4000_0000;
  localparam logic [63:0] AXI_AVALON_WINDOW_BYTES = 64'h0000_0000_0800_0000;
  localparam logic [63:0] AXI_AVALON_END_ADDR =
      AXI_AVALON_BASE_ADDR + AXI_AVALON_WINDOW_BYTES;

  function automatic logic lcvex_axi4_avalon_window_ok(
      input logic [63:0] addr,
      input logic [7:0] len,
      input logic [2:0] size,
      input logic [1:0] burst
  );
    logic [64:0] transfer_bytes;
    logic [64:0] end_addr;
    logic [64:0] line_offset;
    logic [64:0] beat_bytes;
    begin
      beat_bytes = 65'd1 << size;
      transfer_bytes = ({57'd0, len} + 65'd1) * beat_bytes;
      end_addr = {1'b0, addr} + transfer_bytes;
      line_offset = {1'b0, addr} - {1'b0, AXI_AVALON_BASE_ADDR};

      // The last two checks make the legal request a single 64B Avalon word.
      // The final check also keeps a single AXI beat representable on the
      // 128-bit AXI data bus (an unaligned 16B beat cannot wrap that bus).
      lcvex_axi4_avalon_window_ok =
          (burst == AXI4_BURST_INCR) &&
          (len <= 8'd3) &&
          (size <= 3'd4) &&
          (addr >= AXI_AVALON_BASE_ADDR) &&
          (end_addr <= {1'b0, AXI_AVALON_END_ADDR}) &&
          ({59'd0, line_offset[5:0]} + transfer_bytes <= 65'd64) &&
          ({61'd0, addr[3:0]} + beat_bytes <= 65'd16);
    end
  endfunction

  function automatic logic [AVALON_ADDRESS_WIDTH-1:0]
      lcvex_axi4_to_avalon_address(input logic [63:0] addr);
    logic [63:0] offset;
    begin
      offset = addr - AXI_AVALON_BASE_ADDR;
      lcvex_axi4_to_avalon_address = offset[30:6];
    end
  endfunction

  function automatic logic [63:0] lcvex_axi4_avalon_full_byteenable();
    begin
      lcvex_axi4_avalon_full_byteenable = 64'hffff_ffff_ffff_ffff;
    end
  endfunction

endpackage
