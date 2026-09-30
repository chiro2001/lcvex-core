// lcvex_axi4_sva.sv
//
// AXI4 Full 五通道被动协议检查器。该模块不改变任何通道信号，由独立
// testbench 实例化；断言在 Verilator --assert 和支持 SVA 的仿真器中均可用。

`timescale 1ns/1ps

module lcvex_axi4_sva #(
    parameter int ADDR_WIDTH = 64,
    parameter int DATA_WIDTH = 128,
    parameter int ID_WIDTH = 4
) (
    input logic clk,
    input logic rst_n,

    input logic awvalid,
    input logic awready,
    input logic [ID_WIDTH-1:0] awid,
    input logic [ADDR_WIDTH-1:0] awaddr,
    input logic [7:0] awlen,
    input logic [2:0] awsize,
    input logic [1:0] awburst,
    input logic awlock,
    input logic [3:0] awcache,
    input logic [2:0] awprot,
    input logic [3:0] awqos,

    input logic wvalid,
    input logic wready,
    input logic [DATA_WIDTH-1:0] wdata,
    input logic [DATA_WIDTH/8-1:0] wstrb,
    input logic wlast,

    input logic bvalid,
    input logic bready,
    input logic [ID_WIDTH-1:0] bid,
    input logic [1:0] bresp,

    input logic arvalid,
    input logic arready,
    input logic [ID_WIDTH-1:0] arid,
    input logic [ADDR_WIDTH-1:0] araddr,
    input logic [7:0] arlen,
    input logic [2:0] arsize,
    input logic [1:0] arburst,
    input logic arlock,
    input logic [3:0] arcache,
    input logic [2:0] arprot,
    input logic [3:0] arqos,

    input logic rvalid,
    input logic rready,
    input logic [ID_WIDTH-1:0] rid,
    input logic [DATA_WIDTH-1:0] rdata,
    input logic [1:0] rresp,
    input logic rlast
);

  /* verilator lint_off WIDTHEXPAND */
  /* verilator lint_off SYNCASYNCNET */

  import lcvex_axi4_pkg::*;

  localparam int BYTE_LANES = DATA_WIDTH / 8;
  localparam int BUS_SIZE = $clog2(BYTE_LANES);

  logic wr_active_q;
  logic rd_active_q;
  logic [ID_WIDTH-1:0] wr_id_q;
  logic [ID_WIDTH-1:0] rd_id_q;
  logic [7:0] rd_len_q;
  logic [7:0] rd_beat_q;

  logic aw_stalled_q;
  logic w_stalled_q;
  logic b_stalled_q;
  logic ar_stalled_q;
  logic r_stalled_q;
  logic [ID_WIDTH+ADDR_WIDTH+8+3+2+1+4+3+4-1:0] aw_hold_payload_q;
  logic [DATA_WIDTH+DATA_WIDTH/8+1-1:0] w_hold_payload_q;
  logic [ID_WIDTH+2-1:0] b_hold_payload_q;
  logic [ID_WIDTH+ADDR_WIDTH+8+3+2+1+4+3+4-1:0] ar_hold_payload_q;
  logic [ID_WIDTH+DATA_WIDTH+2+1-1:0] r_hold_payload_q;

  logic aw_fire;
  logic b_fire;
  logic ar_fire;
  logic r_fire;

  function automatic logic addr_4k_ok(
      input logic [ADDR_WIDTH-1:0] addr,
      input logic [7:0] len,
      input logic [2:0] size
  );
    logic [63:0] addr64;
    begin
      addr64 = '0;
      addr64[ADDR_WIDTH-1:0] = addr;
      addr_4k_ok = lcvex_axi4_4k_boundary_ok(addr64, len, size);
    end
  endfunction

  assign aw_fire = awvalid && awready;
  assign b_fire = bvalid && bready;
  assign ar_fire = arvalid && arready;
  assign r_fire = rvalid && rready;

  initial begin
    if (ADDR_WIDTH < 12 || ADDR_WIDTH > 64) begin
      $fatal(1, "lcvex_axi4_sva: ADDR_WIDTH must be in [12,64]");
    end
    if (DATA_WIDTH < 8 || (DATA_WIDTH % 8) != 0 ||
        !lcvex_axi4_is_power_of_two(BYTE_LANES) || DATA_WIDTH > 1024) begin
      $fatal(1, "lcvex_axi4_sva: invalid DATA_WIDTH");
    end
  end

  // The B1 master emits only legal INCR bursts and never crosses a 4 KiB
  // boundary. These checks are at the handshake point so idle payload values
  // do not matter.
  assert property (@(posedge clk) disable iff (!rst_n)
      aw_fire |-> (awburst == AXI4_BURST_INCR && awsize <= BUS_SIZE &&
                   addr_4k_ok(awaddr, awlen, awsize)))
    else $error("AXI4 AW burst/size/4KiB rule violated");

  assert property (@(posedge clk) disable iff (!rst_n)
      ar_fire |-> (arburst == AXI4_BURST_INCR && arsize <= BUS_SIZE &&
                   addr_4k_ok(araddr, arlen, arsize)))
    else $error("AXI4 AR burst/size/4KiB rule violated");

  // The selected simulator samples a concurrent |=> consequent after the source FSM's
  // nonblocking update. The following clocked assertions deliberately sample
  // the current (pre-update) handshake cycle, so a VALID may drop immediately
  // after the first cycle in which READY accepts it, while a stalled payload
  // still has to remain bit-for-bit unchanged. The same payload tuples are
  // kept in explicit SVA-side hold registers for review/debug visibility.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_stalled_q <= 1'b0;
      w_stalled_q <= 1'b0;
      b_stalled_q <= 1'b0;
      ar_stalled_q <= 1'b0;
      r_stalled_q <= 1'b0;
      aw_hold_payload_q <= '0;
      w_hold_payload_q <= '0;
      b_hold_payload_q <= '0;
      ar_hold_payload_q <= '0;
      r_hold_payload_q <= '0;
    end else begin
      if (aw_stalled_q) begin
        assert(awvalid)
          else $error("AXI4 AWVALID dropped before AWREADY handshake");
        assert({awid, awaddr, awlen, awsize, awburst,
                awlock, awcache, awprot, awqos} == aw_hold_payload_q)
          else $error("AXI4 AW payload changed while AWREADY was low");
        if (awvalid && awready) begin
          aw_stalled_q <= 1'b0;
        end
      end else if (awvalid && !awready) begin
        aw_stalled_q <= 1'b1;
        aw_hold_payload_q <= {awid, awaddr, awlen, awsize, awburst,
                              awlock, awcache, awprot, awqos};
      end

      if (w_stalled_q) begin
        assert(wvalid)
          else $error("AXI4 WVALID dropped before WREADY handshake");
        assert({wdata, wstrb, wlast} == w_hold_payload_q)
          else $error("AXI4 W payload changed while WREADY was low");
        if (wvalid && wready) begin
          w_stalled_q <= 1'b0;
        end
      end else if (wvalid && !wready) begin
        w_stalled_q <= 1'b1;
        w_hold_payload_q <= {wdata, wstrb, wlast};
      end

      if (b_stalled_q) begin
        assert(bvalid)
          else $error("AXI4 BVALID dropped before BREADY handshake");
        assert({bid, bresp} == b_hold_payload_q)
          else $error("AXI4 B payload changed while BREADY was low");
        if (bvalid && bready) begin
          b_stalled_q <= 1'b0;
        end
      end else if (bvalid && !bready) begin
        b_stalled_q <= 1'b1;
        b_hold_payload_q <= {bid, bresp};
      end

      if (ar_stalled_q) begin
        assert(arvalid)
          else $error("AXI4 ARVALID dropped before ARREADY handshake");
        assert({arid, araddr, arlen, arsize, arburst,
                arlock, arcache, arprot, arqos} == ar_hold_payload_q)
          else $error("AXI4 AR payload changed while ARREADY was low");
        if (arvalid && arready) begin
          ar_stalled_q <= 1'b0;
        end
      end else if (arvalid && !arready) begin
        ar_stalled_q <= 1'b1;
        ar_hold_payload_q <= {arid, araddr, arlen, arsize, arburst,
                              arlock, arcache, arprot, arqos};
      end

      if (r_stalled_q) begin
        assert(rvalid)
          else $error("AXI4 RVALID dropped before RREADY handshake");
        assert({rid, rdata, rresp, rlast} == r_hold_payload_q)
          else $error("AXI4 R payload changed while RREADY was low");
        if (rvalid && rready) begin
          r_stalled_q <= 1'b0;
        end
      end else if (rvalid && !rready) begin
        r_stalled_q <= 1'b1;
        r_hold_payload_q <= {rid, rdata, rresp, rlast};
      end
    end
  end

  // Single-ID/single-outstanding bookkeeping. W may legally arrive before
  // AW; only the response ordering depends on the corresponding address.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_active_q <= 1'b0;
      rd_active_q <= 1'b0;
      wr_id_q <= '0;
      rd_id_q <= '0;
      rd_len_q <= '0;
      rd_beat_q <= '0;
    end else begin
      if (aw_fire) begin
        assert(!wr_active_q || b_fire)
          else $error("AXI4 more than one write outstanding");
        wr_active_q <= 1'b1;
        wr_id_q <= awid;
      end
      if (bvalid) begin
        assert(wr_active_q || aw_fire)
          else $error("AXI4 BVALID without a write address");
        assert(!wr_active_q || bid == wr_id_q)
          else $error("AXI4 BID does not match AWID");
      end
      if (b_fire) begin
        wr_active_q <= 1'b0;
      end

      if (ar_fire) begin
        assert(!rd_active_q || (r_fire && rlast))
          else $error("AXI4 more than one read outstanding");
        rd_active_q <= 1'b1;
        rd_id_q <= arid;
        rd_len_q <= arlen;
        rd_beat_q <= '0;
      end
      if (rvalid) begin
        assert(rd_active_q || ar_fire)
          else $error("AXI4 RVALID without a read address");
        assert(!rd_active_q || rid == rd_id_q)
          else $error("AXI4 RID does not match ARID");
      end
      if (r_fire) begin
        assert(rd_active_q || ar_fire)
          else $error("AXI4 R handshake without an outstanding read");
        if (rlast) begin
          assert((rd_active_q ? rd_beat_q : 8'd0) ==
                 (rd_active_q ? rd_len_q : arlen))
            else $error("AXI4 RLAST arrived at the wrong beat");
          rd_active_q <= 1'b0;
        end else begin
          rd_beat_q <= rd_beat_q + 8'd1;
          assert(rd_active_q && rd_beat_q < rd_len_q)
            else $error("AXI4 R beat missing LAST");
        end
      end
    end
  end

  /* verilator lint_on SYNCASYNCNET */
  /* verilator lint_on WIDTHEXPAND */

endmodule
