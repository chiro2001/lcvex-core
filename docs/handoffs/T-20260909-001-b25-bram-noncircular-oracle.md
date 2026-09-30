# T-20260909-001：B25 BRAM 非循环 ELF-derived oracle 交接

~~~text
task=T-20260909-001 state=done
base=5e89563ba5e6577d6f81df5f08a19769fcada2ef
source_head_before_docs=5e89563ba5e6577d6f81df5f08a19769fcada2ef
branch=fix/T-20260909-001-b25-bram-noncircular-oracle
worktree=/home/chiro/projects/mycpu/lcvex-wt-T-20260909-001
sent_at=2026-09-09T00:28:09+08:00 received_at=2026-09-09T00:28:09+08:00
reported_at=2026-09-09T00:54:29+08:00
files=fpga/catapult_a10/boot/check_image_contract.py,fpga/catapult_a10/tools/run_bram_init25_test.sh,tb/sv/lcvex_bram_init25_tb.sv,docs/tasks/evidence/T-20260909-001.json,docs/handoffs/T-20260909-001-b25-bram-noncircular-oracle.md
tests=boot build + ELF-derived checker + 13 negative fixtures + resource-locked fresh Verilator TB
blockers=none in this task
next=integrator registers runner and reruns on combined T-007 candidate
evidence=docs/tasks/evidence/T-20260909-001.json
~~~

## 结论

B25 BRAM init test 已改为非循环 oracle。checker 从 ELF64 AArch64 的 PT_LOAD 和
symbols 独立构造精确 64 KiB expected byte-HEX，随后严格验证 BIN、HEX、MIF 和
expected/manifest hash；TB 只消费这个 expected 文件，不从 DUT、boot.hex 或
boot.mif 反推期望。

当前权威首 word 仍为 0x9100001f58001700。正向构建和 TB 通过，13 个故障注入均
在预期层失败。没有修改 RTL、boot.S/boot.ld/build.sh/bin_to_mif、QSF、共享
Makefile、test registry、QEMU 或任务状态文件。

## 实现

fpga/catapult_a10/boot/check_image_contract.py：

- 独立解析 ELF64 little-endian AArch64、entry=0、_start=0、__stack_top=0x10000；
- 从每个 PT_LOAD 复制 load bytes 到 64 KiB BRAM image，检查 BRAM 边界；
- 解码首条 LDR X0 literal 的 imm19/PC-relative target，并检查 target literal
  等于 __stack_top；
- 结构检查第二条 ADD XSP,X0,#0（MOV SP,X0）；
- 检查 boot.bin 等于 ELF PT_LOAD、boot.hex 等于 boot.bin；
- 检查 MIF WIDTH=64、DEPTH=8192、8192 条显式 record、little-endian lane 0
  和全零 padding；
- 生成 65536 条 expected byte-HEX，并用 canonical manifest SHA-256 绑定
  ELF/BIN/HEX/MIF/expected/source。

fpga/catapult_a10/tools/run_bram_init25_test.sh：

- task-local 重建 boot ELF/BIN/HEX/MIF；
- 先执行 checker --emit 和 --check，再用 -GBOOT_HEX_FILE、
  -GEXPECTED_IMAGE_FILE 编译 TB；
- 负向 fixture 只在 build/agents/T-20260909-001/** 内复制/篡改；
- 13 个故障都要求 checker 非零退出；
- Verilator compile/runtime 通过 resource-lock local、MemoryMax=16G、
  MemorySwapMax=0、VERILATOR_JOBS=1；
- 只有精确 BRAM_INIT25_TB PASS marker 且进程 exit 0 才报告通过。

tb/sv/lcvex_bram_init25_tb.sv：

- 新增 BOOT_HEX_FILE 和 EXPECTED_IMAGE_FILE 参数；
- 用 $readmemh 装载独立 expected byte image，并按地址拼装 debug 64-bit word；
- 保留 reset/debug 多 word、stack 全零、0xFFFC、0xFFFF、cross-boundary 和
  exclusive 0x10000 fault 检查；
- 不再硬编码 layout-dependent 0x...17c0。

## 验证结果

最终 fresh runner：

~~~text
command:
LCVEX_BRAM_INIT25_TEST_DIR=build/agents/T-20260909-001/final-run \
  bash fpga/catapult_a10/tools/run_bram_init25_test.sh
started_at=2026-09-09T00:53:56+08:00
finished_at=2026-09-09T00:54:07+08:00
exit_code=0
LCVEX_BOOT_BUILD_PASS
IMAGE_CONTRACT_PASS mode=emit
IMAGE_CONTRACT_PASS mode=check
NEGATIVE_SUMMARY pass=13 total=13
BRAM_INIT25_TB PASS
LCVEX_BRAM_INIT25_HEAVY_PASS
LCVEX_BRAM_INIT25_TEST_PASS
~~~

正向 artifact：

- boot.elf 68832 B，SHA-256
  618d66ee57e1206f71376478f9db714b135f61efaffc348cbc4ec6393c5b4231；
- boot.bin 957 B，SHA-256
  aa4a8bbe2a71affe281c8b60922ee27dfc0b2a99a7f645d5ed53767ff192f0c6；
- boot.hex 2871 B，SHA-256
  c3ce37d62c5dd92171a88484669e433ae311df8860cf72cc2bc54be518989ffa；
- boot.mif 204942 B，SHA-256
  614d4505f8a6836eeb73e92ff5f2ba43ed9e3be27df6ef450675e651db280cd7；
- ELF-derived expected byte-HEX 196608 B，decoded SHA-256
  7889fff7ca07867da8827cede9d0444ed306b7a2be42e2b2f934ec66be9b643b；
- final manifest field manifest_sha256=ed731c588379a2c665a98e305e2957c03182a6e0e6c61ff0659f13b6ca8a7be4。

ELF reset contract：

~~~text
PT_LOAD: vaddr=0, filesz=957, memsz=968
word0=0x58001700, imm19=184, target=0x2e0
literal[0x2e0]=0x0000000000010000 (__stack_top)
word1=0x9100001f (ADD XSP,X0,#0 / MOV SP,X0)
expected image=65536 bytes; zero pad=64579 bytes
~~~

故障注入矩阵：缺失 expected、错误 HEX path、reset byte、LDR imm19、MOV SP 字段、
BIN byte reverse、BIN word swap、HEX 单字节、HEX extra line、MIF lane、MIF duplicate
record、MIF nonzero padding、stale expected hash，全部 NEGATIVE_PASS。

Resource-lock 证据：

~~~text
resource-lock run local mycpu T-20260909-001 b25_boot_oracle
  --min-local-available-mib 8192
  --meta stage=bram-init25-verilator
  --meta source_sha=5e89563ba5e6577d6f81df5f08a19769fcada2ef
  --meta verilator_jobs=1
  -- systemd-run --user --scope -p MemoryMax=16G -p MemorySwapMax=0
  -- env TMPDIR=.../build/agents/T-20260909-001/final-run/tmp VERILATOR_JOBS=1 ...
compile max RSS=1472000 KiB
runtime max RSS=19088 KiB
Verilator reported compile allocated=27.562 MB
simulation finish=225 ns
postflight: local FREE; gamepc FREE
~~~

## 后续

集成者应在合并 T-007 candidate 后重新运行该 runner，并把 runner 注册到共享
Makefile/test registry；本任务不做该共享写入。每次 boot ELF 变化都必须重新生成
expected 和 manifest，不能复制 DUT 的 HEX/MIF 作为 oracle。详细命令、工具 hash、日志
hash、负向 fixture 和写集边界见任务 evidence：
docs/tasks/evidence/T-20260909-001.json。
