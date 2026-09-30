[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^T-[0-9]{8}-[0-9]{3}$')]
    [string] $TaskId,
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $TaskRoot,
    [Parameter(Mandatory = $true)]
    [ValidateSet('candidate', 'golden')]
    [string] $Mode,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string] $RunLabel,
    [string] $ContractPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$root = [System.IO.Path]::GetFullPath($TaskRoot)
. (Join-Path $PSScriptRoot 'contract_common.ps1')
$contractPath = Get-BoardContractPath -TaskRoot $root -ContractPath $ContractPath
$contract = Get-BoardContract -Path $contractPath -TaskId $TaskId
$sourceServer = [string]$contract.paths.source_server
$candidate = [string]$contract.candidate.path
$golden = [string]$contract.golden.path
$quartusBin = [string]$contract.paths.quartus_bin
$quartusPgm = Join-Path $quartusBin 'quartus_pgm.exe'
$programCable = [string]$contract.hardware.program_cable
$expectedCandidateBytes = [int64]$contract.candidate.bytes
$expectedCandidateHash = [string]$contract.candidate.sha256
$expectedCandidateChecksum = [string]$contract.candidate.checksum
$expectedCandidateDesign = [string]$contract.candidate.design_hash
$expectedGoldenBytes = [int64]$contract.golden.bytes
$expectedGoldenHash = [string]$contract.golden.sha256
$expectedGoldenChecksum = [string]$contract.golden.checksum
$expectedGoldenDesign = [string]$contract.golden.design_hash
$expectedJtagId = [string]$contract.hardware.jtag_id
$serverPort = [int]$contract.hardware.server_port
$serverFrequencyHz = [int]$contract.hardware.server_frequency_hz
$serverFiles = @($contract.server_bundle.required_files | ForEach-Object { [string]$_ })
$expectedPins = $contract.server_bundle.pinned_sha256

$target = if ($Mode -eq 'candidate') { $candidate } else { $golden }
$targetBytes = if ($Mode -eq 'candidate') { $expectedCandidateBytes } else { $expectedGoldenBytes }
$targetHash = if ($Mode -eq 'candidate') { $expectedCandidateHash } else { $expectedGoldenHash }
$targetChecksum = if ($Mode -eq 'candidate') { $expectedCandidateChecksum } else { $expectedGoldenChecksum }
$targetDesign = if ($Mode -eq 'candidate') { $expectedCandidateDesign } else { $expectedGoldenDesign }
$guardName = if ($Mode -eq 'candidate') { 'candidate-quartus-pgm.once' } else { 'golden-quartus-pgm.once' }
$guardPath = Join-Path $root $guardName
$runRoot = Join-Path $root ('program-' + $Mode + '-' + $RunLabel)
$runtime = Join-Path $runRoot 'runtime'
$serverDir = Join-Path $runRoot 'server'

$ownedServer = $null
$ownedServerStopped = $true
$failure = $null
$standardPid = $null

function File-Record([string] $Path) {
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    [ordered]@{
        path = $item.FullName
        bytes = [int64]$item.Length
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Write-Json([string] $Path, [object] $Value) {
    [IO.File]::WriteAllText(
        $Path,
        (($Value | ConvertTo-Json -Depth 20) + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
}

function Assert-Identity([string] $Label, [string] $Path, [int64] $Bytes, [string] $Hash) {
    $record = File-Record $Path
    Write-Output ($Label + '=bytes=' + $record.bytes + '|sha256=' + $record.sha256)
    if ($record.bytes -ne $Bytes -or $record.sha256 -ne $Hash) {
        throw ($Label + ' identity mismatch')
    }
    return $record
}

function Stop-OwnedServer([string] $Reason) {
    if ($null -eq $script:ownedServer -or $script:ownedServerStopped) {
        return
    }
    $process = Get-Process -Id $script:ownedServer.Id -ErrorAction SilentlyContinue
    if ($null -ne $process) {
        Write-Output ($Reason + '_OWNED_SERVER_STOP_PID=' + $script:ownedServer.Id)
        Stop-Process -Id $script:ownedServer.Id -Force -ErrorAction Stop
        $process.WaitForExit(10000) | Out-Null
    }
    $script:ownedServerStopped = $true
    Remove-Item Env:QUARTUS_JTAG_CLIENT_CONFIG -ErrorAction SilentlyContinue
    Remove-Item Env:QUARTUS_JTAG_CLIENT_NO_LOCAL_SERVER -ErrorAction SilentlyContinue
}

function Start-OwnedServer {
    $serverExe = Join-Path $serverDir 'jtagserver.exe'
    $stdout = Join-Path $runtime 'owned-server.stdout.log'
    $stderr = Join-Path $runtime 'owned-server.stderr.log'
    $script:ownedServer = Start-Process -FilePath $serverExe `
        -ArgumentList @('--foreground', '--no-config', '--port', [string]$serverPort, '--port-file', 'port.txt') `
        -WorkingDirectory $serverDir -RedirectStandardOutput $stdout -RedirectStandardError $stderr `
        -WindowStyle Hidden -PassThru
    $script:ownedServerStopped = $false
    Write-Output ('OWNED_SERVER_PID=' + $script:ownedServer.Id)
    Start-Sleep -Seconds 2
    $script:ownedServer.Refresh()
    if ($script:ownedServer.HasExited) {
        throw ('owned server exited: ' + $script:ownedServer.ExitCode)
    }
    $listeners = @(Get-NetTCPConnection -LocalPort $serverPort -State Listen -ErrorAction SilentlyContinue)
    if ($listeners.Count -ne 1 -or [int]$listeners[0].OwningProcess -ne [int]$script:ownedServer.Id) {
        throw 'owned server did not acquire the expected port 1310 listener'
    }
    $env:QUARTUS_JTAG_CLIENT_CONFIG = Join-Path $serverDir 'client.conf'
    $env:QUARTUS_JTAG_CLIENT_NO_LOCAL_SERVER = '1'
}

function New-InvocationGuard {
    if (Test-Path -LiteralPath $guardPath) {
        throw ('invocation guard already exists; refusing second quartus_pgm call: ' + $guardPath)
    }
    $stamp = (Get-Date).ToString('o') + "`n" + $TaskId + '|' + $Mode + '|' + $RunLabel + "`n"
    $stream = [IO.File]::Open(
        $guardPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($stamp)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    }
    finally {
        $stream.Dispose()
    }
    Write-Output ($Mode.ToUpperInvariant() + '_MARKER_CREATED=' + $guardPath)
}

function Invoke-Programmer {
    $stdout = Join-Path $runtime 'quartus_pgm.stdout.log'
    $stderr = Join-Path $runtime 'quartus_pgm.stderr.log'
    $args = @('-c', ('"' + $programCable + '"'), '-m', 'JTAG', '-o', ('"p;' + $target + '"'))
    $programmer = Start-Process -FilePath $quartusPgm -ArgumentList $args -WorkingDirectory $runtime `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -Wait -PassThru
    $text = [IO.File]::ReadAllText($stdout)
    $tool = $text.Contains('Quartus Prime Programmer was successful. 0 errors, 0 warnings')
    $config = $text.Contains('Configuration succeeded -- 1 device(s) configured')
    $operation = $text.Contains('Successfully performed operation(s)')
    $checksum = $text.Contains(('checksum ' + $targetChecksum))
    $jtag = $text.Contains('JTAG ID code 0x' + $expectedJtagId)
    Write-Output ('PROGRAMMER_PID=' + $programmer.Id)
    Write-Output ('PROGRAMMER_EXIT=' + $programmer.ExitCode)
    Write-Output ('PROGRAM_TOOL_SUCCESS=' + $tool)
    Write-Output ('PROGRAM_CONFIG_SUCCESS=' + $config)
    Write-Output ('PROGRAM_OPERATION_SUCCESS=' + $operation)
    Write-Output ('PROGRAM_CHECKSUM_MATCH=' + $checksum)
    Write-Output ('PROGRAM_JTAG_ID_MATCH=' + $jtag)
    $record = [ordered]@{
        pid = $programmer.Id
        exit_code = $programmer.ExitCode
        tool_success = $tool
        configuration_success = $config
        operation_success = $operation
        checksum_match = $checksum
        jtag_id_match = $jtag
        stdout = File-Record $stdout
        stderr = File-Record $stderr
    }
    if ($programmer.ExitCode -ne 0 -or -not $tool -or -not $config -or -not $operation -or
        -not $checksum -or -not $jtag) {
        throw 'programming acceptance failed'
    }
    return $record
}

try {
    Write-Output ('TASK=' + $TaskId)
    Write-Output ('MODE=' + $Mode)
    Write-Output ('RUN_LABEL=' + $RunLabel)
    Write-Output ('CONTRACT_ID=' + [string]$contract.contract_id)
    Write-Output ('CONTRACT_SHA256=' + (Get-FileHash -LiteralPath $contractPath -Algorithm SHA256).Hash.ToLowerInvariant())
    Write-Output ('PROGRAM_STARTED_AT=' + (Get-Date).ToString('o'))
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw 'task root missing'
    }
    if (Test-Path -LiteralPath $runRoot) {
        throw ('run root already exists; refusing overwrite: ' + $runRoot)
    }
    if (Test-Path -LiteralPath $guardPath) {
        throw ('invocation guard already exists before setup: ' + $guardPath)
    }
    foreach ($path in @($sourceServer, $quartusBin, $quartusPgm, $target)) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw ('required path missing: ' + $path)
        }
    }
    $candidateRecord = Assert-Identity 'CANDIDATE' $candidate $expectedCandidateBytes $expectedCandidateHash
    $goldenRecord = Assert-Identity 'GOLDEN' $golden $expectedGoldenBytes $expectedGoldenHash
    $targetRecord = Assert-Identity 'TARGET' $target $targetBytes $targetHash

    $busy = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match '^(quartus|quartus_sh|quartus_syn|quartus_fit|quartus_sta|quartus_asm|quartus_pgm|qsys|ip-generate|vsim|questa|modelsim|nios2-terminal)(\.exe)?$'
    })
    Write-Output ('PRE_BUSY_COUNT=' + $busy.Count)
    if ($busy.Count -ne 0) {
        throw 'conflicting EDA/programmer/terminal process exists before owned server'
    }
    $port = @(Get-NetTCPConnection -LocalPort $serverPort -State Listen -ErrorAction SilentlyContinue)
    Write-Output ('PRE_PORT1310_COUNT=' + $port.Count)
    if ($port.Count -ne 0) {
        throw 'port 1310 is occupied before owned server'
    }
    $standard = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match '^jtagserver(\.exe)?$' -and $_.ExecutablePath -eq (Join-Path $quartusBin 'jtagserver.exe')
    })
    Write-Output ('STANDARD_SERVER_COUNT=' + $standard.Count)
    if ($standard.Count -ne 1) {
        throw 'standard jtagserver identity count mismatch'
    }
    $standardPid = [int]$standard[0].ProcessId

    New-Item -ItemType Directory -Path $runRoot -ErrorAction Stop | Out-Null
    New-Item -ItemType Directory -Path $runtime -ErrorAction Stop | Out-Null
    New-Item -ItemType Directory -Path $serverDir -ErrorAction Stop | Out-Null
    $manifest = New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in $serverFiles) {
        $source = Join-Path $sourceServer $name
        $destination = Join-Path $serverDir $name
        if (-not (Test-Path -LiteralPath $source)) {
            throw ('server bundle file missing: ' + $name)
        }
        Copy-Item -LiteralPath $source -Destination $destination -ErrorAction Stop
        $sourceRecord = File-Record $source
        $copyRecord = File-Record $destination
        if ($sourceRecord.bytes -ne $copyRecord.bytes -or $sourceRecord.sha256 -ne $copyRecord.sha256) {
            throw ('server bundle copy mismatch: ' + $name)
        }
        $manifest.Add([ordered]@{ name = $name; source = $sourceRecord; copy = $copyRecord })
    }
    $serverManifestPath = Join-Path $runtime 'server-manifest.json'
    Write-Json $serverManifestPath $manifest
    $known = @{}
    foreach ($property in $expectedPins.PSObject.Properties) {
        $known[[string]$property.Name] = ([string]$property.Value).ToLowerInvariant()
    }
    foreach ($entry in $manifest) {
        if ($known.ContainsKey($entry.name) -and $entry.copy.sha256 -ne $known[$entry.name]) {
            throw ('known server identity mismatch: ' + $entry.name)
        }
    }
    $frequency = [IO.File]::ReadAllText((Join-Path $serverDir 'msftdi.cfg'))
    if ($frequency -notmatch '(?m)^channel=0\s*$' -or
        $frequency -notmatch ('(?m)^frequency=' + [string]$serverFrequencyHz + '\s*$')) {
        throw 'programming server channel/frequency does not match contract'
    }
    $client = [IO.File]::ReadAllText((Join-Path $serverDir 'client.conf'))
    if ($client -notmatch ('127\.0\.0\.1:' + [string]$serverPort)) {
        throw 'programming client endpoint does not match contract'
    }

    $env:LM_LICENSE_FILE = [string]$contract.paths.license_file
    Start-OwnedServer

    # The durable CreateNew guard is immediately before the single programmer call.
    New-InvocationGuard
    $programRecord = Invoke-Programmer
    Stop-OwnedServer 'POST_PROGRAM'

    $postBusy = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match '^(quartus_pgm|nios2-terminal)(\.exe)?$'
    })
    $postPort = @(Get-NetTCPConnection -LocalPort $serverPort -State Listen -ErrorAction SilentlyContinue)
    $standardAlive = $null -ne (Get-Process -Id $standardPid -ErrorAction SilentlyContinue)
    Write-Output ('POST_BUSY_COUNT=' + $postBusy.Count)
    Write-Output ('POST_PORT1310_COUNT=' + $postPort.Count)
    Write-Output ('STANDARD_SERVER_PRESERVED=' + $standardAlive + '|pid=' + $standardPid)
    if ($postBusy.Count -ne 0 -or $postPort.Count -ne 0 -or -not $standardAlive) {
        throw 'post-program cleanup or preserved standard server check failed'
    }

    $result = [ordered]@{
        schema_version = 1
        task_id = $TaskId
        contract_id = [string]$contract.contract_id
        contract_sha256 = (Get-FileHash -LiteralPath $contractPath -Algorithm SHA256).Hash.ToLowerInvariant()
        mode = $Mode
        run_label = $RunLabel
        result = 'PASS'
        target = $targetRecord
        candidate = $candidateRecord
        golden = $goldenRecord
        candidate_checksum = $expectedCandidateChecksum
        golden_checksum = $expectedGoldenChecksum
        candidate_design_hash = $expectedCandidateDesign
        golden_design_hash = $expectedGoldenDesign
        target_design_hash = $targetDesign
        jtag_id = ('0x' + $expectedJtagId)
        standard_server_pid = $standardPid
        standard_server_preserved = $standardAlive
        server_manifest = $manifest
        server_manifest_sha256 = (Get-FileHash -LiteralPath $serverManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        program = $programRecord
        post_busy_count = $postBusy.Count
        post_port1310_count = $postPort.Count
        candidate_quartus_pgm_invocation_count = if ($Mode -eq 'candidate') { 1 } else { 0 }
        golden_quartus_pgm_invocation_count = if ($Mode -eq 'golden') { 1 } else { 0 }
        persistent_flash_action = $false
        reset_or_power_action = $false
        unknown_process_stopped = $false
        finished_at = (Get-Date).ToString('o')
    }
    $resultPath = Join-Path $runtime 'program-result.json'
    Write-Json $resultPath $result
    Write-Output ('PROGRAM_RESULT=' + $resultPath)
    Write-Output ('PROGRAM_RESULT_SHA256=' + (Get-FileHash -LiteralPath $resultPath -Algorithm SHA256).Hash.ToLowerInvariant())
    Write-Output 'VOLATILE_PROGRAM_PASS'
}
catch {
    $failure = $_.Exception.Message
    Write-Output ('PROGRAM_FAILURE=' + $failure)
}
finally {
    try {
        Stop-OwnedServer 'FAILURE_CLEANUP'
    }
    catch {
        Write-Output ('SERVER_CLEANUP_ERROR=' + $_.Exception.Message)
        if ($null -eq $failure) {
            $failure = $_.Exception.Message
        }
    }
    Remove-Item Env:QUARTUS_JTAG_CLIENT_CONFIG -ErrorAction SilentlyContinue
    Remove-Item Env:QUARTUS_JTAG_CLIENT_NO_LOCAL_SERVER -ErrorAction SilentlyContinue
}

if ($null -ne $failure) {
    if (Test-Path -LiteralPath $runtime) {
        $failureRecord = [ordered]@{
            schema_version = 1
            task_id = $TaskId
            mode = $Mode
            run_label = $RunLabel
            result = 'FAIL'
            failure = $failure
            marker_path = $guardPath
            marker_exists = Test-Path -LiteralPath $guardPath
            finished_at = (Get-Date).ToString('o')
        }
        Write-Json (Join-Path $runtime 'program-result.json') $failureRecord
    }
    exit 1
}
exit 0
