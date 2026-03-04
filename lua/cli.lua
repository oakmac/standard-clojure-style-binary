-- cli.lua
-- CLI entry point for Standard Clojure Style.
--
-- This script is embedded into the binary at compile time.
-- It receives:
--   arg[]        — command-line arguments (standard Lua convention)
--   scs_native   — C helper functions (list_directory, read_file, write_file, etc.)
--   require("standard-clojure-style") — the SCS formatting library
--   require("dkjson")                 — JSON parser for config files
--
-- Returns an integer exit code (0 = success, 1 = failure).

local version = scs_native.version
local sep = scs_native.path_separator()

-- ==========================================================================
-- ANSI Color Support
--
-- Matches the styles used by yoctocolors in the JS CLI.
-- Colors are only emitted when outputting to a terminal (TTY).
-- ==========================================================================

local stdout_is_tty = scs_native.is_tty(1)
local stderr_is_tty = scs_native.is_tty(2)

-- ANSI escape code helpers.
-- Each takes a string and returns it wrapped in the appropriate escape codes,
-- or returns it unchanged if the target stream is not a TTY.
--
-- The `for_stderr` parameter controls which TTY flag to check.
-- By default (nil/false), checks stdout. Pass true for stderr output.

local function bold(s, for_stderr)
	local is_tty = for_stderr and stderr_is_tty or stdout_is_tty
	if is_tty then
		return "\x1b[1m" .. s .. "\x1b[22m"
	end
	return s
end

local function dim(s, for_stderr)
	local is_tty = for_stderr and stderr_is_tty or stdout_is_tty
	if is_tty then
		return "\x1b[2m" .. s .. "\x1b[22m"
	end
	return s
end

local function red(s, for_stderr)
	local is_tty = for_stderr and stderr_is_tty or stdout_is_tty
	if is_tty then
		return "\x1b[31m" .. s .. "\x1b[39m"
	end
	return s
end

local function green(s, for_stderr)
	local is_tty = for_stderr and stderr_is_tty or stdout_is_tty
	if is_tty then
		return "\x1b[32m" .. s .. "\x1b[39m"
	end
	return s
end

local function yellow(s, for_stderr)
	local is_tty = for_stderr and stderr_is_tty or stdout_is_tty
	if is_tty then
		return "\x1b[33m" .. s .. "\x1b[39m"
	end
	return s
end

-- ==========================================================================
-- Logging
-- ==========================================================================

local log_level = "everything"

local function set_log_level(level)
	level = tostring(level or "everything")
	if level == "ignore-already-formatted" or level == "1" then
		log_level = "ignore-already-formatted"
	elseif level == "quiet" or level == "5" then
		log_level = "quiet"
	else
		log_level = "everything"
	end
end

local function print_stdout(msg)
	if log_level ~= "quiet" then
		io.stdout:write(msg .. "\n")
	end
end

local function print_stderr(msg)
	if log_level ~= "quiet" then
		io.stderr:write(msg .. "\n")
	end
end

-- ==========================================================================
-- Timing
-- ==========================================================================

-- os.clock() returns CPU time in seconds
local script_start_time = os.clock()

local function format_duration(seconds, for_stderr)
	local ms = seconds * 1000
	-- round to 2 decimal places
	local rounded = math.floor(ms * 100 + 0.5) / 100
	return dim("[" .. rounded .. "ms]", for_stderr)
end

-- ==========================================================================
-- Utility functions
-- ==========================================================================

local function starts_with(str, prefix)
	return string.sub(str, 1, #prefix) == prefix
end

local function ends_with(str, suffix)
	return string.sub(str, -#suffix) == suffix
end

-- Strip trailing path separator(s) from a path.
-- "src/" -> "src", "src" -> "src", "/" -> "/"
local function strip_trailing_sep(path)
	while #path > 1 and ends_with(path, sep) do
		path = string.sub(path, 1, -2)
	end
	return path
end

-- ==========================================================================
-- File extension matching
-- ==========================================================================

local default_file_extensions = {
	[".clj"] = true,
	[".cljs"] = true,
	[".cljc"] = true,
	[".edn"] = true,
	[".jank"] = true,
}

-- This gets set from the --file-ext flag or stays as the default.
local file_extensions = default_file_extensions

-- Parse a comma-separated --file-ext string into a lookup table.
-- Input: "clj,cljs,cljc" or ".clj,.cljs,.cljc" (periods are added if missing)
-- Returns: {[".clj"]=true, [".cljs"]=true, [".cljc"]=true}
local function parse_file_ext(ext_str)
	local exts = {}
	for ext1 in string.gmatch(ext_str, "[^,]+") do
		-- trim whitespace
		local ext2 = string.match(ext1, "^%s*(.-)%s*$")
		-- add leading period if missing
		if not starts_with(ext2, ".") then
			ext2 = "." .. ext2
		end
		exts[ext2] = true
	end
	return exts
end

local function has_matching_extension(filename)
	for ext, _ in pairs(file_extensions) do
		if ends_with(filename, ext) then
			return true
		end
	end
	return false
end

local function file_str(n)
	if n == 1 then
		return "file"
	else
		return "files"
	end
end

-- ==========================================================================
-- Config file loading
-- ==========================================================================

-- Try to load a JSON config file. Returns a table or nil.
local function load_json_config(path)
	local content = scs_native.read_file(path)
	if not content then
		return nil
	end

	local json = require("dkjson")
	local config, _, err = json.decode(content)
	if err then
		print_stderr("WARN: failed to parse " .. path .. ": " .. err)
		return nil
	end

	if type(config) ~= "table" then
		print_stderr("WARN: config file " .. path .. " must contain a JSON object")
		return nil
	end

	return config
end

-- Search for a config file in the current working directory.
-- Checks .standard-clj.json (JSON is what we support for now).
-- Returns a config table (possibly empty) and the path that was loaded (or nil).
local function find_config()
	-- TODO: also support .standard-clj.edn once we have an EDN parser
	local json_path = ".standard-clj.json"
	local config = load_json_config(json_path)
	if config then
		return config, json_path
	end

	return {}, nil
end

-- Merge CLI options with config file settings.
-- CLI flags take precedence over config file values.
local function merge_config(cli_options, file_config)
	local merged = {}

	-- include from CLI --include flags (always applied)
	merged.include = cli_options.include or {}

	-- include from config file (only applied when no direct path args are passed,
	-- matching the JS CLI behavior)
	merged.include_from_config = {}
	if file_config.include then
		if type(file_config.include) == "string" then
			merged.include_from_config = { file_config.include }
		elseif type(file_config.include) == "table" then
			for i = 1, #file_config.include do
				merged.include_from_config[#merged.include_from_config + 1] = file_config.include[i]
			end
		end
	end

	-- ignore: CLI --ignore overrides config file ignore
	if cli_options.ignore then
		merged.ignore = cli_options.ignore
	elseif file_config.ignore then
		merged.ignore = {}
		if type(file_config.ignore) == "string" then
			merged.ignore = { file_config.ignore }
		elseif type(file_config.ignore) == "table" then
			for i = 1, #file_config.ignore do
				merged.ignore[#merged.ignore + 1] = file_config.ignore[i]
			end
		end
	else
		merged.ignore = {}
	end

	-- log_level: CLI flag overrides config
	merged.log_level = cli_options.log_level or file_config["log-level"] or "everything"

	return merged
end

-- ==========================================================================
-- Ignore matching
-- ==========================================================================

-- Check if a file path should be ignored based on the ignore patterns.
-- For now, supports simple prefix matching (directories) and exact matches.
local function is_ignored(filepath, ignore_patterns)
	if not ignore_patterns or #ignore_patterns == 0 then
		return false
	end

	for i = 1, #ignore_patterns do
		local pattern = ignore_patterns[i]

		-- Strip trailing separator for consistent matching
		if ends_with(pattern, sep) then
			pattern = string.sub(pattern, 1, -2)
		end

		-- Check if the path starts with the ignore pattern (directory match)
		if starts_with(filepath, pattern .. sep) or filepath == pattern then
			return true
		end

		-- Check if any path component matches
		if string.find(filepath, sep .. pattern .. sep, 1, true) then
			return true
		end

		-- Check suffix match (for patterns like "generated/")
		if ends_with(filepath, sep .. pattern) then
			return true
		end
	end

	return false
end

-- ==========================================================================
-- Glob pattern matching
--
-- Handles --include patterns like "src/**/*.{clj,cljs,cljc}".
-- Supports:
--   **       — match any path including directory separators
--   *        — match anything except directory separators
--   ?        — match a single character except directory separators
--   {a,b,c}  — brace expansion (single level, no nesting)
-- ==========================================================================

-- Characters that are special in Lua patterns and need escaping.
local lua_pattern_specials = {
	["("] = true,
	[")"] = true,
	["."] = true,
	["%"] = true,
	["+"] = true,
	["-"] = true,
	["["] = true,
	["]"] = true,
	["^"] = true,
	["$"] = true,
}

-- Expand {a,b,c} brace patterns into multiple strings.
-- Only handles a single level of braces (no nesting).
-- "src/**/*.{clj,cljs}" -> {"src/**/*.clj", "src/**/*.cljs"}
-- "src/**/*.clj" -> {"src/**/*.clj"} (no braces, returned as-is)
local function expand_braces(pattern)
	local prefix, alternatives, suffix = string.match(pattern, "^(.-)%{(.-)%}(.*)$")
	if not prefix then
		return { pattern }
	end

	local results = {}
	for alt in string.gmatch(alternatives, "[^,]+") do
		results[#results + 1] = prefix .. alt .. suffix
	end
	return results
end

-- Convert a glob pattern (after brace expansion) to a Lua pattern string.
local function glob_to_lua_pattern(glob)
	local p = "^"
	local i = 1
	local len = #glob

	while i <= len do
		local c = string.sub(glob, i, i)

		if c == "*" then
			if i + 1 <= len and string.sub(glob, i + 1, i + 1) == "*" then
				-- ** : match anything including /
				p = p .. ".*"
				i = i + 2
				-- skip trailing / after **
				if i <= len and (string.sub(glob, i, i) == "/" or string.sub(glob, i, i) == sep) then
					-- allow the separator to optionally match (** at end of pattern
					-- should still work)
					p = p .. "/?"
					i = i + 1
				end
			else
				-- * : match anything except /
				p = p .. "[^/]*"
				i = i + 1
			end
		elseif c == "?" then
			p = p .. "[^/]"
			i = i + 1
		elseif lua_pattern_specials[c] then
			p = p .. "%" .. c
			i = i + 1
		else
			p = p .. c
			i = i + 1
		end
	end

	p = p .. "$"
	return p
end

-- Extract the root directory from a glob pattern.
-- Everything before the first wildcard character, trimmed to the last separator.
-- "src/**/*.clj" -> "src"
-- "**/*.clj" -> "."
local function extract_glob_root(pattern)
	-- Find the first glob special character
	local first_special = nil
	for i = 1, #pattern do
		local c = string.sub(pattern, i, i)
		if c == "*" or c == "?" or c == "{" or c == "[" then
			first_special = i
			break
		end
	end

	if not first_special then
		-- No wildcards — treat as literal path
		return pattern
	end

	-- Take everything before the first special char
	local prefix = string.sub(pattern, 1, first_special - 1)

	-- Find the last separator in the prefix
	local last_sep = nil
	for i = #prefix, 1, -1 do
		local c = string.sub(prefix, i, i)
		if c == "/" or c == sep then
			last_sep = i
			break
		end
	end

	if last_sep then
		return string.sub(prefix, 1, last_sep - 1)
	else
		return "."
	end
end

-- Collect ALL files recursively from a directory (no extension filtering).
-- Used by glob resolution, where the glob pattern itself determines which
-- files match.
local function collect_all_files(dir_path, results)
	results = results or {}
	dir_path = strip_trailing_sep(dir_path)
	local entries = scs_native.list_directory(dir_path)

	for i = 1, #entries do
		local entry = entries[i]
		local full_path = dir_path .. sep .. entry.name

		if entry.is_dir then
			collect_all_files(full_path, results)
		else
			results[#results + 1] = full_path
		end
	end

	return results
end

-- Resolve a glob pattern into a list of matching file paths.
-- Expands braces, finds the root directory, collects all files, and filters
-- by the Lua pattern.
local function resolve_glob_pattern(pattern, ignore_patterns)
	local expanded = expand_braces(pattern)
	local results = {}

	for i = 1, #expanded do
		local glob = expanded[i]
		local root = extract_glob_root(glob)
		local lua_pat = glob_to_lua_pattern(glob)
		local all_files = collect_all_files(root)

		for j = 1, #all_files do
			local filepath = all_files[j]
			if string.match(filepath, lua_pat) then
				if not is_ignored(filepath, ignore_patterns) then
					results[#results + 1] = filepath
				end
			end
		end
	end

	return results
end

-- ==========================================================================
-- File discovery
-- ==========================================================================

-- Recursively collect files from a directory, filtered by extension.
-- Returns an array of absolute file paths.
local function collect_files(dir_path, ignore_patterns, results)
	results = results or {}
	dir_path = strip_trailing_sep(dir_path)
	local entries = scs_native.list_directory(dir_path)

	for i = 1, #entries do
		local entry = entries[i]
		local full_path = dir_path .. sep .. entry.name

		if entry.is_dir then
			if not is_ignored(full_path, ignore_patterns) then
				collect_files(full_path, ignore_patterns, results)
			end
		else
			if has_matching_extension(entry.name) then
				if not is_ignored(full_path, ignore_patterns) then
					results[#results + 1] = full_path
				end
			end
		end
	end

	return results
end

-- Resolve a CLI argument to a list of files.
-- If it's a file, return it. If it's a directory, recurse.
local function resolve_arg_to_files(a, ignore_patterns)
	a = strip_trailing_sep(a)

	-- Try as file first: attempt to read it
	local content = scs_native.read_file(a)
	if content then
		if not is_ignored(a, ignore_patterns) then
			return { a }
		else
			return {}
		end
	end

	-- Try as directory
	local entries = scs_native.list_directory(a)
	if #entries > 0 then
		return collect_files(a, ignore_patterns)
	end

	-- Check if it might be a directory that's empty
	-- list_directory returns empty table for both "not found" and "empty dir"
	-- For now, warn and skip
	print_stderr(bold(yellow("WARN", true), true) .. ' Could not find a file or directory at "' .. a .. '"')
	return {}
end

-- ==========================================================================
-- Commands
-- ==========================================================================

local function print_usage()
	print("standard-clj " .. version)
	print("")
	print("Usage: standard-clj <command> [options] [paths...]")
	print("")
	print("Commands:")
	print("  list    List files that would be formatted")
	print("  check   Check if files are already formatted (exit 1 if not)")
	print("  fix     Format files in-place")
	print("  fix -   Read from stdin, write formatted code to stdout")
	print("")
	print("Options:")
	print("  --help, -h       Show this help message")
	print("  --version, -v    Show version")
	print("  --config, -c     Path to config file (.standard-clj.json)")
	print("  --ignore, -ig    Ignore files or directories")
	print("  --include, -in   Include files matching a glob pattern")
	print("  --log-level, -l  Log level: everything, ignore-already-formatted, quiet")
	print("  --file-ext       Comma-separated list of file extensions (default: clj,cljs,cljc,edn,jank)")
	print("")
	print("Examples:")
	print("  standard-clj list src/")
	print("  standard-clj check src/ test/")
	print("  standard-clj fix src/ test/ deps.edn")
	print("  echo '(ns foo)' | standard-clj fix -")
end

local function print_program_info(command)
	print_stdout(bold("standard-clj " .. command) .. " " .. dim(version))
	print_stdout("")
end

local function cmd_version()
	print("standard-clj " .. version)
	return 0
end

local function cmd_list(files)
	for i = 1, #files do
		print(files[i])
	end
	return 0
end

local function cmd_check(files)
	local scs = require("standard-clojure-style")

	local at_least_one_file_printed = false
	local num_already_formatted = 0
	local num_need_formatting = 0
	local num_errors = 0

	for i = 1, #files do
		local filename = files[i]
		local file_start_time = os.clock()
		local content = scs_native.read_file(filename)

		if not content then
			print_stderr("Unable to read file: " .. filename)
			at_least_one_file_printed = true
			num_errors = num_errors + 1
		else
			local result = scs.format(content)
			local file_end_time = os.clock()
			local duration_seconds = file_end_time - file_start_time

			if result and result.status == "success" then
				local formatted = result.out .. "\n"
				if formatted == content then
					num_already_formatted = num_already_formatted + 1
					if log_level ~= "ignore-already-formatted" then
						print_stdout(
							green("\xE2\x9C\x93") .. " " .. bold(filename) .. " " .. format_duration(duration_seconds)
						)
						at_least_one_file_printed = true
					end
				else
					print_stderr(
						red("\xE2\x9C\x97", true)
							.. " "
							.. bold(filename, true)
							.. " "
							.. format_duration(duration_seconds, true)
					)
					at_least_one_file_printed = true
					num_need_formatting = num_need_formatting + 1
				end
			else
				local reason = (result and result.reason) or "unknown error"
				print_stderr(
					red("E", true)
						.. " "
						.. bold(red(filename, true), true)
						.. " - "
						.. reason
						.. " "
						.. format_duration(duration_seconds, true)
				)
				at_least_one_file_printed = true
				num_errors = num_errors + 1
			end
		end
	end

	-- Summary
	local total = num_already_formatted + num_need_formatting + num_errors
	local script_end_time = os.clock()
	local script_duration_str = format_duration(script_end_time - script_start_time)

	if at_least_one_file_printed then
		print_stdout("")
	end

	if num_need_formatting == 0 and num_errors == 0 then
		if total == 1 then
			print_stdout(
				green("1 file formatted with Standard Clojure Style \xF0\x9F\x91\x8D") .. " " .. script_duration_str
			)
		else
			print_stdout(
				green("All " .. total .. " files formatted with Standard Clojure Style \xF0\x9F\x91\x8D")
					.. " "
					.. script_duration_str
			)
		end
		return 0
	else
		print_stdout(
			green(
				num_already_formatted
					.. " "
					.. file_str(num_already_formatted)
					.. " formatted with Standard Clojure Style"
			)
		)
		print_stdout(red(num_need_formatting .. " " .. file_str(num_need_formatting) .. " require formatting"))
		print_stdout("Checked " .. total .. " " .. file_str(total) .. ". " .. script_duration_str)
		return 1
	end
end

local function cmd_fix_stdin()
	local scs = require("standard-clojure-style")

	local input = io.stdin:read("*a")
	if not input or input == "" then
		print_stderr('Nothing found on stdin. Please pipe some Clojure code to stdin when using "standard-clj fix -"')
		return 1
	end

	local result = scs.format(input)

	if result and result.status == "success" then
		io.stdout:write(result.out .. "\n")
		return 0
	elseif result and result.status == "error" then
		print_stderr("Failed to format code: " .. (result.reason or "unknown"))
		return 1
	else
		print_stderr(
			"Failed to format code due to unknown error with the format() function. Please help the standard-clj project by opening an issue to report this."
		)
		return 1
	end
end

local function cmd_fix(files)
	local scs = require("standard-clojure-style")

	local at_least_one_file_printed = false
	local num_already_formatted = 0
	local num_formatted = 0
	local num_errors = 0

	for i = 1, #files do
		local filename = files[i]
		local file_start_time = os.clock()
		local content = scs_native.read_file(filename)

		if not content then
			print_stderr("Unable to read file: " .. filename)
			at_least_one_file_printed = true
			num_errors = num_errors + 1
		else
			local result = scs.format(content)
			local file_end_time = os.clock()
			local duration_seconds = file_end_time - file_start_time

			if result and result.status == "success" then
				local formatted = result.out .. "\n"
				if formatted == content then
					num_already_formatted = num_already_formatted + 1
					if log_level ~= "ignore-already-formatted" then
						print_stdout(
							green("\xE2\x9C\x93") .. " " .. bold(filename) .. " " .. format_duration(duration_seconds)
						)
						at_least_one_file_printed = true
					end
				else
					local ok, err = scs_native.write_file(filename, formatted)
					if ok then
						print_stdout(green("F") .. " " .. bold(filename) .. " " .. format_duration(duration_seconds))
						at_least_one_file_printed = true
						num_formatted = num_formatted + 1
					else
						print_stderr(
							red("E", true)
								.. " "
								.. bold(red(filename, true), true)
								.. " - "
								.. (err or "write error")
								.. " "
								.. format_duration(duration_seconds, true)
						)
						at_least_one_file_printed = true
						num_errors = num_errors + 1
					end
				end
			else
				local reason = (result and result.reason) or "unknown error"
				print_stderr(
					red("E", true)
						.. " "
						.. bold(red(filename, true), true)
						.. " - "
						.. reason
						.. " "
						.. format_duration(duration_seconds, true)
				)
				at_least_one_file_printed = true
				num_errors = num_errors + 1
			end
		end
	end

	-- Summary
	local total = num_already_formatted + num_formatted + num_errors
	local num_ok = num_already_formatted + num_formatted
	local script_end_time = os.clock()
	local script_duration_str = format_duration(script_end_time - script_start_time)

	if at_least_one_file_printed then
		print_stdout("")
	end

	if num_errors == 0 then
		if total == 1 then
			print_stdout(
				green("1 file formatted with Standard Clojure Style \xF0\x9F\x91\x8D") .. " " .. script_duration_str
			)
		else
			print_stdout(
				green("All " .. total .. " files formatted with Standard Clojure Style \xF0\x9F\x91\x8D")
					.. " "
					.. script_duration_str
			)
		end
		return 0
	else
		print_stdout(green(num_ok .. " " .. file_str(num_ok) .. " formatted with Standard Clojure Style"))
		print_stdout(red(num_errors .. " " .. file_str(num_errors) .. " with errors"))
		print_stdout("Checked " .. total .. " " .. file_str(total) .. ". " .. script_duration_str)
		return 1
	end
end

-- ==========================================================================
-- Argument parsing
-- ==========================================================================

-- Parse arg[] into a command and a list of file paths.
-- Returns: command (string), paths (array of strings), options (table)
local function parse_args()
	local command = nil
	local paths = {}
	local options = {}

	local i = 1
	while i <= #arg do
		local a = arg[i]

		if a == "--help" or a == "-h" then
			options.help = true
		elseif a == "--version" or a == "-v" then
			options.version = true
		elseif a == "--log-level" or a == "-l" then
			i = i + 1
			options.log_level = arg[i]
		elseif a == "--include" or a == "-in" then
			i = i + 1
			options.include = options.include or {}
			options.include[#options.include + 1] = arg[i]
		elseif a == "--ignore" or a == "-ig" then
			i = i + 1
			options.ignore = options.ignore or {}
			options.ignore[#options.ignore + 1] = arg[i]
		elseif a == "--config" or a == "-c" then
			i = i + 1
			options.config = arg[i]
		elseif a == "--file-ext" then
			i = i + 1
			options.file_ext = arg[i]
		elseif not command then
			command = a
		else
			paths[#paths + 1] = a
		end

		i = i + 1
	end

	return command, paths, options
end

-- ==========================================================================
-- Entry point
-- ==========================================================================

local command, paths, options = parse_args()

-- Handle --help and --version before anything else
if options.help then
	print_usage()
	return 0
end

if options.version then
	return cmd_version()
end

-- Validate command
if not command then
	print_usage()
	return 1
end

if command ~= "list" and command ~= "check" and command ~= "fix" then
	print_stderr("Unknown command: " .. command)
	print_stderr("Run 'standard-clj --help' for usage information.")
	return 1
end

-- Handle fix - (stdin mode)
if command == "fix" and #paths == 1 and paths[1] == "-" then
	return cmd_fix_stdin()
end

-- Load config file
local file_config, config_path
if options.config then
	-- Explicit --config flag
	file_config = load_json_config(options.config)
	if not file_config then
		print_stderr("ERROR: could not load config file: " .. options.config)
		return 1
	end
	config_path = options.config
else
	-- Auto-detect in cwd
	file_config, config_path = find_config()
end

local config = merge_config(options, file_config)

-- Set log level from merged config
set_log_level(config.log_level)

-- Set custom file extensions if provided
if options.file_ext then
	file_extensions = parse_file_ext(options.file_ext)
end

-- Print program info header
print_program_info(command)

-- Resolve paths to file lists
local files = {}
for i = 1, #paths do
	local resolved = resolve_arg_to_files(paths[i], config.ignore)
	for j = 1, #resolved do
		files[#files + 1] = resolved[j]
	end
end

-- Resolve CLI --include glob patterns (always applied)
if #config.include > 0 then
	for i = 1, #config.include do
		local resolved = resolve_glob_pattern(config.include[i], config.ignore)
		for j = 1, #resolved do
			files[#files + 1] = resolved[j]
		end
	end
end

-- Resolve config file --include patterns (only when no direct path args passed)
if #paths == 0 and #config.include_from_config > 0 then
	for i = 1, #config.include_from_config do
		local resolved = resolve_glob_pattern(config.include_from_config[i], config.ignore)
		for j = 1, #resolved do
			files[#files + 1] = resolved[j]
		end
	end
end

-- TODO: load .standard-clj.edn config file (needs EDN parser)

-- Deduplicate (a file could match both a direct arg and a glob pattern)
local seen = {}
local unique_files = {}
for i = 1, #files do
	if not seen[files[i]] then
		seen[files[i]] = true
		unique_files[#unique_files + 1] = files[i]
	end
end
files = unique_files

table.sort(files)

if #files == 0 then
	print_stderr(
		'No files were passed to the "'
			.. command
			.. '" command. Please pass a filename, directory, or --include glob pattern.'
	)
	return 1
end

-- Dispatch
if command == "list" then
	return cmd_list(files)
elseif command == "check" then
	return cmd_check(files)
elseif command == "fix" then
	return cmd_fix(files)
end

return 1
