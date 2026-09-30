# 工具链固定版本

工程只使用下表固定的版本组合；升级工具链必须单独提交并重新跑完整
回归。版本以 `env/environment.yml` 和本文件为准，`scripts/toolcheck.sh`
负责自动核对。

| 工具 | 固定版本 | 说明 |
| --- | --- | --- |
| Verilator | 5.050（2026-07-01） | conda-forge 构建，SystemVerilog 仿真 |
| Cocotb | 2.0.1 | Python 测试框架，配合 Verilator |
| Python | 3.12 | conda-forge |
| GNU Make | 4.4.1 | 构建入口 |
| QEMU | 11.1.0（2026-08-11） | 参考模型，见 `qemu/VERSION` |
| pytest | 8.3.5 | Cocotb 断言输出辅助（不参与核心固定） |
| AArch64 交叉编译器 | 待定（P2） | 裸机软件测试，当前为提示级 |

## 创建环境

```sh
conda env create -f env/environment.yml
conda activate lcvex
```

## 运行 P0 检查

```sh
make test          # toolcheck + lint + SV testbench + Cocotb smoke test
```

单独运行：

```sh
make toolcheck    # 版本核对
make compile      # RTL lint
make sim-sv       # SystemVerilog testbench
make sim-cocotb   # Cocotb smoke test
```

## 网络说明

本机对外网络操作（如克隆 QEMU）走 HTTP 代理 `http://localhost:14514`：

```sh
export http_proxy=http://localhost:14514
export https_proxy=http://localhost:14514
```

## 已知缺口

- `aarch64-none-elf-gcc` 尚未安装，P2（软件测试）前补齐并固定版本。
- QEMU 本地 fork 已克隆到 `../qemu`（tag `v11.1.0`），P1 起在 fork
  中实现 single-step hook。
