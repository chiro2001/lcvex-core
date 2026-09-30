# lcvex_catapult_a10_top user timing constraints (B0+ skeleton)
# clk_u59 = 100 MHz system/core clock (PIN_AP20, 1.8V)
create_clock -period 10.000 -name clk_u59 [get_ports {clk_u59}]
# Glitch-free divide-by-four register in lcvex_catapult_a10_top.  All logic
# domain paths (JTAG-UART, EPCQ controller, B5 SoC wiring) run from this real
# 25 MHz clock.  The Qsys clk_100 auxiliary input remains on clk_u59 below
# because its reset controller is a genuine 100 MHz consumer.
create_generated_clock -name sys_clk_25 \
    -source [get_ports {clk_u59}] -divide_by 4 \
    [get_pins {sys_clk_25|q}]
# clk_y3  = 266.667 MHz EMIF bottom reference (PIN_AG5)
create_clock -period 3.750 -name clk_y3 [get_ports {clk_y3}]
# LED outputs are purely cosmetic; no frequency requirement.
set_false_path -to [get_ports {leds[*]}]

# ---- Declare the EMIF user-clock -> sys_clk_25 CDC false paths ----
# The user SDC is read before the EMIF-generated clocks exist, so the EMIF
# clock cannot be reliably named in set_clock_groups here (Quartus warns and
# ignores the filter).  The register-level CDC exceptions below are the
# authoritative enforcement after post-fit STA.  The only crossings are the
# reset/calibration synchronizer inputs, the adapter reset synchronizers and
# the asynchronous FIFO gray pointer/data paths.
set_false_path -from [get_registers -nowarn {emif|emif_bot|*}] \
    -to [get_registers -nowarn {reset_gate_inst|cal_success_sync_q[0]}]
set_false_path -from [get_registers -nowarn {reset_gate_inst|fail_emif_latched_q}] \
    -to [get_registers -nowarn {reset_gate_inst|cal_fail_sync_q[0]}]

# ============================================================================
# AUD-04: B2 async FIFO CDC and common-reset release constraints
# ----------------------------------------------------------------------------
# This block is the static/stand-in for the B2 CDC.  T-20260902-019 confirmed
# the real post-fit clock name is emif|emif_bot|emif_bot_core_usr_clk and that
# the previous un-prefixed FIFO/reset-sync register filters were ignored by
# TimeQuest.  The names below use wildcard prefixes so they match the actual
# soc|emif_adapter hierarchy.
# ============================================================================

# 1. A clock-group declaration is intentionally not used here: the EMIF
#    generated clock is not visible when the user SDC is first read, so
#    set_clock_groups cannot be reliably applied and would only produce
#    ignored-filter warnings.  The register-level exceptions below are the
#    authoritative asynchronous/CDC cuts.
# 2. Explicitly cut/annotate all four gray-pointer crossing directions
#    source -> first synchronizer stage.  These are actual asynchronous
#    crossings even if the clock-group declaration is not resolvable in the
#    user SDC phase:
#      request:  sys wr_ptr_gray_q -> EMIF wr_ptr_gray_rd1_q (sys->EMIF)
#                EMIF rd_ptr_gray_q -> sys rd_ptr_gray_wr1_q (EMIF->sys)
#      response: sys rd_ptr_gray_q -> EMIF rd_ptr_gray_wr1_q (sys->EMIF)
#                EMIF wr_ptr_gray_q -> sys wr_ptr_gray_rd1_q (EMIF->sys)
#    The RTL is hardened so the launch register is always a source-domain
#    registered Gray pointer; these SDC cuts only name the correct first-stage
#    synchronizer crossings, not binary-pointer retiming paths.
if {[llength [get_registers -nowarn {*request_fifo|wr_ptr_gray_q*}]] > 0} {
  set_false_path -from [get_registers -nowarn {*request_fifo|wr_ptr_gray_q*}] \
                 -to [get_registers -nowarn {*request_fifo|wr_ptr_gray_rd1_q*}]
}
if {[llength [get_registers -nowarn {*request_fifo|rd_ptr_gray_q*}]] > 0} {
  set_false_path -from [get_registers -nowarn {*request_fifo|rd_ptr_gray_q*}] \
                 -to [get_registers -nowarn {*request_fifo|rd_ptr_gray_wr1_q*}]
}
if {[llength [get_registers -nowarn {*response_fifo|rd_ptr_gray_q*}]] > 0} {
  set_false_path -from [get_registers -nowarn {*response_fifo|rd_ptr_gray_q*}] \
                 -to [get_registers -nowarn {*response_fifo|rd_ptr_gray_wr1_q*}]
}
if {[llength [get_registers -nowarn {*response_fifo|wr_ptr_gray_q*}]] > 0} {
  set_false_path -from [get_registers -nowarn {*response_fifo|wr_ptr_gray_q*}] \
                 -to [get_registers -nowarn {*response_fifo|wr_ptr_gray_rd1_q*}]
}

# 3. Async-FIFO data/memory paths are asynchronous; T-019 showed these as the
#    worst sys_clk_25 hold violations when the clock-group declaration was
#    ignored.  Keep the same 2 ns manual-review bound on all four pointer-sync
#    directions.  The bound applies to the registered Gray launch register, so
#    it documents the intended first-stage crossing after RTL hardening.
if {[llength [get_registers -nowarn {*request_fifo|wr_ptr_gray_q*}]] > 0} {
  set_data_delay -from [get_registers -nowarn {*request_fifo|wr_ptr_gray_q*}] \
                 -to [get_registers -nowarn {*request_fifo|wr_ptr_gray_rd1_q*}] 2.000
}
if {[llength [get_registers -nowarn {*request_fifo|rd_ptr_gray_q*}]] > 0} {
  set_data_delay -from [get_registers -nowarn {*request_fifo|rd_ptr_gray_q*}] \
                 -to [get_registers -nowarn {*request_fifo|rd_ptr_gray_wr1_q*}] 2.000
}
if {[llength [get_registers -nowarn {*response_fifo|rd_ptr_gray_q*}]] > 0} {
  set_data_delay -from [get_registers -nowarn {*response_fifo|rd_ptr_gray_q*}] \
                 -to [get_registers -nowarn {*response_fifo|rd_ptr_gray_wr1_q*}] 2.000
}
if {[llength [get_registers -nowarn {*response_fifo|wr_ptr_gray_q*}]] > 0} {
  set_data_delay -from [get_registers -nowarn {*response_fifo|wr_ptr_gray_q*}] \
                 -to [get_registers -nowarn {*response_fifo|wr_ptr_gray_rd1_q*}] 2.000
}

# 3b. FIFO memory read data is consumed in the receiving clock domain without a
#     second synchronizer.  The gray-pointer CDC handles safe pointer transfer;
#     the data path itself is therefore an asynchronous exception and must not
#     be timed as a normal setup/hold path.
set_false_path -from [get_registers -nowarn {*request_fifo|mem*}] \
               -to [get_registers -nowarn {soc|emif_adapter|emif_req_q*}]
set_false_path -from [get_registers -nowarn {*response_fifo|mem*}] \
               -to [get_registers -nowarn {soc|emif_adapter|read_line_q*}]
set_false_path -from [get_registers -nowarn {*response_fifo|mem*}] \
               -to [get_registers -nowarn {soc|emif_adapter|response_code_q*}]
set_false_path -from [get_registers -nowarn {*response_fifo|mem*}] \
               -to [get_registers -nowarn {soc|emif_adapter|txn_local_q*}]
set_false_path -from [get_registers -nowarn {*response_fifo|mem*}] \
               -to [get_registers -nowarn {soc|emif_adapter|read_len_q*}]
set_false_path -from [get_registers -nowarn {*response_fifo|mem*}] \
               -to [get_registers -nowarn {soc|emif_adapter|read_beat_q*}]

# 4. Per-domain reset/FIFO epoch synchronizers (EXT-03-001/T-045).  CPU and
#    EMIF FSM resets remain local.  FIFO reset epochs additionally observe the
#    remote reset and calibration failure through first-stage synchronizers.
#    T-045 keeps CPU transaction context across an EMIF-only reset and returns
#    DECERR, so the old EMIF->cpu_rst_sync0_n path is no longer functional;
#    the explicit reset/poison status synchronizers in section 4c now own that
#    abort boundary.  Post-fit TimeQuest must confirm every filter resolves and
#    recovery/removal remains nonnegative.
if {[llength [get_registers -nowarn {*emif_adapter|cpu_rst_sync0_n*}]] > 0} {
  set_false_path -from [get_registers -nowarn {emif|emif_bot|*}] \
                 -to [get_registers -nowarn {*emif_adapter|cpu_rst_sync0_n*}]
  set_false_path -from [get_registers -nowarn {emif|emif_bot|*}] \
                 -to [get_registers -nowarn {*emif_adapter|emif_rst_sync0_n*}]
}
if {[llength [get_registers -nowarn {*emif_adapter|emif_rst_sync0_n*}]] > 0} {
  set_false_path -from [get_registers -nowarn {reset_gate_inst|fail_emif_latched_q}] \
                 -to [get_registers -nowarn {*emif_adapter|emif_rst_sync0_n*}]
}
if {[llength [get_registers -nowarn {*emif_adapter|cpu_rst_sync0_n*}]] > 0} {
  set_false_path -from [get_registers -nowarn {reset_gate_inst|logic_rst_n_q}] \
                 -to [get_registers -nowarn {*emif_adapter|cpu_rst_sync0_n*}]
}

# T-20260902-027: the adapter reset release bridges now sample the remote
# domain reset as ordinary data into the first EMIF synchronizer stage (the
# async reset pin itself is driven only by the local EMIF reset). Cut the
# sys->EMIF first-stage data path; the EMIF recovery path is now entirely a
# same-domain local reset path.
if {[llength [get_registers -nowarn {*emif_adapter|emif_rst_sync0_n*}]] > 0} {
  set_false_path -from [get_registers -nowarn {reset_gate_inst|logic_rst_n_q}] \
                 -to [get_registers -nowarn {*emif_adapter|emif_rst_sync0_n*}]
}

# 4b. Calibration-gate first-stage synchronizers inside the SoC adapter.
if {[llength [get_registers -nowarn {*emif_adapter|calibration_gate|success_cpu_meta_q*}]] > 0} {
  set_false_path -from [get_registers -nowarn {emif|emif_bot|*}] \
                 -to [get_registers -nowarn {*emif_adapter|calibration_gate|success_cpu_meta_q*}]
}

# 4c. T-045 EMIF abort/poison epoch synchronizers.  emif_reset_cpu_meta_q and
#     emif_poisoned_cpu_meta_q are the only CPU-domain first stages.  The
#     reverse cpu_rst_emif_meta_q chain samples the CPU reset as data so an
#     EMIF-only reset cannot accidentally re-arm retained read/poison state.
if {[llength [get_registers -nowarn {*emif_adapter|emif_reset_cpu_meta_q*}]] > 0} {
  set_false_path -from [get_registers -nowarn {emif|emif_bot|*}] \
                 -to [get_registers -nowarn {*emif_adapter|emif_reset_cpu_meta_q*}]
}
if {[llength [get_registers -nowarn {*emif_adapter|emif_poisoned_cpu_meta_q*}]] > 0} {
  set_false_path -from [get_registers -nowarn {*emif_adapter|emif_poisoned_q*}] \
                 -to [get_registers -nowarn {*emif_adapter|emif_poisoned_cpu_meta_q*}]
  set_data_delay -from [get_registers -nowarn {*emif_adapter|emif_poisoned_q*}] \
                 -to [get_registers -nowarn {*emif_adapter|emif_poisoned_cpu_meta_q*}] 2.000
}
if {[llength [get_registers -nowarn {*emif_adapter|cpu_rst_emif_meta_q*}]] > 0} {
  set_false_path -from [get_registers -nowarn {reset_gate_inst|logic_rst_n_q}] \
                 -to [get_registers -nowarn {*emif_adapter|cpu_rst_emif_meta_q*}]
}
if {[llength [get_registers -nowarn {*emif_adapter|calibration_gate|fail_cpu_meta_q*}]] > 0} {
  set_false_path -from [get_registers -nowarn {*emif_adapter|calibration_gate|fail_emif_latched_q*}] \
                 -to [get_registers -nowarn {*emif_adapter|calibration_gate|fail_cpu_meta_q*}]
}

# 5. Asynchronous control/reset exceptions observed in T-20260902-019 signoff
#    STA.  The CPU power-on reset and the EMIF calibration status are consumed
#    as asynchronous control/reset signals by the adapter/EMIF boundary before
#    all paths are synchronized.  These exception cuts are required to keep
#    those known asynchronous crossings out of setup/hold/recovery/removal
#    analysis; they do NOT replace the RTL-level CDC hardening needed for
#    safe reset deassertion/calibration-handling (see handoff blockers).
set_false_path -from [get_registers -nowarn {reset_gate_inst|logic_rst_n_q}] \
               -to [get_registers -nowarn {emif|emif_bot|*}]
set_false_path -from [get_registers -nowarn {reset_gate_inst|logic_rst_n_q}] \
               -to [get_registers -nowarn {soc|emif_adapter|emif_req_q*}]
set_false_path -from [get_registers -nowarn {reset_gate_inst|logic_rst_n_q}] \
               -to [get_registers -nowarn {soc|emif_adapter|response_fifo|*}]
set_false_path -from [get_registers -nowarn {reset_gate_inst|logic_rst_n_q}] \
               -to [get_registers -nowarn {soc|emif_adapter|request_fifo|*}]

set_false_path -from [get_registers -nowarn {emif|emif_bot|*}] \
               -to [get_registers -nowarn {soc|core|*}]
set_false_path -from [get_registers -nowarn {emif|emif_bot|*}] \
               -to [get_registers -nowarn {soc|axi_master|*}]
set_false_path -from [get_registers -nowarn {emif|emif_bot|*}] \
               -to [get_registers -nowarn {soc|emif_adapter|calibration_gate|*}]
set_false_path -from [get_registers -nowarn {emif|emif_bot|*}] \
               -to [get_registers -nowarn {soc|emif_adapter|txn_*}]
set_false_path -from [get_registers -nowarn {emif|emif_bot|*}] \
               -to [get_registers -nowarn {soc|emif_adapter|aw_*}]
set_false_path -from [get_registers -nowarn {emif|emif_bot|*}] \
               -to [get_registers -nowarn {soc|emif_adapter|w_*}]
set_false_path -from [get_registers -nowarn {emif|emif_bot|*}] \
               -to [get_registers -nowarn {soc|emif_adapter|read_addr_q*}]
set_false_path -from [get_registers -nowarn {emif|emif_bot|*}] \
               -to [get_registers -nowarn {soc|emif_adapter|read_len_q*}]
set_false_path -from [get_registers -nowarn {emif|emif_bot|*}] \
               -to [get_registers -nowarn {soc|emif_adapter|read_size_q*}]
set_false_path -from [get_registers -nowarn {emif|emif_bot|*}] \
               -to [get_registers -nowarn {soc|emif_adapter|read_beat_q*}]
set_false_path -from [get_registers -nowarn {emif|emif_bot|*}] \
               -to [get_registers -nowarn {soc|emif_adapter|read_line_q*}]
set_false_path -from [get_registers -nowarn {emif|emif_bot|*}] \
               -to [get_registers -nowarn {soc|emif_adapter|response_code_q*}]
set_false_path -from [get_registers -nowarn {emif|emif_bot|*}] \
               -to [get_registers -nowarn {soc|emif_adapter|cpu_*}]
set_false_path -from [get_registers -nowarn {emif|emif_bot|*}] \
               -to [get_registers -nowarn {soc|emif_adapter|response_fifo|rd_ptr_*}]
set_false_path -from [get_registers -nowarn {emif|emif_bot|*}] \
               -to [get_registers -nowarn {soc|emif_adapter|response_fifo|wr_ptr_gray_rd*}]
set_false_path -from [get_registers -nowarn {emif|emif_bot|*}] \
               -to [get_registers -nowarn {soc|emif_adapter|response_fifo|mem*}]

# 6. The FIFO internal source->first-synchronizer paths remain the same CDC
#    paths (steps 2/3).  Reset release must additionally be validated
#    dynamically; see docs/handoffs/T-20260830-026-ext-03-fix.md.
#    No TimeQuest/Report CDC run was attempted in this task; the T-019 STA
#    report is the source for the observed path names.
