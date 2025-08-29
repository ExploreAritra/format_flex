// main_windows.dart
// Windows-only Flutter app that runs FFmpeg with robust logging, GPU usage, and validation.

import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// =============================================================
/// Simple structured logger with file output + in-app tail
/// =============================================================
class AppLog {
  AppLog._();
  static final AppLog I = AppLog._();

  final _listeners = <void Function(String)>[];
  final _tail = <String>[];
  File? _logFile;

  Future<void> init() async {
    try {
      final root = await getApplicationSupportDirectory();
      final dir = Directory(p.join(root.path, 'logs'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final now = DateTime.now();
      final name = '${now.year.toString().padLeft(4, "0")}-${now.month.toString().padLeft(2, "0")}-${now.day.toString().padLeft(2, "0")}.txt';
      _logFile = File(p.join(dir.path, name));
      _log('=== Log started ${now.toIso8601String()} ===');
    } catch (e, st) {
      debugPrint('[LOG][init] failed: $e\n$st');
    }
  }

  void addListener(void Function(String line) fn) => _listeners.add(fn);
  void removeListener(void Function(String line) fn) => _listeners.remove(fn);

  void _log(String line) {
    final ts = DateTime.now().toIso8601String(); // human-friendly precise timestamp
    final full = '[$ts] $line';
    debugPrint(full);

    // in-memory tail (last ~500 lines)
    _tail.add(full);
    if (_tail.length > 500) _tail.removeAt(0);
    for (final fn in _listeners) {
      try {
        fn(full);
      } catch (_) {}
    }

    // file
    try {
      _logFile?.writeAsStringSync(full + '\n', mode: FileMode.append, flush: false);
    } catch (_) {}
  }

  void i(String msg) => _log('[INFO] $msg');
  void w(String msg) => _log('[WARN] $msg');
  void e(String msg) => _log('[ERROR] $msg');

  List<String> tail([int n = 200]) => _tail.length <= n ? List.of(_tail) : _tail.sublist(_tail.length - n);

  Future<void> openLogFolder() async {
    try {
      final root = await getApplicationSupportDirectory();
      final dir = Directory(p.join(root.path, 'logs'));
      if (Platform.isWindows) {
        await Process.start('explorer.exe', [dir.path]);
      }
    } catch (e) {
      log('Failed to open logs folder: $e');
    }
  }
}

/// =============================================================
/// Models, enums, presets
/// =============================================================

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

enum ACodec { aac, ac3, eac3, opus, mp3, copy }

extension ACodecX on ACodec {
  String get ffmpegName => switch (this) {
    ACodec.aac => 'aac',
    ACodec.ac3 => 'ac3',
    ACodec.eac3 => 'eac3',
    ACodec.opus => 'libopus',
    ACodec.mp3 => 'libmp3lame',
    ACodec.copy => 'copy',
  };
  String get label => switch (this) {
    ACodec.aac => 'AAC',
    ACodec.ac3 => 'AC-3',
    ACodec.eac3 => 'E-AC-3',
    ACodec.opus => 'Opus',
    ACodec.mp3 => 'MP3',
    ACodec.copy => 'Copy (no re-encode)',
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

  // Optional: preferred ffmpeg folder containing ffmpeg.exe/ffprobe.exe
  String? ffmpegDir;

  // user-chosen tracks
  int videoStream = 0; // usually 0
  int? audioStream; // chosen index, null = auto

  // downmix 7.1->5.1 if requested or if target channels < source channels
  bool allowDownmix = true;

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

/// =============================================================
/// FFmpeg location and GPU capability discovery
/// =============================================================
class FfmpegBins {
  FfmpegBins(this.ffmpegDir);
  final String? ffmpegDir;

  String get ffmpeg => ffmpegDir == null || ffmpegDir!.isEmpty ? 'ffmpeg' : p.join(ffmpegDir!, 'ffmpeg.exe');
  String get ffprobe => ffmpegDir == null || ffmpegDir!.isEmpty ? 'ffprobe' : p.join(ffmpegDir!, 'ffprobe.exe');

  Future<bool> check() async {
    AppLog.I.i('Checking FFmpeg at: ffmpeg="$ffmpeg"  ffprobe="$ffprobe"');
    try {
      final pr = await Process.run(ffmpeg, ['-version']);
      final rr = await Process.run(ffprobe, ['-version']);
      AppLog.I.i('ffmpeg -version exit=${pr.exitCode}');
      AppLog.I.i('ffprobe -version exit=${rr.exitCode}');
      if (pr.exitCode != 0) AppLog.I.w('ffmpeg -version stdout: ${pr.stdout}\nstderr: ${pr.stderr}');
      if (rr.exitCode != 0) AppLog.I.w('ffprobe -version stdout: ${rr.stdout}\nstderr: ${rr.stderr}');
      return (pr.exitCode == 0 && rr.exitCode == 0);
    } catch (e, st) {
      AppLog.I.e('FFmpeg check failed: $e\n$st');
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
  bool get hasScaleQsv => filters.contains('scale_qsv');
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
      } else {
        AppLog.I.w('ffmpeg -encoders failed: ${e.exitCode}\n${e.stderr}');
      }
      if (f.exitCode == 0) {
        for (final line in LineSplitter.split(f.stdout.toString())) {
          final name = line.trim().split(RegExp(r'\s+')).first;
          if (name.isNotEmpty) caps.filters.add(name);
        }
      } else {
        AppLog.I.w('ffmpeg -filters failed: ${f.exitCode}\n${f.stderr}');
      }
      AppLog.I.i('GPU caps: encoders=${caps.encoders.length} filters=${caps.filters.length}');
    } catch (e, st) {
      AppLog.I.e('GPU caps probe failed: $e\n$st');
    }
    return caps;
  }
}

/// =============================================================
/// Media probe (ffprobe JSON)
/// =============================================================
class MediaProbeResult {
  final int? durationMs;
  final bool hasHdr;
  final int? width;
  final int? height;
  final String? vCodecName;
  final String? pixFmt;
  final List<_AudioTrack> audioTracks;

  MediaProbeResult({required this.durationMs, required this.hasHdr, this.width, this.height, this.vCodecName, this.pixFmt, required this.audioTracks});
}

class _AudioTrack {
  final int index;
  final String codec;
  final int? channels;
  final int? sampleRate;
  final String? lang;
  final String? title;

  _AudioTrack({required this.index, required this.codec, this.channels, this.sampleRate, this.lang, this.title});

  @override
  String toString() =>
      '#$index ${codec.toUpperCase()} ${channels ?? 0}ch ${sampleRate ?? 0}Hz'
      '${lang != null ? ' [$lang]' : ''}${title != null ? ' "$title"' : ''}';
}

class ConvertResult {
  final bool ok;
  final bool cancelled;
  final int? returnCode;
  final String tailLog;
  final String executedCmd;
  ConvertResult({required this.ok, required this.cancelled, required this.returnCode, required this.tailLog, required this.executedCmd});
}

/// =============================================================
/// FFmpeg service (Windows)
/// =============================================================
class FfmpegServiceWin {
  FfmpegServiceWin(this.bins, this.caps);
  final FfmpegBins bins;
  final GpuCaps caps;

  Future<MediaProbeResult> probe(String inputPath) async {
    AppLog.I.i('Probing media: "$inputPath"');
    try {
      final pr = await Process.run(bins.ffprobe, ['-v', 'error', '-print_format', 'json', '-show_streams', '-show_format', inputPath]);
      if (pr.exitCode != 0) {
        AppLog.I.w('ffprobe failed: ${pr.exitCode}\n${pr.stderr}');
        return MediaProbeResult(durationMs: null, hasHdr: false, audioTracks: const []);
      }
      final json = jsonDecode(pr.stdout.toString());
      final streams = (json['streams'] as List<dynamic>? ?? []);
      double? durSec;
      if (json['format'] != null && json['format']['duration'] != null) {
        durSec = double.tryParse(json['format']['duration'].toString());
      }
      int? w, h;
      String? vCodec, pix;
      bool hasHdr = false;

      final at = <_AudioTrack>[];

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
          at.add(
            _AudioTrack(
              index: int.tryParse(s['index']?.toString() ?? '') ?? 0,
              codec: (s['codec_name']?.toString() ?? 'unknown'),
              channels: int.tryParse(s['channels']?.toString() ?? ''),
              sampleRate: int.tryParse(s['sample_rate']?.toString() ?? ''),
              lang: (s['tags']?['language']?.toString()),
              title: (s['tags']?['title']?.toString()),
            ),
          );
        }
      }

      final res = MediaProbeResult(
        durationMs: durSec == null ? null : (durSec * 1000).round(),
        hasHdr: hasHdr,
        width: w,
        height: h,
        vCodecName: vCodec,
        pixFmt: pix,
        audioTracks: at,
      );
      AppLog.I.i('Probe: durMs=${res.durationMs} video=${res.width}x${res.height} v=$vCodec pix=$pix hdr=$hasHdr at=${at.length}');
      return res;
    } catch (e, st) {
      AppLog.I.e('Probe exception: $e\n$st');
      return MediaProbeResult(durationMs: null, hasHdr: false, audioTracks: const []);
    }
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

  int _even(int v) => (v & ~1);

  ({int w, int h}) bestFitSize({required int srcW, required int srcH, required int maxW, required int maxH}) {
    if (srcW <= 0 || srcH <= 0) return (w: maxW, h: maxH);
    final sw = maxW / srcW;
    final sh = maxH / srcH;
    final s = (sw < sh) ? sw : sh;
    final tw = _even((srcW * s).floor());
    final th = _even((srcH * s).floor());
    return (w: tw.clamp(2, maxW), h: th.clamp(2, maxH));
  }

  // Cheap runtime check for CUDA DLLs (prevents "Cannot load nvcuda.dll").
  bool _hasCudaRuntime() {
    try {
      final winDir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final sys32 = p.join(winDir, 'System32');
      final nvcuda = File(p.join(sys32, 'nvcuda.dll'));
      final nvencApi = File(p.join(sys32, 'nvEncodeAPI64.dll'));
      final ok = nvcuda.existsSync() && nvencApi.existsSync();
      if (!ok) {
        AppLog.I.i('CUDA runtime not found — will not add -hwaccel cuda');
      }
      return ok;
    } catch (e) {
      AppLog.I.w('CUDA runtime check failed: $e');
      return false;
    }
  }

  /// Build ffmpeg argv list (no shell quoting).
  List<String> buildCommand({
    required String input,
    required String output,
    required MediaProbeResult probe,
    required ConvertOptions o,
    bool forceSoftwareDecode = false,
    bool forceSoftwareEncode = false,
  }) {
    final turbo = o.turbo;
    final hdrToneMapRequested = o.toneMapHdrToSdr && probe.hasHdr && !turbo;

    final knowSize = (probe.width != null && probe.height != null);
    final needsScale = knowSize ? (probe.width! > o.resolution.w || probe.height! > o.resolution.h) : false;
    final srcW = probe.width ?? 0;
    final srcH = probe.height ?? 0;
    final target = needsScale ? bestFitSize(srcW: srcW, srcH: srcH, maxW: o.resolution.w, maxH: o.resolution.h) : (w: srcW, h: srcH);

    final VCodec effV = turbo ? VCodec.h264 : o.vcodec;
    final encName = forceSoftwareEncode ? effV.swName : pickEncoder(effV, requestHw: o.useHwEncoder || turbo);
    final usingHwEnc = !encName.startsWith('lib');

    final vCodecIn = (probe.vCodecName ?? '').toLowerCase();
    final sameCodec =
        (effV == VCodec.h264 && vCodecIn.contains('h264')) ||
        (effV == VCodec.hevc && (vCodecIn.contains('hevc') || vCodecIn.contains('h265'))) ||
        (effV == VCodec.vp9 && vCodecIn.contains('vp9')) ||
        (effV == VCodec.av1 && vCodecIn.contains('av1'));

    final pixOk = (probe.pixFmt == null) || probe.pixFmt!.contains('yuv420');
    final canCopyVideo = !hdrToneMapRequested && !needsScale && (turbo ? true : (o.fps == null)) && sameCodec && pixOk;

    // ---------- Filters ----------
    final vf = <String>[];
    final preGlobal = <String>[]; // e.g., -init_hw_device opencl=ocl -filter_hw_device ocl

    // Tone-map strategy
    final useOpenCLToneMap = hdrToneMapRequested && caps.hasTonemapOpenCL;

    // Prefer vendor scaling when staying on one GPU path
    final wantVendorScale = needsScale && usingHwEnc && !useOpenCLToneMap;
    final useScaleCuda = wantVendorScale && encName.contains('_nvenc') && caps.hasScaleCuda;
    final useScaleQsv = wantVendorScale && encName.contains('_qsv') && caps.hasScaleQsv;

    // 1) Tone-map chain
    if (useOpenCLToneMap) {
      preGlobal.addAll(['-init_hw_device', 'opencl=ocl', '-filter_hw_device', 'ocl']);
      vf.addAll(['format=p010le', 'hwupload', 'tonemap_opencl=tonemap=hable:desat=0', 'hwdownload', 'format=yuv420p']);
    } else if (hdrToneMapRequested) {
      vf.add('zscale=t=linear:npl=100,format=gbrpf32le,tonemap=hable,zscale=p=bt709:t=bt709:m=bt709,format=yuv420p');
    }

    // 2) Scaling chain
    if (needsScale) {
      if (useOpenCLToneMap) {
        vf.add('scale=w=${target.w}:h=${target.h}:flags=fast_bilinear');
      } else if (useScaleCuda) {
        vf.add('scale_cuda=w=${target.w}:h=${target.h}');
      } else if (useScaleQsv) {
        vf.add('scale_qsv=w=${target.w}:h=${target.h}');
      } else {
        vf.add('scale=w=${target.w}:h=${target.h}:flags=fast_bilinear');
      }
    }

    final vfChain = vf.isEmpty ? null : vf.join(',');

    // ---------- Decoder side (opportunistic, but SAFE) ----------
    final preInput = <String>[];
    if (!forceSoftwareDecode && usingHwEnc && !hdrToneMapRequested && !needsScale) {
      if (encName.contains('_nvenc')) {
        final canUseCuda = _hasCudaRuntime();
        final av1Input = vCodecIn.contains('av1'); // FFmpeg CUDA AV1 decode support varies; dav1d is safer
        if (canUseCuda && !av1Input) {
          preInput.addAll(['-hwaccel', 'cuda']);
          AppLog.I.i('HW decode: ON (-hwaccel cuda)');
        } else {
          AppLog.I.i('HW decode: OFF → ${canUseCuda ? "AV1 input; using CPU (dav1d)" : "CUDA DLLs missing"}');
        }
      } else if (encName.contains('_qsv')) {
        preInput.addAll(['-hwaccel', 'qsv']);
        AppLog.I.i('HW decode: ON (-hwaccel qsv)');
      } else if (encName.contains('_amf')) {
        preInput.addAll(['-hwaccel', 'd3d11va']);
        AppLog.I.i('HW decode: ON (-hwaccel d3d11va)');
      }
    } else {
      AppLog.I.i('HW decode: OFF (decode on CPU). usingHwEnc=$usingHwEnc hdrToneMap=$hdrToneMapRequested needsScale=$needsScale');
    }

    // ---------- Stream selection ----------
    final mapArgs = <String>[];
    mapArgs.addAll(['-map', '0:${o.videoStream}']);
    if (o.audioStream != null) {
      mapArgs.addAll(['-map', '0:${o.audioStream}']);
    }

    // ---------- Video encoder args ----------
    final vArgs = <String>[];
    if (canCopyVideo) {
      vArgs.addAll(['-c:v', 'copy']);
    } else {
      vArgs.addAll(['-c:v', encName]);
      if (encName.contains('_nvenc')) {
        final cq = o.useCrf ? o.crf.clamp(10, 40) : 23;
        vArgs.addAll(['-preset', o.turbo ? 'p1' : 'p4']);
        if (o.useCrf) {
          vArgs.addAll(['-rc', 'vbr', '-cq', '$cq']);
        } else {
          vArgs.addAll(['-b:v', '${o.vBitrateK}k']);
        }
        vArgs.addAll(['-pix_fmt', 'yuv420p']);
        if (o.container == ContainerFmt.mp4 && effV == VCodec.hevc) {
          vArgs.addAll(['-tag:v', 'hvc1']);
        }
      } else if (encName.contains('_qsv')) {
        if (o.useCrf) {
          final gq = (o.crf + 2).clamp(18, 42);
          vArgs.addAll(['-rc', 'icq', '-global_quality', '$gq']);
        } else {
          vArgs.addAll(['-b:v', '${o.vBitrateK}k']);
        }
        vArgs.addAll(['-pix_fmt', 'nv12']);
        if (o.container == ContainerFmt.mp4 && effV == VCodec.hevc) {
          vArgs.addAll(['-tag:v', 'hvc1']);
        }
      } else if (encName.contains('_amf')) {
        vArgs.addAll(['-quality', o.turbo ? 'speed' : 'balanced']);
        if (o.useCrf) {
          vArgs.addAll(['-rc', 'vbr', '-q', '${o.crf}']);
        } else {
          vArgs.addAll(['-b:v', '${o.vBitrateK}k']);
        }
        vArgs.addAll(['-pix_fmt', 'yuv420p']);
        if (o.container == ContainerFmt.mp4 && effV == VCodec.hevc) {
          vArgs.addAll(['-tag:v', 'hvc1']);
        }
      } else {
        // software encoders
        switch (effV) {
          case VCodec.h264:
            vArgs.addAll(['-preset', o.turbo ? 'superfast' : 'veryfast', '-profile:v', 'high', '-pix_fmt', 'yuv420p']);
            if (o.useCrf)
              vArgs.addAll(['-crf', '${o.crf}']);
            else
              vArgs.addAll(['-b:v', '${o.vBitrateK}k']);
            break;
          case VCodec.hevc:
            vArgs.addAll(['-preset', o.turbo ? 'ultrafast' : 'fast', '-pix_fmt', 'yuv420p']);
            if (o.container == ContainerFmt.mp4) vArgs.addAll(['-tag:v', 'hvc1']);
            if (o.useCrf)
              vArgs.addAll(['-crf', '${o.crf}']);
            else
              vArgs.addAll(['-b:v', '${o.vBitrateK}k']);
            break;
          case VCodec.vp9:
            vArgs.addAll([
              '-deadline',
              o.turbo ? 'realtime' : 'good',
              '-cpu-used',
              o.turbo ? '8' : '2',
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
            vArgs.addAll(['-cpu-used', o.turbo ? '10' : '8', '-pix_fmt', 'yuv420p']);
            if (o.useCrf) {
              vArgs.addAll(['-crf', '${o.crf}', '-b:v', '0']);
            } else {
              vArgs.addAll(['-b:v', '${o.vBitrateK}k']);
            }
            break;
        }
      }
    }

    // ---------- Audio ----------
    final aArgs = <String>[];
    if (o.acodec == ACodec.copy && o.audioStream == null) {
      AppLog.I.w('Audio set to copy but no specific stream selected; falling back to codec-based decision.');
    }

    _AudioTrack? srcTrack;
    if (o.audioStream != null) {
      srcTrack = probe.audioTracks.firstWhere(
        (t) => t.index == o.audioStream,
        orElse: () => probe.audioTracks.isNotEmpty ? probe.audioTracks.first : _AudioTrack(index: 1, codec: 'unknown'),
      );
    } else {
      srcTrack = probe.audioTracks.isNotEmpty ? probe.audioTracks.first : null;
    }
    final needDownmix = o.allowDownmix && srcTrack != null && srcTrack.channels != null && srcTrack.channels! > o.audioChannels;

    if (o.acodec == ACodec.copy && needDownmix) {
      AppLog.I.i('Forcing audio re-encode because downmix ${srcTrack.channels} -> ${o.audioChannels}');
    }

    final canCopyAudioCodec =
        (o.acodec == ACodec.copy) ||
        (srcTrack != null &&
            ((o.acodec == ACodec.aac && srcTrack.codec == 'aac') ||
                (o.acodec == ACodec.ac3 && srcTrack.codec == 'ac3') ||
                (o.acodec == ACodec.eac3 && srcTrack.codec == 'eac3') ||
                (o.acodec == ACodec.opus && srcTrack.codec == 'opus') ||
                (o.acodec == ACodec.mp3 && srcTrack.codec == 'mp3')));

    if (canCopyAudioCodec && !needDownmix && o.sampleRate <= 0) {
      aArgs.addAll(['-c:a', 'copy']);
    } else {
      aArgs.addAll(['-c:a', o.acodec == ACodec.copy ? 'aac' : o.acodec.ffmpegName, '-b:a', '${o.aBitrateK}k', '-ac', '${o.audioChannels}']);
      if (o.sampleRate > 0) aArgs.addAll(['-ar', '${o.sampleRate}']);
    }

    final fpsArgs = (turbo ? <String>[] : (o.fps != null ? ['-r', o.fps!.toString()] : <String>[]));
    final movFlags = (o.container == ContainerFmt.mp4) ? ['-movflags', '+faststart'] : <String>[];

    final args = <String>[
      ...preGlobal,
      '-y',
      '-v',
      'verbose',
      '-hide_banner',
      '-stats_period',
      '0.5',
      ...preInput,
      '-i',
      input,
      ...mapArgs,
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
    return args;
  }

  Future<ConvertResult> convert({
    required List<String> args,
    required void Function(double pct, {int? outUs, double? speedX, int? frame}) onProgress,
    required int? durationMs,
    required String outputPath,
    void Function(Process p)? onProcess,
  }) async {
    final ff = bins.ffmpeg;
    final cmdForCopyPaste = '$ff ${args.map((a) => a.contains(' ') ? '"$a"' : a).join(' ')}';
    AppLog.I.i('Launching FFmpeg:\n$cmdForCopyPaste');

    Process proc;
    try {
      proc = await Process.start(ff, args, mode: ProcessStartMode.normal);
    } catch (e, st) {
      AppLog.I.e('Process.start failed: $e\n$st');
      return ConvertResult(ok: false, cancelled: false, returnCode: -1, tailLog: 'Spawn failed: $e', executedCmd: cmdForCopyPaste);
    }

    onProcess?.call(proc);

    // ---- Progress state ----
    final totalUs = (durationMs ?? 0) > 0 ? durationMs! * 1000 : null;
    int? lastOutUs;
    int? lastFrame;
    double? lastFps;
    double? lastSpeed;
    double lastPct = 0.0;
    bool sawEnd = false;

    // nudge the bar so it isn’t stuck during warmup
    try {
      onProgress(0.001, outUs: 0, speedX: null, frame: null);
    } catch (_) {}

    // ---- Tail capture + logging ----
    final tail = <String>[];
    void add(String s) {
      if (s.isEmpty) return;
      tail.add(s);
      if (tail.length > 400) tail.removeAt(0);
      AppLog.I.i(s);
    }

    void consume(String line) {
      // Parse -progress key=value
      // We’ve seen ffmpeg write microseconds to both out_time_us and out_time_ms in some builds.
      if (line.startsWith('out_time_us=')) {
        final v = int.tryParse(line.substring(12).trim());
        if (v != null) lastOutUs = v;
      } else if (line.startsWith('out_time_ms=')) {
        final v = int.tryParse(line.substring(12).trim());
        if (v != null) lastOutUs = v; // treat as µs like in your logs
      } else if (line.startsWith('frame=')) {
        lastFrame = int.tryParse(line.substring(6).trim());
      } else if (line.startsWith('fps=')) {
        lastFps = double.tryParse(line.substring(4).trim());
      } else if (line.startsWith('speed=')) {
        final s = line.substring(6).trim(); // e.g. "2.67x"
        lastSpeed = double.tryParse(s.replaceAll('x', '').trim());
      } else if (line.startsWith('progress=')) {
        final state = line.substring(9).trim();
        if (state == 'end') {
          sawEnd = true;
        }
      }

      // Emit progress updates
      if (totalUs != null && totalUs > 0 && lastOutUs != null) {
        double pct = (lastOutUs! / totalUs).clamp(0.0, 1.0);
        if (pct < lastPct) pct = lastPct; // monotonic
        if (pct >= 0.999 && !sawEnd) pct = 0.999; // don’t hit 100% until end
        lastPct = pct;
        try {
          onProgress(pct, outUs: lastOutUs, speedX: lastSpeed, frame: lastFrame);
        } catch (_) {}
      }

      if (sawEnd && lastPct < 1.0) {
        try {
          onProgress(1.0, outUs: lastOutUs, speedX: lastSpeed, frame: lastFrame);
        } catch (_) {}
        lastPct = 1.0;
      }
    }

    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      add('[ffmpeg-out] $line');
      consume(line);
    });

    proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      add('[ffmpeg-err] $line');
      consume(line); // some builds emit progress keys on stderr
    });

    final code = await proc.exitCode;
    AppLog.I.i('FFmpeg exited with code $code');

    // Post validation: check the output file exists and has non-zero size.
    bool ok = (code == 0);
    int size = 0;
    try {
      final f = File(outputPath);
      if (await f.exists()) {
        size = await f.length();
      } else {
        ok = false;
        AppLog.I.e('Output file not found at "$outputPath"');
      }
      if (size <= 0) {
        ok = false;
        AppLog.I.e('Output file size is zero at "$outputPath"');
      }
    } catch (e) {
      ok = false;
      AppLog.I.e('Failed to validate output "$outputPath": $e');
    }

    if (ok && lastPct < 1.0) {
      try {
        onProgress(1.0, outUs: lastOutUs, speedX: lastSpeed, frame: lastFrame);
      } catch (_) {}
    }

    final last = tail.skip(tail.length > 120 ? tail.length - 120 : 0).join('\n');
    return ConvertResult(ok: ok, cancelled: false, returnCode: code, tailLog: last, executedCmd: cmdForCopyPaste);
  }
}

/// =============================================================
/// App UI (Windows only)
/// =============================================================
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLog.I.init();
  runApp(const ConverterApp());
}

class ConverterApp extends StatelessWidget {
  const ConverterApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Universal Video Converter (Windows)',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.redAccent),
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
  bool _showLog = false;

  ConvertOptions opts = ConvertOptions()..applyPreset(kPresets[1]);
  late FfmpegBins _bins;
  GpuCaps? _caps;
  Process? _active; // for cancel
  String _lastCmd = '';

  // Finds "<exe_dir>\ffmpeg\bin" or nearby
  String? findBundledFfmpegBin() {
    String? hit0(String dir) {
      final ff = File(p.join(dir, 'ffmpeg.exe'));
      final fp = File(p.join(dir, 'ffprobe.exe'));
      return (ff.existsSync() && fp.existsSync()) ? p.normalize(dir) : null;
    }

    final exeDir = p.dirname(Platform.resolvedExecutable);
    final cwd = Directory.current.path;

    final candidates = <String>[p.join(exeDir, 'ffmpeg', 'bin'), p.join(exeDir, '..', 'ffmpeg', 'bin'), p.join(exeDir, '..', '..', 'ffmpeg', 'bin'), p.join(cwd, 'ffmpeg', 'bin')];

    for (final c in candidates) {
      final hit = hit0(c);
      if (hit != null) return hit;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _initDefaults();
    AppLog.I.addListener(_onLogLine);
  }

  void _onLogLine(String _) {
    if (_showLog && mounted) setState(() {}); // refresh tail area
  }

  Future<void> _initDefaults() async {
    opts.outputDir = await _suggestDefaultFolder();

    final localBin = findBundledFfmpegBin();
    if (localBin != null) {
      opts.ffmpegDir = localBin;
    } // else: leave null => PATH

    _bins = FfmpegBins(opts.ffmpegDir);
    final ok = await _bins.check();
    setState(() => _status = ok ? 'Ready' : 'FFmpeg not found. Add to PATH or set folder below.');

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
    } catch (e, st) {
      AppLog.I.w('Suggest default folder failed: $e\n$st');
    }
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
    AppLog.I.i('Picked input: $path');
    await _suggestOutputName(path);
    setState(() {
      opts.input = path;
      _status = 'Ready';
    });
    await _probeInput();
  }

  Future<void> _probeInput() async {
    final svc = FfmpegServiceWin(_bins, _caps ?? GpuCaps());
    final pr = await svc.probe(opts.input);
    _durationMs = pr.durationMs;
    // If there's any audio, default audioStream to first track
    if (pr.audioTracks.isNotEmpty && opts.audioStream == null) {
      opts.audioStream = pr.audioTracks.first.index;
    }
    setState(() {});
  }

  Future<void> _chooseOutputFolder() async {
    final chosen = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Choose output folder');
    if (chosen != null) {
      AppLog.I.i('Output folder chosen: $chosen');
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
    final args1 = svc.buildCommand(input: opts.input, output: tempOut, probe: probe, o: opts);
    setState(() => _status = 'Converting… (HW accel when available)');

    final res1 = await svc.convert(
      args: args1,
      onProgress: (pct, {outUs, speedX, frame}) {
        setState(() {
          _progress = pct;
          _status = _prettyProgress(outUs, _durationMs, speedX);
        });
      },
      durationMs: _durationMs,
      outputPath: tempOut,
      onProcess: (p) => _active = p,
    );
    _lastCmd = res1.executedCmd;

    bool ok = res1.ok;
    var finalRes = res1;

    // Attempt #2: force SW path if needed
    if (!ok && (res1.returnCode != 0 || res1.returnCode == null)) {
      setState(() {
        _status = 'HW path failed — retrying with software encoding…';
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
        ..ffmpegDir = opts.ffmpegDir
        ..videoStream = opts.videoStream
        ..audioStream = opts.audioStream
        ..allowDownmix = opts.allowDownmix;

      final args2 = svc.buildCommand(input: opts.input, output: tempOut, probe: probe, o: soft, forceSoftwareDecode: true, forceSoftwareEncode: true);
      final res2 = await svc.convert(
        args: args2,
        onProgress: (pct, {outUs, speedX, frame}) {
          setState(() {
            _progress = pct;
            _status = _prettyProgress(outUs, _durationMs, speedX);
          });
        },
        durationMs: _durationMs,
        outputPath: tempOut,
        onProcess: (p) => _active = p,
      );
      _lastCmd = res2.executedCmd;
      ok = res2.ok;
      finalRes = res2;
    }

    // finalize
    if (ok) {
      final finalPath = await _exportFinal(tempFilePath: tempOut);
      if (finalPath != null) {
        setState(() {
          _status = 'Saved: $finalPath';
          _progress = 1.0;
          _busy = false;
        });
        AppLog.I.i('Saved to final path: $finalPath');
      } else {
        setState(() {
          _status = 'Converted, but failed to save to output folder.';
          _busy = false;
        });
        AppLog.I.e('Failed to move temp output to final folder.');
      }
      await _cleanupTemp();
      return;
    }

    setState(() {
      _status = 'Failed (code ${finalRes.returnCode}). See logs (bottom) or open logs folder.';
      _busy = false;
    });
    AppLog.I.e('Conversion failed.\nTail:\n${finalRes.tailLog}');
    await _cleanupTemp();
  }

  Future<String?> _exportFinal({required String tempFilePath}) async {
    try {
      final dir = Directory(opts.outputDir!);
      if (!await dir.exists()) await dir.create(recursive: true);
      final outPath = p.join(dir.path, opts.outputFileName);
      final out = File(outPath);
      if (await out.exists()) {
        await out.delete();
      }
      await File(tempFilePath).copy(outPath);
      try {
        await File(tempFilePath).delete();
      } catch (_) {}
      // validate final as well
      if (await File(outPath).exists() && await File(outPath).length() > 0) {
        return outPath;
      }
      return null;
    } catch (e, st) {
      AppLog.I.e('Export final failed: $e\n$st');
      return null;
    }
  }

  Future<void> _cleanupTemp() async {
    try {
      final tmp = await getTemporaryDirectory();
      final ff = Directory(p.join(tmp.path, 'FormatFlex'));
      if (await ff.exists()) await ff.delete(recursive: true);
    } catch (e) {
      AppLog.I.w('Cleanup temp failed: $e');
    }
  }

  Future<void> _cancel() async {
    try {
      _active?.stdin.add(utf8.encode('q')); // graceful
      await Future.delayed(const Duration(milliseconds: 200));
      _active?.kill(ProcessSignal.sigint); // best-effort on Windows
      _active?.kill(); // hard kill
      AppLog.I.i('Cancellation requested.');
    } catch (e) {
      AppLog.I.w('Cancel failed: $e');
    }
    setState(() => _busy = false);
  }

  @override
  void dispose() {
    AppLog.I.removeListener(_onLogLine);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canConvert = opts.input.isNotEmpty && opts.outputFileName.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Universal Video Converter (Windows)'),
        actions: [
          IconButton(
            tooltip: 'Copy last command',
            onPressed: _lastCmd.isEmpty ? null : () => Clipboard.setData(ClipboardData(text: _lastCmd)),
            icon: const Icon(Icons.content_copy),
          ),
          IconButton(tooltip: 'Open logs folder', onPressed: () => AppLog.I.openLogFolder(), icon: const Icon(Icons.folder_open)),
          IconButton(onPressed: _busy ? _cancel : null, icon: const Icon(Icons.close), tooltip: 'Cancel'),
        ],
      ),
      body: ListView(
        controller: _scroll,
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Status: $_status'
            '${opts.ffmpegDir != null ? "  (FFmpeg: ${opts.ffmpegDir})" : ""}',
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: LinearProgressIndicator(value: _progress == 0 ? null : _progress)),
              SizedBox(width: 60, child: Text('${(_progress * 100).toStringAsFixed(1)}%', textAlign: TextAlign.right)),
            ],
          ),
          const SizedBox(height: 16),

          // Toggle log tail
          Row(
            children: [
              Switch(value: _showLog, onChanged: (v) => setState(() => _showLog = v)),
              const SizedBox(width: 8),
              const Text('Show live log'),
            ],
          ),
          if (_showLog) _LogTail(),

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
            onChanged: _busy
                ? null
                : (v) {
                    setState(() => opts.ffmpegDir = v.trim().isEmpty ? null : v.trim());
                  },
            decoration: const InputDecoration(labelText: 'FFmpeg Folder (optional)', hintText: r'C:\path\to\ffmpeg\bin', border: OutlineInputBorder()),
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
              onChanged: _busy ? null : (c) => setState(() => opts.audioChannels = c ?? 2),
            ),
          ),
          const SizedBox(height: 12),

          _Labeled(
            label: 'Sample Rate',
            child: DropdownButtonFormField<int>(
              value: opts.sampleRate,
              items: [44100, 48000].map((sr) => DropdownMenuItem(value: sr, child: Text('$sr Hz'))).toList(),
              onChanged: _busy ? null : (sr) => setState(() => opts.sampleRate = sr ?? 48000),
            ),
          ),
          const SizedBox(height: 12),

          CheckboxListTile(
            value: opts.toneMapHdrToSdr,
            onChanged: _busy ? null : (v) => setState(() => opts.toneMapHdrToSdr = v ?? true),
            title: const Text('Tone-map HDR → SDR when needed'),
            subtitle: const Text('OpenCL/CPU depending on availability'),
          ),
          const SizedBox(height: 12),

          SwitchListTile(
            title: const Text('Use hardware encoder (faster)'),
            subtitle: Text(
              'Detected: ${_caps == null ? "…" : [if (_caps!.hasNVENC) "NVENC", if (_caps!.hasQSV) "QSV", if (_caps!.hasAMF) "AMF"].join(", ").ifEmpty("none")} — '
              '${_caps?.hasTonemapOpenCL == true ? "OpenCL tonemap ✓" : "OpenCL tonemap ✗"}',
            ),
            value: opts.useHwEncoder,
            onChanged: _busy ? null : (v) => setState(() => opts.useHwEncoder = v),
          ),

          const SizedBox(height: 16),

          // Track pickers
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
                      decoration: InputDecoration(
                        hintText: '(auto)',
                        border: const OutlineInputBorder(),
                        helperText: 'Pick track index if needed',
                        suffixText: opts.audioStream?.toString() ?? 'auto',
                      ),
                    ),
                  ),
                ),
              ],
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

extension _StringIfEmpty on String {
  String ifEmpty(String alt) => isEmpty ? alt : this;
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
            Text('• Turbo: H.264 + MP4, HW encode, stream copy when possible, keep FPS.'),
            Text('• Prefer MP4 + H.264 + AAC/AC-3 for older TVs.'),
            Text('• 1080p or 720p often plays best on lower-end devices.'),
            Text('• HDR→SDR tone-mapping can be heavy; OpenCL/CPU used as available.'),
            Text('• AV1 is efficient but slow on CPU; use NVENC/AMF/QSV AV1 if supported.'),
          ],
        ),
      ),
    );
  }
}

/// Compact log tail widget
class _LogTail extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final lines = AppLog.I.tail(150).join('\n');
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
