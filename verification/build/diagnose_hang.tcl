run 1760 us
set base /tb_top/soc_lite/u_cpu/u_mycpu
foreach sig {
    u_backend/u_commit_recovery/u_ROB/head
    u_backend/u_commit_recovery/u_ROB/tail
    u_backend/u_commit_recovery/u_ROB/count
    u_backend/u_commit_recovery/u_ROB/valid
    u_backend/u_commit_recovery/u_ROB/done
    u_backend/u_scheduler/u_DISPATCH_QUEUE/count
    u_backend/u_scheduler/u_DISPATCH_QUEUE/valid
    u_backend/u_rename_dispatch/u_RAT/map_valid
    u_frontend/u_IF/meta_count
    u_frontend/u_IF/ibuf_count
    u_frontend/u_IF/f1_valid
    pipeline_flush
    recover_valid
} {
    puts "DIAG $sig = [get_value -radix hex $base/$sig]"
}
quit
