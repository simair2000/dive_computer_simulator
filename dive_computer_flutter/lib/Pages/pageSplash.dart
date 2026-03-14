import 'dart:async';

import 'package:after_layout/after_layout.dart';
import 'package:dive_computer_flutter/define.dart';
import 'package:dive_computer_flutter/extensions.dart';
import 'package:dive_computer_flutter/router.dart';
import 'package:dive_computer_flutter/styles.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:go_router/go_router.dart';

class PageSplash extends StatefulWidget {
  const PageSplash({super.key});

  @override
  State<PageSplash> createState() => _PageSplashState();
}

class _PageSplashState extends State<PageSplash> with AfterLayoutMixin {
  bool _showGoButton = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              'assets/scuba-diving.png',
              width: 150,
              fit: BoxFit.cover,
            ),
            const SizedBox(height: 20),
            const Text(
              'HOON\'s Dive',
              style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
            ).color(colorMain).marginOnly(bottom: 10),
            Text(
              'ZHL-16C Algorithm based.',
            ).color(colorMain).marginOnly(bottom: 10),
            Text(
              'Made by SangHoon Kim, PADI SCUBA Instructor #537076',
            ).color(colorMain).marginOnly(bottom: 30),
            _showGoButton
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Button(
                        height: 50,
                        child: Row(
                          children: [
                            Icon(
                              Icons.scuba_diving,
                              color: Colors.white,
                            ).marginOnly(right: 5),
                            Text('DIVE Simulator').color(Colors.white),
                          ],
                        ),
                        onPressed: () {
                          context.goNamed(RoutePage.home.name);
                        },
                      ).marginOnly(right: 10),
                      Button(
                        height: 50,
                        child: Row(
                          children: [
                            Icon(
                              Icons.assignment,
                              color: Colors.white,
                            ).marginOnly(right: 5),
                            Text('DIVE Planner').color(Colors.white),
                          ],
                        ),
                        onPressed: () {
                          context.goNamed(RoutePage.planner.name);
                        },
                      ),
                    ],
                  )
                : CircularProgressIndicator(color: colorMain),
          ],
        ),
      ),
    );
  }

  @override
  Future<void> afterFirstLayout(BuildContext context) async {
    // Timer(Duration(seconds: 3), () {
    //   setState(() {
    //     _showGoButton = true;
    //   });
    // });
  }
}
