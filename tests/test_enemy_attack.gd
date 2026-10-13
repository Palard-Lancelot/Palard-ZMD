extends SceneTree
## 敌人攻击集成测试（阶段 0 任务 0.9 / 0.10）
##
## 背景：曾出现"敌人不会攻击玩家"的问题，根因是**碰撞检测的双向匹配**
## 没有配置正确 —— 攻击盒的 mask 里没有玩家受击盒所在的层，
## 导致 area_entered 永远不触发。单元测试测不到这个，
## 因为它只验证 take_damage() 本身，而不是"信号能否送达"。
##
## 本测试做真正的集成验证：把玩家放到会还手的假人旁边，
## 等待假人走完「冷却 → 前摇 → 有效帧」的完整循环，断言玩家确实掉血。
##
## 断言：
##   1. 假人在前摇时确实有 telegraph（支柱2 要求：伤害必须可预判）
##   2. 玩家在假人攻击范围内会掉血
##   3. 掉血发生在首次前摇之后（说明走的是完整攻击循环）
##   4. 全程掉血次数合理（受击无敌帧应限制连击频率）
##
## 用法：
##   $env:DSH_SKIP_BOOT_QUIT = "1"
##   & $GODOT --headless --path . --script "res://tests/test_enemy_attack.gd"

const TOTAL_FRAMES := 300
const MELEE_DISTANCE := 22.0

var _player: CharacterBody2D = null
var _dummy: Node2D = null
var _started := false
var _frame := 0

var _hp_start := 0
var _hp_min := 9999
var _telegraph_seen := false
var _first_hit_frame := -1
var _first_telegraph_frame := -1
var _hit_count := 0
var _last_hp := 0


func _physics_process(_d: float) -> bool:
	if not _started:
		_boot()
		return false

	_frame += 1

	# 观察假人前摇
	if _dummy.call("is_telegraphing"):
		_telegraph_seen = true
		if _first_telegraph_frame < 0:
			_first_telegraph_frame = _frame

	# 观察玩家掉血
	var hp: int = _player.hp
	if hp < _last_hp:
		_hit_count += 1
		if _first_hit_frame < 0:
			_first_hit_frame = _frame
	_last_hp = hp
	_hp_min = mini(_hp_min, hp)

	if _frame >= TOTAL_FRAMES:
		_report()
		return true
	return false


func _boot() -> void:
	_started = true
	var scene: PackedScene = load("res://scenes/boot/boot.tscn")
	var root: Node = scene.instantiate()
	get_root().add_child(root)

	_player = root.get_node_or_null("World/Player") as CharacterBody2D
	_dummy = root.get_node_or_null("World/HostileDummy") as Node2D
	if _player == null or _dummy == null:
		print("[TEST] FAIL: 找不到 Player 或 HostileDummy")
		quit(1)
		return

	# 站在会还手的假人左边，保持正常近战距离
	_player.position = Vector2(_dummy.position.x - MELEE_DISTANCE, _dummy.position.y)
	_player.velocity = Vector2.ZERO

	_hp_start = _player.hp
	_last_hp = _player.hp

	print("[TEST] 玩家: %s  假人: %s  间距: %.0fpx" % [
		str(_player.position), str(_dummy.position), MELEE_DISTANCE])
	print("[TEST] 假人是否 hostile: %s" % str(_dummy.get("hostile")))


func _report() -> void:
	var damage_taken: int = _hp_start - _hp_min

	var checks: Array = [
		["假人有攻击前摇（可预判）", _telegraph_seen],
		["玩家在攻击范围内掉血（-%d HP）" % damage_taken, damage_taken > 0],
		["掉血发生在前摇之后",
			_first_hit_frame > 0 and _first_telegraph_frame > 0
			and _first_hit_frame >= _first_telegraph_frame],
		["受击无敌帧限制了连击频率（共受击 %d 次 / 300 帧）" % _hit_count,
			_hit_count >= 1 and _hit_count <= 6],
	]

	print("")
	print("[TEST] ========== 敌人攻击集成测试 ==========")
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
	print("[TEST] HP: %d → %d（最低）" % [_hp_start, _hp_min])
	print("[TEST] 首次前摇帧: %d   首次受击帧: %d" % [_first_telegraph_frame, _first_hit_frame])
	print("[TEST] 结果: %d / %d 通过" % [passed, checks.size()])
	if passed == checks.size():
		print("[TEST] ★ 全部通过")
	else:
		print("[TEST] ✗ 有失败项")
	print("[TEST] =======================================")
