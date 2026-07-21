param(
    [int]$Seed = 20260716,
    [ValidateSet(0, 1)] [int]$KeepBuild = 0
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$rtl = Join-Path $root 'rtl\mycpu'
$tb = Join-Path $PSScriptRoot 'unit\tb_rat32_extended.sv'
$vivado = 'D:\vavido\Vivado\2023.2\bin'
$build = Join-Path $PSScriptRoot 'build\rat32_mutations'

$mutations = @(
    @{ Name='lane1_raw_no_lane0_bypass'; Old='assign query_tag2 = lane0_writes_rs2 ? alloc_tag : map_tag[query_rs2];'; New='assign query_tag2 = map_tag[query_rs2];' },
    @{ Name='lane1_raw_src1_no_lane0_bypass'; Old='assign query_tag3 = lane0_writes_rs3 ? alloc_tag : map_tag[query_rs3];'; New='assign query_tag3 = map_tag[query_rs3];' },
    @{ Name='lane1_mapping_uses_lane0_tag'; Old='map_tag[alloc1_rd]   <= alloc1_tag;'; New='map_tag[alloc1_rd]   <= alloc_tag;' },
    @{ Name='x0_mapping_can_become_pending'; Old='map_valid[0] <= 1''b0;'; New='/* MUTATION: x0 invariant removed */'; Old2='if (alloc_valid && alloc_rf_we && (alloc_rd != 5''h0)) begin'; New2='if (alloc_valid && alloc_rf_we) begin'; Old3='assign query_pending0 = (query_rs0 != 5''h0) && map_valid[query_rs0];'; New3='assign query_pending0 = map_valid[query_rs0];' },
    @{ Name='commit_requires_wrong_tag'; Old='map_valid[commit_rd] && (map_tag[commit_rd] == commit_tag))'; New='map_valid[commit_rd] && (map_tag[commit_rd] != commit_tag))' },
    @{ Name='lane1_checkpoint_misses_lane0'; Old="if (alloc_valid && alloc_rf_we && (alloc_rd != 5'h0)) begin`r`n                    checkpoint_valid[alloc1_tag][alloc_rd] <= 1'b1;"; New="if (1'b0 && alloc_valid && alloc_rf_we && (alloc_rd != 5'h0)) begin`r`n                    checkpoint_valid[alloc1_tag][alloc_rd] <= 1'b1;" },
    @{ Name='checkpoint0_excludes_self'; Old='checkpoint_valid[alloc_tag][alloc_rd] <= 1''b1;'; New='checkpoint_valid[alloc_tag][alloc_rd] <= 1''b0;' },
    @{ Name='recovery_ignores_live_mask'; Old="checkpoint_valid[recover_tag][i] &&`r`n                                rob_live_mask[checkpoint_tag[recover_tag][i]]"; New='checkpoint_valid[recover_tag][i]' }
)

if (Test-Path -LiteralPath $build) { Remove-Item -LiteralPath $build -Recurse -Force }
New-Item -ItemType Directory -Path $build | Out-Null
$source = Get-Content -Raw -LiteralPath (Join-Path $rtl 'RAT32.v')
$detected = 0
$results = @()

foreach ($m in $mutations) {
    $dir = Join-Path $build $m.Name
    New-Item -ItemType Directory -Path $dir | Out-Null
    $mutant = $source.Replace($m.Old, $m.New)
    if ($mutant -eq $source) { throw "Mutation pattern not found: $($m.Name)" }
    if ($m.ContainsKey('Old2')) {
        $second = $mutant.Replace($m.Old2, $m.New2)
        if ($second -eq $mutant) { throw "Secondary mutation pattern not found: $($m.Name)" }
        $mutant = $second
    }
    if ($m.ContainsKey('Old3')) {
        $third = $mutant.Replace($m.Old3, $m.New3)
        if ($third -eq $mutant) { throw "Tertiary mutation pattern not found: $($m.Name)" }
        $mutant = $third
    }
    $mutantPath = Join-Path $dir 'RAT32_mutant.sv'
    [IO.File]::WriteAllText($mutantPath, $mutant, [Text.UTF8Encoding]::new($false))
    Push-Location $dir
    try {
        & (Join-Path $vivado 'xvlog.bat') -sv -i $rtl $mutantPath $tb *> compile.log
        if ($LASTEXITCODE -ne 0) { throw "compile failed: $($m.Name)" }
        & (Join-Path $vivado 'xelab.bat') tb_rat32_extended -s mutant_sim -timescale 1ns/1ps --override_timeunit --override_timeprecision *> elaborate.log
        if ($LASTEXITCODE -ne 0) { throw "elaboration failed: $($m.Name)" }
        $simArgs = @(
            "--testplusarg=`"SEED=$Seed`"",
            '--testplusarg="TEST=directed"',
            '--testplusarg="MIN_COVERAGE=0"',
            '--testplusarg="STOP_ON_ERROR=1"',
            '--runall'
        )
        & (Join-Path $vivado 'xsim.bat') mutant_sim @simArgs *> simulate.log
        $hit = Select-String -LiteralPath simulate.log -Pattern '\[RAT-EXT-(SCOREBOARD-FAIL|ASSERT-FAIL|PROTOCOL-FAIL|OWNERSHIP-FAIL)|\[RAT-EXT\] FAILURES=' -Quiet
        if ($hit) { $detected++; $results += "[MUTATION-DETECTED] $($m.Name)" }
        else { $results += "[MUTATION-MISSED] $($m.Name)" }
    }
    finally { Pop-Location }
}

$results | ForEach-Object { Write-Host $_ }
Write-Host "[MUTATION-SUMMARY] detected=$detected total=$($mutations.Count)"
if (!$KeepBuild -and $detected -eq $mutations.Count) {
    Remove-Item -LiteralPath $build -Recurse -Force
}
if ($detected -ne $mutations.Count) { throw 'RAT32 mutation score is incomplete' }
