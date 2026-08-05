[CmdletBinding(DefaultParameterSetName = "Task")]
param(
    [Parameter(Mandatory = $true, ParameterSetName = "Task")]
    [ValidateSet("windows-user-s4u-v1")][string]$Context,
    [Parameter(Mandatory = $true, ParameterSetName = "SelfTest")][switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:Ascii = [Text.Encoding]::ASCII
$script:Utf8 = [Text.UTF8Encoding]::new($false, $true)
$script:MaximumManifestBytes = 4194304
$script:MaximumPayloadBytes = 67108864
$script:FixtureMode = $false
$script:FixtureProfileRootId = "1" * 64
$script:FixtureCommitFailureAfter = -1
$script:HandlerKinds = @(
    "json-scalar", "managed-file", "marketplace-desired-record", "marketplace-file",
    "standalone-skill-file", "toml-scalar")

function Get-Sha256Bytes([byte[]]$Bytes) {
    $Hasher = [Security.Cryptography.SHA256]::Create()
    try { return (($Hasher.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") }) -join "") }
    finally { $Hasher.Dispose() }
}

function Get-Sha256Text([string]$Text) {
    return Get-Sha256Bytes ([Text.Encoding]::UTF8.GetBytes($Text))
}

function ConvertFrom-CanonicalAsciiBytes([byte[]]$Bytes, [int]$MaximumBytes, [string]$Label) {
    if ($Bytes.Count -lt 1 -or $Bytes.Count -gt $MaximumBytes -or $Bytes[-1] -ne 10) { throw "invalid_$Label" }
    foreach ($Byte in $Bytes) {
        if ($Byte -ne 10 -and ($Byte -lt 32 -or $Byte -gt 126)) { throw "invalid_$Label" }
    }
    $Text = $script:Ascii.GetString($Bytes)
    if ($Text.Contains("`r")) { throw "invalid_$Label" }
    return [string[]]@($Text.Substring(0, $Text.Length - 1).Split("`n"))
}

function ConvertTo-CanonicalAsciiBytes([string[]]$Lines) {
    foreach ($Line in $Lines) { if ($Line -notmatch '^[\x20-\x7e]*$') { throw "non_ascii_record" } }
    return $script:Ascii.GetBytes(($Lines -join "`n") + "`n")
}

function Test-Digest([string]$Value) { return $Value -cmatch '^[0-9a-f]{64}$' }
function Test-Token([string]$Value) { return $Value -cmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$' }
function Test-Atom([string]$Value) { return $Value -cmatch '^[A-Za-z0-9][A-Za-z0-9._:+@,-]{0,255}$' }

function Read-FixedFields([string[]]$Lines, [string[]]$Names, [string]$Header, [string]$Trailer, [string]$Label) {
    if ($Lines.Count -ne $Names.Count + 2 -or $Lines[0] -cne $Header -or $Lines[-1] -cne $Trailer) {
        throw "invalid_$Label"
    }
    $Result = [ordered]@{}
    for ($Index = 0; $Index -lt $Names.Count; $Index++) {
        $Parts = $Lines[$Index + 1].Split('|')
        if ($Parts.Count -ne 2 -or $Parts[0] -cne $Names[$Index] -or $Result.Contains($Parts[0])) {
            throw "invalid_$Label"
        }
        $Result[$Parts[0]] = $Parts[1]
    }
    return $Result
}

function ConvertTo-BoundedUInt([string]$Value, [long]$Maximum, [string]$Reason, [bool]$Positive = $false) {
    [long]$Parsed = 0
    if ($Value -notmatch '^(0|[1-9][0-9]{0,18})$' -or
        -not [long]::TryParse($Value, [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$Parsed) -or
        $Parsed -gt $Maximum -or ($Positive -and $Parsed -lt 1)) { throw $Reason }
    return $Parsed
}

function Test-ManagedRelativePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 512 -or
        $Path.StartsWith('/') -or $Path.StartsWith('\') -or $Path.Contains('\') -or
        $Path.Contains(':') -or $Path.Contains("`0") -or $Path.Contains('//')) { return $false }
    $Segments = $Path.Split('/')
    $Reserved = '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$'
    foreach ($Segment in $Segments) {
        if ($Segment -in @("", ".", "..") -or $Segment.EndsWith('.') -or $Segment.EndsWith(' ') -or
            $Segment -match $Reserved -or $Segment -notmatch '^[A-Za-z0-9._@+ -]+$') { return $false }
    }
    $Folded = $Path.ToLowerInvariant()
    foreach ($Denied in @(
        ".codex/auth.json", ".codex/plugins/cache/", ".codex/sessions/", ".codex/browser/",
        ".codex/history", ".codex/internal", "appdata/roaming/microsoft/windows/start menu/programs/startup/",
        "windows/system32/tasks/", "programdata/", ".ssh/", "credentials", "secrets",
        ".claude/.credentials", ".claude/session", ".claude/history", ".claude/projects/")) {
        if ($Folded -eq $Denied.TrimEnd('/') -or $Folded.StartsWith($Denied)) { return $false }
    }
    $Segments = $Path.Split('/')
    $StandaloneSkillFile = $Segments.Count -ge 4 -and
        $Segments[0].ToLowerInvariant() -ceq ".codex" -and
        $Segments[1].ToLowerInvariant() -ceq "skills" -and
        $Segments[2] -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
    return $Folded.StartsWith(".codex/machine-utilities/managed/") -or
        $Folded.StartsWith(".codex/machine-utilities/marketplace-stage/") -or
        $StandaloneSkillFile -or
        $Folded -match '^\.codex/settings(?:\.[a-z0-9._-]+)?\.json$' -or
        $Folded -match '^\.codex/config(?:\.[a-z0-9._-]+)?\.toml$' -or
        $Folded -ceq ".claude/settings.json"
}

function Assert-HandlerDestination([string]$Path, [string]$Handler) {
    if ($Handler -notin $script:HandlerKinds -or -not (Test-ManagedRelativePath $Path)) {
        throw "unsupported_profile_destination"
    }
    $Folded = $Path.ToLowerInvariant()
    $Expected = switch ($Handler) {
        "json-scalar" { $Folded -match '^\.codex/settings(?:\.[a-z0-9._-]+)?\.json$' -or
            $Folded -ceq ".claude/settings.json" }
        "toml-scalar" { $Folded -match '^\.codex/config(?:\.[a-z0-9._-]+)?\.toml$' }
        "standalone-skill-file" {
            $Parts = $Path.Split('/')
            $Parts.Count -ge 4 -and $Parts[0].ToLowerInvariant() -ceq ".codex" -and
                $Parts[1].ToLowerInvariant() -ceq "skills" -and
                $Parts[2] -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
        }
        "marketplace-file" { $Folded.StartsWith(".codex/machine-utilities/marketplace-stage/") }
        "marketplace-desired-record" { $Folded -eq ".codex/machine-utilities/managed/marketplace.desired" }
        "managed-file" { $Folded.StartsWith(".codex/machine-utilities/managed/") }
    }
    if (-not $Expected) { throw "handler_destination_mismatch" }
}

function Get-CompiledEntryContract([string]$Path, [string]$Handler) {
    Assert-HandlerDestination $Path $Handler
    $Folded = $Path.ToLowerInvariant()
    switch ($Handler) {
        "json-scalar" {
            if ($Folded -ceq ".claude/settings.json") {
                return [pscustomobject]@{ Artifact = "claude-code-settings"; Manager = "claude";
                    LogicalIdentity = "claude-settings" }
            }
            return [pscustomobject]@{ Artifact = "codex-settings"; Manager = "codex";
                LogicalIdentity = "codex-settings" }
        }
        "toml-scalar" {
            return [pscustomobject]@{ Artifact = "codex-settings"; Manager = "codex";
                LogicalIdentity = "codex-settings" }
        }
        "standalone-skill-file" {
            $Parts = $Path.Split('/'); $Skill = $Parts[2].ToLowerInvariant()
            return [pscustomobject]@{ Artifact = $Skill; Manager = "standalone";
                LogicalIdentity = "standalone-skill-file:$(Get-Sha256Text $Folded)" }
        }
        "marketplace-desired-record" {
            return [pscustomobject]@{ Artifact = "marketplace-desired"; Manager = "fleet-agents";
                LogicalIdentity = "marketplace-desired" }
        }
        "marketplace-file" {
            $Parts = $Path.Split('/')
            if ($Parts.Count -lt 5 -or -not (Test-Token $Parts[3])) { throw "handler_identity_mismatch" }
            $Marketplace = $Parts[3].ToLowerInvariant()
            return [pscustomobject]@{ Artifact = $Marketplace; Manager = "fleet-agents";
                LogicalIdentity = "marketplace-file:$(Get-Sha256Text $Folded)" }
        }
        "managed-file" {
            $Parts = $Path.Split('/')
            if ($Parts.Count -lt 5 -or -not (Test-Token $Parts[3])) { throw "handler_identity_mismatch" }
            $Artifact = $Parts[3].ToLowerInvariant()
            return [pscustomobject]@{ Artifact = $Artifact; Manager = "machine-utilities";
                LogicalIdentity = "managed-file:$(Get-Sha256Text $Folded)" }
        }
    }
    throw "handler_identity_mismatch"
}

function Assert-CompiledEntryIdentity([string]$Path, [string]$Handler, [string]$Artifact,
    [string]$Manager, [string]$LogicalIdentity) {
    $Expected = Get-CompiledEntryContract $Path $Handler
    if ($Artifact -cne $Expected.Artifact -or $Manager -cne $Expected.Manager -or
        $LogicalIdentity -cne $Expected.LogicalIdentity) { throw "handler_identity_mismatch" }
}

function Read-EntryMap([byte[]]$Bytes) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes $script:MaximumManifestBytes "entry_map"
    if ($Lines.Count -lt 2 -or $Lines[0] -cne "profile-entry-map|1" -or $Lines[-1] -cne "end-entry-map|") {
        throw "invalid_entry_map"
    }
    $Entries = New-Object Collections.Generic.List[object]
    $SeenPaths = @{}; $Previous = ""
    foreach ($Line in @($Lines | Select-Object -Skip 1 | Select-Object -SkipLast 1)) {
        $Parts = $Line.Split('|')
        if ($Parts.Count -ne 6 -or $Parts[0] -cne "entry" -or
            [StringComparer]::Ordinal.Compare($Previous, $Line) -ge 0 -or
            -not (Test-Atom $Parts[3]) -or -not (Test-Atom $Parts[4]) -or -not (Test-Atom $Parts[5])) {
            throw "invalid_entry_map"
        }
        Assert-CompiledEntryIdentity $Parts[1] $Parts[2] $Parts[3] $Parts[4] $Parts[5]
        $Key = $Parts[1].ToLowerInvariant()
        if ($SeenPaths.ContainsKey($Key)) { throw "case_colliding_destination" }
        $SeenPaths[$Key] = $true; $Previous = $Line
        [void]$Entries.Add([pscustomobject]@{ Path = $Parts[1]; Handler = $Parts[2];
            Artifact = $Parts[3]; Manager = $Parts[4]; LogicalIdentity = $Parts[5] })
    }
    return [pscustomobject]@{ Entries = $Entries; ByPath = $SeenPaths; Digest = Get-Sha256Bytes $Bytes }
}

function Read-MarketplaceSet([byte[]]$Bytes) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes $script:MaximumManifestBytes "profile_marketplace_set"
    if ($Lines.Count -lt 2 -or $Lines[0] -cne "profile-marketplace-set|1" -or
        $Lines[-1] -cne "end-marketplace-set|") { throw "invalid_profile_marketplace_set" }
    $Files = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    $Plugins = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $InsensitivePlugins = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $Records = New-Object Collections.Generic.List[object]
    $Previous = ""
    foreach ($Line in @($Lines | Select-Object -Skip 1 | Select-Object -SkipLast 1)) {
        if (($Previous.Length -gt 0 -and [StringComparer]::Ordinal.Compare($Previous, $Line) -ge 0) -or
            $Line.Length -gt 2048) { throw "invalid_profile_marketplace_set" }
        $Parts = $Line.Split('|')
        if ($Parts[0] -ceq "file") {
            if ($Parts.Count -ne 3 -or -not (Test-Digest $Parts[2])) {
                throw "invalid_profile_marketplace_set"
            }
            $Contract = Get-CompiledEntryContract $Parts[1] "marketplace-file"
            if ($Files.ContainsKey($Parts[1])) { throw "invalid_profile_marketplace_set" }
            $Record = [pscustomobject]@{ Kind = "file"; Path = $Parts[1]; Sha256 = $Parts[2]
                Marketplace = $Contract.Artifact; Line = $Line }
            $Files.Add($Parts[1], $Record); [void]$Records.Add($Record)
        } elseif ($Parts[0] -ceq "plugin") {
            if ($Parts.Count -ne 4 -or
                $Parts[1] -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or
                $Parts[2] -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or
                -not (Test-Digest $Parts[3]) -or -not $Plugins.Add($Line) -or
                -not $InsensitivePlugins.Add("$($Parts[1])@$($Parts[2])")) {
                throw "invalid_profile_marketplace_set"
            }
            [void]$Records.Add([pscustomobject]@{ Kind = "plugin"; Plugin = $Parts[1]
                Marketplace = $Parts[2]; Sha256 = $Parts[3]; Line = $Line })
        } else { throw "invalid_profile_marketplace_set" }
        $Previous = $Line
    }
    return [pscustomobject]@{ Files = $Files; Plugins = $Plugins; Records = $Records.ToArray()
        PluginCount = $Plugins.Count; Digest = Get-Sha256Bytes $Bytes }
}

function Get-EmptyMarketplaceSet {
    return Read-MarketplaceSet (ConvertTo-CanonicalAsciiBytes @(
        "profile-marketplace-set|1", "end-marketplace-set|"))
}

function Assert-MarketplaceAuthorization([object]$EntryMap, [object]$MarketplaceSet) {
    $MarketplaceEntries = @($EntryMap.Entries | Where-Object {
        $_.Handler -in @("marketplace-file", "marketplace-desired-record") })
    if (($MarketplaceEntries.Count -eq 0 -and $MarketplaceSet.Records.Count -ne 0) -or
        ($MarketplaceEntries.Count -ne 0 -and $MarketplaceSet.Records.Count -eq 0)) {
        throw "profile_marketplace_set_binding_mismatch"
    }
    $MapFiles = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($Entry in @($MarketplaceEntries | Where-Object { $_.Handler -ceq "marketplace-file" })) {
        $MapFiles.Add($Entry.Path, $Entry)
        if (-not $MarketplaceSet.Files.ContainsKey($Entry.Path) -or
            $MarketplaceSet.Files[$Entry.Path].Path -cne $Entry.Path) {
            throw "profile_marketplace_set_binding_mismatch"
        }
    }
    foreach ($Record in $MarketplaceSet.Files.Values) {
        if (-not $MapFiles.ContainsKey($Record.Path) -or $MapFiles[$Record.Path].Path -cne $Record.Path) {
            throw "profile_marketplace_set_binding_mismatch"
        }
    }
    $DesiredEntries = @($MarketplaceEntries | Where-Object { $_.Handler -ceq "marketplace-desired-record" })
    if (($DesiredEntries.Count -eq 0 -and $MarketplaceSet.PluginCount -ne 0) -or
        ($DesiredEntries.Count -ne 1 -and $MarketplaceSet.PluginCount -ne 0) -or
        ($DesiredEntries.Count -eq 1 -and $MarketplaceSet.PluginCount -eq 0)) {
        throw "profile_marketplace_set_binding_mismatch"
    }
    $Marketplaces = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($Record in $MarketplaceSet.Files.Values) { [void]$Marketplaces.Add($Record.Marketplace) }
    foreach ($Record in @($MarketplaceSet.Records | Where-Object { $_.Kind -ceq "plugin" })) {
        if (-not $Marketplaces.Contains($Record.Marketplace)) {
            throw "profile_marketplace_set_binding_mismatch"
        }
    }
}

function Read-ProfileManifest([byte[]]$Bytes) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes $script:MaximumManifestBytes "profile_manifest"
    if ($Lines.Count -lt 10 -or $Lines[0] -cne "profile-bundle|1" -or $Lines[-1] -cne "end-bundle|") {
        throw "invalid_profile_manifest"
    }
    $HeaderNames = @("request-id", "action-id", "policy-token", "target-sid", "profile-root-id",
        "entry-count", "payload-length", "payload-sha256")
    $Header = [ordered]@{}
    for ($Index = 0; $Index -lt $HeaderNames.Count; $Index++) {
        $Parts = $Lines[$Index + 1].Split('|')
        if ($Parts.Count -ne 2 -or $Parts[0] -cne $HeaderNames[$Index]) { throw "invalid_profile_manifest" }
        $Header[$Parts[0]] = $Parts[1]
    }
    if ($Header.'request-id' -notmatch '^request-[0-9a-f]{32}$' -or
        $Header.'action-id' -notin @("profile.apply-managed-bundle.v1", "profile.inventory-managed-state.v1") -or
        -not (Test-Token $Header.'policy-token') -or
        $Header.'target-sid' -notmatch '^S-[0-9]+(?:-[0-9]+){1,14}$' -or
        -not (Test-Digest $Header.'profile-root-id') -or -not (Test-Digest $Header.'payload-sha256')) {
        throw "invalid_profile_manifest"
    }
    $EntryCount = ConvertTo-BoundedUInt $Header.'entry-count' 100000 "invalid_profile_manifest"
    $PayloadLength = ConvertTo-BoundedUInt $Header.'payload-length' $script:MaximumPayloadBytes "invalid_profile_manifest"
    $EntryLines = @($Lines | Select-Object -Skip 9 | Select-Object -SkipLast 1)
    if ($EntryLines.Count -ne $EntryCount) { throw "invalid_profile_manifest" }
    $Entries = New-Object Collections.Generic.List[object]
    $PreviousPath = ""; $SeenPaths = @{}; [long]$NextOffset = 0
    for ($Index = 0; $Index -lt $EntryLines.Count; $Index++) {
        $Line = $EntryLines[$Index]; $Parts = $Line.Split('|')
        if ($Parts.Count -ne 14 -or $Parts[0] -cne "entry" -or [string]$Parts[1] -cne [string]$Index -or
            ($PreviousPath.Length -gt 0 -and [StringComparer]::Ordinal.Compare($PreviousPath, $Parts[2]) -ge 0)) {
            throw "invalid_profile_manifest"
        }
        Assert-CompiledEntryIdentity $Parts[2] $Parts[3] $Parts[4] $Parts[5] $Parts[6]
        if (-not (Test-Atom $Parts[4]) -or -not (Test-Atom $Parts[5]) -or -not (Test-Atom $Parts[6])) {
            throw "invalid_profile_manifest"
        }
        if ($Parts[7] -notin @("delete", "observe", "write")) { throw "invalid_profile_manifest" }
        $Offset = ConvertTo-BoundedUInt $Parts[8] $PayloadLength "invalid_profile_manifest"
        $Length = ConvertTo-BoundedUInt $Parts[9] $PayloadLength "invalid_profile_manifest"
        if ($Offset -ne $NextOffset -or $Offset + $Length -gt $PayloadLength -or -not (Test-Digest $Parts[10]) -or
            $Parts[11] -notin @("present", "absent") -or
            ($Parts[11] -ceq "present" -and -not (Test-Digest $Parts[12])) -or
            ($Parts[11] -ceq "absent" -and $Parts[12] -cne "-") -or
            ($Parts[13] -cne "-" -and -not (Test-Atom $Parts[13])) -or
            ($Parts[11] -ceq "present" -and
                $Parts[13] -cne (Get-CompiledEntryContract $Parts[2] $Parts[3]).Manager) -or
            ($Parts[11] -ceq "absent" -and $Parts[13] -cne "-") -or
            ($Parts[7] -in @("delete", "observe") -and
                ($Length -ne 0 -or $Parts[10] -cne (Get-Sha256Bytes ([byte[]]@()))))) {
            throw "invalid_profile_manifest"
        }
        $Key = $Parts[2].ToLowerInvariant()
        if ($SeenPaths.ContainsKey($Key)) { throw "case_colliding_destination" }
        $SeenPaths[$Key] = $true; $PreviousPath = $Parts[2]
        $NextOffset += $Length
        [void]$Entries.Add([pscustomobject]@{
            Index = $Index; Path = $Parts[2]; Handler = $Parts[3]; Artifact = $Parts[4];
            Manager = $Parts[5]; LogicalIdentity = $Parts[6]; Operation = $Parts[7]
            Offset = $Offset; Length = $Length; Sha256 = $Parts[10]
            ExpectedPresence = $Parts[11]; ExpectedSha256 = $Parts[12]; ExpectedManager = $Parts[13]
        })
    }
    if ($NextOffset -ne $PayloadLength) { throw "invalid_profile_manifest" }
    return [pscustomobject]@{ Header = $Header; Entries = $Entries; Digest = Get-Sha256Bytes $Bytes;
        PayloadLength = $PayloadLength }
}

function Read-Handoff([byte[]]$Bytes) {
    $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 4096 "profile_handoff"
    $Fields = Read-FixedFields $Lines @(
        "request-id", "action-id", "policy-token", "target-sid", "profile-root-id",
        "bundle-length", "bundle-sha256", "entry-map-sha256", "marketplace-set-sha256", "max-entries", "max-bytes",
        "delete-mode", "request-precondition-sha256"
    ) "windows-profile-handoff|1" "end-handoff|" "profile_handoff"
    if ($Fields.'request-id' -notmatch '^request-[0-9a-f]{32}$' -or
        $Fields.'action-id' -notin @("profile.apply-managed-bundle.v1", "profile.inventory-managed-state.v1",
            "profile.readiness-probe.v1") -or
        -not (Test-Token $Fields.'policy-token') -or
        $Fields.'target-sid' -notmatch '^S-[0-9]+(?:-[0-9]+){1,14}$' -or
        -not (Test-Digest $Fields.'profile-root-id') -or
        @($Fields.'bundle-sha256', $Fields.'entry-map-sha256', $Fields.'marketplace-set-sha256',
            $Fields.'request-precondition-sha256' |
            Where-Object { -not (Test-Digest $_) }).Count -ne 0 -or
        $Fields.'delete-mode' -notin @("managed-only", "managed-and-prune")) { throw "invalid_profile_handoff" }
    return [pscustomobject]@{ Fields = $Fields
        BundleLength = ConvertTo-BoundedUInt $Fields.'bundle-length' ($script:MaximumManifestBytes + $script:MaximumPayloadBytes + 16) "invalid_profile_handoff"
        MaxEntries = ConvertTo-BoundedUInt $Fields.'max-entries' 100000 "invalid_profile_handoff" $true
        MaxBytes = ConvertTo-BoundedUInt $Fields.'max-bytes' 1073741824 "invalid_profile_handoff" $true }
}

function Read-ProfileBundleContainer([byte[]]$Bytes) {
    if ($Bytes.Count -lt 16) { throw "invalid_profile_bundle_container" }
    [byte[]]$ManifestLengthBytes = $Bytes[0..7]
    [byte[]]$PayloadLengthBytes = $Bytes[8..15]
    if ([BitConverter]::IsLittleEndian) {
        [Array]::Reverse($ManifestLengthBytes); [Array]::Reverse($PayloadLengthBytes)
    }
    [uint64]$ManifestLength = [BitConverter]::ToUInt64($ManifestLengthBytes, 0)
    [uint64]$PayloadLength = [BitConverter]::ToUInt64($PayloadLengthBytes, 0)
    if ($ManifestLength -lt 1 -or $ManifestLength -gt $script:MaximumManifestBytes -or
        $PayloadLength -gt $script:MaximumPayloadBytes -or
        (16 + $ManifestLength + $PayloadLength) -ne $Bytes.Count) { throw "invalid_profile_bundle_container" }
    [byte[]]$ManifestBytes = $Bytes[16..(15 + [int]$ManifestLength)]
    [byte[]]$PayloadBytes = if ($PayloadLength -eq 0) { @() }
        else { $Bytes[(16 + [int]$ManifestLength)..($Bytes.Count - 1)] }
    return [pscustomobject]@{ ManifestBytes = $ManifestBytes; PayloadBytes = $PayloadBytes }
}

function New-ProfileBundleContainer([byte[]]$ManifestBytes, [byte[]]$PayloadBytes) {
    [byte[]]$ManifestLength = [BitConverter]::GetBytes([uint64]$ManifestBytes.Count)
    [byte[]]$PayloadLength = [BitConverter]::GetBytes([uint64]$PayloadBytes.Count)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($ManifestLength); [Array]::Reverse($PayloadLength) }
    $Stream = [IO.MemoryStream]::new()
    try {
        $Stream.Write($ManifestLength); $Stream.Write($PayloadLength); $Stream.Write($ManifestBytes); $Stream.Write($PayloadBytes)
        return $Stream.ToArray()
    } finally { $Stream.Dispose() }
}

function Assert-ContentForHandler([object]$Entry, [byte[]]$Bytes, [object]$MarketplaceSet = $null) {
    if ($Bytes.Count -gt 16777216) { throw "invalid_profile_content" }
    switch ($Entry.Handler) {
        "json-scalar" {
            try { $Text = $script:Utf8.GetString($Bytes) } catch { throw "invalid_profile_content" }
            if ($Text.Contains([char]0)) { throw "invalid_profile_content" }
            try {
                $Document = [Text.Json.JsonDocument]::Parse($Text)
                try {
                    if ($Document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
                        throw "invalid_profile_content"
                    }
                    $Allowed = if ($Entry.Manager -ceq "claude") {
                        @("remoteControlAtStartup", "switchModelsOnFlag", "model", "effortLevel",
                            "availableModels", "fallbackModel", "autoUpdatesChannel", "agentPushNotifEnabled")
                    } else { @("model", "model_reasoning_effort", "service_tier",
                            "check_for_update_on_startup", "cli_auth_credentials_store") }
                    $Seen = @{}
                    foreach ($Property in $Document.RootElement.EnumerateObject()) {
                        if ($Property.Name -cnotin $Allowed -or $Seen.ContainsKey($Property.Name)) {
                            throw "invalid_profile_content"
                        }
                        $Seen[$Property.Name] = $true
                        if ($Property.Name -ceq "availableModels") {
                            if ($Property.Value.ValueKind -ne [Text.Json.JsonValueKind]::Array -or
                                @($Property.Value.EnumerateArray() | Where-Object {
                                    $_.ValueKind -ne [Text.Json.JsonValueKind]::String -or
                                    [string]::IsNullOrWhiteSpace($_.GetString()) }).Count -ne 0) {
                                throw "invalid_profile_content"
                            }
                        } elseif ($Property.Name -in @("remoteControlAtStartup", "switchModelsOnFlag",
                            "agentPushNotifEnabled", "check_for_update_on_startup")) {
                            if ($Property.Value.ValueKind -notin @([Text.Json.JsonValueKind]::True,
                                [Text.Json.JsonValueKind]::False)) { throw "invalid_profile_content" }
                        } elseif ($Property.Name -ceq "autoUpdatesChannel") {
                            if ($Property.Value.ValueKind -ne [Text.Json.JsonValueKind]::String -or
                                $Property.Value.GetString() -cnotin @("latest", "stable")) { throw "invalid_profile_content" }
                        } elseif ($Property.Name -ceq "cli_auth_credentials_store") {
                            if ($Property.Value.ValueKind -ne [Text.Json.JsonValueKind]::String -or
                                $Property.Value.GetString() -cnotin @("file", "keyring", "auto")) {
                                throw "invalid_profile_content"
                            }
                        } elseif ($Property.Name -ceq "fallbackModel") {
                            if ($Property.Value.ValueKind -ne [Text.Json.JsonValueKind]::Null -and
                                ($Property.Value.ValueKind -ne [Text.Json.JsonValueKind]::String -or
                                [string]::IsNullOrWhiteSpace($Property.Value.GetString()))) {
                                throw "invalid_profile_content"
                            }
                        } elseif ($Property.Value.ValueKind -ne [Text.Json.JsonValueKind]::String -or
                            [string]::IsNullOrWhiteSpace($Property.Value.GetString())) {
                            throw "invalid_profile_content"
                        }
                    }
                } finally { $Document.Dispose() }
            } catch { throw "invalid_profile_content" }
        }
        "toml-scalar" {
            try { $Text = $script:Utf8.GetString($Bytes) } catch { throw "invalid_profile_content" }
            if ($Text.Contains([char]0)) { throw "invalid_profile_content" }
            if ($Text -notmatch '^(?<key>model|model_reasoning_effort|service_tier|check_for_update_on_startup|cli_auth_credentials_store)\s*=\s*(?<value>true|false|"[^"\r\n]+")\r?\n?$') {
                throw "invalid_profile_content"
            }
            $Key = $Matches.key; $Value = $Matches.value
            if (($Key -ceq "check_for_update_on_startup" -and $Value -notin @("true", "false")) -or
                ($Key -ceq "cli_auth_credentials_store" -and $Value -notin @('"file"', '"keyring"', '"auto"')) -or
                ($Key -notin @("check_for_update_on_startup", "cli_auth_credentials_store") -and
                    -not $Value.StartsWith('"'))) { throw "invalid_profile_content" }
        }
        "marketplace-desired-record" {
            if ($null -eq $MarketplaceSet) { throw "profile_marketplace_set_binding_mismatch" }
            $Lines = ConvertFrom-CanonicalAsciiBytes $Bytes 65536 "marketplace_desired"
            if ($Lines.Count -lt 2 -or $Lines[0] -cne "marketplace-desired|1" -or
                $Lines[-1] -cne "end-marketplace-desired|") { throw "invalid_profile_content" }
            $Previous = ""
            foreach ($Line in @($Lines | Select-Object -Skip 1 | Select-Object -SkipLast 1)) {
                if ($Line -notmatch '^plugin\|[A-Za-z0-9][A-Za-z0-9._-]{0,127}\|[A-Za-z0-9][A-Za-z0-9._-]{0,127}\|[0-9a-f]{64}$' -or
                    ($Previous.Length -gt 0 -and [StringComparer]::Ordinal.Compare($Previous, $Line) -ge 0) -or
                    -not $MarketplaceSet.Plugins.Contains($Line)) {
                    throw "invalid_profile_content"
                }
                $Previous = $Line
            }
        }
        "marketplace-file" {
            if ($null -eq $MarketplaceSet -or -not $MarketplaceSet.Files.ContainsKey($Entry.Path) -or
                $MarketplaceSet.Files[$Entry.Path].Path -cne $Entry.Path -or
                $MarketplaceSet.Files[$Entry.Path].Sha256 -cne (Get-Sha256Bytes $Bytes)) {
                throw "invalid_profile_content"
            }
        }
        default { }
    }
}

function Initialize-ProfileNativeTypes {
    if ("MachineUtilitiesProfileNative" -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public sealed class MachineUtilitiesHeldDirectory : IDisposable
{
    public SafeFileHandle Handle { get; private set; }
    public string FinalPath { get; private set; }
    public uint VolumeSerial { get; private set; }
    public ulong FileId { get; private set; }

    internal MachineUtilitiesHeldDirectory(SafeFileHandle handle, string finalPath, uint volumeSerial, ulong fileId)
    {
        Handle = handle; FinalPath = finalPath; VolumeSerial = volumeSerial; FileId = fileId;
    }

    public void Dispose() { if (Handle != null) Handle.Dispose(); }
}

public sealed class MachineUtilitiesRegularFile
{
    public bool Exists { get; internal set; }
    public byte[] Bytes { get; internal set; }
}

public sealed class MachineUtilitiesStagedFile
{
    public SafeFileHandle Handle { get; internal set; }
    public string TemporaryPath { get; internal set; }
    public bool Committed { get; internal set; }
    public bool Closed { get; internal set; }
}

public static class MachineUtilitiesProfileNative
{
    const uint FILE_READ_ATTRIBUTES = 0x80;
    const uint GENERIC_READ = 0x80000000;
    const uint GENERIC_WRITE = 0x40000000;
    const uint DELETE = 0x00010000;
    const uint FILE_SHARE_READ = 1;
    const uint FILE_SHARE_WRITE = 2;
    const uint FILE_SHARE_DELETE = 4;
    const uint CREATE_NEW = 1;
    const uint OPEN_EXISTING = 3;
    const uint FILE_ATTRIBUTE_DIRECTORY = 0x10;
    const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x400;
    const uint FILE_ATTRIBUTE_TEMPORARY = 0x100;
    const uint FILE_FLAG_WRITE_THROUGH = 0x80000000;
    const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;

    [StructLayout(LayoutKind.Sequential)]
    struct BY_HANDLE_FILE_INFORMATION
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security,
        uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle handle, out BY_HANDLE_FILE_INFORMATION info);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, char[] path, uint length, uint flags);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(SafeFileHandle handle, IntPtr buffer, uint count, out uint written, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool FlushFileBuffers(SafeFileHandle handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFileInformationByHandle(SafeFileHandle handle, int infoClass, IntPtr info, uint size);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool DeleteFileW(string path);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateDirectoryW(string path, IntPtr security);

    static Win32Exception Error(string operation) { return new Win32Exception(Marshal.GetLastWin32Error(), operation); }

    static BY_HANDLE_FILE_INFORMATION Information(SafeFileHandle handle)
    {
        BY_HANDLE_FILE_INFORMATION info;
        if (!GetFileInformationByHandle(handle, out info)) throw Error("profile_path_information_failed");
        return info;
    }

    static string FinalPath(SafeFileHandle handle)
    {
        char[] buffer = new char[32768];
        uint length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Length, 0);
        if (length == 0 || length >= buffer.Length) throw Error("profile_final_path_failed");
        string value = new string(buffer, 0, (int)length);
        if (value.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) return @"\\" + value.Substring(8);
        return value.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase) ? value.Substring(4) : value;
    }

    static void AssertInside(string finalPath, string rootFinalPath)
    {
        string root = Path.GetFullPath(rootFinalPath).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        string candidate = Path.GetFullPath(finalPath);
        if (!candidate.StartsWith(root, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("profile_path_escape");
    }

    public static MachineUtilitiesHeldDirectory OpenDirectory(string path)
    {
        SafeFileHandle handle = CreateFileW(path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);
        if (handle.IsInvalid) { handle.Dispose(); throw Error("profile_directory_open_failed"); }
        try
        {
            BY_HANDLE_FILE_INFORMATION info = Information(handle);
            if ((info.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
                (info.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
                throw new InvalidOperationException("profile_reparse_or_collision");
            ulong fileId = ((ulong)info.FileIndexHigh << 32) | info.FileIndexLow;
            return new MachineUtilitiesHeldDirectory(handle, FinalPath(handle), info.VolumeSerialNumber, fileId);
        }
        catch { handle.Dispose(); throw; }
    }

    public static MachineUtilitiesRegularFile ReadRegularFile(string path, string rootFinalPath)
    {
        SafeFileHandle handle = CreateFileW(path, GENERIC_READ | FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_DELETE, IntPtr.Zero, OPEN_EXISTING,
            FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error(); handle.Dispose();
            if (error == 2 || error == 3) return new MachineUtilitiesRegularFile { Exists = false, Bytes = new byte[0] };
            throw new Win32Exception(error, "profile_file_open_failed");
        }
        using (handle)
        {
            BY_HANDLE_FILE_INFORMATION info = Information(handle);
            if ((info.FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0 ||
                info.NumberOfLinks != 1) throw new InvalidOperationException("invalid_live_profile_state");
            AssertInside(FinalPath(handle), rootFinalPath);
            using (FileStream stream = new FileStream(handle, FileAccess.Read))
            using (MemoryStream output = new MemoryStream())
            {
                stream.CopyTo(output);
                return new MachineUtilitiesRegularFile { Exists = true, Bytes = output.ToArray() };
            }
        }
    }

    public static bool CreateDirectoryExclusive(string path)
    {
        if (CreateDirectoryW(path, IntPtr.Zero)) return true;
        int error = Marshal.GetLastWin32Error();
        if (error == 80 || error == 183) return false;
        throw new Win32Exception(error, "profile_directory_create_failed");
    }

    static void RenameByHandle(SafeFileHandle source, SafeFileHandle parent, string leaf)
    {
        byte[] name = System.Text.Encoding.Unicode.GetBytes(leaf);
        int rootOffset = IntPtr.Size == 8 ? 8 : 4;
        int lengthOffset = rootOffset + IntPtr.Size;
        int nameOffset = lengthOffset + 4;
        int size = nameOffset + name.Length;
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try
        {
            for (int i = 0; i < size; i++) Marshal.WriteByte(buffer, i, 0);
            Marshal.WriteInt32(buffer, 0, 1); // FILE_RENAME_FLAG_REPLACE_IF_EXISTS
            Marshal.WriteIntPtr(buffer, rootOffset, parent.DangerousGetHandle());
            Marshal.WriteInt32(buffer, lengthOffset, name.Length);
            Marshal.Copy(name, 0, IntPtr.Add(buffer, nameOffset), name.Length);
            if (!SetFileInformationByHandle(source, 22, buffer, (uint)size))
            {
                int error = Marshal.GetLastWin32Error();
                if (error != 87 || !SetFileInformationByHandle(source, 3, buffer, (uint)size))
                    throw new Win32Exception(error == 87 ? Marshal.GetLastWin32Error() : error,
                        "profile_atomic_replace_failed");
            }
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    public static MachineUtilitiesStagedFile StageFile(MachineUtilitiesHeldDirectory parent,
        string parentPath, byte[] bytes)
    {
        string temporary = Path.Combine(parentPath, ".machine-utilities-" + Guid.NewGuid().ToString("N"));
        SafeFileHandle handle = CreateFileW(temporary, GENERIC_READ | GENERIC_WRITE | DELETE,
            FILE_SHARE_READ | FILE_SHARE_DELETE, IntPtr.Zero, CREATE_NEW,
            FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_WRITE_THROUGH | FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);
        if (handle.IsInvalid) { handle.Dispose(); throw Error("profile_temporary_create_failed"); }
        try
        {
            AssertInside(FinalPath(handle), parent.FinalPath);
            GCHandle pin = default(GCHandle);
            try
            {
                if (bytes.Length > 0)
                {
                    pin = GCHandle.Alloc(bytes, GCHandleType.Pinned);
                    int offset = 0;
                    while (offset < bytes.Length)
                    {
                        uint written;
                        if (!WriteFile(handle, IntPtr.Add(pin.AddrOfPinnedObject(), offset),
                            (uint)(bytes.Length - offset), out written, IntPtr.Zero) || written == 0)
                            throw Error("profile_write_failed");
                        offset += (int)written;
                    }
                }
            }
            finally { if (pin.IsAllocated) pin.Free(); }
            if (!FlushFileBuffers(handle)) throw Error("profile_flush_failed");
            return new MachineUtilitiesStagedFile { Handle = handle, TemporaryPath = temporary };
        }
        catch
        {
            handle.Dispose();
            if (File.Exists(temporary)) DeleteFileW(temporary);
            throw;
        }
    }

    public static void CommitStagedFile(MachineUtilitiesHeldDirectory parent, string leaf,
        MachineUtilitiesStagedFile staged)
    {
        if (String.IsNullOrEmpty(leaf) || leaf.IndexOfAny(new char[] { '\\', '/', ':' }) >= 0)
            throw new InvalidOperationException("invalid_profile_leaf");
        if (staged == null || staged.Closed || staged.Committed || staged.Handle == null || staged.Handle.IsInvalid)
            throw new InvalidOperationException("invalid_profile_stage");
        RenameByHandle(staged.Handle, parent.Handle, leaf);
        staged.Committed = true;
    }

    public static void CloseStagedFile(MachineUtilitiesStagedFile staged)
    {
        if (staged == null || staged.Closed) return;
        if (staged.Handle != null) staged.Handle.Dispose();
        if (!staged.Committed && File.Exists(staged.TemporaryPath) && !DeleteFileW(staged.TemporaryPath))
            throw Error("profile_temporary_cleanup_failed");
        staged.Closed = true;
    }

    public static void AtomicReplace(MachineUtilitiesHeldDirectory parent, string parentPath, string leaf, byte[] bytes)
    {
        MachineUtilitiesStagedFile staged = StageFile(parent, parentPath, bytes);
        try { CommitStagedFile(parent, leaf, staged); }
        finally { CloseStagedFile(staged); }
    }

    public static void DeleteRegularFile(string path, string rootFinalPath)
    {
        SafeFileHandle handle = CreateFileW(path, DELETE | FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, IntPtr.Zero, OPEN_EXISTING,
            FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error(); handle.Dispose();
            if (error == 2 || error == 3) return;
            throw new Win32Exception(error, "profile_delete_open_failed");
        }
        using (handle)
        {
            BY_HANDLE_FILE_INFORMATION info = Information(handle);
            if ((info.FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0 ||
                info.NumberOfLinks != 1) throw new InvalidOperationException("invalid_live_profile_state");
            AssertInside(FinalPath(handle), rootFinalPath);
            IntPtr disposition = Marshal.AllocHGlobal(1);
            try
            {
                Marshal.WriteByte(disposition, 1);
                if (!SetFileInformationByHandle(handle, 4, disposition, 1)) throw Error("profile_delete_failed");
            }
            finally { Marshal.FreeHGlobal(disposition); }
        }
    }
}
'@
}

function Get-RootIdentity([object]$RootHandle, [string]$TargetSid) {
    if ($script:FixtureMode) { return $script:FixtureProfileRootId }
    $Record = "profile-root-identity|1`ntarget-sid|$TargetSid`nfinal-path|$($RootHandle.FinalPath.ToUpperInvariant())" +
        "`nvolume-serial|$($RootHandle.VolumeSerial.ToString('x8'))`nfile-id|$($RootHandle.FileId.ToString('x16'))`nend-profile-root|`n"
    return Get-Sha256Text $Record
}

function New-ManagedPathSession([string]$ProfileRoot, [string]$TargetSid, [string]$ExpectedRootId) {
    $FullRoot = [IO.Path]::GetFullPath($ProfileRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if (-not [IO.Directory]::Exists($FullRoot)) { throw "profile_root_missing" }
    $Handles = New-Object Collections.Generic.List[object]
    $ByPath = @{}
    if ($IsWindows -and -not $script:FixtureMode) {
        Initialize-ProfileNativeTypes
        $RootHandle = [MachineUtilitiesProfileNative]::OpenDirectory($FullRoot)
        [void]$Handles.Add($RootHandle); $ByPath[$FullRoot.ToLowerInvariant()] = $RootHandle
    } else {
        $RootItem = Get-Item -LiteralPath $FullRoot -Force
        if (($RootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "profile_reparse_point" }
        $RootHandle = [pscustomobject]@{ FinalPath = $FullRoot; VolumeSerial = 0; FileId = 0 }
        $ByPath[$FullRoot.ToLowerInvariant()] = $RootHandle
    }
    $ObservedRootId = Get-RootIdentity $RootHandle $TargetSid
    if ($ObservedRootId -cne $ExpectedRootId -or (-not $script:FixtureMode -and -not (Test-Digest $ExpectedRootId))) {
        foreach ($Handle in $Handles) { $Handle.Dispose() }
        throw "profile_root_identity_drift"
    }
    return [pscustomobject]@{ RootPath = $FullRoot; RootHandle = $RootHandle; RootId = $ObservedRootId;
        Handles = $Handles; ByPath = $ByPath }
}

function Close-ManagedPathSession([object]$Session) {
    if ($null -eq $Session) { return }
    for ($Index = $Session.Handles.Count - 1; $Index -ge 0; $Index--) { $Session.Handles[$Index].Dispose() }
}

function Resolve-ManagedDestination([object]$Session, [string]$RelativePath, [bool]$CreateParents = $false,
    [object]$CreatedParents = $null) {
    if (-not (Test-ManagedRelativePath $RelativePath)) { throw "unsupported_profile_destination" }
    $Segments = $RelativePath.Split('/')
    $Current = $Session.RootPath
    for ($Index = 0; $Index -lt $Segments.Count - 1; $Index++) {
        $Current = Join-Path $Current $Segments[$Index]
        $Key = [IO.Path]::GetFullPath($Current).ToLowerInvariant()
        if ($Session.ByPath.ContainsKey($Key)) { continue }
        if ([IO.File]::Exists($Current)) { throw "profile_path_collision" }
        $Created = $false
        if (-not [IO.Directory]::Exists($Current)) {
            if (-not $CreateParents) { break }
            if ($null -eq $CreatedParents) { throw "profile_created_parent_untracked" }
            if ($IsWindows -and -not $script:FixtureMode) {
                $Created = [MachineUtilitiesProfileNative]::CreateDirectoryExclusive($Current)
            } else {
                try {
                    [void][IO.Directory]::CreateDirectory($Current)
                    $Created = $true
                } catch {
                    if (-not [IO.Directory]::Exists($Current)) { throw }
                }
            }
        }
        if ($Created) { [void]$CreatedParents.Add([IO.Path]::GetFullPath($Current)) }
        if ($IsWindows -and -not $script:FixtureMode) {
            $Handle = [MachineUtilitiesProfileNative]::OpenDirectory($Current)
            $Expected = [IO.Path]::GetFullPath($Current).TrimEnd([IO.Path]::DirectorySeparatorChar)
            if (-not $Handle.FinalPath.Equals($Expected, [StringComparison]::OrdinalIgnoreCase)) {
                $Handle.Dispose(); throw "profile_ancestor_identity_drift"
            }
            [void]$Session.Handles.Add($Handle); $Session.ByPath[$Key] = $Handle
        } else {
            $Item = Get-Item -LiteralPath $Current -Force
            if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "profile_reparse_point" }
            $Session.ByPath[$Key] = [pscustomobject]@{ FinalPath = [IO.Path]::GetFullPath($Current) }
        }
    }
    $Candidate = [IO.Path]::GetFullPath((Join-Path $Session.RootPath ($RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))))
    $RootPrefix = $Session.RootPath + [IO.Path]::DirectorySeparatorChar
    if (-not $Candidate.StartsWith($RootPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Directory]::Exists($Candidate)) { throw "profile_path_escape_or_collision" }
    return $Candidate
}

function Assert-ProfileRootStable([object]$Session, [string]$TargetSid) {
    if ($script:FixtureMode) { return }
    $Observed = [MachineUtilitiesProfileNative]::OpenDirectory($Session.RootPath)
    try {
        if ((Get-RootIdentity $Observed $TargetSid) -cne $Session.RootId -or
            -not $Observed.FinalPath.Equals($Session.RootHandle.FinalPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "profile_root_identity_drift"
        }
    } finally { $Observed.Dispose() }
}

function Assert-EntryMapBinding([object]$Manifest, [object]$EntryMap) {
    $Allowed = @{}
    foreach ($Entry in $EntryMap.Entries) {
        $Allowed[$Entry.Path.ToLowerInvariant()] = $Entry
    }
    foreach ($Entry in $Manifest.Entries) {
        $Key = $Entry.Path.ToLowerInvariant()
        if (-not $Allowed.ContainsKey($Key)) { throw "unlisted_profile_destination" }
        $Expected = $Allowed[$Key]
        if ($Entry.Path -cne $Expected.Path -or $Entry.Handler -cne $Expected.Handler -or
            $Entry.Artifact -cne $Expected.Artifact -or $Entry.Manager -cne $Expected.Manager -or
            $Entry.LogicalIdentity -cne $Expected.LogicalIdentity) { throw "entry_map_binding_mismatch" }
    }
}

function Get-LiveState([object]$Session, [object]$Entry) {
    $Path = Resolve-ManagedDestination $Session $Entry.Path $false
    if ($IsWindows -and -not $script:FixtureMode) {
        $Observed = [MachineUtilitiesProfileNative]::ReadRegularFile($Path, $Session.RootHandle.FinalPath)
        if (-not $Observed.Exists) {
            return [pscustomobject]@{ Presence = "absent"; Digest = "-"; Manager = "-"; Bytes = [byte[]]@() }
        }
        return [pscustomobject]@{ Presence = "present"; Digest = Get-Sha256Bytes $Observed.Bytes;
            Manager = (Get-CompiledEntryContract $Entry.Path $Entry.Handler).Manager; Bytes = [byte[]]$Observed.Bytes }
    }
    if (-not [IO.File]::Exists($Path)) {
        return [pscustomobject]@{ Presence = "absent"; Digest = "-"; Manager = "-"; Bytes = [byte[]]@() }
    }
    $Item = Get-Item -LiteralPath $Path -Force
    if (($Item.Attributes -band ([IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Directory)) -ne 0 -or
        ($null -ne $Item.LinkType -and [string]$Item.LinkType -ne "")) { throw "invalid_live_profile_state" }
    [byte[]]$Bytes = [IO.File]::ReadAllBytes($Path)
    return [pscustomobject]@{ Presence = "present"; Digest = Get-Sha256Bytes $Bytes;
        Manager = (Get-CompiledEntryContract $Entry.Path $Entry.Handler).Manager; Bytes = $Bytes }
}

function Get-LiveStateDigest([string]$ProfileRootId, [object[]]$States) {
    if (-not (Test-Digest $ProfileRootId)) { throw "invalid_profile_root_identity" }
    $Lines = New-Object Collections.Generic.List[string]
    [void]$Lines.Add("profile-live-state|1")
    [void]$Lines.Add("profile-root-id|$ProfileRootId")
    $Previous = ""
    foreach ($State in $States) {
        if (-not (Test-ManagedRelativePath $State.Path) -or
            ($Previous.Length -gt 0 -and [StringComparer]::Ordinal.Compare($Previous, $State.Path) -ge 0) -or
            $State.Presence -notin @("present", "absent") -or
            ($State.Presence -ceq "present" -and -not (Test-Digest $State.Digest)) -or
            ($State.Presence -ceq "absent" -and $State.Digest -cne "-") -or
            ($State.Manager -cne "-" -and -not (Test-Atom $State.Manager))) {
            throw "invalid_profile_live_state"
        }
        [void]$Lines.Add("entry|$($State.Path)|$($State.Presence)|$($State.Digest)|$($State.Manager)")
        $Previous = $State.Path
    }
    [void]$Lines.Add("end-live-state|")
    return Get-Sha256Bytes (ConvertTo-CanonicalAsciiBytes $Lines)
}

function Get-ProfileStates([object]$Session, [object]$EntryMap) {
    $States = New-Object Collections.Generic.List[object]
    foreach ($Entry in $EntryMap.Entries) {
        $Live = Get-LiveState $Session $Entry
        [void]$States.Add([pscustomobject]@{ Path = $Entry.Path; Presence = $Live.Presence;
            Digest = $Live.Digest; Manager = $Live.Manager })
    }
    return $States.ToArray()
}

function Test-LiveStateMatches([object]$Live, [string]$Presence, [string]$Digest, [string]$Manager) {
    return $Live.Presence -ceq $Presence -and $Live.Digest -ceq $Digest -and $Live.Manager -ceq $Manager
}

function New-StagedManagedFile([object]$Session, [object]$Entry, [byte[]]$Bytes, [object]$CreatedParents) {
    $Destination = Resolve-ManagedDestination $Session $Entry.Path $true $CreatedParents
    $ParentPath = Split-Path -Parent $Destination
    if ($IsWindows -and -not $script:FixtureMode) {
        $Parent = $Session.ByPath[[IO.Path]::GetFullPath($ParentPath).ToLowerInvariant()]
        if ($null -eq $Parent) { throw "profile_parent_not_held" }
        return [MachineUtilitiesProfileNative]::StageFile($Parent, $ParentPath, $Bytes)
    }
    $Temporary = Join-Path $ParentPath (".machine-utilities-" + [Guid]::NewGuid().ToString("N"))
    try {
        $Stream = [IO.File]::Open($Temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $Stream.Write($Bytes, 0, $Bytes.Count); $Stream.Flush($true) } finally { $Stream.Dispose() }
        return [pscustomobject]@{ TemporaryPath = $Temporary; Committed = $false; Closed = $false }
    } catch {
        if ([IO.File]::Exists($Temporary)) { [IO.File]::Delete($Temporary) }
        throw
    }
}

function Commit-StagedManagedFile([object]$Session, [object]$Entry, [object]$Staged) {
    $Destination = Resolve-ManagedDestination $Session $Entry.Path $false
    $ParentPath = Split-Path -Parent $Destination
    if ($IsWindows -and -not $script:FixtureMode) {
        $Parent = $Session.ByPath[[IO.Path]::GetFullPath($ParentPath).ToLowerInvariant()]
        if ($null -eq $Parent) { throw "profile_parent_not_held" }
        [MachineUtilitiesProfileNative]::CommitStagedFile($Parent, [IO.Path]::GetFileName($Destination), $Staged)
        return
    }
    if ($Staged.Closed -or $Staged.Committed -or -not [IO.File]::Exists($Staged.TemporaryPath)) {
        throw "invalid_profile_stage"
    }
    [IO.File]::Move($Staged.TemporaryPath, $Destination, $true)
    $Staged.Committed = $true
}

function Close-StagedManagedFile([object]$Staged) {
    if ($null -eq $Staged) { return }
    if ($IsWindows -and -not $script:FixtureMode) {
        [MachineUtilitiesProfileNative]::CloseStagedFile($Staged)
        return
    }
    if ($Staged.Closed) { return }
    if (-not $Staged.Committed -and [IO.File]::Exists($Staged.TemporaryPath)) {
        [IO.File]::Delete($Staged.TemporaryPath)
    }
    $Staged.Closed = $true
}

function Assert-StagedManagedFile([object]$Session, [object]$Staged, [byte[]]$ExpectedBytes) {
    if ($IsWindows -and -not $script:FixtureMode) {
        $Observed = [MachineUtilitiesProfileNative]::ReadRegularFile(
            $Staged.TemporaryPath, $Session.RootHandle.FinalPath)
        if (-not $Observed.Exists -or (Get-Sha256Bytes $Observed.Bytes) -cne (Get-Sha256Bytes $ExpectedBytes) -or
            $Observed.Bytes.Count -ne $ExpectedBytes.Count) { throw "profile_stage_verification_failed" }
        return
    }
    if (-not [IO.File]::Exists($Staged.TemporaryPath)) { throw "profile_stage_verification_failed" }
    $Item = Get-Item -LiteralPath $Staged.TemporaryPath -Force
    if (($Item.Attributes -band ([IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Directory)) -ne 0) {
        throw "profile_stage_verification_failed"
    }
    [byte[]]$ObservedBytes = [IO.File]::ReadAllBytes($Staged.TemporaryPath)
    if ($ObservedBytes.Count -ne $ExpectedBytes.Count -or
        (Get-Sha256Bytes $ObservedBytes) -cne (Get-Sha256Bytes $ExpectedBytes)) {
        throw "profile_stage_verification_failed"
    }
}

function Write-ManagedFileAtomic([object]$Session, [object]$Entry, [byte[]]$Bytes,
    [object]$CreatedParents = $null) {
    $Destination = Resolve-ManagedDestination $Session $Entry.Path $true $CreatedParents
    $ParentPath = Split-Path -Parent $Destination
    if ($IsWindows -and -not $script:FixtureMode) {
        $Parent = $Session.ByPath[[IO.Path]::GetFullPath($ParentPath).ToLowerInvariant()]
        if ($null -eq $Parent) { throw "profile_parent_not_held" }
        [MachineUtilitiesProfileNative]::AtomicReplace($Parent, $ParentPath,
            [IO.Path]::GetFileName($Destination), $Bytes)
        return
    }
    $Temporary = Join-Path $ParentPath (".machine-utilities-" + [Guid]::NewGuid().ToString("N"))
    try {
        $Stream = [IO.File]::Open($Temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $Stream.Write($Bytes, 0, $Bytes.Count); $Stream.Flush($true) } finally { $Stream.Dispose() }
        [IO.File]::Move($Temporary, $Destination, $true)
    } finally { if ([IO.File]::Exists($Temporary)) { [IO.File]::Delete($Temporary) } }
}

function Remove-ManagedFile([object]$Session, [object]$Entry) {
    $Destination = Resolve-ManagedDestination $Session $Entry.Path $false
    if ($IsWindows -and -not $script:FixtureMode) {
        [MachineUtilitiesProfileNative]::DeleteRegularFile($Destination, $Session.RootHandle.FinalPath)
    } elseif ([IO.File]::Exists($Destination)) { [IO.File]::Delete($Destination) }
}

function Remove-CreatedManagedParents([string]$ProfileRoot, [object]$CreatedParents) {
    $FullRoot = [IO.Path]::GetFullPath($ProfileRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $RootPrefix = $FullRoot + [IO.Path]::DirectorySeparatorChar
    for ($Index = $CreatedParents.Count - 1; $Index -ge 0; $Index--) {
        $Path = [IO.Path]::GetFullPath([string]$CreatedParents[$Index])
        if (-not $Path.StartsWith($RootPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.File]::Exists($Path)) { throw "profile_created_parent_cleanup_failed" }
        if ([IO.Directory]::Exists($Path)) {
            $Item = Get-Item -LiteralPath $Path -Force
            if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "profile_created_parent_cleanup_failed"
            }
            [IO.Directory]::Delete($Path, $false)
        }
        if ([IO.Directory]::Exists($Path) -or [IO.File]::Exists($Path)) {
            throw "profile_created_parent_cleanup_failed"
        }
    }
}

function Get-FixtureContextEvidence {
    return [ordered]@{
        Integrity = "medium_or_lower"; Elevated = "false"; Administrators = "disabled"
        DangerousPrivileges = "none"; AuthenticatedSmb = "unavailable"; ProgramDataWrite = "denied"
        TaskWrite = "denied"; ServiceControl = "denied"; HklmWrite = "denied"; OtherProfileWrite = "denied"
    }
}

function Write-ProfileResult([object]$Handoff, [object[]]$States, [object]$ContextEvidence,
    [string]$Reason, [string]$ResultPath) {
    $PostState = Get-LiveStateDigest $Handoff.Fields.'profile-root-id' $States
    $Results = New-Object Collections.Generic.List[string]
    for ($Index = 0; $Index -lt $States.Count; $Index++) {
        $State = $States[$Index]
        [void]$Results.Add("entry|$Index|$($State.Path)|$($State.Presence)|$($State.Digest)|$($State.Manager)")
    }
    $Lines = @(
        "windows-profile-result|2", "request-id|$($Handoff.Fields.'request-id')",
        "action-id|$($Handoff.Fields.'action-id')", "target-sid|$($Handoff.Fields.'target-sid')",
        "profile-root-id|$($Handoff.Fields.'profile-root-id')",
        "context-integrity|$($ContextEvidence.Integrity)", "context-elevated|$($ContextEvidence.Elevated)",
        "context-administrators|$($ContextEvidence.Administrators)",
        "context-dangerous-privileges|$($ContextEvidence.DangerousPrivileges)",
        "context-authenticated-smb|$($ContextEvidence.AuthenticatedSmb)",
        "context-programdata-write|$($ContextEvidence.ProgramDataWrite)",
        "context-task-write|$($ContextEvidence.TaskWrite)",
        "context-service-control|$($ContextEvidence.ServiceControl)",
        "context-hklm-write|$($ContextEvidence.HklmWrite)",
        "context-other-profile-write|$($ContextEvidence.OtherProfileWrite)",
        "pre-state-sha256|$($Handoff.Fields.'request-precondition-sha256')", "post-state-sha256|$PostState",
        "state|completed", "reason|$Reason", "entry-count|$($Results.Count)") + @($Results) + @("end-result|")
    $ResultBytes = ConvertTo-CanonicalAsciiBytes $Lines
    $Directory = Split-Path -Parent $ResultPath; [void][IO.Directory]::CreateDirectory($Directory)
    $Stream = [IO.File]::Open($ResultPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $Stream.Write($ResultBytes, 0, $ResultBytes.Count); $Stream.Flush($true) } finally { $Stream.Dispose() }
}

function Write-UnsupportedContextResult([object]$Handoff, [string]$ResultPath) {
    $Bytes = ConvertTo-CanonicalAsciiBytes @(
        "windows-profile-context-result|1", "request-id|$($Handoff.Fields.'request-id')",
        "action-id|$($Handoff.Fields.'action-id')", "target-sid|$($Handoff.Fields.'target-sid')",
        "profile-root-id|$($Handoff.Fields.'profile-root-id')", "state|rejected", "reason|unsupported_context",
        "end-result|")
    $Stream = [IO.File]::Open($ResultPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $Stream.Write($Bytes, 0, $Bytes.Count); $Stream.Flush($true) } finally { $Stream.Dispose() }
}

function Write-RecoveryRequiredResult([object]$Handoff, [string]$ResultPath) {
    $Bytes = ConvertTo-CanonicalAsciiBytes @(
        "windows-profile-recovery-result|1", "request-id|$($Handoff.Fields.'request-id')",
        "action-id|$($Handoff.Fields.'action-id')", "target-sid|$($Handoff.Fields.'target-sid')",
        "profile-root-id|$($Handoff.Fields.'profile-root-id')", "state|recovery-required",
        "reason|profile_rollback_unverified", "end-result|")
    $Stream = [IO.File]::Open($ResultPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $Stream.Write($Bytes, 0, $Bytes.Count); $Stream.Flush($true) } finally { $Stream.Dispose() }
}

function Invoke-ProfileOperation {
    param([string]$ProfileRoot, [object]$Handoff, [object]$Manifest, [object]$EntryMap,
        [byte[]]$Payload, [string]$ResultPath, [object]$ContextEvidence = (Get-FixtureContextEvidence),
        [object]$MarketplaceSet = (Get-EmptyMarketplaceSet))
    if ($Manifest.Header.'request-id' -cne $Handoff.Fields.'request-id' -or
        $Manifest.Header.'action-id' -cne $Handoff.Fields.'action-id' -or
        -not (Test-Token $Handoff.Fields.'policy-token') -or
        $Manifest.Header.'policy-token' -cne $Handoff.Fields.'policy-token' -or
        $Manifest.Header.'target-sid' -cne $Handoff.Fields.'target-sid' -or
        $Manifest.Header.'profile-root-id' -cne $Handoff.Fields.'profile-root-id' -or
        $Manifest.Entries.Count -gt $Handoff.MaxEntries -or $EntryMap.Entries.Count -gt $Handoff.MaxEntries -or
        $Payload.Count -gt $Handoff.MaxBytes -or
        $Manifest.PayloadLength -ne $Payload.Count -or
        (Get-Sha256Bytes $Payload) -cne $Manifest.Header.'payload-sha256' -or
        $Handoff.Fields.'entry-map-sha256' -cne $EntryMap.Digest -or
        $Handoff.Fields.'marketplace-set-sha256' -cne $MarketplaceSet.Digest -or
        $Handoff.Fields.'request-precondition-sha256' -ceq $Handoff.Fields.'bundle-sha256' -or
        $Handoff.Fields.'request-precondition-sha256' -ceq $Manifest.Header.'payload-sha256') {
        throw "handoff_binding_mismatch"
    }
    Assert-EntryMapBinding $Manifest $EntryMap
    Assert-MarketplaceAuthorization $EntryMap $MarketplaceSet
    $ExpectedStates = @($Manifest.Entries | ForEach-Object {
        [pscustomobject]@{ Path = $_.Path; Presence = $_.ExpectedPresence;
            Digest = $_.ExpectedSha256; Manager = $_.ExpectedManager }
    })
    if ((Get-LiveStateDigest $Handoff.Fields.'profile-root-id' $ExpectedStates) -cne
        $Handoff.Fields.'request-precondition-sha256') { throw "profile_precondition_binding_mismatch" }
    if ($Handoff.Fields.'action-id' -ceq "profile.inventory-managed-state.v1" -and
        @($Manifest.Entries | Where-Object { $_.Operation -cne "observe" }).Count -ne 0) {
        throw "inventory_mutation_forbidden"
    }
    if ($Handoff.Fields.'action-id' -ceq "profile.apply-managed-bundle.v1" -and
        (@($Manifest.Entries | Where-Object { $_.Operation -ceq "observe" }).Count -ne 0 -or
        ($Handoff.Fields.'delete-mode' -ceq "managed-only" -and
            @($Manifest.Entries | Where-Object { $_.Operation -ceq "delete" }).Count -ne 0))) {
        throw "deletion_not_authorized"
    }
    $Session = $null
    $Prepared = New-Object Collections.Generic.List[object]
    $MapSnapshots = New-Object Collections.Generic.List[object]
    $CreatedParents = New-Object Collections.Generic.List[string]
    $Staged = New-Object Collections.Generic.List[object]
    $Committed = New-Object Collections.Generic.List[object]
    $MutationPhaseStarted = $false
    try {
        $Session = New-ManagedPathSession $ProfileRoot $Handoff.Fields.'target-sid' $Handoff.Fields.'profile-root-id'
        [long]$RollbackBytes = 0
        foreach ($Entry in $Manifest.Entries) {
            # Preflight is read-only. Parent creation begins only after every entry and payload slice passes.
            [void](Resolve-ManagedDestination $Session $Entry.Path $false)
            $Live = Get-LiveState $Session $Entry
            if (-not (Test-LiveStateMatches $Live $Entry.ExpectedPresence $Entry.ExpectedSha256 `
                    $Entry.ExpectedManager)) { throw "profile_precondition_drift" }
            [byte[]]$Content = if ($Entry.Length -eq 0) { @() }
                else { $Payload[$Entry.Offset..($Entry.Offset + $Entry.Length - 1)] }
            if ((Get-Sha256Bytes $Content) -cne $Entry.Sha256) { throw "profile_payload_digest_mismatch" }
            if ($Entry.Operation -ceq "write") { Assert-ContentForHandler $Entry $Content $MarketplaceSet }
            $RollbackBytes += $Live.Bytes.Count
            if ($RollbackBytes -gt $Handoff.MaxBytes) { throw "profile_rollback_capacity_exceeded" }
            [void]$Prepared.Add([pscustomobject]@{ Entry = $Entry; Bytes = $Content
                BeforePresence = $Live.Presence; BeforeDigest = $Live.Digest; BeforeManager = $Live.Manager
                BeforeBytes = [byte[]]$Live.Bytes; Staged = $null })
        }
        foreach ($Entry in $EntryMap.Entries) {
            [void](Resolve-ManagedDestination $Session $Entry.Path $false)
            $Live = Get-LiveState $Session $Entry
            [void]$MapSnapshots.Add([pscustomobject]@{ Entry = $Entry; Presence = $Live.Presence
                Digest = $Live.Digest; Manager = $Live.Manager })
        }

        $MutationPhaseStarted = $true
        foreach ($Item in $Prepared) {
            if ($Item.Entry.Operation -ceq "write") {
                $Item.Staged = New-StagedManagedFile $Session $Item.Entry $Item.Bytes $CreatedParents
                [void]$Staged.Add($Item.Staged)
                Assert-StagedManagedFile $Session $Item.Staged $Item.Bytes
            }
        }

        # This is the final read of every destination before the first ordered commit.
        foreach ($Snapshot in $MapSnapshots) {
            $Live = Get-LiveState $Session $Snapshot.Entry
            if (-not (Test-LiveStateMatches $Live $Snapshot.Presence $Snapshot.Digest $Snapshot.Manager)) {
                throw "profile_precondition_drift"
            }
        }
        Assert-ProfileRootStable $Session $Handoff.Fields.'target-sid'

        foreach ($Item in $Prepared) {
            if ($Item.Entry.Operation -ceq "delete") { Remove-ManagedFile $Session $Item.Entry }
            elseif ($Item.Entry.Operation -ceq "write") {
                Commit-StagedManagedFile $Session $Item.Entry $Item.Staged
            }
            [void]$Committed.Add($Item)
            if ($script:FixtureMode -and $script:FixtureCommitFailureAfter -ge 0 -and
                $Committed.Count -ge $script:FixtureCommitFailureAfter) {
                throw "fixture_injected_commit_failure"
            }
        }

        foreach ($Stage in $Staged) { Close-StagedManagedFile $Stage }
        foreach ($Item in $Prepared) {
            $Live = Get-LiveState $Session $Item.Entry
            $PostPresence = if ($Item.Entry.Operation -ceq "write") { "present" } else { "absent" }
            $PostDigest = if ($Item.Entry.Operation -ceq "write") { $Item.Entry.Sha256 } else { "-" }
            $PostManager = if ($Item.Entry.Operation -ceq "write") { $Item.Entry.Manager } else { "-" }
            if (-not (Test-LiveStateMatches $Live $PostPresence $PostDigest $PostManager)) {
                throw "profile_postcondition_drift"
            }
        }
        Assert-ProfileRootStable $Session $Handoff.Fields.'target-sid'
        $States = Get-ProfileStates $Session $EntryMap
        Write-ProfileResult $Handoff $States $ContextEvidence "post_state_verified" $ResultPath
    } catch {
        $Failure = $_
        if (-not $MutationPhaseStarted) { throw }
        $RecoveryErrors = New-Object Collections.Generic.List[string]
        foreach ($Stage in $Staged) {
            try { Close-StagedManagedFile $Stage }
            catch { [void]$RecoveryErrors.Add("profile_stage_cleanup_failed") }
        }
        for ($Index = $Committed.Count - 1; $Index -ge 0; $Index--) {
            $Item = $Committed[$Index]
            try {
                $Live = Get-LiveState $Session $Item.Entry
                $PostPresence = if ($Item.Entry.Operation -ceq "write") { "present" } else { "absent" }
                $PostDigest = if ($Item.Entry.Operation -ceq "write") { $Item.Entry.Sha256 } else { "-" }
                $PostManager = if ($Item.Entry.Operation -ceq "write") { $Item.Entry.Manager } else { "-" }
                if (-not (Test-LiveStateMatches $Live $PostPresence $PostDigest $PostManager)) {
                    throw "profile_rollback_target_drift"
                }
                if ($Item.BeforePresence -ceq "present") {
                    Write-ManagedFileAtomic $Session $Item.Entry $Item.BeforeBytes $CreatedParents
                } else { Remove-ManagedFile $Session $Item.Entry }
            } catch { [void]$RecoveryErrors.Add("profile_rollback_write_failed") }
        }
        try {
            foreach ($Item in $Prepared) {
                $Live = Get-LiveState $Session $Item.Entry
                if (-not (Test-LiveStateMatches $Live $Item.BeforePresence $Item.BeforeDigest $Item.BeforeManager)) {
                    throw "profile_rollback_verification_failed"
                }
            }
            Assert-ProfileRootStable $Session $Handoff.Fields.'target-sid'
        } catch { [void]$RecoveryErrors.Add("profile_rollback_verification_failed") }
        try { Close-ManagedPathSession $Session; $Session = $null }
        catch { [void]$RecoveryErrors.Add("profile_rollback_session_close_failed") }
        try { Remove-CreatedManagedParents $ProfileRoot $CreatedParents }
        catch { [void]$RecoveryErrors.Add("profile_created_parent_cleanup_failed") }
        $RecoverySession = $null
        try {
            $RecoverySession = New-ManagedPathSession $ProfileRoot $Handoff.Fields.'target-sid' `
                $Handoff.Fields.'profile-root-id'
            foreach ($Item in $Prepared) {
                $Live = Get-LiveState $RecoverySession $Item.Entry
                if (-not (Test-LiveStateMatches $Live $Item.BeforePresence $Item.BeforeDigest $Item.BeforeManager)) {
                    throw "profile_rollback_verification_failed"
                }
            }
            foreach ($CreatedParent in $CreatedParents) {
                if ([IO.Directory]::Exists($CreatedParent) -or [IO.File]::Exists($CreatedParent)) {
                    throw "profile_created_parent_cleanup_failed"
                }
            }
            Assert-ProfileRootStable $RecoverySession $Handoff.Fields.'target-sid'
        } catch { [void]$RecoveryErrors.Add("profile_rollback_verification_failed") }
        finally { Close-ManagedPathSession $RecoverySession }
        if ($RecoveryErrors.Count -ne 0) {
            try { Write-RecoveryRequiredResult $Handoff $ResultPath } catch { }
            throw "profile_recovery_required"
        }
        throw $Failure
    } finally {
        foreach ($Stage in $Staged) { try { Close-StagedManagedFile $Stage } catch { } }
        Close-ManagedPathSession $Session
    }
}

function Invoke-ProfileInventory([string]$ProfileRoot, [object]$Handoff, [object]$EntryMap, [string]$ResultPath,
    [object]$ContextEvidence = (Get-FixtureContextEvidence),
    [object]$MarketplaceSet = (Get-EmptyMarketplaceSet)) {
    if ($Handoff.Fields.'action-id' -cne "profile.inventory-managed-state.v1" -or
        -not (Test-Token $Handoff.Fields.'policy-token') -or
        $Handoff.BundleLength -ne 0 -or
        $Handoff.Fields.'bundle-sha256' -cne (Get-Sha256Bytes ([byte[]]@())) -or
        $EntryMap.Entries.Count -gt $Handoff.MaxEntries -or
        $Handoff.Fields.'entry-map-sha256' -cne $EntryMap.Digest -or
        $Handoff.Fields.'marketplace-set-sha256' -cne $MarketplaceSet.Digest) {
        throw "inventory_handoff_mismatch"
    }
    Assert-MarketplaceAuthorization $EntryMap $MarketplaceSet
    $Session = $null
    try {
        $Session = New-ManagedPathSession $ProfileRoot $Handoff.Fields.'target-sid' $Handoff.Fields.'profile-root-id'
        $States = Get-ProfileStates $Session $EntryMap
        if ((Get-LiveStateDigest $Handoff.Fields.'profile-root-id' $States) -cne
            $Handoff.Fields.'request-precondition-sha256') { throw "profile_precondition_drift" }
        Assert-ProfileRootStable $Session $Handoff.Fields.'target-sid'
        Write-ProfileResult $Handoff $States $ContextEvidence "inventory_verified" $ResultPath
    } finally { Close-ManagedPathSession $Session }
}

function Write-ProfilePreconditionProbeResult([object]$Handoff, [object[]]$States, [string]$ResultPath) {
    # This is deliberately a distinct, bounded record: readiness consumes only an
    # observed digest and never reuses the mutable profile-operation result schema.
    $PostState = Get-LiveStateDigest $Handoff.Fields.'profile-root-id' $States
    $Bytes = ConvertTo-CanonicalAsciiBytes @(
        "windows-profile-precondition-probe|1", "request-id|$($Handoff.Fields.'request-id')",
        "action-id|profile.readiness-probe.v1", "policy-token|$($Handoff.Fields.'policy-token')",
        "target-sid|$($Handoff.Fields.'target-sid')", "profile-root-id|$($Handoff.Fields.'profile-root-id')",
        "entry-map-sha256|$($Handoff.Fields.'entry-map-sha256')",
        "marketplace-set-sha256|$($Handoff.Fields.'marketplace-set-sha256')",
        "post-state-sha256|$PostState", "entry-count|$($States.Count)", "end-probe|")
    if ($Bytes.Count -gt 4096) { throw "profile_probe_result_exceeded" }
    $Stream = [IO.File]::Open($ResultPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $Stream.Write($Bytes, 0, $Bytes.Count); $Stream.Flush($true) } finally { $Stream.Dispose() }
}

function Invoke-ProfileReadinessProbe([string]$ProfileRoot, [object]$Handoff, [object]$EntryMap,
    [string]$ResultPath, [object]$MarketplaceSet = (Get-EmptyMarketplaceSet)) {
    $EmptySha256 = Get-Sha256Bytes ([byte[]]@())
    if ($Handoff.Fields.'action-id' -cne "profile.readiness-probe.v1" -or
        -not (Test-Token $Handoff.Fields.'policy-token') -or
        $Handoff.BundleLength -ne 0 -or $Handoff.Fields.'bundle-sha256' -cne $EmptySha256 -or
        $Handoff.Fields.'request-precondition-sha256' -cne $EmptySha256 -or
        $EntryMap.Entries.Count -gt $Handoff.MaxEntries -or
        $Handoff.Fields.'entry-map-sha256' -cne $EntryMap.Digest -or
        $Handoff.Fields.'marketplace-set-sha256' -cne $MarketplaceSet.Digest) {
        throw "readiness_probe_handoff_mismatch"
    }
    Assert-MarketplaceAuthorization $EntryMap $MarketplaceSet
    $Session = $null
    try {
        # This path opens only the fixed managed paths and writes only the protected
        # handoff result.  It accepts no bundle, has no mutation operation, and has
        # no network or fallback input.
        $Session = New-ManagedPathSession $ProfileRoot $Handoff.Fields.'target-sid' $Handoff.Fields.'profile-root-id'
        $States = Get-ProfileStates $Session $EntryMap
        Assert-ProfileRootStable $Session $Handoff.Fields.'target-sid'
        Write-ProfilePreconditionProbeResult $Handoff $States $ResultPath
    } finally { Close-ManagedPathSession $Session }
}

function Initialize-ProfileContextTypes {
    if ("MachineUtilitiesProfileContextNative" -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;

public sealed class MachineUtilitiesTokenEvidence
{
    public int IntegrityRid { get; internal set; }
    public bool Elevated { get; internal set; }
    public int ElevationType { get; internal set; }
    public bool AdministratorsEnabled { get; internal set; }
    public string[] EnabledPrivileges { get; internal set; }
}

public sealed class MachineUtilitiesMutationProbeResult
{
    public bool Opened { get; internal set; }
    public int ErrorCode { get; internal set; }
}

public static class MachineUtilitiesProfileContextNative
{
    const uint TOKEN_QUERY = 0x0008;
    const uint SE_GROUP_ENABLED = 0x00000004;
    const uint SE_PRIVILEGE_ENABLED = 0x00000002;
    const uint FILE_READ_ATTRIBUTES = 0x80;
    const uint FILE_ADD_FILE = 0x2;
    const uint GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_ALL = 7;
    const uint OPEN_EXISTING = 3;
    const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
    const uint SC_MANAGER_CREATE_SERVICE = 0x0002;

    [StructLayout(LayoutKind.Sequential)] struct SID_AND_ATTRIBUTES { public IntPtr Sid; public uint Attributes; }
    [StructLayout(LayoutKind.Sequential)] struct LUID { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)] struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }

    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr process, uint access, out SafeAccessTokenHandle token);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool GetTokenInformation(SafeAccessTokenHandle token, int informationClass,
        IntPtr information, int length, out int returnLength);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool LookupPrivilegeNameW(string system, ref LUID luid, StringBuilder name, ref int length);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security,
        uint creation, uint flags, IntPtr template);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr OpenSCManagerW(string machine, string database, uint access);
    [DllImport("advapi32.dll")] static extern bool CloseServiceHandle(IntPtr handle);

    static IntPtr TokenBuffer(SafeAccessTokenHandle token, int informationClass, out int size)
    {
        GetTokenInformation(token, informationClass, IntPtr.Zero, 0, out size);
        if (size <= 0) throw new Win32Exception(Marshal.GetLastWin32Error(), "profile_token_query_failed");
        IntPtr buffer = Marshal.AllocHGlobal(size);
        if (!GetTokenInformation(token, informationClass, buffer, size, out size))
        {
            int error = Marshal.GetLastWin32Error(); Marshal.FreeHGlobal(buffer);
            throw new Win32Exception(error, "profile_token_query_failed");
        }
        return buffer;
    }

    public static MachineUtilitiesTokenEvidence InspectToken()
    {
        SafeAccessTokenHandle token;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, out token))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "profile_token_open_failed");
        using (token)
        {
            int size;
            IntPtr elevation = TokenBuffer(token, 20, out size);
            IntPtr elevationType = TokenBuffer(token, 18, out size);
            IntPtr integrityBase = TokenBuffer(token, 25, out size);
            IntPtr groupsBase = TokenBuffer(token, 2, out size);
            IntPtr privilegesBase = TokenBuffer(token, 3, out size);
            try
            {
                SID_AND_ATTRIBUTES label = Marshal.PtrToStructure<SID_AND_ATTRIBUTES>(integrityBase);
                string integritySid = new SecurityIdentifier(label.Sid).Value;
                int integrityRid = Int32.Parse(integritySid.Substring(integritySid.LastIndexOf('-') + 1),
                    System.Globalization.CultureInfo.InvariantCulture);

                int groupCount = Marshal.ReadInt32(groupsBase);
                int groupOffset = IntPtr.Size;
                int groupSize = Marshal.SizeOf<SID_AND_ATTRIBUTES>();
                bool administratorsEnabled = false;
                for (int i = 0; i < groupCount; i++)
                {
                    SID_AND_ATTRIBUTES group = Marshal.PtrToStructure<SID_AND_ATTRIBUTES>(
                        IntPtr.Add(groupsBase, groupOffset + i * groupSize));
                    if (new SecurityIdentifier(group.Sid).Value == "S-1-5-32-544" &&
                        (group.Attributes & SE_GROUP_ENABLED) != 0) administratorsEnabled = true;
                }

                int privilegeCount = Marshal.ReadInt32(privilegesBase);
                int privilegeOffset = 4;
                int privilegeSize = Marshal.SizeOf<LUID_AND_ATTRIBUTES>();
                List<string> enabled = new List<string>();
                for (int i = 0; i < privilegeCount; i++)
                {
                    LUID_AND_ATTRIBUTES privilege = Marshal.PtrToStructure<LUID_AND_ATTRIBUTES>(
                        IntPtr.Add(privilegesBase, privilegeOffset + i * privilegeSize));
                    if ((privilege.Attributes & SE_PRIVILEGE_ENABLED) == 0) continue;
                    int length = 0; LookupPrivilegeNameW(null, ref privilege.Luid, null, ref length);
                    StringBuilder name = new StringBuilder(length + 1);
                    if (!LookupPrivilegeNameW(null, ref privilege.Luid, name, ref length))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "profile_privilege_name_failed");
                    enabled.Add(name.ToString());
                }
                return new MachineUtilitiesTokenEvidence {
                    IntegrityRid = integrityRid, Elevated = Marshal.ReadInt32(elevation) != 0,
                    ElevationType = Marshal.ReadInt32(elevationType),
                    AdministratorsEnabled = administratorsEnabled, EnabledPrivileges = enabled.ToArray()
                };
            }
            finally
            {
                Marshal.FreeHGlobal(elevation); Marshal.FreeHGlobal(elevationType);
                Marshal.FreeHGlobal(integrityBase); Marshal.FreeHGlobal(groupsBase);
                Marshal.FreeHGlobal(privilegesBase);
            }
        }
    }

    public static MachineUtilitiesMutationProbeResult ProbeMutationAccess(string path, bool directory)
    {
        uint access = directory ? FILE_ADD_FILE : GENERIC_WRITE;
        uint flags = FILE_FLAG_OPEN_REPARSE_POINT | (directory ? FILE_FLAG_BACKUP_SEMANTICS : 0);
        SafeFileHandle handle = CreateFileW(path, access | FILE_READ_ATTRIBUTES, FILE_SHARE_ALL,
            IntPtr.Zero, OPEN_EXISTING, flags, IntPtr.Zero);
        if (!handle.IsInvalid)
        {
            handle.Dispose();
            return new MachineUtilitiesMutationProbeResult { Opened = true, ErrorCode = 0 };
        }
        int error = Marshal.GetLastWin32Error(); handle.Dispose();
        return new MachineUtilitiesMutationProbeResult { Opened = false, ErrorCode = error };
    }

    public static bool CanCreateService()
    {
        IntPtr handle = OpenSCManagerW(null, null, SC_MANAGER_CREATE_SERVICE);
        if (handle == IntPtr.Zero)
        {
            int error = Marshal.GetLastWin32Error();
            if (error == 5) return false;
            throw new Win32Exception(error, "profile_service_canary_unavailable");
        }
        CloseServiceHandle(handle); return true;
    }
}
'@
}

function Get-ProfilePathForSid([string]$Sid) {
    $KeyPath = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid"
    $Raw = Get-ItemPropertyValue -LiteralPath $KeyPath -Name ProfileImagePath -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace([string]$Raw)) { throw "profile_root_unavailable" }
    return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$Raw)).TrimEnd('\')
}

function Get-AuthenticatedSmbCanaryEvidence([string]$ProbePath = "-", [Exception]$Failure = $null) {
    # No protected controlled-share observation is supplied to this worker. Local ADMIN$, access-denied,
    # bad credentials, generic I/O failures, and unreachable shares cannot prove authenticated SMB isolation.
    return "unavailable"
}

function Get-MutationProbeDisposition([object]$Probe) {
    if ($null -eq $Probe -or $null -eq $Probe.PSObject.Properties["Opened"] -or
        $null -eq $Probe.PSObject.Properties["ErrorCode"] -or $Probe.Opened -isnot [bool] -or
        $Probe.ErrorCode -isnot [int]) { throw "invalid_profile_write_canary_result" }
    if ([bool]$Probe.Opened) {
        if ([int]$Probe.ErrorCode -ne 0) { throw "invalid_profile_write_canary_result" }
        return "allowed"
    }
    if ([int]$Probe.ErrorCode -eq 0) { throw "invalid_profile_write_canary_result" }
    if ([int]$Probe.ErrorCode -eq 5) { return "denied" }
    return "unavailable"
}

function Assert-MutationAccessDenied([object]$Probe) {
    $Disposition = Get-MutationProbeDisposition $Probe
    if ($Disposition -ceq "denied") { return }
    if ($Disposition -ceq "allowed") { throw "unsupported_context" }
    throw "profile_write_canary_unavailable"
}

function Get-ProfileContextEvidence([string]$CurrentSid, [string]$ProgramData) {
    if (-not $IsWindows) { throw "unsupported_context" }
    Initialize-ProfileContextTypes
    $Token = [MachineUtilitiesProfileContextNative]::InspectToken()
    $Dangerous = @("SeAssignPrimaryTokenPrivilege", "SeBackupPrivilege", "SeCreatePermanentPrivilege",
        "SeCreateTokenPrivilege", "SeDebugPrivilege", "SeImpersonatePrivilege", "SeLoadDriverPrivilege",
        "SeManageVolumePrivilege", "SeRelabelPrivilege", "SeRestorePrivilege", "SeSecurityPrivilege",
        "SeTakeOwnershipPrivilege", "SeTcbPrivilege", "SeTrustedCredManAccessPrivilege")
    if ($Token.IntegrityRid -gt 8192 -or $Token.Elevated -or $Token.ElevationType -eq 2 -or
        $Token.AdministratorsEnabled -or
        @($Token.EnabledPrivileges | Where-Object { $_ -cin $Dangerous }).Count -ne 0) {
        throw "unsupported_context"
    }
    $BrokerRoot = Join-Path $ProgramData "MachineUtilities"
    $TaskPath = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)) `
        "System32\Tasks\MachineUtilitiesProfileV1"
    Assert-MutationAccessDenied ([MachineUtilitiesProfileContextNative]::ProbeMutationAccess($BrokerRoot, $true))
    Assert-MutationAccessDenied ([MachineUtilitiesProfileContextNative]::ProbeMutationAccess($TaskPath, $false))
    if ([MachineUtilitiesProfileContextNative]::CanCreateService()) { throw "unsupported_context" }
    try {
        $WritableHklm = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE", $true)
        if ($null -ne $WritableHklm) { $WritableHklm.Dispose(); throw "unsupported_context" }
    } catch [System.Security.SecurityException] { } catch [System.UnauthorizedAccessException] { }
    $OtherProfile = $null
    foreach ($ProfileKey in Get-ChildItem -LiteralPath `
        "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" -ErrorAction Stop) {
        $CandidateSid = [IO.Path]::GetFileName([string]$ProfileKey.Name)
        if ($CandidateSid -ceq $CurrentSid) { continue }
        try {
            $Candidate = Get-ProfilePathForSid $CandidateSid
            if ([IO.Directory]::Exists($Candidate)) { $OtherProfile = $Candidate; break }
        } catch { }
    }
    if ($null -eq $OtherProfile) { throw "unsupported_context" }
    Assert-MutationAccessDenied `
        ([MachineUtilitiesProfileContextNative]::ProbeMutationAccess($OtherProfile, $true))
    return [ordered]@{
        Integrity = "medium_or_lower"; Elevated = "false"; Administrators = "disabled"
        DangerousPrivileges = "none"; AuthenticatedSmb = (Get-AuthenticatedSmbCanaryEvidence)
        ProgramDataWrite = "denied"
        TaskWrite = "denied"; ServiceControl = "denied"; HklmWrite = "denied"; OtherProfileWrite = "denied"
    }
}

function Invoke-SelfTest {
    $Root = Join-Path ([IO.Path]::GetTempPath()) ("machine-utilities-profile-worker-" + [Guid]::NewGuid().ToString("N"))
    $script:FixtureMode = $true
    try {
        Initialize-ProfileNativeTypes
        Initialize-ProfileContextTypes
        $DeniedMutationProbe = [pscustomobject]@{ Opened = $false; ErrorCode = [int]5 }
        if ((Get-MutationProbeDisposition $DeniedMutationProbe) -cne "denied") {
            throw "access-denied mutation canary self-test failed"
        }
        Assert-MutationAccessDenied $DeniedMutationProbe
        $HeldHandleMutationProbe = [pscustomobject]@{ Opened = $false; ErrorCode = [int]32 }
        if ((Get-MutationProbeDisposition $HeldHandleMutationProbe) -cne "unavailable") {
            throw "sharing-violation mutation canary self-test failed"
        }
        $HeldHandleRejected = $false
        try { Assert-MutationAccessDenied $HeldHandleMutationProbe }
        catch { $HeldHandleRejected = $_.Exception.Message -eq "profile_write_canary_unavailable" }
        if (-not $HeldHandleRejected) { throw "held-handle mutation canary rejection self-test failed" }
        $AllowedMutationRejected = $false
        try { Assert-MutationAccessDenied ([pscustomobject]@{ Opened = $true; ErrorCode = [int]0 }) }
        catch { $AllowedMutationRejected = $_.Exception.Message -eq "unsupported_context" }
        if (-not $AllowedMutationRejected) { throw "allowed mutation canary self-test failed" }
        if ($IsWindows) {
            [void][IO.Directory]::CreateDirectory($Root)
            $HeldHandlePath = Join-Path $Root "held-handle.canary"
            [IO.File]::WriteAllBytes($HeldHandlePath, [byte[]]@(1))
            $HeldHandle = [IO.File]::Open($HeldHandlePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None)
            try {
                $ObservedHeldHandleProbe = [MachineUtilitiesProfileContextNative]::ProbeMutationAccess(
                    $HeldHandlePath, $false)
                if ((Get-MutationProbeDisposition $ObservedHeldHandleProbe) -cne "unavailable" -or
                    [int]$ObservedHeldHandleProbe.ErrorCode -ne 32) {
                    throw "native held-handle mutation canary self-test failed"
                }
            } finally { $HeldHandle.Dispose() }
        }
        foreach ($SmbProbe in @(
            [pscustomobject]@{ Path = "\\localhost\ADMIN$\System32\config\SAM";
                Failure = [UnauthorizedAccessException]::new("fixture") },
            [pscustomobject]@{ Path = "\\localhost\ADMIN$\System32\config\SAM";
                Failure = [IO.IOException]::new("fixture", -2147024891) },
            [pscustomobject]@{ Path = "\\unavailable\controlled";
                Failure = [IO.IOException]::new("fixture", -2147024843) })) {
            if ((Get-AuthenticatedSmbCanaryEvidence $SmbProbe.Path $SmbProbe.Failure) -cne "unavailable") {
                throw "authenticated SMB unavailable self-test failed"
            }
        }
        $FixtureRootId = $script:FixtureProfileRootId
        $ProfileRoot = Join-Path $Root "profile"; [void][IO.Directory]::CreateDirectory($ProfileRoot)
        [byte[]]$Payload = $script:Utf8.GetBytes('{"model":"gpt-fixture"}')
        $PayloadDigest = Get-Sha256Bytes $Payload
        $EntryLine = "entry|.codex/settings.json|json-scalar|codex-settings|codex|codex-settings"
        $MapBytes = ConvertTo-CanonicalAsciiBytes @("profile-entry-map|1", $EntryLine, "end-entry-map|")
        $EmptyMarketplaceSet = Get-EmptyMarketplaceSet
        $ManifestBytes = ConvertTo-CanonicalAsciiBytes @(
            "profile-bundle|1", "request-id|request-0123456789abcdef0123456789abcdef",
            "action-id|profile.apply-managed-bundle.v1", "policy-token|profile-default",
            "target-sid|S-1-5-21-1-2-3-1001", "profile-root-id|$FixtureRootId", "entry-count|1",
            "payload-length|$($Payload.Count)", "payload-sha256|$PayloadDigest",
            "entry|0|.codex/settings.json|json-scalar|codex-settings|codex|codex-settings|write|0|$($Payload.Count)|$PayloadDigest|absent|-|-",
            "end-bundle|")
        $BundleBytes = New-ProfileBundleContainer $ManifestBytes $Payload
        $AbsentPrecondition = Get-LiveStateDigest $FixtureRootId @([pscustomobject]@{
            Path = ".codex/settings.json"; Presence = "absent"; Digest = "-"; Manager = "-" })
        $HandoffBytes = ConvertTo-CanonicalAsciiBytes @(
            "windows-profile-handoff|1", "request-id|request-0123456789abcdef0123456789abcdef",
            "action-id|profile.apply-managed-bundle.v1", "policy-token|profile-default",
            "target-sid|S-1-5-21-1-2-3-1001", "profile-root-id|$FixtureRootId",
            "bundle-length|$($BundleBytes.Count)", "bundle-sha256|$(Get-Sha256Bytes $BundleBytes)",
            "entry-map-sha256|$(Get-Sha256Bytes $MapBytes)",
            "marketplace-set-sha256|$($EmptyMarketplaceSet.Digest)", "max-entries|8", "max-bytes|65536",
            "delete-mode|managed-only", "request-precondition-sha256|$AbsentPrecondition", "end-handoff|")
        $Handoff = Read-Handoff $HandoffBytes
        $Manifest = Read-ProfileManifest $ManifestBytes
        $EntryMap = Read-EntryMap $MapBytes
        $ParsedBundle = Read-ProfileBundleContainer $BundleBytes
        if ((Get-Sha256Bytes $ParsedBundle.ManifestBytes) -cne (Get-Sha256Bytes $ManifestBytes) -or
            (Get-Sha256Bytes $ParsedBundle.PayloadBytes) -cne $PayloadDigest) { throw "bundle container self-test failed" }
        $ResultPath = Join-Path $Root "result"
        $BadPreconditionBytes = $script:Ascii.GetBytes(($script:Ascii.GetString($HandoffBytes)).Replace(
            "request-precondition-sha256|$AbsentPrecondition", "request-precondition-sha256|$('f' * 64)"))
        $PreconditionRejected = $false
        try { Invoke-ProfileOperation $ProfileRoot (Read-Handoff $BadPreconditionBytes) $Manifest $EntryMap $Payload `
                (Join-Path $Root "bad-precondition-result") } catch {
            $PreconditionRejected = $_.Exception.Message -eq "profile_precondition_binding_mismatch"
        }
        if (-not $PreconditionRejected) { throw "signed precondition self-test failed" }
        $AliasedPreconditionBytes = $script:Ascii.GetBytes(($script:Ascii.GetString($HandoffBytes)).Replace(
            "request-precondition-sha256|$AbsentPrecondition", "request-precondition-sha256|$(Get-Sha256Bytes $BundleBytes)"))
        $AliasedRejected = $false
        try { Invoke-ProfileOperation $ProfileRoot (Read-Handoff $AliasedPreconditionBytes) $Manifest $EntryMap $Payload `
                (Join-Path $Root "aliased-precondition-result") } catch {
            $AliasedRejected = $_.Exception.Message -eq "handoff_binding_mismatch"
        }
        if (-not $AliasedRejected) { throw "payload/precondition separation self-test failed" }
        Invoke-ProfileOperation $ProfileRoot $Handoff $Manifest $EntryMap $Payload $ResultPath
        $Destination = Join-Path $ProfileRoot ".codex/settings.json"
        if ((Get-Sha256Bytes ([IO.File]::ReadAllBytes($Destination))) -cne $PayloadDigest -or
            -not [IO.File]::Exists($ResultPath)) { throw "profile apply self-test failed" }

        $PresentPrecondition = Get-LiveStateDigest $FixtureRootId @([pscustomobject]@{
            Path = ".codex/settings.json"; Presence = "present"; Digest = $PayloadDigest; Manager = "codex" })
        $InventoryHandoffBytes = ConvertTo-CanonicalAsciiBytes @(
            "windows-profile-handoff|1", "request-id|request-2123456789abcdef0123456789abcdef",
            "action-id|profile.inventory-managed-state.v1", "policy-token|profile-default",
            "target-sid|S-1-5-21-1-2-3-1001", "profile-root-id|$FixtureRootId", "bundle-length|0",
            "bundle-sha256|$(Get-Sha256Bytes ([byte[]]@()))", "entry-map-sha256|$(Get-Sha256Bytes $MapBytes)",
            "marketplace-set-sha256|$($EmptyMarketplaceSet.Digest)", "max-entries|8", "max-bytes|65536",
            "delete-mode|managed-only", "request-precondition-sha256|$PresentPrecondition", "end-handoff|")
        $TokenlessInventoryRejected = $false
        try {
            [void](Read-Handoff ($script:Ascii.GetBytes(($script:Ascii.GetString($InventoryHandoffBytes)).Replace(
                "policy-token|profile-default", "policy-token|-"))))
        } catch { $TokenlessInventoryRejected = $_.Exception.Message -eq "invalid_profile_handoff" }
        if (-not $TokenlessInventoryRejected) { throw "tokenless profile inventory self-test failed" }
        $InventoryResultPath = Join-Path $Root "inventory-result"
        Invoke-ProfileInventory $ProfileRoot (Read-Handoff $InventoryHandoffBytes) $EntryMap `
            $InventoryResultPath (Get-FixtureContextEvidence) $EmptyMarketplaceSet
        if ((Get-Content -Raw -LiteralPath $InventoryResultPath) -notmatch
            '^windows-profile-result\|2(?s:.*)reason\|inventory_verified') {
            throw "protected profile inventory token self-test failed"
        }

        $ProbeHandoffBytes = ConvertTo-CanonicalAsciiBytes @(
            "windows-profile-handoff|1", "request-id|request-3123456789abcdef0123456789abcdef",
            "action-id|profile.readiness-probe.v1", "policy-token|profile-default",
            "target-sid|S-1-5-21-1-2-3-1001", "profile-root-id|$FixtureRootId", "bundle-length|0",
            "bundle-sha256|$(Get-Sha256Bytes ([byte[]]@()))", "entry-map-sha256|$(Get-Sha256Bytes $MapBytes)",
            "marketplace-set-sha256|$($EmptyMarketplaceSet.Digest)", "max-entries|8", "max-bytes|65536",
            "delete-mode|managed-only", "request-precondition-sha256|$(Get-Sha256Bytes ([byte[]]@()))",
            "end-handoff|")
        $ProbeResultPath = Join-Path $Root "readiness-probe-result"
        Invoke-ProfileReadinessProbe $ProfileRoot (Read-Handoff $ProbeHandoffBytes) $EntryMap $ProbeResultPath `
            $EmptyMarketplaceSet
        $ProbeLines = ConvertFrom-CanonicalAsciiBytes ([IO.File]::ReadAllBytes($ProbeResultPath)) 4096 `
            "profile_probe_result"
        if ($ProbeLines.Count -ne 11 -or $ProbeLines[0] -cne "windows-profile-precondition-probe|1" -or
            $ProbeLines[1] -cne "request-id|request-3123456789abcdef0123456789abcdef" -or
            $ProbeLines[8] -notmatch '^post-state-sha256\|[0-9a-f]{64}$' -or $ProbeLines[-1] -cne "end-probe|") {
            throw "profile readiness probe self-test failed"
        }
        $ProbePayloadRejected = $false
        try {
            $BadProbe = $script:Ascii.GetBytes(($script:Ascii.GetString($ProbeHandoffBytes)).Replace(
                "bundle-length|0", "bundle-length|1"))
            Invoke-ProfileReadinessProbe $ProfileRoot (Read-Handoff $BadProbe) $EntryMap `
                (Join-Path $Root "readiness-probe-bad") $EmptyMarketplaceSet
        } catch { $ProbePayloadRejected = $_.Exception.Message -eq "readiness_probe_handoff_mismatch" }
        if (-not $ProbePayloadRejected) { throw "profile readiness probe payload self-test failed" }

        foreach ($Case in @(
            @("../escape", "managed-file"), @(".codex/auth.json", "managed-file"),
            @(".codex/plugins/cache/evil", "managed-file"), @("C:/absolute", "managed-file"),
            @(".codex/skills/demo/SKILL.md:ads", "standalone-skill-file"),
            @(".codex/settings.json", "standalone-skill-file"))) {
            $Rejected = $false
            try { Assert-HandlerDestination $Case[0] $Case[1] } catch { $Rejected = $true }
            if (-not $Rejected) { throw "unsafe destination self-test failed: $($Case[0])" }
        }
        $BadMap = ConvertTo-CanonicalAsciiBytes @("profile-entry-map|1",
            "entry|.codex/settings.json|standalone-skill-file|codex-settings|codex|codex-settings", "end-entry-map|")
        $SwapRejected = $false
        try { [void](Read-EntryMap $BadMap) } catch { $SwapRejected = $true }
        if (-not $SwapRejected) { throw "handler swap self-test failed" }

        $SkillFiles = @(
            [pscustomobject]@{ Path = ".codex/skills/demo/SKILL.md"; Bytes = $script:Utf8.GetBytes("# Demo") },
            [pscustomobject]@{ Path = ".codex/skills/demo/assets/icon.bin"; Bytes = [byte[]]@(0, 1, 2, 255) },
            [pscustomobject]@{ Path = ".codex/skills/demo/scripts/check.ps1"; Bytes = $script:Utf8.GetBytes("'fixture'") })
        $SkillMapLines = New-Object Collections.Generic.List[string]
        $SkillManifestLines = New-Object Collections.Generic.List[string]
        $SkillStates = New-Object Collections.Generic.List[object]
        $SkillPayloadStream = [IO.MemoryStream]::new(); [long]$SkillOffset = 0
        try {
            for ($Index = 0; $Index -lt $SkillFiles.Count; $Index++) {
                $File = $SkillFiles[$Index]; $Contract = Get-CompiledEntryContract $File.Path "standalone-skill-file"
                $FileDigest = Get-Sha256Bytes $File.Bytes
                [void]$SkillMapLines.Add("entry|$($File.Path)|standalone-skill-file|$($Contract.Artifact)|" +
                    "$($Contract.Manager)|$($Contract.LogicalIdentity)")
                [void]$SkillManifestLines.Add("entry|$Index|$($File.Path)|standalone-skill-file|" +
                    "$($Contract.Artifact)|$($Contract.Manager)|$($Contract.LogicalIdentity)|write|$SkillOffset|" +
                    "$($File.Bytes.Count)|$FileDigest|absent|-|-")
                [void]$SkillStates.Add([pscustomobject]@{ Path = $File.Path; Presence = "absent"; Digest = "-"; Manager = "-" })
                $SkillPayloadStream.Write($File.Bytes, 0, $File.Bytes.Count); $SkillOffset += $File.Bytes.Count
            }
            [byte[]]$SkillPayload = $SkillPayloadStream.ToArray()
        } finally { $SkillPayloadStream.Dispose() }
        $SkillMapBytes = ConvertTo-CanonicalAsciiBytes (@("profile-entry-map|1") + @($SkillMapLines) + @("end-entry-map|"))
        $SkillManifestBytes = ConvertTo-CanonicalAsciiBytes (@(
            "profile-bundle|1", "request-id|request-4123456789abcdef0123456789abcdef",
            "action-id|profile.apply-managed-bundle.v1", "policy-token|profile-default",
            "target-sid|S-1-5-21-1-2-3-1001", "profile-root-id|$FixtureRootId",
            "entry-count|$($SkillFiles.Count)", "payload-length|$($SkillPayload.Count)",
            "payload-sha256|$(Get-Sha256Bytes $SkillPayload)") + @($SkillManifestLines) + @("end-bundle|"))
        $SkillBundleBytes = New-ProfileBundleContainer $SkillManifestBytes $SkillPayload
        $SkillPrecondition = Get-LiveStateDigest $FixtureRootId $SkillStates.ToArray()
        $SkillHandoff = Read-Handoff (ConvertTo-CanonicalAsciiBytes @(
            "windows-profile-handoff|1", "request-id|request-4123456789abcdef0123456789abcdef",
            "action-id|profile.apply-managed-bundle.v1", "policy-token|profile-default",
            "target-sid|S-1-5-21-1-2-3-1001", "profile-root-id|$FixtureRootId",
            "bundle-length|$($SkillBundleBytes.Count)", "bundle-sha256|$(Get-Sha256Bytes $SkillBundleBytes)",
            "entry-map-sha256|$(Get-Sha256Bytes $SkillMapBytes)",
            "marketplace-set-sha256|$($EmptyMarketplaceSet.Digest)", "max-entries|8", "max-bytes|65536",
            "delete-mode|managed-only", "request-precondition-sha256|$SkillPrecondition", "end-handoff|"))
        $SkillProfileRoot = Join-Path $Root "skill-profile"; [void][IO.Directory]::CreateDirectory($SkillProfileRoot)
        Invoke-ProfileOperation $SkillProfileRoot $SkillHandoff (Read-ProfileManifest $SkillManifestBytes) `
            (Read-EntryMap $SkillMapBytes) $SkillPayload (Join-Path $Root "skill-result")
        foreach ($File in $SkillFiles) {
            $ObservedPath = Join-Path $SkillProfileRoot ($File.Path.Replace('/', [IO.Path]::DirectorySeparatorChar))
            if (-not [IO.File]::Exists($ObservedPath) -or
                (Get-Sha256Bytes ([IO.File]::ReadAllBytes($ObservedPath))) -cne (Get-Sha256Bytes $File.Bytes)) {
                throw "multi-file standalone skill self-test failed"
            }
        }

        $MarketplacePath = ".codex/machine-utilities/marketplace-stage/acme/plugin/SKILL.md"
        [byte[]]$MarketplaceContent = $script:Utf8.GetBytes("fixture marketplace snapshot")
        $MarketplaceDigest = Get-Sha256Bytes $MarketplaceContent
        $MarketplaceLogical = "marketplace-file:$(Get-Sha256Text $MarketplacePath.ToLowerInvariant())"
        $MarketplaceMap = Read-EntryMap (ConvertTo-CanonicalAsciiBytes @(
            "profile-entry-map|1",
            "entry|.codex/machine-utilities/managed/marketplace.desired|marketplace-desired-record|marketplace-desired|fleet-agents|marketplace-desired",
            "entry|$MarketplacePath|marketplace-file|acme|fleet-agents|$MarketplaceLogical",
            "end-entry-map|"))
        $MarketplaceSet = Read-MarketplaceSet (ConvertTo-CanonicalAsciiBytes @(
            "profile-marketplace-set|1", "file|$MarketplacePath|$MarketplaceDigest",
            "plugin|fixture-plugin|acme|$MarketplaceDigest", "end-marketplace-set|"))
        Assert-MarketplaceAuthorization $MarketplaceMap $MarketplaceSet
        $MarketplaceFileEntry = @($MarketplaceMap.Entries | Where-Object { $_.Handler -ceq "marketplace-file" })[0]
        Assert-ContentForHandler $MarketplaceFileEntry $MarketplaceContent $MarketplaceSet
        $DesiredEntry = @($MarketplaceMap.Entries | Where-Object { $_.Handler -ceq "marketplace-desired-record" })[0]
        Assert-ContentForHandler $DesiredEntry (ConvertTo-CanonicalAsciiBytes @(
            "marketplace-desired|1", "plugin|fixture-plugin|acme|$MarketplaceDigest",
            "end-marketplace-desired|")) $MarketplaceSet
        foreach ($Probe in @(
            [pscustomobject]@{ Entry = $MarketplaceFileEntry; Bytes = $script:Utf8.GetBytes("substituted") },
            [pscustomobject]@{ Entry = $DesiredEntry; Bytes = ConvertTo-CanonicalAsciiBytes @(
                "marketplace-desired|1", "plugin|unapproved|acme|$MarketplaceDigest",
                "end-marketplace-desired|") })) {
            $Rejected = $false
            try { Assert-ContentForHandler $Probe.Entry $Probe.Bytes $MarketplaceSet } catch { $Rejected = $true }
            if (-not $Rejected) { throw "marketplace membership self-test failed" }
        }
        $UnusedSetRejected = $false
        try { Assert-MarketplaceAuthorization $EntryMap $MarketplaceSet } catch { $UnusedSetRejected = $true }
        if (-not $UnusedSetRejected) { throw "unused marketplace set self-test failed" }

        $PreflightPayload = $script:Utf8.GetBytes("not-json")
        $PreflightDigest = Get-Sha256Bytes $PreflightPayload
        $BadManifestBytes = ConvertTo-CanonicalAsciiBytes @(
            "profile-bundle|1", "request-id|request-1123456789abcdef0123456789abcdef",
            "action-id|profile.apply-managed-bundle.v1", "policy-token|profile-default",
            "target-sid|S-1-5-21-1-2-3-1001", "profile-root-id|$FixtureRootId", "entry-count|1",
            "payload-length|$($PreflightPayload.Count)", "payload-sha256|$PreflightDigest",
            "entry|0|.codex/settings.json|json-scalar|codex-settings|codex|codex-settings|write|0|$($PreflightPayload.Count)|$PreflightDigest|present|$PayloadDigest|codex",
            "end-bundle|")
        $BadBundleBytes = New-ProfileBundleContainer $BadManifestBytes $PreflightPayload
        $PresentPrecondition = Get-LiveStateDigest $FixtureRootId @([pscustomobject]@{
            Path = ".codex/settings.json"; Presence = "present"; Digest = $PayloadDigest; Manager = "codex" })
        $BadHandoffBytes = ConvertTo-CanonicalAsciiBytes @(
            "windows-profile-handoff|1", "request-id|request-1123456789abcdef0123456789abcdef",
            "action-id|profile.apply-managed-bundle.v1", "policy-token|profile-default",
            "target-sid|S-1-5-21-1-2-3-1001", "profile-root-id|$FixtureRootId",
            "bundle-length|$($BadBundleBytes.Count)", "bundle-sha256|$(Get-Sha256Bytes $BadBundleBytes)",
            "entry-map-sha256|$(Get-Sha256Bytes $MapBytes)",
            "marketplace-set-sha256|$($EmptyMarketplaceSet.Digest)", "max-entries|8", "max-bytes|65536",
            "delete-mode|managed-only", "request-precondition-sha256|$PresentPrecondition", "end-handoff|")
        $Before = [IO.File]::ReadAllBytes($Destination)
        $ContentRejected = $false
        try { Invoke-ProfileOperation $ProfileRoot (Read-Handoff $BadHandoffBytes) `
                (Read-ProfileManifest $BadManifestBytes) $EntryMap $PreflightPayload (Join-Path $Root "bad-result")
        } catch { $ContentRejected = $true }
        if (-not $ContentRejected -or (Get-Sha256Bytes ([IO.File]::ReadAllBytes($Destination))) -cne (Get-Sha256Bytes $Before)) {
            throw "all-entry preflight self-test failed"
        }

        $TransactionalPath = ".codex/machine-utilities/managed/demo/file"
        $TransactionalContract = Get-CompiledEntryContract $TransactionalPath "managed-file"
        $TransactionalMapBytes = ConvertTo-CanonicalAsciiBytes @(
            "profile-entry-map|1",
            "entry|$TransactionalPath|managed-file|$($TransactionalContract.Artifact)|$($TransactionalContract.Manager)|$($TransactionalContract.LogicalIdentity)",
            $EntryLine, "end-entry-map|")
        $TransactionalMap = Read-EntryMap $TransactionalMapBytes
        [byte[]]$NewManagedBytes = $script:Utf8.GetBytes("fixture managed output")
        [byte[]]$ReplacementBytes = $script:Utf8.GetBytes('{"model":"gpt-replacement"}')
        [byte[]]$TransactionalPayload = @($NewManagedBytes) + @($ReplacementBytes)
        $NewManagedDigest = Get-Sha256Bytes $NewManagedBytes
        $ReplacementDigest = Get-Sha256Bytes $ReplacementBytes
        $LateMismatchManifestBytes = ConvertTo-CanonicalAsciiBytes @(
            "profile-bundle|1", "request-id|request-3123456789abcdef0123456789abcdef",
            "action-id|profile.apply-managed-bundle.v1", "policy-token|profile-default",
            "target-sid|S-1-5-21-1-2-3-1001", "profile-root-id|$FixtureRootId", "entry-count|2",
            "payload-length|$($TransactionalPayload.Count)",
            "payload-sha256|$(Get-Sha256Bytes $TransactionalPayload)",
            "entry|0|$TransactionalPath|managed-file|$($TransactionalContract.Artifact)|$($TransactionalContract.Manager)|$($TransactionalContract.LogicalIdentity)|write|0|$($NewManagedBytes.Count)|$NewManagedDigest|absent|-|-",
            "entry|1|.codex/settings.json|json-scalar|codex-settings|codex|codex-settings|write|$($NewManagedBytes.Count)|$($ReplacementBytes.Count)|$ReplacementDigest|absent|-|-",
            "end-bundle|")
        $LateMismatchBundleBytes = New-ProfileBundleContainer $LateMismatchManifestBytes $TransactionalPayload
        $LateMismatchPrecondition = Get-LiveStateDigest $FixtureRootId @(
            [pscustomobject]@{ Path = $TransactionalPath; Presence = "absent"; Digest = "-"; Manager = "-" },
            [pscustomobject]@{ Path = ".codex/settings.json"; Presence = "absent"; Digest = "-"; Manager = "-" })
        $LateMismatchHandoff = Read-Handoff (ConvertTo-CanonicalAsciiBytes @(
            "windows-profile-handoff|1", "request-id|request-3123456789abcdef0123456789abcdef",
            "action-id|profile.apply-managed-bundle.v1", "policy-token|profile-default",
            "target-sid|S-1-5-21-1-2-3-1001", "profile-root-id|$FixtureRootId",
            "bundle-length|$($LateMismatchBundleBytes.Count)",
            "bundle-sha256|$(Get-Sha256Bytes $LateMismatchBundleBytes)",
            "entry-map-sha256|$(Get-Sha256Bytes $TransactionalMapBytes)",
            "marketplace-set-sha256|$($EmptyMarketplaceSet.Digest)", "max-entries|8", "max-bytes|65536",
            "delete-mode|managed-only", "request-precondition-sha256|$LateMismatchPrecondition", "end-handoff|"))
        $TransactionalParent = Join-Path $ProfileRoot ".codex/machine-utilities"
        $LateMismatchRejected = $false
        try {
            Invoke-ProfileOperation $ProfileRoot $LateMismatchHandoff `
                (Read-ProfileManifest $LateMismatchManifestBytes) $TransactionalMap $TransactionalPayload `
                (Join-Path $Root "late-mismatch-result")
        } catch { $LateMismatchRejected = $_.Exception.Message -eq "profile_precondition_drift" }
        if (-not $LateMismatchRejected -or [IO.Directory]::Exists($TransactionalParent) -or
            (Get-Sha256Bytes ([IO.File]::ReadAllBytes($Destination))) -cne (Get-Sha256Bytes $Before)) {
            throw "late-entry zero-change preflight self-test failed"
        }

        $RollbackManifestBytes = ConvertTo-CanonicalAsciiBytes @(
            "profile-bundle|1", "request-id|request-5123456789abcdef0123456789abcdef",
            "action-id|profile.apply-managed-bundle.v1", "policy-token|profile-default",
            "target-sid|S-1-5-21-1-2-3-1001", "profile-root-id|$FixtureRootId", "entry-count|2",
            "payload-length|$($TransactionalPayload.Count)",
            "payload-sha256|$(Get-Sha256Bytes $TransactionalPayload)",
            "entry|0|$TransactionalPath|managed-file|$($TransactionalContract.Artifact)|$($TransactionalContract.Manager)|$($TransactionalContract.LogicalIdentity)|write|0|$($NewManagedBytes.Count)|$NewManagedDigest|absent|-|-",
            "entry|1|.codex/settings.json|json-scalar|codex-settings|codex|codex-settings|write|$($NewManagedBytes.Count)|$($ReplacementBytes.Count)|$ReplacementDigest|present|$PayloadDigest|codex",
            "end-bundle|")
        $RollbackBundleBytes = New-ProfileBundleContainer $RollbackManifestBytes $TransactionalPayload
        $RollbackPrecondition = Get-LiveStateDigest $FixtureRootId @(
            [pscustomobject]@{ Path = $TransactionalPath; Presence = "absent"; Digest = "-"; Manager = "-" },
            [pscustomobject]@{ Path = ".codex/settings.json"; Presence = "present"; Digest = $PayloadDigest; Manager = "codex" })
        $RollbackHandoff = Read-Handoff (ConvertTo-CanonicalAsciiBytes @(
            "windows-profile-handoff|1", "request-id|request-5123456789abcdef0123456789abcdef",
            "action-id|profile.apply-managed-bundle.v1", "policy-token|profile-default",
            "target-sid|S-1-5-21-1-2-3-1001", "profile-root-id|$FixtureRootId",
            "bundle-length|$($RollbackBundleBytes.Count)", "bundle-sha256|$(Get-Sha256Bytes $RollbackBundleBytes)",
            "entry-map-sha256|$(Get-Sha256Bytes $TransactionalMapBytes)",
            "marketplace-set-sha256|$($EmptyMarketplaceSet.Digest)", "max-entries|8", "max-bytes|65536",
            "delete-mode|managed-only", "request-precondition-sha256|$RollbackPrecondition", "end-handoff|"))
        $InjectedFailureRestored = $false
        $script:FixtureCommitFailureAfter = 2
        try {
            Invoke-ProfileOperation $ProfileRoot $RollbackHandoff (Read-ProfileManifest $RollbackManifestBytes) `
                $TransactionalMap $TransactionalPayload (Join-Path $Root "rollback-result")
        } catch { $InjectedFailureRestored = $_.Exception.Message -eq "fixture_injected_commit_failure" }
        finally { $script:FixtureCommitFailureAfter = -1 }
        $TransactionalDestination = Join-Path $ProfileRoot `
            ($TransactionalPath.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if (-not $InjectedFailureRestored -or [IO.File]::Exists($TransactionalDestination) -or
            [IO.Directory]::Exists($TransactionalParent) -or
            (Get-Sha256Bytes ([IO.File]::ReadAllBytes($Destination))) -cne (Get-Sha256Bytes $Before) -or
            @(Get-ChildItem -LiteralPath $ProfileRoot -Filter ".machine-utilities-*" -Recurse -Force).Count -ne 0) {
            throw "mid-commit exact rollback self-test failed"
        }
        $HardLink = Join-Path $Root "settings-hardlink"
        try {
            [void](New-Item -ItemType HardLink -Path $HardLink -Target $Destination -ErrorAction Stop)
            $Session = $null; $Rejected = $false
            try {
                $Session = New-ManagedPathSession $ProfileRoot "S-1-5-21-1-2-3-1001" $FixtureRootId
                [void](Get-LiveState $Session $EntryMap.Entries[0])
            } catch { $Rejected = $true } finally { Close-ManagedPathSession $Session }
            if (-not $Rejected) { throw "hard-link self-test failed" }
        } catch [System.UnauthorizedAccessException] { } finally {
            if ([IO.File]::Exists($HardLink)) { [IO.File]::Delete($HardLink) }
        }
        foreach ($BadIdentity in @(
            "entry|.codex/settings.json|json-scalar|codex-settings|claude|codex-settings",
            "entry|.codex/settings.json|json-scalar|codex-settings|codex|another-identity")) {
            $Rejected = $false
            try { [void](Read-EntryMap (ConvertTo-CanonicalAsciiBytes @(
                        "profile-entry-map|1", $BadIdentity, "end-entry-map|"))) } catch { $Rejected = $true }
            if (-not $Rejected) { throw "compiled identity self-test failed" }
        }
        foreach ($UnsafeJson in @('{"mcp_servers":{"evil":{}}}', '{"password":"secret"}')) {
            $Rejected = $false
            try { Assert-ContentForHandler $Manifest.Entries[0] $script:Utf8.GetBytes($UnsafeJson) } catch { $Rejected = $true }
            if (-not $Rejected) { throw "unsafe content self-test failed" }
        }
        $Outside = Join-Path $Root "outside"; [void][IO.Directory]::CreateDirectory($Outside)
        $LinkParent = Join-Path $ProfileRoot ".codex/machine-utilities"
        if ([IO.Directory]::Exists((Split-Path -Parent $LinkParent))) {
            try {
                [void](New-Item -ItemType SymbolicLink -Path $LinkParent -Target $Outside -ErrorAction Stop)
                $LinkEntry = [pscustomobject]@{ Path = ".codex/machine-utilities/managed/demo/file";
                    Handler = "managed-file"; Artifact = "demo"; Manager = "machine-utilities";
                    LogicalIdentity = "managed-file:$(Get-Sha256Text '.codex/machine-utilities/managed/demo/file')" }
                $Session = $null; $Rejected = $false
                try {
                    $Session = New-ManagedPathSession $ProfileRoot "S-1-5-21-1-2-3-1001" $FixtureRootId
                    [void](Get-LiveState $Session $LinkEntry)
                } catch { $Rejected = $true } finally { Close-ManagedPathSession $Session }
                if (-not $Rejected) { throw "ancestor reparse self-test failed" }
            } catch [System.UnauthorizedAccessException] { }
        }
        $WrongRootRejected = $false
        try { [void](New-ManagedPathSession $ProfileRoot "S-1-5-21-1-2-3-1001" "wrong-profile") }
        catch { $WrongRootRejected = $_.Exception.Message -eq "profile_root_identity_drift" }
        if (-not $WrongRootRejected) { throw "profile root binding self-test failed" }
        if ((Get-Content -Raw -LiteralPath $ResultPath) -notmatch '^windows-profile-result\|2' -or
            (Get-Content -Raw -LiteralPath $ResultPath) -notmatch 'context-authenticated-smb\|unavailable') {
            throw "profile evidence self-test failed"
        }
        $UnsupportedPath = Join-Path $Root "unsupported-result"
        Write-UnsupportedContextResult $Handoff $UnsupportedPath
        if ((Get-Content -Raw -LiteralPath $UnsupportedPath) -notmatch
            '^windows-profile-context-result\|1(?s:.*)reason\|unsupported_context') {
            throw "unsupported context result self-test failed"
        }
        Write-Output "PASS: profile-worker-windows fixture-safe self-check"
    } finally {
        $script:FixtureCommitFailureAfter = -1
        $script:FixtureMode = $false
        if ([IO.Directory]::Exists($Root)) { [IO.Directory]::Delete($Root, $true) }
    }
}

if ($SelfTest) { Invoke-SelfTest; return }

if (-not $IsWindows) { throw "unsupported_context" }
$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
try {
    if ($null -eq $Identity.User) { throw "unsupported_context" }
    $CurrentSid = [string]$Identity.User.Value
} finally { $Identity.Dispose() }
$ProgramData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
$ProfileRoot = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)).TrimEnd('\')
$RegisteredProfileRoot = Get-ProfilePathForSid $CurrentSid
if (-not $ProfileRoot.Equals($RegisteredProfileRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "profile_root_identity_drift"
}
$HandoffRoot = Join-Path $ProgramData "MachineUtilities/profile/handoff"
$PointerBytes = [IO.File]::ReadAllBytes((Join-Path $HandoffRoot "active"))
$PointerLines = ConvertFrom-CanonicalAsciiBytes $PointerBytes 512 "profile_pointer"
$PointerFields = Read-FixedFields $PointerLines @("request-id", "handoff-sha256") `
    "windows-profile-active|1" "end-active|" "profile_pointer"
if ($PointerFields.'request-id' -notmatch '^request-[0-9a-f]{32}$' -or -not (Test-Digest $PointerFields.'handoff-sha256')) {
    throw "invalid_profile_pointer"
}
$RequestRoot = Join-Path $HandoffRoot $PointerFields.'request-id'
$HandoffBytes = [IO.File]::ReadAllBytes((Join-Path $RequestRoot "handoff"))
if ((Get-Sha256Bytes $HandoffBytes) -cne $PointerFields.'handoff-sha256') { throw "profile_handoff_drift" }
$Handoff = Read-Handoff $HandoffBytes
$ResultPath = Join-Path $RequestRoot "result"
if ($Handoff.Fields.'target-sid' -cne $CurrentSid) {
    Write-UnsupportedContextResult $Handoff $ResultPath; exit 3
}
try { $ContextEvidence = Get-ProfileContextEvidence $CurrentSid $ProgramData }
catch { Write-UnsupportedContextResult $Handoff $ResultPath; exit 3 }
$BundleBytes = [IO.File]::ReadAllBytes((Join-Path $RequestRoot "bundle"))
$MapBytes = [IO.File]::ReadAllBytes((Join-Path $RequestRoot "entry.map"))
$MarketplaceSetBytes = [IO.File]::ReadAllBytes((Join-Path $RequestRoot "marketplace.set"))
if ($BundleBytes.Count -ne $Handoff.BundleLength -or (Get-Sha256Bytes $BundleBytes) -cne $Handoff.Fields.'bundle-sha256' -or
    (Get-Sha256Bytes $MapBytes) -cne $Handoff.Fields.'entry-map-sha256' -or
    (Get-Sha256Bytes $MarketplaceSetBytes) -cne $Handoff.Fields.'marketplace-set-sha256') {
    throw "profile_handoff_drift"
}
$EntryMap = Read-EntryMap $MapBytes
$MarketplaceSet = Read-MarketplaceSet $MarketplaceSetBytes
if ($Handoff.Fields.'action-id' -ceq "profile.inventory-managed-state.v1") {
    Invoke-ProfileInventory $ProfileRoot $Handoff $EntryMap $ResultPath $ContextEvidence $MarketplaceSet
} elseif ($Handoff.Fields.'action-id' -ceq "profile.readiness-probe.v1") {
    Invoke-ProfileReadinessProbe $ProfileRoot $Handoff $EntryMap $ResultPath $MarketplaceSet
} else {
    $Bundle = Read-ProfileBundleContainer $BundleBytes
    Invoke-ProfileOperation $ProfileRoot $Handoff (Read-ProfileManifest $Bundle.ManifestBytes) `
        $EntryMap $Bundle.PayloadBytes $ResultPath $ContextEvidence $MarketplaceSet
}
