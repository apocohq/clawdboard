.PHONY: build run test format lint clean setup

build:
	swift build

run:
	swift run Clawdboard

test:
	swift test

format:
	mise run format

lint:
	mise run lint

clean:
	swift package clean

setup:
	mise install
	mise generate git-pre-commit --write
	@echo "Done! Tools installed and pre-commit hook configured."
