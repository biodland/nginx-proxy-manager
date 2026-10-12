# Rewritten bash script to PowerShell for Windows users
$ErrorActionPreference = 'Stop'

function Get-ContainerIp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ContainerName
    )

    $containerId = docker compose -f .\docker\docker-compose.dev.yml ps --all -q $ContainerName | Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($containerId)) {
        return ''
    }

    $ip = docker inspect --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $containerId
    return ($ip | Out-String).Trim()
}

function Wait-ForHealthy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Service,

        [int]$Limit = 120
    )

    Write-Host '❯ ' -NoNewline -ForegroundColor Blue
    Write-Host 'Waiting for healthy: ' -NoNewline -ForegroundColor Cyan
    Write-Host $Service -ForegroundColor Yellow

    $loopCount = 0
    $healthy = ''

    while ($healthy -ne 'healthy') {
        Write-Host '.' -NoNewline
        Start-Sleep -Seconds 1
        $healthy = docker inspect -f '{{.State.Health.Status}}' $Service
        $loopCount++

        if ($loopCount -ge $Limit) {
            Write-Host ''
            Write-Host '❯ ' -NoNewline -ForegroundColor Blue
            Write-Host 'Timed out waiting for healthy' -ForegroundColor Red
            docker logs --tail 50 $Service
            exit 1
        }
    }

    Write-Host ''
    Write-Host '❯ ' -NoNewline -ForegroundColor Blue
    Write-Host 'Healthy!' -ForegroundColor Green
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host '❯ docker command is not available' -ForegroundColor Red
    exit 1
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $repoRoot
$env:COMPOSE_PROJECT_NAME = 'npm2dev'

Write-Host '❯ ' -NoNewline -ForegroundColor Blue
Write-Host 'Starting Dev Stack ...' -ForegroundColor Cyan
Write-Host '❯ ' -NoNewline -ForegroundColor Blue
docker compose -f .\docker\docker-compose.dev.yml config  

# Bring up a stack, in steps so we can inject IPs everywhere
docker compose -f .\docker\docker-compose.dev.yml up -d pdns pdns-db
$pdnsIp = Get-ContainerIp -ContainerName 'pdns'
Write-Host '❯ ' -NoNewline -ForegroundColor Blue
Write-Host "PDNS IP is $pdnsIp" -ForegroundColor Yellow

# adjust the dnsrouter config
$localDnsrouterConfig = Join-Path $repoRoot 'docker\dev\dnsrouter-config.json'
$tmpConfigPath = "$localDnsrouterConfig.tmp"
if (Test-Path $tmpConfigPath) {
    Remove-Item -LiteralPath $tmpConfigPath -Recurse -Force
}

$config = Get-Content -Raw -Path $localDnsrouterConfig | ConvertFrom-Json
$config.servers[0].upstreams[1].upstream = $pdnsIp
$configJson = $config | ConvertTo-Json -Depth 100
$utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($tmpConfigPath, $configJson + [Environment]::NewLine, $utf8WithoutBom)

docker compose -f .\docker\docker-compose.dev.yml up -d dnsrouter
$dnsrouterIp = Get-ContainerIp -ContainerName 'dnsrouter'
Write-Host '❯ ' -NoNewline -ForegroundColor Blue
Write-Host "DNS Router IP is $dnsrouterIp" -ForegroundColor Yellow

if ([string]::IsNullOrWhiteSpace($dnsrouterIp)) {
    Write-Host '❯ ERROR: DNS Router IP is not set' -ForegroundColor Red
    exit 1
}

# mount the resolver
$localResolve = Join-Path $repoRoot 'docker\dev\resolv.conf'
if (Test-Path $localResolve) {
    Remove-Item $localResolve -Force
}
[System.IO.File]::WriteAllText(
    $localResolve,
    "nameserver $dnsrouterIp`noptions ndots:0`n",
    $utf8WithoutBom
)

# bring up all remaining containers, except cypress!
docker compose -f .\docker\docker-compose.dev.yml up -d --remove-orphans stepca squid
docker compose -f .\docker\docker-compose.dev.yml pull db db-postgres authentik-redis authentik authentik-worker authentik-ldap
docker compose -f .\docker\docker-compose.dev.yml build --pull --parallel fullstack
docker compose -f .\docker\docker-compose.dev.yml up -d --remove-orphans fullstack
docker compose -f .\docker\docker-compose.dev.yml up -d --remove-orphans swagger

# wait for main container to be healthy
$fullstackContainer = docker compose -f .\docker\docker-compose.dev.yml ps --all -q fullstack | Select-Object -Last 1
if (-not [string]::IsNullOrWhiteSpace($fullstackContainer)) {
    Wait-ForHealthy -Service $fullstackContainer -Limit 120
}

Write-Host ''
Write-Host 'Admin UI:     http://127.0.0.1:3081' -ForegroundColor Cyan
Write-Host 'Nginx:        http://127.0.0.1:3080' -ForegroundColor Cyan
Write-Host 'Swagger Doc:  http://127.0.0.1:3001' -ForegroundColor Cyan
Write-Host ''

if ($args.Count -gt 0 -and $args[0] -eq '-f') {
    Write-Host '❯ ' -NoNewline -ForegroundColor Blue
    Write-Host 'Following Backend Container:' -ForegroundColor Yellow
    docker logs -f npm2dev.core
}
else {
    Write-Host 'Hint: You can follow the output of some of the containers with:' -ForegroundColor Yellow
    Write-Host '  docker logs -f npm2dev.core'
}
