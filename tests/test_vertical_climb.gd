extends SceneTree
## 垂直攀爬测试（阶段 1 准备）
##
## ⚠️ 存在的理由：**有洞 ≠ 爬得上**。
##
## 这个测试被同一类 bug 骗过两次，两次的教训必须记住：
##
##   第一次：台阶做成实心块，玩家从下往上跳会撞头 —— 完全爬不上。
##   第二次：单向平台但只放 4 级，最高一级到天花板只剩 45.4px（跳跃 48px），
##           余量 2.6px 被离散积分吃掉，实际跳不上去。
##
##   第三次（最隐蔽）：判据写的是「攀升 >= ROOM_H * 0.85」。
##           起点在下层地板 y=+204，0.85 层 = 187px → 只要到 y=+17 就算通过。
##           而**上层房间的可站立面在 y=-16**！
##           于是玩家爬到最高一级台阶（y=+39.6）、甚至只是蹦到 y=+17，
##           就已经"通过测试"了 —— 但脚底**从未越过边界 y=0**，
##           玩家在游戏里看到的就是"跳到最高也过不去"。
##           **测试通过 ≠ 玩家上去了。判据必须量到玩家真正站在上层房间的地板上。**
##
## 现在的判据：`is_on_floor() 且 position.y < 边界 y`。
##   这个判据与 Player 节点原点是脚底还是中心无关（-16 和 -27 都 < 0），
##   而且 y < 0 只可能出现在上层房间里（0..12 的墙带是实心的，进不去）。
##
## 用法：
##   $env:DSH_SKIP_BOOT_QUIT = "1"
##   & $GODOT --headless --path . --script "res://tests/test_vertical_climb.gd"

const ROOM_W := 400.0
const ROOM_H := 220.0
const FLOOR_H := 16.0

## 洞位置必须问生成器（v1.4 起偏移幅度随机，公式不能各写一份）
const LevelBuilder := preload("res://scripts/world/level_builder.gd")

## 攀 6 级台阶 + 每次起跳 44 帧 → 至少 264 帧，再留横向找落点的余量。
const MAX_FRAMES := 720
## ⚠️ 跳跃必须长按：可变跳跃高度会在松开时截断上升速度。
##    到顶点需要 22.5 帧，只按 4 帧 → 只升 22px（应为 47px），会误判"爬不上去"。
const JUMP_PERIOD := 44
const JUMP_HOLD := 24

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
var _room_center_x := 0.0
var _boundary_y := 0.0
var _ever_upper_floor := false
var _last_floor_y := 0.0


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

	# 横向操控：
	#   还没穿过边界 → 朝竖井中线靠，沿着台阶往上爬；
	#   **已经穿过边界 → 朝房间中心走，那里才是上层房间的实地。**
	#   ⚠️ 这一条是"过不去"的最后一个坑：洞有 V_SHAFT_W 宽，
	#      玩家从洞中央冒出来时，左右两侧各有一段空洞，
	#      必须横move 到洞沿以外才能踩到上层地板。
	var target_x: float = _shaft_x
	if _player.position.y < _boundary_y:
		target_x = _room_center_x
	var dx: float = target_x - _player.position.x
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
	if _player.is_on_floor() and _player.velocity.y >= 0.0:
		_last_floor_y = _player.position.y
		# ★ 真正的通过条件：站在上层房间里
		if _player.position.y < _boundary_y:
			_ever_upper_floor = true

	if _ever_upper_floor:
		_finish_pair(true)
	elif _frame >= MAX_FRAMES:
		_finish_pair(false)
	return false


func _setup_pair(idx: int) -> void:
	var pair: Dictionary = _pairs[idx]
	var lower: Vector2i = pair["lower"]
	_target_pair = lower

	# 上行洞属于「下层与上层的边界」，其位置由边界行号决定（逐行交替左右）：
	#   boundary_row = lower.y - 1
	#   sign = -1 若 boundary_row 为偶数，否则 +1
	#   x = 房间中心 + sign * V_SHAFT_SHIFT
	_room_center_x = float(lower.x) * ROOM_W + ROOM_W * 0.5
	_boundary_y = float(lower.y) * ROOM_H
	var boundary_row: int = lower.y - 1
	_shaft_x = LevelBuilder.gap_x_for_boundary(lower.x, boundary_row)
	var floor_y: float = float(lower.y) * ROOM_H + ROOM_H - FLOOR_H

	# ⚠️ 必须先把玩家状态清干净：上一组若被敌人打伤/打死，
	#    DEAD 状态会让玩家整组都不起跳，报出来像"几何 bug"。
	if _player.has_method("respawn"):
		_player.respawn()
	_player.position = Vector2(_shaft_x, floor_y - 1.0)
	_player.velocity = Vector2.ZERO
	_player.set_physics_process(true)

	_start_y = _player.position.y
	_min_y = _start_y
	_last_floor_y = _start_y
	_ever_upper_floor = false
	Input.action_release("jump")
	Input.action_release("move_left")
	Input.action_release("move_right")


func _finish_pair(ok: bool) -> void:
	var climbed: float = _start_y - _min_y
	# 顶点离"上层可站立面"还差多少：正数 = 越过了，负数 = 差多少够不到
	var apex_above_upper_floor: float = (_boundary_y - FLOOR_H) - _min_y
	_results.append({
		"pair": _target_pair,
		"climbed": climbed,
		"apex_gap": apex_above_upper_floor,
		"landed_y": _last_floor_y,
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
	var worst_apex := 99999.0

	if not _results.is_empty():
		print("[TEST] 逐对结果（apex_gap 正数=脚底越过上层地板表面，负数=差多少）：")
		for r in _results:
			var mark := "[PASS]" if r["ok"] else "[FAIL]"
			var note := "站上层房间" if r["ok"] else "仍在下层"
			print("[TEST]   %s 下层 %s  最高 +%.0f px  顶点余量 %+.1f px  %s  落脚 %.0f" % [
				mark, str(r["pair"]), r["climbed"], r["apex_gap"], note,
				float(r["landed_y"])])
			if r["ok"]:
				ok_count += 1
			worst_apex = minf(worst_apex, r["apex_gap"])

	var checks: Array = [
		["本层有垂直相邻房间（%d 组）" % total, total > 0],
		["全部垂直通道能真正站进上层房间（%d/%d）" % [ok_count, total],
			ok_count == total and total > 0],
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
		print("[TEST] 最差顶点余量: %+.1f px（需要 >= 0：脚底必须越过上层地板表面）" % worst_apex)
	print("[TEST] 结果: %d / %d 通过" % [passed, checks.size()])
	if passed == checks.size():
		print("[TEST] ★ 全部垂直通道可真正爬上上层房间")
	else:
		print("[TEST] ✗ 有通道爬不进上层 —— 检查 level_builder 的 TOP_LEDGE_Y 与洞宽")
	print("[TEST] =======================================")
	quit(0 if passed == checks.size() else 1)
