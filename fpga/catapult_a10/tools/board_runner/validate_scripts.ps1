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
$required = @(
    'contract_common.ps1',
    'prepare_task_root.ps1',
    'validate_scripts.ps1',
    'verify_seal.ps1',
    'preflight.ps1',
    'program_once.ps1',
    'postflight.ps1'
)

if (-not (Test-Path -LiteralPath $incoming -PathType Container)) {
    throw ('bundle incoming directory is missing: ' + $incoming)
}

$files = @(Get-ChildItem -LiteralPath $incoming -Filter '*.ps1' -File -Force |
    Sort-Object -Property Name)
$actualNames = @($files | ForEach-Object { $_.Name })
$missing = @($required | Where-Object { $_ -notin $actualNames })
$unexpected = @($actualNames | Where-Object { $_ -notin $required })
if ($missing.Count -ne 0 -or $unexpected.Count -ne 0) {
    throw ('PowerShell bundle set mismatch; missing=' + ($missing -join ',') +
        '; unexpected=' + ($unexpected -join ','))
}

$records = @()
$parseFailures = @()
foreach ($file in $files) {
    [System.Management.Automation.Language.Token[]] $tokens = $null
    [System.Management.Automation.Language.ParseError[]] $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors)
    $errorCount = @($parseErrors).Count
    $record = [pscustomobject][ordered]@{
        name = $file.Name
        bytes = [int64]$file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        parse_error_count = $errorCount
        parse_errors = @($parseErrors | ForEach-Object { $_.Message })
    }
    $records += $record
    if ($errorCount -ne 0) {
        $parseFailures += $record
    }
}

$result = [ordered]@{
    schema_version = 1
    task_id = $TaskId
    task_root = $root
    incoming = $incoming
    parser = 'System.Management.Automation.Language.Parser::ParseFile'
    files = $records
    parse_failure_count = $parseFailures.Count
    result = if ($parseFailures.Count -eq 0) { 'PASS' } else { 'FAIL' }
    finished_at = (Get-Date).ToString('o')
}
Write-Output (($result | ConvertTo-Json -Depth 12))
if ($parseFailures.Count -ne 0) {
    Write-Output 'REMOTE_AST_RESULT=FAIL'
    exit 1
}
Write-Output 'REMOTE_AST_RESULT=PASS'
