# T-20260928-004：AArch64 Linux Flash payload 与 BRAM loader 交接

```text
task=T-20260928-004 state=review partial=false
base=8d24b68ba2f8d4d22fdff95309d6be008a0ea7d8
implementation=a2e314001a60a34fdd0d112e36d0fea012ca6329
tree=e2ad8d05aa6f566f680d680b5a174d1d71da9584
branch=feature/T-20260928-004-linux-flash-loader
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260928-004
model=not-explicitly-specified
sent_at=2026-09-28T00:15:41+08:00
received_at=2026-09-28T00:18:41+08:00
reported_at=2026-09-28T01:23:24+08:00
```

## 交付

提交 `a2e31400` 增加 AArch64 专用 payload 生成/校验器、共享布局 JSON、BRAM loader、独立构建脚本和 18 项 host tests。实现提交之后再次通过全部 host tests 和 loader 构建；精确命令、版本与 artifact hashes 见 [evidence JSON](../tasks/evidence/T-20260928-004.json)。

payload 的字段按小端编码，CRC 使用 CRC-32/ISO-HDLC。descriptor 固定为 40-byte header、两条 32-byte segment、8-byte trailer：

| BIN 相对位置 | 字段 | 语义 |
| --- | --- | --- |
| `0x00..0x27` | header | `LCVXARM!`、version、header/segment 宽度、段数、64-bit kernel entry、64-bit DTB 地址 |
| `0x28..0x67` | segment table | kernel 后接 DTB；每项为 64-bit 绝对 Flash byte offset、64-bit DDR 地址、64-bit长度、CRC32、kind |
| `0x68..0x6F` | trailer | 覆盖 header+segment table 的 CRC32 和零保留字 |
| `0x1000...` | payload data | 4 KiB 对齐的数据段；每段 CRC 覆盖完整 DDR load span |

等价的无填充 C 编码格式为 header `<8sIIIIQQ`，字段 offset 依次为 magic `0`、version `8`、header_size `12`、segment_count `16`、segment_size `20`、entry `24`、DTB `32`；每段 `<QQQII`，offset 依次为 flash_offset `0`、load_address `8`、length `16`、CRC32 `24`、kind `28`。kind `1=kernel`、`2=dtb`。trailer `<II` 位于 BIN offset `104`：CRC32 覆盖 `[0,104)`，reserved 必须为 0。C/RTL 解析时按这些固定 byte offset 读字段，避免 ABI struct padding。

主机打包入口示例：

```sh
python3 fpga/catapult_a10/boot/linux_image_format.py build \
  --layout fpga/catapult_a10/boot/linux_flash_layout.json \
  --image Image --dtb board.dtb \
  --bin flash_data.bin --hex flash_data.hex
```

loader 独立构建入口为 `fpga/catapult_a10/boot/build_linux_loader.sh`；输出不覆盖现有 `boot/build/boot.mif`。

descriptor 的 `flash_offset` 是从 EPCQL 芯片起点计的绝对 byte offset。BIN 和 Intel HEX 地址从 payload 起点的相对 offset 0 开始，所以：

```text
relative_segment_offset = descriptor.flash_offset - payload_offset
CPU_read_address        = aperture_base + descriptor.flash_offset
```

当前布局的 `aperture_base=0x10000000`、size `0x08000000`、`payload_offset=0x04000000` 都是候选值，不代表 CPU Flash aperture 已接入或已由硬件验证。若本次 map 改动，修改 `linux_flash_layout.json` 后重建 loader 常量和 payload。relative HEX 的 COF `hex_offset` 只加一次 payload offset；不要再把绝对芯片偏移写进 HEX 地址。

打包器读取 AArch64 Image 头的 `text_offset`、`image_size` 和 magic；内核按 `image_size` 补零后装载，使 descriptor 的 segment 范围也覆盖该内存占用。entry 为 `kernel_address + text_offset`。DTB 使用 FDT totalsize。外置 initramfs 不属于此格式，首版预期沿用内嵌 initramfs。

## BRAM 与平台接口

- `_start` 链接在 BRAM 地址 `0x00000000`。独立 Linux loader ELF/BIN/byte HEX/MIF 位于 ignored `fpga/catapult_a10/boot/build/linux-loader/`；构建检查 BIN 不超过 `0xF000` 字节，linker 另断言 image 不越过 `[0xF000,0x10000)` 栈区。MIF 为完整 `WIDTH=64, DEPTH=8192`，复用现有转换器逐字节读回校验。
- 这是 Linux 启动配置的替换镜像：不与现有 B25 `boot.S` monitor 或 CoreMark 合链；loader 自己保留 UART `p`/`?`/`r` 安全诊断 monitor。当前 QSF/top 仍选择原 monitor，尚未改 selector。
- Loader 进入时要求当前 EL 的 `SCTLR.M/C=0`，固定 CPU 地址才能当物理地址访问；否则报告 CPU context 错误并留在 monitor。Flash 只读 aperture 必须将 CPU `0x10000000 + byte_offset` 一对一映射到 EPCQL 相同 byte offset，返回 little-endian 数据，并支持 loader 的对齐 32-bit reads 与尾部 byte reads。
- 校准状态读取 `0x09003000`（bit 0 ready、bit 1 failed）；超时用只读 64-bit `0x09003040` 周期计数器和布局中的 750,000,000-cycle 限值。JTAG-UART 使用 DATA `0x09000000`、CONTROL `0x09000004`；DATA bit 15 为 RVALID、低 8 bit 为字符，CONTROL 高 16 bit 为 TX WSPACE。
- DDR contract 是 `[0x40000000,0x48000000)`。默认 kernel load base `0x40200000`、DTB 地址 `0x47000000`，均由布局文件生成/读取。DDR 写操作必须支持 32-bit 对齐访问和末尾 byte 写入；loader 会在复制后从目的区重新计算 CRC。
- CPU/RTL 侧需保证 Flash 读请求在 waitrequest/readdatavalid 协议下最终返回正确数据；loader 没有单次 Flash transaction 的软件超时。若 bridge 可能永久等待，应由 bridge 提供确定的完成或 fault 响应。
- Linux handoff 清 EL1 的 M/C/I，clean 两个 DDR 段、invalidate I-cache、执行 DSB/ISB、屏蔽 DAIF，最终进 non-secure EL1h；`x0=DTB`、`x1=x2=x3=0`、PC 为 Image entry。EL2 路径打开 EL1 physical counter/timer 访问并清零 `CNTVOFF_EL2`；EL3 路径先切到 non-secure EL2。

## 验证边界与后续

18 项 host tests 覆盖合法包、CRC known-answer、descriptor/segment checksum、Flash/DDR 越界与溢出、对齐、重叠、段顺序和 relative HEX 记录。AArch64 GNU 工具完成独立 assemble/link；ELF entry `0x0`，loader BIN 2,049 bytes，低于 61,440-byte image 上限；byte HEX 和 64 KiB MIF 均逐字节回读通过。

测试使用合成的最小 AArch64 Image/DTB fixture，没有真实 Linux Image/DTB 输入，也没有运行 loader 仿真、Quartus、JTAG、Flash 编程或 SoC bring-up。因此只能确认 host 格式和独立 AArch64 image 构建；Flash map、总线响应、DDR 访问及 Linux 冷启动仍由集成侧验证。loader 的首次 BRAM 选择需由平台集成者按实际 MIF/selector 接口完成。
