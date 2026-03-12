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
  final TextEditingController _textControllerHe = TextEditingController(
    text: '0',
  ); // 헬륨 컨트롤러 추가

  bool _showTissueLoadingDetails = false;
  DiveMoveStatus _currentMoveStatus = DiveMoveStatus.onStop;

  Timer? _moveTimer;
  int _currentSpeed = 1; // 현재 배속 상태 변수

  @override
  void initState() {
    _buhlmann.startDive();
    super.initState();
  }

  @override
  void dispose() {
    _moveTimer?.cancel();
    _textControllerEAN.dispose();
    _textControllerHe.dispose();
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
                '- This is a dive computer simulator based on the ZHL-16C algorithm.\n- Supports Trimix (He) diving.\n- The NDL and TTS will be calculated in real-time.\n- Please use this simulator responsibly.',
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
          _buhlmann.currentCNS,
          _buhlmann.currentPressureGroup,
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
                        ],
                      ).marginOnly(bottom: 10),
                      Row(
                        children: [
                          Text('Speed : ')
                              .color(colorMain)
                              .weight(FontWeight.bold)
                              .marginOnly(right: 10),
                          Button(
                            width: 60,
                            child: Text('1x').color(
                              _currentSpeed == 1 ? Colors.white : colorMain,
                            ),
                            color: _currentSpeed == 1
                                ? colorMain
                                : Colors.grey.withAlpha(50),
                            onPressed: () => _setSimulationSpeed(1),
                          ).marginOnly(right: 5),
                          Button(
                            width: 60,
                            child: Text('5x').color(
                              _currentSpeed == 5 ? Colors.white : colorMain,
                            ),
                            color: _currentSpeed == 5
                                ? colorMain
                                : Colors.grey.withAlpha(50),
                            onPressed: () => _setSimulationSpeed(5),
                          ).marginOnly(right: 5),
                          Button(
                            width: 60,
                            child: Text('10x').color(
                              _currentSpeed == 10 ? Colors.white : colorMain,
                            ),
                            color: _currentSpeed == 10
                                ? colorMain
                                : Colors.grey.withAlpha(50),
                            onPressed: () => _setSimulationSpeed(10),
                          ).marginOnly(right: 5),
                          Button(
                            width: 60,
                            child: Text('60x').color(
                              _currentSpeed == 60 ? Colors.white : colorMain,
                            ),
                            color: _currentSpeed == 60
                                ? colorMain
                                : Colors.grey.withAlpha(50),
                            onPressed: () => _setSimulationSpeed(
                              60,
                            ), // 60배속: 현실 1초 = 시뮬레이션 1분
                          ),
                        ],
                      ).marginOnly(bottom: 10),
                      _buhlmann.isOnDiving.value
                          ? Text(
                              'Dive Time : ${_buhlmann.currentDiveTime.value.hhmmss()}',
                            ).color(colorMain).weight(FontWeight.bold)
                          : Text(
                              'Surface Interval : ${_buhlmann.surfaceTime.value.hhmmss()}',
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
                            tooltip: _currentMoveStatus != DiveMoveStatus.onStop
                                ? 'Stop'
                                : 'Descend',
                            onPressed: () {
                              _currentMoveStatus != DiveMoveStatus.onStop
                                  ? _currentMoveStatus = DiveMoveStatus.onStop
                                  : _currentMoveStatus =
                                        DiveMoveStatus.onDescending;
                            },
                            icon: Icon(
                              _currentMoveStatus == DiveMoveStatus.onStop
                                  ? Icons.thumb_down
                                  : Icons.front_hand,
                              color: colorMain,
                            ),
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
                            tooltip: _currentMoveStatus != DiveMoveStatus.onStop
                                ? 'Stop'
                                : 'Ascend',
                            onPressed: () {
                              _currentMoveStatus != DiveMoveStatus.onStop
                                  ? _currentMoveStatus = DiveMoveStatus.onStop
                                  : _currentMoveStatus =
                                        DiveMoveStatus.onAscending;
                            },
                            icon: Icon(
                              _currentMoveStatus == DiveMoveStatus.onStop
                                  ? Icons.thumb_up
                                  : Icons.front_hand,
                              color: colorMain,
                            ),
                          ),
                        ],
                      ).marginOnly(bottom: 10),
                      _horizontalLine(),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 50,
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

                      // Trimix O2 및 He 설정
                      Row(
                        mainAxisAlignment: MainAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 40,
                            child: Text(
                              'O2 %',
                            ).color(colorMain).weight(FontWeight.bold),
                          ),
                          InputText(
                            width: 60,
                            controller: _textControllerEAN,
                            textAlign: TextAlign.center,
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'^\d{0,2}$'),
                              ),
                            ],
                            maxLines: 1,
                            onFieldSubmitted: (value) {
                              int ean = int.tryParse(value) ?? 21;
                              int he =
                                  int.tryParse(_textControllerHe.text) ?? 0;
                              if (ean >= 0 && (ean + he) <= 100) {
                                _buhlmann.setGas(ean, he);
                              } else {
                                _textControllerEAN.text =
                                    (_buhlmann.fractionO2 * 100)
                                        .toInt()
                                        .toString();
                              }
                            },
                          ).marginOnly(right: 20),
                          SizedBox(
                            width: 40,
                            child: Text(
                              'He %',
                            ).color(colorMain).weight(FontWeight.bold),
                          ),
                          InputText(
                            width: 60,
                            controller: _textControllerHe,
                            textAlign: TextAlign.center,
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'^\d{0,2}$'),
                              ),
                            ],
                            maxLines: 1,
                            onFieldSubmitted: (value) {
                              int he = int.tryParse(value) ?? 0;
                              int ean =
                                  int.tryParse(_textControllerEAN.text) ?? 21;
                              if (he >= 0 && (ean + he) <= 100) {
                                _buhlmann.setGas(ean, he);
                              } else {
                                _textControllerHe.text =
                                    (_buhlmann.fractionHe * 100)
                                        .toInt()
                                        .toString();
                              }
                            },
                          ).marginOnly(right: 20),
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
                      Text(
                            'CNS : ${_buhlmann.currentCNS.value.toStringAsFixed(1)} %',
                          )
                          .color(
                            _buhlmann.currentCNS.value > 80
                                ? Colors.red
                                : colorMain,
                          ) // 80% 이상이면 빨간색 경고
                          .weight(
                            _buhlmann.currentCNS.value > 80
                                ? FontWeight.bold
                                : FontWeight.normal,
                          )
                          .marginOnly(bottom: 5),
                      // PADI RDP 압력군 (Pressure Group) 뱃지
                      Row(
                        children: [
                          Text('Pressure Group : ').color(colorMain),
                          Text(_buhlmann.currentPressureGroup.value)
                              .color(
                                _buhlmann.currentPressureGroup.value.startsWith(
                                      'OOR',
                                    )
                                    ? Colors.red
                                    : colorMain,
                              )
                              .size(15),
                        ],
                      ).marginOnly(bottom: 5),
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
                          Text('Tissue Saturation (N2 + He Loadings)')
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
                                if (GetPlatform.isWindows) {
                                  windowManager.setSize(
                                    Size(
                                      900,
                                      _showTissueLoadingDetails ? 950 : 650,
                                    ),
                                  );
                                }
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
                                  // 총 기체 압력 = 질소 압력 + 헬륨 압력
                                  double pTotal =
                                      _buhlmann.currentLoadings[index] +
                                      _buhlmann.currentHeLoadings[index];
                                  double width = pTotal * 150;
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
                                          pTotal.toStringAsFixed(2),
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
  Future<void> afterFirstLayout(BuildContext context) async {
    _setSimulationSpeed(1);
  }

  void _setSimulationSpeed(int speed) {
    setState(() {
      _currentSpeed = speed;
    });

    // 1. 알고리즘 배속 적용
    _buhlmann.setSpeed(speed);

    // 2. 수심 상승/하강 타이머도 배속 적용
    _moveTimer?.cancel();
    _moveTimer = Timer.periodic(Duration(milliseconds: 1000 ~/ speed), (timer) {
      switch (_currentMoveStatus) {
        case DiveMoveStatus.onAscending:
          if (_buhlmann.currentDepth.value <= 0.1) {
            _buhlmann.currentDepth.value = 0;
            _currentMoveStatus = DiveMoveStatus.onStop; // 수면 도착 시 정지
          } else {
            _buhlmann.currentDepth.value -= 0.1;
          }
          _textControllerDepth.text = _buhlmann.currentDepth.value
              .toStringAsFixed(1);
          break;
        case DiveMoveStatus.onDescending:
          _buhlmann.currentDepth.value += 0.3;
          _textControllerDepth.text = _buhlmann.currentDepth.value
              .toStringAsFixed(1);
          break;
        case DiveMoveStatus.onStop:
          break;
      }
    });
  }

  Widget _horizontalLine() {
    return Container(
      height: 1,
      color: colorMain,
    ).marginOnly(bottom: 10, top: 10);
  }
}
