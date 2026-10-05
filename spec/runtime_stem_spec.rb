# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("../tools/lib", __dir__))
require "feedstock"

# tebako#716's language segment of the runtime pair's name is this
# feedstock's distribution identity — the flavor's `implementation`
# ("bun"; the recipe ships one implementation today — oven-sh's build —
# and a future distribution variant slots its own segment in through
# its flavor block, so the segment can never be one hardcoded value).
# Three sites compose the one stem grammar from the same Tebakofile
# values: tools/pins.rb (the workflow's RUNTIME_STEM env), tools/build
# (the artifacts themselves), and Feedstock.runtime_stem (the audit +
# registry tools' expectation). A drift between them publishes names the
# audit refuses — locked here so it fails pre-merge instead.
RSpec.describe "the runtime pair's stem (tebako#716)" do
  def pins_env(asset_platform, flavor)
    out = `ruby #{File.join(REPO_ROOT, "tools/pins.rb")} #{asset_platform} #{flavor} --env 2>/dev/null`
    raise "pins.rb failed for #{flavor}/#{asset_platform}" unless $?.success?

    out.lines.map { |line| line.chomp.split("=", 2) }.to_h
  end

  it "reads the segment from the recipe's flavor block" do
    official = pins_env("macos-arm64", "official")
    expect(official.fetch("IMPLEMENTATION")).to eq("bun")
    expect(official.fetch("RUNTIME_STEM")).to match(/\Atebako-runtime-\d+\.\d+\.\d+-bun-\d/)
  end

  it "agrees across every compose site and every matrix leg" do
    Feedstock.matrix_flavors.product(Feedstock.matrix_platforms).each do |flavor, leg|
      model = Feedstock.runtime_stem(flavor, leg.asset_platform)
      expect(pins_env(leg.asset_platform, flavor).fetch("RUNTIME_STEM"))
        .to eq(model), "tools/pins.rb's RUNTIME_STEM disagrees with Feedstock.runtime_stem for #{flavor}/#{leg.asset_platform}"
    end
  end

  it "threads $IMPLEMENTATION through tools/build's own STEM compose (the artifact-naming site)" do
    build = File.read(File.join(REPO_ROOT, "tools", "build"))
    expect(build).to include('STEM="tebako-runtime-$WRAPPER_TEBAKO-$IMPLEMENTATION-$VERSION-$ASSET_PLATFORM"')
  end

  it "fails named when a flavor carries no usable implementation segment" do
    Dir.mktmpdir do |dir|
      recipe = File.join(dir, "Tebakofile")
      File.write(recipe, <<~YAML)
        runtime: {wrapper_tebako: "9.9.9"}
        flavors:
          official:
            upstream: {version: "1.4.2"}
      YAML
      expect { Feedstock.runtime_stem("official", "macos-arm64", { "RECIPE_PATH" => recipe }) }
        .to raise_error(Feedstock::FeedstockError, /flavors\.official\.implementation/)
    end
  end
end
