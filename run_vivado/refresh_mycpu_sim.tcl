# Refresh the Golden Trace RTL source set after replacing rtl/mycpu.
# Intended for Vivado 2023.2.  It is safe to run repeatedly.

set script_dir  [file dirname [file normalize [info script]]]
set verify_root [file normalize [file join $script_dir ..]]
set rtl_dir     [file normalize [file join $verify_root rtl]]
set cpu_dir     [file normalize [file join $rtl_dir mycpu]]
set tb_dir      [file normalize [file join $verify_root testbench]]
set project_xpr [file normalize [file join $script_dir project loongson.xpr]]

if {![file exists $project_xpr]} {
    error "Vivado project not found: $project_xpr"
}
# The CPU files follow the normalized snake_case naming used by D:/LAcpu.
# Check several ownership-boundary files instead of one obsolete filename so
# a partial directory copy is still diagnosed accurately.
set cpu_required_files [list \
    cpu_types_pkg.sv \
    my_cpu.sv \
    mycpu_top.v \
    frontend.sv \
    ooo_backend.sv \
    load_store_unit.sv]
set cpu_missing_files {}
foreach required_file $cpu_required_files {
    if {![file exists [file join $cpu_dir $required_file]]} {
        lappend cpu_missing_files $required_file
    }
}
if {[llength $cpu_missing_files] != 0} {
    error "CPU source tree is incomplete: $cpu_dir; missing: [join $cpu_missing_files {, }]"
}

if {[current_project -quiet] eq ""} {
    open_project $project_xpr
} elseif {[get_property NAME [current_project]] ne "loongson"} {
    error "Close the current project before refreshing loongson.xpr"
}

catch {close_sim}

set srcset [get_filesets sources_1]
set simset [get_filesets sim_1]
set cpu_prefix "[string map {\\ /} $cpu_dir]/"
set soc_top_file [string map {\\ /} [file normalize [file join $rtl_dir soc_lite_top.sv]]]
set confreg_file [string map {\\ /} [file normalize [file join $rtl_dir CONFREG confreg.v]]]
set legacy_header [string map {\\ /} [file normalize [file join $rtl_dir mycpu_inst.vh]]]

# Remove the replaceable CPU RTL, top wrapper and confreg references.  IP
# children are owned by their XCI parent and must not be removed individually.
set old_rtl_files {}
foreach file_obj [get_files -quiet -of_objects $srcset] {
    set file_name [file normalize [get_property NAME $file_obj]]
    set file_name [string map {\\ /} $file_name]
    if {[string first $cpu_prefix $file_name] == 0 ||
        $file_name eq $soc_top_file ||
        $file_name eq $confreg_file ||
        $file_name eq $legacy_header} {
        lappend old_rtl_files $file_obj
    }
}
if {[llength $old_rtl_files] != 0} {
    remove_files -fileset sources_1 $old_rtl_files
}

set cpu_v_files  [lsort [glob -nocomplain -directory $cpu_dir *.v]]
set cpu_sv_files [lsort [glob -nocomplain -directory $cpu_dir *.sv]]
set cpu_vh_files [lsort [glob -nocomplain -directory $cpu_dir *.vh]]

set design_files [concat \
    [list [file join $rtl_dir soc_lite_top.sv]] \
    [list [file join $rtl_dir CONFREG confreg.v]] \
    $cpu_v_files $cpu_sv_files $cpu_vh_files]

set ip_files [list \
    [file join $rtl_dir xilinx_ip clk_pll clk_pll.xci] \
    [file join $rtl_dir xilinx_ip blk_mem_gen_0 blk_mem_gen_0.xci] \
    [file join $rtl_dir xilinx_ip div_gen_0 div_gen_0.xci] \
    [file join $rtl_dir xilinx_ip mult_gen_0 mult_gen_0.xci]]

foreach source_file $design_files {
    if {![file exists $source_file]} {
        error "Required source file not found: $source_file"
    }
}
foreach ip_file $ip_files {
    if {![file exists $ip_file]} {
        error "Required IP source not found: $ip_file"
    }
    if {[get_files -quiet [file tail $ip_file]] eq ""} {
        add_files -norecurse -fileset sources_1 $ip_file
    }
}

add_files -norecurse -fileset sources_1 $design_files

foreach source_file $cpu_sv_files {
    set file_obj [get_files -quiet [file normalize $source_file]]
    if {$file_obj ne ""} {
        set_property FILE_TYPE SystemVerilog $file_obj
    }
}
set top_sv [get_files -quiet [file normalize [file join $rtl_dir soc_lite_top.sv]]]
if {$top_sv ne ""} {
    set_property FILE_TYPE SystemVerilog $top_sv
}

set_property INCLUDE_DIRS [list $cpu_dir $rtl_dir] $srcset
set_property INCLUDE_DIRS [list $cpu_dir $rtl_dir $tb_dir] $simset
set_property TOP soc_lite_top $srcset
set_property TOP tb_top $simset

set_property -name "xsim.simulate.log_all_signals" -value "false" -objects $simset
set_property -name "xsim.simulate.runtime" -value "0ns" -objects $simset

set_property SOURCE_MGMT_MODE All [current_project]
catch {update_compile_order -fileset sources_1}
catch {update_compile_order -fileset sim_1}

set pkg_file [file normalize [file join $cpu_dir cpu_types_pkg.sv]]
set sim_order [get_files -quiet -compile_order sources -used_in simulation]
set pkg_index [lsearch -exact $sim_order $pkg_file]

# catch {reset_simulation} reset_message
puts "Golden Trace source refresh complete."
puts "  CPU Verilog files       : [llength $cpu_v_files]"
puts "  CPU SystemVerilog files : [llength $cpu_sv_files]"
puts "  CPU header files        : [llength $cpu_vh_files]"
puts "  cpu_types_pkg sim index : $pkg_index"

launch_simulation -scripts_only -mode behavioral
