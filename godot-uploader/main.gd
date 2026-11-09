extends Control
## QR 3D Uploader
## Load a .glb/.fbx model from this PC, adjust its transform, lighting and materials while
## previewing it on a QR code, then upload it to the GitHub repo behind the QR AR website.
## Everything set here is saved in models.json and used by the website exactly the same way.

const GitHubClient = preload("res://github.gd")

const SETTINGS_PATH := "user://settings.cfg"
const DEFAULT_OWNER := "Novaillusion"
const DEFAULT_REPO := "Danangtui_QR_3D_scanner"
const DEFAULT_SITE := "https://novaillusion.github.io/Danangtui_QR_3D_scanner/"
const MAX_UPLOAD_MB := 50.0
const MODEL_EXTS := ["glb", "fbx"]
const IMAGE_EXTS := ["png", "jpg", "jpeg", "webp"]
const ALL_MATS := "*"

## Same defaults as the website (index.html → DEFAULT_LIGHTING).
const DEFAULT_LIGHTING := {
	"ambient": 1.6, "ambientColor": "#ffffff", "sun": 2.2, "sunColor": "#ffffff",
	"sunAzimuth": 26.6, "sunElevation": 53.3, "exposure": 1.0, "shadow": 0.55,
}

var gh: GitHubClient
var settings := ConfigFile.new()
var site_url := DEFAULT_SITE

var models := {}            # key -> entry (Dictionary) from models.json
var selected_key := ""      # key being edited; "" = new model
var picked_path := ""       # local model file chosen for upload
var key_touched := false
var busy := false

# material state
var mat_overrides := {}     # material name (or "*") -> { color, metalness, ... , map }
var mat_refs := {}          # material name -> Array of preview materials (duplicates we can edit)
var mat_orig := {}          # material name -> original values
var tex_cache := {}         # "local:<path>" or repo path -> Texture2D
var light_dirty := false    # lighting differs from the defaults

# --- UI ---
var model_list: ItemList
var form_title: Label
var file_label: Label
var name_edit: LineEdit
var key_edit: LineEdit
var anim_edit: LineEdit
var pos_spins: Array = []
var rot_spins: Array = []
var scale_spins: Array = []
var scale_lock: CheckBox
var light_ui := {}          # lighting field -> SpinBox or ColorPickerButton
var mat_select: OptionButton
var mat_ui := {}            # material field -> SpinBox or ColorPickerButton
var mat_tex_label: Label
var tabs: TabContainer
var upload_btn: Button
var qr_btn: Button
var delete_btn: Button
var status_label: Label
var file_dialog: FileDialog
var tex_dialog: FileDialog
var settings_dialog: ConfirmationDialog
var confirm_delete: ConfirmationDialog
var s_owner: LineEdit
var s_repo: LineEdit
var s_branch: LineEdit
var s_token: LineEdit
var s_site: LineEdit

# --- 3D preview ---
var viewport: SubViewport
var env: Environment
var sun: DirectionalLight3D
var shadow_mat: StandardMaterial3D
var pivot: Node3D
var cam: Camera3D
var wrap: Node3D            # user transform (same as the website's wrap group)
var model_root: Node3D      # fitted model: 0.9 of the QR width, standing on the code
var anim_player: AnimationPlayer
var dragging := false
var yaw := 0.6
var pitch := -0.55
var dist := 2.6


func _ready() -> void:
	get_window().title = "QR 3D Uploader"
	get_window().files_dropped.connect(_on_files_dropped)
	gh = GitHubClient.new()
	add_child(gh)
	_build_ui()
	_load_settings()
	_new_model()
	if gh.token == "":
		_set_status("Welcome! Open Settings and paste your GitHub token. You can already load and preview models from this PC.")
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
		margin.add_theme_constant_override("margin_" + side, 12)
	add_child(margin)

	var split := HSplitContainer.new()
	margin.add_child(split)

	# ---- left: models on the website ----
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 250
	split.add_child(left)
	left.add_child(_title("Models on the website"))
	model_list = ItemList.new()
	model_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	model_list.item_selected.connect(_on_list_selected)
	left.add_child(model_list)
	var lrow := HBoxContainer.new()
	left.add_child(lrow)
	lrow.add_child(_button("+ New", _new_model))
	lrow.add_child(_button("Refresh", _refresh))
	lrow.add_child(_button("Settings", _open_settings))
	left.add_child(_button("Open website", func(): OS.shell_open(site_url)))

	var split2 := HSplitContainer.new()
	split2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(split2)

	# ---- center: 3D preview ----
	var center := VBoxContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split2.add_child(center)
	form_title = _title("New model")
	center.add_child(form_title)
	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	svc.custom_minimum_size = Vector2(380, 300)
	svc.gui_input.connect(_on_preview_input)
	center.add_child(svc)
	viewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_4X
	svc.add_child(viewport)
	_build_preview_scene()
	var hint := Label.new()
	hint.text = "Drag to orbit · scroll to zoom · the square is the QR code (1 unit wide) · drop .glb/.fbx or images onto this window"
	hint.modulate = Color(1, 1, 1, 0.55)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	center.add_child(hint)

	# ---- right: inspector ----
	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 390
	right.add_theme_constant_override("separation", 8)
	split2.add_child(right)
	tabs = TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(tabs)
	_build_model_tab()
	_build_transform_tab()
	_build_lighting_tab()
	_build_material_tab()

	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 6)
	right.add_child(brow)
	upload_btn = _button("Upload to website", _on_upload)
	upload_btn.custom_minimum_size = Vector2(170, 38)
	brow.add_child(upload_btn)
	qr_btn = _button("Show QR", _on_show_qr)
	brow.add_child(qr_btn)
	delete_btn = _button("Delete", func(): confirm_delete.popup_centered())
	brow.add_child(delete_btn)
	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.custom_minimum_size = Vector2(380, 60)
	right.add_child(status_label)

	_build_dialogs()


func _tab(title: String) -> GridContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 6)
	box.add_child(grid)
	return grid


func _build_model_tab() -> void:
	var grid := _tab("Model")
	var file_row := HBoxContainer.new()
	file_label = Label.new()
	file_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	file_label.clip_text = true
	file_row.add_child(file_label)
	file_row.add_child(_button("Choose file…", func(): file_dialog.popup_centered_ratio(0.7)))
	_row(grid, "Model file", file_row)

	name_edit = LineEdit.new()
	name_edit.placeholder_text = "e.g. Dragon"
	name_edit.text_changed.connect(_on_name_changed)
	_row(grid, "Name", name_edit)

	key_edit = LineEdit.new()
	key_edit.placeholder_text = "e.g. dragon (a–z, 0–9, - and _)"
	key_edit.text_changed.connect(_on_key_typed)
	_row(grid, "QR key", key_edit)

	anim_edit = LineEdit.new()
	anim_edit.placeholder_text = "empty = first animation, or a name/number"
	anim_edit.text_changed.connect(func(_t): _play_animation())
	_row(grid, "Animation", anim_edit)

	var note := Label.new()
	note.text = "Formats: .glb (best) or .fbx. For .fbx, embed textures when exporting."
	note.modulate = Color(1, 1, 1, 0.6)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	grid.add_child(Control.new())
	grid.add_child(note)


func _build_transform_tab() -> void:
	var grid := _tab("Transform")
	for i in 3:
		pos_spins.append(_num(grid, "Position " + "XYZ"[i], -5.0, 5.0, 0.01, 0.0, _on_transform_changed))
	for i in 3:
		rot_spins.append(_num(grid, "Rotation " + "XYZ"[i] + " (°)", -180.0, 180.0, 1.0, 0.0, _on_transform_changed))
	scale_lock = CheckBox.new()
	scale_lock.text = "Uniform scale"
	scale_lock.button_pressed = true
	_row(grid, "", scale_lock)
	for i in 3:
		var axis := i
		scale_spins.append(_num(grid, "Scale " + "XYZ"[i], 0.01, 20.0, 0.01, 1.0,
			func(v): _on_scale_changed(axis, v)))
	grid.add_child(Control.new())
	grid.add_child(_button("Reset transform", _reset_transform))
	var note := Label.new()
	note.text = "Units are QR-code widths. Y is up from the code; Z points to the code's bottom edge."
	note.modulate = Color(1, 1, 1, 0.6)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	grid.add_child(Control.new())
	grid.add_child(note)


func _build_lighting_tab() -> void:
	var grid := _tab("Lighting")
	light_ui["ambient"] = _num(grid, "Ambient light", 0.0, 6.0, 0.05, 1.6, _on_lighting_changed)
	light_ui["ambientColor"] = _color(grid, "Ambient color", Color.WHITE, _on_lighting_changed)
	light_ui["sun"] = _num(grid, "Sun light", 0.0, 10.0, 0.05, 2.2, _on_lighting_changed)
	light_ui["sunColor"] = _color(grid, "Sun color", Color.WHITE, _on_lighting_changed)
	light_ui["sunAzimuth"] = _num(grid, "Sun direction (°)", -180.0, 180.0, 1.0, 26.6, _on_lighting_changed)
	light_ui["sunElevation"] = _num(grid, "Sun height (°)", 0.0, 90.0, 1.0, 53.3, _on_lighting_changed)
	light_ui["exposure"] = _num(grid, "Exposure", 0.1, 4.0, 0.05, 1.0, _on_lighting_changed)
	light_ui["shadow"] = _num(grid, "Ground shadow", 0.0, 1.0, 0.05, 0.55, _on_lighting_changed)
	grid.add_child(Control.new())
	grid.add_child(_button("Reset lighting", _reset_lighting))
	var note := Label.new()
	note.text = "Lighting is saved per model. The sun turns with the QR code, so the model stays lit the same way as people walk around it."
	note.modulate = Color(1, 1, 1, 0.6)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	grid.add_child(Control.new())
	grid.add_child(note)


func _build_material_tab() -> void:
	var grid := _tab("Material")
	mat_select = OptionButton.new()
	mat_select.item_selected.connect(func(_i): _show_material_ui())
	_row(grid, "Material", mat_select)
	mat_ui["color"] = _color(grid, "Base color", Color.WHITE, func(c): _on_material_changed("color", c))
	mat_ui["metalness"] = _num(grid, "Metalness", 0.0, 1.0, 0.01, 0.0, func(v): _on_material_changed("metalness", v))
	mat_ui["roughness"] = _num(grid, "Roughness", 0.0, 1.0, 0.01, 1.0, func(v): _on_material_changed("roughness", v))
	mat_ui["emissive"] = _color(grid, "Glow color", Color.BLACK, func(c): _on_material_changed("emissive", c))
	mat_ui["emissiveIntensity"] = _num(grid, "Glow strength", 0.0, 20.0, 0.1, 1.0, func(v): _on_material_changed("emissiveIntensity", v))
	mat_ui["opacity"] = _num(grid, "Opacity", 0.0, 1.0, 0.01, 1.0, func(v): _on_material_changed("opacity", v))

	var tex_row := VBoxContainer.new()
	mat_tex_label = Label.new()
	mat_tex_label.clip_text = true
	tex_row.add_child(mat_tex_label)
	var tb := HBoxContainer.new()
	tb.add_child(_button("Replace…", func(): tex_dialog.popup_centered_ratio(0.7)))
	tb.add_child(_button("Remove", func(): _set_texture_override("")))
	tb.add_child(_button("Original", func(): _clear_material_field("map")))
	tex_row.add_child(tb)
	_row(grid, "Texture", tex_row)

	grid.add_child(Control.new())
	grid.add_child(_button("Reset this material", _reset_material))
	var note := Label.new()
	note.text = "'All materials' changes every part of the model; pick one material to change only that part. Only the settings you change are saved."
	note.modulate = Color(1, 1, 1, 0.6)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	grid.add_child(Control.new())
	grid.add_child(note)


func _build_dialogs() -> void:
	file_dialog = FileDialog.new()
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.filters = PackedStringArray(["*.glb, *.fbx ; 3D models", "*.glb ; glTF binary", "*.fbx ; FBX"])
	file_dialog.use_native_dialog = true
	file_dialog.title = "Choose a 3D model"
	file_dialog.file_selected.connect(_on_file_picked)
	add_child(file_dialog)

	tex_dialog = FileDialog.new()
	tex_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	tex_dialog.access = FileDialog.ACCESS_FILESYSTEM
	tex_dialog.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp ; Images"])
	tex_dialog.use_native_dialog = true
	tex_dialog.title = "Choose a texture image"
	tex_dialog.file_selected.connect(_on_texture_picked)
	add_child(tex_dialog)

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
	sbox.add_child(_button("Open GitHub token page",
		func(): OS.shell_open("https://github.com/settings/personal-access-tokens/new")))
	settings_dialog.add_child(sbox)
	settings_dialog.confirmed.connect(_on_settings_saved)
	add_child(settings_dialog)


# ---- small UI helpers ----

func _title(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 20)
	return l


func _button(t: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = t
	b.pressed.connect(cb)
	return b


func _row(grid: GridContainer, label_text: String, control: Control) -> void:
	var l := Label.new()
	l.text = label_text
	grid.add_child(l)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(control)


## Slider + number box. Returns the SpinBox; cb(value) is called only when the user changes it.
func _num(grid: GridContainer, label_text: String, lo: float, hi: float, step: float, value: float, cb: Callable) -> SpinBox:
	var row := HBoxContainer.new()
	var slider := HSlider.new()
	slider.min_value = lo
	slider.max_value = hi
	slider.step = step
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var spin := SpinBox.new()
	spin.min_value = lo
	spin.max_value = hi
	spin.step = step
	spin.value = value
	spin.allow_greater = true
	spin.allow_lesser = true
	spin.custom_minimum_size.x = 96
	spin.set_meta("slider", slider)
	slider.value_changed.connect(func(v): spin.value = v)
	spin.value_changed.connect(func(v):
		slider.set_value_no_signal(v)
		cb.call(v)
	)
	row.add_child(slider)
	row.add_child(spin)
	_row(grid, label_text, row)
	return spin


func _set_num(spin: SpinBox, v: float) -> void:
	spin.set_value_no_signal(v)
	(spin.get_meta("slider") as HSlider).set_value_no_signal(v)


func _color(grid: GridContainer, label_text: String, value: Color, cb: Callable) -> ColorPickerButton:
	var b := ColorPickerButton.new()
	b.color = value
	b.edit_alpha = false
	b.custom_minimum_size = Vector2(80, 28)
	b.color_changed.connect(func(c): cb.call(c))
	_row(grid, label_text, b)
	return b


func _hex(c: Color) -> String:
	return "#" + c.to_html(false)


func _set_status(t: String, is_error: bool = false) -> void:
	status_label.text = t
	status_label.modulate = Color("ff8a80") if is_error else Color("cfe3ff")


func _set_busy(on: bool) -> void:
	busy = on
	upload_btn.disabled = on
	if on:
		qr_btn.disabled = true
		delete_btn.disabled = true
	else:
		_update_buttons()


func _update_buttons() -> void:
	delete_btn.disabled = busy or selected_key == ""
	qr_btn.disabled = busy or selected_key == ""


# =====================================================================
# Settings
# =====================================================================

func _load_settings() -> void:
	settings.load(SETTINGS_PATH)
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
# Model list / form
# =====================================================================

func _refresh() -> void:
	if busy or gh.token == "":
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
	file_label.text = "No file chosen – click Choose file… or drop a .glb/.fbx here"
	name_edit.text = ""
	key_edit.text = ""
	anim_edit.text = ""
	upload_btn.text = "Upload to website"
	_load_entry_to_ui({})
	_clear_preview()
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
	anim_edit.text = str(entry.get("animation", "")).trim_suffix(".0") if entry.has("animation") else ""
	upload_btn.text = "Save changes"
	_load_entry_to_ui(entry)
	_update_buttons()
	_preview_remote(entry)


## Put an entry's transform / lighting / material settings into the inspector.
func _load_entry_to_ui(entry: Dictionary) -> void:
	# transform (older entries used rotationY / offsetY)
	var pos: Array = entry.get("position", [0.0, entry.get("offsetY", 0.0), 0.0])
	var rot: Array = entry.get("rotation", [0.0, entry.get("rotationY", 0.0), 0.0])
	var sc = entry.get("scale", 1.0)
	var sca: Array = sc if sc is Array else [sc, sc, sc]
	for i in 3:
		_set_num(pos_spins[i], float(pos[i]))
		_set_num(rot_spins[i], float(rot[i]))
		_set_num(scale_spins[i], float(sca[i]))
	scale_lock.set_pressed_no_signal(not (sc is Array) or (sca[0] == sca[1] and sca[1] == sca[2]))
	_apply_transform()

	# lighting
	var lighting: Dictionary = entry.get("lighting", {})
	light_dirty = not lighting.is_empty()
	var L := DEFAULT_LIGHTING.duplicate()
	L.merge(lighting, true)
	_put_lighting_ui(L)

	# materials
	mat_overrides = (entry.get("materials", {}) as Dictionary).duplicate(true)
	_rebuild_material_list()


func _on_name_changed(t: String) -> void:
	if not key_touched:
		key_edit.text = _slug(t)


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


## Keep the QR key valid while typing: "Tara Test" -> "tara-test" (lowercase, no spaces, no accents).
func _on_key_typed(t: String) -> void:
	key_touched = true
	var clean := _clean_key(t)
	if clean != t:
		var caret := key_edit.caret_column
		key_edit.text = clean
		key_edit.caret_column = mini(caret, clean.length())


func _clean_key(s: String) -> String:
	var out := ""
	for ch in _slug_chars(s.to_lower()):
		var c: String = ch
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "-" or c == "_":
			out += c
		elif c == " ":
			out += "-"
	return out


## Replace Vietnamese accented letters with plain ones ("ồ" -> "o", "đ" -> "d").
func _slug_chars(s: String) -> String:
	const GROUPS := {
		"a": "àáạảãâầấậẩẫăằắặẳẵ", "e": "èéẹẻẽêềếệểễ", "i": "ìíịỉĩ", "o": "òóọỏõôồốộổỗơờớợởỡ",
		"u": "ùúụủũưừứựửữ", "y": "ỳýỵỷỹ", "d": "đ",
	}
	var out := ""
	for ch in s:
		var c: String = ch
		for base in GROUPS:
			if GROUPS[base].contains(c):
				c = base
				break
		out += c
	return out


func _valid_key(key: String) -> bool:
	var re := RegEx.create_from_string("^[a-z0-9_-]+$")
	return re.search(key) != null


# =====================================================================
# Loading local files (dialog or drag & drop)
# =====================================================================

func _on_files_dropped(files: PackedStringArray) -> void:
	for f in files:
		var ext := f.get_extension().to_lower()
		if ext in MODEL_EXTS:
			_on_file_picked(f)
		elif ext in IMAGE_EXTS:
			tabs.current_tab = 3
			_on_texture_picked(f)
		else:
			_set_status("Can't use '%s' – drop a .glb/.fbx model or a .png/.jpg texture." % f.get_file(), true)


func _on_file_picked(path: String) -> void:
	if not FileAccess.file_exists(path):
		_set_status("File not found: " + path, true)
		return
	picked_path = path
	file_label.text = path
	if name_edit.text.strip_edges() == "":
		name_edit.text = path.get_file().get_basename().capitalize()
		_on_name_changed(name_edit.text)
	var mb := FileAccess.get_file_as_bytes(path).size() / 1048576.0
	_set_status("Loaded %s (%.1f MB) from this PC. Adjust it, then upload." % [path.get_file(), mb], mb > MAX_UPLOAD_MB)
	# a new model has different materials: keep only the "all materials" settings
	var keep: Dictionary = mat_overrides.get(ALL_MATS, {})
	mat_overrides = {}
	if not keep.is_empty():
		mat_overrides[ALL_MATS] = keep
	_show_model_bytes(FileAccess.get_file_as_bytes(path), path.get_extension().to_lower(), path.get_base_dir())


func _on_texture_picked(path: String) -> void:
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		_set_status("Couldn't read the image " + path.get_file(), true)
		return
	img.generate_mipmaps()
	tex_cache["local:" + path] = ImageTexture.create_from_image(img)
	_set_texture_override("local:" + path)


# =====================================================================
# Transform
# =====================================================================

func _on_transform_changed(_v: float) -> void:
	_apply_transform()


func _on_scale_changed(axis: int, v: float) -> void:
	if scale_lock.button_pressed:
		for i in 3:
			if i != axis:
				_set_num(scale_spins[i], v)
	_apply_transform()


func _reset_transform() -> void:
	for i in 3:
		_set_num(pos_spins[i], 0.0)
		_set_num(rot_spins[i], 0.0)
		_set_num(scale_spins[i], 1.0)
	scale_lock.set_pressed_no_signal(true)
	_apply_transform()


## Same as the website: wrap.position, wrap.rotation (XYZ order, degrees), wrap.scale.
func _apply_transform() -> void:
	var r := Vector3(deg_to_rad(rot_spins[0].value), deg_to_rad(rot_spins[1].value), deg_to_rad(rot_spins[2].value))
	var basis := Basis(Vector3.RIGHT, r.x) * Basis(Vector3.UP, r.y) * Basis(Vector3.BACK, r.z)
	basis = basis * Basis.from_scale(Vector3(scale_spins[0].value, scale_spins[1].value, scale_spins[2].value))
	wrap.transform = Transform3D(basis, Vector3(pos_spins[0].value, pos_spins[1].value, pos_spins[2].value))


# =====================================================================
# Lighting
# =====================================================================

func _put_lighting_ui(L: Dictionary) -> void:
	for k in light_ui:
		var c = light_ui[k]
		if c is ColorPickerButton:
			c.color = Color(str(L[k]))
		else:
			_set_num(c, float(L[k]))
	_apply_lighting()


func _lighting_values() -> Dictionary:
	var L := {}
	for k in light_ui:
		var c = light_ui[k]
		L[k] = _hex(c.color) if c is ColorPickerButton else snappedf(c.value, 0.001)
	return L


func _on_lighting_changed(_v) -> void:
	light_dirty = true
	_apply_lighting()


func _reset_lighting() -> void:
	light_dirty = false
	_put_lighting_ui(DEFAULT_LIGHTING)


func _apply_lighting() -> void:
	var L := _lighting_values()
	# The website uses a hemisphere light + a sun; these factors give a similar look in Godot.
	env.ambient_light_color = Color(str(L["ambientColor"]))
	env.ambient_light_energy = float(L["ambient"]) * 0.55
	sun.light_color = Color(str(L["sunColor"]))
	sun.light_energy = float(L["sun"]) * 0.64
	var az := deg_to_rad(float(L["sunAzimuth"]))
	var el := deg_to_rad(float(L["sunElevation"]))
	var dir := Vector3(sin(az) * cos(el), sin(el), cos(az) * cos(el))
	var up := Vector3.UP if absf(dir.y) < 0.99 else Vector3.FORWARD
	sun.basis = Basis.looking_at(-dir, up)
	env.tonemap_exposure = float(L["exposure"])
	shadow_mat.albedo_color = Color(0, 0, 0, float(L["shadow"]))


# =====================================================================
# Materials
# =====================================================================

func _rebuild_material_list() -> void:
	var prev := _current_mat()
	mat_select.clear()
	mat_select.add_item("All materials")
	mat_select.set_item_metadata(0, ALL_MATS)
	var names := mat_refs.keys()
	names.sort()
	for nm in names:
		if nm == "":
			continue  # unnamed materials can only be changed through "All materials"
		mat_select.add_item(nm)
		mat_select.set_item_metadata(mat_select.item_count - 1, nm)
	for i in mat_select.item_count:
		if mat_select.get_item_metadata(i) == prev:
			mat_select.select(i)
	_apply_materials()
	_show_material_ui()


func _current_mat() -> String:
	if mat_select == null or mat_select.item_count == 0 or mat_select.selected < 0:
		return ALL_MATS
	return str(mat_select.get_item_metadata(mat_select.selected))


## Effective values (original + overrides) of the selected material, shown in the inspector.
func _show_material_ui() -> void:
	var nm := _current_mat()
	var orig: Dictionary = {}
	if mat_orig.has(nm):
		orig = mat_orig[nm]
	elif not mat_orig.is_empty():
		orig = mat_orig[mat_orig.keys()[0]]
	var base := {
		"color": _hex(orig.get("color", Color.WHITE)),
		"metalness": orig.get("metallic", 0.0),
		"roughness": orig.get("roughness", 1.0),
		"emissive": _hex(orig.get("emission", Color.BLACK)) if orig.get("emission_enabled", false) else "#000000",
		"emissiveIntensity": orig.get("emission_energy", 1.0),
		"opacity": (orig.get("color", Color.WHITE) as Color).a,
	}
	var ov := _merged_overrides(nm)
	for k in mat_ui:
		var v = ov.get(k, base[k])
		var c = mat_ui[k]
		if c is ColorPickerButton:
			c.color = Color(str(v))
		else:
			_set_num(c, float(v))
	var m := str(ov.get("map", "(original)"))
	if m == "":
		m = "(removed)"
	mat_tex_label.text = m.trim_prefix("local:").get_file() if m.begins_with("local:") else m


func _merged_overrides(nm: String) -> Dictionary:
	var ov := {}
	ov.merge(mat_overrides.get(ALL_MATS, {}), true)
	if nm != ALL_MATS:
		ov.merge(mat_overrides.get(nm, {}), true)
	return ov


func _on_material_changed(field: String, value) -> void:
	var nm := _current_mat()
	if not mat_overrides.has(nm):
		mat_overrides[nm] = {}
	mat_overrides[nm][field] = _hex(value) if value is Color else snappedf(value, 0.001)
	_apply_materials()


func _set_texture_override(map_value: String) -> void:
	var nm := _current_mat()
	if not mat_overrides.has(nm):
		mat_overrides[nm] = {}
	mat_overrides[nm]["map"] = map_value
	_apply_materials()
	_show_material_ui()
	if map_value.begins_with("local:"):
		_set_status("Texture loaded from this PC for '%s'. It's uploaded together with the model." % _mat_label(nm))


func _clear_material_field(field: String) -> void:
	var nm := _current_mat()
	if mat_overrides.has(nm):
		mat_overrides[nm].erase(field)
		if mat_overrides[nm].is_empty():
			mat_overrides.erase(nm)
	_apply_materials()
	_show_material_ui()


func _reset_material() -> void:
	mat_overrides.erase(_current_mat())
	_apply_materials()
	_show_material_ui()


func _mat_label(nm: String) -> String:
	return "all materials" if nm == ALL_MATS else nm


## Collect the model's materials, replacing each with an editable copy.
func _collect_materials(root: Node) -> void:
	mat_refs = {}
	mat_orig = {}
	var copies := {}   # original material -> copy (shared materials stay shared)
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var m := mi.get_active_material(s)
			if not (m is BaseMaterial3D):
				continue
			if not copies.has(m):
				copies[m] = m.duplicate()
			var copy: BaseMaterial3D = copies[m]
			mi.set_surface_override_material(s, copy)
			var nm := str(m.resource_name)
			if not mat_refs.has(nm):
				mat_refs[nm] = []
				mat_orig[nm] = {
					"color": copy.albedo_color, "texture": copy.albedo_texture,
					"metallic": copy.metallic, "roughness": copy.roughness,
					"emission_enabled": copy.emission_enabled, "emission": copy.emission,
					"emission_energy": copy.emission_energy_multiplier, "transparency": copy.transparency,
				}
			if not mat_refs[nm].has(copy):
				mat_refs[nm].append(copy)


## Apply "all materials" + per-material overrides to the preview (same rules as the website).
func _apply_materials() -> void:
	for nm in mat_refs:
		var orig: Dictionary = mat_orig[nm]
		var ov := {}
		ov.merge(mat_overrides.get(ALL_MATS, {}), true)
		ov.merge(mat_overrides.get(nm, {}), true)
		for m in mat_refs[nm]:
			var mat := m as BaseMaterial3D
			var col: Color = orig["color"]
			if ov.has("color"):
				var c := Color(str(ov["color"]))
				col = Color(c.r, c.g, c.b, col.a)
			if ov.has("opacity"):
				col.a = float(ov["opacity"])
			mat.albedo_color = col
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if col.a < 0.999 else orig["transparency"]
			mat.metallic = float(ov.get("metalness", orig["metallic"]))
			mat.roughness = float(ov.get("roughness", orig["roughness"]))
			if ov.has("emissive") or ov.has("emissiveIntensity"):
				mat.emission_enabled = true
				mat.emission = Color(str(ov["emissive"])) if ov.has("emissive") else orig["emission"]
			else:
				mat.emission_enabled = orig["emission_enabled"]
				mat.emission = orig["emission"]
			mat.emission_energy_multiplier = float(ov.get("emissiveIntensity", orig["emission_energy"]))
			if ov.has("map"):
				var mp := str(ov["map"])
				mat.albedo_texture = tex_cache.get(mp, orig["texture"]) if mp != "" else null
			else:
				mat.albedo_texture = orig["texture"]


## Download textures referenced by an entry so the preview shows them.
func _fetch_remote_textures() -> void:
	for nm in mat_overrides.keys():
		var mp := str(mat_overrides[nm].get("map", ""))
		if mp == "" or mp.begins_with("local:") or tex_cache.has(mp):
			continue
		var r: Dictionary
		if mp.begins_with("http"):
			r = await gh.download(mp)
		else:
			r = await gh.get_raw(mp)
		if not r["ok"]:
			continue
		var img := Image.new()
		var bytes: PackedByteArray = r["bytes"]
		var ext := mp.get_extension().to_lower()
		var err := ERR_FILE_UNRECOGNIZED
		if ext == "png":
			err = img.load_png_from_buffer(bytes)
		elif ext == "jpg" or ext == "jpeg":
			err = img.load_jpg_from_buffer(bytes)
		elif ext == "webp":
			err = img.load_webp_from_buffer(bytes)
		if err == OK:
			img.generate_mipmaps()
			tex_cache[mp] = ImageTexture.create_from_image(img)
	_apply_materials()


# =====================================================================
# Upload / save / delete
# =====================================================================

func _on_upload() -> void:
	if busy:
		return
	var key := _clean_key(key_edit.text.strip_edges())
	key_edit.text = key
	var display_name := name_edit.text.strip_edges()
	if display_name == "":
		display_name = key
	if not _valid_key(key):
		_set_status("Please enter a QR key (letters a–z, numbers, - or _).", true)
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
	var entry: Dictionary = (models.get(selected_key, {}) as Dictionary).duplicate(true)
	entry["name"] = display_name

	# 1) model file (only when a new one was chosen)
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
		var ok: bool = await _upload_file(repo_path, bytes, "Upload model '%s'" % key)
		if not ok:
			return
		entry["file"] = repo_path

	# 2) textures loaded from this PC
	for nm in mat_overrides.keys():
		var mp := str(mat_overrides[nm].get("map", ""))
		if not mp.begins_with("local:"):
			continue
		var local := mp.trim_prefix("local:")
		var tbytes := FileAccess.get_file_as_bytes(local)
		if tbytes.is_empty():
			_fail("Could not read the texture " + local)
			return
		var part := "all" if nm == ALL_MATS else _slug(str(nm))
		if part == "":
			part = "mat"
		var tpath := "models/%s-%s.%s" % [key, part, local.get_extension().to_lower()]
		_set_status("Uploading texture %s…" % local.get_file())
		var tok: bool = await _upload_file(tpath, tbytes, "Upload texture for '%s'" % key)
		if not tok:
			return
		tex_cache[tpath] = tex_cache.get(mp)
		mat_overrides[nm]["map"] = tpath

	# 3) settings used by the website
	var uniform: bool = scale_lock.button_pressed
	entry["scale"] = snappedf(scale_spins[0].value, 0.001) if uniform else \
		[snappedf(scale_spins[0].value, 0.001), snappedf(scale_spins[1].value, 0.001), snappedf(scale_spins[2].value, 0.001)]
	entry["position"] = [snappedf(pos_spins[0].value, 0.001), snappedf(pos_spins[1].value, 0.001), snappedf(pos_spins[2].value, 0.001)]
	entry["rotation"] = [snappedf(rot_spins[0].value, 0.1), snappedf(rot_spins[1].value, 0.1), snappedf(rot_spins[2].value, 0.1)]
	entry.erase("rotationY")
	entry.erase("offsetY")
	if light_dirty:
		entry["lighting"] = _lighting_values()
	else:
		entry.erase("lighting")
	var mats := {}
	for nm in mat_overrides:
		if not (mat_overrides[nm] as Dictionary).is_empty():
			mats[nm] = mat_overrides[nm]
	if mats.is_empty():
		entry.erase("materials")
	else:
		entry["materials"] = mats
	var anim := anim_edit.text.strip_edges()
	if anim == "":
		entry.erase("animation")
	elif anim.is_valid_int():
		entry["animation"] = anim.to_int()
	else:
		entry["animation"] = anim

	# 4) models.json (retry once if it changed meanwhile)
	_set_status("Linking '%s' to its QR code…" % key)
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
		var json_text := JSON.stringify(cfg, "  ", false) + "\n"
		var put: Dictionary = await gh.put_file("models.json", json_text.to_utf8_buffer(),
			"Add/update model '%s'" % key, mj["sha"])
		if put["ok"]:
			break
		if put["code"] != 409 or attempt == 1:
			_fail("Could not update models.json: " + put["error"])
			return

	selected_key = key
	picked_path = ""
	form_title.text = "Edit: " + display_name
	upload_btn.text = "Save changes"
	file_label.text = str(entry.get("file", ""))
	_set_busy(false)
	await _refresh()
	_show_material_ui()
	_set_status("Done! '%s' is saved. The website updates in about 1 minute. Click 'Show QR' to print its code." % display_name)


## Create or overwrite a file in the repo. Shows the error and returns false on failure.
func _upload_file(repo_path: String, bytes: PackedByteArray, message: String) -> bool:
	var existing: Dictionary = await gh.get_file(repo_path)
	var sha: String = existing["sha"] if existing["ok"] else ""
	var up: Dictionary = await gh.put_file(repo_path, bytes, message, sha)
	if not up["ok"]:
		_fail("Upload of %s failed: %s" % [repo_path.get_file(), up["error"]])
		return false
	return true


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
	var old_entry: Dictionary = cfg["models"].get(key, {})
	cfg["models"].erase(key)
	var put: Dictionary = await gh.put_file("models.json", (JSON.stringify(cfg, "  ", false) + "\n").to_utf8_buffer(),
		"Remove model '%s'" % key, mj["sha"])
	if not put["ok"]:
		_fail("Could not update models.json: " + put["error"])
		return
	# delete the model file and its textures if they live in the repo and nothing else uses them
	var files := [str(old_entry.get("file", ""))]
	var mats: Dictionary = old_entry.get("materials", {})
	for nm in mats:
		files.append(str(mats[nm].get("map", "")))
	var used := JSON.stringify(cfg)
	for f in files:
		if f.begins_with("models/") and not used.contains("\"" + f + "\""):
			var info: Dictionary = await gh.get_file(f)
			if info["ok"] and info["sha"] != "":
				await gh.delete_file(f, "Delete file of model '%s'" % key, info["sha"])
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
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("2a3042")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env_node.environment = env
	viewport.add_child(env_node)

	sun = DirectionalLight3D.new()
	viewport.add_child(sun)

	# white paper + QR code (1 x 1 unit, like on the website)
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

	# soft ground shadow, like the website's
	var blob := MeshInstance3D.new()
	var blob_mesh := PlaneMesh.new()
	blob_mesh.size = Vector2(1.3, 1.3)
	blob.mesh = blob_mesh
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 1))
	grad.set_color(1, Color(1, 1, 1, 0))
	var gtex := GradientTexture2D.new()
	gtex.gradient = grad
	gtex.fill = GradientTexture2D.FILL_RADIAL
	gtex.fill_from = Vector2(0.5, 0.5)
	gtex.fill_to = Vector2(1.0, 0.5)
	shadow_mat = StandardMaterial3D.new()
	shadow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shadow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shadow_mat.albedo_texture = gtex
	shadow_mat.albedo_color = Color(0, 0, 0, 0.55)
	blob.material_override = shadow_mat
	blob.position.y = 0.003
	viewport.add_child(blob)

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
			dist = maxf(0.6, dist * 0.9)
			_update_camera()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dist = minf(15.0, dist * 1.1)
			_update_camera()
	elif ev is InputEventMouseMotion and dragging:
		var mm := ev as InputEventMouseMotion
		yaw -= mm.relative.x * 0.01
		pitch = clampf(pitch - mm.relative.y * 0.01, -1.5, 0.3)
		_update_camera()


func _clear_preview() -> void:
	for c in wrap.get_children():
		c.queue_free()
	model_root = null
	anim_player = null
	mat_refs = {}
	mat_orig = {}
	_rebuild_material_list()


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
	if selected_key != key_at_start or picked_path != "":
		return  # user selected something else meanwhile
	if not r["ok"]:
		_set_status("Could not download the model for preview: " + r["error"], true)
		return
	_show_model_bytes(r["bytes"], ext, "")
	await _fetch_remote_textures()
	_set_status("Editing '%s'. Change anything and click 'Save changes', or choose a new file to replace the model." % selected_key)


func _show_model_bytes(bytes: PackedByteArray, ext: String, base_path: String) -> void:
	for c in wrap.get_children():
		c.queue_free()
	model_root = null
	anim_player = null
	mat_refs = {}
	mat_orig = {}
	if bytes.is_empty():
		_set_status("The model file is empty.", true)
		_rebuild_material_list()
		return
	var doc: GLTFDocument
	var state: GLTFState
	if ext == "fbx":
		if not ClassDB.class_exists("FBXDocument"):
			_set_status("This Godot build can't preview .fbx files – uploading still works.")
			_rebuild_material_list()
			return
		doc = ClassDB.instantiate("FBXDocument")
		state = ClassDB.instantiate("FBXState")
	else:
		doc = GLTFDocument.new()
		state = GLTFState.new()
	var err := doc.append_from_buffer(bytes, base_path, state)
	if err != OK:
		_set_status("Couldn't read this model for the preview (error %d). It may still work on the website." % err, true)
		_rebuild_material_list()
		return
	var scene := doc.generate_scene(state)
	if scene == null:
		_set_status("Couldn't build the preview for this model.", true)
		_rebuild_material_list()
		return
	model_root = Node3D.new()
	wrap.add_child(model_root)
	model_root.add_child(scene)
	_fit_model()
	_collect_materials(scene)
	_rebuild_material_list()
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
	var anim_names := anim_player.get_animation_list()
	if anim_names.is_empty():
		return
	var want := anim_edit.text.strip_edges()
	var pick: String = anim_names[0]
	if want.is_valid_int() and want.to_int() >= 0 and want.to_int() < anim_names.size():
		pick = anim_names[want.to_int()]
	elif want != "":
		for nm in anim_names:
			if nm == want or nm.ends_with("/" + want):
				pick = nm
				break
	var a := anim_player.get_animation(pick)
	if a:
		a.loop_mode = Animation.LOOP_LINEAR
	anim_player.play(pick)
