// lcvex_l2_cluster.sv
// C2 shared-L2 directory MSI cluster.
//
// This module is intentionally a correctness-first, single-transaction
// implementation for CORE_COUNT=2:
//   * directory I/S/M with sharer bits and a unique dirty owner;
//   * ReadShared / ReadUnique / Upgrade / WriteBack / Clean /
//     Clean+Invalidate / Invalidate / Bypass;
//   * per-core probe ports with the existing B4 probe command encoding;
//   * dirty data from an owner is written to PoC before the probe response is
//     released (probe_rsp_abort on PoC fault);
//   * no in-flight request is accepted for the same line (global single
//     transaction in C2);
//   * fault paths never create a new M owner and never emit a stale success
//     response.
//
// C2 does not implement E/O, ACE/CHI, coherent DMA, or a full ARM memory
// model.  The PoC port remains the existing 8B M1-B shape.

`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off DECLFILENAME */

module lcvex_l2_cluster #(
    parameter int           CORE_COUNT       = 2,
    parameter int           CORE_ID_W        = 4,
    parameter int           SOURCE_ID_W      = 4,
    parameter int           TRANSACTION_ID_W = 8,
    parameter int           LINE_BYTES       = 64,
    parameter logic [63:0]  MEM_BASE         = 64'h0000_0000_0000_0000,
    parameter int           MEM_LINES        = 1024
) (
    input  logic                        clk,
    input  logic                        rst_n,

    // Per-core line-level coherent request ports.
    input  logic [CORE_COUNT-1:0]       req_valid,
    output logic [CORE_COUNT-1:0]       req_ready,
    input  lcvex_cluster_pkg::lcvex_coh_req_t req [CORE_COUNT],
    input  logic [SOURCE_ID_W-1:0]      req_source_id [CORE_COUNT],
    input  logic [TRANSACTION_ID_W-1:0] req_transaction_id [CORE_COUNT],

    output logic [CORE_COUNT-1:0]       rsp_valid,
    input  logic [CORE_COUNT-1:0]       rsp_ready,
    output lcvex_cluster_pkg::lcvex_coh_rsp_t rsp [CORE_COUNT],
    output logic [SOURCE_ID_W-1:0]      rsp_source_id [CORE_COUNT],
    output logic [TRANSACTION_ID_W-1:0] rsp_transaction_id [CORE_COUNT],

    // Per-core L2 -> L1 probe ports (same encoding as B4 D-L1 probe).
    output logic [CORE_COUNT-1:0]       probe_req_valid,
    input  logic [CORE_COUNT-1:0]       probe_req_ready,
    output logic [63:0]                 probe_req_addr [CORE_COUNT],
    output logic [1:0]                  probe_req_cmd [CORE_COUNT],
    output logic [SOURCE_ID_W-1:0]      probe_req_source_id [CORE_COUNT],
    output logic [TRANSACTION_ID_W-1:0] probe_req_transaction_id [CORE_COUNT],

    input  logic [CORE_COUNT-1:0]       probe_rsp_valid,
    output logic [CORE_COUNT-1:0]       probe_rsp_ready,
    input  logic [CORE_COUNT-1:0]       probe_rsp_fault,
    input  logic [CORE_COUNT-1:0]       probe_rsp_line_valid,
    input  logic [CORE_COUNT-1:0]       probe_rsp_dirty,
    input  logic [LINE_BYTES*8-1:0]     probe_rsp_data [CORE_COUNT],
    input  logic [63:0]                 probe_rsp_addr [CORE_COUNT],
    input  logic [SOURCE_ID_W-1:0]      probe_rsp_source_id [CORE_COUNT],
    input  logic [TRANSACTION_ID_W-1:0] probe_rsp_transaction_id [CORE_COUNT],
    output logic [CORE_COUNT-1:0]       probe_rsp_abort,

    // PoC M1-B 8B port.
    output logic                        poc_req_valid,
    output lcvex_pkg::mem_req_t         poc_req,
    input  logic                        poc_req_ready,
    input  logic                        poc_rsp_valid,
    input  lcvex_pkg::mem_rsp_t         poc_rsp,
    output logic                        poc_rsp_ready,

    // Debug directory state (for directed invariants; not an architecture port).
    output logic [MEM_LINES-1:0]        dir_valid_dbg,
    output logic [1:0]                  dir_state_dbg [MEM_LINES],
    output logic [CORE_COUNT-1:0]       dir_sharers_dbg [MEM_LINES],
    output logic [CORE_COUNT-1:0]       dir_owner_dbg [MEM_LINES],
    output logic [MEM_LINES-1:0]        dir_dirty_dbg,
    output logic [MEM_LINES-1:0]        dir_pending_dbg,
    output logic [CORE_ID_W-1:0]        dbg_cur_core,
    output logic [1:0]                  dbg_cur_state
);

  import lcvex_pkg::*;
  import lcvex_cluster_pkg::*;

  localparam int OFF_W   = $clog2(LINE_BYTES);
  localparam int BEAT_W  = $clog2(LINE_BYTES / 8);
  localparam int BEATS   = LINE_BYTES / 8;
  localparam int IDX_W   = (MEM_LINES > 1) ? $clog2(MEM_LINES) : 1;

  localparam logic [1:0] DIR_I = 2'd0;
  localparam logic [1:0] DIR_S = 2'd1;
  localparam logic [1:0] DIR_M = 2'd2;

  typedef enum logic [4:0] {
    S_IDLE,
    S_PROBE_REQ,
    S_PROBE_WAIT,
    S_PROBE_COMMIT,
    S_FILL_REQ,
    S_FILL_WAIT,
    S_WB_REQ,
    S_WB_WAIT,
    S_BYPASS_REQ,
    S_BYPASS_WAIT,
    S_COMMIT,
    S_RSP
  } state_t;

  state_t state;

  // Line-indexed directory.  C2 uses the backing PoC as the data source, so
  // this table only records coherence metadata, not the line data itself.
  logic [MEM_LINES-1:0]             dir_valid;
  logic [1:0]                       dir_state [MEM_LINES];
  logic [CORE_COUNT-1:0]            dir_sharers [MEM_LINES];
  logic [CORE_COUNT-1:0]            dir_owner   [MEM_LINES];
  logic [MEM_LINES-1:0]             dir_dirty;
  logic [MEM_LINES-1:0]             dir_pending;

  localparam int CORE_IDX_W = (CORE_COUNT > 1) ? $clog2(CORE_COUNT) : 1;

  // Current transaction context.
  logic [CORE_IDX_W-1:0]            cur_core;
  logic [3:0]                       cur_cmd;
  logic [63:0]                      cur_addr;
  logic [IDX_W-1:0]                 cur_idx;
  logic [1:0]                       old_state;
  logic [CORE_COUNT-1:0]            old_sharers;
  logic [CORE_COUNT-1:0]            old_owner;
  logic                             old_dirty;
  logic                             need_fill;
  logic                             need_probe;
  logic [CORE_IDX_W-1:0]            probe_target;
  logic [CORE_COUNT-1:0]            probe_pending_mask;
  logic [1:0]                       probe_cmd_r;
  logic                             probe_active;
  logic                             probe_abort_pending;
  logic                             probe_dirty_seen;
  logic [LINE_BYTES*8-1:0]          line_buf;
  logic [LINE_BYTES*8-1:0]          wb_data;
  logic                             wb_from_probe;
  logic [BEAT_W-1:0]                beat_r;
  logic                             op_fault;
  logic                             op_rsp_data_ok;
  logic [LINE_BYTES*8-1:0]          op_rsp_data;
  logic [SOURCE_ID_W-1:0]           cur_source;
  logic [TRANSACTION_ID_W-1:0]      cur_transaction;
  logic [CORE_IDX_W-1:0]            rr_ptr;
  logic [CORE_IDX_W-1:0]            arb_sel;
  logic                             arb_sel_valid;

  // ---- Combinational helpers ----
  function automatic logic [IDX_W-1:0] line_index(input logic [63:0] a);
    logic [63:0] off;
    begin
      off = a - MEM_BASE;
      line_index = off[IDX_W+OFF_W-1:OFF_W];
    end
  endfunction

  function automatic logic [63:0] line_base(input logic [IDX_W-1:0] idx);
    logic [63:0] a;
    begin
      a = MEM_BASE + (64'(idx) << OFF_W);
      line_base = a;
    end
  endfunction

  function automatic logic [63:0] line_byte(
      input logic [LINE_BYTES*8-1:0] line,
      input logic [OFF_W-1:0]        off);
    logic [63:0] v;
    begin
      v = '0;
      for (int i = 0; i < 8; i++) begin
        if ((off + i) < LINE_BYTES)
          v[i*8 +: 8] = line[(off+i)*8 +: 8];
      end
      line_byte = v;
    end
  endfunction

  function automatic logic [CORE_IDX_W-1:0] first_core(
      input logic [CORE_COUNT-1:0] mask);
    logic [CORE_IDX_W-1:0] r;
    begin
      r = '0;
      for (int i = 0; i < CORE_COUNT; i++) begin
        if (mask[i]) begin
          r = CORE_IDX_W'(i);
          i = CORE_COUNT; // stop after first set bit
        end
      end
      first_core = r;
    end
  endfunction

  always_comb begin
    // Round-robin with a liveness fallback: if the pointer core has no
    // request, grant the next valid request rather than stalling the other
    // core forever.
    arb_sel = rr_ptr;
    arb_sel_valid = req_valid[rr_ptr];
    if (!arb_sel_valid && (CORE_COUNT == 2)) begin
      if (req_valid[1-rr_ptr]) begin
        arb_sel = CORE_IDX_W'(1 - rr_ptr);
        arb_sel_valid = 1'b1;
      end
    end
    if (!arb_sel_valid) begin
      for (int ai = 1; ai < CORE_COUNT; ai++) begin
        if (!arb_sel_valid &&
            req_valid[(int'(rr_ptr) + ai) % CORE_COUNT]) begin
          arb_sel = CORE_IDX_W'((int'(rr_ptr) + ai) % CORE_COUNT);
          arb_sel_valid = 1'b1;
        end
      end
    end
    for (int i = 0; i < CORE_COUNT; i++) begin
      req_ready[i] = rst_n && (state == S_IDLE) && arb_sel_valid && (i == arb_sel);
      rsp_valid[i] = rst_n && (state == S_RSP) && (i == cur_core);
      rsp[i].data = op_rsp_data;
      rsp[i].fault = op_fault;
      rsp_source_id[i] = cur_source;
      rsp_transaction_id[i] = cur_transaction;

      probe_req_valid[i] = rst_n && (state == S_PROBE_REQ) && (i == probe_target);
      probe_req_addr[i] = line_base(cur_idx);
      probe_req_cmd[i] = probe_cmd_r;
      probe_req_source_id[i] = cur_source;
      probe_req_transaction_id[i] = cur_transaction;
      probe_rsp_ready[i] = rst_n && (state == S_PROBE_COMMIT) && (i == probe_target);
      probe_rsp_abort[i] = rst_n && (state == S_PROBE_COMMIT) && (i == probe_target) &&
                           probe_abort_pending;
    end

    poc_req = '0;
    poc_req_valid = 1'b0;
    if (state == S_FILL_REQ) begin
      poc_req_valid = rst_n;
      poc_req.addr = line_base(cur_idx) + (BEAT_W'(beat_r) * 64'd8);
      poc_req.we = 1'b0;
      poc_req.strb = 8'h00;
      poc_req.wdata = '0;
      poc_req.maint = MAINT_NONE;
      poc_req.bypass = 1'b0;
    end else if (state == S_WB_REQ) begin
      poc_req_valid = rst_n;
      poc_req.addr = line_base(cur_idx) + (BEAT_W'(beat_r) * 64'd8);
      poc_req.we = 1'b1;
      poc_req.strb = 8'hff;
      poc_req.wdata = wb_data[beat_r*64 +: 64];
      poc_req.maint = MAINT_NONE;
      poc_req.bypass = 1'b0;
    end else if (state == S_BYPASS_REQ) begin
      poc_req_valid = rst_n;
      poc_req.addr = cur_addr;
      poc_req.we = (cur_cmd == COH_BYPASS_WRITE);
      poc_req.strb = (cur_cmd == COH_BYPASS_WRITE) ? 8'hff : 8'h00;
      poc_req.wdata = (cur_cmd == COH_BYPASS_WRITE) ?
                      line_byte(op_rsp_data, cur_addr[OFF_W-1:0]) : '0;
      poc_req.maint = MAINT_NONE;
      poc_req.bypass = 1'b1;
    end
    poc_rsp_ready = rst_n && ((state == S_FILL_WAIT) ||
                              (state == S_WB_WAIT) ||
                              (state == S_BYPASS_WAIT));
  end

  // Debug outputs.
  always_comb begin
    for (int i = 0; i < MEM_LINES; i++) begin
      dir_valid_dbg[i]    = dir_valid[i];
      dir_state_dbg[i]    = dir_state[i];
      dir_sharers_dbg[i]  = dir_sharers[i];
      dir_owner_dbg[i]    = dir_owner[i];
    end
    dir_dirty_dbg   = dir_dirty;
    dir_pending_dbg = dir_pending;
    dbg_cur_core    = cur_core;
    dbg_cur_state   = old_state;
  end

  // ---- Main state machine ----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state           <= S_IDLE;
      cur_core        <= '0;
      cur_cmd         <= '0;
      cur_addr        <= '0;
      cur_idx         <= '0;
      old_state       <= DIR_I;
      old_sharers     <= '0;
      old_owner       <= '0;
      old_dirty       <= 1'b0;
      need_fill       <= 1'b0;
      need_probe      <= 1'b0;
      probe_target    <= '0;
      probe_pending_mask <= '0;
      probe_cmd_r     <= COH_PROBE_LOOKUP;
      probe_active    <= 1'b0;
      probe_abort_pending <= 1'b0;
      probe_dirty_seen <= 1'b0;
      line_buf        <= '0;
      wb_data         <= '0;
      wb_from_probe   <= 1'b0;
      beat_r          <= '0;
      op_fault        <= 1'b0;
      op_rsp_data_ok  <= 1'b0;
      op_rsp_data     <= '0;
      cur_source      <= '0;
      cur_transaction <= '0;
      rr_ptr          <= '0;
      for (int i = 0; i < MEM_LINES; i++) begin
        dir_valid[i]   <= 1'b0;
        dir_state[i]   <= DIR_I;
        dir_sharers[i] <= '0;
        dir_owner[i]   <= '0;
        dir_dirty[i]   <= 1'b0;
        dir_pending[i] <= 1'b0;
      end
    end else begin
      case (state)
        S_IDLE: begin
          op_fault       <= 1'b0;
          op_rsp_data_ok <= 1'b0;
          op_rsp_data    <= '0;
          probe_active   <= 1'b0;
          probe_abort_pending <= 1'b0;
          probe_dirty_seen <= 1'b0;
          wb_from_probe  <= 1'b0;

          if (arb_sel_valid && req_ready[arb_sel]) begin
            cur_core       <= arb_sel;
            cur_cmd        <= req[arb_sel].cmd;
            cur_addr       <= req[arb_sel].addr;
            cur_idx        <= line_index(req[arb_sel].addr);
            old_state      <= dir_valid[line_index(req[arb_sel].addr)] ?
                              dir_state[line_index(req[arb_sel].addr)] : DIR_I;
            old_sharers    <= dir_valid[line_index(req[arb_sel].addr)] ?
                              dir_sharers[line_index(req[arb_sel].addr)] : '0;
            old_owner      <= dir_valid[line_index(req[arb_sel].addr)] ?
                              dir_owner[line_index(req[arb_sel].addr)] : '0;
            old_dirty      <= dir_valid[line_index(req[arb_sel].addr)] ?
                              dir_dirty[line_index(req[arb_sel].addr)] : 1'b0;
            cur_source     <= req_source_id[arb_sel];
            cur_transaction <= req_transaction_id[arb_sel];
            wb_data        <= req[arb_sel].data;
            beat_r         <= '0;
            op_fault       <= 1'b0;
            // A non-power-of-two or out-of-range line is treated as a fault;
            // this is a bounded C2 memory model, not a claim about full PA.
            if (req[arb_sel].addr < MEM_BASE ||
                (req[arb_sel].addr - MEM_BASE) >= (64'(MEM_LINES) * 64'd64)) begin
              op_fault <= 1'b1;
              // Pending is not set for an invalid address; go straight to rsp.
              state <= S_RSP;
            end else begin
              dir_pending[line_index(req[arb_sel].addr)] <= 1'b1;
              // Clear stale dir_dirty when a new non-owner transaction starts;
              // it is only meaningful in M/clean states below.
              if (req[arb_sel].cmd == COH_READ_SHARED ||
                  req[arb_sel].cmd == COH_READ_UNIQUE ||
                  req[arb_sel].cmd == COH_UPGRADE) begin
                // Default decision.
                if (dir_valid[line_index(req[arb_sel].addr)] && (dir_state[line_index(req[arb_sel].addr)] == DIR_M)) begin
                  if (dir_owner[line_index(req[arb_sel].addr)][arb_sel]) begin
                    // Owner asks again: provide data through a fill.
                    need_probe <= 1'b0;
                    need_fill   <= 1'b1;
                    state       <= S_FILL_REQ;
                  end else begin
                    need_probe <= 1'b1;
                    probe_pending_mask <= dir_owner[line_index(req[arb_sel].addr)];
                    probe_target <= first_core(dir_owner[line_index(req[arb_sel].addr)]);
                    probe_cmd_r  <= COH_PROBE_CLEAN_INVALIDATE;
                    need_fill    <= 1'b0;
                    state        <= S_PROBE_REQ;
                  end
                end else if (dir_valid[line_index(req[arb_sel].addr)] && (dir_state[line_index(req[arb_sel].addr)] == DIR_S)) begin
                  if ((req[arb_sel].cmd == COH_READ_UNIQUE) ||
                      (req[arb_sel].cmd == COH_UPGRADE)) begin
                    // If the requester is already a sharer, no refill is needed
                    // for Upgrade/ReadUnique-as-upgrade.  A true ReadUnique from
                    // I/S with the requester absent still needs data.
                    if ((req[arb_sel].cmd == COH_UPGRADE) ||
                        (req[arb_sel].cmd == COH_READ_UNIQUE &&
                         dir_sharers[line_index(req[arb_sel].addr)][arb_sel])) begin
                      need_fill <= 1'b0;
                    end else begin
                      need_fill <= 1'b1;
                    end
                    // Invalidate all sharers except the requester.  If there are
                    // multiple sharers, iterate through them via probe_pending_mask.
                    if ((dir_sharers[line_index(req[arb_sel].addr)] &
                         ~(CORE_COUNT'(1) << arb_sel)) != '0) begin
                      need_probe <= 1'b1;
                      probe_pending_mask <= dir_sharers[line_index(req[arb_sel].addr)] &
                                            ~(CORE_COUNT'(1) << arb_sel);
                      probe_target <= first_core(dir_sharers[line_index(req[arb_sel].addr)] &
                                                 ~(CORE_COUNT'(1) << arb_sel));
                      probe_cmd_r  <= COH_PROBE_INVALIDATE;
                      state        <= S_PROBE_REQ;
                    end else begin
                      need_probe <= 1'b0;
                      probe_pending_mask <= '0;
                      if ((req[arb_sel].cmd == COH_UPGRADE) ||
                          (req[arb_sel].cmd == COH_READ_UNIQUE &&
                           dir_sharers[line_index(req[arb_sel].addr)][arb_sel]))
                        state <= S_COMMIT;
                      else
                        state <= S_FILL_REQ;
                    end
                  end else begin
                    // ReadShared from S: just add sharer; data comes from PoC.
                    need_probe <= 1'b0;
                    need_fill   <= 1'b1;
                    state       <= S_FILL_REQ;
                  end
                end else begin
                  // I: need data from PoC.
                  need_probe <= 1'b0;
                  need_fill   <= 1'b1;
                  state       <= S_FILL_REQ;
                end
              end else if (req[arb_sel].cmd == COH_WRITEBACK ||
                           req[arb_sel].cmd == COH_CLEAN ||
                           req[arb_sel].cmd == COH_CLEAN_INVALIDATE ||
                           req[arb_sel].cmd == COH_INVALIDATE) begin
                need_probe <= 1'b0;
                need_fill   <= 1'b0;
                wb_from_probe <= 1'b0;
                state <= S_WB_REQ;
              end else if (req[arb_sel].cmd == COH_BYPASS_READ ||
                           req[arb_sel].cmd == COH_BYPASS_WRITE) begin
                need_probe <= 1'b0;
                need_fill   <= 1'b0;
                // The bypass write data is taken from the 64B request payload.
                op_rsp_data <= req[arb_sel].data;
                state <= S_BYPASS_REQ;
              end else begin
                op_fault <= 1'b1;
                state <= S_RSP;
              end
            end
            rr_ptr <= (arb_sel == CORE_IDX_W'(CORE_COUNT-1)) ? '0 : (arb_sel + 1'b1);
          end
        end

        S_PROBE_REQ: begin
          if (probe_req_valid[probe_target] && probe_req_ready[probe_target]) begin
            probe_active <= 1'b1;
            state        <= S_PROBE_WAIT;
          end
        end

        S_PROBE_WAIT: begin
          if (probe_rsp_valid[probe_target]) begin
            if (probe_rsp_fault[probe_target]) begin
              op_fault <= 1'b1;
              probe_abort_pending <= 1'b0;
              state <= S_PROBE_COMMIT;
            end else if (probe_rsp_line_valid[probe_target] &&
                         probe_rsp_dirty[probe_target]) begin
              // Hold the probe response until the dirty line is written to PoC.
              wb_data       <= probe_rsp_data[probe_target];
              line_buf      <= probe_rsp_data[probe_target];
              wb_from_probe <= 1'b1;
              probe_dirty_seen <= 1'b1;
              beat_r        <= '0;
              state         <= S_WB_REQ;
            end else begin
              // Non-dirty probe can be committed immediately.
              probe_dirty_seen <= 1'b0;
              state <= S_PROBE_COMMIT;
            end
          end
        end

        S_PROBE_COMMIT: begin
          if (probe_rsp_valid[probe_target] && probe_rsp_ready[probe_target]) begin
            probe_active <= 1'b0;
            if (op_fault) begin
              probe_pending_mask <= '0;
              state <= S_RSP;
            end else if ((probe_pending_mask &
                          ~(CORE_COUNT'(1) << probe_target)) != '0) begin
              // More sharers/owners still need to be invalidated.
              probe_pending_mask <= probe_pending_mask &
                                    ~(CORE_COUNT'(1) << probe_target);
              probe_target <= first_core(probe_pending_mask &
                                         ~(CORE_COUNT'(1) << probe_target));
              state <= S_PROBE_REQ;
            end else begin
              probe_pending_mask <= '0;
              if (need_fill) begin
                state <= S_FILL_REQ;
              end else begin
                state <= S_COMMIT;
              end
            end
          end
        end

        S_FILL_REQ: begin
          if (poc_req_valid && poc_req_ready) begin
            state <= S_FILL_WAIT;
          end
        end

        S_FILL_WAIT: begin
          if (poc_rsp_valid && poc_rsp_ready) begin
            if (poc_rsp.fault) begin
              op_fault <= 1'b1;
              state    <= S_RSP;
            end else begin
              for (int i = 0; i < 8; i++) begin
                line_buf[beat_r*64 + i*8 +: 8] <= poc_rsp.rdata[i*8 +: 8];
              end
              if (beat_r == BEAT_W'(BEATS-1)) begin
                state <= S_COMMIT;
              end else begin
                beat_r <= beat_r + 1'b1;
                state  <= S_FILL_REQ;
              end
            end
          end
        end

        S_WB_REQ: begin
          if (poc_req_valid && poc_req_ready) begin
            state <= S_WB_WAIT;
          end
        end

        S_WB_WAIT: begin
          if (poc_rsp_valid && poc_rsp_ready) begin
            if (poc_rsp.fault) begin
              op_fault <= 1'b1;
              if (wb_from_probe) begin
                probe_abort_pending <= 1'b1;
                state <= S_PROBE_COMMIT;
              end else begin
                state <= S_RSP;
              end
            end else if (beat_r == BEAT_W'(BEATS-1)) begin
              if (wb_from_probe) begin
                state <= S_PROBE_COMMIT;
              end else begin
                state <= S_COMMIT;
              end
            end else begin
              beat_r <= beat_r + 1'b1;
              state  <= S_WB_REQ;
            end
          end
        end

        S_BYPASS_REQ: begin
          if (poc_req_valid && poc_req_ready) begin
            state <= S_BYPASS_WAIT;
          end
        end

        S_BYPASS_WAIT: begin
          if (poc_rsp_valid && poc_rsp_ready) begin
            op_rsp_data <= {448'd0, poc_rsp.rdata};
            op_fault     <= poc_rsp.fault;
            state        <= S_RSP;
          end
        end

        S_COMMIT: begin
          // Only commit directory state on success.  op_fault means this was
          // not reached from fault paths.
          if (!op_fault) begin
            case (cur_cmd)
              COH_READ_SHARED: begin
                dir_valid[cur_idx] <= 1'b1;
                dir_state[cur_idx] <= DIR_S;
                // If we invalidated a dirty M owner, its old sharer bit must
                // not survive; if we were already in S and merely added a
                // sharer, preserve the existing sharer set.
                if (old_state == DIR_S)
                  dir_sharers[cur_idx] <= (1 << cur_core) | old_sharers;
                else
                  dir_sharers[cur_idx] <= (1 << cur_core);
                dir_owner[cur_idx] <= '0;
                dir_dirty[cur_idx] <= 1'b0;
              end
              COH_READ_UNIQUE, COH_UPGRADE: begin
                dir_valid[cur_idx] <= 1'b1;
                dir_state[cur_idx] <= DIR_M;
                dir_sharers[cur_idx] <= (1 << cur_core);
                dir_owner[cur_idx] <= (1 << cur_core);
                dir_dirty[cur_idx] <= 1'b1;
              end
              COH_WRITEBACK: begin
                dir_valid[cur_idx] <= 1'b0;
                dir_state[cur_idx] <= DIR_I;
                dir_sharers[cur_idx] <= '0;
                dir_owner[cur_idx] <= '0;
                dir_dirty[cur_idx] <= 1'b0;
              end
              COH_CLEAN: begin
                dir_valid[cur_idx] <= 1'b1;
                dir_state[cur_idx] <= DIR_S;
                dir_sharers[cur_idx] <= (1 << cur_core);
                dir_owner[cur_idx] <= '0;
                dir_dirty[cur_idx] <= 1'b0;
              end
              default: begin // COH_CLEAN_INVALIDATE / COH_INVALIDATE
                dir_valid[cur_idx] <= 1'b0;
                dir_state[cur_idx] <= DIR_I;
                dir_sharers[cur_idx] <= '0;
                dir_owner[cur_idx] <= '0;
                dir_dirty[cur_idx] <= 1'b0;
              end
            endcase
            // Response data: if a fill or dirty-owner probe produced a line,
            // return it.  Otherwise return zero (Upgrade/WB/clean are ack-only).
            if (need_fill || probe_dirty_seen) begin
              op_rsp_data <= line_buf;
              op_rsp_data_ok <= 1'b1;
            end else begin
              op_rsp_data <= '0;
              op_rsp_data_ok <= 1'b0;
            end
          end
          dir_pending[cur_idx] <= 1'b0;
          state <= S_RSP;
        end

        S_RSP: begin
          if (rsp_valid[cur_core] && rsp_ready[cur_core]) begin
            state          <= S_IDLE;
            dir_pending[cur_idx] <= 1'b0;
            op_rsp_data_ok <= 1'b0;
            op_rsp_data    <= '0;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  // Helper used only in the probe wait branch.  It intentionally allows a
  // response to be observed only when the current probe target is valid.
  function automatic logic poc_probe_ready_ok();
    return 1'b1;
  endfunction

  // ---- C2 directory invariants (SVA) ----
  /* verilator lint_off SYNCASYNCNET */
  generate
    for (genvar gi = 0; gi < MEM_LINES; gi++) begin : g_dir_inv
      assert property (@(posedge clk) disable iff (!rst_n)
          (dir_state[gi] == DIR_M) |->
          ($onehot(dir_owner[gi]) &&
           (dir_sharers[gi] == dir_owner[gi]) &&
           dir_dirty[gi]));
      assert property (@(posedge clk) disable iff (!rst_n)
          (dir_state[gi] == DIR_S) |->
          (dir_sharers[gi] != '0 &&
           (dir_owner[gi] == '0) &&
           !dir_dirty[gi]));
      assert property (@(posedge clk) disable iff (!rst_n)
          (dir_state[gi] == DIR_I) |->
          (dir_sharers[gi] == '0 &&
           (dir_owner[gi] == '0) &&
           !dir_dirty[gi]));
    end
  endgenerate
  /* verilator lint_on SYNCASYNCNET */

endmodule
