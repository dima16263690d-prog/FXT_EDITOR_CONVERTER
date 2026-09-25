param(
    [Parameter(Mandatory=$true)][string]$InputFile,
    [string]$OutputFile,
    [ValidateSet('utf-8-bom','utf-8','cp1251','auto')]
    [string]$OutEncoding = 'utf-8-bom'
)

$ErrorActionPreference = "Stop"

# ---------- paths ----------
$InputFile = [IO.Path]::GetFullPath($InputFile)
if (!(Test-Path -LiteralPath $InputFile -PathType Leaf)) {
    throw "FXT file not found: $InputFile"
}

if ([string]::IsNullOrWhiteSpace($OutputFile)) {
    $dir  = [IO.Path]::GetDirectoryName($InputFile)
    $name = [IO.Path]::GetFileNameWithoutExtension($InputFile)
    $OutputFile = [IO.Path]::Combine($dir, ($name + ".decoded.txt"))
} else {
    $OutputFile = [IO.Path]::GetFullPath($OutputFile)
}

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
if (!$dtf) {
    throw "FONTS.dtf not found. Put FONTS.dtf next to the FXT or next to fxt_decode.ps1."
}

# ---------- parse FONTS.dtf ----------
$raw = [IO.File]::ReadAllBytes($dtf)
$sy  = [Text.Encoding]::ASCII.GetString($raw)
$pos = $sy.IndexOf("SYMB=")
if ($pos -lt 0) { throw "SYMB= not found in FONTS.dtf ($dtf)" }

$start = $pos + 5
$end   = $start
while ($end -lt $raw.Length -and $raw[$end] -ne 13 -and $raw[$end] -ne 10) { $end++ }

# GTA byte -> CP1251 source byte
$revMap = @{}
for ($i = $start; $i -lt $end; $i++) {
    $gtaByte          = 0x20 + ($i - $start)
    $revMap[$gtaByte] = [int]$raw[$i]
}

$cp1251 = [Text.Encoding]::GetEncoding(1251)

# ---------- read FXT as bytes ----------
$inBytes = [IO.File]::ReadAllBytes($InputFile)

# Split into lines on CR / LF, empty lines dropped
$lines = New-Object System.Collections.Generic.List[byte[]]
$cur   = New-Object System.Collections.Generic.List[byte]
foreach ($b in $inBytes) {
    if ($b -eq 13 -or $b -eq 10) {
        if ($cur.Count -gt 0) {
            $lines.Add($cur.ToArray())
            $cur.Clear()
        }
    } else {
        $cur.Add($b)
    }
}
if ($cur.Count -gt 0) { $lines.Add($cur.ToArray()) }

# ---------- decode ----------
$sb      = New-Object Text.StringBuilder
$lineNo  = 0
$unknown = New-Object System.Collections.Generic.List[string]

foreach ($lb in $lines) {
    $lineNo++
    if ($lb.Length -eq 0) { continue }

    # Skip comment / header lines that start with '#'
    if ($lb[0] -eq 0x23) { continue }

    # Split KEY<TAB or space>TEXT - first space wins
    $sp = -1
    for ($i = 0; $i -lt $lb.Length; $i++) {
        if ($lb[$i] -eq 0x20 -or $lb[$i] -eq 0x09) { $sp = $i; break }
    }
    if ($sp -lt 1) {
        Write-Warning "Line ${lineNo}: no KEY/TEXT separator, skipped"
        continue
    }

    $key = [Text.Encoding]::ASCII.GetString($lb, 0, $sp)

    $outB = New-Object System.Collections.Generic.List[byte]
    for ($i = $sp + 1; $i -lt $lb.Length; $i++) {
        $g = [int]$lb[$i]
        if ($g -lt 0x80) {
            # ASCII - passthrough
            $outB.Add([byte]$g)
        }
        elseif ($revMap.ContainsKey($g)) {
            # Mapped back via FONTS.dtf SYMB=
            $outB.Add([byte]$revMap[$g])
        }
        elseif ($g -ge 0x80 -and $g -le 0xFF) {
            # Extended byte without mapping - passthrough
            $outB.Add([byte]$g)
        }
        else {
            $unknown.Add(("{0}: 0x{1:X2}" -f $lineNo, $g))
            $outB.Add([byte][char]'?')
        }
    }

    $value = $cp1251.GetString($outB.ToArray())

    [void]$sb.Append($key)
    [void]$sb.Append(' ')
    [void]$sb.Append($value)
    [void]$sb.Append("`r`n")
}

# ---------- choose output encoding ----------
$outEnc     = $null
$outEncName = ''
switch ($OutEncoding) {
    'utf-8-bom' { $outEnc = New-Object System.Text.UTF8Encoding($true);  $outEncName = 'UTF-8 with BOM' }
    'utf-8'     { $outEnc = New-Object System.Text.UTF8Encoding($false); $outEncName = 'UTF-8' }
    'cp1251'    { $outEnc = [Text.Encoding]::GetEncoding(1251);          $outEncName = 'Windows-1251' }
    'auto'      { $outEnc = New-Object System.Text.UTF8Encoding($true);  $outEncName = 'UTF-8 with BOM (auto)' }
    default     { $outEnc = New-Object System.Text.UTF8Encoding($true);  $outEncName = 'UTF-8 with BOM' }
}

[IO.File]::WriteAllText($OutputFile, $sb.ToString(), $outEnc)

# ---------- report ----------
Write-Host ""
Write-Host "========================================"
Write-Host " FXT decoded back to TXT"
Write-Host "========================================"
Write-Host "Input    : $InputFile"
Write-Host "Output   : $OutputFile"
Write-Host "OutEnc   : $outEncName"
Write-Host "Fonts    : $dtf"
Write-Host "Mapping  : FONTS.dtf SYMB= (reverse) + extended passthrough"

if ($unknown.Count -gt 0) {
    Write-Host ""
    Write-Host (" WARNING: {0} byte(s) had no reverse mapping:" -f $unknown.Count) -ForegroundColor Yellow
    $unknown | Select-Object -First 20 | ForEach-Object { Write-Host "   $_" -ForegroundColor Yellow }
    if ($unknown.Count -gt 20) { Write-Host "   ..." -ForegroundColor Yellow }
}

Write-Host ""