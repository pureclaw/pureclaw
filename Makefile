NIX := nix develop . --command

.PHONY: build test clean lint coverage run repl gateway-dev frontend-build

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

# Build the frontend bundle that PureClaw's HTTP server serves from
# frontend/dist/. The static-asset path is baked into Frontend/Server.hs,
# so a stale dist/ silently serves outdated UI. Run this any time the
# frontend source changes (it's fast — ~500ms).
frontend-build:
	cd frontend && npm run build

# Manual-testing entry point for the gateway. Always rebuilds the
# frontend first so you never end up testing a stale bundle against
# fresh Haskell changes. Use this instead of running
# `cabal run pureclaw -- gateway run` directly.
gateway-dev: frontend-build
	$(NIX) cabal run pureclaw -- gateway run

tui:
	$(NIX) cabal run pureclaw -- tui
