import 'dart:typed_data';
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dive_computer_flutter/aPref.dart';
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
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

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
  String _exportQuality = 'Original'; // 'Original', 'HD', 'FullHD', '2K', '4K'
  bool _isFullscreen = false;
  bool _processingFrame = false;
  int _playbackSession = 0;
  final FocusNode _fullscreenFocusNode = FocusNode();

  // Playback isolate state
  Isolate? _playbackIsolate;
  SendPort? _isolateSendPort;
  ReceivePort? _fromIsolatePort;
  StreamSubscription<dynamic>? _isolateSub;

  // Save isolate state
  Isolate? _saveIsolate;
  ReceivePort? _fromSaveIsolatePort;
  StreamSubscription<dynamic>? _saveIsolateSub;
  int _lastReceivedFrameNum = 0;
  int _lastReceivedPosMs = 0;
  int _totalFrames = 0;
  bool _seekingSlider = false;
  double _saveProgress = 0;
  String _statusText = 'Waiting...';
  final List<String> _playlistPaths = [];
  int _playlistIndex = -1;

  bool _isAnalysing = false;

  void _setCurrentFrame(ui.Image? image) {
    final previous = _currentFrame;
    _currentFrame = image;
    if (previous != null && !identical(previous, image)) {
      previous.dispose();
    }
  }

  bool _autoCorrection = true;
  double _autoStrength = 0.62;
  double _contrast = 1.2;
  double _brightness = 6.0;
  double _saturation = 1.12;
  double _temperature = 10.0;
  double _redRecovery = 1.05;
  bool _greenWaterAutoCorrection = false;
  double _greenWaterStrength = 0.55;
  bool _localMaskEnabled = false;
  double _localMaskStrength = 0.55;
  double _blueOceanTone = 1.12;
  bool _particleReduction = false;
  double _particleReductionStrength = 0.55;
  bool _previewMatchMode = true;
  double _audioVolume = 1.0;
  bool _audioEnabled = true;
  bool _controlsVisible = true;
  Timer? _controlsHideTimer;
  DateTime? _lastFineResyncAt;
  bool _fineResyncInFlight = false;

  bool get _hasPrevPlaylistFile => _playlistIndex > 0;
  bool get _hasNextPlaylistFile =>
      _playlistIndex >= 0 && _playlistIndex < _playlistPaths.length - 1;

  void _loadSavedSettings() {
    _autoCorrection = APref.getData(AprefKey.VC_AUTO_CORRECTION);
    _autoStrength = APref.getData(AprefKey.VC_AUTO_STRENGTH);
    _contrast = APref.getData(AprefKey.VC_CONTRAST);
    _brightness = APref.getData(AprefKey.VC_BRIGHTNESS);
    _saturation = APref.getData(AprefKey.VC_SATURATION);
    _temperature = APref.getData(AprefKey.VC_TEMPERATURE);
    _redRecovery = APref.getData(AprefKey.VC_RED_RECOVERY);
    _greenWaterAutoCorrection = APref.getData(
      AprefKey.VC_GREEN_WATER_AUTO_CORRECTION,
    );
    _greenWaterStrength = APref.getData(AprefKey.VC_GREEN_WATER_STRENGTH);
    _localMaskEnabled = APref.getData(AprefKey.VC_LOCAL_MASK_ENABLED);
    _localMaskStrength = APref.getData(AprefKey.VC_LOCAL_MASK_STRENGTH);
    _blueOceanTone = APref.getData(AprefKey.VC_BLUE_OCEAN_TONE);
    _particleReduction = APref.getData(AprefKey.VC_PARTICLE_REDUCTION);
    _particleReductionStrength = APref.getData(
      AprefKey.VC_PARTICLE_REDUCTION_STRENGTH,
    );
    _previewMatchMode = APref.getData(AprefKey.VC_PREVIEW_MATCH_MODE);
    _audioVolume = APref.getData(AprefKey.VC_AUDIO_VOLUME);
  }

  @override
  void initState() {
    super.initState();
    _loadSavedSettings();
    mk.MediaKit.ensureInitialized();
    unawaited(_clearTemporaryCacheDirectory());
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _resetControlsHideTimer(),
    );
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

  /// Deletes `_openedSrcPath` if it is a temporary copy (input_* in cache dir).
  Future<void> _deleteTempInputIfNeeded() async {
    final prev = _openedSrcPath;
    if (prev == null) return;
    final name = p.basename(prev);
    if (!name.startsWith('input_')) return;
    try {
      final f = File(prev);
      if (await f.exists()) {
        await f.delete();
        debugPrint('Deleted temp input copy: $prev');
      }
    } catch (e) {
      debugPrint('Failed to delete temp input: $e');
    }
  }

  Future<void> _clearTemporaryCacheDirectory() async {
    try {
      final cacheDir = await getApplicationCacheDirectory();
      if (!await cacheDir.exists()) return;

      await for (final entity in cacheDir.list(followLinks: false)) {
        try {
          await entity.delete(recursive: true);
        } catch (e) {
          debugPrint('Failed to delete temp entity ${entity.path}: $e');
        }
      }
    } catch (e) {
      debugPrint('Failed to clear temporary cache directory: $e');
    }
  }

  Future<bool> _openVideoCapture(String path) async {
    await _deleteTempInputIfNeeded();
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

  bool _isSupportedVideoPath(String path) {
    final ext = p.extension(path).toLowerCase();
    const supported = {
      '.mp4',
      '.mov',
      '.m4v',
      '.avi',
      '.mkv',
      '.wmv',
      '.webm',
      '.mpeg',
      '.mpg',
    };
    return supported.contains(ext);
  }

  Future<List<String>> _collectVideoFilesFromFolder(String folderPath) async {
    final dir = Directory(folderPath);
    if (!await dir.exists()) return [];

    final files = <String>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      if (_isSupportedVideoPath(entity.path)) {
        files.add(entity.path);
      }
    }

    files.sort(
      (a, b) =>
          p.basename(a).toLowerCase().compareTo(p.basename(b).toLowerCase()),
    );
    return files;
  }

  Future<bool> _openVideoPath(String path) async {
    await _stopVideo(refreshPreview: false);
    if (!mounted) return false;

    debugPrint('selected file: $path');

    // Show loading state immediately before the blocking vc.open() call.
    setState(() {
      src = path;
      _setCurrentFrame(null);
      _isPaused = false;
      _isAnalysing = true;
      _statusText = 'Opening video...';
    });
    // Yield so the UI renders the loading state before we block.
    await Future.delayed(Duration.zero);

    final ret = await _openVideoCapture(path);
    if (!mounted) {
      return ret;
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
        _lastReceivedPosMs = 0;
        _isAnalysing = true;
        _statusText = 'Analysing...';
      } else {
        width = -1;
        height = -1;
        fps = -1;
        backend = 'open-failed';
        _isAnalysing = false;
        _statusText = 'Failed to open selected video';
      }
    });

    if (ret) {
      // Show the raw first frame immediately so the user sees something.
      vc.set(cv.CAP_PROP_POS_FRAMES, 0);
      final (rawOk, rawFrame) = await vc.readAsync();
      if (rawOk && rawFrame.width > 0) {
        final rawImage = await _cvMatToImage(rawFrame);
        rawFrame.dispose();
        if (mounted) {
          setState(() {
            _setCurrentFrame(rawImage);
          });
        }
      } else {
        rawFrame.dispose();
      }
      vc.set(cv.CAP_PROP_POS_FRAMES, 0);
      await _refreshPreviewFrame();
    }

    final dstDir = await getApplicationCacheDirectory();
    if (!mounted) {
      return ret;
    }
    setState(() {
      dst = p.join(dstDir.path, 'output.mp4');
    });

    return ret;
  }

  Future<bool> _openPlaylistIndex(int index, {bool autoplay = false}) async {
    if (index < 0 || index >= _playlistPaths.length) return false;
    final path = _playlistPaths[index];
    final opened = await _openVideoPath(path);
    if (!opened || !mounted) {
      return false;
    }
    setState(() {
      _playlistIndex = index;
    });
    if (autoplay) {
      await _playVideo();
    }
    return true;
  }

  Future<bool> _openNextPlaylistFile({required bool autoplay}) async {
    for (var i = _playlistIndex + 1; i < _playlistPaths.length; i++) {
      if (await _openPlaylistIndex(i, autoplay: autoplay)) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _openPrevPlaylistFile({required bool autoplay}) async {
    for (var i = _playlistIndex - 1; i >= 0; i--) {
      if (await _openPlaylistIndex(i, autoplay: autoplay)) {
        return true;
      }
    }
    return false;
  }

  Future<void> _selectFolder() async {
    final folderPath = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select video folder',
      lockParentWindow: true,
    );
    if (folderPath == null) {
      return;
    }

    final files = await _collectVideoFilesFromFolder(folderPath);
    if (files.isEmpty) {
      if (!mounted) return;
      setState(() {
        _playlistPaths..clear();
        _playlistIndex = -1;
        _statusText = 'No video files found in selected folder';
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _playlistPaths
        ..clear()
        ..addAll(files);
      _playlistIndex = 0;
    });

    if (!await _openPlaylistIndex(0)) {
      if (!await _openNextPlaylistFile(autoplay: false)) {
        if (!mounted) return;
        setState(() {
          _statusText = 'No playable video files in selected folder';
        });
      }
    }
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

    if (_greenWaterAutoCorrection) {
      final bgr = await cv.splitAsync(working);
      final b = bgr[0];
      final g = bgr[1];
      final r = bgr[2];

      final bMean = b.mean().val1;
      final gMean = g.mean().val1;
      final rMean = r.mean().val1;
      final rgAvg = (rMean + bMean) / 2.0;
      final greenBias = ((gMean - rgAvg) / math.max(gMean, 1.0)).clamp(
        0.0,
        1.0,
      );
      final mix = (_greenWaterStrength * (0.35 + 0.65 * greenBias)).clamp(
        0.0,
        1.0,
      );

      final greenReduce = (1.0 - mix * (realtime ? 0.14 : 0.24)).clamp(
        realtime ? 0.82 : 0.74,
        1.0,
      );
      final redBoost = (1.0 + mix * (realtime ? 0.12 : 0.20)).clamp(
        1.0,
        realtime ? 1.22 : 1.36,
      );
      final blueBoost = (1.0 + mix * (realtime ? 0.08 : 0.14)).clamp(
        1.0,
        realtime ? 1.16 : 1.28,
      );

      final bAdj = await cv.convertScaleAbsAsync(b, alpha: blueBoost);
      final gAdj = await cv.convertScaleAbsAsync(g, alpha: greenReduce);
      final rAdj = await cv.convertScaleAbsAsync(r, alpha: redBoost);
      final magentaBalanced = await cv.mergeAsync(
        cv.VecMat.fromList([bAdj, gAdj, rAdj]),
      );

      b.dispose();
      g.dispose();
      r.dispose();
      bAdj.dispose();
      gAdj.dispose();
      rAdj.dispose();
      if (!identical(working, inputFrame)) {
        working.dispose();
      }
      working = magentaBalanced;
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
      final hCh = hsvChannels[0];
      final sCh = hsvChannels[1];
      final vCh = hsvChannels[2];
      final satAdjusted = await cv.convertScaleAbsAsync(sCh, alpha: saturation);
      final hsvMerged = await cv.mergeAsync(
        cv.VecMat.fromList([hCh, satAdjusted, vCh]),
      );
      final saturatedBgr = await cv.cvtColorAsync(hsvMerged, cv.COLOR_HSV2BGR);

      satAdjusted.dispose();
      hCh.dispose();
      sCh.dispose();
      vCh.dispose();
      hsvMerged.dispose();
      hsv.dispose();
      working.dispose();
      working = saturatedBgr;
    }

    if ((_blueOceanTone - 1.0).abs() > 0.01) {
      // In realtime mode, just scale the blue channel directly (no masking).
      if (realtime) {
        final bgrChannels = await cv.splitAsync(working);
        final bBaseChannel = bgrChannels[0];
        final gBaseChannel = bgrChannels[1];
        final rBaseChannel = bgrChannels[2];
        final bScaled = await cv.convertScaleAbsAsync(
          bBaseChannel,
          alpha: _blueOceanTone,
        );
        final blued = await cv.mergeAsync(
          cv.VecMat.fromList([bScaled, gBaseChannel, rBaseChannel]),
        );
        bScaled.dispose();
        bBaseChannel.dispose();
        gBaseChannel.dispose();
        rBaseChannel.dispose();
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
        b.dispose();
        g.dispose();
        r.dispose();
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

  Future<void> _seekAudioToMs(int posMs) async {
    if (!_audioEnabled) return;
    try {
      await _audioPlayer.seek(Duration(milliseconds: math.max(0, posMs)));
    } catch (e) {
      debugPrint('Audio seek failed: $e');
    }
  }

  Future<void> _maybeFineResyncAudio(int posMs) async {
    if (!_isPlaying || !_audioEnabled || !_hasVideo) return;
    if (_fineResyncInFlight) return;

    final now = DateTime.now();
    if (_lastFineResyncAt != null &&
        now.difference(_lastFineResyncAt!).inMilliseconds < 450) {
      return;
    }

    _fineResyncInFlight = true;
    try {
      final videoPos = Duration(milliseconds: math.max(0, posMs));
      final audioPos = _audioPlayer.state.position;
      final driftMs = audioPos.inMilliseconds - videoPos.inMilliseconds;

      // Keep tiny jitter untouched; only correct meaningful drift.
      if (driftMs.abs() >= 120) {
        await _audioPlayer.seek(videoPos);
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
      final corrected = _previewMatchMode
          ? await _applyExportCorrections(preview, _buildCorrectionParams())
          : await _applyCorrections(preview, realtime: true);
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
        _setCurrentFrame(image);
        _isAnalysing = false;
        _statusText = 'Video ready';
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

    final file = result.files.single;
    final path = file.path;
    if (path == null) {
      return;
    }

    if (!mounted) return;
    setState(() {
      _playlistPaths
        ..clear()
        ..add(path);
      _playlistIndex = 0;
    });
    await _openPlaylistIndex(0);
  }

  Future<void> _seekTo(int frameNum) async {
    if (!_hasVideo || _isSaving) return;
    final target = frameNum.clamp(0, math.max(0, _totalFrames - 1)).toInt();
    _seekingSlider = true;
    _lastReceivedFrameNum = target;
    // Compute actual ms position from the video rather than fps-based estimate.
    vc.set(cv.CAP_PROP_POS_FRAMES, target.toDouble());
    final seekPosMs = vc.get(cv.CAP_PROP_POS_MSEC).round();
    _lastReceivedPosMs = seekPosMs;
    unawaited(_seekAudioToMs(seekPosMs));

    if (_isPlaying) {
      // Kill the in-flight isolate immediately (no waiting for current frame to finish)
      // and restart from the target position. This gives instant seek response.
      await _killPlaybackIsolate();
      _seekingSlider = false;
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _isPaused =
              true; // _playVideo will resume from _lastReceivedFrameNum = target
          _statusText = 'Seeking...';
        });
      }
      await _playVideo();
      return;
    }

    // Position was already set above for ms calculation; keep it there.
    _seekingSlider = false;
    if (!_processingFrame) {
      _processingFrame = true;
      try {
        final (ok, frame) = await vc.readAsync();
        if (ok && frame.width > 0) {
          final corrected = _previewMatchMode
              ? await _applyExportCorrections(frame, _buildCorrectionParams())
              : await _applyCorrections(frame, realtime: true);
          final image = await _cvMatToImage(corrected);
          frame.dispose();
          corrected.dispose();
          if (mounted) {
            setState(() => _setCurrentFrame(image));
          } else {
            image.dispose();
          }
        } else {
          frame.dispose();
        }
      } finally {
        _processingFrame = false;
        vc.set(cv.CAP_PROP_POS_FRAMES, _lastReceivedFrameNum.toDouble());
      }
    } else {
      // Not processing frame: restore position that was changed for ms read.
      vc.set(cv.CAP_PROP_POS_FRAMES, _lastReceivedFrameNum.toDouble());
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

  Future<void> _saveSettings() async {
    await APref.setData(AprefKey.VC_AUTO_CORRECTION, _autoCorrection);
    await APref.setData(AprefKey.VC_AUTO_STRENGTH, _autoStrength);
    await APref.setData(AprefKey.VC_CONTRAST, _contrast);
    await APref.setData(AprefKey.VC_BRIGHTNESS, _brightness);
    await APref.setData(AprefKey.VC_SATURATION, _saturation);
    await APref.setData(AprefKey.VC_TEMPERATURE, _temperature);
    await APref.setData(AprefKey.VC_RED_RECOVERY, _redRecovery);
    await APref.setData(
      AprefKey.VC_GREEN_WATER_AUTO_CORRECTION,
      _greenWaterAutoCorrection,
    );
    await APref.setData(AprefKey.VC_GREEN_WATER_STRENGTH, _greenWaterStrength);
    await APref.setData(AprefKey.VC_LOCAL_MASK_ENABLED, _localMaskEnabled);
    await APref.setData(AprefKey.VC_LOCAL_MASK_STRENGTH, _localMaskStrength);
    await APref.setData(AprefKey.VC_BLUE_OCEAN_TONE, _blueOceanTone);
    await APref.setData(AprefKey.VC_PARTICLE_REDUCTION, _particleReduction);
    await APref.setData(
      AprefKey.VC_PARTICLE_REDUCTION_STRENGTH,
      _particleReductionStrength,
    );
    await APref.setData(AprefKey.VC_PREVIEW_MATCH_MODE, _previewMatchMode);
    await APref.setData(AprefKey.VC_AUDIO_VOLUME, _audioVolume);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Settings saved.')));
    }
  }

  /// Shows a dialog to pick export quality. Returns the chosen quality string,
  /// or null if the user cancelled.
  Future<String?> _showExportQualityDialog(int srcW, int srcH) async {
    const qualities = ['Original', 'HD', 'FullHD', '2K', '4K'];
    const labels = {
      'Original': '원본 해상도',
      'HD': 'HD  (1280×720)',
      'FullHD': 'Full HD  (1920×1080)',
      '2K': '2K  (2560×1440)',
      '4K': '4K  (3840×2160)',
    };

    // Map quality → target height for preview
    int targetH(String q) {
      switch (q) {
        case 'HD':
          return 720;
        case 'FullHD':
          return 1080;
        case '2K':
          return 1440;
        case '4K':
          return 2160;
        default:
          return srcH;
      }
    }

    String resolution(String q) {
      if (q == 'Original') return '${srcW}×$srcH';
      final th = targetH(q);
      if (th >= srcH) return '${srcW}×$srcH (원본 유지)';
      final tw = ((srcW * th / srcH).round() ~/ 2) * 2;
      return '${tw}×$th';
    }

    return showDialog<String>(
      context: context,
      builder: (ctx) {
        String selected = _exportQuality;
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('저장 화질 선택'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: qualities.map((q) {
                  return RadioListTile<String>(
                    title: Text(labels[q]!),
                    subtitle: Text(
                      resolution(q),
                      style: const TextStyle(fontSize: 12),
                    ),
                    value: q,
                    groupValue: selected,
                    dense: true,
                    onChanged: (v) => setLocal(() => selected = v!),
                  );
                }).toList(),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('취소'),
                ),
                ElevatedButton(
                  onPressed: () {
                    setState(() => _exportQuality = selected);
                    Navigator.of(ctx).pop(selected);
                  },
                  child: const Text('확인'),
                ),
              ],
            );
          },
        );
      },
    );
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
    await _killPlaybackIsolate();
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

    // Show quality selection dialog
    final quality = await _showExportQualityDialog(srcW, srcH);
    if (quality == null) {
      exportCapture.dispose();
      if (mounted) {
        setState(() {
          _isSaving = false;
          _statusText = 'Export cancelled.';
        });
      }
      return;
    }

    // Compute target resolution (maintain aspect ratio, never upscale)
    int outH;
    switch (quality) {
      case 'HD':
        outH = 720;
      case 'FullHD':
        outH = 1080;
      case '2K':
        outH = 1440;
      case '4K':
        outH = 2160;
      default:
        outH = srcH;
    }
    if (outH > srcH) outH = srcH; // never upscale
    int outW = srcH > 0 ? ((srcW * outH / srcH).round() ~/ 2) * 2 : srcW;
    outH = (outH ~/ 2) * 2;

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

    exportCapture.dispose(); // metadata only; export loop opens its own capture

    final safeOutputPath = await _prepareOutputPath(requestedPath);
    final targetFps = srcFps.isFinite && srcFps > 0 ? srcFps : 30.0;
    final audioSourcePath = _openedSrcPath!;

    // Try to find ffmpeg for single-pass H.264 pipe encoding.
    setState(() => _statusText = 'Locating ffmpeg...');
    final ffmpegExe = await _quickFindFfmpeg();
    if (ffmpegExe == null) {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _statusText =
              'ffmpeg not found (or auto-install failed). Export aborted.';
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _statusText = 'Starting converter...';
      });
    }

    // Run the frame-processing loop in a background isolate so the UI stays
    // responsive and the heavy 4K OpenCV work doesn't block the Flutter engine.
    _fromSaveIsolatePort = ReceivePort();
    _saveIsolate = await Isolate.spawn(_saveVideoIsolateEntry, [
      _fromSaveIsolatePort!.sendPort,
      _openedSrcPath!,
      safeOutputPath,
      targetFps,
      srcW,
      srcH,
      totalFrames,
      _buildCorrectionParams(),
      ffmpegExe,
      audioSourcePath,
      outW,
      outH,
    ]);

    final completer = Completer<Map<String, dynamic>>();
    _saveIsolateSub = _fromSaveIsolatePort!.listen((msg) {
      if (msg is! Map) return;
      final type = msg['type'] as String?;
      if (type == 'progress') {
        final written = msg['written'] as int? ?? 0;
        final total = msg['total'] as int? ?? totalFrames;
        if (mounted) {
          setState(() {
            _saveProgress = total > 0 ? (written / total).clamp(0.0, 1.0) : 0.0;
            _statusText = 'Exporting... $written/$total';
          });
        }
      } else if (type == 'done') {
        if (!completer.isCompleted) {
          completer.complete(Map<String, dynamic>.from(msg as Map));
        }
      } else if (type == 'error') {
        final errMsg = msg['message'] as String? ?? 'Unknown export error';
        debugPrint('Save isolate error: $errMsg');
        if (!completer.isCompleted) {
          completer.complete({
            'success': false,
            'hasAudio': false,
            'message': errMsg,
          });
        }
      }
    });

    final result = await completer.future;
    await _killSaveIsolate();

    final saveSucceeded = result['success'] as bool? ?? false;
    if (!saveSucceeded) {
      final errDetail = result['message'] as String? ?? '';
      if (mounted) {
        setState(() {
          _isSaving = false;
          _statusText = errDetail.isNotEmpty
              ? 'Export failed: $errDetail'
              : 'Failed to write video frames.';
        });
      }
      return;
    }

    bool hasAudio = result['hasAudio'] as bool? ?? false;

    if (safeOutputPath != requestedPath) {
      await File(safeOutputPath).copy(requestedPath);
      await File(safeOutputPath).delete();
    }

    if (!mounted) return;
    setState(() {
      _isSaving = false;
      _saveProgress = 1;
      dst = requestedPath;
      _statusText = hasAudio
          ? 'Saved with audio: $requestedPath'
          : 'Saved (video only): $requestedPath';
    });
  }

  Future<void> _openSavedFolderInExplorer() async {
    final savedPath = dst;
    if (savedPath == null) return;
    final dir = p.dirname(savedPath);
    if (Platform.isWindows) {
      await Process.run('explorer.exe', ['/select,$savedPath']);
    } else if (Platform.isMacOS) {
      await Process.run('open', ['-R', savedPath]);
    } else {
      await Process.run('xdg-open', [dir]);
    }
  }

  @override
  void dispose() {
    _controlsHideTimer?.cancel();
    unawaited(_killPlaybackIsolate());
    unawaited(_killSaveIsolate());
    unawaited(_deleteTempInputIfNeeded());
    unawaited(_clearTemporaryCacheDirectory());
    vc.release();
    vw.release();
    _fullscreenFocusNode.dispose();
    _setCurrentFrame(null);
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

  Future<void> _killSaveIsolate() async {
    _saveIsolateSub?.cancel();
    _saveIsolateSub = null;
    _saveIsolate?.kill(priority: Isolate.immediate);
    _saveIsolate = null;
    _fromSaveIsolatePort?.close();
    _fromSaveIsolatePort = null;
  }

  Map<String, dynamic> _buildCorrectionParams() => {
    'autoCorrection': _autoCorrection,
    'autoStrength': _autoStrength,
    'contrast': _contrast,
    'brightness': _brightness,
    'saturation': _saturation,
    'temperature': _temperature,
    'redRecovery': _redRecovery,
    'greenWaterAutoCorrection': _greenWaterAutoCorrection,
    'greenWaterStrength': _greenWaterStrength,
    'blueOceanTone': _blueOceanTone,
    'localMaskEnabled': _localMaskEnabled,
    'localMaskStrength': _localMaskStrength,
    'particleReduction': _particleReduction,
    'particleReductionStrength': _particleReductionStrength,
    'previewMatchMode': _previewMatchMode,
  };

  Future<Map<String, dynamic>> _exportVideoWithFfmpeg({
    required String videoPath,
    required String outputPath,
    required String ffmpegExe,
    required String audioSourcePath,
    required double fps,
    required int srcW,
    required int srcH,
    required int totalFrames,
    required int outW,
    required int outH,
    required Map<String, dynamic> params,
  }) async {
    final vcExport = cv.VideoCapture.fromFile(videoPath);
    if (!vcExport.isOpened) {
      vcExport.dispose();
      return {
        'success': false,
        'hasAudio': false,
        'message': 'Cannot open video for export: $videoPath',
      };
    }

    Process? ffProcess;
    final stderrBuf = StringBuffer();
    final needsResize = outW != srcW || outH != srcH;

    try {
      ffProcess = await Process.start(ffmpegExe, [
        '-y',
        '-f',
        'rawvideo',
        '-pix_fmt',
        'bgr24',
        '-s',
        '${outW}x$outH',
        '-r',
        fps.toStringAsFixed(6),
        '-i',
        'pipe:0',
        '-i',
        audioSourcePath,
        '-map',
        '0:v:0',
        '-map',
        '1:a:0?',
        '-c:v',
        'libx264',
        '-preset',
        'fast',
        '-crf',
        '23',
        '-c:a',
        'aac',
        '-shortest',
        outputPath,
      ]);

      final stderrDone = ffProcess.stderr
          .transform(const SystemEncoding().decoder)
          .listen((s) => stderrBuf.write(s))
          .asFuture<void>()
          .catchError((_) {});

      var written = 0;
      while (true) {
        final (ok, frame) = await vcExport.readAsync();
        if (!ok || frame.width == 0 || frame.height == 0) {
          frame.dispose();
          break;
        }

        final corrected = await _applyExportCorrections(frame, params);
        cv.Mat output = corrected;
        if (needsResize) {
          output = await cv.resizeAsync(corrected, (outW, outH));
          corrected.dispose();
        }

        // Copy raw bytes to Dart heap BEFORE disposing the Mat.
        final frameBytes = Uint8List.fromList(output.data);
        frame.dispose();
        output.dispose();
        ffProcess.stdin.add(frameBytes);

        written++;
        if (written % 30 == 0) {
          // Flush every 30 frames for backpressure.
          await ffProcess.stdin.flush();
          if (mounted) {
            setState(() {
              _saveProgress = totalFrames > 0
                  ? (written / totalFrames).clamp(0.0, 1.0)
                  : 0.0;
              _statusText = 'Exporting... $written/$totalFrames';
            });
          }
          await Future<void>.delayed(Duration.zero);
        }
      }

      await ffProcess.stdin.flush();
      await ffProcess.stdin.close();
      final exitCode = await ffProcess.exitCode;
      await stderrDone;
      vcExport.dispose();

      if (exitCode == 0) {
        return {'success': true, 'hasAudio': true, 'written': written};
      }

      return {
        'success': false,
        'hasAudio': false,
        'message':
            'ffmpeg exited with code $exitCode: ${stderrBuf.toString().trim()}',
      };
    } catch (e) {
      debugPrint('ffmpeg export exception: $e');
      try {
        await ffProcess?.stdin.close();
      } catch (_) {}
      ffProcess?.kill();
      vcExport.dispose();
      return {
        'success': false,
        'hasAudio': false,
        'message': 'ffmpeg export exception: $e',
      };
    }
  }

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
        final posMs = msg['posMs'] as int?;
        if (rgba == null || w == null || h == null) {
          _isolateSendPort?.send({'cmd': 'ack'});
          return;
        }
        if (frameNum != null && !_seekingSlider) {
          _lastReceivedFrameNum = frameNum;
          if (posMs != null) {
            _lastReceivedPosMs = posMs;
            unawaited(_maybeFineResyncAudio(posMs));
          }
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
        setState(() => _setCurrentFrame(image));
        // Send ack so isolate proceeds to next frame (backpressure).
        _isolateSendPort?.send({'cmd': 'ack'});
      } else if (type == 'done') {
        if (!mounted) return;
        // If pause was requested, the isolate was already killed; ignore stale 'done'.
        if (!_isPlaying) return;
        await _killPlaybackIsolate();
        await _stopAudioPlayback();

        if (await _openNextPlaylistFile(autoplay: true)) {
          return;
        }

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

  void _enterFullscreen() {
    if (_isFullscreen) return;
    windowManager.setFullScreen(true);
    setState(() {
      _isFullscreen = true;
      _controlsVisible = true;
    });
    _resetControlsHideTimer();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fullscreenFocusNode.requestFocus();
    });
  }

  void _exitFullscreen() {
    if (!_isFullscreen) return;
    windowManager.setFullScreen(false);
    setState(() {
      _isFullscreen = false;
      _controlsVisible = true;
    });
    _resetControlsHideTimer();
  }

  void _toggleFullscreen() {
    if (_isFullscreen) {
      _exitFullscreen();
    } else {
      _enterFullscreen();
    }
  }

  void _resetControlsHideTimer() {
    _controlsHideTimer?.cancel();
    _controlsHideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _showControlsTemporarily() {
    if (!mounted) return;
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _resetControlsHideTimer();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _fullscreenFocusNode,
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.escape && _isFullscreen) {
          _exitFullscreen();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.space && _hasVideo && !_isSaving) {
          if (_isPlaying) {
            _pauseVideo();
          } else {
            _playVideo();
          }
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowRight && _hasVideo && !_isSaving) {
          final skipFrames = (fps > 0 ? fps * 10 : 300).round();
          unawaited(_seekTo(_lastReceivedFrameNum + skipFrames));
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowLeft && _hasVideo && !_isSaving) {
          final skipFrames = (fps > 0 ? fps * 10 : 300).round();
          unawaited(_seekTo(_lastReceivedFrameNum - skipFrames));
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.keyN &&
            _hasNextPlaylistFile &&
            !_isSaving) {
          final shouldAutoplay = _isPlaying;
          unawaited(_openNextPlaylistFile(autoplay: shouldAutoplay));
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.keyP &&
            _hasPrevPlaylistFile &&
            !_isSaving) {
          final shouldAutoplay = _isPlaying;
          unawaited(_openPrevPlaylistFile(autoplay: shouldAutoplay));
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        appBar: _isFullscreen
            ? null
            : AppBar(
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
                    icon: const Icon(Icons.video_file, color: Colors.white),
                  ),
                  IconButton(
                    tooltip: 'Select folder',
                    onPressed: _isSaving ? null : _selectFolder,
                    icon: const Icon(Icons.folder_open, color: Colors.white),
                  ),
                  IconButton(
                    tooltip: 'Save corrected video',
                    onPressed: (_hasVideo && !_isSaving)
                        ? _saveEditedVideo
                        : null,
                    icon: const Icon(Icons.save_alt, color: Colors.white),
                  ),
                  IconButton(
                    tooltip: 'Open saved folder in Explorer',
                    onPressed: (dst != null && !_isSaving)
                        ? _openSavedFolderInExplorer
                        : null,
                    icon: const Icon(
                      Icons.folder_open_outlined,
                      color: Colors.white,
                    ),
                  ),
                  // IconButton(
                  //   tooltip: 'Save correction settings',
                  //   onPressed: !_isSaving ? _saveSettings : null,
                  //   icon: const Icon(
                  //     Icons.settings_backup_restore,
                  //     color: Colors.white,
                  //   ),
                  // ),
                ],
                backgroundColor: colorMain,
              ),
        body: Stack(
          children: [
            SafeArea(
              child: Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: _buildMainContent(),
                    ),
                  ),
                  if (!_isFullscreen)
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
            if (_isFullscreen)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black,
                  child: Stack(
                    children: [
                      Center(child: _buildVideoSurface()),
                      Positioned(
                        top: 12,
                        right: 12,
                        child: IconButton(
                          tooltip: 'Exit fullscreen (Esc)',
                          onPressed: _exitFullscreen,
                          icon: const Icon(
                            Icons.fullscreen_exit,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainContent() {
    final currentFileName = (src == null || src!.isEmpty)
        ? '-'
        : p.basename(src!);
    final playlistLabel = (_playlistPaths.isNotEmpty && _playlistIndex >= 0)
        ? '${_playlistIndex + 1}/${_playlistPaths.length}'
        : '-';

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
            // Text('backend: $backend'),
            Text('file: $playlistLabel  $currentFileName'),
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
                const verticalPadding = 38.0;
                final maxVideoHeight = math.max(
                  1.0,
                  constraints.maxHeight - verticalPadding,
                );
                if (videoHeight > maxVideoHeight) {
                  videoHeight = maxVideoHeight;
                  videoWidth = videoHeight * aspect;
                }

                final previewWidget = AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: videoWidth,
                  height: videoHeight,
                  child: _previewContainer(child: _buildVideoSurface()),
                );

                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: videoWidth,
                      child: Align(
                        alignment: Alignment.topRight,
                        child: _buildPreviewMatchToggle(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    previewWidget,
                  ],
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
        // ExtendedText(
        //   'dst: $dst',
        //   maxLines: 1,
        //   overflowWidget: const TextOverflowWidget(
        //     position: TextOverflowPosition.middle,
        //     child: Text('...'),
        //   ),
        // ),
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
                value: _greenWaterAutoCorrection,
                title: const Text('Enable green-water auto correction'),
                subtitle: const Text('Apply magenta compensation'),
                onChanged: (v) {
                  setState(() {
                    _greenWaterAutoCorrection = v;
                  });
                  _pushRealtimeParamsToIsolate();
                  _refreshPreviewFrame();
                },
              ),
              _sliderTile(
                title: 'Green-water correction strength',
                value: _greenWaterStrength,
                min: 0,
                max: 1,
                divisions: 20,
                label: _greenWaterStrength.toStringAsFixed(2),
                enabled: _greenWaterAutoCorrection,
                onChanged: (v) {
                  setState(() => _greenWaterStrength = v);
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
                            _previewMatchMode = true;
                            _autoCorrection = true;
                            _autoStrength = 0.62;
                            _contrast = 1.2;
                            _brightness = 6;
                            _saturation = 1.12;
                            _temperature = 10;
                            _redRecovery = 1.05;
                            _greenWaterAutoCorrection = false;
                            _greenWaterStrength = 0.55;
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
                  onPressed: !_isSaving ? _saveSettings : null,
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

    return MouseRegion(
      onHover: (_) => _showControlsTemporarily(),
      child: Stack(
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
          if (_isAnalysing)
            Positioned(
              top: 12,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white70,
                        ),
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Analysing...',
                        style: TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: AnimatedOpacity(
              opacity: _controlsVisible ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 300),
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
                            tooltip: 'Previous file',
                            onPressed: (_isSaving || !_hasPrevPlaylistFile)
                                ? null
                                : () async {
                                    final shouldAutoplay = _isPlaying;
                                    await _openPrevPlaylistFile(
                                      autoplay: shouldAutoplay,
                                    );
                                  },
                            icon: const Icon(
                              Icons.skip_previous,
                              color: Colors.white,
                              size: 28,
                            ),
                          ),
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
                          IconButton(
                            tooltip: 'Next file',
                            onPressed: (_isSaving || !_hasNextPlaylistFile)
                                ? null
                                : () async {
                                    final shouldAutoplay = _isPlaying;
                                    await _openNextPlaylistFile(
                                      autoplay: shouldAutoplay,
                                    );
                                  },
                            icon: const Icon(
                              Icons.skip_next,
                              color: Colors.white,
                              size: 28,
                            ),
                          ),
                          IconButton(
                            tooltip: _isFullscreen
                                ? 'Exit fullscreen (Esc)'
                                : 'Fullscreen',
                            onPressed: _hasVideo ? _toggleFullscreen : null,
                            icon: Icon(
                              _isFullscreen
                                  ? Icons.fullscreen_exit
                                  : Icons.fullscreen,
                              color: Colors.white,
                              size: 28,
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
                            _audioVolume == 0
                                ? Icons.volume_off
                                : Icons.volume_up,
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
          ),
        ],
      ),
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

  Widget _buildPreviewMatchToggle() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.black12),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, 2)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Preview Match', style: TextStyle(fontSize: 12)),
            Switch.adaptive(
              value: _previewMatchMode,
              onChanged: (_isSaving || !_hasVideo)
                  ? null
                  : (v) {
                      setState(() {
                        _previewMatchMode = v;
                      });
                      _pushRealtimeParamsToIsolate();
                      _refreshPreviewFrame();
                    },
            ),
          ],
        ),
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
  var localFrameCount =
      0; // counts frames sent; used for timing instead of CAP_PROP_POS_FRAMES
  final playbackClock = Stopwatch()..start();

  const previewWidth = 1280;
  const previewHeight = 720;

  while (true) {
    final (success, raw) = await vc.readAsync();
    if (!success || raw.width == 0 || raw.height == 0) {
      raw.dispose();
      break;
    }

    final previewMatchMode = params['previewMatchMode'] as bool? ?? true;

    // Match OFF: resize raw frame to 720p BEFORE correction to dramatically
    // reduce pixel count (e.g. 6K→720p is ~46x fewer pixels).
    cv.Mat frameToProcess = raw;
    cv.Mat? rawResized;
    if (!previewMatchMode &&
        (raw.width > previewWidth || raw.height > previewHeight)) {
      final scaleW = previewWidth / raw.width;
      final scaleH = previewHeight / raw.height;
      final scale = math.min(scaleW, scaleH);
      final tw = math.max(1, (raw.width * scale).round());
      final th = math.max(1, (raw.height * scale).round());
      rawResized = await cv.resizeAsync(raw, (
        tw,
        th,
      ), interpolation: cv.INTER_LINEAR);
      frameToProcess = rawResized;
    }

    final corrected = previewMatchMode
        ? await _applyExportCorrections(frameToProcess, params)
        : await _applyRealtimeCorrections(frameToProcess, params);

    rawResized?.dispose();
    raw.dispose();

    final rgba = await cv.cvtColorAsync(corrected, cv.COLOR_BGR2RGBA);
    corrected.dispose();
    final rgbaBytes = Uint8List.fromList(rgba.data);
    final w = rgba.width;
    final h = rgba.height;
    rgba.dispose();

    localFrameCount++;
    final frameNum = vc.get(cv.CAP_PROP_POS_FRAMES).round() - 1;
    final posMs = vc.get(cv.CAP_PROP_POS_MSEC).round();
    mainPort.send({
      'type': 'frame',
      'rgba': rgbaBytes,
      'width': w,
      'height': h,
      'frameNum': frameNum,
      'posMs': posMs,
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
        localFrameCount = 0;
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
    final targetElapsedUs = localFrameCount * frameIntervalUs;
    final diffUs = targetElapsedUs - elapsedUs;

    // When ahead of schedule, wait to maintain target fps.
    // When behind, proceed immediately — no frame skipping to avoid choppiness.
    if (diffUs > 0) {
      await Future<void>.delayed(Duration(microseconds: diffUs));
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

  final greenWaterAutoCorrection =
      params['greenWaterAutoCorrection'] as bool? ?? false;
  if (greenWaterAutoCorrection) {
    final greenWaterStrength = params['greenWaterStrength'] as double? ?? 0.55;
    final bgr = await cv.splitAsync(working);
    final b = bgr[0];
    final g = bgr[1];
    final r = bgr[2];

    final bMean = b.mean().val1;
    final gMean = g.mean().val1;
    final rMean = r.mean().val1;
    final rgAvg = (rMean + bMean) / 2.0;
    final greenBias = ((gMean - rgAvg) / math.max(gMean, 1.0)).clamp(0.0, 1.0);
    final mix = (greenWaterStrength * (0.35 + 0.65 * greenBias)).clamp(
      0.0,
      1.0,
    );

    final greenReduce = (1.0 - mix * 0.14).clamp(0.82, 1.0);
    final redBoost = (1.0 + mix * 0.12).clamp(1.0, 1.22);
    final blueBoost = (1.0 + mix * 0.08).clamp(1.0, 1.16);

    final bAdj = await cv.convertScaleAbsAsync(b, alpha: blueBoost);
    final gAdj = await cv.convertScaleAbsAsync(g, alpha: greenReduce);
    final rAdj = await cv.convertScaleAbsAsync(r, alpha: redBoost);
    final magentaBalanced = await cv.mergeAsync(
      cv.VecMat.fromList([bAdj, gAdj, rAdj]),
    );

    b.dispose();
    g.dispose();
    r.dispose();
    bAdj.dispose();
    gAdj.dispose();
    rAdj.dispose();
    if (!identical(working, inputFrame)) working.dispose();
    working = magentaBalanced;
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
    final bBaseChannel = bgrChannels[0];
    final gBaseChannel = bgrChannels[1];
    final rBaseChannel = bgrChannels[2];
    final bScaled = await cv.convertScaleAbsAsync(
      bBaseChannel,
      alpha: blueOceanTone,
    );
    final blued = await cv.mergeAsync(
      cv.VecMat.fromList([bScaled, gBaseChannel, rBaseChannel]),
    );
    bScaled.dispose();
    bBaseChannel.dispose();
    gBaseChannel.dispose();
    rBaseChannel.dispose();
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

/// Quickly checks common locations for an ffmpeg executable without attempting
/// to download/install anything. Returns the path if found, null otherwise.
/// Finds an ffmpeg executable. If not found in PATH or common locations,
/// automatically downloads and installs a portable version (Windows only).
Future<String?> _quickFindFfmpeg() async {
  Future<bool> canRun(String exe) async {
    try {
      final r = await Process.run(exe, ['-version'], runInShell: true);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  // 1. Check system PATH
  if (await canRun('ffmpeg')) return 'ffmpeg';

  // 2. Check common local/bundled paths
  final exeDir = p.dirname(Platform.resolvedExecutable);
  final candidates = [
    p.join(Directory.current.path, 'ffmpeg.exe'),
    p.join(Directory.current.path, 'tools', 'ffmpeg', 'ffmpeg.exe'),
    p.join(Directory.current.path, 'ffmpeg', 'bin', 'ffmpeg.exe'),
    p.join(exeDir, 'ffmpeg.exe'),
    p.join(exeDir, 'ffmpeg', 'ffmpeg.exe'),
    p.join(exeDir, 'ffmpeg', 'bin', 'ffmpeg.exe'),
    p.join(exeDir, 'data', 'flutter_assets', 'assets', 'ffmpeg', 'ffmpeg.exe'),
  ];
  for (final c in candidates) {
    if (File(c).existsSync() && await canRun(c)) return c;
  }

  // 3. Check previously installed portable ffmpeg
  if (Platform.isWindows) {
    try {
      final supportDir = await getApplicationSupportDirectory();
      final installedExe = p.join(
        supportDir.path,
        'ffmpeg_portable',
        'bin',
        'ffmpeg.exe',
      );
      if (File(installedExe).existsSync() && await canRun(installedExe)) {
        return installedExe;
      }

      // 4. Auto-download portable ffmpeg (gyan.dev essentials build)
      debugPrint('[ffmpeg] Not found. Attempting auto-install...');
      final installBinDir = Directory(
        p.join(supportDir.path, 'ffmpeg_portable', 'bin'),
      );
      await installBinDir.create(recursive: true);

      final tempRoot = Directory(
        p.join(supportDir.path, 'ffmpeg_download_tmp'),
      );
      if (tempRoot.existsSync()) await tempRoot.delete(recursive: true);
      await tempRoot.create(recursive: true);

      final zipPath = p.join(tempRoot.path, 'ffmpeg.zip');
      final extractPath = p.join(tempRoot.path, 'extracted');
      const url =
          'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip';

      String psQuote(String v) => v.replaceAll("'", "''");
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
        debugPrint('[ffmpeg] Auto-install download failed: ${download.stderr}');
        return null;
      }

      // Find ffmpeg.exe inside the extracted archive (bin/ subdirectory)
      File? foundExe;
      await for (final entity in Directory(
        extractPath,
      ).list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        if (p.basename(entity.path).toLowerCase() != 'ffmpeg.exe') continue;
        if (p.basename(p.dirname(entity.path)).toLowerCase() != 'bin') continue;
        foundExe = entity;
        break;
      }

      if (foundExe == null) {
        debugPrint('[ffmpeg] Extracted archive but ffmpeg.exe not found.');
        return null;
      }

      // Copy all files from the bin/ dir into installBinDir
      final sourceBin = Directory(p.dirname(foundExe.path));
      await for (final entity in sourceBin.list(followLinks: false)) {
        if (entity is File) {
          await entity.copy(
            p.join(installBinDir.path, p.basename(entity.path)),
          );
        }
      }

      // Clean up temp files
      try {
        await tempRoot.delete(recursive: true);
      } catch (_) {}

      if (File(installedExe).existsSync() && await canRun(installedExe)) {
        debugPrint('[ffmpeg] Auto-install succeeded: $installedExe');
        return installedExe;
      }
    } catch (e) {
      debugPrint('[ffmpeg] Auto-install exception: $e');
    }
  }

  return null;
}

/// Entry point for the background save isolate.
/// args: [SendPort, videoPath, outputPath, fps, width, height, totalFrames,
///        params, ffmpegExe (String), audioSourcePath (String),
///        targetWidth (int), targetHeight (int)]
Future<void> _saveVideoIsolateEntry(List<dynamic> args) async {
  final SendPort mainPort = args[0] as SendPort;
  final String videoPath = args[1] as String;
  final String outputPath = args[2] as String;
  final double fps = args[3] as double;
  final int width = args[4] as int;
  final int height = args[5] as int;
  final int totalFrames = args[6] as int;
  final Map<String, dynamic> params = Map<String, dynamic>.from(args[7] as Map);
  final String ffmpegExe = args[8] as String;
  final String audioSourcePath = args[9] as String;
  final int targetWidth = args.length > 10
      ? (args[10] as int? ?? width)
      : width;
  final int targetHeight = args.length > 11
      ? (args[11] as int? ?? height)
      : height;
  final bool needsResize = targetWidth != width || targetHeight != height;

  final vc = cv.VideoCapture.fromFile(videoPath);
  if (!vc.isOpened) {
    mainPort.send({
      'type': 'error',
      'message': 'Cannot open video: $videoPath',
    });
    vc.dispose();
    return;
  }

  Process? ffProcess;
  try {
    ffProcess = await Process.start(ffmpegExe, [
      '-y',
      '-f',
      'rawvideo',
      '-pix_fmt',
      'bgr24',
      '-s',
      '${targetWidth}x$targetHeight',
      '-r',
      fps.toStringAsFixed(6),
      '-i',
      'pipe:0',
      '-i',
      audioSourcePath,
      '-map',
      '0:v:0',
      '-map',
      '1:a:0?',
      '-c:v',
      'libx264',
      '-preset',
      'fast',
      '-crf',
      '23',
      '-c:a',
      'aac',
      '-shortest',
      outputPath,
    ]);

    // Collect stderr so we can report it on failure, and to prevent ffmpeg
    // from blocking when the stderr pipe buffer fills up (which would deadlock
    // the stdin write loop below).
    final stderrBuf = StringBuffer();
    final stderrDone = ffProcess.stderr
        .transform(const SystemEncoding().decoder)
        .listen((s) => stderrBuf.write(s))
        .asFuture<void>()
        .catchError((_) {});

    // Flush interval: keep ~150 MB in the IOSink buffer at most.
    // 4K BGR24 = ~25 MB/frame → flush every 6 frames.
    // 2K BGR24 = ~6 MB/frame  → flush every 25 frames.
    final frameSizeBytes = targetWidth * targetHeight * 3;
    final flushInterval = ((150 * 1024 * 1024) / frameSizeBytes).floor().clamp(
      1,
      60,
    );

    int written = 0;
    while (true) {
      final (ok, frame) = await vc.readAsync();
      if (!ok || frame.width == 0 || frame.height == 0) {
        frame.dispose();
        break;
      }
      final corrected = await _applyExportCorrections(frame, params);
      cv.Mat output = corrected;
      if (needsResize) {
        output = await cv.resizeAsync(corrected, (targetWidth, targetHeight));
        corrected.dispose();
      }
      // Copy raw bytes to Dart heap BEFORE disposing the Mat so the pipe
      // write never touches freed native memory (use-after-free crash fix).
      final frameBytes = Uint8List.fromList(output.data);
      frame.dispose();
      output.dispose();
      ffProcess.stdin.add(frameBytes);

      written++;
      if (written % flushInterval == 0) {
        // Adaptive flush: drain ~150 MB at a time regardless of resolution.
        await ffProcess.stdin.flush();
        mainPort.send({
          'type': 'progress',
          'written': written,
          'total': totalFrames,
        });
      }
    }

    await ffProcess.stdin.flush();
    await ffProcess.stdin.close();
    final exitCode = await ffProcess.exitCode;
    await stderrDone; // ensure stderr buffer is fully flushed
    vc.dispose();

    if (exitCode == 0) {
      mainPort.send({
        'type': 'done',
        'success': true,
        'hasAudio': true,
        'written': written,
      });
      return;
    }

    mainPort.send({
      'type': 'error',
      'message':
          'ffmpeg exited with code $exitCode: ${stderrBuf.toString().trim()}',
    });
    return;
  } catch (e) {
    debugPrint('ffmpeg pipe exception: $e');
    ffProcess?.stdin.close().catchError((_) {});
    ffProcess?.kill();
    vc.dispose();
    mainPort.send({'type': 'error', 'message': 'ffmpeg pipe exception: $e'});
  }
}

/// Full-quality corrections for export (no realtime caps, includes saturation
/// HSV pass and full blue-ocean masking).
Future<cv.Mat> _applyExportCorrections(
  cv.Mat inputFrame,
  Map<String, dynamic> params,
) async {
  cv.Mat working = inputFrame;

  // Particle reduction
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

  // Auto underwater correction with optional local mask
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

  // Green water correction
  final greenWaterAutoCorrection =
      params['greenWaterAutoCorrection'] as bool? ?? false;
  if (greenWaterAutoCorrection) {
    final greenWaterStrength = params['greenWaterStrength'] as double? ?? 0.55;
    final bgr = await cv.splitAsync(working);
    final b = bgr[0];
    final g = bgr[1];
    final r = bgr[2];

    final bMean = b.mean().val1;
    final gMean = g.mean().val1;
    final rMean = r.mean().val1;
    final rgAvg = (rMean + bMean) / 2.0;
    final greenBias = ((gMean - rgAvg) / math.max(gMean, 1.0)).clamp(0.0, 1.0);
    final mix = (greenWaterStrength * (0.35 + 0.65 * greenBias)).clamp(
      0.0,
      1.0,
    );

    final greenReduce = (1.0 - mix * 0.24).clamp(0.76, 1.0);
    final redBoost = (1.0 + mix * 0.20).clamp(1.0, 1.28);
    final blueBoost = (1.0 + mix * 0.14).clamp(1.0, 1.20);

    final bAdj = await cv.convertScaleAbsAsync(b, alpha: blueBoost);
    final gAdj = await cv.convertScaleAbsAsync(g, alpha: greenReduce);
    final rAdj = await cv.convertScaleAbsAsync(r, alpha: redBoost);
    final magentaBalanced = await cv.mergeAsync(
      cv.VecMat.fromList([bAdj, gAdj, rAdj]),
    );

    b.dispose();
    g.dispose();
    r.dispose();
    bAdj.dispose();
    gAdj.dispose();
    rAdj.dispose();
    if (!identical(working, inputFrame)) working.dispose();
    working = magentaBalanced;
  }

  // Contrast & brightness – full values (no realtime cap)
  final contrast = params['contrast'] as double? ?? 1.2;
  final brightness = params['brightness'] as double? ?? 6.0;
  final saturation = params['saturation'] as double? ?? 1.12;

  final leveled = await cv.convertScaleAbsAsync(
    working,
    alpha: contrast,
    beta: brightness,
  );
  if (!identical(working, inputFrame)) working.dispose();
  working = leveled;

  // Saturation (HSV round-trip, skipped in realtime mode)
  if ((saturation - 1.0).abs() > 0.01) {
    final hsv = await cv.cvtColorAsync(working, cv.COLOR_BGR2HSV);
    final hsvChannels = await cv.splitAsync(hsv);
    final hCh = hsvChannels[0];
    final sCh = hsvChannels[1];
    final vCh = hsvChannels[2];
    final satAdjusted = await cv.convertScaleAbsAsync(sCh, alpha: saturation);
    final hsvMerged = await cv.mergeAsync(
      cv.VecMat.fromList([hCh, satAdjusted, vCh]),
    );
    final saturatedBgr = await cv.cvtColorAsync(hsvMerged, cv.COLOR_HSV2BGR);
    satAdjusted.dispose();
    hCh.dispose();
    sCh.dispose();
    vCh.dispose();
    hsvMerged.dispose();
    hsv.dispose();
    working.dispose();
    working = saturatedBgr;
  }

  // Blue ocean tone – full HSV-masked path
  final blueOceanTone = params['blueOceanTone'] as double? ?? 1.12;
  if ((blueOceanTone - 1.0).abs() > 0.01) {
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
    final blueMask = await cv.inRangeAsync(hsvForBlue, lowerBlue, upperBlue);
    final invBlueMask = await cv.bitwiseNOTAsync(blueMask);

    final bgrChannels = await cv.splitAsync(working);
    final b = bgrChannels[0];
    final g = bgrChannels[1];
    final r = bgrChannels[2];

    final bBoosted = await cv.convertScaleAbsAsync(b, alpha: blueOceanTone);
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
    b.dispose();
    g.dispose();
    r.dispose();
    working.dispose();
    working = blued;
  }

  // Color temperature tint
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
