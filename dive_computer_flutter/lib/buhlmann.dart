import 'dart:async';
import 'package:dive_computer_flutter/aPref.dart';
import 'dart:math';
import 'package:flutter/material.dart';

// ZHL-16C 질소 반감기 (단위: 분)
const List<double> n2HalfLives = [
  4.0,
  5.0,
  8.0,
  12.5,
  18.5,
  27.0,
  38.3,
  54.3,
  77.0,
  109.0,
  146.0,
  187.0,
  239.0,
  305.0,
  390.0,
  635.0,
];

// N2 A 계수
const List<double> aCoefficients = [
  1.2599,
  1.0000,
  0.8618,
  0.7562,
  0.6667,
  0.5600,
  0.4947,
  0.4500,
  0.4187,
  0.3798,
  0.3497,
  0.3223,
  0.2850,
  0.2737,
  0.2523,
  0.2327,
];

// N2 B 계수
const List<double> bCoefficients = [
  0.5050,
  0.5533,
  0.6122,
  0.6626,
  0.7004,
  0.7541,
  0.7957,
  0.8279,
  0.8491,
  0.8732,
  0.8910,
  0.9092,
  0.9222,
  0.9319,
  0.9508,
  0.9650,
];

// [추가] ZHL-16C 헬륨 반감기 (단위: 분)
const List<double> heHalfLives = [
  1.88,
  3.02,
  4.72,
  7.30,
  11.50,
  19.00,
  30.20,
  49.00,
  73.00,
  146.00,
  205.00,
  304.00,
  425.00,
  571.00,
  739.00,
  850.00,
];

// [추가] 헬륨 A 계수
const List<double> aHeCoefficients = [
  1.7424,
  1.3830,
  1.1919,
  1.0458,
  0.9220,
  0.8205,
  0.7305,
  0.6502,
  0.5950,
  0.5545,
  0.5333,
  0.5189,
  0.5181,
  0.5176,
  0.5172,
  0.5119,
];

// [추가] 헬륨 B 계수
const List<double> bHeCoefficients = [
  0.4245,
  0.5747,
  0.6527,
  0.7222,
  0.7582,
  0.7957,
  0.8279,
  0.8553,
  0.8757,
  0.8903,
  0.8997,
  0.9073,
  0.9122,
  0.9171,
  0.9217,
  0.9267,
];

const double intervalSeconds = 1; // 알고리즘 계산 주기 (초 단위)
const double WATER_VAPOR_PRESSURE = 0.0627; // in bar, at 37°C 폐속 수증기압
const int NUM_COMPARTMENTS = 16; // Compartment 개수

class Buhlmann {
  List<double> currentLoadings = []; // 질소(N2) 포화도
  List<double> currentHeLoadings = []; // [추가] 헬륨(He) 포화도

  int EAN = 21; // 산소 비율 (%)
  int HE = 0; // [추가] 헬륨 비율 (%)

  double get fractionO2 => EAN / 100.0;
  double get fractionHe => HE / 100.0;
  double get fractionN2 => 1.0 - fractionO2 - fractionHe; // 질소 비율 동적 계산

  var currentDepth = ValueNotifier<double>(0.0);
  double prevDepth = 0.0;

  double gfHigh = 0.8;
  double gfLow = 0.2;
  var gfHighNotifier = ValueNotifier<double>(85);
  var gfLowNotifier = ValueNotifier<double>(40);

  var ppo2 = ValueNotifier<double>(1.4);
  double get mod => (((ppo2.value / fractionO2) * 10) - 10);
  var modNotifier = ValueNotifier<double>(0);

  var ndl = ValueNotifier<double>(0.0);
  var tts = ValueNotifier<int>(0);
  var isOnDiving = ValueNotifier<bool>(false);
  var maxDepth = ValueNotifier<double>(0.0);
  var currentDiveTime = ValueNotifier<Duration>(Duration.zero);
  var surfaceTime = ValueNotifier<Duration>(Duration.zero);

  // DECO Plan
  var decoStopDepth = ValueNotifier<int>(0);
  var decoStopTime = ValueNotifier<int>(0);
  var needDeco = ValueNotifier<bool>(false);

  // Safty Stop
  var saftyStop = ValueNotifier<Duration>(Duration.zero);

  // PO2
  var currentPO2 = ValueNotifier<double>(0.21);

  // CNS(중추신경계 산소 중독, Central Nervous System Oxygen Toxicity)
  var currentCNS = ValueNotifier<double>(0.0); // CNS 퍼센트 (0~100% 이상)
  final double cnsHalfLifeMinutes = 90.0; // 수면에서의 CNS 반감기 (90분)

  Timer? _timer;
  var updateTick = ValueNotifier<int>(0);

  int _decoAnchorDepth = 0;
  var diveCount = ValueNotifier<int>(0);
  Duration _lastDiveTime = Duration.zero;

  Buhlmann() {
    var surfaceTime = getSurfaceTime();
    if (surfaceTime == null) {
      double initialN2Pressure = (1.0 - WATER_VAPOR_PRESSURE) * 0.79;
      currentLoadings = List.filled(NUM_COMPARTMENTS, initialN2Pressure);
      currentHeLoadings = List.filled(NUM_COMPARTMENTS, 0.0); // 헬륨 초기화
    } else {
      List<double> lastLoadingList = APref.getData(
        AprefKey.LAST_N2_LOADING_LIST,
      );
      currentLoadings = List.from(lastLoadingList);
      currentHeLoadings = List.filled(
        NUM_COMPARTMENTS,
        0.0,
      ); // 헬륨도 저장/로딩이 필요하나 현재는 0으로 초기화

      updateGasLoadingsSchreiner(
        currentLoadings,
        0,
        0,
        fractionN2,
        n2HalfLives,
        intervalSeconds,
      );
      updateGasLoadingsSchreiner(
        currentHeLoadings,
        0,
        0,
        fractionHe,
        heHalfLives,
        intervalSeconds,
      );
    }
  }

  void dispose() {
    _timer?.cancel();
  }

  // [수정] 혼합 가스 설정
  void setGas(int newO2, int newHe) {
    EAN = newO2;
    HE = newHe;
  }

  // NOAA(미국 해양대기청) 산소 노출 한계 기반 1초당 CNS 증가율 계산
  double getCnsRatePerSecond(double po2) {
    // PO2가 0.5 이하일 때는 산소 중독이 누적되지 않음
    if (po2 <= 0.5) return 0.0;

    // NOAA PO2 Table (bar)
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
    // 허용 시간 Table (분 단위)
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
      // 1.6을 초과하는 위험 구간은 1.5~1.6의 기울기를 연장(외삽법)하여 급격히 증가하도록 계산
      double r1 = 100.0 / 120.0; // 1.5일 때 1분당 오르는 CNS%
      double r2 = 100.0 / 45.0; // 1.6일 때 1분당 오르는 CNS%
      double slope = (r2 - r1) / (1.6 - 1.5);
      ratePerMinute = r2 + slope * (po2 - 1.6);
    } else {
      // 0.5 ~ 1.6 구간 사이의 값을 선형 보간법(Linear Interpolation)으로 정밀하게 계산
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

    return ratePerMinute / 60.0; // 1초당 누적량으로 반환
  }

  // [수정] N2와 He 모두에 사용 가능한 범용 기체 변화 계산 함수
  void updateGasLoadingsSchreiner(
    List<double> loadings,
    double depth,
    double prevDepth,
    double fractionGas,
    List<double> halfLives,
    double intervalSeconds,
  ) {
    double timeMin = intervalSeconds / 60.0;

    double pAmbStart = 1.0 + (prevDepth / 10.0);
    double pAmbEnd = 1.0 + (depth / 10.0);

    double pGasStart = (pAmbStart > WATER_VAPOR_PRESSURE)
        ? (pAmbStart - WATER_VAPOR_PRESSURE) * fractionGas
        : 0.0;
    double pGasEnd = (pAmbEnd > WATER_VAPOR_PRESSURE)
        ? (pAmbEnd - WATER_VAPOR_PRESSURE) * fractionGas
        : 0.0;

    double R = (pGasEnd - pGasStart) / timeMin;

    for (int i = 0; i < NUM_COMPARTMENTS; i++) {
      double Pi = loadings[i];
      double halfLife = halfLives[i];
      double k = log(2.0) / halfLife;
      double pNew;

      if (R.abs() < 0.00001) {
        // 깊이 변화가 없으면 할데인 공식
        pNew = Pi + (pGasEnd - Pi) * (1.0 - exp(-k * timeMin));
      } else {
        // 상승/하강 중이면 슈라이너 공식
        double eKt = exp(-k * timeMin);
        pNew =
            pGasStart +
            R * (timeMin - 1.0 / k) -
            (pGasStart - Pi - (R / k)) * eKt;
      }

      if (pNew < 0.0) pNew = 0.0;
      loadings[i] = pNew;
    }
  }

  static Duration? getSurfaceTime() {
    int lastDiveTime = APref.getData(AprefKey.LAST_DIVE_DATETIME);
    if (lastDiveTime == 0) return null;
    var now = DateTime.now().millisecondsSinceEpoch;
    return Duration(milliseconds: now - lastDiveTime);
  }

  // [수정] 역계산이 아닌 1분 단위 Look-ahead 시뮬레이션 방식의 완벽한 혼합가스 NDL
  double calculateNDL() {
    // 1. 너무 얕은 수심(예: 1.2m 미만)에서는 NDL이 무한대(99)
    if (currentDepth.value < 1.2) return 999.0;

    List<double> simN2 = List.from(currentLoadings);
    List<double> simHe = List.from(currentHeLoadings);

    // 2. "지금 당장" 수면(0m)으로 올라가는 것이 불가능하다면?
    // 이미 감압(Deco) 모드에 진입한 것이므로 NDL은 0분입니다.
    if (!isDepthSafe(0.0, simN2, simHe, gfHigh)) return 0.0;

    // 3. 현재 수심에서 1분씩 머문다고 가정하고 미래를 예측 (최대 99분)
    int minutes = 0;
    while (minutes < 999) {
      // 현재 수심에서 1분(60초)간 기체를 흡수
      updateGasLoadingsSchreiner(
        simN2,
        currentDepth.value,
        currentDepth.value,
        fractionN2,
        n2HalfLives,
        60.0,
      );
      updateGasLoadingsSchreiner(
        simHe,
        currentDepth.value,
        currentDepth.value,
        fractionHe,
        heHalfLives,
        60.0,
      );

      minutes++;

      // 1분 머문 결과, 이제 수면(0m)으로 올라가는 것이 위험해졌는가?
      if (!isDepthSafe(0.0, simN2, simHe, gfHigh)) {
        // 위험해지는 시점의 시간이 바로 무감압 한계 시간(NDL)입니다.
        return minutes.toDouble();
      }
    }

    // 99분을 머물러도 계속 안전하다면 (보통 얕은 수심) 컴퓨터 표시 한계인 99분 반환
    return 999.0;
  }

  void calculateDecoStop() {
    List<double> tempN2Loadings = List.from(currentLoadings);
    List<double> tempHeLoadings = List.from(currentHeLoadings);

    if (isDepthSafe(0.0, tempN2Loadings, tempHeLoadings, gfHigh)) {
      needDeco.value = false;
      decoStopDepth.value = 0;
      decoStopTime.value = 0;
      _decoAnchorDepth = 0;
      return;
    }

    needDeco.value = true;

    int currentDeepestStop = 0;
    for (int d = 3; d < 300; d += 3) {
      if (isDepthSafe(d.toDouble(), tempN2Loadings, tempHeLoadings, gfLow)) {
        currentDeepestStop = d;
        break;
      }
    }
    if (currentDeepestStop == 0)
      currentDeepestStop = (currentDepth.value / 3).ceil() * 3;

    if (_decoAnchorDepth == 0 || currentDeepestStop > _decoAnchorDepth) {
      _decoAnchorDepth = currentDeepestStop;
    }

    double gfSlope = (gfHigh - gfLow) / (0.0 - _decoAnchorDepth.toDouble());

    int currentSimDepth = _decoAnchorDepth;
    int requiredTime = 0;

    while (currentSimDepth > 0) {
      double nextDepth = (currentSimDepth - 3).toDouble();
      if (nextDepth < 0) nextDepth = 0.0;

      double targetGf = gfHigh + (gfSlope * nextDepth);
      if (targetGf > gfHigh) targetGf = gfHigh;
      if (targetGf < gfLow) targetGf = gfLow;

      requiredTime = 0;
      List<double> timeCalcN2Loadings = List.from(tempN2Loadings);
      List<double> timeCalcHeLoadings = List.from(tempHeLoadings);

      while (requiredTime < 99) {
        if (isDepthSafe(
          nextDepth,
          timeCalcN2Loadings,
          timeCalcHeLoadings,
          targetGf,
        )) {
          break;
        }
        updateGasLoadingsSchreiner(
          timeCalcN2Loadings,
          currentSimDepth.toDouble(),
          currentSimDepth.toDouble(),
          fractionN2,
          n2HalfLives,
          60.0,
        );
        updateGasLoadingsSchreiner(
          timeCalcHeLoadings,
          currentSimDepth.toDouble(),
          currentSimDepth.toDouble(),
          fractionHe,
          heHalfLives,
          60.0,
        );
        requiredTime++;
      }

      if (requiredTime > 0) {
        decoStopDepth.value = currentSimDepth;
        decoStopTime.value = requiredTime;
        return;
      } else {
        currentSimDepth -= 3;
      }
    }

    decoStopDepth.value = 3;
    decoStopTime.value = 0;
    needDeco.value = false;
  }

  int calculateTTS() {
    List<double> tempN2Loadings = List.from(currentLoadings);
    List<double> tempHeLoadings = List.from(currentHeLoadings);

    double totalTimeMin = 0.0;
    double simDepth = currentDepth.value;
    const double ASCENT_RATE = 10.0;

    if (isDepthSafe(0.0, tempN2Loadings, tempHeLoadings, gfHigh)) {
      totalTimeMin = getAscentTime(simDepth, 18.0);
      return totalTimeMin.ceil();
    }

    int deepestStop = 0;
    for (int d = 3; d <= simDepth.toInt() + 3; d += 3) {
      if (isDepthSafe(d.toDouble(), tempN2Loadings, tempHeLoadings, gfLow)) {
        deepestStop = d;
        break;
      }
    }
    if (deepestStop == 0) deepestStop = (simDepth / 3).ceil() * 3;

    if (simDepth > deepestStop) {
      double ascentTime = getAscentTime(simDepth - deepestStop, ASCENT_RATE);
      // 상승 구간 시뮬레이션 (Schreiner 공식으로 수심 변화에 따른 가스 증감 반영)
      updateGasLoadingsSchreiner(
        tempN2Loadings,
        deepestStop.toDouble(),
        simDepth,
        fractionN2,
        n2HalfLives,
        ascentTime * 60.0,
      );
      updateGasLoadingsSchreiner(
        tempHeLoadings,
        deepestStop.toDouble(),
        simDepth,
        fractionHe,
        heHalfLives,
        ascentTime * 60.0,
      );

      totalTimeMin += ascentTime;
      simDepth = deepestStop.toDouble();
    } else {
      simDepth = deepestStop.toDouble();
    }

    double gfSlope = (gfHigh - gfLow) / (0.0 - deepestStop.toDouble());

    while (simDepth > 0) {
      double nextDepth = simDepth - 3.0;
      if (nextDepth < 0) nextDepth = 0.0;

      double targetGf = gfHigh + (gfSlope * nextDepth);
      bool canAscend = isDepthSafe(
        nextDepth,
        tempN2Loadings,
        tempHeLoadings,
        targetGf,
      );

      if (canAscend) {
        double travelTime = getAscentTime(3.0, ASCENT_RATE);
        updateGasLoadingsSchreiner(
          tempN2Loadings,
          nextDepth,
          simDepth,
          fractionN2,
          n2HalfLives,
          travelTime * 60.0,
        );
        updateGasLoadingsSchreiner(
          tempHeLoadings,
          nextDepth,
          simDepth,
          fractionHe,
          heHalfLives,
          travelTime * 60.0,
        );
        totalTimeMin += travelTime;
        simDepth = nextDepth;
      } else {
        updateGasLoadingsSchreiner(
          tempN2Loadings,
          simDepth,
          simDepth,
          fractionN2,
          n2HalfLives,
          60.0,
        );
        updateGasLoadingsSchreiner(
          tempHeLoadings,
          simDepth,
          simDepth,
          fractionHe,
          heHalfLives,
          60.0,
        );
        totalTimeMin += 1.0;
      }

      if (totalTimeMin > 999) break;
    }

    return totalTimeMin.ceil();
  }

  double getAscentTime(double distM, double rateMMin) {
    if (distM <= 0) return 0.0;
    return distM / rateMMin;
  }

  // [수정] 질소와 헬륨의 가중 평균 허용치를 계산 (Trimix 지원)
  bool isDepthSafe(
    double depthToCheck,
    List<double> n2Loadings,
    List<double> heLoadings,
    double gf,
  ) {
    double pAmb = 1.0 + (depthToCheck / 10.0);

    for (int i = 0; i < NUM_COMPARTMENTS; i++) {
      double pN2 = n2Loadings[i];
      double pHe = heLoadings[i];
      double pTotal = pN2 + pHe; // 총 조직 내 가스 압력

      if (pTotal == 0.0) continue;

      // 질소/헬륨 비율에 따른 혼합 M-value 계수 계산 (가중 평균)
      double aMix =
          ((aCoefficients[i] * pN2) + (aHeCoefficients[i] * pHe)) / pTotal;
      double bMix =
          ((bCoefficients[i] * pN2) + (bHeCoefficients[i] * pHe)) / pTotal;

      double mPure = aMix + (pAmb / bMix);
      double mGf = pAmb + gf * (mPure - pAmb);

      if (pTotal > mGf) {
        return false;
      }
    }
    return true;
  }

  bool processCycle() {
    checkSaftyStop();

    currentPO2.value =
        (1.0 + (currentDepth.value / 10.0) - WATER_VAPOR_PRESSURE) * fractionO2;

    // 매 초마다 2개 기체 업데이트
    updateGasLoadingsSchreiner(
      currentLoadings,
      currentDepth.value,
      prevDepth,
      fractionN2,
      n2HalfLives,
      intervalSeconds,
    );
    updateGasLoadingsSchreiner(
      currentHeLoadings,
      currentDepth.value,
      prevDepth,
      fractionHe,
      heHalfLives,
      intervalSeconds,
    );

    ndl.value = calculateNDL();
    tts.value = calculateTTS();
    calculateDecoStop();

    prevDepth = currentDepth.value;

    if (currentDepth.value > maxDepth.value) {
      maxDepth.value = currentDepth.value;
    }

    if (1.2 <= currentDepth.value) {
      if (isOnDiving.value == false) {
        diveCount.value++;
        currentDiveTime.value = Duration.zero;
      }
      isOnDiving.value = true;
      surfaceTime.value = Duration.zero;
      currentDiveTime.value += Duration(seconds: intervalSeconds.toInt());
      currentCNS.value +=
          getCnsRatePerSecond(currentPO2.value) * intervalSeconds;
    } else {
      isOnDiving.value = false;
      tts.value = 0;
      saftyStop.value = Duration.zero;
      _lastDiveTime = currentDiveTime.value;

      double timeMin = intervalSeconds / 60.0;
      currentCNS.value =
          currentCNS.value * pow(2.0, -timeMin / cnsHalfLifeMinutes);

      updateTick.value++;
      surfaceTime.value += Duration(seconds: intervalSeconds.toInt());
      return false;
    }

    updateTick.value++;
    return true;
  }

  void startDive() {
    if (isOnDiving.value) return;
    isOnDiving.value = true;
    currentDiveTime.value = Duration.zero;
    _timer = Timer.periodic(Duration(seconds: intervalSeconds.toInt()), (
      timer,
    ) {
      processCycle();
    });
  }

  void checkSaftyStop() {
    if (10 < currentDepth.value && saftyStop.value.inSeconds <= 0) {
      saftyStop.value = Duration(seconds: 180);
    }
    if (saftyStop.value.inSeconds == 180 && 30 < currentDepth.value) {
      saftyStop.value = saftyStop.value + Duration(seconds: 120);
    }
    if (saftyStop.value.inSeconds == 180 && ndl.value <= 5) {
      saftyStop.value = saftyStop.value + Duration(seconds: 120);
    }
    double ascentRate =
        (prevDepth - currentDepth.value) / (intervalSeconds / 60.0);
    if (ascentRate > 18.0) {
      if (saftyStop.value.inSeconds == 180) {
        saftyStop.value += Duration(seconds: 120);
      }
    }
    if (saftyStop.value.inSeconds == 180 && 3 <= diveCount.value) {
      saftyStop.value += Duration(seconds: 120);
    }

    if (saftyStop.value.inSeconds > 0 &&
        currentDepth.value <= 6 &&
        !needDeco.value) {
      saftyStop.value = saftyStop.value - Duration(seconds: 1);
      if (saftyStop.value.inSeconds < 0) saftyStop.value = Duration.zero;
    }
  }
}
