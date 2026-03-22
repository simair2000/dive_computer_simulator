import 'dart:async';
import 'package:after_layout/after_layout.dart';
import 'package:dive_computer_flutter/aPref.dart';
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

  bool _showTissueLoadingDetails = true;
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
        title: Text('Diving Simulator').color(Colors.white),
        leading: const Icon(Icons.scuba_diving, color: Colors.white, size: 30),
        backgroundColor: colorMain,
        actions: [
          IconButton(
            tooltip: 'Go to the eRDPml Calculator',
            onPressed: () {
              context.goNamed(RoutePage.eRDP.name);
            },
            icon: const Icon(Icons.calculate, color: Colors.white),
          ),
          IconButton(
            tooltip: 'Go to the diving planner',
            onPressed: () {
              context.goNamed(RoutePage.planner.name);
            },
            icon: const Icon(Icons.assignment, color: Colors.white),
          ),
          IconButton(
            tooltip: 'Go to the settings',
            onPressed: () {
              context.pushNamed(RoutePage.settings.name);
            },
            icon: const Icon(Icons.settings, color: Colors.white),
          ),
          IconButton(
            tooltip: 'About',
            onPressed: () {
              showGetDialog(
                'About Dive Simulator',
                '- This is a dive computer simulator based on the ZHL-16C algorithm.\n- Supports Trimix (He) diving.\n- The NDL and TTS will be calculated in real-time.\n- Please use this simulator responsibly.',
              );
            },
            icon: const Icon(Icons.help, color: Colors.white),
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
          _buhlmann.updateTick,
          _buhlmann.surfaceTime,
          _buhlmann.diveCount,
          _buhlmann.currentCNS,
          _buhlmann.currentPressureGroup,
        ]),
        builder: (context, child) {
          // ==============================================================
          // 1. 왼쪽 패널 (제어부) 위젯 리스트
          // ==============================================================
          List<Widget> leftPanelContents = [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  DateTime.now().toString().formatDateTime('dd/MM/yyyy'),
                ).color(colorMain).weight(FontWeight.bold).size(18),
                Text(
                  'Dive #${_buhlmann.diveCount.value}',
                ).color(colorMain).weight(FontWeight.bold).size(18),
              ],
            ).marginOnly(bottom: 10),
            // 배속 설정 부분 (Wrap을 사용해 화면이 좁을 때 줄바꿈 처리)
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              runSpacing: 5,
              children: [
                Text('Speed : ')
                    .color(colorMain)
                    .weight(FontWeight.bold)
                    .marginOnly(right: 10),
                Button(
                  width: 60,
                  color: _currentSpeed == 1
                      ? colorMain
                      : Colors.grey.withAlpha(50),
                  onPressed: () => _setSimulationSpeed(1),
                  child: Text(
                    '1x',
                  ).color(_currentSpeed == 1 ? Colors.white : colorMain),
                ).marginOnly(right: 5),
                Button(
                  width: 60,
                  color: _currentSpeed == 5
                      ? colorMain
                      : Colors.grey.withAlpha(50),
                  onPressed: () => _setSimulationSpeed(5),
                  child: Text(
                    '5x',
                  ).color(_currentSpeed == 5 ? Colors.white : colorMain),
                ).marginOnly(right: 5),
                Button(
                  width: 60,
                  color: _currentSpeed == 10
                      ? colorMain
                      : Colors.grey.withAlpha(50),
                  onPressed: () => _setSimulationSpeed(10),
                  child: Text(
                    '10x',
                  ).color(_currentSpeed == 10 ? Colors.white : colorMain),
                ).marginOnly(right: 5),
                Button(
                  width: 60,
                  color: _currentSpeed == 60
                      ? colorMain
                      : Colors.grey.withAlpha(50),
                  onPressed: () => _setSimulationSpeed(60),
                  child: Text(
                    '60x',
                  ).color(_currentSpeed == 60 ? Colors.white : colorMain),
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
            horizontalLine(),
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
                        : _currentMoveStatus = DiveMoveStatus.onDescending;
                  },
                  icon: Icon(
                    _currentMoveStatus == DiveMoveStatus.onStop
                        ? Icons.thumb_down
                        : Icons.front_hand,
                    color: colorMain,
                  ),
                ),
                Expanded(
                  child: InputText(
                    controller: _textControllerDepth,
                    textAlign: TextAlign.center,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$')),
                    ],
                    maxLines: 1,
                    onFieldSubmitted: (value) {
                      double? depth = double.tryParse(value);
                      if (depth != null) {
                        _buhlmann.currentDepth.value = depth;
                      }
                      _textControllerDepth.text = _buhlmann.currentDepth.value
                          .toStringAsFixed(1);
                    },
                  ).marginSymmetric(horizontal: 10),
                ),
                IconButton(
                  tooltip: _currentMoveStatus != DiveMoveStatus.onStop
                      ? 'Stop'
                      : 'Ascend',
                  onPressed: () {
                    _currentMoveStatus != DiveMoveStatus.onStop
                        ? _currentMoveStatus = DiveMoveStatus.onStop
                        : _currentMoveStatus = DiveMoveStatus.onAscending;
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
            horizontalLine(),
            Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                Text('PPO2 Bottom: ${APref.getData(AprefKey.PPO2_BOTTOM)}')
                    .color(colorMain)
                    .weight(FontWeight.bold)
                    .marginOnly(right: 20),
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
                  child: Text('O2 %').color(colorMain).weight(FontWeight.bold),
                ),
                Expanded(
                  child: InputText(
                    controller: _textControllerEAN,
                    textAlign: TextAlign.center,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'^\d{0,3}$')),
                    ],
                    maxLines: 1,
                    onFieldSubmitted: (value) {
                      int ean = int.tryParse(value) ?? 21;
                      int he = int.tryParse(_textControllerHe.text) ?? 0;
                      if (ean >= 0 && (ean + he) <= 100) {
                        _buhlmann.setGas(ean, he);
                      } else {
                        _textControllerEAN.text = (_buhlmann.fractionO2 * 100)
                            .toInt()
                            .toString();
                      }
                    },
                  ).marginOnly(right: 10),
                ),
                SizedBox(
                  width: 40,
                  child: Text('He %').color(colorMain).weight(FontWeight.bold),
                ),
                Expanded(
                  child: InputText(
                    controller: _textControllerHe,
                    textAlign: TextAlign.center,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'^\d{0,2}$')),
                    ],
                    maxLines: 1,
                    onFieldSubmitted: (value) {
                      int he = int.tryParse(value) ?? 0;
                      int ean = int.tryParse(_textControllerEAN.text) ?? 21;
                      if (he >= 0 && (ean + he) <= 100) {
                        _buhlmann.setGas(ean, he);
                      } else {
                        _textControllerHe.text = (_buhlmann.fractionHe * 100)
                            .toInt()
                            .toString();
                      }
                    },
                  ).marginOnly(right: 10),
                ),
                Image.asset(
                  'assets/air-tank.png',
                  fit: BoxFit.fitHeight,
                  height: 50,
                ),
              ],
            ).marginOnly(bottom: 10),
            horizontalLine(),
          ];

          // ==============================================================
          // 2. 오른쪽 패널 (정보부) 위젯 리스트
          // ==============================================================
          List<Widget> rightPanelContents = [
            Text(
              'Informations',
            ).color(colorMain).weight(FontWeight.bold).marginOnly(bottom: 10),
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
            Text('CNS : ${_buhlmann.currentCNS.value.toStringAsFixed(1)} %')
                .color(_buhlmann.currentCNS.value > 80 ? Colors.red : colorMain)
                .weight(
                  _buhlmann.currentCNS.value > 80
                      ? FontWeight.bold
                      : FontWeight.normal,
                )
                .marginOnly(bottom: 5),
            Row(
              children: [
                Text('Pressure Group : ').color(colorMain),
                Text(_buhlmann.currentPressureGroup.value)
                    .color(
                      _buhlmann.currentPressureGroup.value.startsWith('OOR')
                          ? Colors.red
                          : colorMain,
                    )
                    .size(15),
              ],
            ).marginOnly(bottom: 5),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Depth : ${_buhlmann.currentDepth.value.toStringAsFixed(1)}m',
                  ).color(colorMain),
                ),
                Expanded(
                  child: Text(
                    'Max Depth : ${_buhlmann.maxDepth.value.toStringAsFixed(1)}m',
                  ).color(colorMain),
                ),
              ],
            ).marginOnly(bottom: 5),
            horizontalLine(),
            Text(
              'DECO (Decompression) status',
            ).color(colorMain).weight(FontWeight.bold).marginOnly(bottom: 10),
            Text(
              'Ceiling : ${_buhlmann.decoStopDepth.value}m',
            ).color(colorMain).marginOnly(bottom: 5),
            Text(
              'Deep Stop : ${_buhlmann.decoStopTime.value} min',
            ).color(colorMain).marginOnly(bottom: 5),
            horizontalLine(),
            Text(
              'Tissue Saturation (N2 + He Loadings)',
            ).color(colorMain).weight(FontWeight.bold).marginOnly(bottom: 10),
            LayoutBuilder(
              builder: (context, constraints) {
                double maxWidth = constraints.maxWidth;
                const double maxDisplayPressure = 4.0;

                return Column(
                  children: List.generate(_buhlmann.currentLoadings.length, (
                    index,
                  ) {
                    double pTotal =
                        _buhlmann.currentLoadings[index] +
                        _buhlmann.currentHeLoadings[index];
                    double barWidth = (pTotal / maxDisplayPressure) * maxWidth;
                    if (barWidth > maxWidth) barWidth = maxWidth;
                    if (barWidth < 5) barWidth = 5;

                    return Row(
                      children: [
                        SizedBox(
                          width: 25,
                          child: Text(
                            '${index + 1}',
                          ).size(10).color(colorMain.withOpacity(0.7)),
                        ),
                        Expanded(
                          child: Stack(
                            children: [
                              Container(
                                height: 10,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(2),
                                  gradient: const LinearGradient(
                                    colors: [
                                      Colors.green,
                                      Colors.yellow,
                                      Colors.yellow,
                                      Colors.red,
                                    ],
                                    stops: [0, 0.4, 0.9, 1.0],
                                  ),
                                ),
                              ),
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 300),
                                height: 10,
                                width: barWidth,
                                decoration: BoxDecoration(
                                  color: Colors.blueAccent,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_showTissueLoadingDetails)
                          Container(
                            width: 45,
                            alignment: Alignment.centerRight,
                            child: Text(
                              pTotal.toStringAsFixed(2),
                            ).size(11).color(colorMain),
                          ),
                      ],
                    );
                  }),
                );
              },
            ),
          ];

          // ==============================================================
          // 3. LayoutBuilder를 사용한 반응형 화면 렌더링
          // ==============================================================
          return LayoutBuilder(
            builder: (context, constraints) {
              bool isWideScreen = constraints.maxWidth > 850;

              if (isWideScreen) {
                // [PC / 태블릿] 가로 모드 (Row 사용)
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 2,
                      child: Container(
                        color: colorMain.withAlpha(30),
                        padding: const EdgeInsets.all(20),
                        child: ListView(children: leftPanelContents),
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Container(
                        color: _buhlmann.needDeco.value
                            ? Colors.red.withAlpha(70)
                            : Colors.transparent,
                        padding: const EdgeInsets.all(20),
                        child: ListView(children: rightPanelContents),
                      ),
                    ),
                  ],
                );
              } else {
                // [모바일] 세로 모드 (SingleChildScrollView + Column 사용)
                return SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        color: colorMain.withAlpha(30),
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: leftPanelContents,
                        ),
                      ),
                      Container(
                        color: _buhlmann.needDeco.value
                            ? Colors.red.withAlpha(70)
                            : Colors.transparent,
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: rightPanelContents,
                        ),
                      ),
                    ],
                  ),
                );
              }
            },
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
            _buhlmann.currentDepth.value -=
                (APref.getData(AprefKey.AscentSpeed) / 60);
          }
          _textControllerDepth.text = _buhlmann.currentDepth.value
              .toStringAsFixed(1);
          break;
        case DiveMoveStatus.onDescending:
          _buhlmann.currentDepth.value +=
              (APref.getData(AprefKey.DescentSpeed) / 60);
          _textControllerDepth.text = _buhlmann.currentDepth.value
              .toStringAsFixed(1);
          break;
        case DiveMoveStatus.onStop:
          break;
      }
    });
  }
}
