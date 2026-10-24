# frozen_string_literal: true

require "spec_helper"

$LOAD_PATH.unshift(File.expand_path("../tools/lib", __dir__))
require "feedstock"

# The monitor's answer classification, kept pure so the network edge
# stays out of the suite: a quota answer is TRANSIENT (retry, then name
# it), everything else that is not a success is a dead upstream.
#
# The 2026-10-23 run is the reason this exists: an anonymous
# api.github.com call answered 403 under the shared-IP quota, and the
# monitor reported a dead upstream.
RSpec.describe Feedstock::ReleaseMonitor do
  it "treats the quota answers as transient and nothing else" do
    expect(described_class.transient_status?(403)).to be(true)
    expect(described_class.transient_status?(429)).to be(true)
    [200, 301, 404, 500, 502].each do |code|
      expect(described_class.transient_status?(code)).to be(false), "status #{code} is not a quota answer"
    end
  end

  it "honours Retry-After seconds and caps the wait" do
    expect(described_class.retry_after("retry-after" => "5")).to eq(5)
    expect(described_class.retry_after("retry-after" => "9000")).to eq(60)
  end

  it "falls back to the rate-limit reset, clamped to at least a second" do
    now = Time.now.to_i
    expect(described_class.retry_after("x-ratelimit-reset" => (now + 10).to_s)).to be_between(1, 60)
    expect(described_class.retry_after("x-ratelimit-reset" => (now - 100).to_s)).to eq(1)
  end

  it "answers nil when the server gives no advice" do
    expect(described_class.retry_after({})).to be_nil
    expect(described_class.retry_after("retry-after" => "Wed, 21 Oct 2015 07:28:00 GMT")).to be_nil
  end
end
