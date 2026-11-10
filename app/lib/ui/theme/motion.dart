// Portions derived from PiPilot (https://github.com/CikeSeven/pi_pilot), MIT, Copyright (c) 2026 CikeSeven. See THIRD_PARTY_NOTICES.md.

import 'package:flutter/material.dart';

/// 动效 token。原则:**安静、短、跟手**。
///
/// - 反馈类(按压、图标切换)≤ 160ms,快到"感觉不到在等";
/// - 结构类(折叠、胶囊变形、抽屉)240–340ms,慢到"看得出从哪来";
/// - 环境类(安装进度的呼吸)2.4s 一个周期,慢到"不打扰"。
///
/// 系统开启"移除动画"时,用 [of] 取时长会得到 0;循环动画用 [reduced]
/// 判断后停在静止帧。
abstract final class AppMotion {
  /// 按压缩放、水波起始。
  static const press = Duration(milliseconds: 90);

  /// 淡入淡出、图标交叉切换、复制成功对勾。
  static const quick = Duration(milliseconds: 160);

  /// 小块展开收起、列表项进出。
  static const standard = Duration(milliseconds: 240);

  /// 思考块 / 工具行的折叠展开(大块高度变化,慢一拍才不"啪"一下)。
  static const collapse = Duration(milliseconds: 280);

  /// 胶囊变形(顶栏展开、模型选择)、抽屉落位。
  static const emphasized = Duration(milliseconds: 340);

  /// 底部弹层进 / 出(showModalBottomSheet 只认时长)。
  static const sheetIn = Duration(milliseconds: 380);
  static const sheetOut = Duration(milliseconds: 260);

  /// 页面级过场、安装步骤切换。
  static const slow = Duration(milliseconds: 480);

  /// 环境呼吸(安装进度光晕、连接中的状态点)。
  static const breath = Duration(milliseconds: 2400);

  /// 标准缓动(M3 standard,DSH Web 的 cubic-bezier(.4,0,.2,1) 同族)。
  static const std = Easing.standard;

  /// 进场:快出慢停。
  static const enter = Easing.emphasizedDecelerate;

  /// 退场:慢起快走。
  static const exit = Easing.emphasizedAccelerate;

  /// 折叠展开。
  static const collapseCurve = Curves.easeInOutCubic;

  /// 滑行:抽屉、胶囊位移这类"跟手后落位"的运动,iOS 式长尾减速。
  static const glide = Cubic(0.32, 0.72, 0.0, 1.0);

  /// 轻微欠阻尼的弹簧(阻尼比约 0.93):落位时几乎不回弹,只有一点"活"气。
  /// 用于抽屉 fling、底栏指示器。
  static const spring = SpringDescription(mass: 1, stiffness: 420, damping: 38);

  /// 页面级的步骤切换(引导各步、启动页 → 主页)。
  static const page = Duration(milliseconds: 300);

  /// 二级页推入 / 推出(iOS 式水平推入)。
  static const push = Duration(milliseconds: 300);

  /// 首次出现的列表逐项错开(≤ 30ms,只错开前 [staggerLimit] 项)。
  static const stagger = Duration(milliseconds: 30);
  static const staggerLimit = 8;

  /// 首次出现时上移的距离(逻辑像素)。
  static const rise = 8.0;

  /// 按压缩放:按下 [press] 缩到 [pressScale],松手 [release] 回到 1(不越过)。
  static const pressScale = 0.97;
  static const release = Duration(milliseconds: 200);

  /// 弹层升起:快出、长尾减速,像有一点阻尼;不回弹。
  static const sheetRise = Cubic(0.2, 0.9, 0.25, 1.0);

  /// 弹层收起(作为 reverseCurve 使用:反向播放时先慢后快)。
  static const sheetFall = Curves.easeOutCubic;

  /// 系统是否要求减少动画。
  static bool reduced(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// 按系统设置取时长:要求减少动画时返回 0。
  static Duration of(BuildContext context, Duration duration) => reduced(context) ? Duration.zero : duration;
}
