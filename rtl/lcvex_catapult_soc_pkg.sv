// lcvex_catapult_soc_pkg.sv
// B5-SoC/Boot: Catapult A10 SoC 地址映射与平台常量。
//
// 首版地址图（AArch64 physical address，MMU 关闭时 core 直接使用）：
//   BRAM        0x0000_0000 .. 0x0000_FFFF  64 KiB 启动区（复位 PC=0）
//   DDR4        0x4000_0000 .. 0x47FF_FFFF  128 MiB 窗口（QEMU virt 基址）
//   JTAG-UART   0x0900_0000 .. 0x0900_0FFF  4 KiB，Avalon 从口桥
//   GICv2       0x0800_0000 .. 0x0802_0FFF  distributor/CPU interface
//   EPCQ CSR    0x0900_1000 .. 0x0900_1FFF  4 KiB，SFL CSR Avalon 从口桥
//   EPCQ MEM    0x0900_2000 .. 0x0900_2FFF  保留（B5 只接控制寄存器）
//   EPCQ READ   0x1000_0000 .. 0x17FF_FFFF  CPU window onto 128 MiB Flash
//   PLAT_STATUS 0x0900_3000 .. 0x0900_3FFF  校准门/版本状态寄存器
//   (其余地址回 fault)

`timescale 1ns/1ps

package lcvex_catapult_soc_pkg;

  /* verilator lint_off UNUSEDPARAM */

  localparam logic [63:0] SOC_BRAM_BASE     = 64'h0000_0000_0000_0000;
  // B25 fixed map: one 64 KiB M20K-resident image.  The top address is
  // exclusive; the linker reserves [0xF000,0x10000) for the stack.
  localparam logic [63:0] SOC_BRAM_TOP      = 64'h0000_0000_0001_0000;
  localparam logic [63:0] SOC_BRAM_STACK_BASE = 64'h0000_0000_0000_F000;
  localparam logic [63:0] SOC_BRAM_STACK_TOP  = SOC_BRAM_TOP;
  localparam logic [63:0] SOC_DDR_BASE      = 64'h0000_0000_4000_0000;
  localparam logic [63:0] SOC_DDR_TOP       = 64'h0000_0000_4800_0000;
  localparam logic [63:0] SOC_JTAG_UART_BASE = 64'h0000_0000_0900_0000;
  localparam logic [63:0] SOC_JTAG_UART_TOP  = 64'h0000_0000_0900_1000;
  localparam logic [63:0] SOC_GIC_BASE = 64'h0000_0000_0800_0000;
  localparam logic [63:0] SOC_GIC_TOP  = 64'h0000_0000_0802_1000;
  localparam logic [63:0] SOC_TIMER_HZ = 64'd25_000_000;
  localparam int          SOC_JTAG_UART_SPI = 1; // GIC INTID 32 + SPI index 1 = 33
  localparam logic [63:0] SOC_EPCQ_CSR_BASE  = 64'h0000_0000_0900_1000;
  localparam logic [63:0] SOC_EPCQ_CSR_TOP   = 64'h0000_0000_0900_2000;
  localparam logic [63:0] SOC_EPCQ_MEM_BASE  = 64'h0000_0000_0900_2000;
  localparam logic [63:0] SOC_EPCQ_MEM_TOP   = 64'h0000_0000_0900_3000;
  localparam logic [63:0] SOC_FLASH_BASE = 64'h0000_0000_1000_0000;
  localparam logic [63:0] SOC_FLASH_TOP  = 64'h0000_0000_1800_0000;
  localparam logic [63:0] SOC_PLAT_STATUS_BASE = 64'h0000_0000_0900_3000;
  localparam logic [63:0] SOC_PLAT_STATUS_TOP  = 64'h0000_0000_0900_4000;

  // PLAT_STATUS 寄存器位定义。
  localparam logic [7:0]  SOC_STATUS_VERSION      = 8'h01;
  localparam int          SOC_STATUS_CAL_READY_BIT = 0;
  localparam int          SOC_STATUS_CAL_FAILED_BIT = 1;
  localparam logic [11:0] SOC_STATUS_CAL_OFFSET = 12'h000;
  localparam logic [11:0] SOC_STATUS_JTAG_READ_COUNT_OFFSET = 12'h008;
  localparam logic [11:0] SOC_STATUS_JTAG_RX_EVENT_OFFSET = 12'h010;
  // T-20260920-013：只读 CPU-originated UART DATA RVALID response trace。
  localparam logic [11:0] SOC_STATUS_JTAG_BRIDGE_RSP_OFFSET = 12'h018;
  localparam logic [11:0] SOC_STATUS_JTAG_POC_RSP_OFFSET    = 12'h020;
  localparam logic [11:0] SOC_STATUS_JTAG_DMEM_RSP_OFFSET   = 12'h028;
  localparam logic [11:0] SOC_STATUS_JTAG_PATH_EVENTS_OFFSET = 12'h030;
  localparam logic [11:0] SOC_STATUS_JTAG_TX_EVENT_OFFSET  = 12'h038;
  // Read-only logic-clock cycle counter. Reset value is zero; it increments
  // once per lcvex_catapult_soc_status clk and is sampled atomically on read.
  localparam logic [11:0] SOC_STATUS_CYCLE_COUNT_OFFSET = 12'h040;
  localparam int          SOC_STATUS_JTAG_RX_SEEN_BIT = 8;

  // BRAM 启动 smoke marker（JTAG-UART 输出，裸机 boot.S 使用同一值）。
  localparam logic [31:0] SOC_BOOT_MARKER = 32'h4C43_5645;  // "LCVEX"
  localparam logic [31:0] SOC_DDR_MAGIC   = 32'hB007_C0DE;

  /* verilator lint_on UNUSEDPARAM */

endpackage
