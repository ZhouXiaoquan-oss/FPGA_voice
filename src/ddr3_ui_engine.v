`timescale 1ns/1ps
//=====================================================================
// ddr3_ui_engine -- single native DDR3MI transaction engine (ui_clk)
//---------------------------------------------------------------------
// Transaction protocol (frozen, see SPEC 2.1):
//   * core domain presents a bundled payload (req_iswr/req_addr/req_wdata/
//     req_mask) and toggles req_tgl once; the payload is held stable until
//     ack_tgl changes, therefore only req_tgl needs a synchroniser.  The
//     bundled fields are never passed through per-bit synchronisers.
//   * this engine performs exactly one native write or one native read and
//     then toggles ack_tgl.  ack_rdata / ack_toerr are held until the next
//     request.
//   * any state outside IDLE aborts with ack_toerr = 1 when
//     init_calib_complete drops, ddr_rst is high, or the internal
//     TXN_TIMEOUT (ui_clk cycles) expires.
//   * req_ready is registered and only rises 2+ ui_clk after ack_tgl
//     changed, so the core always has time to re-arm its own logic.
//=====================================================================
module ddr3_ui_engine #(
    parameter integer TXN_TIMEOUT = 65536
) (
    input  wire         ui_clk,
    input  wire         rst_n,
    input  wire         init_calib_complete,
    input  wire         ddr_rst,
    // request from core, payload held until ack_tgl changes
    input  wire         req_tgl,
    input  wire         req_iswr,
    input  wire [28:0]  req_addr,
    input  wire [127:0] req_wdata,
    input  wire [15:0]  req_mask,
    // response to core
    output reg          ack_tgl,
    output reg  [127:0] ack_rdata,
    output reg          ack_toerr,
    output reg          req_ready,
    // native DDR3MI user interface
    output reg  [2:0]   cmd,
    output wire         cmd_en,
    output reg  [28:0]  addr,
    input  wire         cmd_ready,
    output reg  [127:0] wr_data,
    output wire         wr_data_en,
    output reg          wr_data_end,
    output reg  [15:0]  wr_data_mask,
    input  wire         wr_data_rdy,
    input  wire [127:0] rd_data,
    input  wire         rd_data_valid
);

    //-----------------------------------------------------------------
    // reset: async assert, synchronous release inside the ui domain
    //-----------------------------------------------------------------
    reg [1:0] rsync;
    always @(posedge ui_clk or negedge rst_n) begin
        if (!rst_n) rsync <= 2'b00;
        else        rsync <= {rsync[0], 1'b1};
    end
    wire rs_n = rsync[1];

    //-----------------------------------------------------------------
    // S1 (STA fix): ddr_rst comes from the clk-domain DDR PHY. 2FF-sync it
    // into ui_clk before it reaches abort/req_ready. This matches R3's
    // ip_reset_sync treatment and removes the raw clk->clk_x1 CE cone.
    // Synchronizer entrance gets the only false_path in d2.sdc.
    //-----------------------------------------------------------------
    reg [1:0] ddrst_s;
    always @(posedge ui_clk or negedge rs_n) begin
        if (!rs_n) ddrst_s <= 2'b00;
        else       ddrst_s <= {ddrst_s[0], ddr_rst};
    end
    wire ddr_rst_s = ddrst_s[1];

    //-----------------------------------------------------------------
    // req_tgl 2FF synchroniser + edge detect (one ui_clk pulse)
    //-----------------------------------------------------------------
    reg [1:0] req_s;
    reg       req_prev;
    always @(posedge ui_clk or negedge rs_n) begin
        if (!rs_n) begin
            req_s    <= 2'b00;
            req_prev <= 1'b0;
        end else begin
            req_s    <= {req_s[0], req_tgl};
            req_prev <= req_s[1];
        end
    end
    wire req_pulse = (req_s[1] != req_prev);

    //-----------------------------------------------------------------
    // transaction state machine
    //-----------------------------------------------------------------
    localparam [2:0] E_IDLE  = 3'd0,
                     E_WCMD  = 3'd1,
                     E_WWAIT = 3'd2,
                     E_WBEAT = 3'd3,
                     E_WEND  = 3'd4,
                     E_RCMD  = 3'd5,
                     E_RWAIT = 3'd6;

    reg [2:0]  e_st;
    reg [31:0] e_to;
    reg [1:0]  cool;

    wire to_hit = (e_to >= TXN_TIMEOUT);
    wire abort  = (!init_calib_complete) || ddr_rst_s;

    assign cmd_en     = (e_st == E_WCMD) || (e_st == E_RCMD);
    assign wr_data_en = (e_st == E_WBEAT);

    always @(posedge ui_clk or negedge rs_n) begin
        if (!rs_n) begin
            e_st         <= E_IDLE;
            e_to         <= 32'd0;
            cool         <= 2'd2;
            cmd          <= 3'd0;
            addr         <= 29'd0;
            wr_data      <= 128'd0;
            wr_data_end  <= 1'b0;
            wr_data_mask <= 16'd0;
            ack_tgl      <= 1'b0;
            ack_rdata    <= 128'd0;
            ack_toerr    <= 1'b0;
        end else begin
            if (cool != 2'd0) cool <= cool - 2'd1;
            case (e_st)
                E_IDLE: begin
                    if (req_pulse) begin
                        e_to      <= 32'd0;
                        ack_toerr <= 1'b0;
                        addr      <= req_addr;
                        wr_data   <= req_wdata;
                        wr_data_mask <= req_mask;
                        if (req_iswr) begin
                            cmd  <= 3'b000;
                            e_st <= E_WCMD;
                        end else begin
                            cmd  <= 3'b001;
                            e_st <= E_RCMD;
                        end
                    end
                end

                E_WCMD: begin
                    if (abort) begin
                        ack_toerr <= 1'b1;
                        ack_tgl   <= ~ack_tgl;
                        cool      <= 2'd2;
                        e_st      <= E_IDLE;
                    end else if (cmd_ready) begin
                        e_st <= E_WWAIT;
                    end else if (to_hit) begin
                        ack_toerr <= 1'b1;
                        ack_tgl   <= ~ack_tgl;
                        cool      <= 2'd2;
                        e_st      <= E_IDLE;
                    end else begin
                        e_to <= e_to + 32'd1;
                    end
                end

                E_WWAIT: begin
                    wr_data      <= req_wdata;
                    wr_data_mask <= req_mask;
                    wr_data_end  <= 1'b1;
                    if (abort) begin
                        wr_data_end <= 1'b0;
                        ack_toerr   <= 1'b1;
                        ack_tgl     <= ~ack_tgl;
                        cool        <= 2'd2;
                        e_st        <= E_IDLE;
                    end else if (wr_data_rdy) begin
                        e_st <= E_WBEAT;
                    end else if (to_hit) begin
                        wr_data_end <= 1'b0;
                        ack_toerr   <= 1'b1;
                        ack_tgl     <= ~ack_tgl;
                        cool        <= 2'd2;
                        e_st        <= E_IDLE;
                    end else begin
                        e_to <= e_to + 32'd1;
                    end
                end

                E_WBEAT: begin
                    if (abort) begin
                        wr_data_end <= 1'b0;
                        ack_toerr   <= 1'b1;
                        ack_tgl     <= ~ack_tgl;
                        cool        <= 2'd2;
                        e_st        <= E_IDLE;
                    end else if (wr_data_rdy) begin
                        e_st <= E_WEND;
                    end else begin
                        e_st <= E_WWAIT;
                    end
                end

                E_WEND: begin
                    wr_data_end <= 1'b0;
                    ack_tgl     <= ~ack_tgl;
                    cool        <= 2'd2;
                    e_st        <= E_IDLE;
                end

                E_RCMD: begin
                    if (abort) begin
                        ack_toerr <= 1'b1;
                        ack_tgl   <= ~ack_tgl;
                        cool      <= 2'd2;
                        e_st      <= E_IDLE;
                    end else if (cmd_ready) begin
                        e_st <= E_RWAIT;
                    end else if (to_hit) begin
                        ack_toerr <= 1'b1;
                        ack_tgl   <= ~ack_tgl;
                        cool      <= 2'd2;
                        e_st      <= E_IDLE;
                    end else begin
                        e_to <= e_to + 32'd1;
                    end
                end

                E_RWAIT: begin
                    if (abort) begin
                        ack_toerr <= 1'b1;
                        ack_tgl   <= ~ack_tgl;
                        cool      <= 2'd2;
                        e_st      <= E_IDLE;
                    end else if (rd_data_valid) begin
                        ack_rdata <= rd_data;
                        ack_toerr <= 1'b0;
                        ack_tgl   <= ~ack_tgl;
                        cool      <= 2'd2;
                        e_st      <= E_IDLE;
                    end else if (to_hit) begin
                        ack_toerr <= 1'b1;
                        ack_tgl   <= ~ack_tgl;
                        cool      <= 2'd2;
                        e_st      <= E_IDLE;
                    end else begin
                        e_to <= e_to + 32'd1;
                    end
                end

                default: e_st <= E_IDLE;
            endcase
        end
    end

    //-----------------------------------------------------------------
    // req_ready: registered, idle + calibrated + 2 ui_clk after ack_tgl
    //-----------------------------------------------------------------
    always @(posedge ui_clk or negedge rs_n) begin
        if (!rs_n) req_ready <= 1'b0;
        else       req_ready <= (e_st == E_IDLE) && init_calib_complete &&
                                (!ddr_rst_s) && (cool == 2'd0);
    end

endmodule
