# vivado/scripts/query_zybo_board_part.tcl
#
# Query the installed Digilent board repository for Zybo Z7-20 board parts.
#
# Usage:
#   vivado -mode batch -source vivado/scripts/query_zybo_board_part.tcl \
#          -tclargs <board_files_path>

if {[llength $argv] > 0} {
    set board_repo [file normalize [lindex $argv 0]]
} else {
    set board_repo [file normalize "~/fpga/vivado-boards/new/board_files"]
}

puts "Board repository: ${board_repo}"

if {![file isdirectory $board_repo]} {
    puts "ERROR: Board repository path does not exist: ${board_repo}"
    exit 1
}

set_param board.repoPaths [list $board_repo]

set matches [get_board_parts *zybo*z7*20*]
if {[llength $matches] == 0} {
    puts "ERROR: No board parts matched *zybo*z7*20*"
    exit 2
}

puts "Matched board parts:"
foreach part $matches {
    puts "  $part"
}

exit 0
