import 'dart:typed_data';
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:dartcv4/dartcv.dart' as cv;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;

/// 선택된 영역 정보를 저장하는 클래스
class ImageSelectionRect {
  final Offset start;
  final Offset end;

  ImageSelectionRect({required this.start, required this.end});

  /// 정규화된 직사각형 좌표를 반환
  Rect get rect {
    final left = start.dx < end.dx ? start.dx : end.dx;
    final top = start.dy < end.dy ? start.dy : end.dy;
    final right = start.dx > end.dx ? start.dx : end.dx;
    final bottom = start.dy > end.dy ? start.dy : end.dy;
    return Rect.fromLTRB(left, top, right, bottom);
  }

  bool get isEmpty => rect.width < 5 || rect.height < 5;
}

/// 이미지에서 선택된 영역을 크롭하여 cv.Mat으로 반환
Future<cv.Mat?> cropSelectedRegion({
  required cv.Mat sourceImage,
  required ImageSelectionRect selection,
  required Size displaySize,
}) async {
  try {
    final rect = selection.rect;

    // displaySize를 기준으로 선택 영역의 비율 계산
    final scaleX = sourceImage.width / displaySize.width;
    final scaleY = sourceImage.height / displaySize.height;

    // 원본 이미지 좌표로 변환
    final x = (rect.left * scaleX).round().clamp(0, sourceImage.width - 1);
    final y = (rect.top * scaleY).round().clamp(0, sourceImage.height - 1);
    final width = ((rect.width * scaleX).round()).clamp(
      1,
      sourceImage.width - x,
    );
    final height = ((rect.height * scaleY).round()).clamp(
      1,
      sourceImage.height - y,
    );

    // ROI (Region of Interest) 설정
    final roi = cv.Rect(x, y, width, height);
    final cropped = sourceImage.region(roi);

    return cropped;
  } catch (e) {
    print('Error cropping region: $e');
    return null;
  }
}

/// 크롭된 이미지를 임시 파일로 저장
Future<String?> saveCroppedImage(cv.Mat croppedImage) async {
  try {
    final tempDir = await getApplicationCacheDirectory();
    final fileName = 'cropped_${DateTime.now().millisecondsSinceEpoch}.png';
    final filePath = p.join(tempDir.path, fileName);

    final success = await cv.imwriteAsync(filePath, croppedImage);
    if (success) {
      return filePath;
    }
    return null;
  } catch (e) {
    print('Error saving cropped image: $e');
    return null;
  }
}

/// cv.Mat을 PNG 파일로 저장하고 경로 반환
/// 긴 변이 maxLongEdge를 넘으면 저장 전 다운스케일한다.
Future<String?> matToPngFile(cv.Mat mat, {int maxLongEdge = 0}) async {
  try {
    final tempDir = await getApplicationCacheDirectory();
    final tempFile = p.join(
      tempDir.path,
      'search_image_${DateTime.now().millisecondsSinceEpoch}.png',
    );

    cv.Mat output = mat;
    if (maxLongEdge > 0) {
      final srcW = mat.width;
      final srcH = mat.height;
      final longEdge = srcW > srcH ? srcW : srcH;
      if (longEdge > maxLongEdge) {
        final scale = maxLongEdge / longEdge;
        final targetW = (srcW * scale).round().clamp(1, srcW);
        final targetH = (srcH * scale).round().clamp(1, srcH);
        output = await cv.resizeAsync(mat, (targetW, targetH));
      }
    }

    final success = await cv.imwriteAsync(tempFile, output);
    if (!identical(output, mat)) {
      output.dispose();
    }
    if (!success) {
      return null;
    }

    return tempFile;
  } catch (e) {
    print('Error converting Mat to PNG file: $e');
    return null;
  }
}

/// Windows 클립보드에 실제 이미지 형식으로 복사
Future<bool> copyImageFileToWindowsClipboard(String imagePath) async {
  try {
    if (!File(imagePath).existsSync()) {
      print('Image file not found: $imagePath');
      return false;
    }

    // Windows 클립보드에 이미지를 복사하기 위해 PowerShell 사용
    if (Platform.isWindows) {
      // 파일 경로를 이스케이프 처리
      final escapedPath = imagePath.replaceAll('\\', '\\\\');

      final psCommand =
          'Add-Type -AssemblyName System.Windows.Forms; '
          'Add-Type -AssemblyName System.Drawing; '
          '\$image = [System.Drawing.Image]::FromFile(\'$escapedPath\'); '
          '[System.Windows.Forms.Clipboard]::SetImage(\$image); '
          '\$image.Dispose()';

      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-Command',
        psCommand,
      ]);

      if (result.exitCode == 0) {
        print('Image copied to clipboard successfully');
        return true;
      } else {
        print('PowerShell error: ${result.stderr}');
        return false;
      }
    }

    return false;
  } catch (e) {
    print('Error copying image to clipboard: $e');
    return false;
  }
}

/// 파일을 클립보드에 경로로 복사 (텍스트)
Future<bool> copyFilePathToClipboard(String filePath) async {
  try {
    await Clipboard.setData(ClipboardData(text: filePath));
    return true;
  } catch (e) {
    print('Error copying file path to clipboard: $e');
    return false;
  }
}

/// 이미지를 Google Images에 업로드하고 검색 결과 표시
Future<bool> searchImageOnGoogle(String imagePath) async {
  try {
    if (!File(imagePath).existsSync()) {
      print('Image file not found: $imagePath');
      return false;
    }

    // Google Images에 이미지 업로드 (multipart form data 사용)
    final imageFile = File(imagePath);
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('https://www.google.com/searchbyimage/upload'),
    );

    // 이미지 파일을 multipart 요청에 추가
    request.files.add(
      http.MultipartFile(
        'encoded_image',
        imageFile.readAsBytes().asStream(),
        imageFile.lengthSync(),
        filename: p.basename(imagePath),
      ),
    );

    // 요청 전송
    final streamedResponse = await request.send().timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        throw TimeoutException('Upload request timed out');
      },
    );

    final response = await http.Response.fromStream(streamedResponse);

    // 리다이렉트된 URL을 추출하고 열기
    if (response.statusCode == 200 || response.statusCode == 302) {
      // URL에서 리다이렉트 정보 추출
      final redirectUrl =
          response.request?.url.toString() ?? 'https://images.google.com/';

      // 브라우저에서 검색 결과 열기
      final uri = Uri.parse(redirectUrl);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return true;
      }
    }

    // 폴백: Google Images 메인 페이지 열기 (클립보드의 이미지를 Ctrl+V로 붙여넣기 가능)
    final googleImagesUrl = Uri.parse('https://images.google.com/');
    if (await canLaunchUrl(googleImagesUrl)) {
      await launchUrl(googleImagesUrl, mode: LaunchMode.externalApplication);
      return true;
    }

    return false;
  } catch (e) {
    print('Error in searchImageOnGoogle: $e');
    return false;
  }
}

/// 선택 영역을 UI에 그리기 위한 커스텀 페인터
class SelectionPainter extends CustomPainter {
  final ImageSelectionRect? selection;
  final Color boxColor;
  final Color fillColor;

  SelectionPainter({
    this.selection,
    this.boxColor = const Color(0xFF00BCD4),
    this.fillColor = const Color(0x2200BCD4),
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (selection == null || selection!.isEmpty) return;

    final rect = selection!.rect;

    // 반투명 배경
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0x44000000),
    );

    // 선택 영역은 밝게
    canvas.drawRect(rect, Paint()..color = fillColor);

    // 테두리
    canvas.drawRect(
      rect,
      Paint()
        ..color = boxColor
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );

    // 모서리 마커
    const markerSize = 8.0;
    final cornerPaint = Paint()
      ..color = boxColor
      ..strokeWidth = 2;

    // 네 모서리 그리기
    for (final corner in [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ]) {
      canvas.drawCircle(corner, markerSize / 2, cornerPaint);
    }

    // 크기 정보 표시
    final textPainter = TextPainter(
      text: TextSpan(
        text:
            '${rect.width.toStringAsFixed(0)} × ${rect.height.toStringAsFixed(0)}',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(rect.center.dx - textPainter.width / 2, rect.top - 25),
    );
  }

  @override
  bool shouldRepaint(SelectionPainter oldDelegate) {
    return oldDelegate.selection != selection;
  }
}

/// 드래그로 선택 영역을 관리하는 위젯
class SelectableImageDisplay extends StatefulWidget {
  final Widget baseWidget;
  final Function(ImageSelectionRect)? onSelectionComplete;

  const SelectableImageDisplay({
    super.key,
    required this.baseWidget,
    this.onSelectionComplete,
  });

  @override
  State<SelectableImageDisplay> createState() => _SelectableImageDisplayState();
}

class _SelectableImageDisplayState extends State<SelectableImageDisplay> {
  ImageSelectionRect? _currentSelection;
  bool _isSelecting = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return MouseRegion(
          cursor: SystemMouseCursors.basic,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanDown: (details) {
              setState(() {
                _isSelecting = true;
                _currentSelection = ImageSelectionRect(
                  start: details.localPosition,
                  end: details.localPosition,
                );
              });
            },
            onPanStart: (details) {
              setState(() {
                _isSelecting = true;
                _currentSelection = ImageSelectionRect(
                  start: details.localPosition,
                  end: details.localPosition,
                );
              });
            },
            onPanUpdate: (details) {
              setState(() {
                _currentSelection = ImageSelectionRect(
                  start: _currentSelection!.start,
                  end: details.localPosition,
                );
              });
            },
            onPanEnd: (_) {
              if (_currentSelection != null && !_currentSelection!.isEmpty) {
                // 정규화된 좌표로 변환 (0~1 범위)
                final rect = _currentSelection!.rect;
                final normalizedSelection = ImageSelectionRect(
                  start: Offset(
                    rect.left / constraints.maxWidth,
                    rect.top / constraints.maxHeight,
                  ),
                  end: Offset(
                    rect.right / constraints.maxWidth,
                    rect.bottom / constraints.maxHeight,
                  ),
                );
                widget.onSelectionComplete?.call(normalizedSelection);
              }
              setState(() {
                _isSelecting = false;
                _currentSelection = null;
              });
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                widget.baseWidget,
                if (_currentSelection != null)
                  CustomPaint(
                    painter: SelectionPainter(selection: _currentSelection),
                    size: Size.infinite,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// Base64 encoding functions
String encodeBase64(Uint8List bytes) {
  return base64Encode(bytes);
}

Uint8List decodeBase64(String encoded) {
  return base64Decode(encoded);
}
