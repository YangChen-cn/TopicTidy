cask "topictidy-cli" do
  version "__VERSION__"
  sha256 "__SHA256_CLI__"

  url "https://github.com/YangChen-cn/TopicTidy/releases/download/v#{version}/topictidy-cli-#{version}-arm64.tar.gz"
  name "TopicTidy CLI"
  desc "Command-line Downloads organizer (the tt binary from TopicTidy)"
  homepage "https://github.com/YangChen-cn/TopicTidy"

  livecheck do
    url :homepage
    strategy :github_latest
  end

  depends_on macos: :sequoia
  depends_on arch: :arm64

  # Prebuilt arm64 binary: no Xcode, Swift, CLT or Python required.
  binary "topictidy-cli-#{version}-arm64/tt", target: "tt"

  caveats <<~EOS
    只需菜单栏界面时安装应用本体：
      brew install --cask YangChen-cn/tap/topictidy
  EOS
end
