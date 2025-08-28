// pubspec.yaml (add these):
// dependencies:
//   flutter: {sdk: flutter}
//   file_picker: ^8.0.3
//   path: ^1.9.0
//   path_provider: ^2.1.4

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// -------------------------------------------------------------
// Models, enums, presets (mostly identical to your Android code)
// -------------------------------------------------------------

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
  String get swName => switch (this) {
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
  final int w, h;
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
  String? outputDir;
  String outputFileName = '';

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
  bool turbo = false;

  // Optional: set to a custom folder containing ffmpeg.exe/ffprobe.exe
  String? ffmpegDir;

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

// -------------------------------------------------------------
// Low-level: FFmpeg paths and GPU capability discovery
// -------------------------------------------------------------

class FfmpegBins {
  FfmpegBins(this.ffmpegDir);
  final String? ffmpegDir;

  String get ffmpeg => ffmpegDir == null || ffmpegDir!.isEmpty ? 'ffmpeg' : p.join(ffmpegDir!, 'ffmpeg.exe');
  String get ffprobe => ffmpegDir == null || ffmpegDir!.isEmpty ? 'ffprobe' : p.join(ffmpegDir!, 'ffprobe.exe');

  Future<bool> check() async {
    try {
      final pr = await Process.run(ffmpeg, ['-version']);
      final rr = await Process.run(ffprobe, ['-version']);
      return (pr.exitCode == 0 && rr.exitCode == 0);
    } catch (_) {
      return false;
    }
  }
}

class GpuCaps {
  final Set<String> encoders = {};
  final Set<String> filters = {};

  bool get hasNVENC => encoders.contains('h264_nvenc') || encoders.contains('hevc_nvenc') || encoders.contains('av1_nvenc');
  bool get hasQSV => encoders.contains('h264_qsv') || encoders.contains('hevc_qsv') || encoders.contains('av1_qsv') || encoders.contains('vp9_qsv');
  bool get hasAMF => encoders.contains('h264_amf') || encoders.contains('hevc_amf') || encoders.contains('av1_amf');

  bool get hasScaleCuda => filters.contains('scale_cuda') || filters.contains('scale_npp');
  bool get hasTonemapOpenCL => filters.contains('tonemap_opencl');

  static Future<GpuCaps> probe(FfmpegBins bins) async {
    final caps = GpuCaps();
    try {
      final e = await Process.run(bins.ffmpeg, ['-hide_banner', '-encoders']);
      final f = await Process.run(bins.ffmpeg, ['-hide_banner', '-filters']);
      if (e.exitCode == 0) {
        for (final line in LineSplitter.split(e.stdout.toString())) {
          final m = RegExp(r'\s([a-z0-9_]{3,})\s+').firstMatch(line);
          if (m != null) caps.encoders.add(m.group(1)!);
        }
      }
      if (f.exitCode == 0) {
        for (final line in LineSplitter.split(f.stdout.toString())) {
          final parts = line.trim().split(RegExp(r'\s+'));
          if (parts.isNotEmpty && !parts.first.startsWith('T.')) {
            caps.filters.add(parts.first);
          }
        }
      }
    } catch (_) {}
    return caps;
  }
}

// -------------------------------------------------------------
// Media probe
// -------------------------------------------------------------

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

class FfmpegServiceWin {
  FfmpegServiceWin(this.bins, this.caps);
  final FfmpegBins bins;
  final GpuCaps caps;

  Future<MediaProbeResult> probe(String inputPath) async {
    final pr = await Process.run(bins.ffprobe, ['-v', 'error', '-print_format', 'json', '-show_streams', '-show_format', inputPath]);
    if (pr.exitCode != 0) {
      return MediaProbeResult(durationMs: null, hasHdr: false);
    }
    final json = jsonDecode(pr.stdout.toString());
    final streams = (json['streams'] as List<dynamic>? ?? []);
    double? durSec;
    if (json['format'] != null && json['format']['duration'] != null) {
      durSec = double.tryParse(json['format']['duration'].toString());
    }
    int? w, h, ch, sr;
    String? vCodec, aCodec, pix;
    bool hasHdr = false;
    for (final s in streams) {
      final type = (s['codec_type'] ?? '').toString();
      if (type == 'video') {
        w = (s['width'] as int? ?? w);
        h = (s['height'] as int? ?? h);
        vCodec = (s['codec_name']?.toString() ?? vCodec);
        pix = (s['pix_fmt']?.toString() ?? pix);
        final ct = (s['color_transfer'] ?? s['color_transfer_name'] ?? '').toString().toLowerCase();
        final cp = (s['color_primaries'] ?? s['color_primaries_name'] ?? '').toString().toLowerCase();
        if (ct.contains('smpte2084') || ct.contains('pq') || ct.contains('hlg') || cp.contains('bt2020')) {
          hasHdr = true;
        }
      } else if (type == 'audio') {
        aCodec = (s['codec_name']?.toString() ?? aCodec);
        ch = int.tryParse(s['channels']?.toString() ?? '') ?? ch;
        sr = int.tryParse(s['sample_rate']?.toString() ?? '') ?? sr;
      }
    }
    return MediaProbeResult(
      durationMs: durSec == null ? null : (durSec * 1000).round(),
      hasHdr: hasHdr,
      width: w,
      height: h,
      vCodecName: vCodec,
      pixFmt: pix,
      aCodecName: aCodec,
      aChannels: ch,
      aSampleRate: sr,
    );
  }

  // Choose the best available HW encoder name for the requested codec.
  // Order: NVENC -> QSV -> AMF -> software.
  String pickEncoder(VCodec v, {required bool requestHw}) {
    if (requestHw) {
      if (v == VCodec.h264) {
        if (caps.encoders.contains('h264_nvenc')) return 'h264_nvenc';
        if (caps.encoders.contains('h264_qsv')) return 'h264_qsv';
        if (caps.encoders.contains('h264_amf')) return 'h264_amf';
      } else if (v == VCodec.hevc) {
        if (caps.encoders.contains('hevc_nvenc')) return 'hevc_nvenc';
        if (caps.encoders.contains('hevc_qsv')) return 'hevc_qsv';
        if (caps.encoders.contains('hevc_amf')) return 'hevc_amf';
      } else if (v == VCodec.av1) {
        if (caps.encoders.contains('av1_nvenc')) return 'av1_nvenc';
        if (caps.encoders.contains('av1_qsv')) return 'av1_qsv';
        if (caps.encoders.contains('av1_amf')) return 'av1_amf';
      } else if (v == VCodec.vp9) {
        if (caps.encoders.contains('vp9_qsv')) return 'vp9_qsv';
      }
    }
    return v.swName; // fallback software encoder
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
    final bool wantToneMap = turbo ? false : (o.toneMapHdrToSdr && probe.hasHdr);
    final knowSize = (probe.width != null && probe.height != null);
    final needsScale = knowSize ? (probe.width! > o.resolution.w || probe.height! > o.resolution.h) : false;

    final VCodec effV = turbo ? VCodec.h264 : o.vcodec;
    final encName = forceSoftwareEncode ? effV.swName : pickEncoder(effV, requestHw: o.useHwEncoder || turbo);

    final String vCodecIn = (probe.vCodecName ?? '').toLowerCase();
    final bool sameCodec =
        (effV == VCodec.h264 && vCodecIn.contains('h264')) ||
        (effV == VCodec.hevc && (vCodecIn.contains('hevc') || vCodecIn.contains('h265'))) ||
        (effV == VCodec.vp9 && vCodecIn.contains('vp9')) ||
        (effV == VCodec.av1 && vCodecIn.contains('av1'));

    final pixOk = (probe.pixFmt == null) || probe.pixFmt!.contains('yuv420');
    final canCopyVideo = !wantToneMap && !needsScale && (turbo ? true : (o.fps == null)) && sameCodec && pixOk;

    final String aCodecIn = (probe.aCodecName ?? '').toLowerCase();
    final bool sameAudio =
        (o.acodec == ACodec.aac && aCodecIn == 'aac') ||
        (o.acodec == ACodec.ac3 && aCodecIn == 'ac3') ||
        (o.acodec == ACodec.eac3 && aCodecIn == 'eac3') ||
        (o.acodec == ACodec.opus && aCodecIn == 'opus') ||
        (o.acodec == ACodec.mp3 && aCodecIn == 'mp3');
    final bool canCopyAudio = sameAudio && (probe.aChannels == null || probe.aChannels == o.audioChannels) && (probe.aSampleRate == null || probe.aSampleRate == o.sampleRate);

    // ------------------ Filter chain (tone-map & scale) ------------------
    final vf = <String>[];
    // We keep CPU tonemap by default (stable everywhere). If OpenCL tonemap exists, we could switch to it later.
    if (wantToneMap) {
      vf.add('zscale=t=linear:npl=100,format=gbrpf32le,tonemap=hable,zscale=p=bt709:t=bt709:m=bt709,format=yuv420p');
    }
    if (needsScale) {
      vf.add('scale=w=${o.resolution.w}:h=${o.resolution.h}:flags=fast_bilinear:force_original_aspect_ratio=decrease');
    }
    final vfChain = vf.isEmpty ? null : vf.join(',');

    // ------------------ Decoder side ------------------
    final preInput = <String>[];
    final usingHwEnc = !encName.startsWith('lib'); // we selected a HW encoder
    // Use HW decode opportunistically only when we are not forcing software decode and have HW encoder (best end-to-end).
    if (!forceSoftwareDecode && usingHwEnc && !wantToneMap && !needsScale) {
      // zero-copy path most likely when no filters are applied
      if (encName.contains('_nvenc')) {
        preInput.addAll(['-hwaccel', 'cuda']);
      } else if (encName.contains('_qsv')) {
        preInput.addAll(['-hwaccel', 'qsv']);
      } else if (encName.contains('_amf')) {
        // AMF uses D3D11/DirectX under the hood; decoding accel is typically via d3d11va
        preInput.addAll(['-hwaccel', 'd3d11va']);
      }
    }

    // ------------------ Encoder args ------------------
    final vArgs = <String>[];
    if (canCopyVideo) {
      vArgs.addAll(['-c:v', 'copy']);
    } else {
      vArgs.addAll(['-c:v', encName]);

      if (encName.contains('_nvenc')) {
        // Map CRF -> NVENC CQ (rough approximation), preset p1 fastest..p7 best
        final cq = o.useCrf ? o.crf.clamp(10, 40) : 23;
        vArgs.addAll(['-preset', turbo ? 'p1' : 'p4']);
        if (o.useCrf) {
          vArgs.addAll(['-rc', 'vbr', '-cq', '$cq']);
        } else {
          vArgs.addAll(['-b:v', '${o.vBitrateK}k']);
        }
        vArgs.addAll(['-pix_fmt', 'yuv420p']);
      } else if (encName.contains('_qsv')) {
        if (o.useCrf) {
          // QSV uses -global_quality for ICQ; scale 18~28 → 20~30
          final gq = (o.crf + 2).clamp(18, 42);
          vArgs.addAll(['-rc', 'icq', '-global_quality', '$gq']);
        } else {
          vArgs.addAll(['-b:v', '${o.vBitrateK}k']);
        }
        vArgs.addAll(['-pix_fmt', 'nv12']);
      } else if (encName.contains('_amf')) {
        vArgs.addAll(['-quality', turbo ? 'speed' : 'balanced']);
        if (o.useCrf) {
          vArgs.addAll(['-rc', 'vbr', '-q', '${o.crf}']);
        } else {
          vArgs.addAll(['-b:v', '${o.vBitrateK}k']);
        }
        vArgs.addAll(['-pix_fmt', 'yuv420p']);
      } else {
        // software encoders
        switch (effV) {
          case VCodec.h264:
            vArgs.addAll(['-preset', turbo ? 'superfast' : 'veryfast', '-profile:v', 'high', '-pix_fmt', 'yuv420p']);
            if (o.useCrf)
              vArgs.addAll(['-crf', '${o.crf}']);
            else
              vArgs.addAll(['-b:v', '${o.vBitrateK}k']);
            break;
          case VCodec.hevc:
            vArgs.addAll(['-preset', turbo ? 'ultrafast' : 'fast', '-pix_fmt', 'yuv420p', '-tag:v', 'hvc1']);
            if (o.useCrf)
              vArgs.addAll(['-crf', '${o.crf}']);
            else
              vArgs.addAll(['-b:v', '${o.vBitrateK}k']);
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
            if (o.useCrf)
              vArgs.addAll(['-crf', '${o.crf}', '-b:v', '0']);
            else
              vArgs.addAll(['-b:v', '${o.vBitrateK}k']);
            break;
        }
      }
    }

    // Audio
    final aArgs = <String>[];
    if (canCopyAudio) {
      aArgs.addAll(['-c:a', 'copy']);
    } else {
      aArgs.addAll(['-c:a', o.acodec.ffmpegName, '-b:a', '${o.aBitrateK}k', '-ac', '${o.audioChannels}', '-ar', '${o.sampleRate}']);
    }

    final fpsArgs = (turbo ? <String>[] : (o.fps != null ? ['-r', o.fps!.toString()] : <String>[]));
    final movFlags = (o.container == ContainerFmt.mp4) ? ['-movflags', '+faststart'] : <String>[];

    final args = <String>[
      '-y',
      '-hide_banner',
      '-stats_period',
      '0.5',
      ...preInput,
      '-i',
      input,
      if (vfChain != null) ...['-vf', vfChain],
      ...fpsArgs,
      ...vArgs,
      ...aArgs,
      '-threads',
      '0',
      ...movFlags,
      '-progress',
      'pipe:1',
      '-nostats',
      output,
    ];
    return args.join(' ');
  }

  // Parse ffmpeg -progress key=value lines; return out_time_ms
  static int? _parseProgressLine(String line) {
    // Example: out_time_ms=1234567
    if (line.startsWith('out_time_ms=')) {
      final v = int.tryParse(line.split('=').last.trim());
      return v;
    }
    return null;
  }

  Future<ConvertResult> convert({required String cmd, required void Function(double pct) onProgress, required int? durationMs, void Function(Process p)? onProcess}) async {
    final parts = _shellSplit(cmd);
    final proc = await Process.start(parts.first, parts.sublist(1), mode: ProcessStartMode.detachedWithStdio);
    onProcess?.call(proc);

    final tail = <String>[];
    final completer = Completer<ConvertResult>();

    // progress from stdout (-progress pipe:1)
    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (line.isEmpty) return;
      tail.add(line);
      if (tail.length > 200) tail.removeAt(0);
      final ms = _parseProgressLine(line);
      if (ms != null && durationMs != null && durationMs > 0) {
        final pct = (ms / durationMs).clamp(0.0, 1.0);
        onProgress(pct);
      }
    });

    // collect stderr tail for diagnostics
    proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (line.isEmpty) return;
      tail.add(line);
      if (tail.length > 200) tail.removeAt(0);
    });

    proc.exitCode.then((code) {
      final ok = code == 0;
      final cancelled = false; // (if you wire SIGINT you can set it)
      final last = tail.skip(tail.length > 120 ? tail.length - 120 : 0).join('\n');
      completer.complete(ConvertResult(ok: ok, cancelled: cancelled, returnCode: code, tailLog: last));
    });

    return completer.future;
  }

  // Tiny shell splitter for our simple command strings
  static List<String> _shellSplit(String cmd) {
    final rx = RegExp(r'("([^"]*)"|\S+)');
    final m = rx.allMatches(cmd);
    return m.map((e) => (e.group(2) ?? e.group(1)!)).toList();
  }
}

// -------------------------------------------------------------
// App UI (Windows only)
// -------------------------------------------------------------

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ConverterApp());
}

class ConverterApp extends StatelessWidget {
  const ConverterApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Universal Video Converter (Windows)',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: const ConverterHome(),
    );
  }
}

class ConverterHome extends StatefulWidget {
  const ConverterHome({super.key});
  @override
  State<ConverterHome> createState() => _ConverterHomeState();
}

class _ConverterHomeState extends State<ConverterHome> {
  final ScrollController _scroll = ScrollController();

  String _status = 'Idle';
  double _progress = 0.0;
  int? _durationMs;
  bool _busy = false;

  ConvertOptions opts = ConvertOptions()..applyPreset(kPresets[1]);
  late FfmpegBins _bins;
  GpuCaps? _caps;

  Process? _active; // for cancel

  @override
  void initState() {
    super.initState();
    _initDefaults();
  }

  Future<void> _initDefaults() async {
    opts.outputDir = await _suggestDefaultFolder();
    _bins = FfmpegBins(null);
    final ok = await _bins.check();
    setState(() {
      _status = ok ? 'Ready' : 'FFmpeg not found. Add to PATH or set folder below.';
    });
    _caps = await GpuCaps.probe(_bins);
    setState(() {});
  }

  Future<String> _suggestDefaultFolder() async {
    try {
      final vids = await getDownloadsDirectory();
      if (vids != null) {
        final dir = Directory(p.join(vids.path, 'FormatFlex'));
        if (!await dir.exists()) await dir.create(recursive: true);
        return dir.path;
      }
    } catch (_) {}
    final cache = await getTemporaryDirectory();
    final fallback = Directory(p.join(cache.path, 'FormatFlex'));
    if (!await fallback.exists()) await fallback.create(recursive: true);
    return fallback.path;
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
    await _suggestOutputName(path);
    setState(() {
      opts.input = path;
      _status = 'Ready';
    });
  }

  Future<void> _chooseOutputFolder() async {
    final chosen = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Choose output folder');
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

  Future<void> _convert() async {
    if (opts.input.isEmpty) return;
    if (opts.outputFileName.isEmpty) {
      setState(() => _status = 'Choose output filename');
      return;
    }
    if (_scroll.hasClients) {
      _scroll.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }

    // allow user-set ffmpeg folder
    _bins = FfmpegBins(opts.ffmpegDir);
    if (!await _bins.check()) {
      setState(() => _status = 'FFmpeg/FFprobe not found. Fix PATH or set folder.');
      return;
    }
    _caps ??= await GpuCaps.probe(_bins);
    final caps = _caps!;

    setState(() {
      _status = 'Probing…';
      _progress = 0;
      _durationMs = null;
      _busy = true;
    });

    final svc = FfmpegServiceWin(_bins, caps);
    final probe = await svc.probe(opts.input);
    _durationMs = probe.durationMs;

    // temp work file
    final tmp = await getTemporaryDirectory();
    final tempOut = p.join(tmp.path, 'FormatFlex', opts.outputFileName);
    await Directory(p.dirname(tempOut)).create(recursive: true);

    // Attempt #1: as configured (may use HW)
    final cmd1 = svc.buildCommand(input: opts.input, output: tempOut, probe: probe, o: opts);
    setState(() => _status = 'Converting… (HW accel when available)');

    ConvertResult res = await svc.convert(
      cmd: cmd1,
      onProgress: (pct) {
        setState(() => _progress = pct);
      },
      durationMs: _durationMs,
      onProcess: (p) => _active = p,
    );

    bool mustRetrySoft = !res.ok && !res.cancelled && (res.returnCode != 0);

    // Attempt #2: force SW path
    if (mustRetrySoft) {
      setState(() {
        _status = 'Hardware path failed — retrying with software encoding…';
        _progress = 0;
      });
      final soft = ConvertOptions()
        ..applyPreset(opts.preset)
        ..container = opts.container
        ..vcodec = opts.vcodec
        ..acodec = opts.acodec
        ..resolution = opts.resolution
        ..twoPass = opts.twoPass
        ..useCrf = opts.useCrf
        ..crf = opts.crf
        ..vBitrateK = opts.vBitrateK
        ..aBitrateK = opts.aBitrateK
        ..audioChannels = opts.audioChannels
        ..sampleRate = opts.sampleRate
        ..fps = opts.fps
        ..toneMapHdrToSdr = opts.toneMapHdrToSdr
        ..useHwEncoder = false
        ..turbo = false
        ..ffmpegDir = opts.ffmpegDir;

      final cmd2 = svc.buildCommand(input: opts.input, output: tempOut, probe: probe, o: soft, forceSoftwareDecode: true, forceSoftwareEncode: true);
      res = await svc.convert(cmd: cmd2, onProgress: (pct) => setState(() => _progress = pct), durationMs: _durationMs, onProcess: (p) => _active = p);
    }

    // finalize
    if (res.ok) {
      final finalPath = await _exportFinal(tempFilePath: tempOut);
      setState(() {
        _status = finalPath != null ? 'Saved: $finalPath' : 'Converted, but failed to save.';
        _progress = 1.0;
        _busy = false;
      });
      await _cleanupTemp();
      return;
    }

    if (res.cancelled) {
      setState(() {
        _status = 'Cancelled';
        _busy = false;
      });
    } else {
      setState(() {
        _status = 'Failed (code ${res.returnCode}).\n${_summarizeFailure(res.tailLog)}';
        _busy = false;
      });
    }
    await _cleanupTemp();
  }

  Future<String?> _exportFinal({required String tempFilePath}) async {
    try {
      final dir = Directory(opts.outputDir!);
      if (!await dir.exists()) await dir.create(recursive: true);
      final outPath = p.join(dir.path, opts.outputFileName);
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

  Future<void> _cleanupTemp() async {
    try {
      final tmp = await getTemporaryDirectory();
      final ff = Directory(p.join(tmp.path, 'FormatFlex'));
      if (await ff.exists()) await ff.delete(recursive: true);
    } catch (_) {}
  }

  String _summarizeFailure(String tail) {
    final lines = tail.split('\n').where((l) {
      final s = l.toLowerCase();
      return s.contains('error') || s.contains('failed') || s.contains('unable');
    }).toList();
    if (lines.isEmpty) return 'See logs for details.';
    return lines.length <= 6 ? lines.join('\n') : lines.sublist(lines.length - 6).join('\n');
  }

  Future<void> _cancel() async {
    try {
      _active?.kill(ProcessSignal.sigint);
      _active?.kill(ProcessSignal.sigterm);
      _active?.kill();
    } catch (_) {}
    setState(() => _busy = false);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canConvert = opts.input.isNotEmpty && opts.outputFileName.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Universal Video Converter (Windows)'),
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

          // Turbo mode
          SwitchListTile(
            title: const Text('Turbo mode (max speed)'),
            subtitle: const Text('H.264 + MP4, HW encode, stream copy when possible, keep FPS, HDR tone-map off'),
            value: opts.turbo,
            onChanged: _busy
                ? null
                : (v) => setState(() {
                    opts.turbo = v;
                    if (v) {
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
                    if (opts.input.isNotEmpty) _suggestOutputName(opts.input);
                  }),
          ),
          const SizedBox(height: 8),

          // FFmpeg folder (optional)
          TextField(
            onChanged: _busy ? null : (v) => opts.ffmpegDir = v.trim().isEmpty ? null : v.trim(),
            decoration: const InputDecoration(labelText: 'FFmpeg Folder (optional)', hintText: r'C:\ffmpeg\bin', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),

          Row(
            children: [
              Expanded(
                child: FilledButton.icon(onPressed: _busy ? null : _pickInput, icon: const Icon(Icons.video_file), label: const Text('Pick Video')),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(onPressed: _busy ? null : _chooseOutputFolder, child: const Text('Choose Output Folder…')),
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
              decoration: const InputDecoration(labelText: 'Full Output Path', border: OutlineInputBorder()),
            ),

          const SizedBox(height: 24),

          _Labeled(
            label: 'Preset',
            child: DropdownButtonFormField<Preset>(
              value: opts.preset,
              items: [for (final pz in kPresets) DropdownMenuItem(value: pz, child: Text(pz.name))],
              onChanged: _busy
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
              onChanged: _busy
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
              onChanged: _busy ? null : (v) => setState(() => opts.vcodec = v ?? opts.vcodec),
            ),
          ),
          const SizedBox(height: 12),

          _Labeled(
            label: 'Audio Codec',
            child: DropdownButtonFormField<ACodec>(
              value: opts.acodec,
              items: ACodec.values.map((e) => DropdownMenuItem(value: e, child: Text(e.label))).toList(),
              onChanged: _busy ? null : (v) => setState(() => opts.acodec = v ?? opts.acodec),
            ),
          ),
          const SizedBox(height: 12),

          _Labeled(
            label: 'Resolution',
            child: DropdownButtonFormField<Resolution>(
              value: opts.resolution,
              items: kResList.map((r) => DropdownMenuItem(value: r, child: Text(r.label))).toList(),
              onChanged: _busy
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
              onChanged: _busy ? null : (f) => setState(() => opts.fps = f),
            ),
          ),
          const SizedBox(height: 12),

          SwitchListTile(
            title: const Text('Use CRF (quality based)'),
            subtitle: const Text('Off = target bitrate'),
            value: opts.useCrf,
            onChanged: _busy ? null : (v) => setState(() => opts.useCrf = v),
          ),
          if (opts.useCrf)
            _NumberField(label: 'CRF (lower = better, typical 18–28)', value: opts.crf.toDouble(), min: 0, max: 51, onChanged: (v) => setState(() => opts.crf = v.round()))
          else
            _NumberField(
              label: 'Video Bitrate (kbps)',
              value: opts.vBitrateK.toDouble(),
              min: 250,
              max: 20000,
              step: 250,
              onChanged: (v) => setState(() => opts.vBitrateK = v.round()),
            ),

          const SizedBox(height: 12),
          _NumberField(label: 'Audio Bitrate (kbps)', value: opts.aBitrateK.toDouble(), min: 96, max: 768, step: 32, onChanged: (v) => setState(() => opts.aBitrateK = v.round())),
          const SizedBox(height: 12),

          _Labeled(
            label: 'Audio Channels',
            child: DropdownButtonFormField<int>(
              value: opts.audioChannels,
              items: [2, 6].map((c) => DropdownMenuItem(value: c, child: Text(c == 2 ? 'Stereo (2.0)' : '5.1 (6 ch)'))).toList(),
              onChanged: _busy ? null : (c) => setState(() => opts.audioChannels = c ?? opts.audioChannels),
            ),
          ),
          const SizedBox(height: 12),

          _Labeled(
            label: 'Sample Rate',
            child: DropdownButtonFormField<int>(
              value: opts.sampleRate,
              items: [44100, 48000].map((sr) => DropdownMenuItem(value: sr, child: Text('$sr Hz'))).toList(),
              onChanged: _busy ? null : (sr) => setState(() => opts.sampleRate = sr ?? opts.sampleRate),
            ),
          ),
          const SizedBox(height: 12),

          CheckboxListTile(
            value: opts.toneMapHdrToSdr,
            onChanged: _busy ? null : (v) => setState(() => opts.toneMapHdrToSdr = v ?? true),
            title: const Text('Tone-map HDR → SDR when needed'),
            subtitle: const Text('CPU tonemap by default; fastest when HDR not present'),
          ),
          const SizedBox(height: 12),

          SwitchListTile(
            title: const Text('Use hardware encoder (faster)'),
            subtitle: Text(
              'Detected: '
              '${_caps == null ? '…' : [if (_caps!.hasNVENC) 'NVENC', if (_caps!.hasQSV) 'QSV', if (_caps!.hasAMF) 'AMF'].join(', ').ifEmpty('none')}',
            ),
            value: opts.useHwEncoder,
            onChanged: _busy ? null : (v) => setState(() => opts.useHwEncoder = v),
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
          const _TipsBox(),
        ],
      ),
    );
  }
}

extension _EmptyX on String {
  String ifEmpty(String alt) => isEmpty ? alt : this;
}

extension _ListJoinX on List<String> {
  String ifEmpty(String alt) => isEmpty ? alt : join(', ');
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
  const _NumberField({required this.label, required this.value, required this.onChanged, this.min = 0, this.max = 100, this.step = 1});
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
              onChanged: (v) {
                setState(() => _v = v);
                widget.onChanged(v);
              },
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
            Text('• Prefer MP4 + H.264 + AAC/AC-3 for older TVs.'),
            Text('• 1080p or 720p often plays best on lower-end devices.'),
            Text('• HDR→SDR tone-mapping is CPU heavy—only enable if needed.'),
            Text('• AV1 is efficient but slow on CPU; use NVENC/AMF/QSV AV1 if supported.'),
          ],
        ),
      ),
    );
  }
}
