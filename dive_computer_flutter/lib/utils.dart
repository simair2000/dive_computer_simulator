import 'dart:async';

import 'package:dive_computer_flutter/extensions.dart';
import 'package:dive_computer_flutter/styles.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:get/get.dart';

bool listIsNotEmpty(List? list) {
  if (list != null && list.isNotEmpty) {
    return true;
  }
  return false;
}

bool listIsEmpty(List? list) {
  if (list == null || list.isEmpty) {
    return true;
  }
  return false;
}

bool textIsNotEmpty(String? value) {
  if (value != null && value.isNotEmpty) {
    return true;
  }
  return false;
}

bool textIsEmpty(String? value) {
  if (value == null || value.isEmpty) {
    return true;
  }
  return false;
}

void scrollToEnd(ScrollController controller) {
  SchedulerBinding.instance.addPostFrameCallback((_) {
    Future.delayed(Duration(milliseconds: 100), () {
      if (controller.hasClients) {
        controller.animateTo(
          controller.position.maxScrollExtent,
          curve: Curves.ease,
          duration: Duration(milliseconds: 200),
        );
      }
    });
  });
}

void showSnackbar(String title, String message) {
  final double horizontalMargin = (Get.width * 0.06).clamp(12.0, 150.0);
  Get.snackbar(
    title,
    message,
    backgroundColor: Colors.black.withAlpha(150),
    colorText: Colors.white,
    margin: EdgeInsets.symmetric(horizontal: horizontalMargin, vertical: 20),
    snackPosition: SnackPosition.BOTTOM,
  );
}

Future showGetDialog(String title, String message) {
  return Get.dialog(
    AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        Button(
          child: Text('OK').color(Colors.white),
          onPressed: () => Get.back(),
        ),
      ],
    ),
  );
}

Future showToast(String msg, {double? fontSize, Duration? duration}) {
  return Get.showOverlay(
    asyncFunction: () async {
      await Future.delayed(duration ?? Duration(seconds: 2));
    },
    loadingWidget: Scaffold(
      backgroundColor: Colors.black.withAlpha(100),
      body: Center(
        child: Container(
          width: 400,
          height: 300,
          margin: EdgeInsets.symmetric(horizontal: 20, vertical: 100),
          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.all(Radius.circular(10)),
          ),
          child: Center(
            child: Text(msg).color(Colors.black).size(fontSize ?? 15),
          ),
        ),
      ),
    ),
  );
}

double clamp(double x, double min, double max) {
  if (x < min) x = min;
  if (x > max) x = max;

  return x;
}
