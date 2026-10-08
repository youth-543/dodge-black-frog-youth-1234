extends CharacterBody2D

## 玩家小球脚本：用键盘（WASD / 方向键）控制移动，并且不能跑出窗口。

# 移动速度：每秒移动多少像素
const SPEED := 300.0

# 视觉放大倍数：只放大奶蛙"显示"（贴图/光晕），碰撞箱、速度、难度完全不变。
# 手机真机实测后把视觉整体放大到 1.6 倍（碰撞体保持原尺寸，不改判定）
const VISUAL_SCALE_MULT := 1.6
# 光晕贴图在 tscn 里的基础缩放（放大时按同比例跟随，保持光晕与身体的比例）
const GLOW_BASE_SCALE := 0.55

# 当前显示的奶蛙编号（1 ~ 10）
var current_frog := 1

# 边界限制用的半径（随着奶蛙变大会增大，防止身体一半跑出屏幕）
var _clamp_radius := 20.0

# —— 10 张奶蛙图的碰撞与显示配置 ——
# type: 形状类型 "circle" / "capsule" / "rectangle"
# radius: 碰撞半径（约为主体实际显示长边的 0.44 倍，圆形身体）
# height: 仅胶囊用，总高度（含两端圆头）
# size: 仅矩形用，Vector2(宽, 高)
# target_size: 奶蛙"主体"的目标显示尺寸（像素）。
#   关键：以"主体实际长边"为缩放基准，而不是图片长边！
#   每张图的主体占图比例差异很大（53%~100%），只看图片尺寸会导致
#   某些阶段看起来没变大甚至变小。subject_px 是用 alpha 通道实测的
#   主体包围盒长边（frog-10 用"身体亮核"测量，翅膀和光晕不计入）。
#   运行时缩放 = target_size ÷ subject_px，宽高比不变（不变形）。
#   9 个阶段的 target_size 每级约 +10~11%（面积 +21~23%），逐级明显变大。
# comment: 这张图的备注
const FROG_CONFIGS := {
	1: {"type": "circle",    "radius": 20.0, "subject_px": 313.0,  "target_size": 45.0,  "comment": "初始小奶蛙，主体占图90%"},
	2: {"type": "circle",    "radius": 22.0, "subject_px": 771.0,  "target_size": 50.0,  "comment": "主体占图91%"},
	3: {"type": "circle",    "radius": 24.0, "subject_px": 845.0,  "target_size": 55.0,  "comment": "主体占图99%"},
	4: {"type": "capsule",   "radius": 22.0, "height": 50.0, "subject_px": 601.0, "target_size": 61.0, "comment": "肌肉奶蛙，张开手臂占满图，稍宽胶囊形"},
	5: {"type": "circle",    "radius": 29.0, "subject_px": 809.0,  "target_size": 67.5, "comment": "大笑奶蛙，主体占图95%"},
	6: {"type": "circle",    "radius": 33.0, "subject_px": 754.0,  "target_size": 74.5, "comment": "胖奶蛙，主体只占图74%，必须按主体算"},
	7: {"type": "circle",    "radius": 36.0, "subject_px": 1014.0, "target_size": 82.5, "comment": "怀孕姿势奶蛙，主体占图94%"},
	8: {"type": "capsule",   "radius": 26.0, "height": 71.0, "subject_px": 1708.0, "target_size": 91.0, "comment": "西装奶蛙，瘦高，偏高胶囊形"},
	9: {"type": "rectangle", "size": Vector2(66, 48), "subject_px": 800.0, "target_size": 92.0, "comment": "侠客奶蛙（已从9阶段成长流程移除，此配置保留不使用）"},
	10: {"type": "circle",   "radius": 44.0, "subject_px": 508.0,  "target_size": 100.0, "comment": "天使奶蛙，按身体亮核测量（不含翅膀光晕），翅膀只算视觉"},
}


func _ready() -> void:
	# 游戏启动时，按当前 frog 编号设置好碰撞体、贴图和显示大小
	_set_frog(current_frog)


func _physics_process(_delta: float) -> void:
	# get_vector 会把"左、右、上、下"四个按键合并成一个方向向量。
	# 同时按两个键斜着走时，速度也不会变快（它会自动处理）。
	var direction := Input.get_vector("move_left", "move_right", "move_up", "move_down")

	# velocity 是 CharacterBody2D 自带的属性：
	# 表示"这一帧我打算往哪个方向、以多快的速度移动"。
	velocity = direction * SPEED

	# 真正执行移动。以后有墙壁、敌人时，碰撞也是在这里自动处理的。
	move_and_slide()

	# 把位置"夹"在窗口范围内，防止跑出屏幕。
	# 用当前奶蛙的实际半径，这样变大之后也不会半身出屏幕
	var screen_size := get_viewport_rect().size
	position.x = clampf(position.x, _clamp_radius, screen_size.x - _clamp_radius)
	position.y = clampf(position.y, _clamp_radius, screen_size.y - _clamp_radius)


# 根据奶蛙编号切换碰撞体、贴图和显示大小
# 之后做"15秒换图"或"奶蛙成长"时，只需要调用这个函数即可
func _set_frog(frog_id: int) -> void:
	current_frog = frog_id
	var cfg: Dictionary = FROG_CONFIGS[frog_id]

	# 1) 创建对应形状的碰撞体
	var shape: Shape2D
	match cfg["type"]:
		"circle":
			var c := CircleShape2D.new()
			c.radius = cfg["radius"]
			shape = c
		"capsule":
			var cap := CapsuleShape2D.new()
			cap.radius = cfg["radius"]
			cap.height = cfg["height"]
			shape = cap
		"rectangle":
			var r := RectangleShape2D.new()
			r.size = cfg["size"]
			shape = r

	# 2) 应用到玩家物理碰撞体和 HurtBox 检测区域
	$CollisionShape2D.shape = shape
	$HurtBox/CollisionShape2D.shape = shape

	# 3) 更新贴图（frog-01.jpg ~ frog-10.jpg）：
	#    优先使用去背景的 PNG 版本（如果存在），否则回退到原始 JPG。
	#    以后哪张图做了透明处理，把 PNG 放进 assets/frog 就会自动生效
	var png_path := "res://assets/frog/frog-%02d.png" % frog_id
	var path := png_path if ResourceLoader.exists(png_path) else "res://assets/frog/frog-%02d.jpg" % frog_id
	var tex: Texture2D = load(path)
	$Body.texture = tex

	# 4) 等比缩放到目标显示尺寸：以"主体实际长边"（subject_px，实测）为基准，
	#    缩放 = 目标尺寸 ÷ 主体长边。这样不管原图留白多少，
	#    奶蛙身体在游戏里的实际大小都严格等于 target_size，逐级稳定变大。
	#    x、y 用同一个值，宽高比不变（不变形）。
	#    最后再统一乘 VISUAL_SCALE_MULT 做纯视觉放大——碰撞形状在第 1、2 步已定死，不受影响
	var s: float = cfg["target_size"] / cfg["subject_px"] * VISUAL_SCALE_MULT
	$Body.scale = Vector2(s, s)
	# 光晕是纯视觉节点，按同比例跟随放大
	$Glow.scale = Vector2(GLOW_BASE_SCALE * VISUAL_SCALE_MULT, GLOW_BASE_SCALE * VISUAL_SCALE_MULT)

	# 5) 更新边界限制半径（取碰撞体最宽处的半径，防止半身出屏幕）
	match cfg["type"]:
		"circle":
			_clamp_radius = cfg["radius"]
		"capsule":
			_clamp_radius = maxf(cfg["radius"], cfg["height"] * 0.5)
		"rectangle":
			_clamp_radius = maxf(cfg["size"].x, cfg["size"].y) * 0.5


# ——成长弹跳动画——
# 只在阶段切换成功时由主场景调用（开局第一次显示 frog-01 不调用）。
# 只缩放 Body 贴图节点：碰撞体是它的兄弟节点，完全不受影响；
# 结束时精确回到本阶段设定的正常大小；玩家根节点位置不动，不会跳位
func _play_grow_anim() -> void:
	var body: Sprite2D = $Body
	var final_scale: Vector2 = body.scale  # _set_frog 刚算好的本阶段正常大小
	body.scale = final_scale * 0.87  # 起手先缩到 87%
	var tw := create_tween()
	tw.tween_property(body, "scale", final_scale * 1.05, 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)  # 弹到 105%
	tw.tween_property(body, "scale", final_scale, 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)  # 回落 100%
