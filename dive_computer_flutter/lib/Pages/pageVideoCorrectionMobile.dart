import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:image/image.dart' as img;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class PageVideoCorrectionMobile extends StatefulWidget {
  const PageVideoCorrectionMobile({super.key});

  @override
  State<PageVideoCorrectionMobile> createState() =>
      _PageVideoCorrectionMobileState();
}

class _PageVideoCorrectionMobileState extends State<PageVideoCorrectionMobile> {
  File? _selectedImageFile;
  File? _selectedVideoFile;
  Uint8List? _displayedImageBytes;
  VideoPlayerController? _videoController;
  bool _isProcessing = false;

  // Correction settings
  bool _useAutoEnhance = false;
  double _brightness = 0;
  double _contrast = 1.0;
  double _saturation = 1.0;

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final isWide = mediaQuery.size.shortestSide >= 600;
    final isTabletDevice = isWide;
    return Scaffold(
      appBar: AppBar(title: const Text('Video/Image Correction (Mobile)')),
      body: isTabletDevice
          ? _buildTabletLayout(context)
          : _buildPhoneLayout(context),
    );
  }

  Widget _buildTabletLayout(BuildContext context) {
    return Row(
      children: [
        Expanded(flex: 2, child: _buildImageVideoSelector(context)),
        VerticalDivider(width: 1),
        Expanded(flex: 3, child: _buildCorrectionPanel(context)),
      ],
    );
  }

  Widget _buildPhoneLayout(BuildContext context) {
    return ListView(
      children: [
        _buildImageVideoSelector(context),
        Divider(),
        _buildCorrectionPanel(context),
      ],
    );
  }

  Widget _buildImageVideoSelector(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Select Image/Video',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          SizedBox(height: 12),
          ElevatedButton.icon(
            icon: Icon(Icons.photo),
            label: Text('Pick Image'),
            onPressed: _isProcessing
                ? null
                : () async {
                    final picker = ImagePicker();
                    final picked = await picker.pickImage(
                      source: ImageSource.gallery,
                    );
                    if (picked != null) {
                      setState(() {
                        _selectedImageFile = File(picked.path);
                        _selectedVideoFile = null;
                        _displayedImageBytes = File(
                          picked.path,
                        ).readAsBytesSync();
                        _videoController?.dispose();
                        _videoController = null;
                      });
                    }
                  },
          ),
          SizedBox(height: 8),
          ElevatedButton.icon(
            icon: Icon(Icons.videocam),
            label: Text('Pick Video'),
            onPressed: _isProcessing
                ? null
                : () async {
                    final picker = ImagePicker();
                    final picked = await picker.pickVideo(
                      source: ImageSource.gallery,
                    );
                    if (picked != null) {
                      final controller = VideoPlayerController.file(
                        File(picked.path),
                      );
                      await controller.initialize();

                      // Extract first frame for preview
                      setState(() => _isProcessing = true);
                      try {
                        final frame = await _extractVideoFirstFrame(
                          File(picked.path),
                        );
                        setState(() {
                          _selectedVideoFile = File(picked.path);
                          _selectedImageFile = null;
                          _displayedImageBytes = frame;
                          _videoController?.dispose();
                          _videoController = controller;
                        });
                      } finally {
                        setState(() => _isProcessing = false);
                      }
                    }
                  },
          ),
          SizedBox(height: 16),
          _selectedImageFile != null && _displayedImageBytes != null
              ? Image.memory(_displayedImageBytes!, height: 200)
              : _selectedVideoFile != null &&
                    _videoController != null &&
                    _videoController!.value.isInitialized
              ? AspectRatio(
                  aspectRatio: _videoController!.value.aspectRatio,
                  child: VideoPlayer(_videoController!),
                )
              : Container(
                  height: 200,
                  color: Colors.grey[200],
                  child: Center(child: Text('No media selected')),
                ),
        ],
      ),
    );
  }

  Widget _buildCorrectionPanel(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Correction Settings',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            SizedBox(height: 12),
            CheckboxListTile(
              title: Text('Auto Enhance'),
              value: _useAutoEnhance,
              onChanged: !_isProcessing
                  ? (v) => setState(() => _useAutoEnhance = v ?? false)
                  : null,
            ),
            SizedBox(height: 8),
            Text('Brightness: ${_brightness.toStringAsFixed(1)}'),
            Slider(
              value: _brightness,
              min: -50,
              max: 50,
              onChanged: !_isProcessing
                  ? (v) => setState(() => _brightness = v)
                  : null,
            ),
            SizedBox(height: 8),
            Text('Contrast: ${_contrast.toStringAsFixed(2)}'),
            Slider(
              value: _contrast,
              min: 0.5,
              max: 2.0,
              onChanged: !_isProcessing
                  ? (v) => setState(() => _contrast = v)
                  : null,
            ),
            SizedBox(height: 8),
            Text('Saturation: ${_saturation.toStringAsFixed(2)}'),
            Slider(
              value: _saturation,
              min: 0.5,
              max: 2.0,
              onChanged: !_isProcessing
                  ? (v) => setState(() => _saturation = v)
                  : null,
            ),
            SizedBox(height: 16),
            if (_selectedImageFile != null)
              ElevatedButton(
                child: Text('Apply to Preview'),
                onPressed: !_isProcessing
                    ? () => _applyCorrectionsToImage()
                    : null,
              ),
            if (_selectedVideoFile != null) ...[
              SizedBox(height: 8),
              ElevatedButton(
                child: Text('Save Video with Corrections'),
                onPressed: !_isProcessing
                    ? () => _saveVideoWithCorrections()
                    : null,
              ),
            ],
            if (_isProcessing) ...[
              SizedBox(height: 16),
              Center(child: CircularProgressIndicator()),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _applyCorrectionsToImage() async {
    if (_selectedImageFile == null) return;
    setState(() => _isProcessing = true);
    try {
      final bytes =
          _displayedImageBytes ?? await _selectedImageFile!.readAsBytes();
      final image = img.decodeImage(bytes)!;

      var adjusted = image;
      if (_useAutoEnhance) {
        adjusted = img.adjustColor(
          adjusted,
          contrast: 1.15,
          brightness: 10,
          saturation: 1.1,
        );
      } else {
        adjusted = img.adjustColor(
          adjusted,
          brightness: _brightness.toInt(),
          contrast: _contrast,
          saturation: _saturation,
        );
      }

      final result = img.encodeJpg(adjusted, quality: 90);
      setState(() => _displayedImageBytes = Uint8List.fromList(result));
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<Uint8List?> _extractVideoFirstFrame(File videoFile) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final outputPath = p.join(
        tempDir.path,
        'frame_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );

      final session = await FFmpegKit.execute(
        '-i "${videoFile.path}" -vf "select=eq(n\\,0)" -q:v 3 "$outputPath"',
      );
      final rc = await session.getReturnCode();

      if (ReturnCode.isSuccess(rc) && File(outputPath).existsSync()) {
        return File(outputPath).readAsBytes();
      }
    } catch (e) {
      debugPrint('Error extracting video frame: $e');
    }
    return null;
  }

  Future<void> _saveVideoWithCorrections() async {
    if (_selectedVideoFile == null) return;
    setState(() => _isProcessing = true);
    try {
      final tempDir = await getTemporaryDirectory();
      final outputPath = p.join(
        tempDir.path,
        'corrected_${DateTime.now().millisecondsSinceEpoch}.mp4',
      );

      String filterChain = '';
      if (_useAutoEnhance) {
        // Auto enhance: increase contrast, brightness, and saturation
        filterChain = 'eq=contrast=1.15:brightness=0.04,hue=s=1.1';
      } else {
        // Custom values
        final brightnessVal = _brightness / 255.0;
        filterChain =
            'eq=contrast=$_contrast:brightness=$brightnessVal,hue=s=$_saturation';
      }

      // Build FFmpeg command for video correction
      final cmd =
          '-i "${_selectedVideoFile!.path}" -vf "$filterChain" '
          '-c:v libx264 -crf 23 -c:a aac -b:a 128k "$outputPath"';

      final session = await FFmpegKit.execute(cmd);
      final rc = await session.getReturnCode();

      if (ReturnCode.isSuccess(rc) && await File(outputPath).exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Video saved: ${p.basename(outputPath)}'),
              duration: Duration(seconds: 3),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Video processing failed (RC: ${rc?.getValue()})')),
          );
        }
      }
    } catch (e) {
      debugPrint('Error saving video: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      setState(() => _isProcessing = false);
    }
  }
}
