// GW5AT-60K PLL stop adapter wiring, derived from Sipeed cam_dvi/top.v.
// The vendor pll_mDRP_intf implementation is included unchanged separately.
module ddr3_pll_ctrl(
    input wire clk,
    input wire rst_n,
    input wire pll_lock,
    input wire pll_stop,
    input wire [7:0] mdrp_rdata,
    output wire [1:0] mdrp_op,
    output wire mdrp_inc,
    output wire [7:0] mdrp_wdata
);
    reg [1:0] lock_sync;
    reg stop_prev;
    reg wr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lock_sync <= 2'b00;
            stop_prev <= 1'b0;
            wr <= 1'b0;
        end else begin
            lock_sync <= {lock_sync[0], pll_lock};
            stop_prev <= pll_stop;
            wr <= lock_sync[1] && (pll_stop != stop_prev);
        end
    end
    pll_mDRP_intf u_mdrp(
        .clk(clk), .rst_n(rst_n), .pll_lock(lock_sync[1]), .wr(wr),
        .mdrp_inc(mdrp_inc), .mdrp_op(mdrp_op),
        .mdrp_wdata(mdrp_wdata), .mdrp_rdata(mdrp_rdata)
    );
endmodule
