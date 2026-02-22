<#
FORK-MAINTENANCE NOTE (GLM-OCR branch)
- This script can apply `scripts/patches/llama.cpp.mtmd-tools.patch` before packing.
- The patch is tracked in this repo so local package rebuilds stay reproducible after upstream LLamaSharp merges.
- If upstream llama.cpp changes and patch apply fails, update the patch file and commit it in this branch.
- If you later maintain your own llama.cpp fork, commit equivalent changes there and update submodule URL/pointer.
#>

param(
    [string]$Version = "0.26.1-glmocr-local8",
    [string]$Configuration = "Release",
    [string]$OutputDirectory = ".artifacts/nuget-glm-ocr-local8",
    [string]$LlamaCppRelease = "b8093",
    [switch]$SyncOfficialBinaries = $true,
    [switch]$ApplyLocalLlamaCppPatch = $true
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

function Apply-OptionalLlamaCppPatch {
    param(
        [string]$RepositoryRoot
    )

    $patchPath = Join-Path $RepositoryRoot "scripts/patches/llama.cpp.mtmd-tools.patch"
    if (-not (Test-Path $patchPath)) {
        Write-Host "No local llama.cpp patch found at '$patchPath'; continuing."
        return
    }

    $llamaCppRoot = Join-Path $RepositoryRoot "llama.cpp"
    if (-not (Test-Path $llamaCppRoot)) {
        throw "llama.cpp submodule directory was not found at '$llamaCppRoot'."
    }

    Write-Host "Checking optional llama.cpp local patch..."
    Push-Location $llamaCppRoot
    $previousNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        # Keep this idempotent so repeated local rebuilds remain deterministic.
        # Already applied? Keep going without changing local work.
        & git apply --reverse --check $patchPath *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Local llama.cpp patch is already applied."
            return
        }

        # Not applied yet; apply now.
        # Fail fast when upstream drift requires a patch refresh.
        & git apply --check $patchPath *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to apply local llama.cpp patch '$patchPath'. Resolve submodule state first."
        }

        & git apply $patchPath
        if ($LASTEXITCODE -ne 0) {
            throw "Applying local llama.cpp patch '$patchPath' failed."
        }

        Write-Host "Applied local llama.cpp patch."
    }
    finally {
        $PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference
        Pop-Location
    }
}

function Copy-IfExists {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )

    if (-not (Test-Path $SourcePath)) {
        return
    }

    $destinationDirectory = Split-Path -Path $DestinationPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($destinationDirectory)) {
        New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
    }

    Copy-Item -Path $SourcePath -Destination $DestinationPath -Force
}

function Copy-OfficialCpuRuntimeSet {
    param(
        [string]$SourceDirectory,
        [string]$DestinationDirectory,
        [switch]$IncludeVulkan
    )

    New-Item -ItemType Directory -Force -Path $DestinationDirectory | Out-Null

    $coreFiles = @(
        "llama.dll",
        "mtmd.dll",
        "ggml.dll",
        "ggml-base.dll",
        "libomp140.x86_64.dll",
        "ggml-rpc.dll"
    )
    foreach ($coreFile in $coreFiles) {
        Copy-IfExists -SourcePath (Join-Path $SourceDirectory $coreFile) -DestinationPath (Join-Path $DestinationDirectory $coreFile)
    }

    if ($IncludeVulkan) {
        Copy-IfExists -SourcePath (Join-Path $SourceDirectory "ggml-vulkan.dll") -DestinationPath (Join-Path $DestinationDirectory "ggml-vulkan.dll")
    }

    Get-ChildItem -Path $SourceDirectory -Filter "ggml-cpu-*.dll" -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-IfExists -SourcePath $_.FullName -DestinationPath (Join-Path $DestinationDirectory $_.Name)
    }

    # Compatibility alias: LLamaSharp loader still probes ggml-cpu.dll in CPU folders.
    if (Test-Path (Join-Path $SourceDirectory "ggml-cpu-x64.dll")) {
        Copy-IfExists -SourcePath (Join-Path $SourceDirectory "ggml-cpu-x64.dll") -DestinationPath (Join-Path $DestinationDirectory "ggml-cpu.dll")
    }
    else {
        Copy-IfExists -SourcePath (Join-Path $SourceDirectory "ggml-cpu.dll") -DestinationPath (Join-Path $DestinationDirectory "ggml-cpu.dll")
    }
}

function Copy-OfficialLinuxRuntimeSet {
    param(
        [string]$SourceDirectory,
        [string]$DestinationDirectory,
        [switch]$IncludeVulkan
    )

    New-Item -ItemType Directory -Force -Path $DestinationDirectory | Out-Null

    $coreFiles = @(
        "libllama.so",
        "libmtmd.so",
        "libggml.so",
        "libggml-base.so",
        "libggml-rpc.so"
    )

    foreach ($coreFile in $coreFiles) {
        Copy-IfExists -SourcePath (Join-Path $SourceDirectory $coreFile) -DestinationPath (Join-Path $DestinationDirectory $coreFile)
    }

    if ($IncludeVulkan) {
        Copy-IfExists -SourcePath (Join-Path $SourceDirectory "libggml-vulkan.so") -DestinationPath (Join-Path $DestinationDirectory "libggml-vulkan.so")
    }

    Get-ChildItem -Path $SourceDirectory -Filter "libggml-cpu-*.so" -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-IfExists -SourcePath $_.FullName -DestinationPath (Join-Path $DestinationDirectory $_.Name)
    }

    # Compatibility alias: current LLamaSharp loader still probes libggml-cpu.so.
    if (Test-Path (Join-Path $SourceDirectory "libggml-cpu-x64.so")) {
        Copy-IfExists -SourcePath (Join-Path $SourceDirectory "libggml-cpu-x64.so") -DestinationPath (Join-Path $DestinationDirectory "libggml-cpu.so")
    }
    else {
        Copy-IfExists -SourcePath (Join-Path $SourceDirectory "libggml-cpu.so") -DestinationPath (Join-Path $DestinationDirectory "libggml-cpu.so")
    }
}

function Copy-OfficialMacRuntimeSet {
    param(
        [string]$SourceDirectory,
        [string]$DestinationDirectory,
        [switch]$IncludeMetal
    )

    New-Item -ItemType Directory -Force -Path $DestinationDirectory | Out-Null

    $coreFiles = @(
        "libllama.dylib",
        "libmtmd.dylib",
        "libggml.dylib",
        "libggml-base.dylib",
        "libggml-cpu.dylib",
        "libggml-blas.dylib",
        "libggml-rpc.dylib"
    )

    foreach ($coreFile in $coreFiles) {
        Copy-IfExists -SourcePath (Join-Path $SourceDirectory $coreFile) -DestinationPath (Join-Path $DestinationDirectory $coreFile)
    }

    if ($IncludeMetal) {
        Copy-IfExists -SourcePath (Join-Path $SourceDirectory "libggml-metal.dylib") -DestinationPath (Join-Path $DestinationDirectory "libggml-metal.dylib")
    }
}

function Sync-OfficialLlamaCppRuntimeBinaries {
    param(
        [string]$RepositoryRoot,
        [string]$ReleaseTag
    )

    $downloadRoot = Join-Path $RepositoryRoot ".artifacts/llama.cpp-$ReleaseTag"
    New-Item -ItemType Directory -Force -Path $downloadRoot | Out-Null

    function Expand-OfficialAssetArchive {
        param(
            [string]$AssetName,
            [string]$ExtractFolderName
        )

        $zipPath = Join-Path $downloadRoot $AssetName
        if (-not (Test-Path $zipPath)) {
            $assetUrl = "https://github.com/ggml-org/llama.cpp/releases/download/$ReleaseTag/$AssetName"
            Write-Host "Downloading official llama.cpp asset: $AssetName"
            Invoke-WebRequest -Uri $assetUrl -OutFile $zipPath
        }

        $extractPath = Join-Path $downloadRoot $ExtractFolderName
        if (Test-Path $extractPath) {
            Remove-Item -Recurse -Force $extractPath
        }
        New-Item -ItemType Directory -Force -Path $extractPath | Out-Null

        if ($AssetName.EndsWith(".zip", [StringComparison]::OrdinalIgnoreCase)) {
            Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
        }
        elseif ($AssetName.EndsWith(".tar.gz", [StringComparison]::OrdinalIgnoreCase)) {
            & tar -xzf $zipPath -C $extractPath
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to extract archive '$AssetName'."
            }
        }
        else {
            throw "Unsupported archive type for '$AssetName'."
        }

        $singleChildDirectory = Get-ChildItem -Path $extractPath -Directory | Select-Object -First 1
        if ($singleChildDirectory) {
            return $singleChildDirectory.FullName
        }

        return $extractPath
    }

    Write-Host "Syncing official llama.cpp binaries from release $ReleaseTag ..."
    $cpuWinX64Path = Expand-OfficialAssetArchive -AssetName "llama-$ReleaseTag-bin-win-cpu-x64.zip" -ExtractFolderName "win-cpu-x64"
    $vulkanWinX64Path = Expand-OfficialAssetArchive -AssetName "llama-$ReleaseTag-bin-win-vulkan-x64.zip" -ExtractFolderName "win-vulkan-x64"
    $cpuWinArm64Path = Expand-OfficialAssetArchive -AssetName "llama-$ReleaseTag-bin-win-cpu-arm64.zip" -ExtractFolderName "win-cpu-arm64"
    $cpuLinuxX64Path = Expand-OfficialAssetArchive -AssetName "llama-$ReleaseTag-bin-ubuntu-x64.tar.gz" -ExtractFolderName "ubuntu-x64"
    $vulkanLinuxX64Path = Expand-OfficialAssetArchive -AssetName "llama-$ReleaseTag-bin-ubuntu-vulkan-x64.tar.gz" -ExtractFolderName "ubuntu-vulkan-x64"
    $macosX64Path = Expand-OfficialAssetArchive -AssetName "llama-$ReleaseTag-bin-macos-x64.tar.gz" -ExtractFolderName "macos-x64"
    $macosArm64Path = Expand-OfficialAssetArchive -AssetName "llama-$ReleaseTag-bin-macos-arm64.tar.gz" -ExtractFolderName "macos-arm64"

    $runtimeDepsRoot = Join-Path $RepositoryRoot "LLama/runtimes/deps"
    $x64CpuTargets = @("noavx", "avx", "avx2", "avx512")
    foreach ($target in $x64CpuTargets) {
        Copy-OfficialCpuRuntimeSet -SourceDirectory $cpuWinX64Path -DestinationDirectory (Join-Path $runtimeDepsRoot $target)
    }

    Copy-OfficialCpuRuntimeSet -SourceDirectory $vulkanWinX64Path -DestinationDirectory (Join-Path $runtimeDepsRoot "vulkan") -IncludeVulkan

    foreach ($target in $x64CpuTargets) {
        Copy-OfficialLinuxRuntimeSet -SourceDirectory $cpuLinuxX64Path -DestinationDirectory (Join-Path $runtimeDepsRoot $target)
    }

    Copy-OfficialLinuxRuntimeSet -SourceDirectory $vulkanLinuxX64Path -DestinationDirectory (Join-Path $runtimeDepsRoot "vulkan") -IncludeVulkan

    Copy-OfficialMacRuntimeSet -SourceDirectory $macosX64Path -DestinationDirectory (Join-Path $runtimeDepsRoot "osx-x64")
    Copy-OfficialMacRuntimeSet -SourceDirectory $macosX64Path -DestinationDirectory (Join-Path $runtimeDepsRoot "osx-x64-rosetta2")
    Copy-OfficialMacRuntimeSet -SourceDirectory $macosArm64Path -DestinationDirectory (Join-Path $runtimeDepsRoot "osx-arm64") -IncludeMetal

    Write-Host "Note: official $ReleaseTag assets do not include linux-arm64 or linux-musl builds; existing LLamaSharp payloads for those RIDs were left unchanged."

    $arm64Destination = Join-Path $runtimeDepsRoot "win-arm64"
    New-Item -ItemType Directory -Force -Path $arm64Destination | Out-Null
    $arm64Files = @(
        "llama.dll",
        "mtmd.dll",
        "ggml.dll",
        "ggml-base.dll",
        "ggml-cpu.dll",
        "ggml-rpc.dll",
        "libomp140.aarch64.dll"
    )
    foreach ($arm64File in $arm64Files) {
        Copy-IfExists -SourcePath (Join-Path $cpuWinArm64Path $arm64File) -DestinationPath (Join-Path $arm64Destination $arm64File)
    }
}

if ($ApplyLocalLlamaCppPatch) {
    Apply-OptionalLlamaCppPatch -RepositoryRoot $repoRoot
}
else {
    Write-Host "Skipping optional llama.cpp local patch (ApplyLocalLlamaCppPatch disabled)."
}

if ($SyncOfficialBinaries) {
    Sync-OfficialLlamaCppRuntimeBinaries -RepositoryRoot $repoRoot -ReleaseTag $LlamaCppRelease
}
else {
    Write-Host "Skipping official llama.cpp binary sync (SyncOfficialBinaries disabled)."
}

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
# Force a real rebuild so managed loader changes are always reflected in the packed DLL.
# We explicitly skip LLamaSharp's upstream deps.zip refresh here because this script has
# already prepared runtime payloads (including official llama.cpp overlay) under runtimes/deps.
dotnet build (Join-Path $repoRoot "LLama/LLamaSharp.csproj") `
    -c $Configuration `
    /t:Rebuild `
    /p:SkipDownloadReleaseBinaries=true
dotnet pack (Join-Path $repoRoot "LLama/LLamaSharp.csproj") `
    -c $Configuration `
    --no-build `
    -o $outputPath `
    /p:PackageVersion=$Version `
    /p:Version=$Version `
    /p:SkipDownloadReleaseBinaries=true `
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
