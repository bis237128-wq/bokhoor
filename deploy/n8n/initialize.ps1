$ErrorActionPreference = 'Stop'

$envPath = Join-Path $PSScriptRoot '.env'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$ignorePath = Join-Path $repoRoot '.gitignore'

if (Test-Path -LiteralPath $envPath) {
    throw 'The local .env already exists. It was not overwritten.'
}
if (!(Test-Path -LiteralPath $ignorePath) -or
    (Get-Content -LiteralPath $ignorePath -Raw) -notmatch '(?m)^/deploy/n8n/\.env\r?$') {
    throw 'The deployment .env is not explicitly ignored by Git.'
}

function New-RandomHex {
    param([int]$ByteCount)

    $bytes = New-Object byte[] $ByteCount
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
    }
    finally {
        $generator.Dispose()
    }
    return [System.BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
}

$postgresPassword = New-RandomHex -ByteCount 32
$encryptionKey = New-RandomHex -ByteCount 32
$webhookToken = New-RandomHex -ByteCount 32
$lines = [string[]]@(
    'N8N_DOMAIN=replace-before-deployment',
    'LETSENCRYPT_EMAIL=replace-before-deployment',
    '',
    'POSTGRES_DB=n8n',
    'POSTGRES_USER=n8n',
    "POSTGRES_PASSWORD=$postgresPassword",
    "N8N_ENCRYPTION_KEY=$encryptionKey",
    "N8N_WEBHOOK_TOKEN=$webhookToken"
)

[System.IO.File]::WriteAllLines($envPath, $lines, [System.Text.UTF8Encoding]::new($false))

try {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
    & $icacls $envPath '/inheritance:r' '/grant:r' "${identity}:(F)" 'SYSTEM:(F)' '*S-1-5-32-544:(F)' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not restrict access to the local .env file.'
    }
}
catch {
    Remove-Item -LiteralPath $envPath -Force -ErrorAction SilentlyContinue
    throw
}

Write-Output 'Created a protected local deployment .env. Secret values were not displayed.'
