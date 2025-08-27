// Universal Video Converter — modular single-file edition
// If you prefer, split sections into lib/models, lib/services, lib/ui.

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// NEW: use the maintained fork
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';

void main() => runApp(const ConverterApp());

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
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: const ConverterHome(),
    );
  }
}

// =============================================================
// Models (could live in lib/models)
// =============================================================

enum ContainerFmt { mp4, mkv, webm }
extension ContainerFmtX on ContainerFmt {
  String get label => switch (this) { ContainerFmt.mp4 => 'MP4', ContainerFmt.mkv => 'MKV', ContainerFmt.webm => 'WebM' };
  String get ext => switch (this) { ContainerFmt.mp4 => 'mp4', ContainerFmt.mkv => 'mkv', ContainerFmt.webm => 'webm' };
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

class Resolution { final int w; final int h; final String label; const Resolution(this.w, this.h, this.label); }
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
  final bool useCrf; // true: CRF/Quality, false: target bitrate
  final int crf; // 18-28 typical
  final int vBitrateK; // if useCrf=false
  final int aBitrateK;
  final int audioChannels; // 2 or 6
  final int sampleRate; // 44100/48000
  final double? fps; // null to keep
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
    useCrf: true, crf: 20, twoPass: false,
    aBitrateK: 192, audioChannels: 2,
  ),
  Preset(
    name: 'Smart TV Legacy (1080p H.264 + AC-3 5.1)',
    container: ContainerFmt.mp4,
    vCodec: VCodec.h264,
    aCodec: ACodec.ac3,
    resolution: res1080,
    useCrf: true, crf: 19, twoPass: false,
    aBitrateK: 448, audioChannels: 6,
  ),
  Preset(
    name: 'Streaming-Optimized (720p H.264 + AAC)',
    container: ContainerFmt.mp4,
    vCodec: VCodec.h264,
    aCodec: ACodec.aac,
    resolution: res720,
    useCrf: true, crf: 22, twoPass: false,
    aBitrateK: 160, audioChannels: 2,
  ),
  Preset(
    name: 'Space Saver (1080p HEVC + AAC)',
    container: ContainerFmt.mkv,
    vCodec: VCodec.hevc,
    aCodec: ACodec.aac,
    resolution: res1080,
    useCrf: true, crf: 24, twoPass: false,
    aBitrateK: 160, audioChannels: 2,
  ),
  Preset(
    name: '4K Archive (2160p HEVC + AC-3 5.1)',
    container: ContainerFmt.mkv,
    vCodec: VCodec.hevc,
    aCodec: ACodec.ac3,
    resolution: res4k,
    useCrf: true, crf: 22, twoPass: false,
    aBitrateK: 448, audioChannels: 6,
  ),
  Preset(
    name: 'Web (1080p VP9 + Opus)',
    container: ContainerFmt.webm,
    vCodec: VCodec.vp9,
    aCodec: ACodec.opus,
    resolution: res1080,
    useCrf: false, vBitrateK: 4500, twoPass: true,
    aBitrateK: 160, audioChannels: 2,
  ),
  Preset(
    name: 'Next-Gen (1080p AV1 + Opus)',
    container: ContainerFmt.mkv,
    vCodec: VCodec.av1,
    aCodec: ACodec.opus,
    resolution: res1080,
    useCrf: true, crf: 28, twoPass: false,
    aBitrateK: 160, audioChannels: 2,
  ),
];

class ConvertOptions {
  String input = '';
  String output = '';

  // NEW: user-chosen output pieces
  String? outputDir; // e.g., /Movies/FormatFlex (Android/desktop)
  String outputFileName = '';

  Preset preset = kPresets.first;

  // Individual overrides
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
  double? fps; // null = keep
  bool toneMapHdrToSdr = true;

  // NEW: hardware encoder toggle
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
// Services (could live in lib/services)
// =============================================================

class MediaProbeResult {
  final int? durationMs;
  final bool hasHdr;
  MediaProbeResult({required this.durationMs, required this.hasHdr});
}

class FfmpegService {
  Future<MediaProbeResult> probe(String inputPath) async {
    final probe = await FFprobeKit.getMediaInformation(inputPath);
    final info = probe.getMediaInformation();
    if (info == null) return MediaProbeResult(durationMs: null, hasHdr: false);
    int? durationMs;
    final d = double.tryParse(info.getDuration() ?? '');
    if (d != null) durationMs = (d * 1000).round();
    final streams = info.getStreams() ?? []; // <-- null-safe
    final hasHdr = _hasHdrColor(streams);
    return MediaProbeResult(durationMs: durationMs, hasHdr: hasHdr);
  }

  bool _hasHdrColor(List<dynamic> streams) {
    try {
      for (final s in streams) {
        if (s['type'] == 'video') {
          final ct = (s['color_transfer'] ?? '').toString().toLowerCase();
          final cp = (s['color_primaries'] ?? '').toString().toLowerCase();
          if (ct.contains('smpte2084') || cp.contains('bt2020')) return true;
        }
      }
    } catch (_) {}
    return false;
  }

  String buildCommand({
    required String input,
    required String output,
    required bool hasHdr,
    required ConvertOptions o,
  }) {
    final vfScalePad = 'scale=w=${o.resolution.w}:h=${o.resolution.h}:force_original_aspect_ratio=decrease,pad=${o.resolution.w}:${o.resolution.h}:(ow-iw)/2:(oh-ih)/2';
    final vfHdr = 'zscale=t=linear:npl=100,format=gbrpf32le,tonemap=hable,zscale=p=bt709:t=bt709:m=bt709,format=yuv420p';
    final vfChain = (o.toneMapHdrToSdr && hasHdr) ? '$vfHdr,$vfScalePad' : vfScalePad;

    // --- Video encoder selection (HW/SW) ---
    String vEnc = o.vcodec.ffmpegName; // default software encoders
    if (o.useHwEncoder) {
      if (Platform.isAndroid) {
        if (o.vcodec == VCodec.h264) vEnc = 'h264_mediacodec';
        if (o.vcodec == VCodec.hevc) vEnc = 'hevc_mediacodec';
      } else if (Platform.isIOS || Platform.isMacOS) {
        if (o.vcodec == VCodec.h264) vEnc = 'h264_videotoolbox';
        if (o.vcodec == VCodec.hevc) vEnc = 'hevc_videotoolbox';
      }
      // VP9/AV1 hardware varies; fall back to software for those here.
    }

    final vArgs = <String>['-c:v', vEnc];

    if (o.useHwEncoder && (vEnc.contains('mediacodec') || vEnc.contains('videotoolbox'))) {
      // Prioritize speed; many encoder-specific options are ignored by HW drivers
      vArgs.addAll(['-b:v', '${o.vBitrateK}k', '-pix_fmt', 'yuv420p']);
      if (vEnc.contains('videotoolbox')) { vArgs.addAll(['-allow_sw', '1']); }
      if (vEnc.contains('mediacodec')) { vArgs.addAll(['-g', '240']); }
    } else {
      // Software encoders (previous behavior, with slightly faster presets)
      switch (o.vcodec) {
        case VCodec.h264:
          vArgs.addAll(['-preset', 'veryfast', '-profile:v', 'high', '-pix_fmt', 'yuv420p']);
          if (o.useCrf) {
            vArgs.addAll(['-crf', '${o.crf}']);
          } else {
            vArgs.addAll(['-b:v', '${o.vBitrateK}k']);
          }
          break;
        case VCodec.hevc:
          vArgs.addAll(['-preset', 'fast', '-pix_fmt', 'yuv420p', '-tag:v', 'hvc1']);
          if (o.useCrf) {
            vArgs.addAll(['-crf', '${o.crf}']);
          } else {
            vArgs.addAll(['-b:v', '${o.vBitrateK}k']);
          }
          break;
        case VCodec.vp9:
          vArgs.addAll(['-b:v', '${o.vBitrateK}k', '-pix_fmt', 'yuv420p', '-deadline', 'good', '-cpu-used', '2']);
          break;
        case VCodec.av1:
          vArgs.addAll(['-pix_fmt', 'yuv420p', '-cpu-used', '8']);
          if (o.useCrf) {
            vArgs.addAll(['-crf', '${o.crf}', '-b:v', '0']);
          } else {
            vArgs.addAll(['-b:v', '${o.vBitrateK}k']);
          }
          break;
      }
    }

    final aArgs = <String>['-c:a', o.acodec.ffmpegName, '-b:a', '${o.aBitrateK}k', '-ac', '${o.audioChannels}', '-ar', '${o.sampleRate}'];
    final fpsArgs = o.fps != null ? ['-r', o.fps!.toString()] : <String>[];
    final movFlags = (o.container == ContainerFmt.mp4) ? ['-movflags', '+faststart'] : <String>[];

    final args = <String>[
      '-y', '-hide_banner',
      '-threads', '0',
      '-i', '"$input"',
      '-vf', '"$vfChain"',
      ...fpsArgs,
      ...vArgs,
      ...aArgs,
      ...movFlags,
      output.startsWith('saf:') ? output : '"$output"',
    ];
    return args.join(' ');
  }

  Future<void> convert({
    required String cmd,
    required void Function(double pct) onProgress,
    required void Function(String status) onDone,
    required void Function(String status) onError,
    void Function(int id)? onSession,
  }) async {
    // capture FFmpeg logs (keep last ~200 lines)
    final List<String> _tail = [];
    FFmpegKitConfig.enableLogCallback((log) {
      final line = log.getMessage() ?? '';
      _tail.add(line);
      if (_tail.length > 200) _tail.removeAt(0);
    });

    FFmpegKitConfig.enableStatisticsCallback((Statistics s) => onProgress(_pct(s)));

    final session = await FFmpegKit.executeAsync(
      cmd,
          (session) async {
        final rc = await session.getReturnCode();
        if (ReturnCode.isSuccess(rc)) {
          onDone('Success');
        } else if (ReturnCode.isCancel(rc)) {
          onError('Cancelled');
        } else {
          // include the last lines in status for easier diagnosis from UI/logcat
          final lastLines = _tail.skip(_tail.length > 80 ? _tail.length - 80 : 0).join('\n');
          onError('Failed (code ${rc?.getValue()})\n$lastLines');
        }
      },
    );
    onSession?.call(session.getSessionId() ?? 0);
  }


  double _pct(Statistics s) {
    // We cannot know duration here; UI maps it when available. Returning 0..1 when time is known.
    final t = s.getTime();
    if (t <= 0) return 0.0; // UI will clamp via duration
    return t / 1000.0; // raw seconds processed, UI will divide by duration
  }
}

class PathService {
  // Suggest default folder like /Movies/FormatFlex (Android/Desktop)
  Future<String> suggestDefaultFolder() async {
    // Android/Desktop: try external storage Movies/FormatFlex; fallback to cache
    try {
      final dir = await getExternalStorageDirectory();
      if (dir != null) {
        final movies = Directory(p.join(dir.path.split('Android').first, 'Movies', 'FormatFlex'));
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
    // Directory picker works on Android/desktop. iOS may return null.
    return FilePicker.platform.getDirectoryPath(dialogTitle: 'Choose output folder');
  }
}

// =============================================================
// UI (could live in lib/ui)
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
  double _progress = 0.0; // 0..1
  int? _durationMs;
  int? _sessionId;
  bool _busy = false; // NEW: disable controls while converting
  String? _safWriteUri; // keeps SAF output URI so we can refresh 'saf:' path on retries


  ConvertOptions opts = ConvertOptions()..applyPreset(kPresets[1]);

  @override
  void initState() {
    super.initState();
    _initDefaultFolder();
  }

  Future<void> _initDefaultFolder() async {
    final def = await _paths.suggestDefaultFolder();
    if (mounted) setState(() => opts.outputDir = def);
  }

  @override
  void dispose() {
    FFmpegKitConfig.disableStatistics();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _pickInput() async {
    setState(() { _status = 'Picking input…'; _progress = 0; });
    final result = await FilePicker.platform.pickFiles(type: FileType.video);
    if (result == null || result.files.isEmpty) { setState(() => _status = 'Cancelled'); return; }
    final path = result.files.single.path;
    if (path == null) { setState(() => _status = 'Invalid selection'); return; }
    await _suggestOutputName(path);
    setState(() { opts.input = path; _status = 'Ready'; });
  }

  Future<void> _chooseOutputFolder() async {
    final chosen = await _paths.pickOutputFolder();
    if (chosen != null) {
      setState(() { opts.outputDir = chosen; });
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

  Future<bool> _ensureOutputDirWritable(String fullPath) async {
    try {
      final parent = Directory(p.dirname(fullPath));
      if (!await parent.exists()) await parent.create(recursive: true);
      final probeFile = File(p.join(parent.path, '.ff_out_test'));
      await probeFile.writeAsString('ok');
      await probeFile.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _pickSafOutputFile(String suggestedName) async {
    try {
      final uri = await FFmpegKitConfig.selectDocumentForWrite(
        suggestedName.isEmpty ? 'output.${opts.container.ext}' : suggestedName,
        'video/*',
      );
      if (uri == null) return null;
      _safWriteUri = uri; // <-- remember it for retries
      final safUrl = await FFmpegKitConfig.getSafParameterForWrite(uri);
      return safUrl; // e.g., "saf:3"
    } catch (_) {
      return null;
    }
  }

  Future<void> _convert() async {
    if (opts.input.isEmpty) return;
    if ((opts.outputDir ?? '').isEmpty || opts.outputFileName.isEmpty) {
      setState(() => _status = 'Choose output folder & filename');
      return;
    }

    // Scroll to top when starting
    if (_scroll.hasClients) {
      _scroll.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }

    setState(() { _status = 'Probing…'; _progress = 0; _durationMs = null; _busy = true; });

    // Probe input
    final probe = await _svc.probe(opts.input);
    _durationMs = probe.durationMs;

    // Decide output target: try direct path; if not writable on Android, fall back to SAF
    String outTarget = opts.computedOutputPath();
    bool needSaf = false;

    final writable = await _ensureOutputDirWritable(outTarget);
    if (!writable && Platform.isAndroid) {
      needSaf = true;
    } else if (!writable) {
      setState(() { _status = 'Output folder not writable.'; _busy = false; });
      return;
    }

    if (needSaf) {
      setState(() => _status = 'Choose output file (Android Storage Access Framework)…');
      final safUrl = await _pickSafOutputFile(opts.outputFileName);
      if (safUrl == null) {
        setState(() { _status = 'Output not selected'; _busy = false; });
        return;
      }
      outTarget = safUrl; // use SAF output (e.g., "saf:3")
    }

    String buildCmd() => _svc.buildCommand(
      input: opts.input,
      output: outTarget,
      hasHdr: probe.hasHdr,
      o: opts,
    );

    Future<void> runOnce(String command) async {
      setState(() => _status = 'Converting…');
      await _svc.convert(
        cmd: command,
        onProgress: (rawSec) {
          if (_durationMs == null || _durationMs == 0) return;
          final pct = (rawSec * 1000) / _durationMs!;
          setState(() => _progress = pct.clamp(0.0, 1.0));
        },
        onDone: (msg) => setState(() {
          _status = 'Done: $outTarget';
          _progress = 1.0;
          _busy = false;
        }),
        onError: (msg) async {
          // If HW encoder failed, retry once in software
          final lower = msg.toLowerCase();
          final hw = opts.useHwEncoder;
          final looksHwFail =
              lower.contains('mediacodec') ||
                  (lower.contains('encoder') && lower.contains('not found')) ||
                  lower.contains('configure');

          if (hw && looksHwFail) {
            setState(() => _status = 'HW encoder failed, retrying with software…');
            opts.useHwEncoder = false;

            // IMPORTANT: if we’re writing to SAF, refresh the 'saf:' parameter for the retry
            if (outTarget.startsWith('saf:')) {
              if (_safWriteUri != null) {
                try {
                  final refreshed = await FFmpegKitConfig.getSafParameterForWrite(_safWriteUri!);
                  if (refreshed != null) outTarget = refreshed;
                } catch (_) { /* ignore, will try repick below if still failing */ }
              }
            }

            final swCmd = buildCmd();
            _svc.convert(
              cmd: swCmd,
              onProgress: (raw2) {
                if (_durationMs == null || _durationMs == 0) return;
                final pct2 = (raw2 * 1000) / _durationMs!;
                setState(() => _progress = pct2.clamp(0.0, 1.0));
              },
              onDone: (msg2) => setState(() {
                _status = 'Done: $outTarget';
                _progress = 1.0;
                _busy = false;
              }),
              onError: (msg2) async {
                // As a last resort: if SAF handle still missing, ask the user again once
                if (outTarget.startsWith('saf:') && msg2.toLowerCase().contains('saf id') ) {
                  setState(() => _status = 'Output handle expired. Pick output again…');
                  final repick = await _pickSafOutputFile(opts.outputFileName);
                  if (repick != null) {
                    outTarget = repick;
                    final retryCmd = buildCmd();
                    _svc.convert(
                      cmd: retryCmd,
                      onProgress: (raw3) {
                        if (_durationMs == null || _durationMs == 0) return;
                        final pct3 = (raw3 * 1000) / _durationMs!;
                        setState(() => _progress = pct3.clamp(0.0, 1.0));
                      },
                      onDone: (msg3) => setState(() {
                        _status = 'Done: $outTarget';
                        _progress = 1.0;
                        _busy = false;
                      }),
                      onError: (msg3) => setState(() { _status = msg3; _busy = false; }),
                      onSession: (id3) => _sessionId = id3,
                    );
                    return;
                  }
                }
                setState(() { _status = msg2; _busy = false; });
              },
              onSession: (id2) => _sessionId = id2,
            );
          } else {
            setState(() {
              _status = msg;
              _busy = false;
            });
          }
        },
        onSession: (id) => _sessionId = id,
      );
    }

    final cmd = buildCmd();
    await runOnce(cmd);
  }

  Future<void> _cancel() async {
    if (_sessionId != null) {
      await FFmpegKit.cancel(_sessionId!);
    }
    setState(() { _busy = false; });
  }

  @override
  Widget build(BuildContext context) {
    final canConvert = opts.input.isNotEmpty && (opts.outputDir ?? '').isNotEmpty && opts.outputFileName.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Universal Video Converter'),
        actions: [IconButton(onPressed: _busy ? () { _cancel(); } : null, icon: const Icon(Icons.close))],
      ),
      body: ListView(
        controller: _scroll,
        padding: const EdgeInsets.all(16),
        children: [
          Text('Status: $_status'),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: _progress == 0 ? null : _progress),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: FilledButton.icon(onPressed: _busy ? null : () => _pickInput(), icon: const Icon(Icons.video_file), label: const Text('Pick Video'))),
          ]),
          const SizedBox(height: 16),
          if (opts.input.isNotEmpty)
            TextField(readOnly: true, controller: TextEditingController(text: opts.input), decoration: const InputDecoration(labelText: 'Input', border: OutlineInputBorder())),
          const SizedBox(height: 12),

          // Output selection
          Row(children: [
            Expanded(
              child: TextField(
                controller: TextEditingController(text: opts.outputDir ?? ''),
                readOnly: true,
                decoration: const InputDecoration(labelText: 'Output Folder', border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(onPressed: _busy ? null : () => _chooseOutputFolder(), child: const Text('Choose…')),
          ]),
          const SizedBox(height: 12),
          TextField(
            onChanged: _busy ? null : (v) => setState(() { opts.outputFileName = v; opts.output = opts.computedOutputPath(); }),
            controller: TextEditingController(text: opts.outputFileName),
            readOnly: _busy,
            decoration: const InputDecoration(labelText: 'Output File Name', hintText: 'movie_1080p.mp4', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          if ((opts.outputDir ?? '').isNotEmpty && opts.outputFileName.isNotEmpty)
            TextField(readOnly: true, controller: TextEditingController(text: opts.computedOutputPath()), decoration: const InputDecoration(labelText: 'Full Output Path', border: OutlineInputBorder())),

          const SizedBox(height: 24),
          // Preset
          _Labeled(
            label: 'Preset',
            child: DropdownButtonFormField<Preset>(
              value: opts.preset,
              items: [for (final pz in kPresets) DropdownMenuItem(value: pz, child: Text(pz.name))],
              onChanged: _busy ? null : (pz) { if (pz == null) return; setState(() { opts.applyPreset(pz); _suggestOutputName(opts.input.isNotEmpty ? opts.input : opts.outputFileName); }); },
            ),
          ),
          const SizedBox(height: 12),
          // Container
          _Labeled(
            label: 'Container',
            child: DropdownButtonFormField<ContainerFmt>(
              value: opts.container,
              items: ContainerFmt.values.map((e) => DropdownMenuItem(value: e, child: Text(e.label))).toList(),
              onChanged: _busy ? null : (v) { if (v==null) return; setState(() { opts.container = v; if (opts.input.isNotEmpty) _suggestOutputName(opts.input); }); },
            ),
          ),
          const SizedBox(height: 12),
          // Video codec
          _Labeled(
            label: 'Video Codec',
            child: DropdownButtonFormField<VCodec>(
              value: opts.vcodec,
              items: VCodec.values.map((e) => DropdownMenuItem(value: e, child: Text(e.label))).toList(),
              onChanged: _busy ? null : (v) { if (v==null) return; setState(() { opts.vcodec = v; }); },
            ),
          ),
          const SizedBox(height: 12),
          // Audio codec
          _Labeled(
            label: 'Audio Codec',
            child: DropdownButtonFormField<ACodec>(
              value: opts.acodec,
              items: ACodec.values.map((e) => DropdownMenuItem(value: e, child: Text(e.label))).toList(),
              onChanged: _busy ? null : (v) { if (v==null) return; setState(() { opts.acodec = v; }); },
            ),
          ),
          const SizedBox(height: 12),
          // Resolution
          _Labeled(
            label: 'Resolution',
            child: DropdownButtonFormField<Resolution>(
              value: opts.resolution,
              items: kResList.map((r) => DropdownMenuItem(value: r, child: Text(r.label))).toList(),
              onChanged: _busy ? null : (r) { if (r==null) return; setState(() { opts.resolution = r; if (opts.input.isNotEmpty) _suggestOutputName(opts.input); }); },
            ),
          ),
          const SizedBox(height: 12),
          // FPS
          _Labeled(
            label: 'Frame Rate',
            child: DropdownButtonFormField<double?>(
              value: opts.fps,
              items: [null, 24.0, 25.0, 29.97, 30.0, 50.0, 59.94, 60.0]
                  .map((f) => DropdownMenuItem(value: f, child: Text(f==null ? 'Keep original' : f.toString())))
                  .toList(),
              onChanged: _busy ? null : (f) => setState(() { opts.fps = f; }),
            ),
          ),
          const SizedBox(height: 12),
          // Quality vs Bitrate
          SwitchListTile(
            title: const Text('Use CRF (quality based)'),
            subtitle: const Text('Off = target bitrate'),
            value: opts.useCrf,
            onChanged: _busy ? null : (v) => setState(() { opts.useCrf = v; }),
          ),
          if (opts.useCrf)
            _NumberField(label: 'CRF (lower = better, typical 18–28)', value: opts.crf.toDouble(), min: 0, max: 51, enabled: !_busy, onChanged: (v) => setState(() { opts.crf = v.round(); }))
          else
            _NumberField(label: 'Video Bitrate (kbps)', value: opts.vBitrateK.toDouble(), min: 250, max: 20000, step: 250, enabled: !_busy, onChanged: (v) => setState(() { opts.vBitrateK = v.round(); })),

          const SizedBox(height: 12),
          _NumberField(label: 'Audio Bitrate (kbps)', value: opts.aBitrateK.toDouble(), min: 96, max: 768, step: 32, enabled: !_busy, onChanged: (v) => setState(() { opts.aBitrateK = v.round(); })),
          const SizedBox(height: 12),
          _Labeled(
            label: 'Audio Channels',
            child: DropdownButtonFormField<int>(
              value: opts.audioChannels,
              items: [2, 6].map((c) => DropdownMenuItem(value: c, child: Text(c == 2 ? 'Stereo (2.0)' : '5.1 (6 ch)'))).toList(),
              onChanged: _busy ? null : (c) => setState(() { if (c!=null) opts.audioChannels = c; }),
            ),
          ),
          const SizedBox(height: 12),
          _Labeled(
            label: 'Sample Rate',
            child: DropdownButtonFormField<int>(
              value: opts.sampleRate,
              items: [44100, 48000].map((sr) => DropdownMenuItem(value: sr, child: Text('$sr Hz'))).toList(),
              onChanged: _busy ? null : (sr) => setState(() { if (sr!=null) opts.sampleRate = sr; }),
            ),
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            value: opts.toneMapHdrToSdr,
            onChanged: _busy ? null : (v) => setState(() { opts.toneMapHdrToSdr = v ?? true; }),
            title: const Text('Tone-map HDR → SDR when needed'),
            subtitle: const Text('Improves compatibility on older projectors/TVs'),
          ),

          const SizedBox(height: 12),
          // NEW: Hardware encoder toggle
          SwitchListTile(
            title: const Text('Use hardware encoder (faster)'),
            subtitle: const Text('Mediacodec on Android, VideoToolbox on iOS/macOS'),
            value: opts.useHwEncoder,
            onChanged: _busy ? null : (v) => setState(() { opts.useHwEncoder = v; }),
          ),

          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: FilledButton.icon(onPressed: (!canConvert || _busy) ? null : () => _convert(), icon: const Icon(Icons.play_arrow), label: const Text('Convert'))),
          ]),
          const SizedBox(height: 24),
          const _TipsBox(),
        ],
      ),
    );
  }
}

class _Labeled extends StatelessWidget {
  final String label; final Widget child; const _Labeled({required this.label, required this.child});
  @override Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: Theme.of(context).textTheme.labelLarge), const SizedBox(height: 6), child,
  ]);
}

class _NumberField extends StatefulWidget {
  final String label; final double value; final double min; final double max; final double step; final ValueChanged<double> onChanged; final bool enabled;
  const _NumberField({required this.label, required this.value, required this.onChanged, this.min=0, this.max=100, this.step=1, this.enabled = true});
  @override State<_NumberField> createState() => _NumberFieldState();
}
class _NumberFieldState extends State<_NumberField> {
  late double _v = widget.value;
  @override void didUpdateWidget(covariant _NumberField oldWidget) { super.didUpdateWidget(oldWidget); _v = widget.value; }
  @override Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(widget.label),
    Row(children: [
      Expanded(child: Slider(value: _v.clamp(widget.min, widget.max), min: widget.min, max: widget.max, divisions: ((widget.max-widget.min)/widget.step).round(), label: _v.round().toString(), onChanged: widget.enabled ? (v){ setState(()=>_v=v); widget.onChanged(v); } : null)),
      SizedBox(width: 64, child: Text('${_v.round()}', textAlign: TextAlign.end)),
    ])
  ]);
}

class _TipsBox extends StatelessWidget {
  const _TipsBox();
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
          Text('Compatibility tips', style: TextStyle(fontWeight: FontWeight.bold)),
          SizedBox(height: 8),
          Text('• For older projectors/TVs, prefer MP4 + H.264 video + AAC or AC-3 audio.'),
          Text('• Use 1080p or 720p for smooth playback on lower-end devices.'),
          Text('• Turn on HDR→SDR tone-mapping for Dolby Vision/HDR10 sources.'),
          Text('• WebM (VP9/Opus) works great on browsers but not all TVs.'),
          Text('• AV1 is efficient but slow to encode and not universally supported yet.'),
          Text('• Android scoped storage: pick a folder (e.g., /Movies/FormatFlex) for direct saves.'),
          Text('• iOS: prefer Share to export from app sandbox.'),
        ]),
      ),
    );
  }
}
