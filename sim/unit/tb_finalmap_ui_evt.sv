// ============================================================================
// tb_finalmap_ui_evt.sv -- v10 FINAL HMI object-map decode test (ui_evt_rx)
// ============================================================================
// Authoritative map (user-confirmed 2026-11-01):
//   page 1: 3 滑音(glide) 4 震音(trem) 5 合唱(chorus) 6 32音测试(p32)
//           7 REV 8 VIB 10 音色(timbre) 11 降八度(oct_dn) 12 高八度(oct_up)
//           13 效果器开关(fx) 14 延迟档位(dly) 15 跟弹开关(guide) 16 选曲(song)
//   page 0: 4 回声开关(echo) 5 回声换挡(echo_dly)
//   silent: page1 obj 2 / 9 / 17 (and any unmapped obj), page0 obj 0/7/18,
//           plus ev_cho_mix / ev_rv_room / ev_rv_damp must never fire.
//   same (page,obj) within the 200 ms debounce window stays silent.
//
// Self-checking: per-frame counter deltas; prints FINALMAP_UI_PASS / FAIL.
// ============================================================================
`timescale 1ns/1ps

module tb_finalmap_ui_evt;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;              // 50 MHz

    reg  [7:0] rx_data  = 8'h00;
    reg        rx_done  = 1'b0;

    wire       in_frame;
    wire       ev_valid;
    wire [7:0] ev_page, ev_obj, ev_event;
    wire ev_timbre, ev_oct_dn, ev_oct_up, ev_fx_toggle, ev_dly_step;
    wire ev_guide, ev_song, ev_vib, ev_rev, ev_p32, ev_glide, ev_trem;
    wire ev_chorus, ev_echo, ev_echo_dly, ev_cho_mix, ev_rv_room, ev_rv_damp;

    ui_evt_rx #(
        .CLK_HZ           (50_000_000),
        .FRAME_TIMEOUT_US (1000),
        .DEBOUNCE_US      (200_000),
        .DO_DEBOUNCE      (1)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .rx_data(rx_data), .rx_done(rx_done), .in_frame(in_frame),
        .ev_valid(ev_valid), .ev_page(ev_page), .ev_obj(ev_obj),
        .ev_event(ev_event),
        .ev_timbre(ev_timbre), .ev_oct_dn(ev_oct_dn), .ev_oct_up(ev_oct_up),
        .ev_fx_toggle(ev_fx_toggle), .ev_dly_step(ev_dly_step),
        .ev_guide(ev_guide), .ev_song(ev_song), .ev_vib(ev_vib),
        .ev_rev(ev_rev), .ev_p32(ev_p32), .ev_glide(ev_glide),
        .ev_trem(ev_trem), .ev_chorus(ev_chorus), .ev_echo(ev_echo),
        .ev_echo_dly(ev_echo_dly), .ev_cho_mix(ev_cho_mix),
        .ev_rv_room(ev_rv_room), .ev_rv_damp(ev_rv_damp)
    );

    // ------------------------------------------------------------- counters
    integer c_timbre = 0, c_oct_dn = 0, c_oct_up = 0, c_fx = 0, c_dly = 0;
    integer c_guide = 0, c_song = 0, c_vib = 0, c_rev = 0, c_p32 = 0;
    integer c_glide = 0, c_trem = 0, c_chorus = 0, c_echo = 0, c_echo_dly = 0;
    integer c_valid = 0, c_mix = 0, c_room = 0, c_damp = 0;

    always @(posedge clk) begin
        if (ev_timbre)   c_timbre   <= c_timbre   + 1;
        if (ev_oct_dn)   c_oct_dn   <= c_oct_dn   + 1;
        if (ev_oct_up)   c_oct_up   <= c_oct_up   + 1;
        if (ev_fx_toggle)c_fx       <= c_fx       + 1;
        if (ev_dly_step) c_dly      <= c_dly      + 1;
        if (ev_guide)    c_guide    <= c_guide    + 1;
        if (ev_song)     c_song     <= c_song     + 1;
        if (ev_vib)      c_vib      <= c_vib      + 1;
        if (ev_rev)      c_rev      <= c_rev      + 1;
        if (ev_p32)      c_p32      <= c_p32      + 1;
        if (ev_glide)    c_glide    <= c_glide    + 1;
        if (ev_trem)     c_trem     <= c_trem     + 1;
        if (ev_chorus)   c_chorus   <= c_chorus   + 1;
        if (ev_echo)     c_echo     <= c_echo     + 1;
        if (ev_echo_dly) c_echo_dly <= c_echo_dly + 1;
        if (ev_valid)    c_valid    <= c_valid    + 1;
        if (ev_cho_mix)  c_mix      <= c_mix      + 1;
        if (ev_rv_room)  c_room     <= c_room     + 1;
        if (ev_rv_damp)  c_damp     <= c_damp     + 1;
    end

    // ------------------------------------------------------------- snapshots
    integer s_timbre, s_oct_dn, s_oct_up, s_fx, s_dly, s_guide, s_song;
    integer s_vib, s_rev, s_p32, s_glide, s_trem, s_chorus, s_echo, s_echo_dly;
    integer s_valid, s_mix, s_room, s_damp;
    integer errors = 0;

    task snap;
        begin
            s_timbre = c_timbre; s_oct_dn = c_oct_dn; s_oct_up = c_oct_up;
            s_fx = c_fx; s_dly = c_dly; s_guide = c_guide; s_song = c_song;
            s_vib = c_vib; s_rev = c_rev; s_p32 = c_p32; s_glide = c_glide;
            s_trem = c_trem; s_chorus = c_chorus; s_echo = c_echo;
            s_echo_dly = c_echo_dly; s_valid = c_valid;
            s_mix = c_mix; s_room = c_room; s_damp = c_damp;
        end
    endtask

    task chk(input integer got, input integer exp, input [8*40-1:0] name);
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("FINALMAP_UI_FAIL %0s got %0d expected %0d (t=%0t)",
                         name, got, exp, $time);
            end
        end
    endtask

    // which: 0=silent 1=timbre 2=oct_dn 3=oct_up 4=fx 5=dly 6=guide 7=song
    //        8=vib 9=rev 10=p32 11=glide 12=trem 13=chorus 14=echo 15=echo_dly
    integer expected_valid_delta;
    task check_frame(input [8*40-1:0] name, input integer which);
        integer d;
        begin
            d = c_valid - s_valid;
            chk(d, expected_valid_delta, name);
            chk(c_mix - s_mix, 0, name);
            chk(c_room - s_room, 0, name);
            chk(c_damp - s_damp, 0, name);
            if (which == 0) begin
                chk(c_timbre - s_timbre, 0, name); chk(c_oct_dn - s_oct_dn, 0, name);
                chk(c_oct_up - s_oct_up, 0, name); chk(c_fx - s_fx, 0, name);
                chk(c_dly - s_dly, 0, name); chk(c_guide - s_guide, 0, name);
                chk(c_song - s_song, 0, name); chk(c_vib - s_vib, 0, name);
                chk(c_rev - s_rev, 0, name); chk(c_p32 - s_p32, 0, name);
                chk(c_glide - s_glide, 0, name); chk(c_trem - s_trem, 0, name);
                chk(c_chorus - s_chorus, 0, name); chk(c_echo - s_echo, 0, name);
                chk(c_echo_dly - s_echo_dly, 0, name);
            end else begin
                chk(c_timbre - s_timbre,   (which == 1)  ? 1 : 0, name);
                chk(c_oct_dn - s_oct_dn,   (which == 2)  ? 1 : 0, name);
                chk(c_oct_up - s_oct_up,   (which == 3)  ? 1 : 0, name);
                chk(c_fx - s_fx,           (which == 4)  ? 1 : 0, name);
                chk(c_dly - s_dly,         (which == 5)  ? 1 : 0, name);
                chk(c_guide - s_guide,     (which == 6)  ? 1 : 0, name);
                chk(c_song - s_song,       (which == 7)  ? 1 : 0, name);
                chk(c_vib - s_vib,         (which == 8)  ? 1 : 0, name);
                chk(c_rev - s_rev,         (which == 9)  ? 1 : 0, name);
                chk(c_p32 - s_p32,         (which == 10) ? 1 : 0, name);
                chk(c_glide - s_glide,     (which == 11) ? 1 : 0, name);
                chk(c_trem - s_trem,       (which == 12) ? 1 : 0, name);
                chk(c_chorus - s_chorus,   (which == 13) ? 1 : 0, name);
                chk(c_echo - s_echo,       (which == 14) ? 1 : 0, name);
                chk(c_echo_dly - s_echo_dly, (which == 15) ? 1 : 0, name);
            end
        end
    endtask

    // ------------------------------------------------------------ frame I/O
    task send_byte(input [7:0] b);
        begin
            @(negedge clk);
            rx_data = b;
            rx_done = 1'b1;
            @(negedge clk);
            rx_done = 1'b0;
            rx_data = 8'h00;
            @(negedge clk);
            @(negedge clk);
        end
    endtask

    task send_frame(input [7:0] page, input [7:0] obj);
        begin
            send_byte(8'h65);
            send_byte(page);
            send_byte(obj);
            send_byte(8'h01);
            send_byte(8'hFF);
            send_byte(8'hFF);
            send_byte(8'hFF);
            repeat (8) @(negedge clk);
        end
    endtask

    task one_frame(input [8*40-1:0] name, input [7:0] page, input [7:0] obj,
                   input integer which);
        begin
            expected_valid_delta = 1;
            snap;
            send_frame(page, obj);
            repeat (8) @(negedge clk);
            check_frame(name, which);
        end
    endtask

    task silent_frame(input [8*40-1:0] name, input [7:0] page, input [7:0] obj);
        begin
            expected_valid_delta = 1;      // structurally valid frame, no action
            snap;
            send_frame(page, obj);
            repeat (8) @(negedge clk);
            check_frame(name, 0);
        end
    endtask

    // ------------------------------------------------------------------ main
    initial begin
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        // ---- page 1, FINAL map ----
        one_frame("p1-obj3-glide",    8'd1, 8'd3,  11);
        one_frame("p1-obj4-trem",     8'd1, 8'd4,  12);
        one_frame("p1-obj5-chorus",   8'd1, 8'd5,  13);
        one_frame("p1-obj6-test",     8'd1, 8'd6,  10);
        one_frame("p1-obj7-rev",      8'd1, 8'd7,   9);
        one_frame("p1-obj8-vib",      8'd1, 8'd8,   8);
        one_frame("p1-obj10-timbre",  8'd1, 8'd10,  1);
        one_frame("p1-obj11-oct_dn",  8'd1, 8'd11,  2);
        one_frame("p1-obj12-oct_up",  8'd1, 8'd12,  3);
        one_frame("p1-obj13-fx",      8'd1, 8'd13,  4);
        one_frame("p1-obj14-dly",     8'd1, 8'd14,  5);
        one_frame("p1-obj15-guide",   8'd1, 8'd15,  6);
        one_frame("p1-obj16-song",    8'd1, 8'd16,  7);

        // ---- page 1, unmapped objs ----
        silent_frame("p1-obj2-silent",   8'd1, 8'd2);
        silent_frame("p1-obj9-silent",   8'd1, 8'd9);
        silent_frame("p1-obj17-silent",  8'd1, 8'd17);

        // ---- page 0 echo keys ----
        one_frame("p0-obj4-echo",      8'd0, 8'd4, 14);
        one_frame("p0-obj5-echo_dly",  8'd0, 8'd5, 15);

        // ---- page 0 lamps (bt7..bt18, sendkey=0) must never fire ----
        silent_frame("p0-obj0-silent",  8'd0, 8'd0);
        silent_frame("p0-obj7-silent",  8'd0, 8'd7);
        silent_frame("p0-obj18-silent", 8'd0, 8'd18);

        // ---- 200 ms same-key debounce ----
        one_frame("p1-obj3-first", 8'd1, 8'd3, 11);    // accepted, reloads dbn
        expected_valid_delta = 0;                      // same key inside window
        snap;
        send_frame(8'd1, 8'd3);
        repeat (8) @(negedge clk);
        check_frame("p1-obj3-debounced", 0);
        // different obj is accepted immediately
        one_frame("p1-obj13-after-diff", 8'd1, 8'd13, 4);

        // ---- summary ----
        $display("FINALMAP_UI counters timbre=%0d oct_dn=%0d oct_up=%0d fx=%0d dly=%0d guide=%0d song=%0d vib=%0d rev=%0d p32=%0d glide=%0d trem=%0d chorus=%0d echo=%0d echo_dly=%0d valid=%0d mix=%0d room=%0d damp=%0d",
                 c_timbre, c_oct_dn, c_oct_up, c_fx, c_dly, c_guide, c_song,
                 c_vib, c_rev, c_p32, c_glide, c_trem, c_chorus, c_echo,
                 c_echo_dly, c_valid, c_mix, c_room, c_damp);
        if (errors == 0) $display("FINALMAP_UI_PASS");
        else             $display("FINALMAP_UI_FAIL errors=%0d", errors);
        $finish;
    end

    initial begin
        #50_000_000;                      // 50 ms watchdog
        $display("FINALMAP_UI_FAIL timeout");
        $finish;
    end

endmodule
