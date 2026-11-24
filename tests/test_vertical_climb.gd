extends SceneTree
## 垂直攀爬测试（v1.5 阶梯改造后重写）
##
## ⚠️ 为什么重写：v1.5 起竖井**不再是洞里的一条等距竖梯**，
## 而是「房间内一条斜向阶梯 + 洞内一块发射台」（对标手写层 PlatformA→B→C）。
## 老的测法（站在井口按住跳一路往上顶）对新结构无效 ——
## 新结构要走位：每一级都要横移一个 dx。
##
## 新测法：**逐跳验证**。对每一跳单独摆好站位、起跳，断言"落在下一级上"：
##   地面 → 阶梯1 → 阶梯2 → 阶梯3 → 阶梯4 → 发射台 → 上层房间
## 一共 6 跳 × 每组垂直通道。
##
## 判据仍然是**最终状态**（`is_on_floor()` 且站在预期的那个平台 / 上层房间），
## 不是"到过某个高度" —— 见 PROGRESS「竖井三算式」的教训。
##
## 用法：
##   $env:DSH_SKIP_BOOT_QUIT = "1"
##   & $GODOT --headless --path . --script "res://tests/test_vertical_climb.gd"

const LevelBuilder := preload("res://scripts/world/level_builder.gd")

const ROOM_W := 400.0
const ROOM_H := 220.0
const FLOOR_H := 16.0
const LEDGE_H := 10.0

const HOP_FRAMES := 70       ## 普通跳段（含起跳 + 落地 + 稳定）
const FINAL_FRAMES := 110    ## 发射台 → 上层房间（还要横向找落脚点）
const JUMP_FRAME := 3        ## 第几帧按跳（先站定，别提前走下台沿）
const JUMP_HOLD := 24        ## 长按到顶点：可变跳跃高度会在松手时截断上升

var _level: Node2D = null
var _player: CharacterBody2D = null
var _started := false
var _collected := false

var _pairs: Array = []
var _pair_index := 0
var _layout: Array = []
var _hop_index := 0          ## 0.._layout.size()；等于 size() 时表示"发射台→上层"
var _frame := 0
var _phase := 0              ## 0 = 准备下一跳，1 = 执行中

var _results: Array = []
var _start_pos := Vector2.ZERO
var _target_pos := Vector2.ZERO
var _target_half_w := 20.0
var _dir := 0.0
var _hop_ok := false


func _physics_process(_d: float) -> bool:
	if not _started:
		_boot()
		return false

	# generated_level.gd 的 _generate() 内部有 await，graph 不是立刻有值
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

	if _phase == 0:
		if _pair_index >= _pairs.size():
			_report()
			return true
		_setup_hop()
		_phase = 1
		_frame = 0
		return false

	_tick_hop()
	return false


# ============================================================
# 一跳的准备与执行
# ============================================================

func _setup_hop() -> void:
	var lower: Vector2i = _pairs[_pair_index]
	_layout = LevelBuilder.climb_layout_for(lower)
	var origin := Vector2(float(lower.x) * ROOM_W, float(lower.y) * ROOM_H)
	var floor_y: float = origin.y + ROOM_H - FLOOR_H
	var boundary_y: float = float(lower.y) * ROOM_H

	if _hop_index < _layout.size():
		var item: Dictionary = _layout[_hop_index]
		var p: Vector2 = origin + (item["pos"] as Vector2)
		_target_pos = p
		_target_half_w = (item["size"] as Vector2).x * 0.5

		if _hop_index == 0:
			# 地面 → 第一级：站在台子正下方，直上
			_start_pos = Vector2(p.x, floor_y)
			_dir = 0.0
		else:
			# 级间：站在上一级**靠近下一级的那一端**
			var prev_item: Dictionary = _layout[_hop_index - 1]
			var pp: Vector2 = origin + (prev_item["pos"] as Vector2)
			var pw: float = (prev_item["size"] as Vector2).x
			_dir = signf(p.x - pp.x)
			if is_zero_approx(_dir):
				_dir = 1.0
			var edge_x: float = pp.x + _dir * (pw * 0.5 - 8.0)
			# 最高一级与发射台同在洞列 → 这一跳是**垂直**的，不能给横向输入
			if absf(p.x - pp.x) < 1.0:
				_dir = 0.0
				edge_x = pp.x
			_start_pos = Vector2(edge_x, pp.y - LEDGE_H * 0.5)
	else:
		# 最后一跳：发射台 → 上层房间
		var last: Dictionary = _layout[_layout.size() - 1]
		var lp: Vector2 = origin + (last["pos"] as Vector2)
		_start_pos = Vector2(lp.x, lp.y - LEDGE_H * 0.5)
		_target_pos = Vector2(origin.x + ROOM_W * 0.5, boundary_y - FLOOR_H)
		_target_half_w = 40.0
		_dir = 0.0    # 先直上穿过洞，越过边界后再横向找实地

	# 清干净上一跳的残留状态
	_release_all()
	if _player.has_method("respawn"):
		_player.respawn()
	_player.position = _start_pos
	_player.velocity = Vector2.ZERO
	_player.set_physics_process(true)


func _tick_hop() -> void:
	_frame += 1

	if _frame == JUMP_FRAME:
		Input.action_press("jump")
		if not is_zero_approx(_dir):
			_press_dir(_dir)
	elif _frame == JUMP_FRAME + JUMP_HOLD:
		Input.action_release("jump")

	# 最后一跳：**一越过边界就开始横向**，不要等松开跳跃。
	# ⚠️ 曾经把这段放在 `_frame > JUMP_FRAME + JUMP_HOLD` 分支里，
	#    等于从顶点之后才开始横移，白丢一半滞空时间，实测差 6px 够不着地板。
	if _hop_index >= _layout.size() and _frame > JUMP_FRAME + 2:
		var boundary_y: float = float(_pairs[_pair_index].y) * ROOM_H
		if _player.position.y < boundary_y:
			var dx: float = _target_pos.x - _player.position.x
			if absf(dx) > 4.0:
				_press_dir(signf(dx))
			else:
				_release_dir()

	# ---- 落地即收工 ----
	# ⚠️ 不能等满帧数再判定：方向键一直按着，玩家落台后会**继续往前跑**，
	#    等 70 帧时早已从另一头跑下去（实测第 37 帧站住、第 50 帧已跑到台外）。
	if _frame >= JUMP_FRAME + 5 and _is_on_target():
		_finish_hop(true)
		return

	var limit: int = FINAL_FRAMES if _hop_index >= _layout.size() else HOP_FRAMES
	if _frame >= limit:
		_finish_hop(false)


## 判据：**站住**，且站在预期的那个平台上（不是"到过某个高度"）
func _is_on_target() -> bool:
	if not _player.is_on_floor():
		return false
	if _hop_index >= _layout.size():
		var boundary_y: float = float(_pairs[_pair_index].y) * ROOM_H
		return _player.position.y < boundary_y
	var expected_y: float = _target_pos.y - LEDGE_H * 0.5
	return absf(_player.position.y - expected_y) <= 8.0 \
		and absf(_player.position.x - _target_pos.x) <= _target_half_w + 10.0


func _finish_hop(ok: bool) -> void:
	_hop_ok = ok
	_release_all()

	if not ok:
		_results.append({
			"pair": _pairs[_pair_index],
			"ok": false,
			"failed_hop": _hop_index,
			"hops": _layout.size() + 1,
			"at": _player.position,
			"want": _target_pos,
		})
		_pair_index += 1
		_hop_index = 0
		_phase = 0
		return

	_hop_index += 1
	if _hop_index > _layout.size():
		_results.append({
			"pair": _pairs[_pair_index],
			"ok": true,
			"failed_hop": -1,
			"hops": _layout.size() + 1,
		})
		_pair_index += 1
		_hop_index = 0
	_phase = 0


func _press_dir(dir: float) -> void:
	if dir > 0.0:
		Input.action_press("move_right")
		Input.action_release("move_left")
	else:
		Input.action_press("move_left")
		Input.action_release("move_right")


func _release_dir() -> void:
	Input.action_release("move_left")
	Input.action_release("move_right")


func _release_all() -> void:
	for a in ["jump", "move_left", "move_right", "move_up", "move_down", "attack", "dash"]:
		Input.action_release(a)


# ============================================================
# 装载
# ============================================================

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
	var cells := {}
	for rm in g.rooms:
		cells[rm["cell"]] = true

	for rm in g.rooms:
		var c: Vector2i = rm["cell"]
		# ⚠️ 阶梯建在**下面**那个房间里（它才是"有上方邻居"的房间）。
		#    收成"有下方邻居"会拿到上面那个房间 —— 那里根本没有台阶。
		if cells.has(c + Vector2i(0, -1)):
			_pairs.append(c)

	print("[TEST] 本层垂直相邻房间对: %d 组" % _pairs.size())


# ============================================================
# 报告
# ============================================================

func _report() -> void:
	var total_pairs: int = _results.size()
	var ok_pairs := 0
	for r in _results:
		if r["ok"]:
			ok_pairs += 1

	var hops_per_pair: int = 0
	if not _results.is_empty():
		hops_per_pair = int(_results[0]["hops"])
	var total_hops: int = total_pairs * hops_per_pair
	var ok_hops: int = ok_pairs * hops_per_pair

	if not _results.is_empty():
		print("[TEST] 逐组结果（每组的跳段数 = %d：阶梯 4 级 + 发射台 + 上层）:" % hops_per_pair)
		for r in _results:
			var mark := "[PASS]" if r["ok"] else "[FAIL]"
			if r["ok"]:
				print("[TEST]   %s 下层 %s  全部 %d 跳通过" % [mark, str(r["pair"]), hops_per_pair])
			else:
				print("[TEST]   %s 下层 %s  第 %d 跳失败  落点 %s  目标 %s" % [
					mark, str(r["pair"]), int(r["failed_hop"]) + 1,
					str(r["at"]), str(r["want"])])

	var checks: Array = [
		["本层有垂直相邻房间（%d 组）" % total_pairs, total_pairs > 0],
		["全部跳段成功（%d/%d 跳）" % [ok_hops, total_hops], ok_pairs == total_pairs and total_pairs > 0],
	]

	print("")
	print("[TEST] ============ 垂直攀爬测试（逐跳） ============")
	var passed := 0
	for c in checks:
		var ok: bool = c[1]
		if ok:
			passed += 1
		print("[TEST]   %s %s" % ["[PASS]" if ok else "[FAIL]", c[0]])
	print("[TEST] ---------------------------------------------")
	print("[TEST] 结果: %d / %d 通过" % [passed, checks.size()])
	if passed == checks.size():
		print("[TEST] ★ 斜向阶梯每一跳都成立，且能站进上层房间")
	else:
		print("[TEST] ✗ 有跳段失败 —— 检查 level_builder.climb_layout_for 的间距")
	print("[TEST] =============================================")
	quit(0 if passed == checks.size() else 1)
