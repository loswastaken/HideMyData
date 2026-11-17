<div align="center">

<img width="180" height="180" alt="HideMyData" src="HideMyData/Assets.xcassets/AppLogo.imageset/logo.png" />

### Local, AI-powered PII redaction for macOS

Built with [OpenMed](https://github.com/maziyarpanahi/openmed), [MLX-Swift](https://github.com/ml-explore/mlx-swift), and Apple Vision

![Swift](https://img.shields.io/badge/Swift-FA7343?style=for-the-badge&logo=swift&logoColor=white)
![Xcode](https://img.shields.io/badge/Xcode-007ACC?style=for-the-badge&logo=Xcode&logoColor=white)
![macOS](https://img.shields.io/badge/mac%20os-000000?style=for-the-badge&logo=apple&logoColor=white)

</div>

## About this fork

This is a fork of [mkbula/HideMyData](https://github.com/mkbula/HideMyData) that fixes PDF redaction that reported success without hiding anything:

- **Rotated pages, shifted page origins and cropped pages** — upstream painted the boxes in the wrong place (or exported content the crop had hidden). Every PDF is now re-drawn into a normalized working copy on open, so what you see is what gets redacted.
- **Protected PDFs** — permission-restricted PDFs silently refused the redaction boxes, and password-locked PDFs exported as blank pages. Restricted PDFs now just work; locked PDFs ask for the password.
- **Scans with a text layer** — every page is now also read with OCR and boxed by where the text is actually drawn, so a hidden text layer that is misplaced, too small, or covers only part of the page no longer leaves data visible.
- **Blur that hides** — blurred regions are reduced to a coarse mosaic before blurring, so they stay unreadable on small pages such as receipts and labels.
- **Manual boxes are kept** — running Detect again no longer removes boxes you drew by hand.
- **Honest status** — a redaction only counts if it is really on the page. Detected items that could not be located, and pages that could not be read, are shown as a warning instead of a green tick.
- **Verified export** — the saved file is reopened and checked (no extractable text, black or blurred where every box should be) before it is put in place. If the check fails, nothing is saved. If detected items could not be located, saving asks for confirmation first.

Known limits: what gets redacted still depends on what the model and the patterns detect, so review the boxes before saving. With "Remove metadata" unticked the document's title, author and subject fields are kept. Detection reads every page twice (text layer and OCR), so it is slower than upstream.
- **No auto-update** — Sparkle is removed so the app cannot update itself back to the upstream build. The app is signed to run locally (bundle id `com.loswastaken.hidemydata`).

## Install

Build from source - see [Build](#build) below. Release downloads on the upstream project do not contain these fixes.

## Features

- **Fully local** — model runs on-device, nothing ever leaves your machine
- **PDF and image input** — both formats share the same detection and redaction pipeline
- **OCR** — Apple Vision handles scanned PDFs, images, and rescues PDFs whose embedded fonts hide text from selection
- **AI detection** — OpenAI `privacy-filter` (MLX 8-bit) catches names, emails, phones, addresses, dates, IDs in context
- **Manually maintained regex** — IBAN, SSN, Personal identifiers, MAC, IPv4/v6, JWT, API keys, crypto wallets and more to come
- **Two redaction styles** — solid black or frosted glass blur
- **Manual editing** — add or remove redaction rectangles by hand before saving
- **Permanent on save** — pages are rasterized and rebuilt - the original text and glyphs are gone, not just hidden

## Requirements

- macOS 26 or later
- Apple Silicon (the MLX backend does not run on Intel)

## Build

```bash
open HideMyData.xcodeproj
# build & run via Xcode (⌘R)
```

Or from the command line (needs Xcode's Metal Toolchain: `xcodebuild -downloadComponent MetalToolchain`):

```bash
xcodebuild -project HideMyData.xcodeproj -scheme HideMyData -configuration Release -derivedDataPath build/DerivedData build
xcodebuild -project HideMyData.xcodeproj -scheme HideMyData -configuration Debug -derivedDataPath build/DerivedData test
```

The project file is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen); run `xcodegen generate` after adding or removing files.

On first launch, you will be prompted to download the model (~1.5 GB) from Hugging Face into `~/Library/Application Support/HideMyData/ModelCache/`.

## Tech Stack

Swift 6, SwiftUI, MLX-Swift, Apple Vision, PDFKit, OpenMedKit

## License

GPL-3.0
