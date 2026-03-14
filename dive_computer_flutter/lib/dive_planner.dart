import 'dart:math';
import 'package:dive_computer_flutter/aPref.dart';
import 'package:dive_computer_flutter/define.dart'; // WATER_VAPOR_PRESSURE 등 상수 임포트용 (필요시 맞게 수정)
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

  Cylinder({
    required this.name,
    required this.volume,
    this.count = 1,
    required this.startPressure,
    required this.fractionO2,
    this.fractionHe = 0.0,
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
  final int totalDiveTime;

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

  // GF값이 백분율(예: 85)로 들어왔을 경우를 대비한 안전 장치 추가
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

    // 1. 초기 바닥 기체 찾기 (안전 수심 기준 필터링 추가)
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

    // 2. 가상 조직(Compartments) 초기화 (Buhlmann ZHL-16C)
    // WATER_VAPOR_PRESSURE가 선언되어 있지 않다면 0.0627 (약 0.0627 atm)를 사용하세요.
    double initialN2 = (1.0 - 0.0627) * 0.79;
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

    // [중요 수정] 전체 다이브 타임을 분 단위 실수로 누적 (매 상승 단계의 ceil로 인한 오차 방지)
    double exactTotalTime = descentTime.toDouble();

    // 4. 바닥 체류 (Bottom)
    int actualBottomTime = input.bottomTime - descentTime;
    if (actualBottomTime < 1) actualBottomTime = 1;

    int phaseTime = 0;
    double phaseGasUsed = 0.0;

    for (int i = 0; i < actualBottomTime; i++) {
      // 매 분마다 현재 가스의 잔압 체크, 50bar 이하면 다음 탱크로 스위칭
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

      // 1분 소모
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

    // 감압 정지가 필요한 첫 수심 계산 (Anchor Depth)
    int anchorDepth = 0;
    for (int d = 3; d <= currentSimDepth; d += 3) {
      if (!_isSafe(d.toDouble(), simN2, simHe, gfLow)) {
        anchorDepth = d;
        break;
      }
    }
    if (anchorDepth == 0) anchorDepth = (currentSimDepth / 3).ceil() * 3;

    // [중요 수정] Anchor Depth가 0일 경우 Division by Zero 방지
    double gfSlope = 0.0;
    if (anchorDepth > 0) {
      gfSlope = (gfHigh - gfLow) / (0.0 - anchorDepth.toDouble());
    }

    // 표면(0m)에 도달할 때까지 루프
    while (currentSimDepth > 0) {
      int nextDepth = currentSimDepth - 3;
      if (nextDepth < 0) nextDepth = 0;

      double targetGf = gfHigh + (gfSlope * nextDepth);
      if (targetGf > gfHigh) targetGf = gfHigh;
      if (targetGf < gfLow) targetGf = gfLow;

      phaseTime = 0;
      phaseGasUsed = 0.0;

      // [중요 수정] 특정 수심에 도착하자마자 더 효율적인 감압기체가 있다면 즉시 전환
      Cylinder? arrivalDecoGas = _getBestDecoGas(
        input.cylinders,
        currentSimDepth.toDouble(),
        gasConsumption,
      );
      if (arrivalDecoGas != null && arrivalDecoGas != currentGas) {
        currentGas = arrivalDecoGas;
        profile.add(
          DiveStep("Gas Switch", currentSimDepth, 0, currentGas, 0.0),
        );
      }

      // 현재 수심에서 무감압 한계(안전)를 만족할 때까지 1분씩 대기 (감압 정지)
      while (true) {
        if (_isSafe(nextDepth.toDouble(), simN2, simHe, targetGf)) {
          break; // 상승 가능해짐
        }

        // 대기 중 기체 고갈 등으로 인한 전환 확인
        Cylinder? stopGas = _getBestDecoGas(
          input.cylinders,
          currentSimDepth.toDouble(),
          gasConsumption,
        );
        if (stopGas != null && stopGas != currentGas) {
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
          phaseTime = 0;
          phaseGasUsed = 0.0;
          currentGas = stopGas;
          profile.add(
            DiveStep("Gas Switch", currentSimDepth, 0, currentGas, 0.0),
          );
        }

        // 1분 대기 및 소모
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
      }

      // 감압 정지 기록
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

      // 3m 상승 이동 시간 계산
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
      gasConsumption[currentGas] = gasConsumption[currentGas]! + travelGasUsed;

      if (phaseTime == 0) {
        // 정지 없이 바로 상승했을 때만 Ascent 항목 추가
        profile.add(
          DiveStep(
            "Ascent",
            nextDepth,
            travelTime.ceil(),
            currentGas,
            travelGasUsed,
          ),
        );
      }

      exactTotalTime += travelTime;
      currentSimDepth = nextDepth;
    }

    // 6. 탱크 잔압 최종 검사 및 경고 생성
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
      totalDiveTime: exactTotalTime.ceil(), // 최종 반환 시 1번만 올림 처리
    );
  }

  // =======================================================
  //[헬퍼 함수] 가스 잔압 계산 및 최적 가스 선택
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
    // 1. 목표 수심에서 MOD를 초과하지 않는 안전한 기체들만 1차 필터링
    var safeGases = cylinders.where((c) => c.bottomMod >= depth).toList();

    // 만약 다이버가 안전한 기체를 하나도 안가져왔다면 (강제 다이빙 시나리오 대비)
    if (safeGases.isEmpty) safeGases = cylinders.toList();

    var valid = safeGases.where((c) {
      // 잔압이 교체 임계점(50bar) 이하인 탱크는 우선 제외
      if (_getRemainBar(c, consumption) <= switchPressureBar) return false;
      return true;
    }).toList();

    // 50bar 이상 남은 안전 기체가 없다면, 고갈되어도 쥐어짜서 써야 하므로 필터 완화
    if (valid.isEmpty) valid = safeGases;

    // 2. 가장 이상적인 기체 순으로 정렬
    valid.sort((a, b) {
      // 우선순위 1: 산소 비율이 높은 기체 (MOD 허용 범위 내에서 가장 유리함)
      int o2Cmp = b.fractionO2.compareTo(a.fractionO2);
      if (o2Cmp != 0) return o2Cmp;
      // 우선순위 2: 동일 기체라면 잔압이 더 많이 남은 탱크
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
      // 수심 초과 가스(산소 중독 위험)는 사망 위험이 크므로 감압 시 절대 제외
      if (c.decoMod < currentDepth) return false;
      // 임계점 이하 제외
      if (_getRemainBar(c, consumption) <= switchPressureBar) return false;
      return true;
    }).toList();

    // 사용 가능한 가스가 없다면 (고갈 상태) 마이너스까지 써야 하므로 다시 탐색
    if (valid.isEmpty) {
      valid = cylinders.where((c) => c.decoMod >= currentDepth).toList();
    }

    if (valid.isEmpty) return null;

    valid.sort((a, b) {
      // 우선순위 1: 감압에 유리한 가장 높은 O2 비율 (예: EAN50, 100% O2)
      int o2Cmp = b.fractionO2.compareTo(a.fractionO2);
      if (o2Cmp != 0) return o2Cmp;
      // 우선순위 2: 잔압이 많은 탱크 우선
      return _getRemainBar(
        b,
        consumption,
      ).compareTo(_getRemainBar(a, consumption));
    });

    return valid.first;
  }

  // =======================================================
  // [헬퍼 함수] 알고리즘 계산 (Schreiner Equation)
  // =======================================================

  void _simulateGasExchange(
    List<double> n2,
    List<double> he,
    double depth1,
    double depth2,
    double mins,
    Cylinder gas,
  ) {
    // 질소 비율 계산 및 부동소수점 오차로 인한 음수 방지
    double fN2 = 1.0 - gas.fractionO2 - gas.fractionHe;
    if (fN2 < 0) fN2 = 0.0;

    double vaporPressure = 0.0627; // 수증기압 (약 0.0627 atm)
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
      // 등압 상태 (정지 중)
      return pi + (pGasStart - pi) * (1.0 - exp(-k * t));
    } else {
      // 압력 변화 상태 (상승/하강 중)
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

      // 순수 무감압 한계(M-value)
      double mPure = aMix + (pAmb / bMix);
      // GF(Gradient Factor)가 적용된 보수적 한계
      double mGf = pAmb + gf * (mPure - pAmb);

      if (pTotal > mGf) return false;
    }
    return true;
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
