<div align="center">

<img src="docs/icon.png" width="128" alt="PicViewer icon">

# PicViewer

**A tiny picture viewer for your Mac that browses in the same order as Finder.**

Open a picture, then flip through its folder with the arrow keys. Rotate without losing quality, trash what you don't want, and nothing else.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-native-F05138?logo=swift&logoColor=white)
![Liquid Glass](https://img.shields.io/badge/Liquid%20Glass-macOS%2026-8E8EF0)

</div>

## Why this exists

Preview doesn't step through the pictures in a folder: it only knows the files you opened together. Other viewers can browse a folder, but they sort it their own way, which is never how Finder sorts it. PicViewer follows Finder: sort the folder by name, date or size and the pictures go by in that same order.

## What it does

- **Finder's order.** Whatever the folder is sorted by in Finder, PicViewer goes through it the same way. Change the sort, switch back, and the new order is used.
- **Lossless rotation.** ⌘R and ⇧⌘R turn the picture and save it to the file straight away. The pixels are never re-encoded, only the orientation flag changes. It works for JPEG, HEIC, TIFF, DNG and RAW files (Fujifilm RAF, Canon CR2, Nikon NEF and more).
- **Quick clean-up.** ⌘⌫ moves the picture to the Trash, and ⌘Z puts it back.
- **Info sidebar.** ⌘I shows the camera, lens, exposure, EV, location on a map and more.
- **Out of the way.** The on-screen arrows show up only when you move the mouse. Double-click for full screen.

## Install

```sh
sh scripts/build-app.sh --install   # builds PicViewer.app and copies it to /Applications
```

To make PicViewer your default viewer: in Finder, select a picture, choose Get Info (⌘I), pick PicViewer under **Open with** and click **Change All…**. Do it once for each file type (JPG, RAF, HEIC and so on).

The first time you open a picture, macOS asks whether PicViewer may **control Finder**. Click Allow, because that's how it reads the folder's sort order. You can change this later in System Settings → Privacy & Security → Automation.

### Stop the permission prompts after every rebuild

macOS remembers folder permissions per code signature. Without a developer account the app gets a throwaway (ad-hoc) signature that changes with every build, so macOS treats each build as a new app and asks again. Create a local signing certificate once and every build gets the same signature:

1. Open **Keychain Access** and choose Keychain Access → Certificate Assistant → **Create a Certificate…**
2. Name it `PicViewer Local`, set Identity Type to **Self-Signed Root** and Certificate Type to **Code Signing**, then click Create.
3. Double-click the new certificate, open **Trust** and set Code Signing to **Always Trust**.
4. Rebuild with `sh scripts/build-app.sh --install`. It says `Signed with "PicViewer Local"`. Allow the folder access one last time.

## Shortcuts

| Key | Action |
| --- | --- |
| ← / → | Previous / next picture |
| ⌘R / ⇧⌘R | Rotate clockwise / counter-clockwise |
| ⌘⌫ | Move to Trash (⌘Z puts it back) |
| ⌘I | Show or hide the info sidebar |
| ⌃⌘F or double-click | Full screen |
| ⌥⌘R | Show in Finder |
| ⌘O | Open a picture or folder |

## How it works

**Folder order.** PicViewer first asks Finder about the folder's open window: the list view's sort column and direction, the icon view's Sort By, or the icon positions read row by row. If that doesn't work, it reads the view settings saved in the folder's `.DS_Store`, then Finder's default view settings, and finally sorts by name. The info sidebar shows which one was used (Details → Order).

**Lossless rotation.** Only the orientation flag changes: the EXIF orientation tags, XMP `tiff:Orientation` and the HEIF `irot` box are overwritten in place. Usually 1 to 3 bytes change and the file size stays the same. After writing, the file is read back to check the result, and if anything doesn't match, the original bytes go back. PNG files have no orientation flag, so they're re-written only if the decoded pixels come out bit-for-bit identical. If there's no lossless way, the rotation is refused and the file isn't touched.

## Limitations

- Finder's Group By is ignored; only the sort inside the view is used.
- Column and gallery views use the saved settings, not the live window.
- Mirrored HEIC orientations can't be rotated in place, so they're refused.
- Without the `PicViewer Local` certificate, macOS asks for permissions again after every rebuild.

## For developers

PicViewer is a native AppKit and SwiftUI app with no dependencies. `PicViewerCore` holds the folder order, the `.DS_Store` reader, lossless rotation and metadata; the app target holds the window and views.

```sh
swift test                 # run the tests
sh scripts/build-app.sh    # build/PicViewer.app
sh scripts/make-icon.sh    # re-render the icon (Resources/AppIcon.icns, docs/icon.png)
```

Set `PICVIEWER_SAMPLES` to a folder of real camera files to also run the rotation tests on them.
