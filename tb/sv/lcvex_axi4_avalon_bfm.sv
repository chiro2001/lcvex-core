// lcvex_axi4_avalon_bfm.sv
//
// 独立双时钟 EMIF-side BFM。它只模拟 Avalon-MM user interface，不添加
// Qsys error/response 信号；write/read accept 计数和随机延迟用于验证无丢失、
// 无重复以及 waitrequest_n/readdatavalid 语义。

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off UNUSEDSIGNAL */

module lcvex_avalon_emif_bfm #(
    parameter int MEM_WORDS = 4096,
    parameter int unsigned SEED = 32'hb2_054
) (
    input logic         clk,
    input logic         rst_n,
    input logic         cfg_random_wait,
    input logic         cfg_force_wait,
    input logic [3:0]   cfg_read_delay,
    input logic         cfg_drop_readdatavalid,
    input logic         cfg_preserve_read_pending,

    input logic         av_read,
    input logic         av_write,
    input logic [24:0]  av_address,
    input logic [511:0] av_writedata,
    input logic [6:0]   av_burstcount,
    input logic [63:0]  av_byteenable,
    output logic        av_waitrequest_n,
    output logic [511:0] av_readdata,
    output logic        av_readdatavalid,

    output logic [31:0] write_accept_count,
    output logic [31:0] read_accept_count,
    output logic [31:0] duplicate_response_count
);

  logic [511:0] mem [0:MEM_WORDS-1];
  logic [31:0] rng_q;
  logic read_pending_q;
  logic [511:0] pending_data_q;
  logic [3:0] pending_delay_q;

  function automatic logic [31:0] lfsr_next(input logic [31:0] value);
    begin
      lfsr_next = {value[30:0], value[31] ^ value[21] ^ value[1] ^ value[0]};
      if (lfsr_next == 32'd0) begin
        lfsr_next = 32'h1;
      end
    end
  endfunction

  initial begin
    if (MEM_WORDS < 1) begin
      $fatal(1, "lcvex_avalon_emif_bfm: MEM_WORDS must be positive");
    end
    for (int i = 0; i < MEM_WORDS; i++) begin
      for (int j = 0; j < 64; j++) begin
        mem[i][j*8 +: 8] = (i + j) & 8'hff;
      end
    end
  end

  always_comb begin
    if (!rst_n || cfg_force_wait) begin
      av_waitrequest_n = 1'b0;
    end else if (cfg_random_wait) begin
      av_waitrequest_n = !rng_q[0];
    end else begin
      av_waitrequest_n = 1'b1;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rng_q <= SEED == 0 ? 32'h1 : SEED;
      // Test-only backend reset mode: preserve an already accepted read so
      // the adapter can prove that its post-reset DRAIN consumes the late
      // response instead of assigning it to a new request epoch.
      if (!cfg_preserve_read_pending) begin
        read_pending_q <= 1'b0;
        pending_data_q <= '0;
        pending_delay_q <= '0;
      end
      av_readdata <= '0;
      av_readdatavalid <= 1'b0;
      if (!cfg_preserve_read_pending) begin
        write_accept_count <= '0;
        read_accept_count <= '0;
        duplicate_response_count <= '0;
      end
    end else begin
      rng_q <= lfsr_next(rng_q);
      av_readdatavalid <= 1'b0;

      if (read_pending_q) begin
        if (pending_delay_q == 0) begin
          if (!cfg_drop_readdatavalid) begin
            av_readdata <= pending_data_q;
            av_readdatavalid <= 1'b1;
            read_pending_q <= 1'b0;
          end
        end else begin
          pending_delay_q <= pending_delay_q - 1'b1;
        end
      end

      if (av_write && av_waitrequest_n) begin
        write_accept_count <= write_accept_count + 1'b1;
        if (av_address < MEM_WORDS) begin
          for (int j = 0; j < 64; j++) begin
            if (av_byteenable[j]) begin
              mem[av_address][j*8 +: 8] <= av_writedata[j*8 +: 8];
            end
          end
        end
      end

      if (av_read && av_waitrequest_n) begin
        read_accept_count <= read_accept_count + 1'b1;
        if (read_pending_q) begin
          duplicate_response_count <= duplicate_response_count + 1'b1;
        end
        if (av_address < MEM_WORDS) begin
          pending_data_q <= mem[av_address];
        end else begin
          pending_data_q <= '0;
        end
        pending_delay_q <= cfg_random_wait ? (rng_q[4:1] & 4'h7) :
            cfg_read_delay;
        read_pending_q <= 1'b1;
      end
    end
  end

endmodule

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on WIDTHTRUNC */
/* verilator lint_on WIDTHEXPAND */
/* verilator lint_on DECLFILENAME */
