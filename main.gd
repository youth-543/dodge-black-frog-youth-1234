extends Node2D

## 主场景脚本：负责游戏结束的整体流程（暂停游戏、显示提示、支持重开），
## 以及按难度曲线在屏幕边缘生成新的红球。

# 红球场景，用来随时"复制"出新的红球
const ENEMY_SCENE := preload("res://enemy.tscn")

# —— 难度曲线（正式版：以 80 秒进化为最终蛙为目标设计）——
const SPAWN_EASE_TIME := 15.0        # 前15秒生成间隔保持宽松（新手适应期）
const SPAWN_INTERVAL_START := 1.6    # 初始生成间隔（秒）
const SPAWN_SHRINK_PER_SEC := 0.024  # 15秒后间隔每秒缩短多少：40秒时降到下限 1.0
const SPAWN_INTERVAL_MIN := 1.0      # 最低生成间隔（秒），不再继续压缩
const MAX_ENEMIES := 25              # 场上红球数量上限，到了就暂时不再生成

const ENEMY_SPEED_START := 120.0     # 红球初始速度（玩家 300 的 40%）
# 速度为两段式平滑曲线，在 40 秒处斜率放缓（最终冲刺靠密度加压而非超速）：
#   0~40 秒：每秒 +2.75 → 40 秒时 230（玩家的 77%）
#   40 秒后：每秒 +1.6  → 60 秒时 262、70 秒 278、80 秒 294（始终低于玩家 300）
# 全程敌人速度不超过玩家速度，80 秒目标可以靠走位真正达成
const ENEMY_SPEED_GAIN_EARLY := 2.75
const ENEMY_SPEED_PIVOT := 40.0
const ENEMY_SPEED_GAIN_LATE := 1.6
const ENEMY_SPEED_MAX := 420.0       # 速度上限保留 420（远期继续上升的空间）

# 生成位置在窗口边缘外多少像素
const EDGE_MARGIN := 40.0

# —— 红球出生间距 ——
# 红球之间不再互相碰撞，如果出生位置太近就会叠成一团。
# 所以生成时挑选位置：新球要离场上每颗已有的球至少这么远
# （球直径 40，取 64 能让相邻球之间留出一圈空隙）
const SPAWN_MIN_DISTANCE := 64.0
# 最多随机尝试多少个位置；球太多实在挤不下时逐步放宽要求，绝不卡死
const SPAWN_MAX_ATTEMPTS := 24

# —— 最高纪录 ——
# 纪录保存成一个本机小文件（user:// 是 Godot 给每个游戏分配的存档文件夹），
# 关闭游戏重新打开后仍然存在
const SAVE_PATH := "user://highscore.cfg"

# —— 背景音乐 ——
# 音乐音量（分贝）：集中控制，以后做设置界面时把滑条连接到这里即可
const MUSIC_VOLUME_DB := -10.0
# 新 BGM 资源（OGG，循环）。文件由外部放入；暂未放入时自动回退到旧版 sounds/bgm.wav
const BGM_PATH_NEW := "res://audio/bgm/main_bgm.ogg"
const BGM_PATH_LEGACY := "res://sounds/bgm.wav"

# —— 奶蛙成长 ——
# 奶蛙切换间隔（秒）：正式版每 10 秒进化一级，
# 0/10/20/.../70 秒依次切换，80 秒进入第 9 阶段最终蛙 frog-10
const FROG_SWITCH_INTERVAL := 10.0

# —— 升级音效（8 次升级固定一一对应，不随机）——
# 第 1~8 次升级分别播放 audio/growth/growth_01.wav ~ growth_08.wav
# （frog-01→02 是第 1 次 …… →frog-10 是第 8 次）。
# 文件暂未放入项目时静默跳过，绝不报错。
const GROWTH_SFX_PATTERN := "res://audio/growth/growth_%02d.wav"
var _growth_streams: Dictionary = {}

# 游戏是否已经结束（死亡）
var game_over := false
# 游戏是否已经胜利（活到 80 秒进化为 frog-10）
var won := false
# 本局已经进行了多少秒（用来计算难度）
var game_time := 0.0
# 历史最佳纪录（从本机文件读取，R 重开也不会丢失）
var best_time := 0.0
var best_score := 0
# 当前奶蛙编号（1~8 和 10），用来避免每帧重复调用 _set_frog()
var current_frog := 1
# 本局实际达到的最高奶蛙阶段（1~9）。只在切换真正发生的瞬间更新，
# 不用生存时间反推；R 重开场景重建时自然归 1，不做永久存档
var best_frog_stage := 1
# 图鉴：历史最高进化阶段（0~9），跨局永久保存，只增不减。
# 已解锁图鉴数 = 该值（第 1 阶段解锁第 1 张 …… 第 9 阶段 frog-10 解锁全部 9 张）
var codex_highest_stage := 0


func _ready() -> void:
	randomize()  # 让每一局的红球出现位置都不同
	_load_best()  # 读回历史最高纪录（按 R 重开场景时也会重新读到）
	# 开局即第 1 阶段 frog-01：第 1 张图鉴在进入游戏的瞬间就永久解锁，
	# 保证"已解锁数 = 历史最高进化阶段"——哪怕 10 秒内死亡也是 1 / 9（历史最高只增不减）
	if codex_highest_stage < 1:
		codex_highest_stage = 1
		_save_codex()
	_update_best_label()  # 左上角 HUD 一开局就显示当前最高纪录

	# 把玩家身上 HurtBox（受伤区域）的信号连接到下面的处理函数。
	# 只要有物体进入这个区域，就会调用 _on_player_hit，并把碰到的物体传进来。
	$Player/HurtBox.body_entered.connect(_on_player_hit)
	# 把计时器的"时间到了"信号连接到生成红球的函数。
	$SpawnTimer.timeout.connect(_on_spawn_timer_timeout)
	# 暂停菜单的两个按钮（面板不受暂停影响，暂停时也能点）
	$PauseUI/Center/Panel/Margin/VBox/ContinueBtn.pressed.connect(_resume_game)
	$PauseUI/Center/Panel/Margin/VBox/BackMenuBtn.pressed.connect(_back_to_menu)
	# 胜利面板的两个按钮
	$VictoryUI/Center/Panel/Margin/VBox/RestartBtn.pressed.connect(_restart_game)
	$VictoryUI/Center/Panel/Margin/VBox/MenuBtn.pressed.connect(_back_to_menu)
	# 游戏结束面板的两个按钮（手机上没有 R 键，靠这两个按钮重开/返回；
	# "再来一局"和 R 键、胜利面板的"再来一局"走同一个 _restart_game）
	$GameOverUI/Center/Panel/Margin/VBox/RestartBtn.pressed.connect(_restart_game)
	$GameOverUI/Center/Panel/Margin/VBox/MenuBtn.pressed.connect(_back_to_menu)
	# 手机端右上角暂停按钮：和 ESC 共用同一个 _pause_game
	$HUD/PauseBtn.pressed.connect(_pause_game)

	# 游戏开始音效（进入场景即开局，所以在这里响一声短促的"开始挑战"）
	_play_sfx("StartSound")

	# 关闭游戏由下面的 _notification 接管：先停声音、再退出
	get_tree().auto_accept_quit = false

	# ——背景音乐：加载资源（新 OGG 优先，缺失时回退旧 WAV）并循环播放——
	_setup_bgm()


func _process(delta: float) -> void:
	# 累计本局时间并刷新左上角显示。
	# 游戏结束后整个 if 被跳过：时间冻结、得分停止、画面保留最终值。
	# ESC 暂停期间同样跳过：时间、难度、成长全部冻结
	if not game_over and not won and not get_tree().paused:
		game_time += delta
		$HUD/TopLeft/TimeValue.text = "%.1f s" % game_time
		$HUD/TopLeft/ScoreValue.text = str(roundi(game_time * 10.0))
		$HUD/TopLeft/DiffLabel.text = "难度：%d" % (int(game_time / 10.0) + 1)

		# 动态难度：把"当前生存时间对应的速度"实时同步给场上每一个红球，
		# 这样所有红球（不管什么时候生成的）都会随时间一起变快
		var current_speed := _current_enemy_speed()
		for enemy in $Enemies.get_children():
			enemy.speed = current_speed

		# 奶蛙成长：按 FROG_SWITCH_INTERVAL 切换到下一张。用 game_time 直接算当前阶段，不另开计时器
		# 成长流程共 9 个阶段（1~8 用 frog-01~08，第 9 阶段直接用 frog-10；
		# frog-09 不参与成长流程，其配置仍留在 player.gd 的表里不删）
		var frog_stage: int = clampi(int(game_time / FROG_SWITCH_INTERVAL) + 1, 1, 9)
		var frog_image: int = frog_stage if frog_stage < 9 else 10
		if frog_image != current_frog:
			current_frog = frog_image
			$Player._set_frog(frog_image)
			# 成长弹跳动画：和换图同一瞬间触发，只动贴图不碰碰撞体
			$Player._play_grow_anim()
			# 切换真正成功了，才更新本局最高阶段（frog-10 对应第 9 阶段）
			best_frog_stage = frog_stage
			# 图鉴立即永久解锁：在真正完成进化的这一瞬间就落盘（不等 GameOver），
			# 历史最高只增不减；第 9 阶段 frog-10 也走这里，Victory 之前已解锁第 9 张
			if frog_stage > codex_highest_stage:
				codex_highest_stage = frog_stage
				_save_codex()
			# 让 HUD 上的 FROG 标签短暂显示，提示玩家变了
			_animate_frog_notice()
			# 成长音效：只在真正切换的这一瞬间播一次（开局、停在 frog-10、结束后都不会到这里）。
			# 第几次升级 = frog_stage - 1（2→第1次 …… 9→第8次），8 个音效固定一一对应
			_play_growth_sfx(frog_stage - 1)
			# 第 9 阶段（frog-10）达成 = 胜利：优先级高于一切 GameOver
			if frog_stage == 9:
				_on_victory()


# 奶蛙切换时的 HUD 提示：让 "FROG 02" 短暂显示一下再自动隐藏
func _animate_frog_notice() -> void:
	var label := $HUD/TopLeft/FrogLabel
	label.text = "FROG %02d" % current_frog
	label.visible = true
	label.modulate.a = 0.0
	# 淡入 → 停一会儿 → 淡出，总共约 0.8 秒
	var tw := create_tween()
	tw.tween_property(label, "modulate:a", 1.0, 0.15)
	tw.tween_interval(0.45)
	tw.tween_property(label, "modulate:a", 0.0, 0.2)
	tw.tween_callback(label.hide)


func _on_spawn_timer_timeout() -> void:
	# 场上红球达到上限就暂时不再生成
	if $Enemies.get_child_count() < MAX_ENEMIES:
		# 复制一个新红球，放到随机选中的窗口边缘，再放进 Enemies 容器
		# （速度不用在这里设置，_process 每帧都会统一同步）
		var enemy: Node2D = ENEMY_SCENE.instantiate()
		enemy.position = _find_spawn_position()
		$Enemies.add_child(enemy)
		_play_sfx("SpawnSound")  # 很轻的一声，只在真正生成时响

	# 按难度曲线设定下一次生成的间隔，并重新开始计时
	$SpawnTimer.start(_current_spawn_interval())


# 难度曲线（生成间隔）：前15秒保持宽松的 1.6 秒；之后每秒缩短 0.024 秒，
# 40 秒时降到下限 1.0 秒并保持（0~20 新手期 / 20~40 加压 / 40 后满频）
func _current_spawn_interval() -> float:
	if game_time <= SPAWN_EASE_TIME:
		return SPAWN_INTERVAL_START
	return maxf(SPAWN_INTERVAL_START - (game_time - SPAWN_EASE_TIME) * SPAWN_SHRINK_PER_SEC, SPAWN_INTERVAL_MIN)


# 难度曲线（红球速度）：两段式平滑递增，全程不超过玩家速度 300
# 0秒→120，10秒→148，20秒→175，40秒→230，60秒→262，70秒→278，80秒→294
func _current_enemy_speed() -> float:
	var speed := ENEMY_SPEED_START + game_time * ENEMY_SPEED_GAIN_EARLY
	if game_time > ENEMY_SPEED_PIVOT:
		speed = ENEMY_SPEED_START \
			+ ENEMY_SPEED_PIVOT * ENEMY_SPEED_GAIN_EARLY \
			+ (game_time - ENEMY_SPEED_PIVOT) * ENEMY_SPEED_GAIN_LATE
	return minf(speed, ENEMY_SPEED_MAX)


# 在窗口四条边外随机选一个位置（0上边 1右边 2下边 3左边）
func _random_edge_position() -> Vector2:
	var screen := get_viewport_rect().size
	match randi() % 4:
		0: return Vector2(randf_range(0, screen.x), -EDGE_MARGIN)
		1: return Vector2(screen.x + EDGE_MARGIN, randf_range(0, screen.y))
		2: return Vector2(randf_range(0, screen.x), screen.y + EDGE_MARGIN)
		_: return Vector2(-EDGE_MARGIN, randf_range(0, screen.y))


# 挑一个不与场上已有红球重叠的出生位置：
# 先随机取一个边缘位置，检查它和每颗已有球的距离；太近就换一个位置再试。
# 尝试若干次后逐步放宽距离要求（64 → 45 → 31），
# 就算一直找不到理想位置，也用最后随机出的位置生成——绝不卡死游戏
func _find_spawn_position() -> Vector2:
	var required := SPAWN_MIN_DISTANCE
	var candidate := _random_edge_position()
	for attempt in SPAWN_MAX_ATTEMPTS:
		var too_close := false
		for enemy in $Enemies.get_children():
			if candidate.distance_to(enemy.position) < required:
				too_close = true
				break
		if not too_close:
			return candidate
		# 这个位置太挤：每试 8 次把要求放宽一档，然后换个位置继续
		if attempt % 8 == 7:
			required *= 0.7
		candidate = _random_edge_position()
	return candidate


func _on_player_hit(body: Node2D) -> void:
	# 碰到的是玩家自己的身体（HurtBox 装在玩家身上），忽略
	if body == $Player:
		return
	# 胜利后所有死亡判定作废：VICTORY 优先级高于 GAME_OVER
	if won:
		return
	# 已经结束过就不再重复处理
	if game_over:
		return
	game_over = true

	# 游戏结束：隐藏手机暂停按钮、松开虚拟摇杆（摇杆在暂停期间也不工作）
	$HUD/PauseBtn.visible = false
	$TouchUI/Joystick.release_all_inputs()

	# 死亡视觉反馈：玩家闪白、一小撮粒子、极轻微震屏（纯表现，不参与任何判定）
	_play_hit_effects()

	# 判断是否打破纪录：本局生存时间超过历史最佳就是新纪录，
	# 最高分和最高时间同步更新（得分本来就是由时间算出来的）
	var is_new_record := game_time > best_time
	if is_new_record:
		best_time = game_time
		best_score = roundi(game_time * 10.0)
		_save_best()

	# 左上角 HUD 里的最高纪录也同步刷新（破纪录时会立刻变成新数字）
	_update_best_label()

	# 把本局成绩、最高纪录和新纪录提示写到游戏结束面板上
	$GameOverUI/Center/Panel/Margin/VBox/FinalTimeValue.text = "%.1f s" % game_time
	$GameOverUI/Center/Panel/Margin/VBox/FinalScoreValue.text = str(roundi(game_time * 10.0))
	$GameOverUI/Center/Panel/Margin/VBox/RecordValue.text = "%.1f s / %d 分" % [best_time, best_score]
	$GameOverUI/Center/Panel/Margin/VBox/FrogStageValue.text = "本局进化：%d / 9" % best_frog_stage
	$GameOverUI/Center/Panel/Margin/VBox/NewRecordLabel.visible = is_new_record
	if is_new_record:
		_animate_new_record($GameOverUI/Center/Panel/Margin/VBox/NewRecordLabel)

	# 显示"游戏结束"文字（连同变暗遮罩一起出现）
	$GameOverUI.visible = true

	# ——音效序列：碰撞音立刻响；0.35 秒后 Game Over 音（和撞击声错开）；
	# 破纪录时再晚 0.35 秒播新纪录音，让奖励反馈明显区别于普通结束——
	# （序列挂在 Main 上，暂停不影响；按 R 重开时场景销毁，未播完的自动作废）
	_play_sfx("HitSound")

	# BGM 快速淡出并停止（死亡后音乐不该继续欢快循环）
	var bgm_fade := create_tween()
	bgm_fade.tween_property($BGM, "volume_db", -40.0, 0.6)
	bgm_fade.tween_callback($BGM.stop)

	var sfx_seq := create_tween()
	sfx_seq.tween_interval(0.35)
	sfx_seq.tween_callback(_play_sfx.bind("GameOverSound"))
	if is_new_record:
		sfx_seq.tween_interval(0.35)
		sfx_seq.tween_callback(_play_sfx.bind("RecordSound"))

	# 暂停整个游戏：玩家和红球的每帧逻辑会自动停止，它们就都冻结了。
	# （Main 节点在场景文件里被设为"不受暂停影响"，所以还能监听按键）
	get_tree().paused = true


func _unhandled_input(event: InputEvent) -> void:
	# ESC：游戏中弹出暂停菜单；菜单已弹出时再按 ESC 等于"继续游戏"。
	# Game Over / Victory 后都不响应（胜利面板有自己的按钮，不再弹暂停菜单）
	if not game_over and not won and event.is_action_pressed("ui_cancel"):
		if $PauseUI.visible:
			_resume_game()
		else:
			_pause_game()
		return
	# 胜利后按下 R：取消暂停，并重新加载主场景（相当于重新开始）
	if won and event.is_action_pressed("restart"):
		_restart_game()
		return
	# 游戏结束后按下 R：取消暂停，并重新加载主场景（相当于重新开始）
	if game_over and event.is_action_pressed("restart"):
		_restart_game()


# 进入暂停：ESC 和手机右上角"暂停"按钮共用这一个入口。
# 暂停菜单、冻结、BGM 暂停全部走原来已验证的逻辑，不新增第二套状态
func _pause_game() -> void:
	if game_over or won or $PauseUI.visible:
		return
	$HUD/PauseBtn.visible = false
	$TouchUI/Joystick.release_all_inputs()  # 进暂停立刻松开虚拟摇杆，恢复时不会自己走
	$PauseUI.visible = true
	get_tree().paused = true  # 玩家/红球/生成计时全部冻结
	$BGM.stream_paused = true  # 音乐跟着暂停，继续时原位恢复


# 继续游戏：关掉暂停菜单，恢复整棵场景树和音乐
func _resume_game() -> void:
	$PauseUI.visible = false
	get_tree().paused = false
	$BGM.stream_paused = false
	$HUD/PauseBtn.visible = true


# 胜利判定（第 9 阶段 frog-10 达成瞬间触发）
# 流程：停表、停生成、停红球移动、冻结场景树、弹胜利面板
func _on_victory() -> void:
	won = true
	$SpawnTimer.stop()  # 停止生成新红球
	# 胜利：隐藏手机暂停按钮、松开虚拟摇杆
	$HUD/PauseBtn.visible = false
	$TouchUI/Joystick.release_all_inputs()
	$BGM.stream_paused = true  # 音乐暂停（和 ESC 暂停同款自然方式）
	get_tree().paused = true  # 红球/玩家全部冻结（现有机制，不改碰撞体）
	# 把本局最高阶段写到面板上（胜利时就是 9/9）
	$VictoryUI/Center/Panel/Margin/VBox/FinalStage.text = "本局进化：%d / 9" % best_frog_stage
	# 胜利成绩固定记为 80.0 秒 / 800 分：不按实际帧时间，避免存出 80.1 这类零头。
	# 只有历史最佳还不到 80.0 才算新纪录；已经是 80.0 就不重复提示、不重复写盘
	var is_new_record := 80.0 > best_time
	if is_new_record:
		best_time = 80.0
		best_score = 800
		_save_best()
	_update_best_label()  # 左上角 HUD 同步显示最新纪录
	var record_label: Label = $VictoryUI/Center/Panel/Margin/VBox/NewRecordLabel
	record_label.visible = is_new_record
	if is_new_record:
		_animate_new_record(record_label)
		_play_sfx("RecordSound")  # 破纪录奖励音，和 GameOver 的新纪录反馈一致
	# 巨大神蛙登场动画：从 80% 大小用 0.5 秒平滑放大到最终尺寸，之后保持静止。
	# 只缩放 VictoryUI 里这张背景贴图，与游戏中玩家的 frog-10 贴图完全无关
	var god_frog: TextureRect = $VictoryUI/GodFrog
	god_frog.scale = Vector2(0.8, 0.8)
	var frog_tw := create_tween()
	frog_tw.tween_property(god_frog, "scale", Vector2.ONE, 0.5).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	$VictoryUI.visible = true


# 重新开始（三个入口共用这一个函数）：
# 胜利面板"再来一局"、游戏结束面板"再来一局"、键盘 R 键。
# 取消暂停并重新加载主场景，场景重建时所有状态自然归零
func _restart_game() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()


# 返回主界面：不算死亡、不写纪录（存档只在 _on_player_hit 里发生），
# 先取消暂停再切场景，主界面才能正常响应
func _back_to_menu() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://main_menu.tscn")


# —— 最高纪录的读取和保存（用 ConfigFile 存成本机文件）——

func _load_best() -> void:
	var cfg := ConfigFile.new()
	# 第一次玩时文件还不存在，load 会失败，此时保持 0 就行
	if cfg.load(SAVE_PATH) == OK:
		best_time = cfg.get_value("record", "best_time", 0.0)
		best_score = cfg.get_value("record", "best_score", 0)
		# 图鉴历史最高阶段（旧存档没有该字段时默认 0=全锁定），夹紧到 0~9
		codex_highest_stage = clampi(int(cfg.get_value("record", "codex_highest_stage", 0)), 0, 9)


func _save_best() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("record", "best_time", best_time)
	cfg.set_value("record", "best_score", best_score)
	cfg.set_value("record", "codex_highest_stage", codex_highest_stage)
	cfg.save(SAVE_PATH)


# 只保存图鉴进度（进化瞬间立即调用，独立于死亡时的最佳成绩保存）。
# 先读回已有纪录再改，避免在游戏中途写图鉴时把 best_time/best_score 覆盖掉
func _save_codex() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) == OK:
		best_time = cfg.get_value("record", "best_time", best_time)
		best_score = cfg.get_value("record", "best_score", best_score)
	cfg.set_value("record", "codex_highest_stage", codex_highest_stage)
	cfg.set_value("record", "best_time", best_time)
	cfg.set_value("record", "best_score", best_score)
	cfg.save(SAVE_PATH)


# 把当前最高纪录刷新到左上角 HUD（开局读档后、以及破纪录时各调用一次）
func _update_best_label() -> void:
	$HUD/TopLeft/BestValue.text = "%.1f s" % best_time


# 死亡瞬间的纯视觉反馈：玩家闪白、一小撮粒子、极轻微震屏。
# 动画挂在 Main（不受暂停影响）上，所以暂停后仍能播完；不影响任何判定和重开
func _play_hit_effects() -> void:
	var tw := create_tween()
	tw.tween_property($Player, "modulate", Color(3.0, 3.0, 3.2, 1), 0.06)
	tw.tween_property($Player, "modulate", Color(1, 1, 1, 1), 0.2)
	$Player/DeathBurst.emitting = true

	# 极轻微屏幕震动：快速抖动 Main 自身的位置几个来回再归位。
	# 玩家和红球的相对位置不变，碰撞判定不受影响
	var shake := create_tween()
	for i in 4:
		shake.tween_property(self, "position", Vector2(randf_range(-4.0, 4.0), randf_range(-4.0, 4.0)), 0.03)
	shake.tween_property(self, "position", Vector2.ZERO, 0.05)


# "新纪录！"入场动画：等一帧让面板完成布局，再从文字中心做"放大→回弹"
func _center_and_animate_record(label: Label) -> void:
	label.pivot_offset = label.size / 2.0
	var tw := create_tween().set_parallel(true)
	tw.tween_property(label, "scale", Vector2.ONE, 0.3).from(Vector2(1.6, 1.6)).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(label, "modulate:a", 1.0, 0.18).from(0.0)


func _animate_new_record(label: Label) -> void:
	_center_and_animate_record.call_deferred(label)


# 统一音效入口：SFX 节点下固定放着 5 个 AudioStreamPlayer，
# 播放只是触发它们，从不创建新节点，所以连续重开也不会越积越多
func _play_sfx(sfx_name: String) -> void:
	$SFX.get_node(sfx_name).play()


# 升级音效：8 次升级固定一一对应 growth_01~growth_08，不随机、不循环、只播一次。
# upgrade_index 为 1~8。对应音频文件还没放进 audio/growth 时静默跳过，不报错
func _play_growth_sfx(upgrade_index: int) -> void:
	if upgrade_index < 1 or upgrade_index > 8:
		return
	var path := GROWTH_SFX_PATTERN % upgrade_index
	if not ResourceLoader.exists(path):
		return  # 音频文件尚未提供：安静跳过，游戏行为不受影响
	if not _growth_streams.has(upgrade_index):
		_growth_streams[upgrade_index] = load(path)
	$SFX/GrowthSound.stream = _growth_streams[upgrade_index]
	$SFX/GrowthSound.play()


# 背景音乐资源装配：新 OGG（res://audio/bgm/main_bgm.ogg）优先；
# 文件尚未放入时回退到旧版 sounds/bgm.wav。播放/暂停/淡出架构完全不变。
# OGG 直接打开循环标记；WAV 沿用原来的整段循环点计算
func _setup_bgm() -> void:
	var path := BGM_PATH_NEW if ResourceLoader.exists(BGM_PATH_NEW) else BGM_PATH_LEGACY
	if not ResourceLoader.exists(path):
		return  # 两个文件都不存在时保持静默，不报错
	var stream: AudioStream = load(path)
	$BGM.stream = stream
	if stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	elif stream is AudioStreamWAV:
		var wav := stream as AudioStreamWAV
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = wav.data.size() / 2  # 16-bit 单声道：2 字节一帧
	$BGM.volume_db = MUSIC_VOLUME_DB
	$BGM.play()


# 玩家点窗口的 X 关闭游戏时：先把所有声音停干净、给音频引擎留一帧处理时间，
# 再正式退出，避免退出瞬间音频对象还没清理干净的警告
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_stop_all_sfx()
		await get_tree().process_frame
		get_tree().quit()


# 场景被销毁时（关闭游戏或 R 重开）把还在响的音效全部停掉，
# 作为 R 重开路径上的兜底清理
func _exit_tree() -> void:
	_stop_all_sfx()


# 统一停止所有音效
func _stop_all_sfx() -> void:
	for player in $SFX.get_children():
		player.stop()
	$BGM.stop()
