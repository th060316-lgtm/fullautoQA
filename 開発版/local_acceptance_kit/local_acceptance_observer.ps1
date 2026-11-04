# Windows PowerShell 5.1. No installation, elevation, network request, or Registry write.
Set-StrictMode -Version 2.0
$script:LocalObserverSourcePath = $PSCommandPath

function Get-PrivateFingerprint {
    param([string]$Nonce, $Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 16 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($Nonce + ':' + $json)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-TokenObservation {
    if ($env:OS -ne 'Windows_NT') { return @{status='NOT_RUN';reason='WINDOWS_TOKEN_UNAVAILABLE'} }
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            $principal = New-Object Security.Principal.WindowsPrincipal($identity)
            return @{status='MEASURED';elevated=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);method='WindowsPrincipal.IsInRole(Administrator)'}
        } finally { $identity.Dispose() }
    } catch { return @{status='NOT_RUN';reason='TOKEN_READ_UNAVAILABLE'} }
}

function Get-RegistryKeyFingerprint {
    param([ValidateSet('CurrentUser','LocalMachine')][string]$Hive, [string]$SubKey, [string]$Nonce, [switch]$PathOnly)
    $base = $null; $key = $null
    try {
        $hiveId = [Microsoft.Win32.RegistryHive]::$Hive
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hiveId, [Microsoft.Win32.RegistryView]::Default)
        $key = $base.OpenSubKey($SubKey, $false)
        if ($null -eq $key) { return @{status='NOT_RUN';reason='KEY_ABSENT_OR_UNREADABLE'} }
        $names = @($key.GetValueNames() | Sort-Object)
        $items = @()
        foreach ($name in $names) {
            if ($PathOnly -and $name -ine 'Path') { continue }
            $kind = [string]$key.GetValueKind($name)
            $value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($value -is [byte[]]) { $value = [Convert]::ToBase64String($value) }
            # Names and values exist only in memory; only one aggregate digest is returned.
            $items += @{name=$name;kind=$kind;value=$value}
        }
        return @{status='MEASURED';present=($items.Count -gt 0);value_count=$items.Count;fingerprint=(Get-PrivateFingerprint -Nonce $Nonce -Value $items);view='Default';method='nonce SHA256 of root values, names, types; no subkeys'}
    } catch [UnauthorizedAccessException] {
        return @{status='NOT_RUN';reason='ACCESS_DENIED'}
    } catch [Security.SecurityException] {
        return @{status='NOT_RUN';reason='ACCESS_DENIED'}
    } catch {
        return @{status='NOT_RUN';reason='REGISTRY_READ_UNAVAILABLE'}
    } finally {
        if ($null -ne $key) { $key.Dispose() }
        if ($null -ne $base) { $base.Dispose() }
    }
}

function Get-NetworkObservation {
    try {
        $counts = @{}
        foreach ($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            $label = ([string]$nic.NetworkInterfaceType) + '/' + ([string]$nic.OperationalStatus)
            if (-not $counts.ContainsKey($label)) { $counts[$label] = 0 }
            $counts[$label]++
        }
        return @{status='MEASURED';interface_type_state_counts=$counts;method='passive local NetworkInterface snapshot; no connectivity probe';full_offline=@{status='NOT_RUN';reason='NO_ENFORCED_ISOLATION_OR_CONTINUOUS_NETWORK_AUDIT'}}
    } catch {
        return @{status='NOT_RUN';reason='INTERFACE_READ_UNAVAILABLE';full_offline=@{status='NOT_RUN';reason='NO_ENFORCED_ISOLATION_OR_CONTINUOUS_NETWORK_AUDIT'}}
    }
}

function Get-LocalObservation {
    param([string]$Nonce)
    $user = 'Environment'
    $machine = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    return @{
        timestamp_utc=[DateTime]::UtcNow.ToString('o')
        token=(Get-TokenObservation)
        persistent_path=@{
            user=(Get-RegistryKeyFingerprint -Hive CurrentUser -SubKey $user -Nonce $Nonce -PathOnly)
            machine=(Get-RegistryKeyFingerprint -Hive LocalMachine -SubKey $machine -Nonce $Nonce -PathOnly)
        }
        registry_scopes=@{
            user_environment_values=(Get-RegistryKeyFingerprint -Hive CurrentUser -SubKey $user -Nonce $Nonce)
            machine_environment_values=(Get-RegistryKeyFingerprint -Hive LocalMachine -SubKey $machine -Nonce $Nonce)
        }
        network=(Get-NetworkObservation)
    }
}

function Compare-PrivateObservation {
    param($Before, $After)
    if ($null -eq $Before -or $null -eq $After -or $Before.status -ne 'MEASURED' -or $After.status -ne 'MEASURED') {
        return @{status='NOT_RUN';reason='BOTH_BOUNDARIES_NOT_MEASURED'}
    }
    if ($Before.fingerprint -ceq $After.fingerprint -and $Before.value_count -eq $After.value_count -and $Before.present -eq $After.present) {
        return @{status='PASS';reason='BOUNDARY_FINGERPRINTS_EQUAL';scope='selected values at two boundaries only; writes then restored between snapshots are not detected'}
    }
    return @{status='FAIL';reason='BOUNDARY_FINGERPRINTS_DIFFER';scope='selected values at two boundaries only'}
}

function Get-RunnerTokenObservations {
    param([string]$OutputRoot)
    $out = @()
    $recordsPath = Join-Path $OutputRoot 'SERIES_RECORDS.json'
    if (-not (Test-Path -LiteralPath $recordsPath)) { return @() }
    try { $records = @(Get-Content -LiteralPath $recordsPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return @() }
    foreach ($index in 1..3) {
        $archive = $null; $reader = $null
        try {
            $path = Join-Path $OutputRoot ('Run' + $index + '/RESULT_FOR_CHATGPT.zip')
            $record = @($records | Where-Object { $_.index -eq $index })
            if ($record.Count -ne 1) { throw 'RECORD_ABSENT' }
            $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($hash -cne $record[0].result_sha256) { throw 'ARCHIVE_IDENTITY_MISMATCH' }
            $archive = [IO.Compression.ZipFile]::OpenRead($path)
            $entries = @($archive.Entries | Where-Object { $_.FullName.Replace('\','/') -eq 'phase3_environment.json' })
            if ($entries.Count -ne 1 -or $entries[0].Length -gt 65536) { throw 'ENVIRONMENT_ABSENT_OR_OVERSIZED' }
            $reader = New-Object IO.StreamReader($entries[0].Open())
            $data = $reader.ReadToEnd() | ConvertFrom-Json
            $state = [string]$data.admin_status
            if ($state -notin @('STANDARD_USER','ELEVATED')) { throw 'TOKEN_UNDETERMINED' }
            $out += @{run=$index;status='MEASURED';admin_status=$state;result_sha256=$hash;source_member='phase3_environment.json'}
        } catch {
            $out += @{run=$index;status='NOT_RUN';reason='RUNNER_TOKEN_EVIDENCE_UNAVAILABLE_OR_UNBOUND'}
        } finally {
            if ($null -ne $reader) { $reader.Dispose() }
            if ($null -ne $archive) { $archive.Dispose() }
        }
    }
    return $out
}

function New-LocalAcceptanceReadback {
    param($Before, $After, $Runners, [bool]$Completed, [int]$ExitCode, [string]$Nonce)
    $standard = ($Before.token.status -eq 'MEASURED' -and $After.token.status -eq 'MEASURED' -and -not $Before.token.elevated -and -not $After.token.elevated)
    $runnerArray = @($Runners)
    $runnerStandard = ($runnerArray.Count -eq 3 -and @($runnerArray | Where-Object { $_.status -ne 'MEASURED' -or $_.admin_status -ne 'STANDARD_USER' }).Count -eq 0)
    $observed = 'NOT_RUN'
    if ($Completed -and $ExitCode -eq 0 -and $standard -and $runnerStandard) { $observed = 'PASS' }
    $path = @{}; $registry = @{}
    foreach ($n in @('user','machine')) { $path[$n] = Compare-PrivateObservation $Before.persistent_path[$n] $After.persistent_path[$n] }
    foreach ($n in @('user_environment_values','machine_environment_values')) { $registry[$n] = Compare-PrivateObservation $Before.registry_scopes[$n] $After.registry_scopes[$n] }
    return @{
        schema_version=1
        collector='local_acceptance_observer.ps1'
        fingerprint_nonce=$Nonce
        action=@{completed=$Completed;exit_code=$ExitCode;status=$(if ($Completed -and $ExitCode -eq 0) {'PASS'} else {'FAIL'});reason=$(if ($Completed) {'ACTION_EXIT_RECORDED'} else {'ACCEPTANCE_ACTION_EXCEPTION'})}
        before=$Before;after=$After
        runner_tokens=$runnerArray
        standard_user_observed_completion=@{status=$observed;scope='launcher token at boundaries and three bound QA runner tokens; child/target token tree and mid-run elevation are not audited'}
        all_descendant_tokens=@{status='NOT_RUN';reason='PROCESS_TREE_TOKEN_AUDIT_NOT_IMPLEMENTED'}
        persistent_path=$path
        registry_selected_values=$registry
        registry_full_write_audit=@{status='NOT_RUN';reason='ONLY_SELECTED_ENVIRONMENT_ROOT_VALUES_SNAPSHOTTED; no continuous write audit or other hives/subkeys'}
        program_files_write_audit=@{status='NOT_RUN';reason='NOT_COLLECTED'}
        fully_offline=@{status='NOT_RUN';reason='PASSIVE_INTERFACE_STATE_DOES_NOT_PROVE_COMPLETE_OFFLINE'}
        human_test=@{status='NOT_RUN';reason='NO_HUMAN_REVIEW_COLLECTED'}
        management_final=@{status='NOT_RUN';reason='LOCAL_OBSERVATIONS_DO_NOT_AUTOMATICALLY_ACCEPT_ALL_MANAGEMENT_GATES'}
        privacy=@{raw_registry_values_included=$false;raw_registry_value_names_included=$false;user_names_addresses_mac_or_adapter_names_included=$false;method='aggregate per-scope fingerprints only; random nonce changes across invocations'}
        product_acceptance='HOLD';stable='HOLD';release='HOLD'
    }
}

function Invoke-ObservedLocalAcceptance {
    param([string]$OutputRoot, [scriptblock]$Action)
    [IO.Directory]::CreateDirectory($OutputRoot) | Out-Null
    $nonce = [Guid]::NewGuid().ToString('N')
    $before = Get-LocalObservation -Nonce $nonce
    $completed = $false; $code = 1
    try {
        $result = & $Action
        if ($result -isnot [int]) { throw 'ACTION_EXIT_CODE_NOT_INTEGER' }
        $code = $result; $completed = $true
    } catch { $code = 1 }
    finally {
        $after = Get-LocalObservation -Nonce $nonce
        $runners = @(Get-RunnerTokenObservations -OutputRoot $OutputRoot)
        $data = New-LocalAcceptanceReadback $before $after $runners $completed $code $nonce
        $data.collector_sha256 = (Get-FileHash -LiteralPath $script:LocalObserverSourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $destination = Join-Path $OutputRoot 'LOCAL_ACCEPTANCE_READBACK.json'
        $temporary = $destination + '.writing.' + [Guid]::NewGuid().ToString('N')
        $json = ConvertTo-Json -InputObject $data -Depth 24
        [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $destination -Force
    }
    return [int]$code
}
