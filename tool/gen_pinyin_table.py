#!/usr/bin/env python3
"""从 lpinyin 的字典生成「汉字 -> 拼音首字母」紧凑表（lib/pinyin_sort.dart）。

为什么不直接依赖 lpinyin：
    lpinyin 的 lib 有 398 KB（其中 dict_data.dart 381 KB），而按拼音排序只需要**首字母**。
    抽成一张按码点索引的定长表后只有 ~21 KB —— 小 18 倍，而且生成完就不再依赖那个包，
    它哪天不维护、改 API、下架，都跟我们无关。

字典本身**不入库**（381 KB 不值得），要用时按下述方式取回：
    curl -L https://pub.flutter-io.cn/api/archives/lpinyin-2.0.3.tar.gz -o lpinyin.tgz
    tar -xzf lpinyin.tgz -C lpinyin
    python tool/gen_pinyin_table.py --src lpinyin/lib/src/dict_data.dart

跑完请确认 `flutter analyze` 无告警，并把生成的 lib/pinyin_sort.dart 一起提交。
"""

import argparse
import re
import sys
import unicodedata
from pathlib import Path

# CJK 统一表意文字基本区。扩展区（生僻字）不收录，排序时兜底即可。
LO, HI = 0x4E00, 0x9FFF
PLACEHOLDER = "."
LINE_WIDTH = 100


def strip_tone(syllable: str) -> str:
    """去掉拼音声调：NFD 分解后丢掉组合记号。

    lpinyin 的拼音是带调的（'lǎo'、'ài'），而带调元音（à/ā/ǎ）不是 ASCII 字母，
    直接取首字符会漏掉一整类字 —— 必须先规范化。
    """
    decomposed = unicodedata.normalize("NFD", syllable)
    base = "".join(c for c in decomposed if not unicodedata.combining(c))
    return base


def parse_dict(text: str) -> dict:
    """解析 `const List<String> pinyinDict = ['耀=yào', ...]`，返回 {码点: 首字母}。"""
    table = {}
    bad = 0
    for ch, pinyin in re.findall(r"'([^'=])=([^']+)'", text):
        if len(ch) != 1:
            continue
        first = pinyin.split(",")[0].strip()  # 多音字取第一个读音
        if not first:
            bad += 1
            continue
        base = strip_tone(first)[:1].upper()
        if "A" <= base <= "Z":
            table[ord(ch)] = base
        else:
            bad += 1
    if bad:
        print(f"  (跳过 {bad} 条无法取首字母的条目)")
    return table


def build_table(table: dict) -> str:
    return "".join(table.get(cp, PLACEHOLDER) for cp in range(LO, HI + 1))


def dart_literal(s: str) -> str:
    """拆成多行相邻字符串字面量（Dart 会自动拼接），避免单行几万字符。"""
    lines = [s[i : i + LINE_WIDTH] for i in range(0, len(s), LINE_WIDTH)]
    out = []
    for i, line in enumerate(lines):
        tail = ";" if i == len(lines) - 1 else ""
        out.append(f"    '{line}'{tail}")
    return "\n".join(out)


HEADER = '''/// 汉字 → 拼音首字母表：给「专辑 · 歌手」以及其它需要按拼音排序的地方用。
///
/// **本文件由脚本生成，不要手改** —— 改数据请跑 `tool/gen_pinyin_table.py`（见其文件头）。
/// 数据源：lpinyin 2.0.3 的 `dict_data.dart`（一次性提取）。生成后**不依赖 lpinyin**：
/// 表固化在仓库里，那个包不维护/下架都不影响本项目。
///
/// 表结构：下标 = 码点 - {lo:#x}，值 = 首字母 A-Z，`{ph}` = 未收录（生僻字、扩展区）。
/// 长度 {length} 字符（覆盖 CJK 基本区），已用多行字面量拼接。
library;

/// 表覆盖范围的起点（CJK 基本区首字）。
const int _kPinyinTableStart = {lo};

/// 未收录字符的占位符：排序时当作「排在最后」。
const String _kPinyinUnknown = '{ph}';

const String _kPinyinInitials =
{body}

/// 取单个字符的拼音首字母；非汉字或表内未收录时返回 null。
String? _initialOf(int rune) {{
  final i = rune - _kPinyinTableStart;
  if (i < 0 || i >= _kPinyinInitials.length) return null;
  final c = _kPinyinInitials[i];
  return c == _kPinyinUnknown ? null : c;
}}

/// 生成用于排序的键（比较两个字符串的返回值即可得到**拼音序**）。
///
/// 规则：
/// - 汉字 → 拼音首字母（大写），于是「陈奕迅」→ C…、「周杰伦」→ Z…
/// - ASCII 可打印字符（空格、标点、数字、字母）→ 原样保留，英文专辑名不会被拆散
/// - 其它（未收录的汉字、全角符号、假名…）→ `{{`（排在最后，内部仍按码点序，结果稳定）
///
/// 只用首字母而不是完整拼音：通讯录也是这么排的，而完整拼音字典要大好几倍。
/// 同首字母内不保证严格拼音序（例如「安」与「爱」），这是刻意的体积取舍。
String pinyinSortKey(String text) {{
  final b = StringBuffer();
  for (final r in text.runes) {{
    final ini = _initialOf(r);
    if (ini != null) {{
      b.write(ini);
    }} else if (r >= 0x20 && r < 0x7F) {{
      // ASCII 可打印字符原样保留（含空格与标点）：「Abbey Road」不该被空格拆成
      // 排在最后的碎片 —— 这一条是单测 `pinyin_sort_test.dart` 抓出来的。
      b.writeCharCode(r);
    }} else {{
      b.write('{{');
    }}
  }}
  return b.toString();
}}
'''


def main() -> int:
    ap = argparse.ArgumentParser(description="生成汉字拼音首字母表")
    ap.add_argument("--src", required=True, help="lpinyin 的 dict_data.dart 路径")
    ap.add_argument("--out", default="lib/pinyin_sort.dart", help="输出的 Dart 文件")
    args = ap.parse_args()

    src = Path(args.src)
    if not src.is_file():
        print(f"[x] 找不到字典文件: {src}")
        return 1

    text = src.read_text(encoding="utf-8")
    table = parse_dict(text)
    if len(table) < 3000:
        print(f"[x] 只解析出 {len(table)} 个字，字典格式可能变了，先别急着用")
        return 1

    body = build_table(table)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(
        HEADER.format(
            lo=LO, ph=PLACEHOLDER, length=len(body), body=dart_literal(body)
        ),
        encoding="utf-8",
    )

    filled = sum(1 for c in body if c != PLACEHOLDER)
    print(f"[ok] 收录 {filled} 个汉字 / 表长 {len(body)}")
    print(f"[ok] 写出 {out}（{out.stat().st_size / 1024:.1f} KB）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
