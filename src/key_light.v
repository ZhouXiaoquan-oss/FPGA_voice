// ============================================================================
// key_light.v -- W21 (2026-10-29): MPR121 key -> screen key backlight follow
// ============================================================================
// Purpose
//   In FREE PLAY (the follow-along guide engine is OFF) light the matching
//   on-screen key while a touch electrode is held, and restore its idle colour
//   on release, by streaming standard TJC background-colour commands on the
//   screen UART (AB22):
//
//       press  : "bt<name>.bco=2016"  + FF FF FF   green  0x07E0 (guide's colour)
//       release: "bt<name>.bco=33808" + FF FF FF   gray   0x8410 (page-0 idle bco)
//
//   The emitted token is bt<key index>, i.e. bt0..bt11 (USER-CONFIRMED
//   2026-11-01: the HMI keeps the control NAMES bt0..bt11, so KEY_BASE = 0).
//   The object ID (7..18 on the page) never appears in this command: TJC
//   addresses controls by NAME, not by id, and the lamps never send frames.
//
//   k is the KEY index 0..11 = exactly the name suffix emitted.
//
//   This module owns NO UART.  It emits a byte stream (data + 1-clk send
//   strobes) that the top level multiplexes into the existing screen
//   transmitter, plus a `busy` flag the top level uses to keep the guide and
//   status engines from taking the same physical line in the middle of one of
//   these frames (frame atomicity: a TJC command is only executed when the
//   buffer ends in FF FF FF, so half of one command followed by half of another
//   would be discarded by the panel).
//
// Coalescing / ordering
//   pending[11:0] is set by any debounced key_on/key_off event and cleared for
//   the key a frame is started for.  The colour is sampled from key_held at
//   frame start, so a press+release that both happen while another frame is in
//   flight collapse into ONE gray frame (no green blip is emitted for a key
//   that is already released).  The lowest pending key wins, which makes a
//   chord light left-to-right in a stable order.
//
//   enable = 0 means "not free play" (guide mode owns the panel): the pending
//   mask is cleared so stale events cannot fire a burst when free play is
//   handed back; a frame already in flight is always finished (never
//   truncated).  Transient environment stalls (a status burst owns AB22 for a
//   few ms, a guide frame is queued) must NOT drop events -- they only delay
//   the frame, which is what start_ok is for.  Two separate inputs are used so
//   a key press landing inside a 4 ms status burst is simply lit afterwards
//   instead of being lost.
//
// Frame atomicity & pacing
//   One frame is 15..17 bytes, emitted at 12 bit times per byte
//   (GAP_BITS * BAUD_DIV = 12 * 434 = 5208 clk @ 50 MHz / 115200 baud), which
//   is the same pacing the W9/W10 status stream uses (a byte occupies exactly
//   10 bit times; 12 leaves 2 bit times of margin for the uart_tx S_IDLE
//   sampling).  busy stays high for the whole frame AND for one extra gap
//   (12 bit times) after the last byte: the top level's AB22 uart_tx keeps
//   shifting that byte for 10 bit times after the strobe, and anything that
//   takes the line over afterwards (a guide frame, the status burst) must not
//   offer its first byte before the transmitter is idle -- uart_tx samples
//   `send` only in S_IDLE, so an earlier byte would be silently dropped and
//   the TJC buffer corrupted (W21 audit finding, fixed here).
//
// Register budget (all registers, conservative)
//   pending 12 + active 1 + finishing 1 + fobj 5 + fgreen 1 + bidx 5 +
//   flen 6 + gap 16 + data 8 + send 1 = 55 FF, ~0 BSRAM, ~150 LUT.
// ============================================================================

`default_nettype none

module key_light #(
    parameter integer CLK_HZ   = 50_000_000,
    parameter integer BAUD_DIV = 434,     // 50 MHz / 115200 = 434.03 -> 434
    parameter integer GAP_BITS = 12       // bit times per byte, must be >= 10
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,      // 1 = free play mode (0 clears pending)
    input  wire        start_ok,    // 1 = AB22 env free: may start a frame
    input  wire [11:0] key_on,      // debounced press pulses, 1 clk wide
    input  wire [11:0] key_off,     // debounced release pulses, 1 clk wide
    input  wire [11:0] key_held,    // debounced levels (1 = held)
    output reg  [7:0]  data,        // byte for uart_tx, valid while send = 1
    output reg         send,        // 1-clk byte strobe
    output wire        busy         // a frame is in flight / tx tail
);

    localparam integer GAP_CYC = GAP_BITS * BAUD_DIV;   // 5208 clk

    // page-0 lamp NAME suffix of key index 0: bt0..bt11 (user-confirmed)
    localparam [4:0] KEY_BASE = 5'd0;

    // ---------------------------------------------------------------- state
    reg [11:0] pending;   // keys whose screen colour is unknown / out of date
    reg        active;    // a frame is in flight
    reg        finishing; // last byte sent, waiting out its bit times
    reg [4:0]  fobj;      // name suffix (0..11 = bt0..bt11) of the active frame
    reg        fgreen;    // 1 = green (lit), 0 = gray (idle)
    reg [4:0]  bidx;      // byte index inside the active frame
    reg [5:0]  flen;      // active frame length, 15..17
    reg [15:0] gap;       // inter-byte pacing counter

    assign busy = active;

    // -------------------------------------------------------------- helpers
    // Lowest set bit index (0..11); same convention as guide_low_key12().
    function [3:0] low_pending;
        input [11:0] m;
        integer i;
        begin
            low_pending = 4'd0;
            for (i = 11; i >= 0; i = i - 1)
                if (m[i]) low_pending = i[3:0];
        end
    endfunction

    // One byte of "bt<k>.bco=<colour>" + FF FF FF.
    //   name suffix = KEY_BASE + key index = 0..11 (bt0..bt11).
    //   pos 0 'b', 1 't', (2..) object-id digits, then ".bco=", then the colour
    //   digits, then 0xFF for every remaining position.
    //   green = "2016" (4 digits), gray = "33808" (5 digits).
    function [7:0] frame_char;
        input [4:0] key;    // name suffix 0..11 (bt0..bt11)
        input       green;
        input [4:0] pos;
        reg   [4:0] d;      // extra digit for obj >= 10
        reg   [4:0] off;
        reg   [4:0] co;
        begin
            d = (key >= 5'd10) ? 5'd1 : 5'd0;
            frame_char = 8'hFF;
            if (pos == 5'd0)
                frame_char = 8'h62;                       // 'b'
            else if (pos == 5'd1)
                frame_char = 8'h74;                       // 't'
            else if (pos < (5'd3 + d)) begin              // object-id digits
                if (d == 5'd0)
                    frame_char = 8'h30 + {3'd0, key};     // '7'..'9'
                else if (pos == 5'd2)
                    frame_char = 8'h31;                   // '1' (tens)
                else
                    frame_char = 8'h30 + {3'd0, key - 5'd10}; // '0'..'8'
            end else begin
                off = pos - 5'd3 - d;   // 0='.', 1='b', 2='c', 3='o', 4='=', 5.. colour
                case (off)
                    5'd0: frame_char = 8'h2E;              // '.'
                    5'd1: frame_char = 8'h62;              // 'b'
                    5'd2: frame_char = 8'h63;              // 'c'
                    5'd3: frame_char = 8'h6F;              // 'o'
                    5'd4: frame_char = 8'h3D;              // '='
                    default: begin
                        co = off - 5'd5;
                        if (green) begin
                            case (co)                      // "2016"
                                5'd0: frame_char = 8'h32;
                                5'd1: frame_char = 8'h30;
                                5'd2: frame_char = 8'h31;
                                5'd3: frame_char = 8'h36;
                                default: frame_char = 8'hFF;
                            endcase
                        end else begin
                            case (co)                      // "33808"
                                5'd0: frame_char = 8'h33;
                                5'd1: frame_char = 8'h33;
                                5'd2: frame_char = 8'h38;
                                5'd3: frame_char = 8'h30;
                                5'd4: frame_char = 8'h38;
                                default: frame_char = 8'hFF;
                            endcase
                        end
                    end
                endcase
            end
        end
    endfunction

    // ------------------------------------------------------- combinational
    wire [3:0] pk      = low_pending(pending);
    wire       pk_green = key_held[pk];
    wire [4:0] pk_obj   = {1'b0, pk} + KEY_BASE;   // 0..11 = bt0..bt11
    wire [3:0] pk_d    = (pk_obj >= 5'd10) ? 4'd1 : 4'd0;
    wire [5:0] pk_len  = (pk_green ? 6'd15 : 6'd16) + {2'd0, pk_d};

    // A frame may start only on request, in free play, while the line
    // environment is free and no frame is in flight.
    wire start = enable && start_ok && !active && (pending != 12'd0);

    // ----------------------------------------------------------- sequential
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending   <= 12'd0;
            active    <= 1'b0;
            finishing <= 1'b0;
            fobj      <= 5'd0;
            fgreen    <= 1'b0;
            bidx      <= 5'd0;
            flen      <= 6'd0;
            gap       <= 16'd0;
            data      <= 8'h00;
            send      <= 1'b0;
        end else begin
            send <= 1'b0;

            // ---- pending mask: capture events, drop the serviced key, clear
            //      while disabled (a frame in flight still finishes) ----------
            pending <= (pending | key_on | key_off) & (start ? ~(12'd1 << pk) : 12'hFFF);
            if (!enable)
                pending <= 12'd0;

            // ---- frame start ----------------------------------------------
            if (start) begin
                active    <= 1'b1;
                finishing <= 1'b0;
                fobj      <= pk_obj;
                fgreen    <= pk_green;
                bidx      <= 5'd0;
                flen      <= pk_len;
                gap       <= GAP_CYC;   // do not issue the 1st byte immediately:
                                        // keep 12 bit times from the previous byte
            end else if (active) begin
                // ---- byte pacing / emission --------------------------------
                if (gap != 16'd0) begin
                    gap <= gap - 16'd1;
                end else if (finishing) begin
                    // the last byte's 10 bit times are over (GAP_CYC = 12 bit
                    // times > 10), so the AB22 transmitter is idle again and
                    // busy may fall safely.
                    active    <= 1'b0;
                    finishing <= 1'b0;
                end else begin
                    data <= frame_char(fobj, fgreen, bidx);
                    send <= 1'b1;
                    gap  <= GAP_CYC;
                    if (bidx == (flen - 5'd1))
                        finishing <= 1'b1;   // busy stays high for the tail
                    else
                        bidx <= bidx + 5'd1;
                end
            end
        end
    end

endmodule

`default_nettype wire
