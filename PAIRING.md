# Pairing Your Device

StikDebug requires a specialized **pairing file** to communicate with your device remotely. This file is specific to the iPhone whose location you want to simulate and is required to use StikDebug. When controlling another iPhone, generate the Lockdown file for iOS 16 or Remote Pairing file for iOS 17.4 or later for that target, export it to a file, and transfer it privately to the controller iPhone. Without it, StikDebug will not work.

> [!WARNING]
> Because of iOS/iPadOS limitations, resetting or changing your device's passcode will invalidate its pairing file. You will need to generate and place a new one.
>
> Keep your pairing file private. It contains connection credentials for your device. Do not share it publicly or attach it to bug reports.

## Computer pairing

This method uses [iloader](https://iloader.app) on a computer to generate the pairing file. You will need a computer and a USB cable.

### Prerequisites

#### Mac

1. Download and install [iloader for Mac](https://github.com/nab138/iloader/releases/latest/download/iloader-darwin-universal.dmg).

#### Windows

1. Download and install [iTunes](https://apple.co/ms).
2. Download the iloader installer: [MSI (recommended)](https://github.com/nab138/iloader/releases/latest/download/iloader-windows-x64.msi) or [EXE](https://github.com/nab138/iloader/releases/latest/download/iloader-windows-x64.exe).
3. Run the installer.

#### Linux

1. Install `usbmuxd` using your package manager if it is not already installed.
2. Download and install iloader for your distribution: [Debian/Ubuntu](https://github.com/nab138/iloader/releases/latest/download/iloader-linux-amd64.deb), [Fedora/openSUSE](https://github.com/nab138/iloader/releases/latest/download/iloader-linux-x86_64.rpm), or [AppImage for other distributions](https://github.com/nab138/iloader/releases/latest/download/iloader-linux-amd64.AppImage).

### Exporting the remote iPhone's pairing file

1. Connect the **remote iPhone** to the computer, unlock it, and trust the computer if prompted.
2. Use the pairing tool to export that iPhone's **Lockdown** record for iOS 16, or **Remote Pairing** record for iOS 17.4 or later. For an iOS 16 target, also enable Wi-Fi syncing on the computer so its Lockdown services are reachable over the local network.
3. Transfer the exported file privately to the controller iPhone.
4. Open StikDebug's **Remote iPhone** settings. Enter the remote iPhone's Wi-Fi IPv4 address, then tap **Import Pairing File** and select the exported file.
5. Review the address and file, then tap **Connect to Remote iPhone**. Importing a file does not connect automatically.

The file must match the remote iPhone, not the controller. The app detects the plist format locally, but cannot validate pairing credentials against the remote phone until you explicitly connect. The absence of public_key in a Lockdown record is expected; do not add fabricated Remote Pairing fields. A TCP connection reset is a transport failure, not proof of a rejected pairing record. If the remote phone explicitly rejects authentication, check that its address and exported file refer to the same phone.
