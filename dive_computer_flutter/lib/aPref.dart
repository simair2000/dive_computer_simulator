import 'package:dive_computer_flutter/hiveHelper.dart';

enum AprefKey {
  LAST_DIVE_DATETIME(0),
  LAST_N2_LOADING_LIST([]),
  LAST_HE_LOADING_LIST([]),
  ALWAYS_ON_TOP(false),
  CYLINDER(11.0),
  RMV(20.0);

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
