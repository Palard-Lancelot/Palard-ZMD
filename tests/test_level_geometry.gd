extends SceneTree
## 关卡几何连通性测试（阶段 1 准备）
##
## ⚠️ 这个测试存在的唯一理由：**图论连通 ≠ 几何可通行**。
##
## 背景：room_graph 的 1000/1000 测试只能证明"图是连通的"，
## 但 level_builder 建出来的墙可能把门堵死。实测第一版 23 条边里
## 有 7 条被完全挡住（只给左右墙留了门洞，地板天花板是整块实的）。
##
## 检测方法按连接方向分开：
##   水平相邻（dx=±1, dy=0）→ 垂直射线，在门洞高度范围内穿过
##   垂直相邻（dx=0, dy=±1）→ 水平射线，在边界高度穿过地板/天花板的洞
##   非相邻（捷径）        → 图级概念，几何上无门，**不计入几何要求**
##
## 为什么捷径不测几何：
##   跨格的捷径在图论上缩短了回退距离，但要在几何上实现
##   需要打通中间的房间（挖走廊），属于后续任务。
##   原型阶段承认这个限制，比假装它通更诚实。
##
## 用法：
##   $env:DSH_SKIP_BOOT_QUIT = "1"
##   & $GODOT --headless --path . --script "res://tests/test_level_geometry.gd"

const ROOM_W := 400.0
const ROOM_H := 220.0
const FLOOR_H := 16.0

var _level: Node2D = null
var _started := false
var _frame := 0

var _room_count := 0
var _h_edges := 0
var _h_blocked := 0
var _v_edges := 0
var _v_blocked := 0
var _sc_edges := 0
var _detail: Array = []


func _physics_process(_d: float) -> bool:
	if not _started:
		_started = true
		var sc: PackedScene = load("res://scenes/world/generated_level.tscn")
		if sc == null:
			print("[TEST] FAIL: 无法加载 generated_level.tscn")
			quit(1)
			return true
		_level = sc.instantiate() as Node2D
		get_root().add_child(_level)
		return false

	_frame += 1
	if _frame < 40:
		return false

	var g = _level.get("graph")
	if g == null:
		print("[TEST] FAIL: graph 为 null")
		quit(1)
		return true

	_run_probes(g)
	_report()
	return true


func _run_probes(g: RefCounted) -> void:
	_room_count = g.rooms.size()
	var space := get_root().get_world_2d().direct_space_state

	var cell_of := {}
	for rm in g.rooms:
		cell_of[rm["id"]] = rm["cell"]

	for e in g.edges:
		var id_a: int = e[0]
		var id_b: int = e[1]
		if not cell_of.has(id_a) or not cell_of.has(id_b):
			continue
		var ca: Vector2i = cell_of[id_a]
		var cb: Vector2i = cell_of[id_b]
		var d: Vector2i = cb - ca

		# --- 水平相邻：垂直射线穿过门洞 ---
		if absi(d.y) == 0 and absi(d.x) == 1:
			_h_edges += 1
			if not _probe_horizontal(space, ca, cb):
				_h_blocked += 1
				_detail.append("水平 %d-%d %s→%s" % [id_a, id_b, str(ca), str(cb)])

		# --- 垂直相邻：水平射线穿过地板/天花板洞 ---
		elif absi(d.x) == 0 and absi(d.y) == 1:
			_v_edges += 1
			if not _probe_vertical(space, ca, cb):
				_v_blocked += 1
				_detail.append("垂直 %d-%d %s→%s" % [id_a, id_b, str(ca), str(cb)])

		# --- 非相邻：捷径，几何上无门（见文件头说明）---
		else:
			_sc_edges += 1


## 水平相邻：验证共享墙上确实留了门洞（= 玩家能走过去）。
##
## ⚠️ 为什么不再「房间中心 → 房间中心」打 6 个高度的射线：
##    射线检测**不认 one_way_collision**，会把竖井攀爬台阶当成实心墙。
##    原来探测高度是 30/60/90/120/150/180（相对地面），
##    台阶间距调成 (204-23)/6 = 30.17px 之后，6 个高度和 6 级台阶几乎一一重合，
##    于是 15 条水平边里有 6 条被**误判**成"被堵死"。
##    （台阶是单向平台，玩家从下方可穿过、从上方可站立，本来就不该算墙。）
##
##    现在只测「玩家走路高度」：贴地 5/11/17px 三条射线。
##    这个高度一定在门洞内（门洞高 90），也一定在最低一级台阶之下（最低台阶离地 25px）。
##    三条都要通 —— 玩家身体高 22px，任何一条被挡都说明走不过去。
func _probe_horizontal(space: PhysicsDirectSpaceState2D, ca: Vector2i, cb: Vector2i) -> bool:
	var floor_y: float = float(ca.y) * ROOM_H + ROOM_H - FLOOR_H
	var ax: float = float(ca.x) * ROOM_W + ROOM_W * 0.5
	var bx: float = float(cb.x) * ROOM_W + ROOM_W * 0.5
	for h in [5.0, 11.0, 17.0]:
		var y: float = floor_y - h
		var q := PhysicsRayQueryParameters2D.create(Vector2(ax, y), Vector2(bx, y))
		q.collision_mask = 1
		if not space.intersect_ray(q).is_empty():
			return false
	return true


## 垂直相邻：在共享边界高度打水平射线，检查**洞所在位置**是否真的空。
##
## ⚠️ 洞的位置由「边界行号」决定并逐行交替左右（见 level_builder._gap_x_for_row）。
##    不能在房间中心探测 —— 中心很可能是实心的，会得到假阳性/假阴性。
func _probe_vertical(space: PhysicsDirectSpaceState2D, ca: Vector2i, cb: Vector2i) -> bool:
	var lower_cell := ca if ca.y > cb.y else cb
	var upper_cell := ca if ca.y < cb.y else cb

	# 共享边界行号 = 上层房间所在行
	var boundary_row: int = upper_cell.y
	var boundary_y: float = float(boundary_row + 1) * ROOM_H + 2.0

	var center_x: float = float(lower_cell.x) * ROOM_W + ROOM_W * 0.5
	var sign: float = -1.0 if (boundary_row % 2 == 0) else 1.0
	var gap_x: float = center_x + sign * 80.0    # V_SHAFT_SHIFT

	# 在洞中心水平打一条短射线（洞宽 100，射线跨度 40，必然在洞内）
	var pa := Vector2(gap_x - 20.0, boundary_y)
	var pb := Vector2(gap_x + 20.0, boundary_y)
	var q := PhysicsRayQueryParameters2D.create(pa, pb)
	q.collision_mask = 1
	return space.intersect_ray(q).is_empty()


func _report() -> void:
	if not _detail.is_empty():
		print("[TEST] 被挡住的边（前 8 条）:")
		for i in mini(_detail.size(), 8):
			print("[TEST]   %s" % _detail[i])

	var tested_edges: int = _h_edges + _v_edges
	var blocked: int = _h_blocked + _v_blocked

	var checks: Array = [
		["关卡生成成功（%d 房间）" % _room_count, _room_count > 0],
		["水平相邻边全部可通行（%d/%d）" % [_h_edges - _h_blocked, _h_edges], _h_blocked == 0],
		["垂直相邻边全部可通行（%d/%d）" % [_v_edges - _v_blocked, _v_edges], _v_blocked == 0],
		["正交相邻边总数正常（%d 条）" % tested_edges, tested_edges >= 10],
	]

	print("")
	print("[TEST] ========== 关卡几何连通性测试 ==========")
	var passed := 0
	for c in checks:
		var ok: bool = c[1]
		if ok:
			passed += 1
		print("[TEST]   %s %s" % ["[PASS]" if ok else "[FAIL]", c[0]])
	print("[TEST] -------------------------------------------")
	print("[TEST] 边分类：水平 %d · 垂直 %d · 捷径 %d（捷径为图级概念，不计入几何）" % [
		_h_edges, _v_edges, _sc_edges])
	print("[TEST] 结果: %d / %d 通过" % [passed, checks.size()])
	if passed == checks.size():
		print("[TEST] ★ 正交相邻的图边已完整转化为几何可通行")
	else:
		print("[TEST] ✗ 有边被墙堵死 —— 检查 level_builder 的洞与台阶")
	print("[TEST] ===========================================")
	quit(0 if passed == checks.size() else 1)
