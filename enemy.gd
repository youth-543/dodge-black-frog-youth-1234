extends CharacterBody2D

## 敌人（红球）脚本：一直朝着玩家所在的位置移动。

# 敌人的移动速度：每秒多少像素。默认 120（比玩家 300 慢），
# 主场景生成新红球时会按难度曲线设置这个值
var speed := 120.0

# 纯视觉放大倍数：只放大黑蛙贴图与光晕，碰撞半径（enemy.tscn 中 20）保持不变。
# 与奶蛙一致取 1.6，手机真机上更容易观察；速度/数量/难度逻辑完全不受影响
const VISUAL_SCALE_MULT := 1.6
const BODY_BASE_SCALE := 0.036
const GLOW_BASE_SCALE := 0.55

# 追踪目标（玩家）。进入游戏后，按 "player" 分组在场景树里找到它
var target: Node2D = null


func _ready() -> void:
	# 只放大显示节点：碰撞体是 Body/Glow 的兄弟节点，完全不受影响
	$Body.scale = Vector2(BODY_BASE_SCALE * VISUAL_SCALE_MULT, BODY_BASE_SCALE * VISUAL_SCALE_MULT)
	$Glow.scale = Vector2(GLOW_BASE_SCALE * VISUAL_SCALE_MULT, GLOW_BASE_SCALE * VISUAL_SCALE_MULT)


func _physics_process(_delta: float) -> void:
	# 还没找到玩家？就按 "player" 分组在场景树里找一次
	if target == null:
		target = get_tree().get_first_node_in_group("player")
	# 还是没找到（玩家还没进入游戏），这帧先站着不动
	if target == null:
		return

	# 玩家位置 - 我的位置 = 一支"从我指向玩家"的箭头。
	# normalized() 把箭头变成纯方向（长度固定为 1），乘上速度就是每帧移动量
	var direction := (target.global_position - global_position).normalized()

	velocity = direction * speed
	move_and_slide()

	# 纯视觉：球越快，红色光晕越亮，危险感轻微增加（不影响真实速度和碰撞范围）
	$Glow.modulate.a = clampf(0.75 + (speed - 120.0) * 0.001, 0.75, 1.0)
