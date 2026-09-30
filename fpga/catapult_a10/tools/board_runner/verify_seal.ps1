[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^T-[0-9]{8}-[0-9]{3}$')]
    [string] $TaskId,
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $TaskRoot,
    [string] $ManifestPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = [System.IO.Path]::GetFullPath($TaskRoot)
$incoming = Join-Path $root 'incoming'
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $incoming 'script-manifest.json'
}

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw ('sealed manifest is missing: ' + $ManifestPath)
}
$manifest = Get-Content -LiteralPath $ManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
if ([int]$manifest.schema_version -ne 2) {
    throw ('manifest schema mismatch: expected 2, got ' + [string]$manifest.schema_version)
}
if ([string]$manifest.task_id -ne $TaskId) {
    throw ('manifest task mismatch: expected ' + $TaskId + ', got ' + [string]$manifest.task_id)
}

$entries = @($manifest.files)
if ($entries.Count -eq 0) {
    throw 'sealed manifest has no files'
}
$entryNames = @($entries | ForEach-Object { [string]$_.name })
if (@($entryNames | Sort-Object -Unique).Count -ne $entryNames.Count) {
    throw 'sealed manifest contains duplicate file names'
}
$records = @()
foreach ($entry in $entries) {
    $name = [string]$entry.name
    if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains('/') -or $name.Contains('\') -or $name -eq '.' -or $name -eq '..') {
        throw ('invalid manifest file name: ' + $name)
    }
    if (-not [bool]$entry.remote) {
        continue
    }
    $path = Join-Path $incoming $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw ('sealed remote file missing: ' + $name)
    }
    $item = Get-Item -LiteralPath $path -ErrorAction Stop
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedHash = ([string]$entry.sha256).ToLowerInvariant()
    $bytesOk = [int64]$entry.bytes -eq [int64]$item.Length
    $hashOk = $expectedHash -eq $hash
    $record = [pscustomobject][ordered]@{
        name = $name
        bytes = [int64]$item.Length
        expected_bytes = [int64]$entry.bytes
        sha256 = $hash
        expected_sha256 = $expectedHash
        bytes_match = $bytesOk
        sha256_match = $hashOk
    }
    $records += $record
    Write-Output ('SEALED_REMOTE=' + $name + '|bytes=' + $item.Length + '|sha256=' + $hash)
    if (-not $bytesOk -or -not $hashOk) {
        throw ('remote seal mismatch: ' + $name)
    }
}

if ($records.Count -ne $entries.Count) {
    throw ('manifest contains non-remote entries; expected every bundle file to be remote, checked=' +
        $records.Count + ', entries=' + $entries.Count)
}

$contractEntries = @($entries | Where-Object { [string]$_.name -eq 'board-contract.json' })
if ($contractEntries.Count -ne 1) {
    throw 'sealed manifest must contain exactly one board-contract.json entry'
}
$contractPath = Join-Path $incoming 'board-contract.json'
$contractHash = (Get-FileHash -LiteralPath $contractPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($contractHash -ne ([string]$manifest.contract_sha256).ToLowerInvariant()) {
    throw 'manifest contract_sha256 mismatch'
}
. (Join-Path $incoming 'contract_common.ps1')
$contract = Get-BoardContract -Path $contractPath -TaskId $TaskId
if ([string]$contract.contract_id -ne [string]$manifest.contract_id) {
    throw 'manifest contract_id mismatch'
}

$result = [ordered]@{
    schema_version = 1
    task_id = $TaskId
    task_root = $root
    manifest = $ManifestPath
    contract_id = [string]$contract.contract_id
    contract_sha256 = $contractHash
    checked_count = $records.Count
    files = $records
    result = 'PASS'
    finished_at = (Get-Date).ToString('o')
}
Write-Output (($result | ConvertTo-Json -Depth 12))
Write-Output ('REMOTE_SEALED_SCRIPT_COUNT=' + $records.Count)
Write-Output 'REMOTE_SCRIPT_SEAL_RESULT=PASS'
