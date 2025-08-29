// Universal Video Converter — Turbo + real output folder + MediaStore + Foreground Service
//
// Updates in this version:
// • Fix Android 14+ FGS crash: pass serviceTypes to startService/restartService
// • Robust FFmpeg run result (no more "code null"): ConvertResult with tail log
// • HW→SW fallback when MediaCodec fails, with clear UI/notification messages
// • Keep UI disabled while converting/retrying; progress updates on both attempts

import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import 'package:ffmpeg_kit_flutter_new/stream_information.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:media_store_plus/media_store_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();

  // Ask notification permission early (Android 13+).
  if (Platform.isAndroid) {
    await FlutterForegroundTask.requestNotificationPermission();
  }

  // Create a fresh channel with proper importance BEFORE runApp.
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'formatflex_channel',
      channelName: 'FormatFlex Conversion',
      channelDescription: 'Video conversion running',
      channelImportance: NotificationChannelImportance.HIGH,
      priority: NotificationPriority.HIGH,
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(1000),
      autoRunOnBoot: false,
      autoRunOnMyPackageReplaced: false,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );

  runApp(WithForegroundTask(child: const ConverterApp()));
}

// =============================================================
// Foreground task handler (very small)
// =============================================================

class _ConvTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onReceiveData(Object data) {}

  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'stop') {
      FlutterForegroundTask.stopService();
    }
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp("/");
  }

  @override
  void onNotificationDismissed() {}
}

// =============================================================
// App Shell
// =============================================================
class ConverterApp extends StatelessWidget {
  const ConverterApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Universal Video Converter',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.redAccent),
      home: const ConverterHome(),
    );
  }
}

// =============================================================
// Models
// =============================================================

enum ContainerFmt { mp4, mkv, webm }

extension ContainerFmtX on ContainerFmt {
  String get label => switch (this) {
    ContainerFmt.mp4 => 'MP4',
    ContainerFmt.mkv => 'MKV',
    ContainerFmt.webm => 'WebM',
  };
  String get ext => switch (this) {
    ContainerFmt.mp4 => 'mp4',
    ContainerFmt.mkv => 'mkv',
    ContainerFmt.webm => 'webm',
  };
}

enum VCodec { h264, hevc, vp9, av1 }

extension VCodecX on VCodec {
  String get ffmpegName => switch (this) {
    VCodec.h264 => 'libx264',
    VCodec.hevc => 'libx265',
    VCodec.vp9 => 'libvpx-vp9',
    VCodec.av1 => 'libaom-av1',
  };
  String get label => switch (this) {
    VCodec.h264 => 'H.264 (AVC)',
    VCodec.hevc => 'H.265 (HEVC)',
    VCodec.vp9 => 'VP9',
    VCodec.av1 => 'AV1',
  };
}

enum ACodec { aac, ac3, eac3, opus, mp3 }

extension ACodecX on ACodec {
  String get ffmpegName => switch (this) {
    ACodec.aac => 'aac',
    ACodec.ac3 => 'ac3',
    ACodec.eac3 => 'eac3',
    ACodec.opus => 'libopus',
    ACodec.mp3 => 'libmp3lame',
  };
  String get label => switch (this) {
    ACodec.aac => 'AAC',
    ACodec.ac3 => 'AC-3',
    ACodec.eac3 => 'E-AC-3',
    ACodec.opus => 'Opus',
    ACodec.mp3 => 'MP3',
  };
}

class Resolution {
  final int w;
  final int h;
  final String label;
  const Resolution(this.w, this.h, this.label);
}

const res4k = Resolution(3840, 2160, '2160p (4K)');
const res1080 = Resolution(1920, 1080, '1080p (FHD)');
const res720 = Resolution(1280, 720, '720p (HD)');
const res480 = Resolution(854, 480, '480p (SD)');
const kResList = [res4k, res1080, res720, res480];

class Preset {
  final String name;
  final ContainerFmt container;
  final VCodec vCodec;
  final ACodec aCodec;
  final Resolution resolution;
  final bool twoPass;
  final bool useCrf;
  final int crf;
  final int vBitrateK;
  final int aBitrateK;
  final int audioChannels;
  final int sampleRate;
  final double? fps;
  final bool toneMapHdrToSdr;

  const Preset({
    required this.name,
    required this.container,
    required this.vCodec,
    required this.aCodec,
    required this.resolution,
    this.twoPass = false,
    this.useCrf = true,
    this.crf = 20,
    this.vBitrateK = 4000,
    this.aBitrateK = 192,
    this.audioChannels = 2,
    this.sampleRate = 48000,
    this.fps,
    this.toneMapHdrToSdr = true,
  });
}

const kPresets = [
  Preset(
    name: 'Projector Safe (1080p H.264 + AAC 2.0)',
    container: ContainerFmt.mp4,
    vCodec: VCodec.h264,
    aCodec: ACodec.aac,
    resolution: res1080,
    useCrf: true,
    crf: 20,
    twoPass: false,
    aBitrateK: 192,
    audioChannels: 2,
  ),
  Preset(
    name: 'Smart TV Legacy (1080p H.264 + AC-3 5.1)',
    container: ContainerFmt.mp4,
    vCodec: VCodec.h264,
    aCodec: ACodec.ac3,
    resolution: res1080,
    useCrf: true,
    crf: 19,
    twoPass: false,
    aBitrateK: 448,
    audioChannels: 6,
  ),
  Preset(
    name: 'Streaming-Optimized (720p H.264 + AAC)',
    container: ContainerFmt.mp4,
    vCodec: VCodec.h264,
    aCodec: ACodec.aac,
    resolution: res720,
    useCrf: true,
    crf: 22,
    twoPass: false,
    aBitrateK: 160,
    audioChannels: 2,
  ),
  Preset(
    name: 'Space Saver (1080p HEVC + AAC)',
    container: ContainerFmt.mkv,
    vCodec: VCodec.hevc,
    aCodec: ACodec.aac,
    resolution: res1080,
    useCrf: true,
    crf: 24,
    twoPass: false,
    aBitrateK: 160,
    audioChannels: 2,
  ),
  Preset(
    name: '4K Archive (2160p HEVC + AC-3 5.1)',
    container: ContainerFmt.mkv,
    vCodec: VCodec.hevc,
    aCodec: ACodec.ac3,
    resolution: res4k,
    useCrf: true,
    crf: 22,
    twoPass: false,
    aBitrateK: 448,
    audioChannels: 6,
  ),
  Preset(
    name: 'Web (1080p VP9 + Opus)',
    container: ContainerFmt.webm,
    vCodec: VCodec.vp9,
    aCodec: ACodec.opus,
    resolution: res1080,
    useCrf: false,
    vBitrateK: 4500,
    twoPass: true,
    aBitrateK: 160,
    audioChannels: 2,
  ),
  Preset(
    name: 'Next-Gen (1080p AV1 + Opus)',
    container: ContainerFmt.mkv,
    vCodec: VCodec.av1,
    aCodec: ACodec.opus,
    resolution: res1080,
    useCrf: true,
    crf: 28,
    twoPass: false,
    aBitrateK: 160,
    audioChannels: 2,
  ),
];

class ConvertOptions {
  String input = '';
  String output = '';

  // The user's chosen final folder (display path only on Android; writing uses MediaStore)
  String? outputDir;
  String outputFileName = '';

  // Track selection and mixing
  int videoStream = 0; // usually 0
  int? audioStream; // null = auto
  bool allowDownmix = true;

  // Speed+compat toggle mirroring desktop build
  bool turbo = false;

  Preset preset = kPresets.first;

  ContainerFmt container = ContainerFmt.mp4;
  VCodec vcodec = VCodec.h264;
  ACodec acodec = ACodec.aac;
  Resolution resolution = res1080;
  bool twoPass = false;
  bool useCrf = true;
  int crf = 20;
  int vBitrateK = 4000;
  int aBitrateK = 192;
  int audioChannels = 2;
  int sampleRate = 48000;
  double? fps;
  bool toneMapHdrToSdr = true;

  bool useHwEncoder = false;

  void applyPreset(Preset p) {
    preset = p;
    container = p.container;
    vcodec = p.vCodec;
    acodec = p.aCodec;
    resolution = p.resolution;
    twoPass = p.twoPass;
    useCrf = p.useCrf;
    crf = p.crf;
    vBitrateK = p.vBitrateK;
    aBitrateK = p.aBitrateK;
    audioChannels = p.audioChannels;
    sampleRate = p.sampleRate;
    fps = p.fps;
    toneMapHdrToSdr = p.toneMapHdrToSdr;
  }

  String computedOutputPath() {
    if (outputDir == null || outputDir!.isEmpty) return output;
    if (outputFileName.isEmpty) return output;
    return p.join(outputDir!, outputFileName);
  }
}

// =============================================================
// Services
// =============================================================

class MediaProbeResult {
  final int? durationMs;
  final bool hasHdr;
  final int? width;
  final int? height;
  final String? vCodecName;
  final String? pixFmt;
  final String? aCodecName;
  final int? aChannels;
  final int? aSampleRate;
  MediaProbeResult({required this.durationMs, required this.hasHdr, this.width, this.height, this.vCodecName, this.pixFmt, this.aCodecName, this.aChannels, this.aSampleRate});
}

class ConvertResult {
  final bool ok;
  final bool cancelled;
  final int? returnCode;
  final String tailLog;
  ConvertResult({required this.ok, required this.cancelled, required this.returnCode, required this.tailLog});
}

class LogBuffer {
  static final LogBuffer I = LogBuffer();
  final List<String> _lines = [];
  void add(String? s) {
    final line = s ?? '';
    _lines.add(line);
    if (_lines.length > 800) _lines.removeAt(0);
  }

  void clear() => _lines.clear();
  String dump() => _lines.join('\n');
}

class FfmpegService {
  Future<MediaProbeResult> probe(String inputPath) async {
    final probe = await FFprobeKit.getMediaInformation(inputPath);
    final info = probe.getMediaInformation();
    if (info == null) return MediaProbeResult(durationMs: null, hasHdr: false);

    int? durationMs;
    final d = double.tryParse(info.getDuration() ?? '');
    if (d != null) durationMs = (d * 1000).round();

    final streams = info.getStreams();

    String? str(StreamInformation s, String key) {
      try {
        final v = s.getStringProperty(key);
        if (v != null) return v;
      } catch (_) {}
      try {
        final n = s.getNumberProperty(key);
        return n?.toString();
      } catch (_) {}
      return null;
    }

    int? _int(StreamInformation s, String key) {
      final sv = str(s, key);
      if (sv != null && sv.isNotEmpty) {
        final i = int.tryParse(sv);
        if (i != null) return i;
        final f = double.tryParse(sv);
        if (f != null) return f.round();
      }
      try {
        final n = s.getNumberProperty(key);
        return n?.toInt();
      } catch (_) {
        return null;
      }
    }

    bool hasHdr = false;
    int? w, h, aCh, aSr;
    String? vCodec, aCodec, pix;

    for (final s in streams) {
      final type = (s.getType() ?? '').toLowerCase();
      if (type == 'video') {
        w ??= _int(s, 'width');
        h ??= _int(s, 'height');
        vCodec ??= s.getCodec();
        pix ??= str(s, 'pix_fmt');
        final ct = (str(s, 'color_transfer') ?? str(s, 'color_transfer_name') ?? '').toLowerCase();
        final cp = (str(s, 'color_primaries') ?? str(s, 'color_primaries_name') ?? '').toLowerCase();
        if (ct.contains('smpte2084') || ct.contains('pq') || ct.contains('hlg') || cp.contains('bt2020')) hasHdr = true;
      } else if (type == 'audio') {
        aCodec ??= s.getCodec();
        aCh ??= _int(s, 'channels');
        aSr ??= _int(s, 'sample_rate');
      }
    }

    return MediaProbeResult(durationMs: durationMs, hasHdr: hasHdr, width: w, height: h, vCodecName: vCodec, pixFmt: pix, aCodecName: aCodec, aChannels: aCh, aSampleRate: aSr);
  }

  String buildCommand({
    required String input,
    required String output,
    required MediaProbeResult probe,
    required ConvertOptions o,
    bool forceSoftwareDecode = false,
    bool forceSoftwareEncode = false,
  }) {
    final bool turbo = o.turbo;
    final bool toneMap = turbo ? false : (o.toneMapHdrToSdr && probe.hasHdr);

    final bool knowSize = (probe.width != null && probe.height != null);
    final bool needsScale = knowSize ? (probe.width! > o.resolution.w || probe.height! > o.resolution.h) : false;
    final VCodec effV = turbo ? VCodec.h264 : o.vcodec;

    bool sameCodec =
        (effV == VCodec.h264 && (probe.vCodecName ?? '').toLowerCase().contains('h264')) ||
        (effV == VCodec.hevc && (probe.vCodecName ?? '').toLowerCase().contains('hevc')) ||
        (effV == VCodec.vp9 && (probe.vCodecName ?? '').toLowerCase().contains('vp9')) ||
        (effV == VCodec.av1 && (probe.vCodecName ?? '').toLowerCase().contains('av1'));

    final bool pixOk = (probe.pixFmt == null) || probe.pixFmt!.contains('yuv420');
    final bool canCopyVideo = !toneMap && !needsScale && (turbo ? true : (o.fps == null)) && sameCodec && pixOk;

    bool sameAudio =
        (o.acodec == ACodec.aac && (probe.aCodecName ?? '').toLowerCase() == 'aac') ||
        (o.acodec == ACodec.ac3 && (probe.aCodecName ?? '').toLowerCase() == 'ac3') ||
        (o.acodec == ACodec.eac3 && (probe.aCodecName ?? '').toLowerCase() == 'eac3') ||
        (o.acodec == ACodec.opus && (probe.aCodecName ?? '').toLowerCase() == 'opus') ||
        (o.acodec == ACodec.mp3 && (probe.aCodecName ?? '').toLowerCase() == 'mp3');

    final bool canCopyAudio = sameAudio && (probe.aChannels == null || probe.aChannels == o.audioChannels) && (probe.aSampleRate == null || probe.aSampleRate == o.sampleRate);

    final List<String> vfParts = [];
    if (toneMap) {
      vfParts.add('zscale=t=linear:npl=100,format=gbrpf32le,tonemap=hable,zscale=p=bt709:t=bt709:m=bt709,format=yuv420p');
    }
    if (needsScale) {
      vfParts.add('scale=w=${o.resolution.w}:h=${o.resolution.h}:force_original_aspect_ratio=decrease');
    }
    final String? vfChain = vfParts.isEmpty ? null : vfParts.join(',');

    // ---- Decode side (preInput) ----
    final preInput = <String>[];
    if (Platform.isAndroid && !forceSoftwareDecode) {
      String? inDec;
      final vName = (probe.vCodecName ?? '').toLowerCase();
      if (vName.contains('hevc')) {
        inDec = 'hevc_mediacodec';
      } else if (vName.contains('h264') || vName.contains('avc')) {
        inDec = 'h264_mediacodec';
      } else if (vName.contains('vp9')) {
        inDec = 'vp9_mediacodec';
      } else if (vName.contains('av1')) {
        inDec = 'av1_mediacodec';
      }
      if (inDec != null) {
        preInput.addAll(['-hwaccel', 'mediacodec', '-c:v', inDec, '-hwaccel_output_format', 'yuv420p']);
      }
    }

    // ---- Encode side ----
    String vEnc;
    if (forceSoftwareEncode) {
      vEnc = effV.ffmpegName; // libx264/libx265/libvpx-vp9/libaom-av1
    } else {
      vEnc = (o.useHwEncoder || turbo)
          ? (Platform.isAndroid
                ? (effV == VCodec.h264
                      ? 'h264_mediacodec'
                      : effV == VCodec.hevc
                      ? 'hevc_mediacodec'
                      : effV.ffmpegName)
                : (Platform.isIOS || Platform.isMacOS)
                ? (effV == VCodec.h264
                      ? 'h264_videotoolbox'
                      : effV == VCodec.hevc
                      ? 'hevc_videotoolbox'
                      : effV.ffmpegName)
                : effV.ffmpegName)
          : effV.ffmpegName;
    }

    final vArgs = <String>[];
    if (canCopyVideo) {
      vArgs.addAll(['-c:v', 'copy']);
    } else {
      vArgs.addAll(['-c:v', vEnc]);
      if (vEnc.contains('mediacodec') || vEnc.contains('videotoolbox')) {
        final vb = turbo ? (o.vBitrateK > 0 ? o.vBitrateK : 4000) : o.vBitrateK;
        vArgs.addAll(['-b:v', '${vb}k', '-pix_fmt', 'yuv420p']);
        if (vEnc.contains('videotoolbox')) vArgs.addAll(['-allow_sw', '1']);
        if (vEnc.contains('mediacodec')) vArgs.addAll(['-g', '240']);
      } else {
        switch (effV) {
          case VCodec.h264:
            vArgs.addAll(['-preset', turbo ? 'superfast' : 'veryfast', '-profile:v', 'high', '-pix_fmt', 'yuv420p']);
            if (o.useCrf) {
              vArgs.addAll(['-crf', '${o.crf}']);
            } else {
              vArgs.addAll(['-b:v', '${o.vBitrateK}k']);
            }
            break;
          case VCodec.hevc:
            vArgs.addAll(['-preset', turbo ? 'ultrafast' : 'fast', '-pix_fmt', 'yuv420p', '-tag:v', 'hvc1']);
            if (o.useCrf) {
              vArgs.addAll(['-crf', '${o.crf}']);
            } else {
              vArgs.addAll(['-b:v', '${o.vBitrateK}k']);
            }
            break;
          case VCodec.vp9:
            vArgs.addAll([
              '-deadline',
              turbo ? 'realtime' : 'good',
              '-cpu-used',
              turbo ? '8' : '2',
              '-row-mt',
              '1',
              '-tile-columns',
              '2',
              '-b:v',
              '${o.vBitrateK}k',
              '-pix_fmt',
              'yuv420p',
            ]);
            break;
          case VCodec.av1:
            vArgs.addAll(['-cpu-used', turbo ? '10' : '8', '-pix_fmt', 'yuv420p']);
            if (o.useCrf) {
              vArgs.addAll(['-crf', '${o.crf}', '-b:v', '0']);
            } else {
              vArgs.addAll(['-b:v', '${o.vBitrateK}k']);
            }
            break;
        }
      }
    }

    final aArgs = <String>[];
    int targetChannels = o.audioChannels;
    if (!o.allowDownmix && (probe.aChannels != null) && (targetChannels < probe.aChannels!)) {
      targetChannels = probe.aChannels!; // keep original, no downmix
    }
    if (canCopyAudio) {
      aArgs.addAll(['-c:a', 'copy']);
    } else {
      aArgs.addAll(['-c:a', o.acodec.ffmpegName, '-b:a', '${o.aBitrateK}k', '-ac', '$targetChannels', '-ar', '${o.sampleRate}']);
    }

    // Explicit stream mapping (if user set)
    final mapArgs = <String>[];
    if (o.videoStream >= 0) {
      mapArgs.addAll(['-map', '0:v:${o.videoStream}']);
    }
    if (o.audioStream != null) {
      mapArgs.addAll(['-map', '0:a:${o.audioStream}']);
    }

    final fpsArgs = (turbo ? <String>[] : (o.fps != null ? ['-r', o.fps!.toString()] : <String>[]));
    final movFlags = (o.container == ContainerFmt.mp4) ? ['-movflags', '+faststart'] : <String>[];

    final args = <String>[
      '-y',
      '-hide_banner',
      '-threads',
      '0',
      if (vfChain != null) ...['-sws_flags', 'fast_bilinear'],
      ...preInput,
      '-i',
      '"$input"',
      ...mapArgs,
      if (vfChain != null) ...['-vf', '"$vfChain"'],
      ...fpsArgs,
      ...vArgs,
      ...aArgs,
      ...movFlags,
      '"$output"',
    ];
    return args.join(' ');
  }

  // onProgress now forwards rawSec + speedX + frame
  Future<ConvertResult> convert({required String cmd, required void Function(double rawSec, {double? speedX, int? frame}) onProgress, void Function(int id)? onSession}) async {
    final List<String> tail = [];
    FFmpegKitConfig.enableLogCallback((log) {
      final line = log.getMessage();
      tail.add(line);
      if (tail.length > 400) tail.removeAt(0);
    });

    FFmpegKitConfig.enableStatisticsCallback((Statistics s) {
      final rawMs = s.getTime();
      final rawSec = rawMs <= 0 ? 0.0 : rawMs / 1000.0;
      final double speedX = s.getSpeed();
      final int frame = s.getVideoFrameNumber();
      onProgress(rawSec, speedX: speedX, frame: frame);
    });

    final completer = Completer<ConvertResult>();

    final session = await FFmpegKit.executeAsync(cmd, (session) async {
      final rc = await session.getReturnCode();
      final ok = ReturnCode.isSuccess(rc);
      final cancelled = ReturnCode.isCancel(rc);
      final lastLines = tail.skip(tail.length > 120 ? tail.length - 120 : 0).join('\n');
      completer.complete(ConvertResult(ok: ok, cancelled: cancelled, returnCode: rc?.getValue(), tailLog: lastLines));
    });

    onSession?.call(session.getSessionId() ?? 0);
    return completer.future;
  }
}

class PathService {
  Future<String> suggestDefaultFolder() async {
    // Prefer the public Movies/FormatFlex by default on Android (display path).
    if (Platform.isAndroid) {
      return '/storage/emulated/0/Movies/FormatFlex';
    }

    // Non-Android: choose a sensible default
    try {
      final dir = await getDownloadsDirectory();
      if (dir != null) {
        final movies = Directory(p.join(dir.path, 'FormatFlex'));
        if (!await movies.exists()) await movies.create(recursive: true);
        return movies.path;
      }
    } catch (_) {}

    final cache = await getTemporaryDirectory();
    final fallback = Directory(p.join(cache.path, 'FormatFlex'));
    if (!await fallback.exists()) await fallback.create(recursive: true);
    return fallback.path;
  }

  Future<String?> pickOutputFolder() async {
    return FilePicker.platform.getDirectoryPath(dialogTitle: 'Choose output folder');
  }
}

// =============================================================
// UI / Screen
// =============================================================

class ConverterHome extends StatefulWidget {
  const ConverterHome({super.key});
  @override
  State<ConverterHome> createState() => _ConverterHomeState();
}

class _ConverterHomeState extends State<ConverterHome> {
  final _svc = FfmpegService();
  final _paths = PathService();
  final ScrollController _scroll = ScrollController();

  String _status = 'Idle';
  double _progress = 0.0;
  int? _durationMs;
  int? _sessionId;
  bool _busy = false;

  String? _cachedPickedPath;

  ConvertOptions opts = ConvertOptions()..applyPreset(kPresets[1]);

  @override
  void initState() {
    FFmpegKitConfig.enableLogCallback((log) {
      try {
        LogBuffer.I.add(log.getMessage());
      } catch (_) {}
    });
    super.initState();
    _initDefaultFolder();
    _initMediaStore();
  }

  Future<void> _initDefaultFolder() async {
    final def = await _paths.suggestDefaultFolder();
    if (mounted) setState(() => opts.outputDir = def);
  }

  Future<void> _initMediaStore() async {
    try {
      await MediaStore.ensureInitialized();
      MediaStore.appFolder = 'FormatFlex';
    } catch (_) {}
  }

  // =============== Foreground service control ===============
  Future<void> _requestFgPermissions() async {
    final perm = await FlutterForegroundTask.checkNotificationPermission();
    if (perm != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (Platform.isAndroid) {
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    }
  }

  Future<ServiceRequestResult> _startFgService() async {
    await _requestFgPermissions();

    if (!Platform.isAndroid) return FlutterForegroundTask.stopService();

    if (await FlutterForegroundTask.isRunningService) {
      return FlutterForegroundTask.restartService();
    }

    return FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'Converting video…',
      notificationText: 'Tap to return to the app',
      notificationButtons: const [NotificationButton(id: 'stop', text: 'Stop')],
      notificationInitialRoute: '/',
      callback: _convCallback,
      serviceTypes: const [ForegroundServiceTypes.dataSync],
    );
  }

  @pragma('vm:entry-point')
  static void _convCallback() {
    FlutterForegroundTask.setTaskHandler(_ConvTaskHandler());
  }

  Future<void> _stopFgService() async {
    if (!Platform.isAndroid) return;
    await FlutterForegroundTask.stopService();
  }

  @override
  void dispose() {
    FFmpegKitConfig.disableStatistics();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _pickInput() async {
    setState(() {
      _status = 'Picking input…';
      _progress = 0;
    });
    final result = await FilePicker.platform.pickFiles(type: FileType.video);
    if (result == null || result.files.isEmpty) {
      setState(() => _status = 'Cancelled');
      return;
    }
    final path = result.files.single.path;
    if (path == null) {
      setState(() => _status = 'Invalid selection');
      return;
    }
    _cachedPickedPath = path;
    await _suggestOutputName(path);
    setState(() {
      opts.input = path;
      _status = 'Ready';
    });
  }

  Future<void> _chooseOutputFolder() async {
    final chosen = await _paths.pickOutputFolder();
    if (chosen != null) {
      setState(() {
        opts.outputDir = chosen;
      });
      if (opts.input.isNotEmpty) await _suggestOutputName(opts.input);
    }
  }

  Future<void> _suggestOutputName(String inputPath) async {
    final base = p.basenameWithoutExtension(inputPath);
    final ext = opts.container.ext;
    final suggested = '${base}_${opts.resolution.label.replaceAll(' ', '')}.$ext';
    setState(() {
      opts.outputFileName = suggested;
      opts.output = opts.computedOutputPath();
    });
  }

  // ======= Output write helpers (honor chosen folder) =======

  Future<bool> _testWritableDir(String dirPath) async {
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) await dir.create(recursive: true);
      final test = File(p.join(dir.path, '.ffw_test_${DateTime.now().millisecondsSinceEpoch}'));
      await test.writeAsString('ok', flush: true);
      await test.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  (DirName, String)? _mediaBucketFor(String targetDir) {
    final norm = targetDir.replaceAll('\\', '/');
    final parts = norm.split('/');
    final idxMovies = parts.indexWhere((e) => e.toLowerCase() == 'movies');
    if (idxMovies != -1) {
      final rel = parts.skip(idxMovies + 1).join('/');
      return (DirName.movies, rel.isEmpty ? FilePath.root : rel);
    }
    final idxDownloads = parts.indexWhere((e) => e.toLowerCase() == 'download' || e.toLowerCase() == 'downloads');
    if (idxDownloads != -1) {
      final rel = parts.skip(idxDownloads + 1).join('/');
      return (DirName.download, rel.isEmpty ? FilePath.root : rel);
    }
    final idxDcim = parts.indexWhere((e) => e.toLowerCase() == 'dcim');
    if (idxDcim != -1) {
      final rel = parts.skip(idxDcim + 1).join('/');
      return (DirName.dcim, rel.isEmpty ? FilePath.root : rel);
    }
    final idxPics = parts.indexWhere((e) => e.toLowerCase() == 'pictures');
    if (idxPics != -1) {
      final rel = parts.skip(idxPics + 1).join('/');
      return (DirName.pictures, rel.isEmpty ? FilePath.root : rel);
    }
    return null;
  }

  Future<String?> _exportFinal({required String tempFilePath}) async {
    final desiredDir = (opts.outputDir ?? '').trim();
    final finalName = opts.outputFileName;

    if (desiredDir.isEmpty) {
      return _saveViaMediaStore(tempFilePath, DirName.movies, 'FormatFlex');
    }

    if (Platform.isAndroid) {
      final bucket = _mediaBucketFor(desiredDir);
      if (bucket != null) {
        final (dirName, rel) = bucket;
        return _saveViaMediaStore(tempFilePath, dirName, rel);
      }

      if (await _testWritableDir(desiredDir)) {
        try {
          final outPath = p.join(desiredDir, finalName);
          final out = File(outPath);
          if (await out.exists()) await out.delete();
          await File(tempFilePath).copy(outPath);
          try {
            await File(tempFilePath).delete();
          } catch (_) {}
          return outPath;
        } catch (_) {}
      }

      final fallback = await _saveViaMediaStore(tempFilePath, DirName.movies, 'FormatFlex');
      if (fallback != null) {
        setState(() => _status = 'Chosen folder not writable. Saved to /Movies/FormatFlex instead.');
      }
      return fallback;
    } else {
      try {
        if (!await Directory(desiredDir).exists()) {
          await Directory(desiredDir).create(recursive: true);
        }
        final outPath = p.join(desiredDir, finalName);
        final out = File(outPath);
        if (await out.exists()) await out.delete();
        await File(tempFilePath).copy(outPath);
        try {
          await File(tempFilePath).delete();
        } catch (_) {}
        return outPath;
      } catch (_) {
        return null;
      }
    }
  }

  Future<String?> _saveViaMediaStore(String tempFilePath, DirName dirName, String relativePath) async {
    try {
      await MediaStore.ensureInitialized();
      final info = await MediaStore().saveFile(
        tempFilePath: tempFilePath,
        dirType: DirType.video,
        dirName: dirName,
        relativePath: relativePath.isEmpty ? FilePath.root : relativePath,
      );
      return info?.uri.path ?? info?.uri.toString();
    } catch (_) {
      return null;
    }
  }

  Future<void> _cleanupCaches() async {
    try {
      final cache = await getTemporaryDirectory();

      final fpDir = Directory(p.join(cache.path, 'file_picker'));
      if (await fpDir.exists()) await fpDir.delete(recursive: true);

      final ourTmp = Directory(p.join(cache.path, 'FormatFlex'));
      if (await ourTmp.exists()) await ourTmp.delete(recursive: true);

      if (_cachedPickedPath != null) {
        final f = File(_cachedPickedPath!);
        if (await f.exists()) await f.delete();
      }

      await for (final e in cache.list()) {
        if (e is File && p.basename(e.path).startsWith('.ffw_test_')) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  // =================== Turbo UI coupling ===================

  void _applyTurboUI(bool on) {
    if (on) {
      opts
        ..container = ContainerFmt.mp4
        ..vcodec = VCodec.h264
        ..acodec = ACodec.aac
        ..useHwEncoder = true
        ..toneMapHdrToSdr = false
        ..fps = null
        ..useCrf = true
        ..twoPass = false;
    }
  }

  bool get _isLockedByTurbo => opts.turbo;

  // ============== Pretty status like Windows build ==============

  String _prettyProgress(int? outUs, int? totalMs, double? speedX) {
    String fmtMs(int ms) {
      final s = (ms ~/ 1000);
      final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
    }

    if (outUs == null || totalMs == null || totalMs <= 0) return 'Converting…';
    final outMs = (outUs / 1000).round();
    final pct = outMs / totalMs;
    final leftMs = (speedX != null && speedX > 0) ? ((totalMs - outMs) / speedX).round() : (totalMs - outMs);
    return 'Converting… ${fmtMs(outMs)} / ${fmtMs(totalMs)}  (${(pct * 100).toStringAsFixed(2)}%)'
        '${speedX != null ? ' • ${speedX.toStringAsFixed(2)}x' : ''}'
        ' • ETA ${fmtMs(leftMs)}';
  }

  // ====================== Convert flow ======================

  Future<void> _convert() async {
    if (opts.input.isEmpty) return;
    if (opts.outputFileName.isEmpty) {
      setState(() => _status = 'Choose output filename');
      return;
    }

    if (_scroll.hasClients) {
      _scroll.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }

    setState(() {
      _status = 'Probing…';
      _progress = 0;
      _durationMs = null;
      _busy = true; // lock UI for the entire conversion (including fallback)
    });

    await _startFgService();
    WakelockPlus.enable();

    final probe = await _svc.probe(opts.input);
    _durationMs = probe.durationMs;

    // Work in app temp; final move happens after encode
    final tmpDir = await getTemporaryDirectory();
    final tmpWorkDir = Directory(p.join(tmpDir.path, 'FormatFlex'));
    if (!await tmpWorkDir.exists()) await tmpWorkDir.create(recursive: true);
    final tempOutPath = p.join(tmpWorkDir.path, opts.outputFileName);

    // Two-pass is software-only: if enabled, temporarily disable HW.
    final bool doTwoPass = opts.twoPass;
    final bool origHw = opts.useHwEncoder;
    if (doTwoPass) opts.useHwEncoder = false;

    // Build initial command (may use HW if two-pass is off)
    String cmd = _svc.buildCommand(input: opts.input, output: tempOutPath, probe: probe, o: opts);

    setState(() => _status = 'Converting… (HW accel when available)');
    FlutterForegroundTask.updateService(notificationTitle: 'Converting video…', notificationText: 'Starting…');

    ConvertResult res;

    if (doTwoPass) {
      // ---- TWO-PASS BRANCH ----
      setState(() => _status = 'Pass 1/2…');

      final nullSink = (Platform.isWindows) ? 'NUL' : '/dev/null';

      final pass1 = '$cmd -pass 1 -passlogfile "$tempOutPath.log" -f null $nullSink';
      await _svc.convert(
        cmd: pass1,
        onProgress: (_, {speedX, frame}) {}, // no bar for null sink
        onSession: (id) => _sessionId = id,
      );

      setState(() => _status = 'Pass 2/2…');
      final pass2 = '$cmd -pass 2 -passlogfile "$tempOutPath.log"';
      res = await _svc.convert(
        cmd: pass2,
        onProgress: (rawSec, {speedX, frame}) {
          if (_durationMs == null || _durationMs == 0) return;
          final outUs = (rawSec * 1000000).round();
          final pct = (rawSec * 1000) / _durationMs!;
          setState(() {
            _progress = pct.clamp(0.0, 1.0);
            _status = _prettyProgress(outUs, _durationMs, speedX);
          });
          FlutterForegroundTask.updateService(notificationTitle: 'Converting video…', notificationText: 'Progress ${(_progress * 100).toStringAsFixed(1)}%');
        },
        onSession: (id) => _sessionId = id,
      );
    } else {
      // ---- SINGLE-PASS BRANCH ----
      res = await _svc.convert(
        cmd: cmd,
        onProgress: (rawSec, {speedX, frame}) {
          if (_durationMs == null || _durationMs == 0) return;
          final outUs = (rawSec * 1000000).round();
          final pct = (rawSec * 1000) / _durationMs!;
          setState(() {
            _progress = pct.clamp(0.0, 1.0);
            _status = _prettyProgress(outUs, _durationMs, speedX);
          });
          FlutterForegroundTask.updateService(notificationTitle: 'Converting video…', notificationText: 'Progress ${(_progress * 100).toStringAsFixed(1)}%');
        },
        onSession: (id) => _sessionId = id,
      );

      // Heuristics for HW decode/encode failure that warrants SW fallback
      final tl = res.tailLog.toLowerCase();
      final mustRetrySoft =
          !res.ok &&
          !res.cancelled &&
          (res.returnCode == null ||
              tl.contains('mediacodec') ||
              tl.contains('decoder failed to start') ||
              tl.contains('unable to configure codec') ||
              tl.contains('both surface and native_window are null'));

      if (mustRetrySoft) {
        setState(() {
          _status = 'Hardware encoding failed — retrying with software encoding…';
          _progress = 0;
        });
        FlutterForegroundTask.updateService(notificationTitle: 'Converting (SW fallback)…', notificationText: 'Retrying without hardware acceleration');

        final softOpts = ConvertOptions()
          ..applyPreset(opts.preset)
          ..container = opts.container
          ..vcodec = opts.vcodec
          ..acodec = opts.acodec
          ..resolution = opts.resolution
          ..twoPass = false
          ..useCrf = opts.useCrf
          ..crf = opts.crf
          ..vBitrateK = opts.vBitrateK
          ..aBitrateK = opts.aBitrateK
          ..audioChannels = opts.audioChannels
          ..sampleRate = opts.sampleRate
          ..fps = opts.fps
          ..toneMapHdrToSdr = opts.toneMapHdrToSdr
          ..useHwEncoder = false
          ..turbo = false;

        cmd = _svc.buildCommand(input: opts.input, output: tempOutPath, probe: probe, o: softOpts, forceSoftwareDecode: true, forceSoftwareEncode: true);

        res = await _svc.convert(
          cmd: cmd,
          onProgress: (rawSec, {speedX, frame}) {
            if (_durationMs == null || _durationMs == 0) return;
            final outUs = (rawSec * 1000000).round();
            final pct = (rawSec * 1000) / _durationMs!;
            setState(() {
              _progress = pct.clamp(0.0, 1.0);
              _status = _prettyProgress(outUs, _durationMs, speedX);
            });
            FlutterForegroundTask.updateService(notificationTitle: 'Converting (SW)…', notificationText: 'Progress ${(_progress * 100).toStringAsFixed(1)}%');
          },
          onSession: (id) => _sessionId = id,
        );
      }
    }

    // ---- Finalize (common) ----
    if (res.ok) {
      final finalPath = await _exportFinal(tempFilePath: tempOutPath);
      setState(() {
        _status = finalPath != null ? 'Saved: $finalPath' : 'Converted, but failed to save to chosen folder.';
        _progress = 1.0;
        _busy = false;
      });
      FlutterForegroundTask.updateService(notificationTitle: 'Done', notificationText: 'Saved successfully');
      WakelockPlus.disable();
      await _stopFgService();
      await _cleanupCaches();
      if (doTwoPass) opts.useHwEncoder = origHw;
      return;
    }

    if (res.cancelled) {
      setState(() {
        _status = 'Cancelled';
        _busy = false;
      });
    } else {
      final msg = 'Failed${res.returnCode != null ? ' (code ${res.returnCode})' : ''}\n${_summarizeFailure(res.tailLog)}';
      setState(() {
        _status = msg;
        _busy = false;
      });
      log(msg, name: 'FFmpegKit');
    }

    WakelockPlus.disable();
    await _stopFgService();
    try {
      final f = File(tempOutPath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    await _cleanupCaches();
    if (doTwoPass) opts.useHwEncoder = origHw;
  }

  String _summarizeFailure(String tail) {
    final lines = tail.split('\n').where((l) {
      final s = l.toLowerCase();
      return s.contains('error') || s.contains('mediacodec') || s.contains('failed') || s.contains('unable');
    }).toList();
    if (lines.isEmpty) return 'See logs for details.';
    return lines.length <= 6 ? lines.join('\n') : lines.sublist(lines.length - 6).join('\n');
  }

  Future<void> _cancel() async {
    if (_sessionId != null) {
      await FFmpegKit.cancel(_sessionId!);
    }
    setState(() => _busy = false);
    WakelockPlus.disable();
    await _stopFgService();
    await _cleanupCaches();
  }

  @override
  Widget build(BuildContext context) {
    final canConvert = opts.input.isNotEmpty && opts.outputFileName.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Universal Video Converter'),
        actions: [IconButton(onPressed: _busy ? _cancel : null, icon: const Icon(Icons.close))],
      ),
      body: ListView(
        controller: _scroll,
        padding: const EdgeInsets.all(16),
        children: [
          Text('Status: $_status'),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: LinearProgressIndicator(value: _progress == 0 ? null : _progress)),
              SizedBox(width: 55, child: Text('${(_progress * 100).toStringAsFixed(1)}%', textAlign: TextAlign.right)),
            ],
          ),
          const SizedBox(height: 16),

          // Turbo mode (locks fields + updates them immediately)
          SwitchListTile(
            title: const Text('Turbo mode (max speed)'),
            subtitle: const Text('H.264 + MP4, HW encode, stream copy when possible, keep FPS, HDR tone-map off'),
            value: opts.turbo,
            onChanged: _busy
                ? null
                : (v) => setState(() {
                    opts.turbo = v;
                    _applyTurboUI(v);
                    if (opts.input.isNotEmpty) _suggestOutputName(opts.input);
                  }),
          ),
          const SizedBox(height: 8),

          Row(
            children: [
              Expanded(
                child: FilledButton.icon(onPressed: _busy ? null : _pickInput, icon: const Icon(Icons.video_file), label: const Text('Pick Video')),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (opts.input.isNotEmpty)
            TextField(
              readOnly: true,
              controller: TextEditingController(text: opts.input),
              decoration: const InputDecoration(labelText: 'Input', border: OutlineInputBorder()),
            ),
          const SizedBox(height: 12),

          // Output selection (display)
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: TextEditingController(text: opts.outputDir ?? ''),
                  readOnly: true,
                  decoration: const InputDecoration(labelText: 'Output Folder (final destination)', border: OutlineInputBorder()),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(onPressed: _busy ? null : _chooseOutputFolder, child: const Text('Choose…')),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            onChanged: _busy
                ? null
                : (v) => setState(() {
                    opts.outputFileName = v;
                    opts.output = opts.computedOutputPath();
                  }),
            controller: TextEditingController(text: opts.outputFileName),
            readOnly: _busy,
            decoration: const InputDecoration(labelText: 'Output File Name', hintText: 'movie_1080p.mp4', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          if ((opts.outputDir ?? '').isNotEmpty && opts.outputFileName.isNotEmpty)
            TextField(
              readOnly: true,
              controller: TextEditingController(text: opts.computedOutputPath()),
              decoration: const InputDecoration(labelText: 'Full Output Path (chosen)', border: OutlineInputBorder()),
            ),

          const SizedBox(height: 24),

          _Labeled(
            label: 'Preset',
            child: DropdownButtonFormField<Preset>(
              value: opts.preset,
              items: [for (final pz in kPresets) DropdownMenuItem(value: pz, child: Text(pz.name))],
              onChanged: (_busy || _isLockedByTurbo)
                  ? null
                  : (pz) {
                      if (pz == null) return;
                      setState(() {
                        opts.applyPreset(pz);
                        _suggestOutputName(opts.input.isNotEmpty ? opts.input : opts.outputFileName);
                      });
                    },
            ),
          ),
          const SizedBox(height: 12),

          _Labeled(
            label: 'Container',
            child: DropdownButtonFormField<ContainerFmt>(
              value: opts.container,
              items: ContainerFmt.values.map((e) => DropdownMenuItem(value: e, child: Text(e.label))).toList(),
              onChanged: (_busy || _isLockedByTurbo)
                  ? null
                  : (v) {
                      if (v == null) return;
                      setState(() {
                        opts.container = v;
                        if (opts.input.isNotEmpty) _suggestOutputName(opts.input);
                      });
                    },
            ),
          ),
          const SizedBox(height: 12),

          _Labeled(
            label: 'Video Codec',
            child: DropdownButtonFormField<VCodec>(
              value: opts.vcodec,
              items: VCodec.values.map((e) => DropdownMenuItem(value: e, child: Text(e.label))).toList(),
              onChanged: (_busy || _isLockedByTurbo) ? null : (v) => setState(() => opts.vcodec = v ?? opts.vcodec),
            ),
          ),
          const SizedBox(height: 12),

          _Labeled(
            label: 'Audio Codec',
            child: DropdownButtonFormField<ACodec>(
              value: opts.acodec,
              items: ACodec.values.map((e) => DropdownMenuItem(value: e, child: Text(e.label))).toList(),
              onChanged: (_busy || _isLockedByTurbo) ? null : (v) => setState(() => opts.acodec = v ?? opts.acodec),
            ),
          ),
          const SizedBox(height: 12),

          _Labeled(
            label: 'Resolution',
            child: DropdownButtonFormField<Resolution>(
              value: opts.resolution,
              items: kResList.map((r) => DropdownMenuItem(value: r, child: Text(r.label))).toList(),
              onChanged: (_busy || _isLockedByTurbo)
                  ? null
                  : (r) {
                      if (r == null) return;
                      setState(() {
                        opts.resolution = r;
                        if (opts.input.isNotEmpty) _suggestOutputName(opts.input);
                      });
                    },
            ),
          ),
          const SizedBox(height: 12),

          _Labeled(
            label: 'Frame Rate',
            child: DropdownButtonFormField<double?>(
              value: opts.fps,
              items: [null, 24.0, 25.0, 29.97, 30.0, 50.0, 59.94, 60.0].map((f) => DropdownMenuItem(value: f, child: Text(f == null ? 'Keep original' : f.toString()))).toList(),
              onChanged: (_busy || _isLockedByTurbo) ? null : (f) => setState(() => opts.fps = f),
            ),
          ),
          const SizedBox(height: 12),

          SwitchListTile(
            title: const Text('Use CRF (quality based)'),
            subtitle: const Text('Off = target bitrate'),
            value: opts.useCrf,
            onChanged: (_busy || _isLockedByTurbo) ? null : (v) => setState(() => opts.useCrf = v),
          ),
          if (opts.useCrf)
            _NumberField(
              label: 'CRF (lower = better, typical 18–28)',
              value: opts.crf.toDouble(),
              min: 0,
              max: 51,
              enabled: !_busy && !_isLockedByTurbo,
              onChanged: (v) => setState(() => opts.crf = v.round()),
            )
          else
            _NumberField(
              label: 'Video Bitrate (kbps)',
              value: opts.vBitrateK.toDouble(),
              min: 250,
              max: 20000,
              step: 250,
              enabled: !_busy && !_isLockedByTurbo,
              onChanged: (v) => setState(() => opts.vBitrateK = v.round()),
            ),

          const SizedBox(height: 12),
          _NumberField(
            label: 'Audio Bitrate (kbps)',
            value: opts.aBitrateK.toDouble(),
            min: 96,
            max: 768,
            step: 32,
            enabled: !_busy && !_isLockedByTurbo,
            onChanged: (v) => setState(() => opts.aBitrateK = v.round()),
          ),
          const SizedBox(height: 12),

          _Labeled(
            label: 'Audio Channels',
            child: DropdownButtonFormField<int>(
              value: opts.audioChannels,
              items: [2, 6].map((c) => DropdownMenuItem(value: c, child: Text(c == 2 ? 'Stereo (2.0)' : '5.1 (6 ch)'))).toList(),
              onChanged: (_busy || _isLockedByTurbo) ? null : (c) => setState(() => opts.audioChannels = c ?? opts.audioChannels),
            ),
          ),
          const SizedBox(height: 12),

          _Labeled(
            label: 'Sample Rate',
            child: DropdownButtonFormField<int>(
              value: opts.sampleRate,
              items: [44100, 48000].map((sr) => DropdownMenuItem(value: sr, child: Text('$sr Hz'))).toList(),
              onChanged: (_busy || _isLockedByTurbo) ? null : (sr) => setState(() => opts.sampleRate = sr ?? opts.sampleRate),
            ),
          ),
          const SizedBox(height: 12),

          // Two-pass (software only)
          CheckboxListTile(
            value: opts.twoPass,
            onChanged: (_busy || _isLockedByTurbo) ? null : (v) => setState(() => opts.twoPass = v ?? false),
            title: const Text('Two-pass encoding (software only)'),
            subtitle: const Text('Disables hardware encoder for this run'),
          ),
          const SizedBox(height: 12),

          // Track pickers and mixing
          if (opts.input.isNotEmpty)
            Row(
              children: [
                Expanded(
                  child: _Labeled(
                    label: 'Video stream index',
                    child: TextField(
                      keyboardType: TextInputType.number,
                      onChanged: _busy
                          ? null
                          : (v) {
                              final n = int.tryParse(v.trim());
                              if (n != null) setState(() => opts.videoStream = n);
                            },
                      decoration: InputDecoration(hintText: '0', border: const OutlineInputBorder(), helperText: 'Usually 0', suffixText: '${opts.videoStream}'),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _Labeled(
                    label: 'Audio stream index (optional)',
                    child: TextField(
                      keyboardType: TextInputType.number,
                      onChanged: _busy
                          ? null
                          : (v) {
                              final n = int.tryParse(v.trim());
                              setState(() => opts.audioStream = n);
                            },
                      decoration: const InputDecoration(hintText: 'auto', border: OutlineInputBorder(), helperText: 'Leave empty for first audio'),
                    ),
                  ),
                ),
              ],
            ),
          CheckboxListTile(
            value: opts.allowDownmix,
            onChanged: _busy ? null : (v) => setState(() => opts.allowDownmix = v ?? true),
            title: const Text('Allow downmix (e.g., 7.1 → 5.1/2.0 when needed)'),
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            value: opts.toneMapHdrToSdr,
            onChanged: (_busy || _isLockedByTurbo) ? null : (v) => setState(() => opts.toneMapHdrToSdr = v ?? true),
            title: const Text('Tone-map HDR → SDR when needed'),
            subtitle: const Text('Improves compatibility on older projectors/TVs'),
          ),
          const SizedBox(height: 12),

          SwitchListTile(
            title: const Text('Use hardware encoder (faster)'),
            subtitle: const Text('Mediacodec on Android, VideoToolbox on iOS/macOS'),
            value: opts.useHwEncoder,
            onChanged: (_busy || _isLockedByTurbo) ? null : (v) => setState(() => opts.useHwEncoder = v),
          ),

          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(onPressed: (!canConvert || _busy) ? null : _convert, icon: const Icon(Icons.play_arrow), label: const Text('Convert')),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Text('Logs', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const _LogPane(),
          const SizedBox(height: 24),
          const _TipsBox(),
        ],
      ),
    );
  }
}

class _Labeled extends StatelessWidget {
  final String label;
  final Widget child;
  const _Labeled({required this.label, required this.child});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 6),
      child,
    ],
  );
}

class _NumberField extends StatefulWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final double step;
  final ValueChanged<double> onChanged;
  final bool enabled;
  const _NumberField({required this.label, required this.value, required this.onChanged, this.min = 0, this.max = 100, this.step = 1, this.enabled = true});
  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late double _v = widget.value;
  @override
  void didUpdateWidget(covariant _NumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    _v = widget.value;
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(widget.label),
      Row(
        children: [
          Expanded(
            child: Slider(
              value: _v.clamp(widget.min, widget.max),
              min: widget.min,
              max: widget.max,
              divisions: ((widget.max - widget.min) / widget.step).round(),
              label: _v.round().toString(),
              onChanged: widget.enabled
                  ? (v) {
                      setState(() => _v = v);
                      widget.onChanged(v);
                    }
                  : null,
            ),
          ),
          SizedBox(width: 64, child: Text('${_v.round()}', textAlign: TextAlign.end)),
        ],
      ),
    ],
  );
}

class _TipsBox extends StatelessWidget {
  const _TipsBox();
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text('Compatibility & Speed tips', style: TextStyle(fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            Text('• Turbo: H.264 + MP4, HW encode, stream copy when possible, HDR tone-map off, keep FPS.'),
            Text('• Prefer MP4 + H.264 + AAC or AC-3 for older TVs.'),
            Text('• 1080p or 720p often plays best on lower-end devices.'),
            Text('• HDR→SDR tone-mapping is CPU heavy—only enable if needed.'),
            Text('• AV1 is efficient but slow to encode on mobile.'),
          ],
        ),
      ),
    );
  }
}

class _LogPane extends StatefulWidget {
  const _LogPane();
  @override
  State<_LogPane> createState() => _LogPaneState();
}

class _LogPaneState extends State<_LogPane> {
  @override
  Widget build(BuildContext context) {
    final lines = LogBuffer.I.dump();
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.black26),
      ),
      child: SingleChildScrollView(
        child: SelectableText(lines, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
      ),
    );
  }
}
