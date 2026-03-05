import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:jiffy/jiffy.dart';

extension TextExtension on Text {
  Text color(Color color) => _copy(style: TextStyle(color: color));

  Text weight(FontWeight weight) => _copy(style: TextStyle(fontWeight: weight));

  Text size(double size) => _copy(style: TextStyle(fontSize: size));

  Text align(TextAlign align) => _copy(textAlign: align);

  Text fontType(String fontType) =>
      _copy(style: TextStyle(fontFamily: fontType));

  Text overFlow(TextOverflow overflow) =>
      _copy(style: TextStyle(overflow: overflow));

  Text line(int maxLines) => _copy(maxLines: maxLines);

  Text _copy({
    Key? key,
    StrutStyle? strutStyle,
    TextAlign? textAlign,
    Locale? locale,
    bool? softWrap,
    TextOverflow? overflow,
    double? textScaleFactor,
    int? maxLines,
    String? semanticsLabel,
    TextWidthBasis? textWidthBasis,
    TextStyle? style,
  }) {
    return Text(
      data ?? '',
      key: key ?? this.key,
      strutStyle: strutStyle ?? this.strutStyle,
      textAlign: textAlign ?? this.textAlign,
      locale: locale ?? this.locale,
      softWrap: softWrap ?? this.softWrap,
      overflow: overflow ?? this.overflow,
      textScaleFactor: textScaleFactor ?? this.textScaleFactor,
      maxLines: maxLines ?? this.maxLines,
      semanticsLabel: semanticsLabel ?? this.semanticsLabel,
      textWidthBasis: textWidthBasis ?? this.textWidthBasis,
      style: style != null ? this.style?.merge(style) ?? style : this.style,
    );
  }
}

extension StringExtension on String {
  String formatWon() {
    final formatter = NumberFormat('#,###');
    return formatter.format(int.parse(this));
  }

  String formatPhoneNumber() {
    return replaceAllMapped(
      RegExp(r'(\d{3})(\d{3,4})(\d{4})'),
      (m) => '${m[1]}-${m[2]}-${m[3]}',
    );
  }

  String formatDateTime(String format) {
    if (isEmpty) {
      return '';
    }
    var ret = '';
    try {
      ret = Jiffy.parse(this).format(pattern: format);
    } on Exception {
      return '';
    }
    return ret;
    // bool isISO8601 = toUpperCase().contains('T');
    // bool isUTC = toUpperCase().endsWith('Z');
    // if(isISO8601 || isUTC) {
    //   return Jiffy.parse(this).format(pattern: format);
    // }
    // var pDateTime = DateTime.tryParse(this);
    // if(pDateTime == null) return '';
    // return pDateTime.formatString(format: format)??'';
  }

  String addSuffix(String suffix) {
    return '$this '
        '$suffix';
  }

  String append(String value) {
    return '$this'
        '$value';
  }

  String convertEnumValue(Map<String, dynamic>? enumList) {
    if (enumList != null) {
      return enumList[this] ?? this;
    }
    return this;
  }

  String toUTF8() {
    return utf8.decode(codeUnits, allowMalformed: true);
  }

  String lastStrings(int n) => substring(length - n);

  String toBase64EndcodedString() {
    // return this;
    List<int> bytes = utf8.encode(this);
    return base64Encode(bytes);
  }

  String decodeBase64() {
    return String.fromCharCodes(base64Decode(this));
  }
}

extension NumberExtension on num? {
  String formatDistance(int fractionDigits) {
    String suffix = "m";
    if (this! >= 500) {
      suffix = "Km";
    }
    if (suffix == 'Km') {
      return (this! / 1000).toStringAsFixed(fractionDigits).addSuffix('km');
    } else {
      return '${this!}m';
    }
  }

  String formatDate({String? format = 'yyyy-MM-dd HH:mm:ss'}) {
    return DateFormat(
      format,
    ).format(DateTime.fromMillisecondsSinceEpoch((this ?? 0).toInt()));
  }
}

extension DateTimeExtension on DateTime {
  String formatString({String? format}) {
    return DateFormat(format ?? 'yyyy-MM-dd').format(this);
  }

  String parseToIso8601() {
    String str = toIso8601String();
    return '${str.substring(0, str.indexOf('.'))}Z';
  }
}

extension DurationExtension on Duration {
  String hhmmss() {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    String hours = twoDigits(inHours);
    String minutes = twoDigits(inMinutes.remainder(60));
    String seconds = twoDigits(inSeconds.remainder(60));
    return "$hours:$minutes:$seconds";
  }
}

extension ColorExtension on Color {
  Color darken({double? amount = .1}) {
    final hsl = HSLColor.fromColor(this);
    var light = hsl.lightness - amount!;
    if (light < 0) {
      light = 0;
    }
    if (1 < light) {
      light = 1;
    }
    final hslDark = hsl.withLightness(light);
    return hslDark.toColor();
  }

  Color lighten({double? amount = .1}) {
    final hsl = HSLColor.fromColor(this);
    var light = hsl.lightness + amount!;
    if (light < 0) {
      light = 0;
    }
    if (1 < light) {
      light = 1;
    }
    final hslLighten = hsl.withLightness(light);
    return hslLighten.toColor();
  }
}

extension ListExtension on List<int> {
  String toHexString() {
    return map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ');
  }
}

extension Uint8ListExtension on Uint8List {
  String toHexString() {
    return map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ');
  }

  String toDecimalString() {
    return map((e) => e.toRadixString(10)).join(' ');
  }

  bool equal(other) {
    if (identical(this, other)) {
      return true;
    }
    if (lengthInBytes != other.lengthInBytes) {
      return false;
    }

    // Treat the original byte lists as lists of 8-byte words.
    var numWords = lengthInBytes ~/ 8;
    var words1 = buffer.asUint64List(0, numWords);
    var words2 = other.buffer.asUint64List(0, numWords);

    for (var i = 0; i < words1.length; i += 1) {
      if (words1[i] != words2[i]) {
        return false;
      }
    }

    // Compare any remaining bytes.
    for (var i = words1.lengthInBytes; i < lengthInBytes; i += 1) {
      if (this[i] != other[i]) {
        return false;
      }
    }

    return true;
  }
}

extension DoubleExtension on double {
  double asFixed(int fractionDigits) {
    return double.parse(toStringAsFixed(fractionDigits));
  }

  double roundTo6Decimals() {
    return (this * 1000000).round() / 1000000;
  }
}
