<picture>
  <source media="(prefers-color-scheme: dark)" srcset="design/kinesis-links-dark.svg">
  <img src="design/kinesis-links.svg" width="80" alt="kinesis">
</picture>

# kinesis

This fork adds an experimental **fingers** page for personal EMG baselines: rest and five finger presses, three training rounds, and a separate test round. It stores a local profile and reports confusion and uncertainty before offering a visual recognition preview. See [finger calibration](docs/finger-calibration.md). Build this fork with `./scripts/build.sh --local`; the upstream download linked below does not include this feature.

use your meta neural band to control your mac




https://github.com/user-attachments/assets/43ed6094-5c66-4992-aacd-e010dae3f4fa





swipe between desktops, open mission control, control your music, and pinch + turn for volume or brightness. pick your own mappings, practice in setup, then keep it in the menu bar.

this extended build adds custom keyboard shortcuts, configurable Dictation, a saved ChatGPT/dot conversation destination, a separate **Send in ChatGPT** action, connection-stall recovery, and fixes for air-mouse gesture switching. [usage and configuration](docs/usage.md).

the Axo edition uses Axo Neurotech's teal, sage and snow palette, original Axo mark, and matching light/dark controls and sensor highlights. the app keeps its Kinesis name and menu-bar mark. branding is bundled locally; the interface does not load assets from the web.

built on some tinkering i did with astra in [neural-band-poc](https://github.com/callbacked/neural-band-poc) (feel free to go through that repo to do your own thing), so naturally i wanted to harness it to make it do something useful

some things may act quirky or not work at all, if that is the case i would love to know why, but this is all highly experimental

## run it
needs macos 14+ and a neural band. the packaged local build is for Apple Silicon; source can also be built for Intel. preserve an existing working pairing when updating the app. resetting or forgetting a band changes its pairing and is not an update step.

**hackathon download:** [Kinesis 0.5.0 build 6.28 for Apple Silicon](https://github.com/Axo-Neurotech/Kinesis-Axo/releases/download/v0.5.0-axo.6.28/Kinesis-0.5.0-build6.28-arm64-local.zip), including the live sensor stream. unzip it, move Kinesis.app into Applications, and open it; developer tools are not required. read the [participant setup guide](docs/hackathon-setup.md) for permissions, Meta sign-in, band pairing, and connecting your code to EMG, gyro, and gestures. [release assets and checksums](https://github.com/Axo-Neurotech/Kinesis-Axo/releases/tag/v0.5.0-axo.6.28).

this experimental build is ad-hoc signed and not Apple-notarized; macOS may require manual approval on first launch. this repository and its published releases are public; participants can download the app without a GitHub account or invitation.

local app and source archives are produced with the commands below. the [original upstream releases](https://github.com/callbacked/kinesis/releases/latest) are maintained by callbacked.

set your assigned band in pairing mode, hit pair band, and sign in with meta once. allow Bluetooth and accept the pairing request from macOS. Accessibility approval is needed for Mac keyboard/mouse controls; it is not needed to read the live sensor API. enable controls when you want gestures to control the Mac.

## why the meta sign-in

the band only works with an owner that meta has enrolled. the meta ai app does that enrollment when you set up a band, and kinesis does the same enrollment for your mac. it opens meta's own sign-in page once and keeps the session token in your keychain. it only gets that token, not your password. once the band is enrolled, connecting doesn't need meta. forget this band clears the key and the sign-in.

## build it

swift 6 and macOS developer tools. for a local build on this Mac, Command Line Tools are sufficient:

```sh
./scripts/build.sh --local
```

this builds for the current Mac and signs locally without requesting a signing identity. it writes `dist/Kinesis.app` and does not replace the installed app. macOS may require fresh Bluetooth, Accessibility or Keychain approval for a locally rebuilt app. the dot conversation link, gesture assignments, band pairing and account session are runtime settings and are not included in the source or app archives.

for a universal Apple Silicon + Intel build, use full Xcode with Swift 6:

```sh
git clone https://github.com/Axo-Neurotech/Kinesis-Axo.git
cd Kinesis-Axo
./scripts/build.sh
open dist/Kinesis.app
```

quit a copy running from `dist/` before rebuilding it. add `--dev` to either build command to include developer tools.

## live sensor stream

Build 6.28 includes a **stream** tab with an opt-in, read-only sensor API for Python and local browser projects. It sends raw eight-channel EMG, gyro, orientation, and decoded gesture messages directly from the existing band connection as timestamped JSON over Server-Sent Events. Open **stream**, enable **local sensor feed**, then select **copy stream URL**. Your project does not pair with the band separately. The feed starts off each time Kinesis opens, and a new link is generated when it starts.

The release includes [sensor-stream-examples.zip](https://github.com/Axo-Neurotech/Kinesis-Axo/releases/download/v0.5.0-axo.6.28/sensor-stream-examples.zip), containing a Python reader that uses only the standard library and the API guide. See the [participant setup](docs/hackathon-setup.md#read-the-live-sensor-stream) for a quick check or the [live sensor API guide](docs/sensor-stream.md) for the schema and browser example.

## experimental iPhone controller

The [Mac-assisted iPhone controller](docs/iphone-controller.md) forwards band gestures through USB to a physical ESP32 Bluetooth keyboard/mouse adapter paired to the iPhone. Scrolling and ChatGPT dictation start/stop/send have been checked on a handset; the Mac must remain awake and connected. Build the adapter firmware with `./scripts/build-phone-bridge.sh`; this compiles without writing to a board. The [adapter setup](firmware/axo-phone-bridge/README.md) describes the supported hardware and pairing. This is separate from the local sensor API; a standalone iPhone companion is not implemented.

## package a local build

```sh
./scripts/package-local.sh
```

this packages the already-built app and an allowlisted source archive under `dist/release-local/`, with release information and verified SHA-256 checksums. it does not rebuild, re-sign, read account settings, or change the installed app. generated archives stay outside the source commit; attach them as GitHub Release assets when publishing. the local app is ad-hoc signed and not notarized. public notarized distribution requires your own Developer ID signing and Apple notarization; see [release instructions](docs/usage.md#release-files).

## license

source code: [mit](LICENSE), retaining the upstream copyright notice. bundled assets retain their own notices in `Sources/Kinesis/Resources/`: the hand mesh has an MIT notice; the Meta/Gizmodo band image and Axo brand marks are separate from Kinesis's MIT license.
