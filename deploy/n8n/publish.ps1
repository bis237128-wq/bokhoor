[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GitExePath
)

$ErrorActionPreference = 'Stop'

if (!(Test-Path -LiteralPath $GitExePath -PathType Leaf) -or
    [System.IO.Path]::GetFileName($GitExePath) -ine 'git.exe') {
    throw 'Provide the full path to an existing git.exe.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$safeRepoRoot = $repoRoot -replace '\\', '/'
$secretFile = Join-Path $PSScriptRoot '.env'
$expectedRemote = '(?i)(github\.com[:/]bis237128-wq/bokhoor)(\.git)?$'
$paths = @(
    '.gitignore',
    'deploy/n8n/compose.yaml',
    'deploy/n8n/Caddyfile',
    'deploy/n8n/.env.example',
    'deploy/n8n/README.md',
    'deploy/n8n/initialize.ps1',
    'deploy/n8n/deploy.ps1',
    'deploy/n8n/configure-supabase.ps1',
    'deploy/n8n/bootstrap.sh',
    'deploy/n8n/publish.ps1'
)

if (!(Test-Path -LiteralPath $secretFile)) {
    throw 'The local .env is missing; no repository changes were staged.'
}

$ignoreText = Get-Content -LiteralPath (Join-Path $repoRoot '.gitignore') -Raw
if ($ignoreText -notmatch '(?m)^/deploy/n8n/\.env\r?$') {
    throw 'The local .env is not explicitly ignored; no repository changes were staged.'
}

$secretPatterns = @(
    '(?i)trycloudflare\.com',
    '(?i)(N8N_WEBHOOK_TOKEN|POSTGRES_PASSWORD|N8N_ENCRYPTION_KEY|ULTRAMSG_TOKEN)\s*[:=]\s*["''][0-9a-f]{64}["'']',
    '(?i)Bearer\s+[A-Za-z0-9._-]{24,}'
)
foreach ($path in $paths) {
    $fullPath = Join-Path $repoRoot $path
    if (!(Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Expected deployment file is missing: $path"
    }
    foreach ($pattern in $secretPatterns) {
        if (Select-String -LiteralPath $fullPath -Pattern $pattern -Quiet) {
            throw "A secret or temporary tunnel pattern was found in $path; no changes were staged."
        }
    }
}

function Invoke-GitCapture {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & $GitExePath '-c' "safe.directory=$safeRepoRoot" '-C' $repoRoot @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $command = $Arguments[0]
        throw "Git command '$command' failed with exit code $exitCode. Output was suppressed."
    }
    return ,$output
}

$trackedSecret = & $GitExePath '-c' "safe.directory=$safeRepoRoot" '-C' $repoRoot 'ls-files' '--' 'deploy/n8n/.env' 2>&1
if ($LASTEXITCODE -ne 0) {
    throw 'Could not verify whether the local .env is tracked; no changes were staged or pushed.'
}
if ($trackedSecret) {
    throw 'The local .env is already tracked by Git; no changes were staged or pushed.'
}

$ignoreCheck = & $GitExePath '-c' "safe.directory=$safeRepoRoot" '-C' $repoRoot 'check-ignore' '-q' '--' 'deploy/n8n/.env' 2>$null
if ($LASTEXITCODE -ne 0) {
    throw 'Git does not ignore the local .env; no changes were staged or pushed.'
}

$remoteLines = Invoke-GitCapture -Arguments @('remote', 'get-url', 'origin')
$remoteUrl = [string]($remoteLines | Select-Object -First 1)
if ($remoteUrl -notmatch $expectedRemote) {
    throw 'The origin remote does not match the authorized GitHub repository; no changes were staged.'
}

$branchLines = Invoke-GitCapture -Arguments @('branch', '--show-current')
$branch = [string]($branchLines | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace($branch)) {
    throw 'Git is not on a named branch; no changes were staged.'
}

$null = Invoke-GitCapture -Arguments @('var', 'GIT_AUTHOR_IDENT')

Push-Location $repoRoot
try {
    $null = Invoke-GitCapture -Arguments (@('add', '--') + $paths)
    $null = Invoke-GitCapture -Arguments (@('diff', '--cached', '--check', '--') + $paths)
    $stagedNames = Invoke-GitCapture -Arguments (@('diff', '--cached', '--name-only', '--') + $paths)
    foreach ($stagedName in $stagedNames) {
        if ($paths -notcontains ([string]$stagedName).Trim()) {
            throw 'Unexpected staged path detected; no commit was created.'
        }
    }

    $message = "Add secure always-on n8n deployment`n`nCo-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
    $null = Invoke-GitCapture -Arguments (@('commit', '--only', '-m', $message, '--') + $paths)
    $commitLines = Invoke-GitCapture -Arguments @('rev-parse', '--short', 'HEAD')
    $commit = [string]($commitLines | Select-Object -First 1)
    $null = Invoke-GitCapture -Arguments @('push', 'origin', $branch)
}
finally {
    Pop-Location
}

Write-Output "PUSH_SUCCEEDED commit=$commit"
