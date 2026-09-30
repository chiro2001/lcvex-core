// lcvex_neon_int.sv
//
// P7-2：受限 Advanced SIMD/Q 整数执行单元。
// 所有运算都在固定宽度 raw bits 上进行；这里没有 host SIMD、real 或
// 浮点运算。Q 寄存器的 lane 方向遵循 AArch64 little-endian 约定：lane 0
// 位于最低有效位，结果比较为对应 lane 的全 1/全 0。

`timescale 1ns/1ps

module lcvex_neon_int (
    input  logic                 valid,
    input  lcvex_pkg::neon_op_t  op,
    input  logic [1:0]           size,       // 0=B, 1=H, 2=S, 3=D
    input  logic [6:0]           shift_amt,
    input  logic                 quad,       // B2c: 1=128-bit, 0=low-64 only
    input  logic [127:0]         operand_a,
    input  logic [127:0]         operand_b,
    output logic [127:0]         result
);

  import lcvex_pkg::*;

  function automatic integer lane_count(input logic [1:0] lane_size);
    unique case (lane_size)
      2'd0: lane_count = 16;
      2'd1: lane_count = 8;
      2'd2: lane_count = 4;
      default: lane_count = 2;
    endcase
  endfunction

  function automatic logic [63:0] lane_unsigned(
      input logic [127:0] value,
      input integer       index,
      input logic [1:0]   lane_size);
    unique case (lane_size)
      2'd0: begin
        // 8-bit lanes are 0..15; keep the read slice in range.
        if (index < 16)
          lane_unsigned = {56'd0, value[index * 8  +: 8]};
        else
          lane_unsigned = 64'd0;
      end
      2'd1: begin
        // 16-bit lanes are 0..7; keep the read slice in range.
        if (index < 8)
          lane_unsigned = {48'd0, value[index * 16 +: 16]};
        else
          lane_unsigned = 64'd0;
      end
      2'd2: begin
        // 32-bit lanes are 0..3; keep the read slice in range.
        if (index < 4)
          lane_unsigned = {32'd0, value[index * 32 +: 32]};
        else
          lane_unsigned = 64'd0;
      end
      default: begin
        // 64-bit lanes are only 0 and 1; keep the read slice in range.
        if (index < 2)
          lane_unsigned = value[index * 64 +: 64];
        else
          lane_unsigned = 64'd0;
      end
    endcase
  endfunction

  function automatic logic signed [63:0] lane_signed(
      input logic [127:0] value,
      input integer       index,
      input logic [1:0]   lane_size);
    logic [63:0] u;
    begin
      u = lane_unsigned(value, index, lane_size);
      unique case (lane_size)
        2'd0: lane_signed = {{56{u[7]}},  u[7:0]};
        2'd1: lane_signed = {{48{u[15]}}, u[15:0]};
        2'd2: lane_signed = {{32{u[31]}}, u[31:0]};
        default: lane_signed = u;
      endcase
    end
  endfunction

  function automatic logic [63:0] lane_mask(input logic [1:0] lane_size);
    unique case (lane_size)
      2'd0: lane_mask = 64'h0000_0000_0000_00ff;
      2'd1: lane_mask = 64'h0000_0000_0000_ffff;
      2'd2: lane_mask = 64'h0000_0000_ffff_ffff;
      default: lane_mask = 64'hffff_ffff_ffff_ffff;
    endcase
  endfunction

  function automatic logic [127:0] set_lane(
      input logic [127:0] value,
      input integer       index,
      input logic [1:0]   lane_size,
      input logic [63:0]  lane_value);
    begin
      set_lane = value;
      unique case (lane_size)
        2'd0: begin
          // 8-bit lanes are 0..15; do not write an out-of-range slice.
          if (index < 16)
            set_lane[index * 8  +: 8] = lane_value[7:0];
        end
        2'd1: begin
          // 16-bit lanes are 0..7; do not write an out-of-range slice.
          if (index < 8)
            set_lane[index * 16 +: 16] = lane_value[15:0];
        end
        2'd2: begin
          // 32-bit lanes are 0..3; do not write an out-of-range slice.
          if (index < 4)
            set_lane[index * 32 +: 32] = lane_value[31:0];
        end
        default: begin
          // 64-bit lanes are only 0 and 1; do not write an out-of-range
          // index*64 slice. Invalid indices leave the destination unchanged.
          if (index < 2)
            set_lane[index * 64 +: 64] = lane_value[63:0];
        end
      endcase
    end
  endfunction

  function automatic logic [63:0] lane_result(
      input neon_op_t          lane_op,
      input logic [1:0]        lane_size,
      input logic [6:0]        amount,
      input logic [63:0]       a_u,
      input logic [63:0]       b_u);
    logic signed [63:0] a_s;
    logic signed [63:0] b_s;
    logic               predicate;
    begin
      a_s = lane_signed({64'd0, a_u}, 0, lane_size);
      b_s = lane_signed({64'd0, b_u}, 0, lane_size);
      lane_result = 64'd0;
      predicate = 1'b0;
      unique case (lane_op)
        NEON_OP_ADD:  lane_result = a_u + b_u;
        NEON_OP_SUB:  lane_result = a_u - b_u;
        NEON_OP_SHL:  lane_result = a_u << amount;
        NEON_OP_SSHR: lane_result = a_s >>> amount;
        NEON_OP_USHR: lane_result = a_u >> amount;
        NEON_OP_SSRA: lane_result = b_u + (a_s >>> amount);
        NEON_OP_USRA: lane_result = b_u + (a_u >> amount);
        NEON_OP_CMEQ: begin
          predicate = (a_u == b_u);
          lane_result = predicate ? lane_mask(lane_size) : 64'd0;
        end
        NEON_OP_CMGE: begin
          predicate = (a_s >= b_s);
          lane_result = predicate ? lane_mask(lane_size) : 64'd0;
        end
        NEON_OP_CMGT: begin
          predicate = (a_s > b_s);
          lane_result = predicate ? lane_mask(lane_size) : 64'd0;
        end
        NEON_OP_CMHI: begin
          predicate = (a_u > b_u);
          lane_result = predicate ? lane_mask(lane_size) : 64'd0;
        end
        NEON_OP_CMHS: begin
          predicate = (a_u >= b_u);
          lane_result = predicate ? lane_mask(lane_size) : 64'd0;
        end
        default: lane_result = 64'd0;
      endcase
    end
  endfunction

  always_comb begin
    result = 128'd0;
    if (valid) begin
      if (op == NEON_OP_DUP_SCALAR || op == NEON_OP_DUP_ELEMENT) begin
        // B2c: DUP replicates a scalar or one source vector lane to every
        // destination lane. Q=0 writes only the low 64 bits (high half zero).
        automatic logic [63:0] lane_value;
        automatic integer nlanes;
        lane_value = (op == NEON_OP_DUP_SCALAR)
                     ? lane_unsigned(operand_a, 0, size)
                     : lane_unsigned(operand_b, int'(shift_amt), size);
        nlanes = quad ? lane_count(size) : (lane_count(size) >> 1);
        for (int i = 0; i < 16; i++) begin
          if (i < nlanes)
            result = set_lane(result, i, size, lane_value);
        end
      end else begin
        unique case (op)
          NEON_OP_MOV: result = operand_a;
          NEON_OP_AND: result = operand_a & operand_b;
          NEON_OP_ORR: result = operand_a | operand_b;
          NEON_OP_EOR: result = operand_a ^ operand_b;
          NEON_OP_BIC: result = operand_a & ~operand_b;
          NEON_OP_ORN: result = operand_a | ~operand_b;
          default: begin
            // The loop is fixed at 16 iterations for synthesis. set_lane and
            // lane_unsigned select only the legal fixed-width lane slice.
            for (int i = 0; i < 16; i++) begin
              if (i < lane_count(size)) begin
                result = set_lane(result, i, size,
                                  lane_result(op, size, shift_amt,
                                    lane_unsigned(operand_a, i, size),
                                    lane_unsigned(operand_b, i, size)));
              end
            end
          end
        endcase
      end
    end
  end

endmodule
