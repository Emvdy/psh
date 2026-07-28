# Copyright (C) 2026 Emvdy
# SPDX-License-Identifier: GPL-3.0-or-later

#Requires -Version 5.1

Set-StrictMode -Version 2.0

function Get-PshGoal6ZipBufferSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Get-PshGoal6ZipStreamSha256 {
    param([Parameter(Mandatory = $true)][IO.Stream]$Stream)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($Stream))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Get-PshGoal6ZipByteSliceBase64 {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][int]$Offset,
        [Parameter(Mandatory = $true)][int]$Length
    )

    Assert-PshGoal6Condition ($Offset -ge 0 -and $Length -ge 0 -and $Offset + $Length -le $Bytes.Length) 'ZIP byte slice is outside the archive.'
    if ($Length -eq 0) { return '' }
    $slice = New-Object byte[] $Length
    [Array]::Copy($Bytes, $Offset, $slice, 0, $Length)
    return [Convert]::ToBase64String($slice)
}

function Clear-PshGoal6ZipNormalizedByteRange {
    param(
        [Parameter(Mandatory = $true)][byte[]]$NormalizedBytes,
        [Parameter(Mandatory = $true)][int]$Offset,
        [Parameter(Mandatory = $true)][int]$Length
    )

    Assert-PshGoal6Condition ($Offset -ge 0 -and $Length -ge 0 -and [int64]$Offset + [int64]$Length -le $NormalizedBytes.Length) 'ZIP timestamp byte range is outside the archive.'
    for ($index = $Offset; $index -lt $Offset + $Length; $index++) { $NormalizedBytes[$index] = 0 }
}

function ConvertTo-PshGoal6ZipNormalizedExtraField {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][byte[]]$NormalizedBytes,
        [Parameter(Mandatory = $true)][int]$Offset,
        [Parameter(Mandatory = $true)][int]$Length,
        [Parameter(Mandatory = $true)][ValidateSet('local', 'central')][string]$HeaderKind,
        [Parameter(Mandatory = $true)][string]$DisplayPath,
        [Parameter(Mandatory = $true)][int]$EntryIndex
    )

    $extraEnd = [int64]$Offset + [int64]$Length
    Assert-PshGoal6Condition ($Offset -ge 0 -and $Length -ge 0 -and $extraEnd -le $Bytes.Length) "ZIP $HeaderKind extra-field range is outside the archive: $DisplayPath entry $EntryIndex"
    $position = [int64]$Offset
    while ($position -lt $extraEnd) {
        Assert-PshGoal6Condition ($position + 4 -le $extraEnd) "ZIP $HeaderKind extra-field header is truncated: $DisplayPath entry $EntryIndex"
        $fieldOffset = [int]$position
        $headerId = [BitConverter]::ToUInt16($Bytes, $fieldOffset)
        $dataLength = [int][BitConverter]::ToUInt16($Bytes, $fieldOffset + 2)
        $dataOffset = $fieldOffset + 4
        $fieldEnd = [int64]$dataOffset + [int64]$dataLength
        $headerIdText = '0x{0:X4}' -f $headerId
        Assert-PshGoal6Condition ($fieldEnd -le $extraEnd) "ZIP $HeaderKind extra field $headerIdText is truncated: $DisplayPath entry $EntryIndex"

        switch ([int]$headerId) {
            0x5455 {
                Assert-PshGoal6Condition ($dataLength -ge 1) "ZIP $HeaderKind extended-timestamp extra field is missing flags: $DisplayPath entry $EntryIndex"
                $flags = [int]$Bytes[$dataOffset]
                Assert-PshGoal6Condition (($flags -band 0xF8) -eq 0) "ZIP $HeaderKind extended-timestamp extra field has reserved flags: $DisplayPath entry $EntryIndex"
                if ($HeaderKind -ceq 'local') {
                    $expectedLength = 1
                    foreach ($mask in @(0x01, 0x02, 0x04)) {
                        if (($flags -band $mask) -ne 0) { $expectedLength += 4 }
                    }
                    Assert-PshGoal6Condition ($dataLength -eq $expectedLength) "ZIP local extended-timestamp extra-field length disagrees with its flags: $DisplayPath entry $EntryIndex"
                    $timestampOffset = $dataOffset + 1
                    foreach ($mask in @(0x01, 0x02, 0x04)) {
                        if (($flags -band $mask) -eq 0) { continue }
                        Clear-PshGoal6ZipNormalizedByteRange -NormalizedBytes $NormalizedBytes -Offset $timestampOffset -Length 4
                        $timestampOffset += 4
                    }
                }
                else {
                    $expectedLength = if (($flags -band 0x01) -ne 0) { 5 } else { 1 }
                    Assert-PshGoal6Condition ($dataLength -eq $expectedLength) "ZIP central extended-timestamp extra-field length disagrees with its flags: $DisplayPath entry $EntryIndex"
                    if (($flags -band 0x01) -ne 0) { Clear-PshGoal6ZipNormalizedByteRange -NormalizedBytes $NormalizedBytes -Offset ($dataOffset + 1) -Length 4 }
                }
            }
            0x000A {
                Assert-PshGoal6Condition ($dataLength -ge 8) "ZIP $HeaderKind NTFS extra field is too short: $DisplayPath entry $EntryIndex"
                $attributePosition = [int64]$dataOffset + 4
                while ($attributePosition -lt $fieldEnd) {
                    Assert-PshGoal6Condition ($attributePosition + 4 -le $fieldEnd) "ZIP $HeaderKind NTFS attribute header is truncated: $DisplayPath entry $EntryIndex"
                    $attributeOffset = [int]$attributePosition
                    $attributeTag = [BitConverter]::ToUInt16($Bytes, $attributeOffset)
                    $attributeLength = [int][BitConverter]::ToUInt16($Bytes, $attributeOffset + 2)
                    $attributeDataOffset = $attributeOffset + 4
                    $attributeEnd = [int64]$attributeDataOffset + [int64]$attributeLength
                    Assert-PshGoal6Condition ($attributeEnd -le $fieldEnd) "ZIP $HeaderKind NTFS attribute is truncated: $DisplayPath entry $EntryIndex"
                    if ($attributeTag -eq 0x0001) {
                        Assert-PshGoal6Condition ($attributeLength -eq 24) "ZIP $HeaderKind NTFS FILETIME attribute length is not 24 bytes: $DisplayPath entry $EntryIndex"
                        Clear-PshGoal6ZipNormalizedByteRange -NormalizedBytes $NormalizedBytes -Offset $attributeDataOffset -Length 24
                    }
                    $attributePosition = $attributeEnd
                }
                Assert-PshGoal6Condition ($attributePosition -eq $fieldEnd) "ZIP $HeaderKind NTFS attribute layout is malformed: $DisplayPath entry $EntryIndex"
            }
            0x5855 {
                if ($HeaderKind -ceq 'local') {
                    Assert-PshGoal6Condition ($dataLength -eq 8 -or $dataLength -eq 12) "ZIP local Info-ZIP Unix1 extra-field length is not 8 or 12 bytes: $DisplayPath entry $EntryIndex"
                }
                else {
                    Assert-PshGoal6Condition ($dataLength -eq 8) "ZIP central Info-ZIP Unix1 extra-field length is not 8 bytes: $DisplayPath entry $EntryIndex"
                }
                Clear-PshGoal6ZipNormalizedByteRange -NormalizedBytes $NormalizedBytes -Offset $dataOffset -Length 8
            }
            0x000D {
                Assert-PshGoal6Condition ($HeaderKind -ceq 'local') "ZIP PKWARE Unix extra field is only valid in a local header: $DisplayPath entry $EntryIndex"
                Assert-PshGoal6Condition ($dataLength -ge 12) "ZIP local PKWARE Unix extra field is shorter than 12 bytes: $DisplayPath entry $EntryIndex"
                Clear-PshGoal6ZipNormalizedByteRange -NormalizedBytes $NormalizedBytes -Offset $dataOffset -Length 8
            }
        }
        $position = $fieldEnd
    }
    Assert-PshGoal6Condition ($position -eq $extraEnd) "ZIP $HeaderKind extra-field layout is malformed: $DisplayPath entry $EntryIndex"
}

function Get-PshGoal6ZipArchiveManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$DisplayPath
    )

    Assert-PshGoal6Condition ([BitConverter]::IsLittleEndian) 'ZIP metadata parsing requires a little-endian runtime.'
    $archivePathFull = [IO.Path]::GetFullPath($ArchivePath)
    Assert-PshGoal6Condition ([IO.File]::Exists($archivePathFull)) "ZIP archive is missing: $archivePathFull"
    [byte[]]$bytes = [IO.File]::ReadAllBytes($archivePathFull)
    Assert-PshGoal6Condition ($bytes.Length -ge 22) "ZIP archive is too short: $DisplayPath"
    [byte[]]$normalizedBytes = [byte[]]$bytes.Clone()

    $eocdOffset = -1
    $searchStart = [Math]::Max(0, $bytes.Length - 65557)
    for ($candidate = $bytes.Length - 22; $candidate -ge $searchStart; $candidate--) {
        if ([BitConverter]::ToUInt32($bytes, $candidate) -ne [uint32]0x06054B50) { continue }
        $commentLength = [int][BitConverter]::ToUInt16($bytes, $candidate + 20)
        if ($candidate + 22 + $commentLength -eq $bytes.Length) { $eocdOffset = $candidate; break }
    }
    Assert-PshGoal6Condition ($eocdOffset -ge 0) "ZIP end-of-central-directory record is missing or malformed: $DisplayPath"

    $diskNumber = [BitConverter]::ToUInt16($bytes, $eocdOffset + 4)
    $centralDiskNumber = [BitConverter]::ToUInt16($bytes, $eocdOffset + 6)
    $entryCountOnDisk = [BitConverter]::ToUInt16($bytes, $eocdOffset + 8)
    $entryCount = [BitConverter]::ToUInt16($bytes, $eocdOffset + 10)
    $centralSize = [BitConverter]::ToUInt32($bytes, $eocdOffset + 12)
    $centralOffset = [BitConverter]::ToUInt32($bytes, $eocdOffset + 16)
    Assert-PshGoal6Condition ($diskNumber -eq 0 -and $centralDiskNumber -eq 0 -and $entryCountOnDisk -eq $entryCount) "Multi-disk ZIP archives are not supported: $DisplayPath"
    Assert-PshGoal6Condition ($entryCount -ne [uint16]0xFFFF -and $centralSize -ne [uint32]::MaxValue -and $centralOffset -ne [uint32]::MaxValue) "ZIP64 archives are not supported by the reproducibility gate: $DisplayPath"
    Assert-PshGoal6Condition ([int64]$centralOffset + [int64]$centralSize -eq [int64]$eocdOffset) "ZIP central-directory bounds are malformed: $DisplayPath"

    $archiveCommentLength = [int][BitConverter]::ToUInt16($bytes, $eocdOffset + 20)
    $archiveCommentBase64 = Get-PshGoal6ZipByteSliceBase64 -Bytes $bytes -Offset ($eocdOffset + 22) -Length $archiveCommentLength
    $centralEntries = New-Object System.Collections.Generic.List[object]
    $centralPosition = [int64]$centralOffset
    for ($index = 0; $index -lt [int]$entryCount; $index++) {
        Assert-PshGoal6Condition ($centralPosition + 46 -le $eocdOffset) "ZIP central entry $index is truncated: $DisplayPath"
        $position = [int]$centralPosition
        Assert-PshGoal6Condition ([BitConverter]::ToUInt32($bytes, $position) -eq [uint32]0x02014B50) "ZIP central entry $index has an invalid signature: $DisplayPath"
        $versionMadeBy = [BitConverter]::ToUInt16($bytes, $position + 4)
        $versionNeeded = [BitConverter]::ToUInt16($bytes, $position + 6)
        $flags = [BitConverter]::ToUInt16($bytes, $position + 8)
        $compressionMethod = [BitConverter]::ToUInt16($bytes, $position + 10)
        $crc32 = [BitConverter]::ToUInt32($bytes, $position + 16)
        $compressedSize = [BitConverter]::ToUInt32($bytes, $position + 20)
        $uncompressedSize = [BitConverter]::ToUInt32($bytes, $position + 24)
        $fileNameLength = [int][BitConverter]::ToUInt16($bytes, $position + 28)
        $extraLength = [int][BitConverter]::ToUInt16($bytes, $position + 30)
        $entryCommentLength = [int][BitConverter]::ToUInt16($bytes, $position + 32)
        $diskStart = [BitConverter]::ToUInt16($bytes, $position + 34)
        $internalAttributes = [BitConverter]::ToUInt16($bytes, $position + 36)
        $externalAttributes = [BitConverter]::ToUInt32($bytes, $position + 38)
        $localHeaderOffset = [BitConverter]::ToUInt32($bytes, $position + 42)
        Assert-PshGoal6Condition ($compressedSize -ne [uint32]::MaxValue -and $uncompressedSize -ne [uint32]::MaxValue -and $localHeaderOffset -ne [uint32]::MaxValue) "ZIP64 entry metadata is not supported: $DisplayPath entry $index"
        Assert-PshGoal6Condition ($diskStart -eq 0) "ZIP entry starts on another disk: $DisplayPath entry $index"
        $recordLength = 46 + $fileNameLength + $extraLength + $entryCommentLength
        Assert-PshGoal6Condition ($centralPosition + $recordLength -le $eocdOffset) "ZIP central entry $index overruns the central directory: $DisplayPath"
        $fileNameOffset = $position + 46
        $extraOffset = $fileNameOffset + $fileNameLength
        $entryCommentOffset = $extraOffset + $extraLength
        for ($timestampOffset = $position + 12; $timestampOffset -le $position + 15; $timestampOffset++) { $normalizedBytes[$timestampOffset] = 0 }
        ConvertTo-PshGoal6ZipNormalizedExtraField -Bytes $bytes -NormalizedBytes $normalizedBytes -Offset $extraOffset -Length $extraLength -HeaderKind central -DisplayPath $DisplayPath -EntryIndex $index
        $centralEntries.Add([pscustomobject][ordered]@{
                index = $index
                path = $null
                isDirectory = $false
                length = [int64]$uncompressedSize
                compressedLength = [int64]$compressedSize
                sha256 = $null
                versionMadeBy = ('0x{0:X4}' -f $versionMadeBy)
                versionNeeded = ('0x{0:X4}' -f $versionNeeded)
                flags = ('0x{0:X4}' -f $flags)
                compressionMethod = [int]$compressionMethod
                crc32 = ('0x{0:X8}' -f $crc32)
                internalAttributes = ('0x{0:X4}' -f $internalAttributes)
                externalAttributes = ('0x{0:X8}' -f $externalAttributes)
                fileNameBytesBase64 = Get-PshGoal6ZipByteSliceBase64 -Bytes $bytes -Offset $fileNameOffset -Length $fileNameLength
                centralExtraBase64 = Get-PshGoal6ZipByteSliceBase64 -Bytes $normalizedBytes -Offset $extraOffset -Length $extraLength
                entryCommentBase64 = Get-PshGoal6ZipByteSliceBase64 -Bytes $bytes -Offset $entryCommentOffset -Length $entryCommentLength
                localExtraBase64 = $null
                localHeaderOffset = [int64]$localHeaderOffset
                externalAttributesValue = [uint32]$externalAttributes
                flagsValue = [uint16]$flags
                compressionMethodValue = [uint16]$compressionMethod
            })
        $centralPosition += $recordLength
    }
    Assert-PshGoal6Condition ($centralPosition -eq [int64]$eocdOffset) "ZIP central-directory entry count or size is inconsistent: $DisplayPath"

    foreach ($metadata in $centralEntries) {
        $localPosition = [int]$metadata.localHeaderOffset
        Assert-PshGoal6Condition ($localPosition -ge 0 -and $localPosition + 30 -le [int]$centralOffset) "ZIP local header is outside the file-data region: $DisplayPath entry $($metadata.index)"
        Assert-PshGoal6Condition ([BitConverter]::ToUInt32($bytes, $localPosition) -eq [uint32]0x04034B50) "ZIP local header signature is invalid: $DisplayPath entry $($metadata.index)"
        $localFlags = [BitConverter]::ToUInt16($bytes, $localPosition + 6)
        $localMethod = [BitConverter]::ToUInt16($bytes, $localPosition + 8)
        $localNameLength = [int][BitConverter]::ToUInt16($bytes, $localPosition + 26)
        $localExtraLength = [int][BitConverter]::ToUInt16($bytes, $localPosition + 28)
        Assert-PshGoal6Condition ($localPosition + 30 + $localNameLength + $localExtraLength -le [int]$centralOffset) "ZIP local header metadata is truncated: $DisplayPath entry $($metadata.index)"
        Assert-PshGoal6Condition ($localFlags -eq [uint16]$metadata.flagsValue -and $localMethod -eq [uint16]$metadata.compressionMethodValue) "ZIP local/central compression flags or method differ: $DisplayPath entry $($metadata.index)"
        $localNameBase64 = Get-PshGoal6ZipByteSliceBase64 -Bytes $bytes -Offset ($localPosition + 30) -Length $localNameLength
        Assert-PshGoal6Condition ($localNameBase64 -ceq [string]$metadata.fileNameBytesBase64) "ZIP local/central entry names differ: $DisplayPath entry $($metadata.index)"
        $localExtraOffset = $localPosition + 30 + $localNameLength
        for ($timestampOffset = $localPosition + 10; $timestampOffset -le $localPosition + 13; $timestampOffset++) { $normalizedBytes[$timestampOffset] = 0 }
        ConvertTo-PshGoal6ZipNormalizedExtraField -Bytes $bytes -NormalizedBytes $normalizedBytes -Offset $localExtraOffset -Length $localExtraLength -HeaderKind local -DisplayPath $DisplayPath -EntryIndex ([int]$metadata.index)
        $metadata.localExtraBase64 = Get-PshGoal6ZipByteSliceBase64 -Bytes $normalizedBytes -Offset $localExtraOffset -Length $localExtraLength
    }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $stream = [IO.File]::OpenRead($archivePathFull)
    try {
        $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Read, $false)
        try {
            Assert-PshGoal6Condition ($archive.Entries.Count -eq $centralEntries.Count) "ZIP API and central-directory entry counts differ: $DisplayPath"
            for ($index = 0; $index -lt $archive.Entries.Count; $index++) {
                $entry = $archive.Entries[$index]
                $metadata = $centralEntries[$index]
                $entryName = ([string]$entry.FullName).Replace('\', '/')
                $isDirectory = $entryName.EndsWith('/', [StringComparison]::Ordinal)
                $semanticName = if ($isDirectory) { $entryName.TrimEnd('/') } else { $entryName }
                Assert-PshGoal6Condition (-not [string]::IsNullOrWhiteSpace($semanticName)) "ZIP contains an empty entry name: $DisplayPath"
                Assert-PshGoal6Condition (-not [IO.Path]::IsPathRooted($semanticName)) "ZIP contains a rooted entry: $DisplayPath!$entryName"
                Assert-PshGoal6Condition ($semanticName -notmatch '[:*?"<>|]') "ZIP contains an invalid entry path: $DisplayPath!$entryName"
                $segments = @($semanticName.Split('/'))
                Assert-PshGoal6Condition ($segments -notcontains '.' -and $segments -notcontains '..') "ZIP contains a traversal entry: $DisplayPath!$entryName"
                Assert-PshGoal6Condition (@($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) "ZIP contains an empty path segment: $DisplayPath!$entryName"
                Assert-PshGoal6Condition ($seen.Add($semanticName)) "ZIP contains a case-insensitive duplicate semantic path: $DisplayPath!$entryName"

                $externalAttributes = [uint32]$metadata.externalAttributesValue
                $unixType = [int](($externalAttributes -shr 16) -band [uint32]0xF000)
                $dosAttributes = [int]($externalAttributes -band [uint32]0xFFFF)
                Assert-PshGoal6Condition ($unixType -ne 0xA000) "ZIP contains a symbolic-link entry: $DisplayPath!$entryName"
                Assert-PshGoal6Condition ($unixType -eq 0 -or $unixType -eq 0x8000 -or $unixType -eq 0x4000) "ZIP contains an unsupported special Unix entry type: $DisplayPath!$entryName"
                Assert-PshGoal6Condition (($dosAttributes -band 0x400) -eq 0) "ZIP contains a reparse-point entry: $DisplayPath!$entryName"
                Assert-PshGoal6Condition (-not ($isDirectory -and $unixType -eq 0x8000) -and -not ((-not $isDirectory) -and $unixType -eq 0x4000)) "ZIP entry path/type semantics disagree: $DisplayPath!$entryName"
                Assert-PshGoal6Condition (($metadata.flagsValue -band 0x0001) -eq 0) "ZIP contains an encrypted entry: $DisplayPath!$entryName"
                Assert-PshGoal6Condition ([int64]$entry.Length -eq [int64]$metadata.length -and [int64]$entry.CompressedLength -eq [int64]$metadata.compressedLength) "ZIP API and central-directory lengths differ: $DisplayPath!$entryName"

                $entryStream = $entry.Open()
                try { $entrySha256 = Get-PshGoal6ZipStreamSha256 -Stream $entryStream }
                finally { $entryStream.Dispose() }
                $metadata.path = $entryName
                $metadata.isDirectory = $isDirectory
                $metadata.sha256 = $entrySha256
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }

    $entries = @($centralEntries.ToArray() | ForEach-Object {
            [pscustomobject][ordered]@{
                index = [int]$_.index
                path = [string]$_.path
                isDirectory = [bool]$_.isDirectory
                length = [int64]$_.length
                compressedLength = [int64]$_.compressedLength
                sha256 = [string]$_.sha256
                versionMadeBy = [string]$_.versionMadeBy
                versionNeeded = [string]$_.versionNeeded
                flags = [string]$_.flags
                compressionMethod = [int]$_.compressionMethod
                crc32 = [string]$_.crc32
                internalAttributes = [string]$_.internalAttributes
                externalAttributes = [string]$_.externalAttributes
                fileNameBytesBase64 = [string]$_.fileNameBytesBase64
                centralExtraBase64 = [string]$_.centralExtraBase64
                entryCommentBase64 = [string]$_.entryCommentBase64
                localExtraBase64 = [string]$_.localExtraBase64
            }
        })
    return [pscustomobject][ordered]@{
        path = $DisplayPath
        containerSha256Informational = Get-PshGoal6Sha256 -Path $archivePathFull
        timestampNormalizedContainerSha256 = Get-PshGoal6ZipBufferSha256 -Bytes $normalizedBytes
        timestampNormalization = 'DOS modification fields and standard timestamp payloads in 0x5455, 0x000A/0x0001, 0x5855, and 0x000D extra fields are zeroed; all headers, flags, lengths, tags, and non-time bytes are retained.'
        containerMetadataCompared = $true
        archiveCommentBase64 = $archiveCommentBase64
        entries = $entries
    }
}

function Compare-PshGoal6ZipArchiveManifest {
    param(
        [Parameter(Mandatory = $true)][object]$First,
        [Parameter(Mandatory = $true)][object]$Second
    )

    $differences = New-Object System.Collections.Generic.List[object]
    $archivePath = [string]$First.path
    if ([string]$First.timestampNormalizedContainerSha256 -cne [string]$Second.timestampNormalizedContainerSha256) {
        $differences.Add([pscustomobject][ordered]@{ kind = 'archive-nontimestamp-container-bytes'; path = $archivePath; first = [string]$First.timestampNormalizedContainerSha256; second = [string]$Second.timestampNormalizedContainerSha256 })
    }
    if ([string]$First.archiveCommentBase64 -cne [string]$Second.archiveCommentBase64) {
        $differences.Add([pscustomobject][ordered]@{ kind = 'archive-comment'; path = $archivePath; first = [string]$First.archiveCommentBase64; second = [string]$Second.archiveCommentBase64 })
    }

    $firstEntries = @($First.entries)
    $secondEntries = @($Second.entries)
    $entryCount = [Math]::Max($firstEntries.Count, $secondEntries.Count)
    $fields = @('path', 'isDirectory', 'length', 'compressedLength', 'sha256', 'versionMadeBy', 'versionNeeded', 'flags', 'compressionMethod', 'crc32', 'internalAttributes', 'externalAttributes', 'fileNameBytesBase64', 'centralExtraBase64', 'entryCommentBase64', 'localExtraBase64')
    for ($index = 0; $index -lt $entryCount; $index++) {
        $qualifiedPath = $archivePath + '!entry[' + $index + ']'
        if ($index -ge $firstEntries.Count) { $differences.Add([pscustomobject][ordered]@{ kind = 'archive-entry-missing-first'; path = $qualifiedPath; first = $null; second = [string]$secondEntries[$index].path }); continue }
        if ($index -ge $secondEntries.Count) { $differences.Add([pscustomobject][ordered]@{ kind = 'archive-entry-missing-second'; path = $qualifiedPath; first = [string]$firstEntries[$index].path; second = $null }); continue }
        foreach ($field in $fields) {
            $firstValue = Get-PshGoal6Property -InputObject $firstEntries[$index] -Name $field
            $secondValue = Get-PshGoal6Property -InputObject $secondEntries[$index] -Name $field
            if ([string]$firstValue -ceq [string]$secondValue) { continue }
            $kind = if ($field -ceq 'path') { 'archive-entry-order' } else { 'archive-entry-' + $field }
            $differences.Add([pscustomobject][ordered]@{ kind = $kind; path = $qualifiedPath; first = $firstValue; second = $secondValue })
        }
    }
    return $differences.ToArray()
}
