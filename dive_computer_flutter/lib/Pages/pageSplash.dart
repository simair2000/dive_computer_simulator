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
              'Dive Computer Simulator',
              style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
            ).color(colorMain).marginOnly(bottom: 10),
            Text(
              'ZHL-16C Algorithm based.',
            ).color(colorMain).marginOnly(bottom: 10),
            Text(
              'Made by SangHoon Kim, PADI SCUBA Instructor #537076',
            ).color(colorMain).marginOnly(bottom: 30),
            _showGoButton
                ? Button(
                    height: 50,
                    child: Text('Let\'s DIVE').color(Colors.white),
                    onPressed: () {
                      context.goNamed(RoutePage.home.name);
                    },
                  )
                : CircularProgressIndicator(color: colorMain),
          ],
        ),
      ),
    );
  }

  @override
  FutureOr<void> afterFirstLayout(BuildContext context) {
    // Timer(Duration(seconds: 3), () {
    //   setState(() {
    //     _showGoButton = true;
    //   });
    // });
  }
}
