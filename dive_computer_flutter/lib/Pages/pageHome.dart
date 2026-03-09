import 'dart:async';

import 'package:after_layout/after_layout.dart';
import 'package:dive_computer_flutter/buhlmann.dart';
import 'package:dive_computer_flutter/define.dart';
import 'package:dive_computer_flutter/extensions.dart';
import 'package:dive_computer_flutter/router.dart';
import 'package:dive_computer_flutter/styles.dart';
import 'package:dive_computer_flutter/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:go_router/go_router.dart';
import 'package:window_manager/window_manager.dart';

class PageHome extends StatefulWidget {
  const PageHome({super.key});

  @override
  State<PageHome> createState() => _PageHomeState();
}

class _PageHomeState extends State<PageHome> with AfterLayoutMixin {
  final Buhlmann _buhlmann = Buhlmann();

  final TextEditingController _textControllerDepth = TextEditingController();
  final TextEditingController _textControllerEAN = TextEditingController(
    text: '21',
  );

  bool _showTissueLoadingDetails = false;

  @override
  void initState() {
    // _textControllerDepth.addListener(() {
    //   double? depth = double.tryParse(_textControllerDepth.text);
    //   if (depth != null && 1.5 <= depth) {
    //     _buhlmann.startDive();
    //   }
    // });
    _buhlmann.startDive();
    super.initState();
  }

  @override
  void dispose() {
    _textControllerEAN.dispose();
    _textControllerDepth.dispose();
    _buhlmann.dispose();
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
              context.pushNamed(RoutePage.settings.name);
            },
            icon: Icon(Icons.settings, color: Colors.white),
          ),
          IconButton(
            onPressed: () {
              showGetDialog(
                'About',
                '- This is a dive computer simulator based on the ZHL-16C algorithm.\n- You can simulate your dive by adjusting the depth.\n- The NDL (No Decompression Limit) and TTS (Time To Surface) will be calculated in real-time based on your current depth and dive time.\n- If you exceed the NDL, the simulator will indicate that you need to perform decompression stops.\n- Please use this simulator responsibly and always follow safe diving practices in real life.',
              );
            },
            icon: Icon(Icons.help, color: Colors.white),
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
          _buhlmann.gfHighNotifier,
          _buhlmann.gfLowNotifier,
          _buhlmann.ppo2,
          _buhlmann.updateTick,
          _buhlmann.surfaceTime,
          _buhlmann.diveCount,
        ]),
        builder: (context, child) {
          return Row(
            children: [
              Expanded(
                flex: 2,
                child: Container(
                  color: colorMain.withAlpha(30),
                  padding: EdgeInsets.all(20),
                  child: ListView(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            DateTime.now().toString().formatDateTime(
                              'dd/MM/yyyy',
                            ),
                          ).color(colorMain).weight(FontWeight.bold).size(18),
                          Text(
                            'Dive #${_buhlmann.diveCount.value}',
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
                              'Dive Time : ${_buhlmann.currentDiveTime.value.inMinutes}:${(_buhlmann.currentDiveTime.value.inSeconds % 60).toString().padLeft(2, '0')}',
                            ).color(colorMain).weight(FontWeight.bold)
                          : Text(
                              'Surface Time : ${_buhlmann.surfaceTime.value == Duration.zero ? 'First Dive!' : '${_buhlmann.surfaceTime.value.inMinutes}:${(_buhlmann.surfaceTime.value.inSeconds % 60).toString().padLeft(2, '0')}'}',
                            ).color(colorMain).weight(FontWeight.bold),
                      _horizontalLine(),
                      SizedBox(
                        width: double.infinity,
                        child: Text('Depth')
                            .color(colorMain)
                            .weight(FontWeight.bold)
                            .align(TextAlign.center)
                            .marginOnly(bottom: 10),
                      ),
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
                        mainAxisAlignment: MainAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 40,
                            child: Text(
                              'PPO2',
                            ).color(colorMain).weight(FontWeight.bold),
                          ).marginOnly(right: 20),
                          Button(
                            child: Text(
                              '${_buhlmann.ppo2.value}',
                            ).color(Colors.white),

                            onPressed: () {
                              _buhlmann.ppo2.value = _buhlmann.ppo2.value == 1.4
                                  ? 1.6
                                  : 1.4;
                            },
                          ).marginOnly(right: 40),
                          Text(
                            'MOD : ${_buhlmann.mod.floor().toStringAsFixed(1)}m',
                          ).color(colorMain).weight(FontWeight.bold),
                        ],
                      ).marginOnly(bottom: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 40,
                            child: Text(
                              'EAN',
                            ).color(colorMain).weight(FontWeight.bold),
                          ),
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
                      _horizontalLine(),
                      Row(
                        children: [
                          Text(
                            'GF High',
                          ).color(colorMain).weight(FontWeight.bold),
                          Slider(
                            activeColor: colorMain,
                            value: _buhlmann.gfHighNotifier.value,
                            onChanged: (value) {
                              if (value <= _buhlmann.gfLowNotifier.value) {
                                if (value < 11) value = 11;
                                _buhlmann.gfLowNotifier.value = value - 1;
                                _buhlmann.gfLow = (value - 1) / 100.0;
                              }
                              _buhlmann.gfHighNotifier.value = value;
                              _buhlmann.gfHigh = value / 100.0;
                            },
                            min: 10,
                            max: 95,
                          ),
                          Text(
                            '${_buhlmann.gfHighNotifier.value.toInt()}%',
                          ).color(colorMain).weight(FontWeight.bold),
                        ],
                      ),
                      Row(
                        children: [
                          SizedBox(
                            width: 55,
                            child: Text(
                              'GF Low',
                            ).color(colorMain).weight(FontWeight.bold),
                          ),
                          Slider(
                            activeColor: colorMain,
                            value: _buhlmann.gfLowNotifier.value,
                            onChanged: (value) {
                              if (value >= _buhlmann.gfHighNotifier.value) {
                                if (value > 94) value = 94;
                                _buhlmann.gfHighNotifier.value = value + 1;
                                _buhlmann.gfHigh = (value + 1) / 100.0;
                              }
                              _buhlmann.gfLowNotifier.value = value;
                              _buhlmann.gfLow = value / 100.0;
                            },
                            min: 10,
                            max: 95,
                          ),
                          Text(
                            '${_buhlmann.gfLowNotifier.value.toInt()}%',
                          ).color(colorMain).weight(FontWeight.bold),
                        ],
                      ),
                      Text('Conservatism Settings')
                          .color(colorMain)
                          .weight(FontWeight.bold)
                          .marginOnly(bottom: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Button(
                            tooltip:
                                'Most conservative setting with longest decompression times',
                            child: Text('SAFE').color(Colors.white),
                            onPressed: () {
                              _buhlmann.gfHighNotifier.value = 70;
                              _buhlmann.gfLowNotifier.value = 30;
                              _buhlmann.gfHigh = 0.7;
                              _buhlmann.gfLow = 0.3;
                            },
                            color: colorMain,
                          ),
                          Button(
                            child: Text('MODERATE').color(Colors.white),
                            onPressed: () {
                              _buhlmann.gfHighNotifier.value = 85;
                              _buhlmann.gfLowNotifier.value = 40;
                              _buhlmann.gfHigh = 0.85;
                              _buhlmann.gfLow = 0.4;
                            },
                            color: colorMain,
                            tooltip:
                                'Moderate conservatism with a balance between safety and efficiency',
                          ),
                          Button(
                            tooltip:
                                'Shortest stop time but higher risk of DCS',
                            child: Text('AGGRESSIVE').color(Colors.white),
                            onPressed: () {
                              _buhlmann.gfHighNotifier.value = 95;
                              _buhlmann.gfLowNotifier.value = 50;
                              _buhlmann.gfHigh = 0.95;
                              _buhlmann.gfLow = 0.5;
                            },
                            color: colorMain,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                flex: 3,
                child: Container(
                  color: _buhlmann.needDeco.value
                      ? Colors.red.withAlpha(70)
                      : Colors.transparent,
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
                      _horizontalLine(),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Tissue Saturation (N2 Loadings)')
                              .color(colorMain)
                              .weight(FontWeight.bold)
                              .marginOnly(bottom: 10),
                          Button(
                            child: Text(
                              _showTissueLoadingDetails
                                  ? 'Hide details'
                                  : 'Show details',
                            ).color(Colors.white),
                            onPressed: () {
                              setState(() {
                                _showTissueLoadingDetails =
                                    !_showTissueLoadingDetails;
                                windowManager.setSize(
                                  Size(
                                    900,
                                    _showTissueLoadingDetails ? 950 : 620,
                                  ),
                                );
                              });
                            },
                          ),
                        ],
                      ).marginOnly(bottom: 5),
                      Builder(
                        builder: (context) {
                          return Container(
                            padding: EdgeInsets.symmetric(vertical: 5),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Colors.green,
                                  Colors.yellow,
                                  Colors.yellow,
                                  Colors.red,
                                ],
                                stops: [0, 0.4, 0.9, 1.0],
                              ),
                            ),
                            child: Column(
                              children: List.generate(
                                _buhlmann.currentLoadings.length,
                                (index) {
                                  double width =
                                      _buhlmann.currentLoadings[index] * 150;
                                  if (450 < width) width = 450;
                                  return Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Container(
                                        color: Colors.black,
                                        height: 1,
                                        width: width,
                                      ),
                                      Visibility(
                                        visible: _showTissueLoadingDetails,
                                        child: Text(
                                          _buhlmann.currentLoadings[index]
                                              .toStringAsFixed(2),
                                        ).color(Colors.white),
                                      ),
                                    ],
                                  ).marginOnly(bottom: 5);
                                },
                              ),
                            ),
                          );
                        },
                      ),
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
  Future<void> afterFirstLayout(BuildContext context) async {}

  Widget _horizontalLine() {
    return Container(
      height: 1,
      color: colorMain,
    ).marginOnly(bottom: 10, top: 10);
  }
}
