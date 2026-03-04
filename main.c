// main.c
// Minimal C wrapper that embeds Lua 5.4 and runs the Standard Clojure Style
// CLI. All logic lives in Lua; this file just bootstraps the runtime.
//
// Build pipeline:
//   1. Makefile converts .lua source files to C byte arrays (xxd -i)
//   2. main.c includes the generated header and loads them into the Lua state
//   3. The resulting binary is fully self-contained — no external files needed
//
// The Lua side gets:
//   - Standard Lua libraries (io, os, string, table, etc.)
//   - The `arg` table populated from C argv (standard Lua convention)
//   - The SCS library available via require("standard-clojure-style")
//   - The dkjson library available via require("dkjson")
//   - A `scs_native` table with C helper functions (directory traversal, etc.)

#include "vendor/lua/lauxlib.h"
#include "vendor/lua/lua.h"
#include "vendor/lua/lualib.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Platform-specific includes for directory traversal
#ifdef _WIN32
#include <windows.h>
#else
#include <dirent.h>
#include <sys/stat.h>
#endif

// Generated at build time from .lua source files.
// Contains: scs_lib_lua[], scs_lib_lua_len,
//           dkjson_lib_lua[], dkjson_lib_lua_len,
//           cli_entry_lua[], cli_entry_lua_len
#include "build/scs_embedded.h"

// ============================================================================
// Version
//
// This gets updated by the release process.
// ============================================================================

#define SCS_VERSION "0.1.0-dev"

// ============================================================================
// Native Helpers — Directory Traversal
//
// Lua's standard library has no directory listing function.
// We provide a minimal C implementation so the CLI can discover files.
// ============================================================================

#ifdef _WIN32

// list_directory(path) -> table of {name=string, is_dir=boolean}
//
// Returns a Lua table (array) of entries in the given directory.
// Hidden files (starting with '.') are skipped.
// On Windows, uses FindFirstFile/FindNextFile.
static int l_list_directory(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);

  lua_newtable(L);
  int index = 1;

  char search_path[1024];
  snprintf(search_path, sizeof(search_path), "%s\\*", path);

  WIN32_FIND_DATA fdata;
  HANDLE hFind = FindFirstFile(search_path, &fdata);
  if (hFind == INVALID_HANDLE_VALUE) {
    return 1; // return empty table
  }

  do {
    // Skip . and .. and hidden files
    if (fdata.cFileName[0] == '.') {
      continue;
    }

    lua_pushinteger(L, index);
    lua_newtable(L);

    lua_pushstring(L, fdata.cFileName);
    lua_setfield(L, -2, "name");

    int is_dir = (fdata.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
    lua_pushboolean(L, is_dir);
    lua_setfield(L, -2, "is_dir");

    lua_settable(L, -3);
    index++;
  } while (FindNextFile(hFind, &fdata));

  FindClose(hFind);
  return 1;
}

#else

// list_directory(path) -> table of {name=string, is_dir=boolean}
//
// Returns a Lua table (array) of entries in the given directory.
// Hidden files (starting with '.') are skipped.
// On POSIX, uses opendir/readdir and stat.
static int l_list_directory(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);

  lua_newtable(L);
  int index = 1;

  DIR *dir = opendir(path);
  if (!dir) {
    return 1; // return empty table
  }

  struct dirent *entry;
  while ((entry = readdir(dir)) != NULL) {
    // Skip . and .. and hidden files
    if (entry->d_name[0] == '.') {
      continue;
    }

    // Build full path to stat for is_dir check
    char full_path[4096];
    snprintf(full_path, sizeof(full_path), "%s/%s", path, entry->d_name);

    struct stat st;
    int is_dir = 0;
    if (stat(full_path, &st) == 0) {
      is_dir = S_ISDIR(st.st_mode);
    }

    lua_pushinteger(L, index);
    lua_newtable(L);

    lua_pushstring(L, entry->d_name);
    lua_setfield(L, -2, "name");

    lua_pushboolean(L, is_dir);
    lua_setfield(L, -2, "is_dir");

    lua_settable(L, -3);
    index++;
  }

  closedir(dir);
  return 1;
}

#endif

// ============================================================================
// Native Helpers — File I/O
//
// Lua has io.open, but we provide a convenience function that reads an entire
// file into a string. This avoids repeated open/read/close boilerplate in Lua.
// ============================================================================

// read_file(path) -> string or nil, error_message
//
// Reads an entire file into a Lua string.
// Returns nil + error message on failure.
static int l_read_file(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);

  FILE *f = fopen(path, "rb");
  if (!f) {
    lua_pushnil(L);
    lua_pushfstring(L, "cannot open file: %s", path);
    return 2;
  }

  fseek(f, 0, SEEK_END);
  long size = ftell(f);
  fseek(f, 0, SEEK_SET);

  if (size < 0) {
    fclose(f);
    lua_pushnil(L);
    lua_pushfstring(L, "cannot determine size of: %s", path);
    return 2;
  }

  char *buf = (char *)malloc(size);
  if (!buf) {
    fclose(f);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  size_t read_count = fread(buf, 1, size, f);
  fclose(f);

  lua_pushlstring(L, buf, read_count);
  free(buf);
  return 1;
}

// write_file(path, content) -> true or nil, error_message
//
// Writes a string to a file, replacing any existing content.
// Returns true on success, nil + error message on failure.
static int l_write_file(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  size_t len;
  const char *content = luaL_checklstring(L, 2, &len);

  FILE *f = fopen(path, "wb");
  if (!f) {
    lua_pushnil(L);
    lua_pushfstring(L, "cannot open file for writing: %s", path);
    return 2;
  }

  size_t written = fwrite(content, 1, len, f);
  fclose(f);

  if (written != len) {
    lua_pushnil(L);
    lua_pushfstring(L, "write error: %s", path);
    return 2;
  }

  lua_pushboolean(L, 1);
  return 1;
}

// ============================================================================
// Native Helpers — Path Utilities
// ============================================================================

// path_separator() -> string
//
// Returns the platform path separator ("/" or "\\").
static int l_path_separator(lua_State *L) {
#ifdef _WIN32
  lua_pushstring(L, "\\");
#else
  lua_pushstring(L, "/");
#endif
  return 1;
}

// is_absolute_path(path) -> boolean
static int l_is_absolute_path(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);

#ifdef _WIN32
  // Check for drive letter (C:\...) or UNC path (\\...)
  int absolute = 0;
  if (strlen(path) >= 3 && path[1] == ':' &&
      (path[2] == '\\' || path[2] == '/')) {
    absolute = 1;
  }
  if (strlen(path) >= 2 && path[0] == '\\' && path[1] == '\\') {
    absolute = 1;
  }
  lua_pushboolean(L, absolute);
#else
  lua_pushboolean(L, path[0] == '/');
#endif
  return 1;
}

// ============================================================================
// Register native helper bindings
//
// These are available in Lua as the global table `scs_native`.
// ============================================================================

static void register_native_bindings(lua_State *L) {
  lua_newtable(L);

  lua_pushcfunction(L, l_list_directory);
  lua_setfield(L, -2, "list_directory");

  lua_pushcfunction(L, l_read_file);
  lua_setfield(L, -2, "read_file");

  lua_pushcfunction(L, l_write_file);
  lua_setfield(L, -2, "write_file");

  lua_pushcfunction(L, l_path_separator);
  lua_setfield(L, -2, "path_separator");

  lua_pushcfunction(L, l_is_absolute_path);
  lua_setfield(L, -2, "is_absolute_path");

  lua_pushstring(L, SCS_VERSION);
  lua_setfield(L, -2, "version");

  lua_setglobal(L, "scs_native");
}

// ============================================================================
// Module Loaders
//
// Pre-loads embedded Lua libraries into package.preload so that Lua code can
// use require() as normal:
//   local scs = require("standard-clojure-style")
//   local json = require("dkjson")
//
// The library sources are embedded as C byte arrays at compile time.
// ============================================================================

static int scs_module_loader(lua_State *L) {
  if (luaL_loadbuffer(L, (const char *)scs_lib_lua, scs_lib_lua_len,
                      "standard-clojure-style") != LUA_OK) {
    return lua_error(L);
  }
  lua_call(L, 0, 1);
  return 1;
}

static int dkjson_module_loader(lua_State *L) {
  if (luaL_loadbuffer(L, (const char *)dkjson_lib_lua, dkjson_lib_lua_len,
                      "dkjson") != LUA_OK) {
    return lua_error(L);
  }
  lua_call(L, 0, 1);
  return 1;
}

static void register_embedded_modules(lua_State *L) {
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "preload");

  lua_pushcfunction(L, scs_module_loader);
  lua_setfield(L, -2, "standard-clojure-style");

  lua_pushcfunction(L, dkjson_module_loader);
  lua_setfield(L, -2, "dkjson");

  lua_pop(L, 2); // pop preload and package
}

// ============================================================================
// Main
// ============================================================================

int main(int argc, char *argv[]) {
  lua_State *L = luaL_newstate();
  if (!L) {
    fprintf(stderr, "standard-clj: failed to create Lua state\n");
    return 1;
  }

  luaL_openlibs(L);

  // -- Set up the arg table (standard Lua convention) --
  //
  // arg[0] = program name
  // arg[1] = first argument
  // arg[2] = second argument
  // ...
  lua_createtable(L, argc, 0);
  for (int i = 0; i < argc; i++) {
    lua_pushstring(L, argv[i]);
    lua_rawseti(L, -2, i);
  }
  lua_setglobal(L, "arg");

  // -- Register C bindings and embedded modules --
  register_native_bindings(L);
  register_embedded_modules(L);

  // -- Run the CLI entry point --
  //
  // The CLI script is embedded as a C byte array. It returns an integer
  // exit code (0 = success, 1 = failure).
  if (luaL_loadbuffer(L, (const char *)cli_entry_lua, cli_entry_lua_len,
                      "cli") != LUA_OK) {
    fprintf(stderr, "standard-clj: %s\n", lua_tostring(L, -1));
    lua_close(L);
    return 1;
  }

  if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
    fprintf(stderr, "standard-clj: %s\n", lua_tostring(L, -1));
    lua_close(L);
    return 1;
  }

  // Get the exit code returned by the CLI script (default 0)
  int exit_code = 0;
  if (lua_isinteger(L, -1)) {
    exit_code = (int)lua_tointeger(L, -1);
  }

  lua_close(L);
  return exit_code;
}