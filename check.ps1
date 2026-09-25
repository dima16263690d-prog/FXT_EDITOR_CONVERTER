# check.ps1 — сравнение двух FXT
$base = "$env:USERPROFILE\OneDrive\Desktop\FXT_EDITOR"

$fileA = Join-Path $base "GANG_BANK_TEST.fxt"
$fileB = Join-Path $base "AFTER_EDITOR.fxt"

Write-Host "File A: $fileA"
Write-Host "File B: $fileB"
Write-Host ""

if (!(Test-Path $fileA)) { Write-Host "A NOT FOUND" -ForegroundColor Red; exit 1 }
if (!(Test-Path $fileB)) { Write-Host "B NOT FOUND" -ForegroundColor Red; exit 1 }

$a = [IO.File]::ReadAllBytes($fileA)
$b = [IO.File]::ReadAllBytes($fileB)

Write-Host "A size: $($a.Length) bytes"
Write-Host "B size: $($b.Length) bytes"
Write-Host ""

$n = 0
$max = [Math]::Max($a.Length, $b.Length)

for ($i = 0; $i -lt $max; $i++) {
    $x = if ($i -lt $a.Length) { $a[$i] } else { -1 }
    $y = if ($i -lt $b.Length) { $b[$i] } else { -1 }
    if ($x -ne $y) {
        $n++
        if ($n -le 40) {
            Write-Host ("0x{0:X8}  {1:X2} -> {2:X2}" -f $i, $x, $y)
        }
    }
}

Write-Host ""
Write-Host "Total diffs: $n"

if ($n -eq 0) {
    Write-Host "FILES ARE IDENTICAL" -ForegroundColor Green
} else {
    Write-Host "FILES DIFFER" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Press Enter to exit..."
Read-Host