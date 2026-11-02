`timescale 1ns/1ps
//=====================================================================
// audio_tap_stream -- one delayed read stream (256 sample cache + prefetch)
//---------------------------------------------------------------------
// * D = 24414/48828/97656/195313 frames, selected by tap_sel.
// * p_q          = frame_seq - D          (absolute sample index wanted)
// * q_region     = frame_seq >= epoch_frame + D
// * cur_blk      = (p_q >> 6) & (N_SAMPLES/64 - 1)   12 bit wrapped index
// * cache slot   = cur_blk[1:0], cache word = cur_blk[1:0]*64 + p_q[5:0]
// * prefetch: one burst at a time, one block ahead; a block is only
//   requested when it has already been committed to the A area
//   (absolute block index < wr_blk_done).
// * a burst is 8 lanes of 16 bit; the returned 128 bit word is written
//   into the cache as cache[slot*64 + b*8 + j] = data[16*j +: 16].
//=====================================================================
module audio_tap_stream #(
    parameter integer N_SAMPLES = 262144,
    parameter integer D0 = 24414,
    parameter integer D1 = 48828,
    parameter integer D2 = 97656,
    parameter integer D3 = 195313
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [31:0]  frame_seq,
    input  wire [1:0]   tap_sel,
    input  wire [31:0]  epoch_frame,
    input  wire         flush,          // tap change or epoch: drop everything
    input  wire [31:0]  wr_blk_done,    // number of blocks already committed
    // burst request towards the single transaction channel
    output wire         b_req,
    output wire [28:0]  b_addr,
    output wire [11:0]  b_blk,
    output wire [2:0]   b_idx,
    input  wire         b_gnt,
    input  wire         txn_done,       // pulse: this stream's burst finished
    input  wire         txn_ok,
    input  wire [28:0]  txn_addr,
    input  wire [127:0] txn_rdata,
    // consume side
    input  wire         cons_en,        // pulse at OUT_SLOT-2
    output wire [15:0]  cons_data,
    // status
    output wire         hit,
    output wire         q_region,
    output wire [31:0]  d_sel,
    output reg          tag_err
);

    localparam integer NUM_BLKS = N_SAMPLES / 64;
    localparam [11:0]  BLK_MASK = NUM_BLKS - 1;

    //-----------------------------------------------------------------
    // delay table and derived addresses
    //-----------------------------------------------------------------
    wire [31:0] dd = (tap_sel == 2'd0) ? D0 :
                     (tap_sel == 2'd1) ? D1 :
                     (tap_sel == 2'd2) ? D2 : D3;
    assign d_sel = dd;

    wire [31:0] region_thresh = epoch_frame + dd;
    assign q_region = (frame_seq >= region_thresh);

    wire [31:0] p_q     = frame_seq - dd;
    wire [31:0] p_q_eff = q_region ? p_q : epoch_frame;

    wire [11:0] cur_blk  = p_q[17:6]     & BLK_MASK;
    wire [11:0] cur_blk_e= p_q_eff[17:6] & BLK_MASK;
    wire [11:0] nxt_blk  = (cur_blk_e + 12'd1) & BLK_MASK;
    wire [31:0] abs_eff  = p_q_eff >> 6;
    wire [31:0] abs_nxt  = abs_eff + 32'd1;

    //-----------------------------------------------------------------
    // 256 x 16 cache (BSRAM) + tag / valid
    //-----------------------------------------------------------------
    wire        cache_we;
    wire [7:0]  cache_wa;
    wire [15:0] cache_wd;
    wire [7:0]  cache_ra = {cur_blk[1:0], p_q[5:0]};
    wire [15:0] cache_q;

    audio_cache #(.AW(8)) u_cache (
        .clk   (clk),
        .we    (cache_we),
        .waddr (cache_wa),
        .wdata (cache_wd),
        .re    (cons_en),
        .raddr (cache_ra),
        .rdata (cache_q)
    );

    assign cons_data = cache_q;

    reg [11:0] tag   [0:3];
    reg [3:0]  valid;

    wire hit_e = valid[cur_blk_e[1:0]] && (tag[cur_blk_e[1:0]] == cur_blk_e);
    wire hit_n = valid[nxt_blk[1:0]]   && (tag[nxt_blk[1:0]]   == nxt_blk);
    assign hit = valid[cur_blk[1:0]] && (tag[cur_blk[1:0]] == cur_blk);

    //-----------------------------------------------------------------
    // prefetch engine
    //-----------------------------------------------------------------
    localparam [1:0] P_IDLE = 2'd0,
                     P_REQ  = 2'd1,
                     P_WAIT = 2'd2,
                     P_WR   = 2'd3;

    reg [1:0]   p_st;
    reg [11:0]  pf_blk;
    reg [2:0]   pf_b;
    reg [3:0]   pw_cnt;
    reg [127:0] pw_data;

    assign b_req  = (p_st == P_REQ);
    assign b_blk  = pf_blk;
    assign b_idx  = pf_b;
    assign b_addr = {pf_blk, pf_b, 3'b000};

    wire want_cur = (!hit_e) && (abs_eff < wr_blk_done);
    wire want_nxt = (hit_e) && (!hit_n) && (abs_nxt < wr_blk_done);
    wire want     = want_cur || want_nxt;
    wire [11:0] tgt_blk = want_cur ? cur_blk_e : nxt_blk;
    wire [31:0] tgt_abs = want_cur ? abs_eff   : abs_nxt;

    // cache write port is shared between the prefetch lane writer and the
    // flush (no flush write needed: valid is simply cleared)
    assign cache_we = (p_st == P_WR);
    assign cache_wa = {pf_blk[1:0], pf_b, pw_cnt[2:0]};
    assign cache_wd = pw_data[16*pw_cnt[2:0] +: 16];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p_st     <= P_IDLE;
            pf_blk   <= 12'd0;
            pf_b     <= 3'd0;
            pw_cnt   <= 4'd0;
            pw_data  <= 128'd0;
            tag_err  <= 1'b0;
            valid    <= 4'b0000;
            tag[0]   <= 12'd0;
            tag[1]   <= 12'd0;
            tag[2]   <= 12'd0;
            tag[3]   <= 12'd0;
        end else if (flush) begin
            p_st    <= P_IDLE;
            pw_cnt  <= 4'd0;
            valid   <= 4'b0000;
            tag_err <= 1'b0;
        end else begin
            tag_err <= 1'b0;
            case (p_st)
                P_IDLE: begin
                    if (want) begin
                        pf_blk <= tgt_blk;
                        pf_b   <= 3'd0;
                        valid[tgt_blk[1:0]] <= 1'b0;
                        p_st   <= P_REQ;
                    end
                end

                P_REQ: begin
                    if (b_gnt) p_st <= P_WAIT;
                end

                P_WAIT: begin
                    if (txn_done) begin
                        if (txn_ok && (txn_addr == b_addr)) begin
                            pw_data <= txn_rdata;
                            pw_cnt  <= 4'd0;
                            p_st    <= P_WR;
                        end else begin
                            if (txn_ok && (txn_addr != b_addr)) tag_err <= 1'b1;
                            p_st <= P_IDLE;
                        end
                    end
                end

                P_WR: begin
                    pw_cnt <= pw_cnt + 4'd1;
                    if (pw_cnt == 4'd7) begin
                        if (pf_b == 3'd7) begin
                            // all eight bursts are in the cache: publish the tag
                            tag[pf_blk[1:0]]   <= pf_blk;
                            valid[pf_blk[1:0]] <= 1'b1;
                            p_st <= P_IDLE;
                        end else begin
                            pf_b <= pf_b + 3'd1;
                            p_st <= P_REQ;
                        end
                    end
                end

                default: p_st <= P_IDLE;
            endcase
        end
    end

endmodule
