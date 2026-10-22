extends SceneTree
var started := false
var f := 0
var lvl: Node2D = null
var p: CharacterBody2D = null
func _physics_process(_d: float) -> bool:
	if not started:
		started = true
		var sc: PackedScene = load("res://scenes/world/generated_level.tscn")
		lvl = sc.instantiate() as Node2D
		get_root().add_child(lvl)
		return false
	f += 1
	if f < 40: return false
	if f > 600: return true
	p = lvl.get_node_or_null("Player")
	if p == null: return true
	Input.action_press("move_right")
	if f == 400:
		print("[S] 位置=", p.position, " 状态=", p.get("debug_state_name"), " vx=", p.velocity.x)
		var n := p.get_slide_collision_count()
		print("[S] 碰撞数=", n)
		for i in n:
			var c := p.get_slide_collision(i)
			var col = c.get_collider()
			print("[S]   撞到类=", col.get_class(), " 名=", col.name, " 法线=", c.get_normal())
		return false
	return false