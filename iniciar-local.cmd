@echo off
cd /d "%~dp0"
if exist ".tools\node.exe" set "PATH=%CD%\.tools;%PATH%"
where node >nul 2>nul
if errorlevel 1 (
  echo Instale o Node.js 20 ou superior e execute novamente.
  pause
  exit /b 1
)
if not exist "node_modules\@electric-sql\pglite" (
  echo Execute npm ci antes de iniciar o painel.
  pause
  exit /b 1
)
node scripts/build.mjs
if errorlevel 1 exit /b 1
node ferramentas/servidor-local.mjs
pause
