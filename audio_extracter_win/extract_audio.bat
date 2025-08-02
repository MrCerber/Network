@echo off
color 0A
title FFmpeg Audio Extractor

:: Check if FFmpeg is installed
where ffmpeg >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] FFmpeg not found! Make sure FFmpeg is installed and added to PATH.
    echo Download: https://ffmpeg.org/download.html
    pause
    exit /b
)

:menu
cls
echo ========================================================
echo            FFmpeg Audio Extractor v1.0
echo ========================================================
echo.
echo  [1] Extract audio from single file
echo  [2] Extract audio from all MP4 files in folder
echo  [3] Exit
echo.
echo ========================================================

set /p choice="Choose option [1-3]: "

if "%choice%"=="1" goto single_file
if "%choice%"=="2" goto all_files
if "%choice%"=="3" exit
echo Invalid choice! Try again.
timeout /t 2 >nul
goto menu

:single_file
cls
echo ========================================================
echo              Single File Processing
echo ========================================================
echo.
echo Available MP4 files in current folder:
echo.
dir *.mp4 /b 2>nul
if %ERRORLEVEL% NEQ 0 (
    echo No MP4 files found in current folder!
    echo.
)
echo.
set /p filename="Enter MP4 filename (with extension): "

if not exist "%filename%" (
    echo File not found!
    pause
    goto menu
)

call :format_menu "%filename%"
goto menu

:all_files
cls
echo ========================================================
echo              Batch Processing
echo ========================================================
echo.
echo This will process ALL MP4 files in current folder.
echo.
dir *.mp4 /b 2>nul
if %ERRORLEVEL% NEQ 0 (
    echo No MP4 files found in current folder!
    pause
    goto menu
)
echo.
set /p confirm="Continue? (y/n): "

if /i not "%confirm%"=="y" goto menu

call :format_menu "ALL_FILES"
goto menu

:format_menu
cls
echo ========================================================
echo              Choose Audio Format
echo ========================================================
echo.
echo  [1] MP3 - Standard Quality (192kbps)
echo  [2] MP3 - High Quality (320kbps)
echo  [3] AAC - Original Quality (copy)
echo  [4] WAV - Uncompressed
echo  [5] Back to main menu
echo.
echo ========================================================

set /p format="Choose format [1-5]: "

if "%format%"=="5" exit /b

if "%~1"=="ALL_FILES" (
    goto process_all
) else (
    goto process_single
)

:process_single
set input_file=%~1
set filename_only=%~n1

echo.
echo Processing: %input_file%
echo.

if "%format%"=="1" (
    ffmpeg -i "%input_file%" -vn -acodec mp3 -ab 192k "%filename_only%.mp3" -y
) else if "%format%"=="2" (
    ffmpeg -i "%input_file%" -vn -acodec mp3 -ab 320k "%filename_only%.mp3" -y
) else if "%format%"=="3" (
    ffmpeg -i "%input_file%" -vn -acodec copy "%filename_only%.aac" -y
) else if "%format%"=="4" (
    ffmpeg -i "%input_file%" -vn -acodec pcm_s16le "%filename_only%.wav" -y
) else (
    echo Invalid choice!
    pause
    call :format_menu "%input_file%"
    exit /b
)

echo.
echo [SUCCESS] Audio extracted successfully!
pause
exit /b

:process_all
echo.
echo Processing all MP4 files...
echo.

if "%format%"=="1" (
    for %%a in (*.mp4) do (
        echo Processing: %%a
        ffmpeg -i "%%a" -vn -acodec mp3 -ab 192k "%%~na.mp3" -y
    )
) else if "%format%"=="2" (
    for %%a in (*.mp4) do (
        echo Processing: %%a
        ffmpeg -i "%%a" -vn -acodec mp3 -ab 320k "%%~na.mp3" -y
    )
) else if "%format%"=="3" (
    for %%a in (*.mp4) do (
        echo Processing: %%a
        ffmpeg -i "%%a" -vn -acodec copy "%%~na.aac" -y
    )
) else if "%format%"=="4" (
    for %%a in (*.mp4) do (
        echo Processing: %%a
        ffmpeg -i "%%a" -vn -acodec pcm_s16le "%%~na.wav" -y
    )
) else (
    echo Invalid choice!
    pause
    call :format_menu "ALL_FILES"
    exit /b
)

echo.
echo [SUCCESS] All files processed!
pause
exit /b
