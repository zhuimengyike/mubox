#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""静态判据：「导出全部歌曲到手机」不许再把旧文件当成功导出（谎报）。

为什么要有它
------------
`MainActivity.exportToMusic` 曾经写成「按 DISPLAY_NAME+RELATIVE_PATH 查到同名条目 ⇒ 直接
return 旧 uri」，一行漂移都没有地骗过了 Dart 侧的成功判定（`lib/export_service.dart` 拿到
非空 uri 就算导出成功），于是「已导出 N/N 首」而磁盘上一个字节都没动（旧歌名/旧封面/旧码率
一直躺在 Music/MuBox）。

这个脚本**不新增任何 gradle 依赖**、不跑编译，只对源码做结构化静态检查。它在
`exportToMusic` 的函数体（花括号配平取出，字符串字面量里的花括号不参与配平）里断言：

  必须没有（负向）：
    N1  在返回值里直接使用 `queryByName(name)` 的结果   ← 旧缺陷的形态
        （修复后的写法是 `val existing = queryByName(name)`，或带内容比对的短路条件）

  必须有（正向）：
    P1  `existing != null && sameContent(src, existing) == false`（内容比对的短路判断）
    P2  `sameContent` 的调用 + 它自己的完整定义（大小不符 ⇒ false；大小相同 ⇒ 比 sha256）
    P3  `openOutputStream(uri, "rwt")` 覆写（rwt 的 t = 截断，官方 ContentResolver 模式）
    P4  真的从源文件向输出流 copy
    P5  通道回包带 "status"（Dart 侧才分得清「真写了」和「内容一致没重写」）

判定：0 = 通过，1 = 判据不成立。用法：
    python check_export_no_reuse.py [MainActivity.kt 的路径]
"""

import re
import sys
from pathlib import Path

# 中文输出别被 Windows 控制台代码页吃掉（PS 5.1 默认 GBK 会把中文变成乱码）
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

DEFAULT_TARGET = (
    "android/app/src/main/kotlin/com/mubox/mu_box_phone/MainActivity.kt"
)

fails: list[str] = []
oks: list[str] = []


def strip_comments(src: str) -> str:
    """去掉 // 行注释与 /* */ 块注释。

    字符串字面量按「遇到引号整段跳过」处理，所以注释里出现引号不会把状态机带跑；
    Kotlin 的 `"` 字符串默认不允许裸换行，`${...}` 等值块也不需要在这里求值。
    """
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '"':
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == '"':
                    j += 1
                    break
                j += 1
            out.append(src[i:j])
            i = j
        elif c == "/" and i + 1 < n and src[i + 1] == "/":
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif c == "/" and i + 1 < n and src[i + 1] == "*":
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def extract_function(src: str, name: str) -> str | None:
    """抓出 `fun <name>(...) { ... }` 的函数体（含声明行），括号按花括号配平。"""
    m = re.search(r"\bfun\s+" + re.escape(name) + r"\s*\(", src)
    if not m:
        return None
    i, n, depth, started = m.start(), len(src), 0, False
    while i < n:
        if src[i] == "{":
            depth += 1
            started = True
        elif src[i] == "}":
            depth -= 1
            if started and depth == 0:
                return src[m.start():i + 1]
        i += 1
    return None


def check_absent(body: str, label: str, pattern: str, why: str) -> None:
    if re.search(pattern, body):
        fails.append(f"F {label} 不该出现的写法仍在：{why}")
    else:
        oks.append(f"OK {label} 不存在旧写法（{why}）")


def check_present(body: str, label: str, pattern: str, why: str,
                  flags: int = re.S) -> None:
    if re.search(pattern, body, flags):
        oks.append(f"OK {label} 在位（{why}）")
    else:
        fails.append(f"F {label} 找不到：{why}")


def main() -> int:
    target = Path(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_TARGET)
    if not target.is_file():
        print(f"F 找不到目标文件：{target}")
        return 1
    raw = target.read_text(encoding="utf-8")
    src = strip_comments(raw)

    body = extract_function(src, "exportToMusic")
    if body is None:
        print(f"F 找不到 fun exportToMusic —— 文件结构变了，判据作废（{target}）")
        return 1

    print(f"目标文件：{target}")
    print(f"exportToMusic 函数体：{len(body)} 字符，起于文件第 "
          f"{src[:src.find(body)].count(chr(10)) + 1} 行")
    print("-" * 72)

    # ---- 负向：旧缺陷形态（命中同名 ⇒ 直接 return 旧 uri）必须不存在 ----
    # N1：`queryByName(...)?.let { return it }` —— 修复前那一版的实际写法
    check_absent(
        body, "N1",
        r"queryByName[\s\S]{0,120}?\.let\s*\{\s*(?:return|it\s*\}\s*\})",
        "命中同名后 ?.let { return it } 直接交旧 uri",
    )
    # N2：`!= null` 紧跟着把查到的 uri 直接交出去 —— 原缺陷本体
    check_absent(
        body, "N2",
        r"!=\s*null\s*\)\s*\{?\s*return\s+\w+",
        "已知同名存在就把旧 uri 交出去 = 原始缺陷本体",
    )
    # N3：`return` 的主语来自 queryByName( 且**同一行里没有内容比对**（N1/N2 的兜底网）
    check_absent(
        body, "N3",
        r"return[^\n]*queryByName\s*\((?![^\n]*sameContent)",
        "return ... queryByName(...) 且不比对内容",
    )

    # ---- 正向：跳过之前必须有「内容比对」这道闸 ----
    check_present(
        body, "G1",
        r"if\s*\([^)]*!=\s*null[^)]{0,80}(?:!?\s*sameContent\s*\()",
        "同名分支的口子是 sameContent（不允许只凭「存在」就跳过）",
    )

    # ---- 正向：内容比对 + 原地覆写 + 结果上报 ----
    check_present(
        body, "P1",
        r"queryByName\s*\(\s*name\s*\)\s*;?\s*if\s*\(\s*\w+\s*!=\s*null\s*&&\s*"
        r"!?\s*sameContent\s*\(",
        "同名条目必须先过内容比对才允许跳过",
    )
    check_present(
        body, "P2a", r"\bsameContent\s*\(\s*src\s*,\s*\w+\s*\)",
        "sameContent 被真正调用（不是只定义不调用）",
    )
    helper = extract_function(src, "sameContent")
    if helper is None:
        fails.append("F P2b 找不到 fun sameContent —— 内容比对函数不存在")
    else:
        check_present(helper, "P2b", r"SHA-256|SHA256|sha256",
                      "内容比对用 sha256（只比大小挡不住等长的不同内容）")
        check_present(helper, "P2c", r"MediaStore\.MediaColumns\.SIZE|MediaColumns\.SIZE",
                      "先看公共条目的 SIZE 做便宜筛除")
        check_present(helper, "P2d", r"openInputStream", "读公共条目内容")
    check_present(
        body, "P3a", r"openOutputStream\s*\([^)]*,\s*(?:\"rwt\"|\w+)\s*\)",
        "openOutputStream 带第二参数（模式）——默认 \"w\" 不截断，不能靠它",
    )
    check_present(
        body, "P3b", r"=\s*(?:if\s*\([^)]*\)\s*)?\"rwt\"",
        "覆写模式取 \"rwt\"（t = 截断；只写不截断会把变短的新文件尾部留成旧数据）",
    )
    check_present(
        body, "P4", r"\.copyTo\s*\(\s*out\s*\)",
        "真的把源文件字节写进输出流",
    )
    check_present(
        src, "P5", r"\"status\"\s+to\s+\w+\.status",
        "MethodChannel 回包带 status（Dart 侧才能区分「真写了」/「内容一致没重写」）",
    )
    check_present(
        src, "P6", r"argument<Boolean>\s*\(\s*\"report\"\s*\)",
        "新回包形状由 report=true 显式开启（老 Dart 调用方仍是纯 uri 字符串）",
    )

    print("\n".join(oks))
    print("-" * 72)
    if fails:
        print("\n".join(fails))
        print(f"\n判定：失败（{len(fails)} 条不成立）")
        return 1
    print(f"判定：通过（{len(oks)} 条全部成立）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
