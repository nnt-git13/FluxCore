// rtl/peripherals/clint.sv
//
// Core-Local Interruptor — single-hart, Spike-compatible register layout so
// the same offsets work under riscv-arch-test/RISCOF with the Spike
// reference model.
//
// Register map (byte offsets from base 0x0200_0000):
//   +0x0000  msip      (RW) bit0 = machine software interrupt
//   +0x4000  mtimecmp  (RW) low 32 bits
//   +0x4004  mtimecmph (RW) high 32 bits
//   +0xBFF8  mtime     (RW) low 32 bits
//   +0xBFFC  mtimeh    (RW) high 32 bits
//
// mtime increments every core clock cycle (tick == clk; documented CPI-exact
// timebase for this BRAM SoC).  mtip is level-sensitive:
//   mtip = (mtime >= mtimecmp), cleared by writing mtimecmp above mtime.
// mtimecmp resets to all-ones so no timer interrupt fires before software
// arms it.
//
// Read timing matches BRAM: rdata registered at end of MEM, consumed in WB.

`default_nettype none

module clint (
    input  wire logic        clk,
    input  wire logic        rst,

    input  wire logic        sel_i,
    input  wire logic [15:0] addr_i,     // byte offset within the 64 KiB window
    input  wire logic        wen_i,
    input  wire logic [31:0] wdata_i,
    output logic [31:0]      rdata_o,

    output logic             mtip_o,     // machine timer interrupt pending
    output logic             msip_o,     // machine software interrupt pending
    output logic [63:0]      mtime_o     // for the core's time/timeh CSRs
);

    localparam logic [15:0] OFF_MSIP      = 16'h0000;
    localparam logic [15:0] OFF_MTIMECMP  = 16'h4000;
    localparam logic [15:0] OFF_MTIMECMPH = 16'h4004;
    localparam logic [15:0] OFF_MTIME     = 16'hBFF8;
    localparam logic [15:0] OFF_MTIMEH    = 16'hBFFC;

    logic        msip_q;
    logic [63:0] mtimecmp_q;
    logic [63:0] mtime_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            msip_q     <= 1'b0;
            mtimecmp_q <= '1;      // no timer IRQ until software arms it
            mtime_q    <= '0;
        end else begin
            mtime_q <= mtime_q + 64'd1;
            if (sel_i & wen_i) begin
                case (addr_i)
                    OFF_MSIP:      msip_q            <= wdata_i[0];
                    OFF_MTIMECMP:  mtimecmp_q[31:0]  <= wdata_i;
                    OFF_MTIMECMPH: mtimecmp_q[63:32] <= wdata_i;
                    OFF_MTIME:     mtime_q[31:0]     <= wdata_i;
                    OFF_MTIMEH:    mtime_q[63:32]    <= wdata_i;
                    default: ;
                endcase
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst)
            rdata_o <= '0;
        else if (sel_i) begin
            case (addr_i)
                OFF_MSIP:      rdata_o <= {31'b0, msip_q};
                OFF_MTIMECMP:  rdata_o <= mtimecmp_q[31:0];
                OFF_MTIMECMPH: rdata_o <= mtimecmp_q[63:32];
                OFF_MTIME:     rdata_o <= mtime_q[31:0];
                OFF_MTIMEH:    rdata_o <= mtime_q[63:32];
                default:       rdata_o <= '0;
            endcase
        end
    end

    assign mtip_o  = (mtime_q >= mtimecmp_q);
    assign msip_o  = msip_q;
    assign mtime_o = mtime_q;

endmodule : clint

`default_nettype wire
