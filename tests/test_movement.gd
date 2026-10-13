extends SceneTree
## 移动物理回归测试（阶段 0 任务 0.5）
##
## 用途：不开窗口，自动验证「走 / 跳 / 落」的物理正确性。
## 每次改动 player.gd 或 feel_config.gd 后都应该跑一遍。
##
## 用法：
##   $env:DSH_SKIP_BOOT_QUIT = "1"
##   & $GODOT --headless --path . --script "res://tests/test_movement.gd"
##
## ⚠️ 必须设置 DSH_SKIP_BOOT_QUIT=1，否则 boot.gd 的 headless 自检会提前退出整个 SceneTree。

const GROUND_TOP := 14.0          ## 测试场景地面顶部的全局 y
const CLEAR_COLUMN_X := 330.0     ## 无天花板 / 无平台的空旷列
const EPSILON_Y := 2.0

const CASE_COUNT := 3

var _player: CharacterBody2D = null
var _started := false
var _case := 0
var _frame := 0
var _min_y := 0.0
var _max_y := 0.0
var _landed_frame := -1
var _results: Array = []
var _peak_vx: float = 0.0        ## 全程记录的水平速度峰值
var _run_start_x: float = 0.0    ## 开始向右输入那一帧的 x（位移从这里量起）


func _physics_process(_d: float) -> bool:
	if not _started:
		_boot()
		return false

	_frame += 1
	_min_y = minf(_min_y, _player.position.y)
	_max_y = maxf(_max_y, _player.position.y)
	# 记录水平速度峰值：不能只看终帧 —— 玩家可能已撞墙导致速度为 0
	_peak_vx = maxf(_peak_vx, absf(_player.velocity.x))
	if _player.is_on_floor() and _landed_frame < 0:
		_landed_frame = _frame

	_apply_input()

	var total := _total_frames()
	if _frame >= total:
		_finish_case()
		_case += 1
		if _case >= CASE_COUNT:
			_report()
			return true
		_begin_case()
	return false


# ============================================================
# 用例定义
# ============================================================

func _total_frames() -> int:
	match _case:
		0: return 70    # 自由落体（约 42 帧落地 + 余量）
		1: return 70    # 原地跳跃：滞空 0.75s = 45 帧，从第 8 帧起跳 → 需 ~55 帧落地
		2: return 45    # 向右跑：0.1s 到全速，45 帧内不会撞到右墙（x=492）
	return 30


func _begin_case() -> void:
	_frame = 0
	_landed_frame = -1
	_peak_vx = 0.0
	_run_start_x = 0.0
	Input.action_release("move_right")
	Input.action_release("move_left")
	Input.action_release("jump")

	match _case:
		0:
			_player.position = Vector2(CLEAR_COLUMN_X, -150)
			_player.velocity = Vector2.ZERO
		1:
			_player.position = Vector2(CLEAR_COLUMN_X, GROUND_TOP)
			_player.velocity = Vector2.ZERO
		2:
			_player.position = Vector2(CLEAR_COLUMN_X, GROUND_TOP)
			_player.velocity = Vector2.ZERO

	_min_y = _player.position.y
	_max_y = _player.position.y


func _apply_input() -> void:
	match _case:
		1:
			# 第 8 帧起按住跳跃（留出落地稳定的时间）
			if _frame >= 8:
				if not Input.is_action_pressed("jump"):
					Input.action_press("jump")
		2:
			if _frame >= 8:
				Input.action_press("move_right")
				if _run_start_x == 0.0:
					_run_start_x = _player.position.x


func _finish_case() -> void:
	Input.action_release("move_right")
	Input.action_release("move_left")
	Input.action_release("jump")

	var name := ""
	var checks: Array = []

	match _case:
		0:
			name = "自由落体停在地面"
			checks = [
				["落地检测", _landed_frame > 0],
				["停在地面 y≈%.0f（实测 %.1f）" % [GROUND_TOP, _player.position.y],
					absf(_player.position.y - GROUND_TOP) < EPSILON_Y],
				["垂直静止", absf(_player.velocity.y) < 1.0],
			]
		1:
			name = "跳跃高度符合配置（目标 48px）"
			var peak: float = GROUND_TOP - _min_y
			checks = [
				["跳跃发生（峰值 %.1fpx > 5）" % peak, peak > 5.0],
				["峰值在 36–60px 之间（±25%）", peak > 36.0 and peak < 60.0],
				["落回地面", absf(_player.position.y - GROUND_TOP) < EPSILON_Y],
			]
		2:
			name = "向右移动达到最大速度"
			var moved: float = _player.position.x - _run_start_x
			checks = [
				["向右位移 %.1fpx（自开始输入起算）" % moved, moved > 40.0],
				["速度峰值达上限 165（实测 %.1f）" % _peak_vx,
					absf(_peak_vx - 165.0) < 8.0],
			]

	_results.append({"name": name, "checks": checks})


# ============================================================
# 启动 / 报告
# ============================================================

func _boot() -> void:
	_started = true
	var scene: PackedScene = load("res://scenes/boot/boot.tscn")
	var root: Node = scene.instantiate()
	get_root().add_child(root)
	_player = root.get_node_or_null("World/Player")
	if _player == null:
		print("[TEST] FAIL: 找不到 World/Player")
		quit(1)
		return
	_begin_case()


func _report() -> void:
	print("")
	print("[TEST] ============== 移动物理回归测试 ==============")
	var total := 0
	var passed := 0
	for r in _results:
		print("[TEST] %s" % r["name"])
		for c in r["checks"]:
			total += 1
			var ok: bool = c[1]
			if ok:
				passed += 1
			var tag := "[PASS]"
			if not ok:
				tag = "[FAIL]"
			print("[TEST]   %s %s" % [tag, c[0]])
	print("[TEST] -----------------------------------------------")
	print("[TEST] 结果: %d / %d 通过" % [passed, total])
	if passed == total and total > 0:
		print("[TEST] ★ 全部通过")
	else:
		print("[TEST] ✗ 有失败项")
	print("[TEST] ===============================================")
