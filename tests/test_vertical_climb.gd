extends SceneTree
## 垂直攀爬测试（阶段 1 准备）
##
## ⚠️ 存在的理由：**有洞 ≠ 爬得上**。
##
## 背景：第一版攀爬台阶做成实心块，玩家从下往上跳会撞头。
## 第二版改成单向平台，但只放了 4 级台阶 ——
## 最高一级到天花板只剩 45.4px，跳跃高度 48px，余量仅 2.6px，
## 被离散积分和可变跳跃的微小损失吃掉，玩家实际还是跳不上去。
##
## 所以本测试**遍历所有垂直相邻房间**，逐个真的跳一遍。
## 只测第一对会漏掉布局差异导致的失败。
##
## 用法：
##   $env:DSH_SKIP_BOOT_QUIT = "1"
##   & $GODOT --headless --path . --script "res://tests/test_vertical_climb.gd"

const ROOM_W := 400.0
const ROOM_H := 220.0
const FLOOR_H := 16.0

const MAX_FRAMES := 420
## ⚠️ 跳跃必须长按：可变跳跃高度会在松开时截断上升速度。
##    实测只按 4 帧松开 → 只升 22px（应为 48px），会误判"爬不上去"。
const JUMP_PERIOD := 44
const JUMP_HOLD := 20

var _level: Node2D = null
var _player: CharacterBody2D = null
var _started := false
var _frame := 0

## 待测试的垂直房间对
var _pairs: Array = []
var _pair_index := 0
var _phase := 0

var _results: Array = []
var _start_y := 0.0
var _min_y := 999999.0
var _target_pair := Vector2i.ZERO
var _collected := false
var _shaft_x := 0.0


func _physics_process(_d: float) -> bool:
	if not _started:
		_boot()
		return false

	# ⚠️ generated_level.gd 的 _generate() 内部有 await，
	#    场景 instantiate 之后 graph 不是立刻有值。
	#    必须等它生成完再收集房间对，否则会得到 0 组。
	if not _collected:
		var g = _level.get("graph")
		if g == null:
			return false
		_collect_pairs()
		_collected = true
		return false

	if _pairs.is_empty():
		_report()
		return true

	_frame += 1

	# 准备下一对
	if _phase == 0:
		if _pair_index >= _pairs.size():
			_report()
			return true
		_setup_pair(_pair_index)
		_phase = 1
		_frame = 0
		return false

	# 跳跃攀爬
	var phase: int = _frame % JUMP_PERIOD
	if phase == 0:
		Input.action_press("jump")
	elif phase == JUMP_HOLD:
		Input.action_release("jump")

	# 朝洞口方向移动（模拟玩家走向竖井）
	var dx: float = _shaft_x - _player.position.x
	if absf(dx) > 6.0:
		if dx > 0.0:
			Input.action_press("move_right")
			Input.action_release("move_left")
		else:
			Input.action_press("move_left")
			Input.action_release("move_right")
	else:
		Input.action_release("move_left")
		Input.action_release("move_right")

	_min_y = minf(_min_y, _player.position.y)

	# 过关判定：攀升足够，或超时
	var climbed: float = _start_y - _min_y
	if climbed >= ROOM_H * 0.85:
		_finish_pair(climbed, true)
	elif _frame >= MAX_FRAMES:
		_finish_pair(climbed, false)
	return false


func _setup_pair(idx: int) -> void:
	var pair: Dictionary = _pairs[idx]
	var lower: Vector2i = pair["lower"]
	_target_pair = lower

	# 上行洞位于房间中心 - V_SHAFT_SHIFT(70)。
	# 玩家站在这个 x 的地面上（该处地板是实的，因为下行洞在 +70），
	# 然后原地起跳穿过上行洞 —— 这就是真实的攀爬路线。
	# 上行洞属于「本层与上一层的边界」，其位置由边界行号决定（逐行交替左右）：
	#   boundary_row = lower.y - 1
	#   sign = -1 若 boundary_row 为偶数，否则 +1
	#   x = 房间中心 + sign * 70
	var room_center: float = float(lower.x) * ROOM_W + ROOM_W * 0.5
	var boundary_row: int = lower.y - 1
	var sign: float = -1.0 if (boundary_row % 2 == 0) else 1.0
	var shaft_x: float = room_center + sign * 70.0
	var floor_y: float = float(lower.y) * ROOM_H + ROOM_H - FLOOR_H

	_player.position = Vector2(shaft_x, floor_y - 1.0)
	_player.velocity = Vector2.ZERO
	_player.set_physics_process(true)

	_shaft_x = shaft_x
	_start_y = _player.position.y
	_min_y = _start_y
	Input.action_release("jump")
	Input.action_release("move_left")
	Input.action_release("move_right")


func _finish_pair(climbed: float, ok: bool) -> void:
	_results.append({
		"pair": _target_pair,
		"climbed": climbed,
		"ok": ok,
	})
	Input.action_release("jump")
	Input.action_release("move_left")
	Input.action_release("move_right")
	_pair_index += 1
	_phase = 0


func _boot() -> void:
	_started = true
	var sc: PackedScene = load("res://scenes/world/generated_level.tscn")
	if sc == null:
		print("[TEST] FAIL: 无法加载 generated_level.tscn")
		quit(1)
		return
	_level = sc.instantiate() as Node2D
	get_root().add_child(_level)
	_player = _level.get_node_or_null("Player") as CharacterBody2D
	if _player == null:
		print("[TEST] FAIL: 找不到 Player")
		quit(1)
		return


func _collect_pairs() -> void:
	var g = _level.get("graph")
	if g == null:
		return
	var cell_of := {}
	for rm in g.rooms:
		cell_of[rm["cell"]] = rm["id"]

	for rm in g.rooms:
		var c: Vector2i = rm["cell"]
		var below := c + Vector2i(0, 1)
		if cell_of.has(below):
			_pairs.append({"upper": c, "lower": below})

	print("[TEST] 本层垂直相邻房间对: %d 组" % _pairs.size())


func _report() -> void:
	var total := _results.size()
	var ok_count := 0
	var worst := 99999.0

	if not _results.is_empty():
		print("[TEST] 逐对结果:")
		for r in _results:
			var mark := "[PASS]" if r["ok"] else "[FAIL]"
			print("[TEST]   %s 下层 %s  攀升 %.0f px" % [
				mark, str(r["pair"]), r["climbed"]])
			if r["ok"]:
				ok_count += 1
			worst = minf(worst, r["climbed"])

	var checks: Array = [
		["本层有垂直相邻房间（%d 组）" % total, total > 0],
		["全部垂直通道可攀爬（%d/%d）" % [ok_count, total], ok_count == total and total > 0],
	]

	print("")
	print("[TEST] ============ 垂直攀爬测试 ============")
	var passed := 0
	for c in checks:
		var ok: bool = c[1]
		if ok:
			passed += 1
		print("[TEST]   %s %s" % ["[PASS]" if ok else "[FAIL]", c[0]])
	print("[TEST] ---------------------------------------")
	if total > 0:
		print("[TEST] 最差攀升: %.0f px（需要 >= %.0f）" % [worst, ROOM_H * 0.85])
	print("[TEST] 结果: %d / %d 通过" % [passed, checks.size()])
	if passed == checks.size():
		print("[TEST] ★ 全部垂直通道可攀爬")
	else:
		print("[TEST] ✗ 有通道爬不上去 —— 检查台阶数 / 间距 / 是否为单向碰撞")
	print("[TEST] =======================================")
	quit(0 if passed == checks.size() else 1)
