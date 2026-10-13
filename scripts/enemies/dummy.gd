extends StaticBody2D
## 训练假人（阶段 0 任务 0.7–0.8）
##
## 用途：让攻击有可打的目标，从而验证「三段连击 / 顿帧 / 屏震 / 击中反馈」。
## 它不是真正的敌人 AI —— 真正的敌人 AI 在任务 0.10。
##
## 接口约定（命中盒通过它造成伤害）：
##   hp: int              当前血量（命中盒读它判断是否击杀）
##   take_hit(damage, from_position)

signal died

## 命中盒会读取这个属性
var hp: int = 30
@export var max_hp: int = 30

var _flash_frames: int = 0
var _is_dead: bool = false

@onready var _body: Polygon2D = $Body
@onready var _hp_bar: ColorRect = $HpBarBg/HpBar
@onready var _hp_bar_bg: ColorRect = $HpBarBg

const BASE_COLOR := Color(0.95, 0.45, 0.35, 1.0)
const FLASH_COLOR := Color(1.0, 1.0, 1.0, 1.0)
const DEAD_COLOR := Color(0.25, 0.2, 0.22, 1.0)


func _ready() -> void:
	hp = max_hp
	add_to_group("dummy")
	_update_hp_bar()


func _physics_process(_delta: float) -> void:
	if _flash_frames > 0:
		_flash_frames -= 1
		if _flash_frames == 0:
			_body.color = BASE_COLOR if not _is_dead else DEAD_COLOR


## 由命中盒调用
func take_hit(damage: int, from_position: Vector2) -> void:
	if _is_dead:
		return

	hp = maxi(0, hp - damage)
	_flash_frames = 3
	_body.color = FLASH_COLOR
	_update_hp_bar()
	_apply_hitstop_and_shake()

	# 击退：朝远离攻击者的方向推一段，然后弹回
	var dir: float = signf(global_position.x - from_position.x)
	if is_zero_approx(dir):
		dir = 1.0
	_knockback(dir, 5.0 if hp > 0 else 9.0)

	print("[DUMMY] 受击 -%d HP → %d/%d%s" % [damage, hp, max_hp, "  ☠ 死亡" if hp == 0 else ""])

	if hp == 0:
		_die()


func _apply_hitstop_and_shake() -> void:
	# 从 GameTime 单例读取（autoload），顿帧与屏震都在那里统一管理
	var gt := _game_time()
	if gt == null:
		return
	var feel := _feel()
	if feel == null:
		return
	var is_kill := hp == 0
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


func _die() -> void:
	_is_dead = true
	_body.color = DEAD_COLOR
	_hp_bar_bg.visible = false
	# 死亡演出：压扁 + 变暗
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_body, "scale", Vector2(1.3, 0.25), 0.12)
	tw.tween_property(_body, "modulate:a", 0.35, 0.25)
	died.emit()


## 复活（R 重生时由关卡调用）
func revive() -> void:
	_is_dead = false
	hp = max_hp
	_flash_frames = 0
	_body.color = BASE_COLOR
	_body.scale = Vector2.ONE
	_body.modulate.a = 1.0
	_hp_bar_bg.visible = true
	_update_hp_bar()


func is_dead() -> bool:
	return _is_dead


# ---- 单例 / 配置查找（玩家会把自己的 FeelConfig 放进 group）----

func _game_time() -> Node:
	return get_node_or_null("/root/GameTime")


func _feel() -> Resource:
	var nodes := get_tree().get_nodes_in_group("feel_config_holder")
	if nodes.is_empty():
		return null
	return nodes[0].get("feel")
