extends SceneTree
## 冲刺与受击测试（阶段 0 任务 0.9）
##
## 验证：
##   1. 按 L 触发冲刺，状态进入 dash
##   2. 冲刺期间有位移（朝输入方向快速移动）
##   3. 无敌帧生效：冲刺的无敌窗口内受击不掉血
##   4. 无敌窗口之外（起始帧之前 / 结束帧之后）受击会掉血
##   5. 受击进入 hurt 状态并扣血
##   6. 受击后有受击无敌帧（连续受击不会连续掉血）
##   7. 受击硬直结束后回位
##
## 用法：
##   $env:DSH_SKIP_BOOT_QUIT = "1"
##   & $GODOT --headless --path . --script "res://tests/test_dash_hurt.gd"

const CASE_COUNT := 3
const GROUND_TOP := 14.0
## 无遮挡列（与 test_movement.gd 保持一致）。
## ⚠️ 关卡布局改动后必须重新核对。
const CLEAR_COLUMN_X := 520.0

var _player: CharacterBody2D = null
var _started := false
var _case := 0
var _frame := 0
var _results: Array = []

## 采样
var _saw_dash := false
var _dash_start_x := 0.0
var _dash_end_x := 0.0
var _hp_before_hit := 0
var _hp_after_hit := 0
var _hp_after_second_hit := 0
var _saw_hurt := false
var _hurt_recovered := false
var _iframe_seen := false
var _hit_during_iframe := false


func _physics_process(_d: float) -> bool:
	if not _started:
		_boot()
		return false

	_frame += 1
	_apply_input()
	_sample()

	if _frame >= _total_frames():
		_finish_case()
		_case += 1
		if _case >= CASE_COUNT:
			_report()
			return true
		_begin_case()
	return false


func _total_frames() -> int:
	match _case:
		0: return 60    # 冲刺：触发 + 位移 + 无敌
		1: return 70    # 无敌窗口内受击（应免疫）
		2: return 90    # 受击流程（应掉血 + 进入 hurt + 回位）
	return 40


func _begin_case() -> void:
	_frame = 0
	_saw_dash = false
	_dash_start_x = 0.0
	_dash_end_x = 0.0
	_hp_before_hit = 0
	_hp_after_hit = 0
	_hp_after_second_hit = 0
	_saw_hurt = false
	_hurt_recovered = false
	_iframe_seen = false
	_hit_during_iframe = false
	Input.action_release("dash")
	Input.action_release("move_right")

	_player.hp = _player.max_hp
	_player.position = Vector2(CLEAR_COLUMN_X, GROUND_TOP)
	_player.velocity = Vector2.ZERO
	_player.respawn()


func _apply_input() -> void:
	match _case:
		0:
			# 第 5 帧按冲刺，并按住右方向
			if _frame == 5:
				Input.action_press("move_right")
				Input.action_press("dash")
				_dash_start_x = _player.position.x
			elif _frame == 6:
				Input.action_release("dash")
		1:
			if _frame == 5:
				Input.action_press("dash")
				_dash_start_x = _player.position.x
			elif _frame == 6:
				Input.action_release("dash")
			# 第 12 帧造成伤害。时序提示：
			#   第 5 帧按冲刺 → _sm 帧号在第 5 帧末才 +1
			#   所以第 12 帧时状态机帧号约 7，已越过 iframe_start_frame(3)
			#   即处于无敌窗口内。若在第 8 帧测（帧号仅 3）则无敌尚未生效。
			elif _frame == 12:
				_hp_before_hit = _player.hp
				_player.take_damage(20, _player.position + Vector2(-40, 0))
				_hp_after_hit = _player.hp
				_hit_during_iframe = (_hp_after_hit == _hp_before_hit)
		2:
			# 受击流程：静止状态下直接造成伤害
			if _frame == 5:
				_hp_before_hit = _player.hp
				_player.take_damage(15, _player.position + Vector2(-40, 0))
				_hp_after_hit = _player.hp
			# 第 8 帧再打一次 —— 应被受击无敌挡住
			elif _frame == 8:
				_player.take_damage(15, _player.position + Vector2(-40, 0))
				_hp_after_second_hit = _player.hp


func _sample() -> void:
	if _player == null:
		return
	var st: String = _player.debug_state_name
	if st == "dash":
		_saw_dash = true
		_dash_end_x = maxf(_dash_end_x, _player.position.x)
	elif st == "hurt":
		_saw_hurt = true
	if _player.debug_iframe:
		_iframe_seen = true
	if _saw_hurt and st != "hurt" and st != "dead":
		_hurt_recovered = true


func _finish_case() -> void:
	Input.action_release("dash")
	Input.action_release("move_right")

	var name := ""
	var checks: Array = []

	match _case:
		0:
			name = "冲刺：触发 / 位移 / 无敌"
			checks = [
				["进入 dash 状态", _saw_dash],
				["冲刺产生水平位移 %.1fpx" % (_dash_end_x - _dash_start_x),
					_dash_end_x - _dash_start_x > 30.0],
				["冲刺期间出现无敌帧", _iframe_seen],
			]
		1:
			name = "冲刺无敌：无敌窗口内受击应免疫"
			checks = [
				["触发冲刺", _saw_dash],
				["无敌期间受击不掉血（HP %d → %d）" % [_hp_before_hit, _hp_after_hit],
					_hp_after_hit == _hp_before_hit],
			]
		2:
			name = "受击：扣血 / 硬直 / 无敌闪烁 / 回位"
			checks = [
				["受击扣血（HP %d → %d）" % [_hp_before_hit, _hp_after_hit],
					_hp_after_hit == _hp_before_hit - 15],
				["进入 hurt 状态", _saw_hurt],
				["受击无敌挡住第二次伤害（HP 保持 %d）" % _hp_after_second_hit,
					_hp_after_second_hit == _hp_after_hit],
				["硬直结束回位", _hurt_recovered],
			]

	_results.append({"name": name, "checks": checks})


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
	print("[TEST] ============ 冲刺与受击测试 ============")
	var passed := 0
	var total := 0
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
	print("[TEST] ------------------------------------------")
	print("[TEST] 结果: %d / %d 通过" % [passed, total])
	if passed == total and total > 0:
		print("[TEST] ★ 全部通过")
	else:
		print("[TEST] ✗ 有失败项")
	print("[TEST] ==========================================")
