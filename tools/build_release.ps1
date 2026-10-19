# Müsvedde sürüm derleme betiği
#
# Kullanım (proje kökünde):
#   powershell -ExecutionPolicy Bypass -File tools\build_release.ps1
#
# 1. pubspec.yaml'dan sürüm numarasını okur
# 2. Windows sürümünü derler (flutter build windows --release)
# 3. Inno Setup ile dist\MusveddeKurulum-<sürüm>.exe dosyasını üretir

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

$pubspec = Get-Content -Raw -Encoding UTF8 pubspec.yaml
if ($pubspec -notmatch '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)') {
    throw 'pubspec.yaml içinde "version: 1.2.3+4" biçiminde sürüm bulunamadı.'
}
$version = $Matches[1]
Write-Host "Müsvedde $version derleniyor..." -ForegroundColor Cyan

flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw 'Flutter derlemesi başarısız oldu.' }

# Inno Setup'ı sürüm numarasından bağımsız ara: kullanıcı ve sistem
# kurulum klasörleri, ardından PATH.
$roots = @("$env:LOCALAPPDATA\Programs", ${env:ProgramFiles(x86)}, $env:ProgramFiles) |
    Where-Object { $_ -and (Test-Path $_) }
$iscc = Get-ChildItem -Path $roots -Directory -Filter 'Inno Setup*' -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    ForEach-Object { Join-Path $_.FullName 'ISCC.exe' } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1
if (-not $iscc) {
    $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($cmd) { $iscc = $cmd.Source }
}
if (-not $iscc) { throw 'Inno Setup bulunamadı. jrsoftware.org adresinden kur ya da ISCC.exe klasörünü PATH''e ekle.' }

Write-Host "Inno Setup: $iscc"
& $iscc "/DAppVersion=$version" installer\musvedde.iss
if ($LASTEXITCODE -ne 0) { throw 'Kurulum paketi oluşturulamadı.' }

$out = "dist\MusveddeKurulum-$version.exe"
$hash = (Get-FileHash $out -Algorithm SHA256).Hash.ToLower()
Write-Host ""
Write-Host "Hazır: $out" -ForegroundColor Green
Write-Host "SHA-256: $hash"