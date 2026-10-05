# frozen_string_literal: true

# Copyright (c) 2026 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of the Tebako project.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

require "spec_helper"
require "base64"
require "digest"
require "json"
require "tmpdir"
require "yaml"

# The tool under test rides the load path (the repo's no-require_relative
# rule; the sibling factories' $LOAD_PATH idiom).
$LOAD_PATH.unshift(File.expand_path("../tools", __dir__))
require "registry_update"

# Recording stand-ins in the sign_release_spec idiom: the renderer accepts
# any client object, and every interaction is observable through the fake.
RegistrySpecRelease = Struct.new(:url, :tag_name)
RegistrySpecAsset = Struct.new(:name, :browser_download_url)
RegistrySpecContents = Struct.new(:content)

# The Octokit stand-in: one release carrying shard assets whose bodies are
# canned JSON, and a contents-API registry source that is a static
# document, a proc (so a spec can read back what the last run wrote), or
# Octokit::NotFound (no registry on main yet).
class FakeRegistryClient
  def initialize(release:, shards:, registry: nil)
    @release = release
    @shards = shards
    @registry = registry
  end

  def release_for_tag(_repo, _tag)
    @release
  end

  def release_assets(url)
    url == @release.url ? @shards.map(&:first) : []
  end

  def get(url)
    @shards.to_h { |asset, body| [asset.browser_download_url, body] }.fetch(url)
  end

  def contents(_repo, **)
    source = @registry.respond_to?(:call) ? @registry.call : @registry
    raise Octokit::NotFound if source.nil?

    RegistrySpecContents.new(Base64.strict_encode64(source))
  end
end

RSpec.describe RegistryUpdate do
  let(:version) { "9.9.9" }

  # The build-matrix fixture the feedstock model reads the asset-platform
  # → triplet mapping from (the real workflow's shape: 1 flavor × 5
  # platforms).
  MATRIX_FIXTURE = <<~YAML
    name: build-payload
    jobs:
      build:
        strategy:
          matrix:
            flavor: [official]
            platform:
              - {triplet: aarch64-macos, asset_platform: macos-arm64, exe_suffix: ""}
              - {triplet: x86_64-macos, asset_platform: macos-x86_64, exe_suffix: ""}
              - {triplet: x86_64-linux-gnu, asset_platform: linux-gnu-x86_64, exe_suffix: ""}
              - {triplet: aarch64-linux-gnu, asset_platform: linux-gnu-arm64, exe_suffix: ""}
              - {triplet: x86_64-windows-ucrt, asset_platform: windows-ucrt64, exe_suffix: .exe}
  YAML

  # A release shard as tools/build writes it (the release's
  # machine-readable unit, spec 13 §2a): the exe pair's own fields plus
  # the `image` block the registry mirrors. `name_suffix` mints a second
  # asset claiming the same platform (the duplicate-triplet case).
  # `new_era` mints the post-tebako#716 spelling (the implementation
  # segment in the stem — what tools/build writes from this branch on).
  def shard(bun:, platform:, tebako_version: version, image: :default, name_suffix: "", new_era: false)
    exe_suffix = platform.start_with?("windows") ? ".exe" : ""
    stem = if new_era
             "tebako-runtime-#{tebako_version}-bun-#{bun}-#{platform}#{name_suffix}"
           else
             "tebako-runtime-#{tebako_version}-#{bun}-#{platform}#{name_suffix}"
           end
    body = { "tebako_version" => tebako_version, "bun_version" => bun,
             "language_version" => "1.4", "abi" => "1.4",
             "implementation" => "bun",
             "platform" => platform,
             "filename" => "#{stem}#{exe_suffix}",
             "sha256" => Digest::SHA256.hexdigest("BYTES-#{stem}#{exe_suffix}") }
    case image
    when :default
      body["image"] = { "filename" => "#{stem}.tfs",
                        "sha256" => Digest::SHA256.hexdigest("BYTES-#{stem}.tfs") }
    when :absent
      # no image key at all — the missing-keys refusal
    else
      body["image"] = image
    end
    asset = RegistrySpecAsset.new("#{stem}.manifest.json", "https://download.test/#{stem}.manifest.json")
    [asset, JSON.generate(body)]
  end

  def shards_of(*list)
    list.map { |args| shard(**args) }
  end

  def render(shards, registry: nil, version_override: nil)
    ver = version_override || version
    Dir.mktmpdir do |dir|
      matrix_path = File.join(dir, "build-payload.yml")
      File.write(matrix_path, MATRIX_FIXTURE)
      path = File.join(dir, "tpkg-registry.yaml")
      release = RegistrySpecRelease.new("https://api.test/releases/1", "v#{ver}")
      client = FakeRegistryClient.new(release: release, shards: shards, registry: registry)
      described_class.new(client: client,
                          env: { "TEBAKO_VERSION" => ver, "REGISTRY_PATH" => path,
                                 "MATRIX_PATH" => matrix_path }).run
      yield path if block_given?
      return File.read(path)
    end
  end

  def payload_named(doc, name)
    doc["payloads"].find { |p| p["name"] == name }
  end

  it "derives the registry from the shards: one bun payload, composite version lines, image-mirroring rows" do
    shards = shards_of({ bun: "1.4.2", platform: "macos-arm64" },
                       { bun: "1.9.0", platform: "macos-arm64" },
                       { bun: "1.9.0", platform: "windows-ucrt64" },
                       { bun: "1.10.0", platform: "linux-gnu-x86_64" })
    doc = YAML.safe_load(render(shards))

    expect(doc["schema_version"]).to eq(1)
    payload = payload_named(doc, "bun")
    expect(payload["kind"]).to eq("runtime")
    # The MINOR-1 edge-discovery key — an engine-less runtime entry is
    # invisible to `kind: runtime` edges.
    expect(payload["engine"]).to eq("bun")
    # spec 28 §8's flavor axis: an implementation-named edge sees only
    # entries carrying the same key — entry-level, never per version row.
    expect(payload["implementation"]).to eq("bun")
    # Composite <bun>-<tebako> keys, numeric sort on both parts, never
    # lexical: 1.9.0 < 1.10.0.
    expect(payload["versions"].map { |v| v["version"] })
      .to eq(["1.4.2-9.9.9", "1.9.0-9.9.9", "1.10.0-9.9.9"])
    v = payload["versions"].find { |x| x["version"] == "1.9.0-9.9.9" }
    expect(v["platforms"].keys).to eq(%w[aarch64-macos x86_64-windows-ucrt])
    stem = "tebako-runtime-9.9.9-1.9.0-macos-arm64"
    # The row mirrors the ENV IMAGE (never the exe).
    expect(v["platforms"]["aarch64-macos"])
      .to eq("artifact" => "#{stem}.tfs", "sha256" => Digest::SHA256.hexdigest("BYTES-#{stem}.tfs"))
    expect(v["release"]).to eq("ref" => "tfs:github:tamatebako/tebako-runtime-bun:v9.9.9")
    expect(v).not_to have_key("implementation")
    expect(payload["default"]).to eq("1.10.0-9.9.9")
  end

  # tebako#716: a post-flip shard's filenames carry the implementation
  # segment — the renderer mirrors the shard's own strings verbatim,
  # never recomposes a name, so the new spelling flows through untouched
  # (and the segment-less spellings above keep flowing as published).
  it "mirrors a post-tebako#716 (implementation-segment) artifact name verbatim" do
    shards = shards_of({ bun: "1.4.2", platform: "macos-arm64", new_era: true },
                       { bun: "1.4.2", platform: "windows-ucrt64", new_era: true })
    doc = YAML.safe_load(render(shards))

    payload = payload_named(doc, "bun")
    v = payload["versions"].find { |x| x["version"] == "1.4.2-9.9.9" }
    stem = "tebako-runtime-9.9.9-bun-1.4.2-macos-arm64"
    expect(v["platforms"]["aarch64-macos"])
      .to eq("artifact" => "#{stem}.tfs", "sha256" => Digest::SHA256.hexdigest("BYTES-#{stem}.tfs"))
    expect(v["platforms"]["x86_64-windows-ucrt"]["artifact"])
      .to eq("tebako-runtime-9.9.9-bun-1.4.2-windows-ucrt64.tfs")
  end

  it "keeps every tebako line addressable: a reline adds a NEW composite version, never a collision" do
    first = render(shards_of({ bun: "1.4.2", platform: "macos-arm64" }))
    reline = shards_of({ bun: "1.4.2", platform: "macos-arm64", tebako_version: "9.9.10" },
                       { bun: "1.4.2", platform: "linux-gnu-x86_64", tebako_version: "9.9.10" })
    doc = YAML.safe_load(render(reline, registry: first, version_override: "9.9.10"))

    payload = payload_named(doc, "bun")
    expect(payload["versions"].map { |v| v["version"] })
      .to eq(["1.4.2-9.9.9", "1.4.2-9.9.10"])
    old = payload["versions"].find { |v| v["version"] == "1.4.2-9.9.9" }
    expect(old["platforms"].keys).to eq(%w[aarch64-macos])
    expect(old["release"]).to eq("ref" => "tfs:github:tamatebako/tebako-runtime-bun:v9.9.9")
    new = payload["versions"].find { |v| v["version"] == "1.4.2-9.9.10" }
    expect(new["platforms"].keys).to eq(%w[aarch64-macos x86_64-linux-gnu])
    expect(payload["default"]).to eq("1.4.2-9.9.10")
  end

  it "unions platform rows on a same-line re-render: new rows win per triplet, the release ref tracks" do
    first = render(shards_of({ bun: "1.4.2", platform: "macos-arm64" }))
    rerender = shards_of({ bun: "1.4.2", platform: "macos-arm64" },
                         { bun: "1.4.2", platform: "linux-gnu-x86_64" })
    doc = YAML.safe_load(render(rerender, registry: first))

    payload = payload_named(doc, "bun")
    expect(payload["versions"].map { |v| v["version"] }).to eq(["1.4.2-9.9.9"])
    row = payload["versions"].first
    expect(row["platforms"].keys).to eq(%w[aarch64-macos x86_64-linux-gnu])
    expect(payload["default"]).to eq("1.4.2-9.9.9")
  end

  it "upserts into an existing registry, preserving other payloads and withdrawn marks" do
    existing = <<~YAML
      schema_version: 1
      payloads:
        - name: metanorma
          kind: app
          versions:
            - version: '1.2.3'
              platforms: universal
              release: {ref: tfs:github:tebako-packages/metanorma:1.2.3}
        - name: bun
          kind: runtime
          engine: bun
          versions:
            - version: '1.3.9-9.9.8'
              status: withdrawn
              platforms:
                aarch64-macos:
                  artifact: tebako-runtime-9.9.8-1.3.9-macos-arm64.tfs
                  sha256: 'aaaa'
              release: {ref: tfs:github:tamatebako/tebako-runtime-bun:v9.9.8}
          default: '1.3.9-9.9.8'
    YAML
    shards = shards_of({ bun: "1.4.2", platform: "linux-gnu-x86_64" })
    doc = YAML.safe_load(render(shards, registry: existing))

    expect(doc["payloads"].map { |p| p["name"] }).to contain_exactly("metanorma", "bun")
    payload = payload_named(doc, "bun")
    old = payload["versions"].find { |v| v["version"] == "1.3.9-9.9.8" }
    expect(old["status"]).to eq("withdrawn")
    expect(old["platforms"]).to have_key("aarch64-macos")
    new = payload["versions"].find { |v| v["version"] == "1.4.2-9.9.9" }
    stem = "tebako-runtime-9.9.9-1.4.2-linux-gnu-x86_64"
    expect(new["platforms"]).to eq("x86_64-linux-gnu" => {
                                     "artifact" => "#{stem}.tfs",
                                     "sha256" => Digest::SHA256.hexdigest("BYTES-#{stem}.tfs")
                                   })
    # The default moves off the withdrawn line onto the live one.
    expect(payload["default"]).to eq("1.4.2-9.9.9")
  end

  it "upserts engine onto an existing engine-less bun entry (the MINOR-1 backfill, never a hand-edit)" do
    existing = <<~YAML
      schema_version: 1
      payloads:
        - name: bun
          kind: runtime
          versions:
            - version: '1.3.9-9.9.8'
              platforms:
                aarch64-macos:
                  artifact: tebako-runtime-9.9.8-1.3.9-macos-arm64.tfs
                  sha256: 'aaaa'
              release: {ref: tfs:github:tamatebako/tebako-runtime-bun:v9.9.8}
          default: '1.3.9-9.9.8'
    YAML
    shards = shards_of({ bun: "1.4.2", platform: "macos-arm64" })
    doc = YAML.safe_load(render(shards, registry: existing))

    expect(payload_named(doc, "bun")["engine"]).to eq("bun")
  end

  it "upserts implementation onto an existing implementation-less bun entry (the spec 28 §8 backfill, never a hand-edit)" do
    existing = <<~YAML
      schema_version: 1
      payloads:
        - name: bun
          kind: runtime
          engine: bun
          versions:
            - version: '1.3.9-9.9.8'
              platforms:
                aarch64-macos:
                  artifact: tebako-runtime-9.9.8-1.3.9-macos-arm64.tfs
                  sha256: 'aaaa'
              release: {ref: tfs:github:tamatebako/tebako-runtime-bun:v9.9.8}
          default: '1.3.9-9.9.8'
    YAML
    shards = shards_of({ bun: "1.4.2", platform: "macos-arm64" })
    doc = YAML.safe_load(render(shards, registry: existing))

    expect(payload_named(doc, "bun")["implementation"]).to eq("bun")
  end

  it "is byte-idempotent: rendering over its own output changes nothing" do
    shards = shards_of({ bun: "1.3.9", platform: "linux-gnu-arm64" },
                       { bun: "1.4.2", platform: "macos-arm64" })
    first = render(shards)
    second = render(shards, registry: -> { first })
    expect(second).to eq(first)
  end

  it "carries the ownership header (never hand-edit except status: withdrawn)" do
    output = render(shards_of({ bun: "1.4.2", platform: "macos-arm64" }))
    expect(output).to include("OWNED BY tools/registry_update.rb")
    expect(output).to include("status: withdrawn")
  end

  it "seeds the document when main carries no registry yet" do
    shards = shards_of({ bun: "1.4.2", platform: "macos-arm64" })
    doc = YAML.safe_load(render(shards, registry: nil))
    expect(doc["schema_version"]).to eq(1)
    expect(doc["payloads"].map { |p| p["name"] }).to eq(["bun"])
  end

  it "drops the default loudly when every version is withdrawn" do
    # The withdrawn entry's own release re-renders (the version key is
    # unchanged), the merge preserves the mark, and no live line remains
    # for `default:` to name.
    existing = <<~YAML
      schema_version: 1
      payloads:
        - name: bun
          kind: runtime
          engine: bun
          versions:
            - version: '1.4.2-9.9.9'
              status: withdrawn
              platforms:
                aarch64-macos:
                  artifact: tebako-runtime-9.9.9-1.4.2-macos-arm64.tfs
                  sha256: 'aaaa'
              release: {ref: tfs:github:tamatebako/tebako-runtime-bun:v9.9.9}
          default: '1.4.2-9.9.9'
    YAML
    shards = shards_of({ bun: "1.4.2", platform: "macos-arm64" })
    output = nil
    expect do
      output = render(shards, registry: existing)
    end.to output(/no default/).to_stderr
    payload = payload_named(YAML.safe_load(output), "bun")
    expect(payload).not_to have_key("default")
    expect(payload["versions"].first["status"]).to eq("withdrawn")
  end

  it "fails named when an existing version carries `platforms: universal` (never both shapes)" do
    existing = <<~YAML
      schema_version: 1
      payloads:
        - name: bun
          kind: runtime
          engine: bun
          versions:
            - version: '1.4.2-9.9.9'
              platforms: universal
              release: {ref: tfs:github:tamatebako/tebako-runtime-bun:v9.9.9}
    YAML
    shards = shards_of({ bun: "1.4.2", platform: "macos-arm64" })
    expect { render(shards, registry: existing) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /never both/)
  end

  it "fails named on a hand-edited non-composite version (the sort key is the composite grammar)" do
    existing = <<~YAML
      schema_version: 1
      payloads:
        - name: bun
          kind: runtime
          engine: bun
          versions:
            - version: '1.4.2'
              platforms: universal
              release: {ref: tfs:github:tamatebako/tebako-runtime-bun:v9.9.9}
    YAML
    shards = shards_of({ bun: "1.4.2", platform: "macos-arm64" })
    expect { render(shards, registry: existing) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /not a <bun>-<tebako> composite/)
  end

  it "fails named when a shard declares another tebako version" do
    shards = shards_of({ bun: "1.4.2", platform: "macos-arm64", tebako_version: "0.0.1" })
    expect { render(shards) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /declares tebako_version "0\.0\.1"/)
  end

  it "fails named when a shard names an unknown platform" do
    shards = shards_of({ bun: "1.4.2", platform: "plan9-arm64" })
    expect { render(shards) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /unknown platform "plan9-arm64"/)
  end

  it "fails named when two shards claim the same triplet for one bun" do
    shards = shards_of({ bun: "1.4.2", platform: "macos-arm64", name_suffix: "-a" },
                       { bun: "1.4.2", platform: "macos-arm64", name_suffix: "-b" })
    expect { render(shards) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /two shards claim aarch64-macos/)
  end

  it "fails named when a shard's image block is malformed (the registry mirrors the env image)" do
    shards = shards_of({ bun: "1.4.2", platform: "macos-arm64", image: {} })
    expect { render(shards) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /carries no image \{filename, sha256\} block/)
  end

  it "fails named when a shard omits the image key entirely" do
    shards = shards_of({ bun: "1.4.2", platform: "macos-arm64", image: :absent })
    expect { render(shards) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /is missing image/)
  end

  it "fails named when a shard is missing a required key" do
    asset, body = shard(bun: "1.4.2", platform: "macos-arm64")
    broken = JSON.generate(JSON.parse(body).reject { |key, _| key == "bun_version" })
    expect { render([[asset, broken]]) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /is missing bun_version/)
  end

  it "fails named when the tag has no release" do
    Dir.mktmpdir do |dir|
      matrix_path = File.join(dir, "build-payload.yml")
      File.write(matrix_path, MATRIX_FIXTURE)
      release = RegistrySpecRelease.new("https://api.test/releases/1", "v#{version}")
      client = FakeRegistryClient.new(release: release, shards: [])
      def client.release_for_tag(_repo, _tag)
        raise Octokit::NotFound
      end
      updater = described_class.new(client: client,
                                    env: { "TEBAKO_VERSION" => version,
                                           "REGISTRY_PATH" => File.join(dir, "r.yaml"),
                                           "MATRIX_PATH" => matrix_path })
      expect { updater.run }
        .to raise_error(RegistryUpdate::RegistryUpdateError, /no release found for tag v9\.9\.9/)
    end
  end

  it "fails named when the release carries no shards" do
    expect { render([]) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /carries no \.manifest\.json shards/)
  end
end
