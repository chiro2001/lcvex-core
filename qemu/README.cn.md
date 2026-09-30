# QEMU 本地 fork 与补丁管理

QEMU 修改保存在本仓库之外的本地 fork：`../qemu`（相对本仓库根目录）。
lcvex 仓库只跟踪补丁本身，不跟踪 QEMU 源码或构建产物。

- 固定版本：见 `VERSION`（当前 QEMU 11.1.0，git tag `v11.1.0`，
  commit `84f07211cc5b4fc6a371559bf8a5de4fb068e648`）。
- 补丁目录：`patches/`，按文件名顺序应用。
- 重放脚本：`scripts/apply-patches.sh`。

## 首次建立 fork

```sh
qemu/scripts/apply-patches.sh
```

脚本会：

1. 在 `../qemu` 克隆 `VERSION` 中固定的 tag（已存在则 fetch 并 checkout）。
2. 校验 HEAD 与 `QEMU_COMMIT` 一致。
3. 依次用 `git apply` 重放 `patches/` 中的补丁。

## 修改流程

1. 在 `../qemu` 修改代码并测试。
2. 用 `git -C ../qemu format-patch` 导出补丁到 `patches/`。
3. 在 lcvex 仓库提交补丁，注明 QEMU release 与差分测试结果。
4. 升级 QEMU release 时必须单独建分支并重新跑完整差分回归。

## 规则

- 不使用 master；只使用 `VERSION` 中固定的 release tag。
- 补丁必须能干净地 `git apply` 到固定版本。
- 不在 lcvex 仓库内提交 QEMU 源码或构建产物。

## 差分导出插件（P1）

P1 的 QEMU 状态导出用官方 TCG 插件实现，不改 QEMU 源码：

- 插件源码：`../lcvex/qemu/plugins/lcvex_difftest.c`（仓库内）。
- 编译：`make -C qemu/plugins`（需要 `../qemu/build` 与 glib 头文件）。
- 运行：`make difftest`。
- 格式与限制：见 `docs/DIFFTEST.md`。

实时锁步扩展的设计见仓库中的
`docs/DIFFTEST_QEMU_PLAN.md`：P2 计划让该插件通过 Unix
`SOCK_SEQPACKET` 连接独立的 Verilator C++ 协调器。

fork 内钩子（`patches/`）保留给 P4：插件 API 没有异常回调，同步异常
的状态导出需要修改 QEMU 并在 `qemu/patches/` 以补丁管理。
