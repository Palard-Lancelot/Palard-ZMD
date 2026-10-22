extends Node2D
## 程序化生成关卡（阶段 1 准备）
##
## 把 room_graph.gd 的抽象图 + level_builder.gd 的几何，组装成一个**可玩的层**。
##
## 与 test_level.tscn 的区别：
##   test_level 是手写固定布局（用于自动化测试，布局稳定）
##   generated_level 每局按种子生成不同布局（验证"层内连通可回退"真的能玩）
##
## 目标流程：从入口房出发 → 穿过连通房间 → 到达出口房

const FeelConfigScript := preload("res://scripts/config/feel_config.gd")
const RoomGraphScript := preload("res://scripts/world/room_graph.gd")
const LevelBuilder := preload("res://scripts/world/level_builder.gd")
const RusherScene := preload("res://scenes/enemies/rusher.tscn")

## 默认种子（可按 R 换一个）
var seed_value: int = 12345

var feel: Resource = null
var graph: RefCounted = null
var _rooms_root: Node2D = null
var _exit_center: Vector2 = Vector2.ZERO
var _entrance_center: Vector2 = Vector2.ZERO
var _won := false
var _kills := 0
var _total_enemies := 0

@onready var player: CharacterBody2D = $Player
@onready var debug_panel: CanvasLayer = $DebugPanel
@onready var kill_label: Label = $HUD/KillCounter
@onready var overlay: Control = $HUD/Overlay
@onready var overlay_title: Label = $HUD/Overlay/Title
@onready var overlay_hint: Label = $HUD/Overlay/Hint


func _ready() -> void:
	feel = FeelConfigScript.new()
	debug_panel.bind(feel)
	player.setup(feel)
	player.died.connect(_on_player_died)

	_generate()


# ============================================================
# 生成
# ============================================================

func _generate() -> void:
	# 清掉上一次的内容（按 R 换种子时用）
	if _rooms_root != null and is_instance_valid(_rooms_root):
		_rooms_root.queue_free()
	for c in get_children():
		if c.is_in_group("generated_enemy"):
			c.queue_free()
	await get_tree().process_frame

	graph = RoomGraphScript.new()
	if not graph.generate(seed_value):
		push_error("层生成失败（种子 %d）" % seed_value)
		return

	_rooms_root = LevelBuilder.build(graph, self)

	# --- 玩家放到入口房 ---
	_entrance_center = LevelBuilder.room_center(graph, graph.entrance_id)
	_exit_center = LevelBuilder.room_center(graph, graph.exit_id)
	player.position = _entrance_center
	player.velocity = Vector2.ZERO

	# --- 相机 limit 覆盖整层 ---
	var bounds: Rect2 = LevelBuilder.layer_bounds(graph)
	var cam := player.get_node_or_null("Camera2D") as Camera2D
	if cam:
		cam.limit_left = int(bounds.position.x)
		cam.limit_right = int(bounds.position.x + bounds.size.x)
		cam.limit_top = int(bounds.position.y - 80.0)
		cam.limit_bottom = int(bounds.position.y + bounds.size.y)

	# --- 战斗房里放敌人 ---
	_total_enemies = 0
	for room in graph.rooms:
		var t: StringName = room["type"]
		if t != &"combat" and t != &"elite":
			continue
		var center: Vector2 = LevelBuilder.room_center(graph, room["id"])
		var e := RusherScene.instantiate()
		e.position = center + Vector2(60.0, 0.0)
		e.add_to_group("generated_enemy")
		add_child(e)
		if e.has_signal("died"):
			e.died.connect(_on_enemy_died)
		_total_enemies += 1

	_won = false
	_kills = 0
	overlay.visible = false
	_update_hud()

	print("[GENLEVEL] 种子 %d  房间 %d  敌人 %d  入口→出口跨度 %d 格" % [
		seed_value, graph.rooms.size(), _total_enemies,
		graph.stats.get("entrance_exit_dx", -1)])


# ============================================================
# 每帧：出口判定
# ============================================================

func _physics_process(_delta: float) -> void:
	# ⚠️ _generate() 内部有 await，_ready 返回时 graph 可能还是 null。
	#    必须显式保护，否则会在生成完成前访问 graph.rooms。
	if _won or graph == null:
		return
	# 到达出口房即通关（按房间格子判断，避免碰撞盒边界误差）
	var exit_cell: Vector2i = _exit_room_cell()
	var player_cell: Vector2i = Vector2i(
		int(floor(player.position.x / LevelBuilder.ROOM_W)),
		int(floor(player.position.y / LevelBuilder.ROOM_H))
	)
	if player_cell == exit_cell and absf(player.position.y - _exit_center.y) < 120.0:
		_win()

	# 掉出整层包围盒 → 死亡
	var bounds: Rect2 = LevelBuilder.layer_bounds(graph)
	if player.position.y > bounds.position.y + bounds.size.y + 200.0:
		if player.has_method("take_damage"):
			player.take_damage(player.max_hp, player.position + Vector2(0, -100))


func _exit_room_cell() -> Vector2i:
	for room in graph.rooms:
		if room["id"] == graph.exit_id:
			return room["cell"]
	return Vector2i(-999, -999)


# ============================================================
# 事件
# ============================================================

func _on_enemy_died() -> void:
	_kills += 1
	_update_hud()


func _on_player_died() -> void:
	_set_overlay("你 死 了", Color(1.0, 0.45, 0.45), "按 R 换一层重开")


func _win() -> void:
	_won = true
	_set_overlay("到 达 出 口", Color(0.6, 1.0, 0.65), "按 R 换一层")


func _set_overlay(title: String, color: Color, hint: String) -> void:
	overlay.visible = true
	overlay_title.text = title
	overlay_title.modulate = color
	overlay_hint.text = hint


func _update_hud() -> void:
	if kill_label:
		kill_label.text = "击杀 %d / %d" % [_kills, _total_enemies]


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			# 换一个种子重新生成 —— 这就是"每局不同"的原型
			seed_value = randi() % 100000
			_generate()
			get_viewport().set_input_as_handled()
