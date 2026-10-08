extends Control

## 主界面脚本：只负责页面切换、按钮跳转和图鉴展示，
## 不含任何玩法逻辑；"开始游戏"直接进入现有的成长模式场景。

const GAME_SCENE := "res://main.tscn"
# 图鉴固定展示成长模式的 9 个阶段（frog-09 已从成长系统移除，不进图鉴）
const GALLERY_IDS := [1, 2, 3, 4, 5, 6, 7, 8, 10]
# 与 main.gd 共用同一个存档：历史最高进化阶段（0~9）= 已解锁图鉴数
const SAVE_PATH := "user://highscore.cfg"

@onready var _pages := {
	"home": $PageHome,
	"mode": $PageMode,
	"gallery": $PageGallery,
	"settings": $PageSettings,
}


func _ready() -> void:
	# ——主页按钮——
	$PageHome/Center/Box/StartBtn.pressed.connect(_start_game)
	$PageHome/Center/Box/ModeBtn.pressed.connect(_show_page.bind("mode"))
	$PageHome/Center/Box/GalleryBtn.pressed.connect(_show_page.bind("gallery"))
	$PageHome/Center/Box/SettingsBtn.pressed.connect(_show_page.bind("settings"))
	$PageHome/Center/Box/ExitBtn.pressed.connect(get_tree().quit)  # 正常退出程序
	# ——子页面按钮——
	$PageMode/Center/Box/GrowthBtn.pressed.connect(_start_game)
	$PageMode/Center/Box/LetterBtn.pressed.connect(_show_letter_toast)
	$PageMode/BackBtn.pressed.connect(_show_page.bind("home"))
	$PageGallery/BackBtn.pressed.connect(_show_page.bind("home"))
	$PageSettings/BackBtn.pressed.connect(_show_page.bind("home"))

	_build_gallery()
	_show_page("home")


# 页面切换：一次只显示一个页面
func _show_page(page_name: String) -> void:
	for key in _pages:
		_pages[key].visible = key == page_name


# 开始游戏 / 成长模式：进入现有的成长模式场景（R 重开逻辑在场景内部，不受影响）
func _start_game() -> void:
	get_tree().change_scene_to_file(GAME_SCENE)


# 字母模式占位：只弹提示，不做玩法
func _show_letter_toast() -> void:
	var toast: Label = $Toast
	toast.text = "字母模式开发中，敬请期待"
	toast.visible = true
	toast.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_interval(1.0)
	tw.tween_property(toast, "modulate:a", 0.0, 0.3)
	tw.tween_callback(toast.hide)


# 图鉴网格：运行时生成 9 张卡片（3×3）。
# 第 i 张（i 从 1 起，等于进化阶段）在 历史最高阶段 >= i 时解锁；未解锁只显示"？"，
# 不显示真实图片和编号，避免提前泄露。图片保持原始宽高比不拉伸
func _build_gallery() -> void:
	var unlocked_count := _load_codex_stage()
	$PageGallery/Center/Box/ProgressLabel.text = "图鉴进度：%d / 9" % unlocked_count
	var grid: GridContainer = $PageGallery/Center/Box/Grid
	for i in GALLERY_IDS.size():
		var stage := i + 1                 # 1~9（第 9 张是 frog-10）
		var frog_id: int = GALLERY_IDS[i]
		var unlocked: bool = stage <= unlocked_count

		var card := PanelContainer.new()
		card.custom_minimum_size = Vector2(146, 176)

		var sb := StyleBoxFlat.new()
		# 未解锁卡片底色更暗，和已解锁的轻微区分（风格不变）
		sb.bg_color = Color(0.04, 0.06, 0.11, 0.92) if not unlocked else Color(0.06, 0.09, 0.16, 0.9)
		sb.border_color = Color(0.35, 0.55, 0.9, 0.35)
		sb.set_border_width_all(1)
		sb.set_corner_radius_all(10)
		card.add_theme_stylebox_override("panel", sb)

		var vb := VBoxContainer.new()
		vb.alignment = BoxContainer.ALIGNMENT_CENTER
		vb.add_theme_constant_override("separation", 6)

		if unlocked:
			var img := TextureRect.new()
			img.custom_minimum_size = Vector2(128, 128)
			img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED  # 等比缩放，不拉伸
			img.texture = _load_frog_tex(frog_id)
			vb.add_child(img)

			var lb := Label.new()
			lb.text = "%02d" % frog_id
			lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			lb.add_theme_color_override("font_color", Color(0.58, 0.66, 0.78))
			lb.add_theme_font_size_override("font_size", 14)
			vb.add_child(lb)
		else:
			# 锁定：图片区域留空（占位保持同样大小），中央显示明显的"？"
			var holder := Control.new()
			holder.custom_minimum_size = Vector2(128, 128)
			var q := Label.new()
			q.text = "？"
			q.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			q.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			q.set_anchors_preset(Control.PRESET_FULL_RECT)
			q.add_theme_color_override("font_color", Color(0.4, 0.48, 0.62, 1))
			q.add_theme_font_size_override("font_size", 56)
			holder.add_child(q)
			vb.add_child(holder)

		card.add_child(vb)
		grid.add_child(card)


# 读取历史最高进化阶段（=已解锁图鉴数）。无存档/旧存档无该字段时为 0（全锁定）
func _load_codex_stage() -> int:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) == OK:
		return clampi(int(cfg.get_value("record", "codex_highest_stage", 0)), 0, 9)
	return 0


# 透明 PNG 优先，没有就用原 JPG（与玩家成长系统同一套取图规则）
func _load_frog_tex(id: int) -> Texture2D:
	var png := "res://assets/frog/frog-%02d.png" % id
	if ResourceLoader.exists(png):
		return load(png)
	return load("res://assets/frog/frog-%02d.jpg" % id)
