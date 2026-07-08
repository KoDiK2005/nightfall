# NIGHTFALL — build file
CC      := gcc
CFLAGS  := -O2 -Wall -Wextra -std=c11
# 2>/dev/null: if pkg-config itself is missing, stay quiet here -- checkdeps
# below gives a clear, actionable error instead of a raw shell message.
SDL_CF  := $(shell pkg-config --cflags sdl2 SDL2_mixer 2>/dev/null)
SDL_LD  := $(shell pkg-config --libs sdl2 SDL2_mixer 2>/dev/null)
LDFLAGS := $(SDL_LD) -lm
BIN     := nightfall
CLASSIC := nightfall-classic

# Windows (MSYS2/MinGW): .exe suffix, and OpenGL comes from opengl32 not GL.
# macOS: no libGL.so -- OpenGL is a framework, linked with -framework instead.
ifeq ($(OS),Windows_NT)
	EXE     := .exe
	GL_LIBS := -lopengl32
else
	EXE     :=
	UNAME_S := $(shell uname -s)
	ifeq ($(UNAME_S),Darwin)
		GL_LIBS := -framework OpenGL
	else
		GL_LIBS := -lGL
	endif
endif

.PHONY: all audio run run-classic classic clean checkdeps

all: checkdeps audio $(BIN)$(EXE)

# Fail fast with a plain-English fix instead of a cryptic "No such file or
# directory" if a required tool wasn't installed (see README's Build & run).
checkdeps:
ifeq ($(shell uname -s),Darwin)
	@command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found. Install it, e.g.: brew install python3"; exit 1; }
	@command -v pkg-config >/dev/null 2>&1 || { echo "error: pkg-config not found. Install it, e.g.: brew install pkg-config"; exit 1; }
	@command -v $(CC) >/dev/null 2>&1 || { echo "error: $(CC) not found. Install a C compiler, e.g.: xcode-select --install"; exit 1; }
	@pkg-config --exists sdl2 SDL2_mixer || { echo "error: SDL2 / SDL2_mixer not found. Install them, e.g.: brew install sdl2 sdl2_mixer (and make sure PKG_CONFIG_PATH includes \$$(brew --prefix)/lib/pkgconfig)"; exit 1; }
else
	@command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found. Install it, e.g.: sudo apt install -y python3"; exit 1; }
	@command -v pkg-config >/dev/null 2>&1 || { echo "error: pkg-config not found. Install it, e.g.: sudo apt install -y pkg-config"; exit 1; }
	@command -v $(CC) >/dev/null 2>&1 || { echo "error: $(CC) not found. Install a C compiler, e.g.: sudo apt install -y gcc"; exit 1; }
	@pkg-config --exists sdl2 SDL2_mixer || { echo "error: SDL2 / SDL2_mixer dev packages not found. Install them, e.g.: sudo apt install -y libsdl2-dev libsdl2-mixer-dev"; exit 1; }
endif

# real-3D OpenGL build (primary): main.c + its modules (gen/ai/audio/render/hud),
# sharing state via game.h. -lz is for the PNG "vision" image decoder.
SRCS := src/main.c src/gen.c src/ai.c src/audio.c src/render.c src/hud.c src/log.c
$(BIN)$(EXE): checkdeps $(SRCS) src/game.h
	$(CC) $(CFLAGS) $(SDL_CF) $(SRCS) -o $(BIN)$(EXE) $(LDFLAGS) $(GL_LIBS) -lz

# original raycasting build (fallback, no GPU needed)
classic: checkdeps audio $(CLASSIC)$(EXE)
$(CLASSIC)$(EXE): checkdeps src/raycast.c
	$(CC) $(CFLAGS) $(SDL_CF) src/raycast.c -o $(CLASSIC)$(EXE) $(LDFLAGS)

# regenerate the procedural sound assets
audio: assets/ambient.wav
assets/ambient.wav: tools/gen_audio.py
	python3 tools/gen_audio.py

run: all
	./$(BIN)$(EXE)

run-classic: classic
	./$(CLASSIC)$(EXE)

clean:
	rm -f $(BIN) $(BIN).exe $(CLASSIC) $(CLASSIC).exe
