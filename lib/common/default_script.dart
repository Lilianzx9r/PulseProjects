/// Contenu par défaut proposé dans l'éditeur de script d'un profil, tant
/// qu'aucun script personnalisé n'a été enregistré pour ce profil.
///
/// Reprend le script `DevTool.bat` fourni par l'utilisateur (pipeline de
/// build/export Flutter) comme point de départ éditable — l'utilisateur
/// peut le conserver tel quel, l'adapter, ou le remplacer entièrement.
const String kDefaultProjectScript = r'''@echo off
setlocal EnableDelayedExpansion

REM =====================================================
REM DevTool Flutter - Release Tool FINAL
REM =====================================================

set ROOT=%~dp0

if "%~1"=="" goto USAGE

set PROJECT=%~1
set SRC=%ROOT%%PROJECT%

if not exist "%SRC%\pubspec.yaml" (
    echo ERREUR : Projet introuvable
    echo %SRC%
    exit /b 1
)

cd /d "%SRC%"

REM =====================================================
REM CHOIX BUILD
REM =====================================================

echo.
echo =========================
echo Choix du build
echo =========================
echo 1 - windows
echo 2 - apk
echo 3 - all
echo =========================

choice /c 123 /n /m "Choix : "

set TARGET=

if %errorlevel%==1 set TARGET=windows
if %errorlevel%==2 set TARGET=apk
if %errorlevel%==3 set TARGET=all

REM =====================================================
REM ROUTING BUILD
REM =====================================================

if "%TARGET%"=="windows" goto BUILD_WINDOWS
if "%TARGET%"=="apk" goto BUILD_APK
if "%TARGET%"=="all" goto BUILD_ALL

echo ERREUR TARGET
goto END

REM =====================================================
REM BUILD WINDOWS
REM =====================================================

:BUILD_WINDOWS
echo.
echo ===== BUILD WINDOWS =====
call flutter build windows --release
if errorlevel 1 goto FAIL
goto EXPORT

REM =====================================================
REM BUILD APK
REM =====================================================

:BUILD_APK
echo.
echo ===== BUILD APK =====
call flutter build apk --release
if errorlevel 1 goto FAIL
goto EXPORT

REM =====================================================
REM BUILD ALL
REM =====================================================

:BUILD_ALL
echo.
echo ===== BUILD WINDOWS =====
call flutter build windows --release
if errorlevel 1 goto FAIL

echo.
echo ===== BUILD APK =====
call flutter build apk --release
if errorlevel 1 goto FAIL

goto EXPORT

REM =====================================================
REM EXPORT RELEASE + HISTORY
REM =====================================================

:EXPORT

set RELEASE=%ROOT%Releases
set OLD=%ROOT%ReleasesOld

if not exist "%RELEASE%" mkdir "%RELEASE%"
if not exist "%OLD%" mkdir "%OLD%"

REM =====================================================
REM MOVE OLD ZIP FILES
REM =====================================================

move /Y "%RELEASE%\%PROJECT%_*.zip" "%OLD%\" >nul 2>nul
move /Y "%RELEASE%\%PROJECT%_*.apk" "%OLD%\" >nul 2>nul

REM =====================================================
REM DATE
REM =====================================================

for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set DATETIME=%%i

set TMP=%TEMP%\%PROJECT%_release
set ZIP=%RELEASE%\%PROJECT%_%DATETIME%.zip

rmdir /s /q "%TMP%" 2>nul

mkdir "%TMP%\%PROJECT%\windows"
mkdir "%TMP%\%PROJECT%\android"
mkdir "%TMP%\%PROJECT%\%PROJECT%"

REM =====================================================
REM WINDOWS BUILD COPY
REM =====================================================

if exist "%SRC%\build\windows\x64\runner\Release" (
    xcopy "%SRC%\build\windows\x64\runner\Release" ^
    "%TMP%\%PROJECT%\windows" /E /I /Y >nul
)

REM =====================================================
REM APK COPY
REM =====================================================

if exist "%SRC%\build\app\outputs\flutter-apk\app-release.apk" (
    copy "%SRC%\build\app\outputs\flutter-apk\app-release.apk" ^
    "%TMP%\%PROJECT%\android\app-release.apk" >nul
	
    copy "%SRC%\build\app\outputs\flutter-apk\app-release.apk" ^
    "%RELEASE%\%PROJECT%_%DATETIME%.apk" >nul

)

REM =====================================================
REM SOURCES CLEAN COPY
REM =====================================================

robocopy "%SRC%" "%TMP%\%PROJECT%\%PROJECT%" ^
 /E ^
 /XD build .dart_tool .idea .vscode ephemeral .gradle ^
 >nul

REM =====================================================
REM INFO FILE
REM =====================================================

echo Project: %PROJECT% > "%TMP%\%PROJECT%\info.txt"
echo Date: %DATETIME% >> "%TMP%\%PROJECT%\info.txt"

REM =====================================================
REM ZIP CREATION
REM =====================================================

powershell -NoProfile -Command ^
"Compress-Archive -Path '%TMP%\%PROJECT%\*' -DestinationPath '%ZIP%' -Force"

rmdir /s /q "%TMP%"

echo.
echo =========================
echo RELEASE OK
echo =========================
echo %ZIP%

goto END

REM =====================================================
REM FAIL
REM =====================================================

:FAIL
echo.
echo =========================
echo BUILD FAILED
echo =========================
exit /b 1

REM =====================================================
REM USAGE
REM =====================================================

:USAGE
echo.
echo Usage:
echo DevTool ProjectName
echo (ex: DevTool PulseIt)
exit /b 1

REM =====================================================
REM END
REM =====================================================

:END
echo.
echo =========================
echo TERMINE
echo =========================
pause
exit /b 0
''';
