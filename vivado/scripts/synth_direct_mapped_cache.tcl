# vivado/scripts/synth_direct_mapped_cache.tcl
#
# Non-project Vivado synthesis smoke check for rtl/cache/direct_mapped_cache.sv.
#
# Usage:
#   vivado -mode batch -source vivado/scripts/synth_direct_mapped_cache.tcl \
#          -tclargs <fpga_part>

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ../..]]

if {[llength $argv] > 0} {
    set fpga_part [lindex $argv 0]
} else {
    set fpga_part "xc7z020clg400-1"
}

set build_dir  [file join $repo_root build/vivado]
set report_dir [file join $repo_root reports/synthesis]

file mkdir $build_dir
file mkdir $report_dir

read_verilog -sv \
    [file join $repo_root rtl/common/fluxcore_pkg.sv] \
    [file join $repo_root rtl/cache/direct_mapped_cache.sv]

synth_design -top direct_mapped_cache -part $fpga_part -mode out_of_context
create_clock -name clk -period 20.000 [get_ports clk]
report_utilization -file [file join $report_dir direct_mapped_cache_utilization_synth.rpt]
report_timing_summary -file [file join $report_dir direct_mapped_cache_timing_summary_synth.rpt]
write_checkpoint -force [file join $build_dir direct_mapped_cache_synth.dcp]

puts ""
puts "RESULT: direct_mapped_cache synthesis completed."
puts ""

exit 0
