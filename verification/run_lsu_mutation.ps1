param(
    [ValidateSet('all','load_sign_extension','store_byte_mask','squashed_load_completion','duplicate_store_write','storebuffer_count','load_not_popped')]
    [string]$Mutation = 'all',
    [int]$Seed = 20260716
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sourceRtl = Join-Path $root 'rtl\mycpu'
$tb = Join-Path $PSScriptRoot 'unit\tb_lsu_extended.sv'
$vivadoBin = 'D:\vavido\Vivado\2023.2\bin'
$xvlog = Join-Path $vivadoBin 'xvlog.bat'
$xelab = Join-Path $vivadoBin 'xelab.bat'
$xsim = Join-Path $vivadoBin 'xsim.bat'
$allMutations = @(
    'load_sign_extension',
    'store_byte_mask',
    'squashed_load_completion',
    'duplicate_store_write',
    'storebuffer_count',
    'load_not_popped'
)
$selected = if ($Mutation -eq 'all') { $allMutations } else { @($Mutation) }
$rtlFiles = @(
    'cpu_types_pkg.sv','defines.vh','load_queue.sv','store_queue.sv',
    'store_buffer.sv','memory_order_checker.sv','lsu_arbiter.sv',
    'load_data_aligner.sv','load_store_unit.sv'
)

function Replace-Checked([string]$Path, [string]$Old, [string]$New) {
    $text = Get-Content -LiteralPath $Path -Raw
    if (!$text.Contains($Old)) { throw "mutation pattern not found in ${Path}: $Old" }
    Set-Content -LiteralPath $Path -Value ($text.Replace($Old, $New)) -NoNewline
}

$killed = 0
foreach ($name in $selected) {
    $build = Join-Path $PSScriptRoot "build\lsu_mutation\$name"
    $mutRtl = Join-Path $build 'rtl'
    if (Test-Path -LiteralPath $build) { Remove-Item -LiteralPath $build -Recurse -Force }
    New-Item -ItemType Directory -Path $mutRtl -Force | Out-Null
    foreach ($file in $rtlFiles) {
        Copy-Item -LiteralPath (Join-Path $sourceRtl $file) -Destination (Join-Path $mutRtl $file)
    }

    switch ($name) {
        'load_sign_extension' {
            Replace-Checked (Join-Path $mutRtl 'load_data_aligner.sv') `
                '`RAM_EXT_B_S:ext_out = {{24{real_din[7]}},real_din[7:0]};' `
                '`RAM_EXT_B_S:ext_out = {24''h000000,real_din[7:0]};'
        }
        'store_byte_mask' {
            Replace-Checked (Join-Path $mutRtl 'load_store_unit.sv') `
                '`RAM_WE_B: make_store_wen = 4''b0001 << off;' `
                '`RAM_WE_B: make_store_wen = 4''b0010 << off;'
        }
        'squashed_load_completion' {
            Replace-Checked (Join-Path $mutRtl 'lsu_arbiter.sv') `
                'load_event = load_response_seen && !flush && !active_killed;' `
                'load_event = load_response_seen && !flush;'
        }
        'duplicate_store_write' {
            Replace-Checked (Join-Path $mutRtl 'lsu_arbiter.sv') `
                'store_pop = store_event;' 'store_pop = 1''b0;'
        }
        'storebuffer_count' {
            Replace-Checked (Join-Path $mutRtl 'store_buffer.sv') `
                '2''b01: count <= count + 1;' '2''b01: count <= count + 2;'
        }
        'load_not_popped' {
            Replace-Checked (Join-Path $mutRtl 'lsu_arbiter.sv') `
                'load_pop = load_event;' 'load_pop = 1''b0;'
        }
    }

    Push-Location $build
    try {
        $sources = @(
            (Join-Path $mutRtl 'cpu_types_pkg.sv'),
            (Join-Path $mutRtl 'load_queue.sv'),
            (Join-Path $mutRtl 'store_queue.sv'),
            (Join-Path $mutRtl 'store_buffer.sv'),
            (Join-Path $mutRtl 'memory_order_checker.sv'),
            (Join-Path $mutRtl 'lsu_arbiter.sv'),
            (Join-Path $mutRtl 'load_data_aligner.sv'),
            (Join-Path $mutRtl 'load_store_unit.sv'),
            $tb
        )
        # The mutated defines.vh includes shared width headers that are not
        # mutation targets; keep the temporary RTL path first in search order.
        & $xvlog -sv -i $mutRtl -i $sourceRtl -i (Join-Path $PSScriptRoot 'common') @sources *> 'compile.log'
        if ($LASTEXITCODE -ne 0) { throw "mutant $name did not compile; see $build\compile.log" }
        & $xelab 'tb_lsu_extended' -s 'tb_lsu_mutation_sim' -debug typical `
            -timescale 1ns/1ps --override_timeunit --override_timeprecision `
            -L xil_defaultlib -L unisims_ver -L unimacro_ver *> 'elaborate.log'
        if ($LASTEXITCODE -ne 0) { throw "mutant $name did not elaborate; see $build\elaborate.log" }
        & $xsim 'tb_lsu_mutation_sim' `
            "--testplusarg=`"SEED=$Seed`"" `
            '--testplusarg="CYCLES=1000"' '--testplusarg="TEST=mutation"' `
            '--testplusarg="MIN_COVERAGE=90"' '--testplusarg="STOP_ON_ERROR=1"' `
            '--testplusarg="STAGE=5"' '--runall' *> 'simulation.log'
        $failure = Select-String -LiteralPath 'simulation.log' `
            -Pattern '\[LSU-EXT-(SCOREBOARD-FAIL|ASSERT-FAIL|PROTOCOL-FAIL|WATCHDOG|MEMORY-FAIL)|\[LSU-EXT\] STAGE5 FAILURES=' -Quiet
        if (!$failure) { throw "MUTANT SURVIVED: $name; see $build\simulation.log" }
        $killed++
        Write-Host "[LSU-MUTATION-KILLED] $name"
    }
    finally { Pop-Location }
}

Write-Host "[LSU-MUTATION-SUMMARY] killed=$killed total=$($selected.Count)"
if ($killed -ne $selected.Count) { throw 'mutation coverage incomplete' }
