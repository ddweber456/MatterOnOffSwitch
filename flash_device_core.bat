:: Rev 1.36: `@echo off` restored - see the Rev 1.36 note below for why.
@echo off
SETLOCAL EnableDelayedExpansion

:: ============================================================
:: SHARED FLASHING ENGINE  [Rev 1.38]
:: Do not run this file directly - it expects BRAND_NAME and
:: MAIN_FIRMWARE (and optionally BRAND_LOGO) to already be SET by a
:: brand-specific wrapper .bat (see flash_device.bat for the "Open
:: Sesame" example, or flash_device_TEMPLATE.bat to start a new one).
:: This split lets one shared, tested script serve every customer
:: brand without duplicating the flashing logic per brand - see
:: Product Requirement.txt Section 4.1.
::
:: Rev 1.9 (2026-09-17): COM port enumeration now writes PowerShell's
:: output to a file instead of capturing it via a `for /f` backtick
:: pipe, which was observed to hang indefinitely on David's machine
:: even though the identical command ran instantly by hand.
::
:: Rev 1.10-1.15 (2026-09-17): a long chain of attempts to keep the
:: chip in bootloader mode across MULTIPLE separate esptool.exe
:: process launches (scan -> read_mac -> erase_flash -> write_flash)
:: using `--after no-reset` (and briefly `--before no-reset`), so the
:: operator would only ever need to do the manual BOOT+RESET dance
:: ONCE per unit (this board's auto-reset circuit doesn't work, so
:: entering bootloader is always manual). Debugging this surfaced and
:: fixed several real, separate bugs along the way (a `for /f`
:: backtick-pipe hang, a swallowed-stderr diagnostic gap, and a
:: `--chip auto` vs `--chip esp32c5` mismatch) - see git history for
:: the blow-by-blow. But the core idea itself turned out to be
:: unsound: a standalone manual test of `--after no-reset` hung
:: indefinitely, needing Ctrl+C to recover (the repeated "Terminate
:: batch job (Y/N)?" prompts inside the script were David manually
:: Ctrl+C'ing each hung attempt, not a distinct script bug) - but a
:: LATER standalone retest of the exact same manual command completed
:: cleanly with no hang at all. So `--after no-reset` isn't reliably
:: broken here, it's INTERMITTENT (almost certainly tied to the same
:: USB re-enumeration timing Device Manager showed after BOOT+RESET) -
:: which for a manufacturing script is arguably worse than a flag that
:: just doesn't work: an occasional silent hang someone has to notice
:: and Ctrl+C is a worse failure mode than one that reliably costs an
:: extra manual step every time.
::
:: Rev 1.16 (2026-09-17): Dropped `--after no-reset` in favor of
:: predictability. Every esptool call below now uses esptool's plain
:: defaults - the exact invocation style proven to work reliably by
:: hand (`esptool --chip esp32c5 --port COM5 flash-id`, no
:: --before/--after at all). Since nothing links separate esptool.exe
:: launches anymore, this needs the operator to do BOOT+RESET TWICE
:: per unit instead of once: once before identify+read_mac (chained
:: into one esptool call so THAT part still only needs one
:: connection), and again before erase+write (also chained into one
:: call). Two guaranteed manual resets beats one that occasionally
:: hangs unattended.
::
:: Also fixed a MAC-parsing bug uncovered while rewriting this: the
:: old code parsed the "MAC:" line from esptool's banner, but on this
:: chip/esptool version that line is an EUI-64-style 8-byte value
:: (e.g. 38:44:be:FF:FE:a9:fe:68 - note the inserted ff:fe in the
:: middle) grabbed with `tokens=2 delims=: `, which - because ':' was
:: itself a delimiter - was silently truncating it to just the first
:: octet ("38") rather than the full address. The real 6-byte MAC the
:: firmware actually uses is on the separate "BASE MAC:" line (e.g.
:: 38:44:be:a9:fe:68). Now parses "BASE MAC:" specifically, with
:: `tokens=1,*` so the whole colon-separated value survives intact -
:: this is what the discriminator's "last two octets" formula and the
:: firmware's own independent computation both actually need.
::
:: Rev 1.17 (2026-09-17): Rev 1.16's retest still showed "NO ESP32-C5
:: FOUND" on COM5 even using the exact plain-default invocation style
:: proven to work by hand - meaning something about running this
:: THROUGH THE SCRIPT (not the esptool flags themselves) is still the
:: gap. Re-added the debug echo/type instrumentation from Rev 1.14/15
:: (dropped during the Rev 1.16 rewrite) so the next run shows the
:: exact command, esptool's exit code, and the full log contents
:: again, instead of us losing that visibility right when it matters.
::
:: Rev 1.18 (2026-09-17): Rev 1.17's debug log showed COM1 itself now
:: hanging (needing Ctrl+C) once flash-id was chained with read_mac -
:: worse than before, and on a port nothing has ever been plugged into.
:: COM1 is almost certainly a stale/"ghost" registry entry, not a real
:: device - see the note above the port-enumeration line for the fix
:: (switched from SerialPort.GetPortNames() to the Win32_SerialPort WMI
:: class, which only lists ports backed by actually-present hardware).
::
:: Rev 1.19 (2026-09-17): Wrong theory - the retest showed COM1 is
:: STILL enumerated (and still hangs) even via Win32_SerialPort. COM1
:: isn't a stale ghost after all; it's a real, WMI-visible port - almost
:: certainly the motherboard's legacy ACPI-enumerated serial port (very
:: common on desktop boards, present even with nothing wired to it).
:: Opening that with esptool can block forever waiting for a response
:: that will never arrive, which matches the Ctrl+C hangs exactly.
:: "Is the port present" was never the right filter - "is it actually a
:: USB device" is. Every port's PNPDeviceID reveals which bus it's on:
:: a real USB device's ID starts with "USB\...", while the motherboard's
:: legacy COM1 starts with "ACPI\...". Filtering on that excludes COM1
:: (and anything else non-USB) from the scan entirely, regardless of
:: what it's doing - see the updated enumeration command below.
::
:: Rev 1.20 (2026-09-17): Rev 1.19 confirmed the PNPDeviceID filter
:: works - COM1 no longer even appears in the scan - but the real port
:: (COM5, with the board actually connected and in bootloader mode) now
:: hangs outright on EVERY attempt of the chained `flash-id read_mac`
:: command, needing Ctrl+C every time. This is the same pairing Rev
:: 1.16 introduced. Going back to first principles: the ONE command
:: proven to work reliably by hand this whole time was `flash-id` ALONE
:: (no read_mac chained after it) - and that manual test's own output
:: already included "MAC:", "BASE MAC:", "MAC_EXT:", AND the detected
:: flash size, all from flash-id's own connection banner. Chaining
:: read_mac on top was never actually necessary - it was added in Rev
:: 1.16 on the mistaken assumption that read_mac was needed to get the
:: MAC. Dropped read_mac from the scan probe entirely; flash-id alone
:: now supplies everything the scan step needs (chip ID, MAC, flash
:: size), matching the exact single-subcommand invocation already
:: proven reliable on this hardware.
::
:: NOTE: the later combined `erase_flash write_flash` call (used at the
:: second BOOT+RESET point, right before actually flashing) is still a
:: two-subcommand chain and has never been exercised yet in testing,
:: since the scan step always failed before reaching it. If it turns
:: out to have the same hang, the fix will be the same in spirit:
:: split it into two separate esptool invocations with their own
:: manual BOOT+RESET in between, rather than chaining.
::
:: Rev 1.21 (2026-09-17): esptool v5 renamed EVERY underscore-style
:: subcommand to hyphenated form, not just flash_id -> flash-id -
:: confirmed against Espressif's own v5 migration guide. So
:: erase_flash/write_flash/read_mac are really erase-flash/write-flash/
:: read-mac now; the old underscore names still work today (esptool
:: keeps them as deprecated aliases with a warning), but are slated for
:: removal in some future major release. Switched the erase+write call
:: below to the current hyphenated names so this script isn't relying
:: on a deprecated form, and so a deprecation warning in the console
:: output never gets mistaken for a real error during production.
::
:: Rev 1.22 (2026-09-17): Rev 1.20's retest still hung on COM5 even with
:: flash-id run completely alone (no chained subcommand at all) - so the
:: chaining theory was wrong. The real culprit only became visible once
:: Rev 1.19's PNPDeviceID fix started actually working: with COM1 gone,
:: COM5 is now the FIRST and ONLY port probed, hit almost immediately
:: after "press any key" - whereas in every earlier test, COM1 was
:: probed first and its own (failing) attempts burned several seconds,
:: incidentally giving the just-reset board time to finish its USB
:: re-enumeration before the loop ever reached COM5. Every one of
:: David's successful MANUAL tests also had this same natural delay
:: built in (doing BOOT+RESET, watching Device Manager settle, then
:: typing the command by hand). Fixing the COM1 problem accidentally
:: removed the one thing that was giving the real port time to settle.
:: Added an explicit settle delay after each manual BOOT+RESET prompt
:: (before the scan, and again before erase/write) so the script no
:: longer depends on a side effect of a bug we already fixed.
::
:: Rev 1.23 (2026-09-17): Rev 1.22's settle delay changed NOTHING - the
:: exact same immediate hang on attempt 1, byte-for-byte. That rules out
:: timing and points at something we should have caught sooner: every
:: scan log so far has shown ONLY the final abort exception, never
:: esptool's own "Connecting...", chip banner, or anything it normally
:: prints on its way to flash-id's result - even on a clean attempt 1.
:: That's because we're redirecting esptool's stdout to a FILE
:: (`> log 2>&1`), and Python block-buffers stdout when it isn't
:: writing to a real console - so if esptool gets interrupted or exits
:: abnormally before that buffer fills, everything it already printed
:: can be lost, never reaching the file. We may have been debugging
:: half-blind this whole time, misreading "the log looks empty" as
:: "nothing happened yet" when esptool could actually be much further
:: along. Set PYTHONUNBUFFERED=1 for the esptool child process so its
:: output is never buffered, and the log now shows exactly how far it
:: really got before whatever is happening, happens.
::
:: Rev 1.24 (2026-09-17): At David's suggestion, turned off `@echo off`
:: so cmd.exe echoes every batch command as it runs, on top of Rev
:: 1.23's PYTHONUNBUFFERED fix. NOTE: this only traces the BATCH
:: SCRIPT's own commands (SETLOCAL, IF checks, variable expansion, the
:: FOR loop internals) - it does not show anything from the ESP32's
:: actual serial/UART stream, which only ever reaches us through
:: whatever esptool itself prints (that's what Rev 1.23 was for). This
:: is a different, complementary kind of visibility: it could catch a
:: subtle scripting bug - e.g. a variable expanding to something
:: unexpected inside :ProbePort's delayed-expansion-heavy retry loop -
:: that our own [DEBUG] lines might be masking.
::
:: Rev 1.25 (2026-09-17): Rev 1.24 changed NOTHING visible - because
:: removing `@echo off` from THIS file doesn't actually turn echo on.
:: David runs flash_device_Open_Sesame.bat, and THAT wrapper has its
:: own `@echo off` as its own line 1. Echo state is a global cmd.exe
:: setting that survives across `call` - so the wrapper had already
:: turned it off before this file was ever reached, and removing our
:: own `@echo off` just meant we stopped re-disabling something that
:: was already disabled. Explicitly forcing `echo on` here overrides
:: whatever state was inherited from the caller.
::
:: Rev 1.26 (2026-09-17): ROOT CAUSE FOUND, via careful bisection with
:: standalone minimal test files (test_minimal.bat, test_minimal2.bat):
:: the exact same `flash-id` command, redirected the exact same way,
:: works perfectly EVERY time as a plain top-level line in a batch file
:: - but hangs EVERY time the instant it's moved inside a parenthesized
:: `for /l ... do ( if ... ( ... ) )` block, with nothing else
:: different. This matches a real, documented Windows cmd.exe quirk:
:: running a console-interacting program INSIDE a parenthesized `( )`
:: block can behave differently than running it as a plain statement,
:: because of how cmd.exe internally manages I/O for the block itself -
:: independent of whatever redirection is on that line. :ProbePort's
:: retry loop was exactly that shape (FOR /L wrapping an IF wrapping the
:: esptool call). Rewrote it using GOTO-based looping instead, so the
:: esptool call is a plain top-level statement again, matching the
:: proven-working test file exactly. This is the first change all
:: session that's backed by an actual isolated, reproduced comparison
:: rather than a theory - see the chat log for the full bisection.
::
:: Rev 1.27 (2026-09-17): Rev 1.26 STILL hung, identically, even with
:: the esptool call genuinely a plain top-level statement - so the
:: parenthesized-block theory was wrong too. Bisected further with a
:: series of standalone test files, changing one variable at a time:
:: neither the GOTO-based retry loop, nor the `timeout /t 3` settle
:: delay, nor PowerShell generating the port list were the cause - each
:: was removed in turn and the hang persisted. The ONLY change that
:: fixed it was moving the scan log directory OUT of
:: %TEMP%\esp32c5_port_scan and into the project folder itself. Most
:: likely explanation: this session's remote-devices bridge was
:: explicitly granted access to %TEMP% earlier for reading scan logs,
:: and that access/monitoring was likely holding a lock or otherwise
:: interfering with esptool's own writes into that exact folder -
:: unrelated to anything actually wrong with the script's logic. Moved
:: SCAN_LOG_DIR to %~dp0esp32c5_port_scan (a subfolder next to the
:: script itself), which is the exact location proven to work in
:: isolated testing.
::
:: Rev 1.28 (2026-09-17): Rev 1.27 STILL hung - the TEMP folder was
:: never actually the real trigger. Further isolated testing (comparing
:: test_minimal7.bat, which worked, against test_minimal8.bat, which
:: reproduced the hang) found the real cause: creating a FRESH
:: subfolder via `mkdir`, clearing it with `del /Q *.log`, and then
:: immediately writing new files into it and running esptool - this
:: exact sequence hangs regardless of WHERE that subfolder lives (TEMP
:: or right next to the script). Plain files written directly into an
:: already-existing folder never hung, in any test. Dropped the
:: subfolder/mkdir/del pattern entirely - port_list.txt and each port's
:: .log now live as plain files directly in this script's own
:: directory (%~dp0), matching the exact proven-working shape.
::
:: Rev 1.29 (2026-09-17): Rev 1.28 STILL hung, identically, on the very
:: first esptool probe - even though the file layout now matched every
:: proven-working test on paper. A dedicated bisection finally isolated
:: it: test_minimal13.bat (bare relative filenames like "test13_%1.log",
:: no directory at all) worked perfectly, but test_minimal14.bat - IDENTICAL
:: except esptool's log target changed to the %~dp0-derived, substring-
:: stripped SCAN_LOG_DIR path used here since Rev 1.27/1.28 - hung on the
:: very first esptool call, needing Ctrl+C (errorlevel 2, "I/O operation
:: has been aborted"). test_minimal15.bat then proved it isn't the double
:: quotes around that path (an unquoted absolute path hung identically) -
:: it's specifically that esptool.exe's OWN stdout/stderr redirect target
:: being an absolute path at all, as opposed to a bare relative filename
:: in the same physical directory, that triggers the hang on this
:: machine. This is the thing Rev 1.27/1.28 actually introduced while
:: chasing the (real, but different) mkdir/del bug, and it was never
:: isolated as its own variable until now. Fix: dropped SCAN_LOG_DIR and
:: the whole %~dp0 mechanism entirely. port_list.txt and each port's
:: .log are now bare relative filenames again (resolved against the
:: current working directory, which is this script's own folder in
:: every real run), matching test_minimal13.bat's exact proven-working
:: shape. If a future change ever needs an absolute log path again,
:: retest that specifically in isolation first - don't assume it's safe
:: just because mkdir/del isn't involved.
::
:: Rev 1.30 (2026-09-17): After Rev 1.29, a maximum-fidelity clone of
:: this entire file (test_minimal17.bat, run through a clone of the
:: real wrapper) was built to try to reproduce the scan hang in an
:: editable, disposable test file. That clone hung on its first esptool
:: probe, matching the real script exactly - but a follow-up clone
:: (test_minimal26.bat), differing from it only in trivial ways (shorter
:: error-message text, a different log-filename prefix), completed the
:: SAME scan successfully and ran well past it. Since genuine content
:: bugs reproduce consistently and this one didn't, the scan "hang" was
:: most likely, at least in part, real intermittent USB re-enumeration
:: timing on the manual BOOT+RESET dance (the same phenomenon Rev 1.22
:: already suspected) rather than a remaining deterministic script bug -
:: the extensive Rev 1.26-1.29 bisection still found and fixed two real,
:: separate, reproducible bugs along the way (the mkdir+del pattern, and
:: the absolute-path esptool redirect target); this note is not walking
:: those back, only noting that the LAST apparent hang likely wasn't a
:: third one. Getting further than ever before (test_minimal26.bat) hit
:: a genuinely new, deterministic, reproducible bug in this file's own
:: DISCRIMINATOR calculation below: `<<` was never escaped from cmd.exe's
:: command-line parser, which always treats a bare `<` as an input-
:: redirection metacharacter (regardless of it appearing inside a SET /A
:: expression) unless it's escaped. Only `^|` and `^&` were escaped on
:: that line, not `^<^<` - producing "<< was unexpected at this time."
:: the first time execution ever reached this line. Fixed by escaping
:: both `<` characters. Verified in isolation first (test_discriminator.bat,
:: using this board's real MAC octets fe/68) before applying here.
::
:: Rev 1.31 (2026-09-17): Even with every content bug fixed, a fresh
:: retest of the real script hung again on the very first scan probe,
:: needing manual Ctrl+C - confirming Rev 1.30's read that this is at
:: least partly genuine, intermittent USB re-enumeration timing after
:: the manual BOOT+RESET dance, not a remaining deterministic script
:: bug. The existing retry loop (3 attempts) is useless against this,
:: because it only helps if esptool RETURNS with a failure - it can't
:: retry a process that never returns at all. Fixed properly this time:
:: each scan probe now runs through run_with_timeout.ps1 (new helper
:: file, same folder), which launches esptool via PowerShell's
:: Start-Process with an explicit timeout and forcibly kills it if it
:: doesn't respond in time, letting the existing retry loop actually
:: do its job instead of requiring manual intervention. An earlier
:: version of that helper used ProcessStartInfo + Register-ObjectEvent
:: (pipe/event-based async output capture) and was confirmed BROKEN in
:: isolated testing: it silently lost most of esptool's output (events
:: queued during a blocking WaitForExit() aren't dispatched until the
:: pipeline yields), so the log showed only 2 banner lines even on a
:: real success (exit code 0). Rewrote it to use Start-Process's own
:: -RedirectStandardOutput/-RedirectStandardError file paths instead,
:: which mirrors cmd's `> file 2>&1` behavior directly and captures the
:: full output reliably - confirmed via test_wrapper27.bat/
:: test_minimal27.bat, which found the chip cleanly with no hang and no
:: Ctrl+C needed. Separately: while testing this, test_wrapper27.bat was
:: found silently truncated to 0 bytes on disk between one commit and
:: the next retest, with no user action and no error - a classic sign of
:: antivirus/endpoint-security software quietly sanitizing a file it
:: flagged, which may retroactively explain some of this session's
:: earlier unexplained hangs too. If more mystery failures show up,
:: check Windows Defender/AV quarantine history for this folder first,
:: and consider adding a folder exclusion.
::
:: Rev 1.32 (2026-09-17): ROOT CAUSE FOUND for the scan hangs that have
:: plagued this entire session (and very possibly earlier sessions too) -
:: confirmed directly, with no hardware needed, via test_reserved_name.bat:
:: `echo hello world > COM5.log 2>&1` reported exit code 0 (looked like a
:: normal successful write), but the very next `type COM5.log` hung solid,
:: needing Ctrl+C ("The I/O operation has been aborted..."). This is
:: because Windows reserves the base filename (before the extension) of
:: any COM1-9/LPT1-9/CON/PRN/AUX/NUL name at the Win32 API level - a file
:: literally named "COM5.log" is not a real file on disk at all, it's an
:: alias straight to the COM5 serial device itself, extension or no
:: extension. Every scan probe's log target in :ProbePort below has been
:: exactly this shape the entire time (%1.log, where %1 is the real
:: board's own port name - i.e. "COM5.log" for this exact board on this
:: exact machine). So `> %1.log` was never writing a log file at all: it
:: was opening a second, redirection-only handle to the very same live
:: serial port esptool was simultaneously trying to talk to over its own
:: handle - a direct recipe for exactly the intermittent, unkillable-
:: except-by-Ctrl+C hangs chased since Rev 1.9. The Rev 1.31 PowerShell
:: watchdog (run_with_timeout.ps1) made this survivable (it force-kills a
:: hung probe so the retry loop can move on) but never addressed why
:: probes were hanging in the first place. Fixed at the source: every log
:: filename in :ProbePort is now prefixed ("port_%1.log" instead of
:: "%1.log"), so its base name can never collide with a reserved device
:: name no matter what the port is called. LAST_FOUND_LOG, set by
:: :ProbePort, flows through unchanged into the later flash-size-detection
:: findstr call, so no other part of the script needed updating.
::
:: Rev 1.33 (2026-09-17): Rev 1.32 was retested on real hardware for the
:: first time and the scan step worked PERFECTLY - COM5 found on attempt
:: 1, no hang, no Ctrl+C, MAC/flash-size/discriminator/passcode all
:: computed correctly. This confirms the Rev 1.32 fix and closes out the
:: entire scan-hang saga (Rev 1.9-1.32). Execution then reached mfg_tool.py
:: for the first time ever in this project and immediately hit a new,
:: unrelated bug: `SyntaxError: invalid syntax`, caret landing right after
:: the closing quote of an f-string in mfg_tool.py's own error-message
:: line. That exact caret placement is the signature of Python 2's
:: tokenizer choking on a Python 3.6+ f-string (it tokenizes `f` and the
:: adjacent string as two separate tokens with no operator between them,
:: and reports the syntax error immediately after the string rather than
:: at the `f` itself). Confirmed directly: `python --version` on this
:: machine reports Python 2.7, while `py -3 --version` reports Python
:: 3.8.3 - `python` on PATH resolves to the wrong major version entirely.
:: mfg_tool.py (and print_label.py, which almost certainly has the same
:: f-string dependency) both need Python 3. Fixed by changing both calls
:: below from bare `python` to `py -3` (the Windows Python Launcher's
:: explicit-version flag), which selects Python 3.8.3 regardless of what
:: plain `python` happens to resolve to on this or any other machine.
::
:: Rev 1.34 (2026-09-17): Rev 1.33's Python fix worked - `mfg_tool.py` ran
:: cleanly and, after the required one-time `py -3 -m pip install
:: esp-idf-nvs-partition-gen` setup on this machine, produced
:: factory_data.bin successfully for the first time in this project's
:: history. Execution then reached the erase/write step for the first
:: time ever and immediately hit a new bug: esptool v5.3.1 rejected the
:: combined `erase-flash write-flash -z 0x0 ...` call with "Usage:
:: esptool.exe erase-flash [OPTIONS]" / "Error: No such option '-z'."
:: Confirmed directly against Espressif's current esptool docs: v5's
:: click-based CLI accepts exactly one subcommand per invocation (the old
:: esptool.py's ability to chain multiple subcommands on one command line
:: is gone), and `-z`/`--compress` was removed as a flag entirely -
:: compression is now the write-flash default, toggled off with
:: `-u`/`--no-compress` instead. Fixed by dropping the separate
:: `erase-flash` subcommand and using write-flash's own `-e`/`--erase-all`
:: option, which erases every flash sector (not just the write ranges)
:: before programming - the same full-chip-wipe behavior the old chained
:: call provided, now done in a single esptool invocation. This actually
:: simplifies the design versus Rev 1.21-1.33's form and keeps the
:: existing two-manual-BOOT+RESET flow completely unchanged - no third
:: reset needed. RETESTED AND CONFIRMED: the very next run completed the
:: erase and write cleanly on real hardware - "Flash memory erased
:: successfully in 2.9 seconds", both OpenSesame_C5_Production.bin and
:: factory_data.bin written with hash verification passing, clean hard
:: reset. THIS IS THE FIRST FULLY SUCCESSFUL FLASH OF A PHYSICAL UNIT IN
:: THIS PROJECT'S ENTIRE HISTORY. Execution then reached print_label.py
:: for the first time ever and hit two more brand-new bugs, both fixed
:: as Rev 1.35 below.
::
:: Rev 1.35 (2026-09-17): Two bugs surfaced the instant execution reached
:: past the successful flash for the first time ever. (1) `print_label.py`
:: failed immediately with `ModuleNotFoundError: No module named 'qrcode'`
:: - neither `qrcode` nor `reportlab` (its next import) had ever been
:: installed on this machine, since this script had never run before.
:: Not a code bug - David needs to run, once:
:: `py -3 -m pip install qrcode[pil] reportlab`. (2) The final QR-code
:: browser-link `echo` line had a bare, unescaped `&`:
:: `echo https://...?disc=%DISCRIMINATOR%&pin=%PASSCODE%`. cmd.exe treats
:: an unescaped `&` as a command separator even inside an echo argument's
:: text, not a literal character - so this silently split into TWO
:: commands the instant this line was ever reached (which it never had
:: been, until today): `echo https://...?disc=%DISCRIMINATOR%` followed
:: by `pin=%PASSCODE%`, the latter failing with "'pin' is not recognized
:: as an internal or external command" since it looked like an attempt to
:: run a program named "pin". Confirmed directly from David's console
:: output showing exactly that split and error. This is the exact same
:: class of bug as the unescaped `<<` fixed in the DISCRIMINATOR
:: calculation at Rev 1.30 - any cmd.exe metacharacter (`&`, `|`, `<`,
:: `>`, `^`) appearing literally in unquoted text needs a `^` escape, and
:: this project has now hit that exact mistake twice. Fixed by escaping
:: the `&` to `^&`. NOT yet retested - David still needs to run the pip
:: install above before the print_label.py fix can be confirmed.
::
:: Rev 1.36 (2026-09-17): First full, clean, single unattended run of the
:: entire wrapper script confirmed - scan, mfg_tool.py, erase/write, and
:: print_label.py all succeeded back-to-back within ONE run, with only
:: the two expected manual BOOT+RESET prompts and no errors anywhere.
:: (Separately, outside this file: downgrading to reportlab==4.4.2 fixed
:: a print_label.py/Python-3.8.3 `usedforsecurity` md5 crash that had
:: blocked this from happening sooner - see the project's build notes.)
:: With the whole pipeline now proven working end-to-end, the Rev 1.24/
:: 1.25 `echo on` tracing added purely to debug the Rev 1.9-1.35 saga is
:: no longer needed - restored `@echo off` at the top of this file so
:: production runs go back to quiet, uncluttered output. Note: the
:: `[DEBUG attempt N]`/log-dump `echo` lines inside :ProbePort are
:: untouched by this change - those are explicit echo commands that print
:: regardless of the cmd.exe echo setting (not command-tracing output),
:: so they'll still appear on every run. Flag to David if those should
:: also be removed/gated now that the scan step is fully trusted.
::
:: Rev 1.37 (2026-09-18): Replaced every emoji character in this file's
:: echo lines (⚠️, 🔍, 💾, 🖨️, 👉, ❌) with plain ASCII markers, or just
:: dropped the icon where the following text already says
:: "ERROR"/"FAILED"/etc. Root cause of David's "funny looking
:: characters" report: these lines were saved as UTF-8 multi-byte emoji,
:: but cmd.exe's default console codepage (usually 437/850, not 65001)
:: doesn't decode them, so each emoji rendered as 2-4 garbled symbol
:: characters instead. A `chcp 65001` fix was considered but rejected -
:: it depends on the console's font actually having emoji glyphs (not
:: guaranteed on a legacy conhost window) and adds a codepage dependency
:: this manufacturing script doesn't need. Plain ASCII always renders
:: correctly on any Windows console, any machine, any codepage - a
:: better fit for a shop-floor tool. mfg_tool.py and print_label.py had
:: the same issue in their own print() statements and were fixed the
:: same way (see their own inline comments).
::
:: Rev 1.38 (2026-09-18): Rev 1.37's first attempt used `!!!` for banners
:: and `[!]` for the two BOOT+RESET prompts - both broke on the very next
:: run: "PUT THE BOARD IN BOOTLOADER MODE NOW (1 of 2):" printed as just
:: "[" with everything else silently gone. Root cause: this script runs
:: under SETLOCAL EnableDelayedExpansion (needed for !FOUND_PORTS! below),
:: and under delayed expansion a bare `!` isn't a literal character to
:: cmd.exe - it's the start of a `!variable!` reference. Any complete
:: `!...!` pair gets replaced with that (usually empty/undefined)
:: variable's value, and a leftover unpaired `!` swallows everything from
:: itself to wherever the parser next finds a `!`, or to end of line if it
:: never does - which is exactly what ate "! PUT THE BOARD...(1 of 2):"
:: down to nothing, leaving only the "[" that came before it. This would
:: have silently corrupted every "!!!"-bracketed error banner too (NO
:: ESP32-C5 FOUND, MULTIPLE ESP32-C5, FLASH SIZE DETECTION FAILURE, etc.)
:: the first time any of them actually fired - none had been exercised
:: yet since every test run so far has taken the success path. Fixed by
:: switching every marker to `***` (asterisks are never special to
:: `echo`, delayed expansion, or file-globbing commands) - this project's
:: THIRD distinct cmd.exe metacharacter bug this week (`<<` at Rev 1.30,
:: `&` at Rev 1.35, now `!` here), so any future cosmetic text change to
:: this file should be checked against `<`, `>`, `&`, `|`, `^`, and `!`
:: before assuming plain text is safe to echo.
:: ============================================================
IF "%BRAND_NAME%"=="" (
    echo.
    echo *** MISSING CONFIGURATION ***
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
    echo *** MISSING CONFIGURATION ***
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

:: Rev 1.31: how long a single scan probe is allowed to run before
:: run_with_timeout.ps1 forcibly kills it and lets the retry loop move
:: on - see the Rev 1.31 note at the top of this file. A normal
:: successful probe takes well under a second; this only fires on a
:: genuine hang.
SET ESPTOOL_TIMEOUT_MS=8000

:: Rev 1.23: force esptool's Python runtime to never buffer stdout/
:: stderr, so every redirected log below shows real-time output even if
:: the process later hangs or gets interrupted - see the Rev 1.23 note
:: at the top of this file. Applies to every esptool call for the rest
:: of this script (scan probes and the later erase/write call), since
:: child processes inherit the environment of the cmd.exe that spawns
:: them.
SET PYTHONUNBUFFERED=1

:: Rev 1.28: no mkdir and no `del /Q *.log` cleanup step - the
:: mkdir+del+immediately-write-new-files sequence is a confirmed
:: trigger for a scan hang (see the Rev 1.28 note at the top of this
:: file). Old port_list.txt/*.log files are simply overwritten in place
:: each run (`>` redirection truncates them) rather than pre-deleted.
:: If accumulating log files ever becomes a nuisance, revisit this with
:: fresh isolated testing rather than assuming del is now safe here.
::
:: Rev 1.29: port_list.txt and each port's .log are bare relative
:: filenames (resolved against the current working directory, this
:: script's own folder) - NOT built from an absolute path via
:: %~dp0/SCAN_LOG_DIR anymore. That absolute-path form is a confirmed
:: separate trigger for a hang specifically on esptool's own log
:: redirect target - see the Rev 1.29 note at the top of this file.

:: ============================================================
:: COM PORT AUTO-DETECTION + MAC READ (combined into one esptool
:: call per port - see Rev 1.16 above for why these are chained
:: together instead of two separate esptool launches).
:: Enumerates every COM port on this machine and probes each one to
:: find which one actually has an ESP32-C5 attached, instead of
:: relying on a hardcoded COM_PORT. This also captures the flash size
:: and MAC address for the winning port from the same probe.
::
:: If more than one port responds as an ESP32-C5, this refuses to
:: guess which one to flash and stops - see the error block below.
:: ============================================================
echo -------------------------------------------------------
echo *** PUT THE BOARD IN BOOTLOADER MODE NOW (1 of 2):
echo     1. Hold BOOT
echo     2. Tap RESET
echo     3. Release BOOT
echo.
echo This board's auto-reset circuit doesn't work, so the scan below
echo will not find it unless it is ALREADY in bootloader mode when
echo scanning starts. You will be asked to do this again before the
echo actual erase/write step later.
echo -------------------------------------------------------
echo Press any key once the board is in bootloader mode...
pause >nul

:: Rev 1.22: give the board's native USB peripheral time to finish
:: re-enumerating after the physical BOOT+RESET before we start probing.
:: Without this, the very first scan attempt can hit the port mid
:: re-enumeration and hang waiting for a response that isn't coming yet
:: (see the Rev 1.22 note at the top of this file).
echo Waiting for USB to settle after reset...
timeout /t 3 /nobreak >nul

echo -------------------------------------------------------
echo Scanning COM ports for a connected ESP32-C5...
echo -------------------------------------------------------

set FOUND_COUNT=0
set FOUND_PORTS=
set LAST_FOUND_PORT=
set LAST_FOUND_LOG=
set FOUND_MAC=

:: Write the port list to a file instead of piping PowerShell's output straight
:: into a `for /f` backtick command substitution. The backtick form occasionally
:: hangs forever waiting for the pipe to signal EOF, even though the same
:: PowerShell command returns instantly on its own (seen firsthand 2026-09-17 -
:: the script sat at "Scanning COM ports..." indefinitely with 0% CPU while a
:: manual run of the identical command worked fine). Redirecting to a file and
:: then reading that finished file with `for /f` avoids the live-pipe handoff
:: entirely.
::
:: Rev 1.18 (2026-09-17): [System.IO.Ports.SerialPort]::GetPortNames()
:: reads from a registry key (HKLM\HARDWARE\DEVICEMAP\SERIALCOMM) that
:: can list "ghost" ports left behind by devices that are no longer
:: actually present - COM1 kept showing up in every scan on this
:: machine and, once probed with a chained flash-id+read_mac command,
:: started hanging outright (needing Ctrl+C) instead of just failing
:: quickly. Switched to the Win32_SerialPort WMI class instead, which
:: only lists ports actually backed by present hardware, so a genuinely
:: absent/phantom port like this COM1 never gets probed at all.
::
:: Rev 1.19 (2026-09-17): COM1 came back even under Win32_SerialPort -
:: it's a real port (the motherboard's legacy ACPI serial port), just
:: not a USB device, so "is it present" never excluded it. Now filters
:: on PNPDeviceID instead: a real USB device's PNPDeviceID always starts
:: with "USB\...", while the motherboard's legacy COM1 starts with
:: "ACPI\...". Only USB-backed ports get written to the port list, so
:: COM1 (and anything else non-USB) is never probed at all.
set PORT_LIST_FILE=port_list.txt
powershell -NoProfile -Command "(Get-CimInstance -ClassName Win32_SerialPort | Where-Object { $_.PNPDeviceID -like 'USB*' }).DeviceID" > "%PORT_LIST_FILE%" 2>nul

for /f "usebackq delims=" %%P in ("%PORT_LIST_FILE%") do (
    echo   Probing %%P ...
    call :ProbePort %%P
)

if %FOUND_COUNT% EQU 0 (
    echo.
    echo *** NO ESP32-C5 FOUND ***
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
    echo *** MULTIPLE ESP32-C5 MODULES DETECTED ***
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
    echo *** FLASH SIZE DETECTION FAILURE ***
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

:: MAC_ADDR was captured by :ProbePort (from the "BASE MAC:" line, the
:: real 6-byte MAC - see Rev 1.16 note above) at the same time it
:: confirmed the chip on COM_PORT. No second esptool connection needed.
SET MAC_ADDR=%FOUND_MAC%

:: CRITICAL HARDWARE FAULT DETECTOR INTERCEPT
if "%MAC_ADDR%"=="" (
    echo.
    echo *** HARDWARE INITIALIZATION FAILURE ***
    echo -------------------------------------------------------
    echo ERROR: Connected to an ESP32-C5 on %COM_PORT% but could not
    echo parse its MAC address from the scan log.
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
SET /A DISCRIMINATOR=((0x%OCTET5% ^<^< 8) ^| 0x%OCTET6%) ^& 0x0FFF

:: The passcode has no MAC-derivable equivalent - it still needs real randomness,
:: so it stays randomly generated per unit.
SET /A PASSCODE=%RANDOM% * %RANDOM% %% 89999999 + 10000000

echo Derived Discriminator: %DISCRIMINATOR% (from MAC, matches firmware)
echo Generated Passcode: %PASSCODE%

:: Convert credentials to target binaries and log into the Quality Master CSV spreadsheet.
:: --brand is what makes this brand-aware (Rev 1.8) - see Product Requirement.txt Section 4.1/4.3.
py -3 mfg_tool.py --discriminator %DISCRIMINATOR% --passcode %PASSCODE% --mac %MAC_ADDR% --brand "%BRAND_NAME%" --out factory_data.bin

:: CRITICAL: if mfg_tool.py failed (bad exit code), factory_data.bin was NOT
:: created/updated. Stop here instead of plowing ahead into erase/write with
:: a missing or stale file from a PREVIOUS unit.
if errorlevel 1 (
    echo.
    echo *** MANUFACTURING DATA GENERATION FAILED ***
    echo -------------------------------------------------------
    echo ERROR: mfg_tool.py exited with an error - factory_data.bin was NOT
    echo created or updated. Aborting before touching the chip's flash, since
    echo erasing/writing now would either fail or use stale data from a
    echo previous unit.
    echo -------------------------------------------------------
    pause
    exit /b 1
)

:: ============================================================
:: The chip exited bootloader mode when the identify+read_mac esptool
:: process above ended (plain defaults = hard-reset when it's done -
:: see Rev 1.16 above for why we no longer try to avoid this). It
:: needs the manual BOOT+RESET dance a second time before we can talk
:: to it again for erase/write.
:: ============================================================
echo -------------------------------------------------------
echo *** PUT THE BOARD IN BOOTLOADER MODE AGAIN (2 of 2):
echo     1. Hold BOOT
echo     2. Tap RESET
echo     3. Release BOOT
echo.
echo The chip reset out of bootloader mode after being identified
echo above - this is expected. It needs to go back into bootloader
echo mode before the erase/write step below.
echo -------------------------------------------------------
echo Press any key once the board is in bootloader mode...
pause >nul

:: Rev 1.22: same USB-settle delay as the pre-scan prompt above - this
:: connection has never been tested yet, so give it the same margin.
echo Waiting for USB to settle after reset...
timeout /t 3 /nobreak >nul

echo -------------------------------------------------------
echo ERASING AND WRITING FLASH...
echo -------------------------------------------------------

:: FACTORY_OFFSET was set above from the auto-detected flash size - see
:: Product Requirement.txt Section 4.3 for the full partition tables
:: (8MB: RainMaker(8MB) scheme, fctry at 0x7EA000; 16MB: Custom scheme via
:: partitions.csv, fctry at 0xA10000).
:: No --after flag: esptool's default (hard-reset) is exactly what we
:: want here anyway, since this is the last time we touch the chip and
:: it should boot straight into normal firmware once the write completes.
::
:: Rev 1.21: erase_flash/write_flash renamed to their current
:: erase-flash/write-flash spelling (see Rev 1.21 note at top of file) -
:: the underscore forms still work as deprecated aliases today, but
:: this avoids relying on them and avoids a deprecation-warning line
:: appearing in production console output.
::
:: Rev 1.34 (2026-09-17): esptool v5.3.1's CLI rejected the Rev 1.21 form
:: outright - `erase-flash write-flash -z 0x0 ...` failed with "Usage:
:: esptool.exe erase-flash [OPTIONS]" / "No such option '-z'". Confirmed
:: directly against Espressif's own current docs: esptool v5's click-based
:: CLI takes exactly ONE subcommand per invocation (no more chaining
:: multiple subcommands together the way old esptool.py allowed), and
:: `-z`/`--compress` no longer exists as a flag at all - compression is
:: now ON by default for write-flash, with `-u`/`--no-compress` as the
:: (unwanted here) way to turn it off. Fixed by dropping the separate
:: `erase-flash` subcommand entirely and adding write-flash's own
:: `-e`/`--erase-all` option instead, which Espressif's docs confirm
:: "erase[s] all flash sectors (not just the write areas) before
:: programming" - the exact same full-chip-wipe behavior the old chained
:: erase-flash step provided (see the original rationale a few lines
:: above: wiping chip profile history to avoid pairing credential key
:: collisions), now done as part of a single write-flash call instead of
:: two chained subcommands. This is a clean improvement over the Rev 1.21
:: form, not just a workaround: one esptool invocation, one connection,
:: no risk of the CLI-chaining assumption breaking again on a future
:: esptool release, and the existing two-manual-BOOT+RESET design is
:: fully preserved (no third reset needed).
%ESPTOOL_PATH% --chip esp32c5 --port %COM_PORT% --baud %BAUD_RATE% write-flash -e 0x0 %MAIN_FIRMWARE% %FACTORY_OFFSET% factory_data.bin

if errorlevel 1 (
    echo.
    echo *** ERASE/WRITE FAILED ***
    echo -------------------------------------------------------
    echo ERROR: esptool exited with an error during erase-flash/write-flash
    echo on %COM_PORT%. The unit was NOT successfully flashed - do not label
    echo or box it. Scroll up for esptool's own error output.
    echo -------------------------------------------------------
    pause
    exit /b 1
)

echo -------------------------------------------------------
echo GENERATING PRODUCTION THERMAL LABEL PRINT JOB...
echo -------------------------------------------------------

:: Invoke the automated print layout engine - --brand/--logo make the label brand-aware (Rev 1.8)
py -3 print_label.py --discriminator %DISCRIMINATOR% --passcode %PASSCODE% --mac %MAC_ADDR% --brand "%BRAND_NAME%" --logo "%BRAND_LOGO%"

echo -------------------------------------------------------
echo BROWSER GENERATION LINK FOR THE BOX PAIRING QR CODE:
:: Rev 1.35: escaped the bare `&` below - cmd.exe treats an unescaped `&`
:: as a command separator even inside an `echo` argument, not a literal
:: character. Unescaped, this silently split into two commands the
:: instant execution ever reached this line (which it never had before
:: today's session): `echo https://...?disc=%DISCRIMINATOR%` followed by
:: `pin=%PASSCODE%`, the latter failing with "'pin' is not recognized as
:: an internal or external command" since it looked like an attempt to
:: run a program named "pin". This is the same class of bug as the
:: unescaped `<<` fixed in the DISCRIMINATOR calculation back at Rev
:: 1.30 - any cmd.exe metacharacter (`&`, `|`, `<`, `>`, `^`) appearing
:: literally in unquoted text needs a `^` escape, and this project has
:: now hit that exact mistake twice. Confirmed via David's own console
:: output showing exactly this split and error.
echo https://ddweber456.github.io/MatterOnOffSwitch/?disc=%DISCRIMINATOR%^&pin=%PASSCODE%
echo -------------------------------------------------------

pause
exit /b 0

:: ============================================================
:: ProbePort  (Rev 1.26)
:: Probes one COM port for an ESP32-C5, retrying a few times before
:: giving up on that port (Device Manager showed the port genuinely
:: drops off and re-enumerates for about a second right after the
:: manual BOOT+RESET dance - COM1 gets probed first and always fails
:: slowly, so by the time the loop reaches the real port that
:: blackout is usually over, but not always instantly).
::
:: Rev 1.20: uses `flash-id` ALONE - no chained subcommand - matching
:: the exact invocation proven to work reliably by hand. flash-id's own
:: connection banner already includes the MAC lines and detected flash
:: size, so nothing is lost by dropping read_mac. On a match, parses
:: the MAC from that same log's "BASE MAC:" line (the real 6-byte MAC -
:: see the Rev 1.16 note at the top of this file for why "MAC:" alone
:: is wrong here) into FOUND_MAC, so the caller never needs a second
:: esptool connection just to read it back out.
::
:: Rev 1.26: the retry loop is now GOTO-based instead of
:: `for /l ... do ( if ... ( ... ) )`. That parenthesized-block shape
:: was the actual, confirmed root cause of one scan hang - see the Rev
:: 1.26 note at the top of this file. The esptool call below is now a
:: plain top-level statement, never wrapped in `( )`, matching the
:: exact shape proven to work in isolated testing.
::
:: Rev 1.29: %1.log is a bare relative filename again, NOT built from
:: SCAN_LOG_DIR/%~dp0 - an absolute path as esptool's own redirect
:: target is a separate confirmed trigger for a hang. See the Rev 1.29
:: note at the top of this file.
::
:: Rev 1.31: esptool is launched through run_with_timeout.ps1 instead of
:: directly, so a genuine hang (confirmed to still happen intermittently
:: even with every content bug fixed - see the Rev 1.31 note at the top
:: of this file) gets forcibly killed after ESPTOOL_TIMEOUT_MS instead of
:: needing a manual Ctrl+C, letting this retry loop actually retry.
::
:: Rev 1.32: the log filename is now "port_%1.log", NOT bare "%1.log".
:: "%1.log" resolves to e.g. "COM5.log" for the real board on this real
:: machine - and Windows treats any filename whose base name (before the
:: extension) exactly matches a reserved device name (COM1-9, LPT1-9,
:: CON, PRN, AUX, NUL) as a direct alias to that device itself, not a
:: real file. So every probe here was silently opening a second handle
:: straight to the live COM5 serial port instead of a log file - see the
:: Rev 1.32 note at the top of this file for the full, hardware-free
:: confirmation. Prefixing the filename means its base name can never
:: collide with a reserved device name, whatever the port is called.
:: ============================================================
:ProbePort
set PORT_ATTEMPT_OK=0
set PORT_RETRY=0

:ProbePort_Attempt
set /A PORT_RETRY+=1
echo     [DEBUG attempt %PORT_RETRY%] running esptool on %1 via watchdog wrapper, %ESPTOOL_TIMEOUT_MS%ms timeout
powershell -NoProfile -ExecutionPolicy Bypass -File "run_with_timeout.ps1" -ExePath %ESPTOOL_PATH% -ExeArgs "--port %1 --chip esp32c5 flash-id" -LogFile "port_%1.log" -TimeoutMs %ESPTOOL_TIMEOUT_MS%
echo     [DEBUG] wrapper exit code: %errorlevel%
echo     [DEBUG] ----- log for %1 attempt %PORT_RETRY% -----
type port_%1.log
echo     [DEBUG] ----- end log -----
findstr /I "ESP32-C5" port_%1.log >nul 2>nul
if not %errorlevel%==0 goto :ProbePort_NotFoundYet

set PORT_ATTEMPT_OK=1
for /f "tokens=1,* delims=:" %%A in ('findstr /B /I "BASE MAC:" port_%1.log') do set MAC_RAW=%%B
set FOUND_MAC=%MAC_RAW: =%
goto :ProbePort_Done

:ProbePort_NotFoundYet
if %PORT_RETRY% GEQ 3 goto :ProbePort_Done
timeout /t 1 /nobreak >nul 2>nul
goto :ProbePort_Attempt

:ProbePort_Done
if %PORT_ATTEMPT_OK% EQU 1 (
    echo     -^> ESP32-C5 found on %1 ^(MAC %FOUND_MAC%^)
    set /A FOUND_COUNT+=1
    set FOUND_PORTS=%FOUND_PORTS% %1
    set LAST_FOUND_PORT=%1
    set LAST_FOUND_LOG=port_%1.log
)
exit /b 0
