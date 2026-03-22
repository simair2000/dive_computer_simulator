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

// ZHL-16C 헬륨 반감기 (단위: 분)
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

// 헬륨 A 계수
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

// 헬륨 B 계수
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

// 시뮬레이션 배속 (기본 1배속)
int timeMultiplier = 1;

const double intervalSeconds = 1; // 알고리즘 계산 주기 (초 단위)
const double WATER_VAPOR_PRESSURE = 0.0627; // in bar, at 37°C 폐속 수증기압
const int NUM_COMPARTMENTS = 16; // Compartment 개수

enum DiveMoveStatus { onAscending, onDescending, onStop }

class Buhlmann {
  List<double> currentLoadings = []; // 질소(N2) 포화도
  List<double> currentHeLoadings = []; // 헬륨(He) 포화도

  int EAN = 21; // 산소 비율 (%)
  int HE = 0; // 헬륨 비율 (%)

  double get fractionO2 => EAN / 100.0;
  double get fractionHe => HE / 100.0;
  double get fractionN2 => 1.0 - fractionO2 - fractionHe; // 질소 비율 동적 계산

  var currentDepth = ValueNotifier<double>(0.0);
  double prevDepth = 0.0;

  double get gfHigh => APref.getData(AprefKey.GF_HIGH);
  double get gfLow => APref.getData(AprefKey.GF_LOW);
  // var gfHighNotifier = ValueNotifier<double>(85);
  // var gfLowNotifier = ValueNotifier<double>(40);

  var ppo2 = APref.getData(AprefKey.PPO2_BOTTOM);
  double get mod => (((ppo2 / fractionO2) * 10) - 10);

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

  var currentPressureGroup = ValueNotifier<String>('-'); // A~Z 표시용
  double _endDivePgIndex = 0.0; // 수면 휴식 시 반감기 감쇠 계산을 위한 내부 인덱스 값

  Timer? _timer;
  var updateTick = ValueNotifier<int>(0);

  int _decoAnchorDepth = 0;
  var diveCount = ValueNotifier<int>(0);
  Duration _lastDiveTime = Duration.zero;

  DiveMoveStatus _currentMoveStatus = DiveMoveStatus.onStop;

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

  // 혼합 가스 설정
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

  // 시뮬레이션 배속 설정 함수
  void setSpeed(int multiplier) {
    if (multiplier < 1) multiplier = 1;
    timeMultiplier = multiplier;

    // 이미 타이머가 돌고 있다면 취소하고 새로운 배속으로 재시작
    if (_timer != null && _timer!.isActive) {
      _timer?.cancel();
      _timer = Timer.periodic(
        // 예: 10배속이면 1000 / 10 = 100ms 마다 1초치 연산 수행
        Duration(milliseconds: 1000 ~/ timeMultiplier),
        (timer) {
          processCycle();
        },
      );
    }
  }

  // N2와 He 모두에 사용 가능한 범용 기체 변화 계산 함수
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

  // 역계산이 아닌 1분 단위 Look-ahead 시뮬레이션 방식의 완벽한 혼합가스 NDL
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
    if (currentDeepestStop == 0) {
      currentDeepestStop = (currentDepth.value / 3).ceil() * 3;
    }

    if (_decoAnchorDepth == 0 || currentDeepestStop > _decoAnchorDepth) {
      _decoAnchorDepth = currentDeepestStop;
    }

    // double gfSlope = (gfHigh - gfLow) / (0.0 - _decoAnchorDepth.toDouble());
    double firstStopDepth = _decoAnchorDepth.toDouble();
    double gfAtDepth(double depth) {
      if (depth >= firstStopDepth) return gfLow;

      double fraction = depth / firstStopDepth;
      return gfLow + (gfHigh - gfLow) * (1.0 - fraction);
    }

    int currentSimDepth = _decoAnchorDepth;
    int requiredTime = 0;

    while (currentSimDepth > 0) {
      double nextDepth = (currentSimDepth - 3).toDouble();
      if (nextDepth < 0) nextDepth = 0.0;

      // double targetGf = gfHigh + (gfSlope * nextDepth);
      double targetGf = gfAtDepth(nextDepth.toDouble());
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

    // double gfSlope = (gfHigh - gfLow) / (0.0 - deepestStop.toDouble());
    double firstStopDepth = deepestStop.toDouble();
    double gfAtDepth(double depth) {
      if (depth >= firstStopDepth) return gfLow;

      double fraction = depth / firstStopDepth;
      return gfLow + (gfHigh - gfLow) * (1.0 - fraction);
    }

    while (simDepth > 0) {
      double nextDepth = simDepth - 3.0;
      if (nextDepth < 0) nextDepth = 0.0;

      // double targetGf = gfHigh + (gfSlope * nextDepth);
      double targetGf = gfAtDepth(nextDepth.toDouble());
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

  // 질소와 헬륨의 가중 평균 허용치를 계산 (Trimix 지원)
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

  // [추가] 실시간 ZHL-16C 조직 포화도 기반 멀티레벨 압력군(A~Z) 계산
  void calculatePressureGroup() {
    double maxRatio = 0.0;

    // 대기압(1.0 bar) 하에서의 수증기압을 제외한 순수 불활성기체(질소) 기본 압력 (약 0.7404 bar)
    // 이 상태가 다이빙을 하지 않은 '0%' 상태입니다.
    double pBase = (1.0 - WATER_VAPOR_PRESSURE) * 0.79;

    for (int i = 0; i < NUM_COMPARTMENTS; i++) {
      double pN2 = currentLoadings[i];
      double pHe = currentHeLoadings[i];
      double pTotal = pN2 + pHe;

      // 체내 압력이 기본 대기압 상태보다 같거나 낮으면 무시
      if (pTotal <= pBase) continue;

      // 해당 조직의 혼합 A, B 계수 산출
      double aMix =
          ((aCoefficients[i] * pN2) + (aHeCoefficients[i] * pHe)) / pTotal;
      double bMix =
          ((bCoefficients[i] * pN2) + (bHeCoefficients[i] * pHe)) / pTotal;

      // 수면(0m, P_amb = 1.0)으로 올라왔을 때의 허용 한계치(M-Value) 계산
      double mPure = aMix + (1.0 / bMix);

      // 사용자가 설정한 보수성(GF High)을 적용한 최종 수면 허용 한계치
      double m0Gf = 1.0 + gfHigh * (mPure - 1.0);

      // 현재 조직의 포화 비율 계산 (0.0 = 기본 상태, 1.0 = 무감압 한계 도달)
      double ratio = (pTotal - pBase) / (m0Gf - pBase);

      // 16개 조직 중 가장 비율이 높은(위험한) 조직을 기준으로 삼음
      if (ratio > maxRatio) {
        maxRatio = ratio;
      }
    }

    // 0.0 ~ 1.0 의 비율을 26개 알파벳(A~Z) 스텝으로 변환
    int pgIdx = (maxRatio * 26).ceil();

    if (pgIdx <= 0) {
      currentPressureGroup.value = '-'; // 안전(기본) 상태
    } else if (pgIdx > 26) {
      currentPressureGroup.value =
          'OOR (Out Of Range - DECO)'; // 무감압 한계 초과 (DECO 진입)
    } else {
      currentPressureGroup.value = String.fromCharCode(
        64 + pgIdx,
      ); // 1=A, 2=B, 26=Z
    }
  }

  bool processCycle() {
    if (prevDepth < currentDepth.value) {
      _currentMoveStatus = DiveMoveStatus.onDescending;
    } else if (currentDepth.value < prevDepth) {
      _currentMoveStatus = DiveMoveStatus.onAscending;
    } else {
      _currentMoveStatus = DiveMoveStatus.onStop;
    }

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

    calculatePressureGroup();

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

      // 다이빙 중 PADI 압력군 계산 (Table 1 룩업)
      // 다이빙 중에는 항상 '최대 수심'과 '현재까지의 다이빙 시간'을 기준으로 산출합니다.
      // int mins = (currentDiveTime.value.inSeconds / 60.0).ceil();
      // int pgIdx = PadiRdp.getPgIndex(currentDepth.value, mins);
      // _endDivePgIndex = pgIdx.toDouble(); // 상승 후 감쇠 계산을 위해 저장

      // if (pgIdx == 0) {
      //   currentPressureGroup.value = '-';
      // } else if (pgIdx > 26) {
      //   currentPressureGroup.value =
      //       'OOR(Out Of Range)'; // Out Of Range (한계 초과)
      // } else {
      //   currentPressureGroup.value = String.fromCharCode(
      //     64 + pgIdx,
      //   ); // 1=A, 2=B...
      // }
    } else {
      isOnDiving.value = false;
      tts.value = 0;
      saftyStop.value = Duration.zero;
      _lastDiveTime = currentDiveTime.value;

      double timeMin = intervalSeconds / 60.0;
      currentCNS.value =
          currentCNS.value * pow(2.0, -timeMin / cnsHalfLifeMinutes);

      // 수면 휴식 중 PADI 압력군 감소 (Table 2 기반 60분 반감기 로직)
      // if (_endDivePgIndex > 0) {
      //   // PADI RDP Table 2는 정확히 60분 반감기 곡선을 그립니다.
      //   double currentIdx = _endDivePgIndex * pow(2.0, -timeMin / 60.0);
      //   _endDivePgIndex = currentIdx; // 매초마다 서서히 감소됨

      //   int roundIdx = currentIdx.round();
      //   if (roundIdx < 1) {
      //     currentPressureGroup.value = '-';
      //     _endDivePgIndex = 0.0; // 체내 잔류 질소(RDP 기준) 완전 초기화
      //   } else if (roundIdx > 26) {
      //     currentPressureGroup.value = 'OOR(Out Of Range)';
      //   } else {
      //     currentPressureGroup.value = String.fromCharCode(64 + roundIdx);
      //   }
      // }

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
    _timer?.cancel();
    _timer = Timer.periodic(Duration(milliseconds: 1000 ~/ timeMultiplier), (
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
    if (_currentMoveStatus == DiveMoveStatus.onDescending &&
        saftyStop.value.inSeconds == 180 &&
        3 <= diveCount.value) {
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

// PADI RDP (Metric) Table 1 매핑 헬퍼 클래스
class PadiRdp {
  // 기준 수심 (m) - 실제 수심이 이 값들 사이에 있으면 무조건 더 깊은 수심으로 올림 처리
  static final List<int> depths = [10, 12, 14, 16, 18, 20, 22, 25, 30, 35, 40];

  // 각 수심별 압력군(A~Z) 최대 허용 시간(분)
  // 0은 해당 수심에서 도달 불가능한(NDL 초과) 영역
  static final List<List<int>> times = [
    // A, B, C, D, E, F, G, H, I, J, K, L, M, N, O, P, Q, R, S, T, U, V, W, X, Y, Z
    [
      10,
      19,
      25,
      29,
      32,
      36,
      40,
      44,
      48,
      52,
      57,
      62,
      67,
      73,
      79,
      85,
      92,
      100,
      108,
      117,
      127,
      139,
      152,
      170,
      188,
      219,
    ], // 10m
    [
      9,
      16,
      22,
      25,
      27,
      31,
      34,
      37,
      40,
      44,
      48,
      51,
      55,
      60,
      64,
      68,
      73,
      79,
      85,
      92,
      100,
      108,
      118,
      130,
      147,
      0,
    ], // 12m
    [
      8,
      14,
      19,
      22,
      24,
      27,
      29,
      32,
      35,
      38,
      42,
      45,
      48,
      52,
      56,
      61,
      65,
      70,
      75,
      82,
      88,
      98,
      0,
      0,
      0,
      0,
    ], // 14m
    [
      7,
      12,
      17,
      19,
      21,
      24,
      26,
      28,
      31,
      34,
      37,
      40,
      43,
      47,
      50,
      54,
      59,
      63,
      68,
      72,
      0,
      0,
      0,
      0,
      0,
      0,
    ], // 16m
    [
      6,
      11,
      15,
      17,
      19,
      21,
      23,
      25,
      27,
      30,
      32,
      35,
      38,
      41,
      44,
      48,
      52,
      56,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ], // 18m
    [
      5,
      9,
      13,
      15,
      17,
      19,
      21,
      23,
      25,
      27,
      29,
      32,
      34,
      37,
      40,
      43,
      45,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ], // 20m
    [
      4,
      8,
      11,
      13,
      15,
      17,
      18,
      20,
      22,
      24,
      26,
      28,
      30,
      32,
      35,
      37,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ], // 22m
    [
      3,
      7,
      10,
      12,
      13,
      15,
      17,
      18,
      20,
      21,
      23,
      25,
      27,
      29,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ], // 25m
    [
      0,
      5,
      7,
      9,
      10,
      11,
      13,
      14,
      15,
      17,
      18,
      19,
      20,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ], // 30m
    [
      0,
      3,
      5,
      6,
      7,
      8,
      9,
      10,
      11,
      12,
      13,
      14,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ], // 35m
    [
      0,
      0,
      4,
      5,
      6,
      7,
      8,
      9,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ], // 40m
  ];

  static int getPgIndex(double maxDepthMeters, int diveTimeMins) {
    if (maxDepthMeters < 1.5 || diveTimeMins <= 0) return 0;

    // 1. 해당되는 수심 찾기 (수심 올림 규정 적용)
    int targetDepthIdx = -1;
    for (int i = 0; i < depths.length; i++) {
      if (maxDepthMeters <= depths[i]) {
        targetDepthIdx = i;
        break;
      }
    }

    // 40m 초과 시 OOR (Out Of Range)
    if (targetDepthIdx == -1) return 27;

    // 2. 해당 수심의 시간 배열에서 그룹 찾기
    List<int> row = times[targetDepthIdx];
    for (int i = 0; i < row.length; i++) {
      if (row[i] == 0) continue;
      if (diveTimeMins <= row[i]) {
        return i + 1; // 1=A, 2=B, 3=C... 반환
      }
    }

    return 27; // NDL을 넘긴 경우 OOR
  }
}
