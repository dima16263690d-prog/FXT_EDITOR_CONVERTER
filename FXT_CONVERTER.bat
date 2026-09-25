@echo off
setlocal EnableExtensions

set "SCRIPT=%~dp0fxt_convert_dtf.ps1"

if not exist "%SCRIPT%" (
    echo.
    echo ERROR: fxt_convert_dtf.ps1 not found next to this BAT.
    echo Expected: "%SCRIPT%"
    echo.
    pause
    exit /b 1
)

if "%~1"=="" (
    echo.
    echo FXT CONVERTER
    echo.
    echo Drag one or more TXT files onto this BAT.
    echo Or run from command line:
    echo   FXT_CONVERTER.bat input1.txt [input2.txt ...]
    echo.
    echo Optional env var FXT_FONTS can point to a FONTS.dtf file.
    echo.
    pause
    exit /b 1
)

set "OK=0"
set "FAIL=0"

:fxtediton
if "%~1"=="" goto done

echo.
echo === Converting: %~nx1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" "%~1" -FixDuplicates -PreferLast -FixSourceTxt
if errorlevel 1 (
    set /a FAIL+=1
) else (
    set /a OK+=1
)
shift
goto fxtediton


:done
echo.
echo ========================================
echo  Done.  OK: %OK%   Failed: %FAIL%
echo ========================================
echo.
pause