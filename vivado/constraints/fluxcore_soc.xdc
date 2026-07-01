## vivado/constraints/fluxcore_soc.xdc
##
## Zybo Z7-20 constraints for the standalone BRAM-backed FluxCore SoC.
##
## Board: Digilent Zybo Z7 Rev. B, compatible with Zybo Z7-20
## Part : xc7z020clg400-1
## Top  : fluxcore_soc
##
## Pin references come from Digilent's Zybo-Z7-Master.xdc:
##   sysclk -> K17
##   btn[0] -> K18

## ---------------------------------------------------------------------------
## Clock: Zybo Z7 system clock input on PL pin K17.
##
## The physical oscillator is 125 MHz on the board. FluxCore Stage 2 targets
## a conservative 50 MHz timing budget for implementation closure, so this
## constraint defines the analysis clock as 20 ns.
## ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN K17 IOSTANDARD LVCMOS33 } [get_ports { clk }]
create_clock -add -name fluxcore_clk -period 20.000 -waveform {0.000 10.000} [get_ports { clk }]

## ---------------------------------------------------------------------------
## Reset: use push-button 0 as an external active-high reset request.
## fluxcore_soc synchronizes it into the core clock domain, so the button input
## is intentionally not timed as a source-synchronous data path.
## ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN K18 IOSTANDARD LVCMOS33 } [get_ports { rst }]
set_input_delay -clock [get_clocks { fluxcore_clk }] 0.000 [get_ports { rst }]
set_false_path -from [get_ports { rst }]

## ---------------------------------------------------------------------------
## Debug visibility.
##
## fluxcore_soc keeps retirement and exception signals internal for this
## standalone synthesis milestone. The RTL already creates explicit dbg_* nets
## with keep/mark_debug attributes; this XDC mirrors that intent without
## broad DONT_TOUCH constraints on every retire/exception bus bit.
## ---------------------------------------------------------------------------
set_property DONT_TOUCH true [get_cells -quiet -hierarchical {u_cpu}]
set_property MARK_DEBUG true [get_nets -quiet -hierarchical -filter {NAME =~ *dbg_*}]
