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
-- Utility functions
-- ==========================================================================

local function print_stderr(msg)
	io.stderr:write(msg .. "\n")
end

local function starts_with(str, prefix)
	return string.sub(str, 1, #prefix) == prefix
end

local function ends_with(str, suffix)
	return string.sub(str, -#suffix) == suffix
end

local function has_clojure_extension(filename)
	return ends_with(filename, ".clj")
		or ends_with(filename, ".cljs")
		or ends_with(filename, ".cljc")
		or ends_with(filename, ".edn")
		or ends_with(filename, ".jank")
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

	-- include: combine CLI --include with config "include"
	merged.include = {}
	if file_config.include then
		for i = 1, #file_config.include do
			merged.include[#merged.include + 1] = file_config.include[i]
		end
	end
	if cli_options.include then
		for i = 1, #cli_options.include do
			merged.include[#merged.include + 1] = cli_options.include[i]
		end
	end

	-- ignore: combine CLI --ignore with config "ignore"
	merged.ignore = {}
	if file_config.ignore then
		for i = 1, #file_config.ignore do
			merged.ignore[#merged.ignore + 1] = file_config.ignore[i]
		end
	end
	if cli_options.ignore then
		for i = 1, #cli_options.ignore do
			merged.ignore[#merged.ignore + 1] = cli_options.ignore[i]
		end
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
-- File discovery
-- ==========================================================================

-- Recursively collect files from a directory.
-- Returns an array of absolute file paths.
local function collect_files(dir_path, ignore_patterns, results)
	results = results or {}
	local entries = scs_native.list_directory(dir_path)

	for i = 1, #entries do
		local entry = entries[i]
		local full_path = dir_path .. sep .. entry.name

		if entry.is_dir then
			if not is_ignored(full_path, ignore_patterns) then
				collect_files(full_path, ignore_patterns, results)
			end
		else
			if has_clojure_extension(entry.name) then
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
	print_stderr("WARN: could not find file or directory: " .. a)
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
	print("  --log-level, -l  Log level: everything, ignore-already-formatted, quiet")
	-- TODO: --include, --file-ext
	print("")
	print("Examples:")
	print("  standard-clj list src/")
	print("  standard-clj check src/ test/")
	print("  standard-clj fix src/ test/ deps.edn")
	print("  echo '(ns foo)' | standard-clj fix -")
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

local function cmd_check(files, config)
	local scs = require("standard-clojure-style")
	local log_level = config.log_level or "everything"

	local num_already_formatted = 0
	local num_need_formatting = 0
	local num_errors = 0

	for i = 1, #files do
		local filename = files[i]
		local content = scs_native.read_file(filename)

		if not content then
			print_stderr("E " .. filename .. " - unable to read file")
			num_errors = num_errors + 1
		else
			local result = scs.format(content)

			if result and result.status == "success" then
				local formatted = result.out .. "\n"
				if formatted == content then
					num_already_formatted = num_already_formatted + 1
				else
					print_stderr("✗ " .. filename)
					num_need_formatting = num_need_formatting + 1
				end
			else
				local reason = (result and result.reason) or "unknown error"
				print_stderr("E " .. filename .. " - " .. reason)
				num_errors = num_errors + 1
			end
		end
	end

	-- Summary
	if log_level ~= "quiet" then
		local total = num_already_formatted + num_need_formatting + num_errors
		print("")
		if num_need_formatting == 0 and num_errors == 0 then
			print(total .. " file(s) formatted with Standard Clojure Style")
		else
			print(num_already_formatted .. " file(s) already formatted")
			if num_need_formatting > 0 then
				print(num_need_formatting .. " file(s) need formatting")
			end
			if num_errors > 0 then
				print(num_errors .. " file(s) with errors")
			end
		end
	end

	if num_need_formatting == 0 and num_errors == 0 then
		return 0
	else
		return 1
	end
end

local function cmd_fix_stdin()
	local scs = require("standard-clojure-style")

	local input = io.stdin:read("*a")
	if not input or input == "" then
		print_stderr("Nothing found on stdin.")
		return 1
	end

	local result = scs.format(input)

	if result and result.status == "success" then
		print(result.out)
		return 0
	elseif result and result.status == "error" then
		print_stderr("Failed to format code: " .. (result.reason or "unknown"))
		return 1
	else
		print_stderr("Failed to format code due to unknown error.")
		return 1
	end
end

local function cmd_fix(files, config)
	local scs = require("standard-clojure-style")
	local log_level = config.log_level or "everything"

	local num_already_formatted = 0
	local num_formatted = 0
	local num_errors = 0

	for i = 1, #files do
		local filename = files[i]
		local content = scs_native.read_file(filename)

		if not content then
			print_stderr("E " .. filename .. " - unable to read file")
			num_errors = num_errors + 1
		else
			local result = scs.format(content)

			if result and result.status == "success" then
				local formatted = result.out .. "\n"
				if formatted == content then
					num_already_formatted = num_already_formatted + 1
				else
					local ok, err = scs_native.write_file(filename, formatted)
					if ok then
						if log_level == "everything" then
							print("F " .. filename)
						end
						num_formatted = num_formatted + 1
					else
						print_stderr("E " .. filename .. " - " .. (err or "write error"))
						num_errors = num_errors + 1
					end
				end
			else
				local reason = (result and result.reason) or "unknown error"
				print_stderr("E " .. filename .. " - " .. reason)
				num_errors = num_errors + 1
			end
		end
	end

	-- Summary
	if log_level ~= "quiet" then
		local total = num_already_formatted + num_formatted + num_errors
		print("")
		if num_errors == 0 then
			print(total .. " file(s) formatted with Standard Clojure Style")
		else
			print((num_already_formatted + num_formatted) .. " file(s) formatted")
			print(num_errors .. " file(s) with errors")
		end
	end

	if num_errors == 0 then
		return 0
	else
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
			-- TODO: glob pattern support
			options.include = options.include or {}
			options.include[#options.include + 1] = arg[i]
		elseif a == "--ignore" or a == "-ig" then
			i = i + 1
			options.ignore = options.ignore or {}
			options.ignore[#options.ignore + 1] = arg[i]
		elseif a == "--config" or a == "-c" then
			i = i + 1
			options.config = arg[i]
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

-- Resolve paths to file lists
local files = {}
for i = 1, #paths do
	local resolved = resolve_arg_to_files(paths[i], config.ignore)
	for j = 1, #resolved do
		files[#files + 1] = resolved[j]
	end
end

-- TODO: resolve --include glob patterns
-- TODO: load .standard-clj.edn config file (needs EDN parser)

table.sort(files)

if #files == 0 then
	print_stderr("No files found. Pass a filename, directory, or --include glob pattern.")
	return 1
end

-- Dispatch
if command == "list" then
	return cmd_list(files)
elseif command == "check" then
	return cmd_check(files, config)
elseif command == "fix" then
	return cmd_fix(files, config)
end

return 1
