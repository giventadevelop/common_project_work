# Copy an existing Next.js frontend (including .env.local) into a NEW workspace
# folder and rewrite the satellite/app domain (and optional tenant id).
#
# Does NOT create GitHub remotes, Amplify apps, or Clerk satellites.
# After this script: npm install, then git_new_project_setup.mdc if a new repo is needed.
#
# Usage:
#   .\Copy-FrontendProjectFromTemplate.ps1 `
#     -SourceDir F:\project_workspace\kcnj-temp `
#     -DestDir F:\project_workspace\new-org `
#     -NewDomain www.new-org.com `
#     -NewTenantId new_org_1 `
#     -LocalPort 3003 `
#     -WhatIf

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceDir,

    [string]$DestDir,

    [string]$DestName,

    [Parameter(Mandatory = $true)]
    [string]$NewDomain,

    [string]$SourceDomain,

    [string]$NewTenantId,

    [int]$LocalPort = 0,

    [string]$WorkspaceRoot = 'F:\project_workspace',

    [switch]$Force,

    [switch]$InitGit
)

$ErrorActionPreference = 'Stop'

function Resolve-ProjectPath {
    param([string]$PathOrName)
    if ([string]::IsNullOrWhiteSpace($PathOrName)) { return $null }
    if ([System.IO.Path]::IsPathRooted($PathOrName)) {
        return [System.IO.Path]::GetFullPath($PathOrName)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $WorkspaceRoot $PathOrName))
}

function Get-HostParts {
    param([string]$Raw)
    $trimmed = ($Raw -replace '^\s+|\s+$', '') -replace '/$', ''
    $trimmed = $trimmed -replace '^https?://', ''
    $hostOnly = ($trimmed -split '/')[0].ToLowerInvariant()
    $apex = $hostOnly -replace '^www\.', ''
    $www = if ($hostOnly.StartsWith('www.')) { $hostOnly } else { "www.$apex" }
    return [pscustomobject]@{
        Apex     = $apex
        Www      = $www
        HttpsWww = "https://$www"
        HttpsApex = "https://$apex"
        HttpWww  = "http://$www"
        HttpApex = "http://$apex"
    }
}

function Read-EnvMap {
    param([string]$FilePath)
    $map = @{}
    if (-not (Test-Path $FilePath)) { return $map }
    Get-Content -LiteralPath $FilePath | ForEach-Object {
        $line = $_
        if ($line -match '^\s*#' -or $line -notmatch '=') { return }
        $idx = $line.IndexOf('=')
        $k = $line.Substring(0, $idx).Trim()
        $v = $line.Substring($idx + 1)
        if ($v -match '\s+#') { $v = ($v -split '\s+#', 2)[0] }
        $map[$k] = $v.Trim()
    }
    return $map
}

function Get-DetectedSourceDomain {
    param([string]$Root)
    $candidates = @(
        (Join-Path $Root '.env.production'),
        (Join-Path $Root '.env.local')
    )
    $keys = @(
        'NEXT_PUBLIC_CLERK_DOMAIN',
        'AMPLIFY_NEXT_PUBLIC_APP_URL',
        'NEXT_PUBLIC_APP_URL'
    )
    foreach ($file in $candidates) {
        $map = Read-EnvMap $file
        foreach ($k in $keys) {
            if (-not $map.ContainsKey($k)) { continue }
            $v = $map[$k]
            if ([string]::IsNullOrWhiteSpace($v)) { continue }
            if ($v -match 'localhost|127\.0\.0\.1') { continue }
            return (Get-HostParts $v).Apex
        }
    }
    $folder = Split-Path $Root -Leaf
    if ($folder -match '^[a-z0-9-]+$') { return "$folder.com" }
    return $null
}

function Get-ProtectedHosts {
    @(
        'kluvo.ai',
        'www.kluvo.ai',
        'event-site-manager-dev.com',
        'event-site-manager-prod.com',
        'clerk.kluvo.ai',
        'localhost',
        '127.0.0.1'
    )
}

function Test-ProtectedValue {
    param([string]$Value)
    foreach ($p in Get-ProtectedHosts) {
        if ($Value -eq $p) { return $true }
    }
    return $false
}

function New-DomainReplacementList {
    param($From, $To)
    $pairs = @(
        @{ Old = $From.HttpsWww;  New = $To.HttpsWww },
        @{ Old = $From.HttpWww;   New = $To.HttpsWww },
        @{ Old = $From.HttpsApex; New = $To.HttpsApex },
        @{ Old = $From.HttpApex;  New = $To.HttpsApex },
        @{ Old = $From.Www;       New = $To.Www },
        @{ Old = $From.Apex;      New = $To.Apex }
    )
    $pairs | Sort-Object { $_.Old.Length } -Descending
}

function Set-EnvKey {
    param(
        [string]$Content,
        [string]$Key,
        [string]$Value
    )
    $pattern = "(?m)^$([regex]::Escape($Key))=.*$"
    $line = "$Key=$Value"
    if ($Content -match $pattern) {
        return [regex]::Replace($Content, $pattern, [System.Text.RegularExpressions.MatchEvaluator] { $line }, 1)
    }
    if ($Content.Length -gt 0 -and -not $Content.EndsWith("`n")) {
        $Content += "`r`n"
    }
    return $Content + $line + "`r`n"
}

function Update-TemplateEnvFile {
    param(
        [string]$FilePath,
        $ReplacementList,
        [string]$NewTenantId,
        [string]$OldTenantId,
        [int]$LocalPort,
        [bool]$IsLocalEnv,
        $NewHost
    )
    if (-not (Test-Path $FilePath)) { return @() }
    $original = [System.IO.File]::ReadAllText($FilePath)
    $content = $original
    $changes = New-Object System.Collections.Generic.List[string]

    foreach ($pair in $ReplacementList) {
        if ([string]::IsNullOrWhiteSpace($pair.Old)) { continue }
        if ($pair.Old -eq $pair.New) { continue }
        if (Test-ProtectedValue $pair.Old) { continue }
        $before = $content
        $content = $content.Replace($pair.Old, $pair.New)
        if ($content -ne $before) {
            $changes.Add("replace $($pair.Old) -> $($pair.New)")
        }
    }

    if ($NewTenantId -and $OldTenantId -and $OldTenantId -ne $NewTenantId) {
        $before = $content
        $content = $content.Replace($OldTenantId, $NewTenantId)
        if ($content -ne $before) {
            $changes.Add("tenant $OldTenantId -> $NewTenantId")
        }
    }

    if ($IsLocalEnv) {
        if ($LocalPort -gt 0) {
            $content = Set-EnvKey $content 'NEXT_PUBLIC_APP_URL' "http://localhost:$LocalPort"
            $changes.Add("NEXT_PUBLIC_APP_URL=http://localhost:$LocalPort")
        }
    } else {
        $content = Set-EnvKey $content 'NEXT_PUBLIC_APP_URL' $NewHost.HttpsWww
        $content = Set-EnvKey $content 'AMPLIFY_NEXT_PUBLIC_APP_URL' $NewHost.HttpsWww
        $content = Set-EnvKey $content 'NEXT_PUBLIC_CLERK_DOMAIN' $NewHost.Www
        $changes.Add("NEXT_PUBLIC_APP_URL=$($NewHost.HttpsWww)")
        $changes.Add("NEXT_PUBLIC_CLERK_DOMAIN=$($NewHost.Www)")
    }

    if ($content -ne $original) {
        if ($PSCmdlet.ShouldProcess($FilePath, 'Rewrite domain in env file')) {
            $utf8 = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::WriteAllText($FilePath, $content, $utf8)
        }
    }
    return $changes
}

$SourceDir = Resolve-ProjectPath $SourceDir
if (-not $DestDir) {
    if (-not $DestName) { throw 'Provide -DestDir or -DestName.' }
    $DestDir = Join-Path $WorkspaceRoot $DestName
} else {
    $DestDir = Resolve-ProjectPath $DestDir
}

if (-not (Test-Path $SourceDir)) { throw "Source not found: $SourceDir" }
if ($SourceDir.TrimEnd('\') -eq $DestDir.TrimEnd('\')) {
    throw 'SourceDir and DestDir must be different.'
}
if ((Test-Path $DestDir) -and -not $Force) {
    throw "Destination already exists: $DestDir  (pass -Force to overwrite files in place; .git is still excluded)"
}

$newHost = Get-HostParts $NewDomain
if ([string]::IsNullOrWhiteSpace($SourceDomain)) {
    $SourceDomain = Get-DetectedSourceDomain $SourceDir
}
if ([string]::IsNullOrWhiteSpace($SourceDomain)) {
    throw 'Could not detect source domain. Pass -SourceDomain www.kcnj-temp.com (or similar).'
}
$oldHost = Get-HostParts $SourceDomain
if ($oldHost.Apex -eq $newHost.Apex) {
    Write-Warning "Source and new apex domains are the same ($($newHost.Apex)). Env rewrite will be a no-op for hostnames."
}

$srcEnv = Read-EnvMap (Join-Path $SourceDir '.env.local')
if (-not $srcEnv.ContainsKey('NEXT_PUBLIC_TENANT_ID')) {
    $srcEnv = Read-EnvMap (Join-Path $SourceDir '.env.production')
}
$oldTenantId = $srcEnv['NEXT_PUBLIC_TENANT_ID']

$replacements = New-DomainReplacementList -From $oldHost -To $newHost

Write-Host "Source      : $SourceDir" -ForegroundColor Cyan
Write-Host "Destination : $DestDir" -ForegroundColor Cyan
Write-Host "Domain      : $($oldHost.Www) -> $($newHost.Www)" -ForegroundColor Cyan
if ($NewTenantId) { Write-Host "Tenant      : $oldTenantId -> $NewTenantId" -ForegroundColor Cyan }
if ($LocalPort -gt 0) { Write-Host "Local port  : $LocalPort" -ForegroundColor Cyan }
Write-Host 'Planned host replacements:' -ForegroundColor DarkCyan
foreach ($pair in $replacements) {
    if ($pair.Old -and $pair.Old -ne $pair.New -and -not (Test-ProtectedValue $pair.Old)) {
        Write-Host "  $($pair.Old) -> $($pair.New)"
    }
}

$excludeDirs = @('.git', '.claude', 'node_modules', '.next', '.turbo', 'out', 'dist', 'coverage', '.amplify', '.vercel')
$robocopyArgs = @(
    $SourceDir, $DestDir, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP',
    '/XD'
) + $excludeDirs
if ($WhatIfPreference) { $robocopyArgs += '/L' }

if ($PSCmdlet.ShouldProcess($DestDir, "Robocopy from $SourceDir (exclude $($excludeDirs -join ', '))")) {
    & robocopy @robocopyArgs | Out-Null
    $code = $LASTEXITCODE
    # robocopy uses bits 0-7 as success; 8+ is failure
    if ($code -ge 8) { throw "robocopy failed with exit $code" }
    Write-Host "[SUCCESS] Copy complete (robocopy exit $code)" -ForegroundColor Green
}

$envReports = New-Object System.Collections.Generic.List[object]
$localEnv = Join-Path $DestDir '.env.local'
$prodEnv = Join-Path $DestDir '.env.production'
$devEnv = Join-Path $DestDir '.env.development'

$envReports.Add([pscustomobject]@{ Name = '.env.local'; Changes = (Update-TemplateEnvFile -FilePath $localEnv -ReplacementList $replacements -NewTenantId $NewTenantId -OldTenantId $oldTenantId -LocalPort $LocalPort -IsLocalEnv $true -NewHost $newHost) })
$envReports.Add([pscustomobject]@{ Name = '.env.production'; Changes = (Update-TemplateEnvFile -FilePath $prodEnv -ReplacementList $replacements -NewTenantId $NewTenantId -OldTenantId $oldTenantId -LocalPort 0 -IsLocalEnv $false -NewHost $newHost) })
if (Test-Path $devEnv) {
    $envReports.Add([pscustomobject]@{ Name = '.env.development'; Changes = (Update-TemplateEnvFile -FilePath $devEnv -ReplacementList $replacements -NewTenantId $NewTenantId -OldTenantId $oldTenantId -LocalPort $LocalPort -IsLocalEnv $true -NewHost $newHost) })
}

if (-not $DestName) { $DestName = Split-Path $DestDir -Leaf }
$pkgPath = Join-Path $DestDir 'package.json'
if ((Test-Path $pkgPath) -and $DestName) {
    try {
        $pkg = Get-Content -LiteralPath $pkgPath -Raw | ConvertFrom-Json
        if ($pkg.name -and $pkg.name -ne $DestName) {
            if ($PSCmdlet.ShouldProcess($pkgPath, "Set package.json name to $DestName")) {
                $raw = [System.IO.File]::ReadAllText($pkgPath)
                $raw = [regex]::Replace($raw, '"name"\s*:\s*"[^"]*"', ('"name": "' + $DestName + '"'), 1)
                $utf8 = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($pkgPath, $raw, $utf8)
                Write-Host "[SUCCESS] package.json name -> $DestName" -ForegroundColor Green
            }
        }
    } catch {
        Write-Warning "Could not update package.json name: $_"
    }
}

$ruleSrc = Join-Path $WorkspaceRoot 'common_project_work\.cursor\rules'
$ruleDest = Join-Path $DestDir '.cursor\rules'
$rulesToCopy = @(
    'Copy_FrontendProjectFrom_Template.mdc',
    'git_new_project_setup.mdc',
    'git_local_push.mdc'
)
if (Test-Path $ruleSrc) {
    if ($PSCmdlet.ShouldProcess($ruleDest, 'Copy cursor git rules')) {
        New-Item -ItemType Directory -Path $ruleDest -Force | Out-Null
        foreach ($r in $rulesToCopy) {
            $from = Join-Path $ruleSrc $r
            if (Test-Path $from) {
                Copy-Item -LiteralPath $from -Destination (Join-Path $ruleDest $r) -Force
            }
        }
    }
}

if ($InitGit -and -not (Test-Path (Join-Path $DestDir '.git'))) {
    if ($PSCmdlet.ShouldProcess($DestDir, 'git init')) {
        git -C $DestDir init | Out-Null
        git -C $DestDir branch -M main | Out-Null
        Write-Host '[SUCCESS] git init (no commit, no remote). Use git_new_project_setup.mdc next.' -ForegroundColor Green
    }
}

Write-Host ''
Write-Host '=== Env rewrite summary (no secret values) ===' -ForegroundColor Magenta
foreach ($row in $envReports) {
    Write-Host $row.Name
    $items = @($row.Changes)
    if (-not $items -or $items.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$items[0])) {
        Write-Host '  (no changes)'
    } else {
        ($items | Select-Object -Unique) | ForEach-Object { Write-Host "  $_" }
    }
}

Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Yellow
Write-Host "  1. cd $DestDir"
Write-Host '  2. npm install'
Write-Host '  3. Confirm .env.local NEXT_PUBLIC_APP_URL / NEXT_PUBLIC_TENANT_ID (gitignored — never commit)'
Write-Host '  4. If this needs a GitHub repo: follow git_new_project_setup.mdc (secret filter will skip .env*)'
Write-Host '  5. Amplify + Clerk satellite + Route 53: satellite_domain_new_site_configuration_and_deployment.mdc'
Write-Host '     (application-deployments). This script does not do infra.'
