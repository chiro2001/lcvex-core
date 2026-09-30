// lcvex_l2_wb_bfm.sv
// B3 独立下游 BFM：字节模型、固定 seed 随机请求背压、可注入 fault。
// 不复用 lcvex_mem_ram，也不依赖现有 write-through l2 TB。

`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off UNUSEDSIGNAL */

module lcvex_l2_wb_bfm #(
    parameter int DEPTH = 1 << 16,
    parameter int BFM_SEED = 32'h00b3_0551
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
  logic ready_gate;

  function automatic logic address_ok(input lcvex_pkg::mem_req_t q);
    integer last;
    begin
      last = 0;
      for (int i = 0; i < 8; i++) if (q.strb[i]) last = i;
      if (!q.we) last = 7;
      address_ok = (q.addr < DEPTH) && ((q.addr + last) < DEPTH);
    end
  endfunction

  // 至少大多数周期允许请求，且不会因为随机背压永久饿死。
  assign ready_gate = lfsr[0] || lfsr[2] || lfsr[5];
  assign req_ready = rst_n && !pending && ready_gate;
  assign rsp_valid = rst_n && pending;
  assign rsp.rdata = rdata_r;
  assign rsp.fault = fault_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (init_we) begin
      for (int i = 0; i < 8; i++) begin
        if (init_strb[i] && ((init_addr + i) < DEPTH))
          mem[init_addr+i] <= init_wdata[i*8 +: 8];
      end
    end
    if (!rst_n) begin
      pending <= 1'b0;
      rdata_r <= 64'd0;
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
        rdata_r <= 64'd0;
        if (address_ok(req) && !(fault_enable && (req.addr == fault_addr) &&
                                 (!fault_we_only || req.we))) begin
        if (req.we) begin
            $display("TB_BFM_WB addr=0x%h data=0x%h", req.addr, req.wdata);
            for (int i = 0; i < 8; i++) begin
              if (req.strb[i]) mem[req.addr+i] <= req.wdata[i*8 +: 8];
            end
          end else begin
            for (int i = 0; i < 8; i++) rdata_r[i*8 +: 8] <= mem[req.addr+i];
          end
        end
      end else if (pending && rsp_ready) begin
        pending <= 1'b0;
        response_count <= response_count + 1'b1;
      end
    end
  end

  /* verilator lint_on UNUSEDSIGNAL */
  /* verilator lint_on WIDTHTRUNC */
  /* verilator lint_on WIDTHEXPAND */

endmodule
