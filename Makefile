# NIGHTFALL — build file
CC      := gcc
CFLAGS  := -O2 -Wall -Wextra -std=c11
SDL_CF  := $(shell pkg-config --cflags sdl2 SDL2_mixer)
SDL_LD  := $(shell pkg-config --libs sdl2 SDL2_mixer)
LDFLAGS := $(SDL_LD) -lm
BIN     := nightfall

.PHONY: all audio run clean

all: audio $(BIN)

$(BIN): src/main.c
	$(CC) $(CFLAGS) $(SDL_CF) src/main.c -o $(BIN) $(LDFLAGS)

# regenerate the procedural sound assets
audio: assets/ambient.wav
assets/ambient.wav: tools/gen_audio.py
	python3 tools/gen_audio.py

run: all
	./$(BIN)

clean:
	rm -f $(BIN)
