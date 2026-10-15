/// 音效增强页：低音增强（BassBoost）+ 响度增强（LoudnessEnhancer）+ 音量淡入淡出
/// + 交叉淡变（曲末双播放器重叠 + 队列预取）。
///
/// 前两项和均衡器一样挂在**正在播放的音频会话**上（所以要先放一首歌），
/// 后两项是纯 Dart 的播放行为（音量包络 / 双播放器换场），跟音频会话无关，任何时候都能改。
/// 都放在同一页：都是「改听感」的开关，用户不必记住入口分散在哪。
///
/// 拖动只改本页临时状态，松手才提交给原生 —— 避免拖动过程中每帧过 MethodChannel
/// （与 EQ 页同一套做法）。原生侧见 `android/.../ExtraEffectsEngine.kt`，
/// 数据层见 `lib/extra_effects.dart`。
library;

import 'package:flutter/material.dart';

import '../app_config.dart';
import '../extra_effects.dart';
import '../widgets/ambient_layer.dart';
import '../widgets/glass_panel.dart';
import '../widgets/wallpaper_layer.dart';

class SoundEffectsPage extends StatefulWidget {
  const SoundEffectsPage({super.key});

  @override
  State<SoundEffectsPage> createState() => _SoundEffectsPageState();
}

class _SoundEffectsPageState extends State<SoundEffectsPage> {
  /// 拖动中的临时值（null = 用引擎里的真实值）
  double? _dragBass;
  double? _dragLoud;

  @override
  void initState() {
    super.initState();
    // 进来补一次刷新：可能刚播放过，音频会话已经就绪
    ExtraFxEngine.instance.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          const Positioned.fill(child: WallpaperLayer()),
          const Positioned.fill(child: AmbientLayer(isPreview: true)),
          SafeArea(
            child: ValueListenableBuilder<ExtraFxState>(
              valueListenable: ExtraFxEngine.instance.state,
              builder: (context, s, _) => Column(
                children: [
                  _header(primary),
                  Expanded(child: _body(s, primary)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 顶栏：返回 + 标题
  Widget _header(Color primary) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 14, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            tooltip: '返回',
            onPressed: () => Navigator.pop(context),
          ),
          const Expanded(
            child: Text(
              '音效增强',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(ExtraFxState s, Color primary) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
      children: [
        if (s.available) ...[
          _bassCard(s, primary),
          const SizedBox(height: 14),
          _loudCard(s, primary),
        ] else
          _notAttached(s),
        const SizedBox(height: 18),
        // 音量淡入淡出不依赖原生音频会话，所以始终可用、始终显示
        _fadeCard(primary),
        const SizedBox(height: 14),
        // 交叉淡变 + 队列预取同样不依赖音频会话，任何时候都能改（开关见 app_config）
        _crossfadeCard(primary),
      ],
    );
  }

  /// 低音增强：强度 0~1000（Android 约定值，UI 显示成百分比）
  Widget _bassCard(ExtraFxState s, Color primary) {
    final supported = s.bassSupported;
    final on = supported && s.bassEnabled;
    final value = (_dragBass ?? s.bassStrength.toDouble()).clamp(0.0, 1000.0);
    return _card(
      icon: Icons.speaker,
      title: '低音增强',
      desc: supported
          ? '加厚低频，鼓点和贝斯更结实；强度越高越「轰」，太高会糊'
          : '这台设备没有提供低音增强接口（各家 ROM 支持度不同）',
      trailing: Switch(
        value: on,
        activeThumbColor: primary,
        onChanged: supported
            ? (v) => ExtraFxEngine.instance.setBassEnabled(v)
            : null,
      ),
      child: _sliderRow(
        value: value,
        max: 1000,
        divisions: 20,
        label: '${(value / 10).round()}%',
        enabled: on,
        primary: primary,
        onChanged: (v) => setState(() => _dragBass = v),
        onCommit: (v) {
          setState(() => _dragBass = null);
          ExtraFxEngine.instance.setBassStrength(v.round());
        },
      ),
    );
  }

  /// 响度增强：增益 0~+12 dB（内部单位毫贝，100 mB = 1 dB）
  ///
  /// ⚠️ **文案与开关可点性**要分清两件事（`lib/attach_retry.dart` 的三态）：
  /// * 真挂上了 / **压根没试过** ⇒ 文案与开关可点性**逐字等于改动前**（观感零变化）；
  /// * ★ **试过但没挂上**（真机实测：`ERROR_NO_INIT(-3)`，`LoudnessEnhancer` 挂到新建会话上
  ///   会间歇性失败）⇒ **绝不许说成「这台设备没有提供响度增强接口」**，而且开关**必须可点**
  ///   —— 点一下就会走一次真实重挂（原生 `setLoudness` → `open(playerId)`）。
  ///   改前这两种情况长得一模一样：开关禁用 + 谎报没有接口 ⇒ 用户既被误导又没法自救。
  ///
  /// 开关**显示为开**仍然只认「真挂上了」（拨到 on 而 native 挂不上，显示成 on 就是骗人）。
  Widget _loudCard(ExtraFxState s, Color primary) {
    final supported = s.loudSupported;
    final on = s.loudSwitchChecked;
    final max = s.loudMaxGain.toDouble().clamp(100.0, 2000.0);
    final value = (_dragLoud ?? s.loudGain.toDouble()).clamp(0.0, max);
    return _card(
      icon: Icons.volume_up,
      title: '响度增强',
      desc: s.loudCardOverride ??
          (supported
              ? '把整体响度往上提，小音量下细节更清楚（近似「夜间模式」的反面）'
              : '这台设备没有提供响度增强接口'),
      trailing: Switch(
        // 测试锚点，字面量与 test/attach_retry_test.dart 的那个一致
        key: const ValueKey<String>('switch_loud'),
        value: on,
        activeThumbColor: primary,
        onChanged: s.loudSwitchOn
            ? (v) => ExtraFxEngine.instance.setLoudnessEnabled(v)
            : null,
      ),
      child: _sliderRow(
        value: value,
        max: max,
        divisions: (max / 50).round().clamp(1, 60),
        label: '+${(value / 100).toStringAsFixed(1)} dB',
        enabled: on,
        primary: primary,
        onChanged: (v) => setState(() => _dragLoud = v),
        onCommit: (v) {
          setState(() => _dragLoud = null);
          ExtraFxEngine.instance.setLoudnessGain(v.round());
        },
      ),
    );
  }

  /// 音量淡入淡出：切歌/起播渐入、暂停渐出（纯 Dart，见 player_service 的 _fade）
  Widget _fadeCard(Color primary) {
    return ListenableBuilder(
      listenable: AppConfig.instance,
      builder: (context, _) {
        final on = AppConfig.instance.volumeFadeEnabled;
        return _card(
          icon: Icons.waves,
          title: '音量淡入淡出',
          desc: on
              ? '切歌和起播时音量渐入、暂停时渐出，消掉那一下的「啪」声'
              : '关掉后切歌、暂停都是瞬间到位（原来的行为）',
          trailing: Switch(
            value: on,
            activeThumbColor: primary,
            onChanged: (v) => AppConfig.instance.setVolumeFadeEnabled(v),
          ),
        );
      },
    );
  }

  /// 交叉淡变（曲末双播放器重叠 ~300ms）+ 队列预取（提前解码下一首）。
  ///
  /// ⚠️ 它**不只是听感修饰**：队列预取**只有这个开关开着才有**（`player_service.dart`
  /// 的 `_tickDual()` 第一行就按它早退）⇒ 文案必须把「重叠」和「预取」一起说清，
  /// 别只写「交叉淡变」四个字（用户看不出它会改观感、也看不出预取跟着它走）。
  ///
  /// 写的是 `AppConfig.setCrossfadeEnabled`（**即时生效、不用重启**：`_tickDual()` 是每拍
  /// 现读 `AppConfig.instance.crossfadeEnabled`），初值也读同一个字段，**不自己读 prefs**。
  Widget _crossfadeCard(Color primary) {
    return ListenableBuilder(
      listenable: AppConfig.instance,
      builder: (context, _) {
        final on = AppConfig.instance.crossfadeEnabled;
        return _card(
          icon: Icons.compare_arrows,
          title: '交叉淡变',
          desc: on
              ? '一首放完自动接下一首时，两首重叠约 300ms 交叉淡过去；下一首会提前解码'
                  '（队列预取），切过去更顺。代价是同时开两个解码器，更费电'
              : '关掉后曲末是硬切、下一首到点才解码（原来的行为）—— 重叠淡变和队列预取'
                  '都没有；打开它不用重启 App',
          trailing: Switch(
            // 测试锚点，字面量与 test/sound_effects_page_test.dart 的那个一致
            key: const ValueKey<String>('switch_crossfade'),
            value: on,
            activeThumbColor: primary,
            onChanged: (v) => AppConfig.instance.setCrossfadeEnabled(v),
          ),
        );
      },
    );
  }

  /// 还没播过歌（或设备不给接口）：说清原因并给个重试
  Widget _notAttached(ExtraFxState s) {
    final noSession = s.sessionId < 0;
    return GlassPanel(
      borderRadius: BorderRadius.circular(16),
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Icon(
            noSession ? Icons.music_note : Icons.info_outline,
            color: Colors.white38,
            size: 40,
          ),
          const SizedBox(height: 14),
          Text(
            noSession ? '音效要挂在正在播放的音频会话上' : '这台设备没给出音效接口',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            noSession
                ? '先在歌单里放一首歌，再回到这一页。\n调好的设置会存下来，之后每次播放自动套用。'
                : '低音增强和响度增强都不可用，\n可以试试下面的「音量淡入淡出」。',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 12,
              height: 1.7,
            ),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重新检测'),
            onPressed: () => ExtraFxEngine.instance.refresh(),
          ),
        ],
      ),
    );
  }

  /// 一行：图标 + 标题 + 右侧开关，下面跟说明，再下面挂可选控件
  Widget _card({
    required IconData icon,
    required String title,
    required String desc,
    required Widget trailing,
    Widget? child,
  }) {
    return GlassPanel(
      borderRadius: BorderRadius.circular(16),
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, color: Colors.white70, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              trailing,
            ],
          ),
          const SizedBox(height: 2),
          Text(
            desc,
            style: const TextStyle(
              fontSize: 11,
              color: Colors.white54,
              height: 1.5,
            ),
          ),
          if (child != null) ...[const SizedBox(height: 6), child],
        ],
      ),
    );
  }

  /// 滑杆行：读数在左上、滑杆在下面（滑杆本体不带数值气泡，避免和边框装饰打架）
  Widget _sliderRow({
    required double value,
    required double max,
    required int divisions,
    required String label,
    required bool enabled,
    required Color primary,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onCommit,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            enabled ? label : '—',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: enabled ? primary : Colors.white38,
            ),
          ),
        ),
        Slider(
          value: value,
          max: max,
          divisions: divisions,
          activeColor: primary,
          inactiveColor: Colors.white24,
          onChanged: enabled ? onChanged : null,
          onChangeEnd: enabled ? onCommit : null,
        ),
      ],
    );
  }
}
