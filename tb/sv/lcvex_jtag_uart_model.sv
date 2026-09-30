// lcvex_jtag_uart_model.sv
//
// B25 JTAG-UART focused model.  This is a small behavioral model of the
// Avalon-MM slave boundary used by lcvex_catapult_soc_jtag_uart; it is not a
// replacement for the vendor-generated production IP.
//
// Address 0 is DATA and address 1 is CONTROL.  DATA reads expose RVALID in
// bit 15 and pop one RX character when the Avalon read is accepted.  CONTROL
// reads expose TX WSPACE in bits [31:16] and host activity in bit 10.  DATA
// writes enqueue one TX character and are back-pressured while the TX FIFO is
// full.  The model intentionally keeps the FIFO state and Avalon side-effect
// counters visible to the focused bridge test.

`timescale 1ns/1ps

module lcvex_jtag_uart_model #(
    parameter int TX_DEPTH = 4,
    parameter int RX_DEPTH = 4
) (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       chipselect,
    input  logic       read_n,
    input  logic       write_n,
    input  logic [0:0] address,
    input  logic [31:0] writedata,
    output logic [31:0] readdata,
    output logic       waitrequest,
    output logic       irq,

    // Test-side host controls.  RX injection is accepted when rx_ready is
    // high; tx_pop drains at most one queued TX character per clock.
    input  logic       rx_valid,
    input  logic [7:0] rx_char,
    output logic       rx_ready,
    input  logic       tx_pop,

    // An externally held waitrequest is useful for delayed Avalon acceptance
    // tests.  It is ORed with the natural TX-full backpressure.
    input  logic       force_waitrequest,
    input  logic       host_activity,

    output logic [31:0] avalon_read_count,
    output logic [31:0] avalon_write_count,
    output logic [31:0] data_read_count,
    output logic [31:0] control_read_count,
    output logic [31:0] data_write_count,
    output logic [31:0] control_write_count,
    output logic [31:0] rx_pop_count,
    output logic [31:0] tx_push_count,
    output logic [15:0] tx_wspace,
    output logic [31:0] tx_event_count,
    output logic [7:0]  tx_event_char,
    output logic        tx_event_valid,
    output logic        tx_drain_valid,
    output logic [7:0]  tx_drain_char
);

  localparam int RX_PTR_W = (RX_DEPTH <= 1) ? 1 : $clog2(RX_DEPTH);
  localparam int TX_PTR_W = (TX_DEPTH <= 1) ? 1 : $clog2(TX_DEPTH);

  logic [7:0] rx_fifo [0:RX_DEPTH-1];
  logic [31:0] tx_fifo [0:TX_DEPTH-1];
  logic [RX_PTR_W-1:0] rx_rd_ptr;
  logic [RX_PTR_W-1:0] rx_wr_ptr;
  logic [TX_PTR_W-1:0] tx_rd_ptr;
  logic [TX_PTR_W-1:0] tx_wr_ptr;
  integer rx_count;
  integer tx_count;
  localparam logic [RX_PTR_W-1:0] RX_LAST_PTR = RX_PTR_W'(RX_DEPTH - 1);
  localparam logic [TX_PTR_W-1:0] TX_LAST_PTR = TX_PTR_W'(TX_DEPTH - 1);
  logic [15:0] tx_wspace_calc;

  wire avalon_read_fire = chipselect && !read_n && !waitrequest;
  wire avalon_write_fire = chipselect && !write_n && !waitrequest;
  wire data_read_fire = avalon_read_fire && (address == 1'b0);
  wire data_write_fire = avalon_write_fire && (address == 1'b0);
  wire rx_push_fire = rx_valid && rx_ready;
  wire rx_pop_fire = data_read_fire && (rx_count != 0);
  wire tx_pop_fire = tx_pop && (tx_count != 0);

  assign rx_ready = (rx_count < RX_DEPTH);
  assign tx_wspace = tx_wspace_calc;
  assign irq = 1'b0; // This lightweight model deliberately has no IRQ model.

  assign tx_wspace_calc = 16'(TX_DEPTH - tx_count);

  // The vendor slave has no readdatavalid on this Avalon interface.  The
  // bridge samples readdata at the cycle in which waitrequest is low.
  always @* begin
    readdata = 32'd0;
    if (address == 1'b0) begin
      readdata[15] = (rx_count != 0); // DATA.RVALID
      if (rx_count != 0)
        readdata[7:0] = rx_fifo[rx_rd_ptr];
    end else begin
      readdata[31:16] = tx_wspace_calc; // CONTROL.WSPACE
      readdata[10] = host_activity;           // CONTROL.AC
    end
  end

  always @* begin
    waitrequest = force_waitrequest;
    if (chipselect && !write_n && (address == 1'b0) &&
        (tx_count >= TX_DEPTH)) begin
      waitrequest = 1'b1;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_rd_ptr         <= '0;
      rx_wr_ptr         <= '0;
      tx_rd_ptr         <= '0;
      tx_wr_ptr         <= '0;
      rx_count          <= 0;
      tx_count          <= 0;
      avalon_read_count <= 0;
      avalon_write_count <= 0;
      data_read_count   <= 0;
      control_read_count <= 0;
      data_write_count  <= 0;
      control_write_count <= 0;
      rx_pop_count      <= 0;
      tx_push_count     <= 0;
      tx_event_count    <= 0;
      tx_event_char     <= 8'd0;
      tx_event_valid    <= 1'b0;
      tx_drain_valid    <= 1'b0;
      tx_drain_char     <= 8'd0;
    end else begin
      tx_event_valid <= 1'b0;
      tx_drain_valid <= 1'b0;

      if (avalon_read_fire) begin
        avalon_read_count <= avalon_read_count + 1;
        if (address == 1'b0)
          data_read_count <= data_read_count + 1;
        else
          control_read_count <= control_read_count + 1;
      end
      if (avalon_write_fire) begin
        avalon_write_count <= avalon_write_count + 1;
        if (address == 1'b0)
          data_write_count <= data_write_count + 1;
        else
          control_write_count <= control_write_count + 1;
      end

      if (rx_push_fire) begin
        rx_fifo[rx_wr_ptr] <= rx_char;
        if (rx_wr_ptr == RX_LAST_PTR)
          rx_wr_ptr <= '0;
        else
          rx_wr_ptr <= rx_wr_ptr + 1'b1;
      end
      if (rx_pop_fire) begin
        if (rx_rd_ptr == RX_LAST_PTR)
          rx_rd_ptr <= '0;
        else
          rx_rd_ptr <= rx_rd_ptr + 1'b1;
        rx_pop_count <= rx_pop_count + 1;
      end
      case ({rx_push_fire, rx_pop_fire})
        2'b10: rx_count <= rx_count + 1;
        2'b01: rx_count <= rx_count - 1;
        default: rx_count <= rx_count;
      endcase

      if (data_write_fire) begin
        tx_fifo[tx_wr_ptr] <= writedata;
        if (tx_wr_ptr == TX_LAST_PTR)
          tx_wr_ptr <= '0;
        else
          tx_wr_ptr <= tx_wr_ptr + 1'b1;
        tx_push_count  <= tx_push_count + 1;
        tx_event_count <= tx_event_count + 1;
        tx_event_char  <= writedata[7:0];
        tx_event_valid <= 1'b1;
      end
      if (tx_pop_fire) begin
        tx_drain_valid <= 1'b1;
        tx_drain_char  <= tx_fifo[tx_rd_ptr][7:0];
        if (tx_rd_ptr == TX_LAST_PTR)
          tx_rd_ptr <= '0;
        else
          tx_rd_ptr <= tx_rd_ptr + 1'b1;
      end
      case ({data_write_fire, tx_pop_fire})
        2'b10: tx_count <= tx_count + 1;
        2'b01: tx_count <= tx_count - 1;
        default: tx_count <= tx_count;
      endcase
    end
  end

endmodule


// Quartus 21.4 generated-IP timing model.  Unlike the lightweight model
// above, the generated Altera JTAG-UART performs the Avalon side effect while
// its registered waitrequest is high, lowers waitrequest for the following
// cycle, and registers DATA selection/RVALID together with the showahead-OFF
// RX FIFO q.  The bridge must therefore hold its request across the high
// phase and capture readdata on the following low phase.
module lcvex_jtag_uart_vendor_model #(
    parameter int TX_DEPTH = 64,
    parameter int RX_DEPTH = 16
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        chipselect,
    input  logic        read_n,
    input  logic        write_n,
    input  logic [0:0]  address,
    input  logic [31:0] writedata,
    output logic [31:0] readdata,
    output logic        waitrequest,
    output logic        irq,
    input  logic        rx_valid,
    input  logic [7:0]  rx_char,
    output logic        rx_ready,
    input  logic        tx_pop,
    input  logic        force_waitrequest,
    input  logic        host_activity,
    output logic [31:0] avalon_read_count,
    output logic [31:0] avalon_write_count,
    output logic [31:0] data_read_count,
    output logic [31:0] control_read_count,
    output logic [31:0] data_write_count,
    output logic [31:0] control_write_count,
    output logic [31:0] rx_pop_count,
    output logic [31:0] tx_push_count,
    output logic [15:0] tx_wspace,
    output logic [31:0] tx_event_count,
    output logic [7:0]  tx_event_char,
    output logic        tx_event_valid,
    output logic        tx_drain_valid,
    output logic [7:0]  tx_drain_char
);

  localparam int RX_PTR_W = (RX_DEPTH <= 1) ? 1 : $clog2(RX_DEPTH);
  localparam int TX_PTR_W = (TX_DEPTH <= 1) ? 1 : $clog2(TX_DEPTH);
  localparam logic [RX_PTR_W-1:0] RX_LAST_PTR = RX_PTR_W'(RX_DEPTH - 1);
  localparam logic [TX_PTR_W-1:0] TX_LAST_PTR = TX_PTR_W'(TX_DEPTH - 1);

  logic [7:0] rx_fifo [0:RX_DEPTH-1];
  logic [7:0] tx_fifo [0:TX_DEPTH-1];
  logic [RX_PTR_W-1:0] rx_rd_ptr;
  logic [RX_PTR_W-1:0] rx_wr_ptr;
  logic [TX_PTR_W-1:0] tx_rd_ptr;
  logic [TX_PTR_W-1:0] tx_wr_ptr;
  integer rx_count;
  integer tx_count;

  logic       av_waitrequest_q;
  logic       read_0_q;
  logic       rvalid_q;
  logic       woverflow_q;
  logic       ac_q;
  logic [7:0] fifo_rdata_q;
  logic       irq_enable_tx_q;
  logic       irq_enable_rx_q;
  logic       tx_almost_empty_q;
  logic       rx_almost_full_q;

  wire tx_irq_pending = irq_enable_tx_q && tx_almost_empty_q;
  wire rx_irq_pending = irq_enable_rx_q && rx_almost_full_q;

  wire selected = chipselect && (!read_n || !write_n);
  wire vendor_read_fire = chipselect && !read_n && av_waitrequest_q &&
                          !force_waitrequest;
  wire vendor_write_fire = chipselect && !write_n && av_waitrequest_q &&
                           !force_waitrequest;
  wire data_read_fire = vendor_read_fire && (address == 1'b0);
  wire data_write_fire = vendor_write_fire && (address == 1'b0);
  wire rx_push_fire = rx_valid && rx_ready;
  wire rx_pop_fire = data_read_fire && (rx_count != 0);
  wire tx_push_fire = data_write_fire && (tx_count < TX_DEPTH);
  wire tx_pop_fire = tx_pop && (tx_count != 0);

  assign waitrequest = force_waitrequest || av_waitrequest_q;
  assign rx_ready = (rx_count < RX_DEPTH);
  assign tx_wspace = 16'(TX_DEPTH - tx_count);
  assign irq = tx_irq_pending || rx_irq_pending;

  always_comb begin
    readdata = 32'd0;
    if (read_0_q) begin
      readdata[22:16] = 7'(rx_count);
      readdata[15] = rvalid_q;
      readdata[14] = woverflow_q;
      readdata[13] = (tx_count < TX_DEPTH);
      readdata[12] = (rx_count != 0);
      readdata[10] = ac_q;
      readdata[9] = tx_irq_pending;
      readdata[8] = rx_irq_pending;
      readdata[7:0] = fifo_rdata_q;
    end else begin
      readdata[31:16] = 16'(TX_DEPTH - tx_count);
      readdata[15] = rvalid_q;
      readdata[14] = woverflow_q;
      readdata[13] = (tx_count < TX_DEPTH);
      readdata[12] = (rx_count != 0);
      readdata[10] = ac_q;
      readdata[9] = tx_irq_pending;
      readdata[8] = rx_irq_pending;
      readdata[1] = irq_enable_tx_q;
      readdata[0] = irq_enable_rx_q;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_rd_ptr <= '0;
      rx_wr_ptr <= '0;
      tx_rd_ptr <= '0;
      tx_wr_ptr <= '0;
      rx_count <= 0;
      tx_count <= 0;
      av_waitrequest_q <= 1'b1;
      read_0_q <= 1'b0;
      rvalid_q <= 1'b0;
      woverflow_q <= 1'b0;
      ac_q <= 1'b0;
      fifo_rdata_q <= 8'd0;
      irq_enable_tx_q <= 1'b0;
      irq_enable_rx_q <= 1'b0;
      tx_almost_empty_q <= 1'b0;
      rx_almost_full_q <= 1'b0;
      avalon_read_count <= 0;
      avalon_write_count <= 0;
      data_read_count <= 0;
      control_read_count <= 0;
      data_write_count <= 0;
      control_write_count <= 0;
      rx_pop_count <= 0;
      tx_push_count <= 0;
      tx_event_count <= 0;
      tx_event_char <= 8'd0;
      tx_event_valid <= 1'b0;
      tx_drain_valid <= 1'b0;
      tx_drain_char <= 8'd0;
    end else begin
      tx_event_valid <= 1'b0;
      tx_drain_valid <= 1'b0;
      read_0_q <= 1'b0;
      tx_almost_empty_q <= (tx_count <= 8);
      // The checked-in Quartus 21.4 JTAG-UART source is configured for 63
      // free entries, i.e. assert RX IRQ as soon as at least one byte exists.
      rx_almost_full_q <= (rx_count != 0);
      if (host_activity)
        ac_q <= 1'b1;

      // This is the generated-IP waitrequest recurrence.  The test-only force
      // input parks the interface before its internal side effect so delayed
      // acceptance and reset can still be exercised deterministically.
      if (force_waitrequest)
        av_waitrequest_q <= 1'b1;
      else
        av_waitrequest_q <= ~(selected && av_waitrequest_q);

      if (vendor_read_fire) begin
        avalon_read_count <= avalon_read_count + 1;
        read_0_q <= !address;
        if (address == 1'b0) begin
          data_read_count <= data_read_count + 1;
          rvalid_q <= (rx_count != 0);
        end else begin
          control_read_count <= control_read_count + 1;
        end
      end
      if (vendor_write_fire) begin
        avalon_write_count <= avalon_write_count + 1;
        if (address == 1'b0) begin
          data_write_count <= data_write_count + 1;
          if (tx_count >= TX_DEPTH)
            woverflow_q <= 1'b1;
        end else begin
          control_write_count <= control_write_count + 1;
          irq_enable_rx_q <= writedata[0];
          irq_enable_tx_q <= writedata[1];
          if (writedata[10] && !host_activity)
            ac_q <= 1'b0;
        end
      end

      if (rx_push_fire) begin
        rx_fifo[rx_wr_ptr] <= rx_char;
        if (rx_wr_ptr == RX_LAST_PTR)
          rx_wr_ptr <= '0;
        else
          rx_wr_ptr <= rx_wr_ptr + 1'b1;
      end
      if (rx_pop_fire) begin
        fifo_rdata_q <= rx_fifo[rx_rd_ptr];
        if (rx_rd_ptr == RX_LAST_PTR)
          rx_rd_ptr <= '0;
        else
          rx_rd_ptr <= rx_rd_ptr + 1'b1;
        rx_pop_count <= rx_pop_count + 1;
      end
      case ({rx_push_fire, rx_pop_fire})
        2'b10: rx_count <= rx_count + 1;
        2'b01: rx_count <= rx_count - 1;
        default: rx_count <= rx_count;
      endcase

      if (tx_push_fire) begin
        tx_fifo[tx_wr_ptr] <= writedata[7:0];
        if (tx_wr_ptr == TX_LAST_PTR)
          tx_wr_ptr <= '0;
        else
          tx_wr_ptr <= tx_wr_ptr + 1'b1;
        tx_push_count <= tx_push_count + 1;
        tx_event_count <= tx_event_count + 1;
        tx_event_char <= writedata[7:0];
        tx_event_valid <= 1'b1;
      end
      if (tx_pop_fire) begin
        tx_drain_char <= tx_fifo[tx_rd_ptr];
        tx_drain_valid <= 1'b1;
        if (tx_rd_ptr == TX_LAST_PTR)
          tx_rd_ptr <= '0;
        else
          tx_rd_ptr <= tx_rd_ptr + 1'b1;
      end
      case ({tx_push_fire, tx_pop_fire})
        2'b10: tx_count <= tx_count + 1;
        2'b01: tx_count <= tx_count - 1;
        default: tx_count <= tx_count;
      endcase
    end
  end

endmodule
