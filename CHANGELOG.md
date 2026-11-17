# Fork (unreleased)

* Fix redaction boxes landing in the wrong place on rotated pages and pages with a non-zero page origin.
* Fix cropped-out page content being exposed on export.
* Fix permission-restricted PDFs showing no redactions while reporting success.
* Ask for the password of locked PDFs instead of exporting blank pages.
* OCR every page and place boxes by pixels as well as by the text layer (fixes scans whose hidden text layer is misplaced, undersized or partial).
* Blur style: mosaic before blur so small pages stay unreadable; blurred regions are verified on export.
* Detect no longer removes manually drawn boxes.
* Saving asks for confirmation when detected items could not be located.
* Fix export of very large pages.
* Report detected items that could not be located, and pages that could not be read, as warnings.
* Verify the exported PDF before saving; refuse to save if verification fails.
* Every page is rasterized on export, including pages without redactions.
* Remove Sparkle auto-update; new bundle id `com.loswastaken.hidemydata`; signed to run locally.
* Add a test suite with protected, rotated, cropped and scanned fixtures.

# 0.2.0

## HideMyData is now notarized!

* Integrate Sparkle for automatic updates. 
* `Check for Updates…` menu item in the app menu.
* Switched to xcodegen.
* Allow removing metadata from files when saving.

### ⚠️ Manual cleanup for users on v0.1.0

Because of the notarization and because I changed the app bundle ID, a one-timemanual reinstall is needed.

* If you use Raycast or AppCleaner - you're good, just uninstall there.

Manually:

* Drag the app to trash
* The old sandbox container at `~/Library/Containers/com.maciejonos.HideMyData/` is left behind. To reclaim the disk space:

```bash
rm -rf ~/Library/Containers/com.maciejonos.HideMyData
```

No further bundle ID changes are planned — future versions update in place via Sparkle.

# 0.1.0

* Initial release.
