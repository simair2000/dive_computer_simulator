import 'package:dive_computer_flutter/aPref.dart';
import 'package:dive_computer_flutter/define.dart';
import 'package:dive_computer_flutter/extensions.dart';
import 'package:flutter/material.dart';
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

  @override
  void initState() {
    _currentView = _settingDiving;
    super.initState();
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
                    title: Text('Diving Table')
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
    return ListView(children: []);
  }
}
