#Requires -Version 5.1
<#
.SYNOPSIS
  DB 컨테이너 중지 (볼륨 유지)
#>
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Invoke-ComposeDown {
    param([string]$ComposeDir)
    Push-Location $ComposeDir
    try {
        & docker compose down
        if ($LASTEXITCODE -ne 0) { throw "docker compose down failed in $ComposeDir" }
    } finally {
        Pop-Location
    }
}

Write-Host '==> Stopping msa-platform DBs'
Invoke-ComposeDown (Join-Path $Root 'msa-platform\docker')

Write-Host '==> Stopping msa-auth postgres'
Invoke-ComposeDown (Join-Path $Root 'msa-auth\docker')

Write-Host '==> Stopping msa-infra'
Invoke-ComposeDown (Join-Path $Root 'msa-infra\docker')

Write-Host 'Done.'
