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

  depends_on macos: :sequoia
  depends_on arch: :arm64

  app "TopicTidy.app"
  # The daily task runs this binary; expose it as `tt` for the terminal too.
  binary "#{appdir}/TopicTidy.app/Contents/Resources/tt", target: "tt"

  uninstall quit: "com.topictidy.app",
            launchctl: "com.topictidy.daily"

  caveats <<~EOS
    TopicTidy 使用自签名证书，未经 Apple 公证。首次启动时系统会提示“未验证”，
    请在“系统设置 → 隐私与安全性”中允许打开；终端里的 tt 同理，被系统终止后
    执行一次即可（exit 137 表示这一步还没做）：

      xattr -dr com.apple.quarantine /Applications/TopicTidy.app

    只需要命令行时：

      brew install --cask YangChen-cn/tap/topictidy-cli
  EOS

  zap trash: [
    "~/Library/LaunchAgents/com.topictidy.daily.plist",
    # The index and undo history are deliberately kept: remove them by hand if
    # you want a clean slate.
  ]
end
