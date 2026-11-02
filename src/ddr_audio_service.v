`timescale 1ns/1ps
//=====================================================================
// ddr_audio_service -- D1 DDR3 audio storage service (core, 50 MHz)
//---------------------------------------------------------------------
//  * frame/slot timing, CAP_SLOT capture, OUT_SLOT output register
//  * 64-sample block write ring inside the A area (N_SAMPLES samples)
//  * two independent 256-sample read caches with one-block look-ahead
//  * one native transaction channel, round-robin over 3 sources
//    (tap0 prefetch, tap1 prefetch, write burst)
//  * toggle handshake CDC towards ddr3_ui_engine (ui_clk domain)
//  * fault / status counters (SPEC 3.6)
//=====================================================================
module ddr_audio_service #(
    parameter integer N_SAMPLES   = 262144,
    parameter integer FRAME_TICKS = 1024,
    parameter integer CAP_SLOT    = 18,
    parameter integer OUT_SLOT    = 32,
    parameter integer UI_TIMEOUT  = 65536
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               frame_tick,
    input  wire signed [15:0] sample_in,
    input  wire [1:0]         tap0_sel,
    input  wire [1:0]         tap1_sel,
    output reg  signed [15:0] q0,
    output reg  signed [15:0] q1,
    output reg                q0_valid,
    output reg                q1_valid,
    output reg  [31:0]        frame_seq_o,
    output reg  [31:0]        hist_count_o,
    // request to ddr3_ui_engine
    output reg                req_tgl,
    output reg                req_iswr,
    output reg  [28:0]        req_addr,
    output reg  [127:0]       req_wdata,
    output reg  [15:0]        req_mask,
    input  wire               ack_tgl,
    input  wire [127:0]       ack_rdata,
    input  wire               ack_toerr,
    input  wire               ui_req_ready,
    input  wire               ui_calib,
    input  wire               ui_ddr_rst,
    // status
    output reg  [15:0]        fault_count,
    output reg  [7:0]         fault_reason,
    output reg  [15:0]        stat_underflow,
    output reg  [15:0]        stat_overflow,
    output reg  [15:0]        stat_timeout,
    output reg  [15:0]        stat_tag_error,
    output reg  [31:0]        dbg_req_max_cycles,
    output wire               service_ready
);

    localparam integer NUM_BLKS = N_SAMPLES / 64;
    localparam [11:0]  BLK_MASK = NUM_BLKS - 1;

    localparam [31:0] D_05S = 32'd24414;
    localparam [31:0] D_1S  = 32'd48828;
    localparam [31:0] D_2S  = 32'd97656;
    localparam [31:0] D_4S  = 32'd195313;

    //-----------------------------------------------------------------
    // declarations (all nets/regs first, assignments later)
    //-----------------------------------------------------------------
    wire calib_ok, ddrst_act, ui_ready_s, ui_ok, ack_edge;
    wire ev_calib_fall, ev_ddrst_rise, ev_ui_fall, ev_ui_rise;
    wire ev_ovf, ev_tagerr, epoch_evt, hist_reset;

    wire cap_pt, cons_pt, out_pt;
    wire [5:0]  col;
    wire [11:0] wblk;
    wire cap_ok, wrb_we, wrb_re;
    wire blk_commit_now, blk_free, wr_cand, wr_urgent;
    wire [6:0]  wrb_wa, wrb_ra;

    wire [15:0] wrb_rd, cons_data0, cons_data1;
    wire        b_req0, b_req1;
    wire [28:0] b_addr0, b_addr1;
    wire [11:0] b_blk0, b_blk1;
    wire [2:0]  b_idx0, b_idx1;
    wire        hit0, hit1, qreg0, qreg1;
    wire [31:0] dsel0, dsel1;
    wire        tag_err0, tag_err1;
    wire        gnt0, gnt1, gnt_wr;
    wire        txn_done0, txn_done1;
    wire        q0_ok, q1_ok;

    wire        c_rd0, c_rd1, c_wr, issue;
    wire [7:0]  fault_new;

    reg [31:0]  epoch_frame;
    reg [31:0]  epoch;

    reg        ev_timeout;
    reg        ev_toerr;
    reg        hist_fault;

    reg [31:0] t_timer;
    reg [31:0] t_cyc;
    reg [1:0]  t_settle;
    reg        t_disc;
    reg        txn_done;
    reg        txn_ok;
    reg [1:0]  rr;
    reg [2:0]  t_src;
    reg [28:0] t_addr;
    reg [2:0]  sel;
    reg [28:0]  iss_addr;
    reg [127:0] iss_wdata;
    reg         iss_iswr;

    //=================================================================
    // 1. clock domain crossing
    //    ui_calib / ui_ddr_rst / ui_req_ready are registered inside the
    //    ui domain (see ddr3_ui_engine) and 3FF synchronised here;
    //    ack_tgl is a toggle and only needs a synchroniser + edge detect.
    //=================================================================
    reg [2:0] calib_s;
    reg [2:0] ddrst_s;
    reg [2:0] rdyn_s;
    reg [2:0] ack_s;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            calib_s <= 3'b000;
            ddrst_s <= 3'b000;
            rdyn_s  <= 3'b000;
            ack_s   <= 3'b000;
        end else begin
            calib_s <= {calib_s[1:0], ui_calib};
            ddrst_s <= {ddrst_s[1:0], ui_ddr_rst};
            rdyn_s  <= {rdyn_s[1:0],  ui_req_ready};
            ack_s   <= {ack_s[1:0],   ack_tgl};
        end
    end

    assign calib_ok   = calib_s[2];
    assign ddrst_act  = ddrst_s[2];
    assign ui_ready_s = rdyn_s[2];
    assign ui_ok      = calib_ok && (!ddrst_act);
    assign ack_edge   = ack_s[1] ^ ack_s[2];

    reg calib_d, ddrst_d, uiok_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            calib_d <= 1'b0;
            ddrst_d <= 1'b0;
            uiok_d  <= 1'b0;
        end else begin
            calib_d <= calib_ok;
            ddrst_d <= ddrst_act;
            uiok_d  <= ui_ok;
        end
    end

    assign ev_calib_fall = calib_d & (!calib_ok);
    assign ev_ddrst_rise = (!ddrst_d) & ddrst_act;
    assign ev_ui_fall    = uiok_d & (!ui_ok);
    assign ev_ui_rise    = ui_ok & (!uiok_d);

    //=================================================================
    // 2. frame / slot timing
    //=================================================================
    reg [15:0] slot;
    reg [31:0] frame_seq;
    reg        fs_started;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            slot       <= 16'd0;
            frame_seq  <= 32'd0;
            fs_started <= 1'b0;
        end else if (frame_tick) begin
            slot <= 16'd0;
            if (!fs_started) begin
                fs_started <= 1'b1;
                frame_seq  <= 32'd0;
            end else begin
                frame_seq <= frame_seq + 32'd1;
            end
        end else begin
            slot <= slot + 16'd1;
        end
    end

    assign cap_pt  = (slot == CAP_SLOT);
    assign cons_pt = (slot == (OUT_SLOT - 2));
    assign out_pt  = (slot == OUT_SLOT);

    //=================================================================
    // 3. tap selection is sampled at the frame tick
    //=================================================================
    reg [1:0] tap0_r, tap1_r;
    reg       flush0_r, flush1_r;
    reg [8:0] und_hold0, und_hold1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tap0_r    <= 2'd0;
            tap1_r    <= 2'd0;
            flush0_r  <= 1'b0;
            flush1_r  <= 1'b0;
            und_hold0 <= 9'd0;
            und_hold1 <= 9'd0;
        end else begin
            flush0_r <= frame_tick && (tap0_sel != tap0_r);
            flush1_r <= frame_tick && (tap1_sel != tap1_r);
            if (frame_tick) begin
                tap0_r <= tap0_sel;
                tap1_r <= tap1_sel;
            end
            // underflow is not counted in the gear-change window (SPEC 3.3)
            if (frame_tick) begin
                if (tap0_sel != tap0_r)       und_hold0 <= 9'd255;
                else if (und_hold0 != 9'd0)   und_hold0 <= und_hold0 - 9'd1;
                if (tap1_sel != tap1_r)       und_hold1 <= 9'd255;
                else if (und_hold1 != 9'd0)   und_hold1 <= und_hold1 - 9'd1;
            end
        end
    end

    //=================================================================
    // 4. write buffer: 2 x 64 x 16 inside one 128 x 16 BSRAM
    //=================================================================
    localparam [1:0] W_IDLE = 2'd0,
                     W_ASM  = 2'd1,
                     W_RDY  = 2'd2,
                     W_WAIT = 2'd3;

    reg [1:0]   w_st;
    reg [2:0]   w_b;
    reg [3:0]   asm_cnt;
    reg [127:0] asm_shift;
    reg [11:0]  w_blk;
    reg [31:0]  w_abs;

    reg         fill_bank;
    reg         pend_valid;
    reg         pend_bank;
    reg [11:0]  pend_blk;
    reg [31:0]  pend_abs;
    reg [31:0]  wr_blk_done;
    reg [10:0]  urd_cnt;

    assign col  = frame_seq[5:0];
    assign wblk = frame_seq[17:6] & BLK_MASK;

    assign cap_ok = cap_pt && ui_ok && (!hist_fault) && fs_started;
    assign wrb_we = cap_ok;
    assign wrb_wa = {fill_bank, col};

    audio_cache #(.AW(7)) u_wrbuf (
        .clk   (clk),
        .we    (wrb_we),
        .waddr (wrb_wa),
        .wdata (sample_in),
        .re    (wrb_re),
        .raddr (wrb_ra),
        .rdata (wrb_rd)
    );

    assign wrb_re = (w_st == W_ASM) && (!asm_cnt[3]);
    assign wrb_ra = {pend_bank, w_b, asm_cnt[2:0]};

    // a block slot is free when nothing is pending, or when the final burst
    // of the pending block is acknowledged in this very cycle
    assign blk_commit_now = (w_st == W_WAIT) && txn_done && txn_ok &&
                            (t_src == 3'd2) && (w_b == 3'd7);
    assign blk_free = (!pend_valid) || blk_commit_now;

    assign wr_cand = (w_st == W_RDY);

    assign ev_ovf = cap_ok && (col == 6'd63) && (!blk_free);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_st          <= W_IDLE;
            w_b           <= 3'd0;
            asm_cnt       <= 4'd0;
            asm_shift     <= 128'd0;
            w_blk         <= 12'd0;
            w_abs         <= 32'd0;
            fill_bank     <= 1'b0;
            pend_valid    <= 1'b0;
            pend_bank     <= 1'b0;
            pend_blk      <= 12'd0;
            pend_abs      <= 32'd0;
            wr_blk_done   <= 32'd0;
            urd_cnt       <= 11'd0;
            hist_fault    <= 1'b0;
            stat_overflow <= 16'd0;
        end else begin
            // ---- commit engine ----
            case (w_st)
                W_IDLE: begin
                    if (pend_valid && (!hist_reset)) begin
                        w_blk   <= pend_blk;
                        w_abs   <= pend_abs;
                        w_b     <= 3'd0;
                        asm_cnt <= 4'd0;
                        w_st    <= W_ASM;
                    end
                end
                W_ASM: begin
                    if (asm_cnt != 4'd0)
                        asm_shift <= {wrb_rd, asm_shift[127:16]};
                    if (asm_cnt == 4'd8) w_st <= W_RDY;
                    else                 asm_cnt <= asm_cnt + 4'd1;
                end
                W_RDY: begin
                    if (gnt_wr) w_st <= W_WAIT;
                end
                W_WAIT: begin
                    if (txn_done && (t_src == 3'd2)) begin
                        if (txn_ok) begin
                            if (w_b == 3'd7) begin
                                pend_valid  <= 1'b0;
                                wr_blk_done <= w_abs + 32'd1;
                                w_st        <= W_IDLE;
                            end else begin
                                w_b     <= w_b + 3'd1;
                                asm_cnt <= 4'd0;
                                w_st    <= W_ASM;
                            end
                        end else begin
                            pend_valid <= 1'b0;
                            w_st       <= W_IDLE;
                        end
                    end
                end
                default: w_st <= W_IDLE;
            endcase

            // ---- capture + block promotion ----
            if (cap_ok && (col == 6'd63) && blk_free) begin
                pend_valid <= 1'b1;
                pend_bank  <= fill_bank;
                pend_blk   <= wblk;
                pend_abs   <= frame_seq >> 6;
                fill_bank  <= !fill_bank;
            end

            // ---- write buffer overflow ----
            if (ev_ovf) begin
                stat_overflow <= stat_overflow + 16'd1;
                hist_fault    <= 1'b1;
            end

            // ---- epoch reset: drop the pending block ----
            if (hist_reset) begin
                pend_valid <= 1'b0;
                w_st       <= W_IDLE;
            end
            if (epoch_evt) hist_fault <= 1'b0;

            // ---- write urgency counter (safety net only) ----
            if (!pend_valid)             urd_cnt <= 11'd0;
            else if (urd_cnt != 11'h7FF) urd_cnt <= urd_cnt + 11'd1;
        end
    end

    assign wr_urgent = (urd_cnt >= 11'd768);

    //=================================================================
    // 5. two read streams
    //=================================================================
    audio_tap_stream #(
        .N_SAMPLES (N_SAMPLES),
        .D0 (24414), .D1 (48828), .D2 (97656), .D3 (195313)
    ) u_tap0 (
        .clk        (clk),
        .rst_n      (rst_n),
        .frame_seq  (frame_seq),
        .tap_sel    (tap0_r),
        .epoch_frame(epoch_frame),
        .flush      (flush0_r | hist_reset),
        .wr_blk_done(wr_blk_done),
        .b_req      (b_req0),
        .b_addr     (b_addr0),
        .b_blk      (b_blk0),
        .b_idx      (b_idx0),
        .b_gnt      (gnt0),
        .txn_done   (txn_done0),
        .txn_ok     (txn_ok),
        .txn_addr   (t_addr),
        .txn_rdata  (ack_rdata),
        .cons_en    (cons_pt),
        .cons_data  (cons_data0),
        .hit        (hit0),
        .q_region   (qreg0),
        .d_sel      (dsel0),
        .tag_err    (tag_err0)
    );

    audio_tap_stream #(
        .N_SAMPLES (N_SAMPLES),
        .D0 (24414), .D1 (48828), .D2 (97656), .D3 (195313)
    ) u_tap1 (
        .clk        (clk),
        .rst_n      (rst_n),
        .frame_seq  (frame_seq),
        .tap_sel    (tap1_r),
        .epoch_frame(epoch_frame),
        .flush      (flush1_r | hist_reset),
        .wr_blk_done(wr_blk_done),
        .b_req      (b_req1),
        .b_addr     (b_addr1),
        .b_blk      (b_blk1),
        .b_idx      (b_idx1),
        .b_gnt      (gnt1),
        .txn_done   (txn_done1),
        .txn_ok     (txn_ok),
        .txn_addr   (t_addr),
        .txn_rdata  (ack_rdata),
        .cons_en    (cons_pt),
        .cons_data  (cons_data1),
        .hit        (hit1),
        .q_region   (qreg1),
        .d_sel      (dsel1),
        .tag_err    (tag_err1)
    );

    //=================================================================
    // 6. single native transaction channel
    //=================================================================
    localparam [1:0] T_IDLE = 2'd0,
                     T_WAIT = 2'd1,
                     T_SET  = 2'd2;

    reg [1:0]  t_st;

    assign c_rd0 = b_req0;
    assign c_rd1 = b_req1;
    assign c_wr  = wr_cand;

    always @(*) begin
        iss_addr  = 29'd0;
        iss_wdata = 128'd0;
        iss_iswr  = 1'b0;
        if (sel == 3'd0) begin
            iss_addr = b_addr0;
        end else if (sel == 3'd1) begin
            iss_addr = b_addr1;
        end else begin
            iss_addr  = {w_blk, w_b, 3'b000};
            iss_wdata = asm_shift;
            iss_iswr  = 1'b1;
        end
    end

    always @(*) begin
        sel = 3'd3;
        if (wr_urgent && c_wr) begin
            sel = 3'd2;
        end else begin
            case (rr)
                2'd0: begin
                    if      (c_rd0) sel = 3'd0;
                    else if (c_rd1) sel = 3'd1;
                    else if (c_wr)  sel = 3'd2;
                end
                2'd1: begin
                    if      (c_rd1) sel = 3'd1;
                    else if (c_wr)  sel = 3'd2;
                    else if (c_rd0) sel = 3'd0;
                end
                default: begin
                    if      (c_wr)  sel = 3'd2;
                    else if (c_rd0) sel = 3'd0;
                    else if (c_rd1) sel = 3'd1;
                end
            endcase
        end
    end

    assign issue   = (t_st == T_IDLE) && ui_ok && ui_ready_s && (sel != 3'd3);
    assign gnt0    = issue && (sel == 3'd0);
    assign gnt1    = issue && (sel == 3'd1);
    assign gnt_wr  = issue && (sel == 3'd2);
    assign txn_done0 = txn_done && (t_src == 3'd0);
    assign txn_done1 = txn_done && (t_src == 3'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_tgl     <= 1'b0;
            req_iswr    <= 1'b0;
            req_addr    <= 29'd0;
            req_wdata   <= 128'd0;
            req_mask    <= 16'd0;
            t_st        <= T_IDLE;
            t_src       <= 3'd0;
            t_addr      <= 29'd0;
            t_timer     <= 32'd0;
            t_cyc       <= 32'd0;
            t_settle    <= 2'd0;
            t_disc      <= 1'b0;
            txn_done    <= 1'b0;
            txn_ok      <= 1'b0;
            ev_timeout  <= 1'b0;
            ev_toerr    <= 1'b0;
            rr          <= 2'd0;
            stat_timeout<= 16'd0;
            dbg_req_max_cycles <= 32'd0;
        end else begin
            txn_done   <= 1'b0;
            ev_timeout <= 1'b0;
            ev_toerr   <= 1'b0;

            case (t_st)
                T_IDLE: begin
                    if (issue) begin
                        req_tgl   <= !req_tgl;
                        req_iswr  <= iss_iswr;
                        req_addr  <= iss_addr;
                        req_wdata <= iss_wdata;
                        req_mask  <= 16'h0000;
                        t_src     <= sel;
                        t_addr    <= iss_addr;
                        t_timer   <= 32'd0;
                        t_cyc     <= 32'd0;
                        t_disc    <= 1'b0;
                        t_settle  <= 2'd0;
                        t_st      <= T_WAIT;
                        rr        <= (sel == 3'd2) ? 2'd0 : (sel[1:0] + 2'd1);
                    end
                end

                T_WAIT: begin
                    if (!t_disc) t_cyc <= t_cyc + 32'd1;
                    if (ack_edge) begin
                        if (t_disc) begin
                            t_st <= T_IDLE;
                        end else begin
                            t_settle <= 2'd2;
                            t_st     <= T_SET;
                        end
                    end else if (!t_disc) begin
                        if (t_timer < UI_TIMEOUT) t_timer <= t_timer + 32'd1;
                        if (t_timer >= UI_TIMEOUT) begin
                            t_disc       <= 1'b1;
                            ev_timeout   <= 1'b1;
                            stat_timeout <= stat_timeout + 16'd1;
                        end
                    end
                end

                T_SET: begin
                    if (t_settle != 2'd0) begin
                        t_settle <= t_settle - 2'd1;
                    end else begin
                        if (t_cyc > dbg_req_max_cycles)
                            dbg_req_max_cycles <= t_cyc;
                        txn_done <= 1'b1;
                        txn_ok   <= !ack_toerr;
                        if (ack_toerr) ev_toerr <= 1'b1;
                        t_st     <= T_IDLE;
                    end
                end

                default: t_st <= T_IDLE;
            endcase
        end
    end

    //=================================================================
    // 7. epoch / fault event collection
    //=================================================================
    assign ev_tagerr = tag_err0 | tag_err1;
    assign hist_reset = ev_timeout | ev_toerr | ev_tagerr |
                        ev_ui_fall | ev_ui_rise;
    assign epoch_evt  = ev_ui_fall | ev_ui_rise;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            epoch_frame <= 32'd0;
            epoch       <= 32'd0;
        end else begin
            // restart the history two frames later so that the first sample
            // of the new epoch is always captured after the reset
            if (hist_reset) epoch_frame <= frame_seq + 32'd2;
            if (epoch_evt)  epoch       <= epoch + 32'd1;
        end
    end

    //=================================================================
    // 8. output register, underflow statistics, history counter
    //=================================================================
    assign q0_ok = qreg0 && hit0 && (!hist_fault) && ui_ok;
    assign q1_ok = qreg1 && hit1 && (!hist_fault) && ui_ok;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q0             <= 16'sd0;
            q1             <= 16'sd0;
            q0_valid       <= 1'b0;
            q1_valid       <= 1'b0;
            frame_seq_o    <= 32'd0;
            hist_count_o   <= 32'd0;
            stat_underflow <= 16'd0;
        end else begin
            frame_seq_o <= frame_seq;

            if (out_pt) begin
                q0       <= q0_ok ? cons_data0 : 16'sd0;
                q1       <= q1_ok ? cons_data1 : 16'sd0;
                q0_valid <= q0_ok;
                q1_valid <= q1_ok;
            end

            if (hist_reset) begin
                hist_count_o <= 32'd0;
            end else if (cap_ok) begin
                if (hist_count_o < N_SAMPLES)
                    hist_count_o <= hist_count_o + 32'd1;
            end

            if (out_pt && ui_ok && (!hist_fault)) begin
                if ((qreg0 && (!q0_ok) && (und_hold0 == 9'd0)) ||
                    (qreg1 && (!q1_ok) && (und_hold1 == 9'd0))) begin
                    stat_underflow <= stat_underflow + 16'd1;
                end
            end
        end
    end

    //=================================================================
    // 9. fault bookkeeping (sticky per epoch, count on 0->1 events)
    //=================================================================
    assign fault_new = { ev_ddrst_rise,   // bit 7
                         ev_calib_fall,   // bit 6
                         1'b0,            // bit 5 (illegal address)
                         ev_ovf,          // bit 4
                         1'b0,            // bit 3 (reserved)
                         ev_tagerr,       // bit 2
                         ev_toerr,        // bit 1
                         ev_timeout };    // bit 0

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fault_reason   <= 8'd0;
            fault_count    <= 16'd0;
            stat_tag_error <= 16'd0;
        end else begin
            if (epoch_evt) fault_reason <= fault_new;
            else           fault_reason <= fault_reason | fault_new;

            if ((fault_new & (~fault_reason)) != 8'd0)
                fault_count <= fault_count + 16'd1;

            if (ev_tagerr) stat_tag_error <= stat_tag_error + 16'd1;
        end
    end

    assign service_ready = ui_ok && (!hist_fault);

endmodule
