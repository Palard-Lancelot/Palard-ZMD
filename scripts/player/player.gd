extends CharacterBody2D
## 玩家移动（阶段 0 任务 0.5）
##
## 职责范围：只做「走 / 跳 / 落」。攻击、受击、冲刺在后续任务（0.7–0.9）加入。
##
## 设计依据（DESIGN.md 第 6 节「手感规格」）：
##   - 三段式水平加速：起步 / 减速 / 转身 各用不同加速度
##     → 转身比起步更快，这是 Dead Cells 的招牌"干脆感"
##   - 土狼时间（Coyote Time）：离开平台后短暂仍可起跳
##   - 跳跃缓冲（Jump Buffer）：落地前按跳会被记住
##   - 可变跳跃高度：松开跳跃键立刻衰减上升速度
##
## ⚠️ 所有手感数值都从 FeelConfig 读取，不得硬编码（DESIGN.md 第 12 节约束）

## 由 boot.gd 注入
var feel: Resource = null

## 状态枚举（完整状态机在 0.6，这里先用最小集合）
enum State { IDLE, RUN, JUMP, FALL, LAND }

var state: State = State.IDLE

## 计时器（秒）
var _coyote_timer: float = 0.0
var _jump_buffer_timer: float = 0.0
## 落地后短暂显示 LAND 状态
var _land_timer: float = 0.0

## 是否处于跳跃的"上升期"（用于可变跳跃高度）
var _is_rising: bool = false

@onready var _body_visual: Polygon2D = $BodyVisual

## 便于调试面板 / 日志读取
var debug_state_name: String = "IDLE"


func setup(config: Resource) -> void:
	feel = config


func _physics_process(delta: float) -> void:
	if feel == null:
		return

	_update_timers(delta)
	_handle_jump_input()
	_apply_gravity(delta)
	_apply_horizontal(delta)
	_update_state()

	move_and_slide()


# ============================================================
# 计时器：土狼时间 / 跳跃缓冲 / 落地
# ============================================================

func _update_timers(delta: float) -> void:
	var was_on_floor := is_on_floor()

	# --- 土狼时间 ---
	if was_on_floor:
		_coyote_timer = feel.coyote_time
	else:
		_coyote_timer = maxf(0.0, _coyote_timer - delta)

	# --- 跳跃缓冲 ---
	if Input.is_action_just_pressed("jump"):
		_jump_buffer_timer = feel.jump_buffer_time
	else:
		_jump_buffer_timer = maxf(0.0, _jump_buffer_timer - delta)

	# --- 起跳瞬间：松开跳跃键 → 截断上升速度（可变跳跃高度）---
	if _is_rising and not Input.is_action_pressed("jump"):
		velocity.y = maxf(velocity.y, -feel.jump_velocity * feel.jump_cut_mult)
		_is_rising = false

	# --- 上升 / 下落 切换 ---
	if velocity.y < 0.0:
		_is_rising = true
	elif velocity.y >= 0.0:
		_is_rising = false

	# --- 落地检测（用于 LAND 状态与计时重置）---
	if not was_on_floor and is_on_floor():
		_land_timer = 0.10
		_coyote_timer = feel.coyote_time
	_land_timer = maxf(0.0, _land_timer - delta)


# ============================================================
# 跳跃：缓冲 + 土狼时间
# ============================================================

func _handle_jump_input() -> void:
	# 缓冲窗口内有输入 且 土狼窗口内（或在地面）→ 起跳
	if _jump_buffer_timer > 0.0 and _coyote_timer > 0.0:
		velocity.y = -feel.jump_velocity
		_jump_buffer_timer = 0.0
		_coyote_timer = 0.0
		_is_rising = true


# ============================================================
# 重力：上升 / 下落 用不同倍率
# ============================================================

func _apply_gravity(delta: float) -> void:
	# ⚠️ 显式标注 float：feel 声明为 Resource，其属性参与运算后无法类型推断
	var g: float = feel.gravity
	if velocity.y < 0.0:
		g *= feel.rise_gravity_mult
	else:
		g *= feel.fall_gravity_mult

	velocity.y += g * delta
	velocity.y = minf(velocity.y, feel.max_fall_speed)


# ============================================================
# 水平移动：三段式加速（起步 / 减速 / 转身）
# ============================================================

func _apply_horizontal(delta: float) -> void:
	var dir := Input.get_axis("move_left", "move_right")
	var air_mult: float = feel.air_control if not is_on_floor() else 1.0

	if is_zero_approx(dir):
		# --- 无输入：减速 ---
		velocity.x = move_toward(velocity.x, 0.0, feel.ground_decel * air_mult * delta)
	else:
		var target: float = dir * feel.max_run_speed
		var accel: float
		if not is_zero_approx(velocity.x) and signf(velocity.x) != signf(dir):
			# --- 反向输入：转身（比起步更快）---
			accel = feel.turn_accel
		else:
			# --- 同向或静止：起步 ---
			accel = feel.ground_accel
		velocity.x = move_toward(velocity.x, target, accel * air_mult * delta)


# ============================================================
# 状态判定（完整状态机在任务 0.6 实现）
# ============================================================

func _update_state() -> void:
	var prev := state
	if _land_timer > 0.0 and is_on_floor():
		state = State.LAND
	elif not is_on_floor():
		state = State.JUMP if velocity.y < 0.0 else State.FALL
	elif absf(velocity.x) > 1.0:
		state = State.RUN
	else:
		state = State.IDLE

	if state != prev:
		debug_state_name = State.keys()[state]
		if feel.show_state_debug:
			print("[PLAYER] 状态 %s → %s" % [State.keys()[prev], debug_state_name])

	# 朝向：让视觉方块朝移动方向翻转（视觉提示，后续用真实动画替代）
	if not is_zero_approx(velocity.x):
		_body_visual.scale.x = signf(velocity.x)
