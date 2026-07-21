param(
    [ValidateSet('rob16', 'rob16_ext', 'dispatch_queue4', 'rat32', 'rat32_ext', 'lsu', 'lsu_ext', 'lsu_forward', 'dcache', 'privilege', 'decoder')]
    [string]$Test = 'rob16',
    [int]$Seed = 1,
    [int]$Cycles = 1000,
    [int]$MinCoverage = 90,
    [ValidateRange(1, 5)]
    [int]$Stage = 3,
    [ValidateSet(0, 1)]
    [int]$StopOnError = 0,
    [ValidateSet(0, 1)]
    [int]$StrictAmbiguity = 0,
    [string]$Mode = 'all'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$rtl = Join-Path $root 'rtl\mycpu'
$unit = Join-Path $PSScriptRoot 'unit'
$vivadoBin = 'D:\vavido\Vivado\2023.2\bin'
$xvlog = Join-Path $vivadoBin 'xvlog.bat'
$xelab = Join-Path $vivadoBin 'xelab.bat'
$xsim = Join-Path $vivadoBin 'xsim.bat'
$build = Join-Path $PSScriptRoot "build\$Test"

if (!(Test-Path -LiteralPath $xvlog)) {
    throw "Vivado xvlog.bat not found: $xvlog"
}

if (Test-Path -LiteralPath $build) {
    Remove-Item -LiteralPath $build -Recurse -Force
}
New-Item -ItemType Directory -Path $build | Out-Null
Push-Location $build
try {
    $package = Join-Path $rtl 'cpu_types_pkg.sv'
    $defines = Join-Path $rtl 'defines.vh'
    $tb = Join-Path $unit "tb_$Test.sv"

    $sources = @()
    switch ($Test) {
        'rob16' {
            $top = 'tb_rob16'
            $sources = @($package, (Join-Path $rtl 'ROB16.sv'), $tb)
        }
        'rob16_ext' {
            $top = 'tb_rob16_extended'
            $tb = Join-Path $unit 'tb_rob16_extended.sv'
            $sources = @($package, (Join-Path $rtl 'ROB16.sv'), $tb)
        }
        'dispatch_queue4' {
            $top = 'tb_dispatch_queue4'
            $sources = @($package, (Join-Path $rtl 'DispatchQueue4.sv'), $tb)
        }
        'rat32' {
            $top = 'tb_rat32'
            $sources = @((Join-Path $rtl 'RAT32.v'), $tb)
        }
        'rat32_ext' {
            $top = 'tb_rat32_extended'
            $tb = Join-Path $unit 'tb_rat32_extended.sv'
            $sources = @((Join-Path $rtl 'RAT32.v'), $tb)
        }
        'lsu' {
            $top = 'tb_lsu'
            $sources = @(
                $package,
                (Join-Path $rtl 'load_queue.sv'),
                (Join-Path $rtl 'store_queue.sv'),
                (Join-Path $rtl 'store_buffer.sv'),
                (Join-Path $rtl 'memory_order_checker.sv'),
                (Join-Path $rtl 'lsu_arbiter.sv'),
                (Join-Path $rtl 'load_data_aligner.sv'),
                (Join-Path $rtl 'load_store_unit.sv'),
                $tb
            )
        }
        'lsu_ext' {
            $top = 'tb_lsu_extended'
            $tb = Join-Path $unit 'tb_lsu_extended.sv'
            $sources = @(
                $package,
                (Join-Path $rtl 'load_queue.sv'),
                (Join-Path $rtl 'store_queue.sv'),
                (Join-Path $rtl 'store_buffer.sv'),
                (Join-Path $rtl 'memory_order_checker.sv'),
                (Join-Path $rtl 'lsu_arbiter.sv'),
                (Join-Path $rtl 'load_data_aligner.sv'),
                (Join-Path $rtl 'load_store_unit.sv'),
                $tb
            )
        }
        'lsu_forward' {
            $top = 'tb_lsu_store_load_forwarding'
            $tb = Join-Path $unit 'tb_lsu_store_load_forwarding.sv'
            $sources = @(
                $package,
                (Join-Path $rtl 'load_queue.sv'),
                (Join-Path $rtl 'store_queue.sv'),
                (Join-Path $rtl 'store_buffer.sv'),
                (Join-Path $rtl 'memory_order_checker.sv'),
                (Join-Path $rtl 'lsu_arbiter.sv'),
                (Join-Path $rtl 'load_data_aligner.sv'),
                (Join-Path $rtl 'load_store_unit.sv'),
                $tb
            )
        }
        'dcache' {
            $top = 'tb_dcache'
            $ipRoot = Join-Path $root 'rtl\xilinx_ip\blk_mem_gen_0'
            $ipModel = Join-Path $ipRoot 'simulation\blk_mem_gen_v8_4.v'
            $ipWrapper = Join-Path $ipRoot 'sim\blk_mem_gen_0.v'
            $sources = @($ipModel, $ipWrapper, (Join-Path $rtl 'DCache.v'), $tb)
        }
        'privilege' {
            $top = 'tb_privilege_supervisor'
            $tb = Join-Path $unit 'tb_privilege_supervisor.sv'
            $sources = @($package, (Join-Path $rtl 'privilege_system.sv'), $tb)
        }
        'decoder' {
            $top = 'tb_instruction_decoder'
            $tb = Join-Path $unit 'tb_instruction_decoder.sv'
            $sources = @(
                $package,
                (Join-Path $rtl 'CU.v'),
                (Join-Path $rtl 'EXT.v'),
                (Join-Path $rtl 'system_decode.sv'),
                (Join-Path $rtl 'instruction_decoder.sv'),
                $tb
            )
        }
    }

    Write-Host "[UNIT] compiling $Test"
    & $xvlog -sv -i $rtl -i (Join-Path $PSScriptRoot 'common') @sources
    if ($LASTEXITCODE -ne 0) { throw "xvlog failed for $Test" }

    & $xelab "$top" -s "${top}_sim" -debug typical -timescale 1ns/1ps --override_timeunit --override_timeprecision -L xil_defaultlib -L unisims_ver -L unimacro_ver
    if ($LASTEXITCODE -ne 0) { throw "xelab failed for $Test" }

    $simArgs = @('-runall')
    if ($Test -in @('rob16_ext', 'dispatch_queue4', 'rat32_ext', 'lsu_ext')) {
        $simArgs = @(
            "--testplusarg=`"SEED=$Seed`"",
            "--testplusarg=`"CYCLES=$Cycles`"",
            "--testplusarg=`"TEST=$Mode`"",
            "--testplusarg=`"MIN_COVERAGE=$MinCoverage`"",
            "--testplusarg=`"STOP_ON_ERROR=$StopOnError`"",
            "--testplusarg=`"STRICT_AMBIGUITY=$StrictAmbiguity`"",
            "--testplusarg=`"STAGE=$Stage`"",
            '--runall'
        )
    }
    & $xsim "${top}_sim" @simArgs
    if ($LASTEXITCODE -ne 0) { throw "xsim failed for $Test" }

    $simLog = Join-Path $build 'xsim.log'
    if (Test-Path -LiteralPath $simLog) {
        $unitFailed = Select-String -LiteralPath $simLog -SimpleMatch '[UNIT-FAIL]' -Quiet
        $robExtendedFailed = Select-String -LiteralPath $simLog -SimpleMatch '[ROB-EXT-FAIL]' -Quiet
        $robExtendedAssertionFailed = Select-String -LiteralPath $simLog -Pattern 'ROB-EXT-PROTOCOL|ROB-EXT-INVARIANT|ROB-EXT-WATCHDOG' -Quiet
        $dispatchQueueFailed = Select-String -LiteralPath $simLog -Pattern '\[DQ-(SCOREBOARD-FAIL|ASSERT-FAIL|PROTOCOL-FAIL|WATCHDOG|FAILURES|COVER-FAIL)' -Quiet
        $dispatchStrictAmbiguityFailed = ($Test -eq 'dispatch_queue4') -and
            ($StrictAmbiguity -eq 1) -and
            (Select-String -LiteralPath $simLog -SimpleMatch '[DQ-SPEC-AMBIGUITY]' -Quiet)
        $ratExtendedFailed = Select-String -LiteralPath $simLog -Pattern '\[RAT-EXT-(SCOREBOARD-FAIL|ASSERT-FAIL|PROTOCOL-FAIL|OWNERSHIP-FAIL|WATCHDOG)|\[RAT-EXT\] FAILURES=' -Quiet
        $lsuExtendedFailed = Select-String -LiteralPath $simLog -Pattern '\[LSU-EXT-(SCOREBOARD-FAIL|ASSERT-FAIL|PROTOCOL-FAIL|WATCHDOG|MEMORY-FAIL)|\[LSU-EXT\] STAGE[0-9]+ FAILURES=' -Quiet
        if ($unitFailed -or $robExtendedFailed -or $robExtendedAssertionFailed -or
            $dispatchQueueFailed -or $dispatchStrictAmbiguityFailed -or
            $ratExtendedFailed -or $lsuExtendedFailed) {
            throw "verification test reported a failure: $Test"
        }
    }
}
finally {
    Pop-Location
}
