// ============================================================================
// [p2_synth] Ported VERBATIM from the AX515 project:
//     trae\p1_audio_bringup\rtl\voice_alloc.v
// Only this ASCII provenance header was added; the module body is unchanged
// (its original Chinese comments are preserved as-is).
// Phase-2 target: Tang Mega 60K (GW5AT-60B), PT8211 I2S master, NVOICE=32.
//
// ----------------------------------------------------------------------------
// [p2_synth] DECISION on the `v_note_r` issue (phase-2 notes, section 6)
// ----------------------------------------------------------------------------
// Option (c) was chosen: BEHAVIOUR IS UNCHANGED, the semantics are documented
// here so nobody misreads it later. Do NOT "fix" this while porting.
//
//   `v_note_r[i] <= k_on` (see the assignment below) stores the KEY index, not
//   a pitch index, so the port `v_note` actually means "which key owns this
//   voice" -- it duplicates `v_owner_key`. Because the top level maps one key
//   to one fixed pitch (note_fcw(key_index)), the design works as intended,
//   but `v_note` is only NKEYW = clog2(NKEYS) = 2 bits wide, so it can never
//   express more than NKEYS distinct pitches. That contradicts the module
//   header's claim that the pool is not limited by the key count.
//
//   Consequence for phase 2: with NKEYS = 3 the pool has 32 voices but only 3
//   distinct pitches in play mode. Test mode does not go through this path at
//   all (the top level drives each voice's FCW directly), which is why 32
//   distinct spectral peaks still work.
//
//   The real fix (option (b): widen v_note to a true pitch index fed by an
//   independent pitch source) is deliberately postponed: tb_voice_alloc.v is
//   written against the current behaviour, so changing the semantics here
//   would force a testbench rewrite at the same time.
// ============================================================================
// ============================================================================
// 模块 8: voice_alloc — 声部分配器 (复音资源池)  [P5 新增]
//
// 为什么需要它 (题目"声部数 ≠ 按键数"的关键):
//   声部是**资源池** (NVOICE 个), 按键只是触发源之一 (NKEYS 个)。
//   把"哪个键按下/松开"翻译成"哪个声部起音/释放", 好处有三:
//     1. 声部数不再被按键数卡死 —— 测试模式、加法合成、触摸条、MIDI
//        都能驱动同一个池子 (题目拓展要求 ≥32 声部就是靠这一点)
//     2. 每键长期持有自己的声部 (owner 标记): 重复按同一个键 = 重触发**同一个**
//        振荡器 (包络从当前电平再起音, 不咔哒), 而不是每按一次吃掉一个新声部
//     3. 抢占策略有地方放: 池满时可轮转抢占 (为将来多触发源留的安全网)
//
// 分配优先级 (从高到低):
//   a) 该键已持有声部 (且该声部仍归它) → 直接重触发
//   b) 池中有空闲声部 → 取编号最小的那个 (优先编码)
//   c) 池满 → 轮转抢占 (rr_ptr), 抢当前指向的声部 (归属随之转移)
//   NKEYS=4 且 NVOICE≥4 时 (b) 永远够用, (c) 不会发生 —— 但它保证了
//   "将来把 NKEYS 扩到 12 (触摸条) 或 88 (MIDI) 时行为仍然正确"。
//
// ★ "空闲"的定义 (这里踩过一个坑, 记下来) ★
//   一开始把"空闲"定义为 ADSR 的 active==0。这是错的: 一个键松手后, 声部
//   淡出结束回到 IDLE, 于是**又变成空闲**, 可能被分给另一个键 —— 而原键
//   仍然记着"这个声部是我的"。之后两个键抢同一个声部, 其中一个松手就把
//   另一个正在响的音给 note_off 掉了。
//   正确做法: 声部有**预留位** v_owner_v —— 一旦分配给某个键就长期保留,
//   空闲 = (ADSR 不活跃) 且 (未被任何键预留)。这样每键长期独占自己的声部,
//   顺带保证了"弹奏时活跃声部数恒 ≤ NKEYS"这个顶层混音标度依赖的前提。
//   抢占 (c) 会把 v_owner_key 改写成本键 → 原键的 has_own 检查自然失效,
//   不会再去操作已经被抢走的声部。
//
// 事件节拍 (为什么要有 pend 锁存):
//   按键事件是单周期脉冲, 同一拍可能有多个键同时变化 (消抖计数器同拍到期)。
//   本模块每个时钟只处理一个事件 (最低编号优先), 其余锁存到下一拍继续处理,
//   保证不丢事件、也不会两个键抢到同一个声部。
//   释放事件优先于按下事件: 先把资源腾出来, 再分配。
//
// 端口: v_note 是"每声部当前音高索引"的打包输出 (分配时写入)。
//   打包成一维向量的原因: Verilog-2001 的端口不支持数组, 顶层用
//   v_note[g*NKEYW +: NKEYW] 按索引位选取出即可。
// ============================================================================
module voice_alloc #(
    parameter NVOICE = 32,        // 声部池大小
    parameter NKEYS  = 4,         // 触发键数
    parameter NKEYW  = 2          // 键索引位宽 = clog2(NKEYS); NKEYS=4 → 2
                                  // (声明成参数而不是 localparam: 端口位宽要用到它,
                                  //  Verilog-2001 的端口列表看不到模块体内的 localparam)
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire [NKEYS-1:0]         key_on,     // 每键按下脉冲 (消抖后, 单周期)
    input  wire [NKEYS-1:0]         key_off,    // 每键释放脉冲 (消抖后, 单周期)
    input  wire [NVOICE-1:0]        v_active,   // 各声部忙闲 (来自各声部 ADSR 的 active)
    output reg  [NVOICE-1:0]        v_on,       // 每声部起音脉冲 (单周期)
    output reg  [NVOICE-1:0]        v_off,      // 每声部释放脉冲 (单周期)
    output wire [NVOICE*NKEYW-1:0]  v_note      // 每声部音高索引 (打包)
);

    // ---- 位宽推导工具 (不用 $clog2: 兼容老工具链, 且是常量折叠) ----
    function integer clog2(input integer value);
        integer i;
        begin
            clog2 = 0;
            for (i = value - 1; i > 0; i = i >> 1)
                clog2 = clog2 + 1;
        end
    endfunction

    localparam NVOICEW = clog2(NVOICE);     // 声部号位宽 (32 声部 → 5)

    // ---- "最低置位"优先编码: 返回 one-hot (同一拍多事件时取最低编号) ----
    function [NKEYS-1:0] lowest_oh(input [NKEYS-1:0] v);
        integer i;
        begin
            lowest_oh = {NKEYS{1'b0}};
            for (i = NKEYS - 1; i >= 0; i = i - 1)
                if (v[i])
                    lowest_oh = {{(NKEYS-1){1'b0}}, 1'b1} << i;
        end
    endfunction

    // ---- one-hot → 二进制索引 ----
    function [NKEYW-1:0] oh2idx(input [NKEYS-1:0] oh);
        integer i;
        begin
            oh2idx = {NKEYW{1'b0}};
            for (i = 0; i < NKEYS; i = i + 1)
                if (oh[i])
                    oh2idx = i[NKEYW-1:0];
        end
    endfunction

    // ---- 状态 ----
    reg [NVOICEW-1:0] key_voice  [0:NKEYS-1];    // 每键持有的声部号
    reg [NKEYS-1:0]   key_owned;                 // 每键是否已分到声部
    reg [NVOICE-1:0]  v_owner_v;                 // 声部是否已被某键预留 (长期保持)
    reg [NKEYW-1:0]   v_owner_key[0:NVOICE-1];   // 声部的归属键 (抢占时被改写)
    reg [NKEYW-1:0]   v_note_r   [0:NVOICE-1];   // 每声部音高索引 (分配时写入)
    reg [NVOICEW-1:0] rr_ptr;                    // 轮转抢占指针
    reg [NKEYS-1:0]   pend_on, pend_off;         // 未处理完的事件锁存

    // ---- 本拍要处理哪个事件 (释放优先) ----
    wire [NKEYS-1:0] on_req  = key_on  | pend_on;
    wire [NKEYS-1:0] off_req = key_off | pend_off;
    wire             do_off  = |off_req;
    wire             do_on   = ~do_off & |on_req;

    wire [NKEYS-1:0] sel_on  = lowest_oh(on_req);
    wire [NKEYS-1:0] sel_off = lowest_oh(off_req);
    wire [NKEYW-1:0] k_on    = oh2idx(sel_on);
    wire [NKEYW-1:0] k_off   = oh2idx(sel_off);

    // ---- 归属校验: 键 k 是否仍然持有它记着的那个声部 ----
    //   (被抢占后 v_owner_key 已改写, 这里会返回 0 → 该键不再操作别人的声部)
    wire own_ok_on  = key_owned[k_on]  & (v_owner_key[key_voice[k_on]]  == k_on);
    wire own_ok_off = key_owned[k_off] & (v_owner_key[key_voice[k_off]] == k_off);

    // ---- 空闲声部: 既没在发声 (ADSR IDLE), 也没被任何键预留 ----
    wire [NVOICE-1:0] free_mask = ~v_active & ~v_owner_v;

    reg [NVOICEW-1:0] free_idx;
    reg               free_found;
    integer fi;
    always @* begin
        free_idx   = {NVOICEW{1'b0}};
        free_found = 1'b0;
        for (fi = NVOICE - 1; fi >= 0; fi = fi - 1)
            if (free_mask[fi]) begin          // 倒序覆盖 → 最终留下编号最小的
                free_idx   = fi[NVOICEW-1:0];
                free_found = 1'b1;
            end
    end

    // ---- 分配目标 (a/b/c 三级优先级) ----
    wire [NVOICEW-1:0] tgt_idx = own_ok_on   ? key_voice[k_on] :
                                 free_found  ? free_idx        :
                                               rr_ptr;

    // 目标声部号 → one-hot (起音脉冲)
    reg [NVOICE-1:0] tgt_oh;
    integer ti;
    always @* begin
        tgt_oh = {NVOICE{1'b0}};
        for (ti = 0; ti < NVOICE; ti = ti + 1)
            if (tgt_idx == ti[NVOICEW-1:0])
                tgt_oh[ti] = 1'b1;
    end

    // 释放目标: 该键持有的那个声部 (归属校验通过才发脉冲)
    //   循环写在 if 外面: 循环变量在 if 内不动会被 Quartus 判成 latch (10240)
    reg [NVOICE-1:0] off_oh;
    integer oi;
    always @* begin
        off_oh = {NVOICE{1'b0}};
        for (oi = 0; oi < NVOICE; oi = oi + 1)
            if (own_ok_off && (key_voice[k_off] == oi[NVOICEW-1:0]))
                off_oh[oi] = 1'b1;
    end

    // ---- 顺序逻辑: 事件处理 + 归属表/预留表/音高表维护 ----
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_on       <= {NVOICE{1'b0}};
            v_off      <= {NVOICE{1'b0}};
            v_owner_v  <= {NVOICE{1'b0}};
            key_owned  <= {NKEYS{1'b0}};
            pend_on    <= {NKEYS{1'b0}};
            pend_off   <= {NKEYS{1'b0}};
            rr_ptr     <= {NVOICEW{1'b0}};
            for (i = 0; i < NKEYS; i = i + 1)
                key_voice[i] <= {NVOICEW{1'b0}};
            for (i = 0; i < NVOICE; i = i + 1) begin
                v_owner_key[i] <= {NKEYW{1'b0}};
                v_note_r[i]    <= {NKEYW{1'b0}};
            end
        end else begin
            // 脉冲默认清零 (每拍只可能发一个)
            v_on  <= {NVOICE{1'b0}};
            v_off <= {NVOICE{1'b0}};

            // 事件锁存: 本拍被消费掉的那一位清掉, 其余留到下一拍
            pend_on  <= (pend_on  | key_on)  & ~(do_on  ? sel_on  : {NKEYS{1'b0}});
            pend_off <= (pend_off | key_off) & ~(do_off ? sel_off : {NKEYS{1'b0}});

            if (do_off) begin
                // 释放: 只发 note_off, 预留位保留 (再按 = 重触发同一振荡器)
                v_off <= off_oh;
            end else if (do_on) begin
                v_on <= tgt_oh;
                key_owned[k_on] <= 1'b1;
                key_voice[k_on] <= tgt_idx;
                // 预留表 / 归属键 / 音高表: 只写目标声部那一位
                for (i = 0; i < NVOICE; i = i + 1)
                    if (tgt_oh[i]) begin
                        v_owner_v[i]   <= 1'b1;
                        v_owner_key[i] <= k_on;
                        v_note_r[i]    <= k_on;
                    end
                rr_ptr <= rr_ptr + 1'b1;      // 抢占指针前进 (池满时才会用到)
            end
        end
    end

    // ---- 打包输出 ----
    genvar gi;
    generate
        for (gi = 0; gi < NVOICE; gi = gi + 1) begin : g_note
            assign v_note[gi*NKEYW +: NKEYW] = v_note_r[gi];
        end
    endgenerate

endmodule
