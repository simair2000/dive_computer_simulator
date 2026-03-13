import 'dart:math';
import 'buhlmann.dart'; // n2HalfLives, aCoefficients 등 상수 임포트

/// 1. 실린더(탱크) 데이터 모델
enum GasPurpose { bottom, deco } // 바닥 체류용 vs 감압용

class Cylinder {
  final String name; // 예: "Air", "EAN50", "O2", "Tx 18/45"
  final double volume; // 리터 (예: 11.1L = AL80)
  final int count; // 탱크 갯수 (더블탱크 = 2, 데코탱크 = 1)
  final double startPressure; // 시작 압력 (bar)
  final double fractionO2; // 산소 비율 (0.21 ~ 1.0)
  final double fractionHe; // 헬륨 비율 (0.0 ~ 1.0)
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

  // 감압 기체 최대 허용 수심 (PO2 1.6 기준)
  double get decoMod => ((1.6 / fractionO2) * 10) - 10;
  // 바닥 기체 최대 허용 수심 (PO2 1.4 기준)
  double get bottomMod => ((1.4 / fractionO2) * 10) - 10;
  // 총 보유 가스량 (리터)
  double get totalLiters => volume * count * startPressure;
}

/// 2. 플래너 입력 데이터 모델
class DivePlanInput {
  final double targetDepth; // 목표 수심 (m)
  final int bottomTime; // 바닥 체류 시간 (분, 하강 시간 포함)
  final double rmv; // 분당 기체 소모량 (L/min)
  final List<Cylinder> cylinders; // 사용할 모든 탱크 리스트

  DivePlanInput({
    required this.targetDepth,
    required this.bottomTime,
    required this.rmv,
    required this.cylinders,
  });
}

/// 3. 다이빙 프로필 단계(Step) 모델
class DiveStep {
  final String
  phase; // "Descent", "Bottom", "Ascent", "Deco Stop", "Gas Switch"
  final int depth; // 해당 단계가 끝나는 수심 (m)
  final int time; // 소요 시간 (분)
  final Cylinder gasUsed; // 사용한 기체
  final double gasConsumedLiters; // 소모된 가스량 (L)

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
  final List<DiveStep> profile; // 전체 다이빙 프로필 (가스 스위칭 포함)
  final Map<Cylinder, double> gasConsumption; // 탱크별 소모된 가스량 (Liters)
  final Map<Cylinder, int> remainingPressure; // 탱크별 남은 압력 (bar)
  final int totalDiveTime; // 총 다이빙 시간 (분)

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

  DivePlanner({this.gfHigh = 0.85, this.gfLow = 0.30});

  DivePlanResult generatePlan(DivePlanInput input) {
    List<String> warnings = [];
    bool isFeasible = true;
    List<DiveStep> profile = [];
    Map<Cylinder, double> gasConsumption = {
      for (var c in input.cylinders) c: 0.0,
    };

    // 1. 바닥 기체 찾기 (Bottom 목적 중 가장 적합한 기체)
    Cylinder? bottomGas = _getBestBottomGas(input.cylinders, input.targetDepth);
    if (bottomGas == null) {
      warnings.add(
        "ERROR: 해당 수심(${input.targetDepth}m)에 적합한 바닥 기체(Bottom Gas)가 없습니다.",
      );
      return _failResult(warnings);
    }

    if (bottomGas.bottomMod < input.targetDepth) {
      warnings.add(
        "WARNING: 목표 수심이 바닥 기체의 MOD(${bottomGas.bottomMod.toStringAsFixed(1)}m)를 초과합니다. (PO2 > 1.4)",
      );
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
      bottomGas,
    );
    double descentGas =
        descentTime * input.rmv * (1.0 + avgDescentDepth / 10.0);
    gasConsumption[bottomGas] = gasConsumption[bottomGas]! + descentGas;
    profile.add(
      DiveStep(
        "Descent",
        input.targetDepth.toInt(),
        descentTime,
        bottomGas,
        descentGas,
      ),
    );

    // 4. 바닥 체류 (Bottom)
    int actualBottomTime = input.bottomTime - descentTime;
    if (actualBottomTime < 1) actualBottomTime = 1;

    _simulateGasExchange(
      simN2,
      simHe,
      input.targetDepth,
      input.targetDepth,
      actualBottomTime.toDouble(),
      bottomGas,
    );
    double bottomGasUsed =
        actualBottomTime * input.rmv * (1.0 + input.targetDepth / 10.0);
    gasConsumption[bottomGas] = gasConsumption[bottomGas]! + bottomGasUsed;
    profile.add(
      DiveStep(
        "Bottom",
        input.targetDepth.toInt(),
        actualBottomTime,
        bottomGas,
        bottomGasUsed,
      ),
    );

    // 5. 상승 및 감압 (Ascent & Deco)
    int currentSimDepth = input.targetDepth.toInt();
    Cylinder currentGas = bottomGas;
    int totalTime = descentTime + actualBottomTime;

    // 감압 기준 수심 (최초 감압 정지 수심) - GF 보간용
    int anchorDepth = 0;
    for (int d = 3; d <= currentSimDepth; d += 3) {
      if (!_isSafe(d.toDouble(), simN2, simHe, gfLow)) {
        anchorDepth = d;
        break;
      }
    }
    if (anchorDepth == 0) anchorDepth = (currentSimDepth / 3).ceil() * 3;
    double gfSlope = (gfHigh - gfLow) / (0.0 - anchorDepth.toDouble());

    // 수면(0m)에 도달할 때까지 3m씩 상승
    while (currentSimDepth > 0) {
      // --- 가스 스위칭 체크 (Deco Gas) ---
      Cylinder? bestDecoGas = _getBestDecoGas(input.cylinders, currentSimDepth);
      if (bestDecoGas != null && bestDecoGas != currentGas) {
        currentGas = bestDecoGas;
        profile.add(
          DiveStep("Gas Switch", currentSimDepth, 0, currentGas, 0.0),
        );
      }

      int nextDepth = currentSimDepth - 3;
      if (nextDepth < 0) nextDepth = 0;

      double targetGf = gfHigh + (gfSlope * nextDepth);
      if (targetGf > gfHigh) targetGf = gfHigh;
      if (targetGf < gfLow) targetGf = gfLow;

      int stopTimeAtCurrentDepth = 0;

      // 다음 수심으로 올라갈 수 있을 때까지 현재 수심에서 대기 (1분 단위 시뮬레이션)
      while (true) {
        // 목표 수심(nextDepth)이 안전한지 확인
        if (_isSafe(nextDepth.toDouble(), simN2, simHe, targetGf)) {
          break; // 안전하면 루프 탈출 후 상승
        }
        // 안전하지 않으면 1분간 감압 정지
        _simulateGasExchange(
          simN2,
          simHe,
          currentSimDepth.toDouble(),
          currentSimDepth.toDouble(),
          1.0,
          currentGas,
        );
        stopTimeAtCurrentDepth++;
      }

      // 감압 정지 기록
      if (stopTimeAtCurrentDepth > 0) {
        double stopGasUsed =
            stopTimeAtCurrentDepth * input.rmv * (1.0 + currentSimDepth / 10.0);
        gasConsumption[currentGas] = gasConsumption[currentGas]! + stopGasUsed;
        profile.add(
          DiveStep(
            "Deco Stop",
            currentSimDepth,
            stopTimeAtCurrentDepth,
            currentGas,
            stopGasUsed,
          ),
        );
        totalTime += stopTimeAtCurrentDepth;
      }

      // 3m 상승 이동 (10m/min 속도 가정 -> 3m 이동에 약 0.3분)
      double travelTime = 3.0 / 10.0;
      _simulateGasExchange(
        simN2,
        simHe,
        currentSimDepth.toDouble(),
        nextDepth.toDouble(),
        travelTime,
        currentGas,
      );
      double avgTravelDepth = (currentSimDepth + nextDepth) / 2.0;
      double travelGasUsed =
          travelTime * input.rmv * (1.0 + avgTravelDepth / 10.0);
      gasConsumption[currentGas] = gasConsumption[currentGas]! + travelGasUsed;

      if (stopTimeAtCurrentDepth == 0) {
        // 정지 없이 바로 통과한 경우 (Ascent 프로필 기록)
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

    // 6. 탱크 잔압 계산 및 가스 부족 경고
    Map<Cylinder, int> remainingPressure = {};
    for (var cylinder in input.cylinders) {
      double usedLiters = gasConsumption[cylinder] ?? 0.0;
      double usedBar = usedLiters / (cylinder.volume * cylinder.count);
      int remainBar = (cylinder.startPressure - usedBar).toInt();
      remainingPressure[cylinder] = remainBar;

      if (remainBar < 50) {
        warnings.add(
          "WARNING: ${cylinder.name} 탱크의 잔압이 위험 수준입니다 (${remainBar} bar). 더 큰 용량이나 추가 탱크가 필요합니다.",
        );
        isFeasible = false;
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

  // --- 헬퍼 함수들 ---

  Cylinder? _getBestBottomGas(List<Cylinder> cylinders, double depth) {
    // Bottom 목적 가스 중 MOD가 현재 수심보다 깊고 산소 비율이 가장 높은 것
    var bottomGases = cylinders
        .where((c) => c.purpose == GasPurpose.bottom)
        .toList();
    if (bottomGases.isEmpty) return null;
    bottomGases.sort((a, b) => b.fractionO2.compareTo(a.fractionO2));
    return bottomGases.first;
  }

  Cylinder? _getBestDecoGas(List<Cylinder> cylinders, int currentDepth) {
    // 수심에 맞는 가스 중 산소 비율이 가장 높은 가스 (O2 100% 우선 등)
    Cylinder? bestGas;
    double maxO2 = 0.0;

    for (var cylinder in cylinders) {
      // 현재 수심이 해당 기체의 Deco MOD보다 얕거나 같아야 함
      if (currentDepth <= cylinder.decoMod) {
        if (cylinder.fractionO2 > maxO2) {
          maxO2 = cylinder.fractionO2;
          bestGas = cylinder;
        }
      }
    }
    return bestGas;
  }

  void _simulateGasExchange(
    List<double> n2,
    List<double> he,
    double depth1,
    double depth2,
    double mins,
    Cylinder gas,
  ) {
    double fN2 = 1.0 - gas.fractionO2 - gas.fractionHe;
    // Buhlmann 공식 직접 연산 (Schreiner Equation)
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
