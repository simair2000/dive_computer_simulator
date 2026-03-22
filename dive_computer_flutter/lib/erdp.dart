// PADI eRDPml (Metric) 매핑 및 계산 클래스
import 'dart:math';

class PadiERdp {
  // 기준 수심 (m) - 실제 수심이 이 값들 사이에 있으면 무조건 더 깊은 수심으로 올림 처리
  static final List<int> depths = [10, 12, 14, 16, 18, 20, 22, 25, 30, 35, 40];

  // Table 1: 각 수심별 압력군(A~Z) 최대 허용 시간(분)
  // 0은 해당 수심에서 도달 불가능한(NDL 초과) 영역
  static final List<List<int>> times = [
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
    ],
    // 10m
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
    ],
    // 12m
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
    ],
    // 14m
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
    ],
    // 16m
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
    ],
    // 18m
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
    ],
    // 20m
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
    ],
    // 22m
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
    ],
    // 25m
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
    ],
    // 30m
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
    ],
    // 35m
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
    ],
    // 40m
  ];

  /// [기능 1] 첫 번째 다이빙 후 압력군 구하기 (Table 1)
  /// 반환값: 'A' ~ 'Z', NDL 초과 시 'OOR'
  static String getPressureGroup(double maxDepthMeters, int diveTimeMins) {
    if (maxDepthMeters < 1.5 || diveTimeMins <= 0) return '-';

    int targetDepthIdx = depths.indexWhere((d) => maxDepthMeters <= d);
    if (targetDepthIdx == -1) return 'OOR'; // 40m 초과 (Out Of Range)

    List<int> row = times[targetDepthIdx];
    for (int i = 0; i < row.length; i++) {
      if (row[i] == 0) continue;
      if (diveTimeMins <= row[i]) {
        return String.fromCharCode(65 + i); // 0=A, 1=B, 2=C...
      }
    }
    return 'OOR'; // NDL 초과
  }

  /// [기능 2] 수면 휴식 후 새로운 압력군 구하기 (Table 2)
  /// PADI RDP는 수면 휴식 시 잔류 질소를 60분 반감기(Half-life) 곡선으로 계산합니다.
  static String getNewPressureGroupAfterSurfaceInterval(
    String startingPG,
    int surfaceIntervalMins,
  ) {
    if (startingPG == '-' || startingPG == 'OOR') return startingPG;

    int startIdx = startingPG.codeUnitAt(0) - 64; // A=1, B=2, Z=26
    if (startIdx < 1 || startIdx > 26) return '-';

    // 60분 반감기 적용 지수 감쇠 로직
    num newIdxDouble = startIdx * pow(2.0, -surfaceIntervalMins / 60.0);
    int newIdx = newIdxDouble.round();

    if (newIdx < 1) return '-'; // 잔류 질소 완전 소멸
    return String.fromCharCode(64 + newIdx); // A~Z 반환
  }

  ///[기능 3] 재잠수 시 잔류 질소 시간 (RNT - Residual Nitrogen Time) (Table 3)
  /// 현재 내 압력군(PG)으로 다음 수심에 들어갔을 때, 이미 바닥에 머문 것으로 쳐야 하는 패널티 시간
  static int getResidualNitrogenTime(String currentPG, double nextDepthMeters) {
    if (currentPG == '-' || currentPG == 'OOR') return 0;

    int pgIdx = currentPG.codeUnitAt(0) - 65; // A=0, B=1 ...
    if (pgIdx < 0 || pgIdx > 25) return 0;

    int targetDepthIdx = depths.indexWhere((d) => nextDepthMeters <= d);
    if (targetDepthIdx == -1) return 0;

    List<int> row = times[targetDepthIdx];
    if (pgIdx < row.length && row[pgIdx] != 0) {
      return row[pgIdx];
    }

    return 0; // 해당 수심에서 그 압력군은 NDL을 초과하여 존재할 수 없음
  }

  /// [기능 4] 조정된 무감압 한계 시간 (ANDL - Adjusted No Decompression Limit)
  /// 다음 수심에서 내가 실제로 더 머물 수 있는 한계 시간 = (최대 NDL) - (RNT)
  static int getAdjustedNDL(String currentPG, double nextDepthMeters) {
    int targetDepthIdx = depths.indexWhere((d) => nextDepthMeters <= d);
    if (targetDepthIdx == -1) return 0;

    // 해당 수심의 원래 최대 무감압 한계 시간 (Table 1의 0이 아닌 가장 큰 값)
    int maxNDL = times[targetDepthIdx].lastWhere((t) => t > 0);

    // 잔류 질소 시간 빼기
    int rnt = getResidualNitrogenTime(currentPG, nextDepthMeters);

    int andl = maxNDL - rnt;
    return andl > 0 ? andl : 0;
  }
}
