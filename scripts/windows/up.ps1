#Requires -Version 5.1
<#
.SYNOPSIS
  로컬 DB 컨테이너 일괄 기동 (Kafka + PostgreSQL x10 + MongoDB)
#>
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Wait-Postgres {
    param(
        [string]$Container,
        [string]$User,
        [string]$Database
    )
    for ($i = 1; $i -le 60; $i++) {
        & docker exec $Container pg_isready -U $User -d $Database -q 2>$null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 1
    }
    throw "timeout waiting for $Container"
}

function Invoke-Compose {
    param(
        [string]$ComposeDir,
        [string[]]$ExtraArgs = @('up', '-d')
    )
    Push-Location $ComposeDir
    try {
        & docker compose @ExtraArgs
        return ($LASTEXITCODE -eq 0)
    } finally {
        Pop-Location
    }
}

Write-Host '==> 1/3 msa-infra (Kafka, Redis, msa-network)'
if (-not (Invoke-Compose (Join-Path $Root 'msa-infra\docker'))) {
    Write-Warning 'msa-infra start failed (Kafka image/port 등). DB만 계속합니다.'
    & docker network create msa-network 2>$null
}

Write-Host '==> 2/3 msa-auth postgres-auth'
if (-not (Invoke-Compose (Join-Path $Root 'msa-auth\docker'))) {
    Write-Warning 'msa-postgres-auth failed (5432 포트 충돌?). 나머지 DB는 계속합니다.'
} else {
    Wait-Postgres -Container 'msa-postgres-auth' -User 'auth' -Database 'authdb'
}

Write-Host '==> 3/3 msa-platform (PostgreSQL x9, MongoDB)'
if (-not (Invoke-Compose (Join-Path $Root 'msa-platform\docker'))) {
    throw 'msa-platform docker compose failed'
}

@(
    @{ Container = 'msa-postgres-user'; User = 'userapp'; Database = 'userdb' },
    @{ Container = 'msa-postgres-commerce'; User = 'commerce'; Database = 'commercedb' },
    @{ Container = 'msa-postgres-point'; User = 'pointapp'; Database = 'pointdb' },
    @{ Container = 'msa-postgres-fashion'; User = 'fashion'; Database = 'fashiondb' },
    @{ Container = 'msa-postgres-social'; User = 'social'; Database = 'socialdb' },
    @{ Container = 'msa-postgres-recommendation'; User = 'recommendation'; Database = 'recommendationdb' },
    @{ Container = 'msa-postgres-notification'; User = 'notification'; Database = 'notificationdb' },
    @{ Container = 'msa-postgres-media'; User = 'media'; Database = 'mediadb' },
    @{ Container = 'msa-postgres-content'; User = 'content'; Database = 'contentdb' }
) | ForEach-Object {
    Wait-Postgres -Container $_.Container -User $_.User -Database $_.Database
}

Write-Host ''
Write-Host 'Done. Containers:'
& docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' |
    Select-String -Pattern 'NAMES|msa-postgres|msa-mongodb|msa-kafka|msa-redis'

Write-Host ''
Write-Host 'Schema check (userdb):'
$count = & docker exec msa-postgres-user psql -U userapp -d userdb -tAc `
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';"
Write-Host "  public tables: $count"

Write-Host ''
Write-Host 'Tip: V1 변경 후 재적용 -> db reset'
