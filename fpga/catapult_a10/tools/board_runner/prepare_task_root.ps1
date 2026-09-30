[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^T-[0-9]{8}-[0-9]{3}$')]
    [string] $TaskId,
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $TaskRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = [System.IO.Path]::GetFullPath($TaskRoot)
$incoming = Join-Path $root 'incoming'
$startedAt = (Get-Date).ToString('o')

Write-Output ('TASK=' + $TaskId)
Write-Output ('PREPARE_STARTED_AT=' + $startedAt)
Write-Output ('TASK_ROOT=' + $root)
Write-Output ('TASK_ROOT_EXISTS=' + (Test-Path -LiteralPath $root))
if (Test-Path -LiteralPath $root) {
    throw ('task root already exists; refusing overwrite: ' + $root)
}
if (Test-Path -LiteralPath $incoming) {
    throw ('incoming path already exists; refusing overwrite: ' + $incoming)
}

$parent = [System.IO.Path]::GetDirectoryName($root)
if ([string]::IsNullOrWhiteSpace($parent)) {
    throw ('task root parent is empty: ' + $root)
}
if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    throw ('task root parent is missing: ' + $parent)
}

New-Item -ItemType Directory -Path $root -ErrorAction Stop | Out-Null
try {
    New-Item -ItemType Directory -Path $incoming -ErrorAction Stop | Out-Null
    $children = @(Get-ChildItem -LiteralPath $incoming -Force -ErrorAction Stop)
    if ($children.Count -ne 0) {
        throw 'new incoming directory is not empty'
    }
}
catch {
    throw
}

$result = [ordered]@{
    schema_version = 1
    task_id = $TaskId
    task_root = $root
    incoming = $incoming
    task_root_created = (Test-Path -LiteralPath $root -PathType Container)
    incoming_created = (Test-Path -LiteralPath $incoming -PathType Container)
    result = 'PASS'
    finished_at = (Get-Date).ToString('o')
}
Write-Output (($result | ConvertTo-Json -Depth 8))
Write-Output 'PREPARE_ROOT_RESULT=PASS'
