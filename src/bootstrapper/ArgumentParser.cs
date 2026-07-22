// Copyright (C) 2026 Emvdy
// SPDX-License-Identifier: GPL-3.0-or-later

using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace Psh.Bootstrapper
{
    /// <summary>Options accepted by the release bootstrapper.</summary>
    public sealed class BootstrapperArguments
    {
        internal BootstrapperArguments()
        {
            Edition = "Core";
            Version = "latest";
        }

        public bool Offline { get; internal set; }

        public string Edition { get; internal set; }

        public string Version { get; internal set; }

        public string ArchivePath { get; internal set; }

        public string ArchiveSha256 { get; internal set; }

        public bool NonInteractive { get; internal set; }

        public bool Help { get; internal set; }
    }

    /// <summary>Raised when the command line is outside the public whitelist.</summary>
    public sealed class BootstrapperUsageException : Exception
    {
        public BootstrapperUsageException(string message)
            : base(message)
        {
        }
    }

    /// <summary>Strict parser for the small, stable bootstrapper interface.</summary>
    public static class ArgumentParser
    {
        private const string SemanticVersionPattern =
            @"\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z";

        private static readonly Regex SemanticVersion = new Regex(
            SemanticVersionPattern,
            RegexOptions.CultureInvariant | RegexOptions.ExplicitCapture);

        private static readonly Regex ArchiveSha256 = new Regex(
            @"\A[0-9A-Fa-f]{64}\z",
            RegexOptions.CultureInvariant | RegexOptions.ExplicitCapture);

        public const string UsageText =
            "Usage: psh-installer.exe [--offline --archive-path FILE --archive-sha256 HEX] [--edition Core|Full] [--version latest|x.y.z] [--non-interactive]";

        public static BootstrapperArguments Parse(string[] args)
        {
            if (args == null)
            {
                throw new BootstrapperUsageException("Arguments cannot be null.");
            }

            BootstrapperArguments result = new BootstrapperArguments();
            HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            for (int index = 0; index < args.Length; index++)
            {
                string option = NormalizeOption(args[index]);
                if (option == null)
                {
                    throw new BootstrapperUsageException("Only whitelisted named options are accepted.");
                }

                if (string.Equals(option, "help", StringComparison.OrdinalIgnoreCase))
                {
                    if (args.Length != 1 || !seen.Add(option))
                    {
                        throw new BootstrapperUsageException("The help option cannot be combined with other options.");
                    }

                    result.Help = true;
                    continue;
                }

                if (result.Help)
                {
                    throw new BootstrapperUsageException("The help option cannot be combined with other options.");
                }

                if (string.Equals(option, "offline", StringComparison.OrdinalIgnoreCase))
                {
                    if (!seen.Add(option))
                    {
                        throw new BootstrapperUsageException("The offline option may be specified only once.");
                    }

                    result.Offline = true;
                    continue;
                }

                if (string.Equals(option, "non-interactive", StringComparison.OrdinalIgnoreCase))
                {
                    if (!seen.Add(option))
                    {
                        throw new BootstrapperUsageException("The non-interactive option may be specified only once.");
                    }

                    result.NonInteractive = true;
                    continue;
                }

                if (string.Equals(option, "edition", StringComparison.OrdinalIgnoreCase))
                {
                    if (!seen.Add(option))
                    {
                        throw new BootstrapperUsageException("The edition option may be specified only once.");
                    }

                    string value = ReadValue(args, ref index, "edition");
                    if (string.Equals(value, "Core", StringComparison.OrdinalIgnoreCase))
                    {
                        result.Edition = "Core";
                    }
                    else if (string.Equals(value, "Full", StringComparison.OrdinalIgnoreCase))
                    {
                        result.Edition = "Full";
                    }
                    else
                    {
                        throw new BootstrapperUsageException("Edition must be Core or Full.");
                    }

                    continue;
                }

                if (string.Equals(option, "version", StringComparison.OrdinalIgnoreCase))
                {
                    if (!seen.Add(option))
                    {
                        throw new BootstrapperUsageException("The version option may be specified only once.");
                    }

                    string value = ReadValue(args, ref index, "version");
                    if (string.Equals(value, "latest", StringComparison.OrdinalIgnoreCase))
                    {
                        result.Version = "latest";
                    }
                    else if (IsStrictSemanticVersion(value))
                    {
                        result.Version = value;
                    }
                    else
                    {
                        throw new BootstrapperUsageException("Version must be latest or a semantic x.y.z version.");
                    }

                    continue;
                }

                if (string.Equals(option, "archive-path", StringComparison.OrdinalIgnoreCase))
                {
                    if (!seen.Add(option))
                    {
                        throw new BootstrapperUsageException("The archive-path option may be specified only once.");
                    }

                    result.ArchivePath = ReadValue(args, ref index, "archive-path");
                    continue;
                }

                if (string.Equals(option, "archive-sha256", StringComparison.OrdinalIgnoreCase))
                {
                    if (!seen.Add(option))
                    {
                        throw new BootstrapperUsageException("The archive-sha256 option may be specified only once.");
                    }

                    string value = ReadValue(args, ref index, "archive-sha256");
                    if (!ArchiveSha256.IsMatch(value) || IsAllZeroSha256(value))
                    {
                        throw new BootstrapperUsageException(
                            "Archive SHA256 must be a non-zero 64-character hexadecimal value.");
                    }

                    result.ArchiveSha256 = value.ToLowerInvariant();
                    continue;
                }

                throw new BootstrapperUsageException("Unknown option: " + args[index]);
            }

            bool hasArchivePath = !string.IsNullOrEmpty(result.ArchivePath);
            bool hasArchiveSha256 = !string.IsNullOrEmpty(result.ArchiveSha256);
            if (result.Offline)
            {
                if (!hasArchivePath || !hasArchiveSha256)
                {
                    throw new BootstrapperUsageException(
                        "Offline mode requires both --archive-path and --archive-sha256.");
                }
            }
            else if (hasArchivePath || hasArchiveSha256)
            {
                throw new BootstrapperUsageException(
                    "Archive evidence options are valid only with --offline.");
            }

            return result;
        }

        private static bool IsAllZeroSha256(string value)
        {
            for (int index = 0; index < value.Length; index++)
            {
                if (value[index] != '0')
                {
                    return false;
                }
            }

            return true;
        }

        private static bool IsStrictSemanticVersion(string value)
        {
            if (!SemanticVersion.IsMatch(value) ||
                value.IndexOf("--", StringComparison.Ordinal) >= 0)
            {
                return false;
            }

            int buildStart = value.IndexOf('+');
            int prereleaseStart = value.IndexOf('-');
            if (prereleaseStart < 0 || (buildStart >= 0 && prereleaseStart > buildStart))
            {
                return true;
            }

            int prereleaseEnd = buildStart >= 0 ? buildStart : value.Length;
            string prerelease = value.Substring(prereleaseStart + 1, prereleaseEnd - prereleaseStart - 1);
            string[] identifiers = prerelease.Split('.');
            foreach (string identifier in identifiers)
            {
                if (identifier.Length == 0)
                {
                    return false;
                }

                bool numeric = true;
                bool hasAsciiLetter = false;
                for (int index = 0; index < identifier.Length; index++)
                {
                    char character = identifier[index];
                    if (character >= '0' && character <= '9')
                    {
                        continue;
                    }

                    numeric = false;
                    if ((character >= 'a' && character <= 'z') ||
                        (character >= 'A' && character <= 'Z'))
                    {
                        hasAsciiLetter = true;
                    }
                }

                if (numeric && identifier.Length > 1 && identifier[0] == '0')
                {
                    return false;
                }

                if (!numeric && !hasAsciiLetter)
                {
                    return false;
                }
            }

            return true;
        }

        private static string NormalizeOption(string token)
        {
            if (string.IsNullOrEmpty(token))
            {
                return null;
            }

            int prefixLength;
            if (token.StartsWith("--", StringComparison.Ordinal))
            {
                prefixLength = 2;
            }
            else if (token[0] == '-' || token[0] == '/')
            {
                prefixLength = 1;
            }
            else
            {
                return null;
            }

            if (token.Length == prefixLength)
            {
                return null;
            }

            string option = token.Substring(prefixLength);
            if (option.IndexOf('=') >= 0 || option.IndexOf('\0') >= 0)
            {
                return null;
            }

            return option;
        }

        private static string ReadValue(string[] args, ref int index, string optionName)
        {
            if (index + 1 >= args.Length)
            {
                throw new BootstrapperUsageException("Missing value for --" + optionName + ".");
            }

            index++;
            string value = args[index];
            if (string.IsNullOrEmpty(value) || NormalizeOption(value) != null)
            {
                throw new BootstrapperUsageException("Missing value for --" + optionName + ".");
            }

            return value;
        }
    }
}
