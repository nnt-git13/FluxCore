// verification/riscof/fluxcore/tb_riscof.sv
//
// RISCOF DUT harness: fluxcore_top + flat word memories, driven per test by
// plusargs (one xelab snapshot, one xsim run per test):
//
//   +hex=<file>   $readmemh image (single 64 KiB image serves both ports:
//                 text is fetched from the imem view, data read/written via
//                 the dmem view — the Harvard split of the real SoC without
//                 needing two extractions)
//   +sigb=<addr>  begin_signature byte address (0x80xx_xxxx; the
//                 [21:2] slice aliases into the 4 MiB array)
//   +sige=<addr>  end_signature byte address
//   +sig=<file>   signature output (one 32-bit lowercase hex word per line)
//   +timeout=<n>  cycle limit (default 2,000,000)
//
// Halt: the test's RVMODEL_HALT stores 0xD0E0D0E0 to 0x0000_FFFC.

`timescale 1ns/1ps
`default_nettype none

import fluxcore_pkg::*;
import rv32_isa_pkg::*;
import pipeline_pkg::*;

module tb_riscof;

    logic clk = 0;
    logic rst = 1;
    always #5 clk = ~clk;

    word_t             imem_addr, imem_addr_next;
    instr_t            imem_rdata;
    word_t             dmem_addr, dmem_wdata, dmem_rdata;
    logic              dmem_wen, dmem_ren;
    logic [3:0]        dmem_wstrb;
    retirement_event_t retire;
    exception_meta_t   exc;
    word_t             exc_pc;

    fluxcore_top #(
        .RESET_VECTOR(32'h8000_0000),
        .TRAP_VECTOR (32'h8000_0000)
    ) dut (
        .clk           (clk),
        .rst           (rst),
        .imem_addr_o      (imem_addr),
        .imem_addr_next_o (imem_addr_next),
        .imem_rdata_i     (imem_rdata),
        .dmem_addr_o      (dmem_addr),
        .dmem_wen_o    (dmem_wen),
        .dmem_wstrb_o  (dmem_wstrb),
        .dmem_wdata_o  (dmem_wdata),
        .dmem_rdata_i  (dmem_rdata),
        .dmem_ren_o    (dmem_ren),
        .dmem_stall_i  (1'b0),
        .retire_o      (retire),
        .exception_o   (exc),
        .exception_pc_o(exc_pc)
    );

    // 4 MiB unified image, two views (imem combinational, dmem BRAM-timing).
    // Sized for the largest arch tests (jal-01: 1.7 MB of text).
    word_t mem [0:1048575];

    assign imem_rdata = mem[imem_addr[21:2]];

    always_ff @(posedge clk) begin
        if (dmem_wen) begin
            if (dmem_wstrb[0]) mem[dmem_addr[21:2]][7:0]   <= dmem_wdata[7:0];
            if (dmem_wstrb[1]) mem[dmem_addr[21:2]][15:8]  <= dmem_wdata[15:8];
            if (dmem_wstrb[2]) mem[dmem_addr[21:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_wstrb[3]) mem[dmem_addr[21:2]][31:24] <= dmem_wdata[31:24];
        end
        dmem_rdata <= mem[dmem_addr[21:2]];
    end

    // Halt watch
    logic done = 0;
    always_ff @(posedge clk)
        if (!rst && dmem_wen && dmem_wstrb == 4'hF
            && dmem_addr == 32'h803F_FFFC && dmem_wdata == 32'hD0E0_D0E0)
            done <= 1'b1;

    string       hex_f, sig_f;
    int unsigned sigb, sige, cyc_limit;
    int unsigned cyc = 0;
    always_ff @(posedge clk) if (!rst) cyc <= cyc + 1;

    initial begin
        int fd;
        if (!$value$plusargs("hex=%s", hex_f))
            $fatal(1, "[RISCOF-TB] missing +hex=");
        if (!$value$plusargs("sig=%s", sig_f))
            $fatal(1, "[RISCOF-TB] missing +sig=");
        if (!$value$plusargs("sigb=%h", sigb)) sigb = 0;
        if (!$value$plusargs("sige=%h", sige)) sige = 0;
        if (!$value$plusargs("timeout=%d", cyc_limit)) cyc_limit = 2_000_000;

        for (int i = 0; i < 1048576; i++) mem[i] = '0;
        $readmemh(hex_f, mem);

        repeat (5) @(posedge clk);
        @(negedge clk); rst = 0;

        wait (done || cyc >= cyc_limit);
        @(posedge clk); #1;

        if (!done)
            $fatal(1, "[RISCOF-TB] TIMEOUT after %0d cycles (pc=%h)",
                   cyc, imem_addr);

        fd = $fopen(sig_f, "w");
        if (fd == 0) $fatal(1, "[RISCOF-TB] cannot open %s", sig_f);
        for (int unsigned a = sigb; a < sige; a += 4)
            $fdisplay(fd, "%08x", mem[a[21:2]]);
        $fclose(fd);
        $display("[RISCOF-TB] DONE in %0d cycles; signature %0d words -> %s",
                 cyc, (sige - sigb) / 4, sig_f);
        $finish;
    end

endmodule : tb_riscof

`default_nettype wire
