# StikDebug Location

A reduced StikDebug build for simulating this iPhone's location through an external loopback VPN. Requires iOS 17.4 or later.

## Setup

1. Install and enable LocalDevVPN on the iPhone.
2. Obtain this iPhone's Remote Pairing file using a computer; see [PAIRING.md](PAIRING.md).
3. Open Settings in the app and import the pairing file.
4. Tap Connect. Allow local network access. The app downloads and mounts the Developer Disk Image (DDI); internet access is required for the first download. If needed, tap Download and Mount DDI to retry.
5. Close Settings, select a point on the map and start simulation. Clear the simulation before changing connection settings.

The map retains place search, coordinate entry/import (GPX, KML, GeoJSON, JSON, CSV and text), bookmarks and route playback. Route planning and road speed lookup require internet access. Background audio/location keep-alive options remain in Settings. A denied location permission falls back to audio.

The VPN is a separate app. StikDebug uses it to reach iOS developer services; it does not include a VPN provider. Pairing-file generation inside the app, JIT, scripts, app/process management, profiles and the console have been removed. Old JIT/process/location URL actions and Shortcuts are not supported by this reduced build.

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

Follow [AGENTS.md](AGENTS.md). Pull request and issue descriptions must be human-written. AI translation of those descriptions must be disclosed.

## License

AGPL-3.0; see [LICENSE](LICENSE).
