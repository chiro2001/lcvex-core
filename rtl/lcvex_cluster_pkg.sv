// lcvex_cluster_pkg.sv
// C1 dual-core shell: multi-core observability payload and event types.
//
// This package intentionally does not modify lcvex_pkg's existing single-core
// commit/memory structs.  The new MC envelope is additive only.

package lcvex_cluster_pkg;

  localparam int CORE_ID_W         = 4;
  localparam int CORE_COUNT_MAX    = 4;
  localparam logic [3:0] MC_VERSION = 4'd2;

  // C0 §3.4 event kinds.  C1 only needs a locally observable subset; the
  // enum leaves room for C2/C3 without touching lcvex_pkg.
  typedef enum logic [2:0] {
    MC_EV_COMMIT    = 3'd0,
    MC_EV_ASYNC_IRQ = 3'd1,
    MC_EV_WFI       = 3'd2,
    MC_EV_WFE       = 3'd3,
    MC_EV_STOP      = 3'd4,
    MC_EV_FAULT     = 3'd5,
    MC_EV_RESET     = 3'd6
  } lcvex_mc_event_t;

  // Multi-core commit envelope.  The core_id is intentionally outside the
  // single-core commit packet, per C0 §3.4.
  typedef struct packed {
    logic [3:0]               version;
    logic [CORE_ID_W-1:0]     core_id;
    logic [63:0]              global_seq;
    logic [31:0]              vcpu_seq;
    lcvex_mc_event_t          event_kind;
    lcvex_pkg::commit_packet_t commit;
  } lcvex_mc_commit_t;

  // AArch64 encodings of the P6 event/wait instructions.  These are used by
  // the C1 wrapper only for local observability; the core itself implements
  // the architectural behaviour.
  localparam logic [31:0] INSN_WFI  = 32'hD503_207F;
  localparam logic [31:0] INSN_WFE  = 32'hD503_205F;
  localparam logic [31:0] INSN_SEV  = 32'hD503_209F;
  localparam logic [31:0] INSN_SEVL = 32'hD503_20BF;
  localparam logic [31:0] INSN_WFIT_MASK = 32'hFFFF_FFE0;
  localparam logic [31:0] INSN_WFIT_BASE = 32'hD503_1020;
  localparam logic [31:0] INSN_WFET_MASK = 32'hFFFF_FFE0;
  localparam logic [31:0] INSN_WFET_BASE = 32'hD503_1000;

  // ------------------------------------------------------------------
  // C2 shared-L2 directory MSI protocol types.
  //
  // These are additive to lcvex_pkg.  The cluster talks to a per-core
  // coherent L1 through line-level commands; ordinary M1-B mem_req_t is
  // still used on the PoC side.  C2 deliberately keeps a single transaction
  // in the cluster, one probe at a time, and CORE_COUNT=2.
  // ------------------------------------------------------------------
  localparam int COH_LINE_BYTES = 64;

  typedef enum logic [3:0] {
    COH_READ_SHARED     = 4'd0,
    COH_READ_UNIQUE     = 4'd1,
    COH_UPGRADE         = 4'd2,
    COH_WRITEBACK       = 4'd3,
    COH_CLEAN           = 4'd4,
    COH_CLEAN_INVALIDATE= 4'd5,
    COH_INVALIDATE      = 4'd6,
    COH_BYPASS_READ     = 4'd7,
    COH_BYPASS_WRITE    = 4'd8
  } lcvex_coh_cmd_t;

  typedef enum logic [1:0] {
    COH_L1_I = 2'd0,
    COH_L1_S = 2'd1,
    COH_L1_M = 2'd2
  } lcvex_coh_l1_state_t;

  typedef struct packed {
    lcvex_coh_cmd_t               cmd;
    logic [63:0]                  addr;
    logic [COH_LINE_BYTES*8-1:0]  data;
  } lcvex_coh_req_t;

  typedef struct packed {
    logic [COH_LINE_BYTES*8-1:0]  data;
    logic                         fault;
  } lcvex_coh_rsp_t;

  // Probe command encoding is kept identical to the existing B4 probe port:
  // 0=lookup, 1=clean, 2=invalidate, 3=clean+invalidate.
  localparam logic [1:0] COH_PROBE_LOOKUP           = 2'd0;
  localparam logic [1:0] COH_PROBE_CLEAN            = 2'd1;
  localparam logic [1:0] COH_PROBE_INVALIDATE       = 2'd2;
  localparam logic [1:0] COH_PROBE_CLEAN_INVALIDATE = 2'd3;

endpackage
