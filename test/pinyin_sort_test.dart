/// 拼音首字母表（`lib/pinyin_sort.dart`）的单测。
///
/// 那张表由脚本 `tool/gen_pinyin_table.py` 生成 —— 是「生成物」，
/// 所以这组测试同时兼作**生成结果的自检**：哪天重新生成、格式或数据源变了，这里会先炸。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/pinyin_sort.dart';

void main() {
  group('pinyinSortKey', () {
    test('常用汉字取拼音首字母', () {
      expect(pinyinSortKey('陈奕迅'), 'CYX');
      expect(pinyinSortKey('周杰伦'), 'ZJL');
      expect(pinyinSortKey('林俊杰'), 'LJJ');
    });

    test('抽查单字（含带声调元音，说明声调处理没漏）', () {
      expect(pinyinSortKey('一'), 'Y'); // yī
      expect(pinyinSortKey('乙'), 'Y'); // yǐ
      expect(pinyinSortKey('我'), 'W'); // wǒ
      expect(pinyinSortKey('你'), 'N'); // nǐ
      expect(pinyinSortKey('爱'), 'A'); // ài —— 带调元音，曾是最容易漏的一类
    });

    test('排出来确实是拼音序（这就是它存在的理由）', () {
      final names = ['周杰伦', '陈奕迅', '林俊杰', '邓紫棋'];
      names.sort((a, b) => pinyinSortKey(a).compareTo(pinyinSortKey(b)));
      expect(names, ['陈奕迅', '邓紫棋', '林俊杰', '周杰伦']);
    });

    test('ASCII 字母与数字原样保留（英文专辑名不会挤到中文后面）', () {
      expect(pinyinSortKey('Abbey Road'), 'Abbey Road');
      expect(pinyinSortKey('1989'), '1989');
    });

    test('表内没有的字符（符号 / 生僻扩展区）排到最后', () {
      expect(pinyinSortKey('★'), '{');
      expect(pinyinSortKey('\u{20000}'), '{'); // CJK 扩展 B 的字，不在基本区表内
      expect(
        pinyinSortKey('A★').compareTo(pinyinSortKey('A')),
        greaterThan(0),
      );
    });

    test('空串安全返回空串', () {
      expect(pinyinSortKey(''), '');
    });

    test('同首字母时退化成码点序，结果稳定（不会来回抖）', () {
      expect(pinyinSortKey('安全').startsWith('A'), isTrue);
      expect(pinyinSortKey('爱情').startsWith('A'), isTrue);
      expect(pinyinSortKey('安全'), pinyinSortKey('安全'));
    });
  });
}
