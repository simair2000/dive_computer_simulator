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
  double get decoMod => ((1.6 / fractionO2) * 10) - 10;
  // 바닥 체류용 최대운영수심 (PO2 1.4 기준)
  double get bottomMod => ((1.4 / fractionO2) * 10) - 10;
  // 전체 가스 보유량(리터)
  double get totalLiters => volume * count * startPressure;
}

/// 플래너 입력 데이터 모델
class DivePlanInput {
  final double targetDepth;
  final int bottomTime;
  final double rmv;
  final List<Cylinder> cylinders;

  DivePlanInput({
    required this.targetDepth,
    required this.bottomTime,
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

// ==========================================
// 2. 핵심 알고리즘 로직 (DivePlanner)
// ==========================================

class DivePlanner {
  final double gfHigh;
  final double gfLow;
  final double switchPressureBar = 50.0; // 탱크 교체를 유도할 최소 잔압 임계점 (50 bar)

  DivePlanner({double gfHigh = 0.85, double gfLow = 0.30})
    : this.gfHigh = gfHigh > 1.0 ? gfHigh / 100.0 : gfHigh,
      this.gfLow = gfLow > 1.0 ? gfLow / 100.0 : gfLow;

  DivePlanResult generatePlan(DivePlanInput input) {
    List<String> warnings = [];
    bool isFeasible = true;
    List<DiveStep> profile = [];
    Map<Cylinder, double> gasConsumption = {
      for (var c in input.cylinders) c: 0.0,
    };

    // 1. 초기 바닥 기체 찾기
    Cylinder? currentGas = _getBestBottomGas(
      input.cylinders,
      input.targetDepth,
      gasConsumption,
    );

    if (currentGas == null) {
      warnings.add(
        "ERROR: No suitable gas found for the target depth (${input.targetDepth}m).",
      );
      return _failResult(warnings);
    }

    if (currentGas.bottomMod < input.targetDepth) {
      warnings.add(
        "WARNING: Target depth exceeds the MOD of the first gas. (PO2 > 1.4)",
      );
      isFeasible = false;
    }

    // 2. 가상 조직(Compartments) 초기화
    double vaporPressure = 0.0627;
    double initialN2 = (1.0 - vaporPressure) * 0.79;
    List<double> simN2 = List.filled(NUM_COMPARTMENTS, initialN2);
    List<double> simHe = List.filled(NUM_COMPARTMENTS, 0.0);

    // 3. 하강 (Descent) 로직
    double descentRate = 18.0;
    try {
      descentRate = APref.getData(AprefKey.DescentSpeed) ?? 18.0;
    } catch (_) {}
    if (descentRate <= 0) descentRate = 18.0;

    int descentTime = (input.targetDepth / descentRate).ceil();
    if (descentTime == 0) descentTime = 1;
    double avgDescentDepth = input.targetDepth / 2.0;

    _simulateGasExchange(
      simN2,
      simHe,
      0.0,
      input.targetDepth,
      descentTime.toDouble(),
      currentGas,
    );
    double descentGas =
        descentTime * input.rmv * (1.0 + avgDescentDepth / 10.0);
    gasConsumption[currentGas] = gasConsumption[currentGas]! + descentGas;

    profile.add(
      DiveStep(
        "Descent",
        input.targetDepth.toInt(),
        descentTime,
        currentGas,
        descentGas,
      ),
    );

    double exactTotalTime = descentTime.toDouble();

    // 4. 바닥 체류 (Bottom)
    int actualBottomTime = input.bottomTime - descentTime;
    if (actualBottomTime < 1) actualBottomTime = 1;

    int phaseTime = 0;
    double phaseGasUsed = 0.0;

    for (int i = 0; i < actualBottomTime; i++) {
      if (_getRemainBar(currentGas!, gasConsumption) <= switchPressureBar) {
        Cylinder? nextGas = _getBestBottomGas(
          input.cylinders,
          input.targetDepth,
          gasConsumption,
        );
        if (nextGas != null && nextGas != currentGas) {
          if (phaseTime > 0) {
            profile.add(
              DiveStep(
                "Bottom",
                input.targetDepth.toInt(),
                phaseTime,
                currentGas,
                phaseGasUsed,
              ),
            );
          }
          phaseTime = 0;
          phaseGasUsed = 0.0;
          currentGas = nextGas;
          profile.add(
            DiveStep(
              "Gas Switch",
              input.targetDepth.toInt(),
              0,
              currentGas,
              0.0,
            ),
          );
        }
      }

      _simulateGasExchange(
        simN2,
        simHe,
        input.targetDepth,
        input.targetDepth,
        1.0,
        currentGas,
      );
      double minGas = input.rmv * (1.0 + input.targetDepth / 10.0);
      gasConsumption[currentGas] = gasConsumption[currentGas]! + minGas;
      phaseTime++;
      phaseGasUsed += minGas;
    }

    exactTotalTime += actualBottomTime.toDouble();

    if (phaseTime > 0) {
      profile.add(
        DiveStep(
          "Bottom",
          input.targetDepth.toInt(),
          phaseTime,
          currentGas!,
          phaseGasUsed,
        ),
      );
    }

    // 5. 상승 및 감압 (Ascent & Deco)
    int currentSimDepth = input.targetDepth.toInt();

    double ascentRate = 9.0;
    try {
      ascentRate = APref.getData(AprefKey.AscentSpeed) ?? 9.0;
    } catch (_) {}
    if (ascentRate <= 0) ascentRate = 9.0;

    // [중요 로직 추가]: 무감압 한계(NDL) 체크
    // 수면(0m)에서 최종 GF(gfHigh) 기준으로 안전한지 평가합니다.
    bool isNDL = _isSafe(0.0, simN2, simHe, gfHigh);

    if (isNDL) {
      // =========================================================
      // 5-1. 무감압 다이빙 (No-Decompression Dive) 처리
      // =========================================================

      // 최대 수심이 10m 이상이었을 경우 통상적으로 5m에서 3분 안전정지를 수행
      bool needSafetyStop = currentSimDepth >= 10;
      int safetyStopDepth = 5;
      int targetFirstStop = needSafetyStop ? safetyStopDepth : 0;

      // 1) 바닥에서 안전정지 수심(또는 수면)까지 단번에 상승
      double travelDist1 = (currentSimDepth - targetFirstStop).toDouble();
      if (travelDist1 > 0) {
        double travelTime1 = travelDist1 / ascentRate;
        _simulateGasExchange(
          simN2,
          simHe,
          currentSimDepth.toDouble(),
          targetFirstStop.toDouble(),
          travelTime1,
          currentGas!,
        );

        double avgTravelDepth1 = (currentSimDepth + targetFirstStop) / 2.0;
        double travelGasUsed1 =
            travelTime1 * input.rmv * (1.0 + avgTravelDepth1 / 10.0);
        gasConsumption[currentGas] =
            gasConsumption[currentGas]! + travelGasUsed1;

        profile.add(
          DiveStep(
            "Ascent",
            targetFirstStop,
            travelTime1.ceil(),
            currentGas,
            travelGasUsed1,
          ),
        );
        exactTotalTime += travelTime1;
        currentSimDepth = targetFirstStop;
      }

      // 2) 안전 정지 (Safety Stop)
      if (needSafetyStop) {
        // 무감압 다이빙이라도 다이버가 EAN50 등 산소 비율이 높은 기체를 지참했다면,
        // 5m에서 안전을 위해 기체 스위칭 후 정지할 수 있도록 유도
        Cylinder? bestSafetyGas = _getBestDecoGas(
          input.cylinders,
          safetyStopDepth.toDouble(),
          gasConsumption,
        );
        if (bestSafetyGas != null && bestSafetyGas != currentGas) {
          currentGas = bestSafetyGas;
          profile.add(
            DiveStep("Gas Switch", safetyStopDepth, 0, currentGas, 0.0),
          );
        }

        double safetyStopTime = 3.0; // 3분 안전정지
        _simulateGasExchange(
          simN2,
          simHe,
          safetyStopDepth.toDouble(),
          safetyStopDepth.toDouble(),
          safetyStopTime,
          currentGas!,
        );

        double safetyStopGas =
            safetyStopTime * input.rmv * (1.0 + safetyStopDepth / 10.0);
        gasConsumption[currentGas] =
            gasConsumption[currentGas]! + safetyStopGas;

        profile.add(
          DiveStep(
            "Safety Stop",
            safetyStopDepth,
            safetyStopTime.toInt(),
            currentGas,
            safetyStopGas,
          ),
        );
        exactTotalTime += safetyStopTime;

        // 3) 안전정지 종료 후 수면으로 상승
        double travelTime2 = safetyStopDepth / ascentRate;
        _simulateGasExchange(
          simN2,
          simHe,
          safetyStopDepth.toDouble(),
          0.0,
          travelTime2,
          currentGas,
        );

        double avgTravelDepth2 = safetyStopDepth / 2.0;
        double travelGasUsed2 =
            travelTime2 * input.rmv * (1.0 + avgTravelDepth2 / 10.0);
        gasConsumption[currentGas] =
            gasConsumption[currentGas]! + travelGasUsed2;

        profile.add(
          DiveStep("Ascent", 0, travelTime2.ceil(), currentGas, travelGasUsed2),
        );
        exactTotalTime += travelTime2;
      }
    } else {
      // =========================================================
      // 5-2. 감압 다이빙 (Decompression Dive) 처리
      // =========================================================
      // 첫 번째 정지 수심 계산 (Deep Stop 또는 첫 Deco Stop)
      int anchorDepth = 0;
      for (int d = 3; d <= currentSimDepth; d += 3) {
        if (!_isSafe(d.toDouble(), simN2, simHe, gfLow)) {
          anchorDepth = d;
          break;
        }
      }
      if (anchorDepth == 0) anchorDepth = (currentSimDepth / 3).ceil() * 3;

      double firstStopDepth = anchorDepth.toDouble();

      double gfAtDepth(double depth) {
        if (depth >= firstStopDepth) return gfLow;
        double fraction = depth / firstStopDepth;
        return gfLow + (gfHigh - gfLow) * (1.0 - fraction);
      }

      while (currentSimDepth > 0) {
        int nextDepth = currentSimDepth - 3;
        if (nextDepth < 0) nextDepth = 0;

        double targetGf = gfAtDepth(nextDepth.toDouble());
        if (targetGf > gfHigh) targetGf = gfHigh;
        if (targetGf < gfLow) targetGf = gfLow;

        phaseTime = 0;
        phaseGasUsed = 0.0;

        // 최적의 감압 기체로 스위칭 시도
        Cylinder? decoGas = _getBestDecoGas(
          input.cylinders,
          currentSimDepth.toDouble(),
          gasConsumption,
        );
        if (decoGas != null && decoGas != currentGas) {
          currentGas = decoGas;
          profile.add(
            DiveStep("Gas Switch", currentSimDepth, 0, currentGas, 0.0),
          );
        }

        // --- 무한 루프 방지 로직 적용 ---
        double ceiling = _calcCeiling(simN2, simHe, targetGf);
        int safetyLimit = 0; // 한 수심에서 최대 체류 시간 제한 (예: 1000분)

        // 실링 수심이 다음 수심(nextDepth)보다 깊은 동안 정지 유지
        // 정밀도 오차 방지를 위해 0.01의 여유를 둠
        while (ceiling > nextDepth + 0.01) {
          if (safetyLimit > 1440) {
            // 24시간 이상 정지해야 한다면 논리적 오류로 판단
            isFeasible = false;
            warnings.add(
              "CRITICAL: Infinite deco loop detected at ${currentSimDepth}m. Please check gas oxygen/helium levels.",
            );
            break;
          }

          _simulateGasExchange(
            simN2,
            simHe,
            currentSimDepth.toDouble(),
            currentSimDepth.toDouble(),
            1.0,
            currentGas!,
          );

          double minGas = input.rmv * (1.0 + currentSimDepth / 10.0);
          gasConsumption[currentGas] = gasConsumption[currentGas]! + minGas;

          phaseTime++;
          phaseGasUsed += minGas;
          exactTotalTime += 1.0;
          safetyLimit++;

          // 매 분마다 실링 재계산
          ceiling = _calcCeiling(simN2, simHe, targetGf);
        }

        if (!isFeasible) break; // 무한 루프 감지 시 탈출

        if (phaseTime > 0) {
          profile.add(
            DiveStep(
              "Deco Stop",
              currentSimDepth,
              phaseTime,
              currentGas!,
              phaseGasUsed,
            ),
          );
        }

        // 다음 수심으로 상승
        double travelDistance = (currentSimDepth - nextDepth).toDouble();
        double travelTime = travelDistance / ascentRate;

        _simulateGasExchange(
          simN2,
          simHe,
          currentSimDepth.toDouble(),
          nextDepth.toDouble(),
          travelTime,
          currentGas!,
        );

        double avgTravelDepth = (currentSimDepth + nextDepth) / 2.0;
        double travelGasUsed =
            travelTime * input.rmv * (1.0 + avgTravelDepth / 10.0);
        gasConsumption[currentGas] =
            gasConsumption[currentGas]! + travelGasUsed;

        profile.add(
          DiveStep(
            "Ascent",
            nextDepth,
            travelTime.ceil(),
            currentGas,
            travelGasUsed,
          ),
        );

        exactTotalTime += travelTime;
        currentSimDepth = nextDepth;
      }
    }

    // 6. 탱크 잔압 검사 및 경고
    Map<Cylinder, int> remainingPressure = {};
    for (var cylinder in input.cylinders) {
      double usedLiters = gasConsumption[cylinder] ?? 0.0;
      double usedBar = usedLiters / (cylinder.volume * cylinder.count);
      int remainBar = (cylinder.startPressure - usedBar).toInt();
      remainingPressure[cylinder] = remainBar;

      if (remainBar < 0) {
        warnings.add(
          "CRITICAL: Gas in the [${cylinder.name}] tank is completely depleted ($remainBar bar).",
        );
        isFeasible = false;
      } else if (remainBar < switchPressureBar) {
        warnings.add(
          "WARNING: Insufficient gas pressure in the [${cylinder.name}] cylinder ($remainBar bar).",
        );
      }
    }

    return DivePlanResult(
      isFeasible: isFeasible,
      warnings: warnings,
      profile: profile,
      gasConsumption: gasConsumption,
      remainingPressure: remainingPressure,
      totalDiveTime: exactTotalTime,
    );
  }

  // =======================================================
  // [헬퍼 함수] 잔압 계산 및 기체 선택 로직
  // =======================================================

  double _getRemainBar(Cylinder c, Map<Cylinder, double> consumption) {
    double usedLiters = consumption[c] ?? 0.0;
    return c.startPressure - (usedLiters / (c.volume * c.count));
  }

  Cylinder? _getBestBottomGas(
    List<Cylinder> cylinders,
    double depth,
    Map<Cylinder, double> consumption,
  ) {
    var safeGases = cylinders.where((c) => c.bottomMod >= depth).toList();
    if (safeGases.isEmpty) safeGases = cylinders.toList();

    var valid = safeGases
        .where((c) => _getRemainBar(c, consumption) > switchPressureBar)
        .toList();
    if (valid.isEmpty) valid = safeGases;

    valid.sort((a, b) {
      int o2Cmp = b.fractionO2.compareTo(a.fractionO2);
      if (o2Cmp != 0) return o2Cmp;
      return _getRemainBar(
        b,
        consumption,
      ).compareTo(_getRemainBar(a, consumption));
    });

    return valid.isNotEmpty ? valid.first : null;
  }

  Cylinder? _getBestDecoGas(
    List<Cylinder> cylinders,
    double currentDepth,
    Map<Cylinder, double> consumption,
  ) {
    var valid = cylinders.where((c) {
      if (c.switchDepth != null && currentDepth > c.switchDepth!) return false;
      if (c.decoMod < currentDepth) return false;
      if (_getRemainBar(c, consumption) <= switchPressureBar) return false;
      return true;
    }).toList();

    if (valid.isEmpty) {
      valid = cylinders.where((c) => c.decoMod >= currentDepth).toList();
    }
    if (valid.isEmpty) return null;

    valid.sort((a, b) {
      int o2Cmp = b.fractionO2.compareTo(a.fractionO2);
      if (o2Cmp != 0) return o2Cmp;
      return _getRemainBar(
        b,
        consumption,
      ).compareTo(_getRemainBar(a, consumption));
    });

    return valid.first;
  }

  // =======================================================
  //[헬퍼 함수] 알고리즘 계산 (Schreiner Equation)
  // =======================================================

  void _simulateGasExchange(
    List<double> n2,
    List<double> he,
    double depth1,
    double depth2,
    double mins,
    Cylinder gas,
  ) {
    double fN2 = 1.0 - gas.fractionO2 - gas.fractionHe;
    if (fN2 < 0) fN2 = 0.0;

    double vaporPressure = 0.0627;
    double pAmbStart = 1.0 + (depth1 / 10.0);
    double pAmbEnd = 1.0 + (depth2 / 10.0);

    double pGasStartN2 = (pAmbStart - vaporPressure) * fN2;
    double pGasEndN2 = (pAmbEnd - vaporPressure) * fN2;
    double pGasStartHe = (pAmbStart - vaporPressure) * gas.fractionHe;
    double pGasEndHe = (pAmbEnd - vaporPressure) * gas.fractionHe;

    double rN2 = (pGasEndN2 - pGasStartN2) / mins;
    double rHe = (pGasEndHe - pGasStartHe) / mins;

    for (int i = 0; i < NUM_COMPARTMENTS; i++) {
      n2[i] = _calcSchreiner(n2[i], pGasStartN2, rN2, mins, n2HalfLives[i]);
      he[i] = _calcSchreiner(he[i], pGasStartHe, rHe, mins, heHalfLives[i]);
    }
  }

  double _calcSchreiner(
    double pi,
    double pGasStart,
    double r,
    double t,
    double halfLife,
  ) {
    double k = log(2.0) / halfLife;
    if (r.abs() < 0.00001) {
      return pi + (pGasStart - pi) * (1.0 - exp(-k * t));
    } else {
      return pGasStart +
          r * (t - 1.0 / k) -
          (pGasStart - pi - (r / k)) * exp(-k * t);
    }
  }

  bool _isSafe(double depth, List<double> n2, List<double> he, double gf) {
    double pAmb = 1.0 + (depth / 10.0);
    for (int i = 0; i < NUM_COMPARTMENTS; i++) {
      double pTotal = n2[i] + he[i];
      if (pTotal == 0.0) continue;

      double aMix =
          ((aCoefficients[i] * n2[i]) + (aHeCoefficients[i] * he[i])) / pTotal;
      double bMix =
          ((bCoefficients[i] * n2[i]) + (bHeCoefficients[i] * he[i])) / pTotal;

      double mPure = aMix + (pAmb / bMix);
      double mGf = pAmb + gf * (mPure - pAmb);

      if (pTotal > mGf) return false;
    }
    return true;
  }

  double _calcCeiling(List<double> n2, List<double> he, double gf) {
    double ceiling = 0.0;

    for (int i = 0; i < NUM_COMPARTMENTS; i++) {
      double pTotal = n2[i] + he[i];
      if (pTotal == 0) continue;

      double a =
          ((aCoefficients[i] * n2[i]) + (aHeCoefficients[i] * he[i])) / pTotal;

      double b =
          ((bCoefficients[i] * n2[i]) + (bHeCoefficients[i] * he[i])) / pTotal;

      double tolerated = (pTotal - a * gf) / (gf / b + 1 - gf);

      double depth = (tolerated - 1.0) * 10.0;

      if (depth > ceiling) ceiling = depth;
    }

    return ceiling;
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

class DivePlanner2 {
  // Shearwater 기본 권장 설정 (Medium: 40/85)
  final double gfLow;
  final double gfHigh;

  // 쉬어워터 표준 상승 속도: 10m/min
  final double ascentRate = 10.0;
  final double descentRate = 20.0;
  final double switchPressureBar = 30.0; // 최소 잔압 임계치

  DivePlanner2({this.gfLow = 0.40, this.gfHigh = 0.85});

  DivePlanResult generatePlan(DivePlanInput input) {
    List<String> warnings = [];
    bool isFeasible = true;
    List<DiveStep> profile = [];
    Map<Cylinder, double> gasConsumption = {
      for (var c in input.cylinders) c: 0.0,
    };

    // 1. 초기 조직 상태 (해수면 기준)
    double surfacePressure = 1.013; // 1 atm
    double vaporPressure = 0.0627;
    double initialN2 = (surfacePressure - vaporPressure) * 0.79;
    List<double> simN2 = List.filled(NUM_COMPARTMENTS, initialN2);
    List<double> simHe = List.filled(NUM_COMPARTMENTS, 0.0);

    // 2. 바닥 기체 선택
    Cylinder? currentGas = _getBestGasAtDepth(
      input.cylinders,
      input.targetDepth,
      isDecoPhase: false,
    );
    if (currentGas == null) {
      return _failResult(["ERROR: No suitable gas for target depth."]);
    }

    // 3. 하강 (Descent)
    double descentTime = input.targetDepth / descentRate;
    _simulateGasExchange(
      simN2,
      simHe,
      0.0,
      input.targetDepth,
      descentTime,
      currentGas,
    );
    double descentGasUsed =
        descentTime * input.rmv * (1.0 + (input.targetDepth / 2) / 10.0);
    gasConsumption[currentGas] = gasConsumption[currentGas]! + descentGasUsed;
    profile.add(
      DiveStep(
        "Descent",
        input.targetDepth.toInt(),
        descentTime.ceil(),
        currentGas,
        descentGasUsed,
      ),
    );

    // 4. 바닥 체류 (Bottom Time)
    // 실제 바닥 시간은 하강 시간을 포함한 총 시간에서 차감
    double bottomStayTime = input.bottomTime - descentTime;
    if (bottomStayTime < 0) bottomStayTime = 0;

    _simulateGasExchange(
      simN2,
      simHe,
      input.targetDepth,
      input.targetDepth,
      bottomStayTime,
      currentGas,
    );
    double bottomGasUsed =
        bottomStayTime * input.rmv * (1.0 + input.targetDepth / 10.0);
    gasConsumption[currentGas] = gasConsumption[currentGas]! + bottomGasUsed;
    profile.add(
      DiveStep(
        "Bottom",
        input.targetDepth.toInt(),
        bottomStayTime.ceil(),
        currentGas,
        bottomGasUsed,
      ),
    );

    double totalElapsed = input.bottomTime.toDouble();

    // 5. 상승 및 감압 (Ascent & Deco)
    double currentDepth = input.targetDepth;

    while (currentDepth > 0) {
      // 차기 정지 수심 (3m 간격)
      double nextStop = (currentDepth / 3).floor() * 3.0;
      if (nextStop == currentDepth) nextStop -= 3.0;
      if (nextStop < 0) nextStop = 0;

      // 현재 조직압 기반으로 갈 수 있는 가장 얕은 수심(Ceiling) 계산
      // Shearwater는 실시간 GF를 사용하므로, 수심에 따른 GF 선형 보간 적용
      double currentGF = _getGfAtDepth(currentDepth, input.targetDepth);
      double ceiling = _calcCeiling(simN2, simHe, currentGF);

      if (ceiling <= nextStop) {
        // 다음 정지 수심까지 상승 가능
        double travelTime = (currentDepth - nextStop) / ascentRate;
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
        // 현재 수심에서 감압 필요 (Deco Stop)
        // 1. 가스 스위칭 체크 (쉬어워터는 정지 수심에서 최적 가스 확인)
        Cylinder? bestGas = _getBestGasAtDepth(
          input.cylinders,
          currentDepth,
          isDecoPhase: true,
        );
        if (bestGas != null && bestGas != currentGas) {
          currentGas = bestGas;
          profile.add(
            DiveStep("Gas Switch", currentDepth.toInt(), 0, currentGas, 0),
          );
        }

        // 2. 1분 단위 정지 수행
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

        // 프로필 업데이트 (기존에 Deco Stop이 있으면 시간만 추가, 없으면 새로 생성)
        if (profile.last.phase == "Deco Stop" &&
            profile.last.depth == currentDepth.toInt()) {
          // 리스트가 불변이 아닐 경우 필드 수정 혹은 교체
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

    // 6. 결과 정리 및 경고
    Map<Cylinder, int> remainingPressure = {};
    for (var c in input.cylinders) {
      double usedBar = gasConsumption[c]! / (c.volume * c.count);
      int remain = (c.startPressure - usedBar).toInt();
      remainingPressure[c] = remain;
      if (remain < 0) {
        isFeasible = false;
        warnings.add("CRITICAL: Gas [${c.name}] depleted!");
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
    double depth, {
    required bool isDecoPhase,
  }) {
    Cylinder? best;
    double maxO2 = -1.0;

    for (var c in cylinders) {
      double mod = isDecoPhase ? c.decoMod : c.bottomMod;
      if (mod >= depth) {
        if (c.fractionO2 > maxO2) {
          maxO2 = c.fractionO2;
          best = c;
        }
      }
    }
    return best;
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

// import 'dart:math';
// import 'package:dive_computer_flutter/aPref.dart';
// import 'buhlmann.dart';

// enum GasPurpose { bottom, deco }

// class Cylinder {
//   final String name;
//   final double volume;
//   final int count;
//   final double startPressure;
//   final double fractionO2;
//   final double fractionHe;
//   final GasPurpose purpose;

//   // NEW
//   final double? switchDepth;

//   Cylinder({
//     required this.name,
//     required this.volume,
//     this.count = 1,
//     required this.startPressure,
//     required this.fractionO2,
//     this.fractionHe = 0.0,
//     this.purpose = GasPurpose.bottom,
//     this.switchDepth,
//   });

//   double get decoMod => ((1.6 / fractionO2) * 10) - 10;
//   double get bottomMod => ((1.4 / fractionO2) * 10) - 10;
//   double get totalLiters => volume * count * startPressure;
// }

// class DivePlanInput {
//   final double targetDepth;
//   final int bottomTime;
//   final double rmv;
//   final List<Cylinder> cylinders;

//   DivePlanInput({
//     required this.targetDepth,
//     required this.bottomTime,
//     required this.rmv,
//     required this.cylinders,
//   });
// }

// class DiveStep {
//   final String phase;
//   final int depth;
//   final double time;
//   final Cylinder gasUsed;
//   final double gasConsumed;

//   DiveStep(this.phase, this.depth, this.time, this.gasUsed, this.gasConsumed);
// }

// class DivePlanResult {
//   final bool feasible;
//   final List<String> warnings;
//   final List<DiveStep> profile;
//   final Map<Cylinder, int> remainPressure;
//   final Map<Cylinder, double> gasConsumption;
//   final double totalTime;

//   DivePlanResult({
//     required this.feasible,
//     required this.warnings,
//     required this.profile,
//     required this.remainPressure,
//     required this.gasConsumption,
//     required this.totalTime,
//   });
// }

// class DivePlanner {
//   final double gfLow;
//   final double gfHigh;

//   final bool enableDeepStop;
//   final bool safetyStopAfterDeco;

//   final double switchPressureBar = 50;

//   DivePlanner({
//     this.gfLow = 0.30,
//     this.gfHigh = 0.85,
//     this.enableDeepStop = false,
//     this.safetyStopAfterDeco = true,
//   });

//   DivePlanResult generatePlan(DivePlanInput input) {
//     List<String> warnings = [];
//     bool feasible = true;

//     List<DiveStep> profile = [];

//     Map<Cylinder, double> gasUse = {for (var c in input.cylinders) c: 0};

//     Cylinder? currentGas = _getBestBottomGas(
//       input.cylinders,
//       input.targetDepth,
//       gasUse,
//     );
//     double totalTime = 0;

//     if (currentGas == null) {
//       warnings.add("No bottom gas");
//       return DivePlanResult(
//         feasible: false,
//         warnings: warnings,
//         profile: [],
//         remainPressure: {},
//         totalTime: totalTime,
//         gasConsumption: gasUse,
//       );
//     }

//     double vapor = 0.0627;
//     double initN2 = (1 - vapor) * 0.79;

//     List<double> simN2 = List.filled(NUM_COMPARTMENTS, initN2);
//     List<double> simHe = List.filled(NUM_COMPARTMENTS, 0);

//     double descentRate = APref.getData(AprefKey.DescentSpeed) ?? 18.0;
//     double ascentRate = APref.getData(AprefKey.AscentSpeed) ?? 9.0;

//     double descentTime = (input.targetDepth / descentRate);

//     _simulateGasExchange(
//       simN2,
//       simHe,
//       0,
//       input.targetDepth,
//       descentTime.toDouble(),
//       currentGas,
//     );

//     double descentGas = descentTime * input.rmv * (1 + input.targetDepth / 20);

//     gasUse[currentGas] = gasUse[currentGas]! + descentGas;

//     profile.add(
//       DiveStep(
//         "Descent",
//         input.targetDepth.toInt(),
//         descentTime,
//         currentGas,
//         descentGas,
//       ),
//     );

//     totalTime = descentTime;
//     double bottomRemain = input.bottomTime - descentTime;
//     if (bottomRemain < 1) bottomRemain = 1;

//     for (int i = 0; i < bottomRemain; i++) {
//       _simulateGasExchange(
//         simN2,
//         simHe,
//         input.targetDepth,
//         input.targetDepth,
//         1,
//         currentGas,
//       );

//       double gas = input.rmv * (1 + input.targetDepth / 10);

//       gasUse[currentGas] = gasUse[currentGas]! + gas;

//       totalTime += 1;
//     }

//     profile.add(
//       DiveStep(
//         "Bottom",
//         input.targetDepth.toInt(),
//         bottomRemain,
//         currentGas,
//         0,
//       ),
//     );

//     int currentDepth = input.targetDepth.toInt();

//     double firstStop = _calcFirstStop(simN2, simHe);

//     double gfAtDepth(double depth) {
//       if (depth >= firstStop) return gfLow;

//       double frac = depth / firstStop;

//       return gfLow + (gfHigh - gfLow) * (1 - frac);
//     }

//     while (currentDepth > 0) {
//       // 1. 현재 수심에서 사용할 수 있는 최적의 가스 체크 (매 루프마다)
//       Cylinder? bestGas = _getBestDecoGas(
//         input.cylinders,
//         currentDepth.toDouble(),
//         gasUse,
//       );

//       if (bestGas != null && bestGas != currentGas) {
//         currentGas = bestGas;
//         profile.add(DiveStep("Gas Switch", currentDepth, 0, currentGas!, 0));
//       }

//       int nextDepth = currentDepth - 3;
//       if (nextDepth < 0) nextDepth = 0;

//       double targetGf = gfAtDepth(nextDepth.toDouble());
//       double ceiling = _calcCeiling(simN2, simHe, targetGf);

//       // 2. Deco Stop 계산
//       double stopTime = 0;
//       while (ceiling > nextDepth) {
//         _simulateGasExchange(
//           simN2,
//           simHe,
//           currentDepth.toDouble(),
//           currentDepth.toDouble(),
//           1,
//           currentGas!,
//         );

//         // 가스 소모량 계산 및 추가
//         double gasConsumed = input.rmv * (1 + currentDepth / 10) * 1;
//         gasUse[currentGas] = (gasUse[currentGas] ?? 0) + gasConsumed;

//         stopTime++;
//         totalTime += 1;
//         ceiling = _calcCeiling(simN2, simHe, targetGf);
//       }

//       if (stopTime > 0) {
//         profile.add(
//           DiveStep("Deco Stop", currentDepth, stopTime, currentGas!, 0),
//         );
//       }

//       // 3. 다음 수심으로 이동 (Ascent)
//       double travelDist = (currentDepth - nextDepth).toDouble();
//       double travelTime = travelDist / ascentRate;

//       _simulateGasExchange(
//         simN2,
//         simHe,
//         currentDepth.toDouble(),
//         nextDepth.toDouble(),
//         travelTime,
//         currentGas!,
//       );

//       // 이동 중 가스 소모량 추가
//       double avgDepth = (currentDepth + nextDepth) / 2;
//       double travelGas = travelTime * input.rmv * (1 + avgDepth / 10);
//       gasUse[currentGas] = (gasUse[currentGas] ?? 0) + travelGas;

//       totalTime += travelTime;
//       profile.add(DiveStep("Ascent", nextDepth, travelTime, currentGas!, 0));

//       currentDepth = nextDepth;
//     }

//     if (safetyStopAfterDeco) {
//       int stopDepth = 5;

//       _simulateGasExchange(
//         simN2,
//         simHe,
//         stopDepth.toDouble(),
//         stopDepth.toDouble(),
//         3,
//         currentGas!,
//       );

//       profile.add(DiveStep("SafetyStop", stopDepth, 3, currentGas, 0));

//       totalTime += 3;
//     }

//     Map<Cylinder, int> remain = {};

//     for (var c in input.cylinders) {
//       double used = gasUse[c] ?? 0;

//       double usedBar = used / (c.volume * c.count);

//       remain[c] = (c.startPressure - usedBar).toInt();

//       if (remain[c]! < 0) {
//         feasible = false;
//         warnings.add("Gas depleted in ${c.name}");
//       }
//     }

//     return DivePlanResult(
//       feasible: feasible,
//       warnings: warnings,
//       profile: profile,
//       remainPressure: remain,
//       totalTime: totalTime,
//       gasConsumption: gasUse,
//     );
//   }

//   double _calcFirstStop(List<double> n2, List<double> he) {
//     double ceiling = _calcCeiling(n2, he, 1.0);

//     return (ceiling / 3).ceil() * 3;
//   }

//   double _calcCeiling(List<double> n2, List<double> he, double gf) {
//     double ceiling = 0;

//     for (int i = 0; i < NUM_COMPARTMENTS; i++) {
//       double p = n2[i] + he[i];
//       if (p == 0) continue;

//       double a =
//           ((aCoefficients[i] * n2[i]) + (aHeCoefficients[i] * he[i])) / p;

//       double b =
//           ((bCoefficients[i] * n2[i]) + (bHeCoefficients[i] * he[i])) / p;

//       double tol = (p - a * gf) / (gf / b + 1 - gf);

//       double depth = (tol - 1) * 10;

//       if (depth > ceiling) ceiling = depth;
//     }

//     return ceiling;
//   }

//   Cylinder? _getBestBottomGas(
//     List<Cylinder> cylinders,
//     double depth,
//     Map<Cylinder, double> use,
//   ) {
//     var valid = cylinders.where((c) => c.bottomMod >= depth).toList();

//     if (valid.isEmpty) valid = cylinders;

//     valid.sort((a, b) => b.fractionO2.compareTo(a.fractionO2));

//     return valid.first;
//   }

//   Cylinder? _getBestDecoGas(
//     List<Cylinder> cylinders,
//     double depth,
//     Map<Cylinder, double> use,
//   ) {
//     // 현재 수심에서 MOD를 넘지 않는 가스들 필터링
//     var valid = cylinders.where((c) {
//       // 1. 스위칭 수심이 설정되어 있다면 그보다 얕아야 함
//       if (c.switchDepth != null && depth > c.switchDepth!) return false;

//       // 2. Deco 가스라면 Deco MOD(보통 PPO2 1.6) 내에 있어야 함
//       if (c.purpose == GasPurpose.deco && c.decoMod < depth) return false;

//       // 3. Bottom 가스라면 Bottom MOD(보통 PPO2 1.4) 내에 있어야 함
//       if (c.purpose == GasPurpose.bottom && c.bottomMod < depth) return false;

//       return true;
//     }).toList();

//     if (valid.isEmpty) return null;

//     // 산소 농도가 가장 높은 순으로 정렬 (가장 효율적인 감압 가스)
//     valid.sort((a, b) => b.fractionO2.compareTo(a.fractionO2));

//     return valid.first;
//   }

//   void _simulateGasExchange(
//     List<double> n2,
//     List<double> he,
//     double d1,
//     double d2,
//     double mins,
//     Cylinder gas,
//   ) {
//     double fN2 = 1 - gas.fractionO2 - gas.fractionHe;
//     double fHe = gas.fractionHe;
//     if (fN2 < 0) fN2 = 0;

//     double vapor = 0.0627;
//     double p1 = 1 + d1 / 10;
//     double p2 = 1 + d2 / 10;

//     // 질소 분압 계산
//     double pN2s = (p1 - vapor) * fN2;
//     double pN2e = (p2 - vapor) * fN2;
//     double rN2 = (pN2e - pN2s) / mins;

//     // 헬륨 분압 계산
//     double pHes = (p1 - vapor) * fHe;
//     double pHEe = (p2 - vapor) * fHe;
//     double rHe = (pHEe - pHes) / mins;

//     for (int i = 0; i < NUM_COMPARTMENTS; i++) {
//       // 질소 업데이트
//       n2[i] = _calcSchreiner(n2[i], pN2s, rN2, mins, n2HalfLives[i]);
//       // 헬륨 업데이트 (헬륨 전용 반감기 n2HalfLives[i] * 0.37 등을 사용하거나 별도 상수 사용)
//       // 여기서는 일반적인 Buhlmann 헬륨 계수 적용을 가정
//       he[i] = _calcSchreiner(he[i], pHes, rHe, mins, heHalfLives[i]);
//     }
//   }

//   double _calcSchreiner(
//     double pi,
//     double pGasStart,
//     double r,
//     double t,
//     double halfLife,
//   ) {
//     double k = log(2.0) / halfLife;
//     if (r.abs() < 0.00001) {
//       return pi + (pGasStart - pi) * (1.0 - exp(-k * t));
//     } else {
//       return pGasStart +
//           r * (t - 1.0 / k) -
//           (pGasStart - pi - (r / k)) * exp(-k * t);
//     }
//   }

//   bool _isSafe(double depth, List<double> n2, List<double> he, double gf) {
//     double pAmb = 1.0 + (depth / 10.0);
//     for (int i = 0; i < NUM_COMPARTMENTS; i++) {
//       double pTotal = n2[i] + he[i];
//       if (pTotal == 0.0) continue;

//       double aMix =
//           ((aCoefficients[i] * n2[i]) + (aHeCoefficients[i] * he[i])) / pTotal;
//       double bMix =
//           ((bCoefficients[i] * n2[i]) + (bHeCoefficients[i] * he[i])) / pTotal;

//       double mPure = aMix + (pAmb / bMix);
//       double mGf = pAmb + gf * (mPure - pAmb);

//       if (pTotal > mGf) return false;
//     }
//     return true;
//   }
// }
