// Copyright (C) 2026 Emvdy
// SPDX-License-Identifier: GPL-3.0-or-later

using System;
using System.Collections.Generic;
using System.IO;
using Microsoft.DotNet.Build.Tasks.FileCatalog;

namespace Psh.CatalogBuilder
{
    internal static class Program
    {
        private const int FailureExitCode = 1;
        private const int UsageExitCode = 2;

        public static int Main(string[] args)
        {
            try
            {
                if (args.Length == 1 && string.Equals(args[0], "--help", StringComparison.Ordinal))
                {
                    WriteUsage(Console.Out);
                    return 0;
                }

                Options options = ParseArguments(args);
                BuildCatalog(options);
                return 0;
            }
            catch (UsageException exception)
            {
                Console.Error.WriteLine($"Psh.CatalogBuilder: {exception.Message}");
                WriteUsage(Console.Error);
                return UsageExitCode;
            }
            catch (Exception exception)
            {
                Console.Error.WriteLine($"Psh.CatalogBuilder: {exception.Message}");
                return FailureExitCode;
            }
        }

        private static Options ParseArguments(string[] args)
        {
            string? outputPath = null;
            var members = new List<MemberOption>();

            for (int index = 0; index < args.Length; index++)
            {
                string argument = args[index];
                if (string.Equals(argument, "--output", StringComparison.Ordinal))
                {
                    if (outputPath is not null)
                    {
                        throw new UsageException("--output may be specified only once.");
                    }

                    outputPath = ReadValue(args, ref index, "--output");
                    continue;
                }

                if (string.Equals(argument, "--member", StringComparison.Ordinal))
                {
                    string logicalPath = ReadValue(args, ref index, "--member logical path");
                    string sourcePath = ReadValue(args, ref index, "--member source path");
                    members.Add(new MemberOption(logicalPath, sourcePath));
                    continue;
                }

                throw new UsageException($"Unknown argument: {argument}");
            }

            if (string.IsNullOrWhiteSpace(outputPath))
            {
                throw new UsageException("--output is required.");
            }

            if (members.Count == 0)
            {
                throw new UsageException("At least one --member mapping is required.");
            }

            return new Options(outputPath, members);
        }

        private static string ReadValue(string[] args, ref int index, string description)
        {
            index++;
            if (index >= args.Length || string.IsNullOrEmpty(args[index]))
            {
                throw new UsageException($"A value is required for {description}.");
            }

            return args[index];
        }

        private static void BuildCatalog(Options options)
        {
            string outputPath = Path.GetFullPath(options.OutputPath);
            if (File.Exists(outputPath) || Directory.Exists(outputPath))
            {
                throw new IOException($"Catalog output already exists: {outputPath}");
            }

            string? outputDirectory = Path.GetDirectoryName(outputPath);
            if (string.IsNullOrEmpty(outputDirectory) || !Directory.Exists(outputDirectory))
            {
                throw new DirectoryNotFoundException($"Catalog output directory does not exist: {outputDirectory}");
            }

            var builder = new Microsoft.DotNet.Build.Tasks.FileCatalog.CatalogBuilder();
            var logicalPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (MemberOption member in options.Members)
            {
                string logicalPath = NormalizeLogicalPath(member.LogicalPath);
                if (!logicalPaths.Add(logicalPath))
                {
                    throw new InvalidOperationException($"Duplicate logical path under ordinal-ignore-case comparison: {logicalPath}");
                }

                string sourcePath = Path.GetFullPath(member.SourcePath);
                var source = new FileInfo(sourcePath);
                if (!source.Exists)
                {
                    throw new FileNotFoundException("Catalog input file does not exist.", sourcePath);
                }

                if (source.Length == 0)
                {
                    throw new InvalidOperationException($"Catalog input files must be non-empty: {sourcePath}");
                }

                builder.AddFile(sourcePath, logicalPath);
            }

            builder.WriteTo(outputPath);
        }

        private static string NormalizeLogicalPath(string value)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                throw new InvalidOperationException("Logical paths must not be empty or whitespace.");
            }

            if (value.IndexOf('\0') >= 0)
            {
                throw new InvalidOperationException("Logical paths must not contain NUL.");
            }

            if (Path.IsPathRooted(value) || value.StartsWith("\\", StringComparison.Ordinal) ||
                (value.Length >= 2 && IsAsciiLetter(value[0]) && value[1] == ':'))
            {
                throw new InvalidOperationException($"Logical paths must be relative: {value}");
            }

            string normalized = value.Replace('/', '\\');
            string[] segments = normalized.Split('\\');
            foreach (string segment in segments)
            {
                if (segment.Length == 0)
                {
                    throw new InvalidOperationException($"Logical paths must not contain empty components: {value}");
                }

                if (string.Equals(segment, ".", StringComparison.Ordinal) ||
                    string.Equals(segment, "..", StringComparison.Ordinal))
                {
                    throw new InvalidOperationException($"Logical paths must not contain dot components: {value}");
                }

                if (segment.IndexOfAny(new[] { ':', '*', '?', '"', '<', '>', '|' }) >= 0)
                {
                    throw new InvalidOperationException($"Logical paths contain a character invalid on Windows: {value}");
                }

                foreach (char character in segment)
                {
                    if (char.IsControl(character))
                    {
                        throw new InvalidOperationException($"Logical paths must not contain control characters: {value}");
                    }
                }
            }

            return normalized;
        }

        private static bool IsAsciiLetter(char value)
            => (value >= 'A' && value <= 'Z') || (value >= 'a' && value <= 'z');

        private static void WriteUsage(TextWriter writer)
        {
            writer.WriteLine("Usage: dotnet Psh.CatalogBuilder.dll --output <catalog.cat> --member <logical-relative-path> <source-path> [--member ...]");
        }

        private sealed class Options
        {
            public Options(string outputPath, IReadOnlyList<MemberOption> members)
            {
                OutputPath = outputPath;
                Members = members;
            }

            public string OutputPath { get; }

            public IReadOnlyList<MemberOption> Members { get; }
        }

        private sealed class MemberOption
        {
            public MemberOption(string logicalPath, string sourcePath)
            {
                LogicalPath = logicalPath;
                SourcePath = sourcePath;
            }

            public string LogicalPath { get; }

            public string SourcePath { get; }
        }

        private sealed class UsageException : Exception
        {
            public UsageException(string message)
                : base(message)
            {
            }
        }
    }
}
