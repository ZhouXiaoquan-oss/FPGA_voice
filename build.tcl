# build.tcl — v10 成品版复现构建（Gowin gw_sh）
#
# 用法：在本仓库根目录执行（必须，因为 src/sine_gen.v 用相对路径读 mem/sine_lut.mem）
#   "<Gowin 安装目录>/IDE/bin/gw_sh" build.tcl
#
# 环境：Gowin V1.9.11.03 Education (81398)
# 器件：GW5AT-LV60PG484AC1/I0
# 配方（与 v10 定选位流一致）：place1 / route2 / cro1 / correct_hold1(工程默认) /
#       maxfan100 / bit_compress1 / vccx 1.8
# 说明：syn 与 pnr 必须在同一个 gw_sh 会话内连续执行（分两次调用会改变结果）

open_project ./d2_screen_pnr.gprj
set_option -top_module top_touch
set_option -vccx 1.8
set_option -place_option 1
set_option -route_option 2
set_option -clock_route_order 1
set_option -route_maxfan 100
set_option -bit_compress 1
run syn
run pnr
exit
