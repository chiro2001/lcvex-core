Set-StrictMode -Version 2.0

function Assert-ContractProperties {
    param(
        [Parameter(Mandatory = $true)][object] $Object,
        [Parameter(Mandatory = $true)][string[]] $Names,
        [Parameter(Mandatory = $true)][string] $Where
    )
    if ($null -eq $Object) {
        throw ('board contract object missing: ' + $Where)
    }
    $present = @($Object.PSObject.Properties | ForEach-Object { $_.Name })
    $missing = @($Names | Where-Object { $_ -notin $present })
    if ($missing.Count -ne 0) {
        throw ('board contract ' + $Where + ' missing properties: ' + ($missing -join ','))
    }
}

function Get-BoardContract {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $TaskId
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ('board contract missing: ' + $Path)
    }
    $contract = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
    Assert-ContractProperties -Object $contract -Where 'root' -Names @(
        'schema_version', 'contract_id', 'task_id', 'remote', 'paths', 'hardware',
        'candidate', 'golden', 'server_bundle', 'terminal', 'policy'
    )
    if ([int]$contract.schema_version -ne 1) {
        throw 'board contract schema_version must equal 1'
    }
    if ([string]$contract.task_id -ne $TaskId) {
        throw ('board contract task mismatch: expected ' + $TaskId + ', got ' + [string]$contract.task_id)
    }
    if ([string]$contract.contract_id -notmatch '^[A-Za-z0-9_.-]+$' -or
        [string]$contract.remote.host -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$') {
        throw 'board contract ID or remote host contains unsafe characters'
    }
    foreach ($name in @('remote', 'paths', 'hardware', 'candidate', 'golden', 'server_bundle', 'terminal', 'policy')) {
        if ($null -eq $contract.$name) {
            throw ('board contract missing object: ' + $name)
        }
    }
    Assert-ContractProperties -Object $contract.remote -Where 'remote' -Names @('host', 'task_root', 'bootstrap_path')
    Assert-ContractProperties -Object $contract.paths -Where 'paths' -Names @('quartus_bin', 'license_file', 'source_server')
    Assert-ContractProperties -Object $contract.hardware -Where 'hardware' -Names @(
        'jtag_id', 'console_cable', 'program_cable', 'console_device', 'console_instance',
        'server_port', 'server_frequency_hz', 'terminal_to_golden_delay_s', 'required_nodes'
    )
    Assert-ContractProperties -Object $contract.server_bundle -Where 'server_bundle' -Names @('required_files', 'pinned_sha256')
    Assert-ContractProperties -Object $contract.policy -Where 'policy' -Names @(
        'volatile_sof_only', 'persistent_formats_allowed', 'allow_reset', 'allow_power_cycle',
        'allow_standard_or_unknown_process_stop', 'candidate_program_invocations',
        'terminal_sessions', 'golden_program_invocations'
    )
    foreach ($imageName in @('candidate', 'golden')) {
        $image = $contract.$imageName
        Assert-ContractProperties -Object $image -Where $imageName -Names @('path', 'bytes', 'sha256', 'checksum', 'design_hash')
        $pathValue = [string]$image.path
        $hashValue = [string]$image.sha256
        $checksumValue = [string]$image.checksum
        $designValue = [string]$image.design_hash
        if ($pathValue -notmatch '^[A-Za-z]:[\\/]' -or $pathValue -notmatch '(?i)\.sof$') {
            throw ($imageName + ' path must be an absolute volatile SOF')
        }
        if ([int64]$image.bytes -le 0 -or $hashValue -cnotmatch '^[0-9a-f]{64}$') {
            throw ($imageName + ' identity is malformed')
        }
        if ($checksumValue -notmatch '^0x[0-9A-Fa-f]{8}$' -or $designValue -notmatch '^[0-9A-Fa-f]{16,64}$') {
            throw ($imageName + ' checksum/design identity is malformed')
        }
    }
    foreach ($pathValue in @(
        [string]$contract.remote.task_root,
        [string]$contract.remote.bootstrap_path,
        [string]$contract.paths.quartus_bin,
        [string]$contract.paths.license_file,
        [string]$contract.paths.source_server,
        [string]$contract.candidate.path,
        [string]$contract.golden.path,
        [string]$contract.terminal.executable
    )) {
        if ($pathValue -notmatch '^[A-Za-z]:[A-Za-z0-9_.\\/+:-]+$') {
            throw ('board contract path contains unsafe characters: ' + $pathValue)
        }
    }
    $expectedServerFiles = @(
        'ccl_ver.dll', 'client.conf', 'ftd2xx.dll', 'ftd2xx_real.dll', 'head_blaster.h',
        'jtag_client.dll', 'jtag_hw_microsoft_catapult.dll', 'jtagserver.exe', 'msftdi.cfg',
        'pgm_pgmdrv_apu_usb.dll'
    )
    $actualServerFiles = @($contract.server_bundle.required_files | ForEach-Object { [string]$_ })
    $missingServerFiles = @($expectedServerFiles | Where-Object { $_ -notin $actualServerFiles })
    $unexpectedServerFiles = @($actualServerFiles | Where-Object { $_ -notin $expectedServerFiles })
    if ($actualServerFiles.Count -ne $expectedServerFiles.Count -or
        $missingServerFiles.Count -ne 0 -or $unexpectedServerFiles.Count -ne 0) {
        throw 'server bundle file set differs from reviewed ten-file set'
    }
    $expectedPinNames = @('jtagserver.exe', 'jtag_hw_microsoft_catapult.dll', 'client.conf', 'msftdi.cfg')
    $actualPinNames = @($contract.server_bundle.pinned_sha256.PSObject.Properties | ForEach-Object { $_.Name })
    if ($actualPinNames.Count -ne $expectedPinNames.Count -or
        @($expectedPinNames | Where-Object { $_ -notin $actualPinNames }).Count -ne 0 -or
        @($actualPinNames | Where-Object { $_ -notin $expectedPinNames }).Count -ne 0) {
        throw 'server bundle pinned hash set differs from reviewed four-file set'
    }
    foreach ($property in $contract.server_bundle.pinned_sha256.PSObject.Properties) {
        if ([string]$property.Value -cnotmatch '^[0-9a-f]{64}$') {
            throw ('server bundle pin is not lowercase SHA-256: ' + [string]$property.Name)
        }
    }
    if ([string]$contract.candidate.sha256 -eq [string]$contract.golden.sha256) {
        throw 'candidate and golden identities must differ'
    }
    $hardwareProperties = @($contract.hardware.PSObject.Properties | ForEach-Object { $_.Name })
    $initialChainPolicy = if ('initial_chain_policy' -in $hardwareProperties) {
        [string]$contract.hardware.initial_chain_policy
    } else {
        'require_golden_design_hash'
    }
    if ($initialChainPolicy -notin @('require_golden_design_hash', 'user_attested_flash_boot')) {
        throw 'initial_chain_policy is not a reviewed value'
    }
    if ($initialChainPolicy -eq 'user_attested_flash_boot') {
        $fixedCandidatePath = 'D:/Projects/fpga-altra/lcvex/build/T-20260920-052-b25-coremark-uart-volatile-sof/fpga/catapult_a10/quartus/output_files/catapult_a10.sof'
        $fixedGoldenPath = 'D:/Projects/fpga-altra/a10-linux-riscv/dist/golden/vex_soc_ddr.sof'
        if ($TaskId -ne 'T-20260920-053' -or
            [string]$contract.contract_id -ne 't053-b25-coremark-uart-fixed' -or
            [string]$contract.hardware.initial_state_attestation -ne 'user_confirmed_flash_boot_vexriscv_linux' -or
            [string]$contract.candidate.path -cne $fixedCandidatePath -or
            [int64]$contract.candidate.bytes -ne 36842099 -or
            [string]$contract.candidate.sha256 -cne '39c2945466804036366a6306125323b585bef097aded7e8fff494d60a3ea2def' -or
            [string]$contract.candidate.checksum -cne '0x31585D80' -or
            [string]$contract.candidate.design_hash -cne '48917DD6FD70C4420BD5765A206DACBB' -or
            [string]$contract.golden.path -cne $fixedGoldenPath -or
            [int64]$contract.golden.bytes -ne 36844906 -or
            [string]$contract.golden.sha256 -cne '290ab3cfb18cfd6ee47e5a2bc9324e63882de51d0ae5ac6c2688d7d6a2385f92' -or
            [string]$contract.golden.checksum -cne '0x31510BB6' -or
            [string]$contract.golden.design_hash -cne '193DE4BC8A30F3ED5F1F') {
            throw 'user-attested Flash boot policy is restricted to the reviewed T-053 identity and fixed attestation'
        }
    } elseif ('initial_state_attestation' -in $hardwareProperties) {
        throw 'initial_state_attestation requires user_attested_flash_boot policy'
    }
    if (-not [bool]$contract.policy.volatile_sof_only -or
        [bool]$contract.policy.persistent_formats_allowed -or
        [bool]$contract.policy.allow_reset -or
        [bool]$contract.policy.allow_power_cycle -or
        [bool]$contract.policy.allow_standard_or_unknown_process_stop) {
        throw 'board contract safety policy is not fail-closed'
    }
    if ([int]$contract.policy.candidate_program_invocations -ne 1 -or
        [int]$contract.policy.terminal_sessions -ne 1 -or
        [int]$contract.policy.golden_program_invocations -ne 1) {
        throw 'board contract invocation counts must all equal one'
    }
    if ([int]$contract.hardware.console_device -ne 1 -or [int]$contract.hardware.console_instance -ne 0) {
        throw 'board contract console endpoint must be device 1 instance 0'
    }
    if ([int]$contract.hardware.server_port -ne 1310 -or [int]$contract.hardware.server_frequency_hz -ne 15000000) {
        throw 'board contract server must use port 1310 at 15 MHz'
    }
    if ([int]$contract.hardware.terminal_to_golden_delay_s -lt 0 -or
        [int]$contract.hardware.terminal_to_golden_delay_s -gt 60) {
        throw 'terminal-to-golden delay must be in [0, 60] seconds'
    }
    if ([string]$contract.remote.task_root -notmatch [regex]::Escape($TaskId) -or
        [string]$contract.remote.bootstrap_path -notmatch [regex]::Escape($TaskId)) {
        throw 'board contract remote paths must contain task ID'
    }
    return $contract
}

function Get-BoardInitialChainPolicy {
    param([Parameter(Mandatory = $true)][object] $Contract)
    $properties = @($Contract.hardware.PSObject.Properties | ForEach-Object { $_.Name })
    if ('initial_chain_policy' -notin $properties) {
        return 'require_golden_design_hash'
    }
    return [string]$Contract.hardware.initial_chain_policy
}

function Get-BoardContractPath {
    param(
        [Parameter(Mandatory = $true)][string] $TaskRoot,
        [string] $ContractPath
    )
    if ([string]::IsNullOrWhiteSpace($ContractPath)) {
        return (Join-Path ([System.IO.Path]::GetFullPath($TaskRoot)) 'incoming\board-contract.json')
    }
    return [System.IO.Path]::GetFullPath($ContractPath)
}
