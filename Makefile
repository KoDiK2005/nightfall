# NIGHTFALL — build file
CC      := gcc
CFLAGS  := -O2 -Wall -Wextra -std=c11
SDL_CF  := $(shell pkg-config --cflags sdl2 SDL2_mixer)
SDL_LD  := $(shell pkg-config --libs sdl2 SDL2_mixer)
LDFLAGS := $(SDL_LD) -lm
BIN     := nightfall
CLASSIC := nightfall-classic

# Windows (MSYS2/MinGW): .exe suffix, and OpenGL comes from opengl32 not GL
ifeq ($(OS),Windows_NT)
	EXE     := .exe
	GL_LIBS := -lopengl32
else
	EXE     :=
	GL_LIBS := -lGL
endif

.PHONY: all audio run run-classic classic clean

all: audio $(BIN)$(EXE)

# real-3D OpenGL build (primary): main.c + its modules (gen/ai/audio/render/hud),
# sharing state via game.h. -lz is for the PNG "vision" image decoder.
SRCS := src/main.c src/gen.c src/ai.c src/audio.c src/render.c src/hud.c
$(BIN)$(EXE): $(SRCS) src/game.h
	$(CC) $(CFLAGS) $(SDL_CF) $(SRCS) -o $(BIN)$(EXE) $(LDFLAGS) $(GL_LIBS) -lz

# original raycasting build (fallback, no GPU needed)
classic: audio $(CLASSIC)$(EXE)
$(CLASSIC)$(EXE): src/raycast.c
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
