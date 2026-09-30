// lcvex_pl061.sv
// QEMU virt @0x09030000 的 ARM PrimeCell PL061 GPIO 最小模型。
//
// P6 范围：复刻 Linux early boot/probe 会访问的数据、方向、基础中断控制与
// PrimeCell ID 寄存器。virt 机器把未驱动 GPIO 配为 pull-down，因此输入复位
// 为 0；没有板级外部输入时 irq 始终不会主动置位。P10 再接入真实 GPIO pad。
// 接口遵循 M1-B request/response，响应固定一周期后可见。

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */

module lcvex_pl061 (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                req_valid,
    input  lcvex_pkg::mem_req_t req,
    output logic                req_accept,
    output logic                rsp_valid,
    output lcvex_pkg::mem_rsp_t rsp,
    input  logic                rsp_ready,
    output logic                irq
);

  import lcvex_pkg::*;

  logic [7:0] data_r;
  logic [7:0] dir_r;
  logic [7:0] isense_r;
  logic [7:0] ibe_r;
  logic [7:0] iev_r;
  logic [7:0] im_r;
  logic [7:0] istate_r;
  logic [7:0] afsel_r;

  logic [7:0] data_n;
  logic [7:0] dir_n;
  logic [7:0] isense_n;
  logic [7:0] ibe_n;
  logic [7:0] iev_n;
  logic [7:0] im_n;
  logic [7:0] istate_n;
  logic [7:0] afsel_n;

  logic       rsp_pending;
  logic [63:0] rdata_r;

  function automatic logic [7:0] id_byte(input logic [3:0] index);
    // QEMU hw/gpio/pl061.c pl061_id[12]（非 Luminary 变体，virt 默认）。
    unique case (index)
      4'd0, 4'd1, 4'd2, 4'd3: id_byte = 8'h00;
      4'd4: id_byte = 8'h61; // PeripheralID0 @ 0xfe0
      4'd5: id_byte = 8'h10;
      4'd6: id_byte = 8'h04;
      4'd7: id_byte = 8'h00;
      4'd8: id_byte = 8'h0d; // PrimeCellID0 @ 0xff0
      4'd9: id_byte = 8'hf0;
      4'd10: id_byte = 8'h05;
      default: id_byte = 8'hb1;
    endcase
  endfunction

  function automatic logic [31:0] read_word(input logic [11:0] offset);
    logic [7:0] data_mask;
    logic [3:0] id_index;
    begin
      if (offset <= 12'h3ff) begin
        // PL061 的 data aperture：地址位[9:2]本身是可见引脚 mask。
        data_mask = offset[9:2];
        read_word = {24'd0, data_r & data_mask};
      end else begin
        unique case (offset)
          12'h400: read_word = {24'd0, dir_r};
          12'h404: read_word = {24'd0, isense_r};
          12'h408: read_word = {24'd0, ibe_r};
          12'h40c: read_word = {24'd0, iev_r};
          12'h410: read_word = {24'd0, im_r};
          12'h414: read_word = {24'd0, istate_r};
          12'h418: read_word = {24'd0, istate_r & im_r};
          12'h420: read_word = {24'd0, afsel_r};
          default: begin
            if (offset >= 12'hfd0) begin
              id_index = offset[5:2] - 4'd4;
              read_word = {24'd0, id_byte(id_index)};
            end else begin
              // QEMU 对未实现的非 Luminary 寄存器仅 guest-error 日志，RAZ。
              read_word = 32'd0;
            end
          end
        endcase
      end
    end
  endfunction

  task automatic apply_write(input logic [11:0] offset,
                             input logic [31:0] value,
                             inout logic [7:0] data_v,
                             inout logic [7:0] dir_v,
                             inout logic [7:0] isense_v,
                             inout logic [7:0] ibe_v,
                             inout logic [7:0] iev_v,
                             inout logic [7:0] im_v,
                             inout logic [7:0] istate_v,
                             inout logic [7:0] afsel_v);
    logic [7:0] mask;
    begin
      if (offset <= 12'h3ff) begin
        mask = offset[9:2] & dir_v;
        data_v = (data_v & ~mask) | (value[7:0] & mask);
      end else begin
        unique case (offset)
          12'h400: dir_v    = value[7:0];
          12'h404: isense_v = value[7:0];
          12'h408: ibe_v    = value[7:0];
          12'h40c: iev_v    = value[7:0];
          12'h410: im_v     = value[7:0];
          12'h41c: istate_v = istate_v & ~value[7:0];
          12'h420: afsel_v  = value[7:0];
          default: ;  // ID/非 Luminary 寄存器写忽略（QEMU 同语义）
        endcase
      end
    end
  endtask

  assign req_accept = req_valid && !rsp_pending;
  assign rsp_valid  = rsp_pending;
  assign rsp.rdata  = rdata_r;
  assign rsp.fault  = 1'b0;
  assign irq        = |(istate_r & im_r);

  always_comb begin
    data_n = data_r;
    dir_n = dir_r;
    isense_n = isense_r;
    ibe_n = ibe_r;
    iev_n = iev_r;
    im_n = im_r;
    istate_n = istate_r;
    afsel_n = afsel_r;
    if (req_valid && req_accept && req.we) begin
      automatic logic [11:0] off = req.addr[11:0];
      apply_write(off, req.wdata[31:0], data_n, dir_n, isense_n, ibe_n,
                  iev_n, im_n, istate_n, afsel_n);
      if (req.strb == 8'hff) begin
        apply_write(off + 12'd4, req.wdata[63:32], data_n, dir_n, isense_n,
                    ibe_n, iev_n, im_n, istate_n, afsel_n);
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      data_r      <= 8'd0;
      dir_r       <= 8'd0;
      isense_r    <= 8'd0;
      ibe_r       <= 8'd0;
      iev_r       <= 8'd0;
      im_r        <= 8'd0;
      istate_r    <= 8'd0;
      afsel_r     <= 8'd0;
      rsp_pending <= 1'b0;
      rdata_r     <= 64'd0;
    end else begin
      data_r   <= data_n;
      dir_r    <= dir_n;
      isense_r <= isense_n;
      ibe_r    <= ibe_n;
      iev_r    <= iev_n;
      im_r     <= im_n;
      istate_r <= istate_n;
      afsel_r  <= afsel_n;
      if (req_valid && req_accept) begin
        automatic logic [11:0] off = req.addr[11:0];
        rsp_pending <= 1'b1;
        if (req.we) begin
          rdata_r <= 64'd0;
        end else begin
          rdata_r <= {read_word(off + 12'd4), read_word(off)};
        end
      end
      if (rsp_pending && rsp_ready) begin
        rsp_pending <= 1'b0;
      end
    end
  end

endmodule
