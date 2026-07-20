// Copyright (C) 2026 Emvdy
// SPDX-License-Identifier: GPL-3.0-or-later

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text;

namespace Psh.Bootstrapper
{
    public sealed class ExecutionPolicyResult
    {
        public string EffectivePolicy { get; set; }

        public bool GovernedByGpo { get; set; }

        public string SignatureStatus { get; set; }

        public bool IsInternetZone { get; set; }

        public int? ZoneId { get; set; }

        public bool AllowsScript(bool nonInteractive)
        {
            bool validSignature = string.Equals(SignatureStatus, "Valid", StringComparison.OrdinalIgnoreCase);
            if (string.Equals(EffectivePolicy, "Bypass", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            if (string.Equals(EffectivePolicy, "Restricted", StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }

            if (string.Equals(EffectivePolicy, "AllSigned", StringComparison.OrdinalIgnoreCase))
            {
                return validSignature;
            }

            if (string.Equals(EffectivePolicy, "RemoteSigned", StringComparison.OrdinalIgnoreCase))
            {
                return !IsInternetZone || validSignature;
            }

            if (string.Equals(EffectivePolicy, "Unrestricted", StringComparison.OrdinalIgnoreCase))
            {
                return !(nonInteractive && IsInternetZone && !validSignature);
            }

            return false;
        }

        public string GetDenialMessage(bool nonInteractive)
        {
            if (string.Equals(EffectivePolicy, "Restricted", StringComparison.OrdinalIgnoreCase))
            {
                return "Windows PowerShell Restricted policy does not allow installer scripts.";
            }

            if (string.Equals(EffectivePolicy, "AllSigned", StringComparison.OrdinalIgnoreCase))
            {
                return "Windows PowerShell AllSigned policy requires a valid trusted Authenticode signature.";
            }

            if (string.Equals(EffectivePolicy, "RemoteSigned", StringComparison.OrdinalIgnoreCase) && IsInternetZone)
            {
                return "Windows PowerShell RemoteSigned policy requires a valid signature for an Internet-zone installer script.";
            }

            if (string.Equals(EffectivePolicy, "Unrestricted", StringComparison.OrdinalIgnoreCase) && nonInteractive && IsInternetZone)
            {
                return "An unsigned Internet-zone installer script would require an interactive trust prompt.";
            }

            return "Windows PowerShell execution policy does not allow this installer script.";
        }
    }

    [DataContract]
    internal sealed class ExecutionPolicyProbeDocument
    {
        [DataMember(Name = "schemaVersion", IsRequired = true)]
        internal int SchemaVersion { get; set; }

        [DataMember(Name = "effectivePolicy", IsRequired = true)]
        internal string EffectivePolicy { get; set; }

        [DataMember(Name = "governedByGpo", IsRequired = true)]
        internal bool GovernedByGpo { get; set; }

        [DataMember(Name = "signatureStatus", IsRequired = true)]
        internal string SignatureStatus { get; set; }

        [DataMember(Name = "isInternetZone", IsRequired = true)]
        internal bool IsInternetZone { get; set; }

        [DataMember(Name = "zoneId", IsRequired = true)]
        internal int? ZoneId { get; set; }
    }

    /// <summary>
    /// Reads the effective policy using the selected Windows PowerShell process.
    /// The command is limited to read-only policy, signature, and zone metadata;
    /// installer logic is always launched separately with -File.
    /// </summary>
    internal static class ExecutionPolicyPreflight
    {
        private const string ScriptPathEnvironmentVariable = "PSH_BOOTSTRAPPER_POLICY_SCRIPT_PATH";
        private const string ZoneIdPattern = "(?m)^\\s*ZoneId\\s*=\\s*(\\d+)\\s*$";

        private const string ProbeCommand =
            "$ErrorActionPreference='Stop';" +
            "$scriptPath=$env:PSH_BOOTSTRAPPER_POLICY_SCRIPT_PATH;" +
            "if([string]::IsNullOrWhiteSpace($scriptPath)){throw 'Controlled installer script path is missing'};" +
            "$byScope=@{};" +
            "Get-ExecutionPolicy -List | ForEach-Object { $byScope[[string]$_.Scope]=[string]$_.ExecutionPolicy };" +
            "$effective=[string](Get-ExecutionPolicy);" +
            "$machine=[string]($byScope['MachinePolicy']);" +
            "$user=[string]($byScope['UserPolicy']);" +
            "if([string]::IsNullOrEmpty($machine)){$machine='Undefined'};" +
            "if([string]::IsNullOrEmpty($user)){$user='Undefined'};" +
            "$signatureStatus=[string](Get-AuthenticodeSignature -LiteralPath $scriptPath).Status;" +
            "$streams=@(Get-Item -LiteralPath $scriptPath -Stream '*' -ErrorAction Stop);" +
            "$zoneStreams=@($streams | Where-Object { [string]$_.Stream -eq 'Zone.Identifier' });" +
            "if($zoneStreams.Count -gt 1){throw 'Multiple Zone.Identifier streams were reported'};" +
            "$zoneId=$null;" +
            "if($zoneStreams.Count -eq 1){$zoneText=Get-Content -LiteralPath $scriptPath -Stream 'Zone.Identifier' -Raw -ErrorAction Stop;$zoneMatches=[regex]::Matches([string]$zoneText,'" + ZoneIdPattern + "');if($zoneMatches.Count -ne 1){throw 'Zone.Identifier did not contain exactly one ZoneId'};$zoneId=[int]$zoneMatches[0].Groups[1].Value;if($zoneId -lt 0 -or $zoneId -gt 4){throw 'Zone.Identifier contains an unknown ZoneId'}};" +
            "$internetZone=($zoneId -eq 3 -or $zoneId -eq 4);" +
            "[pscustomobject]@{schemaVersion=1;effectivePolicy=$effective;governedByGpo=($machine -ne 'Undefined' -or $user -ne 'Undefined');signatureStatus=$signatureStatus;isInternetZone=$internetZone;zoneId=$zoneId;machinePolicy=$machine;userPolicy=$user;process=[string]($byScope['Process']);currentUser=[string]($byScope['CurrentUser']);localMachine=[string]($byScope['LocalMachine'])} | ConvertTo-Json -Compress";

        internal static ExecutionPolicyResult Probe(string powershellPath, string scriptPath)
        {
            if (string.IsNullOrEmpty(powershellPath))
            {
                throw new InvalidOperationException("Windows PowerShell was not found.");
            }

            if (string.IsNullOrEmpty(scriptPath) || !Path.IsPathRooted(scriptPath))
            {
                throw new InvalidOperationException("Execution-policy probe requires an absolute installer script path.");
            }

            ProcessStartInfo startInfo = new ProcessStartInfo
            {
                FileName = powershellPath,
                Arguments = CommandLineEscaping.Join(new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", ProbeCommand }),
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            startInfo.EnvironmentVariables[ScriptPathEnvironmentVariable] = scriptPath;

            using (Process process = Process.Start(startInfo))
            {
                if (process == null)
                {
                    throw new InvalidOperationException("Windows PowerShell could not be started.");
                }

                string standardOutput = process.StandardOutput.ReadToEnd();
                string standardError = process.StandardError.ReadToEnd();
                process.WaitForExit();
                if (process.ExitCode != 0)
                {
                    throw new InvalidOperationException("Execution-policy probe failed: " + TrimDiagnostic(standardError));
                }

                string json = GetSingleNonEmptyLine(standardOutput);
                return Parse(json);
            }
        }

        private static ExecutionPolicyResult Parse(string json)
        {
            DataContractJsonSerializer serializer = new DataContractJsonSerializer(typeof(ExecutionPolicyProbeDocument));
            ExecutionPolicyProbeDocument document;
            using (MemoryStream stream = new MemoryStream(Encoding.UTF8.GetBytes(json)))
            {
                document = serializer.ReadObject(stream) as ExecutionPolicyProbeDocument;
            }

            if (document == null)
            {
                throw new InvalidOperationException("Execution-policy probe returned a non-object JSON value.");
            }

            if (document.SchemaVersion != 1)
            {
                throw new InvalidOperationException("Execution-policy probe returned an unsupported schema.");
            }

            if (string.IsNullOrWhiteSpace(document.EffectivePolicy))
            {
                throw new InvalidOperationException("Execution-policy probe returned an empty policy.");
            }

            if (string.IsNullOrWhiteSpace(document.SignatureStatus))
            {
                throw new InvalidOperationException("Execution-policy probe returned an empty signature status.");
            }

            if (document.ZoneId.HasValue && (document.ZoneId.Value < 0 || document.ZoneId.Value > 4))
            {
                throw new InvalidOperationException("Execution-policy probe returned an unknown ZoneId.");
            }

            bool expectedInternetZone = document.ZoneId.HasValue &&
                (document.ZoneId.Value == 3 || document.ZoneId.Value == 4);
            if (document.IsInternetZone != expectedInternetZone)
            {
                throw new InvalidOperationException("Execution-policy probe returned inconsistent zone metadata.");
            }

            return new ExecutionPolicyResult
            {
                EffectivePolicy = document.EffectivePolicy,
                GovernedByGpo = document.GovernedByGpo,
                SignatureStatus = document.SignatureStatus,
                IsInternetZone = document.IsInternetZone,
                ZoneId = document.ZoneId
            };
        }

        private static string GetSingleNonEmptyLine(string text)
        {
            List<string> lines = new List<string>();
            using (System.IO.StringReader reader = new System.IO.StringReader(text ?? string.Empty))
            {
                string line;
                while ((line = reader.ReadLine()) != null)
                {
                    if (!string.IsNullOrWhiteSpace(line))
                    {
                        lines.Add(line.Trim());
                    }
                }
            }

            if (lines.Count != 1)
            {
                throw new InvalidOperationException("Execution-policy probe returned unexpected output.");
            }

            return lines[0];
        }

        private static string TrimDiagnostic(string text)
        {
            if (string.IsNullOrWhiteSpace(text))
            {
                return "no diagnostic output";
            }

            string normalized = text.Replace('\r', ' ').Replace('\n', ' ').Trim();
            return normalized.Length > 240 ? normalized.Substring(0, 240) : normalized;
        }
    }
}
