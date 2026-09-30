// lcvex_axi4_bfm.sv
//
// 独立 AXI4 Full 随机 slave/BFM。它只依赖 lcvex_axi4_pkg，不连接 LCVEX
// core、cache、L2 或任何 FPGA 厂商接口。BFM 支持 W 先于 AW、通道随机背压、
// 可控 SLVERR、字节写使能和按 AXI SIZE 的窄访问。

`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off UNUSEDSIGNAL */
module lcvex_axi4_bfm #(
    parameter int ADDR_WIDTH = 64,
    parameter int DATA_WIDTH = 128,
    parameter int ID_WIDTH = 4,
    parameter int MAX_BURST_LEN = 16,
    parameter int MEM_BYTES = 65536,
    parameter int unsigned SEED = 32'h1b1_a4f7
) (
    input logic clk,
    input logic rst_n,

    // BFM knobs are intentionally explicit so directed and Cocotb tests can
    // force AW/W independence and reproducibly inject response errors.
    input logic cfg_random_stall,
    input logic cfg_block_aw,
    input logic cfg_block_w,
    input logic cfg_block_ar,
    input logic cfg_write_error,
    input logic cfg_read_error,

    // AXI4 AW channel
    input logic awvalid,
    output logic awready,
    input logic [ID_WIDTH-1:0] awid,
    input logic [ADDR_WIDTH-1:0] awaddr,
    input logic [7:0] awlen,
    input logic [2:0] awsize,
    input logic [1:0] awburst,
    input logic awlock,
    input logic [3:0] awcache,
    input logic [2:0] awprot,
    input logic [3:0] awqos,

    // AXI4 W channel
    input logic wvalid,
    output logic wready,
    input logic [DATA_WIDTH-1:0] wdata,
    input logic [DATA_WIDTH/8-1:0] wstrb,
    input logic wlast,

    // AXI4 B channel
    output logic bvalid,
    input logic bready,
    output logic [ID_WIDTH-1:0] bid,
    output logic [1:0] bresp,

    // AXI4 AR channel
    input logic arvalid,
    output logic arready,
    input logic [ID_WIDTH-1:0] arid,
    input logic [ADDR_WIDTH-1:0] araddr,
    input logic [7:0] arlen,
    input logic [2:0] arsize,
    input logic [1:0] arburst,
    input logic arlock,
    input logic [3:0] arcache,
    input logic [2:0] arprot,
    input logic [3:0] arqos,

    // AXI4 R channel
    output logic rvalid,
    input logic rready,
    output logic [ID_WIDTH-1:0] rid,
    output logic [DATA_WIDTH-1:0] rdata,
    output logic [1:0] rresp,
    output logic rlast
);

  import lcvex_axi4_pkg::*;

  localparam int BYTE_LANES = DATA_WIDTH / 8;

  logic [7:0] mem [0:MEM_BYTES-1];
  logic [31:0] rng_q;

  logic aw_captured_q;
  logic [ID_WIDTH-1:0] awid_q;
  logic [ADDR_WIDTH-1:0] awaddr_q;
  logic [7:0] awlen_q;
  logic [2:0] awsize_q;
  logic [1:0] awburst_q;

  logic [DATA_WIDTH-1:0] wr_data_q [0:MAX_BURST_LEN-1];
  logic [BYTE_LANES-1:0] wr_strb_q [0:MAX_BURST_LEN-1];
  integer unsigned w_count_q;
  logic w_done_q;

  logic b_pending_q;
  logic bvalid_q;
  integer unsigned b_delay_q;
  logic [ID_WIDTH-1:0] bid_q;
  logic [1:0] bresp_q;

  logic ar_captured_q;
  logic [ID_WIDTH-1:0] arid_q;
  logic [ADDR_WIDTH-1:0] araddr_q;
  logic [7:0] arlen_q;
  logic [2:0] arsize_q;
  logic [1:0] arburst_q;
  integer unsigned r_beat_q;
  logic r_pending_q;
  logic rvalid_q;
  integer unsigned r_delay_q;
  logic [ID_WIDTH-1:0] rid_q;
  logic [DATA_WIDTH-1:0] rdata_q;
  logic [1:0] rresp_q;
  logic rlast_q;

  logic write_bad_tmp;
  logic read_bad_tmp;
  logic [DATA_WIDTH-1:0] read_data_tmp;

  logic aw_fire;
  logic w_fire;
  logic b_fire;
  logic ar_fire;
  logic r_fire;
  logic read_busy;
  logic write_busy;

  function automatic logic [31:0] lfsr_next(input logic [31:0] value);
    begin
      lfsr_next = {value[30:0], value[31] ^ value[21] ^ value[1] ^ value[0]};
      if (lfsr_next == 32'd0) begin
        lfsr_next = 32'h1;
      end
    end
  endfunction

  function automatic logic address_4k_ok(
      input logic [ADDR_WIDTH-1:0] addr,
      input logic [7:0] len,
      input logic [2:0] size
  );
    logic [63:0] addr64;
    begin
      addr64 = '0;
      addr64[ADDR_WIDTH-1:0] = addr;
      address_4k_ok = lcvex_axi4_4k_boundary_ok(addr64, len, size);
    end
  endfunction

  task automatic commit_write(output logic bad);
    longint unsigned beat_addr;
    longint unsigned absolute_addr;
    int unsigned lane;
    int unsigned transfer_bytes;
    begin
      bad = 1'b0;
      transfer_bytes = 1 << awsize_q;
      if (awburst_q != AXI4_BURST_INCR || awsize_q > $clog2(BYTE_LANES) ||
          awlen_q >= MAX_BURST_LEN ||
          !address_4k_ok(awaddr_q, awlen_q, awsize_q) ||
          w_count_q != (awlen_q + 1)) begin
        bad = 1'b1;
      end

      for (int i = 0; i < MAX_BURST_LEN; i++) begin
        if (i < w_count_q) begin
          beat_addr = awaddr_q + (i * (64'd1 << awsize_q));
          lane = beat_addr % BYTE_LANES;
          if ((lane + transfer_bytes) > BYTE_LANES) begin
            bad = 1'b1;
          end
          for (int j = 0; j < BYTE_LANES; j++) begin
            if (wr_strb_q[i][j] && j >= lane &&
                j < (lane + transfer_bytes)) begin
              absolute_addr = (beat_addr - lane) + j;
              if (absolute_addr >= MEM_BYTES) begin
                bad = 1'b1;
              end else begin
                mem[absolute_addr] = wr_data_q[i][j*8 +: 8];
              end
            end
          end
        end
      end
    end
  endtask

  task automatic make_read_beat(output logic bad,
                                output logic [DATA_WIDTH-1:0] data);
    longint unsigned beat_addr;
    longint unsigned absolute_addr;
    int unsigned lane;
    int unsigned transfer_bytes;
    begin
      bad = 1'b0;
      data = '0;
      transfer_bytes = 1 << arsize_q;
      beat_addr = araddr_q + (r_beat_q * (64'd1 << arsize_q));
      lane = beat_addr % BYTE_LANES;

      if (arburst_q != AXI4_BURST_INCR || arsize_q > $clog2(BYTE_LANES) ||
          arlen_q >= MAX_BURST_LEN ||
          !address_4k_ok(araddr_q, arlen_q, arsize_q) ||
          (lane + transfer_bytes) > BYTE_LANES) begin
        bad = 1'b1;
      end

      if (!bad) begin
        for (int j = 0; j < BYTE_LANES; j++) begin
          if (j >= lane && j < (lane + transfer_bytes)) begin
            absolute_addr = (beat_addr - lane) + j;
            if (absolute_addr >= MEM_BYTES) begin
              bad = 1'b1;
            end else begin
              data[j*8 +: 8] = mem[absolute_addr];
            end
          end
        end
      end
    end
  endtask

  assign read_busy = ar_captured_q || r_pending_q || rvalid_q;
  assign write_busy = aw_captured_q || (w_count_q != 0) || w_done_q ||
                      b_pending_q || bvalid_q;

  always_comb begin
    // AW and W deliberately have independent acceptance predicates. WREADY
    // does not depend on AWVALID/AWREADY, so a legal W-before-AW sequence is
    // exercised by the BFM.
    awready = 1'b0;
    wready = 1'b0;
    arready = 1'b0;

    bvalid = bvalid_q;
    bid = bid_q;
    bresp = bresp_q;
    rvalid = rvalid_q;
    rid = rid_q;
    rdata = rdata_q;
    rresp = rresp_q;
    rlast = rlast_q;

    if (rst_n) begin
      if (!cfg_block_aw && !aw_captured_q && !b_pending_q && !bvalid_q &&
          !read_busy) begin
        awready = !cfg_random_stall || rng_q[0];
      end
      if (!cfg_block_w && !w_done_q && w_count_q < MAX_BURST_LEN &&
          !b_pending_q && !bvalid_q && !read_busy) begin
        wready = !cfg_random_stall || rng_q[1];
      end
      if (!cfg_block_ar && !ar_captured_q && !r_pending_q && !rvalid_q &&
          !write_busy) begin
        arready = !cfg_random_stall || rng_q[2];
      end
    end
  end

  assign aw_fire = awvalid && awready;
  assign w_fire = wvalid && wready;
  assign b_fire = bvalid_q && bready;
  assign ar_fire = arvalid && arready;
  assign r_fire = rvalid_q && rready;

  initial begin
    if (ADDR_WIDTH < 12 || ADDR_WIDTH > 64) begin
      $fatal(1, "lcvex_axi4_bfm: ADDR_WIDTH must be in [12,64]");
    end
    if (DATA_WIDTH < 8 || (DATA_WIDTH % 8) != 0 ||
        !lcvex_axi4_is_power_of_two(BYTE_LANES) || DATA_WIDTH > 1024) begin
      $fatal(1, "lcvex_axi4_bfm: invalid DATA_WIDTH");
    end
    if (MAX_BURST_LEN < 1 || MAX_BURST_LEN > 256 || MEM_BYTES < 1) begin
      $fatal(1, "lcvex_axi4_bfm: invalid capacity parameter");
    end
    for (int i = 0; i < MEM_BYTES; i++) begin
      mem[i] = 8'h00;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rng_q <= SEED == 0 ? 32'h1 : SEED;
      aw_captured_q <= 1'b0;
      awid_q <= '0;
      awaddr_q <= '0;
      awlen_q <= '0;
      awsize_q <= '0;
      awburst_q <= AXI4_BURST_INCR;
      w_count_q <= 0;
      w_done_q <= 1'b0;
      b_pending_q <= 1'b0;
      bvalid_q <= 1'b0;
      b_delay_q <= 0;
      bid_q <= '0;
      bresp_q <= AXI4_RESP_OKAY;
      ar_captured_q <= 1'b0;
      arid_q <= '0;
      araddr_q <= '0;
      arlen_q <= '0;
      arsize_q <= '0;
      arburst_q <= AXI4_BURST_INCR;
      r_beat_q <= 0;
      r_pending_q <= 1'b0;
      rvalid_q <= 1'b0;
      r_delay_q <= 0;
      rid_q <= '0;
      rdata_q <= '0;
      rresp_q <= AXI4_RESP_OKAY;
      rlast_q <= 1'b0;
    end else begin
      rng_q <= lfsr_next(rng_q);

      if (aw_fire) begin
        aw_captured_q <= 1'b1;
        awid_q <= awid;
        awaddr_q <= awaddr;
        awlen_q <= awlen;
        awsize_q <= awsize;
        awburst_q <= awburst;
      end

      if (w_fire) begin
        if (w_count_q < MAX_BURST_LEN) begin
          wr_data_q[w_count_q] <= wdata;
          wr_strb_q[w_count_q] <= wstrb;
          w_count_q <= w_count_q + 1;
          if (wlast) begin
            w_done_q <= 1'b1;
          end
        end
      end

      // Commit the byte writes only after both independently accepted AW and
      // the WLAST beat are present. The response is delayed independently.
      if (aw_captured_q && w_done_q && !b_pending_q && !bvalid_q) begin
        commit_write(write_bad_tmp);
        bid_q <= awid_q;
        if (cfg_write_error) begin
          bresp_q <= AXI4_RESP_SLVERR;
        end else if (write_bad_tmp) begin
          bresp_q <= AXI4_RESP_DECERR;
        end else begin
          bresp_q <= AXI4_RESP_OKAY;
        end
        b_delay_q <= cfg_random_stall ? (rng_q[5:3] & 3) : 0;
        b_pending_q <= 1'b1;
      end

      if (b_pending_q) begin
        if (b_delay_q == 0) begin
          bvalid_q <= 1'b1;
          b_pending_q <= 1'b0;
        end else begin
          b_delay_q <= b_delay_q - 1;
        end
      end

      if (b_fire) begin
        bvalid_q <= 1'b0;
        aw_captured_q <= 1'b0;
        w_count_q <= 0;
        w_done_q <= 1'b0;
      end

      if (ar_fire) begin
        ar_captured_q <= 1'b1;
        arid_q <= arid;
        araddr_q <= araddr;
        arlen_q <= arlen;
        arsize_q <= arsize;
        arburst_q <= arburst;
        r_beat_q <= 0;
        r_delay_q <= cfg_random_stall ? (rng_q[8:6] & 3) : 0;
        r_pending_q <= 1'b1;
      end

      if (r_pending_q && !rvalid_q) begin
        if (r_delay_q == 0) begin
          make_read_beat(read_bad_tmp, read_data_tmp);
          rid_q <= arid_q;
          rdata_q <= read_data_tmp;
          if (cfg_read_error) begin
            rresp_q <= AXI4_RESP_SLVERR;
          end else if (read_bad_tmp) begin
            rresp_q <= AXI4_RESP_DECERR;
          end else begin
            rresp_q <= AXI4_RESP_OKAY;
          end
          rlast_q <= (r_beat_q == arlen_q);
          rvalid_q <= 1'b1;
          r_pending_q <= 1'b0;
        end else begin
          r_delay_q <= r_delay_q - 1;
        end
      end

      if (r_fire) begin
        rvalid_q <= 1'b0;
        if (rlast_q) begin
          ar_captured_q <= 1'b0;
          r_beat_q <= 0;
        end else begin
          r_beat_q <= r_beat_q + 1;
          r_delay_q <= cfg_random_stall ? (rng_q[11:9] & 3) : 0;
          r_pending_q <= 1'b1;
        end
      end
    end
  end

endmodule
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on WIDTHTRUNC */
/* verilator lint_on WIDTHEXPAND */
