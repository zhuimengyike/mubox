/// 氛围层「暂停冻结」策略（U0）的断言 —— 纯函数真值表。
///
/// 正向：真背景 + 有歌 + 暂停 + 前台 + 有特效 ⇒ **停**（省电）；一恢复播放 ⇒ 立刻跑。
/// 负向一：特效预览（`isPreview`）在同样条件下**照样跑** —— 用户经常「暂停着调特效」，
///         预览冻死会被判成「特效坏了」。
/// 负向二：**没传身份参数的调用点必须与改动前逐帧一致** —— 穷举所有组合，
///         断言结果恒等于改动前那句 `screenOn && (heart || rain || edge)`。
///
/// 为什么不写 widget test：本仓 179 项测试里 `testWidgets` = 0，不为这一条开新类别；
/// 抽纯函数是唯一不增加新测试类别的路子（也是这次改动的主要目的之一）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/ambient_policy.dart';

/// 穷举 4 个布尔输入的 16 种组合，对每组调一次 [shouldAnimate]。
void _each4(void Function(bool screenOn, bool hasAnyEffect, bool playing, bool hasSong) f) {
  for (final screenOn in [true, false]) {
    for (final hasAnyEffect in [true, false]) {
      for (final playing in [true, false]) {
        for (final hasSong in [true, false]) {
          f(screenOn, hasAnyEffect, playing, hasSong);
        }
      }
    }
  }
}

void main() {
  test('负向：两个身份参数取缺省值时，逐个组合都等于改动前那句表达式', () {
    _each4((screenOn, hasAnyEffect, playing, hasSong) {
      expect(
        shouldAnimate(
          screenOn: screenOn,
          hasAnyEffect: hasAnyEffect,
          playing: playing,
          hasSong: hasSong,
          isPreview: false, // 缺省值
          freezeOnPause: false, // 缺省值
        ),
        screenOn && hasAnyEffect,
        reason: 'screenOn=$screenOn hasAnyEffect=$hasAnyEffect '
            'playing=$playing hasSong=$hasSong',
      );
    });
  });

  test('负向：特效预览永不冻结（哪怕开了冻结、有歌、正暂停）', () {
    _each4((screenOn, hasAnyEffect, playing, hasSong) {
      expect(
        shouldAnimate(
          screenOn: screenOn,
          hasAnyEffect: hasAnyEffect,
          playing: playing,
          hasSong: hasSong,
          isPreview: true,
          freezeOnPause: true, // 就算被误传成真背景，预览也不许冻
        ),
        screenOn && hasAnyEffect,
        reason: '预览结果必须只由「前台 + 有特效」决定',
      );
    });
  });

  test('正向：真背景暂停 ⇒ 停；再播放 ⇒ 立刻跑', () {
    bool anim(bool playing) => shouldAnimate(
          screenOn: true,
          hasAnyEffect: true,
          playing: playing,
          hasSong: true,
          isPreview: false,
          freezeOnPause: true,
        );
    expect(anim(true), isTrue, reason: '正在播放：跑');
    expect(anim(false), isFalse, reason: '暂停：冻结（U0）');
  });

  test('冷启动还没放过歌 ⇒ 保持旧观感照跑（只有「真的暂停了某首歌」才冻结）', () {
    expect(
      shouldAnimate(
        screenOn: true,
        hasAnyEffect: true,
        playing: false,
        hasSong: false,
        isPreview: false,
        freezeOnPause: true,
      ),
      isTrue,
    );
  });

  test('锁屏 / 退后台：无论开关怎么传都是停（旧行为不许被这次改动放松）', () {
    for (final isPreview in [true, false]) {
      for (final freezeOnPause in [true, false]) {
        for (final hasAnyEffect in [true, false]) {
          for (final playing in [true, false]) {
            for (final hasSong in [true, false]) {
              expect(
                shouldAnimate(
                  screenOn: false,
                  hasAnyEffect: hasAnyEffect,
                  playing: playing,
                  hasSong: hasSong,
                  isPreview: isPreview,
                  freezeOnPause: freezeOnPause,
                ),
                isFalse,
              );
            }
          }
        }
      }
    }
  });

  test('爱心/雨滴/边框全关：无论开关怎么传都是停（旧行为）', () {
    for (final isPreview in [true, false]) {
      for (final freezeOnPause in [true, false]) {
        for (final playing in [true, false]) {
          for (final hasSong in [true, false]) {
            expect(
              shouldAnimate(
                screenOn: true,
                hasAnyEffect: false,
                playing: playing,
                hasSong: hasSong,
                isPreview: isPreview,
                freezeOnPause: freezeOnPause,
              ),
              isFalse,
            );
          }
        }
      }
    }
  });
}
