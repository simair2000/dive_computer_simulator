import 'package:dive_computer_flutter/aPref.dart';
import 'package:dive_computer_flutter/define.dart';
import 'package:dive_computer_flutter/dive_planner.dart';
import 'package:dive_computer_flutter/extensions.dart';
import 'package:dive_computer_flutter/styles.dart';
import 'package:dive_computer_flutter/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get_utils/src/extensions/widget_extensions.dart';
import 'package:get/get_utils/src/platform/platform.dart';
import 'package:window_manager/window_manager.dart';

class PageSettings extends StatefulWidget {
  const PageSettings({super.key});

  @override
  State<PageSettings> createState() => _PageSettingsState();
}

class _PageSettingsState extends State<PageSettings> {
  final _settingGeneral = 'GENERAL_SETTING';
  final _settingDiving = 'DIVING_SETTING';

  var _currentView;

  final TextEditingController _textControllerAscent = TextEditingController();
  final TextEditingController _textControllerDescent = TextEditingController();

  var gfHighNotifier = ValueNotifier<double>(85);
  var gfLowNotifier = ValueNotifier<double>(40);

  double ppo2 = 1.4;
  double get mod => (((ppo2 / 0.21) * 10) - 10);

  @override
  void initState() {
    ppo2 = APref.getData(AprefKey.PPO2);
    gfHighNotifier.value = APref.getData(AprefKey.GF_HIGH) * 100;
    gfLowNotifier.value = APref.getData(AprefKey.GF_LOW) * 100;
    _currentView = _settingDiving;
    super.initState();
  }

  @override
  void dispose() {
    _textControllerDescent.dispose();
    _textControllerAscent.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Settings').color(Colors.white),
        iconTheme: IconThemeData(color: Colors.white),
        backgroundColor: colorMain,
      ),
      body: Row(
        children: [
          Expanded(
            flex: 1,
            child: Container(
              color: colorMain.withAlpha(30),

              child: ListView(
                children: [
                  ListTile(
                    tileColor: _currentView == _settingDiving
                        ? colorMain.withAlpha(100)
                        : Colors.transparent,
                    title: Text('Dive settings')
                        .weight(
                          _currentView == _settingDiving
                              ? FontWeight.bold
                              : FontWeight.normal,
                        )
                        .color(
                          _currentView == _settingDiving
                              ? Colors.white
                              : colorMain,
                        ),
                    onTap: () {
                      setState(() {
                        _currentView = _settingDiving;
                      });
                    },
                  ),
                  ListTile(
                    tileColor: _currentView == _settingGeneral
                        ? colorMain.withAlpha(150)
                        : Colors.transparent,
                    title: Text('General')
                        .weight(
                          _currentView == _settingGeneral
                              ? FontWeight.bold
                              : FontWeight.normal,
                        )
                        .color(
                          _currentView == _settingGeneral
                              ? Colors.white
                              : colorMain,
                        ),
                    onTap: () {
                      setState(() {
                        _currentView = _settingGeneral;
                      });
                    },
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: AnimatedBuilder(
              animation: Listenable.merge([gfHighNotifier, gfLowNotifier]),
              builder: (context, child) {
                return Container(
                  padding: EdgeInsets.all(20),
                  child: _currentView == _settingGeneral
                      ? _viewSettingGeneral()
                      : _viewSettingDiving(),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _viewSettingGeneral() {
    return ListView(
      children: [
        Visibility(
          visible: GetPlatform.isWindows,
          child: CheckboxListTile(
            controlAffinity: ListTileControlAffinity.leading,
            activeColor: colorMain,
            title: Text('Window always on top').color(colorMain),
            value: APref.getData(AprefKey.ALWAYS_ON_TOP),
            onChanged: (value) {
              setState(() {
                APref.setData(AprefKey.ALWAYS_ON_TOP, value);
                if (GetPlatform.isWindows) {
                  windowManager.setAlwaysOnTop(value ?? false);
                }
              });
            },
          ),
        ),
      ],
    );
  }

  Widget _viewSettingDiving() {
    _textControllerAscent.text = '${APref.getData(AprefKey.AscentSpeed)}';
    _textControllerDescent.text = '${APref.getData(AprefKey.DescentSpeed)}';
    return ListView(
      children: [
        ListTile(
          title: Text(
            'Descent Speed (m/min)',
          ).weight(FontWeight.bold).color(colorMain),

          trailing: InputText(
            width: 150,
            controller: _textControllerDescent,
            textAlign: TextAlign.center,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$')),
            ],
            maxLines: 1,
            onFieldSubmitted: (value) {
              if (textIsNotEmpty(_textControllerDescent.text)) {
                APref.setData(
                  AprefKey.DescentSpeed,
                  double.parse(_textControllerDescent.text),
                );
              }
              setState(() {});
            },
          ),
        ),
        ListTile(
          title: Text(
            'Ascent Speed (m/min)',
          ).weight(FontWeight.bold).color(colorMain),
          trailing: InputText(
            width: 150,
            controller: _textControllerAscent,
            textAlign: TextAlign.center,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$')),
            ],
            maxLines: 1,
            onFieldSubmitted: (value) {
              if (textIsNotEmpty(_textControllerAscent.text)) {
                APref.setData(
                  AprefKey.AscentSpeed,
                  double.parse(_textControllerAscent.text),
                );
              }
              setState(() {});
            },
          ),
        ),
        Divider(),
        Row(
          children: [
            Text('GF High').color(colorMain).weight(FontWeight.bold),
            Slider(
              activeColor: colorMain,
              value: gfHighNotifier.value,
              onChanged: (value) {
                if (value <= gfLowNotifier.value) {
                  if (value < 11) value = 11;
                  gfLowNotifier.value = value - 1;
                  APref.setData(AprefKey.GF_LOW, (value - 1) / 100.0);
                }
                gfHighNotifier.value = value;
                APref.setData(AprefKey.GF_HIGH, value / 100.0);
              },
              min: 10,
              max: 95,
            ),
            Text(
              '${gfHighNotifier.value.toInt()}%',
            ).color(colorMain).weight(FontWeight.bold),
          ],
        ),
        Row(
          children: [
            SizedBox(
              width: 55,
              child: Text('GF Low').color(colorMain).weight(FontWeight.bold),
            ),
            Slider(
              activeColor: colorMain,
              value: gfLowNotifier.value,
              onChanged: (value) {
                if (value >= gfHighNotifier.value) {
                  if (value > 94) value = 94;
                  gfHighNotifier.value = value + 1;
                  APref.setData(AprefKey.GF_HIGH, (value + 1) / 100.0);
                }
                gfLowNotifier.value = value;
                APref.setData(AprefKey.GF_LOW, value / 100.0);
              },
              min: 10,
              max: 95,
            ),
            Text(
              '${gfLowNotifier.value.toInt()}%',
            ).color(colorMain).weight(FontWeight.bold),
          ],
        ),
        Text(
          'Conservatism Settings',
        ).color(colorMain).weight(FontWeight.bold).marginOnly(bottom: 10),
        Row(
          children: [
            Button(
              tooltip:
                  'Most conservative setting with longest decompression times',
              child: Text('SAFE').color(Colors.white),
              onPressed: () {
                gfHighNotifier.value = 70;
                gfLowNotifier.value = 30;
                APref.setData(AprefKey.GF_HIGH, 0.7);
                APref.setData(AprefKey.GF_LOW, 0.3);
              },
              color: colorMain,
            ).marginOnly(right: 10),
            Button(
              child: Text('MODERATE').color(Colors.white),
              onPressed: () {
                gfHighNotifier.value = 85;
                gfLowNotifier.value = 40;
                APref.setData(AprefKey.GF_HIGH, 0.85);
                APref.setData(AprefKey.GF_LOW, 0.4);
              },
              color: colorMain,
              tooltip:
                  'Moderate conservatism with a balance between safety and efficiency',
            ).marginOnly(right: 10),
            Button(
              tooltip: 'Shortest stop time but higher risk of DCS',
              child: Text('AGGRESSIVE').color(Colors.white),
              onPressed: () {
                gfHighNotifier.value = 95;
                gfLowNotifier.value = 50;
                APref.setData(AprefKey.GF_HIGH, 0.95);
                APref.setData(AprefKey.GF_LOW, 0.5);
              },
              color: colorMain,
            ),
          ],
        ),
        Divider().marginOnly(top: 10, bottom: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            SizedBox(
              width: 50,
              child: Text('PPO2').color(colorMain).weight(FontWeight.bold),
            ).marginOnly(right: 20),
            Button(
              child: Text('$ppo2').color(Colors.white),
              onPressed: () {
                setState(() {
                  ppo2 = ppo2 == 1.4 ? 1.6 : 1.4;
                  APref.setData(AprefKey.PPO2, ppo2);
                });
              },
            ).marginOnly(right: 40),
            Text(
              'MOD : ${mod.floor().toStringAsFixed(1)}m',
            ).color(colorMain).weight(FontWeight.bold),
          ],
        ),
        Button(
          child: Text('test').color(Colors.white),
          onPressed: () {
            _testDivePlanner();
          },
        ).marginOnly(top: 20),
      ],
    );
  }

  void _testDivePlanner() {
    // 1. 다이버가 장착한 실린더(탱크) 세팅
    List<Cylinder> myTanks = [
      Cylinder(
        name: "Air1(좌)",
        volume: 11.1,
        count: 1,
        startPressure: 200,
        fractionO2: 0.21,
        purpose: GasPurpose.bottom,
      ),
      Cylinder(
        name: "Air2(우)",
        volume: 11.1,
        count: 1,
        startPressure: 200,
        fractionO2: 0.21,
        purpose: GasPurpose.bottom,
      ),
      // Cylinder(
      //   name: "Air3(백업)",
      //   volume: 11.1,
      //   count: 1,
      //   startPressure: 200,
      //   fractionO2: 0.21,
      //   purpose: GasPurpose.bottom,
      // ),
    ];

    // 2. 플랜 입력값 설정 (45미터, 25분, 분당 소모량 18L)
    DivePlanInput input = DivePlanInput(
      targetDepth: 50.0,
      bottomTime: 14,
      rmv: 18.0,
      cylinders: myTanks,
    );

    // 3. 플랜 생성
    DivePlanner planner = DivePlanner(gfHigh: 0.85, gfLow: 0.30);
    DivePlanResult result = planner.generatePlan(input);

    // 4. 결과 출력
    print("=== 다이빙 플랜 결과 ===");
    if (!result.isFeasible) {
      print("🚨 이 다이빙은 현재 가스/설정으로는 불가능하거나 매우 위험합니다!");
      for (var warning in result.warnings) {
        print("⚠️ $warning");
      }
      print("-------------------------");
    } else {
      print("총 다이빙 시간: ${result.totalDiveTime} 분");

      print("\n[상승 프로필]");
      for (var step in result.profile) {
        if (step.phase == "Gas Switch") {
          print(">> ${step.depth}m 도달: [${step.gasUsed.name}] 탱크로 기체 전환! <<");
        } else {
          print(
            "${step.phase} - 수심 ${step.depth}m / ${step.time}분 소요 (기체: ${step.gasUsed.name})",
          );
        }
      }

      print("\n[탱크 잔압 정보]");
      result.remainingPressure.forEach((tank, pressure) {
        print(
          "${tank.name} 잔압: $pressure bar 남음 (소모량: ${result.gasConsumption[tank]!.toStringAsFixed(1)} L)",
        );
      });
    }
  }
}
