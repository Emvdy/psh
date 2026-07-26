// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using System.Buffers;
using System.IO;
using System.Security.Cryptography;

namespace Microsoft.DotNet.Build.Tasks.FileCatalog
{
    /// <summary>
    /// A single file (or in-memory blob) to include in a catalog. Only the SHA-1 and SHA-256
    /// hashes of the content are recorded in the catalog, so an entry stores just those hashes
    /// (never the raw content), keeping memory use bounded regardless of file size.
    /// </summary>
    public sealed class CatalogEntry
    {
        public static CatalogEntry FromFile(string filePath, string? name = null)
        {
            if (string.IsNullOrEmpty(filePath))
            {
                throw new ArgumentException("File path must not be null or empty.", nameof(filePath));
            }

            using IncrementalHash sha1 = IncrementalHash.CreateHash(HashAlgorithmName.SHA1);
            using IncrementalHash sha256 = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            using (FileStream stream = File.OpenRead(filePath))
            {
                byte[] buffer = ArrayPool<byte>.Shared.Rent(81920);
                try
                {
                    int read;
                    while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
                    {
                        sha1.AppendData(buffer, 0, read);
                        sha256.AppendData(buffer, 0, read);
                    }
                }
                finally
                {
                    ArrayPool<byte>.Shared.Return(buffer);
                }
            }

            return new CatalogEntry(name ?? Path.GetFileName(filePath), sha1.GetHashAndReset(), sha256.GetHashAndReset());
        }

        public CatalogEntry(string name, ReadOnlyMemory<byte> content)
            : this(name, SHA1.HashData(content.Span), SHA256.HashData(content.Span))
        {
        }

        private CatalogEntry(string name, byte[] sha1, byte[] sha256)
        {
            if (string.IsNullOrEmpty(name))
            {
                throw new ArgumentException("Name must not be null or empty.", nameof(name));
            }

            Name = name;
            Sha1 = sha1;
            Sha256 = sha256;
        }

        /// <summary>The logical relative path embedded in the SHA-256 catalog member.</summary>
        public string Name { get; }

        public byte[] Sha1 { get; }

        public byte[] Sha256 { get; }
    }
}
