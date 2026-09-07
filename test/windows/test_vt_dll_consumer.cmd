@echo off
setlocal
rem Run from an MSVC developer prompt. Argument: installed Ghostty VT prefix.
if "%~1"=="" (
    echo Usage: %~nx0 ^<Ghostty VT prefix^>
    exit /b 2
)
set "VT_PREFIX=%~f1"
set "VT_TEST_DIR=%TEMP%\ghostty-vt-dll-consumer-%RANDOM%-%RANDOM%"
mkdir "%VT_TEST_DIR%"
if errorlevel 1 exit /b 1
pushd "%VT_TEST_DIR%"
cl /nologo /W4 /WX /LD /MD /I"%VT_PREFIX%\include" "%~dp0test_vt_dll_consumer.c" /link /LIBPATH:"%VT_PREFIX%\lib" ghostty-vt.lib
if errorlevel 1 goto fail
cl /nologo /W4 /WX "%~dp0test_vt_dll_host.c"
if errorlevel 1 goto fail
set "PATH=%VT_PREFIX%\bin;%VT_PREFIX%\lib;%PATH%"
test_vt_dll_host.exe
if errorlevel 1 goto fail
popd
rmdir /s /q "%VT_TEST_DIR%"
echo DLL consumer passed.
exit /b 0
:fail
popd
echo DLL consumer failed. Build artifacts: %VT_TEST_DIR%
exit /b 1
