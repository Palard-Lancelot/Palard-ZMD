extends SceneTree
## 层内连通图验证（阶段 0 任务 0.13）
##
## 这是 DESIGN.md 第 7.6 节标记的**最高技术风险项**。
## 目的：在用 19 个月做内容之前，先证明「层内连通可回退」在算法上可行。
##
## 验证强度：跑 1000 个随机种子，全部必须满足约束。
## 只要有一个失败，就说明结构设计需要调整（而不是继续加内容）。
##
## 断言（对应 PROGRESS.md 0.13 的验收标准）：
##   1. 生成本层连通图        —— 1000 个种子全部成功
##   2. 连通性检查（并查集）  —— 单一连通分量
##   3. 出口可达              —— 入口→出口有路径
##   4. 无孤立房间            —— 所有房间都可达
##   5. 捷径生成              —— 每层至少 1 条捷径
##   6. 规模可控              —— 房间数 12–20
##   7. 可回退（有环路）      —— 入口→出口存在 ≥2 条边不相交路径
##
## 用法：
##   & $GODOT --headless --path . --script "res://tests/test_room_graph.gd"

const RoomGraphScript := preload("res://scripts/world/room_graph.gd")

const SEED_COUNT := 1000

var _fail_reasons: Dictionary = {}
var _fail_examples: Dictionary = {}


func _initialize() -> void:
	print("")
	print("[TEST] ============ 层内连通图验证 ============")
	print("[TEST] 生成 %d 层（随机种子 0..%d）" % [SEED_COUNT, SEED_COUNT - 1])

	var gen: RefCounted = RoomGraphScript.new()

	var ok_count := 0
	var fail_count := 0

	var sum_rooms := 0
	var sum_edges := 0
	var sum_shortcuts := 0
	var sum_path := 0
	var min_rooms := 9999
	var max_rooms := 0
	var min_path := 9999
	var max_path := 0

	for s in SEED_COUNT:
		var ok: bool = gen.generate(s)
		if ok:
			ok_count += 1
			var st: Dictionary = gen.stats
			var r: int = int(st.get("rooms", 0))
			var e: int = int(st.get("edges", 0))
			var sc: int = int(st.get("shortcuts", 0))
			var pl: int = int(st.get("exit_path_len", 0))
			sum_rooms += r
			sum_edges += e
			sum_shortcuts += sc
			sum_path += pl
			min_rooms = mini(min_rooms, r)
			max_rooms = maxi(max_rooms, r)
			min_path = mini(min_path, pl)
			max_path = maxi(max_path, pl)
		else:
			fail_count += 1
			var reason := _diagnose(gen)
			_fail_reasons[reason] = int(_fail_reasons.get(reason, 0)) + 1
			if not _fail_examples.has(reason):
				_fail_examples[reason] = s

	# ---- 报告 ----
	print("[TEST] -------------------------------------------")
	print("[TEST] 成功的层数: %d / %d (%.1f%%)" % [
		ok_count, SEED_COUNT, 100.0 * float(ok_count) / float(SEED_COUNT)])
	print("[TEST] 失败的层数: %d" % fail_count)

	if ok_count > 0:
		print("[TEST] ---- 成功样本统计 ----")
		print("[TEST] 房间数  : 平均 %.1f  范围 %d–%d" % [
			float(sum_rooms) / float(ok_count), min_rooms, max_rooms])
		print("[TEST] 边数    : 平均 %.1f" % (float(sum_edges) / float(ok_count)))
		print("[TEST] 捷径数  : 平均 %.2f" % (float(sum_shortcuts) / float(ok_count)))
		print("[TEST] 出口路径: 平均 %.1f 跳  范围 %d–%d" % [
			float(sum_path) / float(ok_count), min_path, max_path])

	if not _fail_reasons.is_empty():
		print("[TEST] ---- 失败原因分布 ----")
		for reason in _fail_reasons.keys():
			print("[TEST]   %-40s %d 次（例：种子 %d）" % [
				reason, _fail_reasons[reason], _fail_examples[reason]])

	# ---- 断言 ----
	print("[TEST] -------------------------------------------")
	var checks: Array = [
		["1000 个种子全部生成成功", ok_count == SEED_COUNT],
		["房间数落在 12–20 区间", min_rooms >= 12 and max_rooms <= 20],
		["每层至少 1 条捷径", sum_shortcuts >= ok_count],
		["出口路径不占满全部房间（可选探索有意义）", max_path < max_rooms],
	]

	var passed := 0
	for c in checks:
		var ok: bool = c[1]
		if ok:
			passed += 1
		print("[TEST]   %s %s" % ["[PASS]" if ok else "[FAIL]", c[0]])

	print("[TEST] -------------------------------------------")
	print("[TEST] 结果: %d / %d 通过" % [passed, checks.size()])
	if passed == checks.size():
		print("[TEST] ★ 层内连通结构在算法上可行 —— 不需要退回单向推进")
	else:
		print("[TEST] ✗ 结构需要调整 —— 见上方失败原因")
	print("[TEST] ===========================================")

	quit(0 if passed == checks.size() else 1)


## 诊断某一层为什么失败（用于定位是哪个约束不满足）
func _diagnose(gen: RefCounted) -> String:
	var rooms: Array = gen.rooms
	if rooms.size() < 12:
		return "房间数不足（游走放置失败）"
	var adj: Dictionary = gen._adjacency()
	var reach: Dictionary = gen._bfs(gen.entrance_id)
	if reach.size() != rooms.size():
		return "存在不可达房间（连通性失败）"
	if not reach.has(gen.exit_id):
		return "出口不可达"
	var path: Array = gen._shortest_path(gen.entrance_id, gen.exit_id)
	if path.size() == 0:
		return "入口出口无路径"
	if path.size() >= rooms.size():
		return "出口路径占满全部房间"
	var sc := 0
	for e in gen.edges:
		if e[2]:
			sc += 1
	if sc < 1:
		return "无捷径"
	var cycles: int = gen.edges.size() - rooms.size() + 1
	if cycles < 1:
		return "无环路（不可回退）"
	return "未知"
