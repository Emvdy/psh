// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using System.Collections.Generic;
using System.Formats.Asn1;
using System.IO;
using System.Security.Cryptography;

namespace Microsoft.DotNet.Build.Tasks.FileCatalog
{
    /// <summary>
    /// Builds a Microsoft Catalog (.cat) file in pure managed code - no <c>makecat.exe</c>,
    /// no Windows SDK, no P/Invoke, cross-platform.
    ///
    /// The output is an <em>unsigned</em> PKCS#7 SignedData envelope (no signers, no
    /// certificates) whose encapsulated content is a Microsoft <c>CertificateTrustList</c>
    /// (szOID_CTL). This matches the artifact <c>makecat.exe</c> produces from a
    /// <c>CatalogVersion=2 / HashAlgorithms=SHA256</c> <c>.cdf</c>: a catalog ready to be
    /// Authenticode-signed by <c>signtool.exe</c> or the Arcade signing infrastructure.
    ///
    /// For each cataloged file, two <c>TrustedSubject</c> members are emitted - one keyed by
    /// the raw SHA-1 hash and one by the raw SHA-256 hash. The SHA-256 member includes the
    /// logical relative path required by PowerShell <c>Test-FileCatalog</c>.
    /// </summary>
    public sealed class CatalogBuilder
    {
        private static readonly DateTimeOffset s_defaultEffectiveTime =
            new(2000, 1, 1, 0, 0, 0, TimeSpan.Zero);

        private readonly List<CatalogEntry> _entries = new();

        public DateTimeOffset? EffectiveTime { get; set; }

        public byte[]? ListIdentifier
        {
            get => _listIdentifier;
            set
            {
                if (value is not null && value.Length != ListIdentifierLength)
                {
                    throw new ArgumentException(
                        $"List identifier must be exactly {ListIdentifierLength} bytes.", nameof(value));
                }

                _listIdentifier = value;
            }
        }
        private byte[]? _listIdentifier;

        private const int ListIdentifierLength = 16;

        public IReadOnlyList<CatalogEntry> Entries => _entries;

        public CatalogBuilder Add(CatalogEntry entry)
        {
            if (entry is null)
            {
                throw new ArgumentNullException(nameof(entry));
            }

            _entries.Add(entry);
            return this;
        }

        public CatalogBuilder AddFile(string filePath, string? name = null)
            => Add(CatalogEntry.FromFile(filePath, name));

        public byte[] Build()
        {
            if (_entries.Count == 0)
            {
                throw new InvalidOperationException("Catalog must contain at least one entry.");
            }

            List<Member> members = BuildSortedMembers();
            byte[] ctl = EncodeCertificateTrustList(members);
            return EncodePkcs7SignedDataEnvelope(ctl);
        }

        public void WriteTo(string path)
        {
            if (string.IsNullOrEmpty(path))
            {
                throw new ArgumentException("Path must not be null or empty.", nameof(path));
            }

            byte[] bytes = Build();
            using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            stream.Write(bytes, 0, bytes.Length);
            stream.Flush(flushToDisk: true);
        }

        private List<Member> BuildSortedMembers()
        {
            List<Member> members = new(_entries.Count * 2);
            foreach (CatalogEntry entry in _entries)
            {
                // SHA-1 members carry no FilePath attribute, so identical content has one
                // identical legacy lookup member regardless of its logical paths.
                members.Add(new Member(entry.Sha1, sha256Digest: null, relativePath: null));
                members.Add(new Member(entry.Sha256, sha256Digest: entry.Sha256, entry.Name));
            }

            members.Sort(static (a, b) =>
            {
                int identifierComparison = CompareBytes(a.Identifier, b.Identifier);
                return identifierComparison != 0
                    ? identifierComparison
                    : StringComparer.Ordinal.Compare(a.RelativePath, b.RelativePath);
            });

            var deduped = new List<Member>(members.Count);
            foreach (Member member in members)
            {
                if (deduped.Count == 0 ||
                    CompareBytes(deduped[deduped.Count - 1].Identifier, member.Identifier) != 0 ||
                    !string.Equals(deduped[deduped.Count - 1].RelativePath, member.RelativePath, StringComparison.Ordinal))
                {
                    deduped.Add(member);
                }
            }

            return deduped;
        }

        private byte[] EncodeCertificateTrustList(List<Member> members)
        {
            AsnWriter writer = new(AsnEncodingRules.DER);

            writer.PushSequence();

            writer.PushSequence();
            writer.WriteObjectIdentifier(CatalogOids.CatalogList);
            writer.PopSequence();

            writer.WriteOctetString(ListIdentifier ?? DeriveListIdentifier(members));
            writer.WriteUtcTime(EffectiveTime ?? s_defaultEffectiveTime);

            writer.PushSequence();
            writer.WriteObjectIdentifier(CatalogOids.CatalogListMemberV2);
            writer.WriteNull();
            writer.PopSequence();

            writer.PushSequence();
            foreach (Member member in members)
            {
                CatalogMemberEncoder.WriteTrustedSubject(
                    writer,
                    member.Identifier,
                    member.Sha256Digest,
                    member.Sha256Digest is null ? null : member.RelativePath);
            }
            writer.PopSequence();

            writer.PopSequence();

            return writer.Encode();
        }

        private static byte[] EncodePkcs7SignedDataEnvelope(byte[] ctlContent)
        {
            AsnWriter writer = new(AsnEncodingRules.DER);

            writer.PushSequence();
            writer.WriteObjectIdentifier(CatalogOids.SignedData);

            Asn1Tag explicit0 = new(TagClass.ContextSpecific, tagValue: 0, isConstructed: true);
            writer.PushSequence(explicit0);

            writer.PushSequence();
            writer.WriteInteger(1);

            writer.PushSetOf();
            writer.PopSetOf();

            writer.PushSequence();
            writer.WriteObjectIdentifier(CatalogOids.Ctl);
            writer.PushSequence(explicit0);
            writer.WriteEncodedValue(ctlContent);
            writer.PopSequence(explicit0);
            writer.PopSequence();

            writer.PushSetOf();
            writer.PopSetOf();

            writer.PopSequence();
            writer.PopSequence(explicit0);
            writer.PopSequence();

            return writer.Encode();
        }

        private static byte[] DeriveListIdentifier(List<Member> members)
        {
            using var sha256 = SHA256.Create();
            foreach (Member member in members)
            {
                sha256.TransformBlock(member.Identifier, 0, member.Identifier.Length, null, 0);
            }

            sha256.TransformFinalBlock(Array.Empty<byte>(), 0, 0);

            byte[] identifier = new byte[ListIdentifierLength];
            Array.Copy(sha256.Hash!, identifier, ListIdentifierLength);
            return identifier;
        }

        private static int CompareBytes(byte[] x, byte[] y)
        {
            int min = Math.Min(x.Length, y.Length);
            for (int index = 0; index < min; index++)
            {
                int difference = x[index] - y[index];
                if (difference != 0)
                {
                    return difference;
                }
            }

            return x.Length - y.Length;
        }

        private readonly struct Member
        {
            public Member(byte[] identifier, byte[]? sha256Digest, string? relativePath)
            {
                Identifier = identifier;
                Sha256Digest = sha256Digest;
                RelativePath = relativePath;
            }

            public byte[] Identifier { get; }

            public byte[]? Sha256Digest { get; }

            public string? RelativePath { get; }
        }
    }
}
