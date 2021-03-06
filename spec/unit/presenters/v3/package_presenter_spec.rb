require 'spec_helper'
require 'presenters/v3/package_presenter'

module VCAP::CloudController
  describe PackagePresenter do
    describe '#present_json' do
      it 'presents the package as json' do
        package = PackageModel.make(type: 'package_type', url: 'foobar')

        json_result = PackagePresenter.new.present_json(package)
        result      = MultiJson.load(json_result)

        expect(result['guid']).to eq(package.guid)
        expect(result['type']).to eq(package.type)
        expect(result['state']).to eq(package.state)
        expect(result['error']).to eq(package.error)
        expect(result['hash']).to eq(package.package_hash)
        expect(result['url']).to eq(package.url)
        expect(result['created_at']).to eq(package.created_at.as_json)
        expect(result['_links']).to include('self')
        expect(result['_links']).to include('app')
        expect(result['_links']).to include('space')
      end

      context 'when the package type is bits' do
        let(:package) { PackageModel.make(type: 'bits', url: 'foobar') }

        it 'includes a link to upload' do
          json_result = PackagePresenter.new.present_json(package)
          result      = MultiJson.load(json_result)

          expect(result['_links']['upload']['href']).to eq("/v3/packages/#{package.guid}/upload")
        end
      end

      context 'when the package type is not bits' do
        let(:package) { PackageModel.make(type: 'docker', url: 'foobar') }

        it 'does NOT include a link to upload' do
          json_result = PackagePresenter.new.present_json(package)
          result      = MultiJson.load(json_result)

          expect(result['_links']['upload']).to be_nil
        end
      end
    end

    describe '#present_json_list' do
      let(:pagination_presenter) { double(:pagination_presenter) }
      let(:package1) { PackageModel.make }
      let(:package2) { PackageModel.make }
      let(:packages) { [package1, package2] }
      let(:presenter) { PackagePresenter.new(pagination_presenter) }
      let(:page) { 1 }
      let(:per_page) { 1 }
      let(:total_results) { 2 }
      let(:paginated_result) { PaginatedResult.new(packages, total_results, PaginationOptions.new(page, per_page)) }
      before do
        allow(pagination_presenter).to receive(:present_pagination_hash) do |_, url|
          "pagination-#{url}"
        end
      end

      it 'presents the packages as a json array under resources' do
        json_result = presenter.present_json_list(paginated_result, 'potato')
        result      = MultiJson.load(json_result)

        guids = result['resources'].collect { |package_json| package_json['guid'] }
        expect(guids).to eq([package1.guid, package2.guid])
      end

      it 'includes pagination section' do
        json_result = presenter.present_json_list(paginated_result, 'bazooka')
        result      = MultiJson.load(json_result)

        expect(result['pagination']).to eq('pagination-bazooka')
      end
    end
  end
end
