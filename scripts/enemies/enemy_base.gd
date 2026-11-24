extends CharacterBody2D
## 敌人基类（阶段 0 任务 0.10）
##
## 提供一个可复用的敌人骨架：
##   · 帧驱动状态机（与玩家共用 state_machine.gd）
##   · 重力与地面移动（自带，不依赖玩家的 FeelConfig 移动参数）
##   · 玩家感知（距离判定，不需要寻路 —— 灰盒阶段足够）
##   · 攻击循环：冷却 → **前摇（可变黄预警）** → 有效帧 → 后摇
##   · 受击：闪白 / 击退 / 顿帧 / 死亡
##
## ⚠️ 支柱2 硬要求（DESIGN.md 第 1 节）：
##   任何能造成伤害的攻击都必须有**清晰前摇**。
##   本基类把前摇做成必经阶段，子类无法绕过。
##
## 子类用法：继承本脚本，调整 @export 参数即可
##   （见 rusher.gd —— 冲锋兵）

signal died

# ============================================================
# 可配置参数（子类用 @export 覆盖）
# ============================================================

@export_group("属性")
@export var max_hp: int = 30
@export var contact_damage: int = 10

@export_group("移动")
## 基础追击速度（px/s）。
## ⚠️ 必须显著高于玩家的 max_run_speed * 0.6，否则玩家一走就永远追不上，
##    表现为"敌人不追我"。玩家速度 165，所以追击速度至少 90 起。
@export var move_speed: float = 95.0
## 突进爆发速度：进入 lunge_range 后提速，制造"扑上来"的压迫感
@export var lunge_speed: float = 135.0
## 触发突进的距离
@export var lunge_range: float = 95.0
@export var gravity: float = 682.7
@export var max_fall_speed: float = 700.0

@export_group("感知与攻击")
## 发现玩家的水平距离
@export var detect_range: float = 140.0
## 进入攻击的距离
@export var attack_range: float = 28.0
## 攻击冷却（帧）
@export var attack_cooldown: int = 60
## 前摇（帧）—— 这是给玩家的反应时间，不得小于 10
@export var windup_frames: int = 20
## 有效帧（帧）
@export var active_frames: int = 6
## 后摇（帧）
@export var recovery_frames: int = 18
## 前摇期间是否继续移动（冲锋兵会，形成"扑上来"的压迫感）
@export var move_during_windup: bool = true
## 前摇期间的移动速度倍率
@export var windup_speed_mult: float = 0.5

@export_group("受击")
@export var hurt_stun_frames: int = 10
@export var knockback_force: float = 130.0

# ============================================================
# 状态
# ============================================================

const StateMachineScript := preload("res://scripts/player/state_machine.gd")

const S_IDLE := &"idle"
const S_CHASE := &"chase"
const S_WINDUP := &"windup"
const S_ATTACK := &"attack"
const S_RECOVER := &"recover"
const S_HURT := &"hurt"
const S_DEAD := &"dead"

const BASE_COLOR := Color(0.95, 0.45, 0.35, 1.0)
const TELEGRAPH_COLOR := Color(1.0, 0.85, 0.25, 1.0)
const ACTIVE_COLOR := Color(1.0, 0.25, 0.15, 1.0)
const FLASH_COLOR := Color(1.0, 1.0, 1.0, 1.0)
const DEAD_COLOR := Color(0.25, 0.2, 0.22, 1.0)

var hp: int = 30
var is_dead: bool = false
var facing: float = -1.0
var debug_state: String = "idle"

var _sm: RefCounted = null
var _flash_frames: int = 0
var _attack_timer: int = 0
var _player: Node2D = null

## 攻击可视化（阶段 0 可读性修复）
## 这两块色块解决两个体感问题：
##   1. 「出伤速度与画面不同步」—— 原来出伤时只有身体变色，没有挥砍动作
##   2. 「攻击范围得靠自己猜」—— 原来判定盒完全不可见
## 不需要美术资源，纯色块即可。
var _telegraph_poly: Polygon2D     ## 前摇：覆盖真实判定范围的半透明提示
var _slash_poly: Polygon2D         ## 出伤：明显的一记挥砍

@onready var _body: Polygon2D = $Body
@onready var _eye: Polygon2D = $Eye
@onready var _hp_bar: ColorRect = $HpBarBg/HpBar
@onready var _hp_bar_bg: ColorRect = $HpBarBg
@onready var _attack_box: Area2D = $EnemyAttackBox
@onready var _hurtbox: Area2D = $Hurtbox


func _ready() -> void:
	hp = max_hp
	# 前摇绝不允许太短 —— 违反支柱2 的"禁止无效死亡"
	windup_frames = maxi(windup_frames, 10)
	add_to_group("enemy")
	_sm = StateMachineScript.new()
	_sm.add_state(S_IDLE, 0, [S_CHASE, S_HURT, S_DEAD])
	_sm.add_state(S_CHASE, 0, [S_IDLE, S_WINDUP, S_HURT, S_DEAD])
	_sm.add_state(S_WINDUP, 0, [])
	_sm.add_state(S_ATTACK, 0, [])
	_sm.add_state(S_RECOVER, 0, [])
	_sm.add_state(S_HURT, 0, [])
	_sm.add_state(S_DEAD, 999999, [])
	_sm.set_state(S_IDLE)
	debug_state = str(_sm.get_state())
	_attack_timer = attack_cooldown
	_update_hp_bar()
	if _attack_box:
		_attack_box.deactivate()
	_build_attack_visuals()
	_apply_facing()


# ============================================================
# 攻击可视化（可读性）
# ============================================================

## 用两个 Polygon2D 覆盖真实判定范围 —— 范围直接取自 CollisionShape2D，
## 所以以后改攻击盒尺寸，提示会自动跟着变，不会出现"提示和实际不符"。
func _build_attack_visuals() -> void:
	_telegraph_poly = Polygon2D.new()
	_telegraph_poly.name = "TelegraphVisual"
	_telegraph_poly.color = Color(1.0, 0.7, 0.1, 0.22)
	_telegraph_poly.visible = false
	_telegraph_poly.z_index = -1
	add_child(_telegraph_poly)

	_slash_poly = Polygon2D.new()
	_slash_poly.name = "SlashVisual"
	_slash_poly.color = Color(1.0, 0.35, 0.15, 0.75)
	_slash_poly.visible = false
	add_child(_slash_poly)

	_sync_attack_visuals()


## 让可视化矩形与攻击盒的真实范围保持一致
func _sync_attack_visuals() -> void:
	if _attack_box == null:
		return
	var sh := _attack_box.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if sh == null or not (sh.shape is RectangleShape2D):
		return
	var size: Vector2 = (sh.shape as RectangleShape2D).size
	var center: Vector2 = _attack_box.position + sh.position
	var half := size * 0.5
	var pts := PackedVector2Array([
		center + Vector2(-half.x, -half.y),
		center + Vector2( half.x, -half.y),
		center + Vector2( half.x,  half.y),
		center + Vector2(-half.x,  half.y),
	])
	_telegraph_poly.polygon = pts
	_slash_poly.polygon = pts


func _physics_process(delta: float) -> void:
	if _sm == null:
		return

	# 顿帧：与玩家一致，实体逻辑整体冻结
	if _is_frozen():
		velocity = Vector2.ZERO
		return

	if _flash_frames > 0:
		_flash_frames -= 1
		if _flash_frames == 0:
			_restore_color()

	_apply_gravity(delta)
	_tick_ai()
	move_and_slide()
	_sm.tick()


# ============================================================
# 物理
# ============================================================

func _apply_gravity(delta: float) -> void:
	velocity.y += gravity * delta
	velocity.y = minf(velocity.y, max_fall_speed)


# ============================================================
# AI 主循环
# ============================================================

func _tick_ai() -> void:
	if is_dead:
		velocity.x = move_toward(velocity.x, 0.0, 400.0 * get_physics_process_delta_time())
		return

	match _sm.get_state():
		S_IDLE:
			velocity.x = 0.0
			if _player_in_range(detect_range):
				_enter(S_CHASE)

		S_CHASE:
			if not _player_in_range(detect_range * 1.6):
				_enter(S_IDLE)
				return
			_face_target()
			if _player_in_range(attack_range) and _attack_timer <= 0:
				_enter(S_WINDUP)
				return
			# 两档速度：远距离基础追击，进入突进范围后提速
			var spd: float = move_speed
			if _player_in_range(lunge_range):
				spd = lunge_speed
			velocity.x = facing * spd

		S_WINDUP:
			_face_target()
			# 前摇期间继续逼近 —— 给玩家"它正在扑过来"的压迫感
			if move_during_windup:
				var w_spd: float = move_speed
				if _player_in_range(lunge_range):
					w_spd = lunge_speed
				velocity.x = facing * w_spd * windup_speed_mult
			else:
				velocity.x = move_toward(velocity.x, 0.0, 600.0 * get_physics_process_delta_time())
			_pulse_telegraph()
			if _sm.get_frame() >= windup_frames:
				_enter(S_ATTACK)

		S_ATTACK:
			velocity.x = 0.0
			if _sm.get_frame() >= active_frames:
				if _attack_box:
					_attack_box.deactivate()
				_enter(S_RECOVER)

		S_RECOVER:
			velocity.x = move_toward(velocity.x, 0.0, 500.0 * get_physics_process_delta_time())
			if _sm.get_frame() >= recovery_frames:
				_attack_timer = attack_cooldown
				_enter(S_CHASE)

		S_HURT:
			velocity.x = move_toward(velocity.x, 0.0, 900.0 * get_physics_process_delta_time())
			if _sm.get_frame() >= hurt_stun_frames:
				_enter(S_CHASE)

		S_DEAD:
			pass

	# 攻击冷却递减
	if _attack_timer > 0:
		_attack_timer -= 1


## 进入状态：处理每个状态的「入场动作」
func _enter(next: StringName) -> void:
	if not _sm.set_state(next) and not _sm.is_state(next):
		# 转换被最小帧数挡住时用 force（AI 状态机不需要严格转换表）
		_sm.force_state(next)

	match next:
		S_WINDUP:
			# 前摇：身体变黄 + **显示攻击范围提示**
			_body.color = TELEGRAPH_COLOR
			_eye.color = Color(0.5, 0.15, 0.05, 1.0)
			_show_telegraph(true)
		S_ATTACK:
			# 出伤：身体变红 + 隐藏范围提示 + **显示挥砍**
			_body.color = ACTIVE_COLOR
			_show_telegraph(false)
			_show_slash(true)
			_spawn_hit_spark()
			if _attack_box:
				_attack_box.activate()
		S_RECOVER:
			_body.color = BASE_COLOR
			_eye.color = Color(0.1, 0.05, 0.05, 1.0)
			_show_slash(false)
		S_HURT:
			_show_telegraph(false)
			_show_slash(false)
		S_DEAD:
			_show_telegraph(false)
			_show_slash(false)
			_die()

	debug_state = str(next)


## 前摇进度可视化：越接近出手越亮、越不透明 —— 
## 玩家可以靠"变亮的进度"预判出手时机，而不是猜
func _pulse_telegraph() -> void:
	if _telegraph_poly == null or not _telegraph_poly.visible:
		return
	var total: int = maxi(windup_frames, 1)
	var t: float = clampf(float(_sm.get_frame()) / float(total), 0.0, 1.0)
	# 透明度 0.12 → 0.45，同时略微放大
	_telegraph_poly.color.a = 0.22 + 0.33 * t
	var s: float = 1.0 + 0.06 * t
	_telegraph_poly.scale = Vector2(s, s)


func _show_telegraph(v: bool) -> void:
	if _telegraph_poly:
		_telegraph_poly.visible = v
		if v:
			_telegraph_poly.color.a = 0.22
			_telegraph_poly.scale = Vector2.ONE


func _show_slash(v: bool) -> void:
	if _slash_poly:
		_slash_poly.visible = v
		if v:
			_slash_poly.color.a = 0.75
			_slash_poly.scale = Vector2.ONE
			# 挥砍的短促动画：迅速放大并淡出
			var tw := create_tween()
			tw.set_parallel(true)
			tw.tween_property(_slash_poly, "scale", Vector2(1.15, 1.3), 0.10)
			tw.tween_property(_slash_poly, "color:a", 0.0, 0.12)


## 出伤瞬间的命中火花 —— 在攻击范围中心炸开一个短暂的亮色方块。
## 这是"打中了 / 被打中了"的即时确认。
func _spawn_hit_spark() -> void:
	if _attack_box == null:
		return
	var sh := _attack_box.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if sh == null:
		return
	var center: Vector2 = _attack_box.position + sh.position

	var spark := Polygon2D.new()
	spark.color = Color(1.0, 0.95, 0.7, 0.9)
	var s := 6.0
	spark.polygon = PackedVector2Array([
		Vector2(-s, -s), Vector2(s, -s), Vector2(s, s), Vector2(-s, s)
	])
	spark.position = center
	add_child(spark)

	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(spark, "scale", Vector2(3.0, 3.0), 0.10)
	tw.tween_property(spark, "color:a", 0.0, 0.12)
	tw.chain().tween_callback(spark.queue_free)


# ============================================================
# 感知
# ============================================================

func _get_player() -> Node2D:
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
	return _player


func _player_in_range(r: float) -> bool:
	var p := _get_player()
	if p == null:
		return false
	var d := p.global_position - global_position
	return absf(d.x) <= r and absf(d.y) <= 90.0


func _face_target() -> void:
	var p := _get_player()
	if p == null:
		return
	var dx: float = p.global_position.x - global_position.x
	if absf(dx) > 1.0:
		facing = signf(dx)
		_apply_facing()


func _apply_facing() -> void:
	if _body:
		_body.scale.x = absf(_body.scale.x) * facing
	if _eye:
		_eye.scale.x = facing
	if _attack_box:
		var sh := _attack_box.get_node_or_null("CollisionShape2D") as CollisionShape2D
		if sh:
			sh.position.x = absf(sh.position.x) * facing
	# 攻击可视化必须跟着攻击盒一起翻转，否则提示与实际判定不符
	_sync_attack_visuals()


# ============================================================
# 受击
# ============================================================

func take_hit(damage: int, from_position: Vector2) -> void:
	if is_dead:
		return

	hp = maxi(0, hp - damage)
	var feel := _feel()
	_flash_frames = int(feel.hit_flash_frames) if feel != null else 3
	_body.color = FLASH_COLOR
	_update_hp_bar()
	_apply_hitstop()

	var dir: float = signf(global_position.x - from_position.x)
	if is_zero_approx(dir):
		dir = -facing

	if hp == 0:
		velocity = Vector2(dir * knockback_force * 1.5, -110.0)
		_enter(S_DEAD)
	else:
		velocity = Vector2(dir * knockback_force, -40.0)
		_enter(S_HURT)

	print("[%s] 受击 -%d HP → %d/%d%s" % [
		name, damage, hp, max_hp, "  ☠ 死亡" if hp == 0 else ""])


func _apply_hitstop() -> void:
	var gt := get_node_or_null("/root/GameTime")
	if gt == null:
		return
	var is_kill: bool = hp == 0
	var feel := _feel()
	if feel == null:
		gt.request_hitstop(10 if is_kill else 5)
		gt.request_shake(4.0 if is_kill else 2.0, 5)
		return
	gt.request_hitstop(feel.hitstop_kill_frames if is_kill else feel.hitstop_hit_frames)
	gt.request_shake(
		feel.shake_kill_amplitude if is_kill else feel.shake_hit_amplitude,
		feel.shake_duration_frames)


func _die() -> void:
	is_dead = true
	velocity.x = 0.0
	_body.color = DEAD_COLOR
	_hp_bar_bg.visible = false
	if _attack_box:
		# ⚠️ 死亡可能发生在物理 Flush 期间（玩家攻击盒的 area_entered 回调链里），
		#    那时直接 deactivate（改 monitoring）会报
		#    "Can't change this state while flushing queries" —— 延迟到帧末关闭。
		#    正常路径（S_ATTACK 超时 / revive）仍走 _set_active 的直接赋值。
		_attack_box.call_deferred("deactivate")
	remove_from_group("enemy")
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_body, "scale", Vector2(1.4, 0.25), 0.14)
	tw.tween_property(_body, "modulate:a", 0.3, 0.3)
	died.emit()


func revive() -> void:
	is_dead = false
	add_to_group("enemy")
	hp = max_hp
	_flash_frames = 0
	_attack_timer = attack_cooldown
	_body.scale = Vector2(absf(_body.scale.x), 1.0)
	_body.modulate.a = 1.0
	_body.color = BASE_COLOR
	_eye.color = Color(0.1, 0.05, 0.05, 1.0)
	_hp_bar_bg.visible = true
	if _attack_box:
		_attack_box.deactivate()
	_sm.force_state(S_IDLE)
	debug_state = str(S_IDLE)
	_update_hp_bar()


# ============================================================
# 辅助
# ============================================================

func _update_hp_bar() -> void:
	var ratio: float = float(hp) / float(maxi(1, max_hp))
	_hp_bar.size.x = _hp_bar_bg.size.x * ratio
	if ratio > 0.5:
		_hp_bar.color = Color(0.35, 0.9, 0.4)
	elif ratio > 0.25:
		_hp_bar.color = Color(0.95, 0.8, 0.3)
	else:
		_hp_bar.color = Color(0.9, 0.3, 0.3)


func _restore_color() -> void:
	if is_dead:
		_body.color = DEAD_COLOR
		return
	match _sm.get_state():
		S_WINDUP:
			_body.color = TELEGRAPH_COLOR
		S_ATTACK:
			_body.color = ACTIVE_COLOR
		_:
			_body.color = BASE_COLOR
			_eye.color = Color(0.1, 0.05, 0.05, 1.0)


func _is_frozen() -> bool:
	var gt := get_node_or_null("/root/GameTime")
	return gt != null and gt.is_frozen()


func _feel() -> Resource:
	var nodes := get_tree().get_nodes_in_group("feel_config_holder")
	if nodes.is_empty():
		return null
	return nodes[0].get("feel")


## 是否正在前摇（供测试断言 / 调试面板使用）
func is_telegraphing() -> bool:
	return _sm != null and _sm.is_state(S_WINDUP)
