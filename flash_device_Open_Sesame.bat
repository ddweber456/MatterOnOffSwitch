@echo off
:: ============================================================
:: "Open Sesame" brand wrapper.  [Rev 1.8]
:: Running this file does exactly what flash_device.bat always did -
:: it just now calls into the shared flash_device_core.bat engine
:: instead of containing the flashing logic itself. See Product
:: Requirement.txt Section 4.1 for why this split exists (one
:: compiled firmware image, multiple customer brands).
::
:: To onboard a NEW customer brand: copy flash_device_TEMPLATE.bat,
:: fill in its three variables, and save it under a new name (e.g.
:: flash_device_AcmeGarage.bat). No firmware rebuild required.
:: ============================================================
SET BRAND_NAME=Open Sesame
SET MAIN_FIRMWARE=OpenSesame_C5_Production.bin
SET BRAND_LOGO=MiniTechLogo2.png

call "%~dp0flash_device_core.bat"
