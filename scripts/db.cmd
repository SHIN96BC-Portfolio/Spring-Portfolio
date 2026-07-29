@echo off
setlocal EnableExtensions
set "DIR=%~dp0"
set "CMD=%~1"

if "%CMD%"=="" goto help
if /I "%CMD%"=="help" goto help
if /I "%CMD%"=="-h" goto help
if /I "%CMD%"=="--help" goto help

if /I not "%CMD%"=="up" if /I not "%CMD%"=="down" if /I not "%CMD%"=="reset" goto unknown

where bash >nul 2>nul
if %ERRORLEVEL%==0 (
  bash "%DIR%db" %*
  exit /b %ERRORLEVEL%
)

where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%DIR%windows\%CMD%.ps1"
  exit /b %ERRORLEVEL%
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%windows\%CMD%.ps1"
exit /b %ERRORLEVEL%

:help
where bash >nul 2>nul
if %ERRORLEVEL%==0 (
  bash "%DIR%db" help
  exit /b 0
)
echo db — 로컬 개발용 DB 컨테이너 관리
echo.
echo Usage:
echo   db up       Postgres + Mongo + Kafka/Redis 인프라 기동
echo   db down     컨테이너 중지 (볼륨·데이터 유지)
echo   db reset    컨테이너 중지 후 볼륨 삭제, 재기동 (V1 스키마 재적용)
echo   db help     이 도움말
exit /b 0

:unknown
echo Unknown command: %CMD%
echo Run 'db help' for usage.
exit /b 1
