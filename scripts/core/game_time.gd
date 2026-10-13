extends Node
## 全局时间/反馈管理（阶段 0 任务 0.8）
##
## 职责：
##   1. 顿帧（Hit Stop）—— 手感第一功臣
##   2. 屏幕震动
##
## ⚠️ 用法约束：顿帧期间，实体逻辑脚本应「跳过 _physics_process」，
##    但**不要**动 Engine.time_scale —— 那会连 UI、音效、粒子一起拖慢。
##
## 为什么顿帧能出效果：
##    命中瞬间冻结 5 帧（约 83ms），让玩家的手「感觉到阻力」，
##    这是从"切纸"变成"砍骨头"的关键。

## 顿帧剩余帧数
var _hitstop_frames: int = 0

## 屏幕震动状态
var _shake_frames: int = 0
var _shake_amplitude: float = 0.0
var _shake_origin: Vector2 = Vector2.ZERO

var camera: Camera2D = null

## 累计统计（调试面板可显示）
var total_hitstops: int = 0
var total_shakes: int = 0


func register_camera(cam: Camera2D) -> void:
	camera = cam
	if camera:
		_shake_origin = camera.offset


# ============================================================
# 顿帧
# ============================================================

## 请求顿帧。frames 为帧数（60fps 下 5 帧 ≈ 83ms）
## 多次请求取最大值，不会被短顿帧覆盖长顿帧
func request_hitstop(frames: int) -> void:
	if frames <= 0:
		return
	_hitstop_frames = maxi(_hitstop_frames, frames)
	total_hitstops += 1


## 本帧是否处于顿帧中。实体脚本应在 _physics_process 开头检查：
##     if GameTime.is_frozen(): return
func is_frozen() -> bool:
	return _hitstop_frames > 0


## 每物理帧调用一次（由 boot.gd 驱动）
func tick() -> void:
	if _hitstop_frames > 0:
		_hitstop_frames -= 1
	_tick_shake()


func reset() -> void:
	_hitstop_frames = 0
	_shake_frames = 0
	_restore_camera()


# ============================================================
# 屏幕震动
# ============================================================

## 请求屏震。amplitude 为像素幅度
func request_shake(amplitude: float, frames: int) -> void:
	if amplitude <= 0.0 or frames <= 0:
		return
	_shake_amplitude = maxf(_shake_amplitude, amplitude)
	_shake_frames = maxi(_shake_frames, frames)
	total_shakes += 1


func _tick_shake() -> void:
	if camera == null:
		return
	if _shake_frames <= 0:
		_restore_camera()
		return

	_shake_frames -= 1
	# 线性衰减：越接近结束幅度越小，收尾自然
	var t: float = float(_shake_frames) / 10.0
	t = minf(t, 1.0)
	var amp: float = _shake_amplitude * t
	camera.offset = _shake_origin + Vector2(
		randf_range(-amp, amp),
		randf_range(-amp, amp)
	)

	if _shake_frames <= 0:
		_shake_amplitude = 0.0
		_restore_camera()


func _restore_camera() -> void:
	if camera:
		camera.offset = _shake_origin
