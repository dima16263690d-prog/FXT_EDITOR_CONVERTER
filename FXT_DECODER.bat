@echo off
setlocal EnableExtensions

set "SCRIPT=%~dp0fxt_decode.ps1"

if not exist "%SCRIPT%" (
    echo.
    echo ERROR: fxt_decode.ps1 not found next to this BAT.
    echo Expected: "%SCRIPT%"
    echo.
    pause
    exit /b 1
)

if "%~1"=="" (
    echo.
    echo FXT DECODER  ^(FXT -^> TXT^)
    echo.
    echo Drag one or more FXT files onto this BAT.
    echo Or run from command line:
    echo   FXT_DECODER.bat input.fxt [output.txt]
    echo.
    pause
    exit /b 1
)

set "OK=0"
set "FAIL=0"

:fxtediton
if "%~1"=="" goto done

echo.
echo === Decoding: %~nx1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" "%~1"
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