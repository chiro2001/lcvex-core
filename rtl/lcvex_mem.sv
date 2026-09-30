// lcvex_mem.sv
// 1-cycle SRAM：周期 N 发出地址/读写方向/字节使能/写数据，
// 周期 N+1 读数据有效、写完成。按字节编址，地址取低 clog2(DEPTH) 位。

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */  // addr 高位未用：早期按 64K 页映射
module lcvex_mem #(
    parameter int DEPTH = 1 << 16  // 64 KiB
) (
    input  logic        clk,
    input  logic [63:0] addr,
    input  logic        we,
    input  logic [7:0]  strb,
    input  logic [63:0] wdata,
    output logic [63:0] rdata
);

  localparam int AW = $clog2(DEPTH);
  localparam logic [AW-1:0] OFF0 = 0, OFF1 = 1, OFF2 = 2, OFF3 = 3,
                            OFF4 = 4, OFF5 = 5, OFF6 = 6, OFF7 = 7;
  logic [7:0] ram[DEPTH];

  initial begin
    for (int i = 0; i < DEPTH; i++) begin
      ram[i] = 8'h00;
    end
  end

  always_ff @(posedge clk) begin
    logic [AW-1:0] base;
    base = addr[AW-1:0];
    if (we) begin
      for (int i = 0; i < 8; i++) begin
        if (strb[i]) begin
          ram[base + i[AW-1:0]] <= wdata[i*8 +: 8];
        end
      end
    end
    rdata <= {ram[base + OFF7], ram[base + OFF6],
              ram[base + OFF5], ram[base + OFF4],
              ram[base + OFF3], ram[base + OFF2],
              ram[base + OFF1], ram[base + OFF0]};
  end

endmodule
/* verilator lint_on UNUSEDSIGNAL */
