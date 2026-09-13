@echo off
SETLOCAL EnableDelayedExpansion

SET COM_PORT=COM4
SET BAUD_RATE=921600
SET MAIN_FIRMWARE=OpenSesame_C5_Production.bin
SET ESPTOOL_PATH="C:\Users\David\AppData\Local\Arduino15\packages\esp32\tools\esptool_py\5.3.1\esptool.exe"

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
    echo ERROR: Could not communicate with the ESP32-C5 chip.
    echo.
    echo DIAGNOSTIC CHECKLIST FOR TESTING AGENT:
    echo 1. Verify the board is firmly secured inside the jig.
    echo 2. Ensure the USB-Serial cable is connected to %COM_PORT%.
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

:: Convert credentials to target binaries and log into the Quality Master CSV spreadsheet
python mfg_tool.py --discriminator %DISCRIMINATOR% --passcode %PASSCODE% --mac %MAC_ADDR% --out factory_data.bin

:: Wipe chip profile history to avoid pairing credential key collision artifacts
%ESPTOOL_PATH% --chip esp32c5 --port %COM_PORT% erase_flash

:: Stream main system binary assets and unique manufacturing data payloads to target blocks
:: NOTE: verify 0xB00000 against your actual partition table before relying on this offset -
:: see the "Known Open Item" note in Product Requirement.txt.
%ESPTOOL_PATH% --chip esp32c5 --port %COM_PORT% --baud %BAUD_RATE% write_flash -z 0x0 %MAIN_FIRMWARE% 0xB00000 factory_data.bin

echo -------------------------------------------------------
echo 🖨️ GENERATING PRODUCTION THERMAL LABEL PRINT JOB...
echo -------------------------------------------------------

:: Invoke the automated print layout engine
python print_label.py --discriminator %DISCRIMINATOR% --passcode %PASSCODE% --mac %MAC_ADDR%

echo -------------------------------------------------------
echo 👉 BROWSER GENERATION LINK FOR THE BOX PAIRING QR CODE:
echo https://ddweber456.github.io/MatterOnOffSwitch/?disc=%DISCRIMINATOR%&pin=%PASSCODE%
echo -------------------------------------------------------

pause
