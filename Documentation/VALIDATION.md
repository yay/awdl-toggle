# Validation

## Automated checks

Run `Scripts/test.sh` for:

- Manual On/Off, repeated external raises, and avoidance of redundant interface writes.
- Restoration of the saved policy after a monitor restart.
- Interface absence and reappearance, including a pending On transition.
- Interface-write errors, recovery, failed persistence, and corrupt saved state.
- Truncated, malformed, and unrelated route events, including 10,000 randomized inputs.
- Real anonymous XPC round trips, rapid requests, disconnect persistence, timeout, and invalidation.
- LaunchDaemon lifetime, narrowly scoped extension entitlements, shell syntax, startup-volume restriction, and deterministic project regeneration.

`Scripts/build.sh` builds both arm64 and x86_64 with a macOS 26 deployment target and verifies signatures. `python3 Scripts/package.py` verifies the fully packaged app after embedding its repair/uninstall packages.

`python3 Scripts/verify-package.py` extracts the actual installer, verifies both code signatures and architectures, checks App Intents metadata and maintenance packages, and confirms that the client allowlist rejects a modified app with the same bundle identifier.

The administrator-run `Scripts/Run-Live-Tests.command` automates forced interface raises, crash recovery, signature rejection, repair, uninstall, and reinstall. It restores the selection captured at the start and records output in `build/live-tests.log`. It never records the administrator password.

## Live acceptance procedure

These tests change AWDL and require the installed helper. Record actual results below; automated tests with a fake interface do not substitute for them.

1. Install the package and verify that the setup app and small Control Center control both query the helper.
2. Turn Off, inspect `ifconfig awdl0`, then use `sudo ifconfig awdl0 up`; verify that the interface promptly returns down.
3. Turn On and verify that it stays available and AirDrop can use it.
4. Close the setup app and repeat the two Control Center actions.
5. Force-stop the helper while Off; verify launchd restarts it and restores the saved setting.
6. Try a client with the same bundle identifier but a different signature; verify the helper rejects it.
7. Sleep/wake, log out/in, and reboot with Off selected. Verify the policy is restored. Reboot testing requires the user's participation.
8. Run Repair and verify the saved choice remains intact.
9. Run Uninstall; verify AWDL is restored and all custom installed components are removed. Reinstall for continued use.

## Current results

- Development host: macOS 27.0 (26A428), Xcode 27.0 (27A266a).
- Universal Release build: passed.
- Local code signatures: passed.
- PlugInKit discovery of `local.vitaly.AWDLToggle.Control`: passed.
- Automated tests: passed (138 monitor/parser checks, 10,000 randomized parser probes, anonymous XPC integration, 5 packaging checks).
- Clang static analysis of the monitor and service: passed without findings.
- Extracted installer validation and modified-client signature rejection: passed.
- Installed helper: running with Off selected.
- Native small Control Center toggle: both directions verified against helper state; On raised the interface and Off lowered it.
- Five independent `ifconfig awdl0 up` attempts while Off: interface was down at every check after a 100 ms delay.
- Helper recovery after SIGKILL: passed; launchd restarted it and restored Off.
- Live rejection of the uninstalled development build: passed.
- Repair preserved Off: passed.
- Uninstall restored AWDL and removed the app, helper, state, and LaunchDaemon: passed.
- Reinstallation after uninstall: passed; final state restored to Off.
- Final package upgrade: installed binary and bundled repair package match the final packaged artifacts; signatures verified.
- Final native-control On action with the setup app quit: passed. Off was restored and confirmed through the signed app's CLI after the screenshot tool timed out.
- Upgrade edge case fixed and checked: the old extension worker is retired before reloading the control with the current signature.
- macOS 26 runtime, logout, sleep/wake, and reboot: not yet tested.

## Naming cleanup

Internal control and extension names now use `AWDLToggle`. Legacy utility migration and rollback handling were removed; fresh installations default to On, and upgrades preserve the saved setting. The live results above precede this cleanup; the installed upgrade check is recorded below.

## Extension launch recovery (2026-09-15)

The renamed extension was registered correctly, but launchd retained its former executable path inside the existing widget host. Logs showed a conflicting extension path followed by a missing-executable spawn failure. Restarting the current user’s `chronod` cleared that entry, and the installed extension launched successfully.

Verified live after recovery: Control Center On changed helper policy and interface state to On; window Refresh showed On; window Off changed both helper state and Control Center to Off. Final helper status: enabled false, interfaceUp false, monitoring true. Automatic updates of an already-open window remain separate from this launch failure.

## Automatic window updates

The setup window subscribes to authenticated XPC status callbacks and no longer has a Refresh button. The helper sends an initial snapshot and changed status after policy writes or route events. Observation disconnects clear the displayed state and trigger reconnect attempts with a delay capped at eight seconds. Closing the window cancels observation without changing policy.

Universal build and automated checks passed, including an external client changing state, callback delivery, connection invalidation, and a fresh snapshot on resubscription. These tests use an anonymous XPC service; live installed synchronization and helper restart checks for this build remain pending installation.

## Uninstall and native placements (2026-09-15)

After the previous uninstaller ran, the app, helper executable, LaunchDaemon, and extension registration were absent, and `awdl0` was up. The extension process was still alive. Stopping that worker and restarting the signed-in user’s `chronod` and `ControlCenter` removed its interactive cached state; macOS retained a disabled placement. Removing that placement through Control Center’s context menu removed the slot.

The updated uninstaller unregisters the app and extension before removing their files, terminates their processes, and reloads the signed-in user’s hosts. It preserves system control preferences; its introduction asks users to remove AWDL placements first and its conclusion explains any remaining disabled slot. The introduction was checked in macOS Installer. Extraction checks verify the bundled uninstaller script and its presentation resources. Full install/uninstall testing of this revision remains pending administrator authentication.

The control’s WidgetKit configuration was unchanged by the live-sync update. The missing “Copy to Menu Bar” command was observed for the leftover control after uninstall; its availability with the app installed still needs a live check. The app and README now explain Apple’s supported Edit Controls → drag-to-menu-bar method.
