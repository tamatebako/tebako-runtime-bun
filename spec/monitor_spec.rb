# frozen_string_literal: true

require "spec_helper"

$LOAD_PATH.unshift(File.expand_path("../tools/lib", __dir__))
require "feedstock"

# The bun release monitor's pure core (the propose-bump shape): the
# url-derived version anchor (…/download/bun-v<ver>/…), the
# SHASUMS256.txt parse, and the line-level Tebakofile rewrite. The
# network edge (the GitHub releases index, the SHASUMS asset fetch)
# stays outside the suite — the risky logic is the edit, and the edit
# is fully deterministic here.
#
# The rewrite's invariants, locked:
#   * every oven-sh/bun download url moves (the version rides the
#     bun-v<ver>/ path segment; the asset names themselves are
#     version-free);
#   * each url's following sha256: line receives that url's asset
#     digest from the new release's SHASUMS — paired, never positional
#     beyond the one-line adjacency the file itself guarantees;
#   * the standalone version: "<full semver>" line moves with them and
#     NO other version: key does (the tools pins carry their own
#     version: keys — tebako line pins — and must never be caught);
#   * a digest miss is a named error raised BEFORE the caller writes.
RSpec.describe "Feedstock::ReleaseMonitor" do
  let(:tebakofile_snippet) do
    <<~YAML
      tools:
        tebako:
          version: "2.8.22"
      flavors:
        official:
          version: "1.4.2"
          sources:
            - platform: "aarch64-macos"
              url: "https://github.com/oven-sh/bun/releases/download/bun-v1.4.2/bun-darwin-aarch64.zip"
              sha256: "90987a3a16d7db556d886ac3d551e7b6d3edf0a1cf43acaed622e8676be1d12f"
              strip_components: 1
            - platform: "x86_64-windows-ucrt"
              url: "https://github.com/oven-sh/bun/releases/download/bun-v1.4.2/bun-windows-x64-baseline.zip"
              sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
              strip_components: 1
    YAML
  end

  let(:shasums) do
    Feedstock::ReleaseMonitor.parse_shasums(
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  bun-darwin-aarch64.zip\n" \
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  bun-windows-x64-baseline.zip\n" \
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc  SHASUMS256.txt\n"
    )
  end

  it "anchors the current version on the download url path, never a version: key" do
    expect(Feedstock::ReleaseMonitor.current_version(tebakofile_snippet)).to eq("1.4.2")
  end

  it "raises by name when the url anchor is gone" do
    expect { Feedstock::ReleaseMonitor.current_version("version: \"1.4.2\"\n") }
      .to raise_error(Feedstock::FeedstockError, /no bun-v<version>\/ download url/)
  end

  it "parses SHASUMS256.txt lines into a basename → digest map" do
    expect(shasums["bun-windows-x64-baseline.zip"]).to eq("b" * 64)
    expect(shasums.keys.length).to eq(3)
  end

  it "rewrites the download paths, their paired digests, and the flavor's version line" do
    updated, touched = Feedstock::ReleaseMonitor.rewrite(tebakofile_snippet, "1.4.2", "1.4.3", shasums)
    expect(touched).to eq(2)
    expect(updated).to include("download/bun-v1.4.3/bun-darwin-aarch64.zip")
    expect(updated).to include("download/bun-v1.4.3/bun-windows-x64-baseline.zip")
    expect(updated).to include("sha256: \"#{'a' * 64}\"")
    expect(updated).to include("sha256: \"#{'b' * 64}\"")
    expect(updated).not_to include("1.4.2")
  end

  it "never touches the tools pin's version: key" do
    updated, = Feedstock::ReleaseMonitor.rewrite(tebakofile_snippet, "1.4.2", "1.4.3", shasums)
    expect(updated).to include('version: "2.8.22"')
  end

  it "raises by name on a digest miss before anything can be written" do
    expect { Feedstock::ReleaseMonitor.rewrite(tebakofile_snippet, "1.4.2", "1.4.3", {}) }
      .to raise_error(Feedstock::FeedstockError, /no SHASUMS256\.txt entry for bun-darwin-aarch64\.zip/)
  end
end
