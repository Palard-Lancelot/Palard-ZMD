extends SceneTree
## 单向平台下穿测试（DESIGN v1.3：S + Space）
##
## 验证四件事：
##   1. 玩家能站在单向平台上
##   2. **只**按 Space → 正常起跳（下穿逻辑不能把跳跃吃掉）
##   3. S + Space → 真的从单向平台落下去
##   4. 站在**实心**地板上 S + Space → **不**穿透（下穿只对 one_way 生效）
##
## 为什么自己搭最小场景，而不是用现有关卡：
##   这个套件测的是**玩家逻辑**，不是关卡布局。挂在关卡上会让它随
##   布局调整反复碎掉（本项目已经吃过「测试假设了布局」的亏，
##   见 test_generated_level.gd 头部记录）。
##
## 用法：
##   $env:DSH_SKIP_BOOT_QUIT = "1"
##   & $GODOT --headless --path . --script "res://tests/test_drop_through.gd"

const FeelConfigScript := preload("res://scripts/config/feel_config.gd")
const PlayerScene := preload("res://scenes/player/player.tscn")

const X := 300.0
const PLAT_SURFACE := 120.0     ## 单向平台上表面的 y
const PLAT_W := 140.0
const PLAT_H := 10.0
const GROUND_SURFACE := 400.0   ## 实心地板上表面的 y

const WARMUP := 12              ## 等玩家落稳
const ACT_FRAME := 15           ## 按键帧
const CASE_FRAMES := 70         ## 单例总帧数

var _root: Node2D = null
var _player: CharacterBody2D = null
var _started := false

var _case := 0
var _frame := 0
var _results: Array = []

## 采样
var _on_floor_start := false
var _min_y := 99999.0
var _end_y := 0.0
var _dropping_seen := false


func _physics_process(_d: float) -> bool:
	if not _started:
		_boot()
		return false

	_frame += 1
	_apply_input()

	if _frame == WARMUP and _player:
		_on_floor_start = _player.is_on_floor()
	if _player and _player.has_method("is_dropping_through"):
		if _player.is_dropping_through():
			_dropping_seen = true
	if _player:
		_min_y = minf(_min_y, _player.position.y)

	if _frame >= CASE_FRAMES:
		_end_y = _player.position.y
		_finish_case()
		_case += 1
		if _case >= 3:
			_report()
			return true
		_begin_case()
	return false


func _apply_input() -> void:
	if _frame == ACT_FRAME:
		match _case:
			0:
				# 只按跳跃：应正常起跳
				Input.action_press("jump")
			_:
				# S + Space：应下穿（实心地板上则无效）
				Input.action_press("move_down")
				Input.action_press("jump")
	elif _frame == ACT_FRAME + 12:
		# 长按到顶点：可变跳跃高度会在松手时截断上升
		Input.action_release("jump")
		Input.action_release("move_down")


func _begin_case() -> void:
	_frame = 0
	_on_floor_start = false
	_min_y = 99999.0
	_end_y = 0.0
	_dropping_seen = false

	for act in ["jump", "move_up", "move_down", "attack", "dash", "move_left", "move_right"]:
		Input.action_release(act)

	if _player.has_method("respawn"):
		_player.respawn()
	_player.position = Vector2(X, _surface() - 1.0)
	_player.velocity = Vector2.ZERO
	_player.set_physics_process(true)


func _surface() -> float:
	return PLAT_SURFACE if _case < 2 else GROUND_SURFACE


func _finish_case() -> void:
	var surface: float = _surface()
	var case_name := ""
	var checks: Array = []

	match _case:
		0:
			case_name = "单向平台 · 只按 Space 应正常起跳"
			checks = [
				["站在单向平台上（is_on_floor）", _on_floor_start],
				["起跳高度 %.0f px（> 25）" % (surface - _min_y), _min_y < surface - 25.0],
			]
		1:
			case_name = "单向平台 · S+Space 应下穿"
			checks = [
				["触发下穿状态", _dropping_seen],
				["落到平台下方 %.0f px（> 40）" % (_end_y - surface), _end_y > surface + 40.0],
			]
		_:
			case_name = "实心地板 · S+Space 不应穿透"
			checks = [
				["没有穿下去（落点 y=%.0f，地面 %.0f）" % [_end_y, surface],
					_end_y <= surface + 3.0],
				["仍能正常起跳（%.0f px）" % (surface - _min_y), _min_y < surface - 25.0],
			]

	_results.append({"name": case_name, "checks": checks})


func _boot() -> void:
	_started = true

	_root = Node2D.new()
	_root.name = "DropTestRoot"
	get_root().add_child(_root)

	# 实心地板（宽一点，防止玩家走出边缘）
	_root.add_child(_make_platform(GROUND_SURFACE, PLAT_W * 2.0, false))
	# 单向平台
	_root.add_child(_make_platform(PLAT_SURFACE, PLAT_W, true))

	var feel: Resource = FeelConfigScript.new()
	_player = PlayerScene.instantiate() as CharacterBody2D
	if _player == null:
		print("[TEST] FAIL: 无法实例化 player.tscn")
		quit(1)
		return
	_root.add_child(_player)
	_player.setup(feel)

	_begin_case()


## 造一块地板。surface_y = **上表面**的 y
func _make_platform(surface_y: float, width: float, one_way: bool) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = Vector2(X, surface_y + PLAT_H * 0.5)

	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(width, PLAT_H)
	shape.shape = rect
	if one_way:
		shape.one_way_collision = true
	body.add_child(shape)

	return body


func _report() -> void:
	print("")
	print("[TEST] ========== 单向平台下穿测试 ==========")
	var passed := 0
	var total := 0
	for r in _results:
		print("[TEST] %s" % r["name"])
		for c in r["checks"]:
			total += 1
			var ok: bool = c[1]
			if ok:
				passed += 1
			print("[TEST]   %s %s" % ["[PASS]" if ok else "[FAIL]", c[0]])

	print("[TEST] ----------------------------------------")
	print("[TEST] 结果: %d / %d 通过" % [passed, total])
	if passed == total and total > 0:
		print("[TEST] ★ S+Space 只在单向平台上生效，跳跃未被影响")
	else:
		print("[TEST] ✗ 有失败项 —— 检查 player.gd 的 _handle_drop_through_input")
	print("[TEST] ========================================")
	quit(0 if passed == total and total > 0 else 1)
