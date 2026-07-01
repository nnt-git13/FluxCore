# vivado/scripts/bitstream_fluxcore_soc.tcl
#
# Non-project Vivado bitstream generation for the standalone BRAM-backed
# FluxCore SoC. Assumes vivado/scripts/impl_fluxcore_soc.tcl has generated
# build/vivado/fluxcore_soc_route.dcp.
#
# Usage:
#   vivado -mode batch -source vivado/scripts/bitstream_fluxcore_soc.tcl

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ../..]]

set build_dir  [file join $repo_root build/vivado]
set report_dir [file join $repo_root reports/implementation]
set route_dcp  [file join $build_dir fluxcore_soc_route.dcp]
set bit_file   [file join $build_dir fluxcore_soc.bit]

file mkdir $build_dir
file mkdir $report_dir

puts ""
puts "FluxCore Vivado bitstream"
puts "========================="
puts "Input DCP : $route_dcp"
puts "Bitstream : $bit_file"
puts "Reports   : $report_dir"
puts ""

if {![file exists $route_dcp]} {
    puts "ERROR: routed checkpoint not found: $route_dcp"
    puts "Run make vivado-impl first."
    exit 1
}

open_checkpoint $route_dcp

report_drc -file [file join $report_dir fluxcore_soc_drc_bitstream.rpt]
write_bitstream -force $bit_file

puts ""
puts "RESULT: Vivado bitstream completed."
puts "Report:"
puts "  [file join $report_dir fluxcore_soc_drc_bitstream.rpt]"
puts "Bitstream:"
puts "  $bit_file"
puts ""

exit 0
