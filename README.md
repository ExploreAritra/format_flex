# 🎬 Format Flex

**Format Flex** is a universal video converter built with Flutter and powered by FFmpeg.  
It enables seamless video transcoding on Android (and other platforms) with support for hardware acceleration, foreground services, progress notifications, and direct saving into public media folders like `/Movies/FormatFlex`.

---

## ✨ Features

- **Containers:** MP4, MKV, WebM
- **Video codecs:** H.264/AVC, H.265/HEVC, VP9, AV1
- **Audio codecs:** AAC, AC-3 (Dolby Digital), E-AC-3 (Dolby Digital Plus), Opus, MP3
- **Resolution presets:** 2160p/4K, 1080p, 720p, 480p
- **Audio controls:** bitrate (96–768 kbps), channels (Stereo 2.0 / 5.1), sample rate (44.1/48 kHz)
- **Turbo Mode:** HW-accelerated encoding (Mediacodec/VideoToolbox), stream-copy when possible, ultra-fast presets
- **HDR → SDR tone-mapping:** Optional; CPU-intensive
- **Foreground service with notifications:** Live progress in the status bar; keeps work alive
- **Scoped storage integration:** Save to `/Movies/FormatFlex` by default (Android), or any folder you choose
- **Cross-platform:** Android (primary), iOS/macOS (limited codecs via VideoToolbox)

---

## 📦 Dependencies

- [`ffmpeg_kit_flutter_new`](https://pub.dev/packages/ffmpeg_kit_flutter_new)
- [`flutter_foreground_task`](https://pub.dev/packages/flutter_foreground_task) (^9.1.0)
- [`media_store_plus`](https://pub.dev/packages/media_store_plus)
- [`file_picker`](https://pub.dev/packages/file_picker)
- [`wakelock_plus`](https://pub.dev/packages/wakelock_plus)
- [`path_provider`](https://pub.dev/packages/path_provider)
- [`path`](https://pub.dev/packages/path)

---

## 🗂️ Project Structure

```
lib/
└── main.dart                # App entrypoint, UI, Foreground task handler, services
android/
└── app/src/main/AndroidManifest.xml
ios/
└── Runner/Info.plist
```

---

## 🚀 Getting Started

### Prerequisites
- Flutter SDK (3.x or newer)
- Android Studio or VS Code
- Android 8.0+ device recommended

### Install & Run
```bash
flutter pub get
flutter run
```

---

## ⚙️ Android Setup

### Required permissions (Android 13+ and legacy fallbacks)

Add the following to `android/app/src/main/AndroidManifest.xml` (top level, outside `<application>`):

```xml
<!-- Android 13+ scoped media read permissions -->
<uses-permission android:name="android.permission.READ_MEDIA_VIDEO" />
<uses-permission android:name="android.permission.READ_MEDIA_AUDIO" />
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />

<!-- Legacy fallbacks for older devices -->
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32" />
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="29" />

<!-- Foreground service + subtype to be explicit -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />

<!-- Keep CPU running during conversion -->
<uses-permission android:name="android.permission.WAKE_LOCK" />

<!-- Android 13+ notifications permission -->
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
```

Inside `<application>`:

```xml
<application
    android:name="${applicationName}"
    android:label="Format Flex"
    android:icon="@mipmap/ic_launcher"
    android:requestLegacyExternalStorage="true">

    <activity
        android:name=".MainActivity"
        android:exported="true"
        android:launchMode="singleTop"
        android:taskAffinity=""
        android:theme="@style/LaunchTheme"
        android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
        android:hardwareAccelerated="true"
        android:windowSoftInputMode="adjustResize">
        <meta-data
            android:name="io.flutter.embedding.android.NormalTheme"
            android:resource="@style/NormalTheme" />
        <intent-filter>
            <action android:name="android.intent.action.MAIN" />
            <category android:name="android.intent.category.LAUNCHER" />
        </intent-filter>
    </activity>

    <meta-data
        android:name="flutterEmbedding"
        android:value="2" />
</application>

<!-- Optional: intent query for PROCESS_TEXT (used by Flutter engine) -->
<queries>
    <intent>
        <action android:name="android.intent.action.PROCESS_TEXT" />
        <data android:mimeType="text/plain" />
    </intent>
</queries>
```

🔔 **Notes:**
- On first run, the app requests notification permission (Android 13+).
- On Android 12+, it prompts to ignore battery optimizations so your conversion can keep running.

---

## 🍏 iOS Setup

Add to `ios/Runner/Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>processing</string>
    <string>fetch</string>
    <string>audio</string>
</array>

<key>NSPhotoLibraryAddUsageDescription</key>
<string>Format Flex needs access to save converted videos.</string>

<!-- Optional, if you later add local notifications -->
<key>NSUserNotificationUsageDescription</key>
<string>Format Flex shows progress notifications for conversions.</string>
```

⚠️ iOS cannot run a true “Android-style” foreground service; long-running work is best kept with the app active or split into smaller tasks. VideoToolbox hardware encoders are used where available.

---

## 🖥️ Usage

1. Pick a video using the **Pick Video** button.
2. Choose an output folder (defaults to `/Movies/FormatFlex` on Android).
3. Select container, video/audio codecs, resolution, and audio options.
4. Optionally enable **Turbo Mode** for fastest possible conversion.
5. Tap **Convert**.
6. Track progress both in-app and via notification (Android).

**Default Output Folder (Android):**  
Previewed as `/storage/emulated/0/Movies/FormatFlex`.  
Files are written via **MediaStore** to the public Movies/FormatFlex directory, even on scoped storage devices.

---

## 🔧 Implementation Notes

### Foreground Service (flutter_foreground_task v9.1.0)
- The app initializes the service with `ForegroundTaskEventAction.repeat(...)` so the handler’s `onRepeatEvent` runs on schedule.
- Progress text is updated by calling:

```dart
FlutterForegroundTask.updateService(
  notificationTitle: 'Converting video…',
  notificationText: 'Progress 42%',
);
```

- Call `FlutterForegroundTask.startService(...)` before kicking off FFmpeg, and `stopService()` when done.

### FFmpegKit
- Uses hardware decoding/encoding when enabled (mediacodec on Android, VideoToolbox on Apple platforms).
- Attempts **stream copy** when the input already matches target codec/format and no scaling/tone-mapping/FPS changes are needed.
- Optional **HDR → SDR tone-mapping pipeline** (`zscale + tonemap`) for maximum device compatibility.

---

## 🧪 Example FFmpeg Commands

**Convert to MP4 H.264 + AAC (1080p):**
```bash
ffmpeg -i input.mkv -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p -c:a aac -b:a 192k -ac 2 -ar 48000 output.mp4
```

**Turbo mode (copy when possible):**
```bash
ffmpeg -i input.mkv -c:v copy -c:a copy output.mp4
```

**HEVC 4K archive (AC-3 5.1):**
```bash
ffmpeg -i input.mp4 -c:v libx265 -preset slow -crf 22 -pix_fmt yuv420p -c:a ac3 -b:a 448k -ac 6 output.mkv
```

---

## 🧰 Troubleshooting

### ❌ No notifications appear (Android)
- Ensure you granted notifications on Android 13+ (enable in system settings if denied).
- Verify `AndroidNotificationOptions` are set in `FlutterForegroundTask.init(...)`.
- Start the service before conversion: `FlutterForegroundTask.startService(...)`.
- Allow **Ignore battery optimizations** when prompted (OEM background kill policies).

### ❌ Files don’t show up in the target folder
- On Android, saving to public folders uses **MediaStore**; final file should appear in `/Movies/FormatFlex`.
- If a custom folder isn’t writable, the app falls back to `/Movies/FormatFlex` and informs you.

### ❌ Conversion is very slow
- Enable **Turbo Mode** and/or **Use hardware encoder**.
- Avoid HDR→SDR tone-mapping unless necessary (CPU-heavy).
- Choose **H.264** for universal playback and faster encoding.

### ❌ No audio / no surround on the TV
- For widest 5.1 support over HDMI ARC/optical, use **AC-3 (Dolby Digital)**.
- AAC 5.1 is technically possible, but many TVs/soundbars won’t decode it properly and may downmix to stereo.
- E-AC-3 offers better efficiency and Atmos (DD+ JOC), but file playback support varies by device.

---

## 🧭 Roadmap

- [ ] Batch conversion
- [ ] Custom FFmpeg command builder
- [ ] iOS/macOS: Save to Photos library
- [ ] Built-in player & preview
- [ ] Cloud export (Drive/Dropbox/etc.)

---

## 🤝 Contributing

PRs are welcome! Please:
1. Fork the repo
2. Create a feature branch
3. Commit with clear messages
4. Open a pull request

---

## 🛡️ License

This project is licensed under the **MIT License**.

---

## 🙏 Acknowledgements

- [FFmpeg](https://ffmpeg.org/) & [ffmpeg-kit](https://github.com/tanersener/ffmpeg-kit)
- [flutter_foreground_task](https://pub.dev/packages/flutter_foreground_task)
- [media_store_plus](https://pub.dev/packages/media_store_plus)
- The Flutter community 💙  
