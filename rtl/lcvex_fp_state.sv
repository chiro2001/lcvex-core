// lcvex_fp_state.sv
//
// P7-0：独立的 AArch64 FP/Advanced SIMD 架构状态边界。
//
// 本模块只提供状态、权限、异常和提交/恢复接口，不实现任何 FP/NEON
// 运算或访存。当前已加入 rtl/filelist.f，并由 lcvex_core 明确实例化到
// ID/WB/COMMIT 与 checkpoint restore 边界；独立 testbench 仍可直接验证它。
//
// 状态更新规则：
//   * V0-V31、FPCR、FPSR、CPACR 只在 reset、system commit、scalar commit
//     或 difftest restore 边界更新；没有层级窥探或逐条回灌路径。
//   * restore 优先于同拍 commit，并在一个时钟沿同时写入 FP state；这对应
//     P7 checkpoint 的“与 scalar state 同一 clock edge”契约。
//   * FPCR/FPSR 的 reserved/未实现位按 mask RAZ/WI；CPACR 是完整 64 位
//     状态，P7 只使用 FPEN[21:20] 判定权限，不把 FPEN mask 当作 CPACR
//     的全寄存器写 mask。
//   * commit_* 输入代表已经通过 scalar valid/ready 的实际 commit_fire，
//     因此 FP effect 与 scalar commit 属于同一个提交边界。

`timescale 1ns/1ps

module lcvex_fp_state (
    input  logic                    clk,
    input  logic                    rst_n,

    // AArch64 current EL：0=EL0，1=EL1；本阶段不实现 EL2/EL3。
    input  logic [1:0]              current_el,

    // 当前 ID 级 FP/Advanced SIMD 或 FPCR/FPSR access。该信号只描述
    // access 尝试，不会自行提交架构状态。
    input  logic                    fp_access_valid,
    output logic                    fp_access_allowed,
    output logic                    fp_trap_valid,
    output logic [31:0]             fp_trap_code,
    output logic [31:0]             fp_trap_esr,

    // 当前可见架构状态与 MRS 读值。FPCR/FPSR read data 已应用 P7 mask；
    // V 与 CPACR 保持 raw state。
    output logic [31:0]             fpcr_state,
    output logic [31:0]             fpsr_state,
    output logic [63:0]             cpacr_el1_state,
    output logic [1:0]              cpacr_fpen,
    output logic [31:0]             fpcr_read_data,
    output logic [31:0]             fpsr_read_data,
    output logic [63:0]             cpacr_read_data,
    output logic [127:0]            v_state [0:31],

    // ID system commit：FPCR/FPSR access 必须同时经过 fp_access_valid/
    // fp_access_allowed；CPACR 只有 EL1 可写。write_accept 是实际会改变
    // 状态的条件，便于上游把它接到 sys commit effect。
    input  logic                    sys_commit_valid,
    input  logic                    sys_fpcr_we,
    input  logic [31:0]             sys_fpcr_wdata,
    input  logic                    sys_fpsr_we,
    input  logic [31:0]             sys_fpsr_wdata,
    input  logic                    sys_cpacr_we,
    input  logic [63:0]             sys_cpacr_wdata,
    output logic                    sys_fpcr_write_accept,
    output logic                    sys_fpsr_write_accept,
    output logic                    sys_cpacr_write_accept,
    output logic                    sys_fp_access_blocked,
    output logic                    sys_cpacr_write_blocked,

    // 与既有 scalar commit_packet 同一条 commit.valid 的 RTL-only effect
    // 输入。wire/trace 不应把这些 vec_we/fp*_we 当作 QEMU oracle。
    input  logic                    commit_valid,
    input  logic [2:0]              commit_vec_write_count,
    input  logic [4:0]              commit_vec_rd0,
    input  logic [4:0]              commit_vec_rd1,
    input  logic [4:0]              commit_vec_rd2,
    input  logic [4:0]              commit_vec_rd3,
    input  logic [127:0]            commit_vec_wdata0,
    input  logic [127:0]            commit_vec_wdata1,
    input  logic [127:0]            commit_vec_wdata2,
    input  logic [127:0]            commit_vec_wdata3,
    input  logic                    commit_fpcr_we,
    input  logic [31:0]             commit_fpcr_wdata,
    input  logic                    commit_fpsr_we,
    input  logic [31:0]             commit_fpsr_wdata,
    output logic                    commit_effect_valid,
    output logic                    commit_effect_error,
    output logic [2:0]              commit_effect_vec_write_count,
    output logic [4:0]              commit_effect_vec_rd0,
    output logic [4:0]              commit_effect_vec_rd1,
    output logic [4:0]              commit_effect_vec_rd2,
    output logic [4:0]              commit_effect_vec_rd3,
    output logic [127:0]            commit_effect_vec_wdata0,
    output logic [127:0]            commit_effect_vec_wdata1,
    output logic [127:0]            commit_effect_vec_wdata2,
    output logic [127:0]            commit_effect_vec_wdata3,
    output logic                    commit_effect_fpcr_we,
    output logic [31:0]             commit_effect_fpcr_wdata,
    output logic                    commit_effect_fpsr_we,
    output logic [31:0]             commit_effect_fpsr_wdata,

    // checkpoint restore：FP sidecar 的 full raw state。FPCR/FPSR 仍经过
    // 同一个 P7 mask，V 保留全部 128 bit。difftest_restore_sys_valid 是
    // 既有 scalar sys restore 的子集，此处只消费完整 CPACR 值。
    input  logic                    difftest_restore_fp_valid,
    input  logic [31:0]             difftest_restore_fpcr,
    input  logic [31:0]             difftest_restore_fpsr,
    input  logic [127:0]            difftest_restore_v [0:31],
    input  logic                    difftest_restore_sys_valid,
    input  logic [63:0]             difftest_restore_cpacr_el1
);

  import lcvex_pkg::*;

  logic        commit_shape_error;
  logic        commit_has_fp_effect;
  logic        commit_fp_access_ok;
  logic        commit_accept;
  logic        restore_any;

  function automatic logic fp_permission(
      input logic [1:0] el_value,
      input logic [1:0] fpen_value);
    begin
      // CPACR_EL1.FPEN：00/10 trap EL0+EL1，01 只 trap EL0，11 不 trap。
      unique case (el_value)
        2'd0:    fp_permission = (fpen_value == 2'b11);
        2'd1:    fp_permission = (fpen_value inside {2'b01, 2'b11});
        default: fp_permission = 1'b0;
      endcase
    end
  endfunction

  assign cpacr_fpen = cpacr_el1_state[21:20] &
                      CPACR_P7_OWNED_FPEN_MASK[21:20];
  assign fp_access_allowed = fp_permission(current_el, cpacr_fpen);

  // EC=0x07，AArch64 IL=1，CV=1，COND=0xe；这不是 UDEF(EC=0) 或
  // SYSREG_TRAP。该值与 QEMU syn_a64_fp_access_trap(1, 0xe) 一致。
  assign fp_trap_valid = fp_access_valid && !fp_access_allowed;
  assign fp_trap_code  = fp_trap_valid ? EXC_FP_ACCESS : 32'd0;
  assign fp_trap_esr   = fp_trap_valid ? ESR_FP_ACCESS_TRAP : 32'd0;

  assign fpcr_read_data = fpcr_state & FPCR_P7_WRMASK;
  assign fpsr_read_data = fpsr_state & FPSR_P7_WRMASK;
  assign cpacr_read_data = cpacr_el1_state;

  // 系统寄存器访问在 ID 级排空后提交；FPCR/FPSR 的写入不能绕过 FPEN。
  assign sys_fpcr_write_accept = sys_commit_valid && sys_fpcr_we &&
                                 fp_access_valid && fp_access_allowed &&
                                 !restore_any;
  assign sys_fpsr_write_accept = sys_commit_valid && sys_fpsr_we &&
                                 fp_access_valid && fp_access_allowed &&
                                 !restore_any;
  assign sys_cpacr_write_accept = sys_commit_valid && sys_cpacr_we &&
                                  (current_el == 2'd1) && !restore_any;
  assign sys_fp_access_blocked = sys_commit_valid &&
                                 (sys_fpcr_we || sys_fpsr_we) &&
                                 (!fp_access_valid || !fp_access_allowed);
  assign sys_cpacr_write_blocked = sys_commit_valid && sys_cpacr_we &&
                                   (current_el != 2'd1);

  assign restore_any = difftest_restore_fp_valid ||
                       difftest_restore_sys_valid;

  // FP effect 的 shape 是 RTL L1 检查边界：最多 4 个不同 V destination。
  // P7-0 不产生运算 effect，但保留完整 ABI 槽位，禁止上游静默截断。
  always_comb begin
    commit_shape_error = 1'b0;
    if (commit_vec_write_count > 3'd4) begin
      commit_shape_error = 1'b1;
    end
    if ((commit_vec_write_count > 3'd1) &&
        (commit_vec_rd0 == commit_vec_rd1)) begin
      commit_shape_error = 1'b1;
    end
    if ((commit_vec_write_count > 3'd2) &&
        ((commit_vec_rd0 == commit_vec_rd2) ||
         (commit_vec_rd1 == commit_vec_rd2))) begin
      commit_shape_error = 1'b1;
    end
    if ((commit_vec_write_count > 3'd3) &&
        ((commit_vec_rd0 == commit_vec_rd3) ||
         (commit_vec_rd1 == commit_vec_rd3) ||
         (commit_vec_rd2 == commit_vec_rd3))) begin
      commit_shape_error = 1'b1;
    end
  end

  assign commit_has_fp_effect = (commit_vec_write_count != 3'd0) ||
                                commit_fpcr_we || commit_fpsr_we;
  // 带 FP effect 的提交必须显式标记为 FP access，且权限已通过；纯 scalar
  // commit 在 FPEN 关闭时仍可正常通过，保持旧 PRE/COMMIT 兼容性。
  assign commit_fp_access_ok = !commit_has_fp_effect ||
                               (fp_access_valid && fp_access_allowed);
  assign commit_accept = commit_valid && !restore_any && !sys_commit_valid &&
                         !commit_shape_error && commit_fp_access_ok;

  assign commit_effect_valid = commit_accept && commit_has_fp_effect;
  assign commit_effect_error = commit_valid && !restore_any &&
                               !sys_commit_valid &&
                               (commit_shape_error || !commit_fp_access_ok);
  assign commit_effect_vec_write_count = commit_effect_valid
                                         ? commit_vec_write_count : 3'd0;
  assign commit_effect_vec_rd0 = commit_effect_valid ? commit_vec_rd0 : 5'd0;
  assign commit_effect_vec_rd1 = commit_effect_valid ? commit_vec_rd1 : 5'd0;
  assign commit_effect_vec_rd2 = commit_effect_valid ? commit_vec_rd2 : 5'd0;
  assign commit_effect_vec_rd3 = commit_effect_valid ? commit_vec_rd3 : 5'd0;
  assign commit_effect_vec_wdata0 = commit_effect_valid
                                    ? commit_vec_wdata0 : 128'd0;
  assign commit_effect_vec_wdata1 = commit_effect_valid
                                    ? commit_vec_wdata1 : 128'd0;
  assign commit_effect_vec_wdata2 = commit_effect_valid
                                    ? commit_vec_wdata2 : 128'd0;
  assign commit_effect_vec_wdata3 = commit_effect_valid
                                    ? commit_vec_wdata3 : 128'd0;
  assign commit_effect_fpcr_we = commit_effect_valid && commit_fpcr_we;
  assign commit_effect_fpcr_wdata = commit_effect_fpcr_we
                                    ? (commit_fpcr_wdata & FPCR_P7_WRMASK)
                                    : 32'd0;
  assign commit_effect_fpsr_we = commit_effect_valid && commit_fpsr_we;
  assign commit_effect_fpsr_wdata = commit_effect_fpsr_we
                                    ? (commit_fpsr_wdata & FPSR_P7_WRMASK)
                                    : 32'd0;

  integer i;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fpcr_state      <= 32'd0;
      fpsr_state      <= 32'd0;
      cpacr_el1_state <= 64'd0;
      for (i = 0; i < 32; i = i + 1) begin
        v_state[i] <= 128'd0;
      end
    end else if (restore_any) begin
      // Restore 是唯一的 full-state 外部写入口；优先级高于任何同拍输入。
      if (difftest_restore_fp_valid) begin
        fpcr_state <= difftest_restore_fpcr & FPCR_P7_WRMASK;
        fpsr_state <= difftest_restore_fpsr & FPSR_P7_WRMASK;
        for (i = 0; i < 32; i = i + 1) begin
          v_state[i] <= difftest_restore_v[i];
        end
      end
      if (difftest_restore_sys_valid) begin
        // CPACR 非 FPEN 位属于完整 scalar sys state，必须原样恢复。
        cpacr_el1_state <= difftest_restore_cpacr_el1;
      end
    end else if (sys_commit_valid) begin
      if (sys_fpcr_write_accept) begin
        fpcr_state <= sys_fpcr_wdata & FPCR_P7_WRMASK;
      end
      if (sys_fpsr_write_accept) begin
        fpsr_state <= sys_fpsr_wdata & FPSR_P7_WRMASK;
      end
      if (sys_cpacr_write_accept) begin
        cpacr_el1_state <= sys_cpacr_wdata;
      end
    end else if (commit_accept) begin
      if (commit_fpcr_we) begin
        fpcr_state <= commit_fpcr_wdata & FPCR_P7_WRMASK;
      end
      if (commit_fpsr_we) begin
        fpsr_state <= commit_fpsr_wdata & FPSR_P7_WRMASK;
      end
      if (commit_vec_write_count > 3'd0) begin
        v_state[commit_vec_rd0] <= commit_vec_wdata0;
      end
      if (commit_vec_write_count > 3'd1) begin
        v_state[commit_vec_rd1] <= commit_vec_wdata1;
      end
      if (commit_vec_write_count > 3'd2) begin
        v_state[commit_vec_rd2] <= commit_vec_wdata2;
      end
      if (commit_vec_write_count > 3'd3) begin
        v_state[commit_vec_rd3] <= commit_vec_wdata3;
      end
    end
  end

endmodule
