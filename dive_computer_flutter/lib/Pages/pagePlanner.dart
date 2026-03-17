// 기존 pagePlanner.dart 전체를 아래 코드로 교체하시면 됩니다. (불필요한 입력 컨트롤러 제거 및 웨이포인트 UI 추가)

import 'dart:math';

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

class PagePlanner extends StatefulWidget {
  const PagePlanner({super.key});

  @override
  State<PagePlanner> createState() => _PagePlannerState();
}

class _PagePlannerState extends State<PagePlanner> {
  final ScrollController _horizontalScrollController = ScrollController();

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
  int _cylinderPurpose = 0; // 0: Bottom, 1: Deco

  @override
  void dispose() {
    _horizontalScrollController.dispose();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Diving Planner').color(Colors.white),
        leading: Icon(Icons.assignment, color: Colors.white, size: 30),
        backgroundColor: colorMain,
        actions: [
          IconButton(
            tooltip: 'Go to the diving simulator',
            onPressed: () {
              context.goNamed(RoutePage.home.name);
            },
            icon: Icon(Icons.scuba_diving, color: Colors.white),
          ),
          IconButton(
            tooltip: 'Go to the settings',
            onPressed: () {
              context.pushNamed(RoutePage.settings.name);
            },
            icon: Icon(Icons.settings, color: Colors.white),
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
            icon: Icon(Icons.help, color: Colors.white),
          ),
        ],
      ),
      body: Row(
        children: [
          // 왼쪽: 설정 및 입력 (Waypoints & Cylinders)
          Expanded(
            flex: 2,
            child: Container(
              color: colorMain.withAlpha(30),
              padding: EdgeInsets.all(20),
              child: ListView(
                children: [
                  // --- Multi-Level Waypoints 입력부 ---
                  Text('Dive Plan (Multi-Level)')
                      .weight(FontWeight.bold)
                      .color(colorMain)
                      .marginOnly(bottom: 10),
                  Container(
                    padding: EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: colorMain.withOpacity(0.3)),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Depth (m)',
                              ).color(colorMain).size(13),
                            ),
                            Expanded(
                              child: Text(
                                'Stay Time (min)',
                              ).color(colorMain).size(13),
                            ),
                            SizedBox(width: 40), // 버튼 여백
                          ],
                        ).marginOnly(bottom: 5),
                        Row(
                          children: [
                            Expanded(
                              child: InputText(
                                controller: _textControllerWpDepth,
                                textAlign: TextAlign.center,
                                inputFormatters: [
                                  FilteringTextInputFormatter.allow(
                                    RegExp(r'^\d*\.?\d*$'),
                                  ),
                                ],
                                maxLines: 1,
                              ).marginOnly(right: 10),
                            ),
                            Expanded(
                              child: InputText(
                                controller: _textControllerWpTime,
                                textAlign: TextAlign.center,
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                ],
                                maxLines: 1,
                              ).marginOnly(right: 10),
                            ),
                            IconButton(
                              onPressed: _addWaypoint,
                              icon: Icon(
                                Icons.add_box,
                                color: colorMain,
                                size: 35,
                              ),
                              padding: EdgeInsets.zero,
                            ),
                          ],
                        ),
                        if (waypoints.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          const Divider(height: 1),
                          const SizedBox(height: 10),
                          ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: waypoints.length,
                            itemBuilder: (context, index) {
                              var wp = waypoints[index];
                              return Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    '${index + 1}.',
                                  ).weight(FontWeight.bold).color(colorMain),
                                  Text('${wp.depth} m').color(Colors.black87),
                                  Text('${wp.time} min').color(Colors.black87),
                                  IconButton(
                                    icon: Icon(
                                      Icons.delete,
                                      color: Colors.redAccent,
                                      size: 20,
                                    ),
                                    onPressed: () {
                                      setState(() {
                                        waypoints.removeAt(index);
                                      });
                                    },
                                  ),
                                ],
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
                            Text(
                              'RMV',
                            ).weight(FontWeight.bold).color(colorMain),
                            Text(
                              '(Respiratory Minute Volume)',
                            ).color(colorMain).size(11),
                          ],
                        ),
                      ),
                      Expanded(
                        child: InputText(
                          width: 100,
                          controller: _textControllerRMV,
                          textAlign: TextAlign.center,
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'^\d*\.?\d*$'),
                            ),
                          ],
                          maxLines: 1,
                        ),
                      ),
                    ],
                  ),
                  horizontalLine(),

                  // --- Cylinder 세부 입력부 ---
                  Text('Gas Cylinders')
                      .weight(FontWeight.bold)
                      .color(colorMain)
                      .marginOnly(bottom: 10),
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
                            FilteringTextInputFormatter.allow(
                              RegExp(r'^\d*\.?\d*$'),
                            ),
                          ],
                          maxLines: 1,
                        ),
                      ),
                    ],
                  ).marginOnly(bottom: 5),
                  Row(
                    children: [
                      Expanded(
                        child: Text('Start Pressure (bar)').color(colorMain),
                      ),
                      Expanded(
                        child: InputText(
                          controller: _textControllerCylinderStartPressure,
                          textAlign: TextAlign.center,
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'^\d*\.?\d*$'),
                            ),
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
                                color: _cylinderPurpose == 0
                                    ? colorMain
                                    : Colors.grey,
                                child: Text('Bottom').color(Colors.white),
                                onPressed: () =>
                                    setState(() => _cylinderPurpose = 0),
                              ).marginOnly(right: 5),
                            ),
                            Expanded(
                              child: Button(
                                height: 46,
                                color: _cylinderPurpose == 1
                                    ? Colors.orange
                                    : Colors.grey,
                                child: Text('Deco').color(Colors.white),
                                onPressed: () =>
                                    setState(() => _cylinderPurpose = 1),
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
                            FilteringTextInputFormatter.allow(
                              RegExp(r'^\d{0,3}$'),
                            ),
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
                            FilteringTextInputFormatter.allow(
                              RegExp(r'^\d{0,2}$'),
                            ),
                          ],
                          maxLines: 1,
                        ),
                      ),
                    ],
                  ).marginOnly(bottom: 10),
                  Align(
                    alignment: AlignmentGeometry.centerRight,
                    child: IconButton(
                      tooltip: 'Add Cylinder',
                      onPressed: () {
                        _addCylinder();
                      },
                      icon: Icon(Icons.add_circle, color: colorMain, size: 40),
                    ),
                  ),
                  horizontalLine(),
                ],
              ),
            ),
          ),

          // 오른쪽: 결과 화면
          Expanded(
            flex: 3,
            child: Container(
              padding: EdgeInsets.all(20),
              child: ListView(
                children: [
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
                  ),
                  _cylinderList(),
                  horizontalLine(),
                  _divePlanResult(),
                ],
              ),
            ),
          ),
        ],
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
  }

  Widget _cylinderList() {
    return SizedBox(
      height: 120,
      child: Scrollbar(
        controller: _horizontalScrollController,
        thumbVisibility: true,
        thickness: 8.0,
        radius: const Radius.circular(10),
        child: ListView.builder(
          shrinkWrap: true,
          controller: _horizontalScrollController,
          scrollDirection: Axis.horizontal,
          itemCount: cylinders.length,
          itemBuilder: (context, index) {
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
          },
        ),
      ),
    );
  }

  Widget _divePlanResult() {
    if (_planResult == null) return Container();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSummaryCard(),
        const SizedBox(height: 20),
        Text('Dive Profile')
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
          margin: EdgeInsets.only(left: 10),
          child: ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _planResult!.isFeasible
                ? _planResult!.profile.length
                : _planResult!.warnings.length,
            itemBuilder: (context, index) {
              return _planResult!.isFeasible
                  ? _buildProfileStepCard(_planResult!.profile[index])
                  : _buildWarningCard(_planResult!.warnings[index]);
            },
          ),
        ),
      ],
    );
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

  Widget _buildProfileStepCard(DiveStep profile) {
    IconData stepIcon = Icons.arrow_downward;
    Color stepColor = colorMain;
    String phaseName = profile.phase;

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
                            '${profile.depth}m',
                          ).size(20).weight(FontWeight.bold).color(colorMain),
                          const SizedBox(width: 10),
                          Text(
                            '${profile.time} min',
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
          _buildDetailRow(Icons.timer, "Time Spent", "${step.time} min"),
          _buildDetailRow(Icons.air, "Gas Used", step.gasUsed.name),
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
