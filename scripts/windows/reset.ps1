#Requires -Version 5.1
<#
.SYNOPSIS
  볼륨 삭제 후 재기동 (V1 스키마 재적용)
#>
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

Write-Host 'WARNING: 모든 로컬 DB 볼륨을 삭제합니다.'
$ans = Read-Host 'Continue? [y/N]'
if ($ans -notin @('y', 'Y')) {
    Write-Host 'Cancelled.'
    exit 0
}

function Invoke-ComposeDownVolumes {
    param([string]$ComposeDir)
    Push-Location $ComposeDir
    try {
        & docker compose down -v
        if ($LASTEXITCODE -ne 0) { throw "docker compose down -v failed in $ComposeDir" }
    } finally {
        Pop-Location
    }
}

Invoke-ComposeDownVolumes (Join-Path $Root 'msa-platform\docker')
Invoke-ComposeDownVolumes (Join-Path $Root 'msa-auth\docker')

Write-Host 'Volumes removed. Starting fresh...'
& (Join-Path $PSScriptRoot 'up.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
