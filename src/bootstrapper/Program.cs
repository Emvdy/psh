// Copyright (C) 2026 Emvdy
// SPDX-License-Identifier: GPL-3.0-or-later

using System;
using System.Diagnostics;
using System.IO;

namespace Psh.Bootstrapper
{
    internal static class Program
    {
        private const int UsageExitCode = 2;
        private const int RuntimeExitCode = 3;
        private const int DependencyExitCode = 4;
        private const int IntegrityExitCode = 5;
        private const string OnlineScriptName = "install.ps1";
        private const string OfflineScriptName = "install-offline.ps1";
        private const string PolicyRemediation = "Set-ExecutionPolicy -Scope CurrentUser RemoteSigned";

        private static readonly string[] PowerShellFileArguments = { "-NoLogo", "-NoProfile", "-File" };

        private static int Main(string[] args)
        {
            BootstrapperArguments parsed;
            try
            {
                parsed = ArgumentParser.Parse(args);
            }
            catch (BootstrapperUsageException exception)
            {
                ErrorEnvelope.Write("PSH_E_USAGE", UsageExitCode, exception.Message);
                return UsageExitCode;
            }

            if (parsed.Help)
            {
                Console.Out.WriteLine(ArgumentParser.UsageText);
                return 0;
            }

            string baseDirectory = AppDomain.CurrentDomain.BaseDirectory;
            string scriptName = parsed.Offline ? OfflineScriptName : OnlineScriptName;
            string expectedHash = parsed.Offline ? EmbeddedScriptHashes.OfflineScriptSha256 : EmbeddedScriptHashes.OnlineScriptSha256;
            string scriptPath = Path.GetFullPath(Path.Combine(baseDirectory, scriptName));

            VerifiedScriptHandle verifiedScript;
            try
            {
                verifiedScript = ScriptIntegrityVerifier.VerifyScriptIntegrity(scriptPath, expectedHash);
            }
            catch (Exception exception)
            {
                ErrorEnvelope.Write("PSH_E_INTEGRITY", IntegrityExitCode, exception.Message);
                return IntegrityExitCode;
            }

            using (verifiedScript)
            {
                string powershellPath = WindowsPowerShellLocator.ResolveWindowsPowerShellPath();
                if (string.IsNullOrEmpty(powershellPath))
                {
                    ErrorEnvelope.Write(
                        "PSH_E_DEPENDENCY",
                        DependencyExitCode,
                        "Windows PowerShell 5.1 was not found under the native System32 WindowsPowerShell directory.");
                    return DependencyExitCode;
                }

                ExecutionPolicyResult policy;
                try
                {
                    policy = ExecutionPolicyPreflight.Probe(powershellPath, verifiedScript.GetCurrentFinalPath());
                }
                catch (Exception exception)
                {
                    ErrorEnvelope.Write(
                        "PSH_E_EXECUTION_POLICY_PROBE",
                        DependencyExitCode,
                        exception.Message,
                        "Unknown",
                        false,
                        PolicyRemediation);
                    return DependencyExitCode;
                }

                if (!policy.AllowsScript(parsed.NonInteractive))
                {
                    ErrorEnvelope.Write(
                        "PSH_E_EXECUTION_POLICY",
                        DependencyExitCode,
                        policy.GetDenialMessage(parsed.NonInteractive),
                        policy.EffectivePolicy,
                        policy.GovernedByGpo,
                        PolicyRemediation);
                    return DependencyExitCode;
                }

                try
                {
                    // Refresh the final path immediately before CreateProcess. The
                    // package directory is locked; an ancestor rename remains a
                    // narrow documented limitation of path-based -File launch.
                    return StartInstaller(powershellPath, verifiedScript.GetCurrentFinalPath(), parsed);
                }
                catch (Exception exception)
                {
                    ErrorEnvelope.Write("PSH_E_RUNTIME", RuntimeExitCode, exception.Message);
                    return RuntimeExitCode;
                }
            }
        }

        private static int StartInstaller(string powershellPath, string scriptPath, BootstrapperArguments arguments)
        {
            string[] forwarded = new string[PowerShellFileArguments.Length + 5];
            int index = 0;
            forwarded[index++] = PowerShellFileArguments[0];
            forwarded[index++] = PowerShellFileArguments[1];
            forwarded[index++] = PowerShellFileArguments[2];
            forwarded[index++] = scriptPath;
            forwarded[index++] = "-Edition";
            forwarded[index++] = arguments.Edition;
            forwarded[index++] = "-Version";
            forwarded[index++] = arguments.Version;

            string[] effectiveArguments;
            if (arguments.NonInteractive)
            {
                effectiveArguments = new string[index + 1];
                Array.Copy(forwarded, effectiveArguments, index);
                effectiveArguments[index] = "-NonInteractive";
            }
            else
            {
                effectiveArguments = new string[index];
                Array.Copy(forwarded, effectiveArguments, index);
            }

            ProcessStartInfo startInfo = new ProcessStartInfo
            {
                FileName = powershellPath,
                Arguments = CommandLineEscaping.Join(effectiveArguments),
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

    }
}
