[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SshTarget,

    [Parameter(Mandatory = $true)]
    [string]$Domain,

    [Parameter(Mandatory = $true)]
    [string]$LetsEncryptEmail
)

$ErrorActionPreference = 'Stop'

if ($SshTarget -notmatch '^[A-Za-z0-9._@-]+$') {
    throw 'SSH target must be an SSH alias, user@host, or IP-based target without extra options.'
}
if ($Domain -notmatch '^(?=.{1,253}$)([A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$') {
    throw 'A fully qualified public domain is required.'
}
if ($LetsEncryptEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
    throw 'A valid certificate contact email is required.'
}

$ssh = Get-Command ssh -ErrorAction SilentlyContinue
$scp = Get-Command scp -ErrorAction SilentlyContinue
if (!$ssh -or !$scp) {
    throw 'OpenSSH client tools ssh and scp are required.'
}

$envPath = Join-Path $PSScriptRoot '.env'
$ignorePath = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path '.gitignore'
if (!(Test-Path -LiteralPath $envPath)) {
    throw 'Run initialize.ps1 first to create the protected local .env file.'
}
if (!(Test-Path -LiteralPath $ignorePath) -or
    (Get-Content -LiteralPath $ignorePath -Raw) -notmatch '(?m)^/deploy/n8n/\.env\r?$') {
    throw 'The deployment .env is not explicitly ignored by Git.'
}

$lines = [System.Collections.Generic.List[string]]::new()
$lines.AddRange([System.IO.File]::ReadAllLines($envPath))
$values = @{}
foreach ($line in $lines) {
    if ($line -match '^([A-Z0-9_]+)=(.*)$') {
        $values[$matches[1]] = $matches[2]
    }
}

foreach ($key in @('POSTGRES_PASSWORD', 'N8N_ENCRYPTION_KEY', 'N8N_WEBHOOK_TOKEN')) {
    if ($values[$key] -notmatch '^[A-Fa-f0-9]{64}$') {
        throw "The local .env does not contain a valid $key value."
    }
}

$updates = @{
    N8N_DOMAIN = $Domain
    LETSENCRYPT_EMAIL = $LetsEncryptEmail
}
$found = @{}
$updatedLines = [System.Collections.Generic.List[string]]::new()
foreach ($line in $lines) {
    if ($line -match '^([A-Z0-9_]+)=') {
        $key = $matches[1]
        if ($updates.ContainsKey($key)) {
            $updatedLines.Add("$key=$($updates[$key])")
            $found[$key] = $true
            continue
        }
    }
    $updatedLines.Add($line)
}
foreach ($key in $updates.Keys) {
    if (!$found.ContainsKey($key)) {
        $updatedLines.Add("$key=$($updates[$key])")
    }
}
[System.IO.File]::WriteAllLines($envPath, $updatedLines, [System.Text.UTF8Encoding]::new($false))

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$([System.IO.Path]::GetFileName($Executable)) failed with exit code $LASTEXITCODE."
    }
}

$remoteEnvPath = Join-Path $env:TEMP ('.bakhoor-n8n-' + [guid]::NewGuid().ToString('N') + '.env')
[System.IO.File]::Create($remoteEnvPath).Dispose()
try {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
    & $icacls $remoteEnvPath '/inheritance:r' '/grant:r' "${identity}:(F)" 'SYSTEM:(F)' '*S-1-5-32-544:(F)' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not restrict access to the temporary deployment file.'
    }

    $remoteEnvLines = [string[]]@(
        "N8N_DOMAIN=$Domain",
        "LETSENCRYPT_EMAIL=$LetsEncryptEmail",
        'POSTGRES_DB=n8n',
        'POSTGRES_USER=n8n',
        "POSTGRES_PASSWORD=$($values['POSTGRES_PASSWORD'])",
        "N8N_ENCRYPTION_KEY=$($values['N8N_ENCRYPTION_KEY'])"
    )
    [System.IO.File]::WriteAllLines($remoteEnvPath, $remoteEnvLines, [System.Text.UTF8Encoding]::new($false))

    $remoteDirectory = 'bakhoor-n8n'
    Invoke-ExternalCommand -Executable $ssh.Source -Arguments @(
        $SshTarget,
        "umask 077; mkdir -p ~/$remoteDirectory; chmod 700 ~/$remoteDirectory"
    )

    $remotePrefix = '{0}:{1}/' -f $SshTarget, $remoteDirectory
    $safeFiles = @(
        (Join-Path $PSScriptRoot 'compose.yaml'),
        (Join-Path $PSScriptRoot 'Caddyfile'),
        (Join-Path $PSScriptRoot 'bootstrap.sh')
    )
    Invoke-ExternalCommand -Executable $scp.Source -Arguments ($safeFiles + @($remotePrefix))
    Invoke-ExternalCommand -Executable $scp.Source -Arguments @(
        $remoteEnvPath,
        ('{0}:{1}/.env' -f $SshTarget, $remoteDirectory)
    )
    Invoke-ExternalCommand -Executable $ssh.Source -Arguments @(
        $SshTarget,
        "chmod 600 ~/$remoteDirectory/.env && bash ~/$remoteDirectory/bootstrap.sh"
    )
}
finally {
    Remove-Item -LiteralPath $remoteEnvPath -Force -ErrorAction Stop
}

Write-Output 'Deployment commands completed without displaying secret values.'
Write-Output 'Finish n8n owner-account setup and recreate the two workflow credentials in the cloud editor.'
