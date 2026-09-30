# A2 SoC Stub/Tie-off Manifest

Task: T-20260829-081 (A2)
Scope: open-source elaboration proxy for `lcvex_catapult_soc_top`.

All files in this directory are **proxy/lint artifacts**. They are not part of
the Arria 10 Quartus project, do not replace Qsys/Quartus IP generation, and do
not represent an A10 or ECP5 signoff.

## Tie-off wrapper

- `fpga/opensynth/rtl/lcvex_catapult_soc_tieoff.sv`
  - Wraps the real `rtl/lcvex_catapult_soc_top.sv`.
  - Leaves `clk` and `rst_n` as harness inputs.
  - Ties all other external board/vendor-side inputs to inactive constants:
    - EMIF clocks/reset and calibration success/fail;
    - Avalon MM EMIF `waitrequest_n`, `readdata`, `readdatavalid`;
    - JTAG-UART `readdata`, `waitrequest`, `irq`;
    - EPCQ/SFL CSR `waitrequest`, `readdata`, `readdatavalid`;
    - BRAM program/debug write controls and addresses;
    - checkpoint quiesce/drain controls.

## Boundary stub

- `fpga/opensynth/rtl/lcvex_catapult_soc_stub_top.v`
  - Plain-Verilog mirror of the real SoC top port list (109 ports, 2627 port
    bits).
  - No real core/cache/coherence/SoC logic.
  - All outputs tied to inactive constants.
  - Used for the Yosys generic 4-LUT proxy and the optional ECP5 attempt.

## Unsupported / stubbed boundaries

| Boundary | Real provider | A2 handling |
| --- | --- | --- |
| DDR4 EMIF user port | Qsys EMIF / Arria 10 EMIF hard IP | Not modeled; tied off in wrapper; plain stub outputs inactive. |
| Avalon-MM 512-bit EMIF | Qsys EMIF | Stubbed at wrapper/stub boundary. |
| JTAG-UART | Altera Avalon JTAG-UART IP | Stubbed; wrapper ties slave responses off. |
| EPCQ/SFL CSR | Altera EPCQ/SFL IP | Stubbed; wrapper ties slave responses off. |
| EMIF calibration status | A10 EMIF calibration | Tied to `1'b0` (not ready) in wrapper. |
| External clocks/resets | Board A10 clock/reset + reset gate | Main `clk/rst_n` exposed; EMIF clock/reset and calibration tied off. |
| A10 PLL/SDC/Quartus constraints | Quartus/Qsys | Out of scope; no Fmax claim. |
| Direct Yosys full-SoC read | SystemVerilog packages/imports/unpacked arrays | Not supported by Yosys (see A0); no RTL modification made. |

## ECP5 note

- `nextpnr-ecp5` is available, but the boundary stub has **109 ports /
  2627 port bits**; the ECP5 LFE5U-85F has only 365 I/O cells. The A2 ECP5
  attempt stops at IO packing overflow. This is reported as N/A for Fmax.
- No Arria 10 Fmax or resource claim is made.
