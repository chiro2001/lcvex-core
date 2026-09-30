# T-20260928-003：Catapult Linux lite 软件输入

分支：`feature/T-20260928-003-catapult-linux-software`

worktree：`/home/chiro/projects/mycpu/lcvex-wt-T-20260928-003`

任务基线：`8d24b68ba2f8d4d22fdff95309d6be008a0ea7d8`；执行分支包含派发提交 `b14614d6`。

源码身份与 resource-lock labels 修复提交：`7cca1ae2e42b443862c0d2cf451173f9f6ddbd0e`。

`gen_init_cpio` KERNEL_OUT 路径修复提交：`d19103f91a7cd06ace7ea79999c58f685f77fe1b`。
模型：平台默认，未显式指定。

## 交付内容

- `configs/linux-catapult-lite.fragment` 为 AArch64、GIC、architected timer、Altera JTAG-UART 控制台和 initramfs 配置；保留无 libc、无 FP/NEON 的小型用户态路径。
- `fpga/catapult_a10/linux/catapult-a10.dts` 描述单核 CPU0、`0x40000000–0x47ffffff` DDR、GICv2、25 MHz architected timer 和 `altr,juart-1.0`。
- UART 使用 DATA `0x09000000`、CONTROL `+4`、SPI 1（INTID 33）、控制台 `ttyJ0`；Timer 节点以命名 PPI 14/11 对应 INTID 30/27。早期输出使用 Linux 6.6 驱动提供的 `juart` earlycon。核对到当前 SoC Avalon 桥按 `req.addr[2]` 区分 DATA/CONTROL，与驱动寄存器布局相符；本任务没有修改硬件地址或 RTL。
- `baremetal/linux-catapult/init.S` 使用 AArch64 整数指令和 Linux syscall，不链接 libc。它打开 `/dev/console` 并接到标准输入输出，支持 `help`、`echo [text]`、固定 1 秒 `sleep`、`about` 和未知命令回复。CR 与 LF 都能结束命令，CR 后的 LF 会被吞掉；超长行会拒绝执行。
- `fpga/catapult_a10/linux/tests/run_command_parser_test.sh` 在主机上以 `qemu-aarch64` 执行 `init.S` 中的实际命令解析和 CR/LF 状态机；同一入口也编译并静态链接完整 `/init`。
- `scripts/build-linux-catapult.sh` 接受 `--kernel-src`、`--out-root` 和 `--inputs-only`。source revision 只在 Git top-level 的物理路径与 `KERNEL_SRC` 完全相同时取自 `HEAD`；嵌套在 LCVEX checkout 下的 Linux source 使用 `KERNEL_SOURCE_ID`，未提供时记为 `no-git-metadata`。`--source-id-only` 可只读检查 source identity，不进入 Kconfig/build，也不创建输出。
- 构建入口从同一 source root 的 `usr/gen_init_cpio.c` 用 `${HOSTCC:-cc}` 编译 `$KERNEL_OUT/usr/gen_init_cpio`，initramfs 阶段只执行该 `KERNEL_OUT` 文件。`--gen-init-cpio-only` 可在独立输出根验证主机工具的生成和 `-h` 执行，不跑 Kconfig 或内核构建。
- 完整 Image 构建会先取得共享 `local` resource lock，并把 source revision、工具版本、配置、产物 SHA-256 及 lock labels 写进 manifest。lock labels 默认是 `T-20260928-003/linux_software`，集成构建可用 `RESOURCE_TASK_ID` 和 `RESOURCE_OWNER` 覆盖；`--resource-lock-identity-only` 只打印最终 labels 供轻量测试。

## 验证与复现

- `owner-l0-001-parser`：`fpga/catapult_a10/linux/tests/run_command_parser_test.sh`，通过；覆盖完整 `/init` AArch64 编译/链接、命令类型及 CR/LF 转换。
- `owner-l0-002-dtb`：用 `dtc -I dts -O dtb` 编译板级 DTS，通过；编译结果可用同一 `dtc -I dtb -O dts` 反汇编检查。
- `owner-l0-003-script`：`bash -n` 检查构建入口和三个测试脚本，通过。
- `owner-l0-007-source-identity`：合成嵌套非 Git source 仍能发现父级 LCVEX Git root，但构建脚本返回 `KERNEL_SOURCE_ID`/`no-git-metadata`；另验证独立 Git source 仍返回自身 SHA。未读取或构建共享 Linux source。
- `owner-l0-008-resource-lock-identity`：轻量验证默认 labels 与 `RESOURCE_TASK_ID=T-20260928-002 RESOURCE_OWNER=root` 覆盖值；没有获取锁或启动 full build。
- `owner-l0-009-gen-init-cpio-output`：只读使用 Linux 6.6 的 `usr/gen_init_cpio.c`，以主机 `cc` 编译到本 worktree 的临时 `KERNEL_OUT/usr/gen_init_cpio`，验证 executable、`-h` 和 full pipeline 的生成/消费路径，并记录 host binary SHA；没有生成共享内核输出或启动 Image build。
- 配置/镜像入口复现示例：

  ```sh
  scripts/build-linux-catapult.sh \
    --kernel-src /path/to/linux-6.6 \
    --out-root /path/to/output/linux-catapult-6.6 \
    --inputs-only
  ```

  `--inputs-only` 会完成 Linux 配置合并、`/init`、DTB 和 initramfs 输入；移除此选项会构建 `Image`，脚本自动申请 `local` 锁。集成者可在完整构建前设置 `RESOURCE_TASK_ID=T-20260928-002 RESOURCE_OWNER=root`。当前 worktree 没有 Linux 6.6 source tree，因此没有运行 Kconfig 合并或完整 Image 构建；仅 host-tool L0 只读了独立 source 的 `.c`，并将临时输出保留在本 worktree。见 evidence 中的 `owner-prereq-004-source-tree` 和 known limits。

## 边界与后续集成

- 本任务只提供软件输入，不代表当前板级 GIC SPI/Timer 接线、25 MHz `CNTFRQ_EL0`、Linux 启动或真板 UART 收发已经验证。平台集成应让设备树频率与硬件计数器保持一致。
- source identity L0 使用位于本 worktree 临时目录中的 synthetic nested source 和 synthetic standalone Git checkout。host-tool L0 从集成者的 `/home/chiro/projects/mycpu/lcvex/build/linux-6.6/usr/gen_init_cpio.c` 只读编译到本 worktree 的独立临时输出，未写入 shared kernel output。
- 参考 VexRiscv 文档记录过 `WSPACE=0` 与 UART IRQ 未注册问题；那不是当前 AArch64 SoC 的实测。当前目标仍使用计划中的 Altera JTAG-UART 协议，需在后续 SoC/板级启动验证中观察 Linux driver 的 TX/RX 与中断。
- 未运行 `dtbs_check`、Linux Image build、SoC Linux 仿真、Quartus、JTAG 或板级启动。
