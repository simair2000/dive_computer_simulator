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
  final int time;
  final Cylinder gasUsed;
  final double gasConsumedLiters;

  DiveStep(
    this.phase,
    this.depth,
    this.time,
    this.gasUsed,
    this.gasConsumedLiters,
  );
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

  // final double ascentRate = 10.0;
  // final double descentRate = 20.0;
  final double switchPressureBar = 30.0; // 최소 잔압 임계치

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
    Cylinder? currentGas;

    double maxDiveDepth = input.waypoints.map((e) => e.depth).reduce(max);

    // 2. 멀티레벨 웨이포인트(Waypoints) 순회
    for (int w = 0; w < input.waypoints.length; w++) {
      var wp = input.waypoints[w];

      // 하강 전 기체 체크 (currentGas 파라미터 추가)
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
          profile.add(
            DiveStep("Gas Switch", currentDepth.toInt(), 0, currentGas, 0.0),
          );
        }
      }

      // 2-1. 이동 (Descent or Ascent to next level)
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

        profile.add(
          DiveStep(
            wp.depth > currentDepth ? "Descent" : "Ascent",
            wp.depth.toInt(),
            travelTime.ceil(),
            currentGas,
            travelGasUsed,
          ),
        );
        totalElapsed += travelTime;
        currentDepth = wp.depth;
      }

      // 2-2. 체류 (Level Stay) - 1분 단위 처리
      if (wp.time > 0) {
        int phaseTime = 0;
        double phaseGasUsed = 0.0;

        for (int m = 0; m < wp.time; m++) {
          // currentGas 파라미터 추가
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
                ),
              );
            }
            currentGas = bestStayGas;
            profile.add(
              DiveStep("Gas Switch", currentDepth.toInt(), 0, currentGas, 0.0),
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
            ),
          );
        }
      }
    }

    // 3. 최종 상승 및 감압 (Ascent & Deco)
    while (currentDepth > 0) {
      double nextStop = (currentDepth / 3).floor() * 3.0;
      if (nextStop == currentDepth) nextStop -= 3.0;
      if (nextStop < 0) nextStop = 0;

      double currentGF = _getGfAtDepth(currentDepth, maxDiveDepth);
      double ceiling = _calcCeiling(simN2, simHe, currentGF);

      if (ceiling <= nextStop) {
        // 상승 가능
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

        currentDepth = nextStop;
        totalElapsed += travelTime;

        if (currentDepth > 0) {
          profile.add(
            DiveStep(
              "Ascent",
              currentDepth.toInt(),
              travelTime.ceil(),
              currentGas,
              travelGas,
            ),
          );
        } else {
          profile.add(
            DiveStep("Surface", 0, travelTime.ceil(), currentGas, travelGas),
          );
          break;
        }
      } else {
        // 감압 정지 (Deco Stop) - currentGas 파라미터 추가
        Cylinder? decoGas = _getBestGasAtDepth(
          input.cylinders,
          currentDepth,
          gasConsumption,
          currentGas,
          isDecoPhase: true,
        );
        if (decoGas != null && decoGas != currentGas) {
          currentGas = decoGas;
          profile.add(
            DiveStep("Gas Switch", currentDepth.toInt(), 0, currentGas, 0),
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

        if (profile.last.phase == "Deco Stop" &&
            profile.last.depth == currentDepth.toInt()) {
          var last = profile.removeLast();
          profile.add(
            DiveStep(
              "Deco Stop",
              last.depth,
              last.time + 1,
              last.gasUsed,
              last.gasConsumedLiters + stopGas,
            ),
          );
        } else {
          profile.add(
            DiveStep("Deco Stop", currentDepth.toInt(), 1, currentGas, stopGas),
          );
        }
        totalElapsed += 1.0;
      }
    }

    // 4. 탱크 잔압 검사 및 경고
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
    Cylinder? currentGas, { // 현재 물고 있는 레귤레이터(탱크) 정보 추가
    required bool isDecoPhase,
  }) {
    Cylinder? bestChoice;
    double bestO2 = -1.0;

    // 1. 현재 수심(MOD)에서 호흡 가능한 안전한 탱크들만 필터링
    List<Cylinder> safeCylinders = cylinders.where((c) {
      double mod = isDecoPhase ? c.decoMod : c.bottomMod;
      return mod >= depth;
    }).toList();

    if (safeCylinders.isEmpty) return null;

    // 2. 잔압이 스위치 임계치(30bar) 이하로 떨어진 고갈 탱크 제외
    List<Cylinder> usableCylinders = safeCylinders.where((c) {
      double remainBar =
          c.startPressure - ((consumption[c] ?? 0) / (c.volume * c.count));
      return remainBar > switchPressureBar;
    }).toList();

    // 만약 모든 탱크가 고갈되었다면, 어쩔 수 없이 남은 것 중 써야 하므로 원복
    if (usableCylinders.isEmpty) usableCylinders = safeCylinders;

    if (isDecoPhase) {
      // [상승 및 감압 단계] -> 산소(O2) 비율이 가장 높은 가스(Deco Gas)를 최우선으로 찾음
      for (var c in usableCylinders) {
        if (c.fractionO2 > bestO2) {
          bestO2 = c.fractionO2;
          bestChoice = c;
        } else if (c.fractionO2 == bestO2) {
          // 산소 비율이 동일한 탱크가 여러 개일 경우 (예: EAN50 데코 탱크 2개)
          // 1순위: 현재 물고 있는 탱크를 계속 유지 (잦은 스위칭 방지)
          if (c == currentGas) {
            bestChoice = currentGas;
          }
          // 2순위: 현재 물고 있는 탱크가 아니라면, 잔압이 더 많은 쪽 선택
          else if (bestChoice != currentGas) {
            double remainC =
                c.startPressure -
                ((consumption[c] ?? 0) / (c.volume * c.count));
            double remainBest =
                bestChoice!.startPressure -
                ((consumption[bestChoice] ?? 0) /
                    (bestChoice.volume * bestChoice.count));
            if (remainC > remainBest) bestChoice = c;
          }
        }
      }
    } else {
      // [바닥 하강 및 체류 단계] -> Bottom 가스를 우선
      // 만약 현재 물고 있는 가스가 Bottom 용도이고 여전히 쓸만하다면 절대 바꾸지 않음! (Stickiness)
      if (currentGas != null &&
          usableCylinders.contains(currentGas) &&
          currentGas.purpose == GasPurpose.bottom) {
        return currentGas;
      }

      // Bottom 용도로 지정된 가스들 필터링
      List<Cylinder> bottomGases = usableCylinders
          .where((c) => c.purpose == GasPurpose.bottom)
          .toList();
      if (bottomGases.isEmpty)
        bottomGases = usableCylinders; // Bottom이 없으면 아무거나

      // 남은 Bottom 탱크들 중 잔압이 가장 많은 것을 새롭게 선택
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
}
