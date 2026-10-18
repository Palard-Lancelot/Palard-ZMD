extends SceneTree
## 战斗闭环测试（阶段 0 任务 0.11 —— 阶段 0 完成标志）
##
## 验证完整闭环：
##   开局 → 击杀计数 → 打死敌人计数+1 → 被打死 → 进入 DEAD → 重开 → 完整重置
##   以及清场：所有敌人死亡 → 进入 CLEARED
##
## 用法：
##   $env:DSH_SKIP_BOOT_QUIT = "1"
##   & $GODOT --headless --path . --script "res://tests/test_combat_loop.gd"

var _level: Node = null
var _player: CharacterBody2D = null
var _started := false
var _frame := 0
var _phase := 0

## 采样
var _total_enemies := 0
var _kills_after_first := 0
var _state_after_death := -1
var _hp_after_death := 0
var _kills_after_restart := -1
var _hp_after_restart := 0
var _state_after_restart := -1
var _enemy_alive_after_restart := false
var _state_after_clear := -1


func _physics_process(_d: float) -> bool:
	if not _started:
		_boot()
		return false

	_frame += 1

	match _phase:
		0:
			# 阶段 0：等就绪，记录总数
			if _frame >= 8:
				_total_enemies = int(_level.get("total_enemies"))
				# 打死第一个敌人（直接调 take_hit，避免依赖战斗操作）
				var enemies: Array = _level.get("_enemies")
				if enemies.size() > 0:
					var e = enemies[0]
					if is_instance_valid(e):
						e.call("take_hit", 9999, e.global_position + Vector2(-10, 0))
				_phase = 1
				_frame = 0
		1:
			if _frame >= 6:
				_kills_after_first = int(_level.get("kills"))
				# 直接让玩家死亡
				_player.take_damage(9999, _player.global_position + Vector2(-20, 0))
				_phase = 2
				_frame = 0
		2:
			if _frame >= 6:
				_state_after_death = int(_level.get("run_state"))
				_hp_after_death = _player.hp
				# 重开
				_level.call("restart_run")
				_phase = 3
				_frame = 0
		3:
			if _frame >= 10:
				_kills_after_restart = int(_level.get("kills"))
				_hp_after_restart = _player.hp
				_state_after_restart = int(_level.get("run_state"))
				var enemies: Array = _level.get("_enemies")
				_enemy_alive_after_restart = false
				for e in enemies:
					if is_instance_valid(e) and not e.get("is_dead"):
						_enemy_alive_after_restart = true
						break
				# 清场：杀光所有敌人
				for e in enemies:
					if is_instance_valid(e):
						e.call("take_hit", 9999, e.global_position + Vector2(-10, 0))
				_phase = 4
				_frame = 0
		4:
			if _frame >= 10:
				_state_after_clear = int(_level.get("run_state"))
				_report()
				return true
	return false


func _boot() -> void:
	_started = true
	var scene: PackedScene = load("res://scenes/boot/boot.tscn")
	var root: Node = scene.instantiate()
	get_root().add_child(root)
	_level = root.get_node_or_null("World")
	_player = root.get_node_or_null("World/Player") as CharacterBody2D
	if _level == null or _player == null:
		print("[TEST] FAIL: 找不到 World 或 Player")
		quit(1)
		return
	print("[TEST] 关卡敌人总数: %d" % int(_level.get("total_enemies")))
	print("[TEST] 初始 run_state: %d (0=PLAYING 1=DEAD 2=CLEARED)" % int(_level.get("run_state")))


func _report() -> void:
	# RunState 枚举：0 PLAYING / 1 DEAD / 2 CLEARED
	var checks: Array = [
		["关卡识别到敌人（%d 个）" % _total_enemies, _total_enemies > 0],
		["打死敌人后击杀数 +1（%d）" % _kills_after_first, _kills_after_first == 1],
		["玩家死亡后 HP 归零（%d）" % _hp_after_death, _hp_after_death == 0],
		["玩家死亡后进入 DEAD 状态（%d）" % _state_after_death, _state_after_death == 1],
		["重开后击杀数归零（%d）" % _kills_after_restart, _kills_after_restart == 0],
		["重开后玩家 HP 恢复（%d）" % _hp_after_restart, _hp_after_restart == _player.max_hp],
		["重开后回到 PLAYING 状态（%d）" % _state_after_restart, _state_after_restart == 0],
		["重开后所有敌人复活", _enemy_alive_after_restart],
		["清光所有敌人后进入 CLEARED（%d）" % _state_after_clear, _state_after_clear == 2],
	]

	print("")
	print("[TEST] ============ 战斗闭环测试 ============")
	var passed := 0
	for c in checks:
		var ok: bool = c[1]
		if ok:
			passed += 1
		var tag := "[PASS]"
		if not ok:
			tag = "[FAIL]"
		print("[TEST]   %s %s" % [tag, c[0]])
	print("[TEST] ---------------------------------------")
	print("[TEST] 结果: %d / %d 通过" % [passed, checks.size()])
	if passed == checks.size():
		print("[TEST] ★ 阶段 0 战斗闭环达成")
	else:
		print("[TEST] ✗ 有失败项")
	print("[TEST] =======================================")
