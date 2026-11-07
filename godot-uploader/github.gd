extends Node
## Small client for the GitHub "contents" API of one repository.
## Every call returns a Dictionary: { ok: bool, code: int, data: Variant, error: String, ... }

var owner := ""
var repo := ""
var branch := "main"
var token := ""


func api_url(path: String) -> String:
	var encoded := path.uri_encode().replace("%2F", "/")
	return "https://api.github.com/repos/%s/%s/contents/%s" % [owner, repo, encoded]


func headers(accept: String = "application/vnd.github+json") -> PackedStringArray:
	return PackedStringArray([
		"Authorization: Bearer " + token,
		"Accept: " + accept,
		"X-GitHub-Api-Version: 2022-11-28",
		"User-Agent: QR3D-Uploader",
		"Content-Type: application/json",
	])


## Generic HTTP request. Use with: var r = await gh.request(...)
func request(method: int, url: String, body: String = "", hdrs: PackedStringArray = PackedStringArray()) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = 600.0
	add_child(http)
	var err := http.request(url, hdrs, method, body)
	if err != OK:
		http.queue_free()
		return {"ok": false, "code": 0, "data": null, "error": "Could not start the request (error %d)." % err}
	var res: Array = await http.request_completed
	http.queue_free()

	var result: int = res[0]
	var code: int = res[1]
	var raw: PackedByteArray = res[3]
	var out := {"ok": false, "code": code, "data": null, "bytes": raw, "error": ""}
	if result != HTTPRequest.RESULT_SUCCESS:
		out["error"] = "Network error (%d). Check your internet connection." % result
		return out
	out["ok"] = code >= 200 and code < 300
	var text := ""
	if raw.size() > 0 and raw.size() < 5_000_000:
		text = raw.get_string_from_utf8()
	if text.begins_with("{") or text.begins_with("["):
		out["data"] = JSON.parse_string(text)
	if not out["ok"]:
		var msg := text.left(200)
		if out["data"] is Dictionary:
			msg = str(out["data"].get("message", msg))
		match code:
			401:
				out["error"] = "GitHub rejected the token (401). Check it in Settings."
			403:
				out["error"] = "GitHub refused access (403): %s" % msg
			404:
				out["error"] = "Not found (404). Check owner/repo in Settings, and that the token can access this repo."
			_:
				out["error"] = "GitHub error %d: %s" % [code, msg]
	return out


## Check that the repo exists and the token may push to it.
func check_access() -> Dictionary:
	var r: Dictionary = await request(HTTPClient.METHOD_GET,
		"https://api.github.com/repos/%s/%s" % [owner, repo], "", headers())
	if r["ok"] and r["data"] is Dictionary:
		var perms = r["data"].get("permissions", {})
		if perms is Dictionary and not perms.get("push", false):
			r["ok"] = false
			r["error"] = "This token can read the repo but not write to it. Give it 'Contents: Read and write'."
	return r


## Get a file's metadata (sha) and, for files under 1 MB, its content (PackedByteArray in r.content).
func get_file(path: String) -> Dictionary:
	var r: Dictionary = await request(HTTPClient.METHOD_GET, api_url(path) + "?ref=" + branch, "", headers())
	r["sha"] = ""
	r["content"] = PackedByteArray()
	if r["ok"] and r["data"] is Dictionary:
		r["sha"] = str(r["data"].get("sha", ""))
		var b64 := str(r["data"].get("content", ""))
		if b64 != "":
			r["content"] = Marshalls.base64_to_raw(b64.replace("\n", ""))
	return r


## Download the raw bytes of a file in the repo (works for files up to 100 MB). Bytes in r.bytes.
func get_raw(path: String) -> Dictionary:
	return await request(HTTPClient.METHOD_GET, api_url(path) + "?ref=" + branch, "",
		headers("application/vnd.github.raw+json"))


## Create or overwrite a file. Pass the current sha when overwriting.
func put_file(path: String, bytes: PackedByteArray, message: String, sha: String = "") -> Dictionary:
	var body := {"message": message, "content": Marshalls.raw_to_base64(bytes), "branch": branch}
	if sha != "":
		body["sha"] = sha
	return await request(HTTPClient.METHOD_PUT, api_url(path), JSON.stringify(body), headers())


func delete_file(path: String, message: String, sha: String) -> Dictionary:
	var body := {"message": message, "sha": sha, "branch": branch}
	return await request(HTTPClient.METHOD_DELETE, api_url(path), JSON.stringify(body), headers())


## Plain download of any URL (no GitHub auth). Bytes in r.bytes.
func download(url: String) -> Dictionary:
	return await request(HTTPClient.METHOD_GET, url, "", PackedStringArray(["User-Agent: QR3D-Uploader"]))
