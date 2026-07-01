# vivado/scripts/check_environment.tcl
#
# Vivado batch-mode environment validation script.
#
# Confirms that Vivado starts and prints its version. Refuses to create a
# project or attempt synthesis when the board model is UNCONFIRMED.
#
# Usage (invoked by 'make vivado-check'):
#   vivado -mode batch -source vivado/scripts/check_environment.tcl \
#          -tclargs <BOARD_MODEL> -nolog -nojournal
#
# Arguments:
#   argv[0] — BOARD_MODEL (e.g. UNCONFIRMED, zybo-z7-10, zybo-z7-20)

# ---------------------------------------------------------------------------
# Version information
# ---------------------------------------------------------------------------
set vivado_version [version -short]
puts ""
puts "FluxCore — Vivado environment check"
puts "====================================="
puts "Vivado version : ${vivado_version}"

# ---------------------------------------------------------------------------
# Board model validation
# ---------------------------------------------------------------------------
if {[llength $argv] > 0} {
    set board_model [lindex $argv 0]
} else {
    set board_model "UNCONFIRMED"
}

puts "Board model    : ${board_model}"
puts ""

if {[string toupper $board_model] eq "UNCONFIRMED"} {
    puts "INFO: Board model is UNCONFIRMED."
    puts "      No project, block design, synthesis, or implementation will be attempted."
    puts "      Resolve the board model before running any Vivado flow."
    puts "      See config/board.example.mk and docs/decisions/0002-board-model-unconfirmed.md"
    puts ""
    puts "RESULT: Vivado startup validated successfully."
    puts "        Board-specific synthesis intentionally skipped (board unconfirmed)."
    puts ""
    # Exit cleanly — this is the expected state during early development.
    exit 0
}

# If a board model is provided, validate it is a known choice.
# We do NOT proceed to project creation here even for a known model;
# that step requires a separate explicit Makefile target.
set known_models {zybo-z7-10 zybo-z7-20}
if {[lsearch -exact $known_models $board_model] >= 0} {
    puts "INFO: Board model '${board_model}' is a recognized FluxCore target."
    puts "      No project created by this check script."
    puts "      Run the appropriate synthesis target when RTL is ready."
    puts ""
    puts "RESULT: Vivado startup validated successfully."
    puts "        Project creation intentionally skipped."
    puts ""
    exit 0
}

# Unknown board model: warn but do not fail — this check is for tool startup only.
puts "WARNING: Board model '${board_model}' is not a recognized FluxCore target."
puts "         Valid choices: [join $known_models {, }]"
puts "         No project created."
puts ""
puts "RESULT: Vivado startup validated successfully."
puts "        Board model not recognized; synthesis skipped."
puts ""
exit 0
