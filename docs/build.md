# Build and run CodiPad

## Prepare your Mac

Use an Apple silicon Mac with Xcode and its iOS platform support installed. CodiPad targets iPadOS 18.0 and later. The device build has been verified with Xcode 27.2.

Install Python 3.12 or later, Meson, and Ninja. If you use Homebrew, run the following command.

```sh
brew install python meson ninja
```

Start a Linux ARM64 Docker engine to build the Debian filesystem. You can skip Docker for the default app if you already have a compatible ARM64 root filesystem archive and pass it with `--rootfs`. Check your tools before starting the build.

```sh
xcodebuild -version
python3 --version
docker version --format '{{.Server.Os}}/{{.Server.Arch}}'
```

Clone this repository using the URL under GitHub’s **Code** button. Run the commands below from the root of the checkout. The first build downloads the pinned sources and Node.js toolchain. It prepares the upstream sources in `vendor/` and generates the app resources in `app/generated/`. Later builds reuse matching outputs in `.build/`.

## Build the default app

For the public configuration, run the device build with its default options.

```sh
python3 scripts/build.py --sdk iphoneos --configuration Release
```

The script prints `Unsigned app ready` and the path to `CodiPad.app`. This is an unsigned app bundle. Installing a build on your iPad requires signing it for that device. The script stops at the `.app`. If you distribute a signed IPA, archive and export the app separately using the signing method for your distribution channel.

## Install on an iPad

1. Connect your iPad to the Mac and enable Developer Mode on the iPad. In Xcode, sign in with your Apple account and select your development team.
2. Replace `YOUR_TEAM_ID` with your Apple Development Team ID and `com.example.codipad` with a unique bundle identifier.

   ```sh
   python3 scripts/build.py --sdk iphoneos --configuration Release \
     --team YOUR_TEAM_ID --bundle-id com.example.codipad \
     --allow-provisioning-updates
   ```

3. In Xcode, open **Window > Devices and Simulators**. Select the iPad and add the signed app under **Installed Apps**. The Release build writes the app to the following location.

   ```text
   .build/iphoneos/DerivedData/Build/Products/Release-iphoneos/CodiPad.app
   ```

4. Open CodiPad on the iPad. Choose **File > Open Folder…** to grant access to a project, then **Terminal > New Terminal**. Run `node --version` to check the local runtime.

The default **Gadget Only** execution mode works without a debugger. To use StikDebug, select **Runtime > Execution Mode…** and reopen CodiPad. StikDebug requires a build signed for debugging, a paired device, a loopback VPN, and JIT preparation for each new app process.

## Run in the simulator

Install an iPad simulator runtime through Xcode. Start one iPad in Simulator. If you have multiple devices booted, replace `booted` below with the iPad UDID from `xcrun simctl list devices booted`.

```sh
python3 scripts/build.py --sdk iphonesimulator --configuration Release
xcrun simctl install booted .build/iphonesimulator/DerivedData/Build/Products/Release-iphonesimulator/CodiPad.app
```

The Linux filesystem requires case-sensitive storage. If your simulator data is already on a case-sensitive volume, continue to the launch command. On a case-insensitive Mac volume, prepare a case-sensitive disk image **after installing and before the first launch**. Use a fresh simulator installation with an empty Linux directory.

```sh
container=$(xcrun simctl get_app_container booted com.bendews.codipad data) &&
linux_dir="$container/Library/Application Support/CodiPad/Linux" &&
mkdir -p "$linux_dir" &&
hdiutil create -size 8g -type SPARSE -fs 'Case-sensitive APFS' \
  -volname CodiPadLinux .build/codipad-linux.sparseimage &&
hdiutil attach -nobrowse -mountpoint "$linux_dir" .build/codipad-linux.sparseimage
```

Launch CodiPad from the simulator’s Home Screen or from your terminal.

```sh
xcrun simctl launch booted com.bendews.codipad
```

If you mounted the image, quit CodiPad before running `hdiutil detach "$linux_dir"` in the same shell. Keep the image to preserve Linux files and installed packages. For later sessions, get the current data container path again and reattach the existing image before launching the app.

## Build options

| Option | Use |
| --- | --- |
| `--prepare-sources` | Fetch the pinned VS Code, iSH, and libarchive source trees, prepare the VS Code and libarchive patches, then stop. |
| `--build-deps` | Build the native libraries and Linux filesystem for the selected SDK, then stop. Include the agent-host addons when building with extras. |
| `--rootfs PATH` | Supply a prebuilt Linux ARM64 root filesystem as a `.tar.gz`. Building the optional agent host’s SQLite addon from scratch still requires Docker. |
| `--docker-context NAME` | Use a specific Linux ARM64 Docker engine. |
| `--rebuild` | Rebuild generated artifacts for the selected target. |

Run `python3 scripts/build.py --help` for all options. For an Xcode failure, the build prints the log path under `.build/<sdk>/`.

## Configure an extension gallery

The default build supports local VSIX packages and has no extension gallery configured. To install a VSIX, download a compatible package from its publisher, save it in Files, then choose **Extensions: Install from VSIX…** in the Command Palette.

### Build with Microsoft Marketplace

Microsoft’s public policy reserves Visual Studio Marketplace for the Visual Studio family of products. If you have separate authorization from Microsoft to use it in CodiPad, build with the Marketplace flag. [Visual Studio Marketplace policy](https://code.visualstudio.com/docs/supporting/faq#_i-cant-access-the-visual-studio-marketplace-from-product-fill-in-the-blank-why-not)

```sh
python3 scripts/build.py --sdk iphoneos --configuration Release --with-microsoft-marketplace
```

This configures the Extensions view to use Microsoft’s gallery and download hosts. To include Copilot and the signing components in the same authorized build, add `--with-vscode-extras`. Each flag works independently. [Optional VS Code components](#optional-vs-code-components)

### Build with a custom gallery

The build accepts one gallery. Choose either `--extension-gallery FILE` or `--with-microsoft-marketplace`.

If you run a compatible gallery for CodiPad, put its service URL in a local JSON file. For example, save the following as `gallery.json` outside your checkout, replacing the example domain and path with your gallery’s API endpoint.

```json
{
  "serviceUrl": "https://extensions.example.org/_apis/public/gallery"
}
```

Pass the file to the build script.

```sh
python3 scripts/build.py --sdk iphoneos --configuration Release \
  --extension-gallery /path/to/gallery.json
```

You can also supply HTTPS `itemUrl` and `publisherUrl` values for links to extension and publisher pages. Serve the query API and VSIX downloads from the same HTTPS origin, including its port. CodiPad verifies the VSIX against the SHA-256 digest in the gallery response.

## Optional VS Code components

The public source tree contains the build scripts and verification hashes. The default app omits the Microsoft VS Code signing binaries, the packaged Copilot extension, and the local agent host that depends on `@vscode/copilot-api`. The editor, local terminal, and VSIX installation work without these components.

The packaged Copilot extension’s license prohibits distributing it with your app. GitHub limits use of the Copilot API package with Code - OSS to development purposes. Microsoft licenses the VS Code Server for use with Microsoft Visual Studio Code. [Copilot extension license](https://marketplace.visualstudio.com/items/GitHub.copilot-chat/license) · [Copilot API package terms](https://unpkg.com/@vscode/copilot-api@0.5.2/LICENSE) · [VS Code license](https://code.visualstudio.com/license) · [VS Code Server license](https://code.visualstudio.com/license/server)

If you have separate permission to use these components in CodiPad, use the build script to download and set them up locally.

```sh
python3 scripts/build.py --sdk iphoneos --configuration Release --with-vscode-extras
```

The script checks the pinned archives against their SHA-256 digests and stages the selected components in `app/generated/`. To download and verify the archives ahead of the build, run the prefetch script.

```sh
python3 scripts/vscode_extras.py
```

Prefetching saves the archives to `.build/cache/vscode-extras/`. To include them in the app, use the build command above. Git ignores both the cache and the generated files. If you already have the pinned archives elsewhere, pass `--vscode-darwin-archive PATH` and `--vscode-linux-archive PATH` to the build command.

To return to the default app, omit the extras flag, archive paths, and gallery options from the build command.

The permission to use these components locally and the permission to distribute them in an IPA are separate. Publishing a build with extras requires redistribution rights for the bundled components. Copilot services also require account access.

## Prepare a binary release

Build from the release tag in a clean checkout using a workspace path suitable for public disclosure. The app embeds `BuildReceipt.json`, which records the source revision, local build paths, and the signing team when supplied.

Inspect the receipt inside the device app you plan to package.

```sh
app=.build/iphoneos/DerivedData/Build/Products/Release-iphoneos/CodiPad.app
python3 - "$app/BuildReceipt.json" <<'PYTHON'
import json
import sys

with open(sys.argv[1]) as receipt_file:
    receipt = json.load(receipt_file)
print("Source revision:", receipt["source"]["revision"])
print("Uncommitted build inputs:", receipt["source"]["dirty"])
print("VS Code extras:", receipt["vscodeExtras"])
print("Microsoft Marketplace:", receipt["workbench"]["microsoftMarketplace"])
print("Extension gallery:", receipt["workbench"]["extensionGallery"])
PYTHON
```

Compare the source revision with `git rev-parse HEAD` in the tagged checkout. A clean default build prints `False` for uncommitted inputs and both optional features, and `None` for the gallery. Publish the matching source tag with the binary and include the corresponding source and license notices required by the bundled components. [CodiPad license](../LICENSE) · [Third-party notices](../README.md#credits-and-licenses)
