extends Area2D
## 攻击判定盒（阶段 0 任务 0.7）
##
## 设计：判定盒默认 disabled，只在「有效帧」窗口内启用。
##       前摇/后摇期间不产生判定 —— 这是"攻击时机"能被玩家学习的前提。
##
## 防重复命中：一次挥砍内同一个敌人只吃一次伤害，记录在 _hit_this_swing。

signal hit_landed(target: Node2D, damage: int, knockback: float, is_kill: bool)

## 命中敌人所在物理层（见 project.godot 的 layer_names）
## 敌人身体在 layer 3，对应 bit 值 1 << (3-1) = 4
const ENEMY_LAYER := 3

var _shape_node: CollisionShape2D
var _hit_this_swing: Array = []


func _ready() -> void:
	# 判定盒自身不参与被检测，只做检测
	collision_layer = 0
	collision_mask = 1 << (ENEMY_LAYER - 1)
	_shape_node = $CollisionShape2D
	area_entered.connect(_on_area_entered)
	_set_active(false)


## 开启判定窗口（在「有效帧」的第一帧调用）
func activate(width: float) -> void:
	_hit_this_swing.clear()
	_set_active(true)
	# 已重叠的敌人不会触发 area_entered，需主动补扫一次
	_scan_overlaps(width)


## 关闭判定窗口
func deactivate() -> void:
	_set_active(false)


func _set_active(active: bool) -> void:
	monitoring = active
	if _shape_node:
		_shape_node.disabled = not active


## 主动扫描当前重叠，处理「激活瞬间敌人已经在范围内」的情况
func _scan_overlaps(_width: float) -> void:
	for body in get_overlapping_bodies():
		_try_hit(body)


func _on_area_entered(area: Area2D) -> void:
	_try_hit(area)


func _try_hit(node: Node) -> void:
	if node == null or _hit_this_swing.has(node):
		return
	# 敌人需要提供 take_hit(damage, from_position) 接口
	var target := _find_hittable(node)
	if target == null:
		return
	_hit_this_swing.append(target)

	var damage: int = 10
	var knockback: float = 80.0
	if owner is Node and owner.get("attack_damage") != null:
		damage = int(owner.attack_damage)

	var is_kill: bool = false
	if target.has_method("take_hit"):
		var before_hp: int = target.get("hp") if target.get("hp") != null else 1
		target.take_hit(damage, global_position)
		var after_hp: int = target.get("hp") if target.get("hp") != null else 0
		is_kill = after_hp <= 0 and before_hp > 0

	hit_landed.emit(target, damage, knockback, is_kill)


## 从被检测节点向上找具备 take_hit 的节点（敌人可能是 Area2D 或 StaticBody2D）
func _find_hittable(node: Node) -> Node2D:
	var cur: Node = node
	var depth := 0
	while cur != null and depth < 4:
		if cur.has_method("take_hit"):
			return cur as Node2D
		cur = cur.get_parent()
		depth += 1
	return null
