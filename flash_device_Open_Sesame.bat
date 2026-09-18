@echo off
:: ============================================================
:: "Open Sesame" brand wrapper.  [Rev 1.10]
:: Running this file does exactly what flash_device.bat always did -
:: it just now calls into the shared flash_device_core.bat engine
:: instead of containing the flashing logic itself. See Product
:: Requirement.txt Section 4.1 for why this split exists (one
:: compiled firmware image, multiple customer brands).
::
:: To onboard a NEW customer brand: copy flash_device_TEMPLATE.bat,
:: fill in its three variables, and save it under a new name (e.g.
:: flash_device_AcmeGarage.bat). No firmware rebuild required.
::
:: Rev 1.10 (2026-09-18): BRAND_LOGO now points into the Logo_files\
:: subfolder instead of the repo root, so brand logo images stay out
:: of the repo entirely (Logo_files\ is in .gitignore). Only the
:: manufacturing scripts reference the logo by this relative path -
:: nothing else needed to change.
::
:: Rev 1.9 (2026-09-17): MAIN_FIRMWARE now defaults to
:: MatterOnOffSwitch.ino.bin - matching what Arduino IDE actually names
:: the compiled binary (see the build/<fqbn>/ folder produced by any
:: compile), instead of a manually-renamed OpenSesame_C5_Production.bin.
:: A fresh compile's output can now be used directly, no rename step.
:: MAIN_FIRMWARE is still a plain SET here, not hardcoded into
:: flash_device_core.bat - a future brand needing a genuinely different
:: .bin can still override it (see flash_device_TEMPLATE.bat).
:: ============================================================
SET BRAND_NAME=Open Sesame
SET MAIN_FIRMWARE=MatterOnOffSwitch.ino.bin
SET BRAND_LOGO=Logo_files\MiniTechLogo2.png

call "%~dp0flash_device_core.bat"
