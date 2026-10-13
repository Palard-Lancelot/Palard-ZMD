extends CanvasLayer
## 实时手感调参面板（阶段 0 任务 0.4）
##
## 设计约束（DESIGN.md 第 12 节）：
##   手感参数必须实时可调，不得硬编码 → 本面板是这条约束的落地
##
## 实现要点：
##   - 通过 Godot 反射（get_property_list）自动枚举 FeelConfig 的 @export 字段，
##     所以以后往 FeelConfig 里加参数，面板会**自动出现新滑块**，不需要改这个文件。
##   - 拖动滑块实时写回 FeelConfig，游戏内立即生效（无需重新编译）。
##   - F11 开关面板。
##
## 快捷键：
##   F1   显示 / 隐藏面板（对应 InputMap 动作 toggle_debug_panel）
##   F5   保存当前数值到 user://feel_config_saved.tres（方便固化到项目）
##   R    全部重置为初始值

const FeelConfigScript := preload("res://scripts/config/feel_config.gd")

const SAVE_PATH := "user://feel_config_saved.tres"
## 面板宽度按「视口坐标」计（CanvasLayer 随 stretch 一起缩放）。
## 基准视口 480×270 → 150 约占 31%，留够空间看游戏。
const PANEL_WIDTH := 150.0
const FONT_SMALL := 8
const FONT_TITLE := 11

var feel: Resource = null

var _root: PanelContainer
var _list: VBoxContainer
var _status: Label
var _sliders: Dictionary = {}      ## property_name -> { slider, spin, initial }
var _groups: Dictionary = {}       ## group_name -> VBoxContainer


func _ready() -> void:
	layer = 100
	_build_ui()
	# 默认隐藏：让玩家先纯粹感受手感，需要调参时按 F1 打开。
	# （之前设成 is_debug_build() 默认展开，实测面板会挡住游戏主体）
	visible = false


## 由 boot.gd 调用：绑定手感配置并生成滑块
func bind(config: Resource) -> void:
	feel = config
	_rebuild_rows()
	_status.text = "FeelConfig 已绑定 · %d 个参数" % _sliders.size()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_debug_panel"):
		visible = not visible
		get_viewport().set_input_as_handled()
	elif visible and event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F5:
			_save_to_file()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_R:
			_reset_all()
			get_viewport().set_input_as_handled()


# ============================================================
# UI 构建
# ============================================================

func _build_ui() -> void:
	# 面板放在**左上角**（不是右上角）：玩家出生点在画面中部，
	# 右上角会挡住游戏主体；左上角只压住背景。
	_root = PanelContainer.new()
	_root.anchor_left = 0.0
	_root.anchor_right = 0.0
	_root.anchor_top = 0.0
	_root.anchor_bottom = 0.0
	_root.offset_left = 6.0
	_root.offset_right = 6.0 + PANEL_WIDTH
	_root.offset_top = 6.0
	_root.offset_bottom = 6.0
	_root.grow_vertical = Control.GROW_DIRECTION_END
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)
	_root.add_child(outer)

	# --- 标题 ---
	var title := Label.new()
	title.text = "手感调参"
	title.add_theme_font_size_override("font_size", FONT_TITLE)
	outer.add_child(title)

	# --- 状态行 ---
	_status = Label.new()
	_status.text = "未绑定 FeelConfig"
	_status.add_theme_font_size_override("font_size", FONT_SMALL)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.modulate = Color(0.7, 0.9, 0.7)
	outer.add_child(_status)

	var keys := Label.new()
	keys.text = "F1 开关 · F5 保存 · R 重置"
	keys.add_theme_font_size_override("font_size", FONT_SMALL)
	keys.modulate = Color(0.65, 0.65, 0.7)
	outer.add_child(keys)

	outer.add_child(HSeparator.new())

	# --- 滚动区 ---
	# 高度按视口 270 计：留出标题/状态行后约 200
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(PANEL_WIDTH - 14.0, 200.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 1)
	scroll.add_child(_list)


## 清空并从 FeelConfig 重新生成全部滑块
func _rebuild_rows() -> void:
	for c in _list.get_children():
		c.queue_free()
	_sliders.clear()
	_groups.clear()

	if feel == null:
		_status.text = "未绑定 FeelConfig —— 调用 bind() 后才有滑块"
		return

	var current_group := ""

	for prop in feel.get_property_list():
		var pname: String = prop.get("name", "")
		var ptype: int = prop.get("type", 0)
		var pusage: int = prop.get("usage", 0)

		# PROPERTY_USAGE_GROUP 的 name 就是分组名。
		# ⚠️ 必须排除 PROPERTY_USAGE_CATEGORY：脚本的类描述会被当成
		#    一个 category 抛出来（显示为 "— Resource"），那是垃圾分组。
		if pusage & PROPERTY_USAGE_CATEGORY:
			continue
		if pusage & PROPERTY_USAGE_GROUP:
			current_group = pname
			_add_group_header(current_group)
			continue

		# 只处理 @export 出来的属性
		if not (pusage & PROPERTY_USAGE_EDITOR):
			continue
		# 只处理 int / float
		if ptype != TYPE_INT and ptype != TYPE_FLOAT:
			continue

		_add_slider_row(pname, ptype, current_group)


func _add_group_header(group_name: String) -> void:
	var header := Label.new()
	header.text = "· " + group_name
	header.add_theme_font_size_override("font_size", FONT_SMALL + 1)
	header.modulate = Color(0.55, 0.8, 1.0)
	_list.add_child(header)


func _add_slider_row(pname: String, ptype: int, group_name: String) -> void:
	var is_int := ptype == TYPE_INT
	var value = feel.get(pname)

	# 从 @export_range 读取范围（以 hint 形式暴露）
	var hint: int = PROPERTY_HINT_NONE
	var hint_string := ""
	for prop in feel.get_property_list():
		if prop.get("name", "") == pname:
			hint = prop.get("hint", 0)
			hint_string = prop.get("hint_string", "")
			break

	var vmin := 0.0
	var vmax := 1.0
	var vstep := 0.01
	if hint == PROPERTY_HINT_RANGE and hint_string != "":
		var parts := hint_string.split(",")
		if parts.size() >= 3:
			vmin = float(parts[0])
			vmax = float(parts[1])
			vstep = float(parts[2])
	else:
		# 没有显式 range 时按当前值推断一个合理范围
		var fv := float(value)
		vmin = minf(0.0, fv * 2.0)
		vmax = maxf(1.0, absf(fv) * 4.0)
		vstep = 0.01

	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 0)
	_list.add_child(row)

	var label := Label.new()
	label.text = "%s = %s" % [pname, _fmt(value, is_int)]
	label.add_theme_font_size_override("font_size", FONT_SMALL)
	label.clip_text = true
	row.add_child(label)

	var slider := HSlider.new()
	slider.min_value = vmin
	slider.max_value = vmax
	slider.step = vstep
	slider.value = float(value)
	slider.custom_minimum_size = Vector2(PANEL_WIDTH - 26.0, 0.0)
	row.add_child(slider)

	_sliders[pname] = {
		"slider": slider,
		"label": label,
		"is_int": is_int,
		"initial": value,
	}

	slider.value_changed.connect(_on_slider_changed.bind(pname))


func _on_slider_changed(v: float, pname: String) -> void:
	if feel == null:
		return
	var info: Dictionary = _sliders.get(pname, {})
	if info.is_empty():
		return
	var is_int: bool = info["is_int"]
	var new_value = int(round(v)) if is_int else v
	feel.set(pname, new_value)

	var label: Label = info["label"]
	label.text = "%s = %s" % [pname, _fmt(new_value, is_int)]

	if feel.verbose_log:
		print("[FeelConfig] %s = %s" % [pname, new_value])

	# 实时提示参数自洽性
	_update_validation()


func _update_validation() -> void:
	if feel == null:
		return
	var problems: Array = feel.validate()
	if problems.is_empty():
		_status.text = "参数自洽 ✓"
		_status.modulate = Color(0.6, 1.0, 0.6)
	else:
		_status.text = "⚠ " + problems[0]
		_status.modulate = Color(1.0, 0.75, 0.4)


func _reset_all() -> void:
	if feel == null:
		return
	for pname in _sliders.keys():
		var info: Dictionary = _sliders[pname]
		var initial = info["initial"]
		feel.set(pname, initial)
		var slider: HSlider = info["slider"]
		slider.set_value_no_signal(float(initial))
		var label: Label = info["label"]
		label.text = "%s = %s" % [pname, _fmt(initial, info["is_int"])]
	_status.text = "已重置为初始值"
	_status.modulate = Color(0.7, 0.9, 0.7)


func _save_to_file() -> void:
	if feel == null:
		return
	var err := ResourceSaver.save(feel, SAVE_PATH)
	if err == OK:
		_status.text = "已保存 → " + SAVE_PATH
		_status.modulate = Color(0.6, 1.0, 0.6)
		print("[FeelConfig] 已保存调参结果到 ", ProjectSettings.globalize_path(SAVE_PATH))
	else:
		_status.text = "保存失败（错误码 %d）" % err
		_status.modulate = Color(1.0, 0.5, 0.5)


func _fmt(v, is_int: bool) -> String:
	if is_int:
		return str(int(v))
	return "%.2f" % float(v)
