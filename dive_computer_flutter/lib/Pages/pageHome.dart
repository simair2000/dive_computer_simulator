import 'dart:async';

import 'package:after_layout/after_layout.dart';
import 'package:dive_computer_flutter/buhlmann.dart';
import 'package:flutter/material.dart';

class PageHome extends StatefulWidget {
  const PageHome({super.key});

  @override
  State<PageHome> createState() => _PageHomeState();
}

class _PageHomeState extends State<PageHome> with AfterLayoutMixin {
  Duration? _surfaceTime;
  final Buhlmann _buhlmann = Buhlmann();

  @override
  void initState() {
    _surfaceTime = Buhlmann.getSurfaceTime();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        padding: EdgeInsets.all(20),
        child: AnimatedBuilder(
          animation: Listenable.merge([_buhlmann.ndl, _buhlmann.tts]),
          builder: (context, child) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Surface Time : ${_surfaceTime == null ? 'First Dive!' : _surfaceTime.toString()}',
                ),
                Text('NDL : ${_buhlmann.ndl.value.toStringAsFixed(2)} min'),
                Text('TTS : ${_buhlmann.tts.value} min'),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  FutureOr<void> afterFirstLayout(BuildContext context) {
    Timer.periodic(Duration(seconds: intervalSeconds.toInt()), (timer) {
      if (_buhlmann.processCycle()) {
        setState(() {
          _surfaceTime = Buhlmann.getSurfaceTime();
        });
      } else {
        timer.cancel();
      }
    });
  }
}
