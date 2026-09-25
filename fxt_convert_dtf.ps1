param(
    [Parameter(Mandatory=$true)][string]$InputFile,
    [string]$OutputFile,
    [ValidateSet('auto','utf-8','utf-8-bom','utf-16le','utf-16be','cp1251','cp1252','cp866','koi8-r','iso-8859-5','ascii')]
    [string]$Encoding = 'auto',
    [switch]$Strict,
    [switch]$Diagnose,
    [switch]$FixDuplicates,
    [switch]$PreferLast,
    [switch]$FixSourceTxt,
    [switch]$KeepTrailingSpaces
)

$ErrorActionPreference = "Stop"

function Get-EncByName([string]$name) {
    switch ($name.ToLower()) {
        'utf-8'      { return (New-Object System.Text.UTF8Encoding($false, $true)) }
        'utf-8-bom'  { return (New-Object System.Text.UTF8Encoding($true,  $true)) }
        'utf-16le'   { return [Text.Encoding]::Unicode }
        'utf-16be'   { return [Text.Encoding]::BigEndianUnicode }
        'cp1251'     { return [Text.Encoding]::GetEncoding(1251) }
        'cp1252'     { return [Text.Encoding]::GetEncoding(1252) }
        'cp866'      { return [Text.Encoding]::GetEncoding(866) }
        'koi8-r'     { return [Text.Encoding]::GetEncoding(20866) }
        'iso-8859-5' { return [Text.Encoding]::GetEncoding(28595) }
        'ascii'      { return [Text.Encoding]::ASCII }
        default      { return [Text.Encoding]::GetEncoding(1251) }
    }
}

function Test-StrictUtf8([byte[]]$bytes) {
    try {
        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        $null = $strict.GetString($bytes)
        return $true
    } catch { return $false }
}

function Detect-Encoding([byte[]]$bytes, [string]$requested) {
    if ($requested -ne 'auto') {
        return @{ Enc = (Get-EncByName $requested); Offset = 0; Name = $requested.ToUpper() }
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return @{ Enc = [Text.Encoding]::UTF8;             Offset = 3; Name = 'UTF-8 (BOM)' }
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return @{ Enc = [Text.Encoding]::Unicode;          Offset = 2; Name = 'UTF-16 LE (BOM)' }
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return @{ Enc = [Text.Encoding]::BigEndianUnicode; Offset = 2; Name = 'UTF-16 BE (BOM)' }
    }
    $hasHigh = $false
    foreach ($b in $bytes) { if ($b -ge 0x80) { $hasHigh = $true; break } }
    if (!$hasHigh) { return @{ Enc = [Text.Encoding]::ASCII; Offset = 0; Name = 'ASCII' } }
    if (Test-StrictUtf8 $bytes) { return @{ Enc = [Text.Encoding]::UTF8; Offset = 0; Name = 'UTF-8' } }
    return @{ Enc = [Text.Encoding]::GetEncoding(1251); Offset = 0; Name = 'Windows-1251' }
}

function Read-TextSmart([string]$path, [string]$requested) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $det   = Detect-Encoding $bytes $requested
    $text  = $det.Enc.GetString($bytes, $det.Offset, $bytes.Length - $det.Offset)
    return @{ Text = $text; Name = $det.Name; Enc = $det.Enc }
}

# ---------- paths ----------
$InputFile = [IO.Path]::GetFullPath($InputFile)
if (!(Test-Path -LiteralPath $InputFile -PathType Leaf)) { throw "TXT file not found: $InputFile" }

if ([string]::IsNullOrWhiteSpace($OutputFile)) {
    $OutputFile = [IO.Path]::ChangeExtension($InputFile, ".fxt")
} else {
    $OutputFile = [IO.Path]::GetFullPath($OutputFile)
}
$logFile = [IO.Path]::ChangeExtension($OutputFile, ".duplicates.log")

# ---------- find FONTS.dtf ----------
$candidates = @(
    (Join-Path ([IO.Path]::GetDirectoryName($InputFile)) "FONTS.dtf"),
    (Join-Path $PSScriptRoot "FONTS.dtf")
)
if ($env:FXT_FONTS) { $candidates += $env:FXT_FONTS }
$candidates += (Join-Path (Get-Location).Path "FONTS.dtf")

$dtf = $null
foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { $dtf = $c; break }
}
if (!$dtf) { throw "FONTS.dtf not found." }

# ---------- parse FONTS.dtf ----------
$raw = [IO.File]::ReadAllBytes($dtf)
$sy  = [Text.Encoding]::ASCII.GetString($raw)
$pos = $sy.IndexOf("SYMB=")
if ($pos -lt 0) { throw "SYMB= not found in FONTS.dtf ($dtf)" }

$start = $pos + 5
$end   = $start
while ($end -lt $raw.Length -and $raw[$end] -ne 13 -and $raw[$end] -ne 10) { $end++ }

$map = @{}
for ($i = $start; $i -lt $end; $i++) { $map[[int]$raw[$i]] = 0x20 + ($i - $start) }

$homoglyphs = @{
    0xC0 = 0x41; 0xC5 = 0x45; 0xCA = 0x4B; 0xCC = 0x4D; 0xCD = 0x48
    0xCE = 0x4F; 0xD0 = 0x50; 0xD1 = 0x43; 0xD2 = 0x54; 0xD3 = 0x59
    0xD5 = 0x58
    0xE0 = 0x61; 0xE5 = 0x65; 0xEA = 0x6B; 0xEC = 0x6D; 0xED = 0x68
    0xEE = 0x6F; 0xF0 = 0x70; 0xF1 = 0x63; 0xF3 = 0x79; 0xF5 = 0x78
    0xA8 = 0x45
    0xB8 = 0x65
}

# ---------- diagnostics ----------
if ($Diagnose) {
    Write-Host ""
    Write-Host "=== FONTS.dtf mapping test ==="
    Write-Host "FONTS.dtf : $dtf"
    Write-Host "SYMB= len : $($end - $start)"
    Write-Host ""
    $probeCodes = @()
    $probeCodes += 0xC0..0xDF
    $probeCodes += 0xE0..0xFF
    $probeCodes += @(0xA8, 0xB8, 0xB9, 0xAB, 0xBB, 0x97, 0x96, 0x85, 0x7E, 0x24)
    $missing = New-Object System.Collections.Generic.List[string]
    $viaMap = 0; $viaHomo = 0; $viaPass = 0; $viaAsci = 0
    foreach ($code in $probeCodes) {
        $src = [int]$code
        if ($src -lt 0x80) { Write-Host ("0x{0:X2}      -> ASCII" -f $src) -ForegroundColor DarkGray; $viaAsci++ }
        elseif ($map.ContainsKey($src)) { Write-Host ("0x{0:X2}      -> SYMB=0x{1:X2}" -f $src, $map[$src]) -ForegroundColor Green; $viaMap++ }
        elseif ($homoglyphs.ContainsKey($src)) { Write-Host ("0x{0:X2}      -> HOMO=0x{1:X2}" -f $src, $homoglyphs[$src]) -ForegroundColor Yellow; $viaHomo++ }
        elseif ($src -ge 0x80 -and $src -le 0xFF) { Write-Host ("0x{0:X2}      -> PASS=0x{1:X2}" -f $src, $src) -ForegroundColor Cyan; $viaPass++ }
        else { Write-Host ("0x{0:X2}      -> NONE" -f $src) -ForegroundColor Red; $missing.Add(('0x{0:X2}' -f $src)) }
    }
    Write-Host ""
    Write-Host "Summary:"
    Write-Host ("  ASCII: {0}  SYMB=: {1}  HOMO: {2}  PASS: {3}  NONE: {4}" -f $viaAsci, $viaMap, $viaHomo, $viaPass, $missing.Count)
    Write-Host ""
}

# ---------- read input ----------
$read   = Read-TextSmart $InputFile $Encoding
$text   = $read.Text
$cp1251 = [Text.Encoding]::GetEncoding(1251)
$originalLines = @($text -split "\r\n|\n|\r")

# ---------- value normalizer ----------
function Normalize-Value([string]$raw, [bool]$keep) {
    if ($keep) { return @{ Value = $raw; Trimmed = 0 } }
    $trimmed = $raw.TrimEnd()
    return @{ Value = $trimmed; Trimmed = ($raw.Length - $trimmed.Length) }
}

# ---------- PARSE ----------
$records = New-Object System.Collections.Generic.List[object]
$lineNo  = 0

foreach ($line in $originalLines) {
    $lineNo++
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line.TrimStart().StartsWith("#"))   { continue }

    $m = [regex]::Match($line, '^\s*([^\s]+)\s+(.*)$')
    if (!$m.Success) {
        if ($Strict) { throw "Line ${lineNo}: expected KEY<space>TEXT" }
        Write-Warning "Line ${lineNo}: skipped"
        continue
    }

    $key  = $m.Groups[1].Value.ToUpperInvariant()
    $norm = Normalize-Value $m.Groups[2].Value ([bool]$KeepTrailingSpaces)
    $value = $norm.Value

    if ($key -notmatch '^[A-Z0-9_]+$') {
        if ($Strict) { throw "Line ${lineNo}: invalid key '$key'" }
        Write-Warning "Line ${lineNo}: skipped (invalid key)"
        continue
    }

    $records.Add([pscustomobject]@{
        LineNo  = $lineNo
        Key     = $key
        Value   = $value
        Trimmed = $norm.Trimmed
    }) | Out-Null
}

# ---------- Report trimming ----------
$trimmedRows = @($records | Where-Object { $_.Trimmed -gt 0 })
if ($trimmedRows.Count -gt 0) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " TRAILING SPACES NORMALIZED" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    foreach ($r in $trimmedRows) {
        Write-Host ("  line {0,4}  key {1,-10}  removed {2} space(s)" -f $r.LineNo, $r.Key, $r.Trimmed) -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host ("  Total lines cleaned: {0}" -f $trimmedRows.Count) -ForegroundColor Cyan
    Write-Host ""
}

# ---------- DUPLICATES ----------
$keyGroups  = $records | Group-Object Key
$duplicates = $keyGroups | Where-Object { $_.Count -gt 1 }

$modeLabel = 'report-only'
if ($FixDuplicates) {
    if ($PreferLast) { $modeLabel = 'FixDuplicates (keep LAST)' } else { $modeLabel = 'FixDuplicates (keep first)' }
}
if ($FixSourceTxt) { $modeLabel += ' + FixSourceTxt' }
if ($KeepTrailingSpaces) { $modeLabel += ' + KeepTrailingSpaces' }

$logLines = New-Object System.Collections.Generic.List[string]
$logLines.Add("FXT Converter - report")
$logLines.Add("Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$logLines.Add("Input TXT : $InputFile")
$logLines.Add("Output FXT: $OutputFile")
$logLines.Add("Mode      : $modeLabel")
$logLines.Add("")
$logLines.Add(("Total records parsed : {0}" -f $records.Count))
$logLines.Add(("Trailing spaces trimmed on {0} line(s)" -f $trimmedRows.Count))
$logLines.Add(("Duplicate keys found : {0}" -f @($duplicates).Count))
$logLines.Add("")

if ($trimmedRows.Count -gt 0) {
    $logLines.Add("========================================")
    $logLines.Add(" TRAILING SPACES NORMALIZED")
    $logLines.Add("========================================")
    foreach ($r in $trimmedRows) {
        $logLines.Add(("  line {0,4}  key {1,-10}  removed {2} space(s)" -f $r.LineNo, $r.Key, $r.Trimmed))
    }
    $logLines.Add("")
}

$totalRemoved = 0

if ($duplicates) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host " DUPLICATE KEYS FOUND" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow

    $logLines.Add("========================================")
    $logLines.Add(" DUPLICATE KEYS - DETAIL")
    $logLines.Add("========================================")
    $logLines.Add("")

    foreach ($g in ($duplicates | Sort-Object Name)) {
        $sorted = @($g.Group | Sort-Object LineNo)

        if ($FixDuplicates -and $PreferLast) {
            $keep = $sorted[$sorted.Count - 1]
            $drop = @($sorted | Select-Object -First ($sorted.Count - 1))
        } else {
            $keep = $sorted[0]
            $drop = @($sorted | Select-Object -Skip 1)
        }

        $countDropped = @($drop).Count
        $action = if ($FixDuplicates) {
            if ($PreferLast) { 'KEEP last, DROP rest' } else { 'KEEP first, DROP rest' }
        } else { 'KEEP all (report-only)' }

        Write-Host ""
        Write-Host ("  KEY: {0}   ({1} occurrences)   {2}" -f $g.Name, $g.Count, $action) -ForegroundColor Yellow
        Write-Host ("     KEEP  line {0,4}  value: {1}" -f $keep.LineNo, $keep.Value) -ForegroundColor Green

        foreach ($r in $drop) {
            $mark = if ($FixDuplicates) { 'DROP ' } else { 'ALSO ' }
            $col  = if ($FixDuplicates) { 'Red'   } else { 'DarkYellow' }
            Write-Host ("     {0} line {1,4}  value: {2}" -f $mark, $r.LineNo, $r.Value) -ForegroundColor $col
        }

        $logLines.Add(("KEY: {0}  ({1} occurrences)" -f $g.Name, $g.Count))
        $logLines.Add(("  KEEP line {0,4}  value: {1}" -f $keep.LineNo, $keep.Value))
        foreach ($r in $drop) {
            $logLines.Add(("  DROP line {0,4}  value: {1}" -f $r.LineNo, $r.Value))
        }
        $logLines.Add("")
        $totalRemoved += $countDropped
    }

    Write-Host ""
    Write-Host ("  Summary: {0} keys duplicated, {1} line(s) removed." -f @($duplicates).Count, $totalRemoved) -ForegroundColor Yellow
    Write-Host ""

    $logLines.Add("----------------------------------------")
    $logLines.Add(("Summary: {0} keys duplicated, {1} line(s) removed" -f @($duplicates).Count, $totalRemoved))
    $logLines.Add("")

    if ($FixDuplicates) {
        if ($PreferLast) {
            Write-Host "  -PreferLast: keeping LAST occurrence." -ForegroundColor Cyan
            $seen   = @{}
            $unique = New-Object System.Collections.Generic.List[object]
            for ($i = $records.Count - 1; $i -ge 0; $i--) {
                $r = $records[$i]
                if ($seen.ContainsKey($r.Key)) { continue }
                $seen[$r.Key] = $true
                $unique.Insert(0, $r) | Out-Null
            }
            $records = $unique
        } else {
            Write-Host "  -FixDuplicates: keeping FIRST occurrence." -ForegroundColor Cyan
            $seen   = @{}
            $unique = New-Object System.Collections.Generic.List[object]
            foreach ($r in $records) {
                if ($seen.ContainsKey($r.Key)) { continue }
                $seen[$r.Key] = $true
                $unique.Add($r) | Out-Null
            }
            $records = $unique
        }
        Write-Host ("  Records after dedup: {0}" -f $records.Count) -ForegroundColor Cyan
        Write-Host ""
        $logLines.Add(("Records after dedup: {0}" -f $records.Count))
        $logLines.Add("")
    } else {
        Write-Host "  All duplicates will be written to FXT." -ForegroundColor Yellow
        Write-Host ""
        $logLines.Add("Note: all duplicates kept (no -FixDuplicates).")
        $logLines.Add("")
    }
} else {
    Write-Host ""
    Write-Host "No duplicate keys found." -ForegroundColor Green
    Write-Host ""
    $logLines.Add("No duplicate keys found.")
    $logLines.Add("")
}

# ---------- save log ----------
$logText = ($logLines -join "`r`n") + "`r`n"
[IO.File]::WriteAllText($logFile, $logText, (New-Object System.Text.UTF8Encoding($true)))

# ---------- OPTIONAL: FixSourceTxt ----------
if ($FixSourceTxt -and $duplicates -and $FixDuplicates) {
    $backupPath = $InputFile + ".bak"
    Copy-Item -LiteralPath $InputFile -Destination $backupPath -Force
    Write-Host ("  Source backup : {0}" -f $backupPath) -ForegroundColor Cyan

    $keptSet = @{}
    foreach ($r in $records) { $keptSet[[int]$r.LineNo] = $true }

    $sb = New-Object System.Text.StringBuilder
    $ln = 0
    foreach ($line in $originalLines) {
        $ln++
        if ([string]::IsNullOrWhiteSpace($line)) { [void]$sb.Append("`r`n"); continue }
        if ($line.TrimStart().StartsWith("#"))   { [void]$sb.Append($line); [void]$sb.Append("`r`n"); continue }
        if ($keptSet.ContainsKey($ln))           { [void]$sb.Append($line); [void]$sb.Append("`r`n") }
    }

    [IO.File]::WriteAllText($InputFile, $sb.ToString(), $read.Enc)
    Write-Host ("  Source rewrit : {0}" -f $InputFile) -ForegroundColor Cyan
    Write-Host ""
}

# ---------- SECTION SUMMARY ----------
$prefixStats = @{}
foreach ($r in $records) {
    $p = [regex]::Match($r.Key, '^[A-Z]+').Value
    if ($p.Length -gt 4) { $p = $p.Substring(0, 4) }
    if (!$prefixStats.ContainsKey($p)) { $prefixStats[$p] = 0 }
    $prefixStats[$p]++
}

Write-Host "=== Key groups (prefix -> count) ==="
$prefixStats.GetEnumerator() | Sort-Object Name | ForEach-Object {
    Write-Host ("  {0,-8} : {1}" -f $_.Key, $_.Value)
}
Write-Host ""

# ---------- BUILD FXT ----------
# Format matched to FXT Editor (Rus):
#   - header line 2 ends with "--------------- " (trailing space before CRLF)
#   - header is followed by empty line (CRLF CRLF)
#   - EVERY record ends with CRLF, including the last one
$outBytes = New-Object System.Collections.Generic.List[byte]

$header = "# Created with FXT_Editor (Rus) by yelmi`r`n" +
          "# -------------- " + [char]0xA9 + " 2009 --------------- `r`n`r`n"
$outBytes.AddRange($cp1251.GetBytes($header))

$unknown = New-Object System.Collections.Generic.List[string]

foreach ($r in $records) {
    $outBytes.AddRange([Text.Encoding]::ASCII.GetBytes($r.Key))
    $outBytes.Add(0x20)

    foreach ($ch in $r.Value.ToCharArray()) {
        $s = [string]$ch
        $b = $cp1251.GetBytes($s)

        if ($b.Length -ne 1) {
            $unknown.Add(("{0}: char 0x{1:X4} (not CP1251)" -f $r.LineNo, [int][char]$ch))
            $outBytes.Add([byte][char]'?')
            continue
        }

        $src = [int]$b[0]

        if ($src -lt 0x80)                       { $outBytes.Add([byte]$src) }
        elseif ($map.ContainsKey($src))          { $outBytes.Add([byte]$map[$src]) }
        elseif ($homoglyphs.ContainsKey($src))   { $outBytes.Add([byte]$homoglyphs[$src]) }
        elseif ($src -ge 0x80 -and $src -le 0xFF){ $outBytes.Add([byte]$src) }
        else {
            if ($Strict) { throw ("Line {0}: char 0x{1:X2} has no mapping." -f $r.LineNo, $src) }
            $unknown.Add(("{0}: 0x{1:X2}" -f $r.LineNo, $src))
            $outBytes.Add([byte][char]'?')
        }
    }

    # CRLF after EVERY record, including the last one (matches FXT Editor)
    $outBytes.Add(0x0D)
    $outBytes.Add(0x0A)
}

[IO.File]::WriteAllBytes($OutputFile, $outBytes.ToArray())

# ---------- report ----------
Write-Host ""
Write-Host "========================================"
Write-Host " FXT conversion completed"
Write-Host "========================================"
Write-Host "Input    : $InputFile"
Write-Host "Encoding : $($read.Name)"
Write-Host "Output   : $OutputFile"
Write-Host "Fonts    : $dtf"
Write-Host "Records  : $($records.Count)"
Write-Host ("Trimmed  : {0} line(s) had trailing spaces removed" -f $trimmedRows.Count) -ForegroundColor Cyan
if ($duplicates) {
    Write-Host ("Dup. keys: {0}  (lines removed: {1})" -f @($duplicates).Count, $totalRemoved) -ForegroundColor Yellow
}
if ($FixSourceTxt -and $duplicates -and $FixDuplicates) {
    Write-Host ("Source   : rewritten (backup: {0}.bak)" -f [IO.Path]::GetFileName($InputFile)) -ForegroundColor Cyan
}
Write-Host ("Log      : {0}" -f $logFile)
Write-Host "Trim     : $(if ($KeepTrailingSpaces) { 'KEEP trailing spaces' } else { 'trim trailing spaces (FXT Editor compatible)' })"
Write-Host "Mapping  : FONTS.dtf SYMB= + homoglyphs + extended passthrough (byte-identical to FXT Editor)"

if ($unknown.Count -gt 0) {
    Write-Host ""
    Write-Host (" WARNING: {0} character(s) cannot be encoded:" -f $unknown.Count) -ForegroundColor Yellow
    $unknown | Select-Object -First 20 | ForEach-Object { Write-Host "   $_" -ForegroundColor Yellow }
}

Write-Host ""