import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Widget Button({
  VoidCallback? onPressed,
  required Widget child,
  double? width,
  double? height,
  EdgeInsetsGeometry? padding,
  VoidCallback? onLongPress,
  Color? borderColor,
  double? borderWidth,
  EdgeInsetsGeometry? margin,
  bool? enable,
  Color? color,
  Color? hoverColor,
}) {
  Color tColor = color ?? Color(0xFF506898);
  BorderRadiusGeometry borderRadius = BorderRadius.all(Radius.circular(5));
  bool isPressed = false;
  return GestureDetector(
    onLongPressStart: (_) async {
      isPressed = true;
      do {
        await Future.delayed(Duration(milliseconds: 100));
        if (onLongPress != null) {
          onLongPress();
        }
      } while (isPressed);
    },
    onLongPressEnd: (_) => isPressed = false,
    child: Container(
      decoration: BoxDecoration(borderRadius: borderRadius),
      margin: margin ?? EdgeInsets.zero,
      child: MaterialButton(
        hoverColor: hoverColor,
        disabledColor: tColor.withOpacity(0.3),
        hoverElevation: 0,
        disabledTextColor: Colors.black.withOpacity(0.3),
        elevation: 0,
        onPressed: enable != null && enable == false ? null : onPressed,
        color: tColor,
        minWidth: width,
        height: height,
        padding: padding ?? EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: borderRadius,
          side: BorderSide(
            color: borderColor ?? Colors.transparent,
            width: borderWidth ?? 0,
          ),
        ),
        child: enable != null && enable == false
            ? Opacity(opacity: 0.3, child: child)
            : child,
      ),
    ),
  );
}

Widget ButtonWithColor({
  Key? key,
  required Color color,
  required BorderRadiusGeometry borderRadius,
  VoidCallback? onPressed,
  required Widget child,
  double? width,
  double? height,
  EdgeInsetsGeometry? padding,
  VoidCallback? onLongPress,
  Color? borderColor,
  double? borderWidth,
  EdgeInsetsGeometry? margin,
  bool? enable,
  Color? disableColor,
  bool? autoFocus,
}) {
  bool isPressed = false;
  return GestureDetector(
    key: key,
    onLongPressStart: enable != null && enable == false
        ? null
        : (_) async {
            isPressed = true;
            do {
              await Future.delayed(Duration(milliseconds: 100));
              if (onLongPress != null) {
                onLongPress();
              }
            } while (isPressed);
          },
    onLongPressEnd: (_) => isPressed = false,
    child: Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.transparent),
        borderRadius: borderRadius,
      ),
      margin: margin ?? EdgeInsets.zero,
      child: MaterialButton(
        autofocus: autoFocus ?? false,
        disabledColor: disableColor ?? color.withOpacity(0.3),
        disabledTextColor: disableColor ?? Colors.black.withOpacity(0.3),
        elevation: 0,
        onPressed: enable != null && enable == false ? null : onPressed,
        color: color,
        minWidth: width,
        height: height,
        padding: padding ?? EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: borderRadius,
          side: BorderSide(
            color: borderColor ?? Colors.transparent,
            width: borderWidth ?? 0,
          ),
        ),
        child: enable != null && enable == false && disableColor == null
            ? Opacity(opacity: 0.3, child: child)
            : child,
      ),
    ),
  );
}

Widget ButtonWithImage({
  required Image image,
  VoidCallback? onPressed,
  double? width,
  double? height,
  VoidCallback? onLongPress,
  EdgeInsetsGeometry? padding,
  Color? color,
  bool? enable,
}) {
  bool isPressed = false;
  return GestureDetector(
    onLongPressStart: enable != null && enable == false
        ? null
        : (_) async {
            isPressed = true;
            do {
              await Future.delayed(Duration(milliseconds: 120));
              if (onLongPress != null) {
                onLongPress();
              }
            } while (isPressed);
          },
    onLongPressEnd: (_) {
      isPressed = false;
    },
    child: MaterialButton(
      clipBehavior: Clip.hardEdge,
      elevation: 0,
      onPressed: enable != null && enable == false ? null : onPressed,
      minWidth: width,
      height: height,
      color: color ?? Colors.transparent,
      padding: padding ?? EdgeInsets.zero,
      child: enable != null && enable == false
          ? Opacity(opacity: 0.3, child: image)
          : image,
    ),
  );
}

Widget InputText({
  TextEditingController? controller,
  String? hintText,
  int? maxLines,
  ValueChanged<String>? onFieldSubmitted,
  Widget? suffixIcon,
  double? fontSize,
  Color? focusColor,
  bool? enabled,
  bool useEnterKey = false,
  List<TextInputFormatter>? inputFormatters,
  TextInputType? keyboardType,
  double? radius,
  TextAlign? textAlign,
  bool? readOnly,
  FocusNode? focusNode,
  double? height,
  double? width,
  bool? autoFocus,
}) {
  return SizedBox(
    width: width,
    height: height,
    child: TextFormField(
      enabled: enabled,
      style: TextStyle(fontSize: fontSize, color: Colors.black),
      readOnly: readOnly ?? false,
      textAlign: textAlign ?? TextAlign.start,
      inputFormatters: inputFormatters,
      textInputAction: useEnterKey ? null : TextInputAction.go,
      onFieldSubmitted: onFieldSubmitted,
      controller: controller,
      maxLines: maxLines,
      autofocus: autoFocus ?? true,
      focusNode: focusNode,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        isDense: true,
        hintText: hintText,
        hintStyle: TextStyle(
          fontSize: fontSize ?? 13.5,
          color: Color(0xffA1AEC0),
        ),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Colors.grey.withAlpha(100), width: 0.5),
          borderRadius: BorderRadius.circular(radius ?? 5),
        ),
        disabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Colors.grey.withAlpha(100), width: 0.5),
          borderRadius: BorderRadius.circular(radius ?? 5),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(
            color: focusColor ?? Color(0xFFe0e0e0),
            width: 1,
          ),
          borderRadius: BorderRadius.circular(radius ?? 5),
        ),
        errorBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Color(0x00000000), width: 1),
          borderRadius: BorderRadius.circular(radius ?? 5),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Color(0x00000000), width: 1),
          borderRadius: BorderRadius.circular(radius ?? 5),
        ),
        filled: true,
        fillColor: Colors.white,
        suffixIcon: suffixIcon,
      ),
    ),
  );
}

class ConsoleProvider with ChangeNotifier {
  final List<TextSpan> _logs = [];

  List<TextSpan> get logs => _logs;

  void clear() {
    _logs.clear();
    notifyListeners();
  }

  void addLog(String msg, bool isSender) {
    try {
      _logs.add(
        TextSpan(
          text: msg,
          style: TextStyle(
            fontSize: 15,
            color: isSender ? Colors.white : Colors.green,
          ),
        ),
      );
      if (!msg.endsWith('\n')) {
        _logs.add(const TextSpan(text: '\n'));
      }
      // UI 갱신 알림
      notifyListeners();
    } catch (e) {
      print(e);
    }
  }
}
