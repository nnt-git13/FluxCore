# sim/questa/run_smoke.do
#
# Questa do-script for the infrastructure smoke test.
#
# This script is invoked by verification/scripts/run_questa_smoke.sh.
# The shell script sets the working directory to the repository root
# before launching vsim, so all paths here are repository-relative.
#
# Arguments passed from the shell script via -do:
#   None — paths are embedded from environment variables resolved by the
#   shell wrapper. This script is deliberately simple.

# Run the testbench in command-line mode and exit.
# The testbench calls $finish on success and $fatal on failure.
# vsim returns a nonzero exit code when $fatal is called.

run -all

# Propagate the simulation exit status to the shell.
quit -f
