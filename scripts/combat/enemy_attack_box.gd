extends Area2D
## 敌人攻击盒（阶段 0 任务 0.9）
##
## 设计：与玩家攻击盒对称 —— 默认 disabled，只在「有效帧」窗口内启用。
## 玩家的 Hurtbox（layer 4）会检测到本盒（layer 3），触发 take_damage。
##
## 对玩家的约束（DESIGN.md 支柱2「禁止无效死亡」）：
##   任何能造成伤害的敌人攻击，都必须有**清晰前摇**。
##   本盒子默认关闭，由敌人自己在有预警的时机打开。

## 玩家受击逻辑会读取这个属性
@export var contact_damage: int = 10

var _shape_node: CollisionShape2D


func _ready() -> void:
	# 碰撞检测是**双向匹配**：双方都要在对方的 mask 里才会产生 area_entered 信号。
	#   本盒        : layer 5（enemy_attack = bit 16）, mask 含 layer 6（player_hurtbox = bit 32）
	#   玩家 Hurtbox: layer 6,                        mask 含 layer 5
	# 任一侧缺失都会导致"看起来配置对了但收不到信号"。
	collision_layer = 16
	collision_mask = 32
	monitoring = false
	monitorable = true
	_shape_node = $CollisionShape2D
	_set_active(false)


func activate() -> void:
	_set_active(true)


func deactivate() -> void:
	_set_active(false)


func _set_active(active: bool) -> void:
	monitoring = active
	if _shape_node:
		_shape_node.disabled = not active
