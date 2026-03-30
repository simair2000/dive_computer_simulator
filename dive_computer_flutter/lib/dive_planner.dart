import 'dart:math';
import 'package:dive_computer_flutter/aPref.dart';
import 'buhlmann.dart'; // n2HalfLives, aCoefficients 등 ZHL-16C 상수 임포트

// ==========================================
// 1. 데이터 모델 (Models)
// ==========================================

enum GasPurpose { bottom, deco }

/// 실린더(탱크) 데이터 모델
class Cylinder {
  final String name;
  final double volume; // 리터 (예: 11.1L)
  final int count; // 탱크 갯수 (싱글=1, 더블=2)
  final double startPressure; // 시작 압력 (bar)
  final double fractionO2;
  final double fractionHe;
  final GasPurpose purpose;
  final double? switchDepth;

  Cylinder({
    required this.name,
    required this.volume,
    this.count = 1,
    required this.startPressure,
    required this.fractionO2,
    this.fractionHe = 0.0,
    this.switchDepth,
    this.purpose = GasPurpose.bottom,
  });

  // 감압용 최대운영수심 (PO2 1.6 기준)
  double get decoMod =>
      ((APref.getData(AprefKey.PPO2_DECO) / fractionO2) * 10) - 10;
  // 바닥 체류용 최대운영수심 (PO2 1.4 기준)
  double get bottomMod =>
      ((APref.getData(AprefKey.PPO2_BOTTOM) / fractionO2) * 10) - 10;
  // 전체 가스 보유량(리터)
  double get totalLiters => volume * count * startPressure;

  // END
  double getEnd(double depth) {
    return ((depth + 10) * (1 - fractionHe)) - 10;
  }
}

/// 멀티레벨 다이빙을 위한 웨이포인트(경유지) 모델 (새로 추가)
class DiveWaypoint {
  final double depth; // 목표 수심
  final int time; // 해당 수심에서의 체류 시간 (분)

  DiveWaypoint({required this.depth, required this.time});
}

/// 플래너 입력 데이터 모델 (수정됨)
class DivePlanInput {
  final List<DiveWaypoint> waypoints; // 단일 targetDepth, bottomTime 대신 리스트 사용
  final double rmv;
  final List<Cylinder> cylinders;

  DivePlanInput({
    required this.waypoints,
    required this.rmv,
    required this.cylinders,
  });
}

/// 다이빙 프로필 단계(Step) 모델
class DiveStep {
  final String phase;
  final int depth;
  final double time;
  final Cylinder gasUsed;
  final double gasConsumedLiters;
  final double pO2;
  final double cns;
  final double otu;
  final double ndl;
  final double ceiling;

  DiveStep(
    this.phase,
    this.depth,
    this.time,
    this.gasUsed,
    this.gasConsumedLiters, {
    this.pO2 = 0.0,
    this.cns = 0.0,
    this.otu = 0.0,
    this.ndl = 99.0,
    this.ceiling = 0.0,
  });
}

/// 플래너 결과 데이터 모델
class DivePlanResult {
  final bool isFeasible;
  final List<String> warnings;
  final List<DiveStep> profile;
  final Map<Cylinder, double> gasConsumption;
  final Map<Cylinder, int> remainingPressure;
  final double totalDiveTime;

  DivePlanResult({
    required this.isFeasible,
    required this.warnings,
    required this.profile,
    required this.gasConsumption,
    required this.remainingPressure,
    required this.totalDiveTime,
  });
}

class DivePlanner2 {
  final double gfLow;
  final double gfHigh;
  Buhlmann _buhlmann = Buhlmann();

  // final double ascentRate = 10.0;
  // final double descentRate = 20.0;
  final double switchPressureBar = 30.0; // 최소 잔압 임계치
  final double gasSwitchTimeMinutes = 1.0; // 탱크/가스 교체에 소요되는 시간(분)

  DivePlanner2({this.gfLow = 0.40, this.gfHigh = 0.85});

  DivePlanResult generatePlan(DivePlanInput input) {
    List<String> warnings = [];
    bool isFeasible = true;
    List<DiveStep> profile = [];
    Map<Cylinder, double> gasConsumption = {
      for (var c in input.cylinders) c: 0.0,
    };

    if (input.waypoints.isEmpty) {
      return _failResult(["ERROR: No dive waypoints provided."]);
    }

    double surfacePressure = 1.013;
    double vaporPressure = 0.0627;
    double initialN2 = (surfacePressure - vaporPressure) * 0.79;
    List<double> simN2 = List.filled(NUM_COMPARTMENTS, initialN2);
    List<double> simHe = List.filled(NUM_COMPARTMENTS, 0.0);

    double currentDepth = 0.0;
    double totalElapsed = 0.0;
    double currentCns = 0.0;
    double currentOTU = 0.0;
    Cylinder? currentGas;

    double maxDiveDepth = input.waypoints.map((e) => e.depth).reduce(max);

    for (int w = 0; w < input.waypoints.length; w++) {
      var wp = input.waypoints[w];

      Cylinder? bestGas = _getBestGasAtDepth(
        input.cylinders,
        wp.depth,
        gasConsumption,
        currentGas,
        isDecoPhase: false,
      );
      if (bestGas == null) {
        return _failResult(["ERROR: No suitable gas for depth ${wp.depth}m."]);
      }

      if (currentGas != bestGas) {
        currentGas = bestGas;
        if (currentDepth > 0) {
          if (gasSwitchTimeMinutes > 0) {
            _simulateGasExchange(
              simN2,
              simHe,
              currentDepth,
              currentDepth,
              gasSwitchTimeMinutes,
              currentGas,
            );
            double switchGasUsed =
                gasSwitchTimeMinutes * input.rmv * (1.0 + currentDepth / 10.0);
            gasConsumption[currentGas] =
                gasConsumption[currentGas]! + switchGasUsed;
            double switchPO2 =
                (1.0 + currentDepth / 10.0) * currentGas.fractionO2;
            currentCns += _getCnsRatePerMinute(switchPO2) * gasSwitchTimeMinutes;
            currentOTU += _getOtuRatePerMinute(switchPO2) * gasSwitchTimeMinutes;
            totalElapsed += gasSwitchTimeMinutes;
          }

          double switchPO2 =
              (1.0 + currentDepth / 10.0) * currentGas.fractionO2;
          double switchNdl =
              _calculateNDL(simN2, simHe, currentDepth, currentGas);
          double currentCeiling = _calcCeiling(simN2, simHe, gfHigh);
          profile.add(
            DiveStep(
              "Gas Switch",
              currentDepth.toInt(),
              gasSwitchTimeMinutes,
              currentGas,
              gasSwitchTimeMinutes > 0
                  ? gasSwitchTimeMinutes *
                      input.rmv *
                      (1.0 + currentDepth / 10.0)
                  : 0.0,
              pO2: switchPO2,
              cns: currentCns,
              otu: currentOTU,
              ndl: switchNdl,
              ceiling: currentCeiling,
            ),
          );
        }
      }

      double travelDist = (wp.depth - currentDepth).abs();
      if (travelDist > 0) {
        double speed = wp.depth > currentDepth
            ? ((APref.getData(AprefKey.DescentSpeed) as num?)?.toDouble() ??
                  18.0)
            : ((APref.getData(AprefKey.AscentSpeed) as num?)?.toDouble() ??
                  9.0);
        double travelTime = travelDist / speed;

        _simulateGasExchange(
          simN2,
          simHe,
          currentDepth,
          wp.depth,
          travelTime,
          currentGas!,
        );
        double avgTravelDepth = (currentDepth + wp.depth) / 2.0;
        double travelGasUsed =
            travelTime * input.rmv * (1.0 + avgTravelDepth / 10.0);
        gasConsumption[currentGas] =
            gasConsumption[currentGas]! + travelGasUsed;

        double avgPO2 = (1.0 + avgTravelDepth / 10.0) * currentGas.fractionO2;
        currentCns += _getCnsRatePerMinute(avgPO2) * travelTime;
        currentOTU += _getOtuRatePerMinute(avgPO2) * travelTime;

        double endPO2 = (1.0 + wp.depth / 10.0) * currentGas.fractionO2;
        double currentNdl = _calculateNDL(simN2, simHe, wp.depth, currentGas);
        // 💡 실링 계산 추가
        double currentCeiling = _calcCeiling(simN2, simHe, gfHigh);

        profile.add(
          DiveStep(
            wp.depth > currentDepth ? "Descent" : "Ascent",
            wp.depth.toInt(),
            travelTime,
            currentGas,
            travelGasUsed,
            pO2: endPO2,
            cns: currentCns,
            otu: currentOTU,
            ndl: currentNdl,
            ceiling: currentCeiling,
          ),
        );
        totalElapsed += travelTime;
        currentDepth = wp.depth;
      }

      if (wp.time > 0) {
        double phaseTime = 0;
        double phaseGasUsed = 0.0;
        double lastPO2 = (1.0 + currentDepth / 10.0) * currentGas!.fractionO2;
        double lastNdl = _calculateNDL(simN2, simHe, currentDepth, currentGas);
        double lastCeiling = _calcCeiling(simN2, simHe, gfHigh);

        for (int m = 0; m < wp.time; m++) {
          Cylinder? bestStayGas = _getBestGasAtDepth(
            input.cylinders,
            currentDepth,
            gasConsumption,
            currentGas,
            isDecoPhase: false,
          );

          if (bestStayGas != null && bestStayGas != currentGas) {
            if (phaseTime > 0) {
              profile.add(
                DiveStep(
                  "Level Stay",
                  currentDepth.toInt(),
                  phaseTime,
                  currentGas!,
                  phaseGasUsed,
                  pO2: lastPO2,
                  cns: currentCns,
                  otu: currentOTU,
                  ndl: lastNdl,
                  ceiling: lastCeiling,
                ),
              );
            }
            currentGas = bestStayGas;
            if (gasSwitchTimeMinutes > 0) {
              _simulateGasExchange(
                simN2,
                simHe,
                currentDepth,
                currentDepth,
                gasSwitchTimeMinutes,
                currentGas,
              );
              double switchGasUsed = gasSwitchTimeMinutes *
                  input.rmv *
                  (1.0 + currentDepth / 10.0);
              gasConsumption[currentGas] =
                  gasConsumption[currentGas]! + switchGasUsed;
              lastPO2 = (1.0 + currentDepth / 10.0) * currentGas.fractionO2;
              currentCns +=
                  _getCnsRatePerMinute(lastPO2) * gasSwitchTimeMinutes;
              currentOTU +=
                  _getOtuRatePerMinute(lastPO2) * gasSwitchTimeMinutes;
              totalElapsed += gasSwitchTimeMinutes;
            } else {
              lastPO2 = (1.0 + currentDepth / 10.0) * currentGas.fractionO2;
            }
            lastNdl = _calculateNDL(simN2, simHe, currentDepth, currentGas);
            lastCeiling = _calcCeiling(simN2, simHe, gfHigh);
            profile.add(
              DiveStep(
                "Gas Switch",
                currentDepth.toInt(),
                gasSwitchTimeMinutes,
                currentGas,
                gasSwitchTimeMinutes > 0
                    ? gasSwitchTimeMinutes *
                        input.rmv *
                        (1.0 + currentDepth / 10.0)
                    : 0.0,
                pO2: lastPO2,
                cns: currentCns,
                otu: currentOTU,
                ndl: lastNdl,
                ceiling: lastCeiling,
              ),
            );
            phaseTime = 0;
            phaseGasUsed = 0.0;
          }

          _simulateGasExchange(
            simN2,
            simHe,
            currentDepth,
            currentDepth,
            1.0,
            currentGas!,
          );
          double minGasUsed = input.rmv * (1.0 + currentDepth / 10.0);
          gasConsumption[currentGas] = gasConsumption[currentGas]! + minGasUsed;

          lastPO2 = (1.0 + currentDepth / 10.0) * currentGas.fractionO2;
          currentCns += _getCnsRatePerMinute(lastPO2) * 1.0;
          currentOTU += _getOtuRatePerMinute(lastPO2) * 1.0;
          lastNdl = _calculateNDL(simN2, simHe, currentDepth, currentGas);
          lastCeiling = _calcCeiling(simN2, simHe, gfHigh); // 매 분 갱신

          phaseTime++;
          phaseGasUsed += minGasUsed;
          totalElapsed += 1.0;
        }

        if (phaseTime > 0) {
          profile.add(
            DiveStep(
              "Level Stay",
              currentDepth.toInt(),
              phaseTime,
              currentGas!,
              phaseGasUsed,
              pO2: lastPO2,
              cns: currentCns,
              otu: currentOTU,
              ndl: lastNdl,
              ceiling: lastCeiling,
            ),
          );
        }
      }
    }

    bool safetyStopDone = false; // 안전정지 수행 여부
    bool hasDeco = false; // 감압(Deco) 진입 여부

    while (currentDepth > 0) {
      // 🌟 [핵심 변경]: 매 수심 단계마다 가장 효율적인(산소가 높은) 기체 체크
      // 감압 정지 중이 아니더라도 MOD 내에 들어오면 즉시 스위칭을 시도합니다.
      Cylinder? bestGas = _getBestGasAtDepth(
        input.cylinders,
        currentDepth,
        gasConsumption,
        currentGas,
        isDecoPhase: true, // 상승 단계이므로 DecoPhase 활성화
      );

      if (bestGas != null && bestGas != currentGas) {
        currentGas = bestGas;
        if (gasSwitchTimeMinutes > 0) {
          _simulateGasExchange(
            simN2,
            simHe,
            currentDepth,
            currentDepth,
            gasSwitchTimeMinutes,
            currentGas,
          );
          double switchGasUsed =
              gasSwitchTimeMinutes * input.rmv * (1.0 + currentDepth / 10.0);
          gasConsumption[currentGas] = gasConsumption[currentGas]! + switchGasUsed;
          double switchPO2 =
              (1.0 + currentDepth / 10.0) * currentGas.fractionO2;
          currentCns += _getCnsRatePerMinute(switchPO2) * gasSwitchTimeMinutes;
          currentOTU += _getOtuRatePerMinute(switchPO2) * gasSwitchTimeMinutes;
          totalElapsed += gasSwitchTimeMinutes;
        }

        double switchPO2 = (1.0 + currentDepth / 10.0) * currentGas.fractionO2;
        double switchNdl =
            _calculateNDL(simN2, simHe, currentDepth, currentGas);
        double switchCeiling = _calcCeiling(simN2, simHe, gfHigh);

        profile.add(
          DiveStep(
            "Gas Switch",
            currentDepth.toInt(),
            gasSwitchTimeMinutes,
            currentGas,
            gasSwitchTimeMinutes > 0
                ? gasSwitchTimeMinutes *
                    input.rmv *
                    (1.0 + currentDepth / 10.0)
                : 0.0,
            pO2: switchPO2,
            cns: currentCns,
            otu: currentOTU,
            ndl: switchNdl,
            ceiling: switchCeiling,
          ),
        );
      }

      double nextStop = (currentDepth / 3).floor() * 3.0;
      if (nextStop == currentDepth) nextStop -= 3.0;
      if (nextStop < 0) nextStop = 0;

      double currentGF = _getGfAtDepth(currentDepth, maxDiveDepth);
      double ceiling = _calcCeiling(simN2, simHe, currentGF);

      if (ceiling <= nextStop) {
        double ascentSpeed =
            (APref.getData(AprefKey.AscentSpeed) as num?)?.toDouble() ?? 9.0;

        // 🌟 [추가됨] 무감압 다이빙 & 최대 수심 10m 이상일 때 5m에서 3분 안전정지 실행
        if (nextStop == 0 &&
            maxDiveDepth >= 10.0 &&
            !hasDeco &&
            !safetyStopDone) {
          // 1. 현재 수심에서 5m까지 먼저 상승
          if (currentDepth > 5.0) {
            double travelTime = (currentDepth - 5.0) / ascentSpeed;
            _simulateGasExchange(
              simN2,
              simHe,
              currentDepth,
              5.0,
              travelTime,
              currentGas!,
            );

            double avgDepth = (currentDepth + 5.0) / 2.0;
            double travelGas = travelTime * input.rmv * (1.0 + avgDepth / 10.0);
            gasConsumption[currentGas] =
                gasConsumption[currentGas]! + travelGas;

            double avgPO2 = (1.0 + avgDepth / 10.0) * currentGas.fractionO2;
            currentCns += _getCnsRatePerMinute(avgPO2) * travelTime;
            currentOTU += _getOtuRatePerMinute(avgPO2) * travelTime;

            double endPO2 = (1.0 + 5.0 / 10.0) * currentGas.fractionO2;
            double currentNdl = _calculateNDL(simN2, simHe, 5.0, currentGas);
            double currentCeiling = _calcCeiling(simN2, simHe, gfHigh);

            profile.add(
              DiveStep(
                "Ascent",
                5,
                travelTime,
                currentGas,
                travelGas,
                pO2: endPO2,
                cns: currentCns,
                otu: currentOTU,
                ndl: currentNdl,
                ceiling: currentCeiling,
              ),
            );
            currentDepth = 5.0;
            totalElapsed += travelTime;
          }

          // 2. 5m에서 3분간 안전정지 (Safety Stop)
          double stopTime = 3.0;
          _simulateGasExchange(simN2, simHe, 5.0, 5.0, stopTime, currentGas!);
          double stopGas = stopTime * input.rmv * (1.0 + 5.0 / 10.0);
          gasConsumption[currentGas] = gasConsumption[currentGas]! + stopGas;

          double po2 = (1.0 + 5.0 / 10.0) * currentGas.fractionO2;
          currentCns += _getCnsRatePerMinute(po2) * stopTime;
          currentOTU += _getOtuRatePerMinute(po2) * stopTime;
          double stopNdl = _calculateNDL(simN2, simHe, 5.0, currentGas);
          double stopCeiling = _calcCeiling(simN2, simHe, gfHigh);

          profile.add(
            DiveStep(
              "Safety Stop",
              5,
              stopTime,
              currentGas,
              stopGas,
              pO2: po2,
              cns: currentCns,
              otu: currentOTU,
              ndl: stopNdl,
              ceiling: stopCeiling,
            ),
          );
          totalElapsed += stopTime;
          safetyStopDone = true;

          continue; // 3분 쉬었으니 다음 루프를 돌아 5m -> 0m (수면) 상승을 마저 진행합니다.
        }

        double travelTime =
            (currentDepth - nextStop) /
            ((APref.getData(AprefKey.AscentSpeed) as num?)?.toDouble() ?? 9.0);
        _simulateGasExchange(
          simN2,
          simHe,
          currentDepth,
          nextStop,
          travelTime,
          currentGas!,
        );

        double avgDepth = (currentDepth + nextStop) / 2.0;
        double travelGas = travelTime * input.rmv * (1.0 + avgDepth / 10.0);
        gasConsumption[currentGas] = gasConsumption[currentGas]! + travelGas;

        double avgPO2 = (1.0 + avgDepth / 10.0) * currentGas.fractionO2;
        currentCns += _getCnsRatePerMinute(avgPO2) * travelTime;
        currentOTU += _getOtuRatePerMinute(avgPO2) * travelTime;

        double endPO2 = (1.0 + nextStop / 10.0) * currentGas.fractionO2;
        double currentNdl = _calculateNDL(simN2, simHe, nextStop, currentGas);
        double currentCeiling = _calcCeiling(simN2, simHe, gfHigh);

        currentDepth = nextStop;
        totalElapsed += travelTime;

        if (currentDepth > 0) {
          profile.add(
            DiveStep(
              "Ascent",
              currentDepth.toInt(),
              travelTime,
              currentGas,
              travelGas,
              pO2: endPO2,
              cns: currentCns,
              otu: currentOTU,
              ndl: currentNdl,
              ceiling: currentCeiling,
            ),
          );
        } else {
          profile.add(
            DiveStep(
              "Surface",
              0,
              travelTime,
              currentGas,
              travelGas,
              pO2: endPO2,
              cns: currentCns,
              otu: currentOTU,
              ndl: currentNdl,
              ceiling: currentCeiling,
            ),
          );
          break;
        }
      } else {
        hasDeco = true;

        Cylinder? decoGas = _getBestGasAtDepth(
          input.cylinders,
          currentDepth,
          gasConsumption,
          currentGas,
          isDecoPhase: true,
        );
        if (decoGas != null && decoGas != currentGas) {
          currentGas = decoGas;
          if (gasSwitchTimeMinutes > 0) {
            _simulateGasExchange(
              simN2,
              simHe,
              currentDepth,
              currentDepth,
              gasSwitchTimeMinutes,
              currentGas,
            );
            double switchGasUsed =
                gasSwitchTimeMinutes * input.rmv * (1.0 + currentDepth / 10.0);
            gasConsumption[currentGas] =
                gasConsumption[currentGas]! + switchGasUsed;
            double switchPO2 =
                (1.0 + currentDepth / 10.0) * currentGas.fractionO2;
            currentCns += _getCnsRatePerMinute(switchPO2) * gasSwitchTimeMinutes;
            currentOTU += _getOtuRatePerMinute(switchPO2) * gasSwitchTimeMinutes;
            totalElapsed += gasSwitchTimeMinutes;
          }

          double switchPO2 =
              (1.0 + currentDepth / 10.0) * currentGas.fractionO2;
          double switchNdl =
              _calculateNDL(simN2, simHe, currentDepth, currentGas);
          double switchCeiling = _calcCeiling(simN2, simHe, gfHigh);
          profile.add(
            DiveStep(
              "Gas Switch",
              currentDepth.toInt(),
              gasSwitchTimeMinutes,
              currentGas,
              gasSwitchTimeMinutes > 0
                  ? gasSwitchTimeMinutes *
                      input.rmv *
                      (1.0 + currentDepth / 10.0)
                  : 0.0,
              pO2: switchPO2,
              cns: currentCns,
              otu: currentOTU,
              ndl: switchNdl,
              ceiling: switchCeiling,
            ),
          );
        }

        _simulateGasExchange(
          simN2,
          simHe,
          currentDepth,
          currentDepth,
          1.0,
          currentGas!,
        );
        double stopGas = input.rmv * (1.0 + currentDepth / 10.0);
        gasConsumption[currentGas] = gasConsumption[currentGas]! + stopGas;

        double po2 = (1.0 + currentDepth / 10.0) * currentGas.fractionO2;
        currentCns += _getCnsRatePerMinute(po2) * 1.0;
        currentOTU += _getOtuRatePerMinute(po2) * 1.0;
        double currentNdl = _calculateNDL(
          simN2,
          simHe,
          currentDepth,
          currentGas,
        );
        double currentCeiling = _calcCeiling(simN2, simHe, gfHigh);

        if (profile.isNotEmpty &&
            profile.last.phase == "Deco Stop" &&
            profile.last.depth == currentDepth.toInt() &&
            profile.last.gasUsed == currentGas) {
          var last = profile.removeLast();
          profile.add(
            DiveStep(
              "Deco Stop",
              last.depth,
              last.time + 1,
              last.gasUsed,
              last.gasConsumedLiters + stopGas,
              pO2: po2,
              cns: currentCns,
              otu: currentOTU,
              ndl: currentNdl,
              ceiling: currentCeiling,
            ),
          );
        } else {
          profile.add(
            DiveStep(
              "Deco Stop",
              currentDepth.toInt(),
              1,
              currentGas,
              stopGas,
              pO2: po2,
              cns: currentCns,
              otu: currentOTU,
              ndl: currentNdl,
              ceiling: currentCeiling,
            ),
          );
        }
        totalElapsed += 1.0;
      }
    }

    Map<Cylinder, int> remainingPressure = {};
    for (var c in input.cylinders) {
      double usedBar = gasConsumption[c]! / (c.volume * c.count);
      int remain = (c.startPressure - usedBar).toInt();
      remainingPressure[c] = remain;
      if (remain < switchPressureBar) {
        if (remain < 0) {
          isFeasible = false;
          warnings.add("CRITICAL: Gas [${c.name}] completely depleted!");
        } else {
          warnings.add(
            "WARNING: Low gas pressure in [${c.name}] ($remain bar).",
          );
        }
      }
    }

    return DivePlanResult(
      isFeasible: isFeasible,
      warnings: warnings,
      profile: profile,
      gasConsumption: gasConsumption,
      remainingPressure: remainingPressure,
      totalDiveTime: totalElapsed,
    );
  }

  // 수심에 따른 GF 결정 (Shearwater 스타일 선형 보간)
  double _getGfAtDepth(double depth, double maxDepth) {
    if (maxDepth <= 0) return gfHigh;
    if (depth <= 0) return gfHigh;
    // 수심이 깊을수록 gfLow에 가깝고, 얕아질수록 gfHigh에 가까워짐
    return gfHigh - (gfHigh - gfLow) * (depth / maxDepth);
  }

  // 최적의 가스 선택 (쉬어워터는 MOD 이내 산소 함량이 가장 높은 가스 선택)
  Cylinder? _getBestGasAtDepth(
    List<Cylinder> cylinders,
    double depth,
    Map<Cylinder, double> consumption,
    Cylinder? currentGas, {
    required bool isDecoPhase,
  }) {
    Cylinder? bestChoice;
    double bestO2 = -1.0;

    // 1. 현재 수심에서 호흡 가능한 안전한 탱크 필터링
    List<Cylinder> safeCylinders = cylinders.where((c) {
      double mod = isDecoPhase ? c.decoMod : c.bottomMod;
      return mod >= (depth - 0.1); // 소수점 오차 방지
    }).toList();

    if (safeCylinders.isEmpty) return null;

    // 2. 잔압이 있는 탱크 필터링
    List<Cylinder> usableCylinders = safeCylinders.where((c) {
      double remainBar =
          c.startPressure - ((consumption[c] ?? 0) / (c.volume * c.count));
      return remainBar > 5; // 최소 5bar 이상 남은 것
    }).toList();

    if (usableCylinders.isEmpty) usableCylinders = safeCylinders;

    if (isDecoPhase) {
      // [상승/감압 단계] -> 산소 농도가 높은 것을 최우선 (가속 감압 목적)
      for (var c in usableCylinders) {
        // 산소가 더 높으면 무조건 후보
        if (c.fractionO2 > bestO2) {
          bestO2 = c.fractionO2;
          bestChoice = c;
        }
        // 산소가 같다면 현재 가스 유지 (잦은 스위칭 방지)
        else if (c.fractionO2 == bestO2) {
          if (c == currentGas) bestChoice = c;
        }
      }

      // 🌟 [핵심 수정]: 현재 가스가 바닥 가스인데, 더 높은 산소의 데코 가스가 사용 가능하다면 스위칭 강제
      if (currentGas != null && bestChoice != null) {
        if (bestChoice.fractionO2 > currentGas.fractionO2) {
          return bestChoice;
        }
      }
    } else {
      // [바닥/하강 단계] -> 기존 바닥 가스 유지 로직
      if (currentGas != null &&
          usableCylinders.contains(currentGas) &&
          currentGas.purpose == GasPurpose.bottom) {
        return currentGas;
      }
      // ... (이하 동일)
      List<Cylinder> bottomGases = usableCylinders
          .where((c) => c.purpose == GasPurpose.bottom)
          .toList();
      if (bottomGases.isEmpty) bottomGases = usableCylinders;
      bottomGases.sort((a, b) {
        double remainA =
            a.startPressure - ((consumption[a] ?? 0) / (a.volume * a.count));
        double remainB =
            b.startPressure - ((consumption[b] ?? 0) / (b.volume * b.count));
        return remainB.compareTo(remainA);
      });
      bestChoice = bottomGases.first;
    }
    return bestChoice;
  }
  // Cylinder? _getBestGasAtDepth(
  //   List<Cylinder> cylinders,
  //   double depth,
  //   Map<Cylinder, double> consumption,
  //   Cylinder? currentGas, { // 현재 물고 있는 레귤레이터(탱크) 정보 추가
  //   required bool isDecoPhase,
  // }) {
  //   Cylinder? bestChoice;
  //   double bestO2 = -1.0;

  //   // 1. 현재 수심(MOD)에서 호흡 가능한 안전한 탱크들만 필터링
  //   List<Cylinder> safeCylinders = cylinders.where((c) {
  //     double mod = isDecoPhase ? c.decoMod : c.bottomMod;
  //     return mod >= depth;
  //   }).toList();

  //   if (safeCylinders.isEmpty) return null;

  //   // 2. 잔압이 스위치 임계치(30bar) 이하로 떨어진 고갈 탱크 제외
  //   List<Cylinder> usableCylinders = safeCylinders.where((c) {
  //     double remainBar =
  //         c.startPressure - ((consumption[c] ?? 0) / (c.volume * c.count));
  //     return remainBar > switchPressureBar;
  //   }).toList();

  //   // 만약 모든 탱크가 고갈되었다면, 어쩔 수 없이 남은 것 중 써야 하므로 원복
  //   if (usableCylinders.isEmpty) usableCylinders = safeCylinders;

  //   if (isDecoPhase) {
  //     // [상승 및 감압 단계] -> 산소(O2) 비율이 가장 높은 가스(Deco Gas)를 최우선으로 찾음
  //     for (var c in usableCylinders) {
  //       if (c.fractionO2 > bestO2) {
  //         bestO2 = c.fractionO2;
  //         bestChoice = c;
  //       } else if (c.fractionO2 == bestO2) {
  //         // 산소 비율이 동일한 탱크가 여러 개일 경우 (예: EAN50 데코 탱크 2개)
  //         // 1순위: 현재 물고 있는 탱크를 계속 유지 (잦은 스위칭 방지)
  //         if (c == currentGas) {
  //           bestChoice = currentGas;
  //         }
  //         // 2순위: 현재 물고 있는 탱크가 아니라면, 잔압이 더 많은 쪽 선택
  //         else if (bestChoice != currentGas) {
  //           double remainC =
  //               c.startPressure -
  //               ((consumption[c] ?? 0) / (c.volume * c.count));
  //           double remainBest =
  //               bestChoice!.startPressure -
  //               ((consumption[bestChoice] ?? 0) /
  //                   (bestChoice.volume * bestChoice.count));
  //           if (remainC > remainBest) bestChoice = c;
  //         }
  //       }
  //     }
  //   } else {
  //     // [바닥 하강 및 체류 단계] -> Bottom 가스를 우선
  //     // 만약 현재 물고 있는 가스가 Bottom 용도이고 여전히 쓸만하다면 절대 바꾸지 않음! (Stickiness)
  //     if (currentGas != null &&
  //         usableCylinders.contains(currentGas) &&
  //         currentGas.purpose == GasPurpose.bottom) {
  //       return currentGas;
  //     }

  //     // Bottom 용도로 지정된 가스들 필터링
  //     List<Cylinder> bottomGases = usableCylinders
  //         .where((c) => c.purpose == GasPurpose.bottom)
  //         .toList();
  //     if (bottomGases.isEmpty) {
  //       bottomGases = usableCylinders; // Bottom이 없으면 아무거나
  //     }

  //     // 남은 Bottom 탱크들 중 잔압이 가장 많은 것을 새롭게 선택
  //     bottomGases.sort((a, b) {
  //       double remainA =
  //           a.startPressure - ((consumption[a] ?? 0) / (a.volume * a.count));
  //       double remainB =
  //           b.startPressure - ((consumption[b] ?? 0) / (b.volume * b.count));
  //       return remainB.compareTo(remainA);
  //     });

  //     bestChoice = bottomGases.first;
  //   }

  //   return bestChoice;
  // }

  // --- 기존의 _simulateGasExchange, _calcSchreiner, _calcCeiling 등은 유지하되 ---
  // --- _calcCeiling에서 사용되는 공식이 Buhlmann 정석인지 확인 ---

  double _calcCeiling(List<double> n2, List<double> he, double gf) {
    double maxCeiling = 0.0;
    for (int i = 0; i < NUM_COMPARTMENTS; i++) {
      double pTotal = n2[i] + he[i];
      double a =
          ((aCoefficients[i] * n2[i]) + (aHeCoefficients[i] * he[i])) / pTotal;
      double b =
          ((bCoefficients[i] * n2[i]) + (bHeCoefficients[i] * he[i])) / pTotal;

      // Buhlmann 정식: P_tol = (P_tissue - a * GF) / (GF / b + 1 - GF)
      double pTol = (pTotal - a * gf) / (gf / b + (1.0 - gf));
      double ceilingDepth = (pTol - 1.013) * 10.0;
      if (ceilingDepth > maxCeiling) maxCeiling = ceilingDepth;
    }
    return maxCeiling;
  }

  void _simulateGasExchange(
    List<double> n2,
    List<double> he,
    double d1,
    double d2,
    double t,
    Cylinder gas,
  ) {
    if (t <= 0) return;
    double fN2 = 1.0 - gas.fractionO2 - gas.fractionHe;
    double fHe = gas.fractionHe;
    double pVap = 0.0627;

    double pAmbStart = 1.013 + d1 / 10.0;
    double pAmbEnd = 1.013 + d2 / 10.0;

    double pN2Start = (pAmbStart - pVap) * fN2;
    double pN2End = (pAmbEnd - pVap) * fN2;
    double rN2 = (pN2End - pN2Start) / t;

    double pHeStart = (pAmbStart - pVap) * fHe;
    double pHeEnd = (pAmbEnd - pVap) * fHe;
    double rHe = (pHeEnd - pHeStart) / t;

    for (int i = 0; i < NUM_COMPARTMENTS; i++) {
      n2[i] = _calcSchreiner(n2[i], pN2Start, rN2, t, n2HalfLives[i]);
      he[i] = _calcSchreiner(he[i], pHeStart, rHe, t, heHalfLives[i]);
    }
  }

  double _calcSchreiner(
    double pi,
    double piGi,
    double r,
    double t,
    double halfLife,
  ) {
    double k = log(2.0) / halfLife;
    return piGi + r * (t - 1 / k) - (piGi - pi - r / k) * exp(-k * t);
  }

  DivePlanResult _failResult(List<String> warnings) {
    return DivePlanResult(
      isFeasible: false,
      warnings: warnings,
      profile: [],
      gasConsumption: {},
      remainingPressure: {},
      totalDiveTime: 0,
    );
  }

  // --- 새로 추가: 1분당 CNS 증가량 계산 (NOAA 테이블 기반) ---
  double _getCnsRatePerMinute(double po2) {
    if (po2 <= 0.5) return 0.0;
    List<double> po2Table = [
      0.5,
      0.6,
      0.7,
      0.8,
      0.9,
      1.0,
      1.1,
      1.2,
      1.3,
      1.4,
      1.5,
      1.6,
    ];
    List<double> timeTable = [
      999999,
      720,
      570,
      450,
      360,
      300,
      240,
      210,
      180,
      150,
      120,
      45,
    ];
    double ratePerMinute = 0.0;

    if (po2 >= 1.6) {
      double r1 = 100.0 / 120.0;
      double r2 = 100.0 / 45.0;
      double slope = (r2 - r1) / (1.6 - 1.5);
      ratePerMinute = r2 + slope * (po2 - 1.6);
    } else {
      for (int i = 0; i < po2Table.length - 1; i++) {
        if (po2 >= po2Table[i] && po2 <= po2Table[i + 1]) {
          double r1 = po2Table[i] == 0.5 ? 0.0 : 100.0 / timeTable[i];
          double r2 = 100.0 / timeTable[i + 1];
          double slope = (r2 - r1) / (po2Table[i + 1] - po2Table[i]);
          ratePerMinute = r1 + slope * (po2 - po2Table[i]);
          break;
        }
      }
    }
    return ratePerMinute;
  }

  // --- 새로 추가: 1분당 OTU 증가량 계산 ---
  // 공식: OTU = 1분 * ((PO2 - 0.5) / 0.5) ^ (5/6)
  double _getOtuRatePerMinute(double po2) {
    if (po2 <= 0.5) return 0.0; // PO2가 0.5 이하일 때는 OTU가 누적되지 않음
    return pow((po2 - 0.5) / 0.5, 5.0 / 6.0).toDouble();
  }

  // --- 새로 추가: 특정 수심에서의 무감압 한계(NDL) 시뮬레이션 ---
  double _calculateNDL(
    List<double> currentN2,
    List<double> currentHe,
    double depth,
    Cylinder gas,
  ) {
    if (depth < 1.2) return 999.0;
    if (!_buhlmann.isDepthSafe(0.0, currentN2, currentHe, gfHigh)) {
      return 0.0; // 이미 데코에 걸린 상태
    }

    List<double> simN2 = List.from(currentN2); // 원본 훼손 방지
    List<double> simHe = List.from(currentHe);

    int minutes = 0;
    while (minutes < 99) {
      _simulateGasExchange(simN2, simHe, depth, depth, 1.0, gas);
      minutes++;
      if (!_buhlmann.isDepthSafe(0.0, simN2, simHe, gfHigh)) {
        return minutes.toDouble();
      }
    }
    return 99.0; // 99분 이상
  }
}
