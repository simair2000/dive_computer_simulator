import 'package:dive_computer_flutter/hiveHelper.dart';

enum AprefKey {
  LAST_DIVE_DATETIME(0),
  LAST_N2_LOADING_LIST([]),
  LAST_HE_LOADING_LIST([]),
  ALWAYS_ON_TOP(false),
  AscentSpeed(10),
  DescentSpeed(18),
  GF_HIGH(0.85),
  GF_LOW(0.4),
  PPO2(1.4);

  final dynamic defValue;
  const AprefKey(this.defValue);
}

class APref {
  static Future setData(AprefKey key, dynamic value) async {
    await HiveHelper().prefBox.put(key.name, value);
  }

  static dynamic getData(AprefKey key, {dynamic defaultValue}) {
    return HiveHelper().prefBox.get(
      key.name,
      defaultValue: defaultValue ?? key.defValue,
    );
  }

  static void removeData(AprefKey key) {
    HiveHelper().prefBox.delete(key.name);
  }
}
