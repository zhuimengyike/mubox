/// 「允许后台运行」一次性引导（U1）的断言。
///
/// 正向：四行真值表 —— 只有「从没提示过 + 还没授权」才该弹一次。
/// 负向：把**落盘那一步**收起来 ⇒ 同一场景重启后又弹 —— 证明「一辈子一次」
/// 靠的是 SharedPreferences（`bg_hint_shown`），不是内存字段。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/app_config.dart';
import 'package:mu_box_phone/bg_hint.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('shouldShowBgHint 真值表', () {
    test('未提示 + 未授权 → 弹', () {
      expect(shouldShowBgHint(alreadyShown: false, granted: false), isTrue);
    });

    test('未提示 + 已授权 → 不弹（已经有权限了，别烦人）', () {
      expect(shouldShowBgHint(alreadyShown: false, granted: true), isFalse);
    });

    test('已提示 + 未授权 → 不弹（点了不点都算提示过，永久置位）', () {
      expect(shouldShowBgHint(alreadyShown: true, granted: false), isFalse);
    });

    test('已提示 + 已授权 → 不弹', () {
      expect(shouldShowBgHint(alreadyShown: true, granted: true), isFalse);
    });
  });

  group('「一辈子一次」靠落盘，不靠内存', () {
    // ⚠️ 负向用例必须排在**最前**：AppConfig 缓存了 SharedPreferences 实例
    // （`_prefs`），`setMockInitialValues` 只换底层存储、不换它 —— 先跑正向往
    // 磁盘写过 `bg_hint_shown` 的话，这里读到的就不是「干净磁盘」了。
    test('负向：只置内存、不落盘 ⇒ 重读后又变回 false，同一个场景重启又弹一次', () async {
      SharedPreferences.setMockInitialValues({});
      AppConfig.instance.bgHintShown = true; // 模拟「漏掉落盘那一步」的写法
      final sp = await SharedPreferences.getInstance();
      expect(sp.getBool('bg_hint_shown'), isNull,
          reason: '没落盘 ⇒ 磁盘上什么都没有');

      await AppConfig.load(); // 模拟冷启动：内存字段由磁盘重建
      expect(AppConfig.instance.bgHintShown, isFalse);
      expect(
        shouldShowBgHint(
          alreadyShown: AppConfig.instance.bgHintShown,
          granted: false,
        ),
        isTrue,
        reason: '同一个场景（还是没授权）重启后又弹了一次 —— 这就是「靠内存」的下场',
      );
    });

    test('正向：落盘之后重启不再弹', () async {
      SharedPreferences.setMockInitialValues({});
      await AppConfig.instance.setBgHintShown(true); // 真实写法：字段 + prefs
      final sp = await SharedPreferences.getInstance();
      expect(sp.getBool('bg_hint_shown'), isTrue, reason: '写进 prefs 了');

      AppConfig.instance.bgHintShown = false; // 模拟冷启动后的字段缺省值
      await AppConfig.load();
      expect(AppConfig.instance.bgHintShown, isTrue, reason: '从 prefs 读回来了');
      expect(
        shouldShowBgHint(
          alreadyShown: AppConfig.instance.bgHintShown,
          granted: false,
        ),
        isFalse,
        reason: '提示过就不再弹（哪怕用户当时没点「去设置」）',
      );
    });
  });
}
