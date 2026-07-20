// Copyright (C) 2026 Emvdy
// SPDX-License-Identifier: GPL-3.0-or-later

using System;
using System.IO;

namespace Psh.Bootstrapper
{
    public static class WindowsPowerShellLocator
    {
        public static string ResolveWindowsPowerShellPath()
        {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT)
            {
                return null;
            }

            return ResolveWindowsPowerShellPath(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                Environment.SystemDirectory,
                Environment.Is64BitOperatingSystem,
                Environment.Is64BitProcess,
                File.Exists);
        }

        // Kept internal so the release entry point cannot be redirected by
        // environment variables while tests can exercise WOW64 path rules.
        internal static string ResolveWindowsPowerShellPath(
            string windowsDirectory,
            string systemDirectory,
            bool is64BitOperatingSystem,
            bool is64BitProcess,
            Func<string, bool> fileExists)
        {
            if (string.IsNullOrEmpty(windowsDirectory) || string.IsNullOrEmpty(systemDirectory) ||
                fileExists == null || !Path.IsPathRooted(windowsDirectory) || !Path.IsPathRooted(systemDirectory))
            {
                return null;
            }

            string windowsRoot;
            string reportedSystemDirectory;
            try
            {
                windowsRoot = TrimTrailingSeparators(Path.GetFullPath(windowsDirectory));
                reportedSystemDirectory = TrimTrailingSeparators(Path.GetFullPath(systemDirectory));
            }
            catch (Exception exception)
            {
                if (!(exception is ArgumentException) &&
                    !(exception is IOException) &&
                    !(exception is NotSupportedException))
                {
                    throw;
                }

                return null;
            }

            string expectedReportedSystemDirectory;
            string nativeSystemDirectory;
            if (is64BitOperatingSystem && !is64BitProcess)
            {
                // A 32-bit process sees the redirected system directory as
                // SysWOW64. Sysnative is the non-redirected alias for the
                // native (64-bit) Windows PowerShell executable.
                expectedReportedSystemDirectory = Path.Combine(windowsRoot, "SysWOW64");
                nativeSystemDirectory = Path.Combine(windowsRoot, "Sysnative");
            }
            else
            {
                expectedReportedSystemDirectory = Path.Combine(windowsRoot, "System32");
                nativeSystemDirectory = expectedReportedSystemDirectory;
            }

            if (!string.Equals(reportedSystemDirectory, expectedReportedSystemDirectory, StringComparison.OrdinalIgnoreCase) ||
                !Path.IsPathRooted(nativeSystemDirectory))
            {
                return null;
            }

            try
            {
                string powershellPath = Path.GetFullPath(Path.Combine(
                    nativeSystemDirectory,
                    "WindowsPowerShell",
                    "v1.0",
                    "powershell.exe"));
                return fileExists(powershellPath) ? powershellPath : null;
            }
            catch (Exception exception)
            {
                if (!(exception is ArgumentException) &&
                    !(exception is IOException) &&
                    !(exception is NotSupportedException))
                {
                    throw;
                }

                return null;
            }
        }

        private static string TrimTrailingSeparators(string path)
        {
            string root = Path.GetPathRoot(path);
            if (!string.IsNullOrEmpty(root) && string.Equals(path, root, StringComparison.OrdinalIgnoreCase))
            {
                return root;
            }

            string trimmed = path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            return trimmed.Length == 0 ? (root ?? path) : trimmed;
        }
    }
}
