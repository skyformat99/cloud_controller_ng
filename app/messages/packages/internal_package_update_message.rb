require 'messages/base_message'
require 'messages/checksum'

module VCAP::CloudController
  class InternalPackageUpdateMessage < BaseMessage
    ALLOWED_KEYS = [:state, :checksums, :error].freeze

    attr_accessor(*ALLOWED_KEYS)

    def self.create_from_http_request(body)
      InternalPackageUpdateMessage.new(body.deep_symbolize_keys)
    end

    validates_with NoAdditionalKeysValidator

    validate :requested_state
    validates :error, length: { in: 1..500, message: 'must be between 1 and 500 characters', allow_nil: true }
    validates :checksums, presence: { message: 'required when setting state to READY' }, if: :requested_ready?
    validate :checksums_data, if: :requested_checksum?

    def sha1
      sha1_hash = checksums.find { |checksum| checksum[:type] == Checksum::SHA1 }
      HashUtils.dig(sha1_hash, :value)
    end

    def sha256
      sha256_hash = checksums.find { |checksum| checksum[:type] == Checksum::SHA256 }
      HashUtils.dig(sha256_hash, :value)
    end

    private

    def allowed_keys
      ALLOWED_KEYS
    end

    def requested_state
      unless [PackageModel::PENDING_STATE, PackageModel::READY_STATE, PackageModel::FAILED_STATE].include?(state)
        errors.add(:state, 'must be one of PROCESSING_UPLOAD, READY, FAILED')
      end
    end

    def requested_ready?
      state == PackageModel::READY_STATE
    end

    def requested_checksum?
      checksums.present?
    end

    def checksums_data
      unless checksums.is_a?(Array) && checksums.each { |checksum| checksum.is_a?(Hash) }
        errors.add(:checksums, message: 'has invalid structure')
      end

      if errors[:checksums].empty?
        checksum_messages = checksums.map { |checksum| Checksum.new(checksum.deep_symbolize_keys) }
        errors[:checksums].concat(checksum_messages.select(&:invalid?).map { |checksum| checksum.errors.full_messages }.flatten)
      end

      unless checksums.length == 2 && sha1 && sha256
        errors.add(:checksums, 'both sha1 and sha256 checksums must be provided')
      end
    end
  end
end
