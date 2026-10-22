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

		_build_floor(root, origin, has_below)
		_build_ceiling(root, origin, has_above)

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
			_build_climb_ledges(root, origin)

	return root


# 垂直通道参数
const V_SHAFT_W := 76.0       ## 地板/天花板的洞宽
const LEDGE_W := 62.0
const LEDGE_H := 10.0
const LEDGE_COUNT := 4        ## 台阶数（220px 高 / 4 ≈ 55px 一级，跳跃 48px 够）

## 地面：有下方房间时在中间留洞，让玩家能掉下去
static func _build_floor(root: Node2D, origin: Vector2, has_below: bool) -> void:
	var y: float = origin.y + ROOM_H - FLOOR_H * 0.5
	if not has_below:
		_add_solid(root, Vector2(origin.x + ROOM_W * 0.5, y), Vector2(ROOM_W, FLOOR_H))
		return
	# 中间留洞：左右各一段
	var gap_l: float = origin.x + (ROOM_W - V_SHAFT_W) * 0.5
	var gap_r: float = gap_l + V_SHAFT_W
	var left_w: float = gap_l - origin.x
	if left_w > 2.0:
		_add_solid(root, Vector2(origin.x + left_w * 0.5, y), Vector2(left_w, FLOOR_H))
	var right_w: float = (origin.x + ROOM_W) - gap_r
	if right_w > 2.0:
		_add_solid(root, Vector2(gap_r + right_w * 0.5, y), Vector2(right_w, FLOOR_H))


## 天花板：有上方房间时在中间留洞
static func _build_ceiling(root: Node2D, origin: Vector2, has_above: bool) -> void:
	var y: float = origin.y + WALL_THICK * 0.5
	if not has_above:
		_add_solid(root, Vector2(origin.x + ROOM_W * 0.5, y), Vector2(ROOM_W, WALL_THICK))
		return
	var gap_l: float = origin.x + (ROOM_W - V_SHAFT_W) * 0.5
	var gap_r: float = gap_l + V_SHAFT_W
	var left_w: float = gap_l - origin.x
	if left_w > 2.0:
		_add_solid(root, Vector2(origin.x + left_w * 0.5, y), Vector2(left_w, WALL_THICK))
	var right_w: float = (origin.x + ROOM_W) - gap_r
	if right_w > 2.0:
		_add_solid(root, Vector2(gap_r + right_w * 0.5, y), Vector2(right_w, WALL_THICK))


## 攀爬台阶：在垂直通道里交错放几块小平台。
## 玩家跳跃高度 48px，房间高 220 —— 4 级台阶（每级约 55px）刚好够爬。
static func _build_climb_ledges(root: Node2D, origin: Vector2) -> void:
	var center_x: float = origin.x + ROOM_W * 0.5
	var floor_y: float = origin.y + ROOM_H - FLOOR_H
	var step: float = (ROOM_H - FLOOR_H - WALL_THICK) / float(LEDGE_COUNT + 1)

	for i in LEDGE_COUNT:
		var y: float = floor_y - step * float(i + 1)
		# 左右交错，形成之字形攀爬路线
		var side: float = -1.0 if i % 2 == 0 else 1.0
		var x: float = center_x + side * (V_SHAFT_W * 0.5 - LEDGE_W * 0.5 + 6.0)
		_add_solid(root, Vector2(x, y), Vector2(LEDGE_W, LEDGE_H))


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
static func _add_solid(root: Node2D, center: Vector2, size: Vector2) -> void:
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = center

	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = size
	shape.shape = rect
	body.add_child(shape)

	var vis := ColorRect.new()
	vis.color = WALL_COLOR
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
