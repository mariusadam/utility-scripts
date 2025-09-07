<#
.SYNOPSIS
    Lightweight recursive directory comparison.

.DESCRIPTION
    Compares two directories recursively to check whether all files from the source
    are present in the destination and whether sizes match. For a stronger check,
    pass -Hash to compare MD5 hashes (slower but verifies content).

.PARAMETER Source
    Source directory path.

.PARAMETER Destination
    Destination directory path.

.PARAMETER Hash
    If present, compute MD5 hashes for files that exist in both and compare them.

.PARAMETER SkipEmpty
    If present, skip zero-byte files when comparing hashes.

.EXAMPLE
    .\CompareDirectories-Lite.ps1 -Source C:\src -Destination D:\dst

.EXAMPLE
    .\CompareDirectories-Lite.ps1 -Source C:\src -Destination D:\dst -Hash

.NOTES
    Exit codes:
      0 - no differences found
      1 - differences detected
      2 - invalid parameters / error
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateScript({ Test-Path $_ -PathType 'Container' })]
    [string]$Source,

    [Parameter(Mandatory=$true, Position=1)]
    [ValidateScript({ Test-Path $_ -PathType 'Container' })]
    [string]$Destination,

    [switch]$Hash,

    [switch]$SkipEmpty,

    [switch]$WriteJson,

    [string]$OutFile
)

# Normalize Source and Destination to absolute paths
try {
    $Source = (Get-Item -LiteralPath $Source).FullName
} catch {
    # Try to expand relative paths
    try { $Source = [System.IO.Path]::GetFullPath($Source) } catch { Write-Error "Source path invalid: $Source"; exit 2 }
}
try {
    $Destination = (Get-Item -LiteralPath $Destination).FullName
} catch {
    try { $Destination = [System.IO.Path]::GetFullPath($Destination) } catch { Write-Error "Destination path invalid: $Destination"; exit 2 }
}

# Ensure no trailing backslash
$Source = $Source.TrimEnd('\')
$Destination = $Destination.TrimEnd('\')


function Get-RelativeFileMap {
    param(
        [string]$Root
    )
    $rootFull = (Get-Item -LiteralPath $Root).FullName.TrimEnd('\')
    Get-ChildItem -LiteralPath $rootFull -Recurse -File -ErrorAction Stop | ForEach-Object {
        $rel = $_.FullName.Substring($rootFull.Length).TrimStart('\')
        [PSCustomObject]@{
            RelativePath = $rel
            FullName = $_.FullName
            Length = $_.Length
        }
    }
}

try {
    Write-Host "Building file map for Source: $Source"
    $srcFiles = Get-RelativeFileMap -Root $Source | Group-Object -Property RelativePath -AsHashTable -AsString
    Write-Host "Built file map for Source ($($srcFiles.Count) files)."
    Write-Host "Building file map for Destination: $Destination"
    $dstFiles = Get-RelativeFileMap -Root $Destination | Group-Object -Property RelativePath -AsHashTable -AsString
    Write-Host "Built file map for Destination ($($dstFiles.Count) files)."
} catch {
    Write-Error "Failed to enumerate files: $_"
    exit 2
}

$differences = @()

# Check for missing or size-mismatched files
foreach ($rel in $srcFiles.Keys) {
    $src = $srcFiles[$rel][0]
    if (-not $dstFiles.ContainsKey($rel)) {
        $differences += [PSCustomObject]@{Type='MissingInDestination'; RelativePath=$rel; SourceSize=$src.Length; DestinationSize=$null}
        continue
    }
    $dst = $dstFiles[$rel][0]
    if ($src.Length -ne $dst.Length) {
        $differences += [PSCustomObject]@{Type='SizeMismatch'; RelativePath=$rel; SourceSize=$src.Length; DestinationSize=$dst.Length}
    }
}

# Check for extra files in destination
foreach ($rel in $dstFiles.Keys) {
    if (-not $srcFiles.ContainsKey($rel)) {
        $dst = $dstFiles[$rel][0]
        $differences += [PSCustomObject]@{Type='ExtraInDestination'; RelativePath=$rel; SourceSize=$null; DestinationSize=$dst.Length}
    }
}

# Optional hash checks for files that exist in both and have same size
if ($Hash -and ($differences.Count -eq 0 -or $true)) {
    # Only check files present in both
    $common = @()
    foreach ($rel in $srcFiles.Keys) {
        if ($dstFiles.ContainsKey($rel)) {
            $s = $srcFiles[$rel][0]
            $d = $dstFiles[$rel][0]
            if ($SkipEmpty -and $s.Length -eq 0 -and $d.Length -eq 0) { continue }
            $common += [PSCustomObject]@{RelativePath=$rel; Source=$s.FullName; Destination=$d.FullName}
        }
    }

    foreach ($item in $common) {
        try {
            $srcHash = Get-FileHash -Algorithm MD5 -LiteralPath $item.Source -ErrorAction Stop
            $dstHash = Get-FileHash -Algorithm MD5 -LiteralPath $item.Destination -ErrorAction Stop
            if ($srcHash.Hash -ne $dstHash.Hash) {
                $differences += [PSCustomObject]@{Type='HashMismatch'; RelativePath=$item.RelativePath; SourceHash=$srcHash.Hash; DestinationHash=$dstHash.Hash}
            }
        } catch {
            # If hashing fails, record as error
            $differences += [PSCustomObject]@{Type='HashError'; RelativePath=$item.RelativePath; Error=$_.Exception.Message}
        }
    }
}

# Prepare summary counts per Type
$summary = @()
if ($differences.Count -gt 0) {
    $summary = $differences | Group-Object -Property Type | Sort-Object -Property Count -Descending | Select-Object Name, Count
}

if ($differences.Count -eq 0) {
    Write-Host "No differences found between '$Source' and '$Destination'."
} else {
    Write-Host "Detailed differences:"
    # Output a compact report
    $differences | Select-Object Type, RelativePath, SourceSize, DestinationSize, SourceHash, DestinationHash, Error | Format-Table -AutoSize
    
    Write-Host "Differences found: $($differences.Count)"

    Write-Host "Summary by type:"
    $summary | Format-Table @{Label='Type';Expression={$_.Name}}, @{Label='Count';Expression={$_.Count}} -AutoSize
}

# Optionally write JSON report (always write when requested)
if ($WriteJson) {
    if (-not $OutFile) {
        $OutFile = Join-Path -Path (Get-Location) -ChildPath 'CompareDirectories-Report.json'
    }

    # Prepare JSON-friendly objects (ensure arrays)
    $differencesForJson = @($differences | Select-Object Type, RelativePath, SourceSize, DestinationSize, SourceHash, DestinationHash, Error)
    $summaryForJson = @($summary | ForEach-Object { [PSCustomObject]@{Type = $_.Name; Count = $_.Count} })

    $report = [PSCustomObject]@{
        Source = $Source
        Destination = $Destination
        Timestamp = (Get-Date).ToString('o')
        SourceFileCount = $srcFiles.Count
        DestinationFileCount = $dstFiles.Count
        DifferencesCount = $differences.Count
        Summary = $summaryForJson
        Differences = $differencesForJson
    }

    try {
        $json = $report | ConvertTo-Json -Depth 5 -Compress
        $json | Out-File -FilePath $OutFile -Encoding UTF8
        Write-Host "Wrote JSON report to: $OutFile"
    } catch {
        Write-Error "Failed to write JSON report to '$OutFile': $_"
    }
}

if ($differences.Count -eq 0) { exit 0 } else { exit 1 }
