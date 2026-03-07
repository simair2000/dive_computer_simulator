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

// A 계수
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

// B 계수
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

const double intervalSeconds = 1; // 알고리즘 계산 주기 (초 단위)
const double WATER_VAPOR_PRESSURE = 0.0627; // in bar, at 37°C 폐속 수증기압
const int NUM_COMPARTMENTS = 16; // Compartment 개수 - Buhlmann ZHL-16C 모델 기준

class Buhlmann {
  List<double> currentLoadings = [];
  int EAN = 21; // 기본적으로 공기 다이빙으로 시작 (EAN 21)
  double get fractionO2 => EAN / 100.0;
  double get fractionN2 => 1.0 - fractionO2;

  var currentDepth = ValueNotifier<double>(0.0); // 현재 수심 (미터 단위)
  double prevDepth = 0.0; // 이전 수심 (미터 단위)

  double gfHigh = 0.8; // 고감압 계수 (예시값, 실제로는 다이빙 프로필에 따라 조정 필요)
  double gfLow = 0.2; // 저감압 계수 (예시값, 실제로는 다이빙 프로필에 따라 조정 필요)
  var gfHighNotifier = ValueNotifier<double>(80); // 고감압 계수 (퍼센트 단위로 표시)
  var gfLowNotifier = ValueNotifier<double>(20); // 저감압 계수 (퍼센트 단위로 표시)

  var ndl = ValueNotifier<double>(0.0); // 무감압 한계 시간 (분 단위)
  var tts = ValueNotifier<int>(0); // Time To Surface (분 단위)
  var isOnDiving = ValueNotifier<bool>(false); // 다이빙 중 여부
  var maxDepth = ValueNotifier<double>(0.0); // 최대 수심 기록
  var currentDiveTime = ValueNotifier<Duration>(Duration.zero); // 현재 다이빙 시간

  // DECO Plan
  var decoStopDepth = ValueNotifier<int>(0); // 다음 감압 정지 수심 (3m 단위)
  var decoStopTime = ValueNotifier<int>(0); // 다음 감압 정지 시간 (분 단위)
  var needDeco = ValueNotifier<bool>(false); // 감압 정지 필요 여부

  // Safty Stop
  var saftyStop = ValueNotifier<Duration>(Duration.zero); // 안전 정지 남은 시간 (초 단위)

  // PO2
  var currentPO2 = ValueNotifier<double>(0.21);

  Timer? _timer;

  Buhlmann() {
    var surfaceTime = getSurfaceTime();
    if (surfaceTime == null) {
      // 기존 다이빙 기록이 없는경우 ( 첫번째 다이빙 )
      double initialN2Pressure =
          (1.0 - WATER_VAPOR_PRESSURE) * 0.79; // 대기압에서 수증기압과 산소분압을 제외한 질소분압
      currentLoadings = List.filled(NUM_COMPARTMENTS, initialN2Pressure);
    } else {
      // 기존 다이빙 기록이 있는 경우, 마지막 다이빙의 compartment loading을 불러옴
      List<double> lastLoadingList = APref.getData(AprefKey.LAST_LOADING_LIST);
      currentLoadings = List.from(lastLoadingList);
      updateN2Loadings(currentLoadings, 0, fractionO2, intervalSeconds);
    }
  }

  void dispose() {
    _timer?.cancel();
  }

  void setEAN(int newEAN) {
    EAN = newEAN;
  }

  void updateN2Loadings(
    List<double> loadings,
    double depth,
    double fractionO2,
    double intervalSeconds,
  ) {
    updateN2LoadingsSchreiner(
      loadings,
      depth,
      depth,
      fractionO2,
      intervalSeconds,
    );
  }

  void updateN2LoadingsSchreiner(
    List<double> loadings,
    double depth,
    double prevDepth,
    double fractionO2,
    double intervalSeconds,
  ) {
    double timeMin = intervalSeconds / 60.0;
    double fractionN2 = 1.0 - fractionO2;

    // 1. 시작 및 종료 시점의 폐포 내 질소 분압 계산
    double pAmbStart = 1.0 + (prevDepth / 10.0);
    double pAmbEnd = 1.0 + (depth / 10.0);

    // 수증기압 보정 (압력이 너무 낮아질 경우를 대비해 하한선 설정)
    double pGasN2Start = (pAmbStart > WATER_VAPOR_PRESSURE)
        ? (pAmbStart - WATER_VAPOR_PRESSURE) * fractionN2
        : 0.0;
    double pGasN2End = (pAmbEnd > WATER_VAPOR_PRESSURE)
        ? (pAmbEnd - WATER_VAPOR_PRESSURE) * fractionN2
        : 0.0;

    // 2. 분당 질소 압력 변화율 (R)
    double R = (pGasN2End - pGasN2Start) / timeMin;

    for (int i = 0; i < NUM_COMPARTMENTS; i++) {
      double Pi = loadings[i];
      double halfLife = n2HalfLives[i];
      double k = log(2.0) / halfLife;

      double pNew;

      // 3. 수치적 안정성을 위한 분기 처리
      // 수심 변화가 거의 없거나(R=0), 시간이 0에 가까우면 할데인 공식 사용
      if (R.abs() < 0.00001) {
        // 할데인(Haldane) 공식: P_new = Pi + (P_gas - Pi) * (1 - e^-kt)
        pNew = Pi + (pGasN2End - Pi) * (1.0 - exp(-k * timeMin));
      } else {
        // 표준 슈라이너(Schreiner) 공식
        double eKt = exp(-k * timeMin);
        // 공식: P_t = P_start + R*(t - 1/k) - (P_start - Pi - R/k) * e^-kt
        pNew =
            pGasN2Start +
            R * (timeMin - 1.0 / k) -
            (pGasN2Start - Pi - (R / k)) * eKt;
      }

      // 4. 안전 장치: 물리적으로 질소압이 0보다 작을 수 없음
      if (pNew < 0.0) pNew = 0.0;

      loadings[i] = pNew;
    }
  }

  static Duration? getSurfaceTime() {
    int lastDiveTime = APref.getData(AprefKey.LAST_DIVE_DATETIME);
    if (lastDiveTime == 0) {
      return null; // 첫 다이빙인 경우
    }
    var now = DateTime.now().millisecondsSinceEpoch;
    return Duration(milliseconds: now - lastDiveTime);
  }

  double calculateNDL() {
    double minTime = 999.0;
    double pSurface = 1.01325; // 표준 대기압

    double pAmb = 1.0 + (currentDepth.value / 10.0);
    double pGas = (pAmb - WATER_VAPOR_PRESSURE) * fractionN2;
    if (pGas < 0) pGas = 0;

    for (int i = 0; i < NUM_COMPARTMENTS; i++) {
      // M-value 계산 (Buhlmann 공식)
      double mSurf = aCoefficients[i] + (pSurface / bCoefficients[i]);
      double pTol = pSurface + gfHigh * (mSurf - pSurface);

      if (currentLoadings[i] > pTol) return 0.0;
      if (pGas <= pTol) continue;

      // NDL 역계산 공식
      double numerator = pGas - pTol;
      double denominator = pGas - currentLoadings[i];

      if (denominator <= 0.0001) continue;

      double time = (-n2HalfLives[i] / log(2.0)) * log(numerator / denominator);

      if (time < minTime) minTime = time;
    }
    return (minTime > 999.0) ? 999.0 : minTime;
  }

  void calculateDecoStop() {
    // 1. 시뮬레이션용 로딩 배열 복사 (원본 보존)
    List<double> tempLoadings = List.from(currentLoadings);

    // 1. 수면(0m)이 안전한지 확인 (NDL 체크)
    // 수면에서는 GF High를 적용하여 검사
    if (isDepthSafe(0.0, tempLoadings, gfHigh)) {
      needDeco.value = false; // 감압 불필요 (NDL 남음)
      decoStopDepth.value = 0;
      decoStopTime.value = 0;
      return;
    }

    needDeco.value = true; // 감압 필요
    // 2. 감압 정지 수심(Ceiling) 찾기
    // 3m 부터 시작해서 3, 6, 9... 순으로 내려가며 안전한지 확인
    // 주의: 첫 정지 수심을 찾는 것이므로 GF_Low를 기준으로 함 (보수적 접근)
    int depth = 3;
    while (depth < 300) {
      // 최대 300m 제한 (무한루프 방지)
      if (isDepthSafe(depth.toDouble(), tempLoadings, gfLow)) {
        // 이 수심은 안전함! -> 여기가 바로 정지 수심
        decoStopDepth.value = depth;
        break;
      }
      depth += 3; // 3m 더 깊이 내려가서 확인
    }

    // 3. 정지 시간 계산 (시뮬레이션)
    // 현재 발견한 stop_depth에서 얼마나 있어야, 다음 단계(stop_depth - 3m)로 갈 수 있나?
    // GF 보간 (Interpolation):
    // 현재 정지 수심에서는 GF_Low, 수면에서는 GF_High.
    // 하지만 다음 단계로 넘어가기 위한 기준은 그 사이의 어떤 GF 값임.
    // 편의상 여기서는 보수적으로 GF_Low를 유지하거나, 깊이에 따라 선형 보간해야 함.
    // *표준 구현*: 현재 정지 수심이 'Deepest Stop'이므로 GF_Low를 적용.
    // 시간이 지나서 다음 수심으로 갈 수 있는지 체크할 때도,
    // 다음 수심에 해당하는 GF(선형 보간된 값)를 넘지 않는지 봐야 함.
    int seconds = 0;
    double nextStopDepth = (decoStopDepth.value - 3).toDouble();
    while (seconds < 3600) {
      // 최대 99분 제한 (99 * 60)
      // A. 10초 후의 질소 상태 예측 (기체는 현재 기체)
      // Update_N2_Loadings 함수 재사용 (시간 10초)
      updateN2Loadings(
        tempLoadings,
        decoStopDepth.value.toDouble(),
        fractionO2,
        10.0,
      );
      seconds += 10;

      // B. 이제 3m 위로 올라가도 안전한가?
      // 올라갈 목표 수심에 대해 적절한 GF 계산 (선형 보간)
      // Slope = (GF_High - GF_Low) / (0 - First_Stop_Depth)
      // GF_target = GF_High - (Slope * Target_Depth)
      // 하지만 First_Stop_Depth는 고정되어야 함 (최초 발견된 plan.stop_depth)

      double slope =
          (gfHigh - gfLow) /
          (0.0 -
              decoStopDepth.value
                  .toDouble()); // 기울기는 음수 아님에 주의 (분모가 음수라 전체 양수화 필요하나 로직 점검 필요)
      // 정확한 로직: 깊을수록 GF 작음.
      // 분모: (0 - MaxDepth) -> 음수. 분자: (High - Low) -> 양수. 결과: 음수 기울기.
      // 식: GF = GF_Hi + Slope * Depth

      double gfAtNextDepth = gfHigh + slope * nextStopDepth;

      // 목표 수심(next_stop_depth)이 안전한지 체크
      if (isDepthSafe(nextStopDepth, tempLoadings, gfAtNextDepth)) {
        // 안전하다! 이제 올라가도 됨.
        decoStopTime.value = (seconds / 60.0).ceil();
        break;
      }
    }
  }

  int calculateTTS() {
    // 1. 시뮬레이션용 로딩 배열 복사 (원본 보존)
    List<double> tempLoadings = List.from(currentLoadings);

    double totalTimeMin = 0.0;
    double simDepth = currentDepth.value;
    const double ASCENT_RATE = 18.0; // 분당 18m 상승

    // 2. 무감압 한계(NDL) 이내인지 확인 (수면으로 바로 상승 가능한지 체크)
    // 수면 도착 시점의 안전도는 GF_High로 판단
    if (isDepthSafe(0.0, tempLoadings, gfHigh)) {
      // 감압 없이 바로 상승 가능하므로 상승 시간만 더함
      totalTimeMin = getAscentTime(simDepth, ASCENT_RATE);

      // 올림 처리하여 반환 (안전을 위해 분 단위 올림)
      return totalTimeMin.ceil();
    }

    // 3. 첫 번째 감압 정지 수심(Deepest Stop) 찾기
    // 바닥에서부터 3m 단위로 올라가며 GF_Low를 기준으로 안전한 첫 수심을 찾음
    int firstStopDepth = 0;
    for (int d = 3; d < simDepth.toInt(); d += 3) {
      if (isDepthSafe(d.toDouble(), tempLoadings, gfLow)) {
        firstStopDepth = d;
        break;
      }
    }
    // 만약 계산상 현재 수심보다 더 깊은 곳이 첫 정지라면(이론상), 현재 수심을 첫 정지로 설정
    if (firstStopDepth == 0 || firstStopDepth > simDepth) {
      firstStopDepth = simDepth.toInt(); // 매우 위험한 상황이나 시뮬레이션 위해 설정
    }

    // 4. 현재 수심에서 첫 정지 수심까지 상승 시뮬레이션
    double ascentDist = simDepth - firstStopDepth;
    double ascentTime = getAscentTime(ascentDist, ASCENT_RATE);

    // 상승하는 동안에도 가스 교환(배출/흡수)이 일어남
    // 평균 수심에서 해당 시간만큼 머무른 것으로 근사 계산
    double avgDepth = (simDepth + firstStopDepth) / 2.0;
    updateN2Loadings(tempLoadings, avgDepth, fractionO2, ascentTime * 60.0);

    totalTimeMin += ascentTime;
    simDepth = firstStopDepth.toDouble();

    // 5. 감압 정지 및 단계별 상승 루프 (Deco Loop)
    // GF 기울기 계산 (Deepest Stop에서는 GF_Low, 수면에서는 GF_High)
    // 공식: GF_slope = (GF_High - GF_Low) / (0 - first_stop_depth)
    // 주의: 분모가 음수이므로 기울기는 음수가 됨 (깊이가 0에 가까워질수록 GF값 증가)
    double gfSlope = (gfHigh - gfLow) / (0.0 - firstStopDepth.toDouble());

    while (simDepth > 0) {
      double nextDepth = simDepth - 3.0;
      if (nextDepth < 0) nextDepth = 0.0;

      // 다음 수심으로 가기 위해 필요한 목표 GF 계산 (선형 보간)
      double targetGf = gfHigh + (gfSlope * nextDepth);

      // 다음 수심(3m 위)이 안전한지 확인
      if (isDepthSafe(nextDepth, tempLoadings, targetGf)) {
        // 안전함 -> 다음 수심으로 이동 (3m 상승)
        double travel_time = getAscentTime(simDepth - nextDepth, ASCENT_RATE);

        // 이동 중 가스 교환 업데이트
        updateN2Loadings(
          tempLoadings,
          (simDepth + nextDepth) / 2.0,
          fractionO2,
          travel_time * 60.0,
        );

        totalTimeMin += travel_time;
        simDepth = nextDepth;
      } else {
        // 안전하지 않음 -> 현재 수심에서 1분간 감압 정지
        updateN2Loadings(
          tempLoadings,
          simDepth,
          fractionO2,
          60.0,
        ); // 1분(60초) 경과
        totalTimeMin += 1.0;
      }

      // 무한 루프 방지 (안전 장치)
      if (totalTimeMin > 999.0) break;
    }

    // 최종 결과는 분 단위 정수로 올림 반환
    return totalTimeMin.ceil();
  }

  double getAscentTime(double distM, double rateMMin) {
    if (distM <= 0) return 0.0;
    return distM / rateMMin;
  }

  bool isDepthSafe(double depthToCheck, List<double> loadings, double gf) {
    double pAmb = 1.0 + (depthToCheck / 10.0); // 주변 압력

    for (int i = 0; i < NUM_COMPARTMENTS; i++) {
      // 1. 순수 M-Value 계산
      double mPure = aCoefficients[i] + (pAmb / bCoefficients[i]);

      // 2. GF가 적용된 허용 한계치 (M_GF) 계산
      // 공식: M_GF = P_amb + GF * (M_pure - P_amb)
      double mGf = pAmb + gf * (mPure - pAmb);
      // 3. 현재 조직의 질소압이 허용치를 넘는지 검사
      if (loadings[i] > mGf) {
        return false; // 하나라도 넘으면 위험
      }
    }
    return true; // 모든 조직이 안전
  }

  bool processCycle() {
    checkSaftyStop();

    // PO2
    currentPO2.value =
        (1.0 + (currentDepth.value / 10.0) - WATER_VAPOR_PRESSURE) *
        fractionO2; // PO2 계산 (bar 단위)

    updateN2LoadingsSchreiner(
      currentLoadings,
      currentDepth.value,
      prevDepth,
      fractionO2,
      intervalSeconds,
    );

    ndl.value = calculateNDL();
    tts.value = calculateTTS();
    calculateDecoStop();

    prevDepth = currentDepth.value;
    // 최대 수심 업데이트
    if (currentDepth.value > maxDepth.value) {
      maxDepth.value = currentDepth.value;
    }
    // 다이빙 시작 조건
    if (1.5 <= currentDepth.value) {
      currentDiveTime.value += Duration(seconds: intervalSeconds.toInt());
    } else {
      isOnDiving.value = false;
      tts.value = 0;
      return false; // 수심이 1.5m 이하로 내려가면 다이빙 종료
    }

    return true;
  }

  void startDive() {
    if (isOnDiving.value) return; // 이미 다이빙 중인 경우 중복 실행 방지
    isOnDiving.value = true;
    currentDiveTime.value = Duration.zero;
    _timer = Timer.periodic(Duration(seconds: intervalSeconds.toInt()), (
      timer,
    ) {
      processCycle();
    });
  }

  void checkSaftyStop() {
    // 10미터 초과 내려가면 안전정지 3분 생김
    if (10 < currentDepth.value && saftyStop.value.inSeconds <= 0) {
      saftyStop.value = Duration(seconds: 180);
    }

    // 안전 정지 2분 추가 조건들 -->
    // 1. 깊은 수심 다이빙
    if (saftyStop.value.inSeconds == 180 && 30 < currentDepth.value) {
      // 30미터 초과 내려가면 안전정지 2분 추가
      saftyStop.value = saftyStop.value + Duration(seconds: 120);
    }

    // 2. NDL에 근접한 다이빙
    if (saftyStop.value.inSeconds == 180 && ndl.value <= 5) {
      // NDL 5분 이하로 내려가면 안전정지 2분 추가
      saftyStop.value = saftyStop.value + Duration(seconds: 120);
    }

    // 3. 빠른 상승속도(분당 18미터 이상)로 상승한 경우
    double ascentRate =
        (prevDepth - currentDepth.value) / (intervalSeconds / 60.0);

    // 상승 중(ascentRate > 0)이면서 속도가 18m/min을 초과할 때
    if (ascentRate > 18.0) {
      // 이미 안전정지 시간이 늘어났는지 체크하거나,
      // 특정 조건(예: 3분 기본 상태)일 때만 2분 추가
      if (saftyStop.value.inSeconds == 180) {
        saftyStop.value += Duration(seconds: 120);
      }
    }

    // 4. 반복 다이빙 (하루 3회이상 다이빙을 하거나 수면휴식이 짧은 경우)

    // <-- 안전정지 2분 추가 조건들

    if (saftyStop.value.inSeconds > 0 && currentDepth.value <= 6) {
      saftyStop.value = saftyStop.value - Duration(seconds: 1);
      if (saftyStop.value.inSeconds < 0) saftyStop.value = Duration.zero;
    }
  }
}
