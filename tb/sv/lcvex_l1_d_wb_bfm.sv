// lcvex_l1_d_wb_bfm.sv
// B4 独立 PoC BFM：字节模型、随机 req READY、fault 注入和复位装载口。

`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off UNUSEDSIGNAL */

module lcvex_l1_d_wb_bfm #(
    parameter int DEPTH = 1 << 16,
    parameter int BFM_SEED = 32'hd1_056a
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                req_valid,
    input  lcvex_pkg::mem_req_t req,
    output logic                req_ready,
    output logic                rsp_valid,
    output lcvex_pkg::mem_rsp_t rsp,
    input  logic                rsp_ready,
    input  logic                fault_enable,
    input  logic [63:0]         fault_addr,
    input  logic                fault_we_only,
    input  logic                init_we,
    input  logic [63:0]         init_addr,
    input  logic [7:0]          init_strb,
    input  logic [63:0]         init_wdata,
    output logic [31:0]         accepted_count,
    output logic [31:0]         response_count,
    output logic [31:0]         write_count,
    output logic [31:0]         read_count
);

  logic [7:0] mem [0:DEPTH-1];
  logic pending;
  logic [63:0] rdata_r;
  logic fault_r;
  logic [31:0] lfsr;

  function automatic logic address_ok(input lcvex_pkg::mem_req_t q);
    integer last;
    begin
      last = q.we ? 0 : 7;
      for (int i = 0; i < 8; i++) if (q.strb[i]) last = i;
      address_ok = (q.addr < DEPTH) && ((q.addr + last) < DEPTH);
    end
  endfunction

  assign req_ready = rst_n && !pending &&
                     (lfsr[0] || lfsr[2] || lfsr[5]);
  assign rsp_valid = rst_n && pending;
  assign rsp.rdata = rdata_r;
  assign rsp.fault = fault_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (init_we) begin
      for (int i = 0; i < 8; i++)
        if (init_strb[i] && (init_addr + i < DEPTH))
          mem[init_addr+i] <= init_wdata[i*8 +: 8];
    end
    if (!rst_n) begin
      pending <= 1'b0;
      rdata_r <= '0;
      fault_r <= 1'b0;
      lfsr <= BFM_SEED;
      accepted_count <= 0;
      response_count <= 0;
      write_count <= 0;
      read_count <= 0;
    end else begin
      lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
      if (req_valid && req_ready) begin
        pending <= 1'b1;
        accepted_count <= accepted_count + 1'b1;
        if (req.we) write_count <= write_count + 1'b1;
        else read_count <= read_count + 1'b1;
        fault_r <= !address_ok(req) ||
                   (fault_enable && (req.addr == fault_addr) &&
                    (!fault_we_only || req.we));
        rdata_r <= '0;
        if (address_ok(req) &&
            !(fault_enable && (req.addr == fault_addr) &&
              (!fault_we_only || req.we))) begin
          if (req.we) begin
            for (int i = 0; i < 8; i++)
              if (req.strb[i]) mem[req.addr+i] <= req.wdata[i*8 +: 8];
          end else begin
            for (int i = 0; i < 8; i++)
              rdata_r[i*8 +: 8] <= mem[req.addr+i];
          end
        end
      end else if (pending && rsp_ready) begin
        pending <= 1'b0;
        response_count <= response_count + 1'b1;
      end
    end
  end

endmodule
