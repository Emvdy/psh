// Copyright (C) 2026 Emvdy
// SPDX-License-Identifier: GPL-3.0-or-later

using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Psh.Bootstrapper
{
    public sealed class ScriptIntegrityException : Exception
    {
        public ScriptIntegrityException(string message)
            : base(message)
        {
        }
    }

    /// <summary>Keeps the verified file locked against writes and replacement.</summary>
    public sealed class VerifiedScriptHandle : IDisposable
    {
        private FileStream stream;
        private SafeFileHandle directoryHandle;
        private readonly bool windows;

        internal VerifiedScriptHandle(string scriptPath, FileStream stream, SafeFileHandle directoryHandle)
        {
            ScriptPath = scriptPath;
            this.stream = stream;
            this.directoryHandle = directoryHandle;
            windows = Environment.OSVersion.Platform == PlatformID.Win32NT;
        }

        public string ScriptPath { get; private set; }

        public string GetCurrentFinalPath()
        {
            if (stream == null)
            {
                throw new ObjectDisposedException("VerifiedScriptHandle");
            }

            return windows ? WindowsHandle.GetFinalPath(stream.SafeFileHandle) : ScriptPath;
        }

        public void Dispose()
        {
            FileStream current = stream;
            stream = null;
            if (current != null)
            {
                current.Dispose();
            }

            SafeFileHandle currentDirectory = directoryHandle;
            directoryHandle = null;
            if (currentDirectory != null)
            {
                currentDirectory.Dispose();
            }
        }
    }

    /// <summary>Verifies a fixed adjacent script without following reparse points.</summary>
    public static class ScriptIntegrityVerifier
    {
        private const string PlaceholderHash =
            "0000000000000000000000000000000000000000000000000000000000000000";

        public static VerifiedScriptHandle VerifyScriptIntegrity(string scriptPath, string expectedHash)
        {
            if (string.IsNullOrEmpty(scriptPath) || !Path.IsPathRooted(scriptPath))
            {
                throw new ScriptIntegrityException("Installer script path must be absolute.");
            }

            if (!File.Exists(scriptPath))
            {
                throw new ScriptIntegrityException("Adjacent installer script was not found: " + Path.GetFileName(scriptPath));
            }

            if (!IsSha256(expectedHash) || string.Equals(expectedHash, PlaceholderHash, StringComparison.Ordinal))
            {
                throw new ScriptIntegrityException("The bootstrapper does not contain a usable embedded script hash.");
            }

            FileStream stream = null;
            SafeFileHandle directoryHandle = null;
            try
            {
                string requestedPath = Path.GetFullPath(scriptPath);
                AssertNoReparsePoints(requestedPath);
                string baseDirectory = Path.GetDirectoryName(requestedPath);
                if (string.IsNullOrEmpty(baseDirectory))
                {
                    throw new ScriptIntegrityException("Adjacent installer script has no parent directory.");
                }

                string openPath = requestedPath;
                if (Environment.OSVersion.Platform == PlatformID.Win32NT)
                {
                    directoryHandle = WindowsHandle.OpenDirectoryReadLock(baseDirectory);
                    string stableBaseDirectory = WindowsHandle.GetFinalPath(directoryHandle);
                    AssertNoReparsePoints(stableBaseDirectory);
                    openPath = Path.Combine(stableBaseDirectory, Path.GetFileName(requestedPath));
                }

                stream = new FileStream(
                    openPath,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.Read,
                    4096,
                    FileOptions.SequentialScan);

                // Re-check after opening. On Windows the FileShare.Read handle now
                // prevents ordinary write, rename, and delete replacement races.
                AssertNoReparsePoints(openPath);
                string finalPath = Environment.OSVersion.Platform == PlatformID.Win32NT
                    ? WindowsHandle.GetFinalPath(stream.SafeFileHandle)
                    : Path.GetFullPath(openPath);
                AssertNoReparsePoints(finalPath);

                if (Environment.OSVersion.Platform == PlatformID.Win32NT &&
                    !PathEquals(Path.GetDirectoryName(finalPath), Path.GetDirectoryName(openPath)))
                {
                    throw new ScriptIntegrityException("Adjacent installer script final path escaped its locked package directory.");
                }

                string actualHash;
                using (SHA256 sha256 = SHA256.Create())
                {
                    actualHash = ToLowerHex(sha256.ComputeHash(stream));
                }

                if (!string.Equals(actualHash, expectedHash, StringComparison.OrdinalIgnoreCase))
                {
                    throw new ScriptIntegrityException("Adjacent installer script SHA256 does not match the embedded release hash.");
                }

                VerifiedScriptHandle verified = new VerifiedScriptHandle(finalPath, stream, directoryHandle);
                stream = null;
                directoryHandle = null;
                return verified;
            }
            finally
            {
                if (stream != null)
                {
                    stream.Dispose();
                }

                if (directoryHandle != null)
                {
                    directoryHandle.Dispose();
                }
            }
        }

        private static void AssertNoReparsePoints(string path)
        {
            string current = Path.GetFullPath(path);
            while (!string.IsNullOrEmpty(current))
            {
                FileAttributes attributes;
                try
                {
                    attributes = File.GetAttributes(current);
                }
                catch (Exception exception)
                {
                    throw new ScriptIntegrityException("Could not inspect installer path component: " + exception.Message);
                }

                if ((attributes & FileAttributes.ReparsePoint) != 0)
                {
                    throw new ScriptIntegrityException("Installer script or an ancestor directory is a reparse point.");
                }

                string parent = Path.GetDirectoryName(current);
                if (string.IsNullOrEmpty(parent) || PathEquals(parent, current))
                {
                    break;
                }

                current = parent;
            }
        }

        private static bool PathEquals(string left, string right)
        {
            if (string.IsNullOrEmpty(left) || string.IsNullOrEmpty(right))
            {
                return string.Equals(left, right, StringComparison.OrdinalIgnoreCase);
            }

            string normalizedLeft = left.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            string normalizedRight = right.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            return string.Equals(normalizedLeft, normalizedRight, StringComparison.OrdinalIgnoreCase);
        }

        private static string ToLowerHex(byte[] bytes)
        {
            StringBuilder builder = new StringBuilder(bytes.Length * 2);
            for (int index = 0; index < bytes.Length; index++)
            {
                builder.Append(bytes[index].ToString("x2", System.Globalization.CultureInfo.InvariantCulture));
            }

            return builder.ToString();
        }

        private static bool IsSha256(string value)
        {
            if (string.IsNullOrEmpty(value) || value.Length != 64)
            {
                return false;
            }

            for (int index = 0; index < value.Length; index++)
            {
                char character = value[index];
                bool hexadecimal = (character >= '0' && character <= '9') ||
                    (character >= 'a' && character <= 'f') ||
                    (character >= 'A' && character <= 'F');
                if (!hexadecimal)
                {
                    return false;
                }
            }

            return true;
        }
    }

    internal static class WindowsHandle
    {
        private const uint FileReadAttributes = 0x00000080;
        private const uint ShareRead = 0x00000001;
        private const uint OpenExisting = 3;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint FileFlagOpenReparsePoint = 0x00200000;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandle(
            SafeFileHandle file,
            StringBuilder path,
            uint pathLength,
            uint flags);

        internal static SafeFileHandle OpenDirectoryReadLock(string path)
        {
            SafeFileHandle handle = CreateFile(
                path,
                FileReadAttributes,
                ShareRead,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle == null || handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                if (handle != null)
                {
                    handle.Dispose();
                }

                throw new ScriptIntegrityException(
                    "Could not lock the installer package directory: " + new Win32Exception(error).Message);
            }

            return handle;
        }

        internal static string GetFinalPath(SafeFileHandle handle)
        {
            if (handle == null || handle.IsInvalid || handle.IsClosed)
            {
                throw new ScriptIntegrityException("Verified path handle is not open.");
            }

            uint capacity = 512;
            while (true)
            {
                StringBuilder buffer = new StringBuilder((int)capacity);
                uint length = GetFinalPathNameByHandle(handle, buffer, capacity, 0);
                if (length == 0)
                {
                    int error = Marshal.GetLastWin32Error();
                    throw new ScriptIntegrityException(
                        "Could not resolve the verified final path: " + new Win32Exception(error).Message);
                }

                if (length < capacity)
                {
                    return NormalizeFinalPath(buffer.ToString());
                }

                capacity = checked(length + 1);
            }
        }

        private static string NormalizeFinalPath(string path)
        {
            const string uncPrefix = @"\\?\UNC\";
            const string localPrefix = @"\\?\";
            string normalized = path;
            if (normalized.StartsWith(uncPrefix, StringComparison.OrdinalIgnoreCase))
            {
                normalized = @"\\" + normalized.Substring(uncPrefix.Length);
            }
            else if (normalized.StartsWith(localPrefix, StringComparison.OrdinalIgnoreCase))
            {
                normalized = normalized.Substring(localPrefix.Length);
            }

            if (!Path.IsPathRooted(normalized))
            {
                throw new ScriptIntegrityException("Verified final path is not absolute.");
            }

            return Path.GetFullPath(normalized);
        }
    }
}
