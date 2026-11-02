# build_screen_pnr_v10_full.tcl -- v10 FULL flow (syn + pnr in ONE gw_sh session,
# exactly the flow that produced the passing v7 bitstream).
# v10 RTL = FINAL HMI object map (user-confirmed 2026-11-01):
#   page0: 回声开关 obj4, 回声换挡 obj5, 琴键 lamp NAMES bt0..bt11 (ids irrelevant)
#   page1: 3 滑音 4 震音 5 合唱 6 32音测试 7 REV 8 VIB 10 音色
#          11 降八度 12 高八度 13 效果器开关 14 延迟档位 15 跟弹开关 16 选曲
# MANDATED recipe (unchanged): place1 / route2 / cro1 / correct_hold1 (project
# default) / maxfan100 / bit_compress1 / vccx 1.8 ; CST/SDC untouched.
open_project F:/fiehuo/ddr_audio_v1_20261030/work/d2_screen_pnr/d2_screen_pnr.gprj
set_option -vccx 1.8
set_option -top_module top_touch
set_option -place_option 1
set_option -route_option 2
set_option -clock_route_order 1
set_option -route_maxfan 100
set_option -bit_compress 1
run syn
run pnr
exit
