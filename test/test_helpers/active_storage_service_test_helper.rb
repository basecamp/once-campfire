class PathlessActiveStorageTestService < ActiveStorage::Service
  attr_reader :delegate_service

  def initialize(delegate_service:)
    @delegate_service = delegate_service
  end

  def upload(...)
    delegate_service.upload(...)
  end

  def update_metadata(...)
    delegate_service.update_metadata(...)
  end

  def download(...)
    delegate_service.download(...)
  end

  def download_chunk(...)
    delegate_service.download_chunk(...)
  end

  def open(...)
    delegate_service.open(...)
  end

  def compose(...)
    delegate_service.compose(...)
  end

  def delete(...)
    delegate_service.delete(...)
  end

  def delete_prefixed(...)
    delegate_service.delete_prefixed(...)
  end

  def exist?(...)
    delegate_service.exist?(...)
  end

  def url(...)
    delegate_service.url(...)
  end

  def url_for_direct_upload(...)
    delegate_service.url_for_direct_upload(...)
  end

  def headers_for_direct_upload(...)
    delegate_service.headers_for_direct_upload(...)
  end
end

module ActiveStorageServiceTestHelper
  class AdditionalActiveStorageServices
    def initialize(delegate_registry:, extra_services:)
      @delegate_registry = delegate_registry
      @extra_services = extra_services.transform_keys(&:to_sym)
    end

    def fetch(name, &block)
      @extra_services.fetch(name.to_sym) do
        @delegate_registry.fetch(name, &block)
      end
    end
  end

  def with_pathless_active_storage_service
    original_service = ActiveStorage::Blob.service
    original_services = ActiveStorage::Blob.services

    pathless_service = PathlessActiveStorageTestService.new(delegate_service: original_services.fetch(:test))
    pathless_service.name = :pathless_test

    ActiveStorage::Blob.services = AdditionalActiveStorageServices.new(
      delegate_registry: original_services,
      extra_services: { pathless_test: pathless_service }
    )
    ActiveStorage::Blob.service = pathless_service

    yield
  ensure
    ActiveStorage::Blob.service = original_service
    ActiveStorage::Blob.services = original_services
  end
end
