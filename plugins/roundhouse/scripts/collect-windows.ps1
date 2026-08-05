[CmdletBinding(DefaultParameterSetName = "Collect")]
param(
    [Parameter(Mandatory = $true, ParameterSetName = "Collect")][string]$ConfigPath,
    [Parameter(Mandatory = $true, ParameterSetName = "Collect")][string]$HostId,
    [Parameter(Mandatory = $true, ParameterSetName = "Collect")]
    [ValidatePattern("^[0-9A-Fa-f]{64}$")][string]$ControllerConfigDigest,
    [Parameter(ParameterSetName = "Collect")]
    [string]$SnapshotId = ([DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ") + "-" + $PID),
    [Parameter(ParameterSetName = "Collect")][string[]]$Sections = @("all"),
    [Parameter(ParameterSetName = "Collect")][switch]$AllowAuthVerify,
    [Parameter(Mandatory = $true, ParameterSetName = "SelfTest")][switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $OutputEncoding
$script:Records = New-Object System.Collections.Generic.List[object]
$script:HasProblems = $false
$ObservedAt = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")

function Test-Section([string]$Name) {
    return $Sections -contains "all" -or $Sections -contains $Name
}

function Limit-Text([object]$Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }
    $text = [string]$Value
    if ($text.Length -gt 8192) { return $text.Substring(0, 8192) }
    return $text
}

function Add-Record {
    param(
        [string]$Kind,
        [string]$Id,
        [ValidateSet("present", "absent", "partial", "unavailable", "error")][string]$Status,
        [ValidateSet("high", "medium", "low", "unknown")][string]$Confidence,
        [hashtable]$Data = @{},
        [object[]]$Evidence = @(),
        [object[]]$Errors = @()
    )
    [void]$script:Records.Add([ordered]@{
        schema         = "roundhouse.inventory"
        schema_version = 1
        snapshot_id    = $SnapshotId
        host_id        = $HostId
        kind           = $Kind
        id             = Limit-Text $Id
        observed_at    = $ObservedAt
        status         = $Status
        confidence     = $Confidence
        data           = $Data
        evidence       = $Evidence
        errors         = $Errors
    })
    if ($Kind -ne "privilege_broker" -and $Status -in @("partial", "unavailable", "error")) {
        $script:HasProblems = $true
    }
}

function Resolve-UserPath([string]$Path) {
    if ($Path -eq "~") { return $HOME }
    if ($Path.StartsWith("~/") -or $Path.StartsWith("~\")) {
        return Join-Path $HOME $Path.Substring(2)
    }
    return $Path
}

function Get-SafeRemote([string]$Remote) {
    if ([string]::IsNullOrWhiteSpace($Remote)) { return $null }
    $value = $Remote -replace '^([A-Za-z][A-Za-z0-9+.-]*://)[^/@]*@', '$1'
    $value = $value -replace '^[^/@]+@([^:]+:.*)$', '$1'
    return Limit-Text (($value -split '\?')[0])
}

function Get-CanonicalGitSource([string]$Remote) {
    $Value = Get-SafeRemote $Remote
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $Value = $Value.ToLowerInvariant()
    $Value = $Value -replace '^[a-z][a-z0-9+.-]*://', ''
    $Value = $Value -replace '^git@', ''
    $Value = $Value -replace '^([^/]+):', '$1/'
    $Value = $Value.TrimEnd("/")
    $Value = $Value -replace '\.git$', ''
    if (($Value -split '/').Count -eq 2) { return "github.com/$Value" }
    return $Value
}

function Get-TextSha256([string]$Text) {
    $Hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $Bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return (($Hasher.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
    } finally {
        $Hasher.Dispose()
    }
}

function Test-PrivilegePolicy([string[]]$Lines) {
    if ($Lines.Count -ne 12 -or $Lines[0] -cne "policy|1|catalog=1") { return $false }
    $Expected = [ordered]@{
        "apt.autoremove.v1" = @("posix-root-v1", "none")
        "apt.install-package-version.v1" = @("posix-root-v1", "package-source-version-closure-set-sha256")
        "apt.update-metadata.v1" = @("posix-root-v1", "none")
        "apt.upgrade-package.v1" = @("posix-root-v1", "package-source-channel-set-sha256")
        "macos.apply-system-setting.v1" = @("macos-root-v1", "macos-system-setting-sha256")
        "macos.install-signed-pkg.v1" = @("macos-root-v1", "macos-signed-pkg-sha256")
        "profile.apply-managed-bundle.v1" = @("windows-user-s4u-v1", "profile-bundle-set-sha256")
        "profile.inventory-managed-state.v1" = @("windows-user-s4u-v1", "profile-bundle-set-sha256")
        "winget.install-machine-package.v1" = @("windows-system-v1", "winget-package-version-set-sha256")
        "winget.inventory-machine.v1" = @("windows-system-v1", "none")
        "winget.upgrade-machine-package.v1" = @("windows-system-v1", "winget-package-channel-set-sha256")
    }
    $Previous = ""
    $Seen = @{}
    foreach ($Line in $Lines[1..11]) {
        if ($Line -notmatch '^[\x20-\x7e]+$') { return $false }
        $Fields = $Line.Split('|')
        if ($Fields.Count -ne 6 -or $Fields[0] -cne "action" -or
            -not $Expected.Contains($Fields[1]) -or $Seen.ContainsKey($Fields[1]) -or
            ($Previous.Length -gt 0 -and [StringComparer]::Ordinal.Compare($Previous, $Fields[1]) -ge 0) -or
            $Fields[2] -cne $Expected[$Fields[1]][0] -or
            $Fields[4] -cne $Expected[$Fields[1]][1] -or
            $Fields[3] -notin @("enabled", "disabled") -or
            ($Fields[4] -eq "none" -and $Fields[5] -cne "-") -or
            ($Fields[4] -ne "none" -and $Fields[5] -cne "-" -and $Fields[5] -notmatch '^[0-9a-f]{64}$')) {
            return $false
        }
        $Seen[$Fields[1]] = $true
        $Previous = $Fields[1]
    }
    return $Seen.Count -eq $Expected.Count
}

function Get-CanonicalAsciiLines([string]$Path, [int]$MaximumBytes) {
    try {
        [byte[]]$Bytes = [IO.File]::ReadAllBytes($Path)
        if ($Bytes.Count -eq 0 -or $Bytes.Count -gt $MaximumBytes -or $Bytes[-1] -ne 10) { return $null }
        foreach ($Byte in $Bytes) {
            if ($Byte -ne 10 -and ($Byte -lt 32 -or $Byte -gt 126)) { return $null }
        }
        $Text = [Text.Encoding]::ASCII.GetString($Bytes)
        return [string[]]@($Text.Substring(0, $Text.Length - 1).Split("`n"))
    } catch { return $null }
}

function Test-PrivilegeConstraints([string[]]$PolicyLines, [string[]]$Lines, [string]$FileDigest) {
    if ($null -eq $Lines -or $Lines.Count -lt 1 -or
        $Lines[0] -notmatch '^constraints\|1\|generation=([1-9][0-9]{0,9})\|policy-sha256=([0-9a-f]{64})$') {
        return $null
    }
    [int64]$Generation = $Matches[1]
    if ($Generation -lt 1 -or $Generation -gt 2147483647 -or
        $Matches[2] -cne (Get-TextSha256 (($PolicyLines -join "`n") + "`n"))) { return $null }
    $Previous = ""
    $SeenMembership = @{}
    foreach ($Line in @($Lines | Select-Object -Skip 1)) {
        if ($Line.Length -gt 2048 -or ($Previous.Length -gt 0 -and
            [StringComparer]::Ordinal.Compare($Previous, $Line) -ge 0)) { return $null }
        $Previous = $Line
        $Fields = $Line.Split('|')
        $MembershipAction = if ($Fields[0] -ceq "profile") { "profile" } else { $Fields[1] }
        $MembershipToken = if ($Fields[0] -ceq "profile") { $Fields[1] } else { $Fields[2] }
        $MembershipKey = $MembershipAction + "`0" + $MembershipToken
        if ($SeenMembership.ContainsKey($MembershipKey)) { return $null }
        $SeenMembership[$MembershipKey] = $true
        $Token = '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'
        $Atom = '^[A-Za-z0-9][A-Za-z0-9._:+@,-]{0,255}$'
        $Version = '^[0-9A-Za-z][0-9A-Za-z.+:~_-]{0,127}$'
        $Digest = '^[0-9a-f]{64}$'
        switch -CaseSensitive ($Fields[0]) {
            "apt-install" {
                if ($Fields.Count -ne 8 -or $Fields[1] -cne "apt.install-package-version.v1" -or
                    $Fields[2] -notmatch $Token -or $Fields[3] -notmatch $Atom -or $Fields[4] -notmatch $Atom -or
                    $Fields[5] -notmatch $Version -or $Fields[6] -notmatch $Digest -or $Fields[7] -notmatch $Digest) { return $null }
            }
            "apt-upgrade" {
                [int64]$Major = 0
                if ($Fields.Count -ne 9 -or $Fields[1] -cne "apt.upgrade-package.v1" -or
                    $Fields[2] -notmatch $Token -or $Fields[3] -notmatch $Atom -or $Fields[4] -notmatch $Atom -or
                    $Fields[5] -notmatch $Version -or $Fields[6] -notmatch $Version -or
                    -not [int64]::TryParse($Fields[7], [ref]$Major) -or $Major -lt 0 -or $Major -gt 2147483647 -or
                    $Fields[8] -notmatch $Digest) { return $null }
            }
            "macos-pkg" {
                [int64]$PackageBytes = 0
                if ($Fields.Count -ne 12 -or $Fields[1] -cne "macos.install-signed-pkg.v1" -or
                    $Fields[2] -notmatch $Token -or
                    $Fields[3] -cnotin @("script-free", "sealed-cask-payload-v1") -or
                    $Fields[4] -cnotmatch '^[1-9][0-9]{0,9}$' -or
                    -not [int64]::TryParse($Fields[4], [ref]$PackageBytes) -or
                    $PackageBytes -lt 1 -or $PackageBytes -gt 2147483647 -or
                    $Fields[5] -cnotmatch $Digest -or $Fields[6] -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$' -or
                    $Fields[7] -notmatch $Version -or $Fields[8] -cnotmatch '^[A-Z0-9]{10}$' -or
                    $Fields[9] -cnotmatch $Digest -or $Fields[10] -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$' -or
                    $Fields[11] -notmatch $Version) { return $null }
            }
            "macos-setting" {
                if ($Fields.Count -ne 5 -or $Fields[1] -cne "macos.apply-system-setting.v1" -or
                    $Fields[2] -notmatch $Token) { return $null }
                $SettingValid = switch -CaseSensitive ($Fields[3]) {
                    "timezone" { $Fields[4] -cmatch '^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+){0,2}$' -and $Fields[4].Length -le 255 }
                    "network-time-server" { $Fields[4] -cmatch '^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$' -and -not $Fields[4].Contains('..') }
                    { $_ -cin @("wake-on-network-access", "restart-after-power-failure") } { $Fields[4] -cin @("on", "off") }
                    { $_ -cin @("computer-sleep", "display-sleep") } {
                        if ($Fields[4] -ceq "Never") { $true }
                        else { [int64]$Minutes = 0; $Fields[4] -cmatch '^[1-9][0-9]{0,2}$' -and [int64]::TryParse($Fields[4], [ref]$Minutes) -and $Minutes -le 180 }
                    }
                    default { $false }
                }
                if (-not $SettingValid) { return $null }
            }
            "profile" {
                [int64]$Entries = 0; [int64]$Bytes = 0
                if ($Fields.Count -ne 9 -or $Fields[1] -notmatch $Token -or
                    $Fields[2] -notmatch '^S-[0-9]+(-[0-9]+){1,14}$' -or $Fields[3] -notmatch $Atom -or
                    $Fields[4] -notmatch $Digest -or $Fields[5] -notmatch $Digest -or
                    $Fields[6] -notin @("managed-only", "managed-and-prune") -or
                    -not [int64]::TryParse($Fields[7], [ref]$Entries) -or $Entries -lt 1 -or $Entries -gt 100000 -or
                    -not [int64]::TryParse($Fields[8], [ref]$Bytes) -or $Bytes -lt 1 -or $Bytes -gt 1073741824) { return $null }
            }
            "winget-install" {
                if ($Fields.Count -ne 14 -or $Fields[1] -cne "winget.install-machine-package.v1" -or
                    $Fields[2] -notmatch $Token -or @($Fields[3..5] | Where-Object { $_ -notmatch $Atom }).Count -gt 0 -or
                    $Fields[6] -notmatch $Digest -or $Fields[7] -cne "machine" -or
                    @($Fields[8..10] | Where-Object { $_ -notmatch $Atom }).Count -gt 0 -or
                    $Fields[11] -notmatch $Version -or $Fields[12] -cne "provider-enforced-manifest-hash" -or
                    $Fields[13] -cne "source-delegated-all") { return $null }
            }
            "winget-upgrade" {
                [int64]$Major = 0
                if ($Fields.Count -ne 16 -or $Fields[1] -cne "winget.upgrade-machine-package.v1" -or
                    $Fields[2] -notmatch $Token -or @($Fields[3..5] | Where-Object { $_ -notmatch $Atom }).Count -gt 0 -or
                    $Fields[6] -notmatch $Digest -or $Fields[7] -cne "machine" -or
                    @($Fields[8..10] | Where-Object { $_ -notmatch $Atom }).Count -gt 0 -or
                    $Fields[11] -notmatch $Version -or $Fields[12] -notmatch $Version -or
                    -not [int64]::TryParse($Fields[13], [ref]$Major) -or $Major -lt 0 -or $Major -gt 2147483647 -or
                    $Fields[14] -cne "provider-enforced-manifest-hash" -or $Fields[15] -cne "source-delegated-all") { return $null }
            }
            default { return $null }
        }
    }
    $Tokens = @{}
    foreach ($Action in @(
        "apt.autoremove.v1", "apt.install-package-version.v1", "apt.update-metadata.v1",
        "apt.upgrade-package.v1", "macos.apply-system-setting.v1", "macos.install-signed-pkg.v1",
        "profile.apply-managed-bundle.v1", "profile.inventory-managed-state.v1",
        "winget.install-machine-package.v1", "winget.inventory-machine.v1", "winget.upgrade-machine-package.v1")) {
        [string[]]$Group = @($Lines | Select-Object -Skip 1 | Where-Object {
            $Parts = $_.Split('|')
            ($Parts[0] -ceq "profile" -and $Action.StartsWith("profile.")) -or
                ($Parts[0] -cne "profile" -and $Parts[1] -ceq $Action)
        })
        $PolicyFields = @($PolicyLines | Where-Object { $_.Split('|')[1] -ceq $Action })[0].Split('|')
        if ($PolicyFields[5] -cne "-" -and
            ($Group.Count -eq 0 -or (Get-TextSha256 (($Group -join "`n") + "`n")) -cne $PolicyFields[5])) { return $null }
        if ($PolicyFields[5] -ceq "-" -and $Group.Count -gt 0 -and -not $Action.StartsWith("profile.")) { return $null }
        $Tokens[$Action] = @($Group | ForEach-Object {
            $Parts = $_.Split('|'); if ($Parts[0] -ceq "profile") { $Parts[1] } else { $Parts[2] }
        } | Sort-Object -Unique)
    }
    $Profiles = @($Lines | Select-Object -Skip 1 | Where-Object {
        $_.StartsWith("profile|", [StringComparison]::Ordinal)
    } | ForEach-Object {
        $Fields = $_.Split('|')
        [ordered]@{
            policy_token = $Fields[1]
            target_sid = $Fields[2]
            profile_root_id = $Fields[3]
            entry_map_digest = $Fields[4]
            marketplace_set_digest = $Fields[5]
            delete_mode = $Fields[6]
            max_entries = [int64]$Fields[7]
            max_bytes = [int64]$Fields[8]
        }
    })
    return [pscustomobject]@{
        Generation = $Generation
        Digest = $FileDigest
        Tokens = $Tokens
        Profiles = $Profiles
    }
}

function Test-WindowsProtectedFile([string]$Path) {
    try {
        $Item = Get-Item -LiteralPath $Path -Force
        if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        if ($env:OS -ne "Windows_NT") { return $false }
        $Acl = Get-Acl -LiteralPath $Path
        if ([string]$Acl.Owner -notmatch '(S-1-5-18|S-1-5-32-544|SYSTEM|Administrators)$') { return $false }
        foreach ($Rule in $Acl.Access) {
            if ($Rule.AccessControlType -eq "Allow" -and
                ($Rule.FileSystemRights -band ([Security.AccessControl.FileSystemRights]::Write -bor
                    [Security.AccessControl.FileSystemRights]::Modify -bor
                    [Security.AccessControl.FileSystemRights]::FullControl)) -ne 0 -and
                [string]$Rule.IdentityReference -notmatch '(S-1-5-18|S-1-5-32-544|SYSTEM|Administrators|TrustedInstaller)$') {
                return $false
            }
        }
        return $true
    } catch { return $false }
}

function Test-WindowsPublicProjectionFile([string]$Path) {
    try {
        if ($env:OS -ne "Windows_NT") { return $false }
        $Item = Get-Item -LiteralPath $Path -Force
        if ($Item.PSIsContainer -or ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        $Acl = Get-Acl -LiteralPath $Path
        if ([string]$Acl.Owner -notmatch '(S-1-5-18|S-1-5-32-544|SYSTEM|Administrators)$') { return $false }
        foreach ($Rule in $Acl.Access) {
            if ($Rule.AccessControlType -eq "Allow" -and
                ($Rule.FileSystemRights -band ([Security.AccessControl.FileSystemRights]::Write -bor
                    [Security.AccessControl.FileSystemRights]::Modify -bor
                    [Security.AccessControl.FileSystemRights]::FullControl -bor
                    [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
                    [Security.AccessControl.FileSystemRights]::TakeOwnership)) -ne 0 -and
                [string]$Rule.IdentityReference -notmatch '(S-1-5-18|S-1-5-32-544|SYSTEM|Administrators|TrustedInstaller)$') {
                return $false
            }
        }
        return $true
    } catch { return $false }
}

function Read-ExactCanonicalFields(
    [string[]]$Lines,
    [string[]]$Names,
    [string]$Header,
    [string]$Trailer
) {
    if ($null -eq $Lines -or $Lines.Count -ne $Names.Count + 2 -or
        $Lines[0] -cne $Header -or $Lines[-1] -cne $Trailer) { return $null }
    $Fields = [ordered]@{}
    for ($Index = 0; $Index -lt $Names.Count; $Index++) {
        $Parts = $Lines[$Index + 1].Split('|')
        if ($Parts.Count -ne 2 -or $Parts[0] -cne $Names[$Index] -or
            $Parts[1].Length -gt 4096 -or $Fields.Contains($Parts[0])) { return $null }
        $Fields[$Parts[0]] = $Parts[1]
    }
    return [pscustomobject]$Fields
}

function ConvertFrom-WindowsSftpCanonicalBytes([byte[]]$Bytes, [int]$MaximumBytes) {
    if ($null -eq $Bytes -or $Bytes.Count -lt 1 -or $Bytes.Count -gt $MaximumBytes -or
        $Bytes[-1] -ne 10) { return $null }
    foreach ($Byte in $Bytes) {
        if ($Byte -ne 10 -and ($Byte -lt 32 -or $Byte -gt 126)) { return $null }
    }
    $Text = [Text.Encoding]::ASCII.GetString($Bytes)
    if ($Text.Contains("`r") -or $Text.Contains("`0")) { return $null }
    return [string[]]@($Text.Substring(0, $Text.Length - 1).Split("`n"))
}

function Get-WindowsSftpBytesSha256([byte[]]$Bytes) {
    $Hasher = [Security.Cryptography.SHA256]::Create()
    try { return (($Hasher.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") }) -join "") }
    finally { $Hasher.Dispose() }
}

function Test-WindowsSftpDigest([string]$Value) { return $Value -cmatch '^[0-9a-f]{64}$' }
function Test-WindowsSftpThumbprint([string]$Value) {
    return $Value -cmatch '^(?:[0-9A-F]{40}|[0-9A-F]{64})$'
}
function Test-WindowsSftpFingerprint([string]$Value) {
    return $Value -cmatch '^SHA256:[A-Za-z0-9+/]{43}=?$'
}
function Test-WindowsSftpSid([string]$Value) {
    return $Value -cmatch '^S-[0-9]+(?:-[0-9]+){1,14}$' -and $Value -cnotmatch '-500$'
}
function Test-WindowsSftpHost([string]$Value) {
    return $Value.Length -le 253 -and
        $Value -cmatch '^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$'
}
function Test-WindowsSftpUInt([string]$Value, [bool]$Positive = $false) {
    if ($Value -cnotmatch '^(0|[1-9][0-9]{0,18})$') { return $false }
    return -not $Positive -or $Value -cne "0"
}
function Test-WindowsSftpCidr([string]$Value) {
    $Parts = $Value.Split('/')
    if ($Parts.Count -ne 2 -or $Parts[1] -notmatch '^(0|[1-9][0-9]{0,2})$') { return $false }
    [Net.IPAddress]$Address = $null
    if (-not [Net.IPAddress]::TryParse($Parts[0], [ref]$Address)) { return $false }
    [int]$Prefix = $Parts[1]
    if ($Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) { return $Prefix -le 32 }
    if ($Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) { return $Prefix -le 128 }
    return $false
}
function Test-WindowsSftpCidrs([string]$Value) {
    if ($Value.Length -lt 1 -or $Value.Length -gt 2048) { return $false }
    $Items = [string[]]@($Value.Split(','))
    if ($Items.Count -lt 1 -or $Items.Count -gt 32) { return $false }
    $Seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $Previous = ""
    foreach ($Item in $Items) {
        if (-not (Test-WindowsSftpCidr $Item) -or -not $Seen.Add($Item) -or
            ($Previous.Length -gt 0 -and [StringComparer]::Ordinal.Compare($Previous, $Item) -ge 0)) {
            return $false
        }
        $Previous = $Item
    }
    return $true
}

function Read-WindowsSftpCandidateLines([string[]]$Lines) {
    $Names = @(
        "operation", "authorization", "host", "request-account", "request-sid", "endpoint-principal",
        "primary-ca-fingerprint", "primary-ca-generation", "previous-ca-fingerprint",
        "previous-ca-generation", "krl-generation", "management-cidrs", "host-key-fingerprint",
        "intent-sha256", "controller-signature-sha256", "controller-signing-thumbprint",
        "release-publisher-thumbprint", "protected-entrypoint-sha256", "u3-state", "u3-epoch",
        "u3-generation-sha256", "u3-active-pointer-sha256", "u3-task-sha256", "u3-broker-sha256",
        "chroot-contract-sha256", "slot-acl-sha256", "results-acl-sha256", "quota-contract-sha256",
        "openssh-contract-sha256", "configuration-sha256", "firewall-contract-sha256", "issued-at",
        "expires-at", "controller-signing"
    )
    $Fields = Read-ExactCanonicalFields $Lines $Names "windows-sftp-enrollment-candidate|1" "end-candidate|"
    if ($null -eq $Fields -or $Fields.operation -cnotin @("install", "repair") -or
        $Fields.authorization -cne "inert-unsigned-local-observation" -or
        -not (Test-WindowsSftpHost $Fields.host) -or
        $Fields.'request-account' -cne "MachineUtilitiesRequest" -or
        $Fields.'endpoint-principal' -cne "machine-utilities-windows" -or
        -not (Test-WindowsSftpSid $Fields.'request-sid') -or
        -not (Test-WindowsSftpFingerprint $Fields.'primary-ca-fingerprint') -or
        -not (Test-WindowsSftpUInt $Fields.'primary-ca-generation' $true) -or
        -not (Test-WindowsSftpUInt $Fields.'krl-generation' $true) -or
        -not (Test-WindowsSftpCidrs $Fields.'management-cidrs') -or
        -not (Test-WindowsSftpFingerprint $Fields.'host-key-fingerprint') -or
        -not (Test-WindowsSftpThumbprint $Fields.'controller-signing-thumbprint') -or
        -not (Test-WindowsSftpThumbprint $Fields.'release-publisher-thumbprint') -or
        $Fields.'u3-state' -cne "verified" -or -not (Test-WindowsSftpUInt $Fields.'u3-epoch' $true) -or
        $Fields.'controller-signing' -cne "required-separate") { return $null }
    if ($Fields.'previous-ca-fingerprint' -ceq "-") {
        if ($Fields.'previous-ca-generation' -cne "0") { return $null }
    } elseif (-not (Test-WindowsSftpFingerprint $Fields.'previous-ca-fingerprint') -or
        -not (Test-WindowsSftpUInt $Fields.'previous-ca-generation' $true) -or
        $Fields.'previous-ca-fingerprint' -ceq $Fields.'primary-ca-fingerprint') { return $null }
    foreach ($Name in @(
            "intent-sha256", "controller-signature-sha256", "protected-entrypoint-sha256",
            "u3-generation-sha256", "u3-active-pointer-sha256", "u3-task-sha256", "u3-broker-sha256",
            "chroot-contract-sha256", "slot-acl-sha256", "results-acl-sha256", "quota-contract-sha256",
            "openssh-contract-sha256", "configuration-sha256", "firewall-contract-sha256")) {
        if (-not (Test-WindowsSftpDigest $Fields.$Name)) { return $null }
    }
    if (-not (Test-WindowsSftpUInt $Fields.'issued-at' $true) -or
        -not (Test-WindowsSftpUInt $Fields.'expires-at' $true)) { return $null }
    [int64]$IssuedAt = $Fields.'issued-at'; [int64]$ExpiresAt = $Fields.'expires-at'
    if ($ExpiresAt -le $IssuedAt -or ($ExpiresAt - $IssuedAt) -gt 86400) { return $null }
    return $Fields
}

function Read-WindowsSftpReadinessLines([string[]]$Lines) {
    if ($null -eq $Lines -or $Lines.Count -lt 15) { return $null }
    $StateLine = $Lines[1].Split('|')
    if ($StateLine.Count -ne 2 -or $StateLine[0] -cne "state") { return $null }
    $Names = @("state", "reason", "host", "request-sid", "intent-sha256", "candidate-sha256",
        "host-key-fingerprint", "transport-ready", "broker-ready", "node-identity-ready",
        "action-context-ready", "controller-signature-ready", "readiness-authority")
    if ($StateLine[1] -ceq "revoked") { $Names += "revoke-intent-sha256" }
    $Fields = Read-ExactCanonicalFields $Lines $Names "windows-sftp-readiness|1" "end-readiness|"
    if ($null -eq $Fields -or
        $Fields.state -cnotin @("ready", "awaiting-controller-signature", "revoked", "draining", "drifted") -or
        $Fields.reason -cnotmatch '^[a-z][a-z0-9_]{0,127}$' -or
        -not (Test-WindowsSftpHost $Fields.host) -or -not (Test-WindowsSftpSid $Fields.'request-sid') -or
        -not (Test-WindowsSftpDigest $Fields.'intent-sha256') -or
        -not (Test-WindowsSftpDigest $Fields.'candidate-sha256') -or
        -not (Test-WindowsSftpFingerprint $Fields.'host-key-fingerprint') -or
        $Fields.'transport-ready' -cnotin @("true", "false") -or
        $Fields.'controller-signature-ready' -cnotin @("true", "false") -or
        $Fields.'broker-ready' -cne "observed-separately" -or
        $Fields.'node-identity-ready' -cne "observed-separately" -or
        $Fields.'action-context-ready' -cne "observed-separately") { return $null }
    if ($Fields.state -ceq "ready") {
        if ($Fields.reason -cne "controller_signed_receipt_and_local_transport_verified" -or
            $Fields.'transport-ready' -cne "true" -or $Fields.'controller-signature-ready' -cne "true" -or
            $Fields.'readiness-authority' -cne "controller-signed-receipt-plus-local-observation") {
            return $null
        }
    } elseif ($Fields.state -ceq "revoked") {
        if ($Fields.reason -cne "managed_transport_removed" -or $Fields.'transport-ready' -cne "false" -or
            $Fields.'controller-signature-ready' -cne "false" -or
            $Fields.'readiness-authority' -cne "controller-signed-revocation-plus-local-observation" -or
            -not (Test-WindowsSftpDigest $Fields.'revoke-intent-sha256')) { return $null }
    } elseif ($Fields.'transport-ready' -cne "false" -or
        $Fields.'controller-signature-ready' -cne "false" -or
        $Fields.'readiness-authority' -cne "controller-signed-receipt-plus-local-observation") {
        return $null
    }
    return $Fields
}

function Test-WindowsSftpDetachedCms(
    [byte[]]$Content,
    [byte[]]$Signature,
    [string]$ExpectedThumbprint,
    [int64]$IssuedAt,
    [int64]$ExpiresAt
) {
    try {
        Add-Type -AssemblyName System.Security.Cryptography.Pkcs -ErrorAction SilentlyContinue
        $Cms = [Security.Cryptography.Pkcs.SignedCms]::new(
            [Security.Cryptography.Pkcs.ContentInfo]::new($Content), $true)
        $Cms.Decode($Signature)
        $Cms.CheckSignature($true)
        if ($Cms.SignerInfos.Count -ne 1 -or $null -eq $Cms.SignerInfos[0].Certificate) { return $false }
        $Certificate = $Cms.SignerInfos[0].Certificate
        $Issued = [DateTimeOffset]::FromUnixTimeSeconds($IssuedAt).UtcDateTime
        $Expires = [DateTimeOffset]::FromUnixTimeSeconds($ExpiresAt).UtcDateTime
        return $Certificate.Thumbprint.ToUpperInvariant() -ceq $ExpectedThumbprint -and
            $Certificate.NotBefore.ToUniversalTime() -le $Issued -and
            $Certificate.NotAfter.ToUniversalTime() -ge $Expires
    } catch { return $false }
}

function Test-WindowsSftpCandidateReadinessBinding(
    [object]$Candidate,
    [object]$Readiness,
    [string]$CandidateSha256
) {
    return $null -ne $Candidate -and $null -ne $Readiness -and
        $Readiness.state -ceq "ready" -and $Readiness.'transport-ready' -ceq "true" -and
        $Readiness.'controller-signature-ready' -ceq "true" -and
        $Readiness.'candidate-sha256' -ceq $CandidateSha256 -and
        $Readiness.host -ceq $Candidate.host -and
        $Readiness.'request-sid' -ceq $Candidate.'request-sid' -and
        $Readiness.'intent-sha256' -ceq $Candidate.'intent-sha256' -and
        $Readiness.'host-key-fingerprint' -ceq $Candidate.'host-key-fingerprint'
}

function Test-WindowsExactProjectionPath(
    [string]$Path,
    [string]$ExpectedSddl,
    [bool]$Directory
) {
    try {
        if ($env:OS -ne "Windows_NT") { return $false }
        $Item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ([bool]$Item.PSIsContainer -ne $Directory -or
            ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        $Expected = [Security.AccessControl.RawSecurityDescriptor]::new($ExpectedSddl)
        $ObservedSddl = (Get-Acl -LiteralPath $Path -ErrorAction Stop).GetSecurityDescriptorSddlForm(
            [Security.AccessControl.AccessControlSections]::All)
        $Observed = [Security.AccessControl.RawSecurityDescriptor]::new($ObservedSddl)
        [byte[]]$ExpectedBytes = [byte[]]::new($Expected.BinaryLength)
        [byte[]]$ObservedBytes = [byte[]]::new($Observed.BinaryLength)
        $Expected.GetBinaryForm($ExpectedBytes, 0); $Observed.GetBinaryForm($ObservedBytes, 0)
        return [Convert]::ToBase64String($ExpectedBytes) -ceq [Convert]::ToBase64String($ObservedBytes)
    } catch { return $false }
}

function Read-WindowsSftpProtectedReadiness([string]$ProgramDataRoot) {
    try {
        if ($env:OS -ne "Windows_NT") { return $null }
        $CanonicalProgramData = [IO.Path]::GetFullPath([Environment]::GetFolderPath("CommonApplicationData"))
        if (-not [IO.Path]::GetFullPath($ProgramDataRoot).Equals(
                $CanonicalProgramData, [StringComparison]::OrdinalIgnoreCase)) { return $null }
        $PublicRoot = Join-Path $CanonicalProgramData "MachineUtilities-Sftp-Public"
        $ReadinessPath = Join-Path $PublicRoot "readiness"
        $DirectorySddl = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)"
        $FileSddl = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x120089;;;BU)"
        if (-not (Test-WindowsExactProjectionPath $PublicRoot $DirectorySddl $true) -or
            -not (Test-WindowsExactProjectionPath $ReadinessPath $FileSddl $false)) { return $null }
        [byte[]]$ReadinessBytes = [IO.File]::ReadAllBytes($ReadinessPath)
        return Read-WindowsSftpReadinessLines (ConvertFrom-WindowsSftpCanonicalBytes $ReadinessBytes 16384)
    } catch { return $null }
}

function Get-WindowsSftpContractDigests([string]$RequestSid) {
    $SlotDirectory = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x1200a0;;;$RequestSid)"
    $SlotFile = "O:${RequestSid}G:BAD:P(D;;0x000c0000;;;OW)(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x00100002;;;$RequestSid)"
    $ResultsDirectory = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x1200a0;;;$RequestSid)"
    $ResultFile = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x120089;;;$RequestSid)"
    $Chroot = @("windows-sftp-chroot-contract|1", "chroot|C:\ProgramData\MachineUtilities\chroot",
        "request|/ingress/slot/request", "signature|/ingress/slot/request.sig", "payload|/ingress/slot/payload",
        "commit|/ingress/slot/commit", "results|/results/<request-id>.result", "projection|direct-non-reparse",
        "end-chroot|")
    $Slot = @("windows-sftp-slot-acl-contract|1", "slot-directory-sddl|$SlotDirectory",
        "slot-file-sddl|$SlotFile", "file-count|4", "create|denied", "delete|denied", "rename|denied",
        "list|denied", "owner-rights-write-data-only|true", "end-slot-acl|")
    $Results = @("windows-sftp-results-acl-contract|1", "results-directory-sddl|$ResultsDirectory",
        "result-file-sddl|$ResultFile", "create|denied", "write|denied", "delete|denied", "rename|denied",
        "list|denied", "end-results-acl|")
    $Quota = @("windows-sftp-quota-contract|1", "request-sid|$RequestSid", "limit-bytes|68157440",
        "warning-bytes|67108864", "tracking|enabled", "enforcement|enabled", "volume|C:\ProgramData", "end-quota|")
    $OpenSsh = @("windows-sftp-openssh-contract|1", "request-account|MachineUtilitiesRequest",
        "endpoint-principal|machine-utilities-windows", "chroot|C:\ProgramData\MachineUtilities\chroot",
        "force-command|internal-sftp", "authentication|publickey-ca-certificate", "password|disabled",
        "keyboard-interactive|disabled", "pty|disabled", "x11|disabled", "tcp-forwarding|disabled",
        "stream-local-forwarding|disabled", "agent-forwarding|disabled", "tunnel|disabled", "user-rc|disabled",
        "user-environment|disabled", "permit-open|none", "permit-listen|none",
        "authorized-principals-command|absent", "end-openssh|")
    return [pscustomobject]@{
        Chroot = Get-TextSha256 (($Chroot -join "`n") + "`n")
        Slot = Get-TextSha256 (($Slot -join "`n") + "`n")
        Results = Get-TextSha256 (($Results -join "`n") + "`n")
        Quota = Get-TextSha256 (($Quota -join "`n") + "`n")
        OpenSsh = Get-TextSha256 (($OpenSsh -join "`n") + "`n")
    }
}

function Get-WindowsSftpFirewallContractDigest([string]$ManagementCidrs) {
    $Lines = @("windows-sftp-firewall-contract|1", "name|Machine Utilities Windows SFTP v1",
        "group|Machine Utilities", "direction|inbound", "action|allow", "protocol|tcp", "local-port|22",
        "service|sshd", "remote-addresses|$ManagementCidrs", "profiles|any",
        "activation-order|account-then-firewall-last", "end-firewall|")
    return Get-TextSha256 (($Lines -join "`n") + "`n")
}

function Test-WindowsSftpManagedFirewall([string]$ExpectedCidrs) {
    try {
        $Rules = @(NetSecurity\Get-NetFirewallRule -Name "MachineUtilities-Windows-Sftp-v1" -ErrorAction Stop)
        if ($Rules.Count -ne 1) { return $false }
        $Rule = $Rules[0]
        $Port = @(NetSecurity\Get-NetFirewallPortFilter -AssociatedNetFirewallRule $Rule -ErrorAction Stop)
        $Address = @(NetSecurity\Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $Rule -ErrorAction Stop)
        $Service = @(NetSecurity\Get-NetFirewallServiceFilter -AssociatedNetFirewallRule $Rule -ErrorAction Stop)
        if ($Port.Count -ne 1 -or $Address.Count -ne 1 -or $Service.Count -ne 1 -or
            [string]$Rule.DisplayName -cne "Machine Utilities Windows SFTP v1" -or
            [string]$Rule.Group -cne "Machine Utilities" -or [string]$Rule.Direction -cne "Inbound" -or
            [string]$Rule.Action -cne "Allow" -or [string]$Rule.Enabled -cne "True" -or
            [string]$Rule.Profile -cne "Any" -or [string]$Rule.EdgeTraversalPolicy -cne "Block" -or
            [string]$Port[0].Protocol -notin @("TCP", "6") -or [string]$Port[0].LocalPort -cne "22" -or
            [string]$Port[0].RemotePort -cne "Any" -or [string]$Address[0].LocalAddress -cne "Any" -or
            [string]$Service[0].Service -cne "sshd") { return $false }
        $Remote = [string[]]@($Address[0].RemoteAddress | ForEach-Object { [string]$_ })
        [Array]::Sort($Remote, [StringComparer]::Ordinal)
        return ($Remote -join ',') -ceq $ExpectedCidrs
    } catch { return $false }
}

function Get-WindowsSftpProtectedObservation(
    [string]$ProgramDataRoot,
    [object]$ConfiguredMachine,
    [object]$Route,
    [object]$U3Readiness,
    [object]$SftpReadiness
) {
    try {
        if ($env:OS -ne "Windows_NT" -or $null -eq $Route -or $null -eq $U3Readiness -or
            $null -eq $SftpReadiness -or $SftpReadiness.state -cne "ready") { return $null }
        $CanonicalProgramData = [IO.Path]::GetFullPath([Environment]::GetFolderPath("CommonApplicationData"))
        if (-not [IO.Path]::GetFullPath($ProgramDataRoot).Equals(
                $CanonicalProgramData, [StringComparison]::OrdinalIgnoreCase)) { return $null }
        $PublicRoot = Join-Path $CanonicalProgramData "MachineUtilities-Sftp-Public"
        $DirectorySddl = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)"
        $FileSddl = "O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x120089;;;BU)"
        $CandidatePath = Join-Path $PublicRoot "candidate.receipt"
        $SignaturePath = Join-Path $PublicRoot "candidate.receipt.p7s"
        if (-not (Test-WindowsExactProjectionPath $PublicRoot $DirectorySddl $true) -or
            -not (Test-WindowsExactProjectionPath $CandidatePath $FileSddl $false) -or
            -not (Test-WindowsExactProjectionPath $SignaturePath $FileSddl $false)) { return $null }
        [byte[]]$CandidateBytes = [IO.File]::ReadAllBytes($CandidatePath)
        [byte[]]$SignatureBytes = [IO.File]::ReadAllBytes($SignaturePath)
        if ($CandidateBytes.Count -lt 1 -or $CandidateBytes.Count -gt 65536 -or
            $SignatureBytes.Count -lt 1 -or $SignatureBytes.Count -gt 65536) { return $null }
        $Candidate = Read-WindowsSftpCandidateLines (
            ConvertFrom-WindowsSftpCanonicalBytes $CandidateBytes 65536)
        $CandidateSha256 = Get-WindowsSftpBytesSha256 $CandidateBytes
        if (-not (Test-WindowsSftpCandidateReadinessBinding $Candidate $SftpReadiness $CandidateSha256)) {
            return $null
        }
        [int64]$IssuedAt = $Candidate.'issued-at'; [int64]$ExpiresAt = $Candidate.'expires-at'
        # The signed candidate authorizes the completed enrollment ceremony;
        # after protected promotion it is historical evidence, not a renewable
        # readiness lease.  The elevated verifier remains the only mutation
        # path, while read-only local observation continues to require the
        # exact candidate bytes, signer, and certificate coverage of the
        # original issued/expires interval.
        if (-not (Test-WindowsSftpDetachedCms $CandidateBytes $SignatureBytes `
                $Candidate.'controller-signing-thumbprint' $IssuedAt $ExpiresAt)) { return $null }

        $ExpectedHost = ([string]$ConfiguredMachine.expected_hostname).ToUpperInvariant()
        $CurrentHost = ([Environment]::MachineName).ToUpperInvariant()
        $ExpectedCidrs = [string[]]@($Route.management_networks | ForEach-Object { [string]$_ })
        [Array]::Sort($ExpectedCidrs, [StringComparer]::Ordinal)
        $ExpectedCidrsText = $ExpectedCidrs -join ','
        if ($Candidate.host -cne $ExpectedHost -or $Candidate.host -cne $CurrentHost -or
            [string]$Route.mode -cne "windows-sftp" -or [int64]$Route.port -ne 22 -or
            [string]$Route.request_user -cne $Candidate.'request-account' -or
            $Candidate.'endpoint-principal' -cne "machine-utilities-windows" -or
            [string]$Route.pinned_host_key_fingerprint -cne $Candidate.'host-key-fingerprint' -or
            $Candidate.'management-cidrs' -cne $ExpectedCidrsText) { return $null }

        $Contracts = Get-WindowsSftpContractDigests $Candidate.'request-sid'
        if ($Candidate.'chroot-contract-sha256' -cne $Contracts.Chroot -or
            $Candidate.'slot-acl-sha256' -cne $Contracts.Slot -or
            $Candidate.'results-acl-sha256' -cne $Contracts.Results -or
            $Candidate.'quota-contract-sha256' -cne $Contracts.Quota -or
            $Candidate.'openssh-contract-sha256' -cne $Contracts.OpenSsh -or
            $Candidate.'firewall-contract-sha256' -cne
                (Get-WindowsSftpFirewallContractDigest $Candidate.'management-cidrs')) { return $null }

        # U6 readiness is a protected local projection emitted only after its
        # elevated verifier matched the candidate's task/chroot/ACL/quota and
        # native-canary inputs. Public v1 does not expose those protected bytes,
        # so this collector rechecks the public U3 bindings and fixed contracts
        # but deliberately does not claim portable independent canary proof.
        if ($U3Readiness.lifecycle -cnotin @("needs_transport_enrollment", "ready") -or
            $U3Readiness.'request-sid' -cne $Candidate.'request-sid' -or
            $U3Readiness.'request-principal' -cne $Candidate.'request-account' -or
            $U3Readiness.generation -cne $Candidate.'u3-epoch' -or
            $U3Readiness.'generation-sha256' -cne $Candidate.'u3-generation-sha256' -or
            $U3Readiness.'broker-sha256' -cne $Candidate.'u3-broker-sha256' -or
            $U3Readiness.'system-task-ready' -cne "true" -or
            $U3Readiness.'profile-task-ready' -cne "true" -or
            $U3Readiness.'native-canary-ready' -cne "true") { return $null }

        $SshdConfig = Join-Path $CanonicalProgramData "ssh/sshd_config"
        if (-not (Test-WindowsProtectedFile $SshdConfig) -or
            (Get-FileHash -LiteralPath $SshdConfig -Algorithm SHA256).Hash.ToLowerInvariant() -cne
                $Candidate.'configuration-sha256' -or
            -not (Test-WindowsSftpManagedFirewall $Candidate.'management-cidrs')) { return $null }
        $Account = Microsoft.PowerShell.LocalAccounts\Get-LocalUser -Name "MachineUtilitiesRequest" -ErrorAction Stop
        if (-not [bool]$Account.Enabled -or [string]$Account.Sid.Value -cne $Candidate.'request-sid') { return $null }
        return [pscustomobject]@{
            Authority = "protected-local-observation"
            Candidate = $Candidate
            CandidateSha256 = $CandidateSha256
            IssuedAt = $IssuedAt
            ExpiresAt = $ExpiresAt
        }
    } catch { return $null }
}

function Read-WindowsBrokerReadiness([string]$Path) {
    if (-not (Test-WindowsPublicProjectionFile $Path)) { return $null }
    $Lines = Get-CanonicalAsciiLines $Path 8192
    $Names = @("lifecycle", "broker-version", "broker-protocol", "broker-sha256", "generation", "generation-sha256",
        "policy-sha256", "constraints-sha256", "winget-context-sha256", "context-canary-sha256",
        "clock-skew-bound-seconds",
        "request-account-state", "request-sid",
        "request-principal", "system-task-ready", "profile-task-ready", "transport-ready", "native-canary-ready")
    if ($null -eq $Lines -or $Lines.Count -ne $Names.Count + 2 -or
        $Lines[0] -cne "windows-broker-readiness|1" -or $Lines[-1] -cne "end-readiness|") { return $null }
    $Fields = [ordered]@{}
    for ($Index = 0; $Index -lt $Names.Count; $Index++) {
        $Parts = $Lines[$Index + 1].Split('|')
        if ($Parts.Count -ne 2 -or $Parts[0] -cne $Names[$Index] -or $Fields.Contains($Parts[0])) { return $null }
        $Fields[$Parts[0]] = $Parts[1]
    }
    if ($Fields.lifecycle -cnotin @("needs_human_enrollment", "needs_native_canary", "needs_transport_enrollment",
            "recovery_required", "drifted", "revoked", "ready") -or
        $Fields.'broker-version' -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or
        $Fields.'broker-protocol' -cne "1" -or
        @($Fields.'broker-sha256', $Fields.'generation-sha256', $Fields.'policy-sha256',
            $Fields.'constraints-sha256', $Fields.'winget-context-sha256',
            $Fields.'context-canary-sha256' | Where-Object {
                $_ -cne "-" -and $_ -cnotmatch '^[0-9a-f]{64}$'
            }).Count -ne 0 -or
        ($Fields.generation -cne "-" -and $Fields.generation -notmatch '^[1-9][0-9]{0,9}$') -or
        $Fields.'clock-skew-bound-seconds' -cne "300" -or
        $Fields.'request-account-state' -cnotin @("absent", "disabled", "enabled") -or
        ($Fields.'request-account-state' -ceq "absent" -and
            ($Fields.'request-sid' -cne "-" -or $Fields.'request-principal' -cne "-")) -or
        ($Fields.'request-account-state' -cne "absent" -and
            ($Fields.'request-sid' -notmatch '^S-[0-9]+(?:-[0-9]+){1,14}$' -or
             $Fields.'request-principal' -cne "MachineUtilitiesRequest")) -or
        @($Fields.'system-task-ready', $Fields.'profile-task-ready', $Fields.'transport-ready',
            $Fields.'native-canary-ready' | Where-Object { $_ -cnotin @("true", "false") }).Count -ne 0) { return $null }
    if ($Fields.lifecycle -cin @("needs_native_canary", "needs_transport_enrollment", "ready") -and
        ($Fields.generation -ceq "-" -or @($Fields.'broker-sha256', $Fields.'generation-sha256',
            $Fields.'policy-sha256', $Fields.'constraints-sha256', $Fields.'winget-context-sha256' |
            Where-Object { $_ -ceq "-" }).Count -ne 0)) { return $null }
    if (($Fields.lifecycle -ceq "needs_native_canary" -and $Fields.'context-canary-sha256' -cne "-") -or
        ($Fields.lifecycle -cin @("needs_transport_enrollment", "ready") -and
            $Fields.'context-canary-sha256' -ceq "-")) { return $null }
    if (($Fields.lifecycle -cne "ready" -and $Fields.'request-account-state' -ceq "enabled") -or
        ($Fields.lifecycle -ceq "needs_transport_enrollment" -and
            ($Fields.'request-account-state' -cne "disabled" -or
             $Fields.'system-task-ready' -cne "true" -or $Fields.'profile-task-ready' -cne "true" -or
             $Fields.'native-canary-ready' -cne "true" -or $Fields.'transport-ready' -cne "false")) -or
        ($Fields.lifecycle -ceq "ready" -and
            ($Fields.'request-account-state' -cne "enabled" -or
             $Fields.'system-task-ready' -cne "true" -or $Fields.'profile-task-ready' -cne "true" -or
             $Fields.'native-canary-ready' -cne "true" -or $Fields.'transport-ready' -cne "true"))) { return $null }
    return [pscustomobject]$Fields
}

function Read-WindowsBrokerPublicResult([string]$Path) {
    if (-not (Test-WindowsPublicProjectionFile $Path)) { return $null }
    $Lines = Get-CanonicalAsciiLines $Path 4096
    $Names = @("state", "reason", "request-id", "plan-id", "action-id", "enrollment-epoch",
        "protected-result-sha256")
    if ($null -eq $Lines -or $Lines.Count -ne $Names.Count + 2 -or
        $Lines[0] -cne "windows-broker-public|1" -or $Lines[-1] -cne "end-public|") { return $null }
    $Fields = [ordered]@{}
    for ($Index = 0; $Index -lt $Names.Count; $Index++) {
        $Parts = $Lines[$Index + 1].Split('|')
        if ($Parts.Count -ne 2 -or $Parts[0] -cne $Names[$Index]) { return $null }
        $Fields[$Parts[0]] = $Parts[1]
    }
    if ($Fields.state -cnotmatch '^[a-z][a-z0-9_-]{0,31}$' -or
        $Fields.reason -cnotmatch '^[a-z][a-z0-9_]{0,127}$' -or
        $Fields.'request-id' -cnotmatch '^request-[0-9a-f]{32}$' -or
        $Fields.'plan-id' -cnotmatch '^plan-[0-9a-f]{16}$' -or
        $Fields.'action-id' -cnotin @("profile.apply-managed-bundle.v1", "profile.inventory-managed-state.v1",
            "winget.install-machine-package.v1", "winget.inventory-machine.v1", "winget.upgrade-machine-package.v1") -or
        $Fields.'enrollment-epoch' -notmatch '^[1-9][0-9]{0,9}$' -or
        ($Fields.state -cin @("completed", "partial", "rejected", "stale") -and
            $Fields.'protected-result-sha256' -cnotmatch '^[0-9a-f]{64}$') -or
        ($Fields.state -cnotin @("completed", "partial", "rejected", "stale") -and
            $Fields.'protected-result-sha256' -cne "-")) { return $null }
    return [pscustomobject]$Fields
}

function Test-WindowsIdentityFileAcl([string]$Path, [bool]$OwnerOnly) {
    if ($env:OS -ne "Windows_NT") { return $true }
    try {
        $Current = [Security.Principal.WindowsIdentity]::GetCurrent()
        $Acl = Get-Acl -LiteralPath $Path
        if ([string]$Acl.Owner -notin @([string]$Current.Name, [string]$Current.User.Value)) { return $false }
        foreach ($Rule in $Acl.Access) {
            if ($Rule.AccessControlType -ne "Allow") { continue }
            $Principal = [string]$Rule.IdentityReference
            $IsOwner = $Principal -in @([string]$Current.Name, [string]$Current.User.Value)
            $IsSystem = $Principal -match '(S-1-5-18|SYSTEM)$'
            if ($OwnerOnly -and -not $IsOwner -and -not $IsSystem) { return $false }
            if (-not $OwnerOnly -and -not $IsOwner -and -not $IsSystem -and
                ($Rule.FileSystemRights -band ([Security.AccessControl.FileSystemRights]::Write -bor
                    [Security.AccessControl.FileSystemRights]::Modify -bor
                    [Security.AccessControl.FileSystemRights]::FullControl)) -ne 0) { return $false }
        }
        return $true
    } catch { return $false }
}

function Test-WindowsControllerEnrollmentReceipt([object]$Receipt) {
    if ($null -eq $Receipt) { return $false }
    $Expected = @("broker_digest", "context_canary_digest", "enrollment_epoch", "policy_digest",
        "winget_context_digest")
    if ((@($Receipt.PSObject.Properties.Name | Sort-Object) -join "`n") -cne
        (@($Expected | Sort-Object) -join "`n")) { return $false }
    if ($Receipt.enrollment_epoch -is [string]) { return $false }
    [long]$Epoch = 0
    return [long]::TryParse([string]$Receipt.enrollment_epoch,
        [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$Epoch) -and
        $Epoch -ge 1 -and $Epoch -le [int]::MaxValue -and
        @([string]$Receipt.broker_digest, [string]$Receipt.context_canary_digest,
            [string]$Receipt.policy_digest, [string]$Receipt.winget_context_digest |
            Where-Object { $_ -cnotmatch '^[0-9a-f]{64}$' }).Count -eq 0
}

function Test-NodeIdentity([object]$Identity, [string]$IdentityPath, [object]$Route) {
    try {
        $ExpectedFields = @("ca_generation", "certificate_path", "certificate_principals", "certificate_serial",
            "certificate_source_addresses", "certificate_valid_after", "certificate_valid_before", "enrollment_receipts",
            "fleet_ca_fingerprint", "fleet_domain", "known_hosts_path", "node_id", "node_key_fingerprint",
            "private_key_path", "schema", "schema_version")
        if ((@($Identity.PSObject.Properties.Name | Sort-Object) -join "`n") -cne
            (@($ExpectedFields | Sort-Object) -join "`n") -or
            $Identity.schema -cne "roundhouse.node-identity" -or $Identity.schema_version -ne 1) { return $false }
        if ($null -eq $Identity.enrollment_receipts) { return $false }
        foreach ($ReceiptProperty in @($Identity.enrollment_receipts.PSObject.Properties)) {
            if ($ReceiptProperty.Name -notmatch '^[A-Za-z0-9._-]+$' -or
                -not (Test-WindowsControllerEnrollmentReceipt $ReceiptProperty.Value)) { return $false }
        }
        $Paths = @($IdentityPath, [string]$Identity.private_key_path, [string]$Identity.certificate_path,
            [string]$Identity.known_hosts_path)
        $RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../../.."))
        foreach ($Path in $Paths) {
            if (-not [IO.Path]::IsPathRooted($Path) -or $Path.StartsWith($RepositoryRoot, [StringComparison]::OrdinalIgnoreCase) -or
                $Path -match '[\\/](\.codex|\.claude)[\\/]plugins[\\/]cache[\\/]' -or
                $Path -match '[\\/](CloudStorage|Dropbox|OneDrive[^\\/]*)[\\/]') { return $false }
            $Item = Get-Item -LiteralPath $Path -Force
            if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        }
        if (-not (Test-WindowsIdentityFileAcl ([string]$Identity.private_key_path) $true) -or
            -not (Test-WindowsIdentityFileAcl ([string]$Identity.certificate_path) $false) -or
            -not (Test-WindowsIdentityFileAcl ([string]$Identity.known_hosts_path) $false) -or
            -not (Test-WindowsIdentityFileAcl $IdentityPath $false)) { return $false }
        $SshKeygen = if ($env:OS -eq "Windows_NT") {
            Join-Path $env:WINDIR "System32/OpenSSH/ssh-keygen.exe"
        } else { "/usr/bin/ssh-keygen" }
        if (-not (Test-Path -LiteralPath $SshKeygen -PathType Leaf)) { return $false }
        $TemporaryPublic = [IO.Path]::GetTempFileName()
        $TemporaryHostKeys = [IO.Path]::GetTempFileName()
        try {
            @(& $SshKeygen -y -f ([string]$Identity.private_key_path) 2>$null) | Set-Content -LiteralPath $TemporaryPublic -Encoding ascii
            if ($LASTEXITCODE -ne 0) { return $false }
            $PrivateFingerprintLine = @(& $SshKeygen -lf $TemporaryPublic -E sha256 2>$null)
            $CertificateFingerprintLine = @(& $SshKeygen -lf ([string]$Identity.certificate_path) -E sha256 2>$null)
            $CertificateDetails = @(& $SshKeygen -Lf ([string]$Identity.certificate_path) 2>$null)
            if ($null -eq $Route) {
                $KnownHosts = @(& $SshKeygen -lf ([string]$Identity.known_hosts_path) -E sha256 2>$null)
                if ($LASTEXITCODE -ne 0 -or $KnownHosts.Count -eq 0) { return $false }
            } else {
                $Lookup = "[" + [string]$Route.host + "]:" + [string]$Route.port
                $RouteKeys = @(& $SshKeygen -F $Lookup -f ([string]$Identity.known_hosts_path) 2>$null)
                if ($LASTEXITCODE -ne 0 -or $RouteKeys.Count -eq 0) { return $false }
                $RouteKeys | Set-Content -LiteralPath $TemporaryHostKeys -Encoding ascii
                $RouteFingerprints = @(& $SshKeygen -lf $TemporaryHostKeys -E sha256 2>$null)
                if ($LASTEXITCODE -ne 0) { return $false }
                $UniqueFingerprints = @($RouteFingerprints | ForEach-Object {
                    [regex]::Match($_, 'SHA256:[A-Za-z0-9+/]{43}=?').Value
                } | Where-Object { $_.Length -gt 0 } | Sort-Object -Unique)
                if ($UniqueFingerprints.Count -ne 1 -or
                    $UniqueFingerprints[0] -cne [string]$Route.pinned_host_key_fingerprint) { return $false }
            }
        } finally {
            Remove-Item -LiteralPath $TemporaryPublic -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $TemporaryHostKeys -Force -ErrorAction SilentlyContinue
        }
        $PrivateFingerprint = [regex]::Match(($PrivateFingerprintLine -join " "), 'SHA256:[A-Za-z0-9+/]{43}=?').Value
        $CertificateFingerprint = [regex]::Match(($CertificateFingerprintLine -join " "), 'SHA256:[A-Za-z0-9+/]{43}=?').Value
        $CaLine = @($CertificateDetails | Where-Object { $_ -match '^\s*Signing CA:' })[0]
        $CaFingerprint = [regex]::Match($CaLine, 'SHA256:[A-Za-z0-9+/]{43}=?').Value
        $KeyId = [regex]::Match((@($CertificateDetails | Where-Object { $_ -match '^\s*Key ID:' })[0]), '"([^"]+)"').Groups[1].Value
        $Serial = [regex]::Match((@($CertificateDetails | Where-Object { $_ -match '^\s*Serial:' })[0]), '[0-9]+$').Value
        $Valid = [regex]::Match((@($CertificateDetails | Where-Object { $_ -match '^\s*Valid: from ' })[0]),
            'from ([0-9T:-]+) to ([0-9T:-]+)')
        $Principals = New-Object Collections.Generic.List[string]
        $Sources = New-Object Collections.Generic.List[string]
        $Section = ""
        $ExtensionsCleared = $false
        foreach ($Line in $CertificateDetails) {
            if ($Line -match '^\s*Principals:') { $Section = "principals"; continue }
            if ($Line -match '^\s*Critical Options:') { $Section = "critical"; continue }
            if ($Line -match '^\s*Extensions:\s+\(none\)\s*$') { $ExtensionsCleared = $true; $Section = ""; continue }
            if ($Line -match '^\s*Extensions:') { return $false }
            $Trimmed = $Line.Trim()
            if ($Section -eq "principals" -and $Trimmed -ne "(none)") { [void]$Principals.Add($Trimmed) }
            elseif ($Section -eq "critical" -and $Trimmed -ne "(none)") {
                if ($Trimmed -notmatch '^source-address\s+(.+)$') { return $false }
                foreach ($Address in $Matches[1].Split(',')) { [void]$Sources.Add($Address) }
            }
        }
        $ExpectedPrincipals = @($Identity.certificate_principals | Sort-Object)
        $ExpectedSources = @($Identity.certificate_source_addresses | Sort-Object)
        $ExpectedAfterText = Limit-Text $Identity.certificate_valid_after
        $ExpectedBeforeText = Limit-Text $Identity.certificate_valid_before
        $ExpectedAfter = [DateTime]::ParseExact($ExpectedAfterText, "yyyy-MM-ddTHH:mm:ssZ",
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
        $ExpectedBefore = [DateTime]::ParseExact($ExpectedBeforeText, "yyyy-MM-ddTHH:mm:ssZ",
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
        return $ExtensionsCleared -and $PrivateFingerprint -ceq [string]$Identity.node_key_fingerprint -and
            $CertificateFingerprint -ceq [string]$Identity.node_key_fingerprint -and
            $CaFingerprint -ceq [string]$Identity.fleet_ca_fingerprint -and
            $KeyId -ceq (([string]$Identity.node_id) + "@" + ([string]$Identity.fleet_domain)) -and
            $Serial -ceq [string]$Identity.certificate_serial -and
            ($Valid.Groups[1].Value + "Z") -ceq $ExpectedAfterText -and
            ($Valid.Groups[2].Value + "Z") -ceq $ExpectedBeforeText -and
            $ExpectedAfter -le [DateTime]::UtcNow -and $ExpectedBefore -gt [DateTime]::UtcNow -and
            (@($Principals | Sort-Object) -join "`n") -ceq ($ExpectedPrincipals -join "`n") -and
            (@($Sources | Sort-Object) -join "`n") -ceq ($ExpectedSources -join "`n")
    } catch { return $false }
}

function Test-OriginatingNodeIdentity([object]$Identity) {
    if ($null -eq $Identity) { return $false }
    $ExpectedFields = @("ca_generation", "certificate_principals", "certificate_serial",
        "certificate_source_addresses", "certificate_valid_after", "certificate_valid_before",
        "fleet_ca_fingerprint", "fleet_domain", "node_id", "node_key_fingerprint", "schema", "schema_version")
    if ((@($Identity.PSObject.Properties.Name | Sort-Object) -join "`n") -cne
        (@($ExpectedFields | Sort-Object) -join "`n") -or
        $Identity.schema -cne "roundhouse.originating-node-identity" -or $Identity.schema_version -ne 1 -or
        [string]$Identity.node_id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or
        [string]$Identity.fleet_domain -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}[A-Za-z0-9]$' -or
        [string]$Identity.node_key_fingerprint -notmatch '^SHA256:[A-Za-z0-9+/]{43}=?$' -or
        [string]$Identity.fleet_ca_fingerprint -notmatch '^SHA256:[A-Za-z0-9+/]{43}=?$' -or
        [int64]$Identity.ca_generation -lt 1 -or [string]$Identity.certificate_serial -notmatch '^(0|[1-9][0-9]{0,19})$' -or
        @($Identity.certificate_principals).Count -lt 2 -or @($Identity.certificate_principals).Count -gt 16 -or
        @($Identity.certificate_source_addresses).Count -gt 16 -or
        @($Identity.certificate_principals) -notcontains (([string]$Identity.node_id) + "@" + ([string]$Identity.fleet_domain))) { return $false }
    try {
        $After = if ($Identity.certificate_valid_after -is [DateTime]) {
            $Identity.certificate_valid_after.ToUniversalTime()
        } else { [DateTime]::ParseExact([string]$Identity.certificate_valid_after, "yyyy-MM-ddTHH:mm:ssZ",
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal) }
        $Before = if ($Identity.certificate_valid_before -is [DateTime]) {
            $Identity.certificate_valid_before.ToUniversalTime()
        } else { [DateTime]::ParseExact([string]$Identity.certificate_valid_before, "yyyy-MM-ddTHH:mm:ssZ",
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal) }
        return $After -lt $Before -and $Before.ToUniversalTime() -gt [DateTime]::UtcNow
    } catch { return $false }
}

function Add-PrivilegeReadiness([object]$Value, [object]$ConfiguredMachine) {
    $DefaultPolicyPath = Join-Path $PSScriptRoot "../references/privilege-policy.default"
    $ProposalLines = if ($null -ne $ConfiguredMachine.privilege_broker.policy_proposal) {
        [string[]]@($ConfiguredMachine.privilege_broker.policy_proposal)
    } else {
        [string[]]@(Get-Content -LiteralPath $DefaultPolicyPath)
    }
    if (-not (Test-PrivilegePolicy $ProposalLines)) { throw "Invalid privilege policy proposal" }
    $ProposalDigest = if ($null -ne $Value.worker.policy_proposal_digest) {
        [string]$Value.worker.policy_proposal_digest
    } else {
        Get-TextSha256 (($ProposalLines -join "`n") + "`n")
    }
    $Route = $ConfiguredMachine.privilege_broker.automation_transport
    $Transport = if ($null -eq $Route) { $null } else { [string]$Route.mode }
    $RequestPrincipal = if ($null -eq $Route) { $null } else { [string]$Route.request_user }
    $PinnedHostKey = if ($null -eq $Route) { $null } else { [string]$Route.pinned_host_key_fingerprint }

    $IdentityPath = if (-not [string]::IsNullOrWhiteSpace($env:ROUNDHOUSE_IDENTITY)) {
        $env:ROUNDHOUSE_IDENTITY
    } elseif (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Join-Path $env:LOCALAPPDATA "MachineUtilities/identity.json"
    } else {
        Join-Path $HOME ".config/roundhouse/identity.json"
    }
    $NodeIdentityReady = $false
    $ReceiptPresent = $false
    $IdentityReceiptValid = $false
    $Identity = $null
    $Receipt = $null
    if (Test-Path -LiteralPath $IdentityPath -PathType Leaf) {
        try {
            $Identity = Get-Content -LiteralPath $IdentityPath -Raw | ConvertFrom-Json
            if (Test-NodeIdentity $Identity $IdentityPath $Route) {
                $NodeIdentityReady = $true
                $ReceiptProperties = @($Identity.enrollment_receipts.PSObject.Properties |
                    Where-Object { $_.Name -ceq $HostId })
                if ($ReceiptProperties.Count -gt 1) { throw "ambiguous controller enrollment receipt" }
                if ($ReceiptProperties.Count -eq 1) {
                    $ReceiptPresent = $true
                    $Receipt = $ReceiptProperties[0].Value
                    # This user-owned overlay is only an expectation. It never authorizes
                    # transport or substitutes for the protected local U6 projection.
                    $IdentityReceiptValid = Test-WindowsControllerEnrollmentReceipt $Receipt
                }
            }
        } catch { $Identity = $null }
    }
    $OriginatingIdentity = $Value.worker.originating_node_identity
    if ($null -eq $OriginatingIdentity -and $NodeIdentityReady) {
        $OriginatingIdentity = [ordered]@{
            schema = "roundhouse.originating-node-identity"; schema_version = 1
            fleet_domain = [string]$Identity.fleet_domain; node_id = [string]$Identity.node_id
            node_key_fingerprint = [string]$Identity.node_key_fingerprint
            fleet_ca_fingerprint = [string]$Identity.fleet_ca_fingerprint
            ca_generation = [int64]$Identity.ca_generation; certificate_serial = [string]$Identity.certificate_serial
            certificate_valid_after = Limit-Text $Identity.certificate_valid_after
            certificate_valid_before = Limit-Text $Identity.certificate_valid_before
            certificate_principals = @($Identity.certificate_principals)
            certificate_source_addresses = @($Identity.certificate_source_addresses)
        }
    }
    $ProgramDataRoot = if ([string]::IsNullOrWhiteSpace($env:ProgramData)) {
        Join-Path $HOME ".machine-utilities-programdata"
    } else { $env:ProgramData }
    $PublicRoot = Join-Path $ProgramDataRoot "MachineUtilities-Public"
    $ReadinessPath = Join-Path $PublicRoot "readiness"
    $PolicyPath = Join-Path $PublicRoot "policy.actions"
    $ConstraintsPath = Join-Path $PublicRoot "policy.constraints"
    $SftpPublicRoot = Join-Path $ProgramDataRoot "MachineUtilities-Sftp-Public"
    $SftpReadinessPath = Join-Path $SftpPublicRoot "readiness"
    $Readiness = Read-WindowsBrokerReadiness $ReadinessPath
    $ReadinessPresent = Test-Path -LiteralPath $ReadinessPath -PathType Leaf
    $SftpReadiness = Read-WindowsSftpProtectedReadiness $ProgramDataRoot
    $SftpReadinessPresent = Test-Path -LiteralPath $SftpReadinessPath -PathType Leaf
    $ProtectedArtifactsReady = $false
    $AdapterMechanismReady = $false
    $AdapterVerifierStatus = "not-installed"
    $BrokerVersion = $null
    $BrokerProtocol = $null
    $BrokerDigest = $null
    $PolicyDigest = $null
    $ConstraintsDigest = $null
    $WinGetContextDigest = $null
    $ConstraintGeneration = $null
    $ContextDigest = $null
    $ClockSkewBoundSeconds = 300
    $ObservedContexts = @()
    $RequestAccountState = "absent"
    $RequestSid = $null
    $ProtectedRequestPrincipal = $null
    $NativeCanaryReady = $false
    $SystemTaskReady = $false
    $ProfileTaskReady = $false
    if ($null -ne $Readiness) {
        $BrokerVersion = [string]$Readiness.'broker-version'
        $BrokerProtocol = [int]$Readiness.'broker-protocol'
        $BrokerDigest = if ($Readiness.'broker-sha256' -ceq "-") { $null } else { [string]$Readiness.'broker-sha256' }
        $PolicyDigest = if ($Readiness.'policy-sha256' -ceq "-") { $null } else { [string]$Readiness.'policy-sha256' }
        $ConstraintsDigest = if ($Readiness.'constraints-sha256' -ceq "-") { $null } else { [string]$Readiness.'constraints-sha256' }
        $WinGetContextDigest = if ($Readiness.'winget-context-sha256' -ceq "-") {
            $null
        } else { [string]$Readiness.'winget-context-sha256' }
        $ContextDigest = if ($Readiness.'context-canary-sha256' -ceq "-") { $null } else { [string]$Readiness.'context-canary-sha256' }
        $ClockSkewBoundSeconds = [int]$Readiness.'clock-skew-bound-seconds'
        $ConstraintGeneration = if ($Readiness.generation -ceq "-") { $null } else { [int64]$Readiness.generation }
        $RequestAccountState = [string]$Readiness.'request-account-state'
        $RequestSid = if ($Readiness.'request-sid' -ceq "-") { $null } else { [string]$Readiness.'request-sid' }
        $ProtectedRequestPrincipal = if ($Readiness.'request-principal' -ceq "-") {
            $null
        } else { [string]$Readiness.'request-principal' }
        $SystemTaskReady = $Readiness.'system-task-ready' -ceq "true"
        $ProfileTaskReady = $Readiness.'profile-task-ready' -ceq "true"
        $NativeCanaryReady = $Readiness.'native-canary-ready' -ceq "true"
        $AdapterMechanismReady = $SystemTaskReady -and $ProfileTaskReady
        $AdapterVerifierStatus = "public-projection-validated"
    }
    if ($null -ne $Readiness -and $null -ne $PolicyDigest -and $null -ne $ConstraintsDigest -and
        (Test-WindowsPublicProjectionFile $PolicyPath) -and
        (Test-WindowsPublicProjectionFile $ConstraintsPath)) {
        $PolicyLines = Get-CanonicalAsciiLines $PolicyPath 4096
        $ConstraintLines = Get-CanonicalAsciiLines $ConstraintsPath 32768
        $ObservedPolicyDigest = (Get-FileHash -LiteralPath $PolicyPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $ObservedConstraintsDigest = (Get-FileHash -LiteralPath $ConstraintsPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $Constraints = if ($ObservedPolicyDigest -ceq $PolicyDigest -and
            $ObservedConstraintsDigest -ceq $ConstraintsDigest -and
            $null -ne $PolicyLines -and (Test-PrivilegePolicy $PolicyLines)) {
            Test-PrivilegeConstraints $PolicyLines $ConstraintLines $ConstraintsDigest
        } else { $null }
        if ($null -ne $Constraints -and [int64]$Constraints.Generation -eq [int64]$ConstraintGeneration) {
            $ProtectedArtifactsReady = $true
            $ObservedContexts = @($PolicyLines | Select-Object -Skip 1 | ForEach-Object {
                $Fields = $_.Split('|')
                if ($Fields[3] -eq "enabled") {
                    [ordered]@{
                        action_id = $Fields[1]
                        context_id = $Fields[2]
                        constraint_kind = $Fields[4]
                        constraint_digest = $Fields[5]
                        manager_source_identity = $(if ($Fields[4] -eq "none") { "not-applicable" } else { $Fields[5] })
                        constraint_generation = [int64]$Constraints.Generation
                        policy_tokens = @($Constraints.Tokens[$Fields[1]])
                        profile_constraints = $(if ($Fields[1].StartsWith("profile.", [StringComparison]::Ordinal)) {
                            @($Constraints.Profiles)
                        } else { @() })
                    }
                }
            })
        }
    }

    $TransportObservation = Get-WindowsSftpProtectedObservation $ProgramDataRoot $ConfiguredMachine $Route `
        $Readiness $SftpReadiness
    $TransportObservationReady = $null -ne $TransportObservation
    if ($TransportObservationReady) {
        $AdapterVerifierStatus = "protected-local-observation"
        $RequestAccountState = "enabled"
        $RequestSid = [string]$TransportObservation.Candidate.'request-sid'
        $ProtectedRequestPrincipal = [string]$TransportObservation.Candidate.'request-account'
        if ($NodeIdentityReady) {
            $IdentityCaMatches = ([string]$Identity.fleet_ca_fingerprint -ceq
                    [string]$TransportObservation.Candidate.'primary-ca-fingerprint' -and
                [int64]$Identity.ca_generation -eq [int64]$TransportObservation.Candidate.'primary-ca-generation') -or
                ([string]$TransportObservation.Candidate.'previous-ca-fingerprint' -cne "-" -and
                 [string]$Identity.fleet_ca_fingerprint -ceq
                    [string]$TransportObservation.Candidate.'previous-ca-fingerprint' -and
                 [int64]$Identity.ca_generation -eq [int64]$TransportObservation.Candidate.'previous-ca-generation')
            if (-not $IdentityCaMatches) { $NodeIdentityReady = $false }
        }
    } elseif ($SftpReadinessPresent) {
        $AdapterVerifierStatus = "protected-local-observation-invalid"
    }
    $ControllerReceiptMatches = $TransportObservationReady -and $ProtectedArtifactsReady -and
        [int64]$TransportObservation.Candidate.'u3-epoch' -eq [int64]$ConstraintGeneration
    $IdentityReceiptExpectationMatches = $IdentityReceiptValid -and $ProtectedArtifactsReady -and
        [int64]$Receipt.enrollment_epoch -eq [int64]$ConstraintGeneration -and
        [string]$Receipt.broker_digest -ceq $BrokerDigest -and
        [string]$Receipt.policy_digest -ceq $PolicyDigest -and
        [string]$Receipt.winget_context_digest -ceq $WinGetContextDigest -and
        [string]$Receipt.context_canary_digest -ceq $ContextDigest

    $BrokerReady = $ProtectedArtifactsReady -and $NativeCanaryReady -and $AdapterMechanismReady
    $ActionContextReady = $BrokerReady -and $ObservedContexts.Count -gt 0
    $TransportReady = $ControllerReceiptMatches -and $null -ne $Route -and
        $RequestAccountState -ceq "enabled" -and
        -not [string]::IsNullOrWhiteSpace($RequestPrincipal) -and $RequestPrincipal -ceq $ProtectedRequestPrincipal
    $Lifecycle = if ($null -eq $Readiness) {
        if ($ReadinessPresent) { "drifted" } else { "needs_enrollment" }
    } elseif ($Readiness.lifecycle -ceq "needs_human_enrollment") { "needs_enrollment" }
    elseif ($Readiness.lifecycle -ceq "revoked") { "needs_enrollment" }
    elseif ($Readiness.lifecycle -ceq "recovery_required") { "recovery_required" }
    elseif ($Readiness.lifecycle -cin @("needs_transport_enrollment", "ready")) {
        if ($null -eq $SftpReadiness) {
            if ($SftpReadinessPresent) { "drifted" } else { "needs_transport_enrollment" }
        } elseif ($SftpReadiness.state -ceq "ready") {
            if ($TransportObservationReady) { "ready" } else { "drifted" }
        } elseif ($SftpReadiness.state -ceq "awaiting-controller-signature") { "needs_transport_enrollment" }
        elseif ($SftpReadiness.state -ceq "revoked") { "needs_enrollment" }
        else { [string]$SftpReadiness.state }
    }
    else { [string]$Readiness.lifecycle }
    if ($null -ne $Readiness -and $Lifecycle -notin @("needs_enrollment", "revoked") -and
        -not $ProtectedArtifactsReady) { $Lifecycle = "drifted" }
    if ($Lifecycle -ceq "ready" -and (-not $BrokerReady -or -not $TransportReady -or -not $ActionContextReady)) {
        $Lifecycle = "drifted"
    }
    $ActiveRequest = Read-WindowsBrokerPublicResult (Join-Path $PublicRoot "active")
    $LastTerminalResult = Read-WindowsBrokerPublicResult (Join-Path $PublicRoot "last")
    $ProposalStatus = if ($null -eq $PolicyDigest) { "unobserved" } elseif ($ProposalDigest -ceq $PolicyDigest) {
        "matches-observed"
    } else { "pending-human-enrollment" }
    $RecordStatus = if ($Lifecycle -eq "ready") { "present" } elseif (
        $Lifecycle -in @("drifted", "draining", "recovery_required")) { "partial" } else { "unavailable" }
    Add-Record -Kind "privilege_broker" -Id "readiness" -Status $RecordStatus -Confidence "high" -Data ([ordered]@{
        contract_version = 1
        platform_adapter = "windows-scheduled-task-v1"
        platform_boundary = "windows"
        lifecycle_status = $Lifecycle
        transport = $Transport
        transport_ready = $TransportReady
        node_identity_ready = $NodeIdentityReady
        broker_ready = $BrokerReady
        action_context_ready = $ActionContextReady
        protected_artifacts_ready = $ProtectedArtifactsReady
        adapter_mechanism_ready = $AdapterMechanismReady
        adapter_verifier_status = $AdapterVerifierStatus
        profile_runtime_context_evidence = @{
            authenticated_smb = "unavailable"
            interpretation = "ADMIN$/SAM denial and generic I/O failure are not isolation proof"
        }
        independent_native_canary = @{
            ready = ($NativeCanaryReady -and $TransportObservationReady)
            authority = $(if ($TransportObservationReady) { "protected-local-observation" } else { "unavailable" })
            portable_cryptographic_proof = $false
            public_u6_native_canary_details = "not-exposed"
            authenticated_smb_controlled_share = $(if ($NativeCanaryReady -and $TransportObservationReady) {
                "protected-readiness-observation"
            } else { "unavailable" })
            efs_capability_gate = $(if ($NativeCanaryReady -and $TransportObservationReady) {
                "protected-readiness-observation"
            } else { "unavailable" })
        }
        request_principal = $ProtectedRequestPrincipal
        request_account_state = $RequestAccountState
        protected_identity = @{ host_id = $HostId; sid = $RequestSid; request_principal = $ProtectedRequestPrincipal }
        execution_principals = @("LocalSystem", "enrolled-s4u-user")
        session_requirement = "no-console-session"
        broker_protocol = @{ supported = @(1, 0); observed = $BrokerProtocol }
        broker_version = $BrokerVersion
        broker_digest = $(if ($null -eq $BrokerDigest) { $null } else { @{ algorithm = "sha256"; value = $BrokerDigest } })
        policy = @{ catalog_version = 1; version = 1; action_manifest_version = 1 }
        policy_proposal_digest = @{ algorithm = "sha256"; value = $ProposalDigest }
        policy_proposal_status = $ProposalStatus
        observed_policy_digest = $(if ($null -eq $PolicyDigest) { $null } else { @{ algorithm = "sha256"; value = $PolicyDigest } })
        observed_constraints_digest = $(if ($null -eq $ConstraintsDigest) { $null } else { @{ algorithm = "sha256"; value = $ConstraintsDigest } })
        observed_winget_context_digest = $(if ($null -eq $WinGetContextDigest) { $null } else {
            @{ algorithm = "sha256"; value = $WinGetContextDigest }
        })
        constraint_generation = $ConstraintGeneration
        observed_action_contexts = $ObservedContexts
        context_canary_digest = $(if ($null -eq $ContextDigest) { $null } else { @{ algorithm = "sha256"; value = $ContextDigest } })
        node_identity = @{
            node_id = $(if ($NodeIdentityReady) { [string]$Identity.node_id } else { $null })
            fleet_domain = $(if ($NodeIdentityReady) { [string]$Identity.fleet_domain } else { $null })
            node_key_fingerprint = $(if ($NodeIdentityReady) { [string]$Identity.node_key_fingerprint } else { $null })
            fleet_ca_fingerprint = $(if ($NodeIdentityReady) { [string]$Identity.fleet_ca_fingerprint } else { $null })
            ca_generation = $(if ($NodeIdentityReady) { [int64]$Identity.ca_generation } else { $null })
            certificate_serial = $(if ($NodeIdentityReady) { [string]$Identity.certificate_serial } else { $null })
            certificate_valid_after = $(if ($NodeIdentityReady) { Limit-Text $Identity.certificate_valid_after } else { $null })
            certificate_valid_before = $(if ($NodeIdentityReady) { Limit-Text $Identity.certificate_valid_before } else { $null })
            certificate_principals = $(if ($NodeIdentityReady) { @($Identity.certificate_principals) } else { @() })
            certificate_source_addresses = $(if ($NodeIdentityReady) { @($Identity.certificate_source_addresses) } else { @() })
        }
        originating_node_identity = $OriginatingIdentity
        pinned_host_key_fingerprint = $PinnedHostKey
        transport_observation = $(if ($TransportObservationReady) { [ordered]@{
            authority = "protected-local-observation"
            portable_cryptographic_proof = $false
            candidate_digest = @{ algorithm = "sha256"; value = $TransportObservation.CandidateSha256 }
            controller_signing_thumbprint = [string]$TransportObservation.Candidate.'controller-signing-thumbprint'
            primary_ca_fingerprint = [string]$TransportObservation.Candidate.'primary-ca-fingerprint'
            primary_ca_generation = [int64]$TransportObservation.Candidate.'primary-ca-generation'
            previous_ca_fingerprint = $(if ($TransportObservation.Candidate.'previous-ca-fingerprint' -ceq "-") {
                $null
            } else { [string]$TransportObservation.Candidate.'previous-ca-fingerprint' })
            previous_ca_generation = [int64]$TransportObservation.Candidate.'previous-ca-generation'
            krl_generation = [int64]$TransportObservation.Candidate.'krl-generation'
            host_key_fingerprint = [string]$TransportObservation.Candidate.'host-key-fingerprint'
            issued_at = [DateTimeOffset]::FromUnixTimeSeconds($TransportObservation.IssuedAt).UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
            expires_at = [DateTimeOffset]::FromUnixTimeSeconds($TransportObservation.ExpiresAt).UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
            native_canary_details = "not-publicly-exposed"
            projection_binding = "controller-signed-candidate-plus-protected-local-readiness"
            protected_projection_digests = @{
                u3_active_pointer = @{ algorithm = "sha256"; value = $TransportObservation.Candidate.'u3-active-pointer-sha256' }
                u3_generation = @{ algorithm = "sha256"; value = $TransportObservation.Candidate.'u3-generation-sha256' }
                u3_system_task = @{ algorithm = "sha256"; value = $TransportObservation.Candidate.'u3-task-sha256' }
                u3_broker = @{ algorithm = "sha256"; value = $TransportObservation.Candidate.'u3-broker-sha256' }
                chroot_contract = @{ algorithm = "sha256"; value = $TransportObservation.Candidate.'chroot-contract-sha256' }
                slot_acl_contract = @{ algorithm = "sha256"; value = $TransportObservation.Candidate.'slot-acl-sha256' }
                results_acl_contract = @{ algorithm = "sha256"; value = $TransportObservation.Candidate.'results-acl-sha256' }
                quota_contract = @{ algorithm = "sha256"; value = $TransportObservation.Candidate.'quota-contract-sha256' }
                openssh_contract = @{ algorithm = "sha256"; value = $TransportObservation.Candidate.'openssh-contract-sha256' }
                sshd_configuration = @{ algorithm = "sha256"; value = $TransportObservation.Candidate.'configuration-sha256' }
                firewall_contract = @{ algorithm = "sha256"; value = $TransportObservation.Candidate.'firewall-contract-sha256' }
            }
        } } else { $null })
        identity_receipt_expectation = @{
            present = $ReceiptPresent
            valid_shape = $IdentityReceiptValid
            matches_observed_u3 = $IdentityReceiptExpectationMatches
            authority = "user-owned-expectation-only"
        }
        enrollment_epoch = $(if ($TransportObservationReady) {
            [int64]$TransportObservation.Candidate.'u3-epoch'
        } else { $null })
        active_request = $ActiveRequest
        last_terminal_result = $LastTerminalResult
        request_ttl = @{ poll_interval_seconds = 60; clock_skew_bound_seconds = $ClockSkewBoundSeconds
            minimum_seconds = (120 + $ClockSkewBoundSeconds); maximum_seconds = 3600 }
    }) -Evidence @(@{ source = "protected-state"; method = $(if ($TransportObservationReady) {
        "protected-local-observation"
    } else { "read-only-contract-inventory" }) })
}

function Get-NullableBoolean([object]$Value, [object]$Default = $null) {
    if ($Value -is [bool]) { return $Value }
    return $Default
}

function Test-JsmVersion([object]$Value) {
    return $null -eq $Value -or $Value -is [string] -or
        $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]
}

function Test-ManagerEntityName([object]$Value, [string]$Manager) {
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $false }
    $Pattern = if ($Manager -eq "skills-cli") {
        "^[A-Za-z0-9@._/][A-Za-z0-9@._/-]*$"
    } else {
        "^[A-Za-z0-9._/][A-Za-z0-9._/-]*$"
    }
    return [string]$Value -match $Pattern
}

function Test-JsmSkill([object]$Skill) {
    if ($null -eq $Skill -or -not (Test-ManagerEntityName $Skill.name "jsm")) { return $false }
    if (-not (Test-JsmVersion $Skill.version) -or -not (Test-JsmVersion $Skill.latest_version)) { return $false }
    foreach ($Field in @("installed_at")) {
        if ($null -ne $Skill.$Field -and $Skill.$Field -isnot [string]) { return $false }
    }
    foreach ($Field in @("pinned", "update_available", "is_saved", "is_jeffreys")) {
        if ($null -ne $Skill.$Field -and $Skill.$Field -isnot [bool]) { return $false }
    }
    if ($null -ne $Skill.tags -and ($Skill.tags -is [string] -or $Skill.tags -isnot [Collections.IEnumerable])) { return $false }
    if (@($Skill.tags).Count -gt 128) { return $false }
    foreach ($Tag in @($Skill.tags)) {
        if ($Tag -isnot [string] -and $Tag -isnot [ValueType]) { return $false }
    }
    return $true
}

function Get-DirectoryDigest([string]$Path) {
    [string[]]$Lines = foreach ($File in @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction Stop |
        Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' })) {
        $Relative = $File.FullName.Substring($Path.TrimEnd("\", "/").Length).TrimStart("\", "/").Replace("\", "/")
        $Hash = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$Relative`t$Hash"
    }
    if ($null -eq $Lines) { $Lines = @() }
    if ($Lines.Count -gt 1) { [Array]::Sort($Lines, [StringComparer]::Ordinal) }
    return Get-TextSha256 (($Lines -join "`n") + "`n")
}

function Get-AuthHealth([object]$Definition) {
    $Verify = @($Definition.verify)
    if ($Verify.Count -eq 0) { return @{ health = "not-configured"; verify_exit_code = $null } }
    if (-not $AllowAuthVerify) { return @{ health = "not-authorized"; verify_exit_code = $null } }
    if ($Verify.Count -gt 32 -or [string]$Verify[0] -notmatch '^[A-Za-z0-9._+-]+$') {
        return @{ health = "invalid-config"; verify_exit_code = $null }
    }
    if ($null -eq (Get-Command ([string]$Verify[0]) -ErrorAction SilentlyContinue)) {
        return @{ health = "unavailable"; verify_exit_code = $null }
    }
    $Job = Start-Job -ScriptBlock {
        param([string[]]$Argv)
        & $Argv[0] @($Argv | Select-Object -Skip 1) *> $null
        $Succeeded = $?
        if ($null -ne $LASTEXITCODE) { return [int]$LASTEXITCODE }
        if ($Succeeded) { return 0 }
        return 1
    } -ArgumentList (, [string[]]$Verify)
    try {
        if ($null -eq (Wait-Job -Job $Job -Timeout 10)) {
            Stop-Job -Job $Job -ErrorAction SilentlyContinue
            return @{ health = "timeout"; verify_exit_code = 124 }
        }
        if ($Job.State -ne "Completed" -or @($Job.ChildJobs | ForEach-Object { $_.Error }).Count -gt 0) {
            return @{ health = "error"; verify_exit_code = $null }
        }
        $JobOutput = @(Receive-Job -Job $Job -ErrorAction SilentlyContinue)
        [int]$ExitCode = 0
        if ($JobOutput.Count -ne 1 -or
            -not [int]::TryParse([string]$JobOutput[0], [ref]$ExitCode)) {
            return @{ health = "error"; verify_exit_code = $null }
        }
        return @{ health = $(if ($ExitCode -eq 0) { "healthy" } else { "unhealthy" }); verify_exit_code = $ExitCode }
    } finally {
        Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
    }
}

function Test-AgentSettingValue([string]$Key, [object]$Value) {
    if ($null -eq $Value) { return $false }
    if ($Key -cin @("remoteControlAtStartup", "switchModelsOnFlag", "agentPushNotifEnabled",
            "check_for_update_on_startup")) { return $Value -is [bool] }
    if ($Key -ceq "availableModels") {
        return $Value -isnot [string] -and $Value -is [Collections.IEnumerable] -and
            @($Value | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -eq 0
    }
    if ($Key -ceq "autoUpdatesChannel") { return [string]$Value -cin @("latest", "stable") }
    if ($Key -ceq "cli_auth_credentials_store") { return [string]$Value -cin @("file", "keyring", "auto") }
    return $Value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$Value)
}

function Add-AgentSettings(
    [object]$Definition,
    [string]$ArtifactId,
    [string]$ArtifactPath,
    [switch]$UnknownPath,
    [switch]$LinkedPath,
    [switch]$UnavailablePath
) {
    $Format = [string]$Definition.format
    $ArtifactExists = -not $UnknownPath -and -not $LinkedPath -and -not $UnavailablePath -and
        (Test-Path -LiteralPath $ArtifactPath)
    $ArtifactIsFile = -not $UnknownPath -and -not $LinkedPath -and -not $UnavailablePath -and
        (Test-Path -LiteralPath $ArtifactPath -PathType Leaf)
    $Parsed = $null
    if ($Format -eq "json" -and $ArtifactIsFile) {
        try { $Parsed = Get-Content -LiteralPath $ArtifactPath -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate } catch { $Parsed = $null }
        if ($null -eq $Parsed -or $Parsed -isnot [Collections.IDictionary]) {
            $Parsed = $null
        }
    }
    foreach ($Setting in $Definition.settings.PSObject.Properties) {
        $Key = [string]$Setting.Name
        $Desired = $Setting.Value
        $Present = $false
        $Observed = $null
        $ParseFailed = $UnknownPath -or $LinkedPath -or $UnavailablePath -or
            ($ArtifactExists -and -not $ArtifactIsFile)
        if ($Format -eq "json") {
            if (-not $ArtifactExists) {
                # An absent artifact means every configured setting is absent, not unparseable.
            } elseif ($null -eq $Parsed) {
                $ParseFailed = $true
            } else {
                if ($Parsed.Contains($Key)) {
                    $Present = $true
                    $Observed = $Parsed[$Key]
                }
            }
        } elseif ($Format -eq "toml") {
            $Escaped = [Regex]::Escape($Key)
            $KeyPattern = '(?:{0}|"{0}"|''{0}'')' -f $Escaped
            $Line = $null
            $LineIndex = -1
            $ConfigLines = @(
                if ($ArtifactIsFile) { [IO.File]::ReadAllLines($ArtifactPath) }
            )
            for ($Index = 0; $Index -lt $ConfigLines.Count; $Index++) {
                $ConfigLine = $ConfigLines[$Index]
                if ($ConfigLine -match '^\s*\[') { break }
                if ($ConfigLine -cmatch "^\s*$KeyPattern\s*=") {
                    $Line = $ConfigLine
                    $LineIndex = $Index
                    break
                }
            }
            if ($null -ne $Line) {
                $Raw = $Line -creplace "^\s*$KeyPattern\s*=\s*", ""
                $TripleDelimiter = if ($Raw.StartsWith('"""', [StringComparison]::Ordinal)) {
                    '"""'
                } elseif ($Raw.StartsWith("'''", [StringComparison]::Ordinal)) {
                    "'''"
                } else {
                    $null
                }
                if ($null -ne $TripleDelimiter) {
                    $TripleValue = $Raw.Substring(3)
                    if ($TripleValue.Length -eq 0 -and $LineIndex + 1 -lt $ConfigLines.Count) {
                        $TripleValue = $ConfigLines[$LineIndex + 1]
                    }
                    $CloseIndex = $TripleValue.IndexOf($TripleDelimiter, [StringComparison]::Ordinal)
                    if ($CloseIndex -lt 0 -or
                        $TripleValue.Substring($CloseIndex + 3) -cnotmatch '^\s*(?:#.*)?$') {
                        $ParseFailed = $true
                    } else {
                        $TripleValue = $TripleValue.Substring(0, $CloseIndex)
                        if ($TripleDelimiter -ceq '"""') {
                            try {
                                $Observed = ConvertFrom-Json -InputObject ('"' + $TripleValue + '"')
                                $Present = $true
                            } catch {
                                $ParseFailed = $true
                            }
                        } else {
                            $Observed = $TripleValue
                            $Present = $true
                        }
                    }
                } elseif ($Raw -match "^\s*'([^']*)'\s*(?:#.*)?$") {
                    $Observed = $Matches[1]
                    $Present = $true
                } elseif ($Raw -match '^\s*(?<value>"(?:[^"\\]|\\.)*")\s*(?:#.*)?$') {
                    try { $Observed = $Matches.value | ConvertFrom-Json; $Present = $true } catch { $ParseFailed = $true }
                } elseif ($Raw -cmatch '^\s*(?<value>true|false)\s*(?:#.*)?$') {
                    $Observed = $Matches.value -ceq "true"
                    $Present = $true
                } else {
                    $ParseFailed = $true
                }
            }
        }
        $SettingValueValid = $null -eq $Observed -and $null -eq $Desired
        if ($null -ne $Observed) { $SettingValueValid = Test-AgentSettingValue $Key $Observed }
        if ($Present -and
            (-not $SettingValueValid -or -not (Test-BoundedSemanticValue $Observed))) {
            $ParseFailed = $true
            $Observed = $null
        }
        if ($ParseFailed) {
            $SettingPath = if ($UnknownPath) { $null } else { Limit-Text $ArtifactPath }
            $Error = if ($UnknownPath) {
                @{ code = "artifact_path_missing"; severity = "warning"; retryable = $false; message = "agent setting artifact has no path for this host" }
            } elseif ($LinkedPath) {
                @{ code = "symlink_not_followed"; severity = "warning"; retryable = $false; message = "agent setting artifact path is a link" }
            } elseif ($UnavailablePath) {
                @{ code = "artifact_path_unavailable"; severity = "warning"; retryable = $true; message = "agent setting artifact path could not be inspected" }
            } else {
                @{ code = "setting_parse_failed"; severity = "warning"; retryable = $false; message = "allowlisted agent setting could not be parsed" }
            }
            Add-Record -Kind "agent_setting" -Id "$ArtifactId`:$Key" -Status "unavailable" -Confidence "medium" -Data @{
                artifact = $ArtifactId; path = $SettingPath; format = $Format; key = $Key
                desired = $Desired; agent_exposure = @($Definition.agents)
            } -Errors @($Error)
            continue
        }
        $ObservedJson = ConvertTo-Json $Observed -Compress -Depth 20
        $DesiredJson = ConvertTo-Json $Desired -Compress -Depth 20
        $InSync = if ($null -eq $Desired) { -not $Present } else { $Present -and $ObservedJson -ceq $DesiredJson }
        Add-Record -Kind "agent_setting" -Id "$ArtifactId`:$Key" -Status "present" -Confidence "high" -Data @{
            artifact = $ArtifactId; path = Limit-Text $ArtifactPath; format = $Format; key = $Key
            observed_present = $Present; observed = $Observed; desired = $Desired; in_sync = $InSync
            agent_exposure = @($Definition.agents)
        } -Evidence @(@{ source = "filesystem"; method = "allowlisted-semantic-setting" })
    }
}

function Test-BoundedStrings([object]$Value) {
    if ($null -eq $Value) { return $true }
    if ($Value -is [string]) {
        return $Value.Length -le 8192 -and $Value -notmatch "[\x00-\x1f\x7f-\x9f]"
    }
    if ($Value -is [ValueType]) { return $true }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($Key in $Value.Keys) {
            if (-not (Test-BoundedStrings $Key) -or -not (Test-BoundedStrings $Value[$Key])) { return $false }
        }
        return $true
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($Item in $Value) {
            if (-not (Test-BoundedStrings $Item)) { return $false }
        }
        return $true
    }
    if ($Value.PSObject -and $Value.PSObject.Properties) {
        foreach ($Property in $Value.PSObject.Properties) {
            if (-not (Test-BoundedStrings $Property.Name) -or -not (Test-BoundedStrings $Property.Value)) { return $false }
        }
    }
    return $true
}

function Test-BoundedSemanticValue([object]$Value) {
    if (-not (Test-BoundedStrings $Value)) { return $false }
    try {
        $Json = ConvertTo-Json $Value -Compress -Depth 20
        return [Text.Encoding]::UTF8.GetByteCount($Json) -le 8192
    } catch {
        return $false
    }
}

function Get-ExactPropertyValue([object]$Value, [string]$Name) {
    if ($null -eq $Value) { return $null }
    $Property = $Value.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
    if ($null -eq $Property) { return $null }
    return $Property.Value
}

function Test-ExactMember([object[]]$Values, [object]$Value) {
    return @($Values | Where-Object { [string]$_ -ceq [string]$Value }).Count -gt 0
}

function Get-ConfiguredPath([object]$Definition, [string]$ConfiguredHostId) {
    $HostPath = Get-ExactPropertyValue $Definition.paths $ConfiguredHostId
    if ($null -ne $HostPath) { return [string]$HostPath }
    return [string]$Definition.path
}

function Assert-WorkerConfig([object]$Value) {
    $ConfiguredMachine = Get-ExactPropertyValue $Value.machines $HostId
    if ($HostId -notmatch '^[A-Za-z0-9._-]+$' -or $Value.version -ne 1 -or $null -eq $ConfiguredMachine) {
        throw "Invalid version 1 configuration or unknown host"
    }
    if (-not (Test-BoundedStrings $Value)) { throw "Configuration contains an oversized or control string" }
    if ($null -eq $Value.worker -or
        [string]$Value.worker.target -cne $HostId -or
        [string]$Value.worker.controller_configuration_digest -ne $ControllerConfigDigest.ToLowerInvariant()) {
        throw "Worker configuration is not bound to this controller and target"
    }
    if ($Value.worker.node_identity_projected -eq $true -or
        ($null -ne $Value.worker.policy_proposal_digest -and
         [string]$Value.worker.policy_proposal_digest -notmatch '^[0-9a-f]{64}$')) {
        throw "Worker configuration projects invalid privilege metadata"
    }
    if ($null -ne $Value.worker.originating_node_identity -and
        -not (Test-OriginatingNodeIdentity $Value.worker.originating_node_identity)) {
        throw "Worker configuration contains invalid originating node metadata"
    }
    if ($ConfiguredMachine.platform -ne "windows" -or
        $ConfiguredMachine.transport -ne "codex-remote-control" -or
        [string]::IsNullOrWhiteSpace([string]$ConfiguredMachine.codex_host)) {
        throw "Windows worker requires direct codex-remote-control transport"
    }
    if ([string]$ConfiguredMachine.expected_hostname -notmatch "^[A-Za-z0-9._-]+$" -or
        [string]$ConfiguredMachine.expected_user -notmatch "^[A-Za-z0-9._@-]+$") {
        throw "Windows worker requires expected_hostname and expected_user"
    }
    if ([string]$env:COMPUTERNAME -ine [string]$ConfiguredMachine.expected_hostname -or
        [string][Environment]::UserName -ine [string]$ConfiguredMachine.expected_user) {
        throw "Windows target hostname or user does not match configuration"
    }
    if (@($ConfiguredMachine.groups | Where-Object { $_ -notmatch '^[A-Za-z0-9._-]+$' }).Count -gt 0) {
        throw "Invalid machine group"
    }
    if (@($ConfiguredMachine.package_managers | Where-Object { $_ -ne "winget" }).Count -gt 0) {
        throw "Invalid Windows package manager"
    }
    if ($null -ne $ConfiguredMachine.privilege_broker) {
        $UnknownBrokerFields = @($ConfiguredMachine.privilege_broker.PSObject.Properties.Name |
            Where-Object { $_ -notin @("automation_transport", "policy_proposal") })
        if ($UnknownBrokerFields.Count -gt 0) { throw "Invalid privilege broker configuration" }
        if ($null -ne $ConfiguredMachine.privilege_broker.policy_proposal -and
            -not (Test-PrivilegePolicy ([string[]]@($ConfiguredMachine.privilege_broker.policy_proposal)))) {
            throw "Invalid privilege policy proposal"
        }
        $Route = $ConfiguredMachine.privilege_broker.automation_transport
        if ($null -ne $Route) {
            if (-not (Test-OriginatingNodeIdentity $Value.worker.originating_node_identity)) {
                throw "Broker-routed worker requires originating node metadata"
            }
            $RouteFields = @($Route.PSObject.Properties.Name)
            if (@($RouteFields | Where-Object { $_ -notin @("host", "management_networks", "mode", "pinned_host_key_fingerprint", "port", "request_user") }).Count -gt 0 -or
                $RouteFields.Count -ne 6 -or [string]$Route.mode -ne "windows-sftp" -or
                [string]$Route.host -notmatch '^[A-Za-z0-9][A-Za-z0-9.:-]{0,254}$' -or
                [int64]$Route.port -ne 22 -or [string]$Route.request_user -cne "MachineUtilitiesRequest" -or
                [string]$Route.pinned_host_key_fingerprint -notmatch '^SHA256:[A-Za-z0-9+/]{43}=?$' -or
                @($Route.management_networks).Count -lt 1 -or @($Route.management_networks).Count -gt 32) {
                throw "Invalid Windows automation transport"
            }
        }
    }
    if ($null -ne $Value.projects) {
        foreach ($Property in $Value.projects.PSObject.Properties) {
            $Definition = $Property.Value
            $Path = [string]$Definition.path
            if ($Property.Name -notmatch '^[A-Za-z0-9._-]+$' -or
                [string]::IsNullOrWhiteSpace([string]$Definition.source) -or
                [string]$Definition.source -match '\?' -or
                [string]$Definition.source -match '^[A-Za-z][A-Za-z0-9+.-]*://(?!git@)[^/@]+@' -or
                [string]::IsNullOrWhiteSpace($Path) -or
                [IO.Path]::IsPathRooted($Path) -or $Path.Contains("\") -or
                $Path -match '(^|/)\.\.(/|$)') {
                throw "Invalid project configuration"
            }
        }
    }
    if ($null -ne $Value.capabilities) {
        foreach ($Property in $Value.capabilities.PSObject.Properties) {
            if ($Property.Name -notmatch '^[A-Za-z0-9._][A-Za-z0-9._-]*$') { throw "Invalid capability configuration" }
            $Definitions = @()
            $AgentsProperty = $Property.Value.PSObject.Properties |
                Where-Object { $_.Name -ceq "agents" } | Select-Object -First 1
            if ($null -ne $AgentsProperty) {
                $SharedAgents = @($AgentsProperty.Value)
                if ($SharedAgents.Count -eq 0 -or
                    @($SharedAgents | Sort-Object -Unique).Count -ne $SharedAgents.Count -or
                    @($SharedAgents | Where-Object { $_ -cnotin @("codex", "claude") }).Count -gt 0 -or
                    $null -ne (Get-ExactPropertyValue $Property.Value "codex") -or
                    $null -ne (Get-ExactPropertyValue $Property.Value "claude")) {
                    throw "Invalid shared capability agents"
                }
                $Definitions = @($Property.Value)
            } else {
                foreach ($Agent in @("codex", "claude")) {
                    $Definition = Get-ExactPropertyValue $Property.Value $Agent
                    if ($null -ne $Definition) { $Definitions += $Definition }
                }
            }
            foreach ($Definition in $Definitions) {
                if (@("plugin", "skills-cli", "jsm", "manual", "plugin-source") -notcontains [string]$Definition.provider -or
                    [string]::IsNullOrWhiteSpace([string]$Definition.source) -or
                    [string]$Definition.source -match '\?' -or
                    [string]$Definition.source -match '^[A-Za-z][A-Za-z0-9+.-]*://(?!git@)[^/@]+@' -or
                    ($null -ne $Definition.skill -and [string]$Definition.skill -notmatch '^[A-Za-z0-9._][A-Za-z0-9._-]*$') -or
                    ($null -ne $Definition.name -and [string]$Definition.name -notmatch '^[A-Za-z0-9._][A-Za-z0-9._-]*$')) {
                    throw "Invalid capability provider configuration"
                }
                if ([string]$Definition.provider -eq "plugin" -and
                    ([string]$Definition.source -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or
                     [string]$Definition.source -in @(".", ".."))) {
                    throw "Invalid plugin capability source"
                }
            }
            if ($Definitions.Count -eq 0) { throw "Capability has no provider" }
        }
    }
    if ($null -ne $Value.skill_roots) {
        if (@($Value.skill_roots | ForEach-Object { $_.id } | Sort-Object -Unique).Count -ne @($Value.skill_roots).Count) {
            throw "Duplicate skill root ID"
        }
        foreach ($Definition in @($Value.skill_roots)) {
            $Manager = if ($null -eq $Definition.manager) { "manual" } else { [string]$Definition.manager }
            if ([string]$Definition.id -notmatch '^[A-Za-z0-9._-]+$' -or
                [string]::IsNullOrWhiteSpace([string]$Definition.path) -or
                @("manual", "mixed", "skills-cli", "jsm", "plugin-source") -notcontains $Manager -or
                @($Definition.agents | Where-Object { $_ -notin @("codex", "claude") }).Count -gt 0) {
                throw "Invalid skill root configuration"
            }
        }
    }
    if ($null -ne $Value.agent_artifacts) {
        if (@($Value.agent_artifacts | ForEach-Object { $_.id } | Sort-Object -Unique).Count -ne @($Value.agent_artifacts).Count) {
            throw "Duplicate agent artifact ID"
        }
        foreach ($Definition in @($Value.agent_artifacts)) {
            $SettingKeys = if ($null -eq $Definition.settings) { @() } else {
                @($Definition.settings.PSObject.Properties | ForEach-Object { $_.Name })
            }
            $AllowedJsonSettings = @("remoteControlAtStartup", "switchModelsOnFlag", "model", "effortLevel",
                "availableModels", "fallbackModel", "autoUpdatesChannel", "agentPushNotifEnabled")
            $AllowedTomlSettings = @("model", "model_reasoning_effort", "service_tier",
                "check_for_update_on_startup", "cli_auth_credentials_store")
            $InvalidSettingValue = $false
            $SettingProperties = if ($null -eq $Definition.settings) { @() } else {
                @($Definition.settings.PSObject.Properties)
            }
            foreach ($Setting in $SettingProperties) {
                if ($null -eq $Setting.Value) { continue }
                if ($Setting.Name -cin @("remoteControlAtStartup", "switchModelsOnFlag",
                        "agentPushNotifEnabled", "check_for_update_on_startup")) {
                    $InvalidSettingValue = $Setting.Value -isnot [bool]
                } elseif ($Setting.Name -ceq "availableModels") {
                    $InvalidSettingValue = $Setting.Value -is [string] -or
                        $Setting.Value -isnot [Collections.IEnumerable] -or
                        @($Setting.Value | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
                } elseif ($Setting.Name -ceq "autoUpdatesChannel") {
                    $InvalidSettingValue = [string]$Setting.Value -cnotin @("latest", "stable")
                } elseif ($Setting.Name -ceq "cli_auth_credentials_store") {
                    $InvalidSettingValue = [string]$Setting.Value -cnotin @("file", "keyring", "auto")
                } else {
                    $InvalidSettingValue = $Setting.Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Setting.Value)
                }
                if (-not $InvalidSettingValue -and -not (Test-BoundedSemanticValue $Setting.Value)) {
                    $InvalidSettingValue = $true
                }
                if ($InvalidSettingValue) { break }
            }
            if ([string]$Definition.id -notmatch '^[A-Za-z0-9._-]+$' -or
                @("agent-definition", "instruction", "config") -notcontains [string]$Definition.kind -or
                @($Definition.agents | Where-Object { $_ -notin @("codex", "claude") }).Count -gt 0 -or
                ($SettingKeys.Count -gt 0 -and ([string]$Definition.kind -ne "config" -or
                    [string]$Definition.format -notin @("json", "toml"))) -or
                ($SettingKeys.Count -gt 0 -and
                    (([string]$Definition.format -eq "json" -and
                      (@($Definition.agents).Count -ne 1 -or ([string](@($Definition.agents)[0])) -cne "claude")) -or
                     ([string]$Definition.format -eq "toml" -and
                      (@($Definition.agents).Count -ne 1 -or ([string](@($Definition.agents)[0])) -cne "codex")))) -or
                ([string]$Definition.format -eq "json" -and
                    @($SettingKeys | Where-Object { $_ -cnotin $AllowedJsonSettings }).Count -gt 0) -or
                ([string]$Definition.format -eq "toml" -and
                    @($SettingKeys | Where-Object { $_ -cnotin $AllowedTomlSettings }).Count -gt 0) -or
                $InvalidSettingValue) {
                throw "Invalid agent artifact configuration"
            }
        }
    }
    if ($null -ne $Value.auth_artifacts) {
        foreach ($Property in $Value.auth_artifacts.PSObject.Properties) {
            $Verify = @($Property.Value.verify)
            $ReauthValue = $Property.Value.reauth
            $Reauth = if ($null -eq $ReauthValue) { @() } else { @($ReauthValue) }
            $Strategy = if ($null -eq $Property.Value.strategy) { "ignore" } else { [string]$Property.Value.strategy }
            $Portability = if ($null -eq $Property.Value.portability) { "per-machine" } else { [string]$Property.Value.portability }
            $HasPath = -not [string]::IsNullOrWhiteSpace([string]$Property.Value.path) -or
                ($null -ne $Property.Value.paths -and $Property.Value.paths.PSObject.Properties.Count -gt 0) -or
                ($Portability -in @("native-store", "per-machine") -and $Verify.Count -gt 0)
            $PathlessAuthStatus = $Portability -in @("native-store", "per-machine") -and
                [string]::IsNullOrWhiteSpace([string]$Property.Value.path) -and
                ($null -eq $Property.Value.paths -or $Property.Value.paths.PSObject.Properties.Count -eq 0)
            if ($Property.Name -notmatch '^[A-Za-z0-9._-]+$' -or
                -not $HasPath -or
                @("chezmoi", "encrypted-install", "reauth", "ignore") -notcontains $Strategy -or
                @("declarative", "secret-reference", "portable-session", "native-store", "per-machine", "regenerable-cache") -notcontains $Portability -or
                $Verify.Count -gt 32 -or
                ($null -ne $ReauthValue -and $ReauthValue -isnot [Collections.IList]) -or
                $Reauth.Count -gt 32 -or
                ($Strategy -eq "reauth" -and $Reauth.Count -eq 0) -or
                ($Reauth.Count -gt 0 -and
                    ([string]$Reauth[0] -notmatch '^[A-Za-z0-9._+-]+$' -or
                     @($Reauth | Where-Object { $_ -isnot [string] -or [string]::IsNullOrEmpty($_) }).Count -gt 0)) -or
                ($PathlessAuthStatus -and $Strategy -notin @("reauth", "ignore")) -or
                ($PathlessAuthStatus -and $Verify.Count -eq 0) -or
                ($Verify.Count -gt 0 -and [string]$Verify[0] -notmatch '^[A-Za-z0-9._+-]+$')) {
                throw "Invalid auth artifact configuration"
            }
        }
    }
}

function Invoke-WindowsSftpReceiptSelfTest {
    Add-Type -AssemblyName System.Security.Cryptography.Pkcs -ErrorAction SilentlyContinue
    $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $IssuedAt = $Now - 60
    $ExpiresAt = $Now + 600
    $Key = [Security.Cryptography.RSA]::Create(2048)
    $Certificate = $null
    $HistoricalKey = $null
    $HistoricalCertificate = $null
    $SecondKey = $null
    $SecondCertificate = $null
    try {
        $Request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
            "CN=machine-utilities-controller", $Key, [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $Certificate = $Request.CreateSelfSigned(
            [DateTimeOffset]::FromUnixTimeSeconds($IssuedAt - 60),
            [DateTimeOffset]::FromUnixTimeSeconds($ExpiresAt + 60))
        $Thumbprint = $Certificate.Thumbprint.ToUpperInvariant()
        $DigestA = "a" * 64; $DigestB = "b" * 64; $Fingerprint = "SHA256:" + ("A" * 43)
        [string[]]$CandidateLines = @(
            "windows-sftp-enrollment-candidate|1", "operation|install",
            "authorization|inert-unsigned-local-observation", "host|WINDOWS-FIXTURE",
            "request-account|MachineUtilitiesRequest", "request-sid|S-1-5-21-1-2-3-2001",
            "endpoint-principal|machine-utilities-windows", "primary-ca-fingerprint|$Fingerprint",
            "primary-ca-generation|1", "previous-ca-fingerprint|-", "previous-ca-generation|0",
            "krl-generation|1", "management-cidrs|192.0.2.0/24", "host-key-fingerprint|$Fingerprint",
            "intent-sha256|$DigestA", "controller-signature-sha256|$DigestB",
            "controller-signing-thumbprint|$Thumbprint", "release-publisher-thumbprint|$Thumbprint",
            "protected-entrypoint-sha256|$DigestA", "u3-state|verified", "u3-epoch|1",
            "u3-generation-sha256|$DigestA", "u3-active-pointer-sha256|$DigestB",
            "u3-task-sha256|$DigestA", "u3-broker-sha256|$DigestB", "chroot-contract-sha256|$DigestA",
            "slot-acl-sha256|$DigestB", "results-acl-sha256|$DigestA", "quota-contract-sha256|$DigestB",
            "openssh-contract-sha256|$DigestA", "configuration-sha256|$DigestB",
            "firewall-contract-sha256|$DigestA", "issued-at|$IssuedAt", "expires-at|$ExpiresAt",
            "controller-signing|required-separate", "end-candidate|"
        )
        $Candidate = Read-WindowsSftpCandidateLines $CandidateLines
        if ($null -eq $Candidate) { throw "self_test_candidate_rejected" }
        [string[]]$AccountPrincipalLines = $CandidateLines.Clone()
        $AccountPrincipalLines[6] = "endpoint-principal|MachineUtilitiesRequest"
        if ($null -ne (Read-WindowsSftpCandidateLines $AccountPrincipalLines)) {
            throw "self_test_account_name_endpoint_accepted"
        }
        [byte[]]$CandidateBytes = [Text.Encoding]::ASCII.GetBytes(($CandidateLines -join "`n") + "`n")
        $Cms = [Security.Cryptography.Pkcs.SignedCms]::new(
            [Security.Cryptography.Pkcs.ContentInfo]::new($CandidateBytes), $true)
        $Signer = [Security.Cryptography.Pkcs.CmsSigner]::new($Certificate)
        $Signer.IncludeOption = [Security.Cryptography.X509Certificates.X509IncludeOption]::EndCertOnly
        $Cms.ComputeSignature($Signer)
        [byte[]]$SignatureBytes = $Cms.Encode()
        if (-not (Test-WindowsSftpDetachedCms $CandidateBytes $SignatureBytes $Thumbprint $IssuedAt $ExpiresAt)) {
            throw "self_test_signature_rejected"
        }
        $HistoricalIssuedAt = $Now - 600
        $HistoricalExpiresAt = $Now - 300
        $HistoricalKey = [Security.Cryptography.RSA]::Create(2048)
        $HistoricalRequest = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
            "CN=machine-utilities-historical-controller", $HistoricalKey,
            [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $HistoricalCertificate = $HistoricalRequest.CreateSelfSigned(
            [DateTimeOffset]::FromUnixTimeSeconds($HistoricalIssuedAt - 60),
            [DateTimeOffset]::FromUnixTimeSeconds($HistoricalExpiresAt + 60))
        $HistoricalThumbprint = $HistoricalCertificate.Thumbprint.ToUpperInvariant()
        [string[]]$HistoricalCandidateLines = $CandidateLines.Clone()
        for ($Index = 0; $Index -lt $HistoricalCandidateLines.Count; $Index++) {
            if ($HistoricalCandidateLines[$Index] -clike "controller-signing-thumbprint|*") {
                $HistoricalCandidateLines[$Index] = "controller-signing-thumbprint|$HistoricalThumbprint"
            } elseif ($HistoricalCandidateLines[$Index] -clike "release-publisher-thumbprint|*") {
                $HistoricalCandidateLines[$Index] = "release-publisher-thumbprint|$HistoricalThumbprint"
            } elseif ($HistoricalCandidateLines[$Index] -clike "issued-at|*") {
                $HistoricalCandidateLines[$Index] = "issued-at|$HistoricalIssuedAt"
            } elseif ($HistoricalCandidateLines[$Index] -clike "expires-at|*") {
                $HistoricalCandidateLines[$Index] = "expires-at|$HistoricalExpiresAt"
            }
        }
        $HistoricalCandidate = Read-WindowsSftpCandidateLines $HistoricalCandidateLines
        if ($null -eq $HistoricalCandidate -or
            [int64]$HistoricalCandidate.'issued-at' -ne $HistoricalIssuedAt -or
            [int64]$HistoricalCandidate.'expires-at' -ne $HistoricalExpiresAt -or
            $HistoricalExpiresAt -ge $Now) { throw "self_test_historical_candidate_rejected" }
        [byte[]]$HistoricalCandidateBytes = [Text.Encoding]::ASCII.GetBytes(
            ($HistoricalCandidateLines -join "`n") + "`n")
        $HistoricalCms = [Security.Cryptography.Pkcs.SignedCms]::new(
            [Security.Cryptography.Pkcs.ContentInfo]::new($HistoricalCandidateBytes), $true)
        $HistoricalSigner = [Security.Cryptography.Pkcs.CmsSigner]::new($HistoricalCertificate)
        $HistoricalSigner.IncludeOption = [Security.Cryptography.X509Certificates.X509IncludeOption]::EndCertOnly
        $HistoricalCms.ComputeSignature($HistoricalSigner)
        if (-not (Test-WindowsSftpDetachedCms $HistoricalCandidateBytes $HistoricalCms.Encode() `
                $HistoricalThumbprint $HistoricalIssuedAt $HistoricalExpiresAt)) {
            throw "self_test_historical_authorization_rejected"
        }
        $CandidateSha256 = Get-WindowsSftpBytesSha256 $CandidateBytes
        [string[]]$ReadinessLines = @(
            "windows-sftp-readiness|1", "state|ready",
            "reason|controller_signed_receipt_and_local_transport_verified", "host|WINDOWS-FIXTURE",
            "request-sid|S-1-5-21-1-2-3-2001", "intent-sha256|$DigestA",
            "candidate-sha256|$CandidateSha256", "host-key-fingerprint|$Fingerprint",
            "transport-ready|true", "broker-ready|observed-separately",
            "node-identity-ready|observed-separately", "action-context-ready|observed-separately",
            "controller-signature-ready|true",
            "readiness-authority|controller-signed-receipt-plus-local-observation", "end-readiness|"
        )
        $Readiness = Read-WindowsSftpReadinessLines $ReadinessLines
        if (-not (Test-WindowsSftpCandidateReadinessBinding $Candidate $Readiness $CandidateSha256)) {
            throw "self_test_readiness_binding_rejected"
        }

        [string[]]$TamperedCandidateLines = $CandidateLines.Clone()
        $TamperedCandidateLines[2] = "authorization|self-asserted"
        if ($null -ne (Read-WindowsSftpCandidateLines $TamperedCandidateLines)) {
            throw "self_test_candidate_tamper_accepted"
        }
        [byte[]]$TamperedContent = $CandidateBytes.Clone()
        $TamperedContent[10] = $TamperedContent[10] -bxor 1
        if (Test-WindowsSftpDetachedCms $TamperedContent $SignatureBytes $Thumbprint $IssuedAt $ExpiresAt) {
            throw "self_test_content_tamper_accepted"
        }
        [byte[]]$TamperedSignature = $SignatureBytes.Clone()
        $TamperedSignature[0] = $TamperedSignature[0] -bxor 1
        if (Test-WindowsSftpDetachedCms $CandidateBytes $TamperedSignature $Thumbprint $IssuedAt $ExpiresAt) {
            throw "self_test_signature_tamper_accepted"
        }
        [string[]]$TamperedReadinessLines = $ReadinessLines.Clone()
        $TamperedReadinessLines[6] = "candidate-sha256|$DigestB"
        $TamperedReadiness = Read-WindowsSftpReadinessLines $TamperedReadinessLines
        if (Test-WindowsSftpCandidateReadinessBinding $Candidate $TamperedReadiness $CandidateSha256) {
            throw "self_test_readiness_digest_tamper_accepted"
        }
        $TamperedReadinessLines = $ReadinessLines.Clone()
        $TamperedReadinessLines[8] = "transport-ready|false"
        if ($null -ne (Read-WindowsSftpReadinessLines $TamperedReadinessLines)) {
            throw "self_test_readiness_state_tamper_accepted"
        }

        $SecondKey = [Security.Cryptography.RSA]::Create(2048)
        $SecondRequest = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
            "CN=machine-utilities-second-controller", $SecondKey,
            [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $SecondCertificate = $SecondRequest.CreateSelfSigned(
            [DateTimeOffset]::FromUnixTimeSeconds($IssuedAt - 60),
            [DateTimeOffset]::FromUnixTimeSeconds($ExpiresAt + 60))
        $SecondSigner = [Security.Cryptography.Pkcs.CmsSigner]::new($SecondCertificate)
        $SecondSigner.IncludeOption = [Security.Cryptography.X509Certificates.X509IncludeOption]::EndCertOnly
        $Cms.ComputeSignature($SecondSigner)
        if (Test-WindowsSftpDetachedCms $CandidateBytes $Cms.Encode() $Thumbprint $IssuedAt $ExpiresAt) {
            throw "self_test_multi_signer_accepted"
        }
        Write-Output "PASS: Windows SFTP protected-local receipt contracts"
    } finally {
        if ($null -ne $SecondCertificate) { $SecondCertificate.Dispose() }
        if ($null -ne $SecondKey) { $SecondKey.Dispose() }
        if ($null -ne $HistoricalCertificate) { $HistoricalCertificate.Dispose() }
        if ($null -ne $HistoricalKey) { $HistoricalKey.Dispose() }
        if ($null -ne $Certificate) { $Certificate.Dispose() }
        $Key.Dispose()
    }
}

if ($SelfTest) {
    Invoke-WindowsSftpReceiptSelfTest
    exit 0
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Configuration file not found: $ConfigPath"
}
$ConfigItem = Get-Item -LiteralPath $ConfigPath -Force
if (($ConfigItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Configuration file must not be a link"
}
$Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
Assert-WorkerConfig $Config
$Machine = Get-ExactPropertyValue $Config.machines $HostId
$HostGroups = @($Machine.groups)
$AllowedSections = @("all", "host", "packages", "agents", "auth", "projects", "startup", "chezmoi")
if (@($Sections | Where-Object { $AllowedSections -notcontains $_ }).Count -gt 0) {
    throw "Unsupported inventory section"
}

$WorkerConfigHash = (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash.ToLowerInvariant()
Add-Record -Kind "snapshot" -Id "snapshot" -Status "present" -Confidence "high" -Data @{
    configuration_digest = @{ algorithm = "sha256"; value = $ControllerConfigDigest.ToLowerInvariant(); scope = "controller-raw-bytes" }
    worker_configuration_digest = @{ algorithm = "sha256"; value = $WorkerConfigHash; scope = "bounded-worker-raw-bytes" }
    sections = $Sections
}

Add-PrivilegeReadiness $Config $Machine

if (Test-Section "host") {
    $Os = Get-CimInstance Win32_OperatingSystem
    Add-Record -Kind "host" -Id $HostId -Status "present" -Confidence "high" -Data @{
        configured_name = $HostId
        hostname = Limit-Text $env:COMPUTERNAME
        user = Limit-Text ([Environment]::UserName)
        home = Limit-Text $HOME
        os = Limit-Text $Os.Caption
        version = Limit-Text $Os.Version
        build = Limit-Text $Os.BuildNumber
        architecture = Limit-Text $env:PROCESSOR_ARCHITECTURE
    } -Evidence @(@{ source = "system"; method = "Win32_OperatingSystem" })
}

if (Test-Section "packages") {
    $Managers = @($Machine.package_managers)
    if ($Managers -contains "winget") {
        $Winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($null -eq $Winget) {
            Add-Record -Kind "error" -Id "packages:winget" -Status "unavailable" -Confidence "high" -Errors @(
                @{ code = "manager_missing"; severity = "warning"; retryable = $false; message = "winget is not installed" }
            )
        } else {
            $Temp = Join-Path ([IO.Path]::GetTempPath()) ("machine-utilities-winget-" + [Guid]::NewGuid().ToString("N") + ".json")
            $Candidates = @{}
            $CandidateQueryAuthoritative = $false
            try {
                $UpgradeLines = @(& winget upgrade --accept-source-agreements --disable-interactivity 2>$null)
                $UpgradeSucceeded = $?
                $UpgradeExitCode = $LASTEXITCODE
                if ($UpgradeSucceeded -and ($null -eq $UpgradeExitCode -or $UpgradeExitCode -eq 0)) {
                    $HeaderIndex = -1
                    for ($Index = 0; $Index -lt $UpgradeLines.Count; $Index++) {
                        if ([string]$UpgradeLines[$Index] -match '^Name\s{2,}Id\s{2,}Version\s{2,}Available\s{2,}Source\s*$') {
                            $HeaderIndex = $Index
                            break
                        }
                    }
                    if ($HeaderIndex -ge 0 -and $HeaderIndex + 1 -lt $UpgradeLines.Count -and
                        [string]$UpgradeLines[$HeaderIndex + 1] -match '^-{3,}(\s+-{2,}){4}\s*$') {
                        $CandidateQueryAuthoritative = $true
                        foreach ($Line in @($UpgradeLines | Select-Object -Skip ($HeaderIndex + 2))) {
                            if ([string]::IsNullOrWhiteSpace([string]$Line)) { continue }
                            if ([string]$Line -notmatch '^(?<name>.*?)\s{2,}(?<id>\S+)\s+(?<installed>\S+)\s+(?<available>\S+)\s+(?<source>\S+)\s*$' -or
                                [string]$Matches.available -match '^-+$' -or
                                $Candidates.ContainsKey([string]$Matches.id)) {
                                $CandidateQueryAuthoritative = $false
                                $Candidates.Clear()
                                break
                            }
                            $Candidates[[string]$Matches.id] = [string]$Matches.available
                        }
                    } elseif (($UpgradeLines -join "`n") -match
                        '(?m)^(No installed package found matching input criteria|No applicable upgrade found)\.?$') {
                        $CandidateQueryAuthoritative = $true
                    }
                    if (-not $CandidateQueryAuthoritative) {
                        Add-Record -Kind "error" -Id "packages:winget-updates" -Status "partial" -Confidence "high" -Errors @(
                            @{ code = "candidate_query_unverified"; severity = "warning"; retryable = $true; message = "winget upgrade output was not an authoritative package table" }
                        )
                    }
                } else {
                    Add-Record -Kind "error" -Id "packages:winget-updates" -Status "unavailable" -Confidence "medium" -Errors @(
                        @{ code = "candidate_query_failed"; severity = "warning"; retryable = $true; message = "winget upgrade inventory failed" }
                    )
                }
                $null = & winget export --output $Temp --include-versions --accept-source-agreements --disable-interactivity
                $WingetSucceeded = $?
                $WingetExitCode = $LASTEXITCODE
                if (-not $WingetSucceeded -or ($null -ne $WingetExitCode -and $WingetExitCode -ne 0)) {
                    throw "winget export failed"
                }
                if (Test-Path -LiteralPath $Temp) {
                    $Export = Get-Content -LiteralPath $Temp -Raw | ConvertFrom-Json
                    foreach ($Source in @($Export.Sources)) {
                        foreach ($Package in @($Source.Packages)) {
                            $Name = Limit-Text $Package.PackageIdentifier
                            $Candidate = if ($Candidates.ContainsKey([string]$Package.PackageIdentifier)) {
                                Limit-Text $Candidates[[string]$Package.PackageIdentifier]
                            } else {
                                $null
                            }
                            Add-Record -Kind "package" -Id ("winget:" + $Name) -Status "present" `
                                -Confidence $(if ($CandidateQueryAuthoritative) { "high" } else { "medium" }) -Data @{
                                manager = "winget"
                                name = $Name
                                installed_version = Limit-Text $Package.Version
                                candidate_version = $Candidate
                                update_available = if ($CandidateQueryAuthoritative) {
                                    $null -ne $Candidate -and $Candidate -ne [string]$Package.Version
                                } else { $null }
                                source = Limit-Text $Source.SourceDetails.Name
                            } -Evidence @(@{ source = "package-manager"; method = "winget-export+upgrade-list" })
                        }
                    }
                }
            } catch {
                Add-Record -Kind "error" -Id "packages:winget" -Status "error" -Confidence "high" -Errors @(
                    @{ code = "manager_query_failed"; severity = "error"; retryable = $true; message = "winget export failed" }
                )
            } finally {
                Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

if (Test-Section "agents") {
    $SkillLockEntries = @()
    $JsmInventory = $null
    $ActivePluginsByAgent = @{ codex = @(); claude = @() }
    $PluginManagerStates = @{ codex = "absent"; claude = "absent" }
    foreach ($Runtime in @("codex", "claude")) {
        $Command = Get-Command $Runtime -ErrorAction SilentlyContinue
        if ($null -eq $Command) {
            Add-Record -Kind "agent_runtime" -Id $Runtime -Status "absent" -Confidence "high" -Data @{ runtime = $Runtime }
        } else {
            $Version = try { (& $Runtime --version 2>$null | Select-Object -First 1) } catch { "unknown" }
            Add-Record -Kind "agent_runtime" -Id $Runtime -Status "present" -Confidence "high" -Data @{
                runtime = $Runtime
                executable = Limit-Text $Command.Source
                version = Limit-Text $Version
            } -Evidence @(@{ source = "runtime"; method = "--version" })
        }
    }

    foreach ($Agent in @("codex", "claude")) {
        if ($null -eq (Get-Command $Agent -ErrorAction SilentlyContinue)) {
            Add-Record -Kind "plugin_manager" -Id $Agent -Status "absent" -Confidence "high" -Data @{
                agent = $Agent; authoritative = $false
            }
            continue
        }
        try {
            $PluginLines = @(& $Agent plugin list --json 2>$null)
            $PluginSucceeded = $?
            $PluginExitCode = $LASTEXITCODE
            if (-not $PluginSucceeded -or ($null -ne $PluginExitCode -and $PluginExitCode -ne 0)) {
                throw "plugin list failed"
            }
            $PluginOutput = ($PluginLines -join "`n").Trim()
            if ([string]::IsNullOrWhiteSpace($PluginOutput)) { throw "plugin list was empty" }
            $ParsedPlugins = $PluginOutput | ConvertFrom-Json
            $Entries = if ($Agent -eq "codex") {
                if (-not $PluginOutput.TrimStart().StartsWith("{") -or $null -eq $ParsedPlugins.installed) {
                    throw "invalid codex plugin list"
                }
                @($ParsedPlugins.installed)
            } else {
                if (-not $PluginOutput.TrimStart().StartsWith("[")) { throw "invalid claude plugin list" }
                @($ParsedPlugins)
            }
            $Normalized = @()
            foreach ($PluginEntry in $Entries) {
                if ($null -eq $PluginEntry) { throw "plugin entry is missing" }
                if ($Agent -eq "codex") {
                    if (
                        $PluginEntry.pluginId -isnot [string] -or [string]::IsNullOrWhiteSpace($PluginEntry.pluginId) -or
                        $PluginEntry.name -isnot [string] -or [string]::IsNullOrWhiteSpace($PluginEntry.name) -or
                        $PluginEntry.marketplaceName -isnot [string] -or [string]::IsNullOrWhiteSpace($PluginEntry.marketplaceName) -or
                        $PluginEntry.version -isnot [string] -or [string]::IsNullOrWhiteSpace($PluginEntry.version) -or
                        $PluginEntry.installed -isnot [bool] -or
                        $PluginEntry.enabled -isnot [bool]
                    ) {
                        throw "invalid codex plugin entry"
                    }
                    if (
                        $null -ne $PluginEntry.source -and
                        $null -ne $PluginEntry.source.path -and
                        $PluginEntry.source.path -isnot [string]
                    ) {
                        throw "invalid codex plugin path"
                    }
                    if (-not $PluginEntry.installed) { continue }
                } else {
                    if (
                        $PluginEntry.id -isnot [string] -or [string]::IsNullOrWhiteSpace($PluginEntry.id) -or
                        $PluginEntry.version -isnot [string] -or [string]::IsNullOrWhiteSpace($PluginEntry.version) -or
                        $PluginEntry.enabled -isnot [bool] -or
                        ($null -ne $PluginEntry.installPath -and $PluginEntry.installPath -isnot [string]) -or
                        (
                            $null -ne $PluginEntry.installedAt -and
                            $PluginEntry.installedAt -isnot [string] -and
                            $PluginEntry.installedAt -isnot [DateTime]
                        ) -or
                        (
                            $null -ne $PluginEntry.lastUpdated -and
                            $PluginEntry.lastUpdated -isnot [string] -and
                            $PluginEntry.lastUpdated -isnot [DateTime]
                        )
                    ) {
                        throw "invalid claude plugin entry"
                    }
                }
                $ManagerId = Limit-Text $(if ($Agent -eq "codex") { $PluginEntry.pluginId } else { $PluginEntry.id })
                $IdParts = $ManagerId -split "@", 2
                if (
                    $Agent -eq "claude" -and
                    ($IdParts.Count -ne 2 -or
                        [string]::IsNullOrWhiteSpace($IdParts[0]) -or
                        [string]::IsNullOrWhiteSpace($IdParts[1]))
                ) {
                    throw "invalid claude plugin id"
                }
                $Name = Limit-Text $(if ($Agent -eq "codex") {
                    $PluginEntry.name
                } else {
                    $IdParts[0]
                })
                $Marketplace = Limit-Text $(if ($Agent -eq "codex") {
                    $PluginEntry.marketplaceName
                } else {
                    $IdParts[1]
                })
                $Normalized += [ordered]@{
                    agent = $Agent
                    manager_id = $ManagerId
                    marketplace = $Marketplace
                    name = $Name
                    installed_version = Limit-Text $PluginEntry.version
                    enabled = $PluginEntry.enabled
                    path = Limit-Text $(if ($Agent -eq "codex") { $PluginEntry.source.path } else { $PluginEntry.installPath })
                    installed_at = Limit-Text $(if ($Agent -eq "claude") { $PluginEntry.installedAt } else { $null })
                    last_updated = Limit-Text $(if ($Agent -eq "claude") { $PluginEntry.lastUpdated } else { $null })
                }
            }
            $ActivePluginsByAgent[$Agent] = @($Normalized)
            $PluginManagerStates[$Agent] = "present"
            Add-Record -Kind "plugin_manager" -Id $Agent -Status "present" -Confidence "high" -Data @{
                agent = $Agent; authoritative = $true; installed_count = @($Normalized).Count
            } -Evidence @(@{ source = "manager-cli"; method = "plugin-list-json" })
        } catch {
            $PluginManagerStates[$Agent] = "unavailable"
            Add-Record -Kind "plugin_manager" -Id $Agent -Status "unavailable" -Confidence "high" -Data @{
                agent = $Agent; authoritative = $false
            } -Errors @(@{ code = "manager_query_failed"; severity = "warning"; retryable = $true; message = "plugin manager inventory failed" })
        }
    }

    $LockPath = Join-Path $HOME ".agents/.skill-lock.json"
    if (Test-Path -LiteralPath $LockPath -PathType Leaf) {
        try {
            $Lock = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json
            $Skills = if ($null -ne $Lock.skills) { $Lock.skills } else { $Lock }
            $SkillLockEntries = @($Skills.PSObject.Properties)
            foreach ($Property in $Skills.PSObject.Properties) {
                if (-not (Test-ManagerEntityName $Property.Name "skills-cli")) {
                    throw "skills-cli lock contains an option-shaped or invalid skill name"
                }
                $Value = $Property.Value
                Add-Record -Kind "skill" -Id ("skills-cli:" + (Limit-Text $Property.Name)) -Status "present" -Confidence "high" -Data @{
                    manager = "skills-cli"
                    name = Limit-Text $Property.Name
                    source = Get-SafeRemote ([string]$Value.source)
                    source_type = Limit-Text $Value.sourceType
                    source_url = Get-SafeRemote ([string]$Value.sourceUrl)
                    skill_path = Limit-Text $Value.skillPath
                    folder_hash = Limit-Text $Value.skillFolderHash
                    installed_at = Limit-Text $Value.installedAt
                    updated_at = Limit-Text $Value.updatedAt
                } -Evidence @(@{ source = "manager-lock"; method = "skills-v3-lock" })
            }
        } catch {
            Add-Record -Kind "error" -Id "agents:skills-cli-lock" -Status "unavailable" -Confidence "high" -Errors @(
                @{ code = "manager_lock_invalid"; severity = "warning"; retryable = $false; message = "skills-cli lock file is invalid" }
            )
        }
    }

    $Jsm = Get-Command jsm -ErrorAction SilentlyContinue
    if ($null -ne $Jsm) {
        try {
            $JsmLines = @(& jsm --json --offline list 2>$null)
            $JsmSucceeded = $?
            $JsmExitCode = $LASTEXITCODE
            if (-not $JsmSucceeded -or ($null -ne $JsmExitCode -and $JsmExitCode -ne 0)) {
                throw "jsm list failed"
            }
            $JsmOutput = ($JsmLines | Out-String)
            $JsmInventory = $JsmOutput | ConvertFrom-Json
            if ($null -eq $JsmInventory.skills -or $JsmInventory.skills -isnot [Array]) {
                throw "jsm skills payload is not an array"
            }
            foreach ($Skill in @($JsmInventory.skills)) {
                if (-not (Test-JsmSkill $Skill)) { throw "jsm skill payload is invalid" }
                $Name = Limit-Text $Skill.name
                Add-Record -Kind "skill" -Id ("jsm:" + $Name) -Status "present" -Confidence "high" -Data @{
                    manager = "jsm"
                    name = $Name
                    version = Limit-Text $Skill.version
                    installed_at = Limit-Text $Skill.installed_at
                    pinned = $(Get-NullableBoolean $Skill.pinned $false)
                    update_available = $(Get-NullableBoolean $Skill.update_available)
                    latest_version = Limit-Text $Skill.latest_version
                    is_saved = $(Get-NullableBoolean $Skill.is_saved)
                    is_jeffreys = $(Get-NullableBoolean $Skill.is_jeffreys)
                    tags = @($Skill.tags | Select-Object -First 128 | ForEach-Object {
                        $Tag = Limit-Text $_
                        if ($Tag.Length -gt 256) { $Tag.Substring(0, 256) } else { $Tag }
                    })
                } -Evidence @(@{ source = "manager-cli"; method = "jsm-offline-list" })
            }
        } catch {
            Add-Record -Kind "error" -Id "agents:jsm" -Status "unavailable" -Confidence "medium" -Errors @(
                @{ code = "manager_query_failed"; severity = "warning"; retryable = $true; message = "jsm offline inventory failed" }
            )
        }
    }

    if ($null -ne $Config.capabilities) {
        foreach ($Property in $Config.capabilities.PSObject.Properties) {
            $Groups = @($Property.Value.groups)
            if ($Groups.Count -gt 0 -and @($Groups | Where-Object { Test-ExactMember $HostGroups $_ }).Count -eq 0) { continue }
            $Name = Limit-Text $Property.Name
            $Providers = @()
            foreach ($Agent in @("codex", "claude")) {
                $SharedAgents = @(Get-ExactPropertyValue $Property.Value "agents")
                $Definition = if (Test-ExactMember $SharedAgents $Agent) {
                    $Property.Value
                } else {
                    Get-ExactPropertyValue $Property.Value $Agent
                }
                if ($null -eq $Definition) { continue }
                $Provider = Limit-Text $Definition.provider
                $Source = Get-SafeRemote ([string]$Definition.source)
                $ExpectedName = Limit-Text $(if ($null -ne $Definition.skill) {
                    $Definition.skill
                } elseif ($null -ne $Definition.name) {
                    $Definition.name
                } else {
                    $Name
                })
                $Matches = @()
                switch ($Provider) {
                    "plugin" {
                        $PluginName = Split-Path ([string]$Definition.source) -Leaf
                        foreach ($ActivePlugin in @($ActivePluginsByAgent[$Agent])) {
                            if ([bool]$ActivePlugin.enabled -and
                                ($ActivePlugin.name -ceq $PluginName -or
                                $ActivePlugin.manager_id -ceq [string]$Definition.source)) {
                                $Matches += "plugin:$Agent`:$($ActivePlugin.marketplace):$($ActivePlugin.name):$($ActivePlugin.installed_version)"
                            }
                        }
                    }
                    "skills-cli" {
                        foreach ($Entry in $SkillLockEntries) {
                            if ($Entry.Name -ceq $ExpectedName -or
                                [string]$Entry.Value.source -ceq [string]$Definition.source -or
                                [string]$Entry.Value.sourceUrl -ceq [string]$Definition.source) {
                                $Matches += "skills-cli:$($Entry.Name)"
                            }
                        }
                    }
                    "jsm" {
                        foreach ($Skill in @($JsmInventory.skills)) {
                            if ($Skill.name -ceq $ExpectedName -or $Skill.name -ceq [string]$Definition.source) {
                                $Matches += "jsm:$($Skill.name)"
                            }
                        }
                    }
                    { $_ -in @("manual", "plugin-source") } {
                        foreach ($Root in @($Config.skill_roots)) {
                            if (-not (Test-ExactMember @($Root.agents) $Agent)) { continue }
                            $RootGroups = @($Root.groups)
                            if ($RootGroups.Count -gt 0 -and @($RootGroups | Where-Object { Test-ExactMember $HostGroups $_ }).Count -eq 0) { continue }
                            $SkillPath = Join-Path (Resolve-UserPath ([string]$Root.path)) $ExpectedName
                            if (Test-Path -LiteralPath (Join-Path $SkillPath "SKILL.md") -PathType Leaf) {
                                $Matches += "standalone:$($Root.id):$ExpectedName"
                            }
                        }
                    }
                }
                $Matches = @($Matches | Sort-Object -Unique)
                $Providers += @{
                    agent = $Agent
                    provider = $Provider
                    source = $Source
                    expected_name = $ExpectedName
                    observed = $Matches.Count -gt 0
                    matches = $Matches
                    duplicate = $Matches.Count -gt 1
                }
            }
            $ObservedCount = @($Providers | Where-Object { $_.observed }).Count
            $DuplicateCount = @($Providers | Where-Object { $_.duplicate }).Count
            $AuthDependencies = @()
            $ArtifactDependencies = @()
            $DependenciesReady = $true
            foreach ($RequiredAuth in @($Property.Value.requires_auth)) {
                $DependencyStatus = "unconfigured"
                $DependencyReady = $false
                $AuthDefinition = if ($null -ne $Config.auth_artifacts) {
                    Get-ExactPropertyValue $Config.auth_artifacts $RequiredAuth
                } else {
                    $null
                }
                if ($null -ne $AuthDefinition) {
                    $ConfiguredPath = Get-ConfiguredPath $AuthDefinition $HostId
                    $DependencyPath = Resolve-UserPath $ConfiguredPath
                    $Portability = if ($null -eq $AuthDefinition.portability) { "per-machine" } else { [string]$AuthDefinition.portability }
                    if ([string]::IsNullOrWhiteSpace($DependencyPath) -and $Portability -in @("native-store", "per-machine")) {
                        $Health = Get-AuthHealth $AuthDefinition
                        $DependencyStatus = [string]$Health.health
                        $DependencyReady = $DependencyStatus -eq "healthy"
                    } elseif (Test-Path -LiteralPath $DependencyPath) {
                        $Item = Get-Item -LiteralPath $DependencyPath -Force
                        if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $Item.PSIsContainer) {
                            $DependencyStatus = "partial"
                        } else {
                            $Health = Get-AuthHealth $AuthDefinition
                            $DependencyStatus = [string]$Health.health
                            $DependencyReady = $DependencyStatus -in @("healthy", "not-configured")
                        }
                    } else {
                        $DependencyStatus = "absent"
                    }
                }
                if (-not $DependencyReady) { $DependenciesReady = $false }
                $AuthDependencies += @{
                    id = Limit-Text $RequiredAuth
                    status = Limit-Text $DependencyStatus
                    ready = $DependencyReady
                }
            }
            foreach ($RequiredArtifact in @($Property.Value.requires_artifacts)) {
                $DependencyStatus = "unconfigured"
                $DependencyReady = $false
                $ArtifactDefinition = @($Config.agent_artifacts | Where-Object {
                    $_.id -ceq $RequiredArtifact -and
                    (@($_.groups).Count -eq 0 -or @($_.groups | Where-Object { Test-ExactMember $HostGroups $_ }).Count -gt 0)
                } | Select-Object -First 1)
                if ($ArtifactDefinition.Count -gt 0) {
                    $ConfiguredArtifactPath = Get-ConfiguredPath $ArtifactDefinition[0] $HostId
                    $ArtifactPath = Resolve-UserPath $ConfiguredArtifactPath
                    if ([string]::IsNullOrWhiteSpace($ArtifactPath)) {
                        $DependencyStatus = "unavailable"
                    } elseif (Test-Path -LiteralPath $ArtifactPath) {
                        $Item = Get-Item -LiteralPath $ArtifactPath -Force
                        if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                            $DependencyStatus = "partial"
                        } else {
                            $DependencyStatus = "present"
                            $DependencyReady = $true
                        }
                    } else {
                        $DependencyStatus = "absent"
                    }
                }
                if (-not $DependencyReady) { $DependenciesReady = $false }
                $ArtifactDependencies += @{
                    id = Limit-Text $RequiredArtifact
                    status = Limit-Text $DependencyStatus
                    ready = $DependencyReady
                }
            }
            $ProviderAvailable = $Providers.Count -gt 0 -and $ObservedCount -eq $Providers.Count
            $ProviderConsistent = $ProviderAvailable -and $DuplicateCount -eq 0
            $CapabilityReady = $ProviderConsistent -and $DependenciesReady
            $CapabilityStatus = if ($CapabilityReady) {
                "present"
            } elseif ($ObservedCount -gt 0 -or $AuthDependencies.Count -gt 0 -or $ArtifactDependencies.Count -gt 0) {
                "partial"
            } else {
                "absent"
            }
            Add-Record -Kind "capability" -Id $Name -Status $CapabilityStatus -Confidence "high" -Data @{
                name = $Name
                available = $ProviderAvailable -and $DependenciesReady
                ready = $CapabilityReady
                consistent = $ProviderConsistent
                providers = $Providers
                dependencies = @{
                    ready = $DependenciesReady
                    auth = $AuthDependencies
                    artifacts = $ArtifactDependencies
                }
            } -Evidence @(@{ source = "configuration+manager-state+dependency-state"; method = "logical-provider-reconciliation" })
        }
    }

    if ($null -ne $Config.skill_roots) {
        foreach ($Definition in @($Config.skill_roots)) {
            $Groups = @($Definition.groups)
            if ($Groups.Count -gt 0 -and @($Groups | Where-Object { Test-ExactMember $HostGroups $_ }).Count -eq 0) { continue }
            $RootId = Limit-Text $Definition.id
            $RootPath = Resolve-UserPath ([string]$Definition.path)
            if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
                Add-Record -Kind "skill_root" -Id $RootId -Status "absent" -Confidence "high" -Data @{
                    id = $RootId; path = Limit-Text $RootPath
                }
                continue
            }
            $Manager = Limit-Text $(if (Test-Path -LiteralPath (Join-Path $RootPath ".SKILLS_MANAGED_BY_JSM") -PathType Leaf) {
                "jsm"
            } elseif ($null -ne $Definition.manager) {
                $Definition.manager
            } else {
                "manual"
            })
            foreach ($SkillDirectory in @(Get-ChildItem -LiteralPath $RootPath -Directory -Force -ErrorAction SilentlyContinue |
                Sort-Object Name)) {
                $SkillFile = Join-Path $SkillDirectory.FullName "SKILL.md"
                if (-not (Test-Path -LiteralPath $SkillFile -PathType Leaf)) { continue }
                try {
                    $Origin = (& git -C $SkillDirectory.FullName remote get-url origin 2>$null | Select-Object -First 1)
                    $Digest = Get-DirectoryDigest $SkillDirectory.FullName
                    Add-Record -Kind "skill" -Id ("standalone:" + $RootId + ":" + (Limit-Text $SkillDirectory.Name)) -Status "present" -Confidence "medium" -Data @{
                        name = Limit-Text $SkillDirectory.Name
                        root = $RootId
                        path = Limit-Text $SkillDirectory.FullName
                        manager = $Manager
                        agent_exposure = @($Definition.agents)
                        origin = Get-SafeRemote $Origin
                        updated_at = (Get-Item -LiteralPath $SkillFile).LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
                        digest = @{ algorithm = "sha256"; value = $Digest; scope = "directory-files" }
                    } -Evidence @(@{ source = "filesystem"; method = "configured-skill-root+directory-sha256" })
                } catch {
                    Add-Record -Kind "skill" -Id ("standalone:" + $RootId + ":" + (Limit-Text $SkillDirectory.Name)) -Status "partial" -Confidence "medium" -Data @{
                        name = Limit-Text $SkillDirectory.Name; root = $RootId; path = Limit-Text $SkillDirectory.FullName; manager = $Manager
                    } -Errors @(@{ code = "skill_hash_failed"; severity = "warning"; retryable = $true; message = "standalone skill inventory failed" })
                }
            }
        }
    }

    if ($null -ne $Config.agent_artifacts) {
        foreach ($Definition in @($Config.agent_artifacts)) {
            $Groups = @($Definition.groups)
            if ($Groups.Count -gt 0 -and @($Groups | Where-Object { Test-ExactMember $HostGroups $_ }).Count -eq 0) { continue }
            $ArtifactId = Limit-Text $Definition.id
            $ConfiguredArtifactPath = Get-ConfiguredPath $Definition $HostId
            $ArtifactPath = Resolve-UserPath $ConfiguredArtifactPath
            $PathAttributes = $null
            $PathProbeFailed = $false
            if (-not [string]::IsNullOrWhiteSpace($ArtifactPath)) {
                try {
                    $PathAttributes = [IO.File]::GetAttributes($ArtifactPath)
                } catch [IO.FileNotFoundException] {
                    # A missing leaf is an authoritative absent observation.
                } catch [IO.DirectoryNotFoundException] {
                    # A missing parent is an authoritative absent observation.
                } catch {
                    $PathProbeFailed = $true
                }
            }
            if ([string]::IsNullOrWhiteSpace($ArtifactPath)) {
                Add-Record -Kind "agent_artifact" -Id $ArtifactId -Status "unavailable" -Confidence "high" -Data @{
                    id = $ArtifactId; path = $null; artifact_kind = Limit-Text $Definition.kind
                    agent_exposure = @($Definition.agents)
                } -Errors @(@{ code = "artifact_path_missing"; severity = "warning"; retryable = $false; message = "agent artifact has no path for this host" })
                if ($null -ne $Definition.settings -and $Definition.settings.PSObject.Properties.Count -gt 0) {
                    Add-AgentSettings $Definition $ArtifactId "" -UnknownPath
                }
            } elseif ($PathProbeFailed) {
                Add-Record -Kind "agent_artifact" -Id $ArtifactId -Status "unavailable" -Confidence "medium" -Data @{
                    id = $ArtifactId; path = Limit-Text $ArtifactPath; artifact_kind = Limit-Text $Definition.kind
                    agent_exposure = @($Definition.agents)
                } -Errors @(@{ code = "artifact_path_unavailable"; severity = "warning"; retryable = $true; message = "agent artifact path could not be inspected" })
                if ($null -ne $Definition.settings -and
                    $Definition.settings.PSObject.Properties.Count -gt 0) {
                    Add-AgentSettings $Definition $ArtifactId $ArtifactPath -UnavailablePath
                }
            } elseif ($null -ne $PathAttributes) {
                if (($PathAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    Add-Record -Kind "agent_artifact" -Id $ArtifactId -Status "partial" -Confidence "medium" -Data @{
                        id = $ArtifactId; path = Limit-Text $ArtifactPath; artifact_kind = Limit-Text $Definition.kind
                        agent_exposure = @($Definition.agents)
                    } -Errors @(@{ code = "symlink_not_followed"; severity = "warning"; retryable = $false; message = "agent artifact path is a link" })
                    if ($null -ne $Definition.settings -and
                        $Definition.settings.PSObject.Properties.Count -gt 0) {
                        Add-AgentSettings $Definition $ArtifactId $ArtifactPath -LinkedPath
                    }
                } else {
                    $Item = Get-Item -LiteralPath $ArtifactPath -Force -ErrorAction Stop
                    $Digest = if ($Item.PSIsContainer) {
                        Get-DirectoryDigest $ArtifactPath
                    } else {
                        (Get-FileHash -LiteralPath $ArtifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
                    }
                    Add-Record -Kind "agent_artifact" -Id $ArtifactId -Status "present" -Confidence $(if ($Item.PSIsContainer) { "medium" } else { "high" }) -Data @{
                        id = $ArtifactId
                        path = Limit-Text $ArtifactPath
                        artifact_kind = Limit-Text $Definition.kind
                        agent_exposure = @($Definition.agents)
                        updated_at = $Item.LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
                        digest = @{ algorithm = "sha256"; value = $Digest; scope = $(if ($Item.PSIsContainer) { "directory-files" } else { "raw-bytes" }) }
                    } -Evidence @(@{ source = "filesystem"; method = "configured-agent-artifact+sha256" })
                    if ($null -ne $Definition.settings -and
                        $Definition.settings.PSObject.Properties.Count -gt 0) {
                        Add-AgentSettings $Definition $ArtifactId $ArtifactPath
                    }
                }
            } else {
                Add-Record -Kind "agent_artifact" -Id $ArtifactId -Status "absent" -Confidence "high" -Data @{
                    id = $ArtifactId; path = Limit-Text $ArtifactPath; artifact_kind = Limit-Text $Definition.kind
                    agent_exposure = @($Definition.agents)
                }
                if ($null -ne $Definition.settings -and $Definition.settings.PSObject.Properties.Count -gt 0) {
                    Add-AgentSettings $Definition $ArtifactId $ArtifactPath
                }
            }
        }
    }

    $SeenPlugins = @{}
    foreach ($Agent in @("codex", "claude")) {
        $Cache = Join-Path $HOME $(if ($Agent -eq "codex") { ".codex/plugins/cache" } else { ".claude/plugins/cache" })
        foreach ($ActivePlugin in @($ActivePluginsByAgent[$Agent])) {
            $CachePath = Join-Path $Cache ([IO.Path]::Combine(
                [string]$ActivePlugin.marketplace,
                [string]$ActivePlugin.name,
                [string]$ActivePlugin.installed_version
            ))
            $CacheItem = if (Test-Path -LiteralPath $CachePath -PathType Container) {
                Get-Item -LiteralPath $CachePath -Force
            } else {
                $null
            }
            $InferredInstalledAt = if ($null -ne $ActivePlugin.installed_at -or $null -eq $CacheItem) {
                $null
            } else {
                $CacheItem.CreationTimeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
            }
            $Key = "$Agent`:$($ActivePlugin.marketplace):$($ActivePlugin.name):$($ActivePlugin.installed_version)"
            $SeenPlugins[$Key] = $true
            Add-Record -Kind "plugin" -Id $Key -Status "present" -Confidence "high" -Data @{
                agent = $Agent
                manager_id = Limit-Text $ActivePlugin.manager_id
                marketplace = Limit-Text $ActivePlugin.marketplace
                name = Limit-Text $ActivePlugin.name
                installed_version = Limit-Text $ActivePlugin.installed_version
                enabled = [bool]$ActivePlugin.enabled
                path = Limit-Text $ActivePlugin.path
                installed_at = Limit-Text $ActivePlugin.installed_at
                last_updated = Limit-Text $ActivePlugin.last_updated
                active = $true
                install_state = "installed"
                inventory_source = "manager"
                cache_path = Limit-Text $(if ($null -ne $CacheItem) { $CachePath } else { $null })
                inferred_installed_at = $InferredInstalledAt
                inferred_installed_at_evidence = $(if ($null -ne $InferredInstalledAt) { "filesystem_creation_time" } else { $null })
                inferred_installed_at_confidence = $(if ($null -ne $InferredInstalledAt) { "low" } else { "unknown" })
            } -Evidence @(@{ source = "manager-cli"; method = "plugin-list-json" })
        }

        if (-not (Test-Path -LiteralPath $Cache -PathType Container)) { continue }
        $CacheMarketplaces = @(Get-ChildItem -LiteralPath $Cache -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne "plugin-eval" })
        foreach ($MarketplaceDirectory in $CacheMarketplaces) {
            foreach ($PluginDirectory in @(Get-ChildItem -LiteralPath $MarketplaceDirectory.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
                foreach ($VersionDirectory in @(Get-ChildItem -LiteralPath $PluginDirectory.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
                    $HasManifest = $false
                    foreach ($ManifestDirectory in @(".codex-plugin", ".claude-plugin")) {
                        if (Test-Path -LiteralPath (Join-Path $VersionDirectory.FullName "$ManifestDirectory/plugin.json") -PathType Leaf) {
                            $HasManifest = $true
                            break
                        }
                    }
                    if (-not $HasManifest) { continue }
                    $Plugin = $PluginDirectory.Name
                    $Marketplace = $MarketplaceDirectory.Name
                    $Version = $VersionDirectory.Name
                    $Key = "$Agent`:$Marketplace`:$Plugin`:$Version"
                    if ($SeenPlugins.ContainsKey($Key)) { continue }
                    $SeenPlugins[$Key] = $true
                    $ManagerUnverified = $PluginManagerStates[$Agent] -eq "unavailable"
                    Add-Record -Kind "plugin_cache" -Id $Key -Status "present" -Confidence "low" -Data @{
                        agent = $Agent
                        marketplace = Limit-Text $Marketplace
                        name = Limit-Text $Plugin
                        cached_version = Limit-Text $Version
                        path = Limit-Text $VersionDirectory.FullName
                        active = $(if ($ManagerUnverified) { $null } else { $false })
                        install_state = $(if ($ManagerUnverified) { "manager-unverified" } else { "cache-only" })
                        inventory_source = "cache"
                        inferred_cached_at = $VersionDirectory.CreationTimeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
                        inferred_cached_at_evidence = "filesystem_creation_time"
                        inferred_cached_at_confidence = "low"
                    } -Evidence @(@{ source = "filesystem"; method = "cache-directory-observation+creation-time-inference" })
                }
            }
        }
    }
}

if (Test-Section "auth") {
    if ($null -ne $Config.auth_artifacts) {
        foreach ($Property in $Config.auth_artifacts.PSObject.Properties) {
            $Name = Limit-Text $Property.Name
            $Definition = $Property.Value
            $Strategy = if ($null -eq $Definition.strategy) { "ignore" } else { Limit-Text $Definition.strategy }
            $Portability = if ($null -eq $Definition.portability) { "per-machine" } else { Limit-Text $Definition.portability }
            $ConfiguredPath = Get-ConfiguredPath $Definition $HostId
            $Path = Resolve-UserPath $ConfiguredPath
            if ([string]::IsNullOrWhiteSpace($Path) -and $Portability -in @("native-store", "per-machine")) {
                $Health = Get-AuthHealth $Definition
                $ReauthRequired = $Strategy -ceq "reauth" -and $Health.health -eq "unhealthy"
                Add-Record -Kind "auth_artifact" -Id $Name -Status $(if ($Health.health -eq "healthy") { "present" } elseif ($ReauthRequired) { "absent" } else { "partial" }) -Confidence "high" -Data @{
                    tool = $Name; path = $null; strategy = $Strategy; portability = $Portability
                    type = "native-status"; health = $Health.health; verify_exit_code = $Health.verify_exit_code
                    reauth_required = $ReauthRequired
                    manual_action = $(if ($ReauthRequired) { "run the configured native login on this host" } else { $null })
                } -Evidence @(@{ source = "native-cli"; method = "configured-auth-status" })
            } elseif (Test-Path -LiteralPath $Path -PathType Leaf) {
                $Item = Get-Item -LiteralPath $Path -Force
                if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    Add-Record -Kind "auth_artifact" -Id $Name -Status "partial" -Confidence "medium" -Data @{
                        tool = $Name; path = Limit-Text $Path; strategy = $Strategy
                        portability = $Portability
                        type = "symlink"; health = "not-run"; verify_exit_code = $null
                    } -Errors @(@{ code = "symlink_not_followed"; severity = "warning"; retryable = $false; message = "credential path is a link" })
                } else {
                    $Hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
                    $Health = Get-AuthHealth $Definition
                    $Acl = try { Get-Acl -LiteralPath $Path -ErrorAction Stop } catch { $null }
                    $AclErrors = @()
                    $AclAccess = "unavailable"
                    $AclFingerprint = $null
                    if ($null -eq $Acl) {
                        $AclErrors += @{ code = "acl_unavailable"; severity = "warning"; retryable = $true; message = "credential ACL could not be read" }
                    } else {
                        $AclUnresolved = $false
                        $BroadAccess = $false
                        [string[]]$RuleLines = @($Acl.Access | ForEach-Object {
                            $Rule = $_
                            $Sid = try {
                                $Rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
                            } catch {
                                $AclUnresolved = $true
                                "unresolved:" + [string]$Rule.IdentityReference
                            }
                            if ($Sid -in @("S-1-1-0", "S-1-5-11", "S-1-5-32-545") -and
                                $Rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow) {
                                $UnsafeMask = [Security.AccessControl.FileSystemRights]::Read -bor
                                    [Security.AccessControl.FileSystemRights]::Write -bor
                                    [Security.AccessControl.FileSystemRights]::Modify -bor
                                    [Security.AccessControl.FileSystemRights]::FullControl
                                if (($Rule.FileSystemRights -band $UnsafeMask) -ne 0) { $BroadAccess = $true }
                            }
                            "$Sid|$([int]$Rule.AccessControlType)|$([int64]$Rule.FileSystemRights)|$([int]$Rule.InheritanceFlags)|$([int]$Rule.PropagationFlags)|$($Rule.IsInherited)"
                        })
                        if ($RuleLines.Count -gt 1) { [Array]::Sort($RuleLines, [StringComparer]::Ordinal) }
                        $AclFingerprint = Get-TextSha256 (($RuleLines -join "`n") + "`n")
                        $AclAccess = if ($BroadAccess) { "broad-access" } elseif ($AclUnresolved) { "unknown" } else { "restricted" }
                        if ($BroadAccess) {
                            $AclErrors += @{ code = "acl_broad_access"; severity = "warning"; retryable = $false; message = "credential ACL grants broad read or write access" }
                        }
                        if ($AclUnresolved) {
                            $AclErrors += @{ code = "acl_identity_unresolved"; severity = "warning"; retryable = $false; message = "credential ACL contains an identity that could not be resolved to a SID" }
                        }
                    }
                    Add-Record -Kind "auth_artifact" -Id $Name -Status $(if ($AclErrors.Count -eq 0) { "present" } else { "partial" }) -Confidence "medium" -Data @{
                        tool = $Name
                        path = Limit-Text $Path
                        strategy = $Strategy
                        portability = $Portability
                        type = "file"
                        owner = Limit-Text $Acl.Owner
                        acl_inheritance_protected = $Acl.AreAccessRulesProtected
                        acl_access = $AclAccess
                        acl_fingerprint = if ($null -eq $AclFingerprint) { $null } else {
                            @{ algorithm = "sha256"; value = $AclFingerprint; scope = $(if ($AclUnresolved) { "normalized-access-rules" } else { "canonical-sid-access-rules" }) }
                        }
                        size = $Item.Length
                        mtime = $Item.LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
                        digest = @{ algorithm = "sha256"; value = $Hash; scope = "raw-bytes" }
                        health = $Health.health
                        verify_exit_code = $Health.verify_exit_code
                    } -Evidence @(@{ source = "filesystem"; method = "metadata+sha256+acl" }) -Errors $AclErrors
                }
            } else {
                Add-Record -Kind "auth_artifact" -Id $Name -Status "absent" -Confidence "medium" -Data @{
                    tool = $Name; path = Limit-Text $Path; strategy = $Strategy
                    portability = $Portability
                    health = "not-run"; verify_exit_code = $null
                }
            }
        }
    }
}

if (Test-Section "projects") {
    $DevRoot = Resolve-UserPath ([string]$Machine.dev_root)
    if ([string]::IsNullOrWhiteSpace($DevRoot)) {
        Add-Record -Kind "error" -Id "projects:dev-root" -Status "unavailable" -Confidence "high" -Errors @(
            @{ code = "dev_root_missing"; severity = "error"; retryable = $false; message = "project inventory requires a configured dev_root" }
        )
    } elseif ($null -ne $Config.projects) {
        foreach ($Property in $Config.projects.PSObject.Properties) {
            $Definition = $Property.Value
            $Groups = @($Definition.groups)
            if ($Groups.Count -gt 0 -and @($Groups | Where-Object { Test-ExactMember $HostGroups $_ }).Count -eq 0) { continue }
            $Name = Limit-Text $Property.Name
            $Path = Join-Path $DevRoot ([string]$Definition.path)
            if (Test-Path -LiteralPath $Path -PathType Container) {
                try {
                    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { throw "git is not installed" }
                    $HeadLines = @(& git -C $Path rev-parse HEAD 2>$null)
                    $GitSucceeded = $?
                    $GitExitCode = $LASTEXITCODE
                    $Head = ($HeadLines | Select-Object -First 1)
                    if (-not $GitSucceeded -or
                        ($null -ne $GitExitCode -and $GitExitCode -ne 0) -or
                        [string]::IsNullOrWhiteSpace($Head)) {
                        throw "not a Git checkout"
                    }
                    $Tree = (& git -C $Path rev-parse "HEAD^{tree}" 2>$null | Select-Object -First 1)
                    $Branch = (& git -C $Path symbolic-ref --short -q HEAD 2>$null | Select-Object -First 1)
                    if ([string]::IsNullOrWhiteSpace($Branch)) { $Branch = "detached" }
                    $Origin = (& git -C $Path remote get-url origin 2>$null | Select-Object -First 1)
                    $Dirty = @(& git -C $Path status --porcelain 2>$null).Count
                    $ExpectedSource = Get-SafeRemote ([string]$Definition.source)
                    $SafeOrigin = Get-SafeRemote $Origin
                    $OriginMatches = (Get-CanonicalGitSource $ExpectedSource) -eq (Get-CanonicalGitSource $SafeOrigin)
                    $Upstream = (& git -C $Path rev-parse --abbrev-ref --symbolic-full-name "@{upstream}" 2>$null | Select-Object -First 1)
                    $Ahead = 0
                    $Behind = 0
                    $SyncState = "local-no-upstream"
                    if (-not [string]::IsNullOrWhiteSpace($Upstream)) {
                        $Counts = ((& git -C $Path rev-list --left-right --count ("HEAD..." + $Upstream) 2>$null | Select-Object -First 1) -split '\s+')
                        if ($Counts.Count -ge 2) {
                            $Ahead = [int]$Counts[0]
                            $Behind = [int]$Counts[1]
                        }
                        $SyncState = if ($Ahead -gt 0 -and $Behind -gt 0) {
                            "local-tracking-diverged"
                        } elseif ($Ahead -gt 0) {
                            "local-tracking-ahead"
                        } elseif ($Behind -gt 0) {
                            "local-tracking-behind"
                        } else {
                            "local-tracking-up-to-date"
                        }
                    }
                    $Readiness = if ($SyncState -eq "local-tracking-diverged") {
                        "diverged"
                    } elseif ($Branch -eq "detached") {
                        "detached"
                    } elseif (-not $OriginMatches) {
                        "wrong-origin"
                    } elseif ($Dirty -gt 0) {
                        "dirty"
                    } else {
                        "ready"
                    }
                    $CodexRequired = [bool]$Definition.codex
                    Add-Record -Kind "project" -Id $Name -Status $(if ($Readiness -eq "ready") { "present" } else { "partial" }) -Confidence "high" -Data @{
                        name = $Name
                        path = Limit-Text $Path
                        expected_source = $ExpectedSource
                        origin = $SafeOrigin
                        origin_matches = $OriginMatches
                        head = Limit-Text $Head
                        tree = Limit-Text $Tree
                        branch = Limit-Text $Branch
                        upstream = Limit-Text $Upstream
                        ahead = $Ahead
                        behind = $Behind
                        sync_state = $SyncState
                        tracking_freshness = "unknown"
                        dirty_count = $Dirty
                        repository_readiness = $Readiness
                        codex_required = $CodexRequired
                        codex_saved_project_status = $(if ($CodexRequired) { "requires-controller-check" } else { "not-required" })
                    } -Evidence @(@{ source = "git"; method = "rev-parse+status" })
                } catch {
                    Add-Record -Kind "project" -Id $Name -Status "partial" -Confidence "high" -Data @{
                        name = $Name; path = Limit-Text $Path; expected_source = Get-SafeRemote ([string]$Definition.source)
                    } -Errors @(@{ code = "not_git_repository"; severity = "error"; retryable = $false; message = "configured path is not a readable Git checkout" })
                }
            } else {
                Add-Record -Kind "project" -Id $Name -Status "absent" -Confidence "high" -Data @{
                    name = $Name; path = Limit-Text $Path; expected_source = Get-SafeRemote ([string]$Definition.source)
                }
            }
        }
    }
}

if (Test-Section "startup") {
    try {
        foreach ($Task in @(Get-ScheduledTask -ErrorAction Stop)) {
            $Triggers = @($Task.Triggers | ForEach-Object {
                $ClassName = $_.CimClass.CimClassName
                if ($ClassName -match 'BootTrigger$') { "boot" }
                elseif ($ClassName -match 'LogonTrigger$') { "logon" }
            } | Where-Object { $_ } | Sort-Object -Unique)
            if ($Triggers.Count -eq 0) { continue }
            $TaskId = (Limit-Text $Task.TaskPath) + (Limit-Text $Task.TaskName)
            $Info = try { Get-ScheduledTaskInfo -InputObject $Task -ErrorAction Stop } catch { $null }
            $DefinitionXml = try { Export-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath -ErrorAction Stop } catch { "" }
            $Actions = @($Task.Actions | ForEach-Object {
                @{
                    execute = Limit-Text $_.Execute
                    arguments_digest = if ([string]::IsNullOrEmpty([string]$_.Arguments)) { $null } else { Get-TextSha256 ([string]$_.Arguments) }
                    working_directory = Limit-Text $_.WorkingDirectory
                }
            })
            Add-Record -Kind "startup_task" -Id $TaskId -Status "present" -Confidence "high" -Data @{
                scheduler = "windows-scheduled-task"
                scope = "system-or-user"
                path = Limit-Text $Task.TaskPath
                label = Limit-Text $Task.TaskName
                enabled = $Task.Settings.Enabled
                state = Limit-Text $Task.State
                triggers = $Triggers
                actions = $Actions
                next_run = Limit-Text $Info.NextRunTime
                last_run = Limit-Text $Info.LastRunTime
                last_result = $Info.LastTaskResult
                definition_digest = if ([string]::IsNullOrEmpty($DefinitionXml)) {
                    $null
                } else {
                    @{ algorithm = "sha256"; value = Get-TextSha256 $DefinitionXml; scope = "task-xml" }
                }
            } -Evidence @(@{ source = "scheduler"; method = "Get-ScheduledTask" })
        }
    } catch {
        Add-Record -Kind "error" -Id "startup:scheduled-tasks" -Status "unavailable" -Confidence "high" -Errors @(
            @{ code = "scheduler_query_failed"; severity = "warning"; retryable = $true; message = "scheduled task inventory failed" }
        )
    }
    foreach ($StartupDefinition in @(
        @{ scope = "user"; path = [Environment]::GetFolderPath("Startup") },
        @{ scope = "common"; path = [Environment]::GetFolderPath("CommonStartup") }
    )) {
        if ([string]::IsNullOrWhiteSpace($StartupDefinition.path) -or
            -not (Test-Path -LiteralPath $StartupDefinition.path -PathType Container)) { continue }
        foreach ($Item in @(Get-ChildItem -LiteralPath $StartupDefinition.path -File -Force -ErrorAction SilentlyContinue)) {
            Add-Record -Kind "startup_task" -Id ("startup-folder:" + $StartupDefinition.scope + ":" + (Limit-Text $Item.Name)) -Status "present" -Confidence "high" -Data @{
                scheduler = "windows-startup-folder"
                scope = $StartupDefinition.scope
                label = Limit-Text $Item.Name
                source_definition_path = Limit-Text $Item.FullName
                definition_mtime = $Item.LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
                definition_digest = @{
                    algorithm = "sha256"
                    value = (Get-FileHash -LiteralPath $Item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                    scope = "raw-bytes"
                }
            } -Evidence @(@{ source = "filesystem"; method = "startup-folder-scan" })
        }
    }
    foreach ($RunKey in @(
        @{ scope = "user"; path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" },
        @{ scope = "user-once"; path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce" },
        @{ scope = "machine"; path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run" },
        @{ scope = "machine-once"; path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce" }
    )) {
        if (-not (Test-Path -LiteralPath $RunKey.path)) { continue }
        $Values = Get-ItemProperty -LiteralPath $RunKey.path -ErrorAction SilentlyContinue
        foreach ($Property in @($Values.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$' })) {
            $CommandValue = [string]$Property.Value
            Add-Record -Kind "startup_task" -Id ("run-key:" + $RunKey.scope + ":" + (Limit-Text $Property.Name)) -Status "present" -Confidence "high" -Data @{
                scheduler = "windows-run-key"
                scope = $RunKey.scope
                label = Limit-Text $Property.Name
                source_definition_path = $RunKey.path
                definition_digest = @{
                    algorithm = "sha256"
                    value = Get-TextSha256 $CommandValue
                    scope = "registry-value"
                }
            } -Evidence @(@{ source = "registry"; method = "run-key-name+value-hash" })
        }
    }
}

if (Test-Section "chezmoi") {
    $Chezmoi = Get-Command chezmoi -ErrorAction SilentlyContinue
    $SourcePath = if (-not [string]::IsNullOrWhiteSpace($env:CHEZMOI_SOURCE_DIR)) {
        Resolve-UserPath $env:CHEZMOI_SOURCE_DIR
    } elseif ($null -ne $Chezmoi) {
        $ResolvedSource = (& chezmoi source-path 2>$null | Select-Object -First 1)
        if ([string]::IsNullOrWhiteSpace($ResolvedSource)) { Join-Path $HOME ".local/share/chezmoi" } else { $ResolvedSource }
    } else {
        Join-Path $HOME ".local/share/chezmoi"
    }
    if (Test-Path -LiteralPath $SourcePath -PathType Container) {
        try {
            $HeadLines = @(& git -C $SourcePath rev-parse HEAD 2>$null)
            $GitSucceeded = $?
            $GitExitCode = $LASTEXITCODE
            $Head = ($HeadLines | Select-Object -First 1)
            if (-not $GitSucceeded -or
                ($null -ne $GitExitCode -and $GitExitCode -ne 0) -or
                [string]::IsNullOrWhiteSpace($Head)) {
                throw "chezmoi source is not a Git repository"
            }
            $Dirty = @(& git -C $SourcePath status --porcelain 2>$null).Count
            Add-Record -Kind "file" -Id "chezmoi:source" -Status $(if ($Dirty -eq 0) { "present" } else { "partial" }) -Confidence "medium" -Data @{
                role = "chezmoi-source"
                path = Limit-Text $SourcePath
                head = Limit-Text $Head
                dirty_count = $Dirty
            } -Evidence @(@{ source = "git"; method = "rev-parse+status" })
        } catch {
            Add-Record -Kind "file" -Id "chezmoi:source" -Status "partial" -Confidence "medium" -Data @{
                role = "chezmoi-source"; path = Limit-Text $SourcePath
            } -Errors @(@{ code = "not_git_repository"; severity = "warning"; retryable = $false; message = "chezmoi source is not a readable Git checkout" })
        }
    } else {
        Add-Record -Kind "file" -Id "chezmoi:source" -Status "absent" -Confidence "medium" -Data @{
            role = "chezmoi-source"; path = Limit-Text $SourcePath
        }
    }
    if ($null -eq $Chezmoi) {
        Add-Record -Kind "chezmoi_state" -Id "live" -Status "absent" -Confidence "high" -Data @{ tool_available = $false }
    } else {
        $StatusFile = Join-Path ([IO.Path]::GetTempPath()) ("machine-utilities-chezmoi-" + [Guid]::NewGuid().ToString("N"))
        try {
            $StatusOutput = @(& chezmoi status 2>$null)
            $ChezmoiSucceeded = $?
            $ChezmoiExitCode = $LASTEXITCODE
            if (-not $ChezmoiSucceeded -or ($null -ne $ChezmoiExitCode -and $ChezmoiExitCode -ne 0)) {
                throw "chezmoi status failed"
            }
            $StatusText = if ($StatusOutput.Count -gt 0) { ($StatusOutput -join "`n") + "`n" } else { "" }
            [IO.File]::WriteAllText($StatusFile, $StatusText, [Text.UTF8Encoding]::new($false))
            $StatusLines = @(Get-Content -LiteralPath $StatusFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $Codes = @($StatusLines | Group-Object { if ($_.Length -ge 2) { $_.Substring(0, 2) } else { $_ } } |
                Sort-Object Name | ForEach-Object { @{ code = Limit-Text $_.Name; count = $_.Count } })
            Add-Record -Kind "chezmoi_state" -Id "live" -Status "present" -Confidence "high" -Data @{
                source_path = Limit-Text $SourcePath
                drift_count = $StatusLines.Count
                status_codes = $Codes
                status_digest = @{
                    algorithm = "sha256"
                    value = (Get-FileHash -LiteralPath $StatusFile -Algorithm SHA256).Hash.ToLowerInvariant()
                    scope = "chezmoi-status-output"
                }
            } -Evidence @(@{ source = "chezmoi"; method = "source-path+status" })
        } catch {
            Add-Record -Kind "chezmoi_state" -Id "live" -Status "unavailable" -Confidence "high" -Data @{
                source_path = Limit-Text $SourcePath
            } -Errors @(@{ code = "chezmoi_status_failed"; severity = "warning"; retryable = $true; message = "chezmoi status failed" })
        } finally {
            Remove-Item -LiteralPath $StatusFile -Force -ErrorAction SilentlyContinue
        }
    }
}

$HasProblems = $script:HasProblems
Add-Record -Kind "operation" -Id "collect" -Status $(if ($HasProblems) { "partial" } else { "present" }) -Confidence "high" -Data @{
    run_id = $SnapshotId
    host_id = $HostId
    scope = $Sections
    phase = "collect"
    operation_status = $(if ($HasProblems) { "partial" } else { "completed" })
    transport = Limit-Text $Machine.transport
    task_id = $null
    correlation_id = $null
}

$script:Records |
    Sort-Object host_id, kind, id |
    ForEach-Object {
        if (-not (Test-BoundedStrings $_)) { throw "Inventory record contains an oversized string" }
        $Json = $_ | ConvertTo-Json -Compress -Depth 10
        if ([Text.Encoding]::UTF8.GetByteCount($Json) -gt 65536) { throw "Inventory record exceeds 65536 bytes" }
        $Json
    }
