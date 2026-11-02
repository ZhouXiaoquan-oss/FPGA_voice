//=====================================================================
// uart_tx.v -- minimal 8N1 UART transmitter
//
// The board's FPGA-side UART TX is U15 ("txp" in the official .cst,
// BANK8 = 3.3 V). It shows up on the PC as one of the two "USB Serial
// Port" devices (CP2102 on the DEBUG-USB port), which is the evidence
// channel for this whole diagnostic: the screen may be mute, but the
// serial port is not.
//
// Baud divisor = clk / baud. 50 MHz / 115200 = 434.03 -> 434
// (0.008% error, far inside tolerance).
//=====================================================================
module uart_tx #(
    parameter integer DIV = 434
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data,
    input  wire       send,     // 1-clk pulse
    output reg        txd,
    output reg        busy
);
    localparam [1:0] S_IDLE  = 2'd0,
                     S_START = 2'd1,
                     S_DATA  = 2'd2,
                     S_STOP  = 2'd3;

    reg [1:0]  st;
    reg [15:0] cnt;
    reg [2:0]  bit_i;
    reg [7:0]  sh;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; txd <= 1'b1; busy <= 1'b0;
            cnt <= 16'd0; bit_i <= 3'd0; sh <= 8'h00;
        end else begin
            case (st)
                S_IDLE: begin
                    txd <= 1'b1;
                    if (send) begin
                        sh  <= data;
                        st  <= S_START;
                        cnt <= 16'd0;
                        busy <= 1'b1;
                    end else begin
                        busy <= 1'b0;
                    end
                end

                S_START: begin
                    txd <= 1'b0;
                    if (cnt == DIV-1) begin cnt <= 16'd0; bit_i <= 3'd0; st <= S_DATA; end
                    else cnt <= cnt + 1'b1;
                end

                S_DATA: begin                              // LSB first
                    txd <= sh[bit_i];
                    if (cnt == DIV-1) begin
                        cnt <= 16'd0;
                        if (bit_i == 3'd7) st <= S_STOP;
                        else               bit_i <= bit_i + 3'd1;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                S_STOP: begin
                    txd <= 1'b1;
                    if (cnt == DIV-1) begin
                        cnt <= 16'd0; st <= S_IDLE; busy <= 1'b0;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
