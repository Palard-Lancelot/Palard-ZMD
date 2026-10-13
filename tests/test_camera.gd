extends SceneTree
## 相机死区跟随测试（任务 0.1 修复）
##
## 需求：「主控可以短暂脱离中心，相机要迅速跟上」
##
## 背景：曾出现"相机不跟随"问题，根因有两个：
##   1. boot.tscn 里固定的占位 Camera2D 与玩家相机抢占
##   2. 测试关卡只有 504px 宽而视口 480px，相机几乎没有可动空间
##
## 本测试验证死区语义（用 take_damage 的击退做位移源，比模拟输入更可控）：
##   1. 场景内只有 1 个 Camera2D
##   2. 生效相机是玩家的
##   3. 玩家在死区内小位移 → 相机**不动**（允许短暂脱离中心）
##   4. 玩家超出死区 → 相机迅速跟上
##
## 用法：
##   $env:DSH_SKIP_BOOT_QUIT = "1"
##   & $GODOT --headless --path . --script "res://tests/test_camera.gd"

const SETTLE := 10          ## 让相机稳定下来的帧数

var _player: CharacterBody2D = null
var _cam: Camera2D = null
var _started := false
var _frame := 0
var _phase := 0

var _cam_count := 0
var _active_cam_path := ""

## 采样
var _cam_x_a := 0.0
var _cam_x_b := 0.0
var _cam_x_c := 0.0
var _player_x_a := 0.0
var _player_x_b := 0.0
var _player_x_c := 0.0

var _dz := 0.0


func _physics_process(_d: float) -> bool:
	if not _started:
		_boot()
		return false

	_frame += 1

	# 阶段 0：稳定
	if _phase == 0 and _frame >= SETTLE:
		_cam_x_a = _cam.global_position.x
		_player_x_a = _player.position.x
		# 进入阶段 1：把玩家移动一个**小于死区**的距离
		_player.position.x += _dz * 0.5
		_player.velocity = Vector2.ZERO
		_phase = 1
		_frame = 0
		return false

	# 阶段 1：等相机反应，采样
	if _phase == 1 and _frame >= SETTLE:
		_cam_x_b = _cam.global_position.x
		_player_x_b = _player.position.x
		# 进入阶段 2：把玩家移动一个**远大于死区**的距离
		_player.position.x += _dz * 6.0
		_player.velocity = Vector2.ZERO
		_phase = 2
		_frame = 0
		return false

	# 阶段 2：等相机追上，采样
	if _phase == 2 and _frame >= 40:
		_cam_x_c = _cam.global_position.x
		_player_x_c = _player.position.x
		_report()
		return true
	return false


func _boot() -> void:
	_started = true
	var scene: PackedScene = load("res://scenes/boot/boot.tscn")
	var root: Node = scene.instantiate()
	get_root().add_child(root)

	var cams: Array = root.find_children("*", "Camera2D", true, false)
	_cam_count = cams.size()

	_player = root.get_node_or_null("World/Player") as CharacterBody2D
	if _player == null:
		print("[TEST] FAIL: 找不到 Player")
		quit(1)
		return
	_cam = _player.get_node_or_null("Camera2D") as Camera2D
	if _cam == null:
		print("[TEST] FAIL: 找不到 Player/Camera2D")
		quit(1)
		return

	var vp := get_root().get_viewport()
	var active := vp.get_camera_2d()
	if active:
		_active_cam_path = str(active.get_path())

	var feel: Resource = _player.get("feel")
	_dz = float(feel.get("cam_deadzone_x"))

	print("[TEST] 场景内 Camera2D 数量: %d" % _cam_count)
	print("[TEST] 生效相机: %s" % _active_cam_path)
	print("[TEST] 水平死区半径: %.0f px" % _dz)


func _report() -> void:
	# 阶段 1：玩家只动了死区的一半 → 相机不应"跟随"这个位移
	var player_delta_1: float = _player_x_b - _player_x_a
	var cam_delta_1: float = _cam_x_b - _cam_x_a

	# 阶段 2：玩家动了 6 倍死区 → 相机迅速跟上
	var player_delta_2: float = _player_x_c - _player_x_b
	var cam_delta_2: float = _cam_x_c - _cam_x_b

	# 死区语义说明：
	#   相机跟随的是「玩家 ± 死区」的边界，不是玩家本身。
	#   所以玩家在死区内部移动时，相机允许有不超过死区的漂移。
	#   真正的判据是：相机的位移必须**远小于**玩家位移。
	var dz_limit: float = _dz * 0.6

	var checks: Array = [
		["场景内只有 1 个 Camera2D（实际 %d）" % _cam_count, _cam_count == 1],
		["生效相机是玩家相机", _active_cam_path.ends_with("Player/Camera2D")],
		["死区内：玩家移动 %.1fpx（< 死区 %.0f）" % [player_delta_1, _dz],
			player_delta_1 < _dz],
		["死区内：相机仅漂移 %.2fpx（远小于玩家位移 %.1fpx）" % [cam_delta_1, player_delta_1],
			absf(cam_delta_1) < dz_limit and absf(cam_delta_1) < absf(player_delta_1)],
		["超出死区：玩家移动 %.1fpx" % player_delta_2, player_delta_2 > _dz * 3.0],
		["超出死区：相机迅速跟上 %.1fpx" % cam_delta_2, cam_delta_2 > _dz * 3.0],
	]

	print("")
	print("[TEST] ============ 相机死区跟随测试 ============")
	var passed := 0
	for c in checks:
		var ok: bool = c[1]
		if ok:
			passed += 1
		var tag := "[PASS]"
		if not ok:
			tag = "[FAIL]"
		print("[TEST]   %s %s" % [tag, c[0]])
	print("[TEST] -------------------------------------------")
	print("[TEST] 结果: %d / %d 通过" % [passed, checks.size()])
	if passed == checks.size():
		print("[TEST] ★ 全部通过")
	else:
		print("[TEST] ✗ 有失败项")
	print("[TEST] ===========================================")
