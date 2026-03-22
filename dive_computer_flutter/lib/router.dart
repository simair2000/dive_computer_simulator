import 'package:dive_computer_flutter/Pages/pageERDP.dart';
import 'package:dive_computer_flutter/Pages/pageHome.dart';
import 'package:dive_computer_flutter/Pages/pagePlanner.dart';
import 'package:dive_computer_flutter/Pages/pageSettings.dart';
import 'package:dive_computer_flutter/Pages/pageSplash.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:go_router/go_router.dart';

enum RoutePage {
  splash('/'),
  home('/home'),
  planner('/planner'),
  eRDP('/erdp'),
  settings('/settings');

  const RoutePage(this.path);
  final String path;
}

final GlobalKey<NavigatorState> mainTabNavKey = GlobalKey<NavigatorState>();

final GoRouter router = GoRouter(
  navigatorKey: Get.key,
  initialLocation: RoutePage.splash.path,
  routes: [
    GoRoute(
      name: RoutePage.splash.name,
      path: RoutePage.splash.path,
      pageBuilder: (context, state) => NoTransitionPage(child: PageSplash()),
    ),
    GoRoute(
      name: RoutePage.home.name,
      path: RoutePage.home.path,
      pageBuilder: (context, state) => NoTransitionPage(child: PageHome()),
    ),
    GoRoute(
      name: RoutePage.planner.name,
      path: RoutePage.planner.path,
      pageBuilder: (context, state) => NoTransitionPage(child: PagePlanner()),
    ),
    GoRoute(
      name: RoutePage.settings.name,
      path: RoutePage.settings.path,
      pageBuilder: (context, state) => NoTransitionPage(child: PageSettings()),
    ),
    GoRoute(
      name: RoutePage.eRDP.name,
      path: RoutePage.eRDP.path,
      pageBuilder: (context, state) => NoTransitionPage(child: PageErdp()),
    ),
  ],
);
