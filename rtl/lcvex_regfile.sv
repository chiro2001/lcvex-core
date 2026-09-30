// lcvex_regfile.sv
// AArch64 通用寄存器堆：x0~x30。x31（XZR）不存储，读恒为 0，写丢弃。

`timescale 1ns/1ps

module lcvex_regfile (
    input  logic        clk,
    input  logic [4:0]  rs1,
    input  logic [4:0]  rs2,
    input  logic [4:0]  rd,
    input  logic        we,
    input  logic [63:0] wdata,
    output logic [63:0] rs1_data,
    output logic [63:0] rs2_data
);

  logic [63:0] regs[31];

  assign rs1_data = (rs1 == 5'd31) ? 64'd0 : regs[rs1];
  assign rs2_data = (rs2 == 5'd31) ? 64'd0 : regs[rs2];

  always_ff @(posedge clk) begin
    if (we && rd != 5'd31) begin
      regs[rd] <= wdata;
    end
  end

endmodule
