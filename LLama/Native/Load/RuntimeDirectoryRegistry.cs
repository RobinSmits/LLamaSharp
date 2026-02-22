using System;
using System.Collections.Generic;
using System.IO;

namespace LLama.Native
{
    internal static class RuntimeDirectoryRegistry
    {
        private static readonly object Gate = new();
        private static readonly HashSet<string> RuntimeDirectories = new(StringComparer.OrdinalIgnoreCase);

        internal static void Register(string? directory)
        {
            if (string.IsNullOrWhiteSpace(directory))
                return;

            string normalizedPath;
            try
            {
                normalizedPath = Path.GetFullPath(directory);
            }
            catch
            {
                return;
            }

            lock (Gate)
            {
                RuntimeDirectories.Add(normalizedPath);
            }
        }

        internal static string[] Snapshot()
        {
            lock (Gate)
            {
                var directories = new string[RuntimeDirectories.Count];
                RuntimeDirectories.CopyTo(directories);
                return directories;
            }
        }
    }
}
