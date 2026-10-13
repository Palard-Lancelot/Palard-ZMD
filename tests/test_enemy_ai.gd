extends SceneTree
## 冲锋兵 AI 测试（阶段 0 任务 0.10）
##
## 验证第一种真正的敌人 AI：
##   1. 玩家在感知范围内 → 从 idle 进入 chase（**主动追击**）
##   2. 追击过程中与玩家的距离缩小
##   3. 接近到攻击距离 → 进入 windup（前摇，支柱2 硬要求）
##   4. 走完前摇 → 进入 attack 并开启攻击盒
##   5. 玩家最终确实掉血
##   6. 玩家离开感知范围 → 回到 idle
##
## 用法：
##   $env:DSH_SKIP_BOOT_QUIT = "1"
##   & $GODOT --headless --path . --script "res://tests/test_enemy_ai.gd"

const TOTAL_FRAMES := 420

var _player: CharacterBody2D = null
var _rusher: CharacterBody2D = null
var _started := false
var _frame := 0

var _saw_chase := false
var _saw_windup := false
var _saw_attack := false
var _dist_start := 0.0
var _dist_min := 99999.0
var _hp_start := 0
var _hp_min := 9999
var _first_windup_frame := -1
var _windup_frames_observed := 0

## 逃跑场景采样
var _flee_dist_start := 0.0
var _flee_dist_after := 0.0
var _flee_max_dist := 0.0


func _physics_process(_d: float) -> bool:
	if not _started:
		_boot()
		return false

	_frame += 1

	if _rusher == null or not is_instance_valid(_rusher):
		_report()
		return true

	var st: String = str(_rusher.get("debug_state"))
	match st:
		"chase":
			_saw_chase = true
		"windup":
			_saw_windup = true
			_windup_frames_observed += 1
			if _first_windup_frame < 0:
				_first_windup_frame = _frame
		"attack":
			_saw_attack = true

	var dist: float = absf(_player.global_position.x - _rusher.global_position.x)
	_dist_min = minf(_dist_min, dist)

	var hp: int = _player.hp
	_hp_min = mini(_hp_min, hp)

	# ---- 第 240 帧起：要求玩家持续逃离，验证追击速度足够 ----
	if _frame == 240:
		# 把玩家放回敌人右侧，并初始化逃跑采样
		_player.position = Vector2(_rusher.position.x + 60.0, _rusher.position.y)
		_player.velocity = Vector2.ZERO
		_flee_dist_start = 60.0
		_flee_max_dist = 60.0

	if _frame > 240 and _frame <= 340:
		Input.action_press("move_left")
		_flee_max_dist = maxf(_flee_max_dist, dist)
		if _frame == 340:
			Input.action_release("move_left")
			_flee_dist_after = dist

	if _frame >= TOTAL_FRAMES:
		Input.action_release("move_left")
		_report()
		return true
	return false


func _boot() -> void:
	_started = true
	var scene: PackedScene = load("res://scenes/boot/boot.tscn")
	var root: Node = scene.instantiate()
	get_root().add_child(root)

	_player = root.get_node_or_null("World/Player") as CharacterBody2D
	_rusher = root.get_node_or_null("World/Rusher1") as CharacterBody2D
	if _player == null or _rusher == null:
		print("[TEST] FAIL: 找不到 Player 或 Rusher1")
		quit(1)
		return

	# 关键：玩家放在敌人感知范围内，但**超出攻击距离** ——
	# 这样才能验证"主动追击"而不是"站着就能打到"
	var detect: float = float(_rusher.get("detect_range"))
	var attack: float = float(_rusher.get("attack_range"))
	var start_dist: float = (detect + attack) * 0.5

	_player.position = Vector2(_rusher.position.x + start_dist, _rusher.position.y)
	_player.velocity = Vector2.ZERO
	_dist_start = start_dist

	_hp_start = _player.hp
	_hp_min = _player.hp

	print("[TEST] 假人感知范围: %.0f  攻击距离: %.0f" % [detect, attack])
	print("[TEST] 初始距离: %.0fpx（在感知内、攻击外）" % start_dist)


func _report() -> void:
	var dist_closed: float = _dist_start - _dist_min
	var damage: int = _hp_start - _hp_min

	var checks: Array = [
		["进入 chase 状态（主动追击）", _saw_chase],
		["追击缩短了距离 %.0fpx" % dist_closed, dist_closed > 20.0],
		["进入 windup（前摇可预判）", _saw_windup],
		["前摇持续 >= 10 帧（支柱2 要求）", _windup_frames_observed >= 10],
		["进入 attack 状态", _saw_attack],
		["玩家最终掉血（-%d HP）" % damage, damage > 0],
		# ⚠️ 回归守卫：曾出现"敌人追不上逃跑的玩家"——
		#    敌人速度 78 对玩家 165，玩家一动就永远拉开距离，
		#    体感是"敌人不追击"。这里断言逃跑时距离不能失控增长。
		["玩家持续逃跑时距离未失控（60 → 最大 %.0f px）" % _flee_max_dist,
			_flee_max_dist < 260.0],
		["逃跑 100 帧后距离未持续拉大（%.0f px）" % _flee_dist_after,
			_flee_dist_after < 260.0],
	]

	print("")
	print("[TEST] ============== 冲锋兵 AI 测试 ==============")
	var passed := 0
	for c in checks:
		var ok: bool = c[1]
		if ok:
			passed += 1
		var tag := "[PASS]"
		if not ok:
			tag = "[FAIL]"
		print("[TEST]   %s %s" % [tag, c[0]])
	print("[TEST] -------------------------------------------")
	print("[TEST] 距离: %.0f → 最近 %.0f" % [_dist_start, _dist_min])
	print("[TEST] HP: %d → %d（最低）" % [_hp_start, _hp_min])
	print("[TEST] 首次前摇帧: %d" % _first_windup_frame)
	print("[TEST] 逃跑测试: 起始 %.0f → 最大 %.0f → 结束 %.0f" % [
		_flee_dist_start, _flee_max_dist, _flee_dist_after])
	print("[TEST] 结果: %d / %d 通过" % [passed, checks.size()])
	if passed == checks.size():
		print("[TEST] ★ 全部通过")
	else:
		print("[TEST] ✗ 有失败项")
	print("[TEST] ===========================================")
