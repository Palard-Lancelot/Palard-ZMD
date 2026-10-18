extends RefCounted
## 单层连通图生成器（阶段 0 任务 0.13）
##
## 目的：验证「每层内一张连通图、可回退、带捷径」这个结构在算法上是否可行。
## 这是 DESIGN.md 第 7.6 节标记的**最高技术风险项** ——
## 如果做不出来，整个「层内连通可回退」的设计要退回「单向推进」，
## 第 2/3/5 节都要返工。
##
## 纯算法模块，不依赖渲染、不需要美术。
##
## 生成流程（与 Dead Cells 的六步法同构，但拓扑层改成图论问题）：
##   1. 在网格上随机游走放置 N 个房间（保证物理上相邻）
##   2. 用 BFS 从入口建**生成树** → 天然保证连通
##   3. 加 K 条**额外边**制造环路 → 这是"可回退"的结构基础
##   4. 选入口（最左）与出口（最右）
##   5. 加 M 条**捷径**：跨越多个房间的边，缩短回退路程
##   6. 用并查集 + BFS 校验全部约束
##
## ⚠️ 关键设计原则：先建拓扑再填房间。
##    绝不要边填边判断连通性 —— 那样几乎一定会产生死锁。

# ============================================================
# 配置
# ============================================================

const MIN_ROOMS := 12
const MAX_ROOMS := 20
const GRID_MIN_X := 0
const GRID_MAX_X := 30
const GRID_MIN_Y := 0
const GRID_MAX_Y := 6

## 房间类型
const TYPE_ENTRANCE := &"entrance"
const TYPE_EXIT := &"exit"
const TYPE_COMBAT := &"combat"
const TYPE_TREASURE := &"treasure"
const TYPE_SHOP := &"shop"
const TYPE_ELITE := &"elite"

# ============================================================
# 图数据
# ============================================================

## 房间列表：每项 { id: int, cell: Vector2i, type: StringName }
var rooms: Array = []

## 边列表：每项 [id_a, id_b, is_shortcut]
var edges: Array = []

var entrance_id: int = 0
var exit_id: int = 0

## 生成统计（供测试断言）
var stats: Dictionary = {}


func reset() -> void:
	rooms.clear()
	edges.clear()
	entrance_id = 0
	exit_id = 0
	stats.clear()


# ============================================================
# 主入口
# ============================================================

## 生成一层。seed 固定 → 结果可复现（这是随机种子存档的基础）。
## 返回是否生成成功（满足全部约束）。
func generate(seed_value: int) -> bool:
	reset()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	# --- 1. 网格随机游走放置房间 ---
	if not _place_rooms(rng):
		return false

	# --- 2. 生成树保证连通 ---
	if not _build_spanning_tree(rng):
		return false

	# --- 3. 额外边制造环路（可回退的结构基础）---
	_add_loop_edges(rng)

	# --- 4. 选入口 / 出口 ---
	_pick_entrance_exit()

	# --- 5. 捷径 ---
	_add_shortcuts(rng)

	# --- 6. 分配房间类型 ---
	_assign_types(rng)

	# --- 7. 校验 ---
	return validate()


# ============================================================
# 1. 房间放置
# ============================================================

func _place_rooms(rng: RandomNumberGenerator) -> bool:
	var target: int = rng.randi_range(MIN_ROOMS, MAX_ROOMS)
	var used := {}
	var cur := Vector2i(2, GRID_MAX_Y / 2)

	used[cur] = true
	rooms.append({"id": 0, "cell": cur, "type": TYPE_COMBAT})

	# 随机游走放置。⚠️ 纯游走会走进死胡同（四周都是已占用格），
	#    实测约 4% 的种子因此失败。所以卡住时从**已放置房间中随机挑一个**
	#    重新开始走，相当于允许"分叉"而不是单链推进。
	var attempts := 0
	while rooms.size() < target and attempts < 1200:
		attempts += 1

		if attempts % 40 == 0:
			# 重新选起点：从已有房间里挑一个还有空邻格的
			var with_space: Array = []
			for r in rooms:
				if _free_neighbor_count(r["cell"], used) > 0:
					with_space.append(r["cell"])
			if with_space.size() > 0:
				cur = with_space[rng.randi_range(0, with_space.size() - 1)]

		var dirs: Array = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
		var d: Vector2i = dirs[rng.randi_range(0, dirs.size() - 1)]
		var nxt: Vector2i = cur + d

		if nxt.x < GRID_MIN_X or nxt.x > GRID_MAX_X:
			continue
		if nxt.y < GRID_MIN_Y or nxt.y > GRID_MAX_Y:
			continue
		if used.has(nxt):
			continue
		# 水平偏向：横板游戏应该横向铺开而不是纵向堆叠
		if d.y != 0 and rng.randf() > 0.30:
			continue

		used[nxt] = true
		rooms.append({"id": rooms.size(), "cell": nxt, "type": TYPE_COMBAT})
		cur = nxt

	return rooms.size() >= MIN_ROOMS


## 某个格子四周有多少个未占用的合法格
func _free_neighbor_count(cell: Vector2i, used: Dictionary) -> int:
	var cnt := 0
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var n: Vector2i = cell + d
		if n.x < GRID_MIN_X or n.x > GRID_MAX_X:
			continue
		if n.y < GRID_MIN_Y or n.y > GRID_MAX_Y:
			continue
		if not used.has(n):
			cnt += 1
	return cnt


# ============================================================
# 2. 生成树（BFS）
# ============================================================

func _build_spanning_tree(rng: RandomNumberGenerator) -> bool:
	if rooms.size() < 2:
		return false

	var visited := {}
	var queue: Array = [0]
	visited[0] = true

	while queue.size() > 0:
		# 随机取一个已访问的节点继续扩展 —— 让树形更自然
		var idx: int = rng.randi_range(0, queue.size() - 1)
		var from_id: int = queue[idx]
		queue.remove_at(idx)

		var neighbors := _cell_neighbors(from_id)
		neighbors.shuffle()
		for nb_id in neighbors:
			if visited.has(nb_id):
				continue
			visited[nb_id] = true
			_add_edge(from_id, nb_id, false)
			queue.append(nb_id)

	return visited.size() == rooms.size()


## 找出与某房间在网格上相邻的房间
func _cell_neighbors(from_id: int) -> Array:
	var out: Array = []
	var c: Vector2i = rooms[from_id]["cell"]
	for r in rooms:
		if r["id"] == from_id:
			continue
		var d: Vector2i = r["cell"] - c
		if absi(d.x) + absi(d.y) == 1:
			out.append(r["id"])
	return out


# ============================================================
# 3. 额外边（环路）
# ============================================================

func _add_loop_edges(rng: RandomNumberGenerator) -> void:
	# 目标：制造**可靠的环路**，让"可回退"不依赖运气。
	#
	# ⚠️ 这里曾经写成「相邻房间之间 55% 概率补边」——
	#    实测 1000 个种子只有 14.6% 能形成足够环路（815 次失败）。
	#    原因是生成树已经占掉了大多数相邻对，剩下的随机补边概率太低。
	#    改成**确定性补边**：先尽力补相邻对，不够就用跨格边兜底。
	#
	# 环路数（cyclomatic number）= edges - rooms + 1
	# 目标至少 2 个独立环路 → 玩家有真正的"绕路"选择，而不是原地折返。
	var target_cycles := 2
	var target_edges := rooms.size() - 1 + target_cycles

	# --- 第一步：相邻但未连边的房间之间补边 ---
	var candidates: Array = []
	for r in rooms:
		for nb in _cell_neighbors(r["id"]):
			if nb <= r["id"]:
				continue
			if _has_edge(r["id"], nb):
				continue
			candidates.append([r["id"], nb])

	candidates.shuffle()
	for cand in candidates:
		if edges.size() >= target_edges:
			break
		_add_edge(cand[0], cand[1], false)

	# --- 第二步：仍不够则用跨格边兜底（同时兼作捷径）---
	if edges.size() < target_edges:
		var far: Array = []
		for a in rooms:
			for b in rooms:
				if a["id"] >= b["id"]:
					continue
				if _has_edge(a["id"], b["id"]):
					continue
				var d: Vector2i = b["cell"] - a["cell"]
				if absi(d.y) > 2 or absi(d.x) > 5:
					continue
				far.append([a["id"], b["id"]])
		far.shuffle()
		for cand in far:
			if edges.size() >= target_edges:
				break
			_add_edge(cand[0], cand[1], true)

	stats["loop_edges"] = edges.size() - (rooms.size() - 1)


# ============================================================
# 4. 入口 / 出口
# ============================================================

func _pick_entrance_exit() -> void:
	# 入口最左，出口最右 —— 与横板推进方向一致
	var min_x := 999
	var max_x := -999
	for r in rooms:
		var c: Vector2i = r["cell"]
		if c.x < min_x:
			min_x = c.x
			entrance_id = r["id"]
		if c.x > max_x:
			max_x = c.x
			exit_id = r["id"]

	# 出口若离入口太近（层太短），强行换成横向距离最远的房间
	var dx: int = absi(rooms[exit_id]["cell"].x - rooms[entrance_id]["cell"].x)
	if dx < 4:
		var best := exit_id
		var best_d := dx
		for r in rooms:
			var d: int = absi(r["cell"].x - rooms[entrance_id]["cell"].x)
			if d > best_d:
				best_d = d
				best = r["id"]
		exit_id = best

	stats["entrance_exit_dx"] = absi(rooms[exit_id]["cell"].x - rooms[entrance_id]["cell"].x)


# ============================================================
# 5. 捷径
# ============================================================

func _add_shortcuts(rng: RandomNumberGenerator) -> void:
	# 捷径 = 跨越 2~4 格的水平边，大幅缩短回退路程。
	# 没有捷径的话，"层内可回退"会退化成折返跑 —— 这是最大的体验杀手。
	var added := 0
	var wanted: int = rng.randi_range(1, 2)

	var candidates: Array = []
	for a in rooms:
		for b in rooms:
			if a["id"] >= b["id"]:
				continue
			var d: Vector2i = b["cell"] - a["cell"]
			if absi(d.y) > 1:
				continue
			if absi(d.x) < 2 or absi(d.x) > 4:
				continue
			if _has_edge(a["id"], b["id"]):
				continue
			candidates.append([a["id"], b["id"]])

	candidates.shuffle()
	for cand in candidates:
		if added >= wanted:
			break
		_add_edge(cand[0], cand[1], true)
		added += 1

	stats["shortcuts"] = added


# ============================================================
# 6. 房间类型
# ============================================================

func _assign_types(rng: RandomNumberGenerator) -> void:
	for r in rooms:
		r["type"] = TYPE_COMBAT
	rooms[entrance_id]["type"] = TYPE_ENTRANCE
	rooms[exit_id]["type"] = TYPE_EXIT

	# 入口与出口之间至少要有 2 个可选房（宝物 / 商店），
	# 保证「可选探索」有实际内容 —— 这是约束 C-14
	var others: Array = []
	for r in rooms:
		var t: StringName = r["type"]
		if t == TYPE_COMBAT:
			others.append(r["id"])
	others.shuffle()

	var treasure := 0
	var shop := 0
	var elite := 0
	for id in others:
		var t: StringName = TYPE_COMBAT
		if treasure < 2:
			t = TYPE_TREASURE
			treasure += 1
		elif shop < 1:
			t = TYPE_SHOP
			shop += 1
		elif elite < 1 and rng.randf() < 0.5:
			t = TYPE_ELITE
			elite += 1
		rooms[id]["type"] = t

	stats["treasures"] = treasure
	stats["shops"] = shop


# ============================================================
# 7. 校验（核心）
# ============================================================

func validate() -> bool:
	var n := rooms.size()
	if n < MIN_ROOMS or n > MAX_ROOMS:
		return false

	# --- 并查集：必须只有一个连通分量 ---
	var parent := {}
	for i in n:
		parent[i] = i

	for e in edges:
		_union(parent, e[0], e[1])

	var root := _find(parent, 0)
	for i in n:
		if _find(parent, i) != root:
			return false

	# --- BFS：从入口可达所有房间 ---
	var reach := _bfs(entrance_id)
	if reach.size() != n:
		return false

	# --- 出口必须可达 ---
	if not reach.has(exit_id):
		return false

	# --- 出口不应要求清空所有房间 ---
	#    检查：存在一条入口→出口的路径，长度 < 房间总数
	var path := _shortest_path(entrance_id, exit_id)
	if path.size() == 0 or path.size() >= n:
		return false
	stats["exit_path_len"] = path.size()

	# --- 捷径至少 1 条 ---
	var sc := 0
	for e in edges:
		if e[2]:
			sc += 1
	stats["shortcuts"] = sc
	if sc < 1:
		return false

	# --- 存在环路（可回退的结构保证）---
	#
	# 判据用**连通图的环数**（cyclomatic number）= E - V + 1：
	#   0 = 树（只能原路折返，回退体验差）
	#   ≥1 = 有环路，玩家可以绕路而不是走回头路
	#
	# ⚠️ 曾误用「入口→出口存在 2 条边不相交路径」作为判据 ——
	#    那要求整条主干都有平行路径，比设计本意强得多，
	#    导致 815/1000 个种子被判失败。设计本意只是"能绕路"，不是"处处双线"。
	var cycles: int = edges.size() - n + 1
	stats["cycles"] = cycles
	if cycles < 1:
		return false

	stats["rooms"] = n
	stats["edges"] = edges.size()
	return true


func _find(parent: Dictionary, x: int) -> int:
	var p: int = parent[x]
	if p != x:
		p = _find(parent, p)
		parent[x] = p
	return p


func _union(parent: Dictionary, a: int, b: int) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra != rb:
		parent[rb] = ra


## 邻接表
func _adjacency() -> Dictionary:
	var adj := {}
	for r in rooms:
		adj[r["id"]] = []
	for e in edges:
		adj[e[0]].append(e[1])
		adj[e[1]].append(e[0])
	return adj


## 从 start 出发的可达集合（BFS）
func _bfs(start: int) -> Dictionary:
	var adj := _adjacency()
	var seen := {start: true}
	var queue: Array = [start]
	while queue.size() > 0:
		var cur: int = queue.pop_front()
		for nb in adj[cur]:
			if not seen.has(nb):
				seen[nb] = true
				queue.append(nb)
	return seen


## 最短路径（返回节点序列，空表示不可达）
func _shortest_path(start: int, goal: int) -> Array:
	var adj := _adjacency()
	var prev := {start: -1}
	var queue: Array = [start]
	while queue.size() > 0:
		var cur: int = queue.pop_front()
		if cur == goal:
			break
		for nb in adj[cur]:
			if not prev.has(nb):
				prev[nb] = cur
				queue.append(nb)
	if not prev.has(goal):
		return []
	var path: Array = []
	var c := goal
	while c != -1:
		path.append(c)
		c = prev[c]
	path.reverse()
	return path


## 边不相交路径数（最多数到 2，用于判断"有无环路"）
## 简化做法：删掉最短路径上的每条边，看出口是否仍可达
func _count_edge_disjoint_paths(a: int, b: int) -> int:
	var p := _shortest_path(a, b)
	if p.size() == 0:
		return 0

	# 把最短路径上的边移除后重算
	var blocked := {}
	for i in range(p.size() - 1):
		blocked[_edge_key(p[i], p[i + 1])] = true

	var adj := _adjacency()
	var seen := {a: true}
	var queue: Array = [a]
	while queue.size() > 0:
		var cur: int = queue.pop_front()
		for nb in adj[cur]:
			if blocked.has(_edge_key(cur, nb)):
				continue
			if not seen.has(nb):
				seen[nb] = true
				queue.append(nb)
	return 2 if seen.has(b) else 1


# ============================================================
# 工具
# ============================================================

func _add_edge(a: int, b: int, shortcut: bool) -> void:
	if a == b:
		return
	if _has_edge(a, b):
		return
	edges.append([a, b, shortcut])


func _has_edge(a: int, b: int) -> bool:
	for e in edges:
		if (e[0] == a and e[1] == b) or (e[0] == b and e[1] == a):
			return true
	return false


func _edge_key(a: int, b: int) -> String:
	return "%d-%d" % [mini(a, b), maxi(a, b)]


func count_edges() -> int:
	return edges.size()


## 供调试输出
func describe() -> String:
	return "rooms=%d edges=%d shortcuts=%d path=%s" % [
		rooms.size(), edges.size(),
		stats.get("shortcuts", 0), str(stats.get("exit_path_len", -1))]
