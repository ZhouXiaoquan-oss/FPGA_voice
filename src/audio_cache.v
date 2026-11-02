`timescale 1ns/1ps
//=====================================================================
// audio_cache -- 2^AW x 16 simple dual port RAM (inferred BSRAM)
//   write port : we / waddr / wdata
//   read  port : re / raddr -> rdata (synchronous, 1 clk latency)
//   Same-address read/write returns the old content; the upper layer
//   guarantees that a block is only read after it has been written
//   (valid/tag handshake).
//=====================================================================
module audio_cache #(
    parameter integer AW = 8
) (
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [15:0]   wdata,
    input  wire          re,
    input  wire [AW-1:0] raddr,
    output reg  [15:0]   rdata
);

    reg [15:0] mem [0:(1<<AW)-1];

`ifdef SIMULATION
    // Simulation only: deterministic power-up content.  Not required for
    // functional correctness (valid/tag gate every read and q is forced to 0
    // while q_valid is low) and not present in the synthesis tree, so that
    // BSRAM inference never depends on an initial block.
    integer i;
    initial begin
        for (i = 0; i < (1<<AW); i = i + 1) mem[i] = 16'h0000;
    end
`endif

    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
    end

    always @(posedge clk) begin
        if (re) rdata <= mem[raddr];
    end

endmodule
