# build_screen_pnr_v10_pnr.tcl -- v10 PnR ONLY, on the v10 netlist produced by
# build_screen_pnr_v10_syn.tcl.  Recipe is the mandated one, unchanged:
#   place_option 1 / route_option 2 / clock_route_order 1 / correct_hold 1
#   (project default) / route_maxfan 100 / bit_compress 1 / vccx 1.8
open_project F:/fiehuo/ddr_audio_v1_20261030/work/d2_screen_pnr/d2_screen_pnr.gprj
set_option -vccx 1.8
set_option -top_module top_touch
set_option -place_option 1
set_option -route_option 2
set_option -clock_route_order 1
set_option -route_maxfan 100
set_option -bit_compress 1
run pnr
exit
