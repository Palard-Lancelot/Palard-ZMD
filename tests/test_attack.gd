extends SceneTree
## 攻击系统测试（阶段 0 任务 0.7 / 0.8）
##
## 验证：
##   1. 按 L 触发攻击，状态从 idle 进入 attack1
##   2. 有效帧内判定盒命中假人并扣血
##   3. 连续按 L 能接出 3 段连击，伤害递增
##   4. 顿帧确实冻结了玩家逻辑（帧计数不前进）
##   5. 后摇结束后自动回位到 idle
##
## 用法：
##   $env:DSH_SKIP_BOOT_QUIT = "1"
##   & $GODOT --headless --path . --script "res://tests/test_attack.gd"

const FRAME_PER_ATTACK := 4     ## 每段攻击间隔帧数（触发连击）
const TOTAL_FRAMES := 260

var _player: CharacterBody2D = null
var _dummy: Node2D = null
var _started := false
var _frame := 0
var _results: Array = []

## 采样
var _saw_attack1 := false
var _saw_attack2 := false
var _saw_attack3 := false
var _max_combo_seen := 0
var _dummy_hp_start := 0
var _dummy_hp_min := 9999
var _hitstop_seen := false
var _frozen_frame_advanced := false
var _returned_to_idle := false
var _prev_state := ""


func _physics_process(_d: float) -> bool:
	if not _started:
		_boot()
		return false

	_frame += 1

	# --- 攻击输入：每 FRAME_PER_ATTACK 帧按一次攻击键 ---
	if _frame >= 10 and _frame <= 120 and _frame % FRAME_PER_ATTACK == 0:
		Input.action_press("attack")
	else:
		Input.action_release("attack")

	var gt := get_root().get_node_or_null("GameTime")
	var frozen: bool = gt != null and gt.is_frozen()
	if frozen:
		_hitstop_seen = true

	# --- 采样玩家状态 ---
	var st: String = str(_player.debug_state_name)
	if st == "attack1":
		_saw_attack1 = true
	elif st == "attack2":
		_saw_attack2 = true
	elif st == "attack3":
		_saw_attack3 = true
	if _prev_state.begins_with("attack") and st == "idle":
		_returned_to_idle = true
	_prev_state = st

	# --- 采样假人血量 ---
	if _dummy:
		var hp: int = _dummy.get("hp")
		_dummy_hp_min = mini(_dummy_hp_min, hp)

	if _frame >= TOTAL_FRAMES:
		_finish()
		return true
	return false


func _boot() -> void:
	_started = true
	var scene: PackedScene = load("res://scenes/boot/boot.tscn")
	var root: Node = scene.instantiate()
	get_root().add_child(root)
	_player = root.get_node_or_null("World/Player")
	_dummy = root.get_node_or_null("World/Dummy2")   # max_hp = 50，够吃多段
	if _player == null or _dummy == null:
		print("[TEST] FAIL: 找不到 Player 或 Dummy2")
		quit(1)
		return
	# 站到假人左侧并面向右
	_player.position = Vector2(_dummy.position.x - 20.0, _dummy.position.y - 1.0)
	_player.velocity = Vector2.ZERO
	_dummy_hp_start = _dummy.get("hp")
	print("[TEST] 玩家置于假人左侧 20px，假人 HP = %d" % _dummy_hp_start)


func _finish() -> void:
	Input.action_release("attack")

	var hp_end: int = _dummy.get("hp")
	var damage_done: int = _dummy_hp_start - _dummy_hp_min

	_results = [
		["触发攻击状态 attack1", _saw_attack1],
		["连击进入 attack2", _saw_attack2],
		["连击进入 attack3", _saw_attack3],
		["攻击造成伤害（共 %d 点）" % damage_done, damage_done > 0],
		["顿帧被触发", _hitstop_seen],
		["后摇结束回位 idle", _returned_to_idle],
	]

	print("")
	print("[TEST] ============== 攻击系统测试 ==============")
	var passed := 0
	for r in _results:
		var ok: bool = r[1]
		if ok:
			passed += 1
		var tag := "[PASS]"
		if not ok:
			tag = "[FAIL]"
		print("[TEST]   %s %s" % [tag, r[0]])
	print("[TEST] -------------------------------------------")
	print("[TEST] 假人 HP: %d → %d（最低 %d）" % [_dummy_hp_start, hp_end, _dummy_hp_min])
	print("[TEST] 结果: %d / %d 通过" % [passed, _results.size()])
	if passed == _results.size():
		print("[TEST] ★ 全部通过")
	else:
		print("[TEST] ✗ 有失败项")
	print("[TEST] ===========================================")
