# vivado/scripts/impl_fluxcore_soc.tcl
#
# Non-project Vivado implementation flow for the standalone BRAM-backed
# FluxCore SoC. Assumes vivado/scripts/synth_fluxcore_soc.tcl has already
# generated build/vivado/fluxcore_soc_synth.dcp.
#
# Usage:
#   vivado -mode batch -source vivado/scripts/impl_fluxcore_soc.tcl

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ../..]]

set build_dir  [file join $repo_root build/vivado]
set report_dir [file join $repo_root reports/implementation]
set synth_dcp  [file join $build_dir fluxcore_soc_synth.dcp]
set opt_dcp    [file join $build_dir fluxcore_soc_opt.dcp]
set place_dcp  [file join $build_dir fluxcore_soc_place.dcp]
set route_dcp  [file join $build_dir fluxcore_soc_route.dcp]

file mkdir $build_dir
file mkdir $report_dir

puts ""
puts "FluxCore Vivado implementation"
puts "=============================="
puts "Input DCP : $synth_dcp"
puts "Build dir : $build_dir"
puts "Reports   : $report_dir"
puts ""

if {![file exists $synth_dcp]} {
    puts "ERROR: synthesized checkpoint not found: $synth_dcp"
    puts "Run make vivado-synth first."
    exit 1
}

open_checkpoint $synth_dcp

opt_design
write_checkpoint -force $opt_dcp
report_utilization -file [file join $report_dir fluxcore_soc_utilization_opt.rpt]
report_timing_summary -file [file join $report_dir fluxcore_soc_timing_summary_opt.rpt]

place_design
write_checkpoint -force $place_dcp
report_utilization -file [file join $report_dir fluxcore_soc_utilization_place.rpt]
report_timing_summary -file [file join $report_dir fluxcore_soc_timing_summary_place.rpt]

route_design
write_checkpoint -force $route_dcp
check_timing -file [file join $report_dir fluxcore_soc_check_timing_route.rpt]
report_utilization -file [file join $report_dir fluxcore_soc_utilization_route.rpt]
report_timing_summary -file [file join $report_dir fluxcore_soc_timing_summary_route.rpt]
report_route_status -file [file join $report_dir fluxcore_soc_route_status.rpt]

puts ""
puts "RESULT: Vivado implementation completed."
puts "Reports:"
puts "  [file join $report_dir fluxcore_soc_check_timing_route.rpt]"
puts "  [file join $report_dir fluxcore_soc_utilization_route.rpt]"
puts "  [file join $report_dir fluxcore_soc_timing_summary_route.rpt]"
puts "  [file join $report_dir fluxcore_soc_route_status.rpt]"
puts "Checkpoint:"
puts "  $route_dcp"
puts ""

exit 0
