[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('approve', 'update')]
    [string]$Action,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$PluginId
)

$ErrorActionPreference = 'Stop'
$node = $null
$nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
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
