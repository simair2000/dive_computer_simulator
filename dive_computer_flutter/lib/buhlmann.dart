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

  double currentDepth = 0.0; // 현재 수심 (미터 단위)
  double prevDepth = 0.0; // 이전 수심 (미터 단위)

  double gfHigh = 0.8; // 고감압 계수 (예시값, 실제로는 다이빙 프로필에 따라 조정 필요)
  double gfLow = 0.2; // 저감압 계수 (예시값, 실제로는 다이빙 프로필에 따라 조정 필요)
  var ndl = ValueNotifier<double>(0.0); // 무감압 한계 시간 (분 단위)
  var tts = ValueNotifier<int>(0); // Time To Surface (분 단위)

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

    double pAmb = 1.0 + (currentDepth / 10.0);
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

  bool processCycle() {
    updateN2LoadingsSchreiner(
      currentLoadings,
      currentDepth,
      prevDepth,
      fractionO2,
      intervalSeconds,
    );
    ndl.value = calculateNDL();
    prevDepth = currentDepth;
    return true;
  }
}
