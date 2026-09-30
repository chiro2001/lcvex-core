# B3-L2-WB：64B write-back L2

## 范围

`rtl/lcvex_l2_wb.sv` 是独立的、单发射单 outstanding、2-way 组相联 L2
模块。每条 cache line 为 64B，下游以 8 个 8B M1-B beat 传输；实现
write-back、write-allocate、partial-store merge、dirty victim 写回，以及
`CORE_COUNT=1` 的 probe/maintenance 客户端。模块不接 core、L1、SoC，也不加入
现有 `lcvex_l2_tb` 或 `rtl/filelist.f`。

## 提交和 fault 边界

- 读/写 miss 先把 refill 收入独立 `fill_buf`；最后一个 beat 成功后才在
  `ST_COMMIT` 发布 valid/tag，write miss 随后合并字节并置 dirty。
- dirty victim 的 8 个写回 beat 全部成功前保留原 valid/tag/dirty，不能复用
  victim tag。任一写回 fault 上抛 response，原行保持可重试。
- refill fault 不发布新 tag/valid；部分 `fill_buf` 数据不可见，下一次请求重新
  完整 refill。
- 写 hit 只修改 cache line 并置 dirty；写回只在替换、clean 或 global
  invalidate 时发生。

## 接口和维护

上游 `u_req/u_rsp`、下游 `d_req/d_rsp` 使用 `lcvex_pkg::mem_req_t/mem_rsp_t`。
下游每次请求固定一个 8B beat，写回使用 `strb=8'hff`。`probe` 命令为
lookup/clean/invalidate/clean+invalidate（0/1/2/3），响应保持 hit、dirty、
64B 数据、line 地址、source/transaction ID 以及 CORE_COUNT=1 的 owner/sharer。
核心侧支持 DC line maintenance、DC ZVA、TLBI 和 IC 全局 invalidate；global
invalidate 逐行排空 dirty 后再清 valid。

复位为异步 active-low：`state=ST_IDLE`，所有 valid/dirty/tag、事务寄存器、
响应 valid 和 probe 响应寄存器清零；数据阵列不复位，因 valid=0 时不可见。
架构可见的 metadata/data 变化只在 beat 完成后的状态提交点发生。未知 maintenance
返回 fault，旁路请求直接转发下游。

## Cache data RAM 实现

L2 data array 以一条 64B line 为一个 packed 512-bit RAM word，地址为
`set*WAYS+way`；逐字节 store/refill merge 使用 64-bit byte-enable。实现位于
`rtl/lcvex_cache_data_ram.sv`：Verilator 路径是同一时序契约的 packed-line
行为模型，`SYNTHESIS` 路径显式实例化 `altera_syncram`（`SINGLE_PORT`、
`WIDTH_A=512`、`WIDTH_BYTEENA_A=64`、`RAM_BLOCK_TYPE=M20K`）。同步读由
`ST_DATA_RD_REQ/ST_DATA_RD_WAIT` 锁存后再形成命中响应、写回 beat 或 probe
payload；写命中和提交阶段使用 masked line write。读写同址碰撞设为
`DONT_CARE`，控制器通过单阻塞状态机串行化，不依赖碰撞值。RAM data 不复位，
`valid/tag/dirty` metadata 是唯一可见性边界。

## 验证

- `tb/sv/lcvex_l2_wb_tb.sv` 使用独立 byte memory BFM、model memory、替换/响应
  计数和 fault retry 检查，覆盖 refill、write hit/miss、dirty eviction、probe
  clean/invalidate、DC maintenance、global invalidate、bypass、随机读写、
  writeback/refill fault 和 reset stale-response。RTL/bridge 含握手、响应 hold、
  dirty implies valid、probe ID 边界 SVA。
- `sim/cocotb/Makefile.l2_wb` 与 `test_l2_wb.py` 通过独立 wrapper 验证
  write-allocate、8-beat writeback、READY 背压、ID 回传和 writeback fault retry。

精确命令、版本、退出码和 artifact hash 见
[`docs/tasks/evidence/T-20260827-055.json`](tasks/evidence/T-20260827-055.json)。

## 已知限制

当前固定单核、单 outstanding、2-way 和 64B line；不实现多核一致性、并发请求、
真实 SRAM/AXI4、ECC、prefetch 或平台接线。BFM 是有限字节模型，不能替代 SoC/FPGA
和长程 Gate D。`lcvex_l2_wb.sv` 仍需集成者在后续阶段显式接入 L1/SoC。
