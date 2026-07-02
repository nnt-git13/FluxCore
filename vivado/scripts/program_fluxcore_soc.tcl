# vivado/scripts/program_fluxcore_soc.tcl
#
# Program the generated bitstream onto a connected Zybo Z7-20 via the
# hardware manager (JTAG over the on-board USB).
#
# Usage:
#   vivado -mode batch -source vivado/scripts/program_fluxcore_soc.tcl
#   (or: make program-board)

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ../..]]
set bit_file   [file join $repo_root build/vivado/fluxcore_soc.bit]

if {![file exists $bit_file]} {
    puts "ERROR: bitstream not found: $bit_file"
    puts "Run: make vivado-synth SW_PROG=<prog> && make vivado-impl && make vivado-bitstream"
    exit 1
}

open_hw_manager
connect_hw_server
if {[llength [get_hw_targets -quiet]] == 0} {
    puts "ERROR: no JTAG target found. Is the Zybo connected and powered?"
    exit 1
}
open_hw_target

set dev [lindex [get_hw_devices xc7z020*] 0]
if {$dev eq ""} {
    puts "ERROR: no xc7z020 device on the JTAG chain."
    exit 1
}
current_hw_device $dev
set_property PROGRAM.FILE $bit_file $dev
program_hw_devices $dev
refresh_hw_device $dev

puts ""
puts "RESULT: bitstream programmed onto [get_property PART $dev]."
puts "Press BTN0 (K18) to reset the core; UART on PMOD JE1 @ 115200 8N1."
exit 0
