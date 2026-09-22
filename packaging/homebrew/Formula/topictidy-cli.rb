class TopictidyCli < Formula
  desc "Local, explainable and reversible topic-based Downloads organizer (CLI)"
  homepage "https://github.com/YangChen-cn/TopicTidy"
  url "https://github.com/YangChen-cn/TopicTidy/releases/download/v__VERSION__/topictidy-cli-__VERSION__-arm64.tar.gz"
  sha256 "__SHA256_CLI__"
  version "__VERSION__"
  license "MIT"

  livecheck do
    url :homepage
    strategy :github_latest
  end

  depends_on macos: :sequoia
  depends_on arch: :arm64

  def install
    prefix_dir = Dir["topictidy-cli-*/"].first || "."
    bin.install "#{prefix_dir}tt" => "tt"
    prefix.install "#{prefix_dir}LICENSE" => "LICENSE"
    doc.install "#{prefix_dir}README.md" => "README.md"
  end

  def caveats
    <<~EOS
      仅安装命令行工具。需要菜单栏界面时：
        brew install --cask YangChen-cn/tap/topictidy
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/tt --version")
    system "#{bin}/tt", "--help"
  end
end
