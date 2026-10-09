# Sundog

Sundog is a macOS app for wireless iPhone screen mirroring through AirPlay.

Sundog shows your iPhone in a floating window above all other windows, including full-screen slides.

Sundog works in the EU. It does not require Apple's iPhone Mirroring app.
It only shows the iPhone screen. You control the iPhone by hand.
You install Sundog on the Mac. No iPhone app is required.

[Get Sundog for €4.99 once](https://getsundog.eu/) · [Watch the demo](https://getsundog.eu/demo)

The purchase provides the Mac app as a ZIP download. There is no subscription.
The source code is available here under GPL-3.0.

## Use

1. Connect the iPhone and the Mac to the same Wi-Fi network.
2. Open Sundog.
3. On the iPhone, open Control Center.
4. Tap **Screen Mirroring**.
5. Select **Sundog**.

## Build

Sundog runs on macOS 14 or later.

To build it, install Apple's [Command Line Tools for Xcode](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools) with Swift 6 or later. The full Xcode app also includes these tools.

```sh
./scripts/build-app.sh
open build/Sundog.app
```

## License

GPL-3.0. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

The GPL does not cover the Sundog name, the logo, or the app icon. They are not in this repository, so a build from source uses the default macOS icon.
