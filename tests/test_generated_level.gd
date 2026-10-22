extends SceneTree
## 生成关卡可达性测试（阶段 1 准备）
##
## 验证 level_builder.gd 建出的几何真的能走：
##   1. 场景能加载并生成
##   2. 玩家能站住（不穿地板）
##   3. 相邻房间之间的门洞，玩家**真的能走进去**
##   4. 相机 limit 覆盖整层
##
## ⚠️ 这个测试被自己的测法坑过一次，教训值得留着：
##
##   最初版本：把玩家放在入口房中央，按住右键 200 帧，
##             断言"水平位移 > 120px"。
##
##   结果：玩家往右走，正好踩进**地板上的竖井洞**，掉到下层房间去了。
##         位移只有 104px，测试报"几何有问题 —— 检查门洞"，
##         但其实门洞完全正常，是**测法本身假设错了**：
##         房间地面本来就可能开洞（层内上下连通就靠它），
##         "一路按右键能走多远"并不是一个定义明确的东西。
##
##   现在改为：从图里挑一条真实存在的**水平相邻边**，
##             把玩家放在左房里离共享墙 60px 的地面上，
##             按方向键直到跨过 x 边界就立刻收工。
##             这个区间离任何竖井洞都至少 30px（洞最远到离墙 90px），
##             所以不会掉下去。
##
## 用法：
##   $env:DSH_SKIP_BOOT_QUIT = "1"
##   & $GODOT --headless --path . --script "res://tests/test_generated_level.gd"

const WARMUP := 30          ## 等生成完成 + 玩家落地
const MAX_RUN_FRAMES := 120 ## 最多按方向键多久（165px/s 足够走完 60px + 余量）
const ROOM_W := 400.0
const ROOM_H := 220.0
const FLOOR_H := 16.0

var _level: Node2D = null
var _player: CharacterBody2D = null
var _started := false
var _frame := 0
var _run_frames := 0

var _rooms_ok := false
var _room_count := 0
var _edge_found := false
var _boundary_x := 0.0
var _move_right := true
var _start_x := 0.0
var _end_x := 0.0
var _crossed := false
var _cam_limits := Rect2i()
var _done := false


func _physics_process(_d: float) -> bool:
	if not _started:
		_boot()
		return false
	if _done:
		return true

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
		var cam := _player.get_node_or_null("Camera2D") as Camera2D
		if cam:
			_cam_limits = Rect2i(cam.limit_left, cam.limit_top,
				cam.limit_right - cam.limit_left, cam.limit_bottom - cam.limit_top)
		_place_at_horizontal_door(g)
		return false

	if _frame <= WARMUP:
		return false

	# 按方向键走向隔壁房间
	if _run_frames < MAX_RUN_FRAMES:
		_run_frames += 1
		var act := "move_right" if _move_right else "move_left"
		Input.action_press(act)
		_end_x = _player.position.x
		# 跨过共享墙就立刻收工，别继续走进对面房间的竖井洞
		if _move_right and _end_x > _boundary_x + 10.0:
			_crossed = true
			_finish()
		elif not _move_right and _end_x < _boundary_x - 10.0:
			_crossed = true
			_finish()
		return false

	_finish()
	return false


## 从图里挑一条水平相邻边，把玩家放到左房离共享墙 60px 的地面上。
##
## ⚠️ 为什么是 60px：竖井洞最远只到离墙 90px（房间中心 ±80，洞半宽 30），
##    60px 处地面一定是实的。跨过墙 10px 就收工，也不会碰到对面房间的洞。
func _place_at_horizontal_door(g: RefCounted) -> void:
	var cell_of := {}
	for rm in g.rooms:
		cell_of[rm["id"]] = rm["cell"]

	var pick: Array = []
	for e in g.edges:
		var id_a: int = e[0]
		var id_b: int = e[1]
		if not cell_of.has(id_a) or not cell_of.has(id_b):
			continue
		var ca: Vector2i = cell_of[id_a]
		var cb: Vector2i = cell_of[id_b]
		var d: Vector2i = cb - ca
		if absi(d.y) == 0 and absi(d.x) == 1:
			pick.append([ca, cb])
			break

	if pick.is_empty():
		print("[TEST] FAIL: 本层没有水平相邻边，无法测试门洞")
		return

	var ca: Vector2i = pick[0][0]
	var cb: Vector2i = pick[0][1]
	_edge_found = true
	_move_right = cb.x > ca.x
	var left_cell: Vector2i = ca if _move_right else cb
	_boundary_x = float(maxi(ca.x, cb.x)) * ROOM_W
	var floor_y: float = float(left_cell.y) * ROOM_H + ROOM_H - FLOOR_H

	_start_x = _boundary_x - 60.0
	if _move_right:
		_start_x = _boundary_x - 60.0
	else:
		_start_x = _boundary_x + 60.0

	if _player.has_method("respawn"):
		_player.respawn()
	_player.position = Vector2(_start_x, floor_y - 11.0)
	_player.velocity = Vector2.ZERO
	_player.set_physics_process(true)
	print("[TEST] 测试门洞：%s → %s  共享墙 x=%.0f  起点 x=%.0f 方向 %s" % [
		str(ca), str(cb), _boundary_x, _start_x, "右" if _move_right else "左"])


func _finish() -> void:
	_done = true
	Input.action_release("move_right")
	Input.action_release("move_left")
	_end_x = _player.position.x
	_report()


func _report_fail(reason: String) -> void:
	print("[TEST] 结果: 0 / 5 通过（%s）" % reason)
	quit(1)


func _report() -> void:
	var moved: float = absf(_end_x - _start_x)

	print("")
	print("[TEST] ========== 生成关卡可达性测试 ==========")
	print("[TEST] 房间数: %d" % _room_count)
	print("[TEST] 共享墙 x=%.0f  起点 x=%.0f  终点 x=%.0f  位移 %.1f px" % [
		_boundary_x, _start_x, _end_x, moved])
	print("[TEST] 相机 limit: %s" % str(_cam_limits))

	var checks: Array = [
		["场景生成成功（%d 个房间）" % _room_count, _rooms_ok],
		["找到一条水平相邻边用于测门洞", _edge_found],
		["玩家能站在房间地面上（位移 %.1fpx）" % moved, moved > 10.0],
		["跨过共享墙走进隔壁房间（门洞可通行）", _crossed],
		["相机 limit 覆盖多层（宽 %d）" % _cam_limits.size.x, _cam_limits.size.x > 400],
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
