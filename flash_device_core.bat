@echo off
SETLOCAL EnableDelayedExpansion

:: ============================================================
:: SHARED FLASHING ENGINE  [Rev 1.8]
:: Do not run this file directly - it expects BRAND_NAME and
:: MAIN_FIRMWARE (and optionally BRAND_LOGO) to already be SET by a
:: brand-specific wrapper .bat (see flash_device.bat for the "Open
:: Sesame" example, or flash_device_TEMPLATE.bat to start a new one).
:: This split lets one shared, tested script serve every customer
:: brand without duplicating the flashing logic per brand - see
:: Product Requirement.txt Section 4.1.
:: ============================================================
IF "%BRAND_NAME%"=="" (
    echo.
    echo ❌❌❌ MISSING CONFIGURATION ❌❌❌
    echo -------------------------------------------------------
    echo ERROR: BRAND_NAME is not set. flash_device_core.bat is the
    echo shared flashing engine - run it via a brand wrapper such as
    echo flash_device.bat instead of calling this file directly.
    echo -------------------------------------------------------
    pause
    exit /b 1
)
IF "%MAIN_FIRMWARE%"=="" (
    echo.
    echo ❌❌❌ MISSING CONFIGURATION ❌❌❌
    echo -------------------------------------------------------
    echo ERROR: MAIN_FIRMWARE is not set. See flash_device.bat for an
    echo example of setting it before calling flash_device_core.bat.
    echo -------------------------------------------------------
    pause
    exit /b 1
)
IF NOT DEFINED BRAND_LOGO SET BRAND_LOGO=logo.png

echo -------------------------------------------------------
echo Brand:    %BRAND_NAME%
echo Firmware: %MAIN_FIRMWARE%
echo Logo:     %BRAND_LOGO%
echo -------------------------------------------------------

SET BAUD_RATE=921600
SET ESPTOOL_PATH="C:\Users\David\AppData\Local\Arduino15\packages\esp32\tools\esptool_py\5.3.1\esptool.exe"
SET SCAN_LOG_DIR=%TEMP%\esp32c5_port_scan

if not exist "%SCAN_LOG_DIR%" mkdir "%SCAN_LOG_DIR%" >nul 2>nul
del /Q "%SCAN_LOG_DIR%\*.log" >nul 2>nul

:: ============================================================
:: COM PORT AUTO-DETECTION
:: Enumerates every COM port on this machine and probes each one
:: with esptool (--chip auto) to find which one actually has an
:: ESP32-C5 attached, instead of relying on a hardcoded COM_PORT.
:: This also captures the flash size for the winning port from the
:: same probe, reusing the auto-detection logic added previously -
:: see Product Requirement.txt Section 4.3/6.
::
:: If more than one port responds as an ESP32-C5, this refuses to
:: guess which one to flash and stops - see the error block below.
:: ============================================================
echo -------------------------------------------------------
echo 🔍 Scanning COM ports for a connected ESP32-C5...
echo -------------------------------------------------------

set FOUND_COUNT=0
set FOUND_PORTS=
set LAST_FOUND_PORT=
set LAST_FOUND_LOG=

for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "[System.IO.Ports.SerialPort]::GetPortNames()"`) do (
    echo   Probing %%P ...
    %ESPTOOL_PATH% --port %%P --chip auto flash-id > "%SCAN_LOG_DIR%\%%P.log" 2>nul
    findstr /I "ESP32-C5" "%SCAN_LOG_DIR%\%%P.log" >nul 2>nul
    if !errorlevel! EQU 0 (
        echo     -^> ESP32-C5 found on %%P
        set /A FOUND_COUNT+=1
        set FOUND_PORTS=!FOUND_PORTS! %%P
        set LAST_FOUND_PORT=%%P
        set LAST_FOUND_LOG=%SCAN_LOG_DIR%\%%P.log
    )
)

if %FOUND_COUNT% EQU 0 (
    echo.
    echo ❌❌❌ NO ESP32-C5 FOUND ❌❌❌
    echo -------------------------------------------------------
    echo Scanned every available COM port and found no responding
    echo ESP32-C5.
    echo.
    echo DIAGNOSTIC CHECKLIST FOR TESTING AGENT:
    echo 1. Verify the board is firmly secured inside the jig.
    echo 2. Ensure the USB-Serial cable is connected and drivers installed.
    echo 3. Try a different USB cable/port if the board still isn't detected.
    echo -------------------------------------------------------
    pause
    exit /b 1
)

if %FOUND_COUNT% GTR 1 (
    echo.
    echo ❌❌❌ MULTIPLE ESP32-C5 MODULES DETECTED ❌❌❌
    echo -------------------------------------------------------
    echo Found a responding ESP32-C5 on more than one COM port:!FOUND_PORTS!
    echo.
    echo This script flashes exactly one unit at a time and will not
    echo guess which one you mean to flash right now.
    echo.
    echo Disconnect all but the single unit you want to flash, then
    echo re-run this script.
    echo -------------------------------------------------------
    pause
    exit /b 1
)

SET COM_PORT=%LAST_FOUND_PORT%
echo -------------------------------------------------------
echo Selected COM_PORT: %COM_PORT%
echo -------------------------------------------------------

:: ============================================================
:: FLASH SIZE from the same probe (avoids a second esptool connection
:: to the port we just identified). Selects the matching factory-data
:: offset automatically - see Product Requirement.txt Section 4.3.
:: NOTE: this only confirms the PHYSICAL flash size. It cannot verify
:: which Partition Scheme MAIN_FIRMWARE was actually compiled with -
:: that's still on the operator to get right in Arduino IDE
:: (RainMaker (8MB) for 8MB modules; Custom/partitions.csv for 16MB
:: modules - see Section 3.1).
:: ============================================================
set FLASH_SIZE_RAW=UNKNOWN
for /f "tokens=2 delims=:" %%A in ('findstr /I "Detected flash size" "%LAST_FOUND_LOG%"') do (
    set FLASH_SIZE_RAW=%%A
)
set FLASH_SIZE_RAW=%FLASH_SIZE_RAW: =%

IF /I "%FLASH_SIZE_RAW%"=="8MB" (
    SET FACTORY_OFFSET=0x7EA000
) ELSE IF /I "%FLASH_SIZE_RAW%"=="16MB" (
    SET FACTORY_OFFSET=0xA10000
) ELSE (
    echo.
    echo ❌❌❌ FLASH SIZE DETECTION FAILURE ❌❌❌
    echo -------------------------------------------------------
    echo ERROR: esptool reported flash size "%FLASH_SIZE_RAW%" on %COM_PORT%.
    echo This script only has a verified factory-data offset for 8MB and
    echo 16MB modules ^(see Product Requirement.txt Section 4.3^). Refusing
    echo to guess an offset for anything else.
    echo -------------------------------------------------------
    pause
    exit /b 1
)

echo Detected flash size: %FLASH_SIZE_RAW% on %COM_PORT%
echo Factory data will be written to offset %FACTORY_OFFSET%
echo.
echo REMINDER: confirm MAIN_FIRMWARE was compiled with the matching
echo Partition Scheme for this flash size before proceeding ^(see above^).
echo -------------------------------------------------------

echo -------------------------------------------------------
echo 🔍 Interrogating Silicon Hardware eFuses via Serial Port...
echo -------------------------------------------------------

set MAC_ADDR=UNKNOWN
for /f "tokens=2 delims=: " %%A in ('%ESPTOOL_PATH% --chip esp32c5 --port %COM_PORT% read_mac 2^>nul ^| findstr /I "MAC:"') do (
    set MAC_ADDR=%%A
)

:: CRITICAL HARDWARE FAULT DETECTOR INTERCEPT
if "%MAC_ADDR%"=="UNKNOWN" (
    echo.
    echo ❌❌❌ HARDWARE INITIALIZATION FAILURE ❌❌❌
    echo -------------------------------------------------------
    echo ERROR: Could not communicate with the ESP32-C5 chip on %COM_PORT%.
    echo.
    echo DIAGNOSTIC CHECKLIST FOR TESTING AGENT:
    echo 1. Verify the board is firmly secured inside the jig.
    echo 2. Ensure the USB-Serial cable is still connected to %COM_PORT%.
    echo 3. Inspect module pins for bridging, debris, or warping.
    echo -------------------------------------------------------
    pause
    exit /b 1
)

echo Hardware MAC Found: %MAC_ADDR%

:: Derive the setup discriminator from the MAC address using the EXACT same formula
:: as MatterOnOffSwitch.ino: last two octets, masked to 12 bits. This is a deterministic
:: mirror of what the firmware will independently compute for itself on first boot -
:: it is NOT random. Keeping this in lockstep with the firmware is what makes the
:: printed label / QR code / onboarding link actually match the device's real identity.
for /f "tokens=5,6 delims=:" %%X in ("%MAC_ADDR%") do (
    SET OCTET5=%%X
    SET OCTET6=%%Y
)
SET /A DISCRIMINATOR=((0x%OCTET5% << 8) ^| 0x%OCTET6%) ^& 0x0FFF

:: The passcode has no MAC-derivable equivalent - it still needs real randomness,
:: so it stays randomly generated per unit.
SET /A PASSCODE=%RANDOM% * %RANDOM% %% 89999999 + 10000000

echo Derived Discriminator: %DISCRIMINATOR% (from MAC, matches firmware)
echo Generated Passcode: %PASSCODE%

:: Convert credentials to target binaries and log into the Quality Master CSV spreadsheet.
:: --brand is what makes this brand-aware (Rev 1.8) - see Product Requirement.txt Section 4.1/4.3.
python mfg_tool.py --discriminator %DISCRIMINATOR% --passcode %PASSCODE% --mac %MAC_ADDR% --brand "%BRAND_NAME%" --out factory_data.bin

:: Wipe chip profile history to avoid pairing credential key collision artifacts
%ESPTOOL_PATH% --chip esp32c5 --port %COM_PORT% erase_flash

:: Stream main system binary assets and unique manufacturing data payloads to target blocks.
:: FACTORY_OFFSET was set above from the auto-detected flash size - see
:: Product Requirement.txt Section 4.3 for the full partition tables
:: (8MB: RainMaker(8MB) scheme, fctry at 0x7EA000; 16MB: Custom scheme via
:: partitions.csv, fctry at 0xA10000).
%ESPTOOL_PATH% --chip esp32c5 --port %COM_PORT% --baud %BAUD_RATE% write_flash -z 0x0 %MAIN_FIRMWARE% %FACTORY_OFFSET% factory_data.bin

echo -------------------------------------------------------
echo 🖨️ GENERATING PRODUCTION THERMAL LABEL PRINT JOB...
echo -------------------------------------------------------

:: Invoke the automated print layout engine - --brand/--logo make the label brand-aware (Rev 1.8)
python print_label.py --discriminator %DISCRIMINATOR% --passcode %PASSCODE% --mac %MAC_ADDR% --brand "%BRAND_NAME%" --logo "%BRAND_LOGO%"

echo -------------------------------------------------------
echo 👉 BROWSER GENERATION LINK FOR THE BOX PAIRING QR CODE:
echo https://ddweber456.github.io/MatterOnOffSwitch/?disc=%DISCRIMINATOR%&pin=%PASSCODE%
echo -------------------------------------------------------

pause
