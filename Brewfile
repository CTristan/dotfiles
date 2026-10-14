brew "chezmoi"
brew "gh"
brew "git-lfs"
brew "jq"
cask "secretive"

skipped = ENV.fetch("DOTFILES_SKIP", "").split(",")
cask "obsidian" unless skipped.include?("vault")

unless skipped.include?("runtimes")
  cask "docker-desktop"
  brew "pnpm"
  brew "bun"
  brew "python"
end
