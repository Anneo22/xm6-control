<h1><a href="https://abcastor.com"><img src="docs/readme-mark.svg" width="40" height="40" align="absmiddle" alt=""></a> <img src="docs/readme-title.svg" width="212" align="absmiddle" alt="XM6 Control*"></h1>

XM6 Control is a native macOS app for controlling Sony WH-1000XM6 headphones over Bluetooth. This personal fork of [Rui Martins's app](https://github.com/ruimartins23/xm6-control) adds confirmed quality controls, local commands, and automatic release of the control connection.

[![Checks](https://github.com/Anneo22/xm6-control/actions/workflows/checks.yml/badge.svg?branch=main)](https://github.com/Anneo22/xm6-control/actions/workflows/checks.yml)

<p><img src="docs/screenshot.png" alt="XM6 Control dashboard with noise control, listening mode and equalizer" width="450"></p>

## Build and run

You need macOS 13 or later, Xcode Command Line Tools, and a WH-1000XM6 paired in System Settings. Full Xcode is not required. Liquid Glass styling is available on macOS 26; earlier versions use the fallback appearance.

```sh
git clone https://github.com/Anneo22/xm6-control.git
cd xm6-control
./Scripts/build_app.sh
```

The script builds and signs a double-clickable app, then prints its launch command. Rebuilds keep the previous bundle and use a fresh output directory. Copy the new app to `/Applications` for the local commands below. Allow Bluetooth access on first launch. Ad-hoc signing can prompt again after a rebuild; a code-signing certificate named `XM6Dev` gives builds a stable identity. Set `XM6_SIGN_IDENTITY` to use a different certificate.

## Controls

The window, menu bar panel, and floating widget offer noise cancelling, ambient level and voice focus, listening modes, a ten-band equalizer, battery status, multipoint device selection, Speak-to-Chat, wearing detection, and automatic power-off. The app supports light and dark appearance and an optional menu-bar-only mode.

**Release the headphones when I'm not using the app** is enabled by default. Closing the window, panel, and widget releases the control connection after 20 seconds without a command, allowing Sony Sound Connect to take over. A visible widget keeps the controls connected. Audio stays connected. You can disable idle release in the app.

### Bluetooth quality

Quality and stable-connection writes were confirmed on XM6 firmware 3.1.5. Low latency was advertised but its writes were ignored, so it is read only. A mode changes on screen only after the headset reports it; a change can briefly interrupt audio.

The quality preference does not identify or force the negotiated audio codec. It cannot add LDAC or LE Audio support to macOS. Other firmware may behave differently, and the software tests cannot prove headset acceptance.

### Local commands

With the app installed in `/Applications`:

```sh
./Scripts/xm6control status
./Scripts/xm6control quality quality
./Scripts/xm6control quality stable
```

The helper shares the app's controller and Bluetooth permission. It launches the app with its window hidden if necessary. Connecting and reading do not apply noise-control startup defaults.

JSON includes `quality`, `qualityObservedAt`, and `confirmed`. Confirmation requires a fresh headset report, including after a write. `supportedQualityModes` lists advertised modes; `writableQualityModes` lists the choices the app can change. Other fields under `cachedState` are last-reported values and are not refreshed independently by a status request.

Failures exit nonzero. An unconfirmed write may have changed the headset: read status before retrying. Requests use a private directory owned by the current user, are serialized, and expose only `status` and `quality`. No network listener or automatic quality switching is installed.

## Troubleshooting

- If the headset is not found, pair it in System Settings and connect it for audio before trying again.
- The headphones accept one control connection at a time. Close Sony Sound Connect before connecting this app. To return control to the phone, close all app surfaces and wait for idle release.
- If audio works but controls cannot connect, disconnect and reconnect the headphones from the Bluetooth menu. macOS sometimes establishes audio without publishing the control service.
- If a card says state was not reported, that query received no answer. Debug logging in the main window records protocol frames under the app's Application Support folder. Review logs for device information before sharing them.

## Development

```sh
swift test
./Scripts/check_syntax.sh
python3 Scripts/check_leaks.py
```

`SonyHeadphonesKit` handles the framed Sony MDR protocol and IOBluetooth transport. `XM6Control` supplies the SwiftUI app and local command bridge. `XM6Probe` is a developer tool for raw protocol investigations; it can send headset commands, so use it only when you understand the payload.

The protocol work draws on [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge), [SonyHeadphonesClient](https://github.com/Plutoberth/SonyHeadphonesClient), and the [mos9527 fork](https://github.com/mos9527/SonyHeadphonesClient). This project is independent of Sony; Sony and its product names remain their respective trademarks.

## Licence

Upstream code remains under [Rui Martins's MIT licence](LICENSE), with its full notice retained. Original additions owned by Anneo22 are available under [Apache 2.0](LICENSE-APACHE); [NOTICE.md](NOTICE.md) defines that boundary. This is not a blanket relicensing of the upstream app. The outlined title uses Literata under its [SIL Open Font Licence](docs/Literata-OFL.txt).

<p><a href="https://abcastor.com"><img src="docs/castor-footer.svg" width="350" alt="Chip, the Castor beaver, by Castor, we give a dam"></a></p>
