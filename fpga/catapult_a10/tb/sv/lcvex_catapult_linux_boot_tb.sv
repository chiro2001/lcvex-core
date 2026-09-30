`timescale 1ns/1ps

// Single integrated Linux smoke: BRAM loader -> EPCQ model -> DDR -> /init
// and JTAG-UART command input/output. The B25 monitor mode remains a separate
// default configuration in lcvex_catapult_soc_tb.
module lcvex_catapult_linux_boot_tb;
  lcvex_catapult_soc_tb #(
      .LINUX_BOOT_TEST(1'b1),
      .JTAG_VENDOR_TIMING(1'b1),
      .A64_FP_SIMD(1'b0),
      .BOOT_HEX_FILE("fpga/catapult_a10/boot/build/linux-loader/linux_loader.hex"),
      .FLASH_WORDS_MEMH("build/agents/T-20260928-002/linux-catapult/artifacts/flash_data.memh"),
      .FLASH_PAYLOAD_OFFSET(64'h0400_0000),
      .FLASH_LINE_CAPACITY(93_750),
      // Match the physical 128 MiB DDR aperture; 16 MiB leaves only a few MiB
      // after Linux reserves the kernel/initramfs and early SWIOTLB storage.
      .DDR_MODEL_DEPTH_WORDS(1 << 21),
      .LINUX_JTAG_LOG_BYTES(1 << 20),
      .LINUX_BOOT_TIMEOUT_CYCLES(2_000_000_000)
  ) linux_boot ();
endmodule
