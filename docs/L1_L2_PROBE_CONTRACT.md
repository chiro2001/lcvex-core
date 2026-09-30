# B4 L2→D-L1 probe/drain 契约

本文是 T-20260827-056 在 `cfa8b9a` 基线上的模块级契约，按已确认的
`contract_resolution` 实现。它只描述 `CORE_COUNT=1` 的 D-L1/L2 endpoint，
不代表多核 MESI、ACE/CHI、DMA 一致性或 SoC 已接通。

## Probe 请求和响应

`lcvex_l2_wb` 的 `L1_PROBE_ENABLE=1` 实例提供一条单 outstanding 的
`l1_probe_req/l1_probe_rsp` 通道。命令编码固定为：

| cmd | 含义 | D-L1 成功消费响应后的动作 |
| --- | --- | --- |
| 0 | lookup | 不改变 valid/tag/dirty/data |
| 1 | clean | dirty 清零，保留 valid/tag/data |
| 2 | invalidate | valid、dirty 清零 |
| 3 | clean+invalidate | 先完成 clean，再清 valid |

L2 在选择有效 victim、目标 line maintenance 前发起 probe；无效替换槽不需
probe。请求携带 line-aligned PA、`source_id` 和 `transaction_id`。D-L1 返回
line-aligned PA、`line_valid`、`dirty`、完整 64B raw data、`fault` 以及相同
身份字段。单核 owner/sharer 退化为 D-L1 的一位语义，只作为未来扩展边界。

响应 valid/字段在 `valid && !ready` 时保持。D-L1 的 probe response 是
metadata 的提交点：response 未被消费前禁止复用 tag、替换 line 或修改
valid/dirty/data。

## 脏响应和 fault

L2 看见 dirty response 后先把完整 raw line 锁存到独立 buffer，并向 PoC 发
8 个完整字节写 beat。所有 beat 成功前，L2 保持
`l1_probe_rsp_ready=0`，D-L1 因而继续持有旧 metadata。全部成功后 L2 才
释放 response ready，D-L1 才提交 clean/invalidate。任意 PoC fault 时 L2
使用 `l1_probe_rsp_abort=1` 消费被持有的 response；D-L1 保留原
valid/tag/dirty/data，L2 向当前 client 报 fault，后续可重试。

L2 选择 victim 时发 `lookup`，dirty 数据由 L2 下刷后才允许 refill；若 D-L1
没有 dirty owner，L2 才使用自己的 victim 副本。L2 maintenance 先 probe
D-L1，再按返回 raw line 更新/清理自身副本；不会把旧 L2 data 覆盖最新 D-L1
data。

## Checkpoint drain

`lcvex_l1_coherence` 固定实现以下顺序：

```text
checkpoint_quiesce
        ↓
D-L1 停止 core/PTW 新请求，逐行下刷本地 dirty line
        ↓ l1_drain_done
L2 drain_to_poc，逐行下刷所有 dirty line
        ↓ drain_ack_valid
checkpoint_ack_valid
```

D-L1 本地 drain 使用普通 8B write 请求把 dirty line 写入 L2；L2 在这段窗口
通过 `l1_probe_block` 避免对正在排空的 blocking D-L1 发起冲突 probe。L2 完成
全阵列 dirty scan 后才产生成功 ack。任一 fault/reset 都保留未完成 line，
不产生成功 ack 或 stale response；fault epoch 释放 quiesce 后可重新开始。

## 复位和范围

- 两级异步 active-low reset；reset 清 state、valid/dirty/tag、事务/响应寄存器，
  data RAM 只通过 valid 边界可见，不依赖复位大规模 data array。
- `l1_probe_rsp_abort` 是 L2→D-L1 的失败提交控制；只在 L2 已消费 dirty raw
  line 失败时置位，正常 lookup/clean/invalidate 成功路径为零。
- `CORE_COUNT=1`、单发射/单 outstanding、64B line、8×8B beat；不实现跨核
  owner/sharer 状态机、硬件一致 DMA、真实 AXI/EMIF 或 QEMU 接线。
