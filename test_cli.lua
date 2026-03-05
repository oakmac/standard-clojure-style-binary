-- test_cli.lua
-- Unit tests for CLI utility functions in cli.lua.
--
-- These tests are a direct port of cli_util.test.js from the JavaScript
-- implementation, ensuring behavioral parity between the JS and Lua CLIs.
--
-- Usage:
--   lua test_cli.lua
--
-- Requires luaunit (vendored).

-- =========================================================================
-- Setup: mock scs_native and load CLI utility functions
-- =========================================================================

-- cli.lua expects scs_native to be available as a global.
-- We mock it here so the utility functions can be loaded without the C binary.
scs_native = {
  version = "0.0.0-test",
  path_separator = function() return "/" end,
  is_tty = function(_fd) return false end,
}

-- Tell cli.lua not to execute its main CLI logic.
_G._SCS_TEST_MODE = true

-- Load cli.lua — this defines the pure utility functions and exports them
-- via the _scs_cli_util global, then returns early due to test mode.
dofile("lua/cli.lua")

local lu = require("vendor/luaunit")
local cli = _scs_cli_util

-- =========================================================================
-- Helper: deep table comparison
-- =========================================================================

local function tables_equal(t1, t2)
  if type(t1) ~= "table" or type(t2) ~= "table" then
    return t1 == t2
  end
  for k, v in pairs(t1) do
    if not tables_equal(v, t2[k]) then return false end
  end
  for k, v in pairs(t2) do
    if not tables_equal(v, t1[k]) then return false end
  end
  return true
end

-- =========================================================================
-- normalizeLogLevel
-- =========================================================================

TestNormalizeLogLevel = {}

function TestNormalizeLogLevel:testReturnsEverythingByDefault()
  lu.assertEquals(cli.normalize_log_level(nil), "everything")
  lu.assertEquals(cli.normalize_log_level(""), "everything")
  lu.assertEquals(cli.normalize_log_level("everything"), "everything")
  lu.assertEquals(cli.normalize_log_level("junk"), "everything")
  lu.assertEquals(cli.normalize_log_level(0), "everything")
end

function TestNormalizeLogLevel:testRecognisesIgnoreAlreadyFormatted()
  lu.assertEquals(cli.normalize_log_level("ignore-already-formatted"), "ignore-already-formatted")
  lu.assertEquals(cli.normalize_log_level("1"), "ignore-already-formatted")
  lu.assertEquals(cli.normalize_log_level(1), "ignore-already-formatted")
end

function TestNormalizeLogLevel:testRecognisesQuiet()
  lu.assertEquals(cli.normalize_log_level("quiet"), "quiet")
  lu.assertEquals(cli.normalize_log_level("5"), "quiet")
  lu.assertEquals(cli.normalize_log_level(5), "quiet")
end

-- =========================================================================
-- normalizeOutputFormat
-- =========================================================================

TestNormalizeOutputFormat = {}

function TestNormalizeOutputFormat:testReturnsTextByDefault()
  lu.assertEquals(cli.normalize_output_format(nil), "text")
  lu.assertEquals(cli.normalize_output_format(""), "text")
  lu.assertEquals(cli.normalize_output_format("junk"), "text")
  lu.assertEquals(cli.normalize_output_format(42), "text")
end

function TestNormalizeOutputFormat:testRecognisesJson()
  lu.assertEquals(cli.normalize_output_format("json"), "json")
  lu.assertEquals(cli.normalize_output_format("JSON"), "json")
end

function TestNormalizeOutputFormat:testRecognisesJsonPretty()
  lu.assertEquals(cli.normalize_output_format("json-pretty"), "json-pretty")
  lu.assertEquals(cli.normalize_output_format("JSON-PRETTY"), "json-pretty")
end

function TestNormalizeOutputFormat:testRecognisesEdn()
  lu.assertEquals(cli.normalize_output_format("edn"), "edn")
  lu.assertEquals(cli.normalize_output_format("EDN"), "edn")
end

function TestNormalizeOutputFormat:testRecognisesEdnPretty()
  lu.assertEquals(cli.normalize_output_format("edn-pretty"), "edn-pretty")
  lu.assertEquals(cli.normalize_output_format("EDN-PRETTY"), "edn-pretty")
end

function TestNormalizeOutputFormat:testRecognisesText()
  lu.assertEquals(cli.normalize_output_format("text"), "text")
end

-- =========================================================================
-- classifyFormatResult
-- =========================================================================

TestClassifyFormatResult = {}

function TestClassifyFormatResult:testDetectsAlreadyFormatted()
  local original = "(def x 1)\n"
  local format_result = { status = "success", out = "(def x 1)" }

  local result = cli.classify_format_result(original, format_result)

  lu.assertEquals(result.action, "already-formatted")
  lu.assertEquals(result.output_text, "(def x 1)\n")
end

function TestClassifyFormatResult:testDetectsFileNeededFormatting()
  local original = "(def x   1)\n"
  local format_result = { status = "success", out = "(def x 1)" }

  local result = cli.classify_format_result(original, format_result)

  lu.assertEquals(result.action, "formatted")
  lu.assertEquals(result.output_text, "(def x 1)\n")
end

function TestClassifyFormatResult:testDetectsMissingTrailingNewline()
  local original = "(def x 1)"
  local format_result = { status = "success", out = "(def x 1)" }

  local result = cli.classify_format_result(original, format_result)

  lu.assertEquals(result.action, "formatted")
  lu.assertEquals(result.output_text, "(def x 1)\n")
end

function TestClassifyFormatResult:testHandlesExplicitError()
  local result = cli.classify_format_result("(def )", { status = "error", reason = "Unexpected EOF" })

  lu.assertEquals(result.action, "error")
  lu.assertEquals(result.error_message, "Unexpected EOF")
end

function TestClassifyFormatResult:testHandlesNilFormatResult()
  local result = cli.classify_format_result("(def x 1)", nil)

  lu.assertEquals(result.action, "error")
  lu.assertStrContains(result.error_message, "Unknown error")
end

function TestClassifyFormatResult:testHandlesErrorWithMissingReason()
  local result = cli.classify_format_result("(def x 1)", { status = "error" })

  lu.assertEquals(result.action, "error")
  lu.assertStrContains(result.error_message, "Unknown error")
end

function TestClassifyFormatResult:testHandlesErrorWithNonStringReason()
  local result = cli.classify_format_result("(def x 1)", { status = "error", reason = 42 })

  lu.assertEquals(result.action, "error")
  lu.assertStrContains(result.error_message, "Unknown error")
end

function TestClassifyFormatResult:testHandlesUnexpectedStatus()
  local result = cli.classify_format_result("(def x 1)", { status = "wat" })

  lu.assertEquals(result.action, "error")
end

function TestClassifyFormatResult:testAlwaysAppendsExactlyOneNewline()
  local result = cli.classify_format_result("anything", { status = "success", out = "(ns foo.core)" })

  lu.assertEquals(result.output_text, "(ns foo.core)\n")
  -- Should not end with double newline
  lu.assertFalse(string.sub(result.output_text, -2) == "\n\n")
end

function TestClassifyFormatResult:testEmptyFileThatFormatsToEmptyString()
  local result = cli.classify_format_result("\n", { status = "success", out = "" })

  lu.assertEquals(result.action, "already-formatted")
  lu.assertEquals(result.output_text, "\n")
end

function TestClassifyFormatResult:testMultilineNsForm()
  local formatted = "(ns foo.core\n  (:require\n    [clojure.string :as str]))"
  local original = formatted .. "\n"

  local result = cli.classify_format_result(original, { status = "success", out = formatted })

  lu.assertEquals(result.action, "already-formatted")
end

-- =========================================================================
-- fileStr
-- =========================================================================

TestFileStr = {}

function TestFileStr:testReturnsSingularForOne()
  lu.assertEquals(cli.file_str(1), "file")
end

function TestFileStr:testReturnsPluralForOtherNumbers()
  lu.assertEquals(cli.file_str(0), "files")
  lu.assertEquals(cli.file_str(2), "files")
  lu.assertEquals(cli.file_str(100), "files")
end

-- =========================================================================
-- addPeriodPrefix
-- =========================================================================

TestAddPeriodPrefix = {}

function TestAddPeriodPrefix:testAddsPeriodToExtensionWithoutOne()
  lu.assertEquals(cli.add_period_prefix("clj"), ".clj")
  lu.assertEquals(cli.add_period_prefix("cljs"), ".cljs")
end

function TestAddPeriodPrefix:testDoesNotDoubleAddPeriod()
  lu.assertEquals(cli.add_period_prefix(".clj"), ".clj")
  lu.assertEquals(cli.add_period_prefix(".edn"), ".edn")
end

function TestAddPeriodPrefix:testReturnsNonStringValuesAsIs()
  lu.assertNil(cli.add_period_prefix(nil))
  lu.assertEquals(cli.add_period_prefix(42), 42)
  lu.assertEquals(cli.add_period_prefix(true), true)
end

-- =========================================================================
-- relativeFilename
-- =========================================================================

TestRelativeFilename = {}

function TestRelativeFilename:testStripsRootDirPrefix()
  lu.assertEquals(
    cli.relative_filename("/home/user/project/src/foo.clj", "/home/user/project"),
    "/src/foo.clj"
  )
end

function TestRelativeFilename:testReturnsUnchangedIfRootIsNotPrefix()
  lu.assertEquals(
    cli.relative_filename("/other/path/foo.clj", "/home/user/project"),
    "/other/path/foo.clj"
  )
end

function TestRelativeFilename:testHandlesEmptyRootString()
  lu.assertEquals(cli.relative_filename("/src/foo.clj", ""), "/src/foo.clj")
end

-- =========================================================================
-- setDifference
-- =========================================================================

TestSetDifference = {}

function TestSetDifference:testReturnsElementsInAButNotB()
  local a = { [1] = true, [2] = true, [3] = true, [4] = true }
  local b = { [2] = true, [4] = true }

  local result = cli.set_difference(a, b)

  lu.assertTrue(result[1])
  lu.assertTrue(result[3])
  lu.assertNil(result[2])
  lu.assertNil(result[4])
end

function TestSetDifference:testReturnsAllOfAWhenBIsEmpty()
  local a = { x = true, y = true }
  local b = {}

  local result = cli.set_difference(a, b)

  lu.assertTrue(result.x)
  lu.assertTrue(result.y)
end

function TestSetDifference:testReturnsEmptyWhenAIsEmpty()
  local a = {}
  local b = { [1] = true, [2] = true }

  local result = cli.set_difference(a, b)

  lu.assertNil(next(result))
end

function TestSetDifference:testReturnsEmptyWhenAAndBAreIdentical()
  local a = { a = true, b = true }
  local b = { a = true, b = true }

  local result = cli.set_difference(a, b)

  lu.assertNil(next(result))
end

function TestSetDifference:testWorksWithFilePathStrings()
  local include = { ["/src/a.clj"] = true, ["/src/b.clj"] = true, ["/src/c.clj"] = true }
  local ignore = { ["/src/b.clj"] = true }

  local diff = cli.set_difference(include, ignore)

  lu.assertTrue(diff["/src/a.clj"])
  lu.assertTrue(diff["/src/c.clj"])
  lu.assertNil(diff["/src/b.clj"])
end

-- =========================================================================
-- convertFileExt
-- =========================================================================

TestConvertFileExt = {}

function TestConvertFileExt:testConvertsCommaSeparatedStringToSetWithPeriods()
  local result = cli.convert_file_ext("clj,cljs,.edn")

  lu.assertNotNil(result)
  lu.assertTrue(result[".clj"])
  lu.assertTrue(result[".cljs"])
  lu.assertTrue(result[".edn"])

  -- Count entries
  local count = 0
  for _ in pairs(result) do count = count + 1 end
  lu.assertEquals(count, 3)
end

function TestConvertFileExt:testHandlesSingleExtension()
  local result = cli.convert_file_ext("clj")

  lu.assertNotNil(result)
  lu.assertTrue(result[".clj"])

  local count = 0
  for _ in pairs(result) do count = count + 1 end
  lu.assertEquals(count, 1)
end

function TestConvertFileExt:testReturnsNilForEmptyString()
  lu.assertNil(cli.convert_file_ext(""))
end

function TestConvertFileExt:testReturnsNilForNonString()
  lu.assertNil(cli.convert_file_ext(nil))
  lu.assertNil(cli.convert_file_ext(42))
end

-- =========================================================================
-- mergeConfigIntoArgv
-- =========================================================================

TestMergeConfigIntoArgv = {}

function TestMergeConfigIntoArgv:testReturnsArgvUnchangedWhenConfigIsNil()
  local argv = { foo = "bar" }
  local result = cli.merge_config_into_argv(argv, nil)

  lu.assertEquals(result, argv)
  lu.assertNil(result._options_loaded_via_config_file)
end

function TestMergeConfigIntoArgv:testSetsOptionsLoadedFlag()
  local argv = {}
  cli.merge_config_into_argv(argv, {})

  lu.assertTrue(argv._options_loaded_via_config_file)
end

function TestMergeConfigIntoArgv:testAppliesLogLevelFromConfigWhenCLIDidNotSetOne()
  local argv = {}
  cli.merge_config_into_argv(argv, { ["log-level"] = "quiet" })

  lu.assertEquals(argv["log-level"], "quiet")
end

function TestMergeConfigIntoArgv:testCLILogLevelTakesPrecedence()
  local argv = { ["log-level"] = "everything" }
  cli.merge_config_into_argv(argv, { ["log-level"] = "quiet" })

  lu.assertEquals(argv["log-level"], "everything")
end

function TestMergeConfigIntoArgv:testWrapsConfigStringIncludeInArray()
  local argv = {}
  cli.merge_config_into_argv(argv, { include = "src/**/*.clj" })

  lu.assertTrue(tables_equal(argv.include_from_config, { "src/**/*.clj" }))
end

function TestMergeConfigIntoArgv:testPassesConfigArrayIncludeThrough()
  local argv = {}
  cli.merge_config_into_argv(argv, { include = { "src/**/*.clj", "test/**/*.clj" } })

  lu.assertTrue(tables_equal(argv.include_from_config, { "src/**/*.clj", "test/**/*.clj" }))
end

function TestMergeConfigIntoArgv:testWrapsConfigStringIgnoreInArray()
  local argv = {}
  cli.merge_config_into_argv(argv, { ignore = "src/vendor" })

  lu.assertTrue(tables_equal(argv.ignore_from_config, { "src/vendor" }))
end

function TestMergeConfigIntoArgv:testPassesConfigArrayIgnoreThrough()
  local argv = {}
  cli.merge_config_into_argv(argv, { ignore = { "a", "b" } })

  lu.assertTrue(tables_equal(argv.ignore_from_config, { "a", "b" }))
end

function TestMergeConfigIntoArgv:testDoesNotCreateIncludeFromConfigWhenConfigHasNoInclude()
  local argv = {}
  cli.merge_config_into_argv(argv, { ["log-level"] = "quiet" })

  lu.assertNil(argv.include_from_config)
end

function TestMergeConfigIntoArgv:testDoesNotCreateIgnoreFromConfigWhenConfigHasNoIgnore()
  local argv = {}
  cli.merge_config_into_argv(argv, { ["log-level"] = "quiet" })

  lu.assertNil(argv.ignore_from_config)
end

function TestMergeConfigIntoArgv:testFullIntegrationMergesAllFields()
  local argv = { ["log-level"] = "everything" }
  local config = {
    ["log-level"] = "quiet",
    include = { "src/**/*.clj" },
    ignore = "vendor/",
  }
  local result = cli.merge_config_into_argv(argv, config)

  lu.assertEquals(result["log-level"], "everything")
  lu.assertTrue(tables_equal(result.include_from_config, { "src/**/*.clj" }))
  lu.assertTrue(tables_equal(result.ignore_from_config, { "vendor/" }))
  lu.assertTrue(result._options_loaded_via_config_file)
end

-- =========================================================================
-- buildCheckSummary
-- =========================================================================

TestBuildCheckSummary = {}

function TestBuildCheckSummary:testAllFilesAlreadyFormatted()
  local result = cli.build_check_summary({
    files_already_formatted = { "a.clj", "b.clj", "c.clj" },
    files_need_formatting = {},
    files_with_errors = {},
  })

  lu.assertEquals(result.total, 3)
  lu.assertEquals(result.num_already_formatted, 3)
  lu.assertEquals(result.num_need_formatting, 0)
  lu.assertEquals(result.num_errors, 0)
  lu.assertTrue(result.all_formatted)
  lu.assertEquals(result.exit_code, 0)
end

function TestBuildCheckSummary:testSingleFileAlreadyFormatted()
  local result = cli.build_check_summary({
    files_already_formatted = { "a.clj" },
    files_need_formatting = {},
    files_with_errors = {},
  })

  lu.assertEquals(result.total, 1)
  lu.assertTrue(result.all_formatted)
  lu.assertEquals(result.exit_code, 0)
end

function TestBuildCheckSummary:testSomeFilesNeedFormatting()
  local result = cli.build_check_summary({
    files_already_formatted = { "a.clj" },
    files_need_formatting = { "b.clj", "c.clj" },
    files_with_errors = {},
  })

  lu.assertEquals(result.total, 3)
  lu.assertEquals(result.num_already_formatted, 1)
  lu.assertEquals(result.num_need_formatting, 2)
  lu.assertFalse(result.all_formatted)
  lu.assertEquals(result.exit_code, 1)
end

function TestBuildCheckSummary:testFilesWithErrorsCauseExitCode1()
  local result = cli.build_check_summary({
    files_already_formatted = { "a.clj" },
    files_need_formatting = {},
    files_with_errors = { "bad.clj" },
  })

  lu.assertEquals(result.num_errors, 1)
  lu.assertFalse(result.all_formatted)
  lu.assertEquals(result.exit_code, 1)
end

function TestBuildCheckSummary:testEmptyInputNoFilesProcessed()
  local result = cli.build_check_summary({
    files_already_formatted = {},
    files_need_formatting = {},
    files_with_errors = {},
  })

  lu.assertEquals(result.total, 0)
  lu.assertFalse(result.all_formatted)
  lu.assertEquals(result.exit_code, 1)
end

function TestBuildCheckSummary:testMixOfAllThreeCategories()
  local result = cli.build_check_summary({
    files_already_formatted = { "ok.clj" },
    files_need_formatting = { "messy.clj" },
    files_with_errors = { "broken.clj" },
  })

  lu.assertEquals(result.total, 3)
  lu.assertEquals(result.num_already_formatted, 1)
  lu.assertEquals(result.num_need_formatting, 1)
  lu.assertEquals(result.num_errors, 1)
  lu.assertFalse(result.all_formatted)
  lu.assertEquals(result.exit_code, 1)
end

-- =========================================================================
-- buildFixSummary
-- =========================================================================

TestBuildFixSummary = {}

function TestBuildFixSummary:testAllFilesAlreadyFormatted()
  local result = cli.build_fix_summary({
    files_already_formatted = { "a.clj", "b.clj" },
    files_were_formatted = {},
    files_with_errors = {},
  })

  lu.assertEquals(result.total, 2)
  lu.assertEquals(result.num_already_formatted, 2)
  lu.assertEquals(result.num_were_formatted, 0)
  lu.assertEquals(result.num_errors, 0)
  lu.assertTrue(result.all_success)
  lu.assertEquals(result.exit_code, 0)
end

function TestBuildFixSummary:testSomeFilesWereFormattedSuccessfully()
  local result = cli.build_fix_summary({
    files_already_formatted = { "a.clj" },
    files_were_formatted = { "b.clj", "c.clj" },
    files_with_errors = {},
  })

  lu.assertEquals(result.total, 3)
  lu.assertEquals(result.num_already_formatted, 1)
  lu.assertEquals(result.num_were_formatted, 2)
  lu.assertTrue(result.all_success)
  lu.assertEquals(result.exit_code, 0)
end

function TestBuildFixSummary:testErrorsCauseExitCode1()
  local result = cli.build_fix_summary({
    files_already_formatted = { "a.clj" },
    files_were_formatted = { "b.clj" },
    files_with_errors = { "bad.clj" },
  })

  lu.assertEquals(result.total, 3)
  lu.assertEquals(result.num_errors, 1)
  lu.assertFalse(result.all_success)
  lu.assertEquals(result.exit_code, 1)
end

function TestBuildFixSummary:testAllFilesHaveErrors()
  local result = cli.build_fix_summary({
    files_already_formatted = {},
    files_were_formatted = {},
    files_with_errors = { "a.clj", "b.clj" },
  })

  lu.assertEquals(result.total, 2)
  lu.assertFalse(result.all_success)
  lu.assertEquals(result.exit_code, 1)
end

function TestBuildFixSummary:testEmptyInputNoFilesProcessed()
  local result = cli.build_fix_summary({
    files_already_formatted = {},
    files_were_formatted = {},
    files_with_errors = {},
  })

  lu.assertEquals(result.total, 0)
  lu.assertFalse(result.all_success)
  lu.assertEquals(result.exit_code, 1)
end

function TestBuildFixSummary:testSingleFileFormatted()
  local result = cli.build_fix_summary({
    files_already_formatted = {},
    files_were_formatted = { "only.clj" },
    files_with_errors = {},
  })

  lu.assertEquals(result.total, 1)
  lu.assertTrue(result.all_success)
  lu.assertEquals(result.exit_code, 0)
end

-- =========================================================================
-- JSON Encoding
-- =========================================================================

TestEncodeJsonString = {}

function TestEncodeJsonString:testSimpleString()
  lu.assertEquals(cli.encode_json_string("hello"), '"hello"')
end

function TestEncodeJsonString:testStringWithQuotes()
  lu.assertEquals(cli.encode_json_string('say "hi"'), '"say \\"hi\\""')
end

function TestEncodeJsonString:testStringWithBackslash()
  lu.assertEquals(cli.encode_json_string("a\\b"), '"a\\\\b"')
end

function TestEncodeJsonString:testStringWithNewline()
  lu.assertEquals(cli.encode_json_string("a\nb"), '"a\\nb"')
end

function TestEncodeJsonString:testStringWithTab()
  lu.assertEquals(cli.encode_json_string("a\tb"), '"a\\tb"')
end

function TestEncodeJsonString:testEmptyString()
  lu.assertEquals(cli.encode_json_string(""), '""')
end

function TestEncodeJsonString:testFilePath()
  lu.assertEquals(cli.encode_json_string("src/foo.clj"), '"src/foo.clj"')
end

TestEncodeJsonArray = {}

function TestEncodeJsonArray:testEmptyArray()
  lu.assertEquals(cli.encode_json_array({}), "[]")
end

function TestEncodeJsonArray:testSingleElement()
  lu.assertEquals(cli.encode_json_array({"a.clj"}), '["a.clj"]')
end

function TestEncodeJsonArray:testMultipleElements()
  lu.assertEquals(cli.encode_json_array({"a.clj", "b.clj"}), '["a.clj","b.clj"]')
end

TestEncodeJsonArrayPretty = {}

function TestEncodeJsonArrayPretty:testEmptyArray()
  lu.assertEquals(cli.encode_json_array_pretty({}), "[]")
end

function TestEncodeJsonArrayPretty:testSingleElement()
  lu.assertEquals(cli.encode_json_array_pretty({"a.clj"}), '[\n  "a.clj"\n]')
end

function TestEncodeJsonArrayPretty:testMultipleElements()
  local expected = '[\n  "a.clj",\n  "b.clj",\n  "c.clj"\n]'
  lu.assertEquals(cli.encode_json_array_pretty({"a.clj", "b.clj", "c.clj"}), expected)
end

-- =========================================================================
-- EDN Encoding
-- =========================================================================

TestEncodeEdnString = {}

function TestEncodeEdnString:testSimpleString()
  lu.assertEquals(cli.encode_edn_string("hello"), '"hello"')
end

function TestEncodeEdnString:testStringWithQuotes()
  lu.assertEquals(cli.encode_edn_string('say "hi"'), '"say \\"hi\\""')
end

function TestEncodeEdnString:testStringWithBackslash()
  lu.assertEquals(cli.encode_edn_string("a\\b"), '"a\\\\b"')
end

function TestEncodeEdnString:testEmptyString()
  lu.assertEquals(cli.encode_edn_string(""), '""')
end

TestEncodeEdnArray = {}

function TestEncodeEdnArray:testEmptyArray()
  lu.assertEquals(cli.encode_edn_array({}), "[]")
end

function TestEncodeEdnArray:testSingleElement()
  lu.assertEquals(cli.encode_edn_array({"a.clj"}), '["a.clj"]')
end

function TestEncodeEdnArray:testMultipleElements()
  -- EDN uses spaces, not commas
  lu.assertEquals(cli.encode_edn_array({"a.clj", "b.clj"}), '["a.clj" "b.clj"]')
end

TestEncodeEdnArrayPretty = {}

function TestEncodeEdnArrayPretty:testEmptyArray()
  lu.assertEquals(cli.encode_edn_array_pretty({}), "[]")
end

function TestEncodeEdnArrayPretty:testSingleElement()
  lu.assertEquals(cli.encode_edn_array_pretty({"a.clj"}), '["a.clj"]')
end

function TestEncodeEdnArrayPretty:testMultipleElements()
  -- EDN pretty: first element on same line as [, rest aligned with 1 space indent
  local expected = '["a.clj"\n "b.clj"\n "c.clj"]'
  lu.assertEquals(cli.encode_edn_array_pretty({"a.clj", "b.clj", "c.clj"}), expected)
end

-- =========================================================================
-- formatFileList
-- =========================================================================

TestFormatFileList = {}

function TestFormatFileList:testTextFormat()
  lu.assertEquals(cli.format_file_list({"a.clj", "b.clj"}, "text"), "a.clj\nb.clj")
end

function TestFormatFileList:testTextFormatSingleFile()
  lu.assertEquals(cli.format_file_list({"a.clj"}, "text"), "a.clj")
end

function TestFormatFileList:testJsonFormat()
  lu.assertEquals(cli.format_file_list({"a.clj", "b.clj"}, "json"), '["a.clj","b.clj"]')
end

function TestFormatFileList:testJsonPrettyFormat()
  local expected = '[\n  "a.clj",\n  "b.clj"\n]'
  lu.assertEquals(cli.format_file_list({"a.clj", "b.clj"}, "json-pretty"), expected)
end

function TestFormatFileList:testEdnFormat()
  lu.assertEquals(cli.format_file_list({"a.clj", "b.clj"}, "edn"), '["a.clj" "b.clj"]')
end

function TestFormatFileList:testEdnPrettyFormat()
  local expected = '["a.clj"\n "b.clj"]'
  lu.assertEquals(cli.format_file_list({"a.clj", "b.clj"}, "edn-pretty"), expected)
end

function TestFormatFileList:testDefaultsToText()
  lu.assertEquals(cli.format_file_list({"a.clj"}, nil), "a.clj")
  lu.assertEquals(cli.format_file_list({"a.clj"}, "unknown"), "a.clj")
end

-- =========================================================================
-- Integration: classifyFormatResult -> buildCheckSummary
-- =========================================================================

TestIntegrationCheckSummary = {}

function TestIntegrationCheckSummary:testThreeFilesOneCleanOneMessyOneError()
  local files = {
    { original = "(ns foo)\n", format_result = { status = "success", out = "(ns foo)" } },
    { original = "(ns  bar)\n", format_result = { status = "success", out = "(ns bar)" } },
    { original = "(ns baz", format_result = { status = "error", reason = "Unexpected EOF" } },
  }

  local check_result = {
    files_already_formatted = {},
    files_need_formatting = {},
    files_with_errors = {},
  }

  for i, f in ipairs(files) do
    local classification = cli.classify_format_result(f.original, f.format_result)
    local name = "file" .. i .. ".clj"

    if classification.action == "already-formatted" then
      check_result.files_already_formatted[#check_result.files_already_formatted + 1] = name
    elseif classification.action == "formatted" then
      check_result.files_need_formatting[#check_result.files_need_formatting + 1] = name
    else
      check_result.files_with_errors[#check_result.files_with_errors + 1] = name
    end
  end

  local summary = cli.build_check_summary(check_result)

  lu.assertEquals(summary.num_already_formatted, 1)
  lu.assertEquals(summary.num_need_formatting, 1)
  lu.assertEquals(summary.num_errors, 1)
  lu.assertFalse(summary.all_formatted)
  lu.assertEquals(summary.exit_code, 1)
end

-- =========================================================================
-- Integration: classifyFormatResult -> buildFixSummary
-- =========================================================================

TestIntegrationFixSummary = {}

function TestIntegrationFixSummary:testTwoFilesOneAlreadyFormattedOneFormatted()
  local files = {
    { original = "(ns foo)\n", format_result = { status = "success", out = "(ns foo)" } },
    { original = "(ns  bar)\n", format_result = { status = "success", out = "(ns bar)" } },
  }

  local fix_result = {
    files_already_formatted = {},
    files_were_formatted = {},
    files_with_errors = {},
  }

  for i, f in ipairs(files) do
    local classification = cli.classify_format_result(f.original, f.format_result)
    local name = "file" .. i .. ".clj"

    if classification.action == "already-formatted" then
      fix_result.files_already_formatted[#fix_result.files_already_formatted + 1] = name
    elseif classification.action == "formatted" then
      fix_result.files_were_formatted[#fix_result.files_were_formatted + 1] = name
    else
      fix_result.files_with_errors[#fix_result.files_with_errors + 1] = name
    end
  end

  local summary = cli.build_fix_summary(fix_result)

  lu.assertEquals(summary.num_already_formatted, 1)
  lu.assertEquals(summary.num_were_formatted, 1)
  lu.assertTrue(summary.all_success)
  lu.assertEquals(summary.exit_code, 0)
end

-- =========================================================================
-- Integration: mergeConfigIntoArgv pipeline
-- =========================================================================

TestIntegrationConfigPipeline = {}

function TestIntegrationConfigPipeline:testConfigValuesFlowThroughPipeline()
  local argv = { include = "cli-override.clj" }
  local config = {
    include = { "src/**/*.clj" },
    ignore = "vendor/",
    ["log-level"] = "quiet",
  }

  -- In Lua, include is already the correct type (string).
  -- The JS version wraps strings to arrays via convertStringsToArrays middleware.
  -- In Lua, the CLI arg parser already produces arrays for --include/--ignore.
  -- But mergeConfigIntoArgv handles wrapping config values.

  argv = cli.merge_config_into_argv(argv, config)

  -- argv.include stays as the CLI value (not wrapped — that's the arg parser's job)
  lu.assertEquals(argv.include, "cli-override.clj")
  lu.assertTrue(tables_equal(argv.include_from_config, { "src/**/*.clj" }))
  lu.assertTrue(tables_equal(argv.ignore_from_config, { "vendor/" }))
  lu.assertEquals(argv["log-level"], "quiet")
end

-- =========================================================================
-- Run all tests
-- =========================================================================

os.exit(lu.LuaUnit.run())