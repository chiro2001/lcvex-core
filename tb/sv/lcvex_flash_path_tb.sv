`timescale 1ns/1ps

module lcvex_flash_path_tb;
  import lcvex_pkg::*;

  localparam logic [63:0] FLASH_BASE = 64'h1000_0000;
  localparam logic [63:0] FLASH_TOP = FLASH_BASE + 64'h100;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic req_valid = 1'b0;
  mem_req_t req = '0;
  logic req_ready;
  logic rsp_out_valid;
  mem_rsp_t rsp_out;
  logic rsp_out_ready = 1'b0;

  logic ram_req_valid, mmio_req_valid, mmio2_req_valid;
  logic mmio3_req_valid, mmio4_req_valid, mmio5_req_valid, mmio6_req_valid;
  mem_req_t ram_req, mmio_req, mmio2_req, mmio3_req, mmio4_req, mmio5_req, mmio6_req;
  logic ram_rsp_ready, mmio_rsp_ready, mmio2_rsp_ready;
  logic mmio3_rsp_ready, mmio4_rsp_ready, mmio5_rsp_ready, mmio6_rsp_ready;
  logic mmio6_req_accept;
  logic mmio6_rsp_valid;
  mem_rsp_t mmio6_rsp;

  logic av_read;
  logic [24:0] av_address;
  logic [6:0] av_burstcount;
  logic [3:0] av_byteenable;
  logic av_waitrequest;
  logic force_waitrequest = 1'b0;
  logic force_drop_read = 1'b0;
  logic [31:0] av_readdata;
  logic av_readdatavalid;
  logic av_pending;
  logic [24:0] av_address_q;
  logic [1:0] av_delay_q;
  logic [7:0] flash_bytes [0:255];
  logic [7:0] cycle_q;

  lcvex_mem_router #(
      .MMIO6_BASE(FLASH_BASE), .MMIO6_TOP(FLASH_TOP)
  ) router (
      .clk(clk), .rst_n(rst_n), .req_valid(req_valid), .req(req),
      .req_ready(req_ready), .rsp_out_valid(rsp_out_valid),
      .rsp_out(rsp_out), .rsp_out_ready(rsp_out_ready),
      .ram_req_valid(ram_req_valid), .ram_req(ram_req),
      .ram_req_accept(1'b1), .ram_rsp_valid(1'b0), .ram_rsp('0),
      .ram_rsp_ready(ram_rsp_ready),
      .mmio_req_valid(mmio_req_valid), .mmio_req(mmio_req),
      .mmio_req_accept(1'b1), .mmio_rsp_valid(1'b0), .mmio_rsp('0),
      .mmio_rsp_ready(mmio_rsp_ready),
      .mmio2_req_valid(mmio2_req_valid), .mmio2_req(mmio2_req),
      .mmio2_req_accept(1'b1), .mmio2_rsp_valid(1'b0), .mmio2_rsp('0),
      .mmio2_rsp_ready(mmio2_rsp_ready),
      .mmio3_req_valid(mmio3_req_valid), .mmio3_req(mmio3_req),
      .mmio3_req_accept(1'b1), .mmio3_rsp_valid(1'b0), .mmio3_rsp('0),
      .mmio3_rsp_ready(mmio3_rsp_ready),
      .mmio4_req_valid(mmio4_req_valid), .mmio4_req(mmio4_req),
      .mmio4_req_accept(1'b1), .mmio4_rsp_valid(1'b0), .mmio4_rsp('0),
      .mmio4_rsp_ready(mmio4_rsp_ready),
      .mmio5_req_valid(mmio5_req_valid), .mmio5_req(mmio5_req),
      .mmio5_req_accept(1'b1), .mmio5_rsp_valid(1'b0), .mmio5_rsp('0),
      .mmio5_rsp_ready(mmio5_rsp_ready),
      .mmio6_req_valid(mmio6_req_valid), .mmio6_req(mmio6_req),
      .mmio6_req_accept(mmio6_req_accept), .mmio6_rsp_valid(mmio6_rsp_valid),
      .mmio6_rsp(mmio6_rsp), .mmio6_rsp_ready(mmio6_rsp_ready)
  );

  lcvex_catapult_soc_epcq_mem #(
      .FLASH_BASE(FLASH_BASE), .FLASH_TOP(FLASH_TOP),
      .WAIT_LIMIT_CYCLES(32'd12)
  ) bridge (
      .clk(clk), .rst_n(rst_n), .req_valid(mmio6_req_valid),
      .req(mmio6_req), .req_accept(mmio6_req_accept),
      .rsp_valid(mmio6_rsp_valid), .rsp(mmio6_rsp),
      .rsp_ready(mmio6_rsp_ready), .av_read(av_read),
      .av_address(av_address), .av_burstcount(av_burstcount),
      .av_byteenable(av_byteenable), .av_waitrequest(av_waitrequest),
      .av_readdata(av_readdata), .av_readdatavalid(av_readdatavalid)
  );

  always #5 clk = ~clk;
  assign av_waitrequest = force_waitrequest || (cycle_q[1:0] != 2'b10);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      av_pending <= 1'b0;
      av_address_q <= '0;
      av_delay_q <= '0;
      av_readdata <= '0;
      av_readdatavalid <= 1'b0;
      cycle_q <= '0;
    end else begin
      cycle_q <= cycle_q + 8'd1;
      av_readdatavalid <= 1'b0;
      if (av_pending) begin
        if (av_delay_q == 0) begin
          if (!force_drop_read) begin
            av_readdata <= {flash_bytes[int'(av_address_q)*4+3],
                            flash_bytes[int'(av_address_q)*4+2],
                            flash_bytes[int'(av_address_q)*4+1],
                            flash_bytes[int'(av_address_q)*4+0]};
            av_readdatavalid <= 1'b1;
          end
          av_pending <= 1'b0;
        end else begin
          av_delay_q <= av_delay_q - 2'd1;
        end
      end
      if (av_read && !av_waitrequest) begin
        if (av_pending) $fatal(1, "Flash bridge issued overlapping Avalon reads");
        av_pending <= 1'b1;
        av_address_q <= av_address;
        av_delay_q <= 2'd2;
      end
    end
  end

  task automatic transact(input logic write_en,
                          input logic [63:0] address,
                          output logic [63:0] data,
                          output logic fault);
    begin
      @(negedge clk);
      req.addr = address;
      req.we = write_en;
      req.strb = 8'hff;
      req.wdata = 64'hdead_beef_cafe_f00d;
      req.maint = MAINT_NONE;
      req.bypass = 1'b1;
      req_valid = 1'b1;
      do @(posedge clk); while (!req_ready);
      @(negedge clk);
      req_valid = 1'b0;
      while (!rsp_out_valid) @(negedge clk);
      data = rsp_out.rdata;
      fault = rsp_out.fault;
      repeat (2) begin
        @(negedge clk);
        if (!rsp_out_valid || rsp_out.rdata !== data || rsp_out.fault !== fault)
          $fatal(1, "response changed under backpressure");
      end
      rsp_out_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      rsp_out_ready = 1'b0;
    end
  endtask

  initial begin
    logic [63:0] data;
    logic fault;
    for (int i = 0; i < 256; i++) flash_bytes[i] = 8'(i);
    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    transact(1'b0, FLASH_BASE, data, fault);
    if (fault || data !== 64'h0706_0504_0302_0100)
      $fatal(1, "aligned Flash read mismatch fault=%b data=%h", fault, data);
    if (av_burstcount != 1 || av_byteenable != 4'hf)
      $fatal(1, "Flash Avalon controls are not single-word/full-lane");

    transact(1'b0, FLASH_BASE + 1, data, fault);
    if (fault || data !== 64'h0807_0605_0403_0201)
      $fatal(1, "unaligned Flash read mismatch fault=%b data=%h", fault, data);

    transact(1'b1, FLASH_BASE, data, fault);
    if (!fault) $fatal(1, "Flash write was not rejected");
    transact(1'b0, FLASH_TOP - 4, data, fault);
    if (!fault) $fatal(1, "read crossing Flash aperture end was not rejected");

    force_waitrequest = 1'b1;
    transact(1'b0, FLASH_BASE, data, fault);
    if (!fault) $fatal(1, "permanent Avalon waitrequest did not time out");
    force_waitrequest = 1'b0;
    force_drop_read = 1'b1;
    transact(1'b0, FLASH_BASE, data, fault);
    if (!fault) $fatal(1, "missing Avalon readdatavalid did not time out");

    $display("LCVEX_FLASH_PATH_TB PASS");
    $finish;
  end
endmodule
