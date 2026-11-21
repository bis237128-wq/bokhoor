@echo off
setlocal
set "N8N_ROOT=%LOCALAPPDATA%\BakhoorN8N"
if not exist "%N8N_ROOT%\node_modules\n8n\bin\n8n.cmd" set "N8N_ROOT=%LOCALAPPDATA%\Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Local\BakhoorN8N"
set "N8N_USER_FOLDER=%N8N_ROOT%"
set "N8N_BIN=%N8N_ROOT%\node_modules\n8n\bin\n8n"
set "CLOUDFLARED=%N8N_ROOT%\cloudflared.exe"
set "N8N_LISTEN_ADDRESS=127.0.0.1"
set "N8N_PORT=5678"

for /f "delims=" %%N in ('where node 2^>nul') do if not defined NODE_EXE set "NODE_EXE=%%N"
if not defined NODE_EXE set "NODE_EXE=%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe"
if not exist "%NODE_EXE%" (
  echo Node.js is not available at the expected location: "%NODE_EXE%"
  pause
  exit /b 1
)
for %%N in ("%NODE_EXE%") do set "NODE_DIR=%%~dpN"
set "PATH=%NODE_DIR%;%PATH%"
if not exist "%N8N_BIN%" (
  echo n8n is not installed under "%N8N_ROOT%".
  pause
  exit /b 1
)
if not exist "%CLOUDFLARED%" (
  echo Cloudflare Tunnel is not installed under "%N8N_ROOT%".
  pause
  exit /b 1
)

echo Importing and publishing the WhatsApp workflow...
"%NODE_EXE%" "%N8N_BIN%" import:workflow --input="%~dp0n8n-whatsapp-workflow.json"
if errorlevel 1 goto failed
"%NODE_EXE%" "%N8N_BIN%" publish:workflow --id=1aUqT9BQvGLCRLDp
if errorlevel 1 goto failed

powershell -NoProfile -Command "$l=Get-NetTCPConnection -State Listen -LocalPort 5678 -ErrorAction SilentlyContinue; if(-not $l){Start-Process -FilePath '%NODE_EXE%' -ArgumentList @('%N8N_BIN%','start') -WorkingDirectory '%N8N_ROOT%' -WindowStyle Hidden -RedirectStandardOutput '%N8N_ROOT%\n8n.out.log' -RedirectStandardError '%N8N_ROOT%\n8n.err.log'}"
if errorlevel 1 goto failed
powershell -NoProfile -Command "$p=Get-Process -Name cloudflared -ErrorAction SilentlyContinue; if(-not $p){Start-Process -FilePath '%CLOUDFLARED%' -ArgumentList @('tunnel','--url','http://127.0.0.1:5678','--no-autoupdate') -WorkingDirectory '%N8N_ROOT%' -WindowStyle Hidden -RedirectStandardOutput '%N8N_ROOT%\tunnel.out.log' -RedirectStandardError '%N8N_ROOT%\tunnel.err.log'}"
if errorlevel 1 goto failed

echo n8n is configured on port 5678 and the Cloudflare tunnel is running.
echo Quick Tunnel addresses are temporary; update the N8N_WEBHOOK_URL Supabase secret if the address changes.
pause
exit /b 0

:failed
echo Automation setup failed. Check the n8n logs under "%N8N_ROOT%".
pause
exit /b 1
