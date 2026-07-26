// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using System.Formats.Asn1;
using System.Text;

namespace Microsoft.DotNet.Build.Tasks.FileCatalog
{
    /// <summary>
    /// DER-encodes the per-member ASN.1 structures inside a Microsoft Catalog (.cat) file.
    /// Psh adds the CAT_NAMEVALUE/FilePath attribute required by PowerShell CatalogHelper.
    /// </summary>
    internal static class CatalogMemberEncoder
    {
        public static void WriteTrustedSubject(
            AsnWriter writer,
            byte[] identifier,
            byte[]? sha256Digest,
            string? relativePath)
        {
            if ((sha256Digest is null) != (relativePath is null))
            {
                throw new ArgumentException("SHA-256 digest and relative path must either both be present or both be absent.");
            }

            writer.PushSequence();
            writer.WriteOctetString(identifier);

            writer.PushSetOf();

            WriteCatMemberInfo2Attribute(writer);
            if (sha256Digest is not null && relativePath is not null)
            {
                WriteFilePathAttribute(writer, relativePath);
                WriteSpcIndirectDataAttribute(writer, sha256Digest);
            }

            writer.PopSetOf();
            writer.PopSequence();
        }

        private static void WriteCatMemberInfo2Attribute(AsnWriter writer)
        {
            writer.PushSequence();
            writer.WriteObjectIdentifier(CatalogOids.CatMemberInfo2);
            writer.PushSetOf();
            writer.WriteNull(new Asn1Tag(TagClass.ContextSpecific, tagValue: 2));
            writer.PopSetOf();
            writer.PopSequence();
        }

        private static void WriteFilePathAttribute(AsnWriter writer, string relativePath)
        {
            writer.PushSequence();
            writer.WriteObjectIdentifier(CatalogOids.CatNameValue);
            writer.PushSetOf();

            writer.PushSequence();
            writer.WriteCharacterString(UniversalTagNumber.BMPString, "FilePath");
            writer.WriteInteger(0x10010001);
            writer.WriteOctetString(Encoding.Unicode.GetBytes(relativePath + "\0"));
            writer.PopSequence();

            writer.PopSetOf();
            writer.PopSequence();
        }

        private static void WriteSpcIndirectDataAttribute(AsnWriter writer, byte[] sha256Digest)
        {
            writer.PushSequence();
            writer.WriteObjectIdentifier(CatalogOids.SpcIndirectData);
            writer.PushSetOf();

            writer.PushSequence();

            writer.PushSequence();
            writer.WriteObjectIdentifier(CatalogOids.SpcLinkData);
            Asn1Tag fileTag = new(TagClass.ContextSpecific, tagValue: 2, isConstructed: true);
            writer.PushSequence(fileTag);
            Asn1Tag unicodeTag = new(TagClass.ContextSpecific, tagValue: 0, isConstructed: false);
            writer.WriteCharacterString(UniversalTagNumber.BMPString, string.Empty, unicodeTag);
            writer.PopSequence(fileTag);
            writer.PopSequence();

            writer.PushSequence();
            writer.PushSequence();
            writer.WriteObjectIdentifier(CatalogOids.Sha256);
            writer.WriteNull();
            writer.PopSequence();
            writer.WriteOctetString(sha256Digest);
            writer.PopSequence();

            writer.PopSequence();

            writer.PopSetOf();
            writer.PopSequence();
        }
    }
}
