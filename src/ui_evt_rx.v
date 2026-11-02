// ============================================================================
// ui_evt_rx -- TJC serial-screen 0x65 event-frame receiver (Task-016 / W6-C)
// ============================================================================
// Scope
//   This module decodes ONE byte stream: the screen UART (uart_rxd2).  It does
//   not contain a UART; instantiate uart_rx in front of it:
//
//       uart_rx  ->  rx_data[7:0], rx_done  ->  ui_evt_rx  ->  action pulses
//
//   The PC UART (uart_rxd / uart_txd) is NOT touched.  Keeping the two byte
//   streams separate is what makes the "frame byte must not be a command"
//   hazard fixable: see the in_frame section below.
//
// Wire format (TJC "touch event" frame, 7 bytes, MSB-first on the wire)
//   byte 0 : 0x65        frame header (never a single-byte command)
//   byte 1 : page        screen page number
//   byte 2 : obj         control object id (TJC-assigned number, not a name)
//   byte 3 : event       0x01 = press, 0x00 = release, 0x03 = up
//   byte 4 : 0xFF        tail
//   byte 5 : 0xFF        tail
//   byte 6 : 0xFF        tail
//
//   Only event = 0x01 (press edge) is acted on; 0x00 / 0x03 are ignored so a
//   single tap cannot fire twice.  A frame is accepted only if all three tail
//   bytes are 0xFF.  Everything else is dropped silently and the receiver is
//   ready for the next header (no lock-up on malformed input).
//
// in_frame gate (Task-016 section 3 -- the safety requirement)
//   in_frame is HIGH from the header byte until the 7th byte is consumed, or
//   until the frame timeout expires.  If the top level ever merges the screen
//   stream into the legacy single-byte command decoders, it MUST use
//
//       rx_done_eff = rx_done & ~in_frame
//
//   otherwise byte 1 (page = 0x01) would fire the 0x01 beep and byte 2
//   (obj = 0x05) would switch timbre.  The header byte itself is not gated:
//   0x65 is not a command, and in_frame can only rise after seeing it.
//
// Timeouts / de-bounce
//   FRAME_TIMEOUT_US : idle time inside a frame that aborts it (default 1 ms).
//                      A real TJC frame has ~87 us per byte at 115200 baud, so
//                      1 ms leaves >10x margin.
//   DEBOUNCE_US      : same (page,obj) is accepted at most once per window
//                      (default 200 ms, Task-016 T6).  A different obj is
//                      always accepted.  Set DO_DEBOUNCE = 0 to disable.
//
// Object map -- FINAL HMI (user-confirmed 2026-11-01, authoritative)
//
//   page 1 (settings page), obj -> action
//     3  -> ev_glide     (same as PC byte 0x0F)   [滑音]
//     4  -> ev_trem      (same as PC byte 0x10)   [震音]
//     5  -> ev_chorus    (same as PC byte 0x11)   [合唱]
//     6  -> ev_p32       (32-tone TEST on/off, single-key toggle;
//                         equivalent to PC 0x03 / 0x04 alternately)  [32音测试]
//     7  -> ev_rev       (reverb OFF->R0->R1->R2->OFF, same as PC 0x0C)  [REV]
//     8  -> ev_vib       (same as PC byte 0x0B)   [VIB]
//     10 -> ev_timbre    (same as PC byte 0x05)   [音色]
//     11 -> ev_oct_dn    (same as onboard KEY1)   [降八度]
//     12 -> ev_oct_up    (same as onboard KEY2)   [高八度]
//     13 -> ev_fx_toggle (same as PC byte 0x06)   [效果器开关]
//     14 -> ev_dly_step  (same as PC byte 0x07)   [延迟档位]
//     15 -> ev_guide     (same as PC byte 0x08)   [跟弹开关]
//     16 -> ev_song      (same as PC byte 0x09)   [选曲]
//     obj 2 / 9 / 17 have no FPGA action (screen-local or unused).
//
//   page 0 (performance page): exactly TWO sendkey=2 controls,
//     4 -> ev_echo      (DDR echo on/off toggle, same as PC byte 0x13)  [回声开关]
//     5 -> ev_echo_dly  (0.5->1->2->4 s cycle,   same as PC byte 0x14)  [回声换挡]
//     the 12 key lamps are obj 7..18 (bt7..bt18) and bset stays sendkey=0,
//     so they never send a frame.
//
//   NOTE: the page-1 / page-0 pulses all come from the same
//   7-byte/0xFF-tail/event=0x01/200-ms-debounce path -- only the case arms
//   differ.  Page 0 is a SEPARATE `if` (not `else if`) on purpose: the else-if
//   form made GowinSyn explode the top glue LUT count (+2,054).
//
//   ev_cho_mix / ev_rv_room / ev_rv_damp are kept as ports (always 0) because
//   the final HMI has no object for them: chorus-mix (PC 0x12) and reverb
//   room/damp (PC 0x0D/0x0E) stay PC-only.  Keeping the ports means the top
//   level's three-source PC/EV muxes need no edit.
//
//   ev_valid / ev_page / ev_obj / ev_event mark a frame that was structurally
//   valid and carried event = 0x01.  Screen-local objects (obj 9, bset) and
//   unmapped pages still set ev_valid, with every action pulse low; this is
//   what makes them observable for a future status read-back.
// ============================================================================

`default_nettype none

module ui_evt_rx #(
    parameter integer CLK_HZ           = 50_000_000,
    parameter integer FRAME_TIMEOUT_US = 1000,      // 1 ms, Task-016
    parameter integer DEBOUNCE_US      = 200_000,   // 200 ms, Task-016 T6
    parameter integer DO_DEBOUNCE      = 1          // 0 = accept every press
)(
    input  wire       clk,
    input  wire       rst_n,

    // byte stream from the screen UART
    input  wire [7:0] rx_data,
    input  wire       rx_done,      // 1-clk pulse, one per received byte

    // frame gate; see the header.  rx_done_eff = rx_done & ~in_frame
    output reg        in_frame,

    // decoded actions, each exactly 1 clk wide
    output reg        ev_valid,
    output reg  [7:0] ev_page,
    output reg  [7:0] ev_obj,
    output reg  [7:0] ev_event,
    output reg        ev_timbre,
    output reg        ev_oct_dn,
    output reg        ev_oct_up,
    output reg        ev_fx_toggle,
    output reg        ev_dly_step,
    output reg        ev_guide,
    output reg        ev_song,
    output reg        ev_vib,
    output reg        ev_rev,
    output reg        ev_p32,
    output reg        ev_glide,
    output reg        ev_trem,
    output reg        ev_chorus,
    output reg        ev_echo,
    output reg        ev_echo_dly,
    output reg        ev_cho_mix,
    output reg        ev_rv_room,
    output reg        ev_rv_damp
);

    // ------------------------------------------------------------- constants
    // us -> clk.  Integer arithmetic only (no $rtoi / real, keeps Yosys-style
    // tools happy).  At 50 MHz the two counters are 17 and 24 bits wide.
    localparam integer TIMEOUT_CLKS = (CLK_HZ / 1_000_000) * FRAME_TIMEOUT_US;
    localparam integer DEBOUNCE_CLKS = (CLK_HZ / 1_000_000) * DEBOUNCE_US;
    localparam [23:0]  DBN_LOAD   = DEBOUNCE_CLKS;   // 200 ms @ 50 MHz = 10e6

    localparam [7:0] HDR = 8'h65;
    localparam [7:0] TAIL = 8'hFF;
    localparam [7:0] EV_PRESS = 8'h01;

    // byte index inside the frame (byte 0 = header, already consumed)
    localparam [2:0] C_PAGE  = 3'd1;
    localparam [2:0] C_OBJ   = 3'd2;
    localparam [2:0] C_EVENT = 3'd3;
    localparam [2:0] C_TAIL0 = 3'd4;
    localparam [2:0] C_TAIL1 = 3'd5;
    localparam [2:0] C_TAIL2 = 3'd6;

    // object ids, page 1 -- FINAL HMI map (user-confirmed 2026-11-01)
    localparam [7:0] OBJ_GLIDE  = 8'd3;   // 滑音          (PC 0x0F)
    localparam [7:0] OBJ_TREM   = 8'd4;   // 震音          (PC 0x10)
    localparam [7:0] OBJ_CHORUS = 8'd5;   // 合唱开关      (PC 0x11)
    localparam [7:0] OBJ_TEST   = 8'd6;   // 32音测试 开/关 (PC 0x03 / 0x04)
    localparam [7:0] OBJ_REV    = 8'd7;   // REV           (PC 0x0C)
    localparam [7:0] OBJ_VIB    = 8'd8;   // VIB           (PC 0x0B)
    localparam [7:0] OBJ_TIMBRE = 8'd10;  // 音色          (PC 0x05)
    localparam [7:0] OBJ_OCT_DN = 8'd11;  // 降八度        (板载 KEY1)
    localparam [7:0] OBJ_OCT_UP = 8'd12;  // 高八度        (板载 KEY2)
    localparam [7:0] OBJ_FX     = 8'd13;  // 效果器开关    (PC 0x06)
    localparam [7:0] OBJ_DLY    = 8'd14;  // 延迟档位      (PC 0x07)
    localparam [7:0] OBJ_GUIDE  = 8'd15;  // 跟弹开关      (PC 0x08)
    localparam [7:0] OBJ_SONG   = 8'd16;  // 选曲          (PC 0x09)
    // page-0 echo keys (page 0, USER-CONFIRMED 2026-11-01)
    localparam [7:0] OBJ_P0_ECHO     = 8'd4;  // 回声开关 (PC 0x13)
    localparam [7:0] OBJ_P0_ECHO_LEN = 8'd5;  // 回声换挡 (PC 0x14)

    // ----------------------------------------------------------------- state
    reg [2:0]  cnt;                 // bytes consumed in the current frame
    reg [7:0]  page_r, obj_r, evt_r;
    reg        tail_bad;            // any tail byte other than 0xFF
    reg [16:0] tmo;                 // frame timeout, counted while idle

    reg [15:0] last_key;            // {page, obj} of the last accepted action
    reg [23:0] dbn_cnt;             // de-bounce window, counted down

    // ------------------------------------------------------------ de-bounce
    wire [15:0] key_now   = {page_r, obj_r};
    wire        same_key  = (key_now == last_key);
    wire        dbn_block = (DO_DEBOUNCE != 0) && (dbn_cnt != 24'd0) && same_key;

    // tail is OK only if bytes 4/5 were 0xFF and byte 6 (this one) is 0xFF
    wire        tail_ok   = !tail_bad && (rx_data == TAIL);

    // --------------------------------------------------------------- receive
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_frame     <= 1'b0;
            cnt          <= 3'd0;
            page_r       <= 8'd0;
            obj_r        <= 8'd0;
            evt_r        <= 8'd0;
            tail_bad     <= 1'b0;
            tmo          <= 17'd0;
            last_key     <= 16'd0;
            dbn_cnt      <= 24'd0;
            ev_valid     <= 1'b0;
            ev_page      <= 8'd0;
            ev_obj       <= 8'd0;
            ev_event     <= 8'd0;
            ev_timbre    <= 1'b0;
            ev_oct_dn    <= 1'b0;
            ev_oct_up    <= 1'b0;
            ev_fx_toggle <= 1'b0;
            ev_dly_step  <= 1'b0;
            ev_guide     <= 1'b0;
            ev_song      <= 1'b0;
            ev_vib       <= 1'b0;
            ev_rev       <= 1'b0;
            ev_p32       <= 1'b0;
            ev_glide     <= 1'b0;
            ev_trem      <= 1'b0;
            ev_chorus    <= 1'b0;
            ev_echo      <= 1'b0;
            ev_echo_dly  <= 1'b0;
            ev_cho_mix   <= 1'b0;
            ev_rv_room   <= 1'b0;
            ev_rv_damp   <= 1'b0;
        end else begin
            // every action is a single-cycle pulse
            ev_valid     <= 1'b0;
            ev_timbre    <= 1'b0;
            ev_oct_dn    <= 1'b0;
            ev_oct_up    <= 1'b0;
            ev_fx_toggle <= 1'b0;
            ev_dly_step  <= 1'b0;
            ev_guide     <= 1'b0;
            ev_song      <= 1'b0;
            ev_vib       <= 1'b0;
            ev_rev       <= 1'b0;
            ev_p32       <= 1'b0;
            ev_glide     <= 1'b0;
            ev_trem      <= 1'b0;
            ev_chorus    <= 1'b0;
            ev_echo      <= 1'b0;
            ev_echo_dly  <= 1'b0;
            ev_cho_mix   <= 1'b0;
            ev_rv_room   <= 1'b0;
            ev_rv_damp   <= 1'b0;

            if (dbn_cnt != 24'd0)
                dbn_cnt <= dbn_cnt - 24'd1;

            if (!in_frame) begin
                // idle: only a header opens a frame.  Any other byte is left
                // to the legacy single-byte decoders (PC channel).
                cnt      <= 3'd0;
                tmo      <= 17'd0;
                tail_bad <= 1'b0;
                if (rx_done && (rx_data == HDR)) begin
                    in_frame <= 1'b1;
                    cnt      <= C_PAGE;    // next byte is the page
                    tmo      <= 17'd0;
                end
            end else if (rx_done) begin
                // A byte arrived: restart the inter-byte timeout.
                tmo <= 17'd0;
                cnt <= cnt + 3'd1;

                case (cnt)
                    C_PAGE:  page_r <= rx_data;
                    C_OBJ:   obj_r  <= rx_data;
                    C_EVENT: evt_r  <= rx_data;

                    C_TAIL0,
                    C_TAIL1: if (rx_data != TAIL) tail_bad <= 1'b1;

                    C_TAIL2: begin
                        // 7th byte: frame ends here, one way or the other.
                        in_frame <= 1'b0;
                        cnt      <= 3'd0;

                        if (tail_ok && (evt_r == EV_PRESS) && !dbn_block) begin
                            ev_valid <= 1'b1;
                            ev_page  <= page_r;
                            ev_obj   <= obj_r;
                            ev_event <= evt_r;
                            last_key <= {page_r, obj_r};
                            dbn_cnt  <= DBN_LOAD;

                            // page 1 = settings page (FINAL HMI map).
                            if (page_r == 8'd1) begin
                                case (obj_r)
                                    OBJ_GLIDE:  ev_glide     <= 1'b1;   // 3  滑音
                                    OBJ_TREM:   ev_trem      <= 1'b1;   // 4  震音
                                    OBJ_CHORUS: ev_chorus    <= 1'b1;   // 5  合唱
                                    OBJ_TEST:   ev_p32       <= 1'b1;   // 6  32音测试
                                    OBJ_REV:    ev_rev       <= 1'b1;   // 7  REV
                                    OBJ_VIB:    ev_vib       <= 1'b1;   // 8  VIB
                                    OBJ_TIMBRE: ev_timbre    <= 1'b1;   // 10 音色
                                    OBJ_OCT_DN: ev_oct_dn    <= 1'b1;   // 11 降八度
                                    OBJ_OCT_UP: ev_oct_up    <= 1'b1;   // 12 高八度
                                    OBJ_FX:     ev_fx_toggle <= 1'b1;   // 13 效果器开关
                                    OBJ_DLY:    ev_dly_step  <= 1'b1;   // 14 延迟档位
                                    OBJ_GUIDE:  ev_guide     <= 1'b1;   // 15 跟弹开关
                                    OBJ_SONG:   ev_song      <= 1'b1;   // 16 选曲
                                    default:    ;  // obj 2 / 9 / 17: no FPGA action
                                endcase
                            end

                            // page 0 = performance page: only the two DDR3 echo keys
                            // send frames (echo obj4, echo_len obj5); the 12
                            // lamps bt7..bt18 and bset are sendkey=0.
                            // Kept as an INDEPENDENT if (not else-if): the else-if
                            // form made GowinSyn explode the top glue LUT count
                            // (+2,054) and pushed PnR into a routing dead-end.
                            if (page_r == 8'd0) begin
                                case (obj_r)
                                    OBJ_P0_ECHO:     ev_echo     <= 1'b1;
                                    OBJ_P0_ECHO_LEN: ev_echo_dly <= 1'b1;
                                    default:         ;
                                endcase
                            end
                        end
                    end

                    default: begin
                        // Cannot happen with a 3-bit counter, but never hang.
                        in_frame <= 1'b0;
                        cnt      <= 3'd0;
                    end
                endcase
            end else begin
                // Idle inside a frame: 1 ms without a byte aborts it.  The
                // receiver is immediately ready for a new 0x65 header.
                if (tmo == (TIMEOUT_CLKS - 1)) begin
                    in_frame <= 1'b0;
                    cnt      <= 3'd0;
                    tmo      <= 17'd0;
                end else begin
                    tmo <= tmo + 17'd1;
                end
            end
        end
    end

endmodule

`default_nettype wire
