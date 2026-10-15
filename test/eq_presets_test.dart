/// 均衡器「我的预设」的断言：**纯逻辑往返** + **经引擎的坏值隔离**。
///
/// 正向：存 → 序列化 → 解析 原样回来；同名覆盖、id 稳定、曲线逐段匹配、频段数对齐。
/// 负向：`eq_presets` 被写坏 ⇒ **解析成空、绝不抛、也绝不把整个 EQ 设置清空**
///       （读坏了当空，但原始串要留现场 —— 否则下一次写入就把现场永久盖掉，
///        这正是 `Store._decode` 那条规矩的由来）。
///
/// 为什么预设必须存 SharedPreferences 的 `eq_presets` 而不是 `docs/*.json`：
/// `backup_service.dart` 的 `createBackup` 把 prefs **全量**打进 `prefs.json`
/// （`:48-58`）、恢复侧全量写回（`:190-199`）；而它只特殊处理 `songs.json`
/// （`:64-65`）、只遍历 `kBackupDirs` 里的**目录**（`:71-81`）⇒ 单文件方案
/// 不进备份，换机/重装必丢（H4 同一类事故）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/eq_engine.dart';
import 'package:mu_box_phone/eq_presets.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('纯逻辑：序列化 / 解析 / 坏数据', () {
    test('往返：encode → parse 原样回来（id / 名字 / 曲线）', () {
      const items = [
        EqUserPreset(
          id: 'p1',
          name: '我的低音',
          levels: [300, 100, 0, -100, -300],
        ),
        EqUserPreset(id: 'p2', name: '睡前', levels: [0, 0]),
      ];
      final parsed = parseEqPresets(encodeEqPresets(items));
      expect(parsed.damaged, isFalse);
      expect([for (final p in parsed.items) p.id], ['p1', 'p2']);
      expect([for (final p in parsed.items) p.name], ['我的低音', '睡前']);
      expect(parsed.items[0].levels, [300, 100, 0, -100, -300]);
      expect(parsed.items[1].levels, [0, 0]);
    });

    test('坏 JSON / 不是数组 ⇒ 空 + damaged（不抛）', () {
      for (final raw in ['这不是 JSON', '{不是数组}', '[,]', '{"a":1}', '"字符串"', '123']) {
        final r = parseEqPresets(raw);
        expect(r.items, isEmpty, reason: raw);
        expect(r.damaged, isTrue, reason: raw);
      }
    });

    test('没存过 / 空串 / 空数组 ⇒ 空但**不算**坏（不该写现场键）', () {
      for (final raw in [null, '', '   ', '[]']) {
        final r = parseEqPresets(raw);
        expect(r.items, isEmpty, reason: '$raw');
        expect(r.damaged, isFalse, reason: '$raw');
      }
    });

    test('里面坏的一项跳过、其余照读（一项坏 ≠ 整份丢）', () {
      final raw = jsonEncode([
        {'id': 'p1', 'name': '好的', 'levels': [100, 200]},
        {'id': 'p2', 'name': '', 'levels': [1, 2]}, // 名字空 → 跳过
        {'id': 'p3', 'levels': [1, 2]}, // 没名字 → 跳过
        'not a map', // 类型不对 → 跳过
        {'id': 'p4', 'name': '曲线坏了', 'levels': [100, 'x']}, // 有一段不是数 → 跳过
        {'id': 'p5', 'name': '也是好的', 'levels': ['-50', '60']}, // 字符串数字 → 认
      ]);
      final r = parseEqPresets(raw);
      expect(r.damaged, isFalse, reason: '这是「项坏」不是「整份坏」');
      expect([for (final p in r.items) p.name], ['好的', '也是好的']);
      expect(r.items[0].levels, [100, 200]);
      expect(r.items[1].levels, [-50, 60]);
    });

    test('同名项（被手改过）只留第一套，否则「点这个高亮那个」', () {
      final raw = jsonEncode([
        {'id': 'p1', 'name': '摇滚', 'levels': [1]},
        {'id': 'p2', 'name': ' 摇滚 ', 'levels': [2]},
      ]);
      final r = parseEqPresets(raw);
      expect(r.items.length, 1);
      expect(r.items.single.levels, [1]);
    });

    test('id 缺失或撞车都会补号：两套预设不许共用一个 id（删除会误伤）', () {
      final raw = jsonEncode([
        {'name': 'A', 'levels': [1]}, // 没 id
        {'id': 'p1', 'name': 'B', 'levels': [2]},
        {'id': 'p1', 'name': 'C', 'levels': [3]}, // 与上一项撞车
      ]);
      final r = parseEqPresets(raw);
      final ids = [for (final p in r.items) p.id];
      expect(ids.length, 3);
      expect(ids.toSet().length, 3, reason: 'id 必须互不相同');
      expect(ids.every((e) => e.isNotEmpty), isTrue);
    });
  });

  group('纯逻辑：增删改 / 去重 / 匹配', () {
    test('同名保存 = 覆盖那套的曲线（不新增、id 与顺序都不变）', () {
      var items = savePreset(const [], name: '我的低音', levels: [10, 20]);
      expect(items.length, 1);
      final id = items.single.id;
      items = savePreset(items, name: '别的', levels: [1]);
      items = savePreset(items, name: ' 我的低音 ', levels: [30, 40]); // 空格也算同名
      expect(items.length, 2, reason: '重名不新增');
      expect(items.first.id, id, reason: '覆盖不动 id');
      expect(items.first.name, '我的低音', reason: '把这次输入的名字规范化后写回');
      expect(items.first.levels, [30, 40]);
      expect(items.last.name, '别的');
    });

    test('大小写不同也算同一套（英文名）', () {
      var items = savePreset(const [], name: 'Bass', levels: [1]);
      items = savePreset(items, name: 'bass', levels: [2]);
      expect(items.length, 1);
      expect(items.single.levels, [2]);
    });

    test('名字空白 ⇒ 什么都不做（不建无名预设）', () {
      expect(savePreset(const [], name: '   ', levels: [1]), isEmpty);
    });

    test('存的是曲线副本：外面再改那个 list 不影响已存的预设', () {
      final levels = [1, 2, 3];
      final items = savePreset(const [], name: 'A', levels: levels);
      levels[0] = 999;
      expect(items.single.levels, [1, 2, 3]);
    });

    test('新 id 按现有最大号 +1（按数量算会在删掉中间那套后撞号）', () {
      expect(nextPresetId(const []), 'p1');
      const items = [
        EqUserPreset(id: 'p1', name: 'A', levels: [1]),
        EqUserPreset(id: 'p3', name: 'B', levels: [2]),
      ];
      expect(nextPresetId(items), 'p4');
    });

    test('按 id 删除（幂等、找不到不动）', () {
      var items = savePreset(const [], name: 'A', levels: [1]);
      items = savePreset(items, name: 'B', levels: [2]);
      final a = items.firstWhere((p) => p.name == 'A');
      items = removePreset(items, a.id);
      expect([for (final p in items) p.name], ['B']);
      expect(removePreset(items, 'p404').length, 1);
      expect(presetById(items, a.id), isNull);
      expect(presetById(items, items.single.id)?.name, 'B');
    });

    test('高亮「当前选中」：只有曲线逐段相等才算', () {
      final items = savePreset(const [], name: 'A', levels: [10, 20, 30]);
      expect(presetMatchingLevels(items, [10, 20, 30])?.name, 'A');
      expect(presetMatchingLevels(items, [10, 20, 31]), isNull);
      expect(presetMatchingLevels(items, [10, 20]), isNull, reason: '段数不同不算选中');
      expect(presetMatchingLevels(items, const []), isNull);
      expect(presetMatchingLevels(const [], [1]), isNull);
    });
  });

  group('纯逻辑：频段数对齐与增益夹紧', () {
    test('换设备/换 ROM：段数少了补 0 dB、多了截掉、bands<=0 原样返回', () {
      expect(fitLevels([100, 200, 300], 5), [100, 200, 300, 0, 0]);
      expect(fitLevels([100, 200, 300], 2), [100, 200]);
      expect(fitLevels([7], 1), [7]);
      expect(fitLevels([1, 2], 0), [1, 2], reason: '原生还没附着（bands=0）时无从对齐');
      expect(fitLevels(const [], 3), [0, 0, 0]);
    });

    test('增益夹紧边界：越界夹到上下限；范围写反了也能夹进有效区间', () {
      expect(clampLevels([-9999, 0, 9999], min: -1500, max: 1500),
          [-1500, 0, 1500]);
      expect(clampLevels([-1500, 1500], min: -1500, max: 1500),
          [-1500, 1500]);
      expect(clampLevels([5], min: 10, max: -10), [5]);
      expect(clampLevels([100], min: 10, max: -10), [10]);
      expect(clampLevels([-100], min: 10, max: -10), [-10]);
    });
  });

  group('经 EqEngine：坏值隔离（不许崩、不许把整个 EQ 设置清空）', () {
    // ⚠️ 这一段顺序敏感：EqEngine 是单例、init() 有 `_inited` 早退，
    // 所以第一条必须最先跑 —— 此刻 _inited 还是 false，它才是在
    // 「干净磁盘 + 坏值」这个现场上做初始化的那一次。
    test('eq_presets 写坏 ⇒ 当空不抛；eq_enabled / eq_levels 一个都没丢；坏值留了现场', () async {
      SharedPreferences.setMockInitialValues({
        'eq_enabled': true,
        'eq_levels': ['100', '200'],
        'eq_presets': '这不是 JSON',
      });
      await EqEngine.instance.init();
      expect(EqEngine.instance.userPresets, isEmpty, reason: '读坏了当空');

      final sp = await SharedPreferences.getInstance();
      expect(sp.getBool('eq_enabled'), isTrue, reason: 'EQ 总开关不许被连带清空');
      expect(sp.getStringList('eq_levels'), ['100', '200'],
          reason: '曲线不许被连带清空');
      expect(sp.getString('eq_presets'), '这不是 JSON',
          reason: '原值要留着（还没被任何写入盖掉）');
      expect(sp.getString('eq_presets_corrupt'), '这不是 JSON',
          reason: '照 Store._decode 的规矩留现场');
    });

    test('坏值之上照常能存新预设，且现场不被覆盖', () async {
      expect(await EqEngine.instance.saveCurrentAs('我的低音'), isTrue);
      expect(EqEngine.instance.userPresets.single.name, '我的低音');
      expect(EqEngine.instance.userPresets.single.levels, [100, 200],
          reason: '存的就是当前曲线（eq_levels 那份）');

      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('eq_presets_corrupt'), '这不是 JSON',
          reason: '现场留最早那次，不许被新写入盖掉');
      expect(
        parseEqPresets(sp.getString('eq_presets')).items.single.name,
        '我的低音',
        reason: '新值已经落进 prefs（重启/恢复备份都读得回来）',
      );
    });

    test('重读（恢复备份后走 reloadPresets）拿到的是 prefs 里那一份', () async {
      await EqEngine.instance.reloadPresets();
      expect(EqEngine.instance.userPresets.single.name, '我的低音');
      expect(EqEngine.instance.userPresets.single.levels, [100, 200]);
    });

    test('applyNamed 走 setBands 同一条路：曲线落进 eq_levels、顺手打开总开关', () async {
      final p = EqEngine.instance.userPresets.single;
      await EqEngine.instance.applyNamed(p.id); // 测试里原生缺席，过桥失败要安静收场
      final sp = await SharedPreferences.getInstance();
      expect(sp.getStringList('eq_levels'), ['100', '200']);
      expect(sp.getBool('eq_enabled'), isTrue, reason: '选预设即视为「要听」');
    });

    test('applyNamed 认不出的 id：什么都不做，也不许改坏已有曲线', () async {
      await EqEngine.instance.applyNamed('p404');
      final sp = await SharedPreferences.getInstance();
      expect(sp.getStringList('eq_levels'), ['100', '200']);
    });

    test('removeNamed 删掉那套并落盘；删不存在的 id 幂等', () async {
      final id = EqEngine.instance.userPresets.single.id;
      await EqEngine.instance.removeNamed('p404');
      expect(EqEngine.instance.userPresets.length, 1);
      await EqEngine.instance.removeNamed(id);
      expect(EqEngine.instance.userPresets, isEmpty);
      final sp = await SharedPreferences.getInstance();
      expect(parseEqPresets(sp.getString('eq_presets')).items, isEmpty);
    });
  });
}
