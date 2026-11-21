[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRef,

    [Parameter(Mandatory = $true)]
    [string]$N8nDomain,

    [Parameter(Mandatory = $true)]
    [string]$StoreOrigin
)

$ErrorActionPreference = 'Stop'

if ($ProjectRef -notmatch '^[a-z0-9]{20}$') {
    throw 'A valid Supabase project reference is required.'
}
if ($N8nDomain -notmatch '^(?=.{1,253}$)([A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$') {
    throw 'A fully qualified public n8n domain is required.'
}

$originUri = $null
if (![System.Uri]::TryCreate($StoreOrigin, [System.UriKind]::Absolute, [ref]$originUri) -or
    $originUri.Scheme -ne 'https' -or
    $originUri.UserInfo -or
    $originUri.AbsolutePath -ne '/' -or
    $originUri.Query -or
    $originUri.Fragment) {
    throw 'StoreOrigin must be the HTTPS origin only, without a path or query.'
}

$supabase = Get-Command supabase -ErrorAction SilentlyContinue
if (!$supabase) {
    throw 'Supabase CLI is not installed or is not available on PATH.'
}

$localEnvPath = Join-Path $PSScriptRoot '.env'
if (!(Test-Path -LiteralPath $localEnvPath)) {
    throw 'Run initialize.ps1 first to create the protected local .env file.'
}

$values = @{}
foreach ($line in [System.IO.File]::ReadAllLines($localEnvPath)) {
    if ($line -match '^([A-Z0-9_]+)=(.*)$') {
        $values[$matches[1]] = $matches[2]
    }
}
if ($values['N8N_WEBHOOK_TOKEN'] -notmatch '^[A-Fa-f0-9]{64}$') {
    throw 'The local .env does not contain a valid webhook token.'
}

$secretEnvPath = Join-Path $env:TEMP ('.bakhoor-supabase-' + [guid]::NewGuid().ToString('N') + '.env')
[System.IO.File]::Create($secretEnvPath).Dispose()
try {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
    & $icacls $secretEnvPath '/inheritance:r' '/grant:r' "${identity}:(F)" 'SYSTEM:(F)' '*S-1-5-32-544:(F)' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not restrict access to the temporary Supabase secrets file.'
    }

    $secretLines = [string[]]@(
        "N8N_WEBHOOK_URL=https://$N8nDomain/webhook/bakhoor-order",
        "N8N_WEBHOOK_TOKEN=$($values['N8N_WEBHOOK_TOKEN'])",
        "STORE_ORIGIN=$($originUri.GetLeftPart([System.UriPartial]::Authority))"
    )
    [System.IO.File]::WriteAllLines($secretEnvPath, $secretLines, [System.Text.UTF8Encoding]::new($false))

    & $supabase.Source 'secrets' 'set' '--project-ref' $ProjectRef '--env-file' $secretEnvPath 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Supabase CLI failed with exit code $LASTEXITCODE. CLI output was suppressed to prevent accidental disclosure."
    }
}
finally {
    Remove-Item -LiteralPath $secretEnvPath -Force -ErrorAction Stop
}

Write-Output 'Supabase notification secrets were configured without displaying their values.'
