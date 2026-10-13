extends RefCounted
## 帧驱动状态机内核（阶段 0 任务 0.6）
##
## 为什么用「帧」而不是「秒」：
##   攻击前摇 4 帧 / 有效帧 3 帧 / 后摇 8 帧 —— 这些是格斗游戏式的时间单位，
##   用帧计数才能精确复现，也方便和 DESIGN.md 第 6 节的手感表直接对照。
##
## 顿帧（Hit Stop）如何兼容：
##   顿帧期间由外部「不调用 tick()」，所以帧计数自然冻结 ——
##   不需要在这里做特殊处理，动画和判定窗口都自动对齐。
##
## 用法：
##   var sm := StateMachine.new()
##   sm.add_state(&"idle", 0, [&"run", &"jump"])   # 名称, 最小帧数, 可转入的状态
##   sm.set_state(&"idle")
##   sm.tick()                                     # 每物理帧调用一次
##   if sm.is_state(&"idle") and sm.frame == 0: ...

## 状态定义：name -> { min_frames: int, next: Array[StringName] }
var _defs: Dictionary = {}
var _current: StringName = &""
var _frame: int = 0

## 上一次切换的来源（调试用）
var previous: StringName = &""


## 注册一个状态。
## min_frames     该状态至少要持续几帧才能转出（防止同帧反复横跳）
## next           允许转入的状态名列表；空数组 = 不限制
func add_state(p_name: StringName, p_min_frames: int = 0, p_next: Array = []) -> void:
	_defs[p_name] = {
		"min_frames": p_min_frames,
		"next": p_next,
	}


func has_state(p_name: StringName) -> bool:
	return _defs.has(p_name)


## 当前状态名
func get_state() -> StringName:
	return _current


## 在当前状态已持续的帧数（从 0 开始）
func get_frame() -> int:
	return _frame


func is_state(p_name: StringName) -> bool:
	return _current == p_name


## 是否处于这些状态中的任意一个
func is_any(names: Array) -> bool:
	return names.has(_current)


## 切换到新状态。返回是否切换成功。
## 会校验：目标状态已注册 + 当前状态已达最小帧数 + 允许该转换
func set_state(p_name: StringName) -> bool:
	if not _defs.has(p_name):
		push_warning("StateMachine: 未注册的状态 '%s'" % p_name)
		return false

	if _current == p_name:
		return false

	# 首次进入不做转换校验
	if _current != &"":
		var cur: Dictionary = _defs[_current]
		if _frame < int(cur["min_frames"]):
			return false
		var allowed: Array = cur["next"]
		if allowed.size() > 0 and not allowed.has(p_name):
			return false

	previous = _current
	_current = p_name
	_frame = 0
	return true


## 强制切换，忽略最小帧数与转换表（物理事件如"掉下平台"用）
func force_state(p_name: StringName) -> void:
	if not _defs.has(p_name):
		return
	if _current == p_name:
		return
	previous = _current
	_current = p_name
	_frame = 0


## 推进一帧。顿帧期间不要调用本方法。
func tick() -> void:
	_frame += 1


## 当前状态是否已播完（用于攻击后摇结束时自动转出）
func frame_reached(n: int) -> bool:
	return _frame >= n


func describe() -> String:
	return "%s(f%d)" % [_current, _frame]
