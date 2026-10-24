# Builds the Rust FFI dll and then the WinUI app.
# Run from this folder:  powershell -ExecutionPolicy Bypass -File build.ps1

$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$rust = Join-Path $here "..\..\Rust"

Write-Host "==> building voanisa-ffi (release)" -ForegroundColor Cyan
Push-Location $rust
try {
    cargo build -p voanisa-ffi --release
} finally {
    Pop-Location
}

Write-Host "==> building the WinUI app" -ForegroundColor Cyan
dotnet build (Join-Path $here "Voanisa.Windows.csproj") -c Debug

Write-Host ""
Write-Host "Done. The exe is under bin\Debug\net8.0-windows10.0.19041.0\win-x64\" -ForegroundColor Green
Write-Host "It needs Windows App Runtime installed (see README) or set WindowsAppSDKSelfContained=true."
