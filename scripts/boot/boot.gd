extends Node2D
## 启动场景（阶段 0 任务 0.1 + 0.3 + 0.4）
##
## 职责：
##   1. 创建唯一的 FeelConfig 实例（手感参数的权威来源）
##   2. 把它交给调试面板，生成实时滑块
##   3. 打印启动自检信息，方便命令行验证
##
## 后续阶段 0 任务（0.5 起）会在这里挂载玩家与测试场景。

const FeelConfigScript := preload("res://scripts/config/feel_config.gd")

const BOOTSTRAP_LOG_PREFIX := "[BOOT]"

## 手感配置 —— 全局唯一实例
## 用 Resource 而非 FeelConfig 类型标注：
##   script 的 class_name 全局注册与 preload 混用会在首帧解析时报
##   "Could not find type FeelConfig"，故统一用 Resource + 显式 cast。
var feel: Resource = null

@onready var debug_panel: CanvasLayer = $DebugPanel
@onready var world: Node2D = $World


func _ready() -> void:
	feel = FeelConfigScript.new()
	_log("FeelConfig 已创建（%d 个可调参数）" % _count_tunable(feel))

	debug_panel.bind(feel)
	_log("调试面板已绑定 —— 按 F1 打开")

	# 把手感配置注入世界（玩家从 TestLevel 拿到它）
	if world.has_method("setup_player"):
		world.setup_player(feel)
		_log("FeelConfig 已注入 World")
	else:
		push_warning("World 节点没有 setup_player() 方法 —— 玩家将拿不到手感配置")

	_register_game_time()
	_print_feel_summary()
	_print_validation()

	# 无头模式下直接退出，供命令行自检使用。
	# ⚠️ 自动化测试会以本场景为依赖加载，此时必须跳过退出，
	#    否则整个 SceneTree 会提前结束，测试跑不完。
	#    用法：设置环境变量 DSH_SKIP_BOOT_QUIT=1
	var skip_quit := OS.get_environment("DSH_SKIP_BOOT_QUIT") == "1"
	if DisplayServer.get_name() == "headless" and not skip_quit:
		_log("headless 自检完成，退出")
		get_tree().quit()
	else:
		_log("进入游戏 —— A/D 移动 · Space 跳 · J 攻击 · L 冲刺 · R 重开 · F1 调参")


## 把玩家相机注册到 GameTime，屏震才有作用对象
func _register_game_time() -> void:
	var gt := get_node_or_null("/root/GameTime")
	if gt == null:
		push_warning("GameTime 单例不存在 —— 检查 project.godot 的 [autoload] 段")
		return
	var cam := world.get_node_or_null("Player/Camera2D") as Camera2D
	if cam:
		gt.register_camera(cam)
		_log("相机已注册到 GameTime（屏震可用）")


# 注意：不要在这里手动调用 GameTime.tick()。
# GameTime 是 autoload，已经自己在 _physics_process 里驱动 tick。
# 之前在这里手动调 + autoload 自驱 = 双重递减，顿帧只有一半时长。
# 而且一旦场景里没有 boot（如 generated_level），手动调用就消失了，
# 导致顿帧永不结束 —— 这个 bug 曾让玩家第一次挨打后永久卡死。


func _unhandled_input(event: InputEvent) -> void:
	# 占位：阶段 0 后续任务会在这里处理玩家生成 / 重开
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE and not DisplayServer.get_name() == "headless":
			get_tree().quit()


# ============================================================
# 自检输出
# ============================================================

func _print_feel_summary() -> void:
	_log("--- 手感参数摘要 ---")
	_log("  重力            %.1f px/s2" % feel.gravity)
	_log("  跳跃初速        %.1f px/s" % feel.jump_velocity)
	_log("  => 跳跃高度     %.1f px（目标 48 = 3 格）" % feel.jump_height_px())
	_log("  => 滞空时间     %.3f s（目标 0.75）" % feel.jump_airtime_seconds())
	_log("  最大水平速度    %.1f px/s" % feel.max_run_speed)
	_log("  土狼时间        %.3f s" % feel.coyote_time)
	_log("  跳跃缓冲        %.3f s" % feel.jump_buffer_time)
	_log("  顿帧 命中/击杀  %d / %d 帧" % [feel.hitstop_hit_frames, feel.hitstop_kill_frames])
	_log("  受击无敌        %d 帧" % feel.hurt_iframe_frames)


func _print_validation() -> void:
	var problems: Array = feel.validate()
	if problems.is_empty():
		_log("参数自洽性检查：通过 ✓")
	else:
		_log("参数自洽性检查：%d 个提示" % problems.size())
		for p in problems:
			_log("  ⚠ " + p)


func _count_tunable(res: Resource) -> int:
	var n := 0
	for prop in res.get_property_list():
		var ptype: int = prop.get("type", 0)
		var pusage: int = prop.get("usage", 0)
		if (pusage & PROPERTY_USAGE_EDITOR) and (ptype == TYPE_INT or ptype == TYPE_FLOAT):
			n += 1
	return n


func _log(msg: String) -> void:
	print("%s %s" % [BOOTSTRAP_LOG_PREFIX, msg])
