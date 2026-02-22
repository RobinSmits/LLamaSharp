using LLama.Abstractions;
using LLama.Exceptions;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace LLama.Native
{
    internal static class NativeLibraryUtils
    {
        /// <summary>
        /// Try to load libllama/mtmd, using CPU feature detection to try and load a more specialised DLL if possible
        /// </summary>
        /// <returns>The library handle to unload later, or IntPtr.Zero if no library was loaded</returns>
        internal static IntPtr TryLoadLibrary(NativeLibraryConfig config, out INativeLibrary? loadedLibrary)
        {
#if NET6_0_OR_GREATER
            var description = config.CheckAndGatherDescription();
            var systemInfo = SystemInfo.Get();
            Log($"Loading library: '{config.NativeLibraryName.GetLibraryName()}'", LLamaLogLevel.Debug, config.LogCallback);

            // Get platform specific parts of the path (e.g. .so/.dll/.dylib, libName prefix or not)
            NativeLibraryUtils.GetPlatformPathParts(systemInfo.OSPlatform, out var os, out var ext, out var libPrefix);
            Log($"Detected OS Platform: '{systemInfo.OSPlatform}'", LLamaLogLevel.Info, config.LogCallback);
            Log($"Detected OS string: '{os}'", LLamaLogLevel.Debug, config.LogCallback);
            Log($"Detected extension string: '{ext}'", LLamaLogLevel.Debug, config.LogCallback);
            Log($"Detected prefix string: '{libPrefix}'", LLamaLogLevel.Debug, config.LogCallback);

            // Set the flag to ensure this config can no longer be modified
            config.LibraryHasLoaded = true;

            // Show the configuration we're working with
            Log(description.ToString(), LLamaLogLevel.Info, config.LogCallback);

            // Get the libraries ordered by priority from the selecting policy.
            var libraries = config.SelectingPolicy.Apply(description, systemInfo, config.LogCallback);

            // Try to load the libraries
            foreach (var library in libraries)
            {
                // Prepare the local library file and get the path.
                var paths = library.Prepare(systemInfo, config.LogCallback);
                
                foreach (var path in paths)
                {
                    Log($"Got relative library path '{path}' from local with {library.Metadata}, trying to load it...", LLamaLogLevel.Debug, config.LogCallback);
                    
                    // After the llama.cpp binaries have been split up (PR #10256), we need to load the dependencies manually.
                    // It can't be done automatically on Windows, because the dependencies can be in different folders (for example, ggml-cuda.dll from the cuda12 folder, and ggml-cpu.dll from the avx2 folder)
                    // It can't be done automatically on Linux, because Linux uses the environment variable "LD_LIBRARY_PATH" to automatically load dependencies, and LD_LIBRARY_PATH can only be
                    // set before running LLamaSharp, but we only know which folders to search in when running LLamaSharp (decided by the NativeLibrary).
                    
                    // Get the directory of the current runtime
                    string? currentRuntimeDirectory = Path.GetDirectoryName(path);

                    // If we failed to get the directory of the current runtime, log it and continue on to the next library
                    if (currentRuntimeDirectory == null)
                    {
                        Log($"Failed to get the directory of the current runtime from path '{path}'", LLamaLogLevel.Error, config.LogCallback);
                        continue;
                    }

                    // List which will hold all paths to dependencies to load
                    var dependencyPaths = new List<string>();
                    var dependencyPathSet = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

                    void AddDependency(string dependencyPath)
                    {
                        if (dependencyPathSet.Add(dependencyPath))
                            dependencyPaths.Add(dependencyPath);
                    }
                    
                    // If the library has metadata, we can check if we need to load additional dependencies
                    if (library.Metadata != null)
                    {
                        if (systemInfo.OSPlatform == OSPlatform.OSX)
                        {
                            // On OSX, we should load the CPU backend from the current directory
                            
                            // ggml-cpu
                            AddDependency(Path.Combine(currentRuntimeDirectory, $"{libPrefix}ggml-cpu{ext}"));

                            // ggml-metal (only supported on osx-arm64)
                            if (os == "osx-arm64")
                                AddDependency(Path.Combine(currentRuntimeDirectory, $"{libPrefix}ggml-metal{ext}"));
                            
                            // ggml-blas (osx-x64, osx-x64-rosetta2 and osx-arm64 all have blas)
                            AddDependency(Path.Combine(currentRuntimeDirectory, $"{libPrefix}ggml-blas{ext}"));
                        }
                        else
                        {
                            // Probe backend-required DLLs first. If these are missing (for example CUDA on
                            // non-NVIDIA systems), we skip the candidate before loading shared ggml base libs.
                            // This avoids cross-candidate ABI contamination when falling back to another backend.
                            if (library.Metadata.UseCuda)
                                AddDependency(Path.Combine(currentRuntimeDirectory, $"{libPrefix}ggml-cuda{ext}"));

                            if (library.Metadata.UseVulkan)
                                AddDependency(Path.Combine(currentRuntimeDirectory, $"{libPrefix}ggml-vulkan{ext}"));

                            // On other platforms (Windows, Linux), we need to load the CPU backend from the specified AVX level directory
                            // We are using the AVX level supplied by NativeLibraryConfig, which automatically detects the highest supported AVX level for us
                            
                            if (os == "linux-arm64"){
                                AddDependency(Path.Combine(
                                    $"runtimes/{os}/native", 
                                    $"{libPrefix}ggml-cpu{ext}"
                                ));
                            }
                            else{
                                // ggml-cpu
                                AddDependency(Path.Combine(
                                    $"runtimes/{os}/native/{NativeLibraryConfig.AvxLevelToString(library.Metadata.AvxLevel)}",
                                    $"{libPrefix}ggml-cpu{ext}"
                                ));

                                // Newer official llama.cpp builds use dynamic cpu plugin binaries
                                // (e.g. ggml-cpu-x64.dll / ggml-cpu-haswell.dll) colocated with the backend.
                                // We preload whatever is present so ggml can resolve them reliably.
                                if (os.StartsWith("win-", StringComparison.OrdinalIgnoreCase))
                                {
                                    foreach (var cpuPlugin in SafeEnumerateFiles(currentRuntimeDirectory, "ggml-cpu-*.dll"))
                                    {
                                        AddDependency(cpuPlugin);
                                    }

                                    AddDependency(Path.Combine(currentRuntimeDirectory, "ggml-rpc.dll"));
                                }
                            }

                        }
                    }

                    // We always load ggml-base before ggml regardless of backend.
                    AddDependency(Path.Combine(currentRuntimeDirectory, $"{libPrefix}ggml-base{ext}"));
                    
                    // And finally, we can add ggml
                    AddDependency(Path.Combine(currentRuntimeDirectory, $"{libPrefix}ggml{ext}"));
                    
                    // Now, we will loop through our dependencyPaths and try to load them one by one
                    var requiredDependencyMissing = false;
                    foreach (var dependencyPath in dependencyPaths)
                    {
                        // Try to load the dependency
                        var dependencyResult = TryLoad(dependencyPath, description.SearchDirectories, config.LogCallback);
                        var isRequiredDependency = IsRequiredDependency(dependencyPath, library.Metadata, ext, libPrefix);
                        
                        // If we successfully loaded the library, log it
                        if (dependencyResult != IntPtr.Zero)
                        {
                            Log($"Successfully loaded dependency '{dependencyPath}'", LLamaLogLevel.Info, config.LogCallback);
                        }
                        else
                        {
                            Log($"Failed loading dependency '{dependencyPath}'", LLamaLogLevel.Info, config.LogCallback);
                            if (isRequiredDependency)
                            {
                                requiredDependencyMissing = true;
                                Log(
                                    $"Required dependency '{dependencyPath}' is missing; skipping candidate '{path}'.",
                                    LLamaLogLevel.Warning,
                                    config.LogCallback);
                                break;
                            }
                        }
                    }

                    if (requiredDependencyMissing)
                        continue;
                    
                    // Try to load the main library
                    var result = TryLoad(path, description.SearchDirectories, config.LogCallback);
                    
                    // If we successfully loaded the library, return the handle
                    if (result != IntPtr.Zero)
                    {
                        loadedLibrary = library;
                        return result;
                    }
                }
            }

            // If fallback is allowed, we will make the last try (the default system loading) when calling the native api.
            // Otherwise we throw an exception here.
            if (!description.AllowFallback)
            {
                throw new RuntimeError("Failed to load the native library. Please check the log for more information.");
            }
            loadedLibrary = null;
#else
            loadedLibrary = new UnknownNativeLibrary();
#endif

            Log($"No library was loaded before calling native apis. " +
                $"This is not an error under netstandard2.0 but needs attention with net6 or higher.", LLamaLogLevel.Warning, config.LogCallback);
            return IntPtr.Zero;

#if NET6_0_OR_GREATER
            // Try to load a DLL from the path.
            // Returns null if nothing is loaded.
            static IntPtr TryLoad(string path, IEnumerable<string> searchDirectories, NativeLogConfig.LLamaLogCallback? logCallback)
            {
                var fullPath = TryFindPath(path, searchDirectories);
                Log($"Found full path file '{fullPath}' for relative path '{path}'", LLamaLogLevel.Debug, logCallback);
                if (NativeLibrary.TryLoad(fullPath, out var handle))
                {
                    RuntimeDirectoryRegistry.Register(Path.GetDirectoryName(fullPath));
                    Log($"Successfully loaded '{fullPath}'", LLamaLogLevel.Info, logCallback);
                    return handle;
                }

                Log($"Failed Loading '{fullPath}'", LLamaLogLevel.Info, logCallback);
                return IntPtr.Zero;
            }
#endif
        }

        // Try to find the given file in any of the possible search paths
        private static string TryFindPath(string filename, IEnumerable<string> searchDirectories)
        {
            // Try the configured search directories in the configuration
            foreach (var path in searchDirectories)
            {
                var candidate = Path.Combine(path, filename);
                if (File.Exists(candidate))
                    return candidate;
            }

            // Try a few other possible paths
            var possiblePathPrefix = new[] {
                    AppDomain.CurrentDomain.BaseDirectory,
                    Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location) ?? ""
                };

            foreach (var path in possiblePathPrefix)
            {
                var candidate = Path.Combine(path, filename);
                if (File.Exists(candidate))
                    return candidate;
            }

            return filename;
        }

        private static void Log(string message, LLamaLogLevel level, NativeLogConfig.LLamaLogCallback? logCallback)
        {
            if (!message.EndsWith("\n"))
                message += "\n";

            logCallback?.Invoke(level, message);
        }

        private static bool IsRequiredDependency(
            string dependencyPath,
            NativeLibraryMetadata? metadata,
            string fileExtension,
            string libPrefix)
        {
            var fileName = Path.GetFileName(dependencyPath);
            if (string.IsNullOrEmpty(fileName))
                return false;

            bool IsLibrary(string baseName)
            {
                var expected = $"{libPrefix}{baseName}{fileExtension}";
                return string.Equals(fileName, expected, StringComparison.OrdinalIgnoreCase);
            }

            // Always required for llama.cpp bootstrap regardless of backend.
            if (IsLibrary("ggml-base") || IsLibrary("ggml"))
                return true;

            // ggml-cpu became plugin-based in newer official binaries and may not exist as a
            // single hard dependency anymore. Keep it optional to avoid false candidate skips.
            if (IsLibrary("ggml-cpu"))
                return false;

            // Backend-specific plugin dependencies.
            if (metadata?.UseCuda == true && IsLibrary("ggml-cuda"))
                return true;
            if (metadata?.UseVulkan == true && IsLibrary("ggml-vulkan"))
                return true;

            return false;
        }

        private static IEnumerable<string> SafeEnumerateFiles(string directory, string pattern)
        {
            try
            {
                return Directory.EnumerateFiles(directory, pattern).OrderBy(item => item, StringComparer.OrdinalIgnoreCase);
            }
            catch
            {
                return Array.Empty<string>();
            }
        }

#if NET6_0_OR_GREATER
        public static void GetPlatformPathParts(OSPlatform platform, out string os, out string fileExtension, out string libPrefix)
        {
            if (platform == OSPlatform.Windows)
            {
                os = System.Runtime.Intrinsics.Arm.ArmBase.Arm64.IsSupported
                    ? "win-arm64"
                    : "win-x64";
                fileExtension = ".dll";
                libPrefix = "";
                return;
            }

            if (platform == OSPlatform.Linux)
            {
                if(System.Runtime.Intrinsics.Arm.ArmBase.Arm64.IsSupported){
                    // linux arm64
                    os = "linux-arm64";
                    fileExtension = ".so";
                    libPrefix = "lib";
                    return;
                }
                if(RuntimeInformation.RuntimeIdentifier.ToLower().StartsWith("alpine"))
                {
                    // alpine linux distro
                    os = "linux-musl-x64";
                    fileExtension = ".so";
                    libPrefix = "lib";
                    return;
                }
                else
                {
                    // other linux distro
                    os = "linux-x64";
                    fileExtension = ".so";
                    libPrefix = "lib";
                    return;
                }
            }

            if (platform == OSPlatform.OSX)
            {
                fileExtension = ".dylib";

                os = System.Runtime.Intrinsics.Arm.ArmBase.Arm64.IsSupported
                    ? "osx-arm64"
                    : "osx-x64";
                libPrefix = "lib";
            }
            else
            {
                throw new RuntimeError("Your operating system is not supported, please open an issue in LLamaSharp.");
            }
        }
#endif
    }
}
