extends Control
## 启动菜单（DESIGN v1.3）
##
## 两个入口：
##   1 · 随机生成层 —— 每按 R 换一层，验证「层内连通可回退」+ 竖井下穿
##   2 · 手写测试关 —— 固定布局，清光 9 个敌人（0.12 试玩用）
##
## 键盘：1 / 2 直接进入；鼠标点击同样有效；Esc 退出
##
## ⚠️ 本场景是 main_scene，所以**无头自检也走这里**。
##    README 记录的期望输出「参数自洽性检查：通过 ✓」必须继续成立，
##    否则每周的 `--headless --quit-after 300` 自检就失效了。
##
## ⚠️ 从关卡返回菜单时，上一关的相机已被释放：
##    必须 GameTime.reset() + unregister_camera()，
##    否则屏震逻辑会去写一个已释放对象的 offset。

const FeelConfigScript := preload("res://scripts/config/feel_config.gd")

const HAND_LEVEL := "res://scenes/boot/boot.tscn"
const GEN_LEVEL := "res://scenes/world/generated_level.tscn"

const FONT_TITLE := 26
const FONT_SUB := 10
const FONT_BTN := 12
const FONT_HINT := 9

var _buttons: Array = []
var _starting := false


func _ready() -> void:
	_clear_previous_level_state()
	_build_ui()

	if DisplayServer.get_name() == "headless":
		_headless_selfcheck()
		get_tree().quit()
		return

	# 窗口模式也打一行：导出后排查"为什么直接进了某一关"全靠它
	print("[MENU] 已进入启动菜单 —— 1 随机层 / 2 手写关 / Esc 退出")

	if _buttons.size() > 0:
		var first: Button = _buttons[0]
		first.grab_focus()


## 清掉上一关残留：顿帧计数、屏震状态、已释放的相机引用
func _clear_previous_level_state() -> void:
	var gt := get_node_or_null("/root/GameTime")
	if gt == null:
		return
	gt.reset()
	gt.unregister_camera()


# ============================================================
# UI
# ============================================================

func _build_ui() -> void:
	# 根 Control 属于场景根（有视口尺寸），锚点可以正常使用。
	# ⚠️ 这条与「CanvasLayer 上的 UI 不要用 anchors」不冲突 —— 那是另一回事。
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = 0.0
	offset_top = 0.0
	offset_right = 0.0
	offset_bottom = 0.0

	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.07, 0.10, 1.0)
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var center := CenterContainer.new()
	center.anchor_right = 1.0
	center.anchor_bottom = 1.0
	add_child(center)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	center.add_child(box)

	var title := Label.new()
	title.text = "PALARD . ZMD"
	title.add_theme_font_size_override("font_size", FONT_TITLE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.modulate = Color(0.55, 0.85, 1.0)
	box.add_child(title)

	var sub := Label.new()
	sub.text = "2D 横板肉鸽 · 阶段 0 原型"
	sub.add_theme_font_size_override("font_size", FONT_SUB)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.modulate = Color(0.55, 0.58, 0.65)
	box.add_child(sub)

	box.add_child(_spacer(10))

	_add_entry(box, "1 · 随机生成层",
		"每按 R 换一层 · 层内连通可回退 · 竖井攀爬 / S+Space 下穿",
		GEN_LEVEL, Color(0.45, 0.95, 0.85))
	_add_entry(box, "2 · 手写测试关",
		"固定布局 · 清光 9 个敌人 · 0.12 试玩用",
		HAND_LEVEL, Color(0.95, 0.85, 0.45))

	box.add_child(_spacer(10))

	var hint := Label.new()
	hint.text = "点击选择 · 或按 1 / 2 进入 · 关卡内 Esc 返回菜单 · Esc 退出"
	hint.add_theme_font_size_override("font_size", FONT_HINT)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.modulate = Color(0.45, 0.47, 0.52)
	box.add_child(hint)


func _spacer(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0.0, h)
	return c


## 一个入口 = 按钮 + 一行说明
func _add_entry(parent: VBoxContainer, text: String, desc: String,
		scene_path: String, color: Color) -> void:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(300.0, 30.0)
	btn.add_theme_font_size_override("font_size", FONT_BTN)
	btn.add_theme_color_override("font_color", color)
	btn.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	btn.pressed.connect(_start.bind(scene_path))
	parent.add_child(btn)
	_buttons.append(btn)

	var label := Label.new()
	label.text = desc
	label.add_theme_font_size_override("font_size", FONT_HINT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.modulate = Color(0.5, 0.53, 0.58)
	parent.add_child(label)


# ============================================================
# 输入 / 切换
# ============================================================

func _unhandled_input(event: InputEvent) -> void:
	if _starting:
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return

	var handled := true
	match event.keycode:
		KEY_1, KEY_KP_1:
			_start(GEN_LEVEL)
		KEY_2, KEY_KP_2:
			_start(HAND_LEVEL)
		KEY_ESCAPE:
			get_tree().quit()
		_:
			handled = false

	if handled:
		get_viewport().set_input_as_handled()


func _start(scene_path: String) -> void:
	if _starting:
		return
	_starting = true
	print("[MENU] 进入：%s" % scene_path)
	_clear_previous_level_state()

	var err: int = get_tree().change_scene_to_file(scene_path)
	if err != OK:
		_starting = false
		push_error("切换场景失败：%s（错误码 %d）" % [scene_path, err])


# ============================================================
# 无头自检（等价于原 boot.gd 的自检输出，保持 README 的验收方式不变）
# ============================================================

func _headless_selfcheck() -> void:
	var feel: Resource = FeelConfigScript.new()
	print("[MENU] 启动菜单就绪（headless 自检）")
	print("[MENU]   重力 %.1f px/s2 · 跳跃初速 %.1f px/s" % [feel.gravity, feel.jump_velocity])
	print("[MENU]   => 跳跃高度 %.1f px（目标 48）· 滞空 %.3f s（目标 0.75）" % [
		feel.jump_height_px(), feel.jump_airtime_seconds()])

	var problems: Array = feel.validate()
	if problems.is_empty():
		print("[MENU] 参数自洽性检查：通过 ✓")
	else:
		for p in problems:
			print("[MENU]   ⚠ " + p)
