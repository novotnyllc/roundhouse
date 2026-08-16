[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Action')]
    [ValidateSet('approve', 'update')]
    [string]$Action,

    [Parameter(Mandatory = $true, Position = 1, ParameterSetName = 'Action')]
    [string]$PluginId,

    [Parameter(Mandatory = $true, ParameterSetName = 'SelfTest')]
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

function Test-RegularFile {
    param([AllowNull()][string]$Path)

    return -not [string]::IsNullOrWhiteSpace($Path) -and
        (Test-Path -LiteralPath $Path -PathType Leaf)
}

function Get-ApplicationPath {
    param([string[]]$Name)

    foreach ($candidateName in $Name) {
        $command = Get-Command -Name $candidateName -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($command) { return [string]$command.Source }
    }
    return $null
}

function Add-UniqueProbe {
    param(
        [System.Collections.Generic.List[string]]$List,
        [AllowNull()][string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not $List.Contains($Path)) { [void]$List.Add($Path) }
}

function Get-CodexRoots {
    param(
        [AllowNull()][string]$CodexPath,
        [AllowNull()][string]$KnownCodexRoot
    )

    $roots = [System.Collections.Generic.List[string]]::new()
    if ($CodexPath) {
        $codexDirectory = Split-Path -Parent $CodexPath
        Add-UniqueProbe $roots $codexDirectory
        if ((Split-Path -Leaf $codexDirectory) -ieq 'bin') {
            Add-UniqueProbe $roots (Split-Path -Parent $codexDirectory)
        } elseif ((Split-Path -Leaf (Split-Path -Parent $codexDirectory)) -ieq 'bin') {
            Add-UniqueProbe $roots (Split-Path -Parent (Split-Path -Parent $codexDirectory))
        }
    } elseif ($KnownCodexRoot) {
        Add-UniqueProbe $roots $KnownCodexRoot
    }
    return @($roots)
}

function Get-CodexNodeCandidates {
    param(
        [AllowNull()][string]$CodexPath,
        [AllowNull()][string]$KnownCodexRoot
    )

    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($root in @(Get-CodexRoots $CodexPath $KnownCodexRoot)) {
        Add-UniqueProbe $candidates (Join-Path $root 'node.exe')
        Add-UniqueProbe $candidates (Join-Path $root 'bin\node.exe')

        $binRoot = Join-Path $root 'bin'
        if (Test-Path -LiteralPath $binRoot -PathType Container) {
            foreach ($versionDirectory in @(Get-ChildItem -LiteralPath $binRoot -Directory -ErrorAction SilentlyContinue)) {
                Add-UniqueProbe $candidates (Join-Path $versionDirectory.FullName 'node.exe')
            }
        }

        $cuaRoot = Join-Path $root 'runtimes\cua_node'
        if (Test-Path -LiteralPath $cuaRoot -PathType Container) {
            foreach ($versionDirectory in @(Get-ChildItem -LiteralPath $cuaRoot -Directory -ErrorAction SilentlyContinue)) {
                Add-UniqueProbe $candidates (Join-Path $versionDirectory.FullName 'bin\node.exe')
            }
        }
    }
    return @($candidates)
}

function Get-ClaudeNodeCandidates {
    param(
        [AllowNull()][string]$ClaudePath,
        [AllowNull()][string]$LocalAppData = $env:LOCALAPPDATA,
        [AllowNull()][string]$ProgramFiles = $env:ProgramFiles
    )

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($ClaudePath) {
        $claudeDirectory = Split-Path -Parent $ClaudePath
        # Derive from the actual claude.exe layout first. Native inspection of
        # iris-windows found claude.exe at %USERPROFILE%\.local\bin with no
        # node.exe below that directory; the default roots below therefore
        # remain documented best-effort probes only.
        Add-UniqueProbe $candidates (Join-Path $claudeDirectory 'node.exe')
        Add-UniqueProbe $candidates (Join-Path $claudeDirectory 'resources\node.exe')
        Add-UniqueProbe $candidates (Join-Path $claudeDirectory 'resources\app\node.exe')
        Add-UniqueProbe $candidates (Join-Path $claudeDirectory '..\node.exe')
    }
    if ($LocalAppData) {
        Add-UniqueProbe $candidates (Join-Path $LocalAppData 'Programs\Claude Code\resources\node.exe')
    }
    if ($ProgramFiles) {
        Add-UniqueProbe $candidates (Join-Path $ProgramFiles 'Claude Code\resources\node.exe')
    }
    return @($candidates)
}

function New-NodeResolutionResult {
    param(
        [AllowNull()][string]$NodePath,
        [AllowNull()][string]$Source,
        [System.Collections.Generic.List[string]]$PathProbes,
        [System.Collections.Generic.List[string]]$CodexProbes,
        [System.Collections.Generic.List[string]]$ClaudeProbes,
        [AllowNull()][string]$CodexExecutablePath
    )

    return [pscustomobject]@{
        NodePath = $NodePath
        Source = $Source
        CodexExecutablePath = $CodexExecutablePath
        PathProbes = @($PathProbes)
        CodexProbes = @($CodexProbes)
        ClaudeProbes = @($ClaudeProbes)
    }
}

function Resolve-RoundhouseNode {
    param(
        [AllowNull()][string]$PathNode,
        [AllowNull()][string]$CodexPath,
        [AllowNull()][string]$ClaudePath,
        [AllowNull()][string]$KnownCodexRoot,
        [switch]$NoCommandDiscovery
    )

    $pathProbes = [System.Collections.Generic.List[string]]::new()
    $codexProbes = [System.Collections.Generic.List[string]]::new()
    $claudeProbes = [System.Collections.Generic.List[string]]::new()
    Add-UniqueProbe $pathProbes $(if ($PathNode) { $PathNode } else { 'Get-Command node.exe/node' })

    if (-not $NoCommandDiscovery) {
        if (-not $PathNode) { $PathNode = Get-ApplicationPath @('node', 'node.exe') }
        if ($PathNode) { Add-UniqueProbe $pathProbes $PathNode }
        if (-not $CodexPath) { $CodexPath = Get-ApplicationPath @('codex', 'codex.exe') }
        if (-not $ClaudePath) { $ClaudePath = Get-ApplicationPath @('claude', 'claude.exe') }
        if (-not $KnownCodexRoot -and $env:LOCALAPPDATA) {
            $KnownCodexRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex'
        }
    }

    if (-not $CodexPath -and -not $NoCommandDiscovery) {
        $knownCodexInstallRoots = [System.Collections.Generic.List[string]]::new()
        Add-UniqueProbe $knownCodexInstallRoots $KnownCodexRoot
        if ($env:LOCALAPPDATA) {
            Add-UniqueProbe $knownCodexInstallRoots (Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex')
        }
        foreach ($installRoot in @($knownCodexInstallRoots)) {
            foreach ($candidate in @(
                    (Join-Path $installRoot 'codex.exe'),
                    (Join-Path $installRoot 'bin\codex.exe')
                )) {
                Add-UniqueProbe $codexProbes $candidate
                if (Test-RegularFile $candidate) { $CodexPath = $candidate; break }
            }
            if ($CodexPath) { break }
        }
    }
    if ($CodexPath) { Add-UniqueProbe $codexProbes "codex.exe in use: $CodexPath" }

    # (1) An installed Node wins over every bundled runtime.
    if (Test-RegularFile $PathNode) {
        return New-NodeResolutionResult $PathNode 'PATH' $pathProbes $codexProbes $claudeProbes $CodexPath
    }

    # (2) Codex owns this helper's execution surface. Prefer candidates from
    # the active codex.exe tree; consult the known runtime data root only when
    # that installation tree has no node.exe (the native Codex layout keeps
    # its runtime data under %LOCALAPPDATA%\OpenAI\Codex).
    $codexCandidates = if ($CodexPath) {
        @(Get-CodexNodeCandidates $CodexPath $KnownCodexRoot)
    } else {
        @()
    }
    foreach ($candidate in $codexCandidates) { Add-UniqueProbe $codexProbes $candidate }
    $codexFiles = @($codexCandidates |
        Where-Object { Test-RegularFile $_ } |
        ForEach-Object { Get-Item -LiteralPath $_ } |
        Sort-Object @{ Expression = 'LastWriteTimeUtc'; Descending = $true }, @{ Expression = 'FullName'; Descending = $false })
    if ($codexFiles.Count -eq 0 -and $CodexPath -and $KnownCodexRoot) {
        $codexDataCandidates = @(Get-CodexNodeCandidates $null $KnownCodexRoot)
        foreach ($candidate in $codexDataCandidates) { Add-UniqueProbe $codexProbes $candidate }
        $codexFiles = @($codexDataCandidates |
            Where-Object { Test-RegularFile $_ } |
            ForEach-Object { Get-Item -LiteralPath $_ } |
            Sort-Object @{ Expression = 'LastWriteTimeUtc'; Descending = $true }, @{ Expression = 'FullName'; Descending = $false })
    }
    if ($codexFiles.Count -gt 0) {
        return New-NodeResolutionResult $codexFiles[0].FullName 'CODEX-BUNDLED' $pathProbes $codexProbes $claudeProbes $CodexPath
    }

    # (3) Claude is a last-resort compatibility fallback. The command-derived
    # probes are preferred; default install paths are explicitly best effort.
    $claudeCandidates = if ($NoCommandDiscovery) {
        @(Get-ClaudeNodeCandidates -ClaudePath $ClaudePath -LocalAppData $null -ProgramFiles $null)
    } else {
        @(Get-ClaudeNodeCandidates $ClaudePath)
    }
    foreach ($candidate in $claudeCandidates) { Add-UniqueProbe $claudeProbes $candidate }
    foreach ($candidate in $claudeCandidates) {
        if (Test-RegularFile $candidate) {
            return New-NodeResolutionResult $candidate 'CLAUDE-BUNDLED' $pathProbes $codexProbes $claudeProbes $CodexPath
        }
    }

    return New-NodeResolutionResult $null $null $pathProbes $codexProbes $claudeProbes $CodexPath
}

function Format-NodeProbes {
    param([object[]]$Probes)

    if (-not $Probes -or $Probes.Count -eq 0) { return '(none)' }
    return ($Probes -join '; ')
}

function Get-NodeResolutionFailureMessage {
    param([pscustomobject]$Resolution)

    return @(
        'Roundhouse hook approval needs Node.js.',
        'Probes tried:',
        "  PATH node: $(Format-NodeProbes $Resolution.PathProbes)",
        "  CODEX-BUNDLED node: $(Format-NodeProbes $Resolution.CodexProbes)",
        "  Claude-bundled node: $(Format-NodeProbes $Resolution.ClaudeProbes) (last fallback, best effort)",
        'Recovery: install Node on PATH, refresh/repair the Codex installation so its bundled node.exe is present, or use the documented WSL interop recovery.'
    ) -join [Environment]::NewLine
}

function Invoke-RoundhouseNodeResolution {
    param(
        [AllowNull()][string]$PathNode,
        [AllowNull()][string]$CodexPath,
        [AllowNull()][string]$ClaudePath,
        [AllowNull()][string]$KnownCodexRoot,
        [switch]$NoCommandDiscovery
    )

    $resolution = Resolve-RoundhouseNode @PSBoundParameters
    if ($resolution.NodePath) {
        return [pscustomobject]@{
            ExitCode = 0
            NodePath = $resolution.NodePath
            Source = $resolution.Source
            CodexExecutablePath = $resolution.CodexExecutablePath
            ErrorMessage = $null
            Resolution = $resolution
        }
    }
    return [pscustomobject]@{
        ExitCode = 69
        NodePath = $null
        Source = $null
        CodexExecutablePath = $resolution.CodexExecutablePath
        ErrorMessage = Get-NodeResolutionFailureMessage $resolution
        Resolution = $resolution
    }
}

function Assert-Test {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) { throw "codex-plugin-hooks self-test: $Message" }
}

function New-TestFile {
    param([string]$Path)

    $directory = Split-Path -Parent $Path
    [void][IO.Directory]::CreateDirectory($directory)
    [IO.File]::WriteAllText($Path, 'fixture')
}

function New-TestTextFile {
    param(
        [string]$Path,
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    [void][IO.Directory]::CreateDirectory($directory)
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Invoke-SelfTest {
    $hook = Join-Path $PSScriptRoot 'codex-plugin-hooks.mjs'
    Assert-Test (Test-RegularFile $hook) 'Roundhouse hook approval helper is missing its Node entrypoint'

    $root = Join-Path ([IO.Path]::GetTempPath()) ('roundhouse-node-resolution-' + [Guid]::NewGuid().ToString('N'))
    try {
        # PATH wins even when the Codex bundle contains a newer node.exe.
        $pathNode = Join-Path $root 'path\node.exe'
        $codexRoot = Join-Path $root 'codex-data'
        $activeCodex = Join-Path $root 'codex-install\bin\codex.exe'
        New-TestFile $pathNode
        New-TestFile $activeCodex
        $codexNew = Join-Path $codexRoot 'bin\new-hash\node.exe'
        New-TestFile $codexNew
        $pathResult = Invoke-RoundhouseNodeResolution -PathNode $pathNode -CodexPath $activeCodex `
            -KnownCodexRoot $codexRoot -NoCommandDiscovery
        Assert-Test ($pathResult.ExitCode -eq 0 -and $pathResult.Source -eq 'PATH' -and $pathResult.NodePath -eq $pathNode) 'PATH node did not win'

        # With PATH absent, the newest hashed Codex sibling wins.
        $codexOld = Join-Path $codexRoot 'bin\old-hash\node.exe'
        New-TestFile $codexOld
        (Get-Item -LiteralPath $codexOld).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-5)
        $runtimeOld = Join-Path $codexRoot 'runtimes\cua_node\old-runtime\bin\node.exe'
        $runtimeNew = Join-Path $codexRoot 'runtimes\cua_node\new-runtime\bin\node.exe'
        New-TestFile $runtimeOld
        New-TestFile $runtimeNew
        (Get-Item -LiteralPath $runtimeOld).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-10)
        (Get-Item -LiteralPath $codexNew).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-2)
        (Get-Item -LiteralPath $runtimeNew).LastWriteTimeUtc = [DateTime]::UtcNow
        $codexResult = Invoke-RoundhouseNodeResolution -CodexPath $activeCodex `
            -KnownCodexRoot $codexRoot -NoCommandDiscovery
        Assert-Test ($codexResult.ExitCode -eq 0 -and $codexResult.Source -eq 'CODEX-BUNDLED' -and $codexResult.NodePath -eq $runtimeNew) 'newest Codex hashed node did not win'

        # An active Codex install without a local node.exe may use the known
        # runtime data root, but an unrelated newer tree must not outrank the
        # active install when it already has a usable runtime.
        $activeInstallRoot = Join-Path $root 'active-install'
        $activeCodexPath = Join-Path $activeInstallRoot 'bin\codex.exe'
        $activeNode = Join-Path $activeInstallRoot 'bin\node.exe'
        $unrelatedRoot = Join-Path $root 'unrelated-install'
        $unrelatedCodexPath = Join-Path $unrelatedRoot 'bin\codex.exe'
        $unrelatedNode = Join-Path $unrelatedRoot 'bin\node.exe'
        New-TestFile $activeCodexPath
        New-TestFile $activeNode
        New-TestFile $unrelatedCodexPath
        New-TestFile $unrelatedNode
        (Get-Item -LiteralPath $activeNode).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-5)
        (Get-Item -LiteralPath $unrelatedNode).LastWriteTimeUtc = [DateTime]::UtcNow
        $activeResult = Invoke-RoundhouseNodeResolution -CodexPath $activeCodexPath `
            -KnownCodexRoot $unrelatedRoot -NoCommandDiscovery
        Assert-Test ($activeResult.NodePath -eq $activeNode) 'unrelated Codex runtime outranked the active install'

        # With no PATH commands, the native known install root supplies the
        # active codex.exe and its separate runtime data root supplies Node.
        $knownPath = Join-Path $root 'known-empty-path'
        $knownLocalAppData = Join-Path $root 'known-localappdata'
        $knownProgramFiles = Join-Path $root 'known-programfiles'
        $knownCodex = Join-Path $knownLocalAppData 'Programs\OpenAI\Codex\bin\codex.exe'
        $knownNode = Join-Path $knownLocalAppData 'OpenAI\Codex\runtimes\cua_node\known-hash\bin\node.exe'
        New-TestFile $knownCodex
        New-TestFile $knownNode
        $priorPath = $env:PATH
        $priorLocalAppData = $env:LOCALAPPDATA
        $priorProgramFiles = $env:ProgramFiles
        try {
            $env:PATH = $knownPath
            $env:LOCALAPPDATA = $knownLocalAppData
            $env:ProgramFiles = $knownProgramFiles
            $knownResult = Invoke-RoundhouseNodeResolution
        } finally {
            if ($null -eq $priorPath) { Remove-Item Env:PATH -ErrorAction SilentlyContinue } else { $env:PATH = $priorPath }
            if ($null -eq $priorLocalAppData) { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue } else { $env:LOCALAPPDATA = $priorLocalAppData }
            if ($null -eq $priorProgramFiles) { Remove-Item Env:ProgramFiles -ErrorAction SilentlyContinue } else { $env:ProgramFiles = $priorProgramFiles }
        }
        Assert-Test ($knownResult.Source -eq 'CODEX-BUNDLED' -and
            $knownResult.NodePath -eq $knownNode -and
            $knownResult.CodexExecutablePath -eq $knownCodex) 'known Codex install/runtime roots did not resolve together'

        # Claude is only a last fallback, and Codex remains preferred when both
        # bundles are present.
        $claudePath = Join-Path $root 'claude-install\claude.exe'
        $claudeNode = Join-Path $root 'claude-install\resources\node.exe'
        New-TestFile $claudePath
        New-TestFile $claudeNode
        $claudeResult = Invoke-RoundhouseNodeResolution -ClaudePath $claudePath `
            -KnownCodexRoot (Join-Path $root 'absent-codex') -NoCommandDiscovery
        Assert-Test ($claudeResult.ExitCode -eq 0 -and $claudeResult.Source -eq 'CLAUDE-BUNDLED' -and $claudeResult.NodePath -eq $claudeNode) 'Claude fallback did not resolve'
        $codexPreferred = Invoke-RoundhouseNodeResolution -CodexPath $activeCodex -ClaudePath $claudePath `
            -KnownCodexRoot $codexRoot -NoCommandDiscovery
        Assert-Test ($codexPreferred.Source -eq 'CODEX-BUNDLED') 'Codex did not win over Claude fallback'

        # Missing all three classes returns the required recovery code/message.
        $missing = Invoke-RoundhouseNodeResolution -KnownCodexRoot (Join-Path $root 'absent-codex') -NoCommandDiscovery
        Assert-Test ($missing.ExitCode -eq 69) 'all-absent resolution did not return exit 69'
        foreach ($label in @('PATH node:', 'CODEX-BUNDLED node:', 'Claude-bundled node:', 'WSL interop')) {
            Assert-Test ($missing.ErrorMessage.Contains($label)) "all-absent guidance omitted $label"
        }
        $orphanRoot = Join-Path $root 'orphan-codex-data'
        New-TestFile (Join-Path $orphanRoot 'bin\node.exe')
        $orphan = Invoke-RoundhouseNodeResolution -KnownCodexRoot $orphanRoot -NoCommandDiscovery
        Assert-Test ($orphan.ExitCode -eq 69 -and $orphan.Source -eq $null) 'orphaned Codex data resolved without an active codex.exe'

        # Exercise the same native action path used below. A fixture Codex is
        # placed first on PATH, while the real Node remains available to run
        # this PowerShell child. Capture the streams separately: the action's
        # stdout must stay one JSON document, while resolver diagnostics stay
        # on stderr.
        $nodePath = Get-ApplicationPath @('node', 'node.exe')
        $powerShellPath = Get-ApplicationPath @('pwsh', 'pwsh.exe', 'powershell', 'powershell.exe')
        Assert-Test (Test-RegularFile $nodePath) 'action fixture requires a runnable Node.js executable'
        Assert-Test (Test-RegularFile $powerShellPath) 'action fixture requires a runnable PowerShell executable'
        $fixtureSource = Join-Path $root 'codex-action-fixture.mjs'
        New-TestTextFile $fixtureSource @'
import { createInterface } from "node:readline";

const args = process.argv.slice(2);
const respond = (message, result) => process.stdout.write(`${JSON.stringify({ id: message.id, result })}\n`);

if (args[0] === "app-server" && args[1] === "--stdio") {
  createInterface({ input: process.stdin }).on("line", (line) => {
    const message = JSON.parse(line);
    if (message.method === "initialize") {
      respond(message, { codexHome: "fixture" });
    } else if (message.method === "hooks/list") {
      respond(message, { data: [{ cwd: message.params.cwds[0], hooks: [], warnings: [], errors: [] }] });
    }
  });
} else if (args[0] === "plugin" && args[1] === "list" && args[2] === "--json") {
  process.stdout.write(JSON.stringify({ installed: [{ pluginId: "example@test-market", installed: true }] }) + "\n");
} else {
  process.exitCode = 64;
}
'@
        $fixtureBin = Join-Path $root 'codex-action-bin'
        [void][IO.Directory]::CreateDirectory($fixtureBin)
        if ($IsWindows) {
            $fakeCodex = Join-Path $fixtureBin 'codex.cmd'
            $cmdFixture = @(
                '@echo off'
                '"%ROUNDHOUSE_TEST_NODE%" "%ROUNDHOUSE_TEST_CODEX_FIXTURE%" %*'
            ) -join [Environment]::NewLine
            New-TestTextFile $fakeCodex $cmdFixture
        } else {
            $fakeCodex = Join-Path $fixtureBin 'codex'
            New-TestTextFile $fakeCodex @'
#!/bin/sh
exec "$ROUNDHOUSE_TEST_NODE" "$ROUNDHOUSE_TEST_CODEX_FIXTURE" "$@"
'@
            [IO.File]::SetUnixFileMode($fakeCodex,
                [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor
                [IO.UnixFileMode]::UserExecute -bor [IO.UnixFileMode]::GroupRead -bor
                [IO.UnixFileMode]::GroupExecute)
        }
        $priorPath = $env:PATH
        $processInfo = [Diagnostics.ProcessStartInfo]::new()
        $processInfo.FileName = $powerShellPath
        foreach ($argument in @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-File', [IO.Path]::GetFullPath($PSCommandPath),
                '-Action', 'approve', '-PluginId', 'example@test-market')) {
            [void]$processInfo.ArgumentList.Add($argument)
        }
        $processInfo.UseShellExecute = $false
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.Environment['PATH'] = $fixtureBin + [IO.Path]::PathSeparator + $priorPath
        $processInfo.Environment['ROUNDHOUSE_TEST_NODE'] = $nodePath
        $processInfo.Environment['ROUNDHOUSE_TEST_CODEX_FIXTURE'] = $fixtureSource
        $actionProcess = [Diagnostics.Process]::new()
        $actionProcess.StartInfo = $processInfo
        [void]$actionProcess.Start()
        $actionStdout = $actionProcess.StandardOutput.ReadToEnd()
        $actionStderr = $actionProcess.StandardError.ReadToEnd()
        $actionProcess.WaitForExit()
        $actionLines = @($actionStdout -split "`r?`n" | Where-Object { $_.Length -gt 0 })
        Assert-Test ($actionProcess.ExitCode -eq 0 -and $actionLines.Count -eq 1) 'successful action did not preserve one JSON stdout line'
        $actionResult = $actionLines[0] | ConvertFrom-Json
        Assert-Test ($actionResult.pluginId -eq 'example@test-market' -and $actionResult.approved -eq 0) 'successful action returned the wrong JSON result'
        Assert-Test ($actionStdout -notmatch 'using node.exe') 'resolver diagnostics leaked into stdout'
        Assert-Test ($actionStderr -match 'roundhouse: using node\.exe .*\[PATH\]') 'resolver diagnostics did not remain on stderr'
    } finally {
        if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
    }
    Write-Output 'roundhouse: codex-plugin-hooks.ps1 resolution self-test passed'
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

$resolutionResult = Invoke-RoundhouseNodeResolution
if ($resolutionResult.ExitCode -ne 0) {
    [Console]::Error.WriteLine($resolutionResult.ErrorMessage)
    exit $resolutionResult.ExitCode
}

[Console]::Error.WriteLine("roundhouse: using node.exe $($resolutionResult.NodePath) [$($resolutionResult.Source)]")
$hook = Join-Path $PSScriptRoot 'codex-plugin-hooks.mjs'
$hookArguments = @($hook, $Action, $PluginId)
if ($resolutionResult.CodexExecutablePath) {
    $hookArguments += @('--codex-executable', $resolutionResult.CodexExecutablePath)
}
& $resolutionResult.NodePath @hookArguments
exit $LASTEXITCODE
