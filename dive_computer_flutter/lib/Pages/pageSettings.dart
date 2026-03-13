import 'package:dive_computer_flutter/aPref.dart';
import 'package:dive_computer_flutter/define.dart';
import 'package:dive_computer_flutter/dive_planner.dart';
import 'package:dive_computer_flutter/extensions.dart';
import 'package:dive_computer_flutter/styles.dart';
import 'package:dive_computer_flutter/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  final TextEditingController _textControllerRMV = TextEditingController();
  final TextEditingController _textControllerCylinder = TextEditingController();

  @override
  void initState() {
    _currentView = _settingDiving;
    super.initState();
  }

  @override
  void dispose() {
    _textControllerCylinder.dispose();
    _textControllerRMV.dispose();
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
            child: Container(
              padding: EdgeInsets.all(20),
              child: _currentView == _settingGeneral
                  ? _viewSettingGeneral()
                  : _viewSettingDiving(),
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
            title: Text('Always on top').color(colorMain),
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
    _textControllerRMV.text = '${APref.getData(AprefKey.RMV)}';
    _textControllerCylinder.text = '${APref.getData(AprefKey.CYLINDER)}';
    return ListView(
      children: [
        ListTile(
          title: Text(
            'Cylinder(Tank) volume (Litre)',
          ).weight(FontWeight.bold).color(colorMain),

          trailing: InputText(
            width: 150,
            controller: _textControllerCylinder,
            textAlign: TextAlign.center,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$')),
            ],
            maxLines: 1,
            onFieldSubmitted: (value) {
              if (textIsNotEmpty(_textControllerCylinder.text)) {
                APref.setData(
                  AprefKey.CYLINDER,
                  double.parse(_textControllerCylinder.text),
                );
              }
              setState(() {});
            },
          ),
        ),
        ListTile(
          title: Text('RMV (L/min)').weight(FontWeight.bold).color(colorMain),
          subtitle: Text('(Respiratory Minute Volume)').color(colorMain),
          trailing: InputText(
            width: 150,
            controller: _textControllerRMV,
            textAlign: TextAlign.center,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$')),
            ],
            maxLines: 1,
            onFieldSubmitted: (value) {
              if (textIsNotEmpty(_textControllerRMV.text)) {
                APref.setData(
                  AprefKey.RMV,
                  double.parse(_textControllerRMV.text),
                );
              }
              setState(() {});
            },
          ),
        ),
        Button(
          child: Text('test').color(Colors.white),
          onPressed: () {
            _testDivePlanner();
          },
        ),
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
