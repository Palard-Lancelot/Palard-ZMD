extends SceneTree
## 垂直攀爬测试（阶段 1 准备）
##
## ⚠️ 存在的理由：**有洞 ≠ 爬得上**。
##
## 背景：第一版攀爬台阶做成实心块，玩家从下往上跳会撞头，
## 永远爬不上去。几何测试（射线检测）发现不了这个问题 ——
## 射线只问"有没有被挡"，不问"能不能跳过去"。
##
## 本测试真的让角色跳：把玩家放在垂直通道底部，
## 反复按跳跃，看 y 是否真的减小了一个房间高度。
##
## 用法：
##   $env:DSH_SKIP_BOOT_QUIT = "1"
##   & $GODOT --headless --path . --script "res://tests/test_vertical_climb.gd"

const ROOM_W := 400.0
const ROOM_H := 220.0
const FLOOR_H := 16.0

const MAX_FRAMES := 900
## ⚠️ 跳跃周期必须足够长：可变跳跃高度会在「松开跳跃键」时截断上升速度。
##    实测只按 4 帧就松开 → 只升 22px（应为 48px），导致误判"爬不上去"。
##    真实玩家长按跳跃，这里必须模拟长按（20 帧 ≈ 0.33s，覆盖完整上升期）。
const JUMP_PERIOD := 44
const JUMP_HOLD := 20        ## 按住跳跃的帧数

var _level: Node2D = null
var _player: CharacterBody2D = null
var _started := false
var _frame := 0

var _start_y := 0.0
var _min_y := 999999.0
var _climbed := 0.0
var _found_pair := false
var _pair_lower := Vector2i.ZERO
var _pair_upper := Vector2i.ZERO


func _physics_process(_d: float) -> bool:
	if not _started:
		_boot()
		return false

	_frame += 1
	if _frame < 40:
		return false

	# 找一对垂直相邻的房间，把玩家放到下层的通道底部
	if not _found_pair:
		if not _setup_climb_scenario():
			return true
		return false

	# 模拟跳跃：长按以拿到完整跳跃高度，然后松开再按
	var phase: int = _frame % JUMP_PERIOD
	if phase == 0:
		Input.action_press("jump")
	elif phase == JUMP_HOLD:
		Input.action_release("jump")

	_min_y = minf(_min_y, _player.position.y)
	_climbed = _start_y - _min_y

	if _frame >= MAX_FRAMES:
		Input.action_release("jump")
		_report()
		return true
	return false


func _setup_climb_scenario() -> bool:
	var g = _level.get("graph")
	if g == null:
		print("[TEST] FAIL: graph 为 null")
		quit(1)
		return false

	var cell_of := {}
	for rm in g.rooms:
		cell_of[rm["cell"]] = rm["id"]

	# 找一对上下相邻的房间
	for rm in g.rooms:
		var c: Vector2i = rm["cell"]
		var below := c + Vector2i(0, 1)
		if cell_of.has(below):
			_pair_upper = c
			_pair_lower = below
			_found_pair = true
			break

	if not _found_pair:
		print("[TEST] 本层没有上下相邻的房间，无法测试攀爬")
		return false

	# 玩家放到下层通道底部（房间中心 x，地面上）
	var shaft_x: float = float(_pair_lower.x) * ROOM_W + ROOM_W * 0.5
	var floor_y: float = float(_pair_lower.y) * ROOM_H + ROOM_H - FLOOR_H
	_player.position = Vector2(shaft_x, floor_y - 1.0)
	_player.velocity = Vector2.ZERO
	_start_y = _player.position.y
	_min_y = _start_y

	print("[TEST] 攀爬场景: 下层 %s → 上层 %s" % [str(_pair_lower), str(_pair_upper)])
	print("[TEST] 玩家起始 y = %.1f（下层地面 = %.1f）" % [_start_y, floor_y])
	return true


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


func _report() -> void:
	# 必须爬过一个房间的高度（留点余量：至少 150px）
	var needed: float = ROOM_H * 0.7

	var checks: Array = [
		["本层有垂直相邻房间", _found_pair],
		["玩家能向上攀爬（%.0f px）" % _climbed, _climbed >= needed],
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
	print("[TEST] 攀升高度: %.0f px（需要 >= %.0f）" % [_climbed, needed])
	print("[TEST] 结果: %d / %d 通过" % [passed, checks.size()])
	if passed == checks.size():
		print("[TEST] ★ 垂直通道可攀爬 —— 单向平台生效")
	else:
		print("[TEST] ✗ 爬不上去 —— 检查台阶是否为单向碰撞、间距是否超过跳跃高度")
	print("[TEST] =======================================")
	quit(0 if passed == checks.size() else 1)
