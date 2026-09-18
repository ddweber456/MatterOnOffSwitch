@echo off
:: ============================================================
:: TEMPLATE brand wrapper.  [Rev 1.10]
:: Copy this file, rename it (e.g. flash_device_AcmeGarage.bat), and
:: fill in the three variables below for the new customer/brand. Then
:: run the copy - it calls the same shared, already-tested
:: flash_device_core.bat engine that flash_device.bat (the "Open
:: Sesame" wrapper) uses. See Product Requirement.txt Section 4.1.
::
:: You do NOT need a separate compiled firmware .bin per brand unless
:: that brand needs firmware-level differences beyond the device name
:: (not the case today - see Section 3.1's Device Identity Resolution).
::
:: Rev 1.10 (2026-09-18): BRAND_LOGO now points into the Logo_files\
:: subfolder instead of the repo root, so brand logo images stay out
:: of the repo entirely (Logo_files\ is in .gitignore). When onboarding
:: a new brand, drop that brand's logo image into Logo_files\ and
:: reference it the same way below.
::
:: Rev 1.9 (2026-09-17): MAIN_FIRMWARE's default below now matches
:: Arduino IDE's actual compiled-output filename, MatterOnOffSwitch.ino.bin
:: (see flash_device_Open_Sesame.bat's own Rev 1.9 note for why). Leave
:: this as-is unless this new brand genuinely needs a separately compiled
:: .bin - change it here if so.
:: ============================================================
SET BRAND_NAME=CHANGE_ME
SET MAIN_FIRMWARE=MatterOnOffSwitch.ino.bin
SET BRAND_LOGO=Logo_files\CHANGE_ME_logo.png

call "%~dp0flash_device_core.bat"
