import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/lrc.dart';

void main() {
  group('Lrc.parse', () {
    test('解析基本时间戳并按时间升序排序', () {
      final lines = Lrc.parse('[00:12.34]你好\n[00:10.00]世界');
      expect(lines.length, 2);
      expect(lines[0].time, const Duration(seconds: 10));
      expect(lines[0].text, '世界');
      expect(lines[1].time, const Duration(minutes: 0, seconds: 12, milliseconds: 340));
      expect(lines[1].text, '你好');
    });

    test('一行多时间戳展开为多行', () {
      final lines = Lrc.parse('[00:01.00][00:02.00]同一句');
      expect(lines.length, 2);
      expect(lines[0].text, '同一句');
      expect(lines[1].text, '同一句');
    });

    test('过滤元数据标签行（ti/ar/offset 等）', () {
      final lines = Lrc.parse('[ti:歌名]\n[ar:歌手]\n[offset:500]\n[00:05.00]正文');
      expect(lines.length, 1);
      expect(lines.single.text, '正文');
    });

    test('过滤网易云 credits 行（作词/作曲/编曲…）', () {
      final lines = Lrc.parse('[00:01.00]作词：张三\n[00:02.00]正文');
      expect(lines.length, 1);
      expect(lines.single.text, '正文');
    });

    test('去掉 UTF-8 BOM', () {
      final lines = Lrc.parse('﻿[00:01.00]第一句');
      expect(lines.length, 1);
      expect(lines.single.text, '第一句');
    });

    test('毫秒小数位补齐：.5 → 500ms', () {
      final lines = Lrc.parse('[00:01.5]文本');
      expect(lines.single.time,
          const Duration(minutes: 0, seconds: 1, milliseconds: 500));
    });

    test('厘秒分隔（冒号）：50 厘秒 → 500ms', () {
      final lines = Lrc.parse('[00:01:50]文本');
      expect(lines.single.time,
          const Duration(minutes: 0, seconds: 1, milliseconds: 500));
    });

    test('无时间戳的纯文本行被忽略', () {
      expect(Lrc.parse('这行没有时间戳\n也没有'), isEmpty);
    });
  });
}
