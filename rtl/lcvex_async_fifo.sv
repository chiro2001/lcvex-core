// lcvex_async_fifo.sv
//
// 小型 Gray-pointer asynchronous FIFO。B2 的公共复位请求先在每个时钟域内
// 做 async-assert / sync-deassert 的复位同步，再分别以 wr_rst_n / rd_rst_n
// 驱动本 FIFO 的写域和读域。任一域异步复位都会清空两侧指针，释放则分别在
// 各自时钟边沿同步生效。这样不会把一个域复位前的 response 当成复位后的新事务。
//
// AUD-04 reset/CDC contract:
//   - wr_rst_n and rd_rst_n are per-domain asynchronous-assert /
//     synchronous-deassert resets supplied by the adapter. The adapter derives
//     both from the common request
//     link_rst_n_req = cpu_rst_n & emif_rst_n & !cal_fail.
//   - On assertion, all pointer/synchronizer flops are asynchronously cleared,
//     creating an epoch boundary in both directions; an in-flight response
//     from before the failure cannot be mistaken for a post-reset transaction.
//   - On deassertion, each domain exits reset on its own clock edge; the
//     two-stage gray synchronizers are reset in their receiving domain.
//   - TimeQuest must verify: (a) the two clock groups are asynchronous,
//     (b) source->first synchronizer paths are covered, (c) reset release is
//     not analyzed as a normal setup/hold path, and (d) no slave-side gray
//     pointer sample is consolidated across a reset epoch without the FIFO
//     being flushed by the common reset.

`timescale 1ns/1ps

module lcvex_async_fifo #(
    parameter int DATA_WIDTH = 8,
    parameter int ADDR_WIDTH = 2
) (
    input  logic                 wr_clk,
    input  logic                 rd_clk,
    input  logic                 wr_rst_n,
    input  logic                 rd_rst_n,

    input  logic                 wr_en,
    input  logic [DATA_WIDTH-1:0] wr_data,
    output logic                 wr_full,

    input  logic                 rd_en,
    output logic [DATA_WIDTH-1:0] rd_data,
    output logic                 rd_empty
);

  localparam int PTR_WIDTH = ADDR_WIDTH + 1;
  localparam int DEPTH = 1 << ADDR_WIDTH;

  logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];
  logic [PTR_WIDTH-1:0] wr_ptr_bin_q;
  logic [PTR_WIDTH-1:0] wr_ptr_gray_q;
  logic [PTR_WIDTH-1:0] rd_ptr_bin_q;
  logic [PTR_WIDTH-1:0] rd_ptr_gray_q;
  logic [PTR_WIDTH-1:0] rd_ptr_gray_wr1_q;
  logic [PTR_WIDTH-1:0] rd_ptr_gray_wr2_q;
  logic [PTR_WIDTH-1:0] wr_ptr_gray_rd1_q;
  logic [PTR_WIDTH-1:0] wr_ptr_gray_rd2_q;

  logic [PTR_WIDTH-1:0] wr_ptr_bin_next;
  logic [PTR_WIDTH-1:0] wr_ptr_gray_next;
  logic [PTR_WIDTH-1:0] rd_ptr_bin_next;
  logic [PTR_WIDTH-1:0] rd_ptr_gray_next;

  initial begin
    if (DATA_WIDTH < 1 || ADDR_WIDTH < 2 || ADDR_WIDTH > 10) begin
      $fatal(1, "lcvex_async_fifo: invalid DATA_WIDTH/ADDR_WIDTH");
    end
  end

  // These current-pointer status signals do not depend on the enable inputs.
  // Keeping them as continuous assignments avoids a false combinational loop
  // when a caller gates its FIFO enable with full/empty.
  assign rd_empty = (rd_ptr_gray_q == wr_ptr_gray_rd2_q);
  // Inverting the two extra pointer bits is the full condition for a
  // power-of-two FIFO. ADDR_WIDTH>=2 keeps the part-select portable.
  assign wr_full = (wr_ptr_gray_q ==
                    {~rd_ptr_gray_wr2_q[PTR_WIDTH-1:PTR_WIDTH-2],
                     rd_ptr_gray_wr2_q[PTR_WIDTH-3:0]});
  assign rd_data = mem[rd_ptr_bin_q[ADDR_WIDTH-1:0]];

  always_comb begin
    wr_ptr_bin_next = wr_ptr_bin_q;
    if (wr_en && !wr_full) begin
      wr_ptr_bin_next = wr_ptr_bin_q + {{(PTR_WIDTH-1){1'b0}}, 1'b1};
    end
    wr_ptr_gray_next = (wr_ptr_bin_next >> 1) ^ wr_ptr_bin_next;
    rd_ptr_bin_next = rd_ptr_bin_q;
    if (rd_en && !rd_empty) begin
      rd_ptr_bin_next = rd_ptr_bin_q + {{(PTR_WIDTH-1){1'b0}}, 1'b1};
    end
    rd_ptr_gray_next = (rd_ptr_bin_next >> 1) ^ rd_ptr_bin_next;

  end

  // Write pointer and storage. Memory is intentionally not reset: reset only
  // invalidates pointers, which is the required FIFO flush behavior.
  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
      wr_ptr_bin_q <= '0;
      wr_ptr_gray_q <= '0;
    end else begin
      if (wr_en && !wr_full) begin
        mem[wr_ptr_bin_q[ADDR_WIDTH-1:0]] <= wr_data;
      end
      wr_ptr_bin_q <= wr_ptr_bin_next;
      wr_ptr_gray_q <= wr_ptr_gray_next;
    end
  end

  // Read pointer. The asynchronous read view is stable while rd_empty is
  // false; the adapter samples it only on rd_en.
  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      rd_ptr_bin_q <= '0;
      rd_ptr_gray_q <= '0;
    end else begin
      rd_ptr_bin_q <= rd_ptr_bin_next;
      rd_ptr_gray_q <= rd_ptr_gray_next;
    end
  end

  // Synchronizers are reset in their receiving domains. The per-domain reset
  // makes a reset boundary an epoch boundary for both directions.
  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
      rd_ptr_gray_wr1_q <= '0;
      rd_ptr_gray_wr2_q <= '0;
    end else begin
      rd_ptr_gray_wr1_q <= rd_ptr_gray_q;
      rd_ptr_gray_wr2_q <= rd_ptr_gray_wr1_q;
    end
  end

  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      wr_ptr_gray_rd1_q <= '0;
      wr_ptr_gray_rd2_q <= '0;
    end else begin
      wr_ptr_gray_rd1_q <= wr_ptr_gray_q;
      wr_ptr_gray_rd2_q <= wr_ptr_gray_rd1_q;
    end
  end

endmodule
