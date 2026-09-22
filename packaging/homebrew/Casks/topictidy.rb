cask "topictidy" do
  version "__VERSION__"
  sha256 "__SHA256_DMG__"

  url "https://github.com/YangChen-cn/TopicTidy/releases/download/v#{version}/TopicTidy-#{version}-arm64.dmg"
  name "TopicTidy"
  desc "Local, explainable and reversible Downloads organizer"
  homepage "https://github.com/YangChen-cn/TopicTidy"

  livecheck do
    url :homepage
    strategy :github_latest
  end

  depends_on macos: ">= :sequoia"
  depends_on arch: :arm64

  app "TopicTidy.app"
  # The daily task runs this binary; expose it as `tt` for the terminal too.
  binary "#{appdir}/TopicTidy.app/Contents/Resources/tt", target: "tt"

  uninstall quit: "com.topictidy.app",
            launchctl: "com.topictidy.daily"

  zap trash: [
    "~/Library/LaunchAgents/com.topictidy.daily.plist",
    # The index and undo history are deliberately kept: remove them by hand if
    # you want a clean slate.
  ]
end
