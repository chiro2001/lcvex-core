// lcvex_pl011.sv
// PL011 兼容 UART（QEMU virt @0x09000000）的 MMIO 模型。
// 语义按 QEMU 11.1.0 hw/char/pl011.c 逐条复刻（探针实证，见 handoff 036）：
//   - 复位：CR=0x300(TXE|RXE)，其余 0，FR=TXFE|RXFE=0x90（TXFF 从不置位）；
//   - 写 UARTDR：int_level|=INT_TX(0x20)；CR.LBE(bit7) 时数据进入 RX FIFO
//     （回环），深度 = LCR_H.FEN ? 16 : 1；
//   - 读 UARTDR：先读 FIFO 顶再弹；空读返回残留字节（QEMU 同语义）；
//   - FR 读 = TXFE(0x80) | RXFF(0x40) | RXFE(0x10) + LBE 时 CR 调制位映射
//     （RI<-OUT2, DCD<-OUT1, CTS<-RTS, DSR<-DTR）；
//   - 寄存器按字偏移 addr[11:2] 解码；8 字节访问拆成两个字（同 QEMU
//     max_access_size=4 语义：先低字后高字）。
// 地址窗口解码由 lcvex_mem_router 负责，本模块不校验基址。
// 接口与 lcvex_mem_ram 相同（M1-B request/response，1-cycle 读延迟）。

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */
module lcvex_pl011 (
    input  logic                clk,
    input  logic                rst_n,
    // 请求（路由上游 -> 本设备）
    input  logic                req_valid,
    input  lcvex_pkg::mem_req_t req,
    output logic                req_accept,
    // 响应（本设备 -> 路由上游）
    output logic                rsp_valid,
    output lcvex_pkg::mem_rsp_t rsp,
    input  logic                rsp_ready,
    // 控制台输出（观测用，非架构状态）
    output logic                tx_valid,
    output logic [7:0]          tx_char
);

  import lcvex_pkg::*;

  localparam logic [9:0] W_DR    = 10'd0;
  localparam logic [9:0] W_RSR   = 10'd1;
  localparam logic [9:0] W_FR    = 10'd6;
  localparam logic [9:0] W_ILPR  = 10'd8;
  localparam logic [9:0] W_IBRD  = 10'd9;
  localparam logic [9:0] W_FBRD  = 10'd10;
  localparam logic [9:0] W_LCRH  = 10'd11;
  localparam logic [9:0] W_CR    = 10'd12;
  localparam logic [9:0] W_IFLS  = 10'd13;
  localparam logic [9:0] W_IMSC  = 10'd14;
  localparam logic [9:0] W_RIS   = 10'd15;
  localparam logic [9:0] W_MIS   = 10'd16;
  localparam logic [9:0] W_ICR   = 10'd17;
  localparam logic [9:0] W_DMACR = 10'd18;

  // ---- 架构状态 ----
  logic [31:0] cr_r;        // UARTCR（复位 0x300 = TXE|RXE）
  logic [31:0] lcr_r;       // UARTLCR_H
  logic [31:0] ibrd_r;      // UARTIBRD
  logic [31:0] fbrd_r;      // UARTFBRD
  logic [31:0] ilpr_r;      // UARTILPR
  logic [31:0] ifl_r;       // UARTIFLS（复位 0x12）
  logic [31:0] imsc_r;      // UARTIMSC（int_enabled）
  logic [31:0] int_level_r; // UARTRIS（int_level）
  logic [31:0] rsr_r;       // UARTRSR
  logic [31:0] dmacr_r;     // UARTDMACR
  logic [7:0]  read_fifo[16];
  logic [4:0]  read_pos_r;   // 0..15
  logic [4:0]  read_count_r; // 0..16+（QEMU 满时继续写覆盖最旧并自恢复）

  logic        rsp_pending;
  logic [63:0] rdata_r;
  logic        fault_r;

  logic        tx_valid_r;
  logic [7:0]  tx_char_r;

  // FIFO 深度：FEN ? 16 : 1
  logic [4:0] depth;
  assign depth = lcr_r[4] ? 5'd16 : 5'd1;

  // FR 标志（组合）：TXFE 恒 1；RXFE/RXFF 由 read_count 决定；
  // LBE 时 CR 调制位映射（QEMU pl011_loopback_mdmctrl）
  logic [8:0] flags;
  always_comb begin
    flags = 9'h080;              // TXFE
    if (read_count_r == 5'd0) flags[4] = 1'b1;   // RXFE
    if (read_count_r >= depth)  flags[6] = 1'b1; // RXFF
    if (cr_r[7]) begin           // LBE：loopback 调制位
      flags[8] = cr_r[13];       // RI  <- OUT2
      flags[2] = cr_r[12];       // DCD <- OUT1
      flags[0] = cr_r[11];       // CTS <- RTS
      flags[1] = cr_r[10];       // DSR <- DTR
    end
  end

  // ---- 寄存器读（无副作用；DR 副作用在 always_ff 中处理）----
  function automatic logic [31:0] id_reg(input logic [2:0] i);
    case (i)
      3'd0:    id_reg = 32'h00000011;  // PeripheralID0
      3'd1:    id_reg = 32'h00000010;  // PeripheralID1
      3'd2:    id_reg = 32'h00000014;  // PeripheralID2
      3'd3:    id_reg = 32'h00000000;  // PeripheralID3
      3'd4:    id_reg = 32'h0000000D;  // PrimeCellID0
      3'd5:    id_reg = 32'h000000F0;  // PrimeCellID1
      3'd6:    id_reg = 32'h00000005;  // PrimeCellID2
      3'd7:    id_reg = 32'h000000B1;  // PrimeCellID3
    endcase
  endfunction

  function automatic logic [31:0] read_word(input logic [9:0] w);
    case (w)
      W_DR:    read_word = {24'd0, read_fifo[read_pos_r[3:0]]};
      W_RSR:   read_word = rsr_r;
      W_FR:    read_word = {23'd0, flags};
      W_ILPR:  read_word = ilpr_r;
      W_IBRD:  read_word = ibrd_r;
      W_FBRD:  read_word = fbrd_r;
      W_LCRH:  read_word = lcr_r;
      W_CR:    read_word = cr_r;
      W_IFLS:  read_word = ifl_r;
      W_IMSC:  read_word = imsc_r;
      W_RIS:   read_word = int_level_r;
      W_MIS:   read_word = int_level_r & imsc_r;
      W_DMACR: read_word = dmacr_r;
      default: begin
        if (w >= 10'h3F8) begin
          read_word = id_reg(w[2:0]);   // w <= 0x3FF（10 位），恒真
        end else begin
          read_word = 32'd0;
        end
      end
    endcase
  endfunction

  assign req_accept = req_valid && !rsp_pending;
  assign rsp_valid  = rsp_pending;
  assign rsp.rdata  = rdata_r;
  assign rsp.fault  = fault_r;
  assign tx_valid   = tx_valid_r;
  assign tx_char    = tx_char_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cr_r         <= 32'h300;
      lcr_r        <= 32'd0;
      ibrd_r       <= 32'd0;
      fbrd_r       <= 32'd0;
      ilpr_r       <= 32'd0;
      ifl_r        <= 32'h12;
      imsc_r       <= 32'd0;
      int_level_r  <= 32'd0;
      rsr_r        <= 32'd0;
      dmacr_r      <= 32'd0;
      read_pos_r   <= 5'd0;
      read_count_r <= 5'd0;
      rsp_pending  <= 1'b0;
      rdata_r      <= 64'd0;
      fault_r      <= 1'b0;
      tx_valid_r   <= 1'b0;
      tx_char_r    <= 8'd0;
    end else begin
      tx_valid_r <= 1'b0;   // TX 脉冲默认撤销
      if (req_valid && req_accept) begin
        automatic logic [9:0] w   = req.addr[11:2];
        automatic logic [9:0] w2  = req.addr[11:2] + 10'd1;
        automatic logic [31:0] v  = req.wdata[31:0];
        automatic logic [31:0] v2 = req.wdata[63:32];
        automatic logic [3:0] slot;
        rsp_pending <= 1'b1;
        fault_r     <= 1'b0;
        if (!req.we) begin
          // 读：低字（含 DR 副作用）+ 高字（8 字节时）
          rdata_r <= {read_word(w2), read_word(w)};
          if (w == W_DR) begin
            // pl011_read_rxdata：先读再弹；空读返回残留字节
            if (read_count_r > 5'd0) begin
              read_count_r <= read_count_r - 5'd1;
              // QEMU：(pos+1) & (depth-1)，深度 1 时原地回绕（残留可重读）
              read_pos_r   <= (read_pos_r + 5'd1) & (depth - 5'd1);
            end
            if (read_count_r == 5'd1) int_level_r[4] <= 1'b0;  // INT_RX
          end
        end else begin
          rdata_r <= 64'd0;
          // 写：按字宽（8 字节拆低字/高字，与 QEMU max_access_size=4 一致）
          case (w)
            W_DR: begin
              tx_valid_r  <= 1'b1;
              tx_char_r   <= v[7:0];
              int_level_r[5] <= 1'b1;
              if (cr_r[7]) begin
                slot = (read_pos_r[3:0] + read_count_r[3:0]) &
                       (depth[3:0] - 4'd1);
                read_fifo[slot] <= v[7:0];
                read_count_r    <= read_count_r + 5'd1;
                if (read_count_r == 5'd1) int_level_r[4] <= 1'b1;  // INT_RX
              end
            end
            W_RSR:   rsr_r <= 32'd0;                 // ECR：写清零
            W_FR:    ;                                // 忽略
            W_ILPR:  ilpr_r <= v;
            W_IBRD:  ibrd_r <= v & 32'h0000_FFFF;
            W_FBRD:  fbrd_r <= v & 32'h0000_003F;
            W_LCRH:  begin
              if ((lcr_r[4] ^ v[4])) begin           // FEN 切换：重置 RX FIFO
                read_pos_r   <= 5'd0;
                read_count_r <= 5'd0;
              end
              lcr_r <= v;
            end
            W_CR: begin
              cr_r <= v;
              if (v[7]) begin
                // loopback_mdmctrl：调制位中断跟随 CR
                int_level_r[3:0] <= {v[10], v[12], v[11], v[13]};
              end
            end
            W_IFLS:  ifl_r <= v;
            W_IMSC:  imsc_r <= v;
            W_ICR:   int_level_r <= int_level_r & ~v;
            W_DMACR: dmacr_r <= v;
            default: ;
          endcase
          if (req.strb == 8'hFF) begin
            case (w2)
              W_DR: begin
                tx_valid_r  <= 1'b1;
                tx_char_r   <= v2[7:0];
                int_level_r[5] <= 1'b1;
                if (cr_r[7]) begin
                  slot = (read_pos_r[3:0] + read_count_r[3:0]) &
                         (depth[3:0] - 4'd1);
                  read_fifo[slot] <= v2[7:0];
                  read_count_r    <= read_count_r + 5'd1;
                  if (read_count_r == 5'd1) int_level_r[4] <= 1'b1;
                end
              end
              W_RSR:   rsr_r <= 32'd0;
              W_FR:    ;
              W_ILPR:  ilpr_r <= v2;
              W_IBRD:  ibrd_r <= v2 & 32'h0000_FFFF;
              W_FBRD:  fbrd_r <= v2 & 32'h0000_003F;
              W_LCRH:  begin
                if ((lcr_r[4] ^ v2[4])) begin
                  read_pos_r   <= 5'd0;
                  read_count_r <= 5'd0;
                end
                lcr_r <= v2;
              end
              W_CR: begin
                cr_r <= v2;
                if (v2[7]) begin
                  int_level_r[3:0] <= {v2[10], v2[12], v2[11], v2[13]};
                end
              end
              W_IFLS:  ifl_r <= v2;
              W_IMSC:  imsc_r <= v2;
              W_ICR:   int_level_r <= int_level_r & ~v2;
              W_DMACR: dmacr_r <= v2;
              default: ;
            endcase
          end
        end
      end
      if (rsp_pending && rsp_ready) begin
        rsp_pending <= 1'b0;
      end
    end
  end

endmodule
