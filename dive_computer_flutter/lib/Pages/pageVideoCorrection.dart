import 'dart:typed_data';
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dive_computer_flutter/define.dart';
import 'package:dive_computer_flutter/extensions.dart';
import 'package:dive_computer_flutter/router.dart';
import 'package:extended_text/extended_text.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:dartcv4/dartcv.dart' as cv;
import 'package:media_kit/media_kit.dart' as mk;
import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';

class PageVideoCorrection extends StatefulWidget {
  const PageVideoCorrection({super.key});

  @override
  State<PageVideoCorrection> createState() => _PageVideoCorrectionState();
}

class _PageVideoCorrectionState extends State<PageVideoCorrection> {
  int width = -1;
  int height = -1;
  double fps = -1;
  String backend = "unknown";
  String? src;
  String? dst;
  String? _openedSrcPath;
  final vc = cv.VideoCapture.empty();
  final vw = cv.VideoWriter.empty();
  final mk.Player _audioPlayer = mk.Player();

  ui.Image? _currentFrame;
  bool _isPlaying = false;
  bool _isPaused = false;
  bool _isSaving = false;
  bool _processingFrame = false;
  int _playbackSession = 0;

  // Playback isolate state
  Isolate? _playbackIsolate;
  SendPort? _isolateSendPort;
  ReceivePort? _fromIsolatePort;
  StreamSubscription<dynamic>? _isolateSub;
  int _lastReceivedFrameNum = 0;
  int _totalFrames = 0;
  bool _seekingSlider = false;
  double _saveProgress = 0;
  String _statusText = 'Waiting...';

  bool _autoCorrection = true;
  double _autoStrength = 0.62;
  double _contrast = 1.2;
  double _brightness = 6.0;
  double _saturation = 1.12;
  double _temperature = 10.0;
  double _redRecovery = 1.05;
  bool _localMaskEnabled = false;
  double _localMaskStrength = 0.55;
  double _blueOceanTone = 1.12;
  bool _particleReduction = false;
  double _particleReductionStrength = 0.55;
  double _audioVolume = 1.0;
  bool _audioEnabled = true;
  DateTime? _lastFineResyncAt;
  bool _fineResyncInFlight = false;

  @override
  void initState() {
    super.initState();
    mk.MediaKit.ensureInitialized();
  }

  Future<void> _startAudioForPlayback() async {
    if (src == null && _openedSrcPath == null) {
      return;
    }

    final candidates = <String>[
      if (_openedSrcPath != null) _openedSrcPath!,
      if (src != null) src!,
    ];

    for (final audioPath in candidates) {
      if (!File(audioPath).existsSync()) {
        continue;
      }
      try {
        await _audioPlayer.stop();
        await _audioPlayer.open(mk.Media(audioPath), play: true);
        await _audioPlayer.setVolume(_audioVolume * 100.0);
        if (mounted && !_audioEnabled) {
          setState(() {
            _audioEnabled = true;
          });
        }
        return;
      } catch (e) {
        debugPrint('Audio start failed for $audioPath: $e');
      }
    }

    if (mounted) {
      setState(() {
        _audioEnabled = false;
        _statusText = 'Audio file open failed';
      });
    }
  }

  Future<void> _stopAudioPlayback() async {
    try {
      await _audioPlayer.stop();
    } catch (e) {
      debugPrint('Audio stop failed: $e');
    }
  }

  bool _hasOnlyAsciiPath(String value) {
    return value.codeUnits.every((ch) => ch <= 0x7F);
  }

  Future<String> _prepareOpenPath(String originalPath) async {
    if (_hasOnlyAsciiPath(originalPath)) {
      return originalPath;
    }

    // OpenCV on Windows can fail on non-ASCII paths depending on backend and build.
    // Copying to app cache with ASCII filename is a practical fallback.
    final cacheDir = await getApplicationCacheDirectory();
    final ext = p.extension(originalPath).isEmpty
        ? '.mp4'
        : p.extension(originalPath);
    final fallbackName = 'input_${DateTime.now().millisecondsSinceEpoch}$ext';
    final fallbackPath = p.join(cacheDir.path, fallbackName);
    await File(originalPath).copy(fallbackPath);
    debugPrint('Copied source to ASCII path: $fallbackPath');
    return fallbackPath;
  }

  Future<String> _prepareOutputPath(String originalPath) async {
    if (_hasOnlyAsciiPath(originalPath)) {
      return originalPath;
    }
    final cacheDir = await getApplicationCacheDirectory();
    final ext = p.extension(originalPath).isEmpty
        ? '.mp4'
        : p.extension(originalPath);
    return p.join(
      cacheDir.path,
      'output_${DateTime.now().millisecondsSinceEpoch}$ext',
    );
  }

  Future<bool> _openVideoCapture(String path) async {
    vc.release();

    final preparedPath = await _prepareOpenPath(path);
    final apiPreferences = <int>[cv.CAP_ANY, cv.CAP_FFMPEG, cv.CAP_MSMF];

    for (final api in apiPreferences) {
      final opened = vc.open(preparedPath, apiPreference: api);
      debugPrint('open($preparedPath, api=$api) => $opened');
      if (opened && vc.isOpened) {
        _openedSrcPath = preparedPath;
        return true;
      }
      vc.release();
    }

    _openedSrcPath = null;
    return false;
  }

  Future<cv.Mat> _applyCorrections(
    cv.Mat inputFrame, {
    bool realtime = false,
  }) async {
    cv.Mat working = inputFrame;

    // Skip particle reduction during realtime playback to avoid frame drops.
    if (_particleReduction && !realtime) {
      final reductionStrength = _particleReductionStrength;
      final kernel = reductionStrength < 0.33
          ? 3
          : (reductionStrength < 0.66 ? 5 : 7);
      final denoised = await cv.medianBlurAsync(working, kernel);
      if (!identical(working, inputFrame)) {
        working.dispose();
      }
      working = denoised;

      if (!realtime) {
        final sigma = 1.0 + reductionStrength * 2.0;
        final blurred = await cv.gaussianBlurAsync(working, (3, 3), sigma);
        final sharpenAmount = 0.30 + reductionStrength * 0.60;
        final sharpened = await cv.addWeightedAsync(
          working,
          1.0 + sharpenAmount,
          blurred,
          -sharpenAmount,
          0.0,
        );
        blurred.dispose();
        working.dispose();
        working = sharpened;
      }
    }

    if (_autoCorrection) {
      final beforeAuto = cv.Mat.fromMat(working, copy: true);
      final channels = await cv.splitAsync(working);
      final b = channels[0];
      final g = channels[1];
      final r = channels[2];

      final bMean = b.mean().val1;
      final gMean = g.mean().val1;
      final rMean = r.mean().val1;
      final target = (bMean + gMean + rMean) / 3.0;
      final blueGreen = (bMean + gMean) / 2.0;
      final redDeficit = ((blueGreen - rMean) / math.max(blueGreen, 1.0)).clamp(
        0.0,
        1.0,
      );

      final bGain = (target / math.max(bMean, 1.0)).clamp(0.7, 1.8);
      final gGain = (target / math.max(gMean, 1.0)).clamp(0.7, 1.8);
      final rGain = (target / math.max(rMean, 1.0)).clamp(0.7, 1.8);
      // Bright scenes are more prone to red clipping; attenuate red boost there.
      final highlight = ((target - 138.0) / 90.0).clamp(0.0, 1.0);
      final warmScene = ((rMean - gMean) / math.max(target, 1.0)).clamp(
        0.0,
        0.45,
      );
      final redBoostBase =
          1.0 + redDeficit * (0.42 + _autoStrength * 0.48) * _redRecovery;
      final redBoost =
          (1.0 +
                  (redBoostBase - 1.0) *
                      (1.0 - 0.8 * highlight - 0.55 * warmScene))
              .clamp(1.0, realtime ? 1.38 : 1.72);
      final blueSuppress = (1.0 - redDeficit * 0.10 * _autoStrength).clamp(
        0.9,
        1.0,
      );
      final greenSuppress = (1.0 - redDeficit * 0.04 * _autoStrength).clamp(
        0.95,
        1.0,
      );

      final bAlpha = (1.0 + (bGain - 1.0) * _autoStrength) * blueSuppress;
      final gAlpha = (1.0 + (gGain - 1.0) * _autoStrength) * greenSuppress;
      final rAlpha = ((1.0 + (rGain - 1.0) * _autoStrength) * redBoost).clamp(
        0.9,
        realtime ? 1.45 : 1.8,
      );

      final bAdj = await cv.convertScaleAbsAsync(b, alpha: bAlpha);
      final gAdj = await cv.convertScaleAbsAsync(g, alpha: gAlpha);
      final rAdj = await cv.convertScaleAbsAsync(r, alpha: rAlpha);
      final balanced = await cv.mergeAsync(
        cv.VecMat.fromList([bAdj, gAdj, rAdj]),
      );

      if (!identical(working, inputFrame)) {
        working.dispose();
      }
      bAdj.dispose();
      gAdj.dispose();
      rAdj.dispose();
      working = balanced;

      if (_localMaskEnabled && !realtime) {
        final hsvForMask = await cv.cvtColorAsync(beforeAuto, cv.COLOR_BGR2HSV);
        final hsvMaskChannels = await cv.splitAsync(hsvForMask);
        final valueChannel = hsvMaskChannels[2];
        final thresholdHigh = (210.0 - _localMaskStrength * 45.0).clamp(
          145.0,
          220.0,
        );
        final thresholdLow =
            (thresholdHigh - (20.0 + _localMaskStrength * 20.0)).clamp(
              120.0,
              210.0,
            );

        final (_, strongHighlightMask) = await cv.thresholdAsync(
          valueChannel,
          thresholdHigh,
          255,
          cv.THRESH_BINARY,
        );
        final (_, softHighlightMask) = await cv.thresholdAsync(
          valueChannel,
          thresholdLow,
          255,
          cv.THRESH_BINARY,
        );
        final transitionMask = await cv.subtractAsync(
          softHighlightMask,
          strongHighlightMask,
        );
        final invSoftMask = await cv.bitwiseNOTAsync(softHighlightMask);

        final correctedCore = await cv.bitwiseANDAsync(
          working,
          working,
          mask: invSoftMask,
        );
        final strongProtected = await cv.bitwiseANDAsync(
          beforeAuto,
          beforeAuto,
          mask: strongHighlightMask,
        );
        final transitionCorrected = await cv.bitwiseANDAsync(
          working,
          working,
          mask: transitionMask,
        );
        final transitionOriginal = await cv.bitwiseANDAsync(
          beforeAuto,
          beforeAuto,
          mask: transitionMask,
        );
        final transitionMixed = await cv.addWeightedAsync(
          transitionCorrected,
          0.68,
          transitionOriginal,
          0.32,
          0.0,
        );
        final corePlusTransition = await cv.addAsync(
          correctedCore,
          transitionMixed,
        );
        final locallyMasked = await cv.addAsync(
          corePlusTransition,
          strongProtected,
        );

        hsvForMask.dispose();
        strongHighlightMask.dispose();
        softHighlightMask.dispose();
        transitionMask.dispose();
        invSoftMask.dispose();
        correctedCore.dispose();
        strongProtected.dispose();
        transitionCorrected.dispose();
        transitionOriginal.dispose();
        transitionMixed.dispose();
        corePlusTransition.dispose();
        working.dispose();
        working = locallyMasked;
      }

      beforeAuto.dispose();
    }

    final contrast = realtime ? math.min(_contrast, 1.12) : _contrast;
    final brightness = realtime ? math.min(_brightness, 4.0) : _brightness;
    final saturation = realtime ? math.min(_saturation, 1.06) : _saturation;

    final leveled = await cv.convertScaleAbsAsync(
      working,
      alpha: contrast,
      beta: brightness,
    );
    if (!identical(working, inputFrame)) {
      working.dispose();
    }
    working = leveled;

    // In realtime mode, skip the expensive HSV round-trip for saturation.
    if (!realtime && (saturation - 1.0).abs() > 0.01) {
      final hsv = await cv.cvtColorAsync(working, cv.COLOR_BGR2HSV);
      final hsvChannels = await cv.splitAsync(hsv);
      final satAdjusted = await cv.convertScaleAbsAsync(
        hsvChannels[1],
        alpha: saturation,
      );
      final hsvMerged = await cv.mergeAsync(
        cv.VecMat.fromList([hsvChannels[0], satAdjusted, hsvChannels[2]]),
      );
      final saturatedBgr = await cv.cvtColorAsync(hsvMerged, cv.COLOR_HSV2BGR);

      satAdjusted.dispose();
      hsvMerged.dispose();
      hsv.dispose();
      working.dispose();
      working = saturatedBgr;
    }

    if ((_blueOceanTone - 1.0).abs() > 0.01) {
      // In realtime mode, just scale the blue channel directly (no masking).
      if (realtime) {
        final bgrChannels = await cv.splitAsync(working);
        final bScaled = await cv.convertScaleAbsAsync(
          bgrChannels[0],
          alpha: _blueOceanTone,
        );
        final blued = await cv.mergeAsync(
          cv.VecMat.fromList([bScaled, bgrChannels[1], bgrChannels[2]]),
        );
        bScaled.dispose();
        working.dispose();
        working = blued;
      } else {
        final hsvForBlue = await cv.cvtColorAsync(working, cv.COLOR_BGR2HSV);
        final lowerBlue = cv.Mat.fromScalar(
          hsvForBlue.rows,
          hsvForBlue.cols,
          cv.MatType.CV_8UC3,
          cv.Scalar(72.0, 30.0, 20.0, 0.0),
        );
        final upperBlue = cv.Mat.fromScalar(
          hsvForBlue.rows,
          hsvForBlue.cols,
          cv.MatType.CV_8UC3,
          cv.Scalar(132.0, 255.0, 255.0, 0.0),
        );
        final blueMask = await cv.inRangeAsync(
          hsvForBlue,
          lowerBlue,
          upperBlue,
        );
        final invBlueMask = await cv.bitwiseNOTAsync(blueMask);

        final bgrChannels = await cv.splitAsync(working);
        final b = bgrChannels[0];
        final g = bgrChannels[1];
        final r = bgrChannels[2];

        final bBoosted = await cv.convertScaleAbsAsync(
          b,
          alpha: _blueOceanTone,
        );
        final bBase = await cv.bitwiseANDAsync(b, b, mask: invBlueMask);
        final bMaskedBoost = await cv.bitwiseANDAsync(
          bBoosted,
          bBoosted,
          mask: blueMask,
        );
        final bFinal = await cv.addAsync(bBase, bMaskedBoost);

        final blued = await cv.mergeAsync(cv.VecMat.fromList([bFinal, g, r]));

        hsvForBlue.dispose();
        lowerBlue.dispose();
        upperBlue.dispose();
        blueMask.dispose();
        invBlueMask.dispose();
        bBoosted.dispose();
        bBase.dispose();
        bMaskedBoost.dispose();
        bFinal.dispose();
        working.dispose();
        working = blued;
      } // end else (full masking path)
    }

    final tempMix = (_temperature.abs() / 100.0 * 0.28).clamp(0.0, 0.28);
    if (tempMix > 0.001) {
      final tint = _temperature >= 0
          ? cv.Scalar(0.0, 10.0, 40.0, 0.0)
          : cv.Scalar(40.0, 10.0, 0.0, 0.0);
      final tintMat = cv.Mat.fromScalar(
        working.rows,
        working.cols,
        cv.MatType.CV_8UC3,
        tint,
      );
      final mixed = await cv.addWeightedAsync(
        working,
        1.0,
        tintMat,
        tempMix,
        0.0,
      );
      tintMat.dispose();
      working.dispose();
      working = mixed;
    }

    return working;
  }

  Future<cv.Mat> _resizeForPreview(
    cv.Mat frame, {
    bool realtime = false,
  }) async {
    // During realtime playback, cap at 960×540 to keep the correction pipeline fast.
    // For static preview frames, keep full source resolution.
    const hdWidth = 960;
    const hdHeight = 540;
    if (!realtime || (frame.width <= hdWidth && frame.height <= hdHeight)) {
      return frame;
    }
    // Scale down to fit within HD bounds while preserving aspect ratio.
    final scaleW = hdWidth / frame.width;
    final scaleH = hdHeight / frame.height;
    final scale = math.min(scaleW, scaleH);
    final targetW = math.max(1, (frame.width * scale).round());
    final targetH = math.max(1, (frame.height * scale).round());
    return cv.resizeAsync(frame, (targetW, targetH));
  }

  double get _videoAspectRatio {
    if (width > 0 && height > 0) {
      return width / height;
    }
    return 16 / 9;
  }

  bool get _hasVideo => src != null && vc.isOpened;

  Duration _frameToDuration(int frame) {
    final safeFps = fps > 1 ? fps : 30.0;
    final ms = ((frame / safeFps) * 1000).round();
    return Duration(milliseconds: math.max(0, ms));
  }

  Future<void> _seekAudioToFrame(int frame) async {
    if (!_audioEnabled) return;
    try {
      await _audioPlayer.seek(_frameToDuration(frame));
    } catch (e) {
      debugPrint('Audio seek failed: $e');
    }
  }

  Future<void> _maybeFineResyncAudio(int frameNum) async {
    if (!_isPlaying || !_audioEnabled || !_hasVideo || fps <= 1) return;
    if (_fineResyncInFlight) return;
    if (frameNum < 0 || frameNum % 12 != 0) return;

    final now = DateTime.now();
    if (_lastFineResyncAt != null &&
        now.difference(_lastFineResyncAt!).inMilliseconds < 450) {
      return;
    }

    _fineResyncInFlight = true;
    try {
      final videoPos = _frameToDuration(frameNum);
      final audioPos = _audioPlayer.state.position;
      final driftMs = audioPos.inMilliseconds - videoPos.inMilliseconds;

      // Keep tiny jitter untouched; only correct meaningful drift.
      if (driftMs.abs() >= 120) {
        var target = videoPos;
        if (target.isNegative) {
          target = Duration.zero;
        }
        await _audioPlayer.seek(target);
        _lastFineResyncAt = now;
      }
    } catch (e) {
      debugPrint('Fine A/V resync failed: $e');
    } finally {
      _fineResyncInFlight = false;
    }
  }

  Future<void> _refreshPreviewFrame() async {
    if (!vc.isOpened || _isPlaying || _isSaving || _processingFrame) {
      return;
    }

    _processingFrame = true;
    try {
      vc.set(cv.CAP_PROP_POS_FRAMES, 0);
      final (ok, frame) = await vc.readAsync();
      if (!ok || frame.width == 0 || frame.height == 0) {
        frame.dispose();
        return;
      }

      final preview = await _resizeForPreview(frame);
      final corrected = await _applyCorrections(preview);
      final image = await _cvMatToImage(corrected);
      if (!identical(preview, frame)) {
        preview.dispose();
      }
      frame.dispose();
      corrected.dispose();

      if (!mounted) {
        return;
      }
      setState(() {
        _currentFrame = image;
        _statusText = 'Preview updated';
      });
      vc.set(cv.CAP_PROP_POS_FRAMES, 0);
    } finally {
      _processingFrame = false;
    }
  }

  Future<void> _selectVideo() async {
    final result = await FilePicker.pickFiles(type: FileType.video);
    if (result == null) {
      return;
    }

    await _stopVideo(refreshPreview: false);

    final file = result.files.single;
    final path = file.path;
    if (path == null) {
      return;
    }

    debugPrint('selected file: $path');
    final ret = await _openVideoCapture(path);
    if (!mounted) {
      return;
    }

    setState(() {
      src = path;
      _isPaused = false;
      if (ret) {
        width = vc.get(cv.CAP_PROP_FRAME_WIDTH).toInt();
        height = vc.get(cv.CAP_PROP_FRAME_HEIGHT).toInt();
        fps = vc.get(cv.CAP_PROP_FPS);
        backend = vc.getBackendName();
        _totalFrames = vc.get(cv.CAP_PROP_FRAME_COUNT).toInt();
        _lastReceivedFrameNum = 0;
        _statusText = 'Video ready';
      } else {
        width = -1;
        height = -1;
        fps = -1;
        backend = 'open-failed';
        _statusText = 'Failed to open selected video';
      }
    });

    if (ret) {
      await _refreshPreviewFrame();
    }

    final dstDir = await getApplicationCacheDirectory();
    if (!mounted) {
      return;
    }
    setState(() {
      dst = p.join(dstDir.path, 'output.mp4');
    });
  }

  Future<void> _seekTo(int frameNum) async {
    if (!_hasVideo || _isSaving) return;
    final target = frameNum.clamp(0, math.max(0, _totalFrames - 1)).toInt();
    _seekingSlider = true;
    _lastReceivedFrameNum = target;
    unawaited(_seekAudioToFrame(target));

    if (_isPlaying && _isolateSendPort != null) {
      _isolateSendPort?.send({'cmd': 'seek', 'frame': target});
      _seekingSlider = false;
      if (mounted) {
        setState(() {
          _statusText = 'Seeking...';
        });
      }
      return;
    }

    vc.set(cv.CAP_PROP_POS_FRAMES, _lastReceivedFrameNum.toDouble());
    _seekingSlider = false;
    if (!_processingFrame) {
      _processingFrame = true;
      try {
        final (ok, frame) = await vc.readAsync();
        if (ok && frame.width > 0) {
          final corrected = await _applyCorrections(frame);
          final image = await _cvMatToImage(corrected);
          frame.dispose();
          corrected.dispose();
          if (mounted) setState(() => _currentFrame = image);
        } else {
          frame.dispose();
        }
      } finally {
        _processingFrame = false;
        vc.set(cv.CAP_PROP_POS_FRAMES, _lastReceivedFrameNum.toDouble());
      }
    }
  }

  Future<void> _pauseVideo() async {
    if (!_isPlaying) return;

    _playbackSession += 1;
    if (mounted) {
      setState(() {
        _isPlaying = false;
        _isPaused = true;
        _statusText = 'Paused';
      });
    }
    await _killPlaybackIsolate();
    try {
      await _audioPlayer.pause();
    } catch (e) {
      debugPrint('Audio pause failed: $e');
    }
  }

  Future<void> _stopVideo({bool refreshPreview = false}) async {
    final hadPlayback = _isPlaying || _isPaused;
    _playbackSession += 1;

    if (mounted) {
      setState(() {
        _isPlaying = false;
        _isPaused = false;
        if (hadPlayback || refreshPreview) _statusText = 'Stopped';
      });
    }
    await _killPlaybackIsolate();
    await _stopAudioPlayback();

    if (refreshPreview && vc.isOpened) {
      await _refreshPreviewFrame();
    }
  }

  Future<bool> _muxOriginalAudioToVideo({
    required String silentVideoPath,
    required String sourceWithAudioPath,
    required String outputPath,
  }) async {
    String psQuote(String value) => value.replaceAll("'", "''");

    Future<bool> canRun(String executable) async {
      try {
        final r = await Process.run(executable, ['-version'], runInShell: true);
        return r.exitCode == 0;
      } catch (_) {
        return false;
      }
    }

    Future<String?> tryInstallPortableFfmpeg() async {
      if (!Platform.isWindows) return null;
      try {
        final supportDir = await getApplicationSupportDirectory();
        final installBinDir = Directory(
          p.join(supportDir.path, 'ffmpeg_portable', 'bin'),
        );
        final installedExe = p.join(installBinDir.path, 'ffmpeg.exe');
        if (File(installedExe).existsSync() && await canRun(installedExe)) {
          return installedExe;
        }

        await installBinDir.create(recursive: true);
        final tempRoot = Directory(
          p.join(supportDir.path, 'ffmpeg_download_tmp'),
        );
        if (tempRoot.existsSync()) {
          await tempRoot.delete(recursive: true);
        }
        await tempRoot.create(recursive: true);

        final zipPath = p.join(tempRoot.path, 'ffmpeg.zip');
        final extractPath = p.join(tempRoot.path, 'extracted');
        const url =
            'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip';
        final script =
            "\$ErrorActionPreference='Stop'; "
            "\$ProgressPreference='SilentlyContinue'; "
            "Invoke-WebRequest -Uri '${psQuote(url)}' -OutFile '${psQuote(zipPath)}'; "
            "Expand-Archive -Path '${psQuote(zipPath)}' -DestinationPath '${psQuote(extractPath)}' -Force;";

        final download = await Process.run('powershell', [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          script,
        ], runInShell: true);
        if (download.exitCode != 0) {
          debugPrint('Portable ffmpeg download failed: ${download.stderr}');
          return null;
        }

        File? foundExe;
        await for (final entity in Directory(
          extractPath,
        ).list(recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          if (p.basename(entity.path).toLowerCase() != 'ffmpeg.exe') continue;
          if (p.basename(p.dirname(entity.path)).toLowerCase() != 'bin') {
            continue;
          }
          foundExe = entity;
          break;
        }
        if (foundExe == null) {
          debugPrint('Portable ffmpeg extracted but ffmpeg.exe not found.');
          return null;
        }

        final sourceBin = Directory(p.dirname(foundExe.path));
        await for (final entity in sourceBin.list(followLinks: false)) {
          final name = p.basename(entity.path);
          final target = p.join(installBinDir.path, name);
          if (entity is File) {
            await entity.copy(target);
          }
        }

        if (File(installedExe).existsSync() && await canRun(installedExe)) {
          return installedExe;
        }
      } catch (e) {
        debugPrint('Portable ffmpeg install exception: $e');
      }
      return null;
    }

    Future<String?> resolveFfmpegExecutable() async {
      if (await canRun('ffmpeg')) {
        return 'ffmpeg';
      }

      final exeDir = p.dirname(Platform.resolvedExecutable);
      final candidates = <String>[
        p.join(Directory.current.path, 'ffmpeg.exe'),
        p.join(Directory.current.path, 'tools', 'ffmpeg', 'ffmpeg.exe'),
        p.join(Directory.current.path, 'ffmpeg', 'bin', 'ffmpeg.exe'),
        p.join(exeDir, 'ffmpeg.exe'),
        p.join(exeDir, 'ffmpeg', 'ffmpeg.exe'),
        p.join(exeDir, 'ffmpeg', 'bin', 'ffmpeg.exe'),
        p.join(
          exeDir,
          'data',
          'flutter_assets',
          'assets',
          'ffmpeg',
          'ffmpeg.exe',
        ),
      ];

      for (final c in candidates) {
        if (!File(c).existsSync()) continue;
        if (await canRun(c)) {
          return c;
        }
      }

      final portable = await tryInstallPortableFfmpeg();
      if (portable != null) {
        return portable;
      }
      return null;
    }

    try {
      final ffmpegExe = await resolveFfmpegExecutable();
      if (ffmpegExe == null) {
        debugPrint('ffmpeg executable not found (system or bundled).');
        return false;
      }

      final result = await Process.run(ffmpegExe, [
        '-y',
        '-i',
        silentVideoPath,
        '-i',
        sourceWithAudioPath,
        '-map',
        '0:v:0',
        '-map',
        '1:a:0?',
        '-c:v',
        'copy',
        '-c:a',
        'aac',
        '-shortest',
        outputPath,
      ], runInShell: true);
      if (result.exitCode != 0) {
        debugPrint('ffmpeg mux failed: ${result.stderr}');
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('ffmpeg mux exception: $e');
      return false;
    }
  }

  Future<void> _saveEditedVideo() async {
    if (src == null || _openedSrcPath == null) {
      setState(() {
        _statusText = 'Select a video first.';
      });
      return;
    }

    setState(() {
      _isPlaying = false;
      _isSaving = true;
      _saveProgress = 0;
      _statusText = 'Preparing export...';
    });
    await _stopAudioPlayback();

    final exportCapture = cv.VideoCapture.fromFile(_openedSrcPath!);
    if (!exportCapture.isOpened) {
      exportCapture.dispose();
      if (mounted) {
        setState(() {
          _isSaving = false;
          _statusText = 'Failed to open source for export.';
        });
      }
      return;
    }

    final srcW = exportCapture.get(cv.CAP_PROP_FRAME_WIDTH).toInt();
    final srcH = exportCapture.get(cv.CAP_PROP_FRAME_HEIGHT).toInt();
    final srcFps = exportCapture.get(cv.CAP_PROP_FPS);
    final totalFrames = exportCapture.get(cv.CAP_PROP_FRAME_COUNT).toInt();

    final cacheDir = await getApplicationCacheDirectory();
    final defaultName =
        'corrected_${DateTime.now().millisecondsSinceEpoch}.mp4';
    final requestedPath = await FilePicker.saveFile(
      dialogTitle: 'Save corrected video',
      fileName: defaultName,
      initialDirectory: cacheDir.path,
      lockParentWindow: true,
    );

    if (requestedPath == null) {
      exportCapture.dispose();
      if (mounted) {
        setState(() {
          _isSaving = false;
          _statusText = 'Export cancelled.';
        });
      }
      return;
    }

    final safeOutputPath = await _prepareOutputPath(requestedPath);
    final silentVideoPath = p.join(
      cacheDir.path,
      'silent_${DateTime.now().millisecondsSinceEpoch}.mp4',
    );
    final targetFps = srcFps.isFinite && srcFps > 0 ? srcFps : 30.0;

    vw.release();
    vw.open(silentVideoPath, 'mp4v', targetFps, (srcW, srcH));
    if (!vw.isOpened) {
      exportCapture.dispose();
      if (mounted) {
        setState(() {
          _isSaving = false;
          _statusText = 'Failed to open writer.';
        });
      }
      return;
    }

    int written = 0;
    while (true) {
      final (ok, frame) = await exportCapture.readAsync();
      if (!ok || frame.width == 0 || frame.height == 0) {
        frame.dispose();
        break;
      }

      final corrected = await _applyCorrections(frame);
      await vw.writeAsync(corrected);

      frame.dispose();
      corrected.dispose();

      written += 1;
      if (mounted && written % 10 == 0) {
        final progress = totalFrames > 0
            ? (written / totalFrames).clamp(0.0, 1.0)
            : 0.0;
        setState(() {
          _saveProgress = progress;
          _statusText =
              'Exporting... ${written.toString()}/${totalFrames.toString()}';
        });
      }
    }

    vw.release();
    exportCapture.dispose();

    final audioSourcePath = _openedSrcPath ?? src!;
    final muxed = await _muxOriginalAudioToVideo(
      silentVideoPath: silentVideoPath,
      sourceWithAudioPath: audioSourcePath,
      outputPath: safeOutputPath,
    );
    if (!muxed) {
      await File(silentVideoPath).copy(safeOutputPath);
    }
    if (File(silentVideoPath).existsSync()) {
      await File(silentVideoPath).delete();
    }

    if (safeOutputPath != requestedPath) {
      await File(safeOutputPath).copy(requestedPath);
      await File(safeOutputPath).delete();
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _isSaving = false;
      _saveProgress = 1;
      dst = requestedPath;
      _statusText = muxed
          ? 'Saved with audio: $requestedPath'
          : 'Saved (video only): $requestedPath';
    });
  }

  @override
  void dispose() {
    unawaited(_killPlaybackIsolate());
    vc.release();
    vw.release();
    unawaited(
      _audioPlayer.dispose().catchError((e) {
        debugPrint('Audio dispose ignored: $e');
      }),
    );
    super.dispose();
  }

  Future<void> _killPlaybackIsolate() async {
    _isolateSub?.cancel();
    _isolateSub = null;
    _isolateSendPort?.send({'cmd': 'stop'});
    _isolateSendPort = null;
    _playbackIsolate?.kill(priority: Isolate.immediate);
    _playbackIsolate = null;
    _fromIsolatePort?.close();
    _fromIsolatePort = null;
  }

  Map<String, dynamic> _buildCorrectionParams() => {
    'autoCorrection': _autoCorrection,
    'autoStrength': _autoStrength,
    'contrast': _contrast,
    'brightness': _brightness,
    'saturation': _saturation,
    'temperature': _temperature,
    'redRecovery': _redRecovery,
    'blueOceanTone': _blueOceanTone,
    'localMaskEnabled': _localMaskEnabled,
    'localMaskStrength': _localMaskStrength,
    'particleReduction': _particleReduction,
    'particleReductionStrength': _particleReductionStrength,
  };

  void _pushRealtimeParamsToIsolate() {
    if (!_isPlaying) return;
    _isolateSendPort?.send({
      'cmd': 'updateParams',
      'params': _buildCorrectionParams(),
    });
  }

  Future<void> _playVideo() async {
    if (!_hasVideo || _isSaving || _isPlaying) {
      debugPrint('No video selected or video not opened');
      return;
    }

    final resume = _isPaused;
    final targetFps = fps > 1 ? fps : 30.0;
    final startFrame = resume ? _lastReceivedFrameNum : 0;
    _playbackSession += 1;
    final session = _playbackSession;

    setState(() {
      _isPlaying = true;
      _isPaused = false;
      _statusText = 'Playing';
    });

    // Kill any existing worker isolate
    await _killPlaybackIsolate();

    _fromIsolatePort = ReceivePort();
    final params = _buildCorrectionParams();
    final videoPath = _openedSrcPath!;

    _playbackIsolate = await Isolate.spawn(_playbackIsolateEntry, [
      _fromIsolatePort!.sendPort,
      videoPath,
      startFrame,
      targetFps,
      params,
    ]);

    // Do not block playback startup on audio initialization.
    unawaited(() async {
      if (resume) {
        try {
          await _audioPlayer.play();
        } catch (e) {
          debugPrint('Audio resume failed: $e');
        }
      } else {
        await _startAudioForPlayback();
      }
    }());

    _isolateSub = _fromIsolatePort!.listen((msg) async {
      if (session != _playbackSession) return;
      if (msg is! Map) return;

      final type = msg['type'] as String?;
      if (type == 'handshake') {
        _isolateSendPort = msg['port'] as SendPort?;
      } else if (type == 'frame') {
        final rgba = msg['rgba'] as Uint8List?;
        final w = msg['width'] as int?;
        final h = msg['height'] as int?;
        final frameNum = msg['frameNum'] as int?;
        if (rgba == null || w == null || h == null) {
          _isolateSendPort?.send({'cmd': 'ack'});
          return;
        }
        if (frameNum != null && !_seekingSlider) {
          _lastReceivedFrameNum = frameNum;
          unawaited(_maybeFineResyncAudio(frameNum));
        }

        if (!mounted || !_isPlaying || session != _playbackSession) {
          _isolateSendPort?.send({'cmd': 'ack'});
          return;
        }

        // Fast decode using decodeImageFromPixels (avoids codec overhead).
        final completer = Completer<ui.Image>();
        ui.decodeImageFromPixels(
          rgba,
          w,
          h,
          ui.PixelFormat.rgba8888,
          completer.complete,
        );
        final image = await completer.future;

        if (!mounted || !_isPlaying || session != _playbackSession) {
          image.dispose();
          _isolateSendPort?.send({'cmd': 'ack'});
          return;
        }
        setState(() => _currentFrame = image);
        // Send ack so isolate proceeds to next frame (backpressure).
        _isolateSendPort?.send({'cmd': 'ack'});
      } else if (type == 'done') {
        if (!mounted) return;
        // If pause was requested, the isolate was already killed; ignore stale 'done'.
        if (!_isPlaying) return;
        await _killPlaybackIsolate();
        await _stopAudioPlayback();
        if (!mounted) return;
        setState(() {
          _isPlaying = false;
          _isPaused = false;
          _statusText = 'Playback finished';
        });
        if (vc.isOpened) await _refreshPreviewFrame();
      } else if (type == 'error') {
        final message = msg['message'] as String? ?? 'Unknown error';
        debugPrint('Playback isolate error: $message');
        await _killPlaybackIsolate();
        await _stopAudioPlayback();
        if (!mounted) return;
        setState(() {
          _isPlaying = false;
          _isPaused = false;
          _statusText = 'Error: $message';
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: LayoutBuilder(
          builder: (context, constraints) {
            return Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: constraints.maxWidth,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text('Video Correction').color(Colors.white),
                ),
              ),
            );
          },
        ),
        leading: IconButton(
          icon: const Icon(Icons.home, color: Colors.white, size: 30),
          onPressed: () {
            context.goNamed(RoutePage.splash.name);
          },
        ),
        actions: [
          IconButton(
            tooltip: 'Select video',
            onPressed: _isSaving ? null : _selectVideo,
            icon: const Icon(Icons.folder_open, color: Colors.white),
          ),
          IconButton(
            tooltip: 'Save corrected video',
            onPressed: (_hasVideo && !_isSaving) ? _saveEditedVideo : null,
            icon: const Icon(Icons.save_alt, color: Colors.white),
          ),
        ],
        backgroundColor: colorMain,
      ),
      body: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _buildMainContent(),
              ),
            ),
            Container(
              width: 360,
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(left: BorderSide(color: Colors.black12)),
              ),
              child: _buildControlPanel(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainContent() {
    return Column(
      children: [
        if (_isSaving)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: LinearProgressIndicator(value: _saveProgress),
          ),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 16,
          runSpacing: 8,
          children: [
            Text('status: $_statusText'),
            Text('size: ${width > 0 ? '$width x $height' : '-'}'),
            Text('fps: ${fps > 0 ? fps.toStringAsFixed(2) : '-'}'),
            Text('backend: $backend'),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Center(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final aspect = _videoAspectRatio;
                var videoWidth = constraints.maxWidth;
                var videoHeight = videoWidth / aspect;
                if (videoHeight > constraints.maxHeight) {
                  videoHeight = constraints.maxHeight;
                  videoWidth = videoHeight * aspect;
                }

                return AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: videoWidth,
                  height: videoHeight,
                  child: _previewContainer(child: _buildVideoSurface()),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        ExtendedText(
          'src: $src',
          maxLines: 1,
          overflowWidget: const TextOverflowWidget(
            position: TextOverflowPosition.middle,
            child: Text('...'),
          ),
        ),
        const SizedBox(height: 4),
        ExtendedText(
          'dst: $dst',
          maxLines: 1,
          overflowWidget: const TextOverflowWidget(
            position: TextOverflowPosition.middle,
            child: Text('...'),
          ),
        ),
      ],
    );
  }

  Widget _buildControlPanel() {
    return Column(
      children: [
        const ListTile(
          title: Text(
            'Correction Controls',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              _sliderTile(
                title: 'Auto correction strength',
                value: _autoStrength,
                min: 0,
                max: 1,
                divisions: 20,
                label: _autoStrength.toStringAsFixed(2),
                enabled: _autoCorrection,
                onChanged: (v) {
                  setState(() => _autoStrength = v);
                  _pushRealtimeParamsToIsolate();
                },
                onChangeEnd: (_) => _refreshPreviewFrame(),
              ),
              SwitchListTile(
                value: _autoCorrection,
                title: const Text('Enable automatic underwater correction'),
                onChanged: (v) {
                  setState(() {
                    _autoCorrection = v;
                  });
                  _pushRealtimeParamsToIsolate();
                  _refreshPreviewFrame();
                },
              ),
              _sliderTile(
                title: 'Contrast',
                value: _contrast,
                min: 0.6,
                max: 2.2,
                divisions: 32,
                label: _contrast.toStringAsFixed(2),
                onChanged: (v) {
                  setState(() => _contrast = v);
                  _pushRealtimeParamsToIsolate();
                },
                onChangeEnd: (_) => _refreshPreviewFrame(),
              ),
              _sliderTile(
                title: 'Brightness',
                value: _brightness,
                min: -60,
                max: 80,
                divisions: 70,
                label: _brightness.toStringAsFixed(0),
                onChanged: (v) {
                  setState(() => _brightness = v);
                  _pushRealtimeParamsToIsolate();
                },
                onChangeEnd: (_) => _refreshPreviewFrame(),
              ),
              _sliderTile(
                title: 'Saturation',
                value: _saturation,
                min: 0.4,
                max: 2.4,
                divisions: 40,
                label: _saturation.toStringAsFixed(2),
                onChanged: (v) {
                  setState(() => _saturation = v);
                  _pushRealtimeParamsToIsolate();
                },
                onChangeEnd: (_) => _refreshPreviewFrame(),
              ),
              _sliderTile(
                title: 'Color temperature',
                value: _temperature,
                min: -100,
                max: 100,
                divisions: 40,
                label: _temperature.toStringAsFixed(0),
                onChanged: (v) {
                  setState(() => _temperature = v);
                  _pushRealtimeParamsToIsolate();
                },
                onChangeEnd: (_) => _refreshPreviewFrame(),
              ),
              _sliderTile(
                title: 'Red recovery',
                value: _redRecovery,
                min: 0.8,
                max: 2.6,
                divisions: 36,
                label: _redRecovery.toStringAsFixed(2),
                enabled: _autoCorrection,
                onChanged: (v) {
                  setState(() => _redRecovery = v);
                  _pushRealtimeParamsToIsolate();
                },
                onChangeEnd: (_) => _refreshPreviewFrame(),
              ),
              SwitchListTile(
                value: _localMaskEnabled,
                title: const Text('Enable local mask (highlight protection)'),
                onChanged: (v) {
                  setState(() {
                    _localMaskEnabled = v;
                  });
                  _pushRealtimeParamsToIsolate();
                  _refreshPreviewFrame();
                },
              ),
              _sliderTile(
                title: 'Local mask strength',
                value: _localMaskStrength,
                min: 0,
                max: 1,
                divisions: 20,
                label: _localMaskStrength.toStringAsFixed(2),
                enabled: _localMaskEnabled,
                onChanged: (v) {
                  setState(() => _localMaskStrength = v);
                  _pushRealtimeParamsToIsolate();
                },
                onChangeEnd: (_) => _refreshPreviewFrame(),
              ),
              _sliderTile(
                title: 'Blue ocean tone',
                value: _blueOceanTone,
                min: 0.7,
                max: 1.8,
                divisions: 22,
                label: _blueOceanTone.toStringAsFixed(2),
                onChanged: (v) {
                  setState(() => _blueOceanTone = v);
                  _pushRealtimeParamsToIsolate();
                },
                onChangeEnd: (_) => _refreshPreviewFrame(),
              ),
              SwitchListTile(
                value: _particleReduction,
                title: const Text('Remove particles / improve clarity'),
                onChanged: (v) {
                  setState(() {
                    _particleReduction = v;
                  });
                  _pushRealtimeParamsToIsolate();
                  _refreshPreviewFrame();
                },
              ),
              _sliderTile(
                title: 'Particle reduction',
                value: _particleReductionStrength,
                min: 0,
                max: 1,
                divisions: 20,
                label: _particleReductionStrength.toStringAsFixed(2),
                enabled: _particleReduction,
                onChanged: (v) {
                  setState(() => _particleReductionStrength = v);
                  _pushRealtimeParamsToIsolate();
                },
                onChangeEnd: (_) => _refreshPreviewFrame(),
              ),
              _sliderTile(
                title: 'Audio volume',
                value: _audioVolume,
                min: 0,
                max: 1,
                divisions: 20,
                label: _audioVolume.toStringAsFixed(2),
                onChanged: (v) {
                  setState(() => _audioVolume = v);
                  if (_audioEnabled) {
                    unawaited(_audioPlayer.setVolume(v * 100.0));
                  }
                },
                onChangeEnd: (_) {},
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _isSaving
                      ? null
                      : () async {
                          setState(() {
                            _autoCorrection = true;
                            _autoStrength = 0.62;
                            _contrast = 1.2;
                            _brightness = 6;
                            _saturation = 1.12;
                            _temperature = 10;
                            _redRecovery = 1.05;
                            _localMaskEnabled = false;
                            _localMaskStrength = 0.55;
                            _blueOceanTone = 1.12;
                            _particleReduction = false;
                            _particleReductionStrength = 0.55;
                          });
                          await _refreshPreviewFrame();
                        },
                  child: const Text('Reset'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: (_hasVideo && !_isSaving)
                      ? _saveEditedVideo
                      : null,
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildVideoSurface() {
    String fmtFrameToTime(int frames) {
      final seconds = (fps > 0 ? frames / fps : 0.0).round();
      final m = seconds ~/ 60;
      final s = seconds % 60;
      return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }

    final progress = (_totalFrames > 0)
        ? (_lastReceivedFrameNum / _totalFrames).clamp(0.0, 1.0)
        : 0.0;

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: Colors.black,
          child: _currentFrame == null
              ? const Center(
                  child: Text(
                    'Select a video',
                    style: TextStyle(color: Colors.white70, fontSize: 18),
                  ),
                )
              : RawImage(
                  image: _currentFrame,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black87],
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 20, 10, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2.5,
                      activeTrackColor: Colors.white,
                      inactiveTrackColor: Colors.white30,
                      thumbColor: Colors.white,
                      overlayColor: Colors.white24,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                    ),
                    child: Slider(
                      value: progress,
                      onChanged: (_hasVideo && !_isSaving)
                          ? (v) {
                              setState(() {
                                _seekingSlider = true;
                                _lastReceivedFrameNum = (_totalFrames * v)
                                    .round();
                              });
                            }
                          : null,
                      onChangeEnd: (_hasVideo && !_isSaving)
                          ? (v) => _seekTo((_totalFrames * v).round())
                          : null,
                    ),
                  ),
                  Row(
                    children: [
                      IconButton(
                        tooltip: _isPlaying ? 'Pause' : 'Play',
                        onPressed: (!_hasVideo || _isSaving)
                            ? null
                            : (_isPlaying ? _pauseVideo : _playVideo),
                        icon: Icon(
                          _isPlaying
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_fill,
                          color: Colors.white,
                          size: 34,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Stop',
                        onPressed:
                            (!_hasVideo ||
                                _isSaving ||
                                (!_isPlaying && !_isPaused))
                            ? null
                            : _stopVideo,
                        icon: const Icon(
                          Icons.stop_circle,
                          color: Colors.white,
                          size: 30,
                        ),
                      ),
                      Text(
                        '${fmtFrameToTime(_lastReceivedFrameNum)} / ${fmtFrameToTime(_totalFrames)}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                      const Spacer(),
                      Icon(
                        _audioVolume == 0 ? Icons.volume_off : Icons.volume_up,
                        color: Colors.white,
                        size: 18,
                      ),
                      SizedBox(
                        width: 92,
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 2,
                            activeTrackColor: Colors.white,
                            inactiveTrackColor: Colors.white24,
                            thumbColor: Colors.white,
                            overlayColor: Colors.white24,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 5,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 10,
                            ),
                          ),
                          child: Slider(
                            value: _audioVolume,
                            min: 0,
                            max: 1,
                            onChanged: (_isSaving || !_hasVideo)
                                ? null
                                : (value) {
                                    setState(() => _audioVolume = value);
                                    unawaited(
                                      _audioPlayer.setVolume(value * 100.0),
                                    );
                                  },
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _previewContainer({required Widget child}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black,
          border: Border.all(color: Colors.black12),
          boxShadow: const [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 18,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: child,
      ),
    );
  }

  Widget _sliderTile({
    required String title,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String label,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
    bool enabled = true,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$title: $label'),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            label: label,
            onChanged: enabled ? onChanged : null,
            onChangeEnd: enabled ? onChangeEnd : null,
          ),
        ],
      ),
    );
  }

  Future<ui.Image> _cvMatToImage(cv.Mat mat, {(int, int)? dstSize}) async {
    final resized = dstSize == null ? mat : await cv.resizeAsync(mat, dstSize);
    final rgba = await cv.cvtColorAsync(resized, cv.COLOR_BGR2RGBA);
    if (!identical(resized, mat)) resized.dispose();
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba.data,
      rgba.width,
      rgba.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final image = await completer.future;
    rgba.dispose();
    return image;
  }
}

/// Entry point for the background playback isolate.
/// args: [SendPort mainPort, String videoPath, int startFrame, double fps,
///        Map<String,dynamic> params]
Future<void> _playbackIsolateEntry(List<dynamic> args) async {
  final SendPort mainPort = args[0] as SendPort;
  final String videoPath = args[1] as String;
  final int startFrame = args[2] as int;
  final double sourceFps = args[3] as double;
  Map<String, dynamic> params = Map<String, dynamic>.from(args[4] as Map);
  final playbackFps = sourceFps.isFinite && sourceFps > 1 ? sourceFps : 30.0;
  final frameIntervalUs = (1000000 / playbackFps).round();

  final receivePort = ReceivePort();
  mainPort.send({'type': 'handshake', 'port': receivePort.sendPort});
  final commands = StreamIterator<dynamic>(receivePort);

  final vc = cv.VideoCapture.fromFile(videoPath);
  if (!vc.isOpened) {
    mainPort.send({
      'type': 'error',
      'message': 'Cannot open video: $videoPath',
    });
    vc.dispose();
    receivePort.close();
    return;
  }

  if (startFrame > 0) {
    vc.set(cv.CAP_PROP_POS_FRAMES, startFrame.toDouble());
  }
  var timelineBaseFrame = startFrame;
  final playbackClock = Stopwatch()..start();

  const hdWidth = 960;
  const hdHeight = 540;

  while (true) {
    final (success, raw) = await vc.readAsync();
    if (!success || raw.width == 0 || raw.height == 0) {
      raw.dispose();
      break;
    }

    cv.Mat frame;
    if (raw.width > hdWidth || raw.height > hdHeight) {
      final scaleW = hdWidth / raw.width;
      final scaleH = hdHeight / raw.height;
      final scale = math.min(scaleW, scaleH);
      final tw = math.max(1, (raw.width * scale).round());
      final th = math.max(1, (raw.height * scale).round());
      frame = await cv.resizeAsync(raw, (tw, th));
      raw.dispose();
    } else {
      frame = raw;
    }

    final corrected = await _applyRealtimeCorrections(frame, params);
    if (!identical(corrected, frame)) frame.dispose();

    final rgba = await cv.cvtColorAsync(corrected, cv.COLOR_BGR2RGBA);
    corrected.dispose();
    final rgbaBytes = Uint8List.fromList(rgba.data);
    final w = rgba.width;
    final h = rgba.height;
    rgba.dispose();

    final frameNum = vc.get(cv.CAP_PROP_POS_FRAMES).round() - 1;
    mainPort.send({
      'type': 'frame',
      'rgba': rgbaBytes,
      'width': w,
      'height': h,
      'frameNum': frameNum,
    });

    var stopRequested = false;
    var seekRequested = false;
    while (true) {
      if (!await commands.moveNext()) {
        stopRequested = true;
        break;
      }
      final cmd = commands.current;
      if (cmd is! Map) {
        continue;
      }

      final c = cmd['cmd'] as String?;
      if (c == 'stop') {
        stopRequested = true;
        break;
      }
      if (c == 'updateParams') {
        final updated = cmd['params'];
        if (updated is Map) {
          params = Map<String, dynamic>.from(updated);
        }
        continue;
      }
      if (c == 'seek') {
        final seekFrame = cmd['frame'] as int? ?? 0;
        vc.set(cv.CAP_PROP_POS_FRAMES, seekFrame.toDouble());
        timelineBaseFrame = seekFrame;
        playbackClock
          ..reset()
          ..start();
        seekRequested = true;
        break;
      }
      if (c == 'ack') {
        break;
      }
    }

    if (stopRequested) break;
    if (seekRequested) continue;

    final elapsedUs = playbackClock.elapsedMicroseconds;
    final playedFrameCount = math.max(0, frameNum - timelineBaseFrame + 1);
    final targetElapsedUs = playedFrameCount * frameIntervalUs;
    final waitUs = targetElapsedUs - elapsedUs;
    if (waitUs > 0) {
      await Future<void>.delayed(Duration(microseconds: waitUs));
    }
  }

  vc.release();
  receivePort.close();
  mainPort.send({'type': 'done'});
}

Future<cv.Mat> _applyRealtimeCorrections(
  cv.Mat inputFrame,
  Map<String, dynamic> params,
) async {
  cv.Mat working = inputFrame;

  final particleReduction = params['particleReduction'] as bool? ?? false;
  final particleReductionStrength =
      params['particleReductionStrength'] as double? ?? 0.55;
  if (particleReduction) {
    final kernel = particleReductionStrength < 0.33
        ? 3
        : (particleReductionStrength < 0.66 ? 5 : 7);
    final denoised = await cv.medianBlurAsync(working, kernel);
    if (!identical(working, inputFrame)) working.dispose();
    working = denoised;
  }

  final autoCorrection = params['autoCorrection'] as bool? ?? true;
  if (autoCorrection) {
    final autoStrength = params['autoStrength'] as double? ?? 0.62;
    final redRecovery = params['redRecovery'] as double? ?? 1.05;
    final localMaskEnabled = params['localMaskEnabled'] as bool? ?? false;
    final localMaskStrength = params['localMaskStrength'] as double? ?? 0.55;

    final beforeAuto = localMaskEnabled
        ? cv.Mat.fromMat(working, copy: true)
        : cv.Mat.empty();

    final channels = await cv.splitAsync(working);
    final b = channels[0];
    final g = channels[1];
    final r = channels[2];

    final bMean = b.mean().val1;
    final gMean = g.mean().val1;
    final rMean = r.mean().val1;
    final target = (bMean + gMean + rMean) / 3.0;
    final blueGreen = (bMean + gMean) / 2.0;
    final redDeficit = ((blueGreen - rMean) / math.max(blueGreen, 1.0)).clamp(
      0.0,
      1.0,
    );

    final bGain = (target / math.max(bMean, 1.0)).clamp(0.7, 1.8);
    final gGain = (target / math.max(gMean, 1.0)).clamp(0.7, 1.8);
    final rGain = (target / math.max(rMean, 1.0)).clamp(0.7, 1.8);
    final highlight = ((target - 138.0) / 90.0).clamp(0.0, 1.0);
    final warmScene = ((rMean - gMean) / math.max(target, 1.0)).clamp(
      0.0,
      0.45,
    );
    final redBoostBase =
        1.0 + redDeficit * (0.42 + autoStrength * 0.48) * redRecovery;
    final redBoost =
        (1.0 +
                (redBoostBase - 1.0) *
                    (1.0 - 0.8 * highlight - 0.55 * warmScene))
            .clamp(1.0, 1.38);
    final blueSuppress = (1.0 - redDeficit * 0.10 * autoStrength).clamp(
      0.9,
      1.0,
    );
    final greenSuppress = (1.0 - redDeficit * 0.04 * autoStrength).clamp(
      0.95,
      1.0,
    );

    final bAlpha = (1.0 + (bGain - 1.0) * autoStrength) * blueSuppress;
    final gAlpha = (1.0 + (gGain - 1.0) * autoStrength) * greenSuppress;
    final rAlpha = ((1.0 + (rGain - 1.0) * autoStrength) * redBoost).clamp(
      0.9,
      1.45,
    );

    final bAdj = await cv.convertScaleAbsAsync(b, alpha: bAlpha);
    final gAdj = await cv.convertScaleAbsAsync(g, alpha: gAlpha);
    final rAdj = await cv.convertScaleAbsAsync(r, alpha: rAlpha);
    final balanced = await cv.mergeAsync(
      cv.VecMat.fromList([bAdj, gAdj, rAdj]),
    );

    b.dispose();
    g.dispose();
    r.dispose();
    bAdj.dispose();
    gAdj.dispose();
    rAdj.dispose();
    if (!identical(working, inputFrame)) working.dispose();
    working = balanced;

    if (localMaskEnabled && !beforeAuto.isEmpty) {
      final gray = await cv.cvtColorAsync(beforeAuto, cv.COLOR_BGR2GRAY);
      final threshold = (215.0 - localMaskStrength * 55.0).clamp(145.0, 220.0);
      final (_, highlightMask) = await cv.thresholdAsync(
        gray,
        threshold,
        255,
        cv.THRESH_BINARY,
      );
      final invMask = await cv.bitwiseNOTAsync(highlightMask);
      final correctedCore = await cv.bitwiseANDAsync(
        working,
        working,
        mask: invMask,
      );
      final preservedHighlight = await cv.bitwiseANDAsync(
        beforeAuto,
        beforeAuto,
        mask: highlightMask,
      );
      final mixed = await cv.addAsync(correctedCore, preservedHighlight);

      gray.dispose();
      highlightMask.dispose();
      invMask.dispose();
      correctedCore.dispose();
      preservedHighlight.dispose();
      working.dispose();
      working = mixed;
    }
    beforeAuto.dispose();
  }

  final contrast = math.min(params['contrast'] as double? ?? 1.2, 1.12);
  final brightness = math.min(params['brightness'] as double? ?? 6.0, 4.0);
  final leveled = await cv.convertScaleAbsAsync(
    working,
    alpha: contrast,
    beta: brightness,
  );
  if (!identical(working, inputFrame)) working.dispose();
  working = leveled;

  final blueOceanTone = params['blueOceanTone'] as double? ?? 1.12;
  if ((blueOceanTone - 1.0).abs() > 0.01) {
    final bgrChannels = await cv.splitAsync(working);
    final bScaled = await cv.convertScaleAbsAsync(
      bgrChannels[0],
      alpha: blueOceanTone,
    );
    final blued = await cv.mergeAsync(
      cv.VecMat.fromList([bScaled, bgrChannels[1], bgrChannels[2]]),
    );
    bScaled.dispose();
    working.dispose();
    working = blued;
  }

  final temperature = params['temperature'] as double? ?? 10.0;
  final tempMix = (temperature.abs() / 100.0 * 0.28).clamp(0.0, 0.28);
  if (tempMix > 0.001) {
    final tint = temperature >= 0
        ? cv.Scalar(0.0, 10.0, 40.0, 0.0)
        : cv.Scalar(40.0, 10.0, 0.0, 0.0);
    final tintMat = cv.Mat.fromScalar(
      working.rows,
      working.cols,
      cv.MatType.CV_8UC3,
      tint,
    );
    final mixed = await cv.addWeightedAsync(
      working,
      1.0,
      tintMat,
      tempMix,
      0.0,
    );
    tintMat.dispose();
    working.dispose();
    working = mixed;
  }

  return working;
}
