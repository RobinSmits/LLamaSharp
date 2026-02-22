param(
    [string]$Version = "0.26.1-glmocr-local4",
    [string]$Configuration = "Release",
    [string]$OutputDirectory = ".artifacts/nuget-glm-ocr"
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$outputPath = if ([System.IO.Path]::IsPathRooted($OutputDirectory)) {
    $OutputDirectory
} else {
    (Join-Path $repoRoot $OutputDirectory)
}

$tempPath = Join-Path $repoRoot ".artifacts/nuget-glm-ocr-temp"

Write-Host "Packing GLM-OCR local LLamaSharp packages"
Write-Host "Version: $Version"
Write-Host "Output : $outputPath"

$nugetCommand = $null
$nugetInPath = Get-Command nuget -ErrorAction SilentlyContinue
if ($nugetInPath) {
    $nugetCommand = $nugetInPath.Source
}
else {
    $toolsPath = Join-Path $repoRoot ".artifacts/tools"
    $localNugetPath = Join-Path $toolsPath "nuget.exe"
    if (-not (Test-Path $localNugetPath)) {
        New-Item -ItemType Directory -Force -Path $toolsPath | Out-Null
        Write-Host "nuget.exe not found in PATH, downloading local copy..."
        Invoke-WebRequest -Uri "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe" -OutFile $localNugetPath
    }
    $nugetCommand = $localNugetPath
}

New-Item -ItemType Directory -Force -Path $outputPath | Out-Null

if (Test-Path $tempPath) {
    Remove-Item -Recurse -Force $tempPath
}
New-Item -ItemType Directory -Force -Path $tempPath | Out-Null

Write-Host "Restoring and packing LLamaSharp managed package..."
dotnet restore (Join-Path $repoRoot "LLama/LLamaSharp.csproj")
dotnet pack (Join-Path $repoRoot "LLama/LLamaSharp.csproj") `
    -c $Configuration `
    -o $outputPath `
    /p:PackageVersion=$Version `
    /p:Version=$Version `
    /p:IncludeSymbols=false `
    /p:SymbolPackageFormat=snupkg

Write-Host "Preparing backend nuspec workspace..."
Copy-Item -Recurse -Force (Join-Path $repoRoot "LLama/runtimes") (Join-Path $tempPath "runtimes")
Copy-Item -Force (Join-Path $repoRoot "LLama/runtimes/build/*.*") $tempPath

$winArm64DepsPath = Join-Path $tempPath "runtimes/deps/win-arm64"
if (-not (Test-Path $winArm64DepsPath)) {
    Write-Host "win-arm64 deps were not found; removing win-arm64 entries from local nuspecs."
    Get-ChildItem -Path $tempPath -Filter "*.nuspec" | ForEach-Object {
        $lines = Get-Content $_.FullName
        $filtered = $lines | Where-Object { $_ -notmatch "win-arm64" }
        Set-Content -Path $_.FullName -Value $filtered -Encoding UTF8
    }
}

Write-Host "Packing backend packages..."
$nuspecFiles = Get-ChildItem -Path $tempPath -Filter "*.nuspec" | Sort-Object Name
foreach ($nuspec in $nuspecFiles) {
    & $nugetCommand pack $nuspec.FullName -Version $Version -OutputDirectory $outputPath -NoPackageAnalysis | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "NuGet pack failed for '$($nuspec.Name)' with exit code $LASTEXITCODE."
    }
}

Write-Host "Done. Generated packages:"
Get-ChildItem -Path $outputPath -Filter "*.nupkg" | Sort-Object Name | ForEach-Object {
    Write-Host " - $($_.Name)"
}
