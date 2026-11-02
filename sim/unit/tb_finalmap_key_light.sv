// ============================================================================
// tb_finalmap_key_light.sv -- v10 key-light string test (key_light)
// ============================================================================
// FINAL HMI 2026-11-01: page-0 lamps are objects bt7..bt18, so key index k must
// emit object id 7+k:
//   key 0  -> bt7   green "bt7.bco=2016"    + FF FF FF  (15 B)
//              gray "bt7.bco=33808"          + FF FF FF  (16 B)
//   key 5  -> bt12  green "bt12.bco=2016"   + FF FF FF  (16 B)
//   key 10 -> bt17  green/gray 16 / 17 B
//   key 11 -> bt18  green/gray 16 / 17 B
// Self-checking byte-for-byte; prints FINALMAP_KL_PASS / FINALMAP_KL_FAIL.
// ============================================================================
`timescale 1ns/1ps

module tb_finalmap_key_light;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;                  // 50 MHz

    reg         enable  = 1'b1;
    reg         start_ok = 1'b1;
    reg  [11:0] key_on  = 12'd0;
    reg  [11:0] key_off = 12'd0;
    reg  [11:0] key_held = 12'd0;

    wire [7:0] data;
    wire       send;
    wire       busy;

    key_light #(
        .CLK_HZ   (50_000_000),
        .BAUD_DIV (434),
        .GAP_BITS (12)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .enable(enable), .start_ok(start_ok),
        .key_on(key_on), .key_off(key_off), .key_held(key_held),
        .data(data), .send(send), .busy(busy)
    );

    // ------------------------------------------------------------- capture
    reg  [7:0] cap [0:63];
    integer cn = 0;
    always @(posedge clk) begin
        if (send && cn < 64) begin
            cap[cn] <= data;
            cn      <= cn + 1;
        end
    end

    integer errors = 0;
    reg [8*32-1:0] last_msg;                // human-readable captured bytes

    task fail(input [8*40-1:0] name, input [8*80-1:0] what);
        begin
            errors = errors + 1;
            $display("FINALMAP_KL_FAIL %0s %0s", name, what);
        end
    endtask

    // expected: reg holds up to 32 chars, zero-padded on the LEFT
    task cmp_frame(input [8*32-1:0] exp, input integer L,
                   input [8*40-1:0] name);
        integer i, bad;
        reg [7:0] e;
        begin
            bad = 0;
            if (cn !== L) begin
                bad = 1;
                $display("FINALMAP_KL_FAIL %0s length got %0d expected %0d",
                         name, cn, L);
                errors = errors + 1;
            end else begin
                for (i = 0; i < L; i = i + 1) begin
                    e = exp[8*(L-1-i) +: 8];
                    if (cap[i] !== e) begin
                        bad = 1;
                        $display("FINALMAP_KL_FAIL %0s byte[%0d] got 0x%02h expected 0x%02h",
                                 name, i, cap[i], e);
                        errors = errors + 1;
                    end
                end
            end
            if (bad == 0) $display("FINALMAP_KL_OK   %0s (%0d bytes)", name, cn);
        end
    endtask

    // ----------------------------------------------------------- key action
    task key_event(input integer k, input pressed);
        begin
            cn = 0;
            @(negedge clk);
            if (pressed) begin
                key_held[k] = 1'b1;
                key_on[k]   = 1'b1;
            end else begin
                key_held[k] = 1'b0;
                key_off[k]  = 1'b1;
            end
            @(negedge clk);
            key_on[k]  = 1'b0;
            key_off[k] = 1'b0;
            // wait for the frame to start and finish
            @(posedge busy);
            @(negedge busy);
            repeat (6) @(negedge clk);
        end
    endtask

    // ------------------------------------------------------------------ main
    initial begin
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        // key 0 <-> bt0  (name suffix = key index, KEY_BASE = 0)
        key_event(0, 1'b1);
        cmp_frame({"bt0.bco=2016", 8'hFF, 8'hFF, 8'hFF}, 15, "key0-press-bt0-green");
        key_event(0, 1'b0);
        cmp_frame({"bt0.bco=33808", 8'hFF, 8'hFF, 8'hFF}, 16, "key0-release-bt0-gray");

        // key 5 <-> bt5
        key_event(5, 1'b1);
        cmp_frame({"bt5.bco=2016", 8'hFF, 8'hFF, 8'hFF}, 15, "key5-press-bt5-green");
        key_event(5, 1'b0);
        cmp_frame({"bt5.bco=33808", 8'hFF, 8'hFF, 8'hFF}, 16, "key5-release-bt5-gray");

        // key 10 <-> bt10 (first 2-digit name)
        key_event(10, 1'b1);
        cmp_frame({"bt10.bco=2016", 8'hFF, 8'hFF, 8'hFF}, 16, "key10-press-bt10-green");
        key_event(10, 1'b0);
        cmp_frame({"bt10.bco=33808", 8'hFF, 8'hFF, 8'hFF}, 17, "key10-release-bt10-gray");

        // key 11 <-> bt11 (last lamp)
        key_event(11, 1'b1);
        cmp_frame({"bt11.bco=2016", 8'hFF, 8'hFF, 8'hFF}, 16, "key11-press-bt11-green");
        key_event(11, 1'b0);
        cmp_frame({"bt11.bco=33808", 8'hFF, 8'hFF, 8'hFF}, 17, "key11-release-bt11-gray");

        if (errors == 0) $display("FINALMAP_KL_PASS");
        else             $display("FINALMAP_KL_FAIL errors=%0d", errors);
        $finish;
    end

    initial begin
        #50_000_000;                         // 50 ms watchdog
        $display("FINALMAP_KL_FAIL timeout");
        $finish;
    end

endmodule
