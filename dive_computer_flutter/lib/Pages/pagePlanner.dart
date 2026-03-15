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

// ==========================================
// 1. UI 파트 (PagePlanner)
// ==========================================
class PagePlanner extends StatefulWidget {
  const PagePlanner({super.key});

  @override
  State<PagePlanner> createState() => _PagePlannerState();
}

class _PagePlannerState extends State<PagePlanner> {
  final ScrollController _horizontalScrollController = ScrollController();

  final TextEditingController _textControllerTargetDepth =
      TextEditingController();
  final TextEditingController _textControllerBottomTime =
      TextEditingController();
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

  @override
  void dispose() {
    _horizontalScrollController.dispose();
    _textControllerCylinderHe.dispose();
    _textControllerCylinderO2.dispose();
    _textControllerCylinderStartPressure.dispose();
    _textControllerCylinderVolume.dispose();
    _textControllerCylinderName.dispose();
    _textControllerRMV.dispose();
    _textControllerBottomTime.dispose();
    _textControllerTargetDepth.dispose();
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
            tooltip: 'About',
            onPressed: () {
              showGetDialog(
                'About Dive Planner',
                'This Dive Planner is an advanced decompression scheduling tool designed for both recreational and technical divers...\n\n',
              );
            },
            icon: Icon(Icons.help, color: Colors.white),
          ),
        ],
      ),
      body: Row(
        children: [
          Expanded(
            flex: 2,
            child: Container(
              color: colorMain.withAlpha(30),
              padding: EdgeInsets.all(20),
              child: ListView(
                children: [
                  // --- Target Depth, Bottom Time, RMV 입력부 ---
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Target Depth (m)',
                        ).weight(FontWeight.bold).color(colorMain),
                      ),
                      Expanded(
                        child: InputText(
                          width: 100,
                          controller: _textControllerTargetDepth,
                          textAlign: TextAlign.center,
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'^\d*\.?\d*$'),
                            ),
                          ],
                          maxLines: 1,
                          onFieldSubmitted: (value) {},
                        ),
                      ),
                    ],
                  ).marginOnly(bottom: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Bottom time (min)',
                            ).weight(FontWeight.bold).color(colorMain),
                            Text('(Include Descent time)').color(colorMain),
                          ],
                        ),
                      ),
                      Expanded(
                        child: InputText(
                          width: 100,
                          controller: _textControllerBottomTime,
                          textAlign: TextAlign.center,
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'^\d{0,3}$'),
                            ),
                          ],
                          maxLines: 1,
                          onFieldSubmitted: (value) {},
                        ),
                      ),
                    ],
                  ).marginOnly(bottom: 10),
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
                            ).color(colorMain),
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
                          onFieldSubmitted: (value) {},
                        ),
                      ),
                    ],
                  ),
                  horizontalLine(),
                  Text('Cylinder')
                      .weight(FontWeight.bold)
                      .color(colorMain)
                      .marginOnly(bottom: 10),

                  // --- Cylinder 세부 입력부 ---
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
                          onFieldSubmitted: (value) {},
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
                          onFieldSubmitted: (value) {},
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
                          onFieldSubmitted: (value) {},
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

    // [수정점] 기체 성분 논리적 무결성 체크
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
                      Text(
                            '${cylinder.name}\nVolume : ${cylinder.totalLiters} L\nRemain : ${remain.toStringAsFixed(1)} L\n${remainingPressure}bar',
                          )
                          .color(colorMain)
                          .align(TextAlign.center)
                          .marginOnly(top: 10),
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
        // 상단 요약 카드
        _buildSummaryCard(),
        const SizedBox(height: 20),

        Text('Dive Profile')
            .weight(FontWeight.bold)
            .color(colorMain)
            .size(18)
            .marginOnly(bottom: 15),

        // 타임라인 리스트
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

    // 페이즈별 아이콘 및 색상 분기
    switch (profile.phase) {
      case 'Descent':
        stepIcon = Icons.south_east;
        stepColor = Colors.blue;
        break;
      case 'Bottom':
        stepIcon = Icons.anchor;
        stepColor = Colors.indigoAccent; // 커스텀 컬러 혹은 Colors.indigo
        break;
      case 'Ascent':
        stepIcon = Icons.north_east;
        stepColor = Colors.lightBlue;
        break;
      case 'Deco':
        stepIcon = Icons.timer_outlined;
        stepColor = Colors.orange;
        break;
      case 'Gas Switch':
        stepIcon = Icons.published_with_changes;
        stepColor = Colors.purple;
        break;
    }

    return Stack(
      children: [
        // 타임라인 왼쪽 점
        Positioned(
          left: -6,
          top: 20,
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: stepColor, shape: BoxShape.circle),
          ),
        ),
        Container(
          margin: EdgeInsets.only(left: 20, bottom: 10),
          padding: EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: stepColor.withAlpha(15),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: stepColor.withAlpha(50)),
          ),
          child: Row(
            children: [
              // 왼쪽: 아이콘 및 페이즈 명
              Column(
                children: [
                  Icon(stepIcon, color: stepColor, size: 28),
                  Text(
                    phaseName,
                  ).size(10).color(stepColor).weight(FontWeight.bold),
                ],
              ).marginOnly(right: 15),

              // 중앙: 수심 및 시간 정보
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

              // 오른쪽: 사용 기체 태그
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
      ],
    );
  }

  // 요약 카드 (총 시간 등)
  Widget _buildSummaryCard() {
    bool isFeasible = _planResult!.isFeasible;
    List<String> warnings = _planResult!.warnings;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        // 계획 가능 여부에 따라 배경색 변경
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
              // 상태 아이콘
              Icon(
                isFeasible ? Icons.check_circle : Icons.dangerous,
                color: isFeasible ? Colors.green : Colors.red,
                size: 40,
              ).marginOnly(right: 15),

              // 핵심 정보 (상태 및 총 시간)
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

          // 경고 메시지가 있을 경우 표시되는 영역
          if (warnings.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Divider(height: 1, thickness: 1, color: Colors.black12),
            ),
            ...warnings
                .map(
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
                )
                .toList(),
          ],
        ],
      ),
    );
  }

  void _startDivePlan() {
    if (textIsEmpty(_textControllerTargetDepth.text)) {
      showSnackbar('Error', 'Please enter target depth');
      return;
    }
    if (textIsEmpty(_textControllerBottomTime.text)) {
      showSnackbar('Error', 'Please enter bottom time');
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
      targetDepth: double.parse(_textControllerTargetDepth.text),
      bottomTime: int.parse(_textControllerBottomTime.text),
      rmv: double.parse(_textControllerRMV.text),
      cylinders: cylinders,
    );

    // APref 값 가져올 때 발생할 수 있는 오류 방어 처리
    double gfHighVal = 0.85;
    double gfLowVal = 0.30;
    try {
      gfHighVal = APref.getData(AprefKey.GF_HIGH) ?? 0.85;
      gfLowVal = APref.getData(AprefKey.GF_LOW) ?? 0.30;
    } catch (_) {}

    DivePlanner2 planner = DivePlanner2(gfHigh: gfHighVal, gfLow: gfLowVal);
    _planResult = planner.generatePlan(input);
    showPlanDetailDialog(_planResult!, input);
    setState(() {});
  }

  void showPlanDetailDialog(DivePlanResult result, DivePlanInput input) {
    // 1. 가스 소모 내역 문자열 생성
    String gasSummary = result.gasConsumption.entries
        .map((e) {
          int remain = result.remainingPressure[e.key] ?? 0;
          return "• ${e.key.name}: ${e.value.toInt()}L 소모 (잔압: ${remain} bar)";
        })
        .join("\n");

    // 2. 경고 사항 문자열 생성
    String warnings = result.warnings.isEmpty
        ? "✅ 안전 주의사항 없음"
        : "⚠️ 경고:\n${result.warnings.map((w) => "- $w").join("\n")}";

    // 3. 주요 감압 정보 추출
    int firstStop = result.profile
        .firstWhere(
          (s) => s.phase == "Deco Stop",
          orElse: () => DiveStep("", 0, 0, input.cylinders.first, 0),
        )
        .depth;

    double gfHighVal = 0.85;
    double gfLowVal = 0.30;
    try {
      gfHighVal = APref.getData(AprefKey.GF_HIGH) ?? 0.85;
      gfLowVal = APref.getData(AprefKey.GF_LOW) ?? 0.30;
    } catch (_) {}

    Get.defaultDialog(
      contentPadding: EdgeInsets.all(20),
      title: "Dive Plan Summary",
      titleStyle: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // --- 기본 정보 ---
          _buildSectionTitle("📊 기본 다이빙 정보"),
          _buildInfoRow("목표 수심", "${input.targetDepth}m"),
          _buildInfoRow("바닥 체류", "${input.bottomTime}분"),
          _buildInfoRow("총 다이빙 시간", "${result.totalDiveTime.toInt()}분"),
          _buildInfoRow("알고리즘", "Buhlmann ZHL-16C"),
          _buildInfoRow(
            "GF 설정",
            "${(gfLowVal * 100).toInt()}/${(gfHighVal * 100).toInt()}",
          ),

          Divider(),

          // --- 감압 정보 ---
          _buildSectionTitle("⚓ 감압/상승 정보"),
          _buildInfoRow(
            "첫 정지 수심",
            firstStop > 0 ? "${firstStop}m" : "무감압(NDL)",
          ),
          _buildInfoRow("최종 정지 수심", "3m"),
          _buildInfoRow("상승 속도", "10m/min"),

          Divider(),

          // --- 가스 정보 ---
          _buildSectionTitle("⛽ 가스 소모 및 잔압"),
          Text(gasSummary, style: TextStyle(fontSize: 13)),

          SizedBox(height: 10),

          // --- 경고창 (있을 경우에만 강조) ---
          Container(
            padding: EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: result.isFeasible
                  ? Colors.blue.withOpacity(0.1)
                  : Colors.red.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              warnings,
              style: TextStyle(
                fontSize: 12,
                color: result.isFeasible ? Colors.blue[800] : Colors.red[800],
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      confirm: TextButton(
        onPressed: () => Get.back(),
        child: Text("확인", style: TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }

  // 헬퍼 위젯: 섹션 타이틀
  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: Colors.blueGrey,
        ),
      ),
    );
  }

  // 헬퍼 위젯: 데이터 행
  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: 13, color: Colors.black54)),
          Text(
            value,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}
