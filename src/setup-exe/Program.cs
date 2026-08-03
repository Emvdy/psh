// Copyright (C) 2026 Emvdy
// SPDX-License-Identifier: GPL-3.0-or-later

using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;

namespace Psh.SetupExe
{
    internal static class Program
    {
        private const int ExitSuccess = 0;
        private const int ExitUsage = 2;
        private const int ExitRuntime = 3;
        private const int ExitDependency = 4;
        private const int ExitIntegrity = 5;

        private const string DefaultEdition = "Core";
        private static readonly string[] ValidEditions = { "Core", "Full" };

        private static int Main(string[] args)
        {
            string edition = DefaultEdition;
            bool nonInteractive = false;
            bool showHelp = false;

            for (int i = 0; i < args.Length; i++)
            {
                string arg = args[i];
                if (string.Equals(arg, "--help", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(arg, "-h", StringComparison.OrdinalIgnoreCase))
                {
                    showHelp = true;
                }
                else if (string.Equals(arg, "--non-interactive", StringComparison.OrdinalIgnoreCase))
                {
                    nonInteractive = true;
                }
                else if (string.Equals(arg, "--edition", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                {
                    edition = args[++i];
                }
                else if (arg.StartsWith("--edition=", StringComparison.OrdinalIgnoreCase))
                {
                    edition = arg.Substring("--edition=".Length);
                }
                else
                {
                    Console.Error.WriteLine("psh-setup: unknown argument: " + arg);
                    Console.Error.WriteLine("Run psh-setup --help for usage.");
                    return ExitUsage;
                }
            }

            if (showHelp)
            {
                PrintHelp();
                return ExitSuccess;
            }

            bool validEdition = false;
            foreach (string v in ValidEditions)
            {
                if (string.Equals(edition, v, StringComparison.OrdinalIgnoreCase))
                {
                    edition = v;
                    validEdition = true;
                    break;
                }
            }

            if (!validEdition)
            {
                Console.Error.WriteLine("psh-setup: --edition must be Core or Full.");
                return ExitUsage;
            }

            if (!string.Equals(edition, "Core", StringComparison.Ordinal))
            {
                Console.Error.WriteLine("psh-setup: this self-contained installer only includes the Core edition.");
                Console.Error.WriteLine("To install the Full edition, download the Full zip and run install-offline.ps1 directly.");
                Console.Error.WriteLine("See https://github.com/Emvdy/psh/releases for downloads.");
                return ExitUsage;
            }

            string powershellPath = ResolveWindowsPowerShell();
            if (powershellPath == null)
            {
                Console.Error.WriteLine("psh-setup: Windows PowerShell 5.1 was not found.");
                Console.Error.WriteLine("Windows PowerShell is required. It ships with Windows 10 and Windows 11.");
                return ExitDependency;
            }

            string tempDir = null;
            try
            {
                tempDir = Path.Combine(Path.GetTempPath(), "psh-setup-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(tempDir);

                // Extract embedded resources
                string scriptPath = ExtractEmbeddedResource("install-offline.ps1", tempDir);
                string archivePath = ExtractEmbeddedResource("psh-core.zip", tempDir);

                // Verify SHA-256 of extracted files
                string scriptHash = ComputeSha256(scriptPath);
                if (!string.Equals(scriptHash, EmbeddedResourceHashes.OfflineScriptSha256, StringComparison.OrdinalIgnoreCase))
                {
                    Console.Error.WriteLine("psh-setup: integrity check failed for install-offline.ps1.");
                    Console.Error.WriteLine("Expected: " + EmbeddedResourceHashes.OfflineScriptSha256);
                    Console.Error.WriteLine("Actual:   " + scriptHash);
                    return ExitIntegrity;
                }

                string archiveHash = ComputeSha256(archivePath);
                if (!string.Equals(archiveHash, EmbeddedResourceHashes.CoreArchiveSha256, StringComparison.OrdinalIgnoreCase))
                {
                    Console.Error.WriteLine("psh-setup: integrity check failed for psh-core.zip.");
                    Console.Error.WriteLine("Expected: " + EmbeddedResourceHashes.CoreArchiveSha256);
                    Console.Error.WriteLine("Actual:   " + archiveHash);
                    return ExitIntegrity;
                }

                // Launch offline installer
                return RunInstaller(powershellPath, scriptPath, archivePath, archiveHash, edition, nonInteractive);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("psh-setup: unexpected error: " + ex.Message);
                return ExitRuntime;
            }
            finally
            {
                if (tempDir != null)
                {
                    try { Directory.Delete(tempDir, true); }
                    catch { /* best-effort cleanup */ }
                }
            }
        }

        private static string ExtractEmbeddedResource(string resourceName, string targetDirectory)
        {
            Assembly assembly = Assembly.GetExecutingAssembly();
            using (Stream resourceStream = assembly.GetManifestResourceStream(resourceName))
            {
                if (resourceStream == null)
                {
                    throw new InvalidOperationException("Embedded resource not found: " + resourceName);
                }

                string targetPath = Path.Combine(targetDirectory, resourceName);
                using (FileStream fileStream = new FileStream(targetPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    resourceStream.CopyTo(fileStream);
                }

                return targetPath;
            }
        }

        private static string ComputeSha256(string filePath)
        {
            using (SHA256 sha256 = SHA256.Create())
            using (FileStream fileStream = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                byte[] hash = sha256.ComputeHash(fileStream);
                StringBuilder sb = new StringBuilder(64);
                foreach (byte b in hash)
                {
                    sb.AppendFormat("{0:x2}", b);
                }

                return sb.ToString();
            }
        }

        private static int RunInstaller(
            string powershellPath,
            string scriptPath,
            string archivePath,
            string archiveSha256,
            string edition,
            bool nonInteractive)
        {
            // Build argument list
            StringBuilder argsBuilder = new StringBuilder();
            argsBuilder.Append("-NoLogo -NoProfile -File ");
            argsBuilder.Append(QuoteArgument(scriptPath));
            argsBuilder.Append(" -Edition ");
            argsBuilder.Append(QuoteArgument(edition));
            argsBuilder.Append(" -Version ");
            argsBuilder.Append(QuoteArgument(PshSetupVersion.Version));
            argsBuilder.Append(" -ArchivePath ");
            argsBuilder.Append(QuoteArgument(archivePath));
            argsBuilder.Append(" -ArchiveSha256 ");
            argsBuilder.Append(QuoteArgument(archiveSha256));

            if (nonInteractive)
            {
                argsBuilder.Append(" -NonInteractive");
            }

            ProcessStartInfo startInfo = new ProcessStartInfo
            {
                FileName = powershellPath,
                Arguments = argsBuilder.ToString(),
                WorkingDirectory = Path.GetDirectoryName(scriptPath),
                UseShellExecute = false,
                CreateNoWindow = false
            };

            using (Process process = Process.Start(startInfo))
            {
                if (process == null)
                {
                    throw new InvalidOperationException("Windows PowerShell could not be started.");
                }

                process.WaitForExit();
                return process.ExitCode;
            }
        }

        private static string ResolveWindowsPowerShell()
        {
            string systemRoot = Environment.GetEnvironmentVariable("SystemRoot");
            if (string.IsNullOrEmpty(systemRoot))
            {
                systemRoot = @"C:\Windows";
            }

            string path = Path.Combine(systemRoot, @"System32\WindowsPowerShell\v1.0\powershell.exe");
            return File.Exists(path) ? path : null;
        }

        private static string QuoteArgument(string argument)
        {
            // PowerShell -File argument quoting: wrap in double quotes, escape internal double quotes
            return "\"" + argument.Replace("\"", "\\\"") + "\"";
        }

        private static void PrintHelp()
        {
            Console.WriteLine("psh-setup " + PshSetupVersion.Version + " - Psh self-contained offline installer");
            Console.WriteLine();
            Console.WriteLine("Usage: psh-setup [options]");
            Console.WriteLine();
            Console.WriteLine("Options:");
            Console.WriteLine("  --edition <Core|Full>   Edition to install (default: Core)");
            Console.WriteLine("                          Note: this exe only includes Core.");
            Console.WriteLine("                          For Full, download the Full zip from GitHub.");
            Console.WriteLine("  --non-interactive       Run without prompts");
            Console.WriteLine("  --help                  Show this help");
            Console.WriteLine();
            Console.WriteLine("This installer is self-contained: it bundles the Psh Core edition and");
            Console.WriteLine("installs for the current user without administrator privileges.");
            Console.WriteLine();
            Console.WriteLine("Requires: Windows 10/11, Windows PowerShell 5.1 (built into Windows).");
            Console.WriteLine("No additional downloads or .NET installations required.");
        }
    }
}
