# NIGHTFALL — build file
CC      := gcc
CFLAGS  := -O2 -Wall -Wextra -std=c11
SDL_CF  := $(shell pkg-config --cflags sdl2 SDL2_mixer)
SDL_LD  := $(shell pkg-config --libs sdl2 SDL2_mixer)
LDFLAGS := $(SDL_LD) -lm
BIN     := nightfall
CLASSIC := nightfall-classic

.PHONY: all audio run run-classic classic clean

all: audio $(BIN)

# real-3D OpenGL build (primary); -lz for the PNG "vision" image decoder
$(BIN): src/main.c
	$(CC) $(CFLAGS) $(SDL_CF) src/main.c -o $(BIN) $(LDFLAGS) -lGL -lz

# original raycasting build (fallback, no GPU needed)
classic: audio $(CLASSIC)
$(CLASSIC): src/raycast.c
	$(CC) $(CFLAGS) $(SDL_CF) src/raycast.c -o $(CLASSIC) $(LDFLAGS)

# regenerate the procedural sound assets
audio: assets/ambient.wav
assets/ambient.wav: tools/gen_audio.py
	python3 tools/gen_audio.py

run: all
	./$(BIN)

run-classic: classic
	./$(CLASSIC)

clean:
	rm -f $(BIN) $(CLASSIC)
