extends CharacterBody2D
## 玩家控制器（阶段 0 任务 0.5 / 0.6 / 0.7 / 0.8）
##
## 结构：
##   移动系统（0.5）—— 三段式加速 / 土狼时间 / 跳跃缓冲 / 可变跳跃高度
##   状态机  （0.6）—— 帧驱动，驱动攻击与取消规则
##   攻击系统（0.7）—— 3 段连击，前摇 → 有效帧 → 后摇
##   打击反馈（0.8）—— 顿帧 / 屏震（通过 GameTime 单例）
##
## ⚠️ 手感数值全部来自 FeelConfig，不得硬编码（DESIGN.md 第 12 节）

const StateMachineScript := preload("res://scripts/player/state_machine.gd")

## 由 test_level.gd 注入
var feel: Resource = null

## ---- 状态定义 ----
const S_IDLE := &"idle"
const S_RUN := &"run"
const S_JUMP := &"jump"
const S_FALL := &"fall"
const S_LAND := &"land"
const S_ATTACK1 := &"attack1"
const S_ATTACK2 := &"attack2"
const S_ATTACK3 := &"attack3"
const S_DEAD := &"dead"

## ---- 攻击参数（后续应移入武器 Resource）----
const ATTACK_DAMAGE := [10, 10, 15]
const ATTACK_HITBOX_WIDTH := [17.0, 17.0, 20.0]
const ATTACK_HITBOX_OFFSET_X := [10.0, 10.0, 12.0]
const ATTACK_HITBOX_OFFSET_Y := [-13.0, -13.0, -12.0]
const ATTACK_EXTRA_RECOVERY := [0, 2, 5]   ## 第 2、3 段后摇更长
const COMBO_GRACE := 4                     ## 后摇结束后仍可接续的宽限帧

var hp: int = 100
var max_hp: int = 100
var attack_damage: int = 10      ## 命中盒读取

var _sm: RefCounted = null
var _combo_index: int = 0        ## 当前连击段（0-based）
var _attack_hit_done: bool = false
var _combo_grace: int = 0        ## 连击追加大于 0 表示仍可接下一段

var _coyote_timer: float = 0.0
var _jump_buffer_timer: float = 0.0
var _land_timer: float = 0.0
var _is_rising: bool = false

var debug_state_name: String = "idle"

@onready var _body_visual: Polygon2D = $BodyVisual
@onready var _hitbox: Area2D = $AttackHitbox


func setup(config: Resource) -> void:
	feel = config
	add_to_group("feel_config_holder")
	_sm_try_init()


func _ready() -> void:
	_sm_try_init()
	if _hitbox:
		_hitbox.hit_landed.connect(_on_hit_landed)


func _sm_try_init() -> void:
	if _sm != null or feel == null:
		return
	_sm = StateMachineScript.new()
	# ---- 注册状态：名称, 最小帧数, 可转入的状态 ----
	_sm.add_state(S_IDLE, 0, [S_RUN, S_JUMP, S_FALL, S_ATTACK1, S_DEAD])
	_sm.add_state(S_RUN, 0, [S_IDLE, S_JUMP, S_FALL, S_ATTACK1, S_DEAD])
	_sm.add_state(S_JUMP, 0, [S_FALL, S_ATTACK1, S_LAND, S_DEAD])
	_sm.add_state(S_FALL, 0, [S_IDLE, S_RUN, S_LAND, S_ATTACK1, S_DEAD])
	_sm.add_state(S_LAND, 2, [S_IDLE, S_RUN, S_JUMP, S_FALL, S_ATTACK1, S_DEAD])
	_sm.add_state(S_ATTACK1, 0, [])
	_sm.add_state(S_ATTACK2, 0, [])
	_sm.add_state(S_ATTACK3, 0, [])
	_sm.add_state(S_DEAD, 999999, [])
	_sm.set_state(S_IDLE)
	debug_state_name = str(_sm.get_state())


# ============================================================
# 主循环
# ============================================================

func _physics_process(delta: float) -> void:
	if feel == null or _sm == null:
		return

	# ---- 顿帧：实体逻辑整体冻结（动画/粒子/UI 不受影响）----
	if _game_time_is_frozen():
		velocity = Vector2.ZERO
		return

	_update_timers(delta)
	_handle_jump_input()
	_apply_gravity(delta)
	_handle_horizontal(delta)
	_handle_attack_input()
	_update_attack()
	_update_state()

	move_and_slide()

	_sm.tick()


# ============================================================
# 计时器 / 重力 / 水平移动（任务 0.5）
# ============================================================

func _update_timers(delta: float) -> void:
	var was_on_floor: bool = is_on_floor()

	if was_on_floor:
		_coyote_timer = feel.coyote_time
	else:
		_coyote_timer = maxf(0.0, _coyote_timer - delta)

	if Input.is_action_just_pressed("jump"):
		_jump_buffer_timer = feel.jump_buffer_time
	else:
		_jump_buffer_timer = maxf(0.0, _jump_buffer_timer - delta)

	# 可变跳跃高度：上升中松开跳跃键 → 截断
	if _is_rising and not Input.is_action_pressed("jump"):
		velocity.y = maxf(velocity.y, -feel.jump_velocity * feel.jump_cut_mult)
		_is_rising = false

	if velocity.y < 0.0:
		_is_rising = true
	else:
		_is_rising = false

	if not was_on_floor and is_on_floor():
		_land_timer = 0.10
		_coyote_timer = feel.coyote_time
		if not _sm.is_any([S_ATTACK1, S_ATTACK2, S_ATTACK3]):
			_sm.force_state(S_LAND)
	_land_timer = maxf(0.0, _land_timer - delta)

	if _combo_grace > 0:
		_combo_grace -= 1
		if _combo_grace == 0:
			_combo_index = 0


func _handle_jump_input() -> void:
	if _jump_buffer_timer > 0.0 and _coyote_timer > 0.0:
		velocity.y = -feel.jump_velocity
		_jump_buffer_timer = 0.0
		_coyote_timer = 0.0
		_is_rising = true


func _apply_gravity(delta: float) -> void:
	# ⚠️ 显式 float：feel 是 Resource，其属性运算结果无法类型推断
	var g: float = feel.gravity
	if velocity.y < 0.0:
		g *= feel.rise_gravity_mult
	else:
		g *= feel.fall_gravity_mult
	velocity.y += g * delta
	velocity.y = minf(velocity.y, feel.max_fall_speed)


func _handle_horizontal(delta: float) -> void:
	var dir: float = Input.get_axis("move_left", "move_right")

	# 后摇锁定：攻击期间禁止转向/加减速
	var locked := _is_in_attack() and not _can_cancel_attack()

	var air_mult: float = feel.air_control if not is_on_floor() else 1.0

	if locked:
		# 后摇阶段保持惯性轻微减速（不能主动加速）
		velocity.x = move_toward(velocity.x, 0.0, feel.ground_decel * 0.35 * delta)
		return

	if is_zero_approx(dir):
		velocity.x = move_toward(velocity.x, 0.0, feel.ground_decel * air_mult * delta)
	else:
		var target: float = dir * feel.max_run_speed
		var accel: float
		if not is_zero_approx(velocity.x) and signf(velocity.x) != signf(dir):
			accel = feel.turn_accel
		else:
			accel = feel.ground_accel
		velocity.x = move_toward(velocity.x, target, accel * air_mult * delta)


# ============================================================
# 攻击（任务 0.7）
# ============================================================

func _handle_attack_input() -> void:
	if not Input.is_action_just_pressed("attack"):
		return

	# 已在攻击中：只有在「允许取消的窗口」内才接受连击输入
	if _is_in_attack():
		if _can_cancel_attack():
			_advance_combo()
		return

	# 触发第一段（从地面或空中都可）
	_start_attack(0)


func _is_in_attack() -> bool:
	return _sm.is_any([S_ATTACK1, S_ATTACK2, S_ATTACK3])


## 后摇阶段且已过「不可取消」的硬直帧 → 允许取消
## 对应 DESIGN.md 第 6 节的取消规则表
func _can_cancel_attack() -> bool:
	if not _is_in_attack():
		return false
	var total := attack_total_frames(_combo_index)
	var recovery_start: int = feel.attack_startup_frames + feel.attack_active_frames
	# 后摇刚开始的一小段不可取消，之后才能被冲刺/跳跃/下一段取消
	var unlock_frame: int = recovery_start + maxi(2, feel.attack_recovery_frames / 3)
	return _sm.get_frame() >= unlock_frame and _sm.get_frame() < total


func attack_total_frames(idx: int) -> int:
	return (feel.attack_startup_frames
		+ feel.attack_active_frames
		+ feel.attack_recovery_frames
		+ ATTACK_EXTRA_RECOVERY[idx])


func _start_attack(idx: int) -> void:
	_combo_index = clampi(idx, 0, feel.attack_combo_max - 1)
	_attack_hit_done = false
	_combo_grace = 0
	_sm.force_state(_attack_state(_combo_index))
	attack_damage = ATTACK_DAMAGE[_combo_index]
	if _hitbox.has_method("deactivate"):
		_hitbox.deactivate()
	debug_state_name = str(_sm.get_state())


func _attack_state(idx: int) -> StringName:
	match idx:
		1: return S_ATTACK2
		2: return S_ATTACK3
	return S_ATTACK1


func _advance_combo() -> void:
	var next_idx: int = _combo_index + 1
	if next_idx >= feel.attack_combo_max:
		next_idx = 0
	_start_attack(next_idx)


## 按帧推进攻击：前摇 → 有效帧（开判定）→ 后摇 → 回位
func _update_attack() -> void:
	if not _is_in_attack():
		return

	var f: int = _sm.get_frame()
	var startup: int = feel.attack_startup_frames
	var active_end: int = startup + feel.attack_active_frames
	var total: int = attack_total_frames(_combo_index)

	# 有效帧：只在这一窗口内开启判定
	if f >= startup and f < active_end:
		if not _attack_hit_done and f == startup:
			_place_hitbox(_combo_index)
			_hitbox.activate(ATTACK_HITBOX_WIDTH[_combo_index])
	elif f == active_end:
		_hitbox.deactivate()
	elif f >= total:
		_hitbox.deactivate()
		# 后摇播完：留下连击宽限，然后回位
		if _combo_index < feel.attack_combo_max - 1:
			_combo_grace = COMBO_GRACE
		else:
			_combo_index = 0
		_sm.force_state(S_IDLE if is_on_floor() else S_FALL)
		debug_state_name = str(_sm.get_state())


func _place_hitbox(idx: int) -> void:
	if _hitbox == null:
		return
	_hitbox.position = Vector2(
		ATTACK_HITBOX_OFFSET_X[idx] * _facing(),
		ATTACK_HITBOX_OFFSET_Y[idx]
	)


func _facing() -> float:
	return _body_visual.scale.x if not is_zero_approx(_body_visual.scale.x) else 1.0


# ============================================================
# 状态同步（任务 0.6）
# ============================================================

func _update_state() -> void:
	# 攻击状态由 _update_attack 独占管理，不被移动逻辑覆盖
	if _is_in_attack():
		return

	var prev: StringName = _sm.get_state()
	var next: StringName = prev

	if _land_timer > 0.0 and is_on_floor():
		next = S_LAND
	elif not is_on_floor():
		next = S_JUMP if velocity.y < 0.0 else S_FALL
	elif absf(velocity.x) > 1.0:
		next = S_RUN
	else:
		next = S_IDLE

	if next != prev:
		_sm.force_state(next)
		debug_state_name = str(next)

	# 朝向
	if not is_zero_approx(velocity.x):
		_body_visual.scale.x = signf(velocity.x)


# ============================================================
# 命中反馈（任务 0.8）
# ============================================================

func _on_hit_landed(_target: Node2D, _damage: int, _knockback: float, is_kill: bool) -> void:
	_attack_hit_done = true
	var gt := _game_time()
	if gt == null:
		return
	# 顿帧与屏震主要由受击方触发（制造"打到东西"的阻力感），
	# 这里只在击杀时补一次更长的顿帧，强化收招份量。
	if is_kill:
		gt.request_hitstop(feel.hitstop_kill_frames)


# ============================================================
# 辅助
# ============================================================

func _game_time() -> Node:
	return get_node_or_null("/root/GameTime")


func _game_time_is_frozen() -> bool:
	var gt := _game_time()
	if gt == null:
		return false
	return gt.is_frozen()


func respawn() -> void:
	hp = max_hp
	velocity = Vector2.ZERO
	_combo_index = 0
	_combo_grace = 0
	if _hitbox and _hitbox.has_method("deactivate"):
		_hitbox.deactivate()
	if _sm:
		_sm.force_state(S_IDLE)
