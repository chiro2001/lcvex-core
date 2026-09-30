// lcvex_muldiv.sv
// 多周期乘除法（P3 Gate B）：移位累加乘法 + 恢复余数除法 + 乘加族。
//   op: 0=MUL 1=UDIV 2=SDIV 3=MADD 4=MSUB 5=SMADDL 6=SMSUBL
//       7=UMADDL 8=UMSUBL 9=UMULH 10=SMULH
//   is_32: 32 位操作（32 周期），否则 64 位（64 周期）。
//   acc: MADD 族加数（Ra；MUL/除法忽略）。
// 乘加族：MADD/MSUB 为同宽乘加；SMADDL/UMADDL 为 32x32->64（Rn/Rm 按
// 有/无符号扩展到 64 后做 64 位移位累加，再 +/- Ra）。
// 时序：最后一个计算周期（cnt==width-1）组合输出 done=1 和最终结果，
// 核心在同一拍推进 EX/MEM 与取指，避免完成拍重复取指。
// 除法：除零结果为 0（A64 语义）；SDIV 按绝对值运算、商符号由两操作数
// 符号决定，INT_MIN/-1 自然得到 0x8000...0 位型。

`timescale 1ns/1ps

module lcvex_muldiv (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,     // 乘除指令进入 EX 槽（一拍脉冲）
    input  logic        kill,      // 取消尚未提交的请求（仅由年龄边界驱动）
    input  logic [3:0]  op,        // 0..10
    input  logic        is_32,
    input  logic [63:0] a,
    input  logic [63:0] b,
    input  logic [63:0] acc,       // MADD 族加数（Ra）
    output logic        busy,      // 运算中
    output logic        done,      // 最后一个计算周期（组合，供核心推进）
    output logic [63:0] result     // 最后一个计算周期为最终结果（组合）
);

  // 请求先在 EX 入口捕获，下一拍再启动迭代器。这样乘法器/DSP 的使能、
  // 操作码和操作数均来自寄存器，不再直接扇出当前 ID/EX live 信号。
  logic        pending_r;
  logic [3:0]  op_req_r;
  logic        is_32_req_r;
  logic [63:0] a_req_r;
  logic [63:0] b_req_r;
  logic [63:0] acc_req_r;
  logic [6:0]  cnt_r;
  logic [3:0]  op_r;
  logic        is_32_r;
  logic        zero_r;        // 除零标记：结果 0
  logic [63:0] a_r;           // 乘法：被乘数（每周期左移）；除法：被除数移位
  logic [63:0] b_r;           // 乘法：乘数（右移）；除法：除数（不变）
  logic [63:0]  acc_r;        // 乘法累积（模 2^64，只取低 64 位乘积）
  logic [127:0] umulh_acc_r;  // UMULH 128 位乘积累积
  logic [127:0] umulh_a_r;    // UMULH 左移中的 128 位被乘数
  logic signed [63:0] smulh_a_r;
  logic signed [63:0] smulh_b_r;
  logic         q_neg_r;       // SDIV 商符号（由捕获的请求决定）
  logic         sub_mode;     // MSUB 族：acc - a*b
  logic [63:0] rem_r;         // 除法余数（恢复除法保证 rem < divisor）
  logic [62:0] quot_r;        // 除法商（最后一位置入 comb）
  logic        busy_r;

  wire logic [6:0] last = is_32_r ? 7'd31 : 7'd63;
  wire logic [6:0] last_req = is_32_req_r ? 7'd31 : 7'd63;

  // SDIV 启动时把捕获的操作数转成幅值。所有这些组合项只看 pending
  // 请求寄存器；launch 后 active 结果只看 *_r 状态。
  logic [63:0] a_mag_req, b_mag_req;
  logic [63:0] a_in_req, b_in_req;
  wire sign_a_req = is_32_req_r ? a_req_r[31] : a_req_r[63];
  wire sign_b_req = is_32_req_r ? b_req_r[31] : b_req_r[63];
  wire [31:0] a_neg32_req = (~a_req_r[31:0] + 32'd1);
  wire [31:0] b_neg32_req = (~b_req_r[31:0] + 32'd1);
  // 32 位操作只用低 32 位（有符号则按位 31 判负取幅值）
  wire [63:0] a_lo_req = {32'd0, a_req_r[31:0]};
  wire [63:0] b_lo_req = {32'd0, b_req_r[31:0]};
  assign a_mag_req = sign_a_req ?
                       (is_32_req_r ? {32'd0, a_neg32_req} : (~a_req_r + 64'd1))
                       : (is_32_req_r ? a_lo_req : a_req_r);
  assign b_mag_req = sign_b_req ?
                       (is_32_req_r ? {32'd0, b_neg32_req} : (~b_req_r + 64'd1))
                       : (is_32_req_r ? b_lo_req : b_req_r);
  // SMADDL/SMSUBL：Rn/Rm 符号扩展；UMADDL/UMSUBL：零扩展
  wire [63:0] a_sext_req = {{32{a_req_r[31]}}, a_req_r[31:0]};
  wire [63:0] b_sext_req = {{32{b_req_r[31]}}, b_req_r[31:0]};
  wire [63:0] a_zext_req = {32'd0, a_req_r[31:0]};
  wire [63:0] b_zext_req = {32'd0, b_req_r[31:0]};
  assign a_in_req = (op_req_r == 4'd2) ? a_mag_req :
                    (op_req_r inside {4'd5, 4'd6}) ? a_sext_req :
                    (op_req_r inside {4'd7, 4'd8}) ? a_zext_req :
                    (is_32_req_r ? a_lo_req : a_req_r);
  assign b_in_req = (op_req_r == 4'd2) ? b_mag_req :
                    (op_req_r inside {4'd5, 4'd6}) ? b_sext_req :
                    (op_req_r inside {4'd7, 4'd8}) ? b_zext_req :
                    (is_32_req_r ? b_lo_req : b_req_r);
  assign sub_mode = (op_r inside {4'd4, 4'd6, 4'd8});

  // 恢复除法的移位余数（rem<<1 | 被除数 MSB），可能到 65 位
  wire n_bit = is_32_r ? a_r[31] : a_r[63];
  wire [64:0] rem_shifted = {rem_r, n_bit};
  // 减法结果必小于 divisor < 2^64（恢复除法不变式）
  wire [63:0] rem_sub = 64'(rem_shifted - {1'b0, b_r});
  wire        div_qbit = (rem_shifted >= {1'b0, b_r});

  // 最后一个计算周期的组合最终结果
  logic [63:0]  mul_comb;
  logic [127:0] umulh_comb;
  logic signed [127:0] smulh_comb;
  logic [63:0]  quot_comb;
  logic [63:0]  result_comb;
  assign mul_comb = sub_mode
                    ? (acc_r - (b_r[0] ? a_r : 64'd0))
                    : (acc_r + (b_r[0] ? a_r : 64'd0));
  assign umulh_comb = umulh_acc_r + (b_r[0] ? umulh_a_r : 128'd0);
  assign smulh_comb = smulh_a_r * smulh_b_r;
  assign quot_comb = {quot_r[62:0], div_qbit};
  assign result_comb = zero_r ? 64'd0 :
                       // 低 64 位以自异或形式显式参与表达式，避免 lint 将
                       // 128 位加法器的低半部分判为未使用；结果恒为 0。
                       (op_r == 4'd9) ?
                         (umulh_comb[127:64] | (umulh_comb[63:0] ^ umulh_comb[63:0])) :
                       (op_r == 4'd10) ?
                         (smulh_comb[127:64] |
                          (smulh_comb[63:0] ^ smulh_comb[63:0])) :
                       (op_r inside {4'd0, 4'd3, 4'd4}) ?
                         (is_32_r ? {32'd0, mul_comb[31:0]} : mul_comb[63:0]) :
                       (op_r inside {4'd5, 4'd6, 4'd7, 4'd8})
                         ? mul_comb[63:0] :
                       (q_neg_r
                         ? (is_32_r
                            ? {32'd0, (~quot_comb[31:0] + 32'd1)}
                            : (~quot_comb + 64'd1))
                         : quot_comb);

  assign busy = pending_r || busy_r;
  assign done = busy_r && (cnt_r == last);
  assign result = (busy_r && (cnt_r == last)) ? result_comb : 64'd0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pending_r <= 1'b0;
      op_req_r  <= 4'd0;
      is_32_req_r <= 1'b0;
      a_req_r   <= 64'd0;
      b_req_r   <= 64'd0;
      acc_req_r <= 64'd0;
      cnt_r   <= 7'd0;
      op_r    <= 4'd0;
      is_32_r <= 1'b0;
      zero_r  <= 1'b0;
      a_r     <= 64'd0;
      b_r     <= 64'd0;
      acc_r   <= 64'd0;
      umulh_acc_r <= 128'd0;
      umulh_a_r   <= 128'd0;
      smulh_a_r   <= 64'sd0;
      smulh_b_r   <= 64'sd0;
      rem_r   <= 64'd0;
      quot_r  <= 63'd0;
      q_neg_r <= 1'b0;
      busy_r  <= 1'b0;
    end else if (kill) begin
      // kill 只来自已有恢复/异常边界，且 core 已按年龄关系确认当前
      // muldiv 是该边界的年轻未提交请求；普通 branch flush/irq_taken
      // 不在此列。清空 pending/active 及组合结果输入，避免幽灵完成。
      pending_r <= 1'b0;
      op_req_r  <= 4'd0;
      is_32_req_r <= 1'b0;
      a_req_r   <= 64'd0;
      b_req_r   <= 64'd0;
      acc_req_r <= 64'd0;
      busy_r    <= 1'b0;
      cnt_r     <= 7'd0;
      zero_r    <= 1'b0;
      q_neg_r   <= 1'b0;
      op_r      <= 4'd0;
      is_32_r   <= 1'b0;
      a_r       <= 64'd0;
      b_r       <= 64'd0;
      acc_r     <= 64'd0;
      umulh_acc_r <= 128'd0;
      umulh_a_r   <= 128'd0;
      smulh_a_r   <= 64'sd0;
      smulh_b_r   <= 64'sd0;
      rem_r      <= 64'd0;
      quot_r     <= 63'd0;
    end else if (start && !pending_r && !busy_r) begin
      // EX request capture；实际运算至少晚一拍 launch。
      pending_r   <= 1'b1;
      op_req_r    <= op;
      is_32_req_r <= is_32;
      a_req_r     <= a;
      b_req_r     <= b;
      acc_req_r   <= acc;
    end else if (pending_r && !busy_r) begin
      // pending -> active launch。last_req 避免宽度切换时使用旧 is_32_r。
      pending_r <= 1'b0;
      op_r     <= op_req_r;
      is_32_r  <= is_32_req_r;
      a_r      <= a_in_req;
      b_r      <= b_in_req;
      // MADD 族以 Ra 为初始累加值（MSUB 族在其上减乘积）
      acc_r    <= (op_req_r inside {4'd3, 4'd4, 4'd5, 4'd6, 4'd7, 4'd8})
                  ? (is_32_req_r ? {32'd0, acc_req_r[31:0]} : acc_req_r) : 64'd0;
      umulh_acc_r <= 128'd0;
      umulh_a_r   <= {64'd0, a_req_r};
      smulh_a_r   <= $signed(a_req_r);
      smulh_b_r   <= $signed(b_req_r);
      rem_r    <= 64'd0;
      quot_r   <= 63'd0;
      q_neg_r  <= (op_req_r == 4'd2) && (sign_a_req != sign_b_req);
      if ((op_req_r inside {4'd1, 4'd2}) && (b_in_req == 64'd0)) begin
        // 除零（仅 UDIV/SDIV）：保留既有迭代槽位，结果为 0。
        // 注意 MADD 族 b=0 时结果是 Ra，必须走正常移位累加路径。
        zero_r <= 1'b1;
        cnt_r  <= last_req;
        busy_r <= 1'b1;
      end else begin
        zero_r <= 1'b0;
        cnt_r  <= 7'd0;
        busy_r <= 1'b1;
      end
    end else if (busy_r) begin
      if (cnt_r == last) begin
        // 最后一个计算周期：结果已组合就绪，登记后结束
        busy_r <= 1'b0;
      end else begin
        if (op_r inside {4'd9, 4'd10}) begin
          // UMULH：保留完整 128 位移位累加；SMULH 使用锁存的有符号
          // 原始操作数，结果组合计算，仍占用相同的 64 周期槽位。
          if (op_r == 4'd9) begin
            if (b_r[0]) umulh_acc_r <= umulh_acc_r + umulh_a_r;
            umulh_a_r <= umulh_a_r << 1;
            b_r <= b_r >> 1;
          end
        end else if (op_r inside {4'd0, 4'd3, 4'd4, 4'd5, 4'd6, 4'd7, 4'd8}) begin
          // 乘法：b 当前最低位为 1 则累加（a 已按位左移）
          if (b_r[0]) begin
            acc_r <= sub_mode ? (acc_r - a_r) : (acc_r + a_r);
          end
          a_r <= a_r << 1;
          b_r <= b_r >> 1;
        end else begin
          // 恢复余数除法：rem = (rem<<1) | n_MSB；够减则商位 1
          if (div_qbit) begin
            rem_r  <= rem_sub;
            quot_r <= {quot_r[61:0], 1'b1};
          end else begin
            rem_r  <= rem_shifted[63:0];
            quot_r <= {quot_r[61:0], 1'b0};
          end
          a_r <= a_r << 1;
        end
        cnt_r <= cnt_r + 7'd1;
      end
    end
  end

endmodule
