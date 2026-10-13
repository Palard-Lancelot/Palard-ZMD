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
## ⚠️ 追击速度必须接近玩家速度（玩家 165），否则玩家一走就追不上，
##    表现为"敌人不追击"。基础速度略低于玩家（可拉扯），
##    突进爆发高于玩家（会被扑到）—— 这样才有攻防博弈。
const RUSHER_CHASE_SPEED := 108.0
const RUSHER_LUNGE_SPEED := 155.0
const RUSHER_LUNGE_RANGE := 90.0
const RUSHER_DETECT := 165.0
const RUSHER_ATTACK_RANGE := 26.0
const RUSHER_COOLDOWN := 55
const RUSHER_WINDUP := 20
const RUSHER_ACTIVE := 6
const RUSHER_RECOVERY := 20


func _init() -> void:
	# —— 属性 ——
	max_hp = RUSHER_HP
	contact_damage = RUSHER_DAMAGE
	# —— 移动（两档速度）——
	move_speed = RUSHER_CHASE_SPEED
	lunge_speed = RUSHER_LUNGE_SPEED
	lunge_range = RUSHER_LUNGE_RANGE
	# —— 感知与攻击 ——
	detect_range = RUSHER_DETECT
	attack_range = RUSHER_ATTACK_RANGE
	attack_cooldown = RUSHER_COOLDOWN
	windup_frames = RUSHER_WINDUP
	active_frames = RUSHER_ACTIVE
	recovery_frames = RUSHER_RECOVERY
	# 前摇期间继续逼近 —— 制造压迫感
	move_during_windup = true
	windup_speed_mult = 0.5
