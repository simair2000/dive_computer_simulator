import 'dart:math';
import 'buhlmann.dart'; // n2HalfLives, aCoefficients 등 상수 임포트

/// 1. 실린더(탱크) 데이터 모델
enum GasPurpose { bottom, deco } // 바닥 체류용 vs 감압용

class Cylinder {
  final String name;
  final double volume; // 리터 (예: 11.1L)
  final int count; // 탱크 갯수
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

  double get decoMod => ((1.6 / fractionO2) * 10) - 10;
  double get bottomMod => ((1.4 / fractionO2) * 10) - 10;
  double get totalLiters => volume * count * startPressure;
}

/// 2. 플래너 입력 데이터 모델
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

/// 3. 다이빙 프로필 단계(Step) 모델
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

/// 4. 플래너 결과 데이터 모델
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

/// 5. 핵심 플래너 로직
class DivePlanner {
  final double gfHigh;
  final double gfLow;
  final double switchPressureBar = 50.0; // 탱크 교체를 유도할 최소 잔압 임계점 (50 bar)

  DivePlanner({this.gfHigh = 0.85, this.gfLow = 0.30});

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
      warnings.add("ERROR: 해당 수심(${input.targetDepth}m)에 적합한 가스가 없습니다.");
      return _failResult(warnings);
    }

    if (currentGas.bottomMod < input.targetDepth) {
      warnings.add("WARNING: 목표 수심이 첫 기체의 MOD를 초과합니다. (PO2 > 1.4)");
      isFeasible = false;
    }

    // 2. 가상 조직 초기화
    double initialN2 = (1.0 - WATER_VAPOR_PRESSURE) * 0.79;
    List<double> simN2 = List.filled(NUM_COMPARTMENTS, initialN2);
    List<double> simHe = List.filled(NUM_COMPARTMENTS, 0.0);

    // 3. 하강 (Descent) - 18m/min
    double descentRate = 18.0;
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

    // 4. 바닥 체류 (Bottom) - 1분 단위 시뮬레이션 (다중 탱크 교체 지원)
    int actualBottomTime = input.bottomTime - descentTime;
    if (actualBottomTime < 1) actualBottomTime = 1;

    int phaseTime = 0;
    double phaseGasUsed = 0.0;

    for (int i = 0; i < actualBottomTime; i++) {
      // 매 분마다 현재 가스의 잔압 체크, 50bar 이하면 다음 동일 가스 탱크로 스위칭
      if (_getRemainBar(currentGas!, gasConsumption) <= switchPressureBar) {
        Cylinder? nextGas = _getBestBottomGas(
          input.cylinders,
          input.targetDepth,
          gasConsumption,
        );

        if (nextGas != null && nextGas != currentGas) {
          // 스위칭 전까지의 기록 저장
          if (phaseTime > 0)
            profile.add(
              DiveStep(
                "Bottom",
                input.targetDepth.toInt(),
                phaseTime,
                currentGas,
                phaseGasUsed,
              ),
            );
          phaseTime = 0;
          phaseGasUsed = 0.0;
          currentGas = nextGas; // 기체 교체
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
    if (phaseTime > 0)
      profile.add(
        DiveStep(
          "Bottom",
          input.targetDepth.toInt(),
          phaseTime,
          currentGas!,
          phaseGasUsed,
        ),
      );

    // 5. 상승 및 감압 (Ascent & Deco)
    int currentSimDepth = input.targetDepth.toInt();
    int totalTime = descentTime + actualBottomTime;

    int anchorDepth = 0;
    for (int d = 3; d <= currentSimDepth; d += 3) {
      if (!_isSafe(d.toDouble(), simN2, simHe, gfLow)) {
        anchorDepth = d;
        break;
      }
    }
    if (anchorDepth == 0) anchorDepth = (currentSimDepth / 3).ceil() * 3;
    double gfSlope = (gfHigh - gfLow) / (0.0 - anchorDepth.toDouble());

    while (currentSimDepth > 0) {
      int nextDepth = currentSimDepth - 3;
      if (nextDepth < 0) nextDepth = 0;

      double targetGf = gfHigh + (gfSlope * nextDepth);
      if (targetGf > gfHigh) targetGf = gfHigh;
      if (targetGf < gfLow) targetGf = gfLow;

      phaseTime = 0;
      phaseGasUsed = 0.0;

      // 현재 수심에서 감압 대기 (1분 단위 루프)
      while (true) {
        if (_isSafe(nextDepth.toDouble(), simN2, simHe, targetGf))
          break; // 상승 가능

        // 감압 중에도 최적의 가스(또는 잔압이 있는 동일 가스)가 있는지 매 분마다 확인
        Cylinder? bestDecoGas = _getBestDecoGas(
          input.cylinders,
          currentSimDepth.toDouble(),
          gasConsumption,
        );
        // 더 좋은 가스가 있거나, 현재 가스가 50bar 이하라 동일한 다른 탱크로 스위치 해야 할 때
        if (bestDecoGas != null && bestDecoGas != currentGas) {
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
          currentGas = bestDecoGas;
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
        totalTime++;
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

      // 3m 상승 이동 (약 0.3분)
      double travelTime = 3.0 / 10.0;
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
      totalTime += travelTime.ceil();
      currentSimDepth = nextDepth;
    }

    // 6. 탱크 잔압 검사
    Map<Cylinder, int> remainingPressure = {};
    for (var cylinder in input.cylinders) {
      double usedLiters = gasConsumption[cylinder] ?? 0.0;
      double usedBar = usedLiters / (cylinder.volume * cylinder.count);
      int remainBar = (cylinder.startPressure - usedBar).toInt();
      remainingPressure[cylinder] = remainBar;

      if (remainBar < 0) {
        warnings.add(
          "CRITICAL: ${cylinder.name} 탱크의 가스가 완전히 고갈되었습니다 ($remainBar bar).",
        );
        isFeasible = false;
      } else if (remainBar < switchPressureBar) {
        warnings.add(
          "WARNING: ${cylinder.name} 탱크 잔압이 부족합니다 ($remainBar bar).",
        );
      }
    }

    return DivePlanResult(
      isFeasible: isFeasible,
      warnings: warnings,
      profile: profile,
      gasConsumption: gasConsumption,
      remainingPressure: remainingPressure,
      totalDiveTime: totalTime,
    );
  }

  // =======================================================
  // [핵심 변경] 잔압 기반 최적 가스 선택 헬퍼 함수들
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
    var valid = cylinders.where((c) {
      if (c.purpose != GasPurpose.bottom) return false;
      // 잔압이 교체 임계점(50bar) 이하인 탱크는 우선 제외 (단, 쓸 수 있는 게 아예 없다면 마지막 탱크를 마이너스까지 써야 함)
      if (_getRemainBar(c, consumption) <= switchPressureBar) return false;
      return true;
    }).toList();

    // 만약 50bar 이상 남은 탱크가 없다면, 고갈되어도 쥐어짜서 써야 하므로 필터 조건 완화
    if (valid.isEmpty) {
      valid = cylinders.where((c) => c.purpose == GasPurpose.bottom).toList();
    }
    if (valid.isEmpty) return null;

    valid.sort((a, b) {
      // 1순위: O2 비율이 높은 기체 (기체 성분)
      int o2Cmp = b.fractionO2.compareTo(a.fractionO2);
      if (o2Cmp != 0) return o2Cmp;
      // 2순위: 똑같은 기체라면 잔압(Remaining Bar)이 가장 많은 탱크 우선
      return _getRemainBar(
        b,
        consumption,
      ).compareTo(_getRemainBar(a, consumption));
    });
    return valid.first;
  }

  Cylinder? _getBestDecoGas(
    List<Cylinder> cylinders,
    double currentDepth,
    Map<Cylinder, double> consumption,
  ) {
    var valid = cylinders.where((c) {
      if (c.decoMod < currentDepth) return false; // 수심 초과 가스는 사망 위험으로 절대 제외
      if (_getRemainBar(c, consumption) <= switchPressureBar)
        return false; // 임계점 이하 제외
      return true;
    }).toList();

    // 사용 가능한 가스가 없다면 (고갈 상태) 마이너스까지 쥐어짜야 하므로 다시 탐색
    if (valid.isEmpty) {
      valid = cylinders.where((c) => c.decoMod >= currentDepth).toList();
    }
    if (valid.isEmpty) return null;

    valid.sort((a, b) {
      // 1순위: 감압에 유리한 가장 높은 O2 비율
      int o2Cmp = b.fractionO2.compareTo(a.fractionO2);
      if (o2Cmp != 0) return o2Cmp;
      // 2순위: 동일한 기체라면 잔압이 많은 탱크 우선
      return _getRemainBar(
        b,
        consumption,
      ).compareTo(_getRemainBar(a, consumption));
    });
    return valid.first;
  }

  // --- 기존 연산 함수들 유지 ---
  void _simulateGasExchange(
    List<double> n2,
    List<double> he,
    double depth1,
    double depth2,
    double mins,
    Cylinder gas,
  ) {
    double fN2 = 1.0 - gas.fractionO2 - gas.fractionHe;
    double pAmbStart = 1.0 + (depth1 / 10.0);
    double pAmbEnd = 1.0 + (depth2 / 10.0);
    double pGasStartN2 = (pAmbStart - WATER_VAPOR_PRESSURE) * fN2;
    double pGasEndN2 = (pAmbEnd - WATER_VAPOR_PRESSURE) * fN2;
    double pGasStartHe = (pAmbStart - WATER_VAPOR_PRESSURE) * gas.fractionHe;
    double pGasEndHe = (pAmbEnd - WATER_VAPOR_PRESSURE) * gas.fractionHe;

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
