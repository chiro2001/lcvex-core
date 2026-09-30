// lcvex_alu.sv
// 组合 ALU：ADD/SUB/AND/ORR/EOR/LSL/LSR/ASR/SBFM/UBFM。
// 32 位运算结果零扩展；逻辑指令清零 C、V（A64 语义），
// 核心在 set_flags 时选择 ALU 输出的 C/V，否则保留旧值。

`timescale 1ns/1ps

module lcvex_alu (
    input  lcvex_pkg::alu_op_t op,
    input  logic [63:0]       a,
    input  logic [63:0]       b,
    input  logic [63:0]       c,        // BFM 的旧 Rd（deposit 基础值）
    input  logic              use_shift,
    input  logic [1:0]        shift_type,  // 0=LSL 1=LSR 2=ASR
    input  logic [5:0]        shift_amt,
    input  logic              inv_b,       // 逻辑取反族（BIC/ORN/EON/BICS）
    input  logic [3:0]        ccmp_nzcv_else,  // CCMP/CCMN 条件不满足时 NZCV
    input  logic              ccmp_taken,      // CCMP/CCMN 条件满足
    input  logic              cin,             // ADC/SBC 进位输入（C 标志）
    input  logic              is_32,
    output logic [63:0]       result,
    output logic              flag_n,
    output logic              flag_z,
    output logic              flag_c,
    output logic              flag_v
);

  import lcvex_pkg::*;

  logic [63:0] shift_out, b_eff, r64;
  logic [31:0] a32, b32, r32;
  logic [32:0] add32w, sub32w;
  logic [64:0] add64w, sub64w;
  logic [63:0] bf64;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [63:0] bf32_full;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] bf32;
  logic [63:0] rev64, rev32, rev16;
  logic [63:0] rbit64;
  logic [31:0] rbit32;
  logic [3:0]  cmp_flags, ccmp_flags;

  // 字节反转（QEMU REV16/REV32/REV 语义）：
  //   REV16：每 16 位元素内两字节交换（byte_j <- byte_{j^1}）
  //   REV32：每 32 位元素内四字节反转（byte_j <- byte_{j^3}）
  //   REV（64 位 REV64）：整 64 位字节反转（byte_j <- byte_{7-j}）
  assign rev16 = {a[55:48], a[63:56], a[39:32], a[47:40],
                  a[23:16], a[31:24], a[7:0],   a[15:8]};
  assign rev32 = {a[39:32], a[47:40], a[55:48], a[63:56],
                  a[7:0],   a[15:8],  a[23:16], a[31:24]};
  assign rev64 = {a[7:0],  a[15:8],  a[23:16], a[31:24],
                  a[39:32], a[47:40], a[55:48], a[63:56]};

  // RBIT：按位反转，W 形式只作用于低 32 位并零扩展。
  always_comb begin
    for (int i = 0; i < 64; i++) begin
      rbit64[i] = a[63-i];
    end
    for (int i = 0; i < 32; i++) begin
      rbit32[i] = a[31-i];
    end
  end

  function automatic logic [6:0] clz64(input logic [63:0] x);
    logic found;
    found = 1'b0;
    clz64 = 7'd64;
    for (int i = 63; i >= 0; i--) begin
      if (!found && x[i]) begin
        found = 1'b1;
        clz64 = 7'(63 - i);
      end
    end
  endfunction

  function automatic logic [6:0] cls64(input logic [63:0] x);
    logic found;
    logic sign;
    sign = x[63];
    found = 1'b0;
    cls64 = 7'd63;
    for (int i = 62; i >= 0; i--) begin
      if (!found && x[i] != sign) begin
        found = 1'b1;
        cls64 = 7'(62 - i);
      end
    end
  endfunction

  function automatic logic [5:0] clz32(input logic [31:0] x);
    logic found;
    found = 1'b0;
    clz32 = 6'd32;
    for (int i = 31; i >= 0; i--) begin
      if (!found && x[i]) begin
        found = 1'b1;
        clz32 = 6'(31 - i);
      end
    end
  endfunction

  function automatic logic [5:0] cls32(input logic [31:0] x);
    logic found;
    logic sign;
    sign = x[31];
    found = 1'b0;
    cls32 = 6'd31;
    for (int i = 30; i >= 0; i--) begin
      if (!found && x[i] != sign) begin
        found = 1'b1;
        cls32 = 6'(30 - i);
      end
    end
  endfunction

  // ARM CRC32（IEEE）与 CRC32C（Castagnoli）均采用 reflected LSB-first
  // 多项式；B/H/W/X 依次消耗 Rm 的低字节到高字节，结果始终为 32 位。
  function automatic logic [31:0] crc32_update(
      input logic [31:0] seed,
      input logic [63:0] data,
      input logic [1:0]  size,
      input logic        castagnoli);
    logic [31:0] crc;
    logic [31:0] poly;
    int bytes;
    begin
      crc = seed;
      poly = castagnoli ? 32'h82f6_3b78 : 32'hedb8_8320;
      unique case (size)
        2'd0: bytes = 1;
        2'd1: bytes = 2;
        2'd2: bytes = 4;
        default: bytes = 8;
      endcase
      for (int i = 0; i < 8; i++) begin
        if (i < bytes) begin
          crc = crc ^ {24'd0, data[i*8 +: 8]};
          for (int j = 0; j < 8; j++) begin
            crc = crc[0] ? ((crc >> 1) ^ poly) : (crc >> 1);
          end
        end
      end
      crc32_update = crc;
    end
  endfunction

  // 位域运算（QEMU disas_bitfield 语义）：
  //   si>=ri（提取）：字段 = x[si:ri]，UBFM 零扩展 / SBFM 符号扩展；
  //   si<ri（左移）：字段 = x[si:0] << pos，pos=(ds-ri)&(ds-1)，
  //     SBFM 在 len<ri 时先对 len 位符号扩展再截断到 ri 位。
  function automatic logic [63:0] bitfield_op(
      input logic [63:0] x,
      input logic        sf,
      input logic        sbfm,
      input logic [5:0]  ri,
      input logic [5:0]  si);
    logic [63:0] m, f;
    int len, pos;
    len = (si >= ri) ? (int'(si) - int'(ri) + 1) : (int'(si) + 1);
    pos = (int'(sf ? 64 : 32) - int'(ri)) & (int'(sf ? 64 : 32) - 1);
    m = (len >= 64) ? ~64'd0 : ((64'd1 << len) - 1);
    if (si >= ri) begin
      f = (x >> ri) & m;
      if (sbfm && f[len-1]) f |= ~m;
    end else begin
      f = x & m;
      if (sbfm && f[len-1]) f |= ~m;
      if (sbfm && (len < ri)) begin
        f = f & ((32'(ri) >= 64) ? ~64'd0 : ((64'd1 << 32'(ri)) - 1));
      end
      f = f << pos;
    end
    bitfield_op = f;
  endfunction

  // BFM 位域插入（QEMU trans_BFM 语义）：
  //   si>=ri：Rd[len-1:0] = Rn[si:ri]，len=si-ri+1，pos=0；
  //   si<ri ：Rd[pos+len-1:pos] = Rn[si:0]，len=si+1，
  //           pos=(bitsize-ri)&(bitsize-1)；
  //   字段外保留旧 Rd（deposit），W 形式最终零扩展高 32 位。
  function automatic logic [63:0] bfm_deposit(
      input logic [63:0] x,        // Rn
      input logic [63:0] old_rd,
      input logic        sf,
      input logic [5:0]  ri,
      input logic [5:0]  si);
    int len, pos;
    logic [63:0] fld, mask;
    if (si >= ri) begin
      len = int'(si) - int'(ri) + 1;
      pos = 0;
      fld = x >> ri;
    end else begin
      len = int'(si) + 1;
      pos = (sf ? 64 : 32) - int'(ri) & ((sf ? 64 : 32) - 1);
      fld = x;
    end
    mask = (len >= 64) ? ~64'd0 : ((64'd1 << len) - 1);
    bfm_deposit = (old_rd & ~(mask << pos)) | ((fld & mask) << pos);
  endfunction

  always_comb begin
    shift_out = b;
    if (use_shift) begin
      if (is_32) begin
        // 32 位操作数先零扩展再移位（ARM 语义：W 形式移位只作用于低 32 位）
        // 变量移位（LSLV/LSRV/ASRV）的 32 位形式移位量取 Rm[4:0]（QEMU
        // disas_ldst 同理掩码到 31），避免 Wm=0x21 时 1<<33 得 0。
        unique case (shift_type)
          2'd0: shift_out = {32'd0, b[31:0]} << shift_amt[4:0];
          2'd1: shift_out = {32'd0, b[31:0]} >> shift_amt[4:0];
          2'd2: shift_out = 64'($signed(b[31:0]) >>> shift_amt[4:0]);
          2'd3: begin
            automatic logic [4:0] amt = shift_amt[4:0];
            shift_out = ({32'd0, b[31:0]} >> amt) |
                        ({32'd0, b[31:0]} << ((6'd32 - amt) & 6'h1F));
          end
          default: shift_out = 64'd0;
        endcase
      end else begin
        unique case (shift_type)
          2'd0: shift_out = b << shift_amt;
          2'd1: shift_out = b >> shift_amt;
          2'd2: shift_out = $signed(b) >>> shift_amt;
          2'd3: begin
            automatic logic [5:0] amt = shift_amt[5:0];
            shift_out = (b >> amt) |
                        (b << ((7'd64 - amt) & 7'h3F));
          end
          default: shift_out = 64'd0;
        endcase
      end
    end
  end

  assign b_eff = inv_b ? ~shift_out : shift_out;
  assign a32 = a[31:0];
  assign b32 = b_eff[31:0];

  assign add32w = {1'b0, a32} + {1'b0, b32};
  assign sub32w = {1'b0, a32} - {1'b0, b32};
  assign add64w = {1'b0, a} + {1'b0, b_eff};
  assign sub64w = {1'b0, a} - {1'b0, b_eff};
  // ADC/SBC：cin 为上一指令 C。SBC 用 a + ~b + cin（等价 a-b-1+C）。
  // 0+32-bit and 0+64-bit operands produce 33/65 bits; keeping one extra
  // unused bit turns Verilator's -Wall UNUSEDSIGNAL into a fatal lint error.
  logic [32:0] addc32w, subc32w;
  logic [64:0] addc64w, subc64w;
  assign addc32w = {1'b0, a32} + {1'b0, b32} + cin;
  assign subc32w = {1'b0, a32} + {1'b0, ~b32} + cin;
  assign addc64w = {1'b0, a} + {1'b0, b_eff} + cin;
  assign subc64w = {1'b0, a} + {1'b0, ~b_eff} + cin;

  always_comb begin
    r32 = 32'd0;
    r64 = 64'd0;
    bf64 = 64'd0;
    bf32_full = 64'd0;
    bf32 = 32'd0;
    unique case (op)
      ALU_ADD: begin
        r64 = add64w[63:0];
        r32 = add32w[31:0];
      end
      ALU_SUB: begin
        r64 = sub64w[63:0];
        r32 = sub32w[31:0];
      end
      ALU_ADC: begin
        r64 = addc64w[63:0];
        r32 = addc32w[31:0];
      end
      ALU_SBC: begin
        r64 = subc64w[63:0];
        r32 = subc32w[31:0];
      end
      ALU_AND: begin
        r64 = a & b_eff;
        r32 = a32 & b32;
      end
      ALU_ORR: begin
        r64 = a | b_eff;
        r32 = a32 | b32;
      end
      ALU_EOR: begin
        r64 = a ^ b_eff;
        r32 = a32 ^ b32;
      end
      ALU_LSL, ALU_LSR, ALU_ASR, ALU_ROR: begin
        r64 = shift_out;
        r32 = shift_out[31:0];
      end
      ALU_SBFM, ALU_UBFM: begin
        bf64 = bitfield_op(a, 1'b1, (op == ALU_SBFM), b[11:6], b[5:0]);
        bf32_full = bitfield_op(a, 1'b0, (op == ALU_SBFM),
                                b[11:6], b[5:0]);
        bf32 = bf32_full[31:0];
        r64 = bf64;
        r32 = bf32;
      end
      ALU_CSEL: begin
        // 条件选择：decode 已把 cond 真/假分支合并进 a，这里透传。
        r64 = a;
        r32 = a32;
      end
      ALU_BFM: begin
        bf64 = bfm_deposit(a, c, 1'b1, b[11:6], b[5:0]);
        bf32_full = bfm_deposit(a, c, 1'b0, b[11:6], b[5:0]);
        bf32 = bf32_full[31:0];
        r64 = bf64;
        r32 = bf32;
      end
      ALU_REV16: begin
        r64 = rev16;
        r32 = {a[23:16], a[31:24], a[7:0], a[15:8]};
      end
      ALU_REV32: begin
        r64 = rev32;
        r32 = {a[7:0], a[15:8], a[23:16], a[31:24]};
      end
      ALU_REV: begin
        r64 = rev64;
        r32 = {a[7:0], a[15:8], a[23:16], a[31:24]};
      end
      ALU_RBIT: begin
        r64 = rbit64;
        r32 = rbit32;
      end
      ALU_EXTR: begin
        // EXTR Xd, Xn, Xm, #lsb = {Xn, Xm} >> lsb；低半部为 Xm，
        // 因而 lsb=0 时结果是 Xm。W 形式同样在 32 位拼接域内截取，
        // 不能把 64 位高半部带入结果。
        if (c == 64'd0) begin
          r64 = b;
        end else if (is_32) begin
          r64 = {32'd0, (a[31:0] << (32 - c[4:0])) |
                         (b[31:0] >> c[4:0])};
        end else begin
          r64 = (a << (64 - c[5:0])) | (b >> c[5:0]);
        end
        r32 = r64[31:0];
      end
      ALU_CLZ: begin
        r64 = {57'd0, clz64(a)};
        r32 = {26'd0, clz32(a[31:0])};
      end
      ALU_CLS: begin
        r64 = {57'd0, cls64(a)};
        r32 = {26'd0, cls32(a[31:0])};
      end
      ALU_CRC: begin
        r32 = crc32_update(a[31:0], b, shift_amt[1:0], inv_b);
        r64 = {32'd0, r32};
      end
      ALU_CCMP, ALU_CCMN: begin
        r64 = 64'd0;   // 只更新 NZCV，无 GPR 写回
        r32 = 32'd0;
      end
      default: ;
    endcase
  end

  assign result = is_32 ? {32'd0, r32} : r64;

  // 比较类（CCMP=减法、CCMN=加法）标志与 ADD/SUB 共用，再由条件选择；
  // ADC/SBC 用带进位/借位的独立加法器。
  logic is_add_like;
  assign is_add_like = (op inside {ALU_ADD, ALU_CCMN, ALU_ADC});
  logic is_sub_like;
  assign is_sub_like = (op inside {ALU_SUB, ALU_CCMP, ALU_SBC});
  assign cmp_flags[3] = is_add_like
                        ? (op == ALU_ADC
                           ? (is_32 ? addc32w[31] : addc64w[63])
                           : (is_32 ? add32w[31] : add64w[63]))
                        : (op == ALU_SBC
                           ? (is_32 ? subc32w[31] : subc64w[63])
                           : (is_32 ? sub32w[31] : sub64w[63]));
  assign cmp_flags[2] = is_add_like
                        ? (op == ALU_ADC
                           ? (is_32 ? (addc32w[31:0] == 32'd0)
                                    : (addc64w[63:0] == 64'd0))
                           : (is_32 ? (add32w[31:0] == 32'd0)
                                    : (add64w[63:0] == 64'd0)))
                        : (op == ALU_SBC
                           ? (is_32 ? (subc32w[31:0] == 32'd0)
                                    : (subc64w[63:0] == 64'd0))
                           : (is_32 ? (sub32w[31:0] == 32'd0)
                                    : (sub64w[63:0] == 64'd0)));
  assign cmp_flags[1] = is_add_like
                        ? (op == ALU_ADC
                           ? (is_32 ? addc32w[32] : addc64w[64])
                           : (is_32 ? add32w[32] : add64w[64]))
                        : is_sub_like
                          ? (op == ALU_SBC
                             ? (is_32 ? subc32w[32] : subc64w[64])
                             : (is_32 ? ~sub32w[32] : ~sub64w[64]))
                          : 1'b0;
  assign cmp_flags[0] = is_add_like
                        ? (op == ALU_ADC
                           ? (is_32 ? ((a32[31] == b32[31]) &&
                                       (addc32w[31] != a32[31]))
                                    : ((a[63] == b_eff[63]) &&
                                       (addc64w[63] != a[63])))
                           : (is_32 ? ((a32[31] == b32[31]) &&
                                       (add32w[31] != a32[31]))
                                    : ((a[63] == b_eff[63]) &&
                                       (add64w[63] != a[63]))))
                        : is_sub_like
                          ? (op == ALU_SBC
                             ? (is_32 ? ((a32[31] != b32[31]) &&
                                         (subc32w[31] != a32[31]))
                                      : ((a[63] != b_eff[63]) &&
                                         (subc64w[63] != a[63])))
                             : (is_32 ? ((a32[31] != b32[31]) &&
                                         (sub32w[31] != a32[31]))
                                      : ((a[63] != b_eff[63]) &&
                                         (sub64w[63] != a[63]))))
                          : 1'b0;

  assign ccmp_flags = (op inside {ALU_CCMP, ALU_CCMN})
                      ? (ccmp_taken ? cmp_flags : ccmp_nzcv_else)
                      : cmp_flags;

  assign flag_n = (op inside {ALU_CCMP, ALU_CCMN}) ? ccmp_flags[3]
                                                    : (is_32 ? result[31]
                                                             : result[63]);
  assign flag_z = (op inside {ALU_CCMP, ALU_CCMN}) ? ccmp_flags[2]
                                                    : (result == 64'd0);
  assign flag_c = (op inside {ALU_CCMP, ALU_CCMN}) ? ccmp_flags[1]
                                                    : cmp_flags[1];
  assign flag_v = (op inside {ALU_CCMP, ALU_CCMN}) ? ccmp_flags[0]
                                                    : cmp_flags[0];

endmodule
