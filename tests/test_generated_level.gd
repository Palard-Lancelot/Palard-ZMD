extends SceneTree
## 生成关卡可达性测试（阶段 1 准备）
##
## 验证 level_builder.gd 建出的几何真的能走：
##   1. 场景能加载并生成
##   2. 玩家被放在入口房
##   3. 门洞可通行 —— 玩家按住方向键能走出入口房
##   4. 相机 limit 覆盖整层
##
## ⚠️ 为什么必须测这个：
##   图论上"连通"不等于几何上"能走"。墙留错位置、门洞高度不够、
##   地板把你挡在门里 —— 这些问题图论测试全看不出，
##   只有真的让角色走一遍才能发现。
##
## 用法：
##   $env:DSH_SKIP_BOOT_QUIT = "1"
##   & $GODOT --headless --path . --script "res://tests/test_generated_level.gd"

const WARMUP := 30          ## 等生成完成 + 玩家落地
const RUN_FRAMES := 200     ## 按住方向键跑多久

var _level: Node2D = null
var _player: CharacterBody2D = null
var _started := false
var _frame := 0

var _rooms_ok := false
var _room_count := 0
var _start_x := 0.0
var _start_cell := Vector2i.ZERO
var _end_x := 0.0
var _end_cell := Vector2i.ZERO
var _moved := 0.0
var _cell_changed := false
var _cam_limits := Rect2i()


func _physics_process(_d: float) -> bool:
	if not _started:
		_boot()
		return false

	_frame += 1

	# 等生成完成
	if _frame == WARMUP:
		var g = _level.get("graph")
		if g == null:
			print("[TEST] FAIL: graph 为 null（生成未完成）")
			_report_fail("生成未完成")
			return true
		_room_count = g.rooms.size()
		_rooms_ok = _room_count > 0
		_start_x = _player.position.x
		_start_cell = _cell_of(_start_x, _player.position.y)
		var cam := _player.get_node_or_null("Camera2D") as Camera2D
		if cam:
			_cam_limits = Rect2i(cam.limit_left, cam.limit_top,
				cam.limit_right - cam.limit_left, cam.limit_bottom - cam.limit_top)
		return false

	if _frame > WARMUP and _frame <= WARMUP + RUN_FRAMES:
		Input.action_press("move_right")

	if _frame == WARMUP + RUN_FRAMES:
		Input.action_release("move_right")
		_end_x = _player.position.x
		_end_cell = _cell_of(_end_x, _player.position.y)
		_moved = _end_x - _start_x
		_cell_changed = _end_cell != _start_cell
		_report()
		return true
	return false


func _cell_of(x: float, y: float) -> Vector2i:
	return Vector2i(
		int(floor(x / 400.0)),      # LevelBuilder.ROOM_W
		int(floor(y / 220.0))       # LevelBuilder.ROOM_H
	)


func _boot() -> void:
	_started = true
	var scene: PackedScene = load("res://scenes/world/generated_level.tscn")
	if scene == null:
		print("[TEST] FAIL: 无法加载 generated_level.tscn")
		_report_fail("场景加载失败")
		return
	_level = scene.instantiate() as Node2D
	get_root().add_child(_level)
	_player = _level.get_node_or_null("Player") as CharacterBody2D
	if _player == null:
		print("[TEST] FAIL: 找不到 Player")
		_report_fail("找不到 Player")


func _report_fail(reason: String) -> void:
	print("[TEST] 结果: 0 / 4 通过（%s）" % reason)
	quit(1)


func _report() -> void:
	print("")
	print("[TEST] ========== 生成关卡可达性测试 ==========")
	print("[TEST] 房间数: %d" % _room_count)
	print("[TEST] 起点 x=%.1f（格 %s） 终点 x=%.1f（格 %s）" % [
		_start_x, str(_start_cell), _end_x, str(_end_cell)])
	print("[TEST] 水平位移: %.1f px" % _moved)
	print("[TEST] 相机 limit: %s" % str(_cam_limits))

	var checks: Array = [
		["场景生成成功（%d 个房间）" % _room_count, _rooms_ok],
		["玩家被放在入口房", _start_x > 0.0],
		["能走出入口房（位移 %.0fpx）" % _moved, _moved > 120.0],
		["跨越了房间边界（门洞可通行）", _cell_changed],
		["相机 limit 覆盖多层", _cam_limits.size.x > 400],
	]

	var passed := 0
	for c in checks:
		var ok: bool = c[1]
		if ok:
			passed += 1
		print("[TEST]   %s %s" % ["[PASS]" if ok else "[FAIL]", c[0]])

	print("[TEST] -----------------------------------------")
	print("[TEST] 结果: %d / %d 通过" % [passed, checks.size()])
	if passed == checks.size():
		print("[TEST] ★ 生成关卡可玩 —— 图论连通已转化为几何可通行")
	else:
		print("[TEST] ✗ 几何有问题 —— 检查门洞 / 地板 / 墙的位置")
	print("[TEST] =========================================")
	quit(0 if passed == checks.size() else 1)
