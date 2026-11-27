$ErrorActionPreference = 'Stop'
Push-Location (Join-Path $PSScriptRoot '..')
try {
    $cargo = Get-Command cargo -ErrorAction SilentlyContinue
    if (!$cargo) { $cargo = Get-Command "$env:USERPROFILE/.cargo/bin/cargo.exe" }
    & $cargo build --release --locked
    if ($LASTEXITCODE) { throw 'Rust build failed' }
    $out = New-Item -ItemType Directory -Force dist/windows-x64
    $archive = Join-Path $out 'mihomo.zip'
    $url = 'https://github.com/MetaCubeX/mihomo/releases/download/v1.19.34/mihomo-windows-amd64-compatible-v1.19.34.zip'
    curl.exe --fail --location --silent --show-error --retry 2 $url -o $archive
    if ($LASTEXITCODE -or (Get-FileHash $archive).Hash -ne 'cd6738d4648cc1a5f48049a1343b697ab510889d648f045c5c780fc1ab443a79') { throw 'Mihomo checksum mismatch' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $entry = @($zip.Entries | Where-Object Name -Like '*.exe')[0]
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,(Join-Path $out 'mihomo.exe'),$true)
    } finally { $zip.Dispose() }
    Remove-Item -LiteralPath $archive
    Copy-Item target/release/netpilot-core.exe $out
    Copy-Item 'scripts/MIHOMO-LICENSE' $out
    Write-Output $out.FullName
} finally { Pop-Location }
