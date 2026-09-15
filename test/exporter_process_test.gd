extends SceneTree

const Exporter = preload("res://addons/godot_mini_game/exporter.gd")
var _failed := false
var _root := OS.get_temp_dir().path_join("godot-mini-game-process-%d-%d" % [
	OS.get_process_id(), Time.get_ticks_usec()])


class FixtureExporter extends "res://addons/godot_mini_game/exporter.gd":
	var worker_script := ""
	var worker_mode := "hang"
	var spawned_pid := -1
	var spawn_count := 0
	var pack_path := ""

	func _create_pack_process(executable: String, args: PackedStringArray) -> int:
		spawn_count += 1
		pack_path = args[args.size() - 1]
		spawned_pid = OS.create_process(executable, PackedStringArray([
			"--headless", "--log-file", args[args.find("--log-file") + 1],
			"--path", ProjectSettings.globalize_path("res://"),
			"--script", worker_script, "--", pack_path, worker_mode,
		]))
		return spawned_pid


func _assert_true(value: bool, message: String) -> void:
	if not value:
		push_error(message)
		_failed = true


func _new_exporter() -> FixtureExporter:
	var exporter := FixtureExporter.new()
	exporter.worker_script = _root.path_join("worker.gd")
	exporter.pack_log_directory = _root.path_join("logs")
	return exporter


func _find_web_preset() -> String:
	var config := ConfigFile.new()
	if config.load("res://export_presets.cfg") != OK:
		return ""
	for section in config.get_sections():
		if section.begins_with("preset.") and config.get_value(section, "platform", "") == "Web":
			return str(config.get_value(section, "name", ""))
	return ""


func _cancel_when_started(exporter: FixtureExporter) -> void:
	var deadline := Time.get_ticks_msec() + 10000
	while not FileAccess.file_exists(_root.path_join("worker-%d.beat" % exporter.spawned_pid)) and Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
	exporter.cancel_export()
	_assert_true(exporter._active_pack_pid == -1,
		"cancellation must stop the process immediately, without another SceneTree tick")
	# The child is stopped, but the old coroutine still owns its log/staging
	# until it resumes. An immediate retry must not reset that operation's state.
	var retry := await exporter.export_mini_game(
		"wechat", "test-app", "portrait", _find_web_preset(), _root.path_join("retry"))
	_assert_true(retry == ERR_BUSY, "cancel followed by an immediate export must stay busy until cleanup")
	retry = await exporter._export_pck(_find_web_preset(), _root.path_join("retry.pack"))
	_assert_true(retry == ERR_BUSY, "direct pack retry must not race cancelled pack cleanup")
	_assert_true(exporter.spawn_count == 1, "immediate retries must not launch another child")


func _assert_clean_stage(output_name: String) -> void:
	if OS.get_name() == "Windows":
		# Godot drops the handle before asynchronous Windows termination ends;
		# production deliberately retains that staging until it can be checked.
		return
	for dirname in DirAccess.get_directories_at(_root):
		_assert_true(not dirname.begins_with(".%s.export-staging-" % output_name),
			"stopped process staging must be removed: %s" % dirname)


func _assert_stopped(exporter: FixtureExporter) -> void:
	_assert_true(exporter.spawned_pid > 0 and exporter._active_pack_pid == -1,
		"exporter should release only its stopped child")
	# Workers append a heartbeat every frame. Verify no writes continue after
	# cancellation/cleanup without relying on process-list privileges. Godot's
	# Unix kill has already waitpid()'d the child, so repolling emits ECHILD.
	var heartbeat := _root.path_join("worker-%d.beat" % exporter.spawned_pid)
	var size_after_stop := Exporter._file_size(heartbeat)
	_assert_true(size_after_stop > 0, "worker must have run before cancellation/timeout")
	await create_timer(0.2).timeout
	_assert_true(Exporter._file_size(heartbeat) == size_after_stop,
		"stopped child must not keep writing its heartbeat outside staging")


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var preset_name := _find_web_preset()
	if preset_name.is_empty():
		push_error("exporter process test requires a Web export preset")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_root)
	var writer := Exporter.new()
	writer._write_text(_root.path_join("worker.gd"), """extends SceneTree
var pack_path := ""
var heartbeat := ""
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	pack_path = args[0]
	heartbeat = get_script().resource_path.get_base_dir().path_join("worker-%d.beat" % OS.get_process_id())
	var file := FileAccess.open(args[0], FileAccess.WRITE)
	file.store_string("partial resource pack")
	file.close()
	print("pack worker diagnostic")
	if args[1] == "success":
		quit(0)
	elif args[1] == "failure":
		quit(7)
func _process(_delta: float) -> bool:
	var file := FileAccess.open(heartbeat, FileAccess.READ_WRITE if FileAccess.file_exists(heartbeat) else FileAccess.WRITE)
	if file:
		file.seek_end()
		file.store_string("tick")
		file.close()
	return false
""")

	# Exercise multiple copy chunks, the final short chunk, and empty files.
	var data := PackedByteArray()
	data.resize(2 * 1024 * 1024 + 17)
	for index in data.size():
		data[index] = index % 251
	var source := _root.path_join("source.bin")
	var target := _root.path_join("copy.bin")
	writer._write_buffer(source, data)
	_assert_true(writer._copy_file(source, target) == OK, "streaming copy should succeed")
	_assert_true(FileAccess.get_sha256(source) == FileAccess.get_sha256(target),
		"streaming copy must preserve all bytes across chunk boundaries")
	writer._write_buffer(source, PackedByteArray())
	_assert_true(writer._copy_file(source, target) == OK and Exporter._file_size(target) == 0,
		"empty copy must truncate an existing target")

	var invalid := _new_exporter()
	var err := await invalid.export_mini_game(
		"tiktok", " \t", "portrait", "missing-preset", _root.path_join("invalid"))
	_assert_true(err == ERR_INVALID_PARAMETER and invalid.spawn_count == 0,
		"missing TikTok Client Key must fail before starting a process")
	_assert_true(not DirAccess.dir_exists_absolute(_root.path_join("invalid")),
		"invalid preflight must not create output")

	# A second process provides evidence cancellation targets only this export.
	var unrelated := _new_exporter()
	var unrelated_pack := _root.path_join("unrelated.pack")
	var unrelated_pid := unrelated._create_pack_process(OS.get_executable_path(), [
		"--log-file", _root.path_join("unrelated.log"), unrelated_pack])
	_assert_true(unrelated_pid > 0, "unrelated worker should start")

	var cancelled := _new_exporter()
	_cancel_when_started(cancelled)
	err = await cancelled.export_mini_game(
		"wechat", "test-app", "portrait", preset_name, _root.path_join("cancelled"))
	_assert_true(err == ERR_SKIP, "cancelled export should report cancellation")
	await _assert_stopped(cancelled)
	_assert_true(FileAccess.file_exists(cancelled.last_pack_log_path),
		"cancelled child diagnostics must survive staging cleanup")
	_assert_true(not DirAccess.dir_exists_absolute(_root.path_join("cancelled")),
		"cancelled export must not publish output")
	_assert_clean_stage("cancelled")
	_assert_true(not cancelled._export_in_progress and not cancelled._pack_in_progress,
		"completed cancellation cleanup must release the busy flags")
	_assert_true(OS.is_process_running(unrelated_pid), "cancellation must not kill another process")
	OS.kill(unrelated_pid)

	var timed_out := _new_exporter()
	timed_out.pack_timeout_seconds = 1.0
	err = await timed_out.export_mini_game(
		"wechat", "test-app", "portrait", preset_name, _root.path_join("timed-out"))
	_assert_true(err == ERR_TIMEOUT, "hung child should reach configured timeout")
	await _assert_stopped(timed_out)
	_assert_true(FileAccess.file_exists(timed_out.last_pack_log_path),
		"timeout diagnostics must be retained")
	_assert_clean_stage("timed-out")

	var failed := _new_exporter()
	failed.worker_mode = "failure"
	err = await failed.export_mini_game(
		"wechat", "test-app", "portrait", preset_name, _root.path_join("failed"))
	_assert_true(err == ERR_COMPILATION_FAILED, "nonzero exit must fail export")
	_assert_true(FileAccess.file_exists(failed.last_pack_log_path),
		"nonzero exit diagnostics must be retained")
	_assert_true(Exporter._read_text(failed.last_pack_log_path).contains("pack worker diagnostic"),
		"retained log should contain full child diagnostics")
	_assert_clean_stage("failed")

	# Reuse an exporter after its cancellation coroutine has fully completed.
	var successful := cancelled
	successful.worker_mode = "success"
	var success_dir := _root.path_join("success")
	DirAccess.make_dir_recursive_absolute(success_dir)
	err = await successful._export_pck(preset_name, success_dir.path_join("godot.zip"))
	_assert_true(err == OK, "normal child completion should still succeed")
	_assert_true(not FileAccess.file_exists(success_dir.path_join(".godot-pack-export.log")),
		"successful pack should remove its temporary log")

	writer._rm_rf(_root)
	print("exporter_process_test.gd: %s" % ("failed" if _failed else "ok"))
	quit(1 if _failed else 0)
