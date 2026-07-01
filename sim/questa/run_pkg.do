# sim/questa/run_pkg.do
#
# Questa do-script for the fluxcore_pkg unit test.
#
# Invoked by verification/scripts/run_questa_pkg.sh.
# The shell script sets the working directory to the repository root,
# so all paths encountered during simulation are repository-relative.
#
# The testbench (tb_fluxcore_pkg) uses $fatal on any mismatch and
# $finish on success. vsim returns a nonzero exit code on $fatal,
# which the shell script captures as a test failure.

run -all
quit -f
