#Requires -Version 5.1
<#
.SYNOPSIS
    Native-Windows resolver and launcher for mcp-siding.mjs.

.DESCRIPTION
    The PowerShell twin of RESOLVER_SH + NODE_RESOLVER_SH in the sibling
    mcp-siding.mjs: locate mcp-siding.mjs across the versioned plugin cache
    (newest version wins, compared NUMERICALLY), resolve a node that can
    actually run it (global fetch/ReadableStream, probed rather than
    assumed), and start it with this shim's stdio handles - all failing
    closed with a diagnostic naming exactly what was tried.

    This file is the SINGLE SOURCE for that logic. `mcp-siding.mjs
    --print-shim-script --platform windows` reads the marked region below
    out of this very file and emits it, followed by one Invoke-McpSidingShim
    call carrying that registration's flags. So there is no second copy to
    keep in sync, and the -SelfTest below tests the same text a real
    registration runs. The POSIX resolvers stay where they are: they are
    embedded in mcp-siding.mjs because a POSIX host is the one place this
    file may not be reachable from, and they are already covered there.

    Windows PowerShell 5.1 compatible on purpose - `powershell.exe` is
    always present on Windows, `pwsh` is not, so a registration that needs
    PowerShell 7 would fail on a stock host. That rules out the 5.1-absent
    conveniences: no ProcessStartInfo.ArgumentList (.NET Core only), no
    ternary, no null-coalescing, no multi-argument Join-Path.

.PARAMETER SelfTest
    Run the built-in assertions and exit non-zero on the first failure.
    Same convention as every other .ps1 in this directory; the Windows CI
    job runs it.

.NOTES
    Deliberately NOT a mandatory parameter in its own parameter set (the
    shape codex-plugin-hooks.ps1 uses, where every invocation has an
    action): the install path dot-sources this file to reuse the node
    resolver, and a mandatory parameter makes an argument-less dot-source
    fail with "missing mandatory parameters" instead of defining the
    functions. With no arguments this file defines and does nothing.
#>
[CmdletBinding()]
param(
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

# <!-- mcp-siding: windows-resolver:start -->
function Test-McpSidingFile {
    param([AllowNull()][string]$Path)

    return -not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path -PathType Leaf)
}

# Numeric, part-by-part version comparison - NOT a string sort. `0.10.0`
# beats `0.7.4`, and lexically it does not; the POSIX resolver uses an awk
# numeric compare for exactly this reason and this is its twin. Missing
# parts read as 0, so `1.2` and `1.2.0` compare equal, and four parts are
# enough for every version this plugin has ever published. Returns -1, 0 or
# 1 like any comparator.
function Compare-McpSidingVersion {
    param([string]$Left, [string]$Right)

    $leftParts = $Left.Split('.')
    $rightParts = $Right.Split('.')
    for ($index = 0; $index -lt 4; $index++) {
        $leftPart = 0
        $rightPart = 0
        if ($index -lt $leftParts.Length) { [void][int]::TryParse($leftParts[$index], [ref]$leftPart) }
        if ($index -lt $rightParts.Length) { [void][int]::TryParse($rightParts[$index], [ref]$rightPart) }
        if ($leftPart -gt $rightPart) { return 1 }
        if ($leftPart -lt $rightPart) { return -1 }
    }
    return 0
}

# The plugin cache roots to scan, in ONE pass so the globally newest
# version wins regardless of which harness owns it - same rule, same
# reason, as the POSIX resolver's single loop over both roots. Windows
# harness state lives under %USERPROFILE%, with $HOME as the fallback for
# the (WSL-interop, CI, test) cases where USERPROFILE is not set.
function Get-McpSidingCacheRoots {
    $userRoot = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($userRoot)) { $userRoot = $HOME }
    if ([string]::IsNullOrWhiteSpace($userRoot)) { return @() }
    return @(
        (Join-Path (Join-Path (Join-Path $userRoot '.claude') 'plugins') 'cache'),
        (Join-Path (Join-Path (Join-Path $userRoot '.codex') 'plugins') 'cache')
    )
}

# Resolves mcp-siding.mjs. Order and fail-closed rules mirror RESOLVER_SH
# exactly:
#   0. $MCP_SIDING_PATH - an explicit local-development pin. Set but naming
#      a file that does not exist is an ERROR, never a fall-through: running
#      an installed build while the user believes they are exercising their
#      working tree is the misleading result dev mode exists to avoid.
#   1. $CLAUDE_PLUGIN_ROOT\scripts\mcp-siding.mjs, when populated.
#   2. every versioned cache directory under BOTH harness roots, newest
#      version wins.
# Throws (never returns $null) so the caller reports one diagnostic naming
# everything checked.
function Resolve-McpSidingScript {
    param(
        [AllowNull()][string]$OverridePath,
        [AllowNull()][string]$PluginRoot,
        [string[]]$CacheRoots
    )

    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        if (-not (Test-McpSidingFile $OverridePath)) {
            throw "mcp-siding: `$env:MCP_SIDING_PATH is set to '$OverridePath' but that file does not exist - this is an explicit local-development override, not a hint, so it must name a real file rather than silently falling back to an installed build."
        }
        return $OverridePath
    }

    if (-not [string]::IsNullOrWhiteSpace($PluginRoot)) {
        $pluginCandidate = Join-Path (Join-Path $PluginRoot 'scripts') 'mcp-siding.mjs'
        if (Test-McpSidingFile $pluginCandidate) { return $pluginCandidate }
    }

    $best = $null
    $bestVersion = $null
    foreach ($cacheRoot in $CacheRoots) {
        foreach ($marketplace in @(Get-ChildItem -LiteralPath $cacheRoot -Directory -ErrorAction SilentlyContinue)) {
            $pluginDirectory = Join-Path $marketplace.FullName 'roundhouse'
            foreach ($versionDirectory in @(Get-ChildItem -LiteralPath $pluginDirectory -Directory -ErrorAction SilentlyContinue)) {
                # Same shape filter as the POSIX resolver's `case` guard: a
                # directory whose name is not a dotted numeric version is
                # not a published version and must not be ranked as one.
                if ($versionDirectory.Name -notmatch '^[0-9]+(\.[0-9]+)*$') { continue }
                $candidate = Join-Path (Join-Path $versionDirectory.FullName 'scripts') 'mcp-siding.mjs'
                if (-not (Test-McpSidingFile $candidate)) { continue }
                if ($null -eq $best -or (Compare-McpSidingVersion $versionDirectory.Name $bestVersion) -gt 0) {
                    $best = $candidate
                    $bestVersion = $versionDirectory.Name
                }
            }
        }
    }
    if ($best) { return $best }

    $checked = @('$env:MCP_SIDING_PATH', '$env:CLAUDE_PLUGIN_ROOT') + @($CacheRoots | ForEach-Object { Join-Path (Join-Path $_ '*\roundhouse\*') 'scripts' })
    throw "mcp-siding: could not find mcp-siding.mjs (checked $($checked -join ', ')). Is the roundhouse plugin installed?"
}

# What this shim actually needs from a runtime, probed directly rather than
# inferred from a version number or from mere existence on disk: an old
# Node starts the server fine and then throws `fetch is not defined` on the
# first backend request, which the shim classifies as the app being down.
function Test-McpSidingNodeCapability {
    param([AllowNull()][string]$Path)

    if (-not (Test-McpSidingFile $Path)) { return $false }
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Path -e 'if (typeof fetch !== "function" || typeof ReadableStream !== "function") process.exit(1)' *> $null
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return ($LASTEXITCODE -eq 0)
}

# Candidate node binaries, in preference order. PATH first (the normal
# case), then Windows' own install locations and the two common version
# managers, then the harness-bundled runtimes. The bundled ones are
# deliberately included here even though the POSIX resolver deliberately
# omits its equivalents: on Windows those layouts are known empirically
# (codex-plugin-hooks.ps1 in this same directory resolves them for the hook
# lane, verified against the iris-windows host), whereas no macOS/Linux
# bundle path is - and guessing one is worse than not trying it.
function Get-McpSidingNodeCandidates {
    param([AllowNull()][string]$Override)

    $candidates = New-Object System.Collections.Generic.List[string]
    $add = {
        param([AllowNull()][string]$Path)
        if (-not [string]::IsNullOrWhiteSpace($Path) -and -not $candidates.Contains($Path)) { [void]$candidates.Add($Path) }
    }

    & $add $Override
    $pathNode = Get-Command -Name 'node.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pathNode) {
        $pathNode = Get-Command -Name 'node' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($pathNode) { & $add ([string]$pathNode.Source) }

    if ($env:ProgramFiles) { & $add (Join-Path (Join-Path $env:ProgramFiles 'nodejs') 'node.exe') }
    if (${env:ProgramFiles(x86)}) { & $add (Join-Path (Join-Path ${env:ProgramFiles(x86)} 'nodejs') 'node.exe') }
    if ($env:LOCALAPPDATA) {
        & $add (Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA 'Programs') 'nodejs') 'node.exe')
        & $add (Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA 'Volta') 'bin') 'node.exe')
        & $add (Join-Path (Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA 'Programs') 'OpenAI') 'Codex') 'node.exe')
        & $add (Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA 'Programs') 'OpenAI') 'Codex') 'bin') 'node.exe')
        & $add (Join-Path (Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA 'Programs') 'Claude Code') 'resources') 'node.exe')
    }
    if ($env:APPDATA) { & $add (Join-Path (Join-Path (Join-Path $env:APPDATA 'npm') 'node_modules') 'node.exe') }
    if ($env:USERPROFILE) {
        & $add (Join-Path (Join-Path (Join-Path $env:USERPROFILE '.volta') 'bin') 'node.exe')
        & $add (Join-Path (Join-Path $env:USERPROFILE '.local') 'node.exe')
        & $add (Join-Path (Join-Path (Join-Path $env:USERPROFILE '.local') 'bin') 'node.exe')
    }
    return @($candidates)
}

# Resolves a usable node. Same fail-closed rule as $MCP_SIDING_PATH, one
# level down: $MCP_SIDING_NODE set but missing, or set but failing the
# capability probe, is an ERROR naming the override - never a silent
# fall-through to some other node, which would run a registration under a
# different runtime than the one being pinned. `Probe` exists so the
# selection, ordering and diagnostics can be tested without needing several
# real Node installs on the test host; production always uses the default.
function Resolve-McpSidingNode {
    param(
        [AllowNull()][string]$Override,
        [string[]]$Candidates,
        [scriptblock]$Probe
    )

    if (-not $Probe) { $Probe = { param([string]$Path) Test-McpSidingNodeCapability $Path } }

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        if (-not (Test-McpSidingFile $Override)) {
            throw "mcp-siding: `$env:MCP_SIDING_NODE is set to '$Override' but that file does not exist or is not executable - this is an explicit override, not a hint, so it must name a usable node rather than silently falling back to another one."
        }
        if (-not (& $Probe $Override)) {
            throw "mcp-siding: `$env:MCP_SIDING_NODE is set to '$Override' but it lacks global fetch/ReadableStream (this shim needs Node 18+) - this is an explicit override, not a hint, so it must name a usable node rather than silently falling back to another one."
        }
    }

    $rejected = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (& $Probe $candidate) { return $candidate }
        if (Test-McpSidingFile $candidate) { [void]$rejected.Add($candidate) }
    }

    $diagnostic = "mcp-siding: no node with global fetch/ReadableStream (this shim needs Node 18+) found (checked `$env:MCP_SIDING_NODE, PATH, $($Candidates -join ', '))."
    if ($rejected.Count -gt 0) {
        $diagnostic = "$diagnostic Rejected as too old: $($rejected -join ' ')."
    }
    throw "$diagnostic Install a newer Node or set `$env:MCP_SIDING_NODE."
}

# Windows command-line quoting (the CommandLineToArgvW rules) for one
# argument vector. Needed because ProcessStartInfo.ArgumentList does not
# exist on Windows PowerShell 5.1 - only the single `Arguments` string does
# - and a --name or --app value may legitimately contain spaces, quotes or
# trailing backslashes ("Autodesk Fusion.app"). Backslashes are only
# special immediately before a quote: they double there, and the quote
# itself is escaped; a run at the very end of a quoted argument doubles too
# so it cannot escape the closing quote.
function ConvertTo-McpSidingArgumentString {
    param([string[]]$Arguments)

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($argument in $Arguments) {
        if ($argument -ne '' -and $argument -notmatch '[\s"]') {
            [void]$parts.Add($argument)
            continue
        }
        $builder = New-Object System.Text.StringBuilder
        [void]$builder.Append('"')
        $backslashes = 0
        foreach ($character in $argument.ToCharArray()) {
            if ($character -eq '\') {
                $backslashes++
                continue
            }
            if ($character -eq '"') {
                [void]$builder.Append('\' * ($backslashes * 2 + 1))
                [void]$builder.Append('"')
                $backslashes = 0
                continue
            }
            if ($backslashes -gt 0) {
                [void]$builder.Append('\' * $backslashes)
                $backslashes = 0
            }
            [void]$builder.Append($character)
        }
        [void]$builder.Append('\' * ($backslashes * 2))
        [void]$builder.Append('"')
        [void]$parts.Add($builder.ToString())
    }
    return ($parts -join ' ')
}

# Resolve, then hand this process's stdio straight to node and wait.
#
# Deliberately NOT `& $node $script @ShimArgs`. A stdio MCP server's stdout
# IS the protocol: one JSON object per line, byte for byte. PowerShell's
# native-command handling reads a child's output into its own pipeline
# whenever it is not inheriting a console, which puts PowerShell's string
# and newline handling between the shim and its client. Starting the
# process with UseShellExecute=$false and NOTHING redirected makes the
# child inherit this process's own standard handles, so PowerShell never
# sees a byte of the protocol in either direction.
function Invoke-McpSidingShim {
    param([string[]]$ShimArgs)

    try {
        $scriptPath = Resolve-McpSidingScript -OverridePath $env:MCP_SIDING_PATH -PluginRoot $env:CLAUDE_PLUGIN_ROOT -CacheRoots (Get-McpSidingCacheRoots)
        $nodePath = Resolve-McpSidingNode -Override $env:MCP_SIDING_NODE -Candidates (Get-McpSidingNodeCandidates $env:MCP_SIDING_NODE)
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $nodePath
    $startInfo.Arguments = ConvertTo-McpSidingArgumentString (@($scriptPath) + @($ShimArgs))
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $false
    $startInfo.RedirectStandardOutput = $false
    $startInfo.RedirectStandardError = $false
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $process.WaitForExit()
    exit $process.ExitCode
}
# <!-- mcp-siding: windows-resolver:end -->

# ---------------------------------------------------------------------------
# Self-test

function Assert-McpSidingTest {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) { throw "mcp-siding-windows self-test: $Message" }
}

function New-McpSidingTestFile {
    param([string]$Path)

    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, 'fixture')
}

function Invoke-McpSidingSelfTest {
    # -- version ordering: the whole point is that it is NUMERIC ------------
    Assert-McpSidingTest ((Compare-McpSidingVersion '0.10.0' '0.7.4') -gt 0) '0.10.0 must rank above 0.7.4 (a string sort gets this backwards)'
    Assert-McpSidingTest ((Compare-McpSidingVersion '0.7.4' '0.10.0') -lt 0) '0.7.4 must rank below 0.10.0'
    Assert-McpSidingTest ((Compare-McpSidingVersion '1.2' '1.2.0') -eq 0) 'a missing part must read as 0'
    Assert-McpSidingTest ((Compare-McpSidingVersion '1.2.3.4' '1.2.3.3') -gt 0) 'the fourth part must be compared'
    Assert-McpSidingTest ((Compare-McpSidingVersion '2.0.0' '10.0.0') -lt 0) 'a two-digit major must outrank a one-digit major'

    $root = Join-Path ([IO.Path]::GetTempPath()) ("mcp-siding-ps-" + [Guid]::NewGuid().ToString('N'))
    try {
        $claudeCache = Join-Path (Join-Path (Join-Path $root '.claude') 'plugins') 'cache'
        $codexCache = Join-Path (Join-Path (Join-Path $root '.codex') 'plugins') 'cache'
        $roots = @($claudeCache, $codexCache)
        $scriptUnder = {
            param([string]$Cache, [string]$Marketplace, [string]$Version)
            return (Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $Cache $Marketplace) 'roundhouse') $Version) 'scripts') 'mcp-siding.mjs')
        }

        # -- nothing installed anywhere -> fail closed, naming what it tried
        $missingMessage = $null
        try {
            [void](Resolve-McpSidingScript -OverridePath $null -PluginRoot $null -CacheRoots $roots)
        } catch {
            $missingMessage = $_.Exception.Message
        }
        Assert-McpSidingTest ($null -ne $missingMessage) 'an empty cache must fail closed, not return a path'
        Assert-McpSidingTest ($missingMessage -like '*MCP_SIDING_PATH*') 'the diagnostic must name $MCP_SIDING_PATH as checked'
        Assert-McpSidingTest ($missingMessage -like '*CLAUDE_PLUGIN_ROOT*') 'the diagnostic must name $CLAUDE_PLUGIN_ROOT as checked'
        Assert-McpSidingTest ($missingMessage -like '*roundhouse*') 'the diagnostic must name the plugin cache paths it scanned'

        # -- numeric ordering across a real tree, not a comparator call:
        #    0.10.0 must win over 0.7.4 even though it sorts lower as text,
        #    and the winner must be the one in the OTHER harness's cache so
        #    a per-root pass (Claude fully before Codex) fails here.
        $lowClaude = & $scriptUnder $claudeCache 'novotnyllc' '0.7.4'
        $highCodex = & $scriptUnder $codexCache 'novotnyllc' '0.10.0'
        New-McpSidingTestFile $lowClaude
        New-McpSidingTestFile $highCodex
        Assert-McpSidingTest ((Resolve-McpSidingScript -OverridePath $null -PluginRoot $null -CacheRoots $roots) -eq $highCodex) '0.10.0 in the Codex cache must beat 0.7.4 in the Claude cache'

        # -- a version directory with no script must be skipped, not win ---
        $emptyHigh = Join-Path (Join-Path (Join-Path (Join-Path $claudeCache 'novotnyllc') 'roundhouse') '99.0.0') 'scripts'
        [void][IO.Directory]::CreateDirectory($emptyHigh)
        Assert-McpSidingTest ((Resolve-McpSidingScript -OverridePath $null -PluginRoot $null -CacheRoots $roots) -eq $highCodex) 'a version directory with no mcp-siding.mjs must be skipped, not win'

        # -- a non-version directory name must never be ranked -------------
        $nonVersion = & $scriptUnder $claudeCache 'novotnyllc' 'latest'
        New-McpSidingTestFile $nonVersion
        Assert-McpSidingTest ((Resolve-McpSidingScript -OverridePath $null -PluginRoot $null -CacheRoots $roots) -eq $highCodex) 'a non-numeric version directory must not be ranked as a version'

        # -- $CLAUDE_PLUGIN_ROOT wins over the cache when populated --------
        $pluginRoot = Join-Path $root 'plugin-root'
        $pluginScript = Join-Path (Join-Path $pluginRoot 'scripts') 'mcp-siding.mjs'
        New-McpSidingTestFile $pluginScript
        Assert-McpSidingTest ((Resolve-McpSidingScript -OverridePath $null -PluginRoot $pluginRoot -CacheRoots $roots) -eq $pluginScript) '$CLAUDE_PLUGIN_ROOT must be preferred over the cache'
        Assert-McpSidingTest ((Resolve-McpSidingScript -OverridePath $null -PluginRoot (Join-Path $root 'absent') -CacheRoots $roots) -eq $highCodex) 'a $CLAUDE_PLUGIN_ROOT with no script must fall through to the cache'

        # -- $MCP_SIDING_PATH: wins when real, FAILS CLOSED when not -------
        $override = Join-Path $root 'dev-checkout\mcp-siding.mjs'
        New-McpSidingTestFile $override
        Assert-McpSidingTest ((Resolve-McpSidingScript -OverridePath $override -PluginRoot $pluginRoot -CacheRoots $roots) -eq $override) 'an existing $MCP_SIDING_PATH must win over everything'
        $failClosed = $null
        try {
            [void](Resolve-McpSidingScript -OverridePath (Join-Path $root 'gone.mjs') -PluginRoot $pluginRoot -CacheRoots $roots)
        } catch {
            $failClosed = $_.Exception.Message
        }
        Assert-McpSidingTest ($null -ne $failClosed) 'a $MCP_SIDING_PATH naming a missing file must fail closed, never fall through'
        Assert-McpSidingTest ($failClosed -like '*MCP_SIDING_PATH*') 'the fail-closed diagnostic must name the override'

        # -- node resolution: order, rejection accounting, fail-closed -----
        $goodNode = Join-Path $root 'good\node.exe'
        $oldNode = Join-Path $root 'old\node.exe'
        New-McpSidingTestFile $goodNode
        New-McpSidingTestFile $oldNode
        $fakeProbe = { param([string]$Path) return ($Path -eq $goodNode) }

        Assert-McpSidingTest ((Resolve-McpSidingNode -Override $null -Candidates @($oldNode, $goodNode) -Probe $fakeProbe) -eq $goodNode) 'the first candidate that PASSES the probe must win, not the first that exists'

        $noneMessage = $null
        try {
            [void](Resolve-McpSidingNode -Override $null -Candidates @($oldNode, (Join-Path $root 'absent\node.exe')) -Probe $fakeProbe)
        } catch {
            $noneMessage = $_.Exception.Message
        }
        Assert-McpSidingTest ($null -ne $noneMessage) 'no usable node must fail closed'
        Assert-McpSidingTest ($noneMessage -like '*Rejected as too old*') 'the diagnostic must account for a node that exists but failed the probe'
        Assert-McpSidingTest ($noneMessage -like "*$oldNode*") 'the diagnostic must name the rejected node'
        Assert-McpSidingTest ($noneMessage -like '*MCP_SIDING_NODE*') 'the diagnostic must name the override as a way out'

        $missingOverride = $null
        try {
            [void](Resolve-McpSidingNode -Override (Join-Path $root 'absent\node.exe') -Candidates @($goodNode) -Probe $fakeProbe)
        } catch {
            $missingOverride = $_.Exception.Message
        }
        Assert-McpSidingTest ($null -ne $missingOverride) 'a $MCP_SIDING_NODE naming a missing file must fail closed, not fall through to a working candidate'

        $badOverride = $null
        try {
            [void](Resolve-McpSidingNode -Override $oldNode -Candidates @($goodNode) -Probe $fakeProbe)
        } catch {
            $badOverride = $_.Exception.Message
        }
        Assert-McpSidingTest ($null -ne $badOverride) 'a $MCP_SIDING_NODE that fails the capability probe must fail closed'
        Assert-McpSidingTest ($badOverride -like '*fetch/ReadableStream*') 'the diagnostic must say what capability was missing'

        # -- the REAL probe, not the injected one: this host's own node must
        #    pass and a real executable that is not node must be rejected.
        #    The current PowerShell binary is the honest "exists, is
        #    executable, cannot run this shim" case - available on every host
        #    this can possibly run on, so nothing here is conditional.
        $realNode = Get-Command -Name 'node' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        Assert-McpSidingTest ($null -ne $realNode) 'this self-test needs a real node on PATH to exercise the capability probe'
        Assert-McpSidingTest (Test-McpSidingNodeCapability ([string]$realNode.Source)) 'the capability probe must accept a real Node 18+'
        $selfBinary = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        Assert-McpSidingTest (-not (Test-McpSidingNodeCapability $selfBinary)) 'the capability probe must reject an executable that cannot run this shim'
        Assert-McpSidingTest (-not (Test-McpSidingNodeCapability (Join-Path $root 'nope\node.exe'))) 'the capability probe must reject a path that does not exist'

        # -- argument quoting: the values a registration actually bakes in -
        $roundTrip = Join-Path $root 'argv.mjs'
        [IO.File]::WriteAllText($roundTrip, 'process.stdout.write(JSON.stringify(process.argv.slice(2)))')
        $awkward = @('--name', 'a b', '--app', 'C:\Program Files\Weird "App"\x\', '--cache', '')
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = [string]$realNode.Source
        $startInfo.Arguments = ConvertTo-McpSidingArgumentString (@($roundTrip) + $awkward)
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $quoteProcess = [Diagnostics.Process]::Start($startInfo)
        $observed = $quoteProcess.StandardOutput.ReadToEnd()
        $quoteProcess.WaitForExit()
        $expected = ConvertTo-Json -Compress -InputObject $awkward
        Assert-McpSidingTest ($observed -eq $expected) "argument quoting must round-trip verbatim: expected $expected, got $observed"

        # -- the GENERATED registration must be valid PowerShell -----------
        # The registration a host actually runs is this file's marked region
        # plus one Invoke-McpSidingShim line that mcp-siding.mjs builds and
        # quotes. Parsing this file alone would never catch a quoting bug in
        # that line, so generate the real thing - with values chosen to break
        # naive quoting - and parse it. Both tools this needs are already
        # required above (a real node) or are the host running this (a
        # PowerShell parser), so nothing here is conditional.
        $siding = Join-Path (Split-Path -Parent $PSCommandPath) 'mcp-siding.mjs'
        Assert-McpSidingTest (Test-McpSidingFile $siding) "the sibling mcp-siding.mjs must be next to this file (looked at $siding)"
        $generated = & ([string]$realNode.Source) $siding '--print-shim-script' '--platform' 'windows' `
            '--backend-url' 'http://127.0.0.1:27182/mcp' `
            '--name' "it's a `"weird`" name" `
            '--app' 'C:\Program Files\Autodesk Fusion.app' 2>&1 | Out-String
        Assert-McpSidingTest ($LASTEXITCODE -eq 0) "mcp-siding.mjs --print-shim-script --platform windows failed: $generated"
        $parseErrors = $null
        $parseTokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($generated, [ref]$parseTokens, [ref]$parseErrors)
        Assert-McpSidingTest ($parseErrors.Count -eq 0) "the generated registration must be valid PowerShell: $($parseErrors -join '; ')"
        Assert-McpSidingTest ($generated -match 'Invoke-McpSidingShim -ShimArgs @\(') 'the generated registration must end in an Invoke-McpSidingShim call'
        Assert-McpSidingTest ($generated -match 'function Resolve-McpSidingScript') 'the generated registration must carry the resolver region from this file'

        # The hostile --name must survive generation as one literal value,
        # not as PowerShell that runs. Evaluating the generated arg vector in
        # isolation is the honest check: it proves what the registration
        # would actually pass to node.
        $shimArgsLine = ($generated -split "`n" | Where-Object { $_ -like 'Invoke-McpSidingShim*' } | Select-Object -First 1)
        $shimArgsExpression = $shimArgsLine -replace '^Invoke-McpSidingShim -ShimArgs ', ''
        $evaluated = @(& ([scriptblock]::Create($shimArgsExpression)))
        Assert-McpSidingTest ($evaluated -contains "it's a `"weird`" name") 'a hostile --name must survive PowerShell quoting verbatim'
        Assert-McpSidingTest ($evaluated -contains 'C:\Program Files\Autodesk Fusion.app') 'an --app path with spaces and backslashes must survive PowerShell quoting verbatim'

        # -- an argument-less dot-source must define the functions ---------
        # The documented install path reuses this file's node resolver by
        # dot-sourcing it, so "no arguments defines and does nothing" is a
        # contract, not an accident: a mandatory parameter here would make
        # that dot-source fail with "missing mandatory parameters" and take
        # the whole Windows install with it. Checked in a child of whatever
        # PowerShell is running this, so it holds on 5.1 and on 7 alike.
        $powerShell = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $dotSourceProbe = & $powerShell -NoProfile -NonInteractive -Command ". '$PSCommandPath'; Get-Command Invoke-McpSidingShim | ForEach-Object { `$_.Name }" 2>&1 | Out-String
        Assert-McpSidingTest ($dotSourceProbe -match 'Invoke-McpSidingShim') "dot-sourcing this file with no arguments must define its functions, got: $dotSourceProbe"
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Output 'mcp-siding-windows self-test ok'
}

if ($SelfTest) {
    Invoke-McpSidingSelfTest
}
