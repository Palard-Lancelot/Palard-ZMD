extends RefCounted
## 关卡构建器（阶段 1 准备）
##
## 把 room_graph.gd 生成的抽象图变成**真正能走的物理空间**。
##
## 布局策略：
##   每个房间占据网格一格，世界坐标 = cell * 房间尺寸。
##   相邻且连边的房间在共享墙上留一个**门洞**，玩家可以自由走过去 ——
##   这样整个层是一张连续的大空间，不需要传送、不需要加载。
##
## 为什么这样做：
##   「层内可回退」如果靠传送门实现，玩家会失去空间直觉，
##   而连续空间能让"我记得这边有路"这个体验真正成立（DESIGN.md 第 3 节）。
##
## 纯几何构建，不依赖美术。全部用 ColorRect + StaticBody2D。

const ROOM_W := 400.0
const ROOM_H := 220.0
const WALL_THICK := 12.0
const DOOR_H := 90.0          ## 门洞高度（玩家 22px，留足余量）
const FLOOR_H := 16.0

## 房间类型对应颜色
const COLORS := {
	&"entrance": Color(0.18, 0.30, 0.24, 1),
	&"exit": Color(0.34, 0.22, 0.36, 1),
	&"combat": Color(0.13, 0.14, 0.19, 1),
	&"treasure": Color(0.30, 0.26, 0.13, 1),
	&"shop": Color(0.20, 0.16, 0.30, 1),
	&"elite": Color(0.32, 0.14, 0.14, 1),
}

const WALL_COLOR := Color(0.26, 0.29, 0.36, 1)


## 把网格坐标转成房间左下角的世界坐标
static func cell_to_world(cell: Vector2i) -> Vector2:
	return Vector2(float(cell.x) * ROOM_W, float(cell.y) * ROOM_H)


## 构建整层几何。
## 返回一个 Node2D，包含所有房间的地面、墙、平台与背景。
## graph 需要提供：rooms（含 id/cell/type）、edges、entrance_id、exit_id。
static func build(graph: RefCounted, parent: Node2D) -> Node2D:
	var root := Node2D.new()
	root.name = "GeneratedRooms"
	parent.add_child(root)

	# --- 背景：每间房一个色块，用类型区分 ---
	for room in graph.rooms:
		var origin := cell_to_world(room["cell"])
		var bg := ColorRect.new()
		bg.color = COLORS.get(room["type"], COLORS[&"combat"])
		bg.position = origin
		bg.size = Vector2(ROOM_W, ROOM_H)
		bg.z_index = -9
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.add_child(bg)

	# --- 地面 / 天花板（垂直连接处留洞）---
	for room in graph.rooms:
		var origin := cell_to_world(room["cell"])
		var cell: Vector2i = room["cell"]
		var has_below := _cell_occupied(graph, cell + Vector2i(0, 1)) >= 0
		var has_above := _cell_occupied(graph, cell + Vector2i(0, -1)) >= 0

		_build_floor(root, origin, has_below, cell.y)
		_build_ceiling(root, origin, has_above, cell.y)

	# --- 侧墙（有连接就留门洞）---
	for room in graph.rooms:
		var origin := cell_to_world(room["cell"])
		var cell: Vector2i = room["cell"]

		var has_left := _cell_occupied(graph, cell + Vector2i(-1, 0)) >= 0
		_add_side_wall(root, origin, true, has_left)
		var has_right := _cell_occupied(graph, cell + Vector2i(1, 0)) >= 0
		_add_side_wall(root, origin, false, has_right)

	# --- 垂直通道的攀爬台阶 ---
	for room in graph.rooms:
		var origin := cell_to_world(room["cell"])
		var cell: Vector2i = room["cell"]
		if _cell_occupied(graph, cell + Vector2i(0, -1)) >= 0:
			_build_climb_ledges(root, origin, cell.y)

	return root


# 垂直通道参数
#
# ⚠️ 这些数值经过实测调过，改之前务必跑 tests/test_vertical_climb.gd。
#
# 演进过程（每一步都是被测试逼出来的）：
#   1. 台阶用实心块 → 玩家撞头，完全爬不上去
#   2. 改成单向平台，但 4 级台阶 → 最高一级到天花板只剩 45.4px（跳跃 48px），
#      余量 2.6px 被离散积分吃掉，实际还是跳不上去
#   3. **上下两个洞都开在正中 → 下方有房间时，玩家走到洞口就掉下去，
#      根本没有站立点起跳。7 组垂直通道只有 3 组（底层）能爬**
#
# 现在的方案：**上行洞与下行洞在 X 方向错开**。
#   上行洞在 center - SHIFT，下行洞在 center + SHIFT。
#   这样玩家永远能站在「下行洞旁边」的实地上，从上行洞往上跳。
const V_SHAFT_W := 60.0       ## 洞宽。⚠️ 见下方「洞宽 = 难度」的算式，不要凭感觉调大
const V_SHAFT_SHIFT := 80.0   ## 上行洞/下行洞相对房间中心的偏移（错开的关键）
const LEDGE_W := 44.0         ## 台阶宽。必须塞得进洞里（见算式）
const LEDGE_H := 10.0
const LEDGE_COUNT := 6        ## 台阶数：越多最后一段越短，越容易跳上去
const TOP_LEDGE_Y := 23.0     ## 最高一级台阶的 y（相对房间原点）。算式见 _build_climb_ledges

## 某个"水平边界"上的洞的 x 坐标。
##
## ⚠️ 洞属于**边界**，不属于房间 —— 上下两个相邻房间共享同一个洞。
##    曾经让"上行洞"和"下行洞"各自按房间中心偏移：
##      A 房(y=4) 的下行洞在 center+70、B 房(y=5) 的上行洞在 center-70，
##      两者错位 → 玩家在 930 往上爬，撞到 A 房在 1070 之外的实心地板。
##      实测 7 组垂直通道全部卡在 181px（差一点进不去）。
##
##    现在改为：洞的位置只由**边界所在行号**决定，且逐行交替左右。
##    这样既能保证上下房间的洞严格对齐，
##    又能让同一个房间的上洞和下洞错开（否则玩家会一口气从顶层掉到底）。
static func _gap_x_for_row(origin: Vector2, boundary_row: int) -> float:
	var center: float = origin.x + ROOM_W * 0.5
	var sign: float = -1.0 if (boundary_row % 2 == 0) else 1.0
	return center + sign * V_SHAFT_SHIFT


## 房间的**上行洞**（通往上一层）x 坐标：属于本层与上一层的边界
static func _up_gap_x(origin: Vector2, room_row: int) -> float:
	return _gap_x_for_row(origin, room_row - 1)


## 房间的**下行洞**（通往下一层）x 坐标：属于本层与下一层的边界
static func _down_gap_x(origin: Vector2, room_row: int) -> float:
	return _gap_x_for_row(origin, room_row)


## 在一条水平实心带上开一个洞：返回 [左段, 右段]（可能为空）
static func _segments_with_gap(origin_x: float, width: float, gap_x: float, gap_w: float) -> Array:
	var segs: Array = []
	var gap_l: float = gap_x - gap_w * 0.5
	var gap_r: float = gap_x + gap_w * 0.5
	var left_w: float = gap_l - origin_x
	if left_w > 2.0:
		segs.append([origin_x + left_w * 0.5, left_w])
	var right_w: float = (origin_x + width) - gap_r
	if right_w > 2.0:
		segs.append([gap_r + right_w * 0.5, right_w])
	return segs


## 地面：有下方房间时在下行洞位置开口
static func _build_floor(root: Node2D, origin: Vector2, has_below: bool, room_row: int) -> void:
	var y: float = origin.y + ROOM_H - FLOOR_H * 0.5
	if not has_below:
		_add_solid(root, Vector2(origin.x + ROOM_W * 0.5, y), Vector2(ROOM_W, FLOOR_H))
		return
	var gap_x := _down_gap_x(origin, room_row)
	var segs := _segments_with_gap(origin.x, ROOM_W, gap_x, V_SHAFT_W)
	for s in segs:
		_add_solid(root, Vector2(s[0], y), Vector2(s[1], FLOOR_H))
	# ⚠️ 这里**不画**通道标记：同一条边界会由下方房间的天花板再画一次，
	#    两边都画会看到两组重叠箭头，很乱。统一由 _build_ceiling 画一次。


## 天花板：有上方房间时在上行洞位置开口
static func _build_ceiling(root: Node2D, origin: Vector2, has_above: bool, room_row: int) -> void:
	var y: float = origin.y + WALL_THICK * 0.5
	if not has_above:
		_add_solid(root, Vector2(origin.x + ROOM_W * 0.5, y), Vector2(ROOM_W, WALL_THICK))
		return
	var gap_x := _up_gap_x(origin, room_row)
	var segs := _segments_with_gap(origin.x, ROOM_W, gap_x, V_SHAFT_W)
	for s in segs:
		_add_solid(root, Vector2(s[0], y), Vector2(s[1], WALL_THICK))
	_add_gap_marker(root, Vector2(gap_x, y))


## 通道标记：让玩家一眼看出「这里是上下贯通的竖井」。
##
## ⚠️ 为什么需要：洞原本只是墙的缺口，在深色背景里几乎看不出来。
##    用户反馈"跳不上去"，实际是**找不到洞在哪**。
##
## ⚠️ 为什么用双向菱形而不是单向箭头：
##    同一条边界从上面看是"往下掉的口"，从下面看是"往上爬的口"。
##    只画单向箭头会让站在另一边的人困惑（实测把↑画在地板上很误导）。
##    菱形（上下两个三角对顶）= "上下都通"，没有歧义。
static func _add_gap_marker(root: Node2D, center: Vector2) -> void:
	var w := V_SHAFT_W
	var h := 6.0

	var band := Polygon2D.new()
	band.name = "GapMarker"
	band.color = Color(0.30, 0.95, 0.85, 0.22)
	band.polygon = PackedVector2Array([
		center + Vector2(-w * 0.5, -h * 0.5),
		center + Vector2( w * 0.5, -h * 0.5),
		center + Vector2( w * 0.5,  h * 0.5),
		center + Vector2(-w * 0.5,  h * 0.5),
	])
	band.z_index = -1
	root.add_child(band)

	# 菱形：上三角 + 下三角对顶
	for i in 3:
		var t: float = (float(i) + 0.5) / 3.0
		var ax: float = center.x - w * 0.5 + w * t
		var r := 5.0
		var up := Polygon2D.new()
		up.color = Color(0.45, 1.0, 0.85, 0.55)
		up.polygon = PackedVector2Array([
			Vector2(ax - r, center.y - 3.0),
			Vector2(ax + r, center.y - 3.0),
			Vector2(ax, center.y - 11.0),
		])
		up.z_index = -1
		root.add_child(up)

		var dn := Polygon2D.new()
		dn.color = Color(0.45, 1.0, 0.85, 0.55)
		dn.polygon = PackedVector2Array([
			Vector2(ax - r, center.y + 3.0),
			Vector2(ax + r, center.y + 3.0),
			Vector2(ax, center.y + 11.0),
		])
		dn.z_index = -1
		root.add_child(dn)


## 攀爬台阶：沿**上行洞**的竖直通道放单向平台。
##
## ⚠️ 必须用 one_way_collision（单向碰撞）：
##    实心平台只能从侧面绕、不能从下方穿过 —— 玩家从下往上跳会撞头。
##    单向平台从下方可穿过、从上方可站立，是横板平台游戏的标准做法。
##
## ⚠️⚠️ 竖井能不能爬上去，**完全由三个数决定**。
##    这三个数不能凭感觉调，必须按下面这套算式核一遍。
##    （玩家碰撞盒 12x22，实测起跳上升 45px —— 理论 48px，
##      被「可变跳跃高度」按 24/44 帧松开和离散积分吃掉 3px）
##
##   【算式 1】最高一级台阶能放多高？
##     玩家站在台阶上，头顶会伸进「边界实心带」的纵向范围里
##     （边界带 = 上层地板 16 + 下层天花板 12，跨 y -16..+12）。
##     只要头顶还在洞里（洞比玩家宽）就不会撞，但台阶本身必须塞进洞里：
##
##       TOP_LEDGE_Y >= 玩家高 22          → 头顶不越过上层地板**底面**
##       LEDGE_W/2 + 玩家宽/2 <= V_SHAFT_W/2   → 人站在台阶边缘也还在洞里
##
##   【算式 2】最后一跳的**余量**（这是最要命的数）
##     上层房间可站立面 = -16（跨过边界后，上层地板的上表面）
##     顶点脚底 = TOP_LEDGE_Y - 45
##     余量     = -16 - (TOP_LEDGE_Y - 45) = 29 - TOP_LEDGE_Y
##
##     TOP_LEDGE_Y=30 → 余量 **-1px**（跳不到，脚底永远差一点）
##     TOP_LEDGE_Y=24 → 余量 +5px
##     TOP_LEDGE_Y=23 → 余量 +6px
##
##   【算式 3】玩家从洞里冒出来后，**横向够不够得着实地**？
##     ⚠️ 这才是"跳到最高也过不去"的真正元凶。
##     玩家从洞中央冒出来时，左右都是空的，必须先横move 到洞沿以外，
##     才能踩到上层地板。可用的滞空时间由算式 2 的余量决定：
##
##       余量 6px → 越过上层地板表面的时间 ≈ 2*sqrt(2*6/682.7) = 0.265s
##       空中加速 = 1650 * air_control(0.75) = 1237 px/s² → 0.13s 到满速
##       0.265s 内水平位移 ≈ 33px
##       需要位移 = V_SHAFT_W/2 - 玩家半宽 6
##
##       V_SHAFT_W=120 → 需要 54px > 33px  ✗ **永远差 21px，这是核心 bug**
##       V_SHAFT_W=60  → 需要 24px < 33px  ✓ 余 9px
##
##    曾经洞宽 120（为了让玩家"看得见洞"），结果洞太宽反而爬不进去。
##    可见性改由 _add_gap_marker 的青色标记负责，洞本身要窄。
##
##   【为什么不再左右交错】
##     交错能增加路线变化，但会让玩家冒出的位置偏离洞中线、把算式 3 的
##     余量吃掉。竖井攀爬的正确手感是「按住跳一路往上」，不需要之字形。
static func _build_climb_ledges(root: Node2D, origin: Vector2, room_row: int) -> void:
	var up_x: float = _up_gap_x(origin, room_row)
	var floor_y: float = origin.y + ROOM_H - FLOOR_H        # +204
	var top_y: float = origin.y + TOP_LEDGE_Y               # +23
	var step: float = (floor_y - top_y) / float(LEDGE_COUNT)

	for i in LEDGE_COUNT:
		var y: float = floor_y - step * float(i + 1)
		# 竖直正对洞中线：玩家只需按住跳跃，不用左右找位置
		_add_solid(root, Vector2(up_x, y), Vector2(LEDGE_W, LEDGE_H), true)


## 判断某格是否已被某个房间占据
static func _cell_occupied(graph: RefCounted, cell: Vector2i) -> int:
	for room in graph.rooms:
		if room["cell"] == cell:
			return room["id"]
	return -1


## 某格是否有房间，且与当前房间有边？
## 注意：这里只看"格子被占用"，因为图是连通的，
## 相邻房间之间可能通过生成树或环路相连 —— 只要相邻就开路。
static func _has_neighbor_edge(_graph: RefCounted, cell: Vector2i) -> bool:
	return _cell_occupied(_graph, cell) >= 0


## 侧墙：中间留门洞，上下各一段
static func _add_side_wall(root: Node2D, origin: Vector2, is_left: bool, has_door: bool) -> void:
	var x: float = origin.x + (WALL_THICK * 0.5 if is_left else ROOM_W - WALL_THICK * 0.5)

	if not has_door:
		# 无连接：整面实墙
		_add_solid(root, Vector2(x, origin.y + ROOM_H * 0.5), Vector2(WALL_THICK, ROOM_H))
		return

	# 有连接：门洞居中，上下各留一段墙
	var door_top: float = origin.y + ROOM_H - FLOOR_H - DOOR_H
	var upper_h: float = door_top - origin.y - WALL_THICK
	if upper_h > 4.0:
		_add_solid(root, Vector2(x, origin.y + WALL_THICK + upper_h * 0.5),
			Vector2(WALL_THICK, upper_h))
	# 门洞下方到地面这一段（防止玩家从门洞掉下去）
	var lower_h: float = FLOOR_H
	_add_solid(root, Vector2(x, origin.y + ROOM_H - lower_h * 0.5),
		Vector2(WALL_THICK, lower_h))


## 加一块实心几何（碰撞 + 可视）
## one_way = true 时启用单向碰撞：从下方可穿过，从上方可站立。
## ⚠️ 单向平台必须配合 CharacterBody2D 的「上落」判定；
##    Godot 的 one_way_collision 默认允许从形状背面穿过。
static func _add_solid(root: Node2D, center: Vector2, size: Vector2, one_way: bool = false) -> void:
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = center

	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = size
	shape.shape = rect
	if one_way:
		shape.one_way_collision = true
	body.add_child(shape)

	var vis := ColorRect.new()
	# 单向平台用略亮的颜色，与实心墙区分开（可读性）
	vis.color = Color(0.42, 0.50, 0.60, 1) if one_way else WALL_COLOR
	vis.position = -size * 0.5
	vis.size = size
	vis.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(vis)

	root.add_child(body)


## 整层的世界包围盒（用于设置相机的 limit）
static func layer_bounds(graph: RefCounted) -> Rect2:
	if graph.rooms.is_empty():
		return Rect2()
	var min_cell := Vector2i(9999, 9999)
	var max_cell := Vector2i(-9999, -9999)
	for room in graph.rooms:
		var c: Vector2i = room["cell"]
		min_cell.x = mini(min_cell.x, c.x)
		min_cell.y = mini(min_cell.y, c.y)
		max_cell.x = maxi(max_cell.x, c.x)
		max_cell.y = maxi(max_cell.y, c.y)

	var top_left := cell_to_world(min_cell)
	var size := Vector2(
		float(max_cell.x - min_cell.x + 1) * ROOM_W,
		float(max_cell.y - min_cell.y + 1) * ROOM_H
	)
	return Rect2(top_left, size)


## 房间中心点（用于放敌人 / 出生点）
static func room_center(graph: RefCounted, room_id: int) -> Vector2:
	for room in graph.rooms:
		if room["id"] == room_id:
			var origin := cell_to_world(room["cell"])
			return origin + Vector2(ROOM_W * 0.5, ROOM_H - FLOOR_H - 11.0)
	return Vector2.ZERO
