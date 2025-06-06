require 'spec_helper'

describe CurrentMarketplaceResolver do

  describe "#resolve_from_host" do

    it "returns community by ident" do
      foo = FactoryBot.create(:community, ident: "foo")
      bar = FactoryBot.create(:community, ident: "bar")

      expect(CurrentMarketplaceResolver.resolve_from_host("foo.sharetribe.com", "sharetribe.com"))
        .to eq(foo)
      expect(CurrentMarketplaceResolver.resolve_from_host("bar.sharetribe.com", "sharetribe.com"))
        .to eq(bar)
      expect(CurrentMarketplaceResolver.resolve_from_host("foobar.sharetribe.com", "sharetribe.com"))
        .to eq(nil)
    end

    it "returns community by domain" do
      foo = FactoryBot.create(:community, domain: "foo.com")
      bar = FactoryBot.create(:community, domain: "bar.com")

      expect(CurrentMarketplaceResolver.resolve_from_host("foo.com", "sharetribe.com"))
        .to eq(foo)
      expect(CurrentMarketplaceResolver.resolve_from_host("bar.com", "sharetribe.com"))
        .to eq(bar)
      expect(CurrentMarketplaceResolver.resolve_from_host("foobar.com", "sharetribe.com"))
        .to eq(nil)
    end
  end

  describe "#resolve_from_id" do

    it "returns community by id" do
      Community.find_by(id: 111).try(:destroy)
      Community.find_by(id: 222).try(:destroy)
      foo = FactoryBot.create(:community, id: 111)
      bar = FactoryBot.create(:community, id: 222)

      expect(CurrentMarketplaceResolver.resolve_from_id(222))
        .to eq(bar)
    end
  end
end
