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
if ($SelfTest) {
    $hook = Join-Path $PSScriptRoot 'codex-plugin-hooks.mjs'
    if (-not (Test-Path -LiteralPath $hook -PathType Leaf)) {
        throw 'Roundhouse hook approval helper is missing its Node entrypoint'
    }
    Write-Output 'roundhouse: codex-plugin-hooks.ps1 self-test passed'
    exit 0
}

$node = $null
$nodeCommand = Get-Command -Name @('node.exe', 'node') -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($nodeCommand) {
    $node = $nodeCommand.Source
}

if (-not $node) {
    $claudeCommand = Get-Command claude.exe -ErrorAction SilentlyContinue
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Claude Code\resources\node.exe'),
        (Join-Path $env:ProgramFiles 'Claude Code\resources\node.exe')
    )
    if ($claudeCommand) {
        $claudeDir = Split-Path -Parent $claudeCommand.Source
        $candidates = @(
            (Join-Path $claudeDir 'node.exe'),
            (Join-Path $claudeDir 'resources\node.exe')
        ) + $candidates
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $node = $candidate
            break
        }
    }
}

if (-not $node) {
    Write-Error 'Roundhouse hook approval needs Node.js. Install/use the Claude-bundled node.exe or run the documented WSL interop fallback.'
    exit 69
}

$hook = Join-Path $PSScriptRoot 'codex-plugin-hooks.mjs'
& $node $hook $Action $PluginId
exit $LASTEXITCODE
