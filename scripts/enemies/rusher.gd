extends "res://scripts/enemies/enemy_base.gd"
## 冲锋兵（阶段 0 任务 0.10）
##
## 第一种真正的敌人：会主动追击玩家，接近后前摇 → 挥砍。
##
## 行为原型定位（DESIGN.md 第 7 节的敌人四原型）：
##   冲锋兵 = 直线接近 → 近身攻击
##   逼玩家做的决策：**拉开距离**
##
## 前摇期间的压迫感设计：
##   前摇 20 帧（0.33 秒）期间**继续以半速逼近** ——
##   给玩家"它正在扑过来"的压力，而不是原地站着挥空气。

const RUSHER_HP := 24
const RUSHER_DAMAGE := 10
const RUSHER_SPEED := 78.0
const RUSHER_DETECT := 150.0
const RUSHER_ATTACK_RANGE := 26.0
const RUSHER_COOLDOWN := 55
const RUSHER_WINDUP := 20
const RUSHER_ACTIVE := 6
const RUSHER_RECOVERY := 20


func _init() -> void:
	# —— 属性 ——
	max_hp = RUSHER_HP
	contact_damage = RUSHER_DAMAGE
	# —— 移动 ——
	move_speed = RUSHER_SPEED
	# —— 感知与攻击 ——
	detect_range = RUSHER_DETECT
	attack_range = RUSHER_ATTACK_RANGE
	attack_cooldown = RUSHER_COOLDOWN
	windup_frames = RUSHER_WINDUP
	active_frames = RUSHER_ACTIVE
	recovery_frames = RUSHER_RECOVERY
	# 前摇期间继续逼近 —— 制造压迫感
	move_during_windup = true
	windup_speed_mult = 0.45
