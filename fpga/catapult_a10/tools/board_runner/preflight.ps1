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
$candidate = [string]$contract.candidate.path
$golden = [string]$contract.golden.path
$expectedCandidateBytes = [int64]$contract.candidate.bytes
$expectedCandidateHash = [string]$contract.candidate.sha256
$expectedGoldenBytes = [int64]$contract.golden.bytes
$expectedGoldenHash = [string]$contract.golden.sha256
$expectedGoldenDesign = [string]$contract.golden.design_hash
$expectedJtag = [string]$contract.hardware.jtag_id
$expectedConsole = [string]$contract.hardware.console_cable
$requiredNodes = @($contract.hardware.required_nodes)
$initialChainPolicy = Get-BoardInitialChainPolicy -Contract $contract

function File-Record([string] $Path) {
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    [ordered]@{
        path = $item.FullName
        bytes = [int64]$item.Length
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

Write-Output ('TASK=' + $TaskId)
Write-Output ('PREFLIGHT_STARTED_AT=' + (Get-Date).ToString('o'))
Write-Output ('TASK_ROOT=' + $root)
Write-Output ('CONTRACT_ID=' + [string]$contract.contract_id)
Write-Output ('CONTRACT_SHA256=' + (Get-FileHash -LiteralPath $contractPath -Algorithm SHA256).Hash.ToLowerInvariant())
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw ('task root is missing: ' + $root)
}

$candidateRecord = File-Record $candidate
$goldenRecord = File-Record $golden
Write-Output ('CANDIDATE=bytes=' + $candidateRecord.bytes + '|sha256=' + $candidateRecord.sha256)
Write-Output ('GOLDEN=bytes=' + $goldenRecord.bytes + '|sha256=' + $goldenRecord.sha256)
if ($candidateRecord.bytes -ne $expectedCandidateBytes -or $candidateRecord.sha256 -ne $expectedCandidateHash) {
    throw 'candidate identity mismatch'
}
if ($goldenRecord.bytes -ne $expectedGoldenBytes -or $goldenRecord.sha256 -ne $expectedGoldenHash) {
    throw 'golden identity mismatch'
}

$busy = @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -match '^(quartus|quartus_sh|quartus_syn|quartus_fit|quartus_sta|quartus_asm|quartus_pgm|qsys|ip-generate|vsim|questa|modelsim|nios2-terminal)(\.exe)?$'
})
Write-Output ('BUSY_COUNT=' + $busy.Count)
foreach ($process in $busy) {
    Write-Output ('BUSY=' + $process.ProcessId + '|' + $process.Name + '|' + $process.ExecutablePath)
}
if ($busy.Count -ne 0) {
    throw 'conflicting EDA/programmer/terminal process exists'
}

$listeners = @(Get-NetTCPConnection -LocalPort 1310 -State Listen -ErrorAction SilentlyContinue)
Write-Output ('PORT1310_COUNT=' + $listeners.Count)
foreach ($listener in $listeners) {
    Write-Output ('PORT1310=' + $listener.OwningProcess + '|' + $listener.LocalAddress + '|' + $listener.LocalPort)
}
if ($listeners.Count -ne 0) {
    throw 'port 1310 is already occupied'
}

$standard = @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -match '^jtagserver(\.exe)?$' -and $_.ExecutablePath -eq (Join-Path $quartusBin 'jtagserver.exe')
})
Write-Output ('STANDARD_SERVER_COUNT=' + $standard.Count)
foreach ($server in $standard) {
    Write-Output ('STANDARD_SERVER=pid=' + $server.ProcessId + '|path=' + $server.ExecutablePath)
}
if ($standard.Count -ne 1) {
    throw 'standard jtagserver identity count mismatch'
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
$cableOk = $text.Contains($expectedConsole)
$jtagOk = $text -match ('(?i)(?:0x)?' + [regex]::Escape($expectedJtag))
$goldenHashReported = $text.Contains($expectedGoldenDesign)
$designHashOk = $initialChainPolicy -eq 'user_attested_flash_boot' -or $goldenHashReported
$chainOk = $exitCode -eq 0 -and $cableOk -and $jtagOk -and $nodesOk -and $designHashOk
Write-Output ('INITIAL_CHAIN_POLICY=' + $initialChainPolicy)
Write-Output ('INITIAL_CABLE_MATCH=' + $cableOk)
Write-Output ('INITIAL_JTAG_ID_MATCH=' + $jtagOk)
Write-Output ('INITIAL_GOLDEN_DESIGN_HASH_MATCH=' + $goldenHashReported)
Write-Output ('INITIAL_UART_PHY_MATCH=' + $nodesOk)
if ($initialChainPolicy -eq 'user_attested_flash_boot') {
    Write-Output ('INITIAL_STATE_ATTESTATION=' + [string]$contract.hardware.initial_state_attestation)
    Write-Output 'INITIAL_DESIGN_HASH_ROLE=DIAGNOSTIC_ONLY_NOT_LIVE_IDENTITY'
}
Write-Output ('INITIAL_CHAIN_CONTRACT_OK=' + $chainOk)
if (-not $chainOk) {
    throw 'initial chain contract failed cable/JTAG-ID/UART/PHY/design-policy checks'
}

Write-Output 'PREFLIGHT_RESULT=PASS'
