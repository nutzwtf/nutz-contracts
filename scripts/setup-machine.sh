#!/usr/bin/env bash
# scripts/setup-machine.sh — the one-time, human-only steps from docs/setup/environment.md §1.
# Everything here needs sudo, your shell rc, or your Chainstack account. Re-running is safe.
set -u
cd "$(dirname "$0")/.."

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
ask()  { read -r -p "$1 [Y/n] " a; [ -z "$a" ] || [ "$a" = y ] || [ "$a" = Y ]; }

step "1/5 System packages (sudo pacman): mise, gitleaks, z3, jq"
if ask "Install/refresh them now?"; then sudo pacman -S --needed mise gitleaks z3 jq; fi

step "2/5 mise in zsh"
if ! grep -q 'mise activate zsh' "$HOME/.zshrc" 2>/dev/null; then
  if ask "Append 'eval \"\$(mise activate zsh)\"' to ~/.zshrc?"; then
    echo 'eval "$(mise activate zsh)"' >> "$HOME/.zshrc"; echo "Added. Run: exec zsh"
  fi
else echo "Already present."; fi

step "3/5 Repo runtimes (mise trust + install: foundry 1.8.1, node 24, pnpm 11, uv)"
if command -v mise >/dev/null; then mise trust && mise install; else echo "mise not on PATH yet; rerun after step 1 and 'exec zsh'."; fi
if [ -x "$HOME/.foundry/bin/forge" ]; then
  echo "Note: a foundryup copy of Foundry exists in ~/.foundry/bin (used to bootstrap the scaffold)."
  echo "      mise shadows it inside the repo; remove it with: rm -rf ~/.foundry/bin"
fi

step "4/5 Analyzers via uv/cyfrinup (no sudo)"
if ask "Install slither (uv) and aderyn (cyfrinup)?"; then
  command -v uv >/dev/null && uv tool install slither-analyzer
  curl -L https://raw.githubusercontent.com/Cyfrin/up/main/install | bash && "$HOME/.cyfrin/bin/cyfrinup"
fi

step "5/5 Secrets and hooks"
[ -f .env ] || { cp .env.example .env; echo "Created .env from .env.example — fill RPC_4663 and RPC_4663_WS with your Chainstack URLs."; }
git config core.hooksPath .githooks && echo "core.hooksPath -> .githooks"

step "Doctor"
scripts/doctor.sh || echo "Some tools missing: finish the steps above, then 'exec zsh' and rerun scripts/doctor.sh"
