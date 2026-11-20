import UIKit

func connectLocalDevVPN() {
    let callbackScheme = ProcessInfo.processInfo.environment["LC_HOME_PATH"] != nil
        ? "livecontainer"
        : "stikdebug"
    guard let url = URL(string: "localdevvpn://enable?scheme=\(callbackScheme)") else { return }
    UIApplication.shared.open(url, options: [:]) { opened in
        if !opened {
            DispatchQueue.main.async {
                UIApplication.shared.open(URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!)
            }
        }
    }
}
