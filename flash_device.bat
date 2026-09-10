@echo off
SETLOCAL EnableDelayedExpansion
SET COM_PORT=COM4
SET BAUD_RATE=921600
SET MAIN_FIRMWARE=OpenSesame_C5_Production.bin
SET ESPTOOL_PATH="C:\Users\Admin\AppData\Local\Arduino15\packages\esp32\tools\esptool_py\4.6\esptool.exe"

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
    echo  ERROR: Could not communicate with the ESP32-C5 chip.
    echo.
    echo  DIAGNOSTIC CHECKLIST FOR TESTING AGENT:
    echo  1. Verify the board is firmly secured inside the jig.
    echo  2. Ensure the USB-Serial cable is connected to %COM_PORT%.
    echo  3. Inspect module pins for bridging, debris, or warping.
    echo -------------------------------------------------------
    :: Run standard terminal sound alert code
    echo 
    pause
    exit /b 1
)

echo Hardware MAC Found: %MAC_ADDR%

:: Generate random 8-digit passcode & 12-bit discriminator code strings
SET /A PASSCODE=%RANDOM% * %RANDOM% %% 89999999 + 10000000
SET /A DISCRIMINATOR=%RANDOM% %% 3095 + 1000

:: Convert credentials to target binaries and log into the Quality Master CSV spreadsheet
python mfg_tool.py --discriminator %DISCRIMINATOR% --passcode %PASSCODE% --mac %MAC_ADDR% --out factory_data.bin

:: Wipe chip profile history to avoid pairing credential key collision artifacts
%ESPTOOL_PATH% --chip esp32c5 --port %COM_PORT% erase_flash

:: Stream main system binary assets and unique manufacturing data payloads to target blocks
%ESPTOOL_PATH% --chip esp32c5 --port %COM_PORT% --baud %BAUD_RATE% write_flash -z 0x0 %MAIN_FIRMWARE% 0x340000 factory_data.bin

echo -------------------------------------------------------
echo 🖨️  GENERATING PRODUCTION THERMAL LABEL PRINT JOB...
echo -------------------------------------------------------
:: Invoke the automated print layout engine
python print_label.py --discriminator %DISCRIMINATOR% --passcode %PASSCODE% --mac %MAC_ADDR%

echo -------------------------------------------------------
echo 👉 BROWSER GENERATION LINK FOR THE BOX PAIRING QR CODE:
echo https://%ddweber456%.github.io/MatterOnOffSwitch/?disc=%DISCRIMINATOR%&pin=%PASSCODE%
echo -------------------------------------------------------
pause
