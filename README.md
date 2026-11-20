# StikDebug Location

A reduced StikDebug build for simulating a paired iPhone's location. Control another iPhone over a reachable local-network Remote Pairing endpoint, or control this iPhone through an external loopback VPN. Requires iOS 17.4 or later.

## Control another iPhone

1. On the target iPhone, enable Developer Mode, complete its restart/confirmation, and unlock it.
2. Generate a **Remote Pairing file for the target iPhone** using a computer; see [PAIRING.md](PAIRING.md). Transfer the exported file privately to the controller iPhone and import it in StikDebug Settings. A pairing file from the controller or an ordinary lockdown pairing record will not work.
3. Connect both phones to the same Wi-Fi network, allowing local network access for StikDebug. The target must expose a reachable Remote Pairing service; Developer Mode alone does not guarantee this. Networks with client isolation or a VPN that blocks LAN access will prevent connection.
4. In Settings, enable **Connect to Another iPhone** and enter the target's IPv4 address (from its Wi-Fi network details). Tap **Connect**. Port discovery accepts only advertisements resolving to that address. If discovery is unavailable, enter the target's actual Remote Pairing port; an empty field falls back to 49152, which may not be the target's port.
5. Wait for **DDI mounted**. The app reads the target's iOS version, checks whether a DDI is already mounted, and downloads and mounts the matching image only if needed. The controller needs internet access for missing assets and any required personalization. A preparation error appears in Settings; use **Download and Mount DDI** to retry.
6. Close Settings, select a map point and tap **Simulate Location**, or play a route. Check the location in an app on the target iPhone. **Stop** clears the simulation on that target. Stop before changing the target or pairing file.

The app does not generate pairing files or enable Developer Mode on another phone. It requires the target owner's prior pairing and a reachable developer service. USB iPhone-to-iPhone transport and arbitrary internet connections are not implemented. LocalDevVPN on the controller is only used for the same-device mode below; it does not make another phone reachable.

## Control this iPhone

1. Install and enable LocalDevVPN on the iPhone.
2. Obtain this iPhone's Remote Pairing file using a computer; see [PAIRING.md](PAIRING.md).
3. In Settings, turn off **Connect to Another iPhone** and import this iPhone's pairing file.
4. Tap **Connect** and wait for **DDI mounted**. If preparation fails, use **Download and Mount DDI** to retry.
5. Close Settings, select a map point and start simulation. Stop before changing connection settings.

The map retains place search, coordinate entry/import (GPX, KML, GeoJSON, JSON, CSV and text), bookmarks and route playback. Route planning and road speed lookup require internet access. Background audio/location keep-alive options remain in Settings. A denied location permission falls back to audio.

The loopback VPN is a separate app used for same-device connections. StikDebug uses Remote Pairing to reach iOS developer services; it does not include a VPN provider. Pairing-file generation inside the app, JIT, scripts, app/process management, profiles and the console have been removed. Old JIT/process/location URL actions and Shortcuts are not supported by this reduced build.

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

Read and understand the complete diff. Personally build the app and inspect the results, then test on an iPhone: pairing import, VPN connect/reconnect, DDI mount, set/change/clear location, background operation, route playback and coordinate import. Check the simulated location in another app and verify that Clear restores the real location. Also test denied permissions, an invalid pairing file and a disconnected VPN.

For two-phone operation, personally test:

- A target with an already mounted DDI and no cached local DDI assets: connect without an unnecessary download.
- An unmounted target with no cached assets: automatic download, mount confirmation, then set/change/clear coordinates on the target.
- Controller and target on different iOS releases, including opposite sides of the iOS 26.4 DDI format change: select assets from the target version.
- Multiple nearby iPhones advertising Remote Pairing: only use the configured target's port; also test a manual port.
- Invalid IP/port, the wrong phone's pairing file, locked target, Developer Mode off, denied local-network permission, target disconnect, and offline/failed DDI downloads. Simulation must stay disabled if preparation fails.
- Changing draft connection fields without tapping Connect: commands still use the connected target. While preparing DDI, sending a location command, or simulating, connection changes must be blocked. Stop and reconnect to a second target; no coordinates should be sent to the previous target.

These checks require Xcode on macOS and physical iPhones. Source checks alone do not establish that the two-phone flow works on a particular iOS/network combination.

Follow [AGENTS.md](AGENTS.md). Pull request and issue descriptions must be human-written. AI translation of those descriptions must be disclosed.

## License

AGPL-3.0; see [LICENSE](LICENSE).
