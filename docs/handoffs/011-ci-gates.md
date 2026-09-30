# LCVEX 交接文档 011：CI 门禁与 QEMU patch 重放落地

日期：2026-08-23（Asia/Shanghai）
前置：handoff 010（M1 完成）、PROJECT_STATUS“回归与 CI 建议分层”。
提交：`3f24948`（infra/full-regression-ci）。

## 1. 落地内容

### qemu/scripts/apply-patches.sh（重写）

- 不再 `git checkout -f` 丢改动：fork HEAD 与固定版本不一致时默认拒绝，
  `--force` 显式才切换。
- 幂等：已应用补丁经 `git apply --reverse --check` 识别后跳过；正放失败
  且回退失败才报冲突。
- `--fresh DIR`：克隆固定 release 到临时目录并重放（CI 干净重放任务）。

### 门禁脚本（本地与 CI 共用，日志落 build/ci-*/）

- `scripts/ci-fast.sh`（PR-fast，无 QEMU）：toolcheck / lint / SV smoke /
  背压 / memif / Cocotb ALU+regfile+背压。
- `scripts/ci-difftest.sh`（PR-difftest）：P1/P2 trace、lockstep 36、
  hazard、p4c、p5a、p5a-hardening、q6、短随机 seed 7 × 20k。
- `scripts/ci-nightly.sh`（nightly）：5 seed × 100k、
  `MEM_DELAY_MODE=2` 随机延迟锁步（MMU/异常组）、干净 QEMU release
  patch 重放。
- `scripts/build-qemu.sh`：固定版本 QEMU 构建（aarch64-softmmu +
  plugins，幂等）。

### GitHub Actions（.github/workflows/ci.yml）

- pr-fast / pr-difftest / nightly 三 job；nightly 带 cron。
- QEMU fork 按 `QEMU_COMMIT` + `qemu/patches/*.patch` 哈希缓存。
- 每 job 上传门禁日志 artifact，Gate 状态可链接具体 run/摘要。

## 2. 本地实跑结果

- `ci-fast.sh`：8/8 通过。
- `ci-difftest.sh`：8/8 通过。
- `ci-nightly.sh`：5×100k + 5 组随机延迟锁步 + patch 重放全通过。
- 干净重放验证：`apply-patches.sh --fresh` 在 v11.1.0 上应用 1 个补丁
  （cpu-exec-common.c / qemu-plugin.h / target/arm/helper.c）。

## 3. 下一步

任务 5：`feature/p5b-l1-cache`（M2）。按 PROJECT_STATUS M2 模块化边界：
cache line SRAM/tag 单元测试 -> I-L1 -> D-L1 -> 统一 L2 ->
maintenance/barrier（ISB 冲刷重取、DMB/DSB 等待未完成访问）。建议
第一版：I/D L1 各 4 KiB、64 B line、直接映射、写通+no-write-allocate，
D-L1 优先写通降低精确 Store 复杂度。P5b 进入“进行中”前还需关闭
R1 遗留（TLBI 一致性、ESR/FAR 完整 syndrome、块描述符）。
