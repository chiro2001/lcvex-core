# T-20260829-098 B5 V82 non-SVE profile freeze handoff

- 任务 ID：T-20260829-098（B5）
- 状态：review（owner 交付；等待集成者复核/冻结）
- 分支：`feature/T-20260829-098-b5-profile-freeze`
- worktree：`/home/chiro/projects/mycpu/lcvex-wt-T-20260829-088`
- base SHA：`62192862bfb51fbc32cd0ee45ef1c1f5a0bde444`
- sent_at：2026-08-29T13:20:00+0800（约）
- received_at：2026-08-29T13:25:00+0800（约）
- reported_at：2026-08-29T13:35:00+0800

## Freeze 摘要

V82 非 SVE Profile 已锁定为机器可检查清单：

| 状态 | 行数 |
| --- | --- |
| implemented | 94 |
| udef（保留/负测行） | 1 |
| blocked | 1 |
| deferred | 13 |
| shim | 8 |
| 合计 | 117 |

- 分类：V82-BASE 68、V82-SELECTED-EXT 28、V82-SVE-EXCLUDED 5、
  POST-V82-DEFERRED 16。
- 无明显“未知”混入已支持集合；每行都有 `status`、`negative`、`rtl`、
  `sv_tb`、`cocotb`、`qemu_oracle`。
- `EXT-FP-012`（标量 FP16 LDR/STR H）仍是唯一 blocked，明确不实现。
- `scripts/v82_profile_check.py` 与 `docs/V82_PROFILE_MANIFEST.md` 已同步，
  `--validate-manifest` 通过。

## 本次 Manifest/证据更新

- 将 B3 解码器级定向 TB 补入 relevant 行：
  - barrier：`lcvex_b3_sys_decode_tb.sv`
  - atomic/LSE：`lcvex_b3_atomic_barrier_tb.sv`
  - maintenance：`lcvex_b3_maint_decode_tb.sv`
  - system regs：`lcvex_b3_sysreg_access_tb.sv`
- 更新系统寄存器编码说明：包含 `CONTEXTIDR_EL1`、`OSLSR_EL1`、`OSLAR_EL1`
  的权限/reset 结论。
- 更新 manifest 元数据：
  - base_sha：`62192862bfb51fbc32cd0ee45ef1c1f5a0bde444`
  - branch：`feature/T-20260829-098-b5-profile-freeze`

## Profile row -> Evidence 映射

新增 `scripts/b5_profile_matrix.py`，读取 manifest 内嵌 JSON 并生成：

```text
build/coverage/b5_profile_matrix.json
```

该文件包含 117 行 `row_id/status/category/feature/encoding/negative` 以及
每行的 `rtl/sv_tb/cocotb/qemu_oracle` 证据来源；同时附上 B4 随机/裸机
聚合覆盖摘要。它不把未执行的 QEMU/Gate D 伪装成逐行执行证据。

## 验证结果

### B4 随机 / 裸机覆盖（引用）
- 随机 trace：seed 1–4，20,010 条提交
  - `expected_hit = 62/62`
  - `observed_families = 63`
  - 无未知助记符
- 裸机 C 反汇编：
  - `-O0`：37 个支持族
  - `-O2`：44 个
  - `-Os`：42 个
  - 合计看到 47 个支持族，未知助记符 0

### B5 本分支回归
```text
make compile
# PASS：Verilator Walltime 36.444s

python3 sim/difftest/check_encoders.py
# PASS：86 条

python3 scripts/v82_profile_check.py --validate-manifest
# OK

python3 sort_scripts... (manifest validation + free json)
# B5 profile matrix generated
```

### 未执行项
- 未跑完整 `make test`（受资源/时间限制）。
- 未跑 Gate D、P6/P7 checkpoint/max compatibility smoke。
- 未跑 Linux 长窗口。
- 未生成完整 QEMU sysreg inventory JSON。
- 未跑 Quartus。

## 依赖/环境锁定

- QEMU fork commit：`84f07211cc5b4fc6a371559bf8a5de4fb068e648`
- QEMU 版本：11.1.0
- QEMU patches：
  `0001..0012` 共 12 个（见 `qemu/patches/`）
- Plugin source sha256：
  `qemu/plugins/lcvex_difftest.c`
  `fb24cc183a497d8a3615283e0b74e095e82856105d86d354e6b3354326f9cb13`
- Plugin built sha256：
  `qemu/plugins/lcvex_difftest.so`
  `f5e7c61c20aafb9f280ffae16bdaa597adad7f2cc24327c5d90ec17ba24a2c6c`
- Protocol sha256:
  - `lcvex_protocol.h` `af62b3d8e4dd4625d958aef222303a97f3828b6c5cf8fb5d76c20ce94868b6b1`
  - `lcvex_protocol.py` `b93f14a5a9a45c7e2fe1ab0b2366bdf382dd2bd0dab7dcb5b11a2b91a08def22`
- RTL filelist sha256：`404108df9586747b6993e490fdda9d223112c0513041926f59d65cda499154c8`
- 配置：`-machine virt -cpu max -accel tcg,thread=single -icount shift=0,align=off,sleep=off`

## 剩余风险 / 剩余门

| 风险 | 状态 |
| --- | --- |
| Gate D 未跑 | B5 不能宣称完整功能性门禁 |
| CONTEXTIDR checkpoint sidecar v4 未做 | 已识别；恢复时 CONTEXTIDR 回 reset 0，需 T-097 全局任务 |
| `EXT-FP-012` scalar FP16 LDR/STR H | blocked，不实现 |
| 全量 QEMU sysreg inventory JSON | 未生成 |
| PMU、RCpc、其它 LSE128、DC CVADP、TLBI OS/RV/range | POST-V82-DEFERRED / 后置 |
| P6/P7 checkpoint/max 兼容 smoke | 未跑 |
| Linux 长窗口 | 未跑 |

## 下一步

1. 集成者在本分支 SHA 上复核 manifest 与 matrix；
2. 若进入最终 Gate，应在资源窗口补跑 `make test`、P6/P7 checkpoint 兼容 smoke
   与 Gate D；
3. 不要用本 handoff 代替 Gate D/正式晋级证据。
