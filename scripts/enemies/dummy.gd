extends StaticBody2D
## 训练假人（阶段 0 任务 0.7–0.10）
##
## 两种形态，由 `hostile` 开关切换：
##   hostile = false  纯靶子，不还手（默认，用于测攻击手感）
##   hostile = true   会周期性攻击，带清晰前摇（用于测受击 / 冲刺无敌帧）
##
## ⚠️ 支柱2 硬要求（DESIGN.md 第 1 节）：
##   任何能造成伤害的攻击都必须有**清晰前摇**（telegraph），
##   否则就是"无效死亡"，直接违反支柱2。
##
## 攻击节奏：
##   冷却 WINDUP_DELAY 帧 → 前摇 WINDUP 帧（变红放大，这是给玩家的预警）
##   → 有效帧 ACTIVE 帧（攻击盒开启）→ 后摇 RECOVERY 帧

signal died

@export var hostile: bool = false
@export var max_hp: int = 30

## 命中盒读取
var hp: int = 30

const BASE_COLOR := Color(0.95, 0.45, 0.35, 1.0)
const TELEGRAPH_COLOR := Color(1.0, 0.85, 0.25, 1.0)
const FLASH_COLOR := Color(1.0, 1.0, 1.0, 1.0)
const DEAD_COLOR := Color(0.25, 0.2, 0.22, 1.0)

## 攻击节奏（帧）
const ATTACK_COOLDOWN := 70
const WINDUP_FRAMES := 18      ## 前摇较长，给玩家充足反应时间
const ACTIVE_FRAMES := 6
const RECOVERY_FRAMES := 16

var _flash_frames: int = 0
var _is_dead: bool = false

## 攻击循环
var _attack_timer: int = 0
var _windup_left: int = 0
var _active_left: int = 0
var _recovery_left: int = 0

@onready var _body: Polygon2D = $Body
@onready var _eye_l: Polygon2D = $EyeL
@onready var _eye_r: Polygon2D = $EyeR
@onready var _hp_bar: ColorRect = $HpBarBg/HpBar
@onready var _hp_bar_bg: ColorRect = $HpBarBg
@onready var _attack_box: Area2D = $EnemyAttackBox

## 攻击朝向（1 = 朝右，-1 = 朝左）。起手前摇时根据玩家位置决定。
var _facing: float = 1.0
var _player: Node2D = null


func _ready() -> void:
	hp = max_hp
	add_to_group("dummy")
	_update_hp_bar()
	if not hostile and _attack_box:
		_attack_box.visible = false
	_attack_timer = ATTACK_COOLDOWN
	_player = get_tree().get_first_node_in_group("player")
	_build_attack_visuals()


# ============================================================
# 攻击可视化（可读性修复 —— 与 enemy_base.gd 同一套思路）
#
# 解决两个体感问题：
#   1. 出伤速度与画面不同步：原来只有身体变色，没有挥砍
#   2. 攻击范围靠猜：判定盒不可见
# ============================================================

var _telegraph_poly: Polygon2D
var _slash_poly: Polygon2D


func _build_attack_visuals() -> void:
	if _attack_box == null:
		return
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


## 让可视化矩形与攻击盒真实范围一致（范围取自 CollisionShape2D，改尺寸会自动跟随）
func _sync_attack_visuals() -> void:
	if _attack_box == null or _telegraph_poly == null:
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
			var tw := create_tween()
			tw.set_parallel(true)
			tw.tween_property(_slash_poly, "scale", Vector2(1.15, 1.3), 0.10)
			tw.tween_property(_slash_poly, "color:a", 0.0, 0.12)


## 出伤瞬间的命中火花
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


func _physics_process(_delta: float) -> void:
	if _flash_frames > 0:
		_flash_frames -= 1
		if _flash_frames == 0:
			_restore_color()

	if _is_dead or not hostile:
		return
	_tick_attack()


# ============================================================
# 攻击循环（hostile 形态）
# ============================================================

func _tick_attack() -> void:
	# --- 前摇：明显的视觉预警 + 攻击范围提示 ---
	if _windup_left > 0:
		_windup_left -= 1
		# 呼吸式放大，越接近出手越大
		var t: float = 1.0 - float(_windup_left) / float(WINDUP_FRAMES)
		_body.scale = Vector2(1.0 + 0.35 * t, 1.0 - 0.15 * t)
		# 范围提示随进度变亮，让玩家能预判出手时机
		if _telegraph_poly and _telegraph_poly.visible:
			_telegraph_poly.color.a = 0.22 + 0.33 * t
			_telegraph_poly.scale = Vector2(1.0 + 0.06 * t, 1.0 + 0.06 * t)
		if _windup_left == 0:
			_start_active()
		return

	# --- 有效帧 ---
	if _active_left > 0:
		_active_left -= 1
		if _active_left == 0:
			if _attack_box:
				_attack_box.deactivate()
			_show_slash(false)
			_recovery_left = RECOVERY_FRAMES
		return

	# --- 后摇 ---
	if _recovery_left > 0:
		_recovery_left -= 1
		if _recovery_left == 0:
			_body.scale = Vector2.ONE
			_restore_color()
			_attack_timer = ATTACK_COOLDOWN
		return

	# --- 冷却 ---
	if _attack_timer > 0:
		_attack_timer -= 1
		if _attack_timer == 0:
			_begin_windup()


func _begin_windup() -> void:
	_windup_left = WINDUP_FRAMES
	_face_player()
	_body.color = TELEGRAPH_COLOR
	if _eye_l:
		_eye_l.color = Color(0.5, 0.15, 0.05, 1)
	if _eye_r:
		_eye_r.color = Color(0.5, 0.15, 0.05, 1)
	# 前摇期间就把攻击盒移到正确方向，并显示攻击范围提示
	_apply_facing()
	_show_telegraph(true)


## 起手前摇时转向玩家。这是"攻击可被预判"的一部分 ——
## 玩家看到前摇变黄且方向确定，就知道该往哪边躲。
func _face_player() -> void:
	if _player == null:
		_player = get_tree().get_first_node_in_group("player")
	if _player == null:
		return
	var dx: float = _player.global_position.x - global_position.x
	if absf(dx) > 1.0:
		_facing = signf(dx)


## 把朝向应用到视觉与攻击盒
func _apply_facing() -> void:
	if _body:
		_body.scale.x = absf(_body.scale.x) * _facing
	if _eye_l:
		_eye_l.scale.x = _facing
	if _eye_r:
		_eye_r.scale.x = _facing
	if _attack_box:
		var shape_node := _attack_box.get_node_or_null("CollisionShape2D") as CollisionShape2D
		if shape_node:
			shape_node.position.x = 16.0 * _facing
	# 攻击可视化跟随翻转，保证提示与实际判定一致
	_sync_attack_visuals()


func _start_active() -> void:
	_active_left = ACTIVE_FRAMES
	_body.color = Color(1.0, 0.25, 0.15, 1.0)
	_show_telegraph(false)
	_show_slash(true)
	_spawn_hit_spark()
	if _attack_box and _attack_box.has_method("activate"):
		_attack_box.activate()


# ============================================================
# 受击
# ============================================================

func take_hit(damage: int, from_position: Vector2) -> void:
	if _is_dead:
		return

	hp = maxi(0, hp - damage)
	var feel := _feel()
	_flash_frames = int(feel.hit_flash_frames) if feel != null else 3
	_body.color = FLASH_COLOR
	_update_hp_bar()
	_apply_hitstop_and_shake()

	var dir: float = signf(global_position.x - from_position.x)
	if is_zero_approx(dir):
		dir = 1.0
	_knockback(dir, 5.0 if hp > 0 else 9.0)

	print("[DUMMY] 受击 -%d HP → %d/%d%s" % [damage, hp, max_hp, "  ☠ 死亡" if hp == 0 else ""])

	if hp == 0:
		_die()


func _apply_hitstop_and_shake() -> void:
	var gt := _game_time()
	var feel := _feel()
	if gt == null or feel == null:
		return
	var is_kill: bool = hp == 0
	gt.request_hitstop(feel.hitstop_kill_frames if is_kill else feel.hitstop_hit_frames)
	gt.request_shake(
		feel.shake_kill_amplitude if is_kill else feel.shake_hit_amplitude,
		feel.shake_duration_frames
	)


func _knockback(dir: float, strength: float) -> void:
	var start := position
	var target := position + Vector2(dir * 3.0, -1.0) * (strength * 0.6)
	var tw := create_tween()
	tw.tween_property(self, "position", target, 0.06)
	tw.tween_property(self, "position", start, 0.10)


func _update_hp_bar() -> void:
	var ratio: float = float(hp) / float(maxi(1, max_hp))
	_hp_bar.size.x = _hp_bar_bg.size.x * ratio
	_hp_bar.color = Color(0.35, 0.9, 0.4) if ratio > 0.5 else (Color(0.95, 0.8, 0.3) if ratio > 0.25 else Color(0.9, 0.3, 0.3))


func _restore_color() -> void:
	if _is_dead:
		_body.color = DEAD_COLOR
	elif _windup_left > 0:
		_body.color = TELEGRAPH_COLOR
	elif _active_left > 0:
		_body.color = Color(1.0, 0.25, 0.15, 1.0)
	else:
		_body.color = BASE_COLOR
		if _eye_l:
			_eye_l.color = Color(0.1, 0.05, 0.05, 1)
		if _eye_r:
			_eye_r.color = Color(0.1, 0.05, 0.05, 1)


func _die() -> void:
	_is_dead = true
	_body.color = DEAD_COLOR
	_hp_bar_bg.visible = false
	if _attack_box and _attack_box.has_method("deactivate"):
		# ⚠️ 死亡可能发生在物理 Flush 期间（玩家攻击盒的 area_entered 回调链里），
		#    那时直接 deactivate（改 monitoring）会报
		#    "Can't change this state while flushing queries" —— 延迟到帧末关闭。
		_attack_box.call_deferred("deactivate")
	_attack_timer = ATTACK_COOLDOWN
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_body, "scale", Vector2(1.3, 0.25), 0.12)
	tw.tween_property(_body, "modulate:a", 0.35, 0.25)
	died.emit()


func revive() -> void:
	_is_dead = false
	hp = max_hp
	_flash_frames = 0
	_windup_left = 0
	_active_left = 0
	_recovery_left = 0
	_attack_timer = ATTACK_COOLDOWN
	_body.scale = Vector2.ONE
	_body.modulate.a = 1.0
	_body.color = BASE_COLOR
	if _eye_l:
		_eye_l.color = Color(0.1, 0.05, 0.05, 1)
	if _eye_r:
		_eye_r.color = Color(0.1, 0.05, 0.05, 1)
	_hp_bar_bg.visible = true
	if _attack_box and _attack_box.has_method("deactivate"):
		_attack_box.deactivate()
	_update_hp_bar()


func is_dead() -> bool:
	return _is_dead


## 是否正在前摇（供测试断言使用）
func is_telegraphing() -> bool:
	return _windup_left > 0


# ---- 单例 / 配置查找 ----

func _game_time() -> Node:
	return get_node_or_null("/root/GameTime")


func _feel() -> Resource:
	var nodes := get_tree().get_nodes_in_group("feel_config_holder")
	if nodes.is_empty():
		return null
	return nodes[0].get("feel")
