import 'dart:async';
import 'dart:math' as math;

import 'package:after_layout/after_layout.dart';
import 'package:dive_computer_flutter/aPref.dart';
import 'package:dive_computer_flutter/hiveHelper.dart';
import 'package:dive_computer_flutter/router.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  if (GetPlatform.isWindows) {
    await windowManager.ensureInitialized();
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final logicalScreenSize = view.physicalSize / view.devicePixelRatio;
    final targetWidth = math.min(1200.0, logicalScreenSize.width * 0.92);
    final targetHeight = math.min(1000.0, logicalScreenSize.height * 0.92);

    final windowOptions = WindowOptions(
      size: Size(targetWidth, targetHeight),
      center: true,
      // backgroundColor: Colors.white,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
      // alwaysOnTop: true,
      minimumSize: Size(
        math.min(300.0, targetWidth),
        math.min(300.0, targetHeight),
      ),
    );

    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(
    MultiProvider(
      providers: [ChangeNotifierProvider(create: (_) => HiveHelper())],
      child: MyApp(),
    ),
  );

  // SystemChrome.setPreferredOrientations([
  //   DeviceOrientation.landscapeLeft,
  //   DeviceOrientation.landscapeRight,
  // ]).then((value) {
  //   runApp(
  //     MultiProvider(
  //       providers: [ChangeNotifierProvider(create: (_) => HiveHelper())],
  //       child: MyApp(),
  //     ),
  //   );
  // });
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with AfterLayoutMixin {
  @override
  void initState() {
    super.initState();
  }

  @override
  FutureOr<void> afterFirstLayout(BuildContext context) async {
    // HIVE initialization
    await HiveHelper().initialize();
    if (GetPlatform.isWindows) {
      await windowManager.setAlwaysOnTop(APref.getData(AprefKey.ALWAYS_ON_TOP));
    }
  }

  @override
  void dispose() {
    HiveHelper().dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp.router(
      debugShowCheckedModeBanner: false,
      routerDelegate: router.routerDelegate,
      routeInformationParser: router.routeInformationParser,
      routeInformationProvider: router.routeInformationProvider,
      backButtonDispatcher: router.backButtonDispatcher,
    );
  }
}
