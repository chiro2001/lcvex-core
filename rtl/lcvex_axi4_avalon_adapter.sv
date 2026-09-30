// lcvex_axi4_avalon_adapter.sv
//
// B2-EMIF: AXI4 Full 128-bit -> 512-bit Avalon-MM bridge.
//
// The AXI side is a single-outstanding slave. AW and W are independently
// buffered, then at most four 128-bit beats are merged into one 64B Avalon
// word. The request and response packets cross a common-reset asynchronous
// FIFO boundary; the EMIF side owns all Avalon waitrequest/readdatavalid
// state. Avalon has no error response, so accepted backend transactions
// return AXI OKAY and all local validation/calibration errors return DECERR.

`timescale 1ns/1ps

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off DECLFILENAME */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off SYNCASYNCNET */

module lcvex_axi4_avalon_adapter #(
    parameter int ADDR_WIDTH = 64,
    parameter int DATA_WIDTH = 128,
    parameter int ID_WIDTH = 4,
    // Maximum number of EMIF clock edges spent waiting for an Avalon
    // acceptance or for a read response.  A read which has already been
    // accepted is moved to DRAIN on timeout so a late readdatavalid cannot
    // complete a later epoch.  The default is deliberately finite: an
    // Avalon endpoint has no error channel with which to report a dead
    // backend.  The production default is conservative for the 266.666750
    // MHz EMIF user clock: 4096 cycles is approximately 15.36 us.  Focused
    // SV/Cocotb endpoints override this with 32 cycles to keep fault tests
    // short; that test value is not a vendor-latency guarantee.
    parameter int unsigned AVALON_TIMEOUT_CYCLES = 4096
) (
    input logic cpu_clk,
    input logic emif_clk,
    input logic cpu_rst_n,
    input logic emif_rst_n,

    // EMIF status is synchronous to emif_clk in the platform wrapper.
    input logic cal_success,
    input logic cal_fail,

    // AXI4 AW channel
    input logic                   awvalid,
    output logic                  awready,
    input logic [ID_WIDTH-1:0]    awid,
    input logic [ADDR_WIDTH-1:0]  awaddr,
    input logic [7:0]             awlen,
    input logic [2:0]             awsize,
    input logic [1:0]             awburst,
    input logic                   awlock,
    input logic [3:0]             awcache,
    input logic [2:0]             awprot,
    input logic [3:0]             awqos,

    // AXI4 W channel
    input logic                   wvalid,
    output logic                  wready,
    input logic [DATA_WIDTH-1:0]  wdata,
    input logic [DATA_WIDTH/8-1:0] wstrb,
    input logic                   wlast,

    // AXI4 B channel
    output logic                  bvalid,
    input logic                   bready,
    output logic [ID_WIDTH-1:0]   bid,
    output logic [1:0]            bresp,

    // AXI4 AR channel
    input logic                   arvalid,
    output logic                  arready,
    input logic [ID_WIDTH-1:0]    arid,
    input logic [ADDR_WIDTH-1:0]  araddr,
    input logic [7:0]             arlen,
    input logic [2:0]             arsize,
    input logic [1:0]             arburst,
    input logic                   arlock,
    input logic [3:0]             arcache,
    input logic [2:0]             arprot,
    input logic [3:0]             arqos,

    // AXI4 R channel
    output logic                  rvalid,
    input logic                   rready,
    output logic [ID_WIDTH-1:0]   rid,
    output logic [DATA_WIDTH-1:0] rdata,
    output logic [1:0]            rresp,
    output logic                  rlast,

    // Avalon-MM 512-bit EMIF user port. addressUnits=WORDS and burstcount
    // is one because one Avalon word is one complete 64B line.
    output logic                  avalon_read,
    output logic                  avalon_write,
    output logic [24:0]           avalon_address,
    output logic [511:0]          avalon_writedata,
    output logic [6:0]            avalon_burstcount,
    output logic [63:0]           avalon_byteenable,
    input logic                   avalon_waitrequest_n,
    input logic [511:0]           avalon_readdata,
    input logic                   avalon_readdatavalid,
    // One-cycle indication that the adapter intentionally abandons a
    // stalled Avalon command because the bounded timeout expired.  It is
    // consumed by the protocol checker to distinguish an error completion
    // from an illegal spontaneous command change.
    output logic                  avalon_timeout_abort
);

  import lcvex_axi4_pkg::*;
  import lcvex_axi4_avalon_pkg::*;

  localparam int BYTE_LANES = DATA_WIDTH / 8;
  localparam int FIFO_ADDR_WIDTH = 2;
  localparam int TIMEOUT_WIDTH =
      (AVALON_TIMEOUT_CYCLES < 2) ? 1 : $clog2(AVALON_TIMEOUT_CYCLES + 1);
  localparam logic [TIMEOUT_WIDTH-1:0] TIMEOUT_TERMINAL =
      (AVALON_TIMEOUT_CYCLES > 0) ? (AVALON_TIMEOUT_CYCLES - 1) : '0;

  typedef enum logic [3:0] {
    CPU_IDLE,
    CPU_WRITE_COLLECT,
    CPU_SEND,
    CPU_WAIT_RESPONSE,
    CPU_B_RESPONSE,
    CPU_R_RESPONSE
  } cpu_state_t;

  typedef enum logic [1:0] {
    EMIF_IDLE,
    EMIF_ISSUE,
    EMIF_WAIT_READ,
    EMIF_DRAIN
  } emif_state_t;

  typedef struct packed {
    logic                    is_write;
    logic [ID_WIDTH-1:0]     id;
    logic [ADDR_WIDTH-1:0]  addr;
    logic [7:0]             len;
    logic [2:0]             size;
    logic [1:0]             burst;
    logic [24:0]            avalon_address;
    logic [511:0]           writedata;
    logic [63:0]            byteenable;
  } request_packet_t;

  typedef struct packed {
    logic                    is_write;
    logic [ID_WIDTH-1:0]     id;
    logic [1:0]             resp;
    logic [511:0]           readdata;
  } response_packet_t;

  localparam int REQUEST_WIDTH = $bits(request_packet_t);
  localparam int RESPONSE_WIDTH = $bits(response_packet_t);

  logic cpu_fsm_reset_req_n;
  logic emif_fsm_reset_req_n;
  logic cpu_fifo_reset_req_n;
  logic emif_fifo_reset_req_n;
  logic cpu_rst_sync0_n;
  logic cpu_rst_sync1_n;
  logic emif_rst_sync0_n;
  logic emif_rst_sync1_n;
  logic cpu_rst_sync0_n_fifo;
  logic cpu_rst_sync1_n_fifo;
  logic emif_rst_sync0_n_fifo;
  logic emif_rst_sync1_n_fifo;
  // This chain is intentionally not reset by emif_rst_n: its second stage
  // tells the retention block whether a CPU reset has really re-armed the
  // epoch, even while the EMIF domain is being reset.  FPGA power-up values
  // are explicit zero; release is then sampled on two emif_clk edges.
  /* verilator lint_off PROCASSINIT */
  (* ASYNC_REG = "TRUE" *) logic cpu_rst_emif_meta_q = 1'b0;
  (* ASYNC_REG = "TRUE" *) logic cpu_rst_emif_sync_q = 1'b0;
  logic cpu_fsm_rst_n;
  logic emif_fsm_rst_n;
  logic cpu_fifo_rst_n;
  logic emif_fifo_rst_n;
  logic cal_ready_cpu;
  logic cal_failed_cpu;
  logic cal_abort_cpu;
  logic cal_local;
  logic cal_accept;
  (* ASYNC_REG = "TRUE" *) logic emif_reset_cpu_meta_q;
  (* ASYNC_REG = "TRUE" *) logic emif_reset_cpu_sync_q;
  logic emif_reset_abort_cpu;
  (* ASYNC_REG = "TRUE" *) logic emif_poisoned_cpu_meta_q;
  (* ASYNC_REG = "TRUE" *) logic emif_poisoned_cpu_q;

  lcvex_calibration_gate calibration_gate (
      .cpu_clk,
      .emif_clk,
      .cpu_rst_n_sync(cpu_fsm_rst_n),
      .emif_rst_n_sync(emif_fsm_rst_n),
      .cal_success,
      .cal_fail,
      .cal_ready_cpu,
      .cal_failed_cpu,
      .cal_abort_cpu
  );

  // AUD-04 / EXT-03-001 / T-20260902-024 / T-20260902-027: per-domain
  // reset release bridges with local asynchronous assertion.
  //
  // Two reset classes are kept separate:
  //   - FSM reset (cpu_fsm_rst_n / emif_fsm_rst_n) follows only the real
  //     CPU/EMIF reset request. It deliberately does NOT reset on cal_fail,
  //     so the CPU-side local-DECERR path remains usable after a latched
  //     calibration failure.
  //   - FIFO epoch reset (cpu_fifo_rst_n / emif_fifo_rst_n) additionally
  //     includes the calibrated failure indication, giving cal_fail its own
  //     transaction epoch and preventing stale FIFO data from surviving.
  // The CPU FIFO request uses the synchronized cal_failed_cpu latch; the EMIF
  // FIFO request may use raw source-domain cal_fail because it is consumed
  // only by the EMIF-domain reset synchronizer. No raw cal_fail is used in
  // CPU-domain sequential or combinational control logic.
  //
  // Reset recovery hardening: each domain's synchronizer first stage uses only
  // its own raw reset on the asynchronous reset pin. The other domain's reset
  // is sampled as ordinary data through the same two-flop chain, so a raw
  // sys-domain logic_rst_n_q can never become an EMIF-domain async reset and
  // cannot create a cross-domain recovery/removal path. The common-reset
  // semantics are preserved: after one side releases, the other domain sees
  // that release within two of its own clocks and only then re-enables.
  assign cpu_fsm_reset_req_n  = cpu_rst_n;
  assign emif_fsm_reset_req_n = emif_rst_n;
  assign cpu_fifo_reset_req_n  = cpu_rst_n & !cal_failed_cpu;
  assign emif_fifo_reset_req_n = emif_rst_n & !cal_fail;

  // Per-domain FSM reset release chain (local async-assert; both-domain
  // sync-deassert through the sampled remote reset).
  always_ff @(posedge cpu_clk or negedge cpu_fsm_reset_req_n) begin
    if (!cpu_fsm_reset_req_n) begin
      cpu_rst_sync0_n <= 1'b0;
      cpu_rst_sync1_n <= 1'b0;
    end else begin
      // The CPU FSM must not be reset by an EMIF-only reset.  An
      // outstanding CPU transaction is converted to DECERR by the explicit
      // emif_reset_cpu_* detector below, allowing the AXI response to be
      // observed exactly once.  Keep this chain local to cpu_rst_n so the
      // remote reset cannot silently erase the response context.
      cpu_rst_sync0_n <= 1'b1;
      cpu_rst_sync1_n <= cpu_rst_sync0_n;
    end
  end

  always_ff @(posedge emif_clk or negedge emif_fsm_reset_req_n) begin
    if (!emif_fsm_reset_req_n) begin
      emif_rst_sync0_n <= 1'b0;
      emif_rst_sync1_n <= 1'b0;
    end else begin
      emif_rst_sync0_n <= cpu_rst_n;
      emif_rst_sync1_n <= emif_rst_sync0_n;
    end
  end

  // Synchronize the remote CPU reset as data.  No EMIF reset is present in
  // this sensitivity list, so an EMIF-only reset cannot clear the chain and
  // accidentally re-arm the retained read/poison epoch.
  always_ff @(posedge emif_clk) begin
    cpu_rst_emif_meta_q <= cpu_rst_n;
    cpu_rst_emif_sync_q <= cpu_rst_emif_meta_q;
  end
  /* verilator lint_on PROCASSINIT */

  // Per-domain FIFO epoch reset release chain (same local-async / remote-sync
  // bridge pattern).
  always_ff @(posedge cpu_clk or negedge cpu_fifo_reset_req_n) begin
    if (!cpu_fifo_reset_req_n) begin
      cpu_rst_sync0_n_fifo <= 1'b0;
      cpu_rst_sync1_n_fifo <= 1'b0;
    end else begin
      cpu_rst_sync0_n_fifo <= emif_rst_n;
      cpu_rst_sync1_n_fifo <= cpu_rst_sync0_n_fifo;
    end
  end

  always_ff @(posedge emif_clk or negedge emif_fifo_reset_req_n) begin
    if (!emif_fifo_reset_req_n) begin
      emif_rst_sync0_n_fifo <= 1'b0;
      emif_rst_sync1_n_fifo <= 1'b0;
    end else begin
      emif_rst_sync0_n_fifo <= cpu_rst_n;
      emif_rst_sync1_n_fifo <= emif_rst_sync0_n_fifo;
    end
  end

  assign cpu_fsm_rst_n  = cpu_rst_sync1_n;
  assign emif_fsm_rst_n = emif_rst_sync1_n;
  assign cpu_fifo_rst_n  = cpu_rst_sync1_n_fifo;
  assign emif_fifo_rst_n = emif_rst_sync1_n_fifo;
  assign cal_local = cal_failed_cpu;
  assign cal_accept = cal_ready_cpu | cal_local;

  // Observe an EMIF-only reset in the CPU domain without using it as an
  // asynchronous reset.  The CPU FSM retains its transaction context and
  // turns an accepted request into DECERR once this synchronized assertion
  // is visible.  This detector is reset only by cpu_rst_n, hence it also
  // works when emif_rst_n is pulsed independently.
  always_ff @(posedge cpu_clk or negedge cpu_fsm_reset_req_n) begin
    if (!cpu_fsm_reset_req_n) begin
      emif_reset_cpu_meta_q <= 1'b0;
      emif_reset_cpu_sync_q <= 1'b0;
    end else begin
      emif_reset_cpu_meta_q <= emif_rst_n;
      emif_reset_cpu_sync_q <= emif_reset_cpu_meta_q;
    end
  end

  assign emif_reset_abort_cpu = !emif_reset_cpu_sync_q;

  // A timed-out accepted read poisons the Avalon link until its late
  // readdatavalid is drained (or until an explicit CPU reset).  Synchronize
  // that level before gating a new AXI request; otherwise a request accepted
  // during the two-cycle CDC gap could wait forever behind EMIF_DRAIN.
  always_ff @(posedge cpu_clk or negedge cpu_fsm_reset_req_n) begin
    if (!cpu_fsm_reset_req_n) begin
      emif_poisoned_cpu_meta_q <= 1'b0;
      emif_poisoned_cpu_q <= 1'b0;
    end else begin
      emif_poisoned_cpu_meta_q <= emif_poisoned_q;
      emif_poisoned_cpu_q <= emif_poisoned_cpu_meta_q;
    end
  end

  cpu_state_t cpu_state_q;
  emif_state_t emif_state_q;

  logic txn_active_q;
  logic txn_local_q;
  logic txn_write_q;

  logic aw_captured_q;
  logic [ID_WIDTH-1:0] awid_q;
  logic [ADDR_WIDTH-1:0] awaddr_q;
  logic [7:0] awlen_q;
  logic [2:0] awsize_q;
  logic [1:0] awburst_q;
  logic [DATA_WIDTH-1:0] wdata_q [0:3];
  logic [BYTE_LANES-1:0] wstrb_q [0:3];
  logic [7:0] w_count_q;
  logic w_done_q;
  logic write_bad_q;

  logic [ID_WIDTH-1:0] read_id_q;
  logic [ADDR_WIDTH-1:0] read_addr_q;
  logic [7:0] read_len_q;
  logic [2:0] read_size_q;
  logic [1:0] read_burst_q;
  logic [7:0] read_beat_q;

  logic [ID_WIDTH-1:0] response_id_q;
  logic [1:0] response_code_q;
  logic [511:0] read_line_q;

  logic aw_fire;
  logic w_fire;
  logic ar_fire;
  logic b_fire;
  logic r_fire;

  logic [511:0] assembled_wdata;
  logic [63:0] assembled_byteenable;
  logic [63:0] beat_addr_calc;
  logic [63:0] line_offset_calc;
  logic [63:0] bus_offset_calc;
  integer destination_offset_calc;
  logic [15:0] transfer_mask_calc;
  integer transfer_bytes_calc;
  integer lane_calc;
  logic normalized_strobe_calc;

  request_packet_t req_fifo_wr_packet;
  request_packet_t req_fifo_rd_packet;
  response_packet_t resp_fifo_wr_packet;
  response_packet_t resp_fifo_rd_packet;
  logic [REQUEST_WIDTH-1:0] req_fifo_wr_data;
  logic [REQUEST_WIDTH-1:0] req_fifo_rd_data;
  logic [RESPONSE_WIDTH-1:0] resp_fifo_wr_data;
  logic [RESPONSE_WIDTH-1:0] resp_fifo_rd_data;
  logic req_fifo_wr_en;
  logic req_fifo_rd_en;
  logic resp_fifo_wr_en;
  logic resp_fifo_rd_en;
  logic req_fifo_full;
  logic req_fifo_empty;
  logic resp_fifo_full;
  logic resp_fifo_empty;

  lcvex_async_fifo_cdc #(
      .DATA_WIDTH(REQUEST_WIDTH),
      .ADDR_WIDTH(FIFO_ADDR_WIDTH)
  ) request_fifo (
      .wr_clk(cpu_clk),
      .rd_clk(emif_clk),
      .wr_rst_n(cpu_fifo_rst_n),
      .rd_rst_n(emif_fifo_rst_n),
      .wr_en(req_fifo_wr_en),
      .wr_data(req_fifo_wr_data),
      .wr_full(req_fifo_full),
      .rd_en(req_fifo_rd_en),
      .rd_data(req_fifo_rd_data),
      .rd_empty(req_fifo_empty)
  );

  lcvex_async_fifo_cdc #(
      .DATA_WIDTH(RESPONSE_WIDTH),
      .ADDR_WIDTH(FIFO_ADDR_WIDTH)
  ) response_fifo (
      .wr_clk(emif_clk),
      .rd_clk(cpu_clk),
      .wr_rst_n(emif_fifo_rst_n),
      .rd_rst_n(cpu_fifo_rst_n),
      .wr_en(resp_fifo_wr_en),
      .wr_data(resp_fifo_wr_data),
      .wr_full(resp_fifo_full),
      .rd_en(resp_fifo_rd_en),
      .rd_data(resp_fifo_rd_data),
      .rd_empty(resp_fifo_empty)
  );

  function automatic logic request_ok(
      input logic [ADDR_WIDTH-1:0] addr,
      input logic [7:0] len,
      input logic [2:0] size,
      input logic [1:0] burst
  );
    logic [63:0] addr64;
    begin
      addr64 = '0;
      addr64[ADDR_WIDTH-1:0] = addr;
      request_ok = lcvex_axi4_avalon_window_ok(addr64, len, size, burst);
    end
  endfunction

  function automatic logic [DATA_WIDTH-1:0] line_to_axi_beat(
      input logic [511:0] line_data,
      input logic [ADDR_WIDTH-1:0] first_addr,
      input logic [7:0] beat,
      input logic [2:0] size
  );
    logic [63:0] beat_addr;
    logic [63:0] offset;
    integer bus_offset;
    begin
      line_to_axi_beat = '0;
      beat_addr = first_addr + (beat * (64'd1 << size));
      if (beat_addr >= AXI_AVALON_BASE_ADDR &&
          beat_addr < AXI_AVALON_END_ADDR) begin
        offset = beat_addr - AXI_AVALON_BASE_ADDR;
        bus_offset = offset[5:0];
        bus_offset = bus_offset & ~15;
        if (bus_offset <= 48) begin
          for (int n = 0; n < BYTE_LANES; n++) begin
            line_to_axi_beat[n*8 +: 8] = line_data[(bus_offset+n)*8 +: 8];
          end
        end
      end
    end
  endfunction

  initial begin
    if (ADDR_WIDTH < 12 || ADDR_WIDTH > 64 || DATA_WIDTH != 128 ||
        ID_WIDTH < 1 || BYTE_LANES != 16 || AVALON_TIMEOUT_CYCLES < 1) begin
      $fatal(1, "lcvex_axi4_avalon_adapter: invalid canonical profile/timeout");
    end
  end

  // Assemble WDATA/WSTRB only after AW and all W beats are present. A normal
  // AXI beat uses bus-lane WSTRB (the B1 profile); for a normalized narrow
  // producer with low WSTRB bits, the same bytes are shifted by the AXI line
  // offset. Both forms have identical behavior for aligned/full beats.
  always_comb begin
    assembled_wdata = '0;
    assembled_byteenable = '0;
    beat_addr_calc = '0;
    line_offset_calc = '0;
    bus_offset_calc = '0;
    destination_offset_calc = '0;
    transfer_mask_calc = '0;
    transfer_bytes_calc = 0;
    lane_calc = 0;
    normalized_strobe_calc = 1'b0;

    for (int k = 0; k < 4; k++) begin
      if (k < w_count_q) begin
        beat_addr_calc = awaddr_q + (k * (64'd1 << awsize_q));
        if (awsize_q <= 3'd4) begin
          transfer_bytes_calc = 1 << awsize_q;
        end else begin
          transfer_bytes_calc = 0;
        end
        if (transfer_bytes_calc >= 16) begin
          transfer_mask_calc = 16'hffff;
        end else if (transfer_bytes_calc != 0) begin
          transfer_mask_calc = (16'h1 << transfer_bytes_calc) - 1;
        end else begin
          transfer_mask_calc = '0;
        end
        normalized_strobe_calc =
            ((wstrb_q[k] & ~transfer_mask_calc) == '0);
        lane_calc = beat_addr_calc[3:0];
        if (beat_addr_calc >= AXI_AVALON_BASE_ADDR &&
            beat_addr_calc < AXI_AVALON_END_ADDR) begin
          line_offset_calc = beat_addr_calc - AXI_AVALON_BASE_ADDR;
          bus_offset_calc = line_offset_calc & 64'h3f;
          bus_offset_calc = bus_offset_calc & ~15;
          for (int j = 0; j < BYTE_LANES; j++) begin
            if (wstrb_q[k][j] && transfer_bytes_calc != 0 &&
                ((normalized_strobe_calc && j < transfer_bytes_calc) ||
                 (!normalized_strobe_calc &&
                  j >= lane_calc && j < lane_calc + transfer_bytes_calc))) begin
              if (normalized_strobe_calc) begin
                destination_offset_calc = line_offset_calc[5:0] + j;
              end else begin
                destination_offset_calc = bus_offset_calc + j;
              end
              if (destination_offset_calc < 64) begin
                assembled_byteenable[destination_offset_calc] = 1'b1;
                assembled_wdata[destination_offset_calc*8 +: 8] =
                    wdata_q[k][j*8 +: 8];
              end
            end
          end
        end
      end
    end
  end

  always_comb begin
    req_fifo_wr_packet = '0;
    req_fifo_wr_packet.is_write = txn_write_q;
    req_fifo_wr_packet.id = txn_write_q ? awid_q : read_id_q;
    req_fifo_wr_packet.addr = txn_write_q ? awaddr_q : read_addr_q;
    req_fifo_wr_packet.len = txn_write_q ? awlen_q : read_len_q;
    req_fifo_wr_packet.size = txn_write_q ? awsize_q : read_size_q;
    req_fifo_wr_packet.burst = txn_write_q ? awburst_q : read_burst_q;
    req_fifo_wr_packet.avalon_address = lcvex_axi4_to_avalon_address(
        txn_write_q ? awaddr_q : read_addr_q);
    req_fifo_wr_packet.writedata = txn_write_q ? assembled_wdata : '0;
    req_fifo_wr_packet.byteenable = txn_write_q ? assembled_byteenable :
        lcvex_axi4_avalon_full_byteenable();
    req_fifo_wr_data = req_fifo_wr_packet;
  end

  always_comb begin
    req_fifo_rd_packet = req_fifo_rd_data;
    resp_fifo_rd_packet = resp_fifo_rd_data;
  end

  // AXI side ready/response signals. The first valid write channel wins over
  // AR when the bridge is idle; once W arrives before AW, AR is no longer
  // eligible and the write remains independently collectable.
  always_comb begin
    awready = 1'b0;
    wready = 1'b0;
    arready = 1'b0;
    bvalid = 1'b0;
    bid = response_id_q;
    bresp = response_code_q;
    rvalid = 1'b0;
    rid = response_id_q;
    rdata = '0;
    rresp = response_code_q;
    rlast = 1'b0;

    if (cpu_fsm_rst_n) begin
      if (cal_accept) begin
        if (cpu_state_q == CPU_IDLE && emif_reset_cpu_sync_q &&
            !emif_poisoned_cpu_q) begin
          awready = 1'b1;
          wready = 1'b1;
          arready = !(awvalid || wvalid);
        end else if (cpu_state_q == CPU_WRITE_COLLECT &&
                     emif_reset_cpu_sync_q && !emif_poisoned_cpu_q) begin
          if (!aw_captured_q) begin
            awready = 1'b1;
          end
          if (!w_done_q && (w_count_q < 8'd4 || write_bad_q)) begin
            wready = 1'b1;
          end
        end
      end

      // Once a response is exposed, AXI requires it to remain asserted with
      // stable ID/payload until the master accepts it.  In particular, a
      // later calibration abort must not retract BVALID/RVALID.  Abort is
      // handled in the sequential FSM before response state is entered.
      if (cpu_state_q == CPU_B_RESPONSE) begin
        bvalid = 1'b1;
      end
      if (cpu_state_q == CPU_R_RESPONSE) begin
        rvalid = 1'b1;
        if (!txn_local_q) begin
          rdata = line_to_axi_beat(read_line_q, read_addr_q,
                                   read_beat_q, read_size_q);
        end
        rlast = (read_beat_q == read_len_q);
      end
    end
  end

  assign aw_fire = awvalid && awready;
  assign w_fire = wvalid && wready;
  assign ar_fire = arvalid && arready;
  assign b_fire = bvalid && bready;
  assign r_fire = rvalid && rready;

  // A request is written only after a complete legal AXI transaction has
  // been assembled. The FIFO has spare capacity, but still gates acceptance
  // so an explicit reset/reuse cannot turn a full queue into a duplicate.
  always_comb begin
    req_fifo_wr_en = 1'b0;
    if (cpu_fifo_rst_n && cpu_state_q == CPU_SEND && !txn_local_q &&
        cal_ready_cpu) begin
      if (txn_write_q) begin
        req_fifo_wr_en = !write_bad_q &&
            (w_count_q == (awlen_q + 8'd1));
      end else begin
        req_fifo_wr_en = 1'b1;
      end
    end
  end

  assign resp_fifo_rd_en =
      cpu_fifo_rst_n && (cpu_state_q == CPU_WAIT_RESPONSE) &&
      !resp_fifo_empty && !cal_failed_cpu;

  // EMIF Avalon request generation. Once ISSUE is entered all fields come
  // from emif_req_q and therefore remain stable while waitrequest_n is low.
  request_packet_t emif_req_q;
  logic avalon_read_fire;
  logic avalon_write_fire;
  // These two flags deliberately survive an EMIF-only reset.  They are the
  // epoch guard for an accepted read whose response may arrive late after
  // the EMIF FSM/FIFO reset.  A CPU reset is the explicit re-arm boundary.
  logic read_issued_q;
  logic emif_poisoned_q;
  logic [TIMEOUT_WIDTH-1:0] timeout_count_q;
  logic timeout_expire;

  always_comb begin
    avalon_read = 1'b0;
    avalon_write = 1'b0;
    avalon_address = emif_req_q.avalon_address;
    avalon_writedata = emif_req_q.writedata;
    avalon_burstcount = 7'd1;
    avalon_byteenable = emif_req_q.byteenable;
    if (emif_fsm_rst_n && !cal_fail && cal_success &&
        emif_state_q == EMIF_ISSUE) begin
      if (emif_req_q.is_write) begin
        avalon_write = 1'b1;
      end else begin
        avalon_read = 1'b1;
      end
    end
  end

  assign avalon_read_fire = avalon_read && avalon_waitrequest_n;
  assign avalon_write_fire = avalon_write && avalon_waitrequest_n;

  // The counter is advanced once per EMIF clock while the backend is
  // waiting.  Reaching the terminal value on the current edge is the single
  // timeout event; an acceptance/readdatavalid on that edge wins over the
  // timeout and is a valid completion.
  generate
    if (AVALON_TIMEOUT_CYCLES <= 1) begin : gen_timeout_one
      assign timeout_expire = 1'b1;
    end else begin : gen_timeout_counter
      assign timeout_expire = (timeout_count_q >= TIMEOUT_TERMINAL);
    end
  endgenerate

  always_comb begin
    avalon_timeout_abort = 1'b0;
    if (emif_fsm_rst_n && timeout_expire) begin
      if (emif_state_q == EMIF_ISSUE &&
          !avalon_read_fire && !avalon_write_fire) begin
        avalon_timeout_abort = 1'b1;
      end else if (emif_state_q == EMIF_WAIT_READ &&
                   !avalon_readdatavalid) begin
        avalon_timeout_abort = 1'b1;
      end
    end
  end

  always_comb begin
    req_fifo_rd_en = 1'b0;
    if (emif_fifo_rst_n && emif_state_q == EMIF_IDLE && !req_fifo_empty &&
        cal_success && !cal_fail) begin
      req_fifo_rd_en = 1'b1;
    end
  end

  // Response FIFO is written on a completed Avalon operation, or on the
  // bounded timeout error path.  A read timeout after acceptance is also
  // moved to EMIF_DRAIN; its eventual readdatavalid is intentionally not a
  // second response.
  always_comb begin
    resp_fifo_wr_en = 1'b0;
    resp_fifo_wr_packet = '0;
    if (emif_fifo_rst_n) begin
      if (emif_state_q == EMIF_ISSUE && emif_req_q.is_write &&
          avalon_write_fire) begin
        resp_fifo_wr_en = 1'b1;
        resp_fifo_wr_packet.is_write = 1'b1;
        resp_fifo_wr_packet.id = emif_req_q.id;
        resp_fifo_wr_packet.resp = AXI4_RESP_OKAY;
      end else if (emif_state_q == EMIF_ISSUE && !emif_req_q.is_write &&
                   avalon_read_fire && avalon_readdatavalid) begin
        resp_fifo_wr_en = 1'b1;
        resp_fifo_wr_packet.is_write = 1'b0;
        resp_fifo_wr_packet.id = emif_req_q.id;
        resp_fifo_wr_packet.resp = AXI4_RESP_OKAY;
        resp_fifo_wr_packet.readdata = avalon_readdata;
      end else if (emif_state_q == EMIF_WAIT_READ &&
                   avalon_readdatavalid) begin
        resp_fifo_wr_en = 1'b1;
        resp_fifo_wr_packet.is_write = 1'b0;
        resp_fifo_wr_packet.id = emif_req_q.id;
        resp_fifo_wr_packet.resp = AXI4_RESP_OKAY;
        resp_fifo_wr_packet.readdata = avalon_readdata;
      end else if (emif_state_q == EMIF_ISSUE && timeout_expire &&
                   !avalon_read_fire && !avalon_write_fire) begin
        // No Avalon acceptance occurred, so there is no backend side effect
        // to drain.  Complete the accepted AXI transaction locally with a
        // single DECERR packet.
        resp_fifo_wr_en = 1'b1;
        resp_fifo_wr_packet.is_write = emif_req_q.is_write;
        resp_fifo_wr_packet.id = emif_req_q.id;
        resp_fifo_wr_packet.resp = AXI4_RESP_DECERR;
      end else if (emif_state_q == EMIF_WAIT_READ && timeout_expire &&
                   !avalon_readdatavalid) begin
        // The Avalon read was accepted earlier, but no response arrived
        // within the bound.  The EMIF FSM enters DRAIN on this edge and
        // consumes any late response without generating another packet.
        resp_fifo_wr_en = 1'b1;
        resp_fifo_wr_packet.is_write = 1'b0;
        resp_fifo_wr_packet.id = emif_req_q.id;
        resp_fifo_wr_packet.resp = AXI4_RESP_DECERR;
      end
    end
    resp_fifo_wr_data = resp_fifo_wr_packet;
  end

  // CPU-domain transaction collector and response splitter. CPU reset
  // asserts this state machine asynchronously; an EMIF-only reset is an
  // in-band abort event so the accepted AXI transaction can still receive
  // its DECERR response.
  always_ff @(posedge cpu_clk or negedge cpu_fsm_rst_n) begin
    if (!cpu_fsm_rst_n) begin
      cpu_state_q <= CPU_IDLE;
      txn_active_q <= 1'b0;
      txn_local_q <= 1'b0;
      txn_write_q <= 1'b0;
      aw_captured_q <= 1'b0;
      awid_q <= '0;
      awaddr_q <= '0;
      awlen_q <= '0;
      awsize_q <= '0;
      awburst_q <= AXI4_BURST_INCR;
      w_count_q <= '0;
      w_done_q <= 1'b0;
      write_bad_q <= 1'b0;
      read_id_q <= '0;
      read_addr_q <= '0;
      read_len_q <= '0;
      read_size_q <= '0;
      read_burst_q <= AXI4_BURST_INCR;
      read_beat_q <= '0;
      response_id_q <= '0;
      response_code_q <= AXI4_RESP_DECERR;
      read_line_q <= '0;
      for (int i = 0; i < 4; i++) begin
        wdata_q[i] <= '0;
        wstrb_q[i] <= '0;
      end
    end else begin
      // Calibration failure or an EMIF-only reset aborts a normal request at
      // the CPU boundary.  Keep the transaction alive long enough to emit
      // exactly one DECERR; silently returning to IDLE would leave the AXI
      // master waiting forever.  A response already exposed is deliberately
      // excluded so its VALID/payload stability is preserved.
      if ((cal_abort_cpu || emif_reset_abort_cpu) && txn_active_q &&
          !txn_local_q && cpu_state_q != CPU_B_RESPONSE &&
          cpu_state_q != CPU_R_RESPONSE &&
          (cpu_state_q == CPU_SEND || cpu_state_q == CPU_WAIT_RESPONSE)) begin
        txn_local_q <= 1'b1;
        response_code_q <= AXI4_RESP_DECERR;
        if (txn_write_q) begin
          response_id_q <= awid_q;
          cpu_state_q <= CPU_B_RESPONSE;
        end else begin
          response_id_q <= read_id_q;
          read_len_q <= '0;
          read_beat_q <= '0;
          read_line_q <= '0;
          cpu_state_q <= CPU_R_RESPONSE;
        end
      end else begin
        case (cpu_state_q)
          CPU_IDLE: begin
            if (ar_fire) begin
              txn_active_q <= 1'b1;
              txn_local_q <= cal_local;
              txn_write_q <= 1'b0;
              read_id_q <= arid;
              read_addr_q <= araddr;
              read_len_q <= arlen;
              read_size_q <= arsize;
              read_burst_q <= arburst;
              read_beat_q <= '0;
              response_id_q <= arid;
              if (!request_ok(araddr, arlen, arsize, arburst) || cal_local) begin
                response_code_q <= AXI4_RESP_DECERR;
                read_len_q <= '0;
                read_line_q <= '0;
                cpu_state_q <= CPU_R_RESPONSE;
              end else begin
                cpu_state_q <= CPU_SEND;
              end
            end else if (aw_fire || w_fire) begin
              txn_active_q <= 1'b1;
              txn_local_q <= cal_local;
              txn_write_q <= 1'b1;
              aw_captured_q <= aw_fire;
              w_count_q <= w_fire ? 8'd1 : 8'd0;
              w_done_q <= w_fire && wlast;
              write_bad_q <= aw_fire &&
                  !request_ok(awaddr, awlen, awsize, awburst);
              if (aw_fire) begin
                awid_q <= awid;
                awaddr_q <= awaddr;
                awlen_q <= awlen;
                awsize_q <= awsize;
                awburst_q <= awburst;
                response_id_q <= awid;
              end
              if (w_fire) begin
                wdata_q[0] <= wdata;
                wstrb_q[0] <= wstrb;
              end
              cpu_state_q <= CPU_WRITE_COLLECT;
            end
          end

          CPU_WRITE_COLLECT: begin
            if (aw_fire) begin
              aw_captured_q <= 1'b1;
              awid_q <= awid;
              awaddr_q <= awaddr;
              awlen_q <= awlen;
              awsize_q <= awsize;
              awburst_q <= awburst;
              response_id_q <= awid;
              write_bad_q <= !request_ok(awaddr, awlen, awsize, awburst);
            end
            if (w_fire) begin
              if (w_count_q < 8'd4) begin
                wdata_q[w_count_q[1:0]] <= wdata;
                wstrb_q[w_count_q[1:0]] <= wstrb;
              end
              if (w_count_q != 8'hff) begin
                w_count_q <= w_count_q + 8'd1;
              end
              if (wlast) begin
                w_done_q <= 1'b1;
              end
            end
            if ((aw_captured_q || aw_fire) &&
                (w_done_q || (w_fire && wlast))) begin
              cpu_state_q <= CPU_SEND;
            end
          end

          CPU_SEND: begin
            if (txn_write_q) begin
              if (txn_local_q || write_bad_q ||
                  (w_count_q != (awlen_q + 8'd1))) begin
                response_id_q <= awid_q;
                response_code_q <= AXI4_RESP_DECERR;
                cpu_state_q <= CPU_B_RESPONSE;
              end else if (req_fifo_wr_en && !req_fifo_full) begin
                cpu_state_q <= CPU_WAIT_RESPONSE;
              end else if (!cal_ready_cpu) begin
                // Calibration went away before the backend was accepted.
                // The AXI channels were already accepted, so complete them
                // with an error instead of dropping the transaction.
                txn_local_q <= 1'b1;
                response_id_q <= awid_q;
                response_code_q <= AXI4_RESP_DECERR;
                cpu_state_q <= CPU_B_RESPONSE;
              end
            end else begin
              if (txn_local_q) begin
                response_id_q <= read_id_q;
                response_code_q <= AXI4_RESP_DECERR;
                read_len_q <= '0;
                read_line_q <= '0;
                cpu_state_q <= CPU_R_RESPONSE;
              end else if (req_fifo_wr_en && !req_fifo_full) begin
                cpu_state_q <= CPU_WAIT_RESPONSE;
              end else if (!cal_ready_cpu) begin
                txn_local_q <= 1'b1;
                response_id_q <= read_id_q;
                response_code_q <= AXI4_RESP_DECERR;
                read_len_q <= '0;
                read_beat_q <= '0;
                read_line_q <= '0;
                cpu_state_q <= CPU_R_RESPONSE;
              end
            end
          end

          CPU_WAIT_RESPONSE: begin
            if (resp_fifo_rd_en) begin
              // Keep the CPU response FSM off the asynchronous FIFO memory
              // control/ID fields. The request-side ID is already captured;
              // the response code is nevertheless taken from the packet so
              // EMIF timeout DECERR is not turned into a false OKAY. Only a
              // successful packet contributes a read line payload.
              if (resp_fifo_rd_packet.id != response_id_q ||
                  resp_fifo_rd_packet.is_write != txn_write_q) begin
                // A response from an old/reset epoch must never be handed to
                // the current AXI request.  Consume the malformed packet,
                // but complete the current transaction with one DECERR and
                // no stale read payload.
                response_code_q <= AXI4_RESP_DECERR;
                txn_local_q <= 1'b1;
                read_line_q <= '0;
                read_beat_q <= '0;
                read_len_q <= '0;
              end else begin
                response_code_q <= resp_fifo_rd_packet.resp;
              end
              if (resp_fifo_rd_packet.resp != AXI4_RESP_OKAY ||
                  resp_fifo_rd_packet.id != response_id_q ||
                  resp_fifo_rd_packet.is_write != txn_write_q) begin
                // Timeout packets carry no valid line data and terminate a
                // read as a one-beat AXI error response.  The same applies
                // to any packet identity mismatch above.
                txn_local_q <= 1'b1;
                read_line_q <= '0;
                read_beat_q <= '0;
                read_len_q <= '0;
              end
              if (txn_write_q) begin
                cpu_state_q <= CPU_B_RESPONSE;
              end else begin
                read_line_q <= resp_fifo_rd_packet.readdata;
                read_beat_q <= '0;
                cpu_state_q <= CPU_R_RESPONSE;
              end
            end
          end

          CPU_B_RESPONSE: begin
            if (b_fire) begin
              cpu_state_q <= CPU_IDLE;
              txn_active_q <= 1'b0;
              txn_local_q <= 1'b0;
              txn_write_q <= 1'b0;
              aw_captured_q <= 1'b0;
              w_count_q <= '0;
              w_done_q <= 1'b0;
              write_bad_q <= 1'b0;
            end
          end

          CPU_R_RESPONSE: begin
            if (r_fire) begin
              if (read_beat_q == read_len_q) begin
                cpu_state_q <= CPU_IDLE;
                txn_active_q <= 1'b0;
                txn_local_q <= 1'b0;
                txn_write_q <= 1'b0;
              end else begin
                read_beat_q <= read_beat_q + 8'd1;
              end
            end
          end

          default: cpu_state_q <= CPU_IDLE;
        endcase
      end
    end
  end

  // EMIF-domain epoch state.  read_issued_q and emif_poisoned_q are reset by
  // the CPU reset, not by emif_rst_n, so an EMIF-only reset cannot erase the
  // fact that a backend read may still return.  The FSM reset branch then
  // re-enters DRAIN when required.  A late readdatavalid clears the poison;
  // if it never arrives, DRAIN remains a deliberate link poison and the CPU
  // side blocks new requests until an explicit reset re-arms the link.
  // This retention block deliberately samples the remote CPU reset
  // synchronously.  Making cpu_rst_n an asynchronous reset here would turn
  // the CPU reset into a recovery/removal path in the EMIF domain and would
  // also erase the very epoch information needed across an EMIF-only reset.
  always_ff @(posedge emif_clk) begin
    if (!cpu_rst_emif_sync_q) begin
      read_issued_q <= 1'b0;
      emif_poisoned_q <= 1'b0;
    end else if (!emif_rst_n) begin
      // An EMIF-only reset invalidates an already accepted read even though
      // the CPU context is retained.  Mark the link poisoned before the FSM
      // reset/release completes; this closes the CDC gap in which a new CPU
      // request could otherwise enter a permanent DRAIN state.
      if (read_issued_q) begin
        emif_poisoned_q <= 1'b1;
      end
    end else begin
      if (avalon_readdatavalid) begin
        read_issued_q <= 1'b0;
        if (emif_state_q == EMIF_DRAIN) begin
          emif_poisoned_q <= 1'b0;
        end
      end else if (avalon_read_fire) begin
        read_issued_q <= 1'b1;
      end

      if (emif_state_q == EMIF_WAIT_READ && timeout_expire &&
          !avalon_readdatavalid) begin
        emif_poisoned_q <= 1'b1;
      end
    end
  end

  always_ff @(posedge emif_clk or negedge emif_fsm_rst_n) begin
    if (!emif_fsm_rst_n) begin
      if (read_issued_q || emif_poisoned_q) begin
        emif_state_q <= EMIF_DRAIN;
      end else begin
        emif_state_q <= EMIF_IDLE;
      end
      emif_req_q <= '0;
      timeout_count_q <= '0;
    end else if (cal_fail) begin
      emif_req_q <= '0;
      if (read_issued_q || emif_poisoned_q) begin
        emif_state_q <= EMIF_DRAIN;
      end else begin
        emif_state_q <= EMIF_IDLE;
      end
      timeout_count_q <= '0;
    end else begin
      case (emif_state_q)
        EMIF_IDLE: begin
          timeout_count_q <= '0;
          if (req_fifo_rd_en && !emif_poisoned_q) begin
            emif_req_q <= req_fifo_rd_packet;
            emif_state_q <= EMIF_ISSUE;
            timeout_count_q <= '0;
          end
        end

        EMIF_ISSUE: begin
          if (emif_req_q.is_write) begin
            if (avalon_write_fire) begin
              emif_state_q <= EMIF_IDLE;
              timeout_count_q <= '0;
            end else if (timeout_expire) begin
              // No write acceptance means no side effect and no drain
              // obligation.  The response FIFO emits one DECERR packet.
              emif_state_q <= EMIF_IDLE;
              timeout_count_q <= '0;
            end else begin
              timeout_count_q <= timeout_count_q + 1'b1;
            end
          end else if (avalon_read_fire) begin
            timeout_count_q <= '0;
            if (avalon_readdatavalid) begin
              emif_state_q <= EMIF_IDLE;
            end else begin
              emif_state_q <= EMIF_WAIT_READ;
            end
          end else if (timeout_expire) begin
            // The command was never accepted, so this read has no late
            // response to drain.
            emif_state_q <= EMIF_IDLE;
            timeout_count_q <= '0;
          end else begin
            timeout_count_q <= timeout_count_q + 1'b1;
          end
        end

        EMIF_WAIT_READ: begin
          if (avalon_readdatavalid) begin
            emif_state_q <= EMIF_IDLE;
            timeout_count_q <= '0;
          end else if (timeout_expire) begin
            // A read was accepted before the timeout.  Keep the link in
            // DRAIN and poison it until the late response is consumed.
            emif_state_q <= EMIF_DRAIN;
            timeout_count_q <= '0;
          end else begin
            timeout_count_q <= timeout_count_q + 1'b1;
          end
        end

        EMIF_DRAIN: begin
          timeout_count_q <= '0;
          if (avalon_readdatavalid) begin
            emif_state_q <= EMIF_IDLE;
          end
        end

        default: begin
          emif_state_q <= EMIF_IDLE;
          timeout_count_q <= '0;
        end
      endcase
    end
  end

endmodule


// T-20260902-027: hardened gray-pointer asynchronous FIFO used by the EMIF
// adapter. It is intentionally kept in this writable adapter source so the
// read-only outer lcvex_async_fifo.sv can remain untouched while the adapter
// gets a CDC-hardened pointer path.
//
// Differences from lcvex_async_fifo.sv:
//   - Every pointer/synchronizer flop carries multiple synthesis keep/preserve
//     attributes (keep, preserve, dont_retime, dont_merge, noprune) so the
//     source-domain gray register is not retimed/merged into the first
//     destination synchronizer stage and the first-stage synchronizer itself
//     is not retimed/merged with the source gray register.
//   - The registered gray pointer (wr_ptr_gray_q / rd_ptr_gray_q) is the only
//     signal sampled by the destination synchronizers. The gray pointers are
//     maintained as independent gray counters inside their source domains:
//     there is no combinational binary->gray alias from wr_ptr_bin_q /
//     rd_ptr_bin_q to the CDC launch registers. Therefore the
//     source->first-sync path cannot start at a binary pointer register.
//   - The synchronous read-data output and reset/pointer protocol are
//     unchanged from the existing FIFO contract.

module lcvex_async_fifo_cdc #(
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

  (* keep = "true", preserve = "true", dont_retime = "true",
     dont_merge = "true", noprune = "true" *) logic [PTR_WIDTH-1:0] wr_ptr_bin_q;
  (* keep = "true", preserve = "true", dont_retime = "true",
     dont_merge = "true", noprune = "true" *) logic [PTR_WIDTH-1:0] wr_ptr_gray_q;
  (* keep = "true", preserve = "true", dont_retime = "true",
     dont_merge = "true", noprune = "true" *) logic [PTR_WIDTH-1:0] rd_ptr_bin_q;
  (* keep = "true", preserve = "true", dont_retime = "true",
     dont_merge = "true", noprune = "true" *) logic [PTR_WIDTH-1:0] rd_ptr_gray_q;
  (* keep = "true", preserve = "true", dont_retime = "true",
     dont_merge = "true", noprune = "true" *) logic [PTR_WIDTH-1:0] rd_ptr_gray_wr1_q;
  (* keep = "true", preserve = "true", dont_retime = "true",
     dont_merge = "true", noprune = "true" *) logic [PTR_WIDTH-1:0] rd_ptr_gray_wr2_q;
  (* keep = "true", preserve = "true", dont_retime = "true",
     dont_merge = "true", noprune = "true" *) logic [PTR_WIDTH-1:0] wr_ptr_gray_rd1_q;
  (* keep = "true", preserve = "true", dont_retime = "true",
     dont_merge = "true", noprune = "true" *) logic [PTR_WIDTH-1:0] wr_ptr_gray_rd2_q;

  logic [PTR_WIDTH-1:0] wr_ptr_bin_next;
  logic [PTR_WIDTH-1:0] wr_ptr_gray_next;
  logic [PTR_WIDTH-1:0] rd_ptr_bin_next;
  logic [PTR_WIDTH-1:0] rd_ptr_gray_next;

  initial begin
    if (DATA_WIDTH < 1 || ADDR_WIDTH < 2 || ADDR_WIDTH > 10) begin
      $fatal(1, "lcvex_async_fifo_cdc: invalid DATA_WIDTH/ADDR_WIDTH");
    end
  end

  assign rd_empty = (rd_ptr_gray_q == wr_ptr_gray_rd2_q);
  assign wr_full = (wr_ptr_gray_q ==
                    {~rd_ptr_gray_wr2_q[PTR_WIDTH-1:PTR_WIDTH-2],
                     rd_ptr_gray_wr2_q[PTR_WIDTH-3:0]});
  assign rd_data = mem[rd_ptr_bin_q[ADDR_WIDTH-1:0]];

  // Increment a Gray-coded pointer without routing the binary pointer into
  // the Gray launch register.  The Gray counter is kept in its own source
  // domain, so synthesis cannot replace the registered Gray launch value with
  // a combinational binary->Gray encoder and report a binary-register-to-
  // first-synchronizer CDC path.
  function automatic logic [PTR_WIDTH-1:0] gray_inc(
      input logic [PTR_WIDTH-1:0] gray
  );
    logic [PTR_WIDTH-1:0] bin;
    begin
      // Gray -> binary (MSB owns the top Gray bit; each lower bit is the
      // running prefix XOR from the top).
      bin[PTR_WIDTH-1] = gray[PTR_WIDTH-1];
      for (int i = PTR_WIDTH-2; i >= 0; i--) begin
        bin[i] = bin[i+1] ^ gray[i];
      end
      bin = bin + 1'b1;
      gray_inc = (bin >> 1) ^ bin;
    end
  endfunction

  always_comb begin
    wr_ptr_bin_next = wr_ptr_bin_q;
    if (wr_en && !wr_full) begin
      wr_ptr_bin_next = wr_ptr_bin_q + {{(PTR_WIDTH-1){1'b0}}, 1'b1};
    end
    wr_ptr_gray_next = wr_ptr_gray_q;
    if (wr_en && !wr_full) begin
      wr_ptr_gray_next = gray_inc(wr_ptr_gray_q);
    end
    rd_ptr_bin_next = rd_ptr_bin_q;
    if (rd_en && !rd_empty) begin
      rd_ptr_bin_next = rd_ptr_bin_q + {{(PTR_WIDTH-1){1'b0}}, 1'b1};
    end
    rd_ptr_gray_next = rd_ptr_gray_q;
    if (rd_en && !rd_empty) begin
      rd_ptr_gray_next = gray_inc(rd_ptr_gray_q);
    end
  end

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

  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      rd_ptr_bin_q <= '0;
      rd_ptr_gray_q <= '0;
    end else begin
      rd_ptr_bin_q <= rd_ptr_bin_next;
      rd_ptr_gray_q <= rd_ptr_gray_next;
    end
  end

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


// Independent Avalon-side protocol checker. It is kept in this source file
// so the B2 task has no new top-level/filelist dependency; testbenches
// instantiate it explicitly with --assert.
module lcvex_axi4_avalon_sva (
    input logic         clk,
    // rst_n is the CPU epoch reset and clears every checker register.
    input logic         rst_n,
    // emif_rst_n clears only Avalon command-hold bookkeeping; the accepted
    // read epoch is intentionally retained across an EMIF-only reset.
    input logic         emif_rst_n,
    input logic         cal_fail,
    input logic         avalon_read,
    input logic         avalon_write,
    input logic [24:0]  avalon_address,
    input logic [511:0] avalon_writedata,
    input logic [6:0]   avalon_burstcount,
    input logic [63:0]  avalon_byteenable,
    input logic         waitrequest_n,
    input logic         readdatavalid,
    input logic         timeout_abort
);

  logic stalled_q;
  logic [24:0] hold_address_q;
  logic [511:0] hold_writedata_q;
  logic [6:0] hold_burstcount_q;
  logic [63:0] hold_byteenable_q;
  logic hold_read_q;
  logic hold_write_q;
  logic read_inflight_q;

  // These properties are intentionally simple and Verilator-friendly. The
  // clocked hold register provides the same payload-stability proof on
  // simulators which do not implement $stable over packed tuples reliably.
  assert property (@(posedge clk) disable iff (!rst_n || !emif_rst_n)
      !(avalon_read && avalon_write))
    else $error("Avalon read/write asserted together");
  assert property (@(posedge clk) disable iff (!rst_n || !emif_rst_n)
      (avalon_read || avalon_write) |-> (avalon_burstcount == 7'd1))
    else $error("Avalon burstcount must be one 512-bit word");
  assert property (@(posedge clk) disable iff (!rst_n || !emif_rst_n)
      cal_fail |-> !(avalon_read || avalon_write))
    else $error("Avalon request emitted after calibration failure");

  // EMIF reset invalidates command-hold bookkeeping because Avalon controls
  // may be withdrawn with waitrequest_n low.  It deliberately does not reset
  // read_inflight_q; that epoch must survive long enough to classify a late
  // readdatavalid after EMIF-only reset.
  always_ff @(posedge clk or negedge rst_n or negedge emif_rst_n) begin
    if (!rst_n || !emif_rst_n) begin
      stalled_q <= 1'b0;
      hold_address_q <= '0;
      hold_writedata_q <= '0;
      hold_burstcount_q <= '0;
      hold_byteenable_q <= '0;
      hold_read_q <= 1'b0;
      hold_write_q <= 1'b0;
    end else begin
      if (timeout_abort) begin
        // The adapter has generated its single DECERR timeout packet and is
        // deliberately withdrawing the Avalon command.  No backend
        // acceptance occurred on an ISSUE timeout; a WAIT_READ timeout is
        // followed by DRAIN.  In either case this is the explicit protocol
        // escape hatch, not a weakened payload-stability rule.
        stalled_q <= 1'b0;
      end else if (stalled_q) begin
        assert(avalon_read == hold_read_q && avalon_write == hold_write_q)
          else $error("Avalon command changed while waitrequest_n was low");
        assert(avalon_address == hold_address_q &&
               avalon_writedata == hold_writedata_q &&
               avalon_burstcount == hold_burstcount_q &&
               avalon_byteenable == hold_byteenable_q)
          else $error("Avalon payload changed while waitrequest_n was low");
        if ((avalon_read || avalon_write) && waitrequest_n) begin
          stalled_q <= 1'b0;
        end
      end else if ((avalon_read || avalon_write) && !waitrequest_n) begin
        stalled_q <= 1'b1;
        hold_read_q <= avalon_read;
        hold_write_q <= avalon_write;
        hold_address_q <= avalon_address;
        hold_writedata_q <= avalon_writedata;
        hold_burstcount_q <= avalon_burstcount;
        hold_byteenable_q <= avalon_byteenable;
      end

    end
  end

  // CPU reset is the only reset that clears the read epoch.  During an EMIF
  // reset the backend interface is quiesced, so the retained flag is held;
  // after release, a late response is accepted as the old read's drain.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      read_inflight_q <= 1'b0;
    end else if (emif_rst_n) begin
      if (readdatavalid) begin
        assert(read_inflight_q || (avalon_read && waitrequest_n))
          else $error("Avalon readdatavalid without an accepted read");
        read_inflight_q <= 1'b0;
      end else if (avalon_read && waitrequest_n) begin
        read_inflight_q <= 1'b1;
      end
    end
  end

endmodule

/* verilator lint_on DECLFILENAME */
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on WIDTHEXPAND */
/* verilator lint_on WIDTHTRUNC */
/* verilator lint_on SYNCASYNCNET */
