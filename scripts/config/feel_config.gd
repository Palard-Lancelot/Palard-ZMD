## 手感配置（FeelConfig）
##
## 集中存放全部手感参数，供运行期实时调节。
## 数值来源：feel-spec-deadcells.md（按 Dead Cells 观感反推校准）
##
## ⚠️ 设计约束（DESIGN.md 第 12 节「已决定」）：
##    手感参数必须实时可调，不得硬编码在逻辑里。
##    任何脚本读取手感数值，都必须走本 Resource。
##
## 用法：
##     var feel: FeelConfig = preload("res://resources/feel_config.tres")
##     velocity.y += feel.get_gravity() * delta
class_name FeelConfig
extends Resource

# ============================================================
# 一、移动（地面 / 空中）
# ============================================================

@export_group("移动 · 水平")

## 最大水平速度（px/s）。165 ≈ 10 格/s
@export_range(20.0, 600.0, 1.0) var max_run_speed: float = 165.0

## 地面加速度（px/s²）。设为无限大会破坏"重量感" —— 务必保留加速过程
@export_range(50.0, 10000.0, 10.0) var ground_accel: float = 1650.0

## 地面减速度（松手时，px/s²）。略低于加速度 → 有轻微滑行
@export_range(50.0, 10000.0, 10.0) var ground_decel: float = 1150.0

## 转身加速度（px/s²）。比起步更快 → Dead Cells 的招牌干脆感
@export_range(50.0, 10000.0, 10.0) var turn_accel: float = 2200.0

## 空中操控系数（0–1）。0.75 = 空中加速为地面的 75%，但仍保留控制权
@export_range(0.0, 1.0, 0.05) var air_control: float = 0.75

@export_group("移动 · 垂直")

## 重力（px/s²）。682.7 反推自「跳跃 3 格(48px) / 滞空 0.75s」
@export_range(50.0, 5000.0, 1.0) var gravity: float = 682.7

## 上升期重力倍率。1.0 = 对称跳跃；< 1.0 手感更"飘"；> 1.0 更"脆"
@export_range(0.3, 3.0, 0.05) var rise_gravity_mult: float = 1.0

## 下落期重力倍率。> 1.0 = 下落更快，手感更利落
@export_range(0.3, 3.0, 0.05) var fall_gravity_mult: float = 1.0

## 最大下落速度（px/s）。防高速穿透地形
@export_range(50.0, 3000.0, 10.0) var max_fall_speed: float = 700.0

## 跳跃初速度（px/s）。
## ⚠️ 必须为 256.0 才能与 gravity=682.7 自洽：
##      h = v0²/(2g) = 256²/(2×682.7) = 48 px  ✓
##      t = 2v0/g    = 2×256/682.7    = 0.75 s ✓
##    （原 feel-spec 文档误写为 128，会得到 12px 高度 —— 已修正）
@export_range(10.0, 1200.0, 1.0) var jump_velocity: float = 256.0

## 土狼时间（秒）。离开平台后仍可起跳的宽限
@export_range(0.0, 0.5, 0.01) var coyote_time: float = 0.10

## 跳跃缓冲（秒）。落地前按跳会被记住
@export_range(0.0, 0.5, 0.01) var jump_buffer_time: float = 0.10

## 松开跳跃键时的速度衰减系数（可变跳跃高度）。1.0 = 不衰减
@export_range(0.0, 1.0, 0.05) var jump_cut_mult: float = 0.5

# ============================================================
# 二、战斗（攻击 / 受击 / 冲刺无敌）
# ============================================================

@export_group("战斗 · 攻击")

## 攻击前摇（帧）。4 帧 → 起手几乎无延迟
@export_range(0, 60, 1) var attack_startup_frames: int = 4

## 有效判定帧（帧）。窗口窄 → 鼓励精确站位
@export_range(0, 60, 1) var attack_active_frames: int = 3

## 攻击后摇（帧）。8 帧 = 每一下挥砍的真实代价
@export_range(0, 120, 1) var attack_recovery_frames: int = 8

## 连击输入窗口（帧）。缓冲式，不要求精确卡帧
@export_range(0, 60, 1) var attack_combo_window_frames: int = 6

## 最大连击段数
@export_range(1, 8, 1) var attack_combo_max: int = 3

@export_group("战斗 · 无敌帧")

## 冲刺无敌总时长（帧）。21 帧 ≈ 0.35s
@export_range(0, 120, 1) var iframe_total_frames: int = 21

## 无敌起始帧。前几帧不是无敌 → 防"贴脸乱滚"
@export_range(0, 120, 1) var iframe_start_frame: int = 3

## 无敌结束帧。最后一帧已恢复可被击中
@export_range(0, 120, 1) var iframe_end_frame: int = 20

## 冲刺后摇（帧）。无敌结束后的硬直 = 风险所在
@export_range(0, 120, 1) var dash_recovery_frames: int = 6

## 冲刺速度（px/s）
@export_range(50.0, 2000.0, 10.0) var dash_speed: float = 300.0

## 冲刺冷却（秒）
@export_range(0.0, 5.0, 0.05) var dash_cooldown: float = 0.4

@export_group("战斗 · 受击")

## 受击无敌帧（帧）。60 帧 = 1.0s，相当长
@export_range(0, 300, 1) var hurt_iframe_frames: int = 60

## 受击击退距离（px）。24 ≈ 1.5 格，以水平为主
@export_range(0.0, 500.0, 1.0) var hurt_knockback: float = 24.0

## 受击硬直（帧）。期间不可操作
@export_range(0, 120, 1) var hurt_stun_frames: int = 12

## 受击闪烁切换间隔（帧）
@export_range(1, 30, 1) var hurt_blink_interval_frames: int = 4

# ============================================================
# 三、打击感三件套（手感第一功臣）
# ============================================================

@export_group("打击感")

## 命中时的顿帧（帧）。5 帧 ≈ 0.083s
@export_range(0, 60, 1) var hitstop_hit_frames: int = 5

## 击杀时的顿帧（帧）。10 帧 = 命中的两倍
@export_range(0, 60, 1) var hitstop_kill_frames: int = 10

## 屏幕震动 · 命中幅度（px）
@export_range(0.0, 50.0, 0.5) var shake_hit_amplitude: float = 2.0

## 屏幕震动 · 击杀幅度（px）
@export_range(0.0, 50.0, 0.5) var shake_kill_amplitude: float = 4.0

## 屏幕震动 · 大招幅度（px）
@export_range(0.0, 50.0, 0.5) var shake_heavy_amplitude: float = 8.0

## 屏幕震动时长（帧）。必须比顿帧先结束
@export_range(0, 60, 1) var shake_duration_frames: int = 5

## 受击方闪白帧数
@export_range(0, 30, 1) var hit_flash_frames: int = 3

# ============================================================
# 四、调试
# ============================================================

@export_group("调试")

## 是否在控制台输出手感参数变更
@export var verbose_log: bool = false

## 是否显示玩家状态机当前状态
@export var show_state_debug: bool = true


# ============================================================
# 便捷换算函数（帧 ↔ 秒）
# ============================================================

const FRAMES_PER_SECOND: float = 60.0


## 帧 → 秒
func f2s(frames: int) -> float:
	return float(frames) / FRAMES_PER_SECOND


## 秒 → 帧
func s2f(seconds: float) -> int:
	return int(round(seconds * FRAMES_PER_SECOND))


## 土狼时间（秒）
func coyote_seconds() -> float:
	return coyote_time


## 跳跃缓冲（秒）
func jump_buffer_seconds() -> float:
	return jump_buffer_time


## 无敌生效的时长（秒）—— 从起始帧到结束帧
func iframe_active_seconds() -> float:
	return f2s(maxi(0, iframe_end_frame - iframe_start_frame))


## 理论跳跃高度（px），用于校验参数是否自洽
## h = v0² / (2g)
func jump_height_px() -> float:
	if gravity <= 0.0:
		return 0.0
	return (jump_velocity * jump_velocity) / (2.0 * gravity)


## 理论滞空时间（秒），用于校验参数是否自洽
## t = 2 * v0 / g
func jump_airtime_seconds() -> float:
	if gravity <= 0.0:
		return 0.0
	return (2.0 * jump_velocity) / gravity


## 当前参数是否自洽（跳跃高度 ≈ 48px、滞空 ≈ 0.75s）
## 返回 String 数组；空数组 = 全部通过
func validate() -> Array:
	var problems: Array = []
	var h := jump_height_px()
	var t := jump_airtime_seconds()
	if absf(h - 48.0) > 8.0:
		problems.append("跳跃高度 %.1f px 偏离基准 48px（3 格）" % h)
	if absf(t - 0.75) > 0.15:
		problems.append("滞空时间 %.2f s 偏离基准 0.75s" % t)
	if ground_accel > max_run_speed * 30.0:
		problems.append("加速度过高（%.0f）—— 会破坏重量感，建议 ≤ %.0f" % [ground_accel, max_run_speed * 30.0])
	if max_fall_speed < jump_velocity:
		problems.append("最大下落速度低于跳跃初速 —— 会出现上升比下落慢的怪手感")
	return problems
