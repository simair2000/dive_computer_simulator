import 'dart:async';
import 'dart:math';

import 'package:after_layout/after_layout.dart';
import 'package:dive_computer_flutter/buhlmann.dart';
import 'package:dive_computer_flutter/define.dart';
import 'package:dive_computer_flutter/extensions.dart';
import 'package:dive_computer_flutter/styles.dart';
import 'package:dive_computer_flutter/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

class PageHome extends StatefulWidget {
  const PageHome({super.key});

  @override
  State<PageHome> createState() => _PageHomeState();
}

class _PageHomeState extends State<PageHome> with AfterLayoutMixin {
  Duration? _surfaceTime;
  final Buhlmann _buhlmann = Buhlmann();

  final TextEditingController _textControllerDepth = TextEditingController();
  final TextEditingController _textControllerEAN = TextEditingController(
    text: '21',
  );

  @override
  void initState() {
    _surfaceTime = Buhlmann.getSurfaceTime();
    _textControllerDepth.addListener(() {
      double? depth = double.tryParse(_textControllerDepth.text);
      if (depth != null && 1.5 <= depth) {
        _buhlmann.startDive();
      }
    });
    super.initState();
  }

  @override
  void dispose() {
    _textControllerEAN.dispose();
    _textControllerDepth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('HOON\'s Dive Computer Simulator').color(Colors.white),
        leading: Icon(Icons.scuba_diving, color: Colors.white, size: 30),
        backgroundColor: colorMain,
        actions: [
          IconButton(
            onPressed: () {
              showGetDialog(
                'About',
                '- This is a dive computer simulator based on the ZHL-16C algorithm.\n- You can simulate your dive by adjusting the depth.\n- The NDL (No Decompression Limit) and TTS (Time To Surface) will be calculated in real-time based on your current depth and dive time.\n- If you exceed the NDL, the simulator will indicate that you need to perform decompression stops.\n- Please use this simulator responsibly and always follow safe diving practices in real life.',
              );
            },
            icon: Icon(Icons.help, color: Colors.white, size: 30),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: Listenable.merge([
          _buhlmann.ndl,
          _buhlmann.tts,
          _buhlmann.isOnDiving,
          _buhlmann.currentDepth,
          _buhlmann.maxDepth,
          _buhlmann.currentDiveTime,
          _buhlmann.decoStopDepth,
          _buhlmann.decoStopTime,
          _buhlmann.needDeco,
          _buhlmann.currentPO2,
        ]),
        builder: (context, child) {
          return Row(
            children: [
              Expanded(
                flex: 2,
                child: Container(
                  color: colorMain.withAlpha(30),
                  padding: EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            DateTime.now().toString().formatDateTime(
                              'dd-MM-yyyy',
                            ),
                          ).color(colorMain).weight(FontWeight.bold).size(18),
                          // Button(
                          //   enable: !_buhlmann.isOnDiving.value,
                          //   onPressed: () {
                          //     _buhlmann.startDive();
                          //   },
                          //   child: Text(
                          //     _buhlmann.isOnDiving.value
                          //         ? 'Diving...'
                          //         : 'Start Dive',
                          //   ).color(Colors.white),
                          // ),
                        ],
                      ).marginOnly(bottom: 10),
                      _buhlmann.isOnDiving.value
                          ? Text(
                              'On Diving...!!',
                            ).color(colorMain).weight(FontWeight.bold)
                          : Text(
                              'Surface Time : ${_surfaceTime == null ? 'First Dive!' : _surfaceTime.toString()}',
                            ).color(colorMain).weight(FontWeight.bold),
                      _horizontalLine(),
                      Text('Depth').color(colorMain).weight(FontWeight.bold),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: 'Descend 0.5m',
                            onPressed: () {
                              _buhlmann.currentDepth.value += 0.5;
                              _textControllerDepth.text = _buhlmann
                                  .currentDepth
                                  .value
                                  .toStringAsFixed(1);
                            },
                            icon: Icon(Icons.thumb_down, color: colorMain),
                          ),
                          InputText(
                            width: 100,
                            controller: _textControllerDepth,
                            textAlign: TextAlign.center,
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'^\d*\.?\d*$'),
                              ),
                            ],
                            maxLines: 1,
                            onFieldSubmitted: (value) {
                              double? depth = double.tryParse(value);
                              if (depth != null) {
                                _buhlmann.currentDepth.value = depth;
                                _textControllerDepth.text = _buhlmann
                                    .currentDepth
                                    .value
                                    .toStringAsFixed(1);
                              } else {
                                _textControllerDepth.text = _buhlmann
                                    .currentDepth
                                    .value
                                    .toStringAsFixed(1);
                              }
                            },
                          ).marginSymmetric(horizontal: 20),
                          IconButton(
                            tooltip: 'Ascend 0.5m',
                            onPressed: () {
                              if (_buhlmann.currentDepth.value <= 0.5) {
                                _buhlmann.currentDepth.value = 0;
                              } else {
                                _buhlmann.currentDepth.value -= 0.5;
                              }
                              _textControllerDepth.text = _buhlmann
                                  .currentDepth
                                  .value
                                  .toStringAsFixed(1);
                            },
                            icon: Icon(Icons.thumb_up, color: colorMain),
                          ),
                        ],
                      ).marginOnly(bottom: 10),
                      _horizontalLine(),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text('EAN').color(colorMain).weight(FontWeight.bold),
                          InputText(
                            width: 100,
                            controller: _textControllerEAN,
                            textAlign: TextAlign.center,
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'^\d{0,2}$'),
                              ),
                            ],
                            maxLines: 1,
                            onFieldSubmitted: (value) {
                              int? ean = int.tryParse(value);
                              if (ean != null && ean >= 21 && ean <= 100) {
                                _buhlmann.setEAN(ean);
                              } else {
                                _textControllerEAN.text =
                                    (_buhlmann.fractionO2 * 100)
                                        .toInt()
                                        .toString();
                              }
                            },
                          ).marginSymmetric(horizontal: 20),
                          Image.asset(
                            'assets/air-tank.png',
                            fit: BoxFit.fitHeight,
                            height: 50,
                          ),
                        ],
                      ).marginOnly(bottom: 10),
                    ],
                  ),
                ),
              ),
              Expanded(
                flex: 3,
                child: Container(
                  padding: EdgeInsets.all(20),
                  child: ListView(
                    children: [
                      Text('Informations')
                          .color(colorMain)
                          .weight(FontWeight.bold)
                          .marginOnly(bottom: 10),
                      Text(
                        'Dive Time : ${_buhlmann.currentDiveTime.value.inMinutes}:${(_buhlmann.currentDiveTime.value.inSeconds % 60).toString().padLeft(2, '0')}',
                      ).color(colorMain).marginOnly(bottom: 5),
                      Text(
                        'NDL : ${_buhlmann.ndl.value.toStringAsFixed(0)} min',
                      ).color(colorMain).marginOnly(bottom: 5),
                      Text(
                        'Safty Stop : ${_buhlmann.saftyStop.value.inMinutes}:${(_buhlmann.saftyStop.value.inSeconds % 60).toString().padLeft(2, '0')}',
                      ).color(colorMain).marginOnly(bottom: 5),
                      Text(
                        'TTS : ${_buhlmann.tts.value} min',
                      ).color(colorMain).marginOnly(bottom: 5),
                      Text(
                        'PO2 : ${_buhlmann.currentPO2.value.toStringAsFixed(2)} bar',
                      ).color(colorMain).marginOnly(bottom: 5),
                      Row(
                        children: [
                          Text(
                            'Depth : ${_buhlmann.currentDepth.value.toStringAsFixed(1)}m',
                          ).color(colorMain).marginOnly(right: 60),
                          Text(
                            'Max Depth : ${_buhlmann.maxDepth.value.toStringAsFixed(1)}m',
                          ).color(colorMain),
                        ],
                      ).marginOnly(bottom: 5),
                      _horizontalLine(),
                      Text('DECO (Decompression) status')
                          .color(
                            colorMain.withAlpha(
                              _buhlmann.needDeco.value ? 255 : 100,
                            ),
                          )
                          .weight(FontWeight.bold)
                          .marginOnly(bottom: 10),
                      Text('Ceiling : ${_buhlmann.decoStopDepth.value}m')
                          .color(
                            colorMain.withAlpha(
                              _buhlmann.needDeco.value ? 255 : 100,
                            ),
                          )
                          .marginOnly(bottom: 5),
                      Text('Stop Time : ${_buhlmann.decoStopTime.value} min')
                          .color(
                            colorMain.withAlpha(
                              _buhlmann.needDeco.value ? 255 : 100,
                            ),
                          )
                          .marginOnly(bottom: 5),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  FutureOr<void> afterFirstLayout(BuildContext context) {
    setState(() {
      _surfaceTime = Buhlmann.getSurfaceTime();
    });
  }

  Widget _horizontalLine() {
    return Container(
      height: 1,
      color: colorMain,
    ).marginOnly(bottom: 10, top: 10);
  }
}
