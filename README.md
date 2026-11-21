# StikDebug Location

A reduced StikDebug build for simulating a paired iPhone's location. Control another iPhone over a reachable local-network Remote Pairing endpoint. Same-device simulation and loopback VPN connections are no longer supported. The controller app requires iOS 17.4 or later. Targets may use iOS 16 through Lockdown, or iOS 17.4 or later through Remote Pairing.

## Control another iPhone

1. On the target iPhone, enable Developer Mode, complete its restart/confirmation, and unlock it.
2. Generate a **pairing file for the target iPhone** (Lockdown for iOS 16, Remote Pairing for iOS 17.4 or later) using a computer; see [PAIRING.md](PAIRING.md). Transfer the exported file privately to the controller iPhone and import it in StikDebug Settings. The record must be for the target. Its format is detected automatically; do not edit or rename fields to convert between formats.
3. Connect both phones to the same Wi-Fi network, allowing local network access for StikDebug. For iOS 16, first enable Wi-Fi syncing for the paired target using a computer, and ensure Lockdown on TCP port 62078 and its developer services are reachable. For iOS 17.4 or later, the target must expose a reachable Remote Pairing service; Developer Mode alone does not guarantee this. Networks with client isolation or a VPN that blocks LAN access will prevent connection.
4. In the **Remote iPhone** settings, enter the target's IPv4 address (from its Wi-Fi network details). Tap **Connect to Remote iPhone**. iOS 16 uses Lockdown directly on port 62078; the Remote Pairing port option is hidden for its file format. For Remote Pairing, port discovery accepts only advertisements resolving to that address. If discovery is unavailable, enter the target's actual Remote Pairing port; an empty field falls back to 49152, which may not be the target's port.
5. Wait for **DDI mounted**. The app reads and displays the target's model and iOS version independently of the controller, checks whether a DDI is already mounted, and downloads and mounts the matching image only if needed. The controller needs internet access for missing assets and any required personalization. A preparation error appears in Settings; use **Retry Developer Disk Setup** to retry.
6. Close Settings, select a map point and tap **Simulate Location**, or play a route. Check the location in an app on the target iPhone. **Stop** clears the simulation on that target. Stop before changing the target or pairing file.

The app does not generate pairing files or enable Developer Mode on another phone. It requires the target owner's prior pairing and a reachable developer service. USB iPhone-to-iPhone transport and arbitrary internet connections are not implemented. The controller's own addresses and the old VPN address are rejected before opening a tunnel. Opening the app, importing a file, or returning from the background does not connect or download DDI assets automatically. Press Connect to Remote iPhone after reviewing the target address and selected file.

The map retains place search, coordinate entry/import (GPX, KML, GeoJSON, JSON, CSV and text), bookmarks and route playback. Route planning and road speed lookup require internet access. Optional background audio keep-alive remains in the advanced settings. The app does not request the controller's location for background operation.

StikDebug uses Lockdown for iOS 16 and Remote Pairing for newer supported targets to reach the remote iPhone's developer services. Pairing-file generation inside the app, JIT, scripts, app/process management, profiles and the console have been removed. Old JIT/process/location URL actions and Shortcuts are not supported by this reduced build.

## Build an IPA on GitHub

Push the repository to GitHub, then run **Actions → Build Location IPA → Run workflow**, or push a commit. Download StikDebug.ipa from the completed run's artifacts. The workflow produces an **unsigned** arm64 IPA; sign it with your sideloading tool before installing.

The project uses the Xcode 27 project format. The workflow uses the xcode-27 runner with Xcode 27.2, Release configuration and no third-party Swift packages. It only builds and uploads the IPA; no release publishing or website credentials are needed.

For local builds on a Mac, open StikDebug.xcodeproj in Xcode 27.2 or later, choose the StikDebug scheme, configure your signing team and run on an iPhone.

## What remains

- Map UI, route/import support and location simulation session.
- Pairing-file import/storage, Remote Pairing discovery, tunnel diagnostics and DDI download/mount support.
- Background keep-alive, original app icon and existing translations for retained strings.
- idevice C header, module map and static library. The prebuilt library is required; its internals have not been modified.

## Verification before submitting

Read and understand the complete diff. Personally build the app and inspect the results, then test on an iPhone: remote pairing import, explicit connect/reconnect, DDI mount, set/change/clear location, background operation, route playback and coordinate import. Check the simulated location in another app and verify that Clear restores the real location. Also test denied permissions, an invalid pairing file and an unreachable remote iPhone.

Run the connection regression checks on macOS before building:

```sh
MACOSX_DEPLOYMENT_TARGET=14.0 swiftc -parse-as-library StikDebug/Device/DeviceConnectionContext.swift StikDebug/Services/ConnectionDiagnostics.swift StikDebug/Support/PairingFileFormat.swift StikDebug/Device/LegacyImageMounterSession.swift Tests/RemoteConnectionTests.swift -o /tmp/stik-remote-tests
/tmp/stik-remote-tests
```

For two-phone operation, personally test:

- On iOS 16, check and mount DDI both when already mounted and when absent. The image mounter must be followed by a Lockdown query; keep that session alive through the operation and close the mounter first. Retry after a service disconnect. A query/EOF failure must keep simulation disabled and must not trigger an upload based on an assumed unmounted state.
- An iOS 16 iPhone X target controlled from a newer iPhone: import its Lockdown plist, authenticate over Wi-Fi, display its real model/iOS, download the versioned DMG/signature if needed, and set/change/clear coordinates. Test clearing again after a failed update or lost socket.
- Copy an error before a successful connection: remote details must be marked unknown; every controller detail must be labeled as controller data.
- A target with an already mounted DDI and no cached local DDI assets: connect without an unnecessary download.
- An unmounted target with no cached assets: automatic download, mount confirmation, then set/change/clear coordinates on the target.
- Controller and target on different iOS releases, including opposite sides of the iOS 26.4 DDI format change: select assets from the target version.
- Multiple nearby iPhones advertising Remote Pairing: only use the configured target's port; also test a manual port.
- First launch and migration from saved 10.7.0.1: no automatic connection or download; importing a remote pairing file does not connect. Self-addresses and loopback addresses must be rejected.
- A TCP reset must appear as Connection interrupted, preserving the file; explicit PairVerifyFailed must remain a pairing rejection.
- Invalid IP/port, the wrong phone's pairing file, locked target, Developer Mode off, denied local-network permission, target disconnect, and offline/failed DDI downloads. Simulation must stay disabled if preparation fails.
- Changing draft connection fields without tapping Connect: commands still use the connected target. While preparing DDI, sending a location command, or simulating, connection changes must be blocked. Stop and reconnect to a second target; no coordinates should be sent to the previous target.

These checks require Xcode on macOS and physical iPhones. Source checks alone do not establish that the two-phone flow works on a particular iOS/network combination.

Follow [AGENTS.md](AGENTS.md).

## License

test
