# config/board.example.mk — Example board configuration
#
# Copy this file to config/board.local.mk and fill in the confirmed values
# for your specific board.
# config/board.local.mk is git-ignored and must NOT be committed until the
# board model is confirmed and part strings are verified.
#
# Usage:
#   cp config/board.example.mk config/board.local.mk
#   # Edit config/board.local.mk with confirmed values
#
# ============================================================================
# IMPORTANT: Do NOT guess or invent part numbers, board part strings, or
# device strings. These values must come from the confirmed board definition
# file shipped with Vivado's board support package (BSP) or from the
# official Digilent board files repository.
#
# Using incorrect part strings produces misleading synthesis and timing
# results that may not correspond to the actual device.
# ============================================================================

# ---------------------------------------------------------------------------
# Board model selection
#
# Valid choices when confirmed:
#   Zybo Z7-10   — Zynq-7000 XC7Z010, smaller device
#   Zybo Z7-20   — Zynq-7000 XC7Z020, larger device (more LUTs and BRAMs)
#
# The choice affects:
#   - Available BRAM count
#   - Available LUT/FF resources
#   - DSP slice count
#   - Pin assignments and I/O bank voltages
#   - Timing constraints
#   - Board part string for Vivado IP integrator
#
# DO NOT set these to anything other than UNCONFIRMED until you have
# physically identified your board and cross-checked the part number.
# ---------------------------------------------------------------------------
BOARD_MODEL  := UNCONFIRMED
FPGA_PART    := UNCONFIRMED
BOARD_PART   := UNCONFIRMED

# ---------------------------------------------------------------------------
# What to fill in once confirmed
# ---------------------------------------------------------------------------
# For Zybo Z7-10 (example placeholders — verify against Digilent BSP):
#   BOARD_MODEL  := zybo-z7-10
#   FPGA_PART    := <verify from board support package>
#   BOARD_PART   := <verify from board support package>
#
# For Zybo Z7-20 (example placeholders — verify against Digilent BSP):
#   BOARD_MODEL  := zybo-z7-20
#   FPGA_PART    := <verify from board support package>
#   BOARD_PART   := <verify from board support package>
#
# Digilent board files are available at:
#   https://github.com/Digilent/vivado-boards
# Load the board repository into Vivado before committing any part string.
# ---------------------------------------------------------------------------
