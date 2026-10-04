# Sundog

Demo your iPhone on your Mac.

Sundog shows your iPhone in a floating window above all other windows, including full-screen slides.

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
