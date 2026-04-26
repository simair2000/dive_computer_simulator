import 'package:dive_computer_flutter/aPref.dart';
import 'package:dive_computer_flutter/define.dart';
import 'package:dive_computer_flutter/extensions.dart';
import 'package:dive_computer_flutter/styles.dart';
import 'package:dive_computer_flutter/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
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
  final TextEditingController _textControllerGasSwitch =
      TextEditingController();

  var gfHighNotifier = ValueNotifier<double>(85);
  var gfLowNotifier = ValueNotifier<double>(40);

  double ppo2Bottom = 1.4;
  double get modBottom => (((ppo2Bottom / 0.21) * 10) - 10);

  double ppo2Deco = 1.6;
  double get modDeco => (((ppo2Deco / 0.21) * 10) - 10);

  @override
  void initState() {
    // 저장된 값을 불러올 때 num 캐스팅 후 double로 변환하여 에러 방지
    ppo2Bottom =
        (APref.getData(AprefKey.PPO2_BOTTOM) as num?)?.toDouble() ?? 1.4;
    ppo2Deco = (APref.getData(AprefKey.PPO2_DECO) as num?)?.toDouble() ?? 1.6;
    gfHighNotifier.value =
        ((APref.getData(AprefKey.GF_HIGH) as num?)?.toDouble() ?? 0.85) * 100;
    gfLowNotifier.value =
        ((APref.getData(AprefKey.GF_LOW) as num?)?.toDouble() ?? 0.40) * 100;
    _currentView = _settingDiving;
    super.initState();
  }

  @override
  void dispose() {
    _textControllerDescent.dispose();
    _textControllerAscent.dispose();
    _textControllerGasSwitch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 1. 왼쪽 메뉴(탭) 아이템 구성
    Widget menuDiveSettings = ListTile(
      tileColor: _currentView == _settingDiving
          ? colorMain.withAlpha(100)
          : Colors.transparent,
      title: Center(
        child: Text('Dive settings')
            .weight(
              _currentView == _settingDiving
                  ? FontWeight.bold
                  : FontWeight.normal,
            )
            .color(_currentView == _settingDiving ? Colors.white : colorMain),
      ),
      onTap: () {
        setState(() {
          _currentView = _settingDiving;
        });
      },
    );

    Widget menuGeneral = ListTile(
      tileColor: _currentView == _settingGeneral
          ? colorMain.withAlpha(150)
          : Colors.transparent,
      title: Center(
        child: Text('General')
            .weight(
              _currentView == _settingGeneral
                  ? FontWeight.bold
                  : FontWeight.normal,
            )
            .color(_currentView == _settingGeneral ? Colors.white : colorMain),
      ),
      onTap: () {
        setState(() {
          _currentView = _settingGeneral;
        });
      },
    );

    // 2. 내용 뷰 영역 구성
    Widget contentArea = AnimatedBuilder(
      animation: Listenable.merge([gfHighNotifier, gfLowNotifier]),
      builder: (context, child) {
        return Container(
          padding: const EdgeInsets.all(20),
          child: _currentView == _settingGeneral
              ? _viewSettingGeneral()
              : _viewSettingDiving(),
        );
      },
    );

    // 3. 반응형 스캐폴드 렌더링
    return Scaffold(
      appBar: AppBar(
        title: LayoutBuilder(
          builder: (context, constraints) {
            return Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: constraints.maxWidth,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text('Settings').color(Colors.white),
                ),
              ),
            );
          },
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        backgroundColor: colorMain,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          bool isWideScreen = constraints.maxWidth > 850;

          if (isWideScreen) {
            // [PC / 태블릿] 가로 레이아웃
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 1,
                  child: Container(
                    color: colorMain.withAlpha(30),
                    child: ListView(children: [menuDiveSettings, menuGeneral]),
                  ),
                ),
                Expanded(flex: 3, child: contentArea),
              ],
            );
          } else {
            // [모바일] 세로 탭 레이아웃
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  color: colorMain.withAlpha(30),
                  child: Row(
                    children: [
                      Expanded(child: menuDiveSettings),
                      Expanded(child: menuGeneral),
                    ],
                  ),
                ),
                Expanded(child: contentArea),
              ],
            );
          }
        },
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
            title: const Text('Window always on top').color(colorMain),
            value: APref.getData(AprefKey.ALWAYS_ON_TOP) ?? false,
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
    _textControllerGasSwitch.text =
        '${APref.getData(AprefKey.GAS_SWITCH_TIME)}';

    return ListView(
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'Descent Speed (m/min)',
          ).weight(FontWeight.bold).color(colorMain),
          trailing: InputText(
            width: 100, // 모바일에서도 삐져나가지 않게 너비 축소
            controller: _textControllerDescent,
            keyboardType: TextInputType.numberWithOptions(decimal: true),
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
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'Ascent Speed (m/min)',
          ).weight(FontWeight.bold).color(colorMain),
          trailing: InputText(
            width: 100,
            controller: _textControllerAscent,
            keyboardType: TextInputType.numberWithOptions(decimal: true),
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
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'GAS Switch Time (min)',
          ).weight(FontWeight.bold).color(colorMain),
          trailing: InputText(
            width: 100,
            controller: _textControllerGasSwitch,
            keyboardType: TextInputType.numberWithOptions(decimal: true),
            textAlign: TextAlign.center,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$')),
            ],
            maxLines: 1,
            onFieldSubmitted: (value) {
              if (textIsNotEmpty(_textControllerGasSwitch.text)) {
                APref.setData(
                  AprefKey.GAS_SWITCH_TIME,
                  double.parse(_textControllerGasSwitch.text),
                );
              }
              setState(() {});
            },
          ),
        ),
        const Divider(),

        // 💡 Slider가 모바일 화면을 뚫고 나가지 않도록 Expanded 처리
        Row(
          children: [
            SizedBox(
              width: 60,
              child: const Text(
                'GF High',
              ).color(colorMain).weight(FontWeight.bold),
            ),
            Expanded(
              child: Slider(
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
            ),
            SizedBox(
              width: 45,
              child: Text(
                '${gfHighNotifier.value.toInt()}%',
              ).color(colorMain).weight(FontWeight.bold).align(TextAlign.right),
            ),
          ],
        ),
        Row(
          children: [
            SizedBox(
              width: 60,
              child: const Text(
                'GF Low',
              ).color(colorMain).weight(FontWeight.bold),
            ),
            Expanded(
              child: Slider(
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
            ),
            SizedBox(
              width: 45,
              child: Text(
                '${gfLowNotifier.value.toInt()}%',
              ).color(colorMain).weight(FontWeight.bold).align(TextAlign.right),
            ),
          ],
        ),

        const Text('Conservatism Settings')
            .color(colorMain)
            .weight(FontWeight.bold)
            .marginOnly(bottom: 10, top: 10),

        // 💡 화면 좁을 때 알아서 밑으로 내려가도록 Wrap 위젯 적용
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            Button(
              tooltip:
                  'Most conservative setting with longest decompression times',
              color: colorMain,
              onPressed: () {
                gfHighNotifier.value = 70;
                gfLowNotifier.value = 30;
                APref.setData(AprefKey.GF_HIGH, 0.7);
                APref.setData(AprefKey.GF_LOW, 0.3);
              },
              child: const Text('SAFE').color(Colors.white),
            ),
            Button(
              tooltip:
                  'Moderate conservatism with a balance between safety and efficiency',
              color: colorMain,
              onPressed: () {
                gfHighNotifier.value = 85;
                gfLowNotifier.value = 40;
                APref.setData(AprefKey.GF_HIGH, 0.85);
                APref.setData(AprefKey.GF_LOW, 0.4);
              },
              child: const Text('MODERATE').color(Colors.white),
            ),
            Button(
              tooltip: 'Shortest stop time but higher risk of DCS',
              color: colorMain,
              onPressed: () {
                gfHighNotifier.value = 95;
                gfLowNotifier.value = 50;
                APref.setData(AprefKey.GF_HIGH, 0.95);
                APref.setData(AprefKey.GF_LOW, 0.5);
              },
              child: const Text('AGGRESSIVE').color(Colors.white),
            ),
          ],
        ),
        const Divider().marginOnly(top: 15, bottom: 15),

        // 💡 폭이 좁은 모바일 기기에서 텍스트 오버플로우를 막기 위한 Wrap 처리
        Wrap(
          spacing: 20,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 110,
              child: const Text(
                'PPO2 BOTTOM',
              ).color(colorMain).weight(FontWeight.bold),
            ),
            Button(
              onPressed: () {
                setState(() {
                  ppo2Bottom = ppo2Bottom == 1.4 ? 1.6 : 1.4;
                  APref.setData(AprefKey.PPO2_BOTTOM, ppo2Bottom);
                });
              },
              child: Text('$ppo2Bottom').color(Colors.white),
            ),
            Text(
              'MOD : ${modBottom.floor().toStringAsFixed(1)}m',
            ).color(colorMain).weight(FontWeight.bold),
          ],
        ).marginOnly(bottom: 15),

        Wrap(
          spacing: 20,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 110,
              child: const Text(
                'PPO2 DECO',
              ).color(colorMain).weight(FontWeight.bold),
            ),
            Button(
              onPressed: () {
                setState(() {
                  ppo2Deco = ppo2Deco == 1.4 ? 1.6 : 1.4;
                  APref.setData(AprefKey.PPO2_DECO, ppo2Deco);
                });
              },
              child: Text('$ppo2Deco').color(Colors.white),
            ),
            Text(
              'MOD : ${modDeco.floor().toStringAsFixed(1)}m',
            ).color(colorMain).weight(FontWeight.bold),
          ],
        ),
        const SizedBox(height: 30),
      ],
    );
  }
}
