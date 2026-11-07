extends Control
## QR 3D Uploader
## Pick a .glb/.fbx model, preview it standing on a QR code, and upload it to the
## GitHub repo behind the QR AR website. Each model gets its own QR key in models.json.

const GitHubClient = preload("res://github.gd")

const SETTINGS_PATH := "user://settings.cfg"
const DEFAULT_OWNER := "Novaillusion"
const DEFAULT_REPO := "Danangtui_QR_3D_scanner"
const DEFAULT_SITE := "https://novaillusion.github.io/Danangtui_QR_3D_scanner/"
const MAX_UPLOAD_MB := 50.0

var gh: GitHubClient
var settings := ConfigFile.new()
var site_url := DEFAULT_SITE

var models := {}            # key -> entry (Dictionary) from models.json
var selected_key := ""      # key being edited; "" = new model
var picked_path := ""       # local file chosen for upload
var key_touched := false    # user typed the key by hand
var busy := false

# --- UI ---
var model_list: ItemList
var file_label: Label
var name_edit: LineEdit
var key_edit: LineEdit
var scale_spin: SpinBox
var rot_spin: SpinBox
var lift_spin: SpinBox
var anim_edit: LineEdit
var upload_btn: Button
var qr_btn: Button
var delete_btn: Button
var browse_btn: Button
var status_label: Label
var form_title: Label
var file_dialog: FileDialog
var settings_dialog: ConfirmationDialog
var confirm_delete: ConfirmationDialog
var s_owner: LineEdit
var s_repo: LineEdit
var s_branch: LineEdit
var s_token: LineEdit
var s_site: LineEdit

# --- 3D preview ---
var viewport: SubViewport
var pivot: Node3D
var cam: Camera3D
var wrap: Node3D            # applies size / rotation / lift, same as the website
var model_root: Node3D      # fitted model (0.9 of the QR width, standing on it)
var anim_player: AnimationPlayer
var dragging := false
var yaw := 0.6
var pitch := -0.55
var dist := 2.6


func _ready() -> void:
	get_window().title = "QR 3D Uploader"
	gh = GitHubClient.new()
	add_child(gh)
	_build_ui()
	_load_settings()
	_new_model()
	if gh.token == "":
		_set_status("Welcome! Open Settings and paste your GitHub token to get started.")
		_open_settings()
	else:
		_refresh()


# =====================================================================
# UI construction
# =====================================================================

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color("1b1f2a")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 14)
	add_child(margin)

	var split := HSplitContainer.new()
	margin.add_child(split)

	# ---- left: list of models on the website ----
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 300
	split.add_child(left)
	left.add_child(_title("Models on the website"))
	model_list = ItemList.new()
	model_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	model_list.item_selected.connect(_on_list_selected)
	left.add_child(model_list)
	var lrow := HBoxContainer.new()
	left.add_child(lrow)
	lrow.add_child(_button("+ New model", _new_model))
	lrow.add_child(_button("Refresh", _refresh))
	lrow.add_child(_button("Settings", _open_settings))
	var site_btn := _button("Open website", func(): OS.shell_open(site_url))
	left.add_child(site_btn)

	# ---- right: preview + form ----
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 8)
	split.add_child(right)

	form_title = _title("New model")
	right.add_child(form_title)

	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	svc.custom_minimum_size = Vector2(420, 320)
	svc.gui_input.connect(_on_preview_input)
	right.add_child(svc)
	viewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_4X
	svc.add_child(viewport)
	_build_preview_scene()

	var hint := Label.new()
	hint.text = "Drag to rotate · scroll to zoom · the square is the QR code (1 unit wide)"
	hint.modulate = Color(1, 1, 1, 0.55)
	right.add_child(hint)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	right.add_child(grid)

	var file_row := HBoxContainer.new()
	file_label = Label.new()
	file_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	file_label.clip_text = true
	file_row.add_child(file_label)
	browse_btn = _button("Choose file…", func(): file_dialog.popup_centered_ratio(0.7))
	file_row.add_child(browse_btn)
	_row(grid, "Model file", file_row)

	name_edit = LineEdit.new()
	name_edit.placeholder_text = "e.g. Dragon"
	name_edit.text_changed.connect(_on_name_changed)
	_row(grid, "Name", name_edit)

	key_edit = LineEdit.new()
	key_edit.placeholder_text = "e.g. dragon (letters a–z, numbers, - and _)"
	key_edit.text_changed.connect(func(_t): key_touched = true)
	_row(grid, "QR key", key_edit)

	scale_spin = _spin(0.05, 10.0, 0.05, 1.0)
	_row(grid, "Size", scale_spin)
	rot_spin = _spin(-180.0, 180.0, 5.0, 0.0)
	_row(grid, "Rotation (°)", rot_spin)
	lift_spin = _spin(-1.0, 3.0, 0.05, 0.0)
	_row(grid, "Lift", lift_spin)

	anim_edit = LineEdit.new()
	anim_edit.placeholder_text = "optional – animation name or number (empty = first)"
	anim_edit.text_changed.connect(func(_t): _play_animation())
	_row(grid, "Animation", anim_edit)

	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 8)
	right.add_child(brow)
	upload_btn = _button("Upload to website", _on_upload)
	upload_btn.custom_minimum_size = Vector2(190, 38)
	brow.add_child(upload_btn)
	qr_btn = _button("Show QR code", _on_show_qr)
	brow.add_child(qr_btn)
	delete_btn = _button("Delete", func(): confirm_delete.popup_centered())
	brow.add_child(delete_btn)

	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.custom_minimum_size.y = 44
	right.add_child(status_label)

	# ---- dialogs ----
	file_dialog = FileDialog.new()
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.filters = PackedStringArray(["*.glb, *.fbx ; 3D models", "*.glb ; glTF binary", "*.fbx ; FBX"])
	file_dialog.use_native_dialog = true
	file_dialog.title = "Choose a 3D model"
	file_dialog.file_selected.connect(_on_file_picked)
	add_child(file_dialog)

	confirm_delete = ConfirmationDialog.new()
	confirm_delete.title = "Delete model"
	confirm_delete.dialog_text = "Remove this model from the website? Its printed QR codes will stop showing anything."
	confirm_delete.confirmed.connect(_on_delete)
	add_child(confirm_delete)

	settings_dialog = ConfirmationDialog.new()
	settings_dialog.title = "Settings"
	settings_dialog.ok_button_text = "Save"
	var sbox := VBoxContainer.new()
	sbox.custom_minimum_size = Vector2(560, 0)
	var sgrid := GridContainer.new()
	sgrid.columns = 2
	sbox.add_child(sgrid)
	s_owner = LineEdit.new()
	_row(sgrid, "GitHub owner", s_owner)
	s_repo = LineEdit.new()
	_row(sgrid, "Repository", s_repo)
	s_branch = LineEdit.new()
	_row(sgrid, "Branch", s_branch)
	s_token = LineEdit.new()
	s_token.secret = true
	s_token.placeholder_text = "github_pat_…"
	_row(sgrid, "Access token", s_token)
	s_site = LineEdit.new()
	_row(sgrid, "Website URL", s_site)
	var help := Label.new()
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.custom_minimum_size.x = 540
	help.modulate = Color(1, 1, 1, 0.7)
	help.text = "Create the token at GitHub → Settings → Developer settings → Fine-grained tokens. " \
		+ "Repository access: only this repository. Permissions: Contents → Read and write. " \
		+ "The token is saved only on this PC."
	sbox.add_child(help)
	var token_link := _button("Open GitHub token page", func(): OS.shell_open("https://github.com/settings/personal-access-tokens/new"))
	sbox.add_child(token_link)
	settings_dialog.add_child(sbox)
	settings_dialog.confirmed.connect(_on_settings_saved)
	add_child(settings_dialog)


func _title(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 20)
	return l


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	return b


func _spin(lo: float, hi: float, step: float, value: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = value
	s.custom_minimum_size.x = 140
	s.value_changed.connect(func(_v): _apply_wrap_transform())
	return s


func _row(grid: GridContainer, label: String, control: Control) -> void:
	var l := Label.new()
	l.text = label
	grid.add_child(l)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(control)


func _set_status(text: String, is_error: bool = false) -> void:
	status_label.text = text
	status_label.modulate = Color("ff8a80") if is_error else Color("cfe3ff")


func _set_busy(on: bool) -> void:
	busy = on
	for b in [upload_btn, qr_btn, delete_btn, browse_btn]:
		b.disabled = on
	if not on:
		_update_buttons()


func _update_buttons() -> void:
	delete_btn.disabled = busy or selected_key == ""
	qr_btn.disabled = busy or selected_key == ""


# =====================================================================
# Settings
# =====================================================================

func _load_settings() -> void:
	settings.load(SETTINGS_PATH)  # missing file is fine: defaults below
	gh.repo_owner = settings.get_value("github", "owner", DEFAULT_OWNER)
	gh.repo = settings.get_value("github", "repo", DEFAULT_REPO)
	gh.branch = settings.get_value("github", "branch", "main")
	gh.token = settings.get_value("github", "token", "")
	site_url = _with_slash(settings.get_value("site", "url", DEFAULT_SITE))


func _open_settings() -> void:
	s_owner.text = gh.repo_owner
	s_repo.text = gh.repo
	s_branch.text = gh.branch
	s_token.text = gh.token
	s_site.text = site_url
	settings_dialog.popup_centered()


func _on_settings_saved() -> void:
	gh.repo_owner = s_owner.text.strip_edges()
	gh.repo = s_repo.text.strip_edges()
	gh.branch = s_branch.text.strip_edges() if s_branch.text.strip_edges() != "" else "main"
	gh.token = s_token.text.strip_edges()
	site_url = _with_slash(s_site.text.strip_edges())
	settings.set_value("github", "owner", gh.repo_owner)
	settings.set_value("github", "repo", gh.repo)
	settings.set_value("github", "branch", gh.branch)
	settings.set_value("github", "token", gh.token)
	settings.set_value("site", "url", site_url)
	settings.save(SETTINGS_PATH)
	_set_busy(true)
	_set_status("Checking access to %s/%s…" % [gh.repo_owner, gh.repo])
	var r: Dictionary = await gh.check_access()
	_set_busy(false)
	if not r["ok"]:
		_set_status(r["error"], true)
		return
	_set_status("Connected to %s/%s." % [gh.repo_owner, gh.repo])
	_refresh()


func _with_slash(url: String) -> String:
	return url if url.ends_with("/") else url + "/"


# =====================================================================
# Model list (models.json in the repo)
# =====================================================================

func _refresh() -> void:
	if busy:
		return
	_set_busy(true)
	_set_status("Loading model list…")
	var r: Dictionary = await gh.get_file("models.json")
	_set_busy(false)
	if not r["ok"]:
		_set_status("Could not load models.json: " + r["error"], true)
		return
	var cfg = JSON.parse_string((r["content"] as PackedByteArray).get_string_from_utf8())
	if not (cfg is Dictionary):
		_set_status("models.json in the repo is not valid JSON.", true)
		return
	models = cfg.get("models", {})
	model_list.clear()
	var keys := models.keys()
	keys.sort()
	for key in keys:
		var entry: Dictionary = models[key]
		var idx := model_list.add_item("%s   (%s)" % [entry.get("name", key), key])
		model_list.set_item_metadata(idx, key)
		if key == selected_key:
			model_list.select(idx)
	_set_status("%d model(s) on the website." % models.size())


func _new_model() -> void:
	selected_key = ""
	picked_path = ""
	key_touched = false
	model_list.deselect_all()
	form_title.text = "New model"
	file_label.text = "No file chosen"
	name_edit.text = ""
	key_edit.text = ""
	scale_spin.set_value_no_signal(1.0)
	rot_spin.set_value_no_signal(0.0)
	lift_spin.set_value_no_signal(0.0)
	anim_edit.text = ""
	upload_btn.text = "Upload to website"
	_clear_preview()
	_apply_wrap_transform()
	_update_buttons()


func _on_list_selected(index: int) -> void:
	var key: String = model_list.get_item_metadata(index)
	var entry: Dictionary = models.get(key, {})
	selected_key = key
	picked_path = ""
	key_touched = true
	form_title.text = "Edit: " + str(entry.get("name", key))
	file_label.text = str(entry.get("file", ""))
	name_edit.text = str(entry.get("name", ""))
	key_edit.text = key
	scale_spin.set_value_no_signal(float(entry.get("scale", 1.0)))
	rot_spin.set_value_no_signal(float(entry.get("rotationY", 0.0)))
	lift_spin.set_value_no_signal(float(entry.get("offsetY", 0.0)))
	anim_edit.text = str(entry.get("animation", "")) if entry.has("animation") else ""
	if anim_edit.text.ends_with(".0"):
		anim_edit.text = anim_edit.text.trim_suffix(".0")
	upload_btn.text = "Save changes"
	_update_buttons()
	_apply_wrap_transform()
	_preview_remote(entry)


func _on_name_changed(text: String) -> void:
	if not key_touched:
		key_edit.text = _slug(text)


## "Rồng Vàng" -> "rong-vang"
func _slug(s: String) -> String:
	const GROUPS := {
		"a": "àáạảãâầấậẩẫăằắặẳẵ", "e": "èéẹẻẽêềếệểễ", "i": "ìíịỉĩ", "o": "òóọỏõôồốộổỗơờớợởỡ",
		"u": "ùúụủũưừứựửữ", "y": "ỳýỵỷỹ", "d": "đ",
	}
	var out := ""
	for ch in s.to_lower():
		var c: String = ch
		for base in GROUPS:
			if GROUPS[base].contains(c):
				c = base
				break
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9"):
			out += c
		elif out != "" and not out.ends_with("-"):
			out += "-"
	return out.trim_suffix("-")


func _valid_key(key: String) -> bool:
	var re := RegEx.create_from_string("^[a-z0-9_-]+$")
	return re.search(key) != null


# =====================================================================
# Upload / save / delete
# =====================================================================

func _on_file_picked(path: String) -> void:
	picked_path = path
	file_label.text = path
	if name_edit.text.strip_edges() == "":
		name_edit.text = path.get_file().get_basename().capitalize()
		_on_name_changed(name_edit.text)
	var mb := FileAccess.get_file_as_bytes(path).size() / 1048576.0
	_set_status("Chosen: %s (%.1f MB). Adjust size/rotation, then upload." % [path.get_file(), mb],
		mb > MAX_UPLOAD_MB)
	_preview_local(path)


func _on_upload() -> void:
	if busy:
		return
	var key := key_edit.text.strip_edges()
	var display_name := name_edit.text.strip_edges()
	if display_name == "":
		display_name = key
	if not _valid_key(key):
		_set_status("The QR key may only contain a–z, 0–9, - and _ (no spaces).", true)
		return
	if selected_key == "" and picked_path == "":
		_set_status("Choose a model file first.", true)
		return
	if key != selected_key and models.has(key):
		_set_status("The key '%s' is already used by another model. Pick a different key." % key, true)
		return
	if gh.token == "":
		_open_settings()
		return

	_set_busy(true)
	var entry: Dictionary = (models.get(selected_key, {}) as Dictionary).duplicate()
	entry["name"] = display_name

	# 1) upload the model file (only when a new file was chosen)
	if picked_path != "":
		var bytes := FileAccess.get_file_as_bytes(picked_path)
		if bytes.is_empty():
			_fail("Could not read the file: " + picked_path)
			return
		var mb := bytes.size() / 1048576.0
		if mb > MAX_UPLOAD_MB:
			_fail("The file is %.0f MB – please keep models under %d MB so phones can load them." % [mb, int(MAX_UPLOAD_MB)])
			return
		var repo_path := "models/%s.%s" % [key, picked_path.get_extension().to_lower()]
		_set_status("Uploading %s (%.1f MB)… this can take a minute for big files." % [picked_path.get_file(), mb])
		var existing: Dictionary = await gh.get_file(repo_path)
		var sha: String = existing["sha"] if existing["ok"] else ""
		var up: Dictionary = await gh.put_file(repo_path, bytes, "Upload model '%s'" % key, sha)
		if not up["ok"]:
			_fail("Upload failed: " + up["error"])
			return
		entry["file"] = repo_path

	# 2) settings shown on the website
	entry["scale"] = snappedf(scale_spin.value, 0.001)
	entry["rotationY"] = snappedf(rot_spin.value, 0.1)
	entry["offsetY"] = snappedf(lift_spin.value, 0.001)
	var anim := anim_edit.text.strip_edges()
	if anim == "":
		entry.erase("animation")
	elif anim.is_valid_int():
		entry["animation"] = anim.to_int()
	else:
		entry["animation"] = anim

	# 3) add / update the entry in models.json (retry once if someone else changed it meanwhile)
	_set_status("Linking '%s' to its QR code…" % key)
	var saved := false
	for attempt in 2:
		var mj: Dictionary = await gh.get_file("models.json")
		if not mj["ok"]:
			_fail("Could not read models.json: " + mj["error"])
			return
		var cfg = JSON.parse_string((mj["content"] as PackedByteArray).get_string_from_utf8())
		if not (cfg is Dictionary):
			_fail("models.json in the repo is not valid JSON.")
			return
		if not cfg.has("models") or not (cfg["models"] is Dictionary):
			cfg["models"] = {}
		if selected_key != "" and selected_key != key:
			cfg["models"].erase(selected_key)
		cfg["models"][key] = entry
		var text := JSON.stringify(cfg, "  ", false) + "\n"
		var put: Dictionary = await gh.put_file("models.json", text.to_utf8_buffer(),
			"Add/update model '%s'" % key, mj["sha"])
		if put["ok"]:
			saved = true
			break
		if put["code"] != 409 or attempt == 1:
			_fail("Could not update models.json: " + put["error"])
			return
	if not saved:
		_fail("Could not update models.json.")
		return

	selected_key = key
	picked_path = ""
	form_title.text = "Edit: " + display_name
	upload_btn.text = "Save changes"
	file_label.text = str(entry.get("file", ""))
	_set_busy(false)
	await _refresh()
	_set_status("Done! '%s' is uploaded. The website updates in about 1 minute. Click 'Show QR code' to print its code." % display_name)


func _on_delete() -> void:
	if busy or selected_key == "":
		return
	var key := selected_key
	_set_busy(true)
	_set_status("Removing '%s'…" % key)
	var mj: Dictionary = await gh.get_file("models.json")
	if not mj["ok"]:
		_fail("Could not read models.json: " + mj["error"])
		return
	var cfg = JSON.parse_string((mj["content"] as PackedByteArray).get_string_from_utf8())
	if not (cfg is Dictionary) or not cfg.has("models"):
		_fail("models.json in the repo is not valid JSON.")
		return
	var file := str(cfg["models"].get(key, {}).get("file", ""))
	cfg["models"].erase(key)
	var put: Dictionary = await gh.put_file("models.json", (JSON.stringify(cfg, "  ", false) + "\n").to_utf8_buffer(),
		"Remove model '%s'" % key, mj["sha"])
	if not put["ok"]:
		_fail("Could not update models.json: " + put["error"])
		return
	# delete the model file too, if it lives in the repo and no other model uses it
	var still_used := false
	for k in cfg["models"]:
		if str(cfg["models"][k].get("file", "")) == file:
			still_used = true
	if file.begins_with("models/") and not still_used:
		var f: Dictionary = await gh.get_file(file)
		if f["ok"] and f["sha"] != "":
			await gh.delete_file(file, "Delete model file for '%s'" % key, f["sha"])
	_set_busy(false)
	_new_model()
	await _refresh()
	_set_status("'%s' was removed from the website." % key)


func _on_show_qr() -> void:
	if selected_key != "":
		OS.shell_open(site_url + "qr.html?m=" + selected_key.uri_encode())


func _fail(msg: String) -> void:
	_set_busy(false)
	_set_status(msg, true)


# =====================================================================
# 3D preview
# =====================================================================

func _build_preview_scene() -> void:
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("2a3042")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.8, 0.83, 0.9)
	env.ambient_light_energy = 0.9
	env_node.environment = env
	viewport.add_child(env_node)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 35, 0)
	sun.light_energy = 1.4
	sun.shadow_enabled = true
	viewport.add_child(sun)

	# white quiet zone + the QR code itself (1 x 1 unit, like on the website)
	var paper := MeshInstance3D.new()
	var paper_mesh := PlaneMesh.new()
	paper_mesh.size = Vector2(1.4, 1.4)
	paper.mesh = paper_mesh
	var paper_mat := StandardMaterial3D.new()
	paper_mat.albedo_color = Color.WHITE
	paper.material_override = paper_mat
	paper.position.y = -0.002
	viewport.add_child(paper)

	var qr := MeshInstance3D.new()
	var qr_mesh := PlaneMesh.new()
	qr_mesh.size = Vector2(1, 1)
	qr.mesh = qr_mesh
	var qr_mat := StandardMaterial3D.new()
	qr_mat.albedo_texture = _fake_qr_texture()
	qr_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	qr.material_override = qr_mat
	viewport.add_child(qr)

	wrap = Node3D.new()
	viewport.add_child(wrap)

	pivot = Node3D.new()
	pivot.position = Vector3(0, 0.35, 0)
	viewport.add_child(pivot)
	cam = Camera3D.new()
	cam.fov = 45
	pivot.add_child(cam)
	_update_camera()


func _fake_qr_texture() -> ImageTexture:
	var n := 25
	var img := Image.create_empty(n, n, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for y in n:
		for x in n:
			img.set_pixel(x, y, Color.BLACK if rng.randf() < 0.5 else Color.WHITE)
	for o in [Vector2i(0, 0), Vector2i(n - 7, 0), Vector2i(0, n - 7)]:
		for y in 7:
			for x in 7:
				var b := maxi(absi(x - 3), absi(y - 3))
				img.set_pixel(o.x + x, o.y + y, Color.BLACK if (b == 3 or b <= 1) else Color.WHITE)
	return ImageTexture.create_from_image(img)


func _update_camera() -> void:
	pivot.rotation = Vector3(pitch, yaw, 0)
	cam.position = Vector3(0, 0, dist)


func _on_preview_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			dragging = mb.pressed
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			dist = maxf(0.8, dist * 0.9)
			_update_camera()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dist = minf(12.0, dist * 1.1)
			_update_camera()
	elif ev is InputEventMouseMotion and dragging:
		var mm := ev as InputEventMouseMotion
		yaw -= mm.relative.x * 0.01
		pitch = clampf(pitch - mm.relative.y * 0.01, -1.45, 0.25)
		_update_camera()


func _apply_wrap_transform() -> void:
	wrap.scale = Vector3.ONE * float(scale_spin.value)
	wrap.rotation = Vector3(0, deg_to_rad(rot_spin.value), 0)
	wrap.position = Vector3(0, lift_spin.value, 0)


func _clear_preview() -> void:
	for c in wrap.get_children():
		c.queue_free()
	model_root = null
	anim_player = null


func _preview_local(path: String) -> void:
	var ext := path.get_extension().to_lower()
	_show_model_bytes(FileAccess.get_file_as_bytes(path), ext, path.get_base_dir())


func _preview_remote(entry: Dictionary) -> void:
	_clear_preview()
	var file := str(entry.get("file", ""))
	if file == "" or file == "builtin":
		_set_status("This is the website's built-in model (no file to preview).")
		return
	var ext: String = file.get_extension().to_lower().split("?")[0]
	_set_status("Downloading %s for preview…" % file.get_file())
	var key_at_start := selected_key
	var r: Dictionary
	if file.begins_with("http"):
		r = await gh.download(file)
	else:
		r = await gh.get_raw(file)
	if selected_key != key_at_start:
		return  # user selected something else meanwhile
	if not r["ok"]:
		_set_status("Could not download the model for preview: " + r["error"], true)
		return
	_show_model_bytes(r["bytes"], ext, "")
	_set_status("Editing '%s'. Change settings and click 'Save changes', or choose a new file to replace the model." % selected_key)


func _show_model_bytes(bytes: PackedByteArray, ext: String, base_path: String) -> void:
	_clear_preview()
	if bytes.is_empty():
		_set_status("The model file is empty.", true)
		return
	var doc: GLTFDocument
	var state: GLTFState
	if ext == "fbx":
		if not ClassDB.class_exists("FBXDocument"):
			_set_status("This Godot build can't preview .fbx files – uploading still works.")
			return
		doc = ClassDB.instantiate("FBXDocument")
		state = ClassDB.instantiate("FBXState")
	else:
		doc = GLTFDocument.new()
		state = GLTFState.new()
	var err := doc.append_from_buffer(bytes, base_path, state)
	if err != OK:
		_set_status("Couldn't read this model for the preview (error %d). It may still work on the website." % err, true)
		return
	var scene := doc.generate_scene(state)
	if scene == null:
		_set_status("Couldn't build the preview for this model.", true)
		return
	model_root = Node3D.new()
	wrap.add_child(model_root)
	model_root.add_child(scene)
	_fit_model()
	var players := scene.find_children("*", "AnimationPlayer", true, false)
	if players.size() > 0:
		anim_player = players[0]
		_play_animation()


## Same normalisation as the website: fit inside 0.9 of the QR width and stand on the code.
func _fit_model() -> void:
	var inv := model_root.global_transform.affine_inverse()
	var box := AABB()
	var first := true
	for n in model_root.find_children("*", "VisualInstance3D", true, false):
		var vi := n as VisualInstance3D
		var b: AABB = inv * vi.global_transform * vi.get_aabb()
		if first:
			box = b
			first = false
		else:
			box = box.merge(b)
	if first:
		return
	var box_size := box.size
	var s := 0.9 / maxf(maxf(box_size.x, box_size.z), maxf(box_size.y * 0.8, 0.000001))
	var c := box.get_center()
	model_root.scale = Vector3.ONE * s
	model_root.position = Vector3(-c.x * s, -box.position.y * s, -c.z * s)


func _play_animation() -> void:
	if anim_player == null:
		return
	var names := anim_player.get_animation_list()
	if names.is_empty():
		return
	var want := anim_edit.text.strip_edges()
	var pick: String = names[0]
	if want.is_valid_int() and want.to_int() >= 0 and want.to_int() < names.size():
		pick = names[want.to_int()]
	elif want != "":
		for nm in names:
			if nm == want or nm.ends_with("/" + want):
				pick = nm
				break
	var a := anim_player.get_animation(pick)
	if a:
		a.loop_mode = Animation.LOOP_LINEAR
	anim_player.play(pick)
