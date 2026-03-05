# Makefile for standard-clojure-style-binary
#
# Builds a self-contained binary that embeds Lua 5.5.0 and the Standard Clojure
# Style formatter. No external runtime dependencies.
#
# Targets:
#   make              Build the standard-clj binary
#   make clean        Remove build artifacts
#   make install      Install to PREFIX/bin (default: /usr/local)
#   make test         Run the test suite
#
# The build has two phases:
#   1. Embed: convert .lua source files to C byte arrays (xxd -i)
#   2. Compile: build everything into a single static binary
CC = cc
CFLAGS = -Wall -O2 -I vendor/lua
PREFIX = /usr/local
BINARY = standard-clj
UNAME := $(shell uname)

# Platform-specific linker flags
ifeq ($(UNAME), Darwin)
	LDFLAGS = -lm
else ifeq ($(OS), Windows_NT)
	LDFLAGS =
	BINARY = standard-clj.exe
else
	# Linux and other POSIX
	LDFLAGS = -lm -ldl
endif

# Lua source files (exclude standalone interpreter and compiler entry points)
LUA_SRC = $(filter-out vendor/lua/lua.c vendor/lua/luac.c vendor/lua/onelua.c, \
            $(wildcard vendor/lua/*.c))

# Embedded Lua source files
SCS_LIB = vendor/standard-clojure-style.lua
DKJSON_LIB = vendor/dkjson.lua
EDN_LIB = vendor/edn.lua
CLI_LUA = lua/cli.lua
EMBEDDED_HEADER = build/scs_embedded.h

# ============================================================================
# Default target — must be first so `make` builds the binary
# ============================================================================
all: $(BINARY)

# ============================================================================
# Embed Phase
#
# Convert .lua files to C byte arrays using xxd -i.
# The files are copied to build/ with clean names first so the generated
# C identifiers are predictable:
#   scs_lib_lua / scs_lib_lua_len
#   dkjson_lib_lua / dkjson_lib_lua_len
#   edn_lib_lua / edn_lib_lua_len
#   cli_entry_lua / cli_entry_lua_len
# ============================================================================
$(EMBEDDED_HEADER): $(SCS_LIB) $(DKJSON_LIB) $(EDN_LIB) $(CLI_LUA)
	@mkdir -p build
	@cp $(SCS_LIB) build/scs_lib.lua
	@cp $(DKJSON_LIB) build/dkjson_lib.lua
	@cp $(EDN_LIB) build/edn_lib.lua
	@cp $(CLI_LUA) build/cli_entry.lua
	@cd build && xxd -i scs_lib.lua > scs_embedded.h
	@cd build && xxd -i dkjson_lib.lua >> scs_embedded.h
	@cd build && xxd -i edn_lib.lua >> scs_embedded.h
	@cd build && xxd -i cli_entry.lua >> scs_embedded.h
	@echo "Embedded Lua source into $(EMBEDDED_HEADER)"

# ============================================================================
# Compile Phase
# ============================================================================
$(BINARY): main.c $(EMBEDDED_HEADER) $(LUA_SRC)
	$(CC) $(CFLAGS) -o $@ main.c $(LUA_SRC) $(LDFLAGS)

# ============================================================================
# Install / Uninstall
# ============================================================================
install: $(BINARY)
	install -d $(PREFIX)/bin
	install -m 755 $(BINARY) $(PREFIX)/bin/$(BINARY)
uninstall:
	rm -f $(PREFIX)/bin/$(BINARY)

# ============================================================================
# Test
# ============================================================================
test: $(BINARY)
	@echo "Running tests..."
	@./test/run_tests.sh

# ============================================================================
# Clean
# ============================================================================
clean:
	rm -f $(BINARY)
	rm -rf build/
.PHONY: all clean install uninstall test