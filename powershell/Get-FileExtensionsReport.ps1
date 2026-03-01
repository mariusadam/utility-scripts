<#
.SYNOPSIS
    Generate a report of file extensions for files in a directory (recursive).

.DESCRIPTION
    Scans the given directory recursively and aggregates files by extension.
    For each extension the report contains Count and TotalSizeMB (megabytes). Optionally
    include the list of files per extension. Output can be written as JSON, CSV
    or a formatted text table.

.PARAMETER Path
    The directory path to scan (mandatory).

.PARAMETER OutFile
    Optional path to write the report. If omitted the report is printed to
    standard output.

.PARAMETER Format
    Output format: json (default), csv or text.

.PARAMETER IncludeFiles
    When specified, include the list of file paths for each extension.

.EXAMPLE
    & .\Get-FileExtensionsReport.ps1 -Path C:\Temp -OutFile report.json -Format json -IncludeFiles

#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateNotNullOrEmpty()]
    [string]$Path,

    [Parameter(Mandatory=$false)]
    [string]$OutFile,

    [Parameter(Mandatory=$false)]
    [ValidateSet('json','csv','text')]
    [string]$Format = 'json',

    [switch]$IncludeFiles
)

$ErrorActionPreference = 'Stop';
$InformationPreference = 'Continue';

function Write-ReportAndExit {
    param(
        [Parameter(Mandatory=$true)] $Report
    )

    switch ($Format) {
        'json' {
            $json = $Report | ConvertTo-Json -Depth 6
            if ($OutFile) {
                $json | Out-File -FilePath $OutFile -Encoding utf8
                Write-Information "Wrote JSON report to: $OutFile"
            }
            else {
                Write-Output $json
            }
        }
        'csv' {
            # CSV will omit the Files array to keep CSV simple
            $csvObj = $Report | Select-Object Extension,Count,TotalSizeMB
            if ($OutFile) {
                $csvObj | Export-Csv -Path $OutFile -NoTypeInformation -Encoding utf8
                Write-Information "Wrote CSV report to: $OutFile"
            }
            else {
                $csvObj | Format-Table -AutoSize
            }
        }
        'text' {
            $Report | Format-Table -AutoSize
            if ($OutFile) {
                # Save a simple text table
                $Report | Out-String -Width 4096 | Out-File -FilePath $OutFile -Encoding utf8
                Write-Information "Wrote text report to: $OutFile"
            }
        }
    }
}

try {
    if (-not (Test-Path -Path $Path)) {
        Write-Error "Path not found: $Path"
        exit 1
    }

    $files = Get-ChildItem -Path $Path -File -Recurse -ErrorAction Stop

    if (-not $files) {
        Write-Information "No files found under: $Path"
        exit 0
    }

    $groups = $files | Group-Object -Property @{Expression={
        $ext = $_.Extension
        if ([string]::IsNullOrEmpty($ext)) { 'noext' } else { $ext.TrimStart('.').ToLower() }
    }}

    $report = $groups | ForEach-Object {
        $sum = ($_.Group | Measure-Object -Property Length -Sum).Sum
        [PSCustomObject]@{
            Extension = $_.Name
            Count = $_.Count
            # Total size in megabytes (rounded to 2 decimals)
            TotalSizeMB = [math]::Round((([double]$sum) / 1MB), 2)
            Files = if ($IncludeFiles) { $_.Group | ForEach-Object { $_.FullName } }
        }
    } | Sort-Object -Property Count -Descending

    Write-ReportAndExit -Report $report
    exit 0
}
catch {
    Write-Error "Failed to generate report: $_"
    exit 1
}
