# Yosys Synthesis (Optional)

Yosys is an optional open-source logic synthesis tool. It is useful for:

- Rapid generic synthesis during early RTL development.
- Structural elaboration checks before committing to a Vivado run.
- Technology-independent area estimation.
- Formal verification preparation (when combined with tools like SymbiYosys).

## Role in the FluxCore Flow

Yosys is **not** the authoritative FPGA implementation tool for FluxCore.

**Vivado remains the required tool** for all Zybo Z7 synthesis, place-and-route,
bitstream generation, and timing closure. The Zynq Processing System (PS) block,
Xilinx BRAM primitives, and other vendor IP are not reliably supported by
generic Yosys flows.

Yosys results (area, gate count, structural warnings) may be used for early
guidance, but they **must not be presented as Zybo Z7 resource utilization** or
substituted for Vivado reports.

## Limitations

- Vendor IP (BRAM, MMCM, IBUF, etc.) requires Vivado.
- Zynq PS configuration and AXI interconnect require Vivado IP Integrator.
- Timing analysis for the Zybo Z7 fabric requires Vivado implementation reports.
- No Yosys synthesis script is provided yet because no FluxCore RTL exists.

## Future Use

When FluxCore RTL development begins, a Yosys synthesis script may be added
at `synth/yosys/synth_fluxcore.ys` for quick generic elaboration checks. This
script will not produce a bitstream and will not replace the Vivado flow.

Check `make yosys-check` to confirm whether Yosys is installed.
