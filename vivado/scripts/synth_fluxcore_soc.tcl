# vivado/scripts/synth_fluxcore_soc.tcl
#
# Non-project Vivado synthesis flow for the standalone BRAM-backed FluxCore SoC.
#
# Usage:
#   vivado -mode batch -source vivado/scripts/synth_fluxcore_soc.tcl \
#          -tclargs <fpga_part>
#
# Example:
#   vivado -mode batch -source vivado/scripts/synth_fluxcore_soc.tcl \
#          -tclargs xc7z020clg400-1

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ../..]]

if {[llength $argv] > 0} {
    set fpga_part [lindex $argv 0]
} else {
    set fpga_part "xc7z020clg400-1"
}

set top_name   "fluxcore_soc"
set filelist   [file join $repo_root synth/fluxcore_soc.f]
set xdc_file   [file join $repo_root vivado/constraints/fluxcore_soc.xdc]
set build_dir  [file join $repo_root build/vivado]
set report_dir [file join $repo_root reports/synthesis]

file mkdir $build_dir
file mkdir $report_dir

puts ""
puts "FluxCore Vivado synthesis"
puts "========================="
puts "Top       : $top_name"
puts "Part      : $fpga_part"
puts "Filelist  : $filelist"
puts "XDC       : $xdc_file"
puts "Build dir : $build_dir"
puts "Reports   : $report_dir"
puts ""

if {![file exists $filelist]} {
    puts "ERROR: filelist not found: $filelist"
    exit 1
}

if {![file exists $xdc_file]} {
    puts "ERROR: XDC not found: $xdc_file"
    exit 1
}

set rtl_files {}
set fh [open $filelist r]
while {[gets $fh line] >= 0} {
    set line [string trim $line]
    if {$line eq ""} {
        continue
    }
    if {[string index $line 0] eq "#"} {
        continue
    }
    lappend rtl_files [file normalize [file join $repo_root $line]]
}
close $fh

puts "Reading [llength $rtl_files] RTL files..."
foreach rtl_file $rtl_files {
    if {![file exists $rtl_file]} {
        puts "ERROR: RTL file not found: $rtl_file"
        exit 1
    }
}

read_verilog -sv {*}$rtl_files

# Optional second tclarg: path to an imem.hex to bake into the BRAM so the
# bitstream boots straight into a program (make vivado-synth SW_PROG=<name>).
if {$argc >= 2} {
    set imem_hex [lindex $argv 1]
    if {![file exists $imem_hex]} {
        puts "ERROR: IMEM init file not found: $imem_hex"
        exit 1
    }
    puts "IMEM init: $imem_hex"
    synth_design -top $top_name -part $fpga_part -generic IMEM_INIT=$imem_hex
} else {
    puts "IMEM init: (none — zeroed instruction memory)"
    synth_design -top $top_name -part $fpga_part
}

# Read constraints after synthesis so MARK_DEBUG get_nets queries can match
# synthesized hierarchical nets.
read_xdc $xdc_file

check_timing -file [file join $report_dir fluxcore_soc_check_timing_synth.rpt]
report_utilization -file [file join $report_dir fluxcore_soc_utilization_synth.rpt]
report_timing_summary -file [file join $report_dir fluxcore_soc_timing_summary_synth.rpt]
write_checkpoint -force [file join $build_dir fluxcore_soc_synth.dcp]

puts ""
puts "RESULT: Vivado synthesis completed."
puts "Reports:"
puts "  [file join $report_dir fluxcore_soc_check_timing_synth.rpt]"
puts "  [file join $report_dir fluxcore_soc_utilization_synth.rpt]"
puts "  [file join $report_dir fluxcore_soc_timing_summary_synth.rpt]"
puts "Checkpoint:"
puts "  [file join $build_dir fluxcore_soc_synth.dcp]"
puts ""

exit 0
