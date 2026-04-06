NIX := nix develop . --command

.PHONY: build test clean lint coverage run repl

build:
	$(NIX) cabal build

test:
	$(NIX) cabal test

coverage:
	$(NIX) cabal test --enable-coverage

lint:
	$(NIX) hlint src/ test/ app/

clean:
	$(NIX) cabal clean

run:
	$(NIX) cabal run pureclaw

repl:
	$(NIX) cabal repl
