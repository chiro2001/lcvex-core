// lcvex_bram_boot.sv
// B5-SoC/Boot: 可综合 BRAM 启动存储（M1-B 1-cycle RAM 语义）。
//
// 本文件是主 RTL 的 BRAM wrapper。它在不同实现之间做显式选择：
//   - Quartus 综合（定义 SYNTHESIS）：使用 lcvex_bram_boot_altsyncram，
//     显式 altera_syncram M20K True Dual Port 结构，避免行为级
//     byte-address 数组在 Quartus 21.4 中引起的 31GB 级 elaboration OOM。
//   - Verilator / 非综合仿真：使用 lcvex_bram_boot_behav，保留严格的
//     字节寻址、$readmemh initial 装载、prog_we 加载口、debug 读口和
//     未对齐访问语义。
//
// 接口与 lcvex_mem_ram 相同：req_accept 单 outstanding、读响应 1 拍后
// 保持、写在接受拍完成副作用。复位后从 0x00000000 取指。
// BOOT_HEX_FILE 非空时在仿真 initial 中装载（8-bit hex，每行一个字节）；
// 综合路径把 BOOT_MIF_FILE（或兼容的 BOOT_HEX_FILE 参数）传给
// altera_syncram.init_file，并关闭 power_up_uninitialized，确保配置流
// 的 M20K 内容是确定的。
//
// 未对齐/跨字说明：行为级 fallback 是完整字节寻址，仍为语义权威；
// 显式 M20K wrapper 是 64-bit word 组织，支持 word 内未对齐的 lane
// 旋转，但跨 8B word 的访问在显式实现中返回 fault（不会静默写错）。
// 详见 docs/handoffs/T-20260830-031-fpga-g2-int.md。

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNSIGNED */

module lcvex_bram_boot #(
    parameter int          DEPTH_BYTES = 1 << 16,   // B25: fixed 64 KiB
    parameter logic [63:0] SRAM_BASE   = 64'h0,
    // BOOT_HEX_FILE is the byte-per-line image used by the behavioral model.
    // The synthesis selector chooses BOOT_MIF_FILE, or the existing
    // BOOT_HEX_FILE parameter as a compatibility init-file path.
    parameter string       BOOT_HEX_FILE = "",
    parameter string       BOOT_MIF_FILE = ""
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                req_valid,
    input  lcvex_pkg::mem_req_t req,
    output logic                req_accept,
    output logic                rsp_valid,
    output lcvex_pkg::mem_rsp_t rsp,
    input  logic                rsp_ready,
    input  logic                prog_we,
    input  logic [63:0]         prog_addr,
    input  logic [7:0]          prog_strb,
    input  logic [63:0]         prog_wdata,
    input  logic [31:0]         dbg_addr,
    output logic [63:0]         dbg_rdata
);

  import lcvex_pkg::*;

`ifdef SYNTHESIS
  lcvex_bram_boot_altsyncram #(
      .DEPTH_BYTES(DEPTH_BYTES),
      .SRAM_BASE(SRAM_BASE),
      .BOOT_HEX_FILE(BOOT_HEX_FILE),
      .BOOT_MIF_FILE(BOOT_MIF_FILE)
  ) u_impl (
      .clk(clk), .rst_n(rst_n),
      .req_valid(req_valid), .req(req),
      .req_accept(req_accept), .rsp_valid(rsp_valid),
      .rsp(rsp), .rsp_ready(rsp_ready),
      .prog_we(prog_we), .prog_addr(prog_addr),
      .prog_strb(prog_strb), .prog_wdata(prog_wdata),
      .dbg_addr(dbg_addr), .dbg_rdata(dbg_rdata)
  );
`else
  lcvex_bram_boot_behav #(
      .DEPTH_BYTES(DEPTH_BYTES),
      .SRAM_BASE(SRAM_BASE),
      .BOOT_HEX_FILE(BOOT_HEX_FILE),
      .BOOT_MIF_FILE(BOOT_MIF_FILE)
  ) u_impl (
      .clk(clk), .rst_n(rst_n),
      .req_valid(req_valid), .req(req),
      .req_accept(req_accept), .rsp_valid(rsp_valid),
      .rsp(rsp), .rsp_ready(rsp_ready),
      .prog_we(prog_we), .prog_addr(prog_addr),
      .prog_strb(prog_strb), .prog_wdata(prog_wdata),
      .dbg_addr(dbg_addr), .dbg_rdata(dbg_rdata)
  );
`endif

endmodule

// ---------------------------------------------------------------------
// 非综合/Verilator 行为级 fallback：完整 byte-address RAM，保持原语义。
// ---------------------------------------------------------------------
`ifndef SYNTHESIS
module lcvex_bram_boot_behav #(
    parameter int          DEPTH_BYTES = 1 << 16,   // B25: fixed 64 KiB
    parameter logic [63:0] SRAM_BASE   = 64'h0,
    parameter string       BOOT_HEX_FILE = "",
    parameter string       BOOT_MIF_FILE = ""
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                req_valid,
    input  lcvex_pkg::mem_req_t req,
    output logic                req_accept,
    output logic                rsp_valid,
    output lcvex_pkg::mem_rsp_t rsp,
    input  logic                rsp_ready,
    input  logic                prog_we,
    input  logic [63:0]         prog_addr,
    input  logic [7:0]          prog_strb,
    input  logic [63:0]         prog_wdata,
    input  logic [31:0]         dbg_addr,
    output logic [63:0]         dbg_rdata
);

  import lcvex_pkg::*;

  localparam int AW = $clog2(DEPTH_BYTES);
  logic [7:0] mem[0:DEPTH_BYTES-1];

  logic        rsp_pending;
  logic [63:0] rdata_r;
  logic        fault_r;

  function automatic logic [2:0] hi_byte(input logic [7:0] s);
    for (int i = 7; i >= 0; i--) begin
      if (s[i]) return i[2:0];
    end
    return 3'd0;
  endfunction

  assign req_accept = req_valid && !rsp_pending;
  assign rsp_valid  = rsp_pending;
  assign rsp.rdata  = rdata_r;
  assign rsp.fault  = fault_r;

  always_ff @(posedge clk) begin
    dbg_rdata <= {mem[AW'(dbg_addr) + AW'(7)],
                  mem[AW'(dbg_addr) + AW'(6)],
                  mem[AW'(dbg_addr) + AW'(5)],
                  mem[AW'(dbg_addr) + AW'(4)],
                  mem[AW'(dbg_addr) + AW'(3)],
                  mem[AW'(dbg_addr) + AW'(2)],
                  mem[AW'(dbg_addr) + AW'(1)],
                  mem[AW'(dbg_addr) + AW'(0)]};
  end

  // 仿真初始化：非综合环境可见（Quartus 综合时定义 SYNTHESIS，且此模块
  // 本身也被 ifndef SYNTHESIS 排除）。
  /* synthesis translate_off */
  initial begin
    for (int i = 0; i < DEPTH_BYTES; i++) begin
      mem[i] = 8'h00;
    end
    if (BOOT_HEX_FILE != "") begin
      $readmemh(BOOT_HEX_FILE, mem);
    end
  end
  /* synthesis translate_on */

  // 程序加载口与请求写共享同一时钟沿进程，避免 Verilator MULTIDRIVEN。
  // 板级 prog_we 固定为 0；非综合环境下复位期间允许加载。
  always_ff @(posedge clk or negedge rst_n) begin
    if (prog_we) begin
      for (int i = 0; i < 8; i++) begin
        if (prog_strb[i]) begin
          mem[prog_addr[AW-1:0] + AW'(i)] <= prog_wdata[i*8 +: 8];
        end
      end
    end
    if (!rst_n) begin
      rsp_pending <= 1'b0;
      rdata_r     <= 64'd0;
      fault_r     <= 1'b0;
    end else begin
      if (req_accept) begin
        fault_r <= (req.addr < SRAM_BASE) ||
                   (req.addr >= (SRAM_BASE + 64'(DEPTH_BYTES))) ||
                   ((64'(req.addr[AW-1:0]) + 64'(hi_byte(req.strb))) >=
                    64'(DEPTH_BYTES));
        rsp_pending <= 1'b1;
        if (req.we && !((req.addr < SRAM_BASE) ||
                        (req.addr >= (SRAM_BASE + 64'(DEPTH_BYTES))) ||
                        ((64'(req.addr[AW-1:0]) +
                          64'(hi_byte(req.strb))) >= 64'(DEPTH_BYTES)))) begin
          for (int i = 0; i < 8; i++) begin
            if (req.strb[i]) begin
              mem[req.addr[AW-1:0] + AW'(i)] <= req.wdata[i*8 +: 8];
            end
          end
        end
        if (!req.we) begin
          for (int i = 0; i < 8; i++) begin
            rdata_r[i*8 +: 8] <= mem[req.addr[AW-1:0] + AW'(i)];
          end
        end
      end
      if (rsp_pending && rsp_ready) begin
        rsp_pending <= 1'b0;
      end
    end
  end

endmodule
`endif

// ---------------------------------------------------------------------
// 显式 altera_syncram M20K True Dual Port wrapper（Quartus 综合路径）。
// 64-bit word 组织：port A 供请求读/写，port B 供 debug 读。
// 写字节使能与数据按 req.addr 低 3 位做 word 内 lane 旋转；跨 word
// 访问显式回 fault，不静默写错。
// ---------------------------------------------------------------------
`ifdef SYNTHESIS
module lcvex_bram_boot_altsyncram #(
    parameter int          DEPTH_BYTES = 65536,
    parameter logic [63:0] SRAM_BASE   = 64'h0,
    parameter string       BOOT_HEX_FILE = "",
    parameter string       BOOT_MIF_FILE = ""
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                req_valid,
    input  lcvex_pkg::mem_req_t req,
    output logic                req_accept,
    output logic                rsp_valid,
    output lcvex_pkg::mem_rsp_t rsp,
    input  logic                rsp_ready,
    input  logic                prog_we,
    input  logic [63:0]         prog_addr,
    input  logic [7:0]          prog_strb,
    input  logic [63:0]         prog_wdata,
    input  logic [31:0]         dbg_addr,
    output logic [63:0]         dbg_rdata
);
  import lcvex_pkg::*;
  localparam int AW = $clog2(DEPTH_BYTES);
  localparam int WADDR = AW - 3;
  localparam int NWORDS = DEPTH_BYTES / 8;
  // The top-level B25 instance supplies the MIF path through the existing
  // BOOT_HEX_FILE SoC parameter.  Keep BOOT_MIF_FILE explicit so standalone
  // users can provide a synthesis image without changing the byte-image ABI.
  localparam string INIT_FILE = (BOOT_MIF_FILE != "")
                              ? BOOT_MIF_FILE : BOOT_HEX_FILE;

  logic        rsp_pending;
  logic [63:0] rdata_r;
  logic        fault_r;
  logic        rsp_read_r;
  logic [WADDR-1:0] req_waddr_r;
  logic [2:0]  req_off_r;
  logic [2:0]  dbg_off_r;
  logic [63:0] req_q;
  logic [63:0] dbg_q;

  wire [WADDR-1:0] req_waddr = req.addr[AW-1:3];
  wire [2:0]       req_off   = req.addr[2:0];
  wire [7:0]       rot_strb  = req.strb << req_off;
  wire [63:0]      rot_data  = req.wdata << (req_off * 8);
  wire [2:0]       req_hi    = hi_byte(req.strb);
  wire             req_cross = (req_off + req_hi) >= 8;
  wire [WADDR-1:0] dbg_waddr = dbg_addr[AW-1:3];
  wire [2:0]       dbg_off   = dbg_addr[2:0];

  // Port A is a synchronous M20K read.  Present the live address on an
  // accepting edge, then keep the accepted word selected until its response
  // retires.  This makes q_a both the correct post-edge word and stable under
  // response backpressure; it also avoids sampling the previous q_a value in
  // an always_ff block on the address-accept edge.
  wire [WADDR-1:0] ram_req_waddr = req_accept ? req_waddr : req_waddr_r;

  wire             wr_en = req_accept && req.we && !req_cross;

  assign req_accept = req_valid && !rsp_pending;
  assign rsp_valid  = rsp_pending;
  assign rsp.rdata  = rsp_read_r ? (req_q >> (req_off_r * 8)) : rdata_r;
  assign rsp.fault  = fault_r;

  // q_b changes after the same edge that samples dbg_waddr.  Capture only the
  // associated byte offset and combine it with q_b after the edge; registering
  // dbg_q here would return the previous debug word.
  assign dbg_rdata = dbg_q >> (dbg_off_r * 8);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) dbg_off_r <= 3'd0;
    else dbg_off_r <= dbg_off;
  end

  altera_syncram #(
    .address_aclr_a       ("NONE"),
    .address_aclr_b       ("NONE"),
    .address_reg_a        ("CLOCK0"),
    .address_reg_b        ("CLOCK0"),
    .indata_reg_a         ("CLOCK0"),
    .indata_reg_b         ("CLOCK0"),
    .byteena_reg_a        ("CLOCK0"),
    .byteena_reg_b        ("CLOCK0"),
    .rdcontrol_reg_a      ("CLOCK0"),
    .rdcontrol_reg_b      ("CLOCK0"),
    .clock_enable_input_a ("BYPASS"),
    .clock_enable_input_b ("BYPASS"),
    .clock_enable_output_a("BYPASS"),
    .clock_enable_output_b("BYPASS"),
    .enable_ecc           ("FALSE"),
    .lpm_type             ("altera_syncram"),
    .numwords_a           (NWORDS),
    .numwords_b           (NWORDS),
    .operation_mode       ("BIDIR_DUAL_PORT"),
    .outdata_aclr_b       ("NONE"),
    .outdata_sclr_b       ("NONE"),
    .outdata_reg_a        ("UNREGISTERED"),
    .outdata_reg_b        ("UNREGISTERED"),
    .init_file            (INIT_FILE),
    .power_up_uninitialized("FALSE"),
    .ram_block_type       ("M20K"),
    .read_during_write_mode_mixed_ports ("DONT_CARE"),
    .widthad_a            (WADDR),
    .widthad_b            (WADDR),
    .width_a              (64),
    .width_b              (64),
    .width_byteena_a      (8),
    .width_byteena_b      (8)
  ) u_ram (
    .address_a   (ram_req_waddr),
    .address_b   (dbg_waddr),
    .clock0      (clk),
    .data_a      (rot_data),
    .wren_a      (wr_en),
    .q_a         (req_q),
    .q_b         (dbg_q),
    .aclr0       (1'b0),
    .aclr1       (1'b0),
    .address2_a  (1'b1),
    .address2_b  (1'b1),
    .addressstall_a(1'b0),
    .addressstall_b(1'b0),
    .byteena_a   (rot_strb),
    .byteena_b   (8'hFF),
    .clock1      (1'b1),
    .clocken0    (1'b1),
    .clocken1    (1'b1),
    .clocken2    (1'b1),
    .clocken3    (1'b1),
    .data_b      (64'h0),
    .eccstatus   (),
    .eccencbypass(1'b0),
    .eccencparity(8'b0),
    .sclr        (1'b0),
    .rden_a      (1'b1),
    .rden_b      (1'b1),
    .wren_b      (1'b0)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rsp_pending <= 1'b0;
      rdata_r     <= 64'd0;
      fault_r     <= 1'b0;
      rsp_read_r  <= 1'b0;
      req_waddr_r <= '0;
      req_off_r   <= 3'd0;
    end else begin
      if (req_accept) begin
        req_waddr_r <= req_waddr;
        req_off_r   <= req_off;
        rsp_read_r  <= !req.we;
        fault_r     <= (req.addr < SRAM_BASE) ||
                       (req.addr >= (SRAM_BASE + 64'(DEPTH_BYTES))) ||
                       ((64'(req.addr[AW-1:0]) + 64'(req_hi)) >=
                        64'(DEPTH_BYTES)) ||
                       (req_cross);
        rsp_pending <= 1'b1;
        if (req.we && req_cross) begin
          // 跨 word 写不执行；fault 已置位，避免静默丢字节。
          rdata_r <= 64'd0;
        end
      end
      if (rsp_pending && rsp_ready) begin
        rsp_pending <= 1'b0;
      end
    end
  end

  function automatic logic [2:0] hi_byte(input logic [7:0] s);
    for (int i = 7; i >= 0; i--) begin
      if (s[i]) return i[2:0];
    end
    return 3'd0;
  endfunction

  // 显式 M20K wrapper 不实现运行时 prog_we（综合顶层 tie-off）；
  // 上电内容由配置流/MIF 决定。保留端口是为了与行为级 fallback 对等。
endmodule
`endif
