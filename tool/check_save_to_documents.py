#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""静态判据：「App 内备份写到公共 Documents/MuBox」那条新方法不许退化成谎报 / 写错表 / 标错 MIME。

为什么要有它
------------
`MainActivity.saveToDocuments` 是把 App 私有 cache 里的备份 zip 落到**公共 Documents/MuBox/**、
让用户插数据线就能在电脑上看见的唯一通道。它有三类会**静默**出错的退化：

  1. 「同名即复用」（`exportToMusic` 在 `0b98cde` 之前的老毛病）—— 用户看到「已保存」，
     磁盘上还是上一份旧备份；
  2. 写错集合 —— 落进 `MediaStore.Audio`（音频表）⇒ 备份 zip 被当歌索引；或覆写模式写成 `"w"`
     （不截断）⇒ 变短的新备份尾部留着旧字节，文件看着更新了、内容却是脏的；
  3. MIME 标错 —— 复用音频用的 `mimeOf`（未知后缀回 `audio/mpeg`）⇒ 系统/文件管理器拿备份
     当音频文件。

这个脚本**不新增任何 gradle 依赖**、不跑编译，只对源码做结构化静态检查。它先剥掉注释
（否则本文件与源码注释里写的「旧写法」会被自己判红），再取出 `saveToDocuments` 的函数体
（花括号配平；字符串字面量里的花括号不参与配平），在**函数体内**断言：

  必须没有（负向）：
    N1  命中同名后 `queryDocByName(...)?.let { return it }` 直接交旧 uri（旧缺陷形态）
    N2  `!= null` 紧跟着把查到的 uri 直接交出去（原缺陷本体）
    N3  `return ... queryDocByName(...)` 且同行没有内容比对（N1/N2 的兜底网）
    N4  新增块里写进 `MediaStore.Audio` 集合（音频表；备份文件不该进音乐库）
    N5  调 `mimeOf(...)`（音频 MIME 表，未知后缀回 audio/mpeg）
    N6  给 `files` 表写未验证存在的 `TITLE` 列（不被认就是 IllegalArgumentException）

  必须有（正向）：
    P1  同名分支的口子是 `sameContent`（只凭「存在」不许跳过）
    P2  `sameContent` 真被调用 + 它自己的定义（大小筛除 + sha256）
    P3  `openOutputStream(uri, mode)` 带第二参数，且覆写取 `"rwt"`（t = 截断）
    P4  真的从源文件向输出流 copy
    P5  失败**只删本次新建**的条目（`if (existing == null) … delete`）
    P6  `RELATIVE_PATH = Environment.DIRECTORY_DOCUMENTS + "/" + 子目录`，且写盘那支真的用它，
        且新建条目三列（DISPLAY_NAME / MIME_TYPE / RELATIVE_PATH）齐全
    P7  集合是 `MediaStore.Files.getContentUri(…)`（含 API29 分支与老机型分支）
    P8  `docMimeOf` 里 `.zip -> application/zip`，未知后缀 -> `application/octet-stream`
    P9  查询走 Files 表 + `RELATIVE_PATH`/`DISPLAY_NAME` 两个条件
    P10 源文件不存在 ⇒ `return null`（与 exportToMusic 同语义）
    P11 通道侧：`"saveToDocuments"` 分支在位、回包带 `"status"`、
        `report=true` 才换回包形状（不带仍是纯 uri 字符串，⛔ 不许删这条兼容）
    P12 参数名契约：`src` / `name` / `subdir`（Dart 侧接线照这个拼）

判定：0 = 通过，1 = 判据不成立。用法（**必须在仓库根跑**）：
    python tool/check_save_to_documents.py [MainActivity.kt 的路径]
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

    字符串字面量按「遇到引号整段跳过」处理，所以注释里出现引号不会把状态机带跑。
    ⚠️ 本判据里**必须有这一步**：新增块自己的注释里就写着 `MediaStore.Audio` 与 `mimeOf`。
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
    """抓出 `[private ]fun <name>(...) { ... }`（含声明行的修饰符），花括号配平。"""
    m = re.search(
        r"^[ \t]*(?:private |internal |public |protected )?fun\s+" + re.escape(name) + r"\s*\(",
        src, re.M,
    )
    if not m:
        return None
    i, n, depth, started = m.start(), len(src), 0, False
    j = src.find("{", m.end())
    if j < 0:
        return None
    i = j
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


def extract_branch(src: str, marker: str) -> str | None:
    """切出 MethodChannel 里以 `marker`（如 `"saveToDocuments" ->`）开头的那条分支。

    终点 = 该分支之后的第一个 `else ->`（when 的下一个分支）。切不出来返回 None。
    """
    i = src.find(marker)
    if i < 0:
        return None
    j = src.find("else ->", i)
    if j < 0:
        return None
    return src[i:j]


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

    body = extract_function(src, "saveToDocuments")
    qbody = extract_function(src, "queryDocByName")
    dbody = extract_function(src, "docRelativeDir")
    mbody = extract_function(src, "docMimeOf")
    if body is None or qbody is None or dbody is None or mbody is None:
        print(f"F 找不到 fun saveToDocuments / queryDocByName / docRelativeDir / docMimeOf "
              f"—— 文件结构变了，判据作废（{target}）")
        return 1
    # **新增**的代码（负向检查只在这块里做：老函数 exportToMusic 合法地用 MediaStore.Audio）
    newcode = "\n".join([body, qbody, dbody, mbody])

    print(f"目标文件：{target}")
    print(f"saveToDocuments 函数体：{len(body)} 字符，起于文件第 "
          f"{src[:src.find(body)].count(chr(10)) + 1} 行")
    print(f"queryDocByName 函数体：{len(qbody)} 字符，起于文件第 "
          f"{src[:src.find(qbody)].count(chr(10)) + 1} 行")
    print("-" * 72)

    # ---- 负向：旧缺陷形态（命中同名 ⇒ 直接 return 旧 uri）必须不存在 ----
    check_absent(
        body, "N1",
        r"queryDocByName[\s\S]{0,140}?\.let\s*\{\s*(?:return|it\s*\}\s*\})",
        "命中同名后 ?.let { return it } 直接交旧 uri",
    )
    check_absent(
        body, "N2",
        r"!=\s*null\s*\)\s*\{?\s*return\s+\w+",
        "已知同名存在就把旧 uri 交出去 = 原始缺陷本体",
    )
    check_absent(
        body, "N3",
        r"return[^\n]*queryDocByName\s*\((?![^\n]*sameContent)",
        "return ... queryDocByName(...) 且不比对内容",
    )
    # ---- 负向：写错集合 / 标错 MIME（只在**新增**的代码里判：exportToMusic 合法地用 Audio 表）----
    check_absent(
        newcode, "N4",
        r"MediaStore\.Audio",
        "⛔ 新增块里不许出现 MediaStore.Audio（那是音频表，备份 zip 会被当歌索引）",
    )
    check_absent(
        body, "N5",
        r"(?<![A-Za-z_])mimeOf\s*\(",
        "⛔ 不许复用音频 MIME 函数 mimeOf（未知后缀回 audio/mpeg）",
    )
    # N6：给 `files` 表写「本机未验证存在」的列 —— 写进去不被认就是 IllegalArgumentException。
    # （`title` 在 files 表里有没有，本机无法证明：android.jar 只有 stub、AOSP 源码取不到。
    #   将来谁真验证过它有，就把这条删掉并写清证据。）
    check_absent(
        body, "N6",
        r"MediaStore\.MediaColumns\.TITLE",
        "⛔ 不许给 files 表写未验证的 TITLE 列（zip 的显示名只由 DISPLAY_NAME 决定）",
    )

    # ---- 正向：跳过之前必须有「内容比对」这道闸 ----
    check_present(
        body, "P1",
        r"if\s*\(\s*\w+\s*!=\s*null\s*&&\s*!?\s*sameContent\s*\(",
        "同名分支的口子是 sameContent（不允许只凭「存在」就跳过）",
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

    # ---- 正向：原地覆写（rwt 截断）+ 真写字节 + 失败只删本次新建 ----
    check_present(
        body, "P3a", r"openOutputStream\s*\(\s*uri\s*,\s*mode\s*\)",
        "openOutputStream 带第二参数（模式）——默认 \"w\" 不截断，不能靠它",
    )
    check_present(
        body, "P3b", r"=\s*(?:if\s*\([^)]*\)\s*)?\"rwt\"",
        "覆写模式取 \"rwt\"（t = 截断；只写不截断会把变短的新备份尾部留成旧数据）",
    )
    check_present(
        body, "P4", r"\.copyTo\s*\(\s*out\s*\)",
        "真的把源文件字节写进输出流",
    )
    check_present(
        body, "P5", r"if\s*\(\s*existing\s*==\s*null\s*\)\s*runCatching\s*\{\s*\w+\.delete\s*\(",
        "失败只删本次新建的条目（不动别人的文件）",
    )

    # ---- 正向：目标目录 + 集合 + MIME ----
    check_present(
        dbody, "P6a", r"Environment\.DIRECTORY_DOCUMENTS",
        "RELATIVE_PATH 落在公共 Documents/ 下",
    )
    check_present(
        body, "P6b", r"\bdocRelativeDir\s*\(",
        "saveToDocuments 用的是那个 Documents 路径函数（不是就地拼字符串）",
    )
    check_present(
        body, "P6c",
        r"put\(MediaStore\.MediaColumns\.DISPLAY_NAME[\s\S]{0,300}?"
        r"put\(MediaStore\.MediaColumns\.MIME_TYPE[\s\S]{0,300}?"
        r"put\(MediaStore\.MediaColumns\.RELATIVE_PATH",
        "新建条目三列齐全：DISPLAY_NAME + MIME_TYPE + RELATIVE_PATH",
    )
    check_present(
        body, "P7a", r"MediaStore\.Files\.getContentUri\s*\(\s*MediaStore\.VOLUME_EXTERNAL_PRIMARY\s*\)",
        "Android 10+ 走 MediaStore.Files 的 external_primary 卷（非媒体文件表）",
    )
    check_present(
        body, "P7b", r"MediaStore\.Files\.getContentUri\s*\(\s*\"external\"\s*\)",
        "老机型分支也用 Files 表（⛔ MediaStore.Files 没有 EXTERNAL_CONTENT_URI 这个常量）",
    )
    dmime = extract_function(src, "docMimeOf")
    if dmime is None:
        fails.append("F P8a 找不到 fun docMimeOf —— 备份文件的 MIME 由谁推？")
    else:
        check_present(dmime, "P8a", r"\"zip\"\s*->\s*\"application/zip\"",
                      "zip 的 MIME 必须是 application/zip（⛔ 别写成音频）")
        check_present(dmime, "P8b", r"else\s*->\s*\"application/octet-stream\"",
                      "未知后缀一律 application/octet-stream（不猜）")
    check_present(
        qbody, "P9a", r"MediaStore\.Files\.getContentUri\s*\(\s*MediaStore\.VOLUME_EXTERNAL_PRIMARY\s*\)",
        "查询也走 Files 表（两张表查/写必须一致）",
    )
    check_present(
        qbody, "P9b", r"RELATIVE_PATH\s*\}=\?\s*AND[\s\S]{0,80}DISPLAY_NAME\s*\}=\?",
        "同名判定 = RELATIVE_PATH + DISPLAY_NAME 两条一起比",
    )

    # ---- 正向：源文件语义 + 通道回包 + 参数名契约 ----
    check_present(
        body, "P10", r"if\s*\(\s*!\s*src\.exists\s*\(\s*\)\s*\)\s*return\s+null",
        "源文件不存在 ⇒ 返回 null（与 exportToMusic 同语义）",
    )
    # 通道分支单独切出来判 —— ⛔ 别在整文件里判：export 那条分支有同样的写法，
    #    在整文件里判会让「新分支的老回包被删」照样绿（假绿）。
    branch = extract_branch(src, '"saveToDocuments" ->')
    if branch is None:
        fails.append("F P11a 找不到 \"saveToDocuments\" -> 这条 MethodChannel 分支")
    else:
        oks.append("OK P11a MethodChannel 上有 saveToDocuments 这条分支")
        check_present(
            branch, "P11b", r"\"status\"\s+to\s+\w+\.status",
            "回包带 status（Dart 侧才分得清「真写了」/「内容一致没重写」）",
        )
        check_present(
            branch, "P11c", r"argument<Boolean>\s*\(\s*\"report\"\s*\)",
            "新回包形状由 report=true 显式开启",
        )
        check_present(
            branch, "P11d", r"result\.success\s*\(\s*u\s*\)",
            "不带 report 时仍回纯 uri 字符串（⛔ 不许删这条向后兼容）",
        )
        check_present(
            branch, "P12",
            r"argument<String>\(\"src\"\)[\s\S]{0,200}?argument<String>\(\"name\"\)"
            r"[\s\S]{0,200}?argument<String>\(\"subdir\"\)",
            "参数名契约 src / name / subdir（Dart 侧照这个拼）",
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
