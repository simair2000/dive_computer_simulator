import 'package:dive_computer_flutter/aPref.dart';
import 'package:dive_computer_flutter/define.dart';
import 'package:dive_computer_flutter/dive_planner.dart';
import 'package:dive_computer_flutter/extensions.dart';
import 'package:dive_computer_flutter/router.dart';
import 'package:dive_computer_flutter/styles.dart';
import 'package:dive_computer_flutter/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:go_router/go_router.dart';
import 'package:fl_chart/fl_chart.dart';

class PagePlanner extends StatefulWidget {
  const PagePlanner({super.key});

  @override
  State<PagePlanner> createState() => _PagePlannerState();
}

class _PagePlannerState extends State<PagePlanner> {
  final ScrollController _horizontalScrollController = ScrollController();
  final ScrollController _inputScrollController = ScrollController();

  // 멀티레벨 입력용 컨트롤러 및 데이터
  final TextEditingController _textControllerWpDepth = TextEditingController();
  final TextEditingController _textControllerWpTime = TextEditingController();
  final List<DiveWaypoint> waypoints = [];

  final TextEditingController _textControllerRMV = TextEditingController(
    text: '20',
  );
  final TextEditingController _textControllerCylinderName =
      TextEditingController(text: 'Air');
  final TextEditingController _textControllerCylinderVolume =
      TextEditingController(text: '11');
  int _cylinderType = 1;
  final TextEditingController _textControllerCylinderStartPressure =
      TextEditingController(text: '200');
  final TextEditingController _textControllerCylinderO2 = TextEditingController(
    text: '21',
  );
  final TextEditingController _textControllerCylinderHe = TextEditingController(
    text: '0',
  );

  final List<Cylinder> cylinders = [];
  DivePlanResult? _planResult;
  int _cylinderPurpose = 0;
  int _mobileStep = 0;

  @override
  void dispose() {
    _horizontalScrollController.dispose();
    _inputScrollController.dispose();
    _textControllerWpDepth.dispose();
    _textControllerWpTime.dispose();
    _textControllerCylinderHe.dispose();
    _textControllerCylinderO2.dispose();
    _textControllerCylinderStartPressure.dispose();
    _textControllerCylinderVolume.dispose();
    _textControllerCylinderName.dispose();
    _textControllerRMV.dispose();
    super.dispose();
  }

  void _applyPreset(String name, String o2, String he, int purpose) {
    setState(() {
      _textControllerCylinderName.text = name;
      _textControllerCylinderO2.text = o2;
      _textControllerCylinderHe.text = he;
      _cylinderPurpose = purpose; // 0: Bottom, 1: Deco
    });
  }

  @override
  Widget build(BuildContext context) {
    // ==============================================================
    // 1. 왼쪽 패널 (입력부) 위젯 리스트
    // ==============================================================
    List<Widget> leftPanelContents = [
      Text(
        'Dive Plan (Multi-Level)',
      ).weight(FontWeight.bold).color(colorMain).marginOnly(bottom: 10),
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colorMain.withOpacity(0.3)),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(child: Text('Depth (m)').color(colorMain).size(13)),
                Expanded(
                  child: Text('Stay Time (min)').color(colorMain).size(13),
                ),
                const SizedBox(width: 40),
              ],
            ).marginOnly(bottom: 5),
            Row(
              children: [
                Expanded(
                  child: InputText(
                    controller: _textControllerWpDepth,
                    textAlign: TextAlign.center,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$')),
                    ],
                    maxLines: 1,
                  ).marginOnly(right: 10),
                ),
                Expanded(
                  child: InputText(
                    controller: _textControllerWpTime,
                    textAlign: TextAlign.center,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    maxLines: 1,
                  ).marginOnly(right: 10),
                ),
                IconButton(
                  onPressed: _addWaypoint,
                  icon: Icon(Icons.add_box, color: colorMain, size: 35),
                  padding: EdgeInsets.zero,
                ),
              ],
            ),
            if (waypoints.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Divider(height: 1),
              const SizedBox(height: 10),
              // 드래그 앤 드롭 리스트
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: waypoints.length,
                onReorder: (int oldIndex, int newIndex) {
                  setState(() {
                    if (oldIndex < newIndex) newIndex -= 1;
                    final item = waypoints.removeAt(oldIndex);
                    waypoints.insert(newIndex, item);
                  });
                },
                itemBuilder: (context, index) {
                  var wp = waypoints[index];
                  return Container(
                    key: ObjectKey(wp),
                    padding: const EdgeInsets.symmetric(vertical: 6.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            ReorderableDragStartListener(
                              index: index,
                              child: MouseRegion(
                                cursor: SystemMouseCursors.grab,
                                child: Icon(
                                  Icons.drag_indicator,
                                  color: Colors.grey[400],
                                  size: 22,
                                ).marginOnly(right: 8),
                              ),
                            ),
                            Text(
                              '${index + 1}.',
                            ).weight(FontWeight.bold).color(colorMain),
                          ],
                        ),
                        Text('${wp.depth} m').color(Colors.black87),
                        Text('${wp.time} min').color(Colors.black87),
                        IconButton(
                          icon: const Icon(
                            Icons.delete,
                            color: Colors.redAccent,
                            size: 20,
                          ),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          onPressed: () {
                            setState(() {
                              waypoints.removeAt(index);
                            });
                          },
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 15),
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('RMV').weight(FontWeight.bold).color(colorMain),
                Text('(Respiratory Minute Volume)').color(colorMain).size(11),
              ],
            ),
          ),
          Expanded(
            child: InputText(
              width: 100,
              controller: _textControllerRMV,
              textAlign: TextAlign.center,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$')),
              ],
              maxLines: 1,
            ),
          ),
        ],
      ),
      horizontalLine(),
      Text(
        'Gas Cylinders',
      ).weight(FontWeight.bold).color(colorMain).marginOnly(bottom: 10),
      Row(
        children: [
          Expanded(
            child: Button(
              height: 35,
              color: colorMain.withAlpha(200),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: const Text('AIR').color(Colors.white).size(12),
              ),
              onPressed: () => _applyPreset('Air', '21', '0', 0),
            ).marginOnly(right: 5),
          ),
          Expanded(
            child: Button(
              height: 35,
              color: colorMain.withAlpha(200),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: const Text('EAN32').color(Colors.white).size(12),
              ),
              onPressed: () => _applyPreset('EAN32', '32', '0', 0),
            ).marginOnly(right: 5),
          ),
          Expanded(
            child: Button(
              height: 35,
              color: colorMain.withAlpha(200),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: const Text('EAN50').color(Colors.white).size(12),
              ),
              onPressed: () =>
                  _applyPreset('EAN50', '50', '0', 1), // EAN50은 주로 Deco용
            ).marginOnly(right: 5),
          ),
          Expanded(
            child: Button(
              height: 35,
              color: colorMain.withAlpha(200),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: const Text('100% O2').color(Colors.white).size(11),
              ),
              onPressed: () =>
                  _applyPreset('100% O2', '100', '0', 1), // 100% O2는 Deco용
            ),
          ),
        ],
      ).marginOnly(bottom: 5),
      Row(
        children: [
          Expanded(
            child: Text('O2/He')
                .weight(FontWeight.bold)
                .color(colorMain)
                .size(13)
                .marginOnly(right: 5),
          ),
          Expanded(
            child: Button(
              height: 35,
              color: colorMain.withAlpha(200),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: const Text('21/35').color(Colors.white).size(12),
              ),
              onPressed: () =>
                  _applyPreset('21/35', '21', '35', 0), // 트라이믹스 Bottom
            ).marginOnly(right: 5),
          ),
          Expanded(
            child: Button(
              height: 35,
              color: colorMain.withAlpha(200),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: const Text('18/45').color(Colors.white).size(12),
              ),
              onPressed: () => _applyPreset('18/45', '18', '45', 0),
            ).marginOnly(right: 5),
          ),
          Expanded(
            child: Button(
              height: 35,
              color: colorMain.withAlpha(200),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: const Text('15/55').color(Colors.white).size(12),
              ),
              onPressed: () => _applyPreset('15/55', '15', '55', 0),
            ),
          ),
        ],
      ).marginOnly(bottom: 10),
      Row(
        children: [
          Expanded(child: Text('Type').color(colorMain)),
          Expanded(
            child: Button(
              height: 46,
              child: Text(
                _cylinderType == 1 ? 'Single' : 'Double',
              ).color(Colors.white),
              onPressed: () {
                setState(() {
                  _cylinderType = _cylinderType == 1 ? 2 : 1;
                });
              },
            ),
          ),
        ],
      ).marginOnly(bottom: 5),
      Row(
        children: [
          Expanded(child: Text('Name').color(colorMain)),
          Expanded(
            child: InputText(
              controller: _textControllerCylinderName,
              textAlign: TextAlign.center,
              maxLines: 1,
            ),
          ),
        ],
      ).marginOnly(bottom: 5),
      Row(
        children: [
          Expanded(child: Text('Volume (Liter)').color(colorMain)),
          Expanded(
            child: InputText(
              controller: _textControllerCylinderVolume,
              textAlign: TextAlign.center,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$')),
              ],
              maxLines: 1,
            ),
          ),
        ],
      ).marginOnly(bottom: 5),
      Row(
        children: [
          Expanded(child: Text('Start Pressure (bar)').color(colorMain)),
          Expanded(
            child: InputText(
              controller: _textControllerCylinderStartPressure,
              textAlign: TextAlign.center,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$')),
              ],
              maxLines: 1,
            ),
          ),
        ],
      ).marginOnly(bottom: 5),
      Row(
        children: [
          Expanded(child: Text('Purpose').color(colorMain)),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: Button(
                    height: 46,
                    color: _cylinderPurpose == 0 ? colorMain : Colors.grey,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('Bottom').color(Colors.white),
                    ),
                    onPressed: () => setState(() => _cylinderPurpose = 0),
                  ).marginOnly(right: 5),
                ),
                Expanded(
                  child: Button(
                    height: 46,
                    color: _cylinderPurpose == 1 ? Colors.orange : Colors.grey,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('Deco').color(Colors.white),
                    ),
                    onPressed: () => setState(() => _cylinderPurpose = 1),
                  ),
                ),
              ],
            ),
          ),
        ],
      ).marginOnly(bottom: 5),
      Row(
        children: [
          Expanded(child: Text('O2 %').color(colorMain)),
          Expanded(
            flex: 2,
            child: InputText(
              controller: _textControllerCylinderO2,
              textAlign: TextAlign.center,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d{0,3}$')),
              ],
              maxLines: 1,
            ).marginOnly(right: 20),
          ),
          Expanded(child: Text('He %').color(colorMain)),
          Expanded(
            flex: 2,
            child: InputText(
              controller: _textControllerCylinderHe,
              textAlign: TextAlign.center,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d{0,2}$')),
              ],
              maxLines: 1,
            ),
          ),
        ],
      ).marginOnly(bottom: 10),

      Align(
        alignment: AlignmentGeometry.centerRight,
        child: FloatingActionButton.extended(
          heroTag: 'addCylinderFab',
          tooltip: 'Add Cylinder',
          backgroundColor: colorMain,
          foregroundColor: Colors.white,
          elevation: 3,
          onPressed: () {
            _addCylinder();
          },
          icon: const Icon(Icons.add),
          label: const Text('Add Cylinder'),
        ),
      ),
      horizontalLine(),
    ];
    final List<Widget> depthPanelContents = leftPanelContents.sublist(0, 5);
    final List<Widget> cylinderPanelContents = leftPanelContents.sublist(
      5,
      leftPanelContents.length,
    );

    // ==============================================================
    // 2. 오른쪽 패널 (결과부) 위젯 리스트
    // ==============================================================
    List<Widget> rightPanelContents = [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text('Cylinder List')
              .weight(FontWeight.bold)
              .color(colorMain)
              .marginOnly(bottom: 10)
              .marginOnly(right: 20),
          Button(
            height: 50,
            color: Colors.green,
            child: Text('Plan').color(Colors.white),
            onPressed: () {
              _startDivePlan();
            },
          ),
        ],
      ).marginOnly(bottom: 10),
      _cylinderList(),
      horizontalLine(),
      _divePlanResult(),
    ];

    // ==============================================================
    // 3. 메인 Scaffold 및 반응형 렌더링 (LayoutBuilder)
    // ==============================================================
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
                  child: Text('Diving Planner').color(Colors.white),
                ),
              ),
            );
          },
        ),
        leading: const Icon(Icons.assignment, color: Colors.white, size: 30),
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
            tooltip: 'Go to the diving simulator',
            onPressed: () {
              context.goNamed(RoutePage.home.name);
            },
            icon: const Icon(Icons.scuba_diving, color: Colors.white),
          ),
          IconButton(
            tooltip: 'Go to the settings',
            onPressed: () {
              context.pushNamed(RoutePage.settings.name);
            },
            icon: const Icon(Icons.settings, color: Colors.white),
          ),
          IconButton(
            tooltip: 'About Dive Planner',
            onPressed: () {
              showGetDialog(
                'About Dive Planner',
                'This Dive Planner is an advanced decompression scheduling tool based on the Bühlmann ZHL-16C algorithm with Gradient Factors (GF).\n\n'
                    '📌 Features:\n'
                    '• Multi-Level Diving: Plan complex profiles by adding multiple waypoints (Depth & Time).\n'
                    '• Gas Management: Supports Air, Nitrox, and Trimix with automatic gas switching logic.\n'
                    '• RMV Tracking: Accurately calculates gas consumption and estimates remaining cylinder pressures.\n'
                    '• Deco Profiling: Generates step-by-step ascent and decompression stop schedules dynamically.\n\n'
                    '⚠️ Warning: This software is purely a simulation tool. Always verify your plans with primary dive computers and never dive beyond your training and personal limits.',
              );
            },
            icon: const Icon(Icons.help, color: Colors.white),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // 🌟 화면 너비가 850 이상이면 PC/태블릿 모드(가로), 그 이하면 모바일 모드(세로)
          bool isWideScreen = constraints.maxWidth > 850;

          if (isWideScreen) {
            // ==========================================
            // [PC / 태블릿] 가로 레이아웃 (Row)
            // ==========================================
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 2,
                  child: Container(
                    color: colorMain.withAlpha(30),
                    padding: const EdgeInsets.all(20),
                    child: ListView(
                      controller: _inputScrollController,
                      children: leftPanelContents,
                    ),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    child: ListView(children: rightPanelContents),
                  ),
                ),
              ],
            );
          } else {
            // ==========================================
            // [모바일] 세로 스크롤 레이아웃 (Column)
            // ==========================================
            return SingleChildScrollView(
              controller: _inputScrollController,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    color: colorMain.withAlpha(20),
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Expanded(
                          child: _buildStepArrowButton(
                            label: '1. Depth',
                            color: _mobileStep == 0
                                ? colorMain
                                : colorMain.withAlpha(120),
                            onTap: () {
                              setState(() {
                                _mobileStep = 0;
                              });
                            },
                            hasLeftNotch: false,
                            hasRightTip: true,
                          ).marginOnly(right: 6),
                        ),
                        Expanded(
                          child: _buildStepArrowButton(
                            label: '2. Cylinder',
                            color: _mobileStep == 1
                                ? colorMain
                                : colorMain.withAlpha(120),
                            onTap: () {
                              setState(() {
                                _mobileStep = 1;
                              });
                            },
                            hasLeftNotch: false,
                            hasRightTip: true,
                          ).marginOnly(right: 6),
                        ),
                        Expanded(
                          child: _buildStepArrowButton(
                            label: '3. Result',
                            color: _mobileStep == 2
                                ? Colors.green
                                : Colors.green.withAlpha(140),
                            onTap: () {
                              if (cylinders.isEmpty) {
                                showSnackbar(
                                  'Notice',
                                  'Please add at least one cylinder first.',
                                );
                                return;
                              }
                              setState(() {
                                _mobileStep = 2;
                              });
                            },
                            hasLeftNotch: false,
                            hasRightTip: false,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_mobileStep == 0)
                    Container(
                      color: colorMain.withAlpha(30),
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ...depthPanelContents,
                          // Button(
                          //   height: 46,
                          //   color: colorMain,
                          //   child: const Text(
                          //     'Done with Depth, go to Cylinder',
                          //   ).color(Colors.white),
                          //   onPressed: () {
                          //     if (waypoints.isEmpty) {
                          //       showSnackbar(
                          //         'Notice',
                          //         'Please add at least one waypoint.',
                          //       );
                          //       return;
                          //     }
                          //     setState(() {
                          //       _mobileStep = 1;
                          //     });
                          //   },
                          // ),
                        ],
                      ),
                    ),
                  if (_mobileStep == 1)
                    Container(
                      color: colorMain.withAlpha(30),
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ...cylinderPanelContents,
                          Text('Cylinder List')
                              .weight(FontWeight.bold)
                              .color(colorMain)
                              .marginOnly(bottom: 10),
                          _cylinderList().marginOnly(bottom: 12),
                          // Row(
                          //   children: [
                          //     Expanded(
                          //       child: Button(
                          //         height: 46,
                          //         color: Colors.grey,
                          //         child: const Text('Back').color(Colors.white),
                          //         onPressed: () {
                          //           setState(() {
                          //             _mobileStep = 0;
                          //           });
                          //         },
                          //       ).marginOnly(right: 8),
                          //     ),
                          //     Expanded(
                          //       child: Button(
                          //         height: 46,
                          //         color: colorMain,
                          //         child: const Text(
                          //           'Done with Cylinder, view Result',
                          //         ).color(Colors.white),
                          //         onPressed: () {
                          //           if (cylinders.isEmpty) {
                          //             showSnackbar(
                          //               'Notice',
                          //               'Please add at least one cylinder.',
                          //             );
                          //             return;
                          //           }
                          //           setState(() {
                          //             _mobileStep = 2;
                          //           });
                          //         },
                          //       ),
                          //     ),
                          //   ],
                          // ),
                        ],
                      ),
                    ),
                  if (_mobileStep == 2)
                    Container(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Row(
                          //   children: [
                          //     Expanded(
                          //       child: Button(
                          //         height: 42,
                          //         color: Colors.grey,
                          //         child: const Text(
                          //           'Go to Cylinder Step',
                          //         ).color(Colors.white),
                          //         onPressed: () {
                          //           setState(() {
                          //             _mobileStep = 1;
                          //           });
                          //         },
                          //       ),
                          //     ),
                          //   ],
                          // ).marginOnly(bottom: 12),
                          ...rightPanelContents,
                        ],
                      ),
                    ),
                ],
              ),
            );
          }
        },
      ),
    );
  }

  Widget _buildStepArrowButton({
    required String label,
    required Color color,
    required VoidCallback onTap,
    required bool hasLeftNotch,
    required bool hasRightTip,
  }) {
    return SizedBox(
      height: 40,
      child: ClipPath(
        clipper: _StepArrowClipper(
          hasLeftNotch: hasLeftNotch,
          hasRightTip: hasRightTip,
        ),
        child: Material(
          color: color,
          child: InkWell(
            onTap: onTap,
            child: Center(child: Text(label).color(Colors.white).size(12)),
          ),
        ),
      ),
    );
  }

  void _addWaypoint() {
    if (textIsEmpty(_textControllerWpDepth.text) ||
        textIsEmpty(_textControllerWpTime.text)) {
      showSnackbar('Error', 'Please enter depth and time');
      return;
    }
    double depth = double.parse(_textControllerWpDepth.text);
    int time = int.parse(_textControllerWpTime.text);

    if (depth <= 0) {
      showSnackbar('Error', 'Depth must be greater than 0');
      return;
    }

    setState(() {
      waypoints.add(DiveWaypoint(depth: depth, time: time));
      _textControllerWpDepth.clear();
      _textControllerWpTime.clear();
    });
  }

  void _addCylinder() {
    if (textIsEmpty(_textControllerCylinderName.text)) {
      showSnackbar('Error', 'Please enter cylinder name');
      return;
    }
    if (textIsEmpty(_textControllerCylinderVolume.text)) {
      showSnackbar('Error', 'Please enter cylinder volume');
      return;
    }
    if (textIsEmpty(_textControllerCylinderStartPressure.text)) {
      showSnackbar('Error', 'Please enter cylinder start pressure');
      return;
    }
    if (textIsEmpty(_textControllerCylinderO2.text)) {
      showSnackbar('Error', 'Please enter the fraction of Oxygen');
      return;
    }
    if (textIsEmpty(_textControllerCylinderHe.text)) {
      showSnackbar('Error', 'Please enter the fraction of helium');
      return;
    }

    double o2Value = double.parse(_textControllerCylinderO2.text);
    double heValue = double.parse(_textControllerCylinderHe.text);

    if (o2Value <= 0 || o2Value > 100) {
      showSnackbar('Error', 'Oxygen percentage must be between 1 and 100');
      return;
    }
    if (heValue < 0 || heValue >= 100) {
      showSnackbar('Error', 'Helium percentage must be between 0 and 99');
      return;
    }
    if (o2Value + heValue > 100) {
      showSnackbar('Error', 'O2 and He total cannot exceed 100%');
      return;
    }

    Cylinder cylinder = Cylinder(
      count: _cylinderType,
      name: _textControllerCylinderName.text,
      volume: double.parse(_textControllerCylinderVolume.text),
      startPressure: double.parse(_textControllerCylinderStartPressure.text),
      fractionO2: o2Value / 100.0,
      fractionHe: heValue / 100.0,
      purpose: _cylinderPurpose == 0
          ? GasPurpose.bottom
          : GasPurpose.deco, // <-- 이 부분 추가
    );
    setState(() {
      cylinders.add(cylinder);
    });
    scrollToEnd(_inputScrollController);
  }

  Widget _cylinderList() {
    if (cylinders.isEmpty) return const SizedBox.shrink();

    return Scrollbar(
      controller: _horizontalScrollController,
      thumbVisibility: GetPlatform.isWindows,
      thickness: 8.0,
      radius: const Radius.circular(10),
      child: SingleChildScrollView(
        controller: _horizontalScrollController,
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: List.generate(cylinders.length, (index) {
            Cylinder cylinder = cylinders[index];
            double consumption = _planResult?.gasConsumption[cylinder] ?? 0;
            int remainingPressure =
                _planResult?.remainingPressure[cylinder] ?? 0;
            double remain = cylinder.totalLiters - consumption;
            double fillRatio = cylinder.totalLiters > 0
                ? (remain / cylinder.totalLiters).clamp(0.0, 1.0)
                : 0.0;
            return Container(
              decoration: BoxDecoration(
                border: Border.all(color: colorMain, width: 1),
                borderRadius: BorderRadius.all(Radius.circular(8)),
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.blueAccent.withAlpha(100),
                    Colors.transparent,
                  ],
                  stops: [fillRatio, fillRatio],
                ),
              ),
              padding: const EdgeInsets.only(top: 10),
              child: Stack(
                alignment: AlignmentGeometry.topRight,
                children: [
                  Row(
                    children: [
                      cylinder.count == 1
                          ? Image.asset(
                              'assets/single-tank.png',
                              color: colorMain,
                              scale: 6,
                            )
                          : Image.asset(
                              'assets/double-tank.png',
                              color: colorMain,
                              scale: 6,
                            ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 용도 뱃지 (Bottom/Deco)
                          Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: cylinder.purpose == GasPurpose.bottom
                                  ? Colors.blue
                                  : Colors.orange,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child:
                                Text(
                                      cylinder.purpose == GasPurpose.bottom
                                          ? "BOTTOM"
                                          : "DECO",
                                    )
                                    .color(Colors.white)
                                    .size(10)
                                    .weight(FontWeight.bold),
                          ),
                          Text(
                                '${cylinder.name}\nVolume : ${cylinder.totalLiters} L\nRemain : ${remain.toStringAsFixed(1)} L\n${remainingPressure}bar',
                              )
                              .color(colorMain)
                              .align(TextAlign.left)
                              .marginOnly(top: 5),
                        ],
                      ).marginOnly(left: 10),
                    ],
                  ).marginOnly(right: 50),
                  IconButton(
                    onPressed: () {
                      setState(() {
                        cylinders.removeAt(index);
                      });
                    },
                    icon: Icon(
                      Icons.disabled_by_default_rounded,
                      color: Colors.red,
                      size: 30,
                    ),
                  ),
                ],
              ),
            ).marginOnly(right: 10);
          }),
        ),
      ),
    );
  }

  Widget _divePlanResult() {
    if (_planResult == null) return Container();
    final List<DiveStep> timelineProfile = _planResult!.isFeasible
        ? _collapsedMovementSteps(_planResult!.profile)
        : [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSummaryCard(),
        const SizedBox(height: 20),

        // ==========================================
        // 🌟 여기에 다이브 프로필 차트를 삽입합니다!
        // ==========================================
        if (_planResult!.isFeasible) ...[
          Text('Profile Chart')
              .weight(FontWeight.bold)
              .color(colorMain)
              .size(18)
              .marginOnly(bottom: 10),
          DiveProfileChart(
            profile: _planResult!.profile,
            totalDiveTime: _planResult!.totalDiveTime,
          ),
          const SizedBox(height: 20),
        ],

        // ==========================================
        Text('Dive Profile Timeline')
            .weight(FontWeight.bold)
            .color(colorMain)
            .size(18)
            .marginOnly(bottom: 15),
        Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: colorMain.withAlpha(100), width: 3),
            ),
          ),
          margin: const EdgeInsets.only(left: 10),
          child: ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _planResult!.isFeasible
                ? timelineProfile.length
                : _planResult!.warnings.length,
            itemBuilder: (context, index) {
              return _planResult!.isFeasible
                  ? _buildProfileStepCard(
                      timelineProfile[index],
                      startDepth: index == 0
                          ? 0
                          : timelineProfile[index - 1].depth,
                    )
                  : _buildWarningCard(_planResult!.warnings[index]);
            },
          ),
        ),
      ],
    );
  }

  List<DiveStep> _collapsedMovementSteps(List<DiveStep> profile) {
    final List<DiveStep> collapsed = [];
    DiveStep? pendingMovement;

    bool isMovement(DiveStep step) =>
        step.phase == 'Descent' || step.phase == 'Ascent';

    void flushPending() {
      if (pendingMovement != null) {
        collapsed.add(pendingMovement!);
        pendingMovement = null;
      }
    }

    for (final step in profile) {
      if (!isMovement(step)) {
        flushPending();
        collapsed.add(step);
        continue;
      }

      if (pendingMovement == null) {
        pendingMovement = step;
        continue;
      }

      if (pendingMovement?.phase == step.phase) {
        pendingMovement = DiveStep(
          step.phase,
          step.depth,
          (pendingMovement?.time ?? 0) + step.time,
          step.gasUsed,
          (pendingMovement?.gasConsumedLiters ?? 0) + step.gasConsumedLiters,
          pO2: step.pO2,
          cns: step.cns,
          otu: step.otu,
          ndl: step.ndl,
          ceiling: step.ceiling,
        );
        continue;
      }

      flushPending();
      pendingMovement = step;
    }

    flushPending();
    return collapsed;
  }

  Widget _buildWarningCard(String warning) {
    return Container(
      margin: EdgeInsets.only(left: 20, bottom: 10),
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withAlpha(20),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.red.withAlpha(100)),
      ),
      child: Row(
        children: [
          Icon(Icons.report_problem, color: Colors.red),
          const SizedBox(width: 10),
          Expanded(
            child: Text(warning).color(Colors.red).weight(FontWeight.w500),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileStepCard(DiveStep profile, {int? startDepth}) {
    IconData stepIcon = Icons.arrow_downward;
    Color stepColor = colorMain;
    String phaseName = profile.phase;
    final bool isMovement =
        profile.phase == 'Descent' || profile.phase == 'Ascent';
    final String depthLabel = isMovement && startDepth != null
        ? '${startDepth}m -> ${profile.depth}m'
        : '${profile.depth}m';

    switch (profile.phase) {
      case 'Descent':
        stepIcon = Icons.south_east;
        stepColor = Colors.blue;
        break;
      case 'Level Stay':
        stepIcon = Icons.anchor;
        stepColor = Colors.indigoAccent;
        break;
      case 'Ascent':
        stepIcon = Icons.north_east;
        stepColor = Colors.lightBlue;
        break;
      case 'Deco Stop':
        stepIcon = Icons.timer_outlined;
        stepColor = Colors.orange;
        break;
      case 'Safety Stop':
        stepIcon = Icons.health_and_safety;
        stepColor = Colors.green;
        break;
      case 'Gas Switch':
        stepIcon = Icons.published_with_changes;
        stepColor = Colors.purple;
        break;
      case 'Surface':
        stepIcon = Icons.waves;
        stepColor = Colors.teal;
        break;
    }

    return Stack(
      children: [
        Positioned(
          left: -6,
          top: 20,
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: stepColor, shape: BoxShape.circle),
          ),
        ),
        GestureDetector(
          onTap: () => _showStepDetails(profile),
          child: Container(
            margin: EdgeInsets.only(left: 20, bottom: 10),
            padding: EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: stepColor.withAlpha(15),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: stepColor.withAlpha(50)),
            ),
            child: Row(
              children: [
                Column(
                  children: [
                    Icon(stepIcon, color: stepColor, size: 28),
                    Text(
                      phaseName,
                    ).size(10).color(stepColor).weight(FontWeight.bold),
                  ],
                ).marginOnly(right: 15),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            depthLabel,
                          ).size(20).weight(FontWeight.bold).color(colorMain),
                          const SizedBox(width: 10),
                          Text(
                            '${profile.time.toStringAsFixed(1)} min',
                          ).size(14).color(Colors.grey[700]!),
                        ],
                      ),
                      if (profile.phase == "Gas Switch")
                        Text(
                          'Switch to ${profile.gasUsed.name}',
                        ).color(Colors.purple).weight(FontWeight.bold).size(12)
                      else
                        Text('Runtime step').size(11).color(Colors.grey),
                    ],
                  ),
                ),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: colorMain,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    profile.gasUsed.name,
                  ).color(Colors.white).size(11).weight(FontWeight.bold),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSummaryCard() {
    bool isFeasible = _planResult!.isFeasible;
    List<String> warnings = _planResult!.warnings;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isFeasible
            ? Colors.green.withAlpha(25)
            : Colors.red.withAlpha(25),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isFeasible
              ? Colors.green.withAlpha(150)
              : Colors.red.withAlpha(150),
          width: 2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isFeasible ? Icons.check_circle : Icons.dangerous,
                color: isFeasible ? Colors.green : Colors.red,
                size: 40,
              ).marginOnly(right: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                          isFeasible
                              ? 'Plan Feasible'
                              : 'Plan Impossible / Critical',
                        )
                        .weight(FontWeight.bold)
                        .size(18)
                        .color(
                          isFeasible ? Colors.green[800]! : Colors.red[800]!,
                        ),
                    Text(
                      'Total Runtime: ${_planResult!.totalDiveTime.toStringAsFixed(1)} min',
                    ).color(colorMain).size(15),
                  ],
                ),
              ),
            ],
          ),
          if (warnings.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Divider(height: 1, thickness: 1, color: Colors.black12),
            ),
            ...warnings.map(
              (msg) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      msg.contains('CRITICAL')
                          ? Icons.report
                          : Icons.warning_amber_rounded,
                      size: 18,
                      color: msg.contains('CRITICAL')
                          ? Colors.red
                          : Colors.orange[800],
                    ).marginOnly(right: 8, top: 2),
                    Expanded(
                      child: Text(msg)
                          .size(13)
                          .color(
                            msg.contains('CRITICAL')
                                ? Colors.red[900]!
                                : Colors.orange[900]!,
                          )
                          .weight(FontWeight.w500),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _startDivePlan() {
    if (waypoints.isEmpty) {
      showSnackbar('Error', 'Please add at least one waypoint (Depth/Time).');
      return;
    }
    if (textIsEmpty(_textControllerRMV.text)) {
      showSnackbar('Error', 'Please enter RMV');
      return;
    }
    if (cylinders.isEmpty) {
      showSnackbar('Error', 'Please add a cylinder');
      return;
    }

    DivePlanInput input = DivePlanInput(
      waypoints: waypoints,
      rmv: double.tryParse(_textControllerRMV.text) ?? 20.0,
      cylinders: cylinders,
    );

    double gfHighVal = 0.85;
    double gfLowVal = 0.30;
    try {
      gfHighVal = (APref.getData(AprefKey.GF_HIGH) as num?)?.toDouble() ?? 0.85;
      gfLowVal = (APref.getData(AprefKey.GF_LOW) as num?)?.toDouble() ?? 0.30;
    } catch (e) {
      print("GF Value Error: $e");
    }

    DivePlanner2 planner = DivePlanner2(gfHigh: gfHighVal, gfLow: gfLowVal);
    setState(() {
      _planResult = planner.generatePlan(input);
    });
  }

  // --- 프로필 카드 클릭 시 뜨는 상세 정보 팝업 ---
  void _showStepDetails(DiveStep step) {
    Get.defaultDialog(
      title: "Step End Details",
      titleStyle: TextStyle(
        fontWeight: FontWeight.bold,
        fontSize: 18,
        color: colorMain,
      ),
      contentPadding: EdgeInsets.all(20),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildDetailRow(Icons.label, "Phase", step.phase),
          _buildDetailRow(Icons.height, "Depth", "${step.depth} m"),
          _buildDetailRow(
            Icons.timer,
            "Time Spent",
            "${step.time.toStringAsFixed(1)} min",
          ),
          _buildDetailRow(Icons.air, "Gas Used", step.gasUsed.name),
          _buildDetailRow(
            Icons.compare_arrows,
            "END",
            "${step.gasUsed.getEnd(step.depth.toDouble()).toStringAsFixed(1)}m",
          ),
          Divider(height: 20, thickness: 1),
          _buildDetailRow(
            Icons.speed,
            "NDL (Remaining)",
            step.ndl <= 0
                ? "DECO"
                : (step.ndl >= 99 ? "99+ min" : "${step.ndl.toInt()} min"),
            color: step.ndl <= 0 ? Colors.red : Colors.green,
          ),
          _buildDetailRow(
            Icons.science,
            "PO2",
            "${step.pO2.toStringAsFixed(2)} bar",
            color: step.pO2 >= 1.4 ? Colors.orange : colorMain,
          ),
          _buildDetailRow(
            Icons.warning,
            "CNS Limit",
            "${step.cns.toStringAsFixed(1)} %",
            color: step.cns >= 80 ? Colors.red : colorMain,
          ),
          _buildDetailRow(
            Icons.coronavirus_outlined, // 혹은 어울리는 아이콘
            "OTU Limit",
            "${step.otu.toStringAsFixed(1)} units",
            // 보통 일일 허용치를 300~600 정도로 잡습니다. 300 이상일 때 주황/빨강 경고 표시를 해줄 수 있습니다.
            color: step.otu >= 300 ? Colors.orange : colorMain,
          ),
        ],
      ),
      confirm: TextButton(
        onPressed: () => Get.back(),
        child: Text(
          "Close",
          style: TextStyle(fontWeight: FontWeight.bold, color: colorMain),
        ),
      ),
    );
  }

  // 다이얼로그 내부 요소 헬퍼
  Widget _buildDetailRow(
    IconData icon,
    String label,
    String value, {
    Color? color,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color ?? Colors.black54),
          SizedBox(width: 10),
          Text(
            "$label : ",
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: color ?? Colors.black87,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class _StepArrowClipper extends CustomClipper<Path> {
  final bool hasLeftNotch;
  final bool hasRightTip;

  _StepArrowClipper({required this.hasLeftNotch, required this.hasRightTip});

  @override
  Path getClip(Size size) {
    final Path path = Path();
    final double tipWidth = 14;
    final double notchWidth = 10;

    final double leftX = hasLeftNotch ? notchWidth : 0;
    final double rightBodyX = hasRightTip ? size.width - tipWidth : size.width;

    path.moveTo(leftX, 0);
    path.lineTo(rightBodyX, 0);

    if (hasRightTip) {
      path.lineTo(size.width, size.height / 2);
      path.lineTo(rightBodyX, size.height);
    } else {
      path.lineTo(rightBodyX, size.height);
    }

    path.lineTo(leftX, size.height);

    if (hasLeftNotch) {
      path.lineTo(0, size.height / 2);
    }

    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant _StepArrowClipper oldClipper) {
    return oldClipper.hasLeftNotch != hasLeftNotch ||
        oldClipper.hasRightTip != hasRightTip;
  }
}

// ==========================================
// 다이브 프로필 차트 위젯 (fl_chart 활용)
// ==========================================
class DiveProfileChart extends StatelessWidget {
  final List<DiveStep> profile;
  final double totalDiveTime;

  const DiveProfileChart({
    super.key,
    required this.profile,
    required this.totalDiveTime,
  });

  @override
  Widget build(BuildContext context) {
    if (profile.isEmpty) return const SizedBox();

    List<LineChartBarData> lineBars = [];
    List<LineChartBarData> profileBars = [];
    List<FlSpot> allSpots = [const FlSpot(0, 0)];

    // 💡 1. 실링 시작을 nullSpot으로 초기화 (0분일 때 수면에 빨간 선 그리지 않음)
    List<FlSpot> ceilingSpots = [FlSpot.nullSpot];

    double currentTime = 0.0;
    double currentDepth = 0.0;
    double maxDepth = 0.0;

    for (var step in profile) {
      if (step.depth > maxDepth) maxDepth = step.depth.toDouble();

      if (step.time <= 0) continue;

      double nextTime = currentTime + step.time;
      double nextDepth = step.depth.toDouble();

      // 💡 1. 실링이 0보다 클 때(Deco 상태)만 점을 찍고, 아니면 끊어버림(nullSpot)
      if (step.ceiling > 0) {
        ceilingSpots.add(FlSpot(nextTime, -step.ceiling.toDouble()));
      } else {
        ceilingSpots.add(FlSpot.nullSpot);
      }

      Color segmentColor = step.gasUsed.purpose == GasPurpose.bottom
          ? Colors.blueAccent
          : Colors.orangeAccent;

      profileBars.add(
        LineChartBarData(
          spots: [
            FlSpot(currentTime, -currentDepth),
            FlSpot(nextTime, -nextDepth),
          ],
          isCurved: false,
          color: segmentColor,
          barWidth: 2,
          isStrokeCapRound: true,
          dotData: FlDotData(
            show:
                step.phase == 'Deco Stop' ||
                step.phase == 'Level Stay' ||
                step.phase == 'Safety Stop',
            getDotPainter: (spot, percent, barData, index) {
              return FlDotCirclePainter(
                radius: 3,
                color: segmentColor,
                strokeWidth: 1,
                strokeColor: Colors.white,
              );
            },
          ),
        ),
      );

      allSpots.add(FlSpot(nextTime, -nextDepth));
      currentTime = nextTime;
      currentDepth = nextDepth;
    }

    //[Layer Index 0] 투명 배경 영역
    lineBars.add(
      LineChartBarData(
        spots: allSpots,
        color: Colors.blueAccent.withOpacity(0.0),
        dotData: const FlDotData(show: false),
        belowBarData: BarAreaData(
          show: true,
          color: Colors.lightBlue.withOpacity(0.1),
        ),
      ),
    );

    // [Layer Index 1] 데코 실링(Ceiling) 라인 (빨간색 점선)
    lineBars.add(
      LineChartBarData(
        spots: ceilingSpots,
        isCurved: false,
        color: Colors.redAccent,
        barWidth: 1,
        // isStrokeCapRound: true,
        // dashArray: [5, 5],
        dotData: const FlDotData(show: false),
      ),
    );

    //[Layer Index 2 이상] 다이브 프로필 라인들 추가
    lineBars.addAll(profileBars);

    double finalMaxX = currentTime > totalDiveTime
        ? currentTime
        : totalDiveTime;
    if (finalMaxX <= 0) finalMaxX = 10;
    double xInterval = (finalMaxX / 5).clamp(1, 999).toDouble();

    return Container(
      height: 300,
      padding: const EdgeInsets.only(right: 20, top: 20, bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.withOpacity(0.3)),
      ),
      child: LineChart(
        LineChartData(
          lineBarsData: lineBars,
          minX: 0,
          maxX: finalMaxX + (finalMaxX * 0.05),
          minY: -(maxDepth + 5),
          maxY: 2,
          clipData: const FlClipData.all(),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: true,
            horizontalInterval: 10,
            getDrawingHorizontalLine: (value) =>
                FlLine(color: Colors.grey.withOpacity(0.2), strokeWidth: 1),
            getDrawingVerticalLine: (value) =>
                FlLine(color: Colors.grey.withOpacity(0.2), strokeWidth: 1),
          ),
          titlesData: FlTitlesData(
            show: true,
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            bottomTitles: AxisTitles(
              axisNameWidget: const Text(
                "Time (min)",
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
              axisNameSize: 20,
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 30,
                interval: xInterval,
                getTitlesWidget: (value, meta) {
                  return SideTitleWidget(
                    meta: meta,
                    child: Text(
                      value.toInt().toString(),
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.black87,
                      ),
                    ),
                  );
                },
              ),
            ),
            leftTitles: AxisTitles(
              axisNameWidget: const Text(
                "Depth (m)",
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
              axisNameSize: 20,
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 35,
                interval: 10,
                getTitlesWidget: (value, meta) {
                  if (value > 0) return const SizedBox();
                  return SideTitleWidget(
                    meta: meta,
                    child: Text(
                      value.abs().toInt().toString(),
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.black87,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          borderData: FlBorderData(
            show: true,
            border: Border(
              bottom: BorderSide(color: Colors.grey.withAlpha(100), width: 1),
              left: BorderSide(color: Colors.grey.withAlpha(100), width: 1),
            ),
          ),
          lineTouchData: LineTouchData(
            // 💡 마우스 hover 시 나타나는 세로 선을 '가늘고 연한 점선'으로 수정
            getTouchedSpotIndicator:
                (LineChartBarData barData, List<int> spotIndexes) {
                  return spotIndexes.map((index) {
                    return TouchedSpotIndicatorData(
                      FlLine(
                        color: Colors.grey.withAlpha(100), // 연한 회색
                        strokeWidth: 2, // 아주 가는 굵기
                        dashArray: [3, 3], // 점선 효과 (선 길이 3, 여백 3)
                      ),
                      FlDotData(
                        show: true,
                        getDotPainter: (spot, percent, barData, index) {
                          return FlDotCirclePainter(
                            radius: 4,
                            color: barData.color ?? Colors.blueAccent,
                            strokeWidth: 2,
                            strokeColor: Colors.white,
                          );
                        },
                      ),
                    );
                  }).toList();
                },
            touchTooltipData: LineTouchTooltipData(
              tooltipBorderRadius: BorderRadius.all(Radius.circular(5)),
              getTooltipItems: (touchedSpots) {
                return touchedSpots.map((spot) {
                  if (spot.barIndex == 0 || spot.barIndex == 1) return null;

                  final firstProfileSpot = touchedSpots.firstWhere(
                    (s) => s.barIndex > 1,
                  );
                  if (spot != firstProfileSpot) return null;

                  double currentCeiling = 0.0;
                  double t = 0.0;
                  for (var s in profile) {
                    if (s.time <= 0) continue;
                    t += s.time;
                    if ((t - spot.x).abs() < 0.01) {
                      currentCeiling = s.ceiling;
                      break;
                    }
                  }

                  return LineTooltipItem(
                    '${spot.x.toInt()} min\n',
                    const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                    children: [
                      TextSpan(
                        text: 'Depth: ${spot.y.abs().toStringAsFixed(1)} m',
                        style: const TextStyle(
                          color: Colors.yellowAccent,
                          fontSize: 12,
                        ),
                      ),
                      if (currentCeiling > 0)
                        TextSpan(
                          text:
                              '\nCeiling: ${currentCeiling.toStringAsFixed(1)} m',
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                    ],
                  );
                }).toList();
              },
            ),
          ),
        ),
      ),
    );
  }
}
