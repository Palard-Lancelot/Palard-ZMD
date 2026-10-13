extends Node2D
## 灰盒测试场景（阶段 0 任务 0.5）
##
## 用途：验证玩家移动手感 —— 走 / 跳 / 落 / 土狼时间 / 跳跃缓冲
## 场景内容：地面、4 层递进平台、台阶、墙、天花板、坑
##
## 设计说明：全部用 ColorRect 色块，不接美术。
## 手感没调对之前画美术等于白画（DESIGN.md 第 7 节）。

## 出生点：站在地面上（脚底对齐 y=0），且头顶无遮挡、不在平台正下方
const SPAWN_POSITION := Vector2(240, 0)

## 掉出这个高度以下就重生
const DEATH_Y := 200.0

## 隔离模式：环境变量 PALARD_ISOLATE=1 时**冻结**关卡内所有敌人的 AI。
##
## 为什么是"冻结"而不是"删除"：
##   攻击测试需要一个可打的靶子（假人），但不需要敌人主动行动。
##   删除会让靶子消失，攻击测试就没目标了。
##   所以这里只关掉 AI 与攻击盒，敌人仍然可以被玩家攻击。
const ISOLATE_ENV := "PALARD_ISOLATE"

@onready var player: CharacterBody2D = $Player
@onready var win_box: Area2D = $WinBox

var _spawn: Vector2
var _fell_count: int = 0
var _cleared: bool = false
var _isolated: bool = false


func _ready() -> void:
	_spawn = SPAWN_POSITION
	player.position = _spawn
	win_box.body_entered.connect(_on_win_box_entered)

	if OS.get_environment(ISOLATE_ENV) == "1":
		_isolate_enemies()

	print("[LEVEL] 灰盒测试场景就绪%s" % (
		"（隔离模式：敌人 AI 已冻结）" if _isolated else " —— 目标：踩到最右侧紫色方块"))


## 冻结所有敌人的 AI 与攻击盒（保留可被攻击的靶子）
func _isolate_enemies() -> void:
	_isolated = true
	var count := 0
	for group in ["dummy", "enemy"]:
		for e in get_tree().get_nodes_in_group(group):
			if not is_instance_valid(e) or e == player:
				continue
			e.set_physics_process(false)
			e.set("hostile", false)
			var ab := e.get_node_or_null("EnemyAttackBox")
			if ab and ab.has_method("deactivate"):
				ab.deactivate()
			count += 1
	print("[LEVEL] 已冻结 %d 个敌人的 AI" % count)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			respawn()
			get_viewport().set_input_as_handled()


func _physics_process(_delta: float) -> void:
	# 掉出地图 → 自动重生
	if player.position.y > DEATH_Y:
		_fell_count += 1
		print("[LEVEL] 掉落重生（第 %d 次）" % _fell_count)
		respawn()


## 由 boot.gd 调用，把 FeelConfig 透传给玩家
func setup_player(config: Resource) -> void:
	player.setup(config)


func respawn() -> void:
	player.position = _spawn
	player.velocity = Vector2.ZERO
	if player.has_method("respawn"):
		player.respawn()
	# 复活所有敌人（假人与冲锋兵都实现了 revive）
	for group in ["dummy", "enemy"]:
		for e in get_tree().get_nodes_in_group(group):
			if e.has_method("revive"):
				e.revive()
	_cleared = false


func _on_win_box_entered(body: Node2D) -> void:
	if _cleared or body != player:
		return
	_cleared = true
	print("[LEVEL] ★ 到达目标平台！")
