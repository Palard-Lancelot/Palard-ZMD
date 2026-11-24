extends CharacterBody2D
## 玩家控制器（阶段 0 任务 0.5 – 0.9）
##
## 结构：
##   移动系统（0.5）—— 三段式加速 / 土狼时间 / 跳跃缓冲 / 可变跳跃高度
##   状态机  （0.6）—— 帧驱动，驱动攻击/冲刺/受击与取消规则
##   攻击系统（0.7）—— 3 段连击，前摇 → 有效帧 → 后摇
##   打击反馈（0.8）—— 顿帧 / 屏震（通过 GameTime 单例）
##   防御系统（0.9）—— 冲刺（带无敌帧）/ 受击硬直 / 受击无敌闪烁
##
## ⚠️ 手感数值全部来自 FeelConfig，不得硬编码（DESIGN.md 第 12 节）

const StateMachineScript := preload("res://scripts/player/state_machine.gd")

## 玩家死亡时发出（阶段 0 任务 0.11 战斗闭环）。
## 由关卡接收，进入"死亡 → 结算 → 重开"流程。
signal died

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
const S_DASH := &"dash"
const S_HURT := &"hurt"
const S_DEAD := &"dead"

const ATTACK_STATES := [S_ATTACK1, S_ATTACK2, S_ATTACK3]

## ---- 攻击参数（后续应移入武器 Resource）----
const ATTACK_DAMAGE := [10, 10, 15]
const ATTACK_HITBOX_WIDTH := [17.0, 17.0, 20.0]
const ATTACK_HITBOX_OFFSET_X := [10.0, 10.0, 12.0]
const ATTACK_HITBOX_OFFSET_Y := [-13.0, -13.0, -12.0]
const ATTACK_EXTRA_RECOVERY := [0, 2, 5]

## ---- 冲刺参数 ----
## 总帧数含后摇；后摇长度来自 feel.dash_recovery_frames（可实时调参）
const DASH_TOTAL_FRAMES := 24

## ---- 单向平台下穿（DESIGN v1.3：S + Space）----
## 忽略该平台碰撞的帧数：0.25s 足够让脚底离开 10px 厚的台阶，
## 又短到不会在落地前就恢复碰撞。
const DROP_THROUGH_FRAMES := 15

var hp: int = 100
var max_hp: int = 100
var attack_damage: int = 10

var _sm: RefCounted = null
var _combo_index: int = 0
var _attack_hit_done: bool = false
var _combo_grace: int = 0

var _dash_cooldown_timer: float = 0.0
var _dash_dir: float = 1.0
var _iframe_frames_left: int = 0
var _blink_counter: int = 0

var _coyote_timer: float = 0.0
var _jump_buffer_timer: float = 0.0
var _land_timer: float = 0.0
var _is_rising: bool = false

## 下穿状态：当前被忽略的平台 + 剩余帧数
var _drop_body: Node = null
var _drop_frames_left: int = 0

var debug_state_name: String = "idle"
var debug_iframe: bool = false

@onready var _body_visual: Polygon2D = $BodyVisual
@onready var _hitbox: Area2D = $AttackHitbox
@onready var _hurtbox: Area2D = $Hurtbox
@onready var _camera: Camera2D = $Camera2D


func setup(config: Resource) -> void:
	feel = config
	add_to_group("feel_config_holder")
	add_to_group("player")
	_sm_try_init()


func _ready() -> void:
	_sm_try_init()
	add_to_group("player")
	if _hitbox:
		_hitbox.hit_landed.connect(_on_hit_landed)
	if _hurtbox:
		_hurtbox.area_entered.connect(_on_hurtbox_entered)
	_init_camera()


func _sm_try_init() -> void:
	if _sm != null or feel == null:
		return
	_sm = StateMachineScript.new()
	_sm.add_state(S_IDLE, 0, [S_RUN, S_JUMP, S_FALL, S_ATTACK1, S_DASH, S_HURT, S_DEAD])
	_sm.add_state(S_RUN, 0, [S_IDLE, S_JUMP, S_FALL, S_ATTACK1, S_DASH, S_HURT, S_DEAD])
	_sm.add_state(S_JUMP, 0, [S_FALL, S_ATTACK1, S_DASH, S_LAND, S_HURT, S_DEAD])
	_sm.add_state(S_FALL, 0, [S_IDLE, S_RUN, S_LAND, S_ATTACK1, S_DASH, S_HURT, S_DEAD])
	_sm.add_state(S_LAND, 2, [S_IDLE, S_RUN, S_JUMP, S_FALL, S_ATTACK1, S_DASH, S_HURT, S_DEAD])
	_sm.add_state(S_ATTACK1, 0, [])
	_sm.add_state(S_ATTACK2, 0, [])
	_sm.add_state(S_ATTACK3, 0, [])
	_sm.add_state(S_DASH, 0, [])
	_sm.add_state(S_HURT, 0, [])
	_sm.add_state(S_DEAD, 999999, [])
	_sm.set_state(S_IDLE)
	debug_state_name = str(_sm.get_state())


# ============================================================
# 主循环
# ============================================================

func _physics_process(delta: float) -> void:
	if feel == null or _sm == null:
		return

	# ---- 相机跟随：即使顿帧也保持更新，避免画面卡住 ----
	_update_camera(delta)

	# ---- 顿帧：实体逻辑整体冻结（动画/粒子/UI 不受影响）----
	if _game_time_is_frozen():
		velocity = Vector2.ZERO
		return

	if _dash_cooldown_timer > 0.0:
		_dash_cooldown_timer = maxf(0.0, _dash_cooldown_timer - delta)

	_update_timers(delta)
	_handle_drop_through_input()
	_handle_jump_input()
	_apply_gravity(delta)
	_update_dash()
	_update_hurt()
	_handle_horizontal(delta)
	_handle_attack_input()
	_handle_dash_input()
	_update_attack()
	_update_iframes()
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
		if not _is_busy():
			_sm.force_state(S_LAND)
	_land_timer = maxf(0.0, _land_timer - delta)

	if _combo_grace > 0:
		_combo_grace -= 1
		if _combo_grace == 0:
			_combo_index = 0


func _handle_jump_input() -> void:
	# 冲刺 / 受击 / 死亡期间不可起跳
	if _is_dashing() or _is_hurt() or _is_dead():
		return
	if _jump_buffer_timer > 0.0 and _coyote_timer > 0.0:
		velocity.y = -feel.jump_velocity
		_jump_buffer_timer = 0.0
		_coyote_timer = 0.0
		_is_rising = true


# ============================================================
# 单向平台下穿（DESIGN v1.3：S + Space）
# ============================================================
#
# 竖井台阶必须是 one_way_collision（从下方可穿过、从上方可站立），
# 否则玩家从下往上跳会撞头。代价是"上得去、下不来"——
# 玩家只能原路跳到边缘再落，回退体验从"走"退化成"绕"。下穿补上这个洞。
#
# 实现方式：给**这一个**平台加临时碰撞例外，N 帧后移除。
# 为什么不直接关掉 one_way_collision：
#   那是 StaticBody 上共享的形状，关掉会影响同一层所有玩家/敌人。

func _handle_drop_through_input() -> void:
	# 例外计时（顿帧期间本函数在更早处已 return，所以计时也跟着冻结，
	# 与状态机的帧驱动语义一致）
	if _drop_frames_left > 0:
		_drop_frames_left -= 1
		if _drop_frames_left == 0:
			_clear_drop_exception()

	if _is_dashing() or _is_hurt() or _is_dead():
		return
	if not is_on_floor():
		return
	# 必须是 S 按住 + 同一帧按下跳跃（v1.3 修订：原设计写 W，手感上"下"用 S 更直观）
	if not Input.is_action_pressed("move_down"):
		return
	if not Input.is_action_just_pressed("jump"):
		return

	var body: Node = _one_way_floor_body()
	if body == null:
		# 站在实心地/墙上：S+Space 不生效，让它照常走跳跃逻辑
		return

	add_collision_exception_with(body)
	_drop_body = body
	_drop_frames_left = DROP_THROUGH_FRAMES

	# 这次空格是"下穿"，不能同时起跳 —— 清掉跳跃缓冲与土狼计时
	_jump_buffer_timer = 0.0
	_coyote_timer = 0.0
	_land_timer = 0.0
	# 给一点初速，避免"原地站一帧才掉落"的顿感
	velocity.y = 40.0
	if _sm != null and _sm.is_state(S_LAND):
		_sm.force_state(S_FALL)
		debug_state_name = str(S_FALL)


## 找出脚下那个单向平台的 StaticBody；脚下是实心地/墙则返回 null
func _one_way_floor_body() -> Node:
	var count: int = get_slide_collision_count()
	if count == 0:
		# 静止帧里滑动碰撞可能为空，兜底用最后一次
		var last := get_last_slide_collision()
		if last != null:
			return _as_one_way(last.get_collider())
		return null

	for i in count:
		var c := get_slide_collision(i)
		if c == null:
			continue
		# 只认脚下的碰撞（法线朝上）
		if c.get_normal().y > -0.7:
			continue
		var body: Node = _as_one_way(c.get_collider())
		if body != null:
			return body
	return null


## 该碰撞体是否带「单向碰撞」形状
func _as_one_way(obj: Object) -> Node:
	var body := obj as Node
	if body == null:
		return null
	for ch in body.get_children():
		var cs := ch as CollisionShape2D
		if cs != null and cs.one_way_collision:
			return body
	return null


func _clear_drop_exception() -> void:
	if _drop_body != null and is_instance_valid(_drop_body):
		remove_collision_exception_with(_drop_body)
	_drop_body = null
	_drop_frames_left = 0


## 是否正在下穿（供测试断言）
func is_dropping_through() -> bool:
	return _drop_frames_left > 0


func _apply_gravity(delta: float) -> void:
	# 冲刺期间不受重力（纯水平位移）
	if _is_dashing():
		return
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

	# 冲刺 / 受击 / 死亡：由各自逻辑接管水平速度
	if _is_dashing() or _is_hurt() or _is_dead():
		return
	var locked := _is_in_attack() and not _can_cancel_attack()
	if locked:
		velocity.x = move_toward(velocity.x, 0.0, feel.ground_decel * 0.35 * delta)
		return

	var air_mult: float = feel.air_control if not is_on_floor() else 1.0

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
# 冲刺（任务 0.9）—— 位移 + 无敌帧
# ============================================================

func _handle_dash_input() -> void:
	if not Input.is_action_just_pressed("dash"):
		return
	if _is_dashing() or _is_dead() or _is_hurt():
		return
	if _dash_cooldown_timer > 0.0:
		return
	# 攻击中只允许在「可取消窗口」内用冲刺取消（DESIGN.md 第 6 节）
	if _is_in_attack() and not _can_cancel_attack():
		return
	_start_dash()


func _start_dash() -> void:
	var dir: float = Input.get_axis("move_left", "move_right")
	if is_zero_approx(dir):
		dir = _facing()
	_dash_dir = signf(dir) if not is_zero_approx(dir) else 1.0

	_sm.force_state(S_DASH)
	_dash_cooldown_timer = feel.dash_cooldown
	velocity = Vector2(_dash_dir * feel.dash_speed, 0.0)
	# 无敌从 iframe_start_frame 帧才开始（前几帧不是无敌 → 防贴脸乱滚）
	_iframe_frames_left = 0
	debug_state_name = str(S_DASH)
	if _hitbox.has_method("deactivate"):
		_hitbox.deactivate()


func _update_dash() -> void:
	if not _is_dashing():
		return
	var f: int = _sm.get_frame()

	# ---- 无敌窗口 ----
	if f == feel.iframe_start_frame:
		_iframe_frames_left = feel.iframe_end_frame - feel.iframe_start_frame
	elif f > feel.iframe_end_frame:
		_iframe_frames_left = 0

	# ---- 位移：无敌段满速，后摇段衰减 ----
	if f < DASH_TOTAL_FRAMES - feel.dash_recovery_frames:
		velocity.x = _dash_dir * feel.dash_speed
	else:
		velocity.x = move_toward(velocity.x, 0.0, feel.dash_speed * 0.5)
	velocity.y = 0.0

	if f >= DASH_TOTAL_FRAMES:
		_iframe_frames_left = 0
		_sm.force_state(S_IDLE if is_on_floor() else S_FALL)
		debug_state_name = str(_sm.get_state())


func _is_dashing() -> bool:
	return _sm != null and _sm.is_state(S_DASH)


# ============================================================
# 受击（任务 0.9）
# ============================================================

func _on_hurtbox_entered(area: Area2D) -> void:
	if _is_dead() or _iframe_frames_left > 0:
		return
	var dmg: int = 10
	if area.get("contact_damage") != null:
		dmg = int(area.contact_damage)
	take_damage(dmg, area.global_position)


func take_damage(damage: int, from_position: Vector2) -> void:
	if _is_dead() or _iframe_frames_left > 0:
		return

	hp = maxi(0, hp - damage)

	var dir: float = signf(global_position.x - from_position.x)
	if is_zero_approx(dir):
		dir = -_facing()
	velocity = Vector2(dir * feel.hurt_knockback * 6.0, -60.0)

	_iframe_frames_left = feel.hurt_iframe_frames
	_blink_counter = 0

	var gt := _game_time()
	if gt:
		var is_kill: bool = hp == 0
		gt.request_hitstop(feel.hitstop_kill_frames if is_kill else feel.hitstop_hit_frames)
		# 玩家死亡是本作最重的单次事件 → 用「大招」档屏震（DESIGN 第 6 节 8px 档）
		gt.request_shake(feel.shake_heavy_amplitude if is_kill else feel.shake_hit_amplitude,
			feel.shake_duration_frames)

	if hp == 0:
		_sm.force_state(S_DEAD)
		velocity = Vector2(dir * feel.hurt_knockback * 4.0, -90.0)
		_body_visual.color = Color(0.5, 0.25, 0.3, 1.0)
		print("[PLAYER] ☠ 死亡")
		died.emit()
	else:
		_sm.force_state(S_HURT)
		print("[PLAYER] 受击 -%d HP → %d/%d" % [damage, hp, max_hp])

	debug_state_name = str(_sm.get_state())


func _update_hurt() -> void:
	if not _is_hurt():
		return
	velocity.x = move_toward(velocity.x, 0.0, feel.hurt_knockback * 8.0)
	if _sm.get_frame() >= feel.hurt_stun_frames:
		_sm.force_state(S_IDLE if is_on_floor() else S_FALL)
		debug_state_name = str(_sm.get_state())


func _is_hurt() -> bool:
	return _sm != null and _sm.is_state(S_HURT)


func _is_dead() -> bool:
	return _sm != null and _sm.is_state(S_DEAD)


# ============================================================
# 无敌帧与闪烁（任务 0.9）
# ============================================================

func _update_iframes() -> void:
	debug_iframe = _iframe_frames_left > 0
	if _iframe_frames_left <= 0:
		_body_visual.modulate.a = 1.0
		return

	_iframe_frames_left -= 1

	if _is_dashing():
		_body_visual.modulate.a = 0.55
	else:
		_blink_counter += 1
		if _blink_counter % feel.hurt_blink_interval_frames == 0:
			_body_visual.modulate.a = 0.3 if _body_visual.modulate.a > 0.5 else 1.0

	if _iframe_frames_left == 0:
		_body_visual.modulate.a = 1.0


# ============================================================
# 攻击（任务 0.7）
# ============================================================

func _handle_attack_input() -> void:
	if not Input.is_action_just_pressed("attack"):
		return
	if _is_dashing() or _is_hurt() or _is_dead():
		return

	if _is_in_attack():
		if _can_cancel_attack():
			_advance_combo()
		return

	# 攻击已结束：仍在连击输入窗口内 → 接出下一段
	# （DESIGN 第 6 节「连击输入窗口：缓冲式，不要求精确卡帧」；
	#   窗口过期由 _update_timers 递减 _combo_grace 归零时复位 _combo_index）
	if _combo_grace > 0:
		_advance_combo()
		return

	_start_attack(0)


func _is_in_attack() -> bool:
	return _sm != null and _sm.is_any(ATTACK_STATES)


## 动作锁：这些状态下不允许移动状态覆盖
func _is_busy() -> bool:
	return _is_in_attack() or _is_dashing() or _is_hurt() or _is_dead()


func _can_cancel_attack() -> bool:
	if not _is_in_attack():
		return false
	var total: int = attack_total_frames(_combo_index)
	var recovery_start: int = feel.attack_startup_frames + feel.attack_active_frames
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


func _update_attack() -> void:
	if not _is_in_attack():
		return

	var f: int = _sm.get_frame()
	var startup: int = feel.attack_startup_frames
	var active_end: int = startup + feel.attack_active_frames
	var total: int = attack_total_frames(_combo_index)

	if f >= startup and f < active_end:
		if not _attack_hit_done and f == startup:
			_place_hitbox(_combo_index)
			_hitbox.activate(ATTACK_HITBOX_WIDTH[_combo_index])
	elif f == active_end:
		_hitbox.deactivate()
	elif f >= total:
		_hitbox.deactivate()
		if _combo_index < feel.attack_combo_max - 1:
			_combo_grace = feel.attack_combo_window_frames
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
	if _is_busy():
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

	if not is_zero_approx(velocity.x) and not _is_dead():
		_body_visual.scale.x = signf(velocity.x)


# ============================================================
# 命中反馈（任务 0.8）
# ============================================================

func _on_hit_landed(_target: Node2D, _damage: int, _knockback: float, is_kill: bool) -> void:
	_attack_hit_done = true
	var gt := _game_time()
	if gt == null:
		return
	if is_kill:
		gt.request_hitstop(feel.hitstop_kill_frames)


# ============================================================
# 相机：死区跟随（任务 0.1 修复 / 手感需求）
# ============================================================
#
# 需求：「主控可以短暂脱离中心，但相机要迅速跟上」
# 实现：死区（deadzone）跟随
#   - 玩家在死区矩形内移动 → 相机完全不动 → 允许短暂脱离中心
#   - 玩家超出死区 → 相机以指数衰减速度迅速追上
#
# 为什么不用 Camera2D 内置的 position_smoothing：
#   那是纯粹的位置平滑，玩家一动相机就跟着动（只是有延迟），
#   无法表达"允许脱离中心一段距离"这个需求，也没有死区概念。

## 相机注视点当前所在的世界坐标
var _cam_anchor: Vector2 = Vector2.ZERO
var _cam_initialized: bool = false


func _init_camera() -> void:
	if _camera == null:
		push_warning("Player 缺少 Camera2D 节点 —— 相机不会跟随")
		return
	# 相机是 top_level：不继承玩家变换，位置完全由代码控制
	_camera.top_level = true
	_camera.global_position = _cam_target_now()
	_cam_anchor = _camera.global_position
	_cam_initialized = true


## 当前理想注视点（玩家脚下 + 配置偏移）
func _cam_target_now() -> Vector2:
	var off_y: float = feel.cam_look_offset_y if feel else -46.0
	return Vector2(global_position.x, global_position.y + off_y)


func _update_camera(delta: float) -> void:
	if _camera == null or feel == null:
		return
	if not _cam_initialized:
		_cam_anchor = _camera.global_position
		_cam_initialized = true

	var target: Vector2 = _cam_target_now()
	var dz_x: float = feel.cam_deadzone_x
	var dz_y: float = feel.cam_deadzone_y

	# ---- 死区内不动，超出部分才作为跟随目标 ----
	var desired: Vector2 = _cam_anchor
	if target.x > _cam_anchor.x + dz_x:
		desired.x = target.x - dz_x
	elif target.x < _cam_anchor.x - dz_x:
		desired.x = target.x + dz_x
	if target.y > _cam_anchor.y + dz_y:
		desired.y = target.y - dz_y
	elif target.y < _cam_anchor.y - dz_y:
		desired.y = target.y + dz_y

	# ---- 指数衰减跟随：与帧率无关，超出越多追得越快 ----
	var speed: float = feel.cam_follow_speed
	if not is_on_floor():
		speed *= feel.cam_air_mult
	var t: float = 1.0 - exp(-speed * delta)
	_cam_anchor = _cam_anchor.lerp(desired, t)

	_camera.global_position = _cam_anchor


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


func is_invincible() -> bool:
	return _iframe_frames_left > 0


func respawn() -> void:
	hp = max_hp
	velocity = Vector2.ZERO
	_combo_index = 0
	_combo_grace = 0
	_dash_cooldown_timer = 0.0
	_iframe_frames_left = 0
	_blink_counter = 0
	_clear_drop_exception()
	_body_visual.modulate.a = 1.0
	_body_visual.color = Color(0.35, 0.85, 1, 1)
	if _hitbox and _hitbox.has_method("deactivate"):
		_hitbox.deactivate()
	if _sm:
		_sm.force_state(S_IDLE)
		debug_state_name = str(S_IDLE)
