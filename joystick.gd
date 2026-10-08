extends Control

## 全屏动态（浮动）虚拟摇杆：手指在屏幕任意非 UI 位置按下，
## 摇杆底盘就出现在按下的那一点；拖动控制 360° 移动；松手整个摇杆消失。
## 把手指拖动转换成现有的 move_up / move_down / move_left / move_right 四个动作，
## 玩家移动仍由 player.gd 的 Input.get_vector 统一处理——本脚本不碰玩家速度。
## PC 上没有触摸屏时整个 TouchUI 自动隐藏，键盘操作完全不受影响。

# 死区：偏移小于最大偏移的这个比例时视为无输入（防止手指轻微抖动带动奶蛙）
const DEAD_ZONE := 0.1
# 摇杆帽最大偏移距离（= 底盘半径 80，和旧固定摇杆一致）
const MAX_OFFSET := 80.0
# 底盘 / 摇杆帽边长（与 main.tscn 里 Base、Knob 的尺寸一致）
const BASE_SIZE := 160.0
const KNOB_SIZE := 76.0

# 当前控制摇杆的手指编号（-1 = 没有手指）
var _touch_id := -1
# 摇杆是否真的注入过动作。没注入过时，松手/暂停/切场景都不碰输入，
# 这样 PC 上按住键盘时重开场景不会被摇杆的兜底释放误伤
var _injected := false
# 本次触摸的起点（= 底盘中心），全局坐标
var _origin := Vector2.ZERO

@onready var _base: TextureRect = $Base
@onready var _knob: TextureRect = $Knob


func _ready() -> void:
	# 只有触摸屏设备才显示整个 TouchUI；PC 隐藏，键盘照旧
	get_parent().visible = DisplayServer.is_touchscreen_available()
	_base.visible = false
	_knob.visible = false
	# 运行时强制全屏锚定：触摸检测区域始终等于当前 viewport，
	# 不写死任何分辨率，横屏 / expand / Web / Android 下都随窗口自动铺满
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_on_viewport_resized):
		vp.size_changed.connect(_on_viewport_resized)


# viewport（窗口/横竖屏）变化后再次铺满，防止任何时序下尺寸没有跟上
func _on_viewport_resized(_size: Vector2) -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PAUSED:
		release_all_inputs()
	elif what == NOTIFICATION_RESIZED:
		set_anchors_preset(Control.PRESET_FULL_RECT)


# 用 _unhandled_input 而不是 _gui_input / _input：
# UI 按钮（暂停、GameOver/Victory 面板按钮等）会先把触摸事件消费掉，
# 事件就不会流到这里——因此"UI 按钮优先于摇杆"由引擎的 GUI 分发天然保证。
# Joystick 控件本身 mouse_filter = IGNORE，也不会挡住任何按钮。
func _unhandled_input(event: InputEvent) -> void:
	# 隐藏时（PC）完全不响应触摸
	if not get_parent().visible:
		return
	# 非游戏进行中（主菜单不在本场景；暂停 / GameOver / Victory 时整树暂停并有面板）
	# 一律不创建/不继续控制摇杆，并兜底释放已注入的输入
	if not _is_playing():
		if _touch_id != -1:
			release_all_inputs()
		return
	if event is InputEventScreenTouch:
		if event.pressed and _touch_id == -1:
			# 任意非 UI 位置按下：以按下点作为摇杆中心
			_touch_id = event.index
			_show_at(event.position)
			_drag_to(event.position)
		elif not event.pressed and event.index == _touch_id:
			release_all_inputs()
	elif event is InputEventScreenDrag and event.index == _touch_id:
		_drag_to(event.position)


# 只有"实际正在游戏中"才允许摇杆工作
func _is_playing() -> bool:
	var main := get_tree().current_scene
	if main == null:
		return false
	if main.get_tree().paused:
		return false
	if main.game_over or main.won:
		return false
	if main.has_node("PauseUI") and main.get_node("PauseUI").visible:
		return false
	return true


# 把底盘显示在触摸起点，并把摇杆帽先回中
func _show_at(pos: Vector2) -> void:
	_origin = pos
	_base.position = pos - Vector2(BASE_SIZE, BASE_SIZE) * 0.5
	_base.visible = true
	_knob.position = pos - Vector2(KNOB_SIZE, KNOB_SIZE) * 0.5
	_knob.visible = true


# 根据手指当前位置更新摇杆帽，并把方向注入 InputMap
func _drag_to(pos: Vector2) -> void:
	var offset := pos - _origin
	if offset.length() > MAX_OFFSET:
		offset = offset.normalized() * MAX_OFFSET
	_knob.position = _origin + offset - Vector2(KNOB_SIZE, KNOB_SIZE) * 0.5

	# 死区内视为无输入（方向为零 = 四个动作全部释放）
	if offset.length() < MAX_OFFSET * DEAD_ZONE:
		_apply_direction(Vector2.ZERO)
	else:
		_apply_direction(offset.normalized())


# 把方向按分量强度注入四个动作（模拟量注入）。
# 传进来的 dir 已归一化：每个动作的力度 = 该方向上的分量（0~1），
# Input.get_vector 会把四个分量重新合成出真实的二维方向——
# 手机上任意角度拖动都能平滑移动，不被量化成 8 个方向（不像 WASD）。
# 向量长度恒为 1，所以合速度始终是 300，和键盘手感一致，摇杆不改变速度
func _apply_direction(dir: Vector2) -> void:
	_set_action(&"move_right", maxf(dir.x, 0.0))
	_set_action(&"move_left", maxf(-dir.x, 0.0))
	_set_action(&"move_down", maxf(dir.y, 0.0))
	_set_action(&"move_up", maxf(-dir.y, 0.0))


# 力度大于 0 就按该力度按下动作；为 0 时释放（只释放摇杆自己注入过的）
func _set_action(action: StringName, strength: float) -> void:
	if strength > 0.0:
		Input.action_press(action, strength)
		_injected = true
	elif _injected:
		Input.action_release(action)


# 统一释放入口：松手、触摸取消、暂停、GameOver、Victory、切场景——全部走这里。
# 任何情况下都不允许"松手后奶蛙还在自己走"
func release_all_inputs() -> void:
	_touch_id = -1
	if _injected:
		_injected = false
		Input.action_release(&"move_up")
		Input.action_release(&"move_down")
		Input.action_release(&"move_left")
		Input.action_release(&"move_right")
	if is_node_ready():
		_base.visible = false
		_knob.visible = false


# 场景销毁时（R 重开 / 再来一局 / 返回主菜单）兜底再释放一次
func _exit_tree() -> void:
	release_all_inputs()
