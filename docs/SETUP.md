# ViSense – one-time Mac setup (do this first)

This Mac is Apple Silicon (arm64). Status when the project was created: **Xcode 27.2 is
installed and selected** (step 1 done, including the iOS platform). Still missing:
**Apple ID in Xcode (step 2), Homebrew + XcodeGen (step 3), Arduino IDE (step 5)**.

---

## 1. Install Xcode (≈ 1 h, ~15 GB incl. iOS platform)

1. Open the **App Store** → search **Xcode** → **Get / Install** (sign in with your Apple ID).
   (Alternative: https://developer.apple.com/download/all → latest Xcode `.xip`.)
2. When it finishes, **open Xcode once**. It asks to install components → tick **iOS** platform → Install.
   (If you skipped it: Xcode → Settings → Components → iOS → Get.)
3. Point the command-line tools at the full Xcode (right now they point at the slim
   Command Line Tools, which can't build iOS apps). In Terminal:

   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```

   ```bash
   sudo xcodebuild -license accept
   ```

   ```bash
   xcodebuild -version
   ```

## 2. Add your (free) Apple ID to Xcode

Xcode → **Settings… → Accounts** → **+** → **Apple ID** → sign in.
You'll get a team called **"Your Name (Personal Team)"**. Click it and note the **Team ID**
(10 characters, also visible later in Xcode → target → Signing & Capabilities).

## 3. Install Homebrew + XcodeGen

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

At the end the installer prints **"Next steps"** with two `echo … >> ~/.zprofile` / `eval …` lines —
copy-paste and run them (they put `brew` on your PATH). Then:

```bash
brew install xcodegen
```

## 4. "Starting the project" in this folder

You do **not** use Xcode's *File → New Project* wizard. The project is described in
`ios/project.yml` and XcodeGen generates `ios/ViSense.xcodeproj` from it (so the project file
never gets merge-conflicted or corrupted — regenerate any time):

```bash
cd "/Users/adityan/Documents/Project Visense/ios" && xcodegen generate && open ViSense.xcodeproj
```

Signing for a free Apple ID → see the main `README.md` section "iOS: signing & installing".

## 5. Arduino IDE for the firmware

1. Download **Arduino IDE 2.x** for macOS (Apple Silicon) from https://www.arduino.cc/en/software
   and drag it to Applications.
2. Arduino IDE → Settings → **Additional boards manager URLs**:
   `https://espressif.github.io/arduino-esp32/package_esp32_index.json`
3. Tools → Board → Boards Manager → search **esp32** → install **"esp32 by Espressif Systems" 3.x**.
4. Tools → Manage Libraries → install **NimBLE-Arduino** (by h2zero, **2.x**) and **U8g2** (by olikraus).
5. Board: **Tools → Board → esp32 → XIAO_ESP32C3**. Also set **Tools → USB CDC On Boot → Enabled**
   (otherwise Serial Monitor shows nothing).

## 6. iPhone prep

- Plug the iPhone into the Mac, unlock it, tap **Trust**.
- iPhone: **Settings → Privacy & Security → Developer Mode → On** (reboots). The switch only
  appears after the phone has been connected to Xcode once.
