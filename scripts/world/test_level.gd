extends Node2D
## 灰盒测试关卡 —— 单局控制器（阶段 0 任务 0.11 战斗闭环）
##
## 完整战斗闭环：
##   开局 → 打敌人（击杀计数）→ 被打死 / 清场 → 结算 → 重开
##
## 职责：
##   · 管理单局状态（PLAYING / DEAD / CLEARED）
##   · 统计击杀数
##   · 死亡与胜利的 UI 覆盖层
##   · 重开时完整重置（玩家 HP / 敌人 / 击杀数）
##
## 设计说明：全部用色块，不接美术。手感没调对之前画美术等于白画。

const SPAWN_POSITION := Vector2(240, 0)
const DEATH_Y := 200.0

## 隔离模式：环境变量 PALARD_ISOLATE=1 时冻结所有敌人 AI。
## 战斗类测试用它避免被其他敌人的 AI 干扰
## （注意是"冻结"而非"删除"—— 攻击测试需要一个可打的靶子）。
const ISOLATE_ENV := "PALARD_ISOLATE"

enum RunState { PLAYING, DEAD, CLEARED }

@onready var player: CharacterBody2D = $Player
@onready var win_box: Area2D = $WinBox
@onready var kill_label: Label = $HUD/KillCounter
@onready var overlay: Control = $HUD/Overlay
@onready var overlay_title: Label = $HUD/Overlay/Title
@onready var overlay_hint: Label = $HUD/Overlay/Hint

var _spawn: Vector2
var _fell_count: int = 0
var _isolated: bool = false

## 单局状态
var run_state: RunState = RunState.PLAYING
var kills: int = 0
var total_enemies: int = 0
var deaths: int = 0

## 开局时快照的敌人列表（用于统计与重置）
var _enemies: Array = []


func _ready() -> void:
	_spawn = SPAWN_POSITION
	player.position = _spawn
	win_box.body_entered.connect(_on_win_box_entered)

	_collect_enemies()
	player.died.connect(_on_player_died)

	if OS.get_environment(ISOLATE_ENV) == "1":
		_isolate_enemies()

	_reset_run()
	print("[LEVEL] 灰盒测试场景就绪%s —— 目标：清光 %d 个敌人" % [
		"（隔离模式：敌人 AI 已冻结）" if _isolated else "", total_enemies])


## 收集关卡内所有敌人并连接死亡信号
func _collect_enemies() -> void:
	_enemies.clear()
	for group in ["dummy", "enemy"]:
		for e in get_tree().get_nodes_in_group(group):
			if not is_instance_valid(e) or e == player:
				continue
			if _enemies.has(e):
				continue
			_enemies.append(e)
			if e.has_signal("died") and not e.died.is_connected(_on_enemy_died):
				e.died.connect(_on_enemy_died)
	total_enemies = _enemies.size()


## 冻结所有敌人的 AI 与攻击盒（保留可被攻击的靶子）
func _isolate_enemies() -> void:
	_isolated = true
	var count := 0
	for e in _enemies:
		if not is_instance_valid(e):
			continue
		e.set_physics_process(false)
		e.set("hostile", false)
		var ab: Node = e.get_node_or_null("EnemyAttackBox")
		if ab and ab.has_method("deactivate"):
			ab.deactivate()
		count += 1
	print("[LEVEL] 已冻结 %d 个敌人的 AI" % count)


# ============================================================
# 单局流程
# ============================================================

## 开新一局：完整重置
func _reset_run() -> void:
	run_state = RunState.PLAYING
	kills = 0
	player.position = _spawn
	player.velocity = Vector2.ZERO
	if player.has_method("respawn"):
		player.respawn()
	for e in _enemies:
		if is_instance_valid(e) and e.has_method("revive"):
			e.revive()
	_set_overlay_visible(false)
	_update_hud()


func restart_run() -> void:
	deaths += 1
	_reset_run()
	print("[LEVEL] === 第 %d 局开始 ===" % (deaths + 1))


func _on_enemy_died() -> void:
	if run_state != RunState.PLAYING:
		return
	kills += 1
	_update_hud()
	print("[LEVEL] 击杀 %d / %d" % [kills, total_enemies])
	if total_enemies > 0 and kills >= total_enemies:
		_clear_run()


func _clear_run() -> void:
	if run_state != RunState.PLAYING:
		return
	run_state = RunState.CLEARED
	_set_overlay_visible(true)
	overlay_title.text = "清 场 完 成"
	overlay_title.modulate = Color(0.6, 1.0, 0.65)
	overlay_hint.text = "按 R 再打一局"
	print("[LEVEL] ★ 清场！全部 %d 个敌人已击杀" % total_enemies)


func _on_player_died() -> void:
	if run_state != RunState.PLAYING:
		return
	run_state = RunState.DEAD
	_set_overlay_visible(true)
	overlay_title.text = "你 死 了"
	overlay_title.modulate = Color(1.0, 0.45, 0.45)
	overlay_hint.text = "按 R 重开"
	print("[LEVEL] 玩家死亡 —— 本局击杀 %d / %d" % [kills, total_enemies])


func _set_overlay_visible(v: bool) -> void:
	if overlay:
		overlay.visible = v


func _update_hud() -> void:
	if kill_label == null:
		return
	kill_label.text = "击杀 %d / %d" % [kills, total_enemies]


# ============================================================
# 输入
# ============================================================

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			# 进行中按 R = 主动重开；死亡 / 清场后按 R = 开新局
			restart_run()
			get_viewport().set_input_as_handled()


# ============================================================
# 每帧
# ============================================================

func _physics_process(_delta: float) -> void:
	if run_state != RunState.PLAYING:
		return
	# 掉出地图 → 走完整死亡流程（而非静默重生）
	if player.position.y > DEATH_Y:
		_fell_count += 1
		print("[LEVEL] 掉落死亡（第 %d 次）" % _fell_count)
		if player.has_method("take_damage"):
			player.take_damage(player.max_hp, player.global_position + Vector2(0, -100))


# ============================================================
# 兼容旧接口
# ============================================================

## 由 boot.gd 调用，把 FeelConfig 透传给玩家
func setup_player(config: Resource) -> void:
	player.setup(config)


## 旧的重生接口 —— 现在等同开新一局
func respawn() -> void:
	restart_run()


func _on_win_box_entered(body: Node2D) -> void:
	if body != player or run_state != RunState.PLAYING:
		return
	_clear_run()
	print("[LEVEL] ★ 到达目标平台")
