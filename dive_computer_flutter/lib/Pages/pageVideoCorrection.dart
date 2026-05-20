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
import 'package:dive_computer_flutter/objectSelection.dart';
import 'package:extended_text/extended_text.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:dartcv4/dartcv.dart' as cv;
import 'package:desktop_drop/desktop_drop.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

enum _ToastType { success, info, warning, error }

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
  String? _lastSavedPath;
  String? _openedSrcPath;
  String? _openedImagePath;
  final vc = cv.VideoCapture.empty();
  final vw = cv.VideoWriter.empty();
  final mk.Player _audioPlayer = mk.Player();
  cv.Mat? _sourceImageMat;

  ui.Image? _currentFrame;
  bool _isPlaying = false;
  bool _isPaused = false;
  bool _isSaving = false;
  String _exportQuality = 'Original'; // 'Original', 'HD', 'FullHD', '2K', '4K'
  bool _isFullscreen = false;
  bool _processingFrame = false;
  int _playbackSession = 0;
  final FocusNode _fullscreenFocusNode = FocusNode();
  final TransformationController _imageTransformController =
      TransformationController();
  double _imageScale = 1.0;

  static const double _imageMinScale = 1.0;
  static const double _imageMaxScale = 8.0;
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
  int? _pendingSeekTargetFrame;
  bool _resumeAfterSeekInteraction = false;
  int _totalFrames = 0;
  bool _seekingSlider = false;
  double _saveProgress = 0;
  cv.Mat?
  _cachedRawPreviewFrame; // raw resized frame before corrections, for fast re-apply
  int? _cachedRawPreviewFrameNum;
  String _statusText = 'Waiting...';
  final List<String> _playlistPaths = [];
  int _playlistIndex = -1;

  bool _isAnalysing = false;
  bool _isDragOver = false;
  String? _ffmpegExeForOpen;
  bool _ffmpegCheckingForOpen = false;
  bool _vcppCheckedForOpen = false;
  bool _vcppCheckingForOpen = false;
  String? _transcodedTempPath; // ffmpeg 트랜스코딩 임시 파일

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
  OverlayEntry? _toastOverlayEntry;
  Timer? _toastTimer;
  final TextEditingController _presetNameController = TextEditingController();
  final Map<String, Map<String, dynamic>> _savedCorrectionPresets = {};
  String? _selectedPresetName;

  // Object detection and selection state
  bool _objectSelectionEnabled = false;

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
    _blueOceanTone = APref.getData(AprefKey.VC_BLUE_OCEAN_TONE);
    _particleReduction = APref.getData(AprefKey.VC_PARTICLE_REDUCTION);
    _particleReductionStrength = APref.getData(
      AprefKey.VC_PARTICLE_REDUCTION_STRENGTH,
    );
    _previewMatchMode = APref.getData(AprefKey.VC_PREVIEW_MATCH_MODE);
    _audioVolume = APref.getData(AprefKey.VC_AUDIO_VOLUME);
    _loadNamedCorrectionPresets();
  }

  void _loadNamedCorrectionPresets() {
    final dynamic raw = APref.getData(
      AprefKey.VC_CORRECTION_PRESETS,
      defaultValue: const <String, dynamic>{},
    );
    _savedCorrectionPresets.clear();

    if (raw is Map) {
      for (final entry in raw.entries) {
        final key = entry.key.toString().trim();
        final value = entry.value;
        if (key.isEmpty || value is! Map) continue;
        _savedCorrectionPresets[key] = Map<String, dynamic>.from(value);
      }
    }

    final dynamic lastPresetRaw = APref.getData(
      AprefKey.VC_LAST_PRESET_NAME,
      defaultValue: '',
    );
    final lastPreset = lastPresetRaw?.toString().trim() ?? '';
    if (lastPreset.isNotEmpty &&
        _savedCorrectionPresets.containsKey(lastPreset)) {
      _selectedPresetName = lastPreset;
      _presetNameController.text = lastPreset;
      return;
    }

    if (_savedCorrectionPresets.isNotEmpty) {
      final sortedNames = _savedCorrectionPresets.keys.toList()..sort();
      _selectedPresetName = sortedNames.first;
      _presetNameController.text = _selectedPresetName!;
    }
  }

  Map<String, dynamic> _currentCorrectionSettingsSnapshot() {
    return <String, dynamic>{
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
      'particleReduction': _particleReduction,
      'particleReductionStrength': _particleReductionStrength,
      'previewMatchMode': _previewMatchMode,
      'audioVolume': _audioVolume,
    };
  }

  bool _asBool(dynamic value, bool fallback) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    return fallback;
  }

  double _asDouble(dynamic value, double fallback) {
    if (value is num) return value.toDouble();
    return fallback;
  }

  void _applyCorrectionSettingsMap(Map<String, dynamic> settings) {
    _autoCorrection = _asBool(settings['autoCorrection'], _autoCorrection);
    _autoStrength = _asDouble(settings['autoStrength'], _autoStrength);
    _contrast = _asDouble(settings['contrast'], _contrast);
    _brightness = _asDouble(settings['brightness'], _brightness);
    _saturation = _asDouble(settings['saturation'], _saturation);
    _temperature = _asDouble(settings['temperature'], _temperature);
    _redRecovery = _asDouble(settings['redRecovery'], _redRecovery);
    _greenWaterAutoCorrection = _asBool(
      settings['greenWaterAutoCorrection'],
      _greenWaterAutoCorrection,
    );
    _greenWaterStrength = _asDouble(
      settings['greenWaterStrength'],
      _greenWaterStrength,
    );
    _blueOceanTone = _asDouble(settings['blueOceanTone'], _blueOceanTone);
    _particleReduction = _asBool(
      settings['particleReduction'],
      _particleReduction,
    );
    _particleReductionStrength = _asDouble(
      settings['particleReductionStrength'],
      _particleReductionStrength,
    );
    _previewMatchMode = _asBool(
      settings['previewMatchMode'],
      _previewMatchMode,
    );
    _audioVolume = _asDouble(
      settings['audioVolume'],
      _audioVolume,
    ).clamp(0.0, 1.0);
  }

  Future<void> _saveNamedCorrectionPreset(String rawName) async {
    final name = rawName.trim();
    if (name.isEmpty) {
      if (!mounted) return;
      _showCenterToast('Please enter a preset name.', type: _ToastType.warning);
      return;
    }

    _savedCorrectionPresets[name] = _currentCorrectionSettingsSnapshot();
    _selectedPresetName = name;
    _presetNameController.text = name;

    await APref.setData(
      AprefKey.VC_CORRECTION_PRESETS,
      _savedCorrectionPresets,
    );
    await APref.setData(AprefKey.VC_LAST_PRESET_NAME, name);
    await _saveSettings(showFeedback: false);

    if (!mounted) return;
    setState(() {});
    _showCenterToast('Preset saved: $name', type: _ToastType.success);
  }

  Future<void> _loadNamedCorrectionPreset(String name) async {
    final preset = _savedCorrectionPresets[name];
    if (preset == null) {
      if (!mounted) return;
      _showCenterToast('Preset not found.', type: _ToastType.warning);
      return;
    }

    if (!mounted) return;
    setState(() {
      _selectedPresetName = name;
      _presetNameController.text = name;
      _applyCorrectionSettingsMap(preset);
    });

    _pushRealtimeParamsToIsolate();
    if (_audioEnabled) {
      unawaited(_audioPlayer.setVolume(_audioVolume * 100.0));
    }
    await APref.setData(AprefKey.VC_LAST_PRESET_NAME, name);
    await _refreshPreviewFrame();

    if (!mounted) return;
    _showCenterToast('Preset loaded: $name', type: _ToastType.info);
  }

  void _showCenterToast(
    String message, {
    Duration duration = const Duration(seconds: 2),
    _ToastType type = _ToastType.info,
  }) {
    if (!mounted) return;

    _toastTimer?.cancel();
    _toastOverlayEntry?.remove();
    _toastOverlayEntry = null;

    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    final entry = OverlayEntry(
      builder: (context) {
        final screenSize = MediaQuery.sizeOf(context);
        final toastMaxWidth = math.min(430.0, screenSize.width - 32);

        Color backgroundColor;
        Color borderColor;
        Color iconColor;
        IconData iconData;

        switch (type) {
          case _ToastType.success:
            backgroundColor = const Color(0xFF0F2A1F).withValues(alpha: 0.93);
            borderColor = const Color(0xFF4CC38A);
            iconColor = const Color(0xFF6FF2B4);
            iconData = Icons.check_circle_rounded;
            break;
          case _ToastType.warning:
            backgroundColor = const Color(0xFF2B220C).withValues(alpha: 0.93);
            borderColor = const Color(0xFFFFC857);
            iconColor = const Color(0xFFFFD57A);
            iconData = Icons.warning_amber_rounded;
            break;
          case _ToastType.error:
            backgroundColor = const Color(0xFF351619).withValues(alpha: 0.94);
            borderColor = const Color(0xFFFF7A86);
            iconColor = const Color(0xFFFF9BA4);
            iconData = Icons.error_rounded;
            break;
          case _ToastType.info:
            backgroundColor = const Color(0xFF0D1A2A).withValues(alpha: 0.92);
            borderColor = const Color(0xFF6CA6FF);
            iconColor = const Color(0xFF8EBBFF);
            iconData = Icons.info_rounded;
            break;
        }

        return IgnorePointer(
          ignoring: true,
          child: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    constraints: BoxConstraints(maxWidth: toastMaxWidth),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 11,
                    ),
                    decoration: BoxDecoration(
                      color: backgroundColor,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: borderColor.withValues(alpha: 0.95),
                        width: 1.2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.45),
                          blurRadius: 18,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(iconData, color: iconColor, size: 18),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            message,
                            textAlign: TextAlign.left,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              height: 1.25,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    overlay.insert(entry);
    _toastOverlayEntry = entry;
    _toastTimer = Timer(duration, () {
      if (identical(_toastOverlayEntry, entry)) {
        _toastOverlayEntry = null;
      }
      entry.remove();
    });
  }

  void _applyDefaultCorrectionSettings() {
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
    _blueOceanTone = 1.12;
    _particleReduction = false;
    _particleReductionStrength = 0.55;
  }

  Future<void> _showSavePresetDialog() async {
    final nameController = TextEditingController(
      text: _selectedPresetName ?? 'Default',
    );
    try {
      final enteredName = await showDialog<String>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('Save preset'),
            content: TextField(
              controller: nameController,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (value) {
                Navigator.of(dialogContext).pop(value);
              },
              decoration: const InputDecoration(
                labelText: 'Preset name',
                border: OutlineInputBorder(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(nameController.text),
                child: const Text('Save'),
              ),
            ],
          );
        },
      );

      if (!mounted || enteredName == null) return;
      await _saveNamedCorrectionPreset(enteredName);
    } finally {
      nameController.dispose();
    }
  }

  Future<void> _showLoadPresetDialog() async {
    if (_savedCorrectionPresets.isEmpty) {
      if (!mounted) return;
      _showCenterToast('No saved presets.', type: _ToastType.warning);
      return;
    }

    final names = _savedCorrectionPresets.keys.toList()..sort();
    final selectedName = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Load preset'),
          content: SizedBox(
            width: 360,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: names.length,
              itemBuilder: (context, index) {
                final name = names[index];
                return ListTile(
                  dense: true,
                  title: Text(name),
                  selected: name == _selectedPresetName,
                  onTap: () => Navigator.of(dialogContext).pop(name),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );

    if (!mounted || selectedName == null) return;
    await _loadNamedCorrectionPreset(selectedName);
  }

  Future<void> _confirmDeleteCurrentPreset() async {
    if (_savedCorrectionPresets.isEmpty) return;
    final targetName = _selectedPresetName;
    if (targetName == null ||
        !_savedCorrectionPresets.containsKey(targetName)) {
      if (!mounted) return;
      _showCenterToast('No current preset selected.', type: _ToastType.warning);
      return;
    }

    final confirmDelete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Delete preset'),
          content: Text('Delete current preset "$targetName"?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (!mounted || confirmDelete != true) return;

    _savedCorrectionPresets.remove(targetName);
    if (_savedCorrectionPresets.isEmpty) {
      _selectedPresetName = null;
      _presetNameController.clear();
      await APref.setData(AprefKey.VC_LAST_PRESET_NAME, '');
    } else {
      final names = _savedCorrectionPresets.keys.toList()..sort();
      _selectedPresetName = names.first;
      _presetNameController.text = _selectedPresetName!;
      await APref.setData(AprefKey.VC_LAST_PRESET_NAME, _selectedPresetName!);
    }

    await APref.setData(
      AprefKey.VC_CORRECTION_PRESETS,
      _savedCorrectionPresets,
    );

    if (!mounted) return;
    setState(() {});
    _showCenterToast('Preset deleted: $targetName', type: _ToastType.info);
  }

  Future<void> _confirmResetToDefault() async {
    final confirmReset = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Reset settings'),
          content: const Text('Reset correction settings to default values?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              // onPressed: () => Navigator.of(dialogContext).pop(true),
              onPressed: () {
                _selectedPresetName = 'Default';
                _presetNameController.text = _selectedPresetName!;
                Navigator.of(dialogContext).pop(true);
              },
              child: const Text('Reset'),
            ),
          ],
        );
      },
    );

    if (!mounted || confirmReset != true) return;

    setState(() {
      _applyDefaultCorrectionSettings();
    });
    _pushRealtimeParamsToIsolate();
    await _refreshPreviewFrame();
    if (!mounted) return;
    _showCenterToast('Reset to default settings.', type: _ToastType.info);
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

  void _disposeSourceImage() {
    _sourceImageMat?.dispose();
    _sourceImageMat = null;
  }

  void _resetImageTransform() {
    _imageTransformController.value = Matrix4.identity();
    _imageScale = 1.0;
  }

  double _currentImageScale() {
    final m = _imageTransformController.value.storage;
    return m[0];
  }

  void _handleImagePointerSignal(
    PointerSignalEvent event,
    BuildContext localContext,
  ) {
    if (!_hasImage || event is! PointerScrollEvent) return;

    final deltaY = event.scrollDelta.dy;
    if (deltaY == 0) return;

    final currentScale = _currentImageScale();
    final step = deltaY > 0 ? 0.9 : 1.1;
    final nextScale = (currentScale * step).clamp(
      _imageMinScale,
      _imageMaxScale,
    );
    if ((nextScale - currentScale).abs() < 0.0001) return;

    if (nextScale <= _imageMinScale + 0.0001) {
      setState(_resetImageTransform);
      return;
    }

    final scaleChange = nextScale / currentScale;
    final renderObject = localContext.findRenderObject();
    if (renderObject is! RenderBox) return;

    final focal = renderObject.globalToLocal(event.position);
    final nextMatrix = _imageTransformController.value.clone()
      ..translate(focal.dx, focal.dy)
      ..scale(scaleChange)
      ..translate(-focal.dx, -focal.dy);

    setState(() {
      _imageTransformController.value = nextMatrix;
      _imageScale = nextScale;
    });
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

  /// Deletes temporary input copies if they were created in cache (input_*).
  Future<void> _deleteTempInputIfNeeded() async {
    final paths = <String?>[_openedSrcPath, _openedImagePath];
    for (final prev in paths) {
      if (prev == null) continue;
      final name = p.basename(prev);
      if (!name.startsWith('input_')) continue;
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
    // ffmpeg 트랜스코딩 임시 파일 삭제
    if (_transcodedTempPath != null) {
      try {
        final f = File(_transcodedTempPath!);
        if (await f.exists()) {
          await f.delete();
          debugPrint('Deleted transcoded temp: $_transcodedTempPath');
        }
      } catch (e) {
        debugPrint('Failed to delete transcoded temp: $e');
      }
      _transcodedTempPath = null;
    }
    _openedSrcPath = null;
    _openedImagePath = null;
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

  Future<bool> _ensureFfmpegForOpen() async {
    if (!Platform.isWindows) {
      return false;
    }
    if (_ffmpegExeForOpen != null) {
      return true;
    }
    if (_ffmpegCheckingForOpen) {
      return false;
    }

    _ffmpegCheckingForOpen = true;
    try {
      final exe = await _quickFindFfmpeg();
      if (exe != null) {
        _ffmpegExeForOpen = exe;
        debugPrint('[ffmpeg] Ready for video open: $exe');
        return true;
      }

      debugPrint(
        '[ffmpeg] Not available for video open. Falling back to non-ffmpeg backends.',
      );
      return false;
    } finally {
      _ffmpegCheckingForOpen = false;
    }
  }

  Future<void> _ensureVcppRuntimeForOpen() async {
    if (!Platform.isWindows || _vcppCheckedForOpen || _vcppCheckingForOpen) {
      return;
    }

    _vcppCheckingForOpen = true;
    try {
      final hasRuntime = await _isVcppRuntimeInstalled();
      if (hasRuntime) {
        debugPrint('[vcpp] VC++ runtime already installed.');
        return;
      }

      debugPrint('[vcpp] VC++ runtime not found. Attempting auto-install...');
      final installed = await _installLatestVcppRuntime();
      if (!installed) {
        debugPrint('[vcpp] Auto-install did not complete.');
        return;
      }

      final verified = await _isVcppRuntimeInstalled();
      if (verified) {
        debugPrint('[vcpp] VC++ runtime installation verified.');
      } else {
        debugPrint('[vcpp] Installer ran but runtime could not be verified.');
      }
    } finally {
      _vcppCheckingForOpen = false;
      _vcppCheckedForOpen = true;
    }
  }

  Future<bool> _isVcppRuntimeInstalled() async {
    if (!Platform.isWindows) {
      return true;
    }

    const runtimeRegPath =
        r'HKLM\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64';
    try {
      final query = await Process.run('reg', [
        'query',
        runtimeRegPath,
        '/v',
        'Installed',
      ], runInShell: true);

      if (query.exitCode != 0) {
        return false;
      }

      final out = '${query.stdout}';
      final installed = RegExp(
        r'Installed\s+REG_DWORD\s+0x1',
        caseSensitive: false,
      ).hasMatch(out);
      return installed;
    } catch (e) {
      debugPrint('[vcpp] Registry check failed: $e');
      return false;
    }
  }

  Future<bool> _installLatestVcppRuntime() async {
    if (!Platform.isWindows) {
      return false;
    }

    const vcRedistUrl = 'https://aka.ms/vs/17/release/vc_redist.x64.exe';

    try {
      final supportDir = await getApplicationSupportDirectory();
      final installerDir = Directory(
        p.join(supportDir.path, 'vcpp_runtime_installer'),
      );
      await installerDir.create(recursive: true);

      final installerPath = p.join(installerDir.path, 'vc_redist.x64.exe');

      String psQuote(String value) => value.replaceAll("'", "''");

      final downloadScript =
          "\$ErrorActionPreference='Stop'; "
          "\$ProgressPreference='SilentlyContinue'; "
          "Invoke-WebRequest -Uri '${psQuote(vcRedistUrl)}' -OutFile '${psQuote(installerPath)}';";

      final download = await Process.run('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        downloadScript,
      ], runInShell: true);

      if (download.exitCode != 0 || !File(installerPath).existsSync()) {
        debugPrint('[vcpp] Download failed: ${download.stderr}');
        return false;
      }

      final silentInstall = await Process.run(installerPath, [
        '/install',
        '/quiet',
        '/norestart',
      ], runInShell: true);

      // 0: success, 1638: newer/already installed, 3010: restart required.
      if (silentInstall.exitCode == 0 ||
          silentInstall.exitCode == 1638 ||
          silentInstall.exitCode == 3010) {
        return true;
      }

      // Fallback to elevated interactive install when silent install is blocked.
      final elevateScript =
          "\$p = Start-Process -FilePath '${psQuote(installerPath)}' "
          "-ArgumentList '/install','/norestart' -Verb RunAs -Wait -PassThru; "
          "exit \$p.ExitCode;";

      final elevatedInstall = await Process.run('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        elevateScript,
      ], runInShell: true);

      if (elevatedInstall.exitCode == 0 ||
          elevatedInstall.exitCode == 1638 ||
          elevatedInstall.exitCode == 3010) {
        return true;
      }

      debugPrint(
        '[vcpp] Install failed. silent=${silentInstall.exitCode}, elevated=${elevatedInstall.exitCode}',
      );
      return false;
    } catch (e) {
      debugPrint('[vcpp] Install exception: $e');
      return false;
    }
  }

  Future<bool> _openVideoCapture(String path) async {
    await _deleteTempInputIfNeeded();
    vc.release();

    final preparedPath = await _prepareOpenPath(path);

    // FFmpeg은 필수 - 반드시 확보해야 함
    final hasFfmpeg = await _ensureFfmpegForOpen();
    if (!hasFfmpeg) {
      debugPrint('[CRITICAL] FFmpeg unavailable - video playback will fail!');
      if (mounted) {
        _showCenterToast(
          'FFmpeg이 설치되지 않았습니다. 인터넷 연결 상태를 확인하고 다시 시도하세요.',
          duration: const Duration(seconds: 5),
          type: _ToastType.error,
        );
      }
    }

    // CAP_FFMPEG (api=1900) 는 dartcv4 에서 native crash 를 유발하므로 절대 사용하지 않음.
    // MSMF / ANY 만 안전하게 시도.
    for (final api in <int>[cv.CAP_MSMF, cv.CAP_ANY]) {
      try {
        debugPrint('[VideoOpen] Trying api=$api on: $preparedPath');
        final opened = vc.open(preparedPath, apiPreference: api);
        if (opened && vc.isOpened) {
          final (testOk, testFrame) = await vc.readAsync();
          debugPrint(
            '[VideoOpen] api=$api frame test: ok=$testOk ${testFrame.width}x${testFrame.height}',
          );
          if (testOk && testFrame.width > 0 && testFrame.height > 0) {
            testFrame.dispose();
            vc.set(cv.CAP_PROP_POS_FRAMES, 0);
            _openedSrcPath = preparedPath;
            debugPrint(
              '[VideoOpen] SUCCESS api=$api backend=${vc.getBackendName()}',
            );
            return true;
          }
          testFrame.dispose();
          debugPrint('[VideoOpen] api=$api opened but frame read failed');
        } else {
          debugPrint('[VideoOpen] api=$api open returned: $opened');
        }
      } catch (e) {
        debugPrint('[VideoOpen] api=$api exception: $e');
      }
      vc.release();
    }

    // 직접 열기 실패 → ffmpeg.exe 로 MJPEG AVI 트랜스코딩 후 재시도
    if (_ffmpegExeForOpen != null) {
      debugPrint('[VideoOpen] Direct open failed. Transcoding via ffmpeg...');
      final transcoded = await _transcodeToMjpegAvi(
        preparedPath,
        _ffmpegExeForOpen!,
      );
      if (transcoded != null) {
        debugPrint('[VideoOpen] Transcoded to: $transcoded');
        try {
          final opened = vc.open(transcoded, apiPreference: cv.CAP_ANY);
          if (opened && vc.isOpened) {
            final (testOk, testFrame) = await vc.readAsync();
            debugPrint(
              '[VideoOpen] Transcoded frame test: ok=$testOk ${testFrame.width}x${testFrame.height}',
            );
            if (testOk && testFrame.width > 0 && testFrame.height > 0) {
              testFrame.dispose();
              vc.set(cv.CAP_PROP_POS_FRAMES, 0);
              _openedSrcPath = transcoded;
              _transcodedTempPath = transcoded;
              debugPrint('[VideoOpen] SUCCESS via ffmpeg transcode');
              return true;
            }
            testFrame.dispose();
          }
        } catch (e) {
          debugPrint('[VideoOpen] Transcoded open exception: $e');
        }
        vc.release();
        try {
          File(transcoded).deleteSync();
        } catch (_) {}
      }
    }

    _openedSrcPath = null;
    debugPrint('[VideoOpen] FAILED - all methods exhausted');
    return false;
  }

  /// ffmpeg.exe 로 H.264 등 OpenCV 직접 열기 불가 영상을 MJPEG AVI 로 변환.
  /// 성공 시 임시 파일 경로 반환, 실패 시 null.
  Future<String?> _transcodeToMjpegAvi(String srcPath, String ffmpegExe) async {
    try {
      final tmpDir = await getTemporaryDirectory();
      final outPath = p.join(
        tmpDir.path,
        'dcs_transcode_${DateTime.now().millisecondsSinceEpoch}.avi',
      );
      debugPrint('[Transcode] $srcPath → $outPath');
      final result = await Process.run(ffmpegExe, [
        '-y',
        '-i', srcPath,
        '-c:v', 'mjpeg',
        '-q:v', '3',
        '-an', // 오디오 제거 (재생은 media_kit 이 별도 처리)
        outPath,
      ]);
      debugPrint('[Transcode] exit=${result.exitCode}');
      if (result.exitCode != 0) {
        debugPrint('[Transcode] stderr: ${result.stderr}');
        return null;
      }
      if (!File(outPath).existsSync()) return null;
      return outPath;
    } catch (e) {
      debugPrint('[Transcode] exception: $e');
      return null;
    }
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

  bool _isSupportedImagePath(String path) {
    final ext = p.extension(path).toLowerCase();
    const supported = {'.jpg', '.jpeg', '.png', '.bmp', '.webp'};
    return supported.contains(ext);
  }

  bool _isSupportedMediaPath(String path) {
    return _isSupportedVideoPath(path) || _isSupportedImagePath(path);
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

  Future<List<String>> _collectMediaFilesFromFolder(String folderPath) async {
    final dir = Directory(folderPath);
    if (!await dir.exists()) return [];

    final files = <String>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      if (_isSupportedMediaPath(entity.path)) {
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
    _disposeSourceImage();
    _openedImagePath = null;
    _resetImageTransform();
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

    if (Platform.isWindows && !_vcppCheckedForOpen) {
      if (mounted) {
        setState(() {
          _statusText = 'Checking VC++ runtime...';
        });
      }
      await Future.delayed(Duration.zero);
      await _ensureVcppRuntimeForOpen();
      if (!mounted) {
        return false;
      }
      setState(() {
        _statusText = 'Opening video...';
      });
    }

    if (Platform.isWindows && _ffmpegExeForOpen == null) {
      if (mounted) {
        setState(() {
          _statusText = 'Checking ffmpeg...';
        });
      }
      await Future.delayed(Duration.zero);
      await _ensureFfmpegForOpen();
      if (!mounted) {
        return false;
      }
      setState(() {
        _statusText = 'Opening video...';
      });
    }

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
      // Cache is now primed; _refreshPreviewFrame will reuse it without seek/read.
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

  Future<bool> _openImagePath(String path) async {
    await _stopVideo(refreshPreview: false);
    if (!mounted) return false;

    vc.release();
    await _stopAudioPlayback();
    await _deleteTempInputIfNeeded();
    _disposeSourceImage();
    _openedSrcPath = null;
    _resetImageTransform();

    setState(() {
      src = path;
      _setCurrentFrame(null);
      _isPaused = false;
      _isPlaying = false;
      _isAnalysing = true;
      _statusText = 'Opening image...';
    });

    await Future.delayed(Duration.zero);
    final preparedPath = await _prepareOpenPath(path);
    final imageMat = await cv.imreadAsync(preparedPath);

    if (!mounted) {
      imageMat.dispose();
      return false;
    }

    if (imageMat.isEmpty) {
      imageMat.dispose();
      setState(() {
        width = -1;
        height = -1;
        fps = -1;
        _totalFrames = 0;
        _isAnalysing = false;
        _statusText = 'Failed to open selected image';
      });
      return false;
    }

    _sourceImageMat = imageMat;
    _openedImagePath = preparedPath;
    setState(() {
      width = imageMat.width;
      height = imageMat.height;
      fps = -1;
      backend = 'image';
      _totalFrames = 1;
      _lastReceivedFrameNum = 0;
      _lastReceivedPosMs = 0;
      _isAnalysing = true;
      _statusText = 'Analysing image...';
    });

    await _refreshPreviewFrame();
    return true;
  }

  Future<bool> _openPlaylistIndex(int index, {bool autoplay = false}) async {
    if (index < 0 || index >= _playlistPaths.length) return false;
    final path = _playlistPaths[index];
    final opened = _isSupportedImagePath(path)
        ? await _openImagePath(path)
        : await _openVideoPath(path);
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
      dialogTitle: 'Select media folder',
      lockParentWindow: true,
    );
    if (folderPath == null) {
      return;
    }

    final files = await _collectMediaFilesFromFolder(folderPath);
    if (files.isEmpty) {
      if (!mounted) return;
      setState(() {
        _playlistPaths..clear();
        _playlistIndex = -1;
        _statusText = 'No supported media files found in selected folder';
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
          _statusText = 'No playable/openable files in selected folder';
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
  bool get _hasImage =>
      src != null && _sourceImageMat != null && !_sourceImageMat!.isEmpty;
  bool get _hasMedia => _hasVideo || _hasImage;

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

  void _cacheRawPreviewFrame(cv.Mat rawPreview, int frameNum) {
    _cachedRawPreviewFrame?.dispose();
    _cachedRawPreviewFrame = cv.Mat.fromMat(rawPreview, copy: true);
    _cachedRawPreviewFrameNum = frameNum;
  }

  Future<void> _refreshPreviewFrame() async {
    if (_isSaving || _processingFrame) {
      return;
    }

    if (_hasImage) {
      _processingFrame = true;
      try {
        final source = _sourceImageMat;
        if (source == null || source.isEmpty) {
          return;
        }
        final sourceCopy = cv.Mat.fromMat(source, copy: true);
        final corrected = _previewMatchMode
            ? await _applyExportCorrections(
                sourceCopy,
                _buildCorrectionParams(),
              )
            : await _applyCorrections(sourceCopy, realtime: false);
        final image = await _cvMatToImage(corrected);
        if (!identical(corrected, sourceCopy)) {
          sourceCopy.dispose();
        }
        corrected.dispose();

        if (!mounted) {
          image.dispose();
          return;
        }
        setState(() {
          _setCurrentFrame(image);
          _isAnalysing = false;
          _statusText = 'Image ready';
        });
      } finally {
        _processingFrame = false;
      }
      return;
    }

    if (!vc.isOpened || _isPlaying) {
      return;
    }

    _processingFrame = true;
    try {
      cv.Mat? frame;
      cv.Mat? rawPreview;
      var usedCachedRaw = false;

      if (_cachedRawPreviewFrame != null &&
          _cachedRawPreviewFrameNum == _lastReceivedFrameNum &&
          !_cachedRawPreviewFrame!.isEmpty) {
        rawPreview = cv.Mat.fromMat(_cachedRawPreviewFrame!, copy: true);
        usedCachedRaw = true;
      } else {
        vc.set(cv.CAP_PROP_POS_FRAMES, _lastReceivedFrameNum.toDouble());
        final (ok, decoded) = await vc.readAsync();
        if (!ok || decoded.width == 0 || decoded.height == 0) {
          decoded.dispose();
          return;
        }
        frame = decoded;
        rawPreview = await _resizeForPreview(decoded, realtime: true);
        _cacheRawPreviewFrame(rawPreview, _lastReceivedFrameNum);
      }

      if (rawPreview == null) {
        frame?.dispose();
        return;
      }

      final corrected = _previewMatchMode
          ? await _applyExportCorrections(rawPreview, _buildCorrectionParams())
          : await _applyCorrections(rawPreview, realtime: true);
      final image = await _cvMatToImage(corrected);
      if (usedCachedRaw || (frame != null && !identical(rawPreview, frame))) {
        rawPreview.dispose();
      }
      frame?.dispose();
      corrected.dispose();

      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _setCurrentFrame(image);
        _isAnalysing = false;
        _statusText = 'Video ready';
      });
      vc.set(cv.CAP_PROP_POS_FRAMES, _lastReceivedFrameNum.toDouble());
    } finally {
      _processingFrame = false;
    }
  }

  Future<void> _selectVideo() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const [
        'mp4',
        'mov',
        'm4v',
        'avi',
        'mkv',
        'wmv',
        'webm',
        'mpeg',
        'mpg',
        'jpg',
        'jpeg',
        'png',
        'bmp',
        'webp',
      ],
      lockParentWindow: true,
    );
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

  Future<void> _handleDroppedPaths(List<String> droppedPaths) async {
    if (droppedPaths.isEmpty) {
      return;
    }

    final collected = <String>[];
    final seen = <String>{};

    for (final raw in droppedPaths) {
      final path = raw.trim();
      if (path.isEmpty) continue;

      FileSystemEntityType type;
      try {
        type = await FileSystemEntity.type(path, followLinks: true);
      } catch (_) {
        continue;
      }

      if (type == FileSystemEntityType.directory) {
        final files = await _collectMediaFilesFromFolder(path);
        for (final filePath in files) {
          if (seen.add(filePath)) {
            collected.add(filePath);
          }
        }
        continue;
      }

      if (type == FileSystemEntityType.file && _isSupportedMediaPath(path)) {
        if (seen.add(path)) {
          collected.add(path);
        }
      }
    }

    if (collected.isEmpty) {
      if (!mounted) return;
      setState(() {
        _statusText = 'No supported media files in dropped item(s)';
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _playlistPaths
        ..clear()
        ..addAll(collected);
      _playlistIndex = 0;
      _statusText = 'Dropped ${collected.length} media file(s)';
    });

    if (!await _openPlaylistIndex(0)) {
      if (!await _openNextPlaylistFile(autoplay: false)) {
        if (!mounted) return;
        setState(() {
          _statusText = 'Dropped files found, but none were playable';
        });
      }
    }
  }

  Future<void> _saveEditedImage() async {
    if (!_hasImage || src == null || _sourceImageMat == null) {
      setState(() {
        _statusText = 'Select an image first.';
      });
      return;
    }

    setState(() {
      _isSaving = true;
      _statusText = 'Preparing image export...';
    });

    final sourceName = p.basenameWithoutExtension(src!);
    final defaultName =
        'corrected_${sourceName}_${DateTime.now().millisecondsSinceEpoch}.png';
    final requestedPath = await FilePicker.saveFile(
      dialogTitle: 'Save corrected image',
      fileName: defaultName,
      initialDirectory: p.dirname(src!),
      lockParentWindow: true,
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg'],
    );

    if (requestedPath == null) {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _statusText = 'Image export cancelled.';
        });
      }
      return;
    }

    var outputPath = requestedPath;
    final ext = p.extension(requestedPath).toLowerCase();
    if (ext.isEmpty) {
      outputPath = '$requestedPath.png';
    } else if (ext != '.png' && ext != '.jpg' && ext != '.jpeg') {
      outputPath = '$requestedPath.png';
    }

    final safeOutputPath = await _prepareOutputPath(outputPath);

    try {
      final sourceCopy = cv.Mat.fromMat(_sourceImageMat!, copy: true);
      final corrected = await _applyExportCorrections(
        sourceCopy,
        _buildCorrectionParams(),
      );
      if (!identical(corrected, sourceCopy)) {
        sourceCopy.dispose();
      }
      final ok = await cv.imwriteAsync(safeOutputPath, corrected);
      corrected.dispose();

      if (!mounted) return;
      if (!ok) {
        setState(() {
          _isSaving = false;
          _statusText = 'Failed to save corrected image.';
        });
        return;
      }

      if (safeOutputPath != outputPath) {
        await File(safeOutputPath).copy(outputPath);
        await File(safeOutputPath).delete();
      }

      setState(() {
        _isSaving = false;
        _lastSavedPath = outputPath;
        dst = outputPath;
        _statusText = 'Image saved: $outputPath';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _statusText = 'Image export failed: $e';
      });
    }
  }

  Future<void> _saveEditedCurrentMedia() async {
    if (_hasVideo) {
      await _saveEditedVideo();
      return;
    }
    if (_hasImage) {
      await _saveEditedImage();
      return;
    }
    setState(() {
      _statusText = 'Select media first.';
    });
  }

  Future<void> _seekTo(int frameNum) async {
    if (!_hasVideo || _isSaving) return;
    final target = frameNum.clamp(0, math.max(0, _totalFrames - 1)).toInt();
    _seekingSlider = true;
    _pendingSeekTargetFrame = target;
    _lastReceivedFrameNum = target;
    final seekPosMs = _frameToDuration(target).inMilliseconds;
    _lastReceivedPosMs = seekPosMs;
    unawaited(_seekAudioToMs(seekPosMs));

    if (_isPlaying) {
      _seekingSlider = false;
      if (_isolateSendPort != null) {
        _isolateSendPort!.send({'cmd': 'seek', 'frame': target});
        if (mounted) {
          setState(() {
            _statusText = 'Seeking...';
          });
        }
        return;
      }

      // Fallback path when isolate channel is not ready.
      await _killPlaybackIsolate();
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _isPaused = true;
          _statusText = 'Seeking...';
        });
      }
      await _playVideo();
      return;
    }

    // When paused/stopped, render a lightweight seek preview to avoid UI stalls.
    vc.set(cv.CAP_PROP_POS_FRAMES, target.toDouble());
    if (_processingFrame) {
      _seekingSlider = false;
      _pendingSeekTargetFrame = null;
      return;
    }

    _processingFrame = true;
    var shouldRefinePreview = false;
    try {
      final (ok, frame) = await vc.readAsync();
      if (ok && frame.width > 0) {
        final preview = await _resizeForPreview(frame, realtime: true);
        _cacheRawPreviewFrame(preview, target);
        // Show a fast raw frame first, then refine with corrections asynchronously.
        final image = await _cvMatToImage(preview);
        if (!identical(preview, frame)) {
          preview.dispose();
        }
        frame.dispose();
        if (mounted) {
          setState(() => _setCurrentFrame(image));
          shouldRefinePreview = true;
        } else {
          image.dispose();
        }
      } else {
        frame.dispose();
      }
    } finally {
      _processingFrame = false;
      vc.set(cv.CAP_PROP_POS_FRAMES, _lastReceivedFrameNum.toDouble());
      _seekingSlider = false;
      _pendingSeekTargetFrame = null;
    }

    if (shouldRefinePreview && !_isPlaying && mounted && !_isSaving) {
      unawaited(_refreshPreviewFrame());
    }

    // If the isolate is alive (paused), sync it so resume continues from here.
    _isolateSendPort?.send({'cmd': 'seek', 'frame': target});
  }

  Future<void> _beginSeekInteraction() async {
    if (!_hasVideo || _isSaving) return;
    _seekingSlider = true;
    _pendingSeekTargetFrame = null;
    if (_isPlaying) {
      _resumeAfterSeekInteraction = true;
      await _pauseVideo();
    } else {
      _resumeAfterSeekInteraction = false;
    }
  }

  Future<void> _endSeekInteraction(double value) async {
    if (!_hasVideo || _isSaving) return;
    final target = (_totalFrames * value).round().clamp(
      0,
      math.max(0, _totalFrames - 1),
    );
    if (_resumeAfterSeekInteraction) {
      // Was playing before drag — skip the heavy frame render and let the
      // fresh playback isolate show the correct frame immediately.
      _resumeAfterSeekInteraction = false;
      _lastReceivedFrameNum = target as int;
      _pendingSeekTargetFrame = target;
      final seekPosMs = _frameToDuration(target).inMilliseconds;
      _lastReceivedPosMs = seekPosMs;
      unawaited(_seekAudioToMs(seekPosMs));
      _isolateSendPort?.send({'cmd': 'seek', 'frame': target});
      _seekingSlider = false;
      if (mounted) setState(() {});
      if (mounted && !_isSaving) await _playVideo();
      return;
    }
    // Was paused/stopped — render a lightweight preview then stay paused.
    await _seekTo(target as int);
    _resumeAfterSeekInteraction = false;
  }

  Future<void> _pauseVideo() async {
    if (!_isPlaying) return;

    // Do NOT increment _playbackSession — the existing listener must stay valid
    // so it can continue to receive 'done'/'error' while paused, and frames
    // after resume without re-attaching.
    if (mounted) {
      setState(() {
        _isPlaying = false;
        _isPaused = true;
        _statusText = 'Paused';
      });
    }
    // Send 'pause' to isolate; keep subscription/port/sendPort alive.
    if (_isolateSendPort != null) {
      _isolateSendPort!.send({'cmd': 'pause'});
    } else {
      await _killPlaybackIsolate();
    }
    try {
      await _audioPlayer.pause();
    } catch (e) {
      debugPrint('Audio pause failed: $e');
    }
  }

  Future<void> _stopVideo({bool refreshPreview = false}) async {
    // Invalidate the cached raw frame so the next _refreshPreviewFrame re-reads.
    _cachedRawPreviewFrame?.dispose();
    _cachedRawPreviewFrame = null;
    _cachedRawPreviewFrameNum = null;
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

  Future<void> _saveSettings({bool showFeedback = true}) async {
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
    await APref.setData(AprefKey.VC_BLUE_OCEAN_TONE, _blueOceanTone);
    await APref.setData(AprefKey.VC_PARTICLE_REDUCTION, _particleReduction);
    await APref.setData(
      AprefKey.VC_PARTICLE_REDUCTION_STRENGTH,
      _particleReductionStrength,
    );
    await APref.setData(AprefKey.VC_PREVIEW_MATCH_MODE, _previewMatchMode);
    await APref.setData(AprefKey.VC_AUDIO_VOLUME, _audioVolume);
    if (mounted && showFeedback) {
      _showCenterToast('Settings saved.', type: _ToastType.success);
    }
  }

  Future<void> _saveCurrentSceneAsPng() async {
    if (_openedSrcPath == null || src == null) {
      if (!mounted) return;
      _showCenterToast('No frame to capture.', type: _ToastType.warning);
      return;
    }
    final wasPlayingBeforeCapture = _isPlaying;
    if (wasPlayingBeforeCapture) {
      await _pauseVideo();
    }
    var waitDialogShown = false;
    try {
      final sourceName = src == null
          ? 'scene'
          : p.basenameWithoutExtension(src!);
      final frameNumber = _lastReceivedFrameNum.clamp(0, 999999999);
      final defaultName =
          '${sourceName}_frame_${frameNumber.toString().padLeft(6, '0')}.png';
      final initialDirectory = src == null ? null : p.dirname(src!);

      final requestedPath = await FilePicker.saveFile(
        dialogTitle: 'Save current scene as PNG',
        fileName: defaultName,
        initialDirectory: initialDirectory,
        lockParentWindow: true,
        type: FileType.custom,
        allowedExtensions: const ['png'],
      );

      if (requestedPath == null) {
        if (!mounted) return;
        setState(() {
          _statusText = 'PNG save cancelled.';
        });
        return;
      }

      final outputPath = p.extension(requestedPath).toLowerCase() == '.png'
          ? requestedPath
          : '$requestedPath.png';

      if (mounted) {
        unawaited(
          showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (context) {
              return const AlertDialog(
                content: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                    SizedBox(width: 14),
                    Text('Saving PNG...'),
                  ],
                ),
              );
            },
          ),
        );
        waitDialogShown = true;
        // Give Flutter one frame so the modal is painted before heavy native work starts.
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }

      setState(() {
        _statusText = 'Rendering original-resolution PNG...';
      });

      final capture = cv.VideoCapture.fromFile(_openedSrcPath!);
      if (!capture.isOpened) {
        capture.dispose();
        if (!mounted) return;
        setState(() {
          _statusText = 'Failed to open source frame for PNG capture.';
        });
        _showCenterToast(
          'Failed to open source video.',
          type: _ToastType.error,
        );
        return;
      }

      capture.set(cv.CAP_PROP_POS_FRAMES, frameNumber.toDouble());
      final (ok, sourceFrame) = await capture.readAsync();
      capture.dispose();
      if (!ok || sourceFrame.width == 0 || sourceFrame.height == 0) {
        sourceFrame.dispose();
        if (!mounted) return;
        setState(() {
          _statusText = 'Failed to read source frame for PNG capture.';
        });
        _showCenterToast(
          'Failed to read source frame.',
          type: _ToastType.error,
        );
        return;
      }

      final corrected = _previewMatchMode
          ? await _applyExportCorrections(sourceFrame, _buildCorrectionParams())
          : await _applyCorrections(sourceFrame, realtime: false);
      final image = await _cvMatToImage(corrected);
      sourceFrame.dispose();
      corrected.dispose();

      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (byteData == null) {
        if (!mounted) return;
        setState(() {
          _statusText = 'Failed to encode current frame as PNG.';
        });
        _showCenterToast(
          'Failed to encode current frame.',
          type: _ToastType.error,
        );
        return;
      }

      final pngBytes = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      await File(outputPath).writeAsBytes(pngBytes, flush: true);

      if (!mounted) return;
      setState(() {
        _lastSavedPath = outputPath;
        _statusText = 'PNG saved: $outputPath';
      });
      _showCenterToast('PNG saved: $outputPath', type: _ToastType.success);
    } finally {
      if (waitDialogShown && mounted) {
        final nav = Navigator.of(context, rootNavigator: true);
        if (nav.canPop()) {
          nav.pop();
        }
      }
      if (wasPlayingBeforeCapture && mounted && _hasVideo && !_isSaving) {
        await _playVideo();
      }
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
    if (!_hasVideo || src == null || _openedSrcPath == null) {
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

    final sourceName = p.basenameWithoutExtension(src!);
    final cacheDir = await getApplicationCacheDirectory();
    final defaultName = 'corrected_$sourceName.mp4';
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
      _lastSavedPath = requestedPath;
      _statusText = hasAudio
          ? 'Saved with audio: $requestedPath'
          : 'Saved (video only): $requestedPath';
    });
  }

  Future<void> _openSavedFolderInExplorer() async {
    final savedPath = _lastSavedPath ?? dst;
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
    _toastTimer?.cancel();
    _toastOverlayEntry?.remove();
    _toastOverlayEntry = null;
    unawaited(_killPlaybackIsolate());
    unawaited(_killSaveIsolate());
    unawaited(_deleteTempInputIfNeeded());
    unawaited(_clearTemporaryCacheDirectory());
    vc.release();
    vw.release();
    _fullscreenFocusNode.dispose();
    _presetNameController.dispose();
    _imageTransformController.dispose();
    _cachedRawPreviewFrame?.dispose();
    _cachedRawPreviewFrame = null;
    _cachedRawPreviewFrameNum = null;
    _disposeSourceImage();
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

  /// Attaches the playback isolate listener to [_fromIsolatePort] for [session].
  /// Extracted so the same listener logic can be reused for fast-resume
  /// (re-attach without re-spawning the isolate).
  void _attachPlaybackIsolateListener(int session) {
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
        if (frameNum != null && _pendingSeekTargetFrame != null) {
          _pendingSeekTargetFrame = null;
          _seekingSlider = false;
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
        // If pause was requested, the isolate is still alive; ignore stale 'done'.
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

  Future<void> _playVideo() async {
    if (!_hasVideo || _isSaving || _isPlaying) {
      debugPrint('No video selected or video not opened');
      return;
    }

    final resume = _isPaused;

    // Fast-resume path: isolate is still alive (kept alive by _pauseVideo).
    // The existing listener and ReceivePort are intact — just send 'resume'.
    // Do NOT increment _playbackSession; the existing session remains valid.
    if (resume && _isolateSendPort != null && _fromIsolatePort != null) {
      setState(() {
        _isPlaying = true;
        _isPaused = false;
        _statusText = 'Playing';
      });
      _isolateSendPort!.send({'cmd': 'resume'});
      unawaited(() async {
        try {
          await _audioPlayer.play();
        } catch (e) {
          debugPrint('Audio resume failed: $e');
        }
      }());
      return;
    }

    // Fresh start: increment session to invalidate any stale callbacks,
    // then kill any existing isolate and spawn a new one.
    _playbackSession += 1;
    final session = _playbackSession;

    setState(() {
      _isPlaying = true;
      _isPaused = false;
      _statusText = 'Playing';
    });

    final targetFps = fps > 1 ? fps : 30.0;
    final startFrame = resume ? _lastReceivedFrameNum : 0;
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

    _attachPlaybackIsolateListener(session);
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
        if (key == LogicalKeyboardKey.keyF && _hasMedia && !_isSaving) {
          _toggleFullscreen();
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
                    tooltip: 'Select media',
                    onPressed: _isSaving ? null : _selectVideo,
                    icon: const Icon(Icons.perm_media, color: Colors.white),
                  ),
                  IconButton(
                    tooltip: 'Select folder',
                    onPressed: _isSaving ? null : _selectFolder,
                    icon: const Icon(Icons.folder_open, color: Colors.white),
                  ),
                  IconButton(
                    tooltip: 'Save corrected media',
                    onPressed: (_hasMedia && !_isSaving)
                        ? _saveEditedCurrentMedia
                        : null,
                    icon: const Icon(Icons.save_alt, color: Colors.white),
                  ),
                  IconButton(
                    tooltip: 'Capture current scene as PNG',
                    onPressed:
                        (_hasVideo && _currentFrame != null && !_isSaving)
                        ? _saveCurrentSceneAsPng
                        : null,
                    icon: const Icon(Icons.photo_camera, color: Colors.white),
                  ),
                  // IconButton(
                  //   tooltip: 'Open saved folder in Explorer',
                  //   onPressed: (dst != null && !_isSaving)
                  //       ? _openSavedFolderInExplorer
                  //       : null,
                  //   icon: const Icon(
                  //     Icons.folder_open_outlined,
                  //     color: Colors.white,
                  //   ),
                  // ),
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
        body: DropTarget(
          onDragEntered: (_) {
            if (!mounted) return;
            setState(() {
              _isDragOver = true;
            });
          },
          onDragExited: (_) {
            if (!mounted) return;
            setState(() {
              _isDragOver = false;
            });
          },
          onDragDone: (details) async {
            if (mounted) {
              setState(() {
                _isDragOver = false;
              });
            }
            final droppedPaths = details.files
                .map((item) => item.path)
                .where((path) => path.isNotEmpty)
                .toList();
            await _handleDroppedPaths(droppedPaths);
          },
          child: Stack(
            children: [
              SafeArea(
                child: Row(
                  children: [
                    Expanded(
                      flex: 7,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: _buildMainContent(),
                      ),
                    ),
                    if (!_isFullscreen)
                      Expanded(
                        flex: 3,
                        child: Container(
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            border: Border(
                              left: BorderSide(color: Colors.black12),
                            ),
                          ),
                          child: _buildControlPanel(),
                        ),
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
              if (_isDragOver)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      alignment: Alignment.center,
                      color: Colors.black.withValues(alpha: 0.35),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: colorMain, width: 2),
                        ),
                        child: Text(
                          'Drop media file or folder to open',
                          style: TextStyle(
                            color: colorMain,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
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
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          IconButton(
                            tooltip: 'Open saved folder in Explorer',
                            onPressed:
                                ((_lastSavedPath ?? dst) != null && !_isSaving)
                                ? _openSavedFolderInExplorer
                                : null,
                            icon: Icon(
                              Icons.folder_open_outlined,
                              color: colorMain,
                              size: 30,
                            ),
                          ),
                          _buildPreviewMatchToggle(),
                        ],
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
    final hasSavedPresets = _savedCorrectionPresets.isNotEmpty;
    final currentPresetLabel = _selectedPresetName ?? 'Default';

    return Column(
      children: [
        const ListTile(
          title: Text(
            'Correction Controls',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
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
              // _sliderTile(
              //   title: 'Audio volume',
              //   value: _audioVolume,
              //   min: 0,
              //   max: 1,
              //   divisions: 20,
              //   label: _audioVolume.toStringAsFixed(2),
              //   onChanged: (v) {
              //     setState(() => _audioVolume = v);
              //     if (_audioEnabled) {
              //       unawaited(_audioPlayer.setVolume(v * 100.0));
              //     }
              //   },
              //   onChangeEnd: (_) {},
              // ),
              const Divider(height: 16),
              SwitchListTile(
                value: _objectSelectionEnabled,
                title: const Text('Object selection mode'),
                subtitle: const Text(
                  'Drag to select & search on Google Images',
                ),
                onChanged: (v) {
                  setState(() => _objectSelectionEnabled = v);
                },
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  const Text(
                    'Current preset: ',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Expanded(
                    child: Text(
                      currentPresetLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colorMain,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: _isSaving ? null : _showSavePresetDialog,
                      child: _compactButtonLabel('Save'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: _isSaving ? null : _showLoadPresetDialog,
                      child: _compactButtonLabel('Load'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _isSaving || !hasSavedPresets
                          ? null
                          : _confirmDeleteCurrentPreset,
                      child: _compactButtonLabel('Delete'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _isSaving ? null : _confirmResetToDefault,
                      child: _compactButtonLabel('Reset'),
                    ),
                  ),
                ],
              ),
              // const SizedBox(height: 12),
              // Expanded(
              //   child: ElevatedButton(
              //     onPressed: !_isSaving
              //         ? () => _saveSettings(showFeedback: true)
              //         : null,
              //     child: const Text('Save'),
              //   ),
              // ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _handleImageSelection(ImageSelectionRect selection) async {
    if (_currentFrame == null) return;

    try {
      // Get the source image for cropping
      cv.Mat? sourceMat;
      if (_hasImage && _sourceImageMat != null) {
        sourceMat = _sourceImageMat;
      } else if (_hasVideo && vc.isOpened) {
        // Read the current frame from video
        vc.set(cv.CAP_PROP_POS_FRAMES, _lastReceivedFrameNum.toDouble());
        final (ok, frame) = await vc.readAsync();
        if (!ok || frame.width == 0) {
          frame.dispose();
          return;
        }
        sourceMat = frame;
      } else {
        return;
      }

      final source = sourceMat;
      if (source == null) return;

      // 정규화된 좌표(0~1)를 원본 이미지 좌표로 변환
      final rect = selection.rect;
      final imageWidth = source.width.toDouble();
      final imageHeight = source.height.toDouble();

      final adjustedSelection = ImageSelectionRect(
        start: Offset(rect.left * imageWidth, rect.top * imageHeight),
        end: Offset(rect.right * imageWidth, rect.bottom * imageHeight),
      );

      // Crop the selected region
      final croppedMat = await cropSelectedRegion(
        sourceImage: source,
        selection: adjustedSelection,
        displaySize: Size(imageWidth, imageHeight),
      );

      if (croppedMat == null || croppedMat.isEmpty) {
        if (!_hasVideo) sourceMat?.dispose();
        return;
      }

      // Convert Mat to PNG file
      final imagePath = await matToPngFile(
        croppedMat,
        maxLongEdge: _hasImage ? 720 : 0,
      );
      croppedMat.dispose();

      if (imagePath != null) {
        if (!mounted) return;

        // Copy image to Windows clipboard (actual image format)
        final clipboardSuccess = await copyImageFileToWindowsClipboard(
          imagePath,
        );

        if (clipboardSuccess) {
          // Open Google Images search with automatic image upload
          await searchImageOnGoogle(imagePath);

          // Show feedback
          _showCenterToast(
            'Image uploaded to Google Images! Check browser...',
            type: _ToastType.success,
          );

          // Open file explorer to show the saved image location
          // 약간의 지연을 주어 이미 열려있는 창에 포커스
          await Future.delayed(const Duration(milliseconds: 500));
          if (Platform.isWindows && mounted) {
            try {
              await Process.run('explorer.exe', ['/select,$imagePath']);
            } catch (e) {
              debugPrint('Failed to open explorer: $e');
            }
          }
        } else {
          _showCenterToast(
            'Clipboard copy failed. Opening Google Images...',
            type: _ToastType.warning,
          );

          // Try to open Google Images anyway and upload
          await searchImageOnGoogle(imagePath);

          // Open file explorer as fallback with delay
          await Future.delayed(const Duration(milliseconds: 500));
          if (Platform.isWindows && mounted) {
            try {
              await Process.run('explorer.exe', ['/select,$imagePath']);
            } catch (e) {
              debugPrint('Failed to open explorer: $e');
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Image selection error: $e');
      if (mounted) {
        _showCenterToast('Error: $e', type: _ToastType.error);
      }
    }
  }

  Widget _compactButtonLabel(String text) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(text, maxLines: 1, softWrap: false),
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

    final videoDisplay = MouseRegion(
      onHover: (_) => _showControlsTemporarily(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: Colors.black,
            child: _currentFrame == null
                ? const Center(
                    child: Text(
                      'Select media (video or image)',
                      style: TextStyle(color: Colors.white70, fontSize: 18),
                    ),
                  )
                : (_hasImage
                      ? Builder(
                          builder: (localContext) {
                            return Listener(
                              onPointerSignal: (event) =>
                                  _handleImagePointerSignal(
                                    event,
                                    localContext,
                                  ),
                              child: InteractiveViewer(
                                transformationController:
                                    _imageTransformController,
                                minScale: _imageMinScale,
                                maxScale: _imageMaxScale,
                                scaleEnabled: false,
                                panEnabled: _imageScale > 1.001,
                                clipBehavior: Clip.hardEdge,
                                child: Center(
                                  child: RawImage(
                                    image: _currentFrame,
                                    fit: BoxFit.contain,
                                    filterQuality: FilterQuality.medium,
                                  ),
                                ),
                              ),
                            );
                          },
                        )
                      : RawImage(
                          image: _currentFrame,
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.medium,
                        )),
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
          if (_hasVideo)
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
                            onChangeStart: (_hasVideo && !_isSaving)
                                ? (_) => unawaited(_beginSeekInteraction())
                                : null,
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
                                ? (v) => unawaited(_endSeekInteraction(v))
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
                              onPressed: _hasMedia ? _toggleFullscreen : null,
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
                                            _audioPlayer.setVolume(
                                              value * 100.0,
                                            ),
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

    // Wrap with SelectableImageDisplay if selection mode is enabled
    if (_objectSelectionEnabled && _hasMedia) {
      return SelectableImageDisplay(
        baseWidget: videoDisplay,
        onSelectionComplete: (selection) async {
          await _handleImageSelection(selection);
        },
      );
    }

    return videoDisplay;
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
              onChanged: (_isSaving || !_hasMedia)
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
      if (c == 'pause') {
        // Enter nested wait until the main thread sends 'resume', 'stop', or 'seek'.
        while (true) {
          if (!await commands.moveNext()) {
            stopRequested = true;
            break;
          }
          final resumeCmd = commands.current;
          if (resumeCmd is! Map) continue;
          final rc = resumeCmd['cmd'] as String?;
          if (rc == 'stop') {
            stopRequested = true;
            break;
          }
          if (rc == 'updateParams') {
            final updated = resumeCmd['params'];
            if (updated is Map) {
              params = Map<String, dynamic>.from(updated);
            }
            continue;
          }
          if (rc == 'seek') {
            final seekFrame = resumeCmd['frame'] as int? ?? 0;
            vc.set(cv.CAP_PROP_POS_FRAMES, seekFrame.toDouble());
            localFrameCount = 0;
            playbackClock
              ..reset()
              ..start();
            seekRequested = true;
            break;
          }
          if (rc == 'resume') {
            // Reset the playback clock so timing debt doesn't pile up while paused.
            localFrameCount = 0;
            playbackClock
              ..reset()
              ..start();
            break; // fall through to outer break (ack-equivalent)
          }
        }
        break; // exit outer command loop — outer loop sends no ack on pause/resume
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
    } catch (e) {
      debugPrint('[ffmpeg] canRun($exe) failed: $e');
      return false;
    }
  }

  // 1. Check system PATH (환경변수에서)
  debugPrint('[ffmpeg] Checking system PATH for ffmpeg...');
  if (await canRun('ffmpeg')) {
    debugPrint('[ffmpeg] Found in system PATH');
    return 'ffmpeg';
  }

  // 2. Check common local/bundled paths
  debugPrint('[ffmpeg] Checking local bundled paths...');
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
    if (File(c).existsSync()) {
      debugPrint('[ffmpeg] Found at: $c');
      if (await canRun(c)) return c;
    }
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
      debugPrint('[ffmpeg] Checking portable dir: $installedExe');
      if (File(installedExe).existsSync() && await canRun(installedExe)) {
        debugPrint('[ffmpeg] Using existing portable FFmpeg');
        return installedExe;
      }

      // 4. Auto-download portable ffmpeg (with retry)
      debugPrint('[ffmpeg] Not found anywhere. Starting auto-download...');
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

      // Multiple CDN fallbacks
      const urls = [
        'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip',
        'https://github.com/GyanD/codexffmpeg/releases/download/7.1/ffmpeg-7.1-essentials_build.zip',
      ];

      String psQuote(String v) => v.replaceAll("'", "''");

      bool downloadSuccess = false;
      for (final url in urls) {
        try {
          debugPrint('[ffmpeg] Trying download from: $url');
          final script =
              "\$ErrorActionPreference='Stop'; "
              "\$ProgressPreference='SilentlyContinue'; "
              "Invoke-WebRequest -Uri '${psQuote(url)}' -OutFile '${psQuote(zipPath)}' -TimeoutSec 300; "
              "Expand-Archive -Path '${psQuote(zipPath)}' -DestinationPath '${psQuote(extractPath)}' -Force;";

          final download = await Process.run('powershell', [
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-Command',
            script,
          ], runInShell: true);

          if (download.exitCode == 0) {
            debugPrint('[ffmpeg] Download succeeded from: $url');
            downloadSuccess = true;
            break;
          } else {
            debugPrint(
              '[ffmpeg] Download failed from $url: ${download.stderr}',
            );
          }
        } catch (e) {
          debugPrint('[ffmpeg] Exception downloading from $url: $e');
        }
      }

      if (!downloadSuccess) {
        debugPrint('[ffmpeg] All download attempts failed');
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

  // Auto underwater correction
  final autoCorrection = params['autoCorrection'] as bool? ?? true;
  if (autoCorrection) {
    final autoStrength = params['autoStrength'] as double? ?? 0.62;
    final redRecovery = params['redRecovery'] as double? ?? 1.05;

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
    final featheredBlueMask = await cv.gaussianBlurAsync(blueMask, (5, 5), 0.0);
    final (_, strongBlueMask) = await cv.thresholdAsync(
      featheredBlueMask,
      178,
      255,
      cv.THRESH_BINARY,
    );
    final (_, softBlueMask) = await cv.thresholdAsync(
      featheredBlueMask,
      42,
      255,
      cv.THRESH_BINARY,
    );
    final transitionBlueMask = await cv.subtractAsync(
      softBlueMask,
      strongBlueMask,
    );
    final invSoftBlueMask = await cv.bitwiseNOTAsync(softBlueMask);

    final bgrChannels = await cv.splitAsync(working);
    final b = bgrChannels[0];
    final g = bgrChannels[1];
    final r = bgrChannels[2];

    final bBoosted = await cv.convertScaleAbsAsync(b, alpha: blueOceanTone);
    final bBase = await cv.bitwiseANDAsync(b, b, mask: invSoftBlueMask);
    final bStrongBoost = await cv.bitwiseANDAsync(
      bBoosted,
      bBoosted,
      mask: strongBlueMask,
    );
    final bTransitionBoost = await cv.bitwiseANDAsync(
      bBoosted,
      bBoosted,
      mask: transitionBlueMask,
    );
    final bTransitionBase = await cv.bitwiseANDAsync(
      b,
      b,
      mask: transitionBlueMask,
    );
    final bTransitionMixed = await cv.addWeightedAsync(
      bTransitionBoost,
      0.70,
      bTransitionBase,
      0.30,
      0.0,
    );
    final bBasePlusTransition = await cv.addAsync(bBase, bTransitionMixed);
    final bFinal = await cv.addAsync(bBasePlusTransition, bStrongBoost);
    final blued = await cv.mergeAsync(cv.VecMat.fromList([bFinal, g, r]));

    hsvForBlue.dispose();
    lowerBlue.dispose();
    upperBlue.dispose();
    blueMask.dispose();
    featheredBlueMask.dispose();
    strongBlueMask.dispose();
    softBlueMask.dispose();
    transitionBlueMask.dispose();
    invSoftBlueMask.dispose();
    bBoosted.dispose();
    bBase.dispose();
    bStrongBoost.dispose();
    bTransitionBoost.dispose();
    bTransitionBase.dispose();
    bTransitionMixed.dispose();
    bBasePlusTransition.dispose();
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
