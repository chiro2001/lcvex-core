# T-20260826-008：Gate E 冻结候选评审交接

日期：2026-08-26（Asia/Shanghai）  
评审模型：`gpt-5.6-sol[high]`  
证据：[T-20260826-008.json](../tasks/evidence/T-20260826-008.json)

## 结论

Gate E 当前不能标记通过。T-006/T-007 已证明固定 QEMU、strict manifest、
coordinator/plugin/RTL 组合下 lite/main 连续锁步到 global 16,509,999，
并具备递归 checkpoint provenance；但这还没有在同一冻结 candidate 上完成
Gate D/CI 证据闭环，也没有把 early-boot 和 EL0 `/init` 稳定用户态判据定义并
实证到阶段门要求。

## 冻结 candidate 必须补齐

1. 从 candidate SHA 建 detached gate worktree，完整执行 `run_gate_d.sh`，记录
   覆盖率、SVA、随机/延迟、裸机 C、QEMU 差分、QEMU patch replay 和资源。
2. 同一 SHA 通过可信 CI fast/difftest 任务；缺失覆盖必须明确列为限制。
3. 固定 Image/DTB/CPU/machine/icount、QEMU 11.1.0、plugin/coordinator/filelist
   摘要；fresh root 与 continuation 均到达确定 early-boot 里程碑。
4. 若 P6 退出定义包含用户态，须证明 EL0 进入、`/init`（或等价 init）执行，
   并在规定窗口重复通过；早期串口文本或动态指令数不能替代该判据。
5. 分类 mismatch、输入/manifest 错误、PSCI reset/off、WFI/Timer/GIC 等待
   超时和资源超限；失败点之后的指令不计入通过。

## P7 入口顺序

Gate E candidate 冻结后，P7 依次实现 FPCR/FPSR 语义、标量 FP32/FP64、NEON
128 位整数/移动/逻辑/移位/访存、选定 NEON 浮点/转换/异常；每层保持 scalar
commit packet 不变，并加入定向、随机和 QEMU 差分测试。未完成 Gate E 不进入
P7 功能实现。

## 当前边界

本任务只冻结验收口径和文档，不修改 RTL/QEMU、不启动重型仿真；下一任务应按
上述清单建立 Gate D/CI candidate，而不是直接把当前 Linux 长窗口写成阶段门。
