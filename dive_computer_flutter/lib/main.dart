import 'dart:async';

import 'package:after_layout/after_layout.dart';
import 'package:dive_computer_flutter/hiveHelper.dart';
import 'package:dive_computer_flutter/router.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  if (GetPlatform.isWindows) {
    WindowOptions windowOptions = const WindowOptions(
      size: Size(900, 600),
      center: true,
      // backgroundColor: Colors.white,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
      alwaysOnTop: true,
      minimumSize: Size(900, 600),
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
