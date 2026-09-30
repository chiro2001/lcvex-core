# T-20260920-016：B25 RX CPU observability no-FP profile 交接

```text
task=T-20260920-016
state=done
base=17d8d6f2a4bbd560b7d3985ce0a4102e2039c92b
base_tree=49ae77b46bac077d68cd5432a09eb64b51b07ebb
profile=e91d20f15244e425fefaadeca8654fdfa1ebebc6
profile_tree=0f4110efbb8fbbc4ea51c147f6ff89e6cb27e2c7
received_at=2026-09-20T10:02:31+08:00
reported_at=2026-09-20T10:11:58+08:00
```

## 实现边界

相对冻结 candidate 只修改一个 functional file、一个参数行：

```text
fpga/catapult_a10/rtl/lcvex_catapult_a10_top.sv
A64_FP_SIMD = 1'b1 -> 1'b0
```

提交：`e91d20f15244e425fefaadeca8654fdfa1ebebc6`。

没有修改 response observer、firmware、SoC RTL、M20K、QSF、SDC、测试、QEMU 或
reference/expected 文件。该 profile 只证明 scalar bring-up，不代表 full-FP/P7 release。

## Image 与等价边界

当前 profile 使用同一份 2011-byte boot image：

```text
boot.bin 96f1b8484b30c33adac0a1562b897647a1f937cd4ac64539bad687538d19ad79
boot.hex e6649fb2a0a162a2e2bc1d213a4c116d0769c853309ff859ac60739e050f0c8a
boot.mif e6de0c384489e6a31dc519b20f41cbefa8f3145e0f14872ecf39a9df1e11eaff
```

T-012 r4 的 response trace/full-SoC 输入严格等价证明通过：共 33 个 filelist input
没有差异，`filelist_soc.f` 和 `filelist_rx_response_trace.f` 均不包含 board-top。
因此沿用 T-012 r4 的 response trace 与 vendor full-SoC evidence 是严格 equivalence，
不是未经证明的结果复制。

## 轻量验证

- boot build、ELF-derived image contract emit/check：PASS；MIF `WIDTH=64,
  DEPTH=8192,
  records=8192`。
- board skeleton Verilator lint：PASS。
- `check_platform.py`：PASS，50 files。
- `check_synthesis_selector.py`：PASS。
- explicit `-GA64_FP_SIMD=0` SoC Verilator lint：PASS。
- corrected M20K timing test：PASS。
- vendor focused/status/observer/bridge：PASS。
- 所有 Verilator 任务均通过 local resource-lock，`VERILATOR_JOBS=1`，最低可用内存门槛
  8192 MiB。

`check_skeleton.py` 未作为 profile acceptance：它绑定 full-FP 的固定
`skeleton_manifest.json` 和默认 boot/build 目录，会因有意的 board-top hash 差异及 task
local image 路径失败；按写集限制不能修改该 manifest。profile 的 board lint、platform
checker、image contract 和 explicit no-FP SoC lint 已覆盖实际受影响边界。

精确 log/hash 见 [`T-20260920-016.json`](../tasks/evidence/T-20260920-016.json)。

## 下一步

T-017 可以使用且只能使用 profile SHA/tree，在全新 GamePC root 上执行：

```text
fresh source staging -> Quartus synthesis -> fitter -> signoff STA
-> FIFO/data-delay/UCP/reset custom gates
```

必须取得 `gamepc` 锁，Quartus 最大 16/24 processors，保留 8192 MiB runtime safety
floor；不能复用旧 `05ea2488`/T-007 fitted DB 或 T-010 SOF。physical 全部通过后再另立
assembler task，只从 T-017 fresh fitted DB 生成唯一 SOF；本任务不包含 GamePC、Quartus、
assembler、JTAG、Flash、reset 或 power 行为。
