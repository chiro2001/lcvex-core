param(
    [Parameter(Mandatory = $true)] [string]$Root,
    [Parameter(Mandatory = $true)]
    [ValidateSet('old-negative', 'fixed')]
    [string]$Variant,
    [Parameter(Mandatory = $true)] [string]$SourceSha
)

# This script is copied into a fresh task-owned GamePC root and is invoked
# only by the locked runner.  It deliberately performs synthesis only; no
# fitter, STA, assembler, programmer, JTAG, Flash, reset or power operation
# is reachable from this entry point.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$rootPath = [System.IO.Path]::GetFullPath($Root)
$projectDir = Join-Path $rootPath 'quartus'
$srcDir = Join-Path $rootPath 'src'
$simDir = Join-Path $rootPath 'sim'
$outputDir = Join-Path $projectDir 'output_files'
$resultPath = Join-Path $rootPath 'probe-result.json'
$synthLog = Join-Path $rootPath 'synthesis.log'
$edaLog = Join-Path $rootPath 'quartus-eda.log'
$quartusRoot = 'D:\Software\intelFPGA_pro\21.4'
$quartusSh = Join-Path $quartusRoot 'quartus\bin64\quartus_sh.exe'
$quartusEda = Join-Path $quartusRoot 'quartus\bin64\quartus_eda.exe'

$result = [ordered]@{
    schema_version = 1
    task_id = 'T-20260920-023'
    variant = $Variant
    source_sha = $SourceSha
    root = $rootPath
    project = 'lcvex_logic_imm_probe'
    synthesis = [ordered]@{}
    postmap = [ordered]@{ semantic_status = 'NOT_RUN' }
    forbidden_artifacts = @()
    status = 'RUNNING'
}

function Write-Result {
    param([string]$Status)
    $result.status = $Status
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding UTF8
}

function Stop-Fail {
    param([string]$Reason)
    $result.failure_reason = $Reason
    Write-Result 'FAIL'
    Write-Error ("LOGIC_IMM_QUARTUS_PROBE_FAIL {0}" -f $Reason)
    exit 1
}

if (-not (Test-Path -LiteralPath $projectDir -PathType Container)) {
    Stop-Fail 'missing-quartus-project-directory'
}
if (-not (Test-Path -LiteralPath (Join-Path $projectDir 'lcvex_logic_imm_probe.qpf') -PathType Leaf)) {
    Stop-Fail 'missing-qpf'
}
if (-not (Test-Path -LiteralPath (Join-Path $projectDir 'lcvex_logic_imm_probe.qsf') -PathType Leaf)) {
    Stop-Fail 'missing-qsf'
}
if (-not (Test-Path -LiteralPath (Join-Path $srcDir 'lcvex_pkg.sv') -PathType Leaf)) {
    Stop-Fail 'missing-pkg-source'
}
if (-not (Test-Path -LiteralPath (Join-Path $srcDir 'lcvex_decode.sv') -PathType Leaf)) {
    Stop-Fail 'missing-decode-source'
}
if (-not (Test-Path -LiteralPath (Join-Path $srcDir 'lcvex_logic_imm_quartus_probe_top.sv') -PathType Leaf)) {
    Stop-Fail 'missing-probe-top'
}

# A stale database/report can make a short Quartus invocation look green.  A
# variant is therefore single-use and must enter synthesis with no output
# directory or database at all.
foreach ($stale in @(
        (Join-Path $projectDir 'output_files'),
        (Join-Path $projectDir 'db'),
        (Join-Path $projectDir 'incremental_db'),
        (Join-Path $projectDir 'greybox_tmp'))) {
    if (Test-Path -LiteralPath $stale) {
        Stop-Fail ("stale-output:{0}" -f $stale)
    }
}
if (-not (Test-Path -LiteralPath $quartusSh -PathType Leaf)) {
    Stop-Fail 'quartus_sh-missing'
}

Set-Location -LiteralPath $projectDir
& $quartusSh --flow compile lcvex_logic_imm_probe -c lcvex_logic_imm_probe `
    -start synthesis -end synthesis 2>&1 |
    Tee-Object -FilePath $synthLog
$synthExit = $LASTEXITCODE
$result.synthesis.exit_code = $synthExit

$reports = @(Get-ChildItem -LiteralPath $projectDir -Recurse -File -Filter '*.syn.rpt' |
    Where-Object { $_.FullName -notmatch '\\db\\' } | Sort-Object FullName)
if ($reports.Count -eq 0) {
    Stop-Fail 'missing-synthesis-report'
}
$report = $reports[0]
$reportText = Get-Content -LiteralPath $report.FullName -Raw
$synthLogText = if (Test-Path -LiteralPath $synthLog) {
    Get-Content -LiteralPath $synthLog -Raw
} else { '' }
$warning16788 = @($reportText -split "`r?`n" | Where-Object { $_ -match '16788' })
$errorLines = @($reportText -split "`r?`n" | Where-Object { $_ -match '(?i)\b[0-9]+\s+errors?\b' -and $_ -notmatch '(?i)\b0\s+errors?\b' })
$successful = ($reportText -match '(?i)(?:Synthesis|Flow) Status[^\r\n]*Successful') -or
    ($synthLogText -match '(?i)(?:Synthesis|Flow) Status[^\r\n]*Successful')
$zeroErrors = ($reportText -match '(?i)\b0\s+errors?\b') -and ($errorLines.Count -eq 0)
$result.synthesis.report = $report.FullName
$result.synthesis.report_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $report.FullName).Hash.ToLowerInvariant()
$result.synthesis.successful = $successful
$result.synthesis.zero_errors = $zeroErrors
$result.synthesis.warning_16788_count = $warning16788.Count
$result.synthesis.warning_16788_lines = @($warning16788 | Select-Object -First 8)
$result.synthesis.report_bytes = $report.Length

if (($synthExit -ne 0) -or (-not $successful) -or (-not $zeroErrors)) {
    Stop-Fail 'synthesis-not-successful-or-report-errors'
}

if ($Variant -eq 'old-negative') {
    if ($warning16788.Count -lt 1) {
        Stop-Fail 'old-negative-missing-warning-16788'
    }
    $result.synthesis.warning_contract = 'PASS_OLD_NEGATIVE_WARNING_16788'
} else {
    if ($warning16788.Count -ne 0) {
        Stop-Fail 'fixed-candidate-warning-16788'
    }
    $result.synthesis.warning_contract = 'PASS_FIXED_NO_WARNING_16788'
}

# Try to emit a simulator netlist.  The installed Quartus distribution may
# not include a usable HDL simulator or Arria-10 primitive models; that case
# is recorded as an explicit limitation and never promoted to semantic PASS.
if (Test-Path -LiteralPath $quartusEda -PathType Leaf) {
    $edaOutput = Join-Path $rootPath 'eda_output'
    New-Item -ItemType Directory -Force -Path $edaOutput | Out-Null
    & $quartusEda --simulation --tool=modelsim --format=verilog `
        --output_directory=$edaOutput lcvex_logic_imm_probe `
        -c lcvex_logic_imm_probe 2>&1 | Tee-Object -FilePath $edaLog
    $edaExit = $LASTEXITCODE
    $netlists = @(Get-ChildItem -LiteralPath $edaOutput -Recurse -File |
        Where-Object { $_.Extension -in @('.vo', '.v') } | Sort-Object FullName)
    $result.postmap.eda_exit_code = $edaExit
    $result.postmap.netlists = @($netlists | ForEach-Object { $_.FullName })
    if ($edaExit -ne 0) {
        Stop-Fail 'quartus-eda-failed'
    }
    if ($netlists.Count -eq 0) {
        $result.postmap.semantic_status = 'UNAVAILABLE_NO_NETLIST'
        $result.postmap.limitation = 'quartus_eda produced no Verilog simulation netlist'
    } else {
        $iverilog = Get-Command iverilog -ErrorAction SilentlyContinue
        $vvp = Get-Command vvp -ErrorAction SilentlyContinue
        $postmapTb = Join-Path $simDir 'lcvex_logic_imm_quartus_postmap_tb.sv'
        if ($null -eq $iverilog -or $null -eq $vvp -or
            -not (Test-Path -LiteralPath $postmapTb -PathType Leaf)) {
            $result.postmap.semantic_status = 'UNAVAILABLE_NO_COMPATIBLE_SIMULATOR'
            $result.postmap.limitation = 'netlist exists but iverilog/vvp or postmap TB is unavailable'
        } else {
            $simExe = Join-Path $rootPath 'postmap.vvp'
            $simBuildLog = Join-Path $rootPath 'postmap-build.log'
            $simRunLog = Join-Path $rootPath 'postmap-run.log'
            & $iverilog.Source -g2012 -s lcvex_logic_imm_quartus_postmap_tb `
                -o $simExe $netlists[0].FullName $postmapTb 2>&1 |
                Tee-Object -FilePath $simBuildLog
            $compileExit = $LASTEXITCODE
            if ($compileExit -ne 0) {
                $buildText = Get-Content -LiteralPath $simBuildLog -Raw
                if ($buildText -match '(?i)unknown module|undefined reference|primitive') {
                    $result.postmap.semantic_status = 'UNAVAILABLE_PRIMITIVE_MODEL'
                    $result.postmap.limitation = 'generated netlist requires vendor simulation primitives'
                } else {
                    Stop-Fail 'postmap-simulator-compile-failed'
                }
            } else {
                & $vvp.Source $simExe 2>&1 | Tee-Object -FilePath $simRunLog
                $runExit = $LASTEXITCODE
                $runText = Get-Content -LiteralPath $simRunLog -Raw
                if ($runText -match 'LOGIC_IMM_POSTMAP_SEMANTIC_PASS' -and $runExit -eq 0) {
                    $result.postmap.semantic_status = 'PASS'
                } elseif ($runText -match 'LOGIC_IMM_POSTMAP_SEMANTIC_MISMATCH') {
                    Stop-Fail 'postmap-semantic-mismatch'
                } else {
                    Stop-Fail 'postmap-simulator-failed-without-pass-marker'
                }
            }
        }
    }
} else {
    $result.postmap.semantic_status = 'UNAVAILABLE_QUARTUS_EDA_MISSING'
    $result.postmap.limitation = 'quartus_eda.exe is not present in the fixed Quartus 21.4 root'
}

$forbidden = @(Get-ChildItem -LiteralPath $rootPath -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension.ToLowerInvariant() -in @('.sof', '.pof', '.jic', '.rbf', '.jbc', '.svf', '.jam') })
$result.forbidden_artifacts = @($forbidden | ForEach-Object { $_.FullName })
if ($forbidden.Count -ne 0) {
    Stop-Fail 'forbidden-configuration-artifact-generated'
}

$result.status = if ($result.postmap.semantic_status -eq 'PASS') {
    'PASS_SYNTHESIS_AND_POSTMAP_SEMANTIC'
} else {
    'PASS_SYNTHESIS_WARNING_CONTRACT_POSTMAP_LIMITED'
}
Write-Result $result.status
Write-Output ("LOGIC_IMM_QUARTUS_PROBE_{0} variant={1} warning16788={2} postmap={3}" -f
    $result.status, $Variant, $result.synthesis.warning_16788_count,
    $result.postmap.semantic_status)
