# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# The tool under test rides the load path (the repo's no-require_relative
# rule; the sibling factories' $LOAD_PATH idiom). tools/lib joins through
# audit_release.rb's own unshift.
$LOAD_PATH.unshift(File.expand_path("../tools", __dir__))
require "audit_release"

# A read-only Octokit stand-in: the audit is strictly a QUERY (spec 13
# §2a — it never mutates the release), and the fake enforces that by
# construction — there are no upload/delete methods to call.
AuditSpecRelease = Struct.new(:url)
AuditSpecAsset = Struct.new(:name)

class FakeAuditClient
  def initialize(release:, asset_names:)
    @release = release
    @asset_names = asset_names
  end

  def release_for_tag(_repo, _tag)
    @release
  end

  def release_assets(_url)
    @asset_names.map { |name| AuditSpecAsset.new(name) }
  end
end

RSpec.describe ReleaseAudit do
  let(:version) { "9.9.9" }
  let(:release) { AuditSpecRelease.new("https://api.test/releases/1") }

  # The feedstock fixtures: a mini Tebakofile + a mini build-payload
  # workflow whose matrix block mirrors the real one's shape (1 flavor ×
  # 5 platforms). Feedstock parses these; the expected names below are
  # written out literally, so a misread fixture fails the clean case.
  RECIPE_FIXTURE = <<~YAML
    runtime:
      wrapper_tebako: "9.9.9"
    flavors:
      official:
        upstream: {version: "1.4.2"}
  YAML

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

  def leg_names(bun_version, asset_platform, exe_suffix)
    stem = "tebako-runtime-#{version}-#{bun_version}-#{asset_platform}"
    exe = "#{stem}#{exe_suffix}"
    [exe, "#{exe}.sha256", "#{stem}.tfs", "#{stem}.tfs.sha256", "#{stem}.manifest.json"]
  end

  # The whole expected matrix, written out: 1 flavor × 5 platforms ×
  # the pair + sidecars + shard = 25 write-once names (spec 13 §2a).
  def all_names
    [%w[1.4.2 macos-arm64], %w[1.4.2 macos-x86_64], %w[1.4.2 linux-gnu-x86_64],
     %w[1.4.2 linux-gnu-arm64], ["1.4.2", "windows-ucrt64", ".exe"]]
      .flat_map { |bun, platform, suffix| leg_names(bun, platform, suffix.to_s) }
  end

  def audit_for(asset_names, env_extra: {})
    Dir.mktmpdir do |dir|
      recipe_path = File.join(dir, "Tebakofile")
      matrix_path = File.join(dir, "build-payload.yml")
      File.write(recipe_path, RECIPE_FIXTURE)
      File.write(matrix_path, MATRIX_FIXTURE)
      env = { "TEBAKO_VERSION" => version,
              "RECIPE_PATH" => recipe_path,
              "MATRIX_PATH" => matrix_path }.merge(env_extra)
      client = FakeAuditClient.new(release: release, asset_names: asset_names)
      yield ReleaseAudit.new(client: client, env: env)
    end
  end

  it "targets this feedstock's release (the rename-sweep guard)" do
    expect(RUNTIME_REPO).to eq("tamatebako/tebako-runtime-bun")
  end

  it "derives the expected matrix from the workflow matrix x recipe pins" do
    audit_for(all_names) do |audit|
      expect(audit.expected_names).to match_array(all_names)
      expect(audit.expected_names.size).to eq(25)
    end
  end

  it "adds every served name's own .asc when the line signs (spec 09 §5's no-fold rule)" do
    audit_for(all_names, env_extra: { "TEBAKO_RELEASE_SIGNING_ENABLED" => "true" }) do |audit|
      expected = audit.expected_names(signing: true)
      expect(expected.size).to eq(50)
      expect(expected).to include("tebako-runtime-9.9.9-1.4.2-macos-arm64.tfs.asc",
                                  "tebako-runtime-9.9.9-1.4.2-windows-ucrt64.exe.asc")
    end
  end

  it "passes clean when every leg's names are served (unsigned line)" do
    audit_for(all_names) do |audit|
      expect { expect(audit.run).to eq(:clean) }.to output(/audit clean/).to_stdout
    end
  end

  it "is a subset check, never equality: extra non-monolith names are tolerated" do
    audit_for(all_names + ["tebako-runtime-9.9.9-1.4.2-linux-musl-x86_64.tfs"]) do |audit|
      expect(audit.run).to eq(:clean)
    end
  end

  it "fails named, listing the gap, when a leg's asset is missing" do
    missing = "tebako-runtime-9.9.9-1.4.2-macos-arm64.tfs"
    audit_for(all_names - [missing]) do |audit|
      expect { audit.run }
        .to output(/Missing asset: #{Regexp.escape(missing)}/).to_stdout
        .and(raise_error(ReleaseAudit::AuditError, /failed the audit \(1 missing, 0 forbidden\)/))
    end
  end

  it "passes clean on a signing-enabled line when every name's .asc rides along" do
    signed = all_names + all_names.map { |name| "#{name}.asc" }
    audit_for(signed, env_extra: { "TEBAKO_RELEASE_SIGNING_ENABLED" => "true" }) do |audit|
      expect { expect(audit.run).to eq(:clean) }.to output(/full \.asc coverage/).to_stdout
    end
  end

  it "fails named on a signing-enabled line when an .asc is missing" do
    signed = all_names + all_names.map { |name| "#{name}.asc" }
    gap = "tebako-runtime-9.9.9-1.4.2-linux-gnu-x86_64.manifest.json.asc"
    audit_for(signed - [gap], env_extra: { "TEBAKO_RELEASE_SIGNING_ENABLED" => "true" }) do |audit|
      expect { audit.run }
        .to output(/Missing asset: #{Regexp.escape(gap)}/).to_stdout
        .and(raise_error(ReleaseAudit::AuditError, /failed the audit/))
    end
  end

  it "refuses the retired monoliths: they are NEVER release assets (spec 13 §2a)" do
    audit_for(all_names + %w[manifest.json SHA256SUMS.txt]) do |audit|
      expect { audit.run }
        .to output(/NEVER release assets/).to_stdout
        .and(raise_error(ReleaseAudit::AuditError, /failed the audit \(0 missing, 2 forbidden\)/))
    end
  end

  it "fails named when the tag has no release" do
    client = FakeAuditClient.new(release: nil, asset_names: [])
    def client.release_for_tag(_repo, _tag)
      raise Octokit::NotFound
    end
    audit = ReleaseAudit.new(client: client, env: { "TEBAKO_VERSION" => version })
    expect { audit.run }
      .to raise_error(ReleaseAudit::AuditError, /no release found for tag v9\.9\.9/)
  end
end
