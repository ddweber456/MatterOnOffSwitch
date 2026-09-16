@echo off
:: ============================================================
:: TEMPLATE brand wrapper.  [Rev 1.8]
:: Copy this file, rename it (e.g. flash_device_AcmeGarage.bat), and
:: fill in the three variables below for the new customer/brand. Then
:: run the copy - it calls the same shared, already-tested
:: flash_device_core.bat engine that flash_device.bat (the "Open
:: Sesame" wrapper) uses. See Product Requirement.txt Section 4.1.
::
:: You do NOT need a separate compiled firmware .bin per brand unless
:: that brand needs firmware-level differences beyond the device name
:: (not the case today - see Section 3.1's Device Identity Resolution).
:: ============================================================
SET BRAND_NAME=CHANGE_ME
SET MAIN_FIRMWARE=OpenSesame_C5_Production.bin
SET BRAND_LOGO=CHANGE_ME_logo.png

call "%~dp0flash_device_core.bat"
