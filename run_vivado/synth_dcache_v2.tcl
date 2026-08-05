set root_dir [file normalize [file join [file dirname [info script]] ..]]
set rtl_dir [file join $root_dir rtl mycpu]
puts "root_dir=$root_dir"
puts "rtl_dir=$rtl_dir"
create_project -in_memory -part xc7a200tfbg676-1
add_files [list [file join $rtl_dir DCache.v]]
set_property include_dirs [list $rtl_dir] [current_fileset]
synth_design -top DCache -part xc7a200tfbg676-1
report_utilization -hierarchical -file [file join [file dirname [info script]] dcache_v2_utilization.rpt]
report_timing_summary -file [file join [file dirname [info script]] dcache_v2_timing.rpt]
exit
