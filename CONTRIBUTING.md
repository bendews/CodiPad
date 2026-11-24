# Contributing to CodiPad

Open a bug report with the steps that reproduce the problem. If an extension installs but its formatter never runs, include the extension ID, its version, and a small file that shows the problem. For a terminal issue, include the command and its output. To run CodiPad on your own hardware, follow the [device build and signing guide](docs/build.md#install-on-an-ipad).

## Find the code

| If you’re changing… | Start here |
| --- | --- |
| Windows, document access, or UIKit controls | [iPad app](app/CodiPad/) |
| An editor command or a call from the workbench into Swift | [iPad workbench overlay](workbench/overlay/src/vs/workbench/ipad-browser/) and [native workbench services](app/CodiPad/Workbench/) |
| The shell, filesystem, or Node.js runtime | [Native modules](native/) and [runtime build scripts](scripts/) |
| Upstream behavior | [Patch sets](patches/) and [source manifests](build/) |

Keep upstream changes small enough to review against the pinned revision. The build reconstructs the upstream trees under `vendor/`. Put persistent edits in the overlay or the relevant patch set. Record new source pins and checksums alongside the existing entries in `build/`.

## Check a change

Run the checks for the part you changed from the repository root. GitHub Actions runs these [source checks](.github/workflows/checks.yml) on pushes and pull requests.

For changes to the build options, run the Python tests.

```sh
python3 -m unittest discover -s tests
```

For workspace filesystem changes, run the Swift tests on macOS.

```sh
swift test --package-path native/CodiPadWorkspace -c release
```

For a patch change, check the series from a fresh checkout.

```sh
python3 scripts/build.py --prepare-sources
```

For a workbench change, prepare the sources as above. On an Apple silicon Mac, bundle the release workbench.

```sh
(cd scripts && python3 -c 'import workbench; workbench.build(minify=True)')
```

For a change to the app, exercise the user action it affects. For example, open a folder from Files, edit and save a file, then read it from the integrated terminal. For an extension fix, repeat the original steps with the published version of the extension.

In your pull request, describe the behavior before and after the change. Include the build command or device checks you ran. For device checks, include the iPad model, iPadOS version, and execution mode.
