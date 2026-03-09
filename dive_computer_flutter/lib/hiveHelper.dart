import 'dart:async';
import 'dart:io';

import 'package:dive_computer_flutter/aPref.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';
import 'package:window_manager/window_manager.dart';

class HiveHelper with ChangeNotifier {
  static final HiveHelper _instance = HiveHelper._internal();
  factory HiveHelper() => _instance;
  HiveHelper._internal();

  static const sharedPrefBoxName = 'SharedPreference';

  late Box prefBox;

  Future<void> initialize() async {
    final path = Directory.current.path;
    Hive.init(path);
    await _openBox();
  }

  @override
  void dispose() async {
    super.dispose();
    await _closeBox();
  }

  Future<void> _openBox() async {
    prefBox = await Hive.openBox(sharedPrefBoxName);
  }

  Future<void> _closeBox() async {
    await prefBox.close();
  }
}
