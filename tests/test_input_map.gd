extends SceneTree
## 键位绑定验证（阶段 0 任务 0.2）
##
## 用途：确认 project.godot 里的输入映射与设计一致。
## 键位是设计决策（DESIGN.md / README），改错会让所有测试与文档失配，
## 所以单独用一个测试守住它。
##
## 用法：
##   & $GODOT --headless --path . --script "res://tests/test_input_map.gd"

## 期望绑定：动作 -> 允许的物理键码集合（顺序无关）
## 物理键码参考：A=65 D=68 W=87 S=83 Space=32 J=74 K=75
const EXPECTED := {
	"move_left":  [65, 4194319],          # A / Left
	"move_right": [68, 4194321],          # D / Right
	"move_up":    [87, 4194320],          # W / Up
	"move_down":  [83, 4194322],          # S / Down
	"jump":       [32],                   # 仅 Space（J 已移除）
	"attack":     [74],                   # J（原 L=76 已改）
	"dash":       [76],                   # L（原 K=75 已改）
}

var _results: Array = []


func _initialize() -> void:
	print("")
	print("[TEST] ============== 键位绑定验证 ==============")
	var passed := 0
	var total := 0

	for action in EXPECTED.keys():
		var want: Array = EXPECTED[action]
		total += 1

		if not InputMap.has_action(action):
			_results.append(["动作 %s 存在" % action, false, "缺失"])
			print("[TEST]   [FAIL] %-12s 动作未注册" % action)
			continue

		var got: Array = []
		for e in InputMap.action_get_events(action):
			if e is InputEventKey:
				got.append(e.physical_keycode)

		var ok: bool = _same_set(got, want)
		if ok:
			passed += 1
		var tag := "[PASS]"
		if not ok:
			tag = "[FAIL]"
		var got_names: Array = []
		for k in got:
			got_names.append(OS.get_keycode_string(k))
		print("[TEST]   %s %-12s 实际绑定: %s" % [tag, action, ", ".join(got_names)])
		if not ok:
			var want_names: Array = []
			for k in want:
				want_names.append(OS.get_keycode_string(k))
			print("[TEST]         期望: %s" % ", ".join(want_names))

	print("[TEST] -------------------------------------------")
	print("[TEST] 结果: %d / %d 通过" % [passed, total])
	if passed == total:
		print("[TEST] ★ 键位与设计一致")
	else:
		print("[TEST] ✗ 键位与设计不符 —— 检查 project.godot 的 [input] 段")
	print("[TEST] ===========================================")
	quit(0 if passed == total else 1)


## 比较两个键码集合是否相同（忽略顺序与重复）
func _same_set(a: Array, b: Array) -> bool:
	var sa := {}
	for x in a:
		sa[x] = true
	var sb := {}
	for x in b:
		sb[x] = true
	if sa.size() != sb.size():
		return false
	for k in sa.keys():
		if not sb.has(k):
			return false
	return true
