# AWDL Toggle

A small native macOS Control Center switch for Apple Wireless Direct Link (AWDL).

## Everyday use

- **AWDL On / highlighted:** allow AWDL for AirDrop and Continuity. macOS manages the interface normally.
- **AWDL Off:** immediately lower `awdl0` and keep it down until you turn AWDL on again.
- Your choice survives closing the app, logging out, restarting the helper, and restarting your Mac.
- There is no Game Mode, foreground-app detection, network-type switching, or permanent app menu bar icon.

The selected state is the **policy**, not a claim that AWDL has an active peer connection. Off can make AirDrop and other features that use AWDL unavailable.

> AWDL Toggle efficiently automates keeping the `awdl0` interface down by monitoring network route changes and immediately bringing the interface back down if some other system component tries to bring it back up.

## Requirements

- macOS 26 or later.
- Administrator authentication to install, repair, or uninstall the helper.
- This is a local, ad-hoc-signed build for your own Mac. No Apple Developer membership is needed. It is not a notarized distribution for other users.

## Build and install

Requires Xcode 26 or later and Python 3 for project generation and packaging.

```sh
Scripts/build.sh
Scripts/test.sh
python3 Scripts/package.py
python3 Scripts/verify-package.py
open dist/AWDL-Toggle.pkg
```

Complete macOS Installer's administrator authentication. The package installs **AWDL Toggle.app** in Applications and its persistent helper. If macOS presents an approval for the background item, allow it in **System Settings → General → Login Items & Extensions**.

Then open **Control Center → Edit Controls**, search for **AWDL**, add the control, and select its small circular size. macOS owns the control's Liquid Glass appearance, sizing, placement, and refresh lifecycle.

You can close the setup app. The helper, rather than the app or widget process, maintains the setting.

Fresh installations default to On. Upgrades and repairs preserve AWDL Toggle's saved setting. Disable any other AWDL-management utility before using this app.

## Status, repair, and uninstall

Open **AWDL Toggle** from Applications to see the selected policy, helper status, and any enforcement error. A control read fails instead of inventing an On/Off value when the helper or interface is unavailable.

- **Repair…** opens the bundled repair installer. It reinstalls the helper and refreshes the allowed client signatures while preserving the setting.
- **Uninstall…** opens the bundled uninstaller. It unloads the helper, restores AWDL, and removes the custom app, helper, state, and launchd plist.
- The same uninstaller is available as `dist/AWDL-Toggle-Uninstall.pkg`.

Use the uninstaller rather than only dragging the app to Trash: this local installation uses a persistent system LaunchDaemon.

If the saved state is corrupt, Repair preserves it as `state.invalid.<timestamp>.plist` and resets AWDL to On so the app can recover. Valid settings are retained.

After rebuilding, reinstall the **full** installer. The privileged helper deliberately rejects old or uninstalled builds whose signatures are not in its administrator-owned allowlist.

### Control stays out of sync after an upgrade

If the native control changes appearance but the window's **Refresh** and CLI still show the old setting, the widget extension may have failed to launch. After an extension filename change, macOS can retain its previous executable path in the widget host. Restarting that host clears the stale entry:

```sh
pkill -u "$(id -u)" -x chronod
```

macOS automatically relaunches the host; other widgets may briefly reload too. Reopen Control Center and verify a toggle against the window's **Refresh** or CLI status. The open window currently refreshes on activation or manually; it does not subscribe to changes from other controls.

### Command-line diagnostics

The installed app's executable also supports these commands without opening a window:

```sh
'/Applications/AWDL Toggle.app/Contents/MacOS/AWDL Toggle' --status
'/Applications/AWDL Toggle.app/Contents/MacOS/AWDL Toggle' --on
'/Applications/AWDL Toggle.app/Contents/MacOS/AWDL Toggle' --off
```

Commands use the same authenticated XPC service as the native control. `--status` prints the saved policy, monitor health, and current interface flag as JSON. If the interface is not present yet, `interfaceUp` is `null`.

## How it works

The Objective-C helper uses `AF_ROUTE` + `SIOCSIFFLAGS`. A serial dispatch queue handles route events, commands, and persistence. It sleeps between events rather than polling periodically. It preserves unrelated interface flags, tolerates interface absence during boot, validates route-message lengths, and restarts through launchd if its route source fails.

Turning On raises the interface once, then releases normal interface management to macOS. Turning Off saves the policy and applies it immediately, then re-applies it on interface changes. When the interface is missing, the saved choice is applied when it appears. An orderly helper unload restores the interface; the saved policy still applies on the next start.

The SwiftUI control extension uses `ControlWidgetToggle`, `ControlValueProvider`, and a Boolean `SetValueIntent`. It has one narrowly scoped sandbox exception for the helper's Mach service. Its requests return only after the helper has persisted and attempted the change. Neither UI stores a second copy of the policy.

The local installer writes the final app and extension's code-signature hashes to a root-owned allowlist. The helper checks incoming clients against those signatures. Its only remote operations are read status and set AWDL policy. It does not execute commands, accept paths, or expose arbitrary network interfaces.

### Installed components

| Component | Location |
|---|---|
| App and control | `/Applications/AWDL Toggle.app` |
| Helper | `/Library/PrivilegedHelperTools/local.vitaly.AWDLToggle.Helper` |
| LaunchDaemon | `/Library/LaunchDaemons/local.vitaly.AWDLToggle.Helper.plist` |
| Root-owned state and client allowlist | `/Library/Application Support/AWDL Toggle` |

## Verification and provenance

See [validation notes](Documentation/VALIDATION.md) for tested behavior and outstanding live checks.

The event-driven monitoring implementation is adapted from [James Howard’s AWDLControl](https://github.com/james-howard/AWDLControl) revision `e54f7922ee5eebb3729e8ad76fd0440a3b3650d9`, under the [MIT license](LICENSE.txt).
