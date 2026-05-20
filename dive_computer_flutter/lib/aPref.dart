import 'package:dive_computer_flutter/hiveHelper.dart';

enum AprefKey {
  LAST_DIVE_DATETIME(0),
  LAST_N2_LOADING_LIST([]),
  LAST_HE_LOADING_LIST([]),
  ALWAYS_ON_TOP(false),
  AscentSpeed(10),
  DescentSpeed(18),
  GAS_SWITCH_TIME(1.0),
  GF_HIGH(0.85),
  GF_LOW(0.4),
  PPO2_BOTTOM(1.4),
  PPO2_DECO(1.6),
  VC_AUTO_CORRECTION(true),
  VC_AUTO_STRENGTH(0.62),
  VC_CONTRAST(1.2),
  VC_BRIGHTNESS(6.0),
  VC_SATURATION(1.12),
  VC_TEMPERATURE(10.0),
  VC_RED_RECOVERY(1.05),
  VC_GREEN_WATER_AUTO_CORRECTION(false),
  VC_GREEN_WATER_STRENGTH(0.55),
  VC_BLUE_OCEAN_TONE(1.12),
  VC_PARTICLE_REDUCTION(false),
  VC_PARTICLE_REDUCTION_STRENGTH(0.55),
  VC_PREVIEW_MATCH_MODE(true),
  VC_AUDIO_VOLUME(1.0),
  VC_CORRECTION_PRESETS(const <String, dynamic>{}),
  VC_LAST_PRESET_NAME('');

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
