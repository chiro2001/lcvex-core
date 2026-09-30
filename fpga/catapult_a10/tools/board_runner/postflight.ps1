[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^T-[0-9]{8}-[0-9]{3}$')]
    [string] $TaskId,
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $TaskRoot,
    [string] $ContractPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = [System.IO.Path]::GetFullPath($TaskRoot)
. (Join-Path $PSScriptRoot 'contract_common.ps1')
$contractPath = Get-BoardContractPath -TaskRoot $root -ContractPath $ContractPath
$contract = Get-BoardContract -Path $contractPath -TaskId $TaskId
$quartusBin = [string]$contract.paths.quartus_bin
$golden = [string]$contract.golden.path
$expectedGoldenBytes = [int64]$contract.golden.bytes
$expectedGoldenHash = [string]$contract.golden.sha256
$expectedGoldenDesign = [string]$contract.golden.design_hash
$expectedJtag = [string]$contract.hardware.jtag_id
$expectedConsole = [string]$contract.hardware.console_cable
$serverPort = [int]$contract.hardware.server_port
$requiredNodes = @($contract.hardware.required_nodes)

function Marker-Ok([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    return (Get-Item -LiteralPath $Path).Length -gt 0
}

Write-Output ('TASK=' + $TaskId)
Write-Output ('POSTFLIGHT_STARTED_AT=' + (Get-Date).ToString('o'))
Write-Output ('CONTRACT_ID=' + [string]$contract.contract_id)
Write-Output ('CONTRACT_SHA256=' + (Get-FileHash -LiteralPath $contractPath -Algorithm SHA256).Hash.ToLowerInvariant())
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw 'task root missing during postflight'
}
$candidateMarker = Join-Path $root 'candidate-quartus-pgm.once'
$goldenMarker = Join-Path $root 'golden-quartus-pgm.once'
$candidateMarkerOk = Marker-Ok $candidateMarker
$goldenMarkerOk = Marker-Ok $goldenMarker
Write-Output ('CANDIDATE_MARKER=' + ([int]$candidateMarkerOk) + '|path=' + $candidateMarker)
Write-Output ('GOLDEN_MARKER=' + ([int]$goldenMarkerOk) + '|path=' + $goldenMarker)

$goldenItem = Get-Item -LiteralPath $golden -ErrorAction Stop
$goldenHash = (Get-FileHash -LiteralPath $golden -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Output ('GOLDEN_FILE_BYTES=' + $goldenItem.Length)
Write-Output ('GOLDEN_FILE_SHA256=' + $goldenHash)

$busy = @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -match '^(quartus|quartus_sh|quartus_syn|quartus_fit|quartus_sta|quartus_asm|quartus_pgm|qsys|ip-generate|vsim|questa|modelsim|nios2-terminal)(\.exe)?$'
})
Write-Output ('POST_BUSY_COUNT=' + $busy.Count)
foreach ($process in $busy) {
    Write-Output ('BUSY=' + $process.ProcessId + '|' + $process.Name + '|' + $process.ExecutablePath)
}

$listeners = @(Get-NetTCPConnection -LocalPort $serverPort -State Listen -ErrorAction SilentlyContinue)
Write-Output ('POST_PORT1310_COUNT=' + $listeners.Count)
foreach ($listener in $listeners) {
    Write-Output ('PORT1310=' + $listener.OwningProcess + '|' + $listener.LocalAddress + '|' + $listener.LocalPort)
}

$standard = @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -match '^jtagserver(\.exe)?$' -and $_.ExecutablePath -eq (Join-Path $quartusBin 'jtagserver.exe')
})
Write-Output ('STANDARD_SERVER_COUNT=' + $standard.Count)
foreach ($server in $standard) {
    Write-Output ('STANDARD_SERVER=pid=' + $server.ProcessId + '|path=' + $server.ExecutablePath)
}

$jtagConfig = Join-Path $quartusBin 'jtagconfig.exe'
$lines = @(& $jtagConfig -n 2>&1)
$exitCode = $LASTEXITCODE
$text = [string]::Join("`n", $lines)
Write-Output ('JTAGCONFIG_EXIT=' + $exitCode)
foreach ($line in $lines) {
    Write-Output ('JTAG=' + $line)
}
$nodesOk = $true
foreach ($node in $requiredNodes) {
    $nodesOk = $nodesOk -and $text.Contains([string]$node)
}
$chainOk = $exitCode -eq 0 -and $text.Contains($expectedConsole) -and
    $text.Contains($expectedJtag) -and $text.Contains($expectedGoldenDesign) -and $nodesOk
Write-Output ('GOLDEN_UART_PHY_OK=' + $nodesOk)
Write-Output ('FINAL_GOLDEN_CHAIN_OK=' + $chainOk)

$accepted = $candidateMarkerOk -and $goldenMarkerOk -and
    $goldenItem.Length -eq $expectedGoldenBytes -and $goldenHash -eq $expectedGoldenHash -and
    $busy.Count -eq 0 -and $listeners.Count -eq 0 -and $standard.Count -eq 1 -and $chainOk
$result = [ordered]@{
    schema_version = 1
    task_id = $TaskId
    contract_id = [string]$contract.contract_id
    contract_sha256 = (Get-FileHash -LiteralPath $contractPath -Algorithm SHA256).Hash.ToLowerInvariant()
    task_root = $root
    candidate_marker = $candidateMarkerOk
    golden_marker = $goldenMarkerOk
    golden_bytes = [int64]$goldenItem.Length
    golden_sha256 = $goldenHash
    busy_count = $busy.Count
    port1310_count = $listeners.Count
    standard_server_count = $standard.Count
    golden_chain_ok = $chainOk
    result = if ($accepted) { 'PASS' } else { 'FAIL' }
    finished_at = (Get-Date).ToString('o')
}
$resultPath = Join-Path $root 'postflight-result.json'
[IO.File]::WriteAllText($resultPath, (($result | ConvertTo-Json -Depth 10) + "`n"), [Text.UTF8Encoding]::new($false))
Write-Output (($result | ConvertTo-Json -Depth 10))
Write-Output ('POSTFLIGHT_RESULT=' + $result.result)
if (-not $accepted) {
    exit 1
}
Write-Output 'GOLDEN_POSTFLIGHT_PASS'
