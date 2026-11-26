class GatewayToken < ApplicationRecord
  has_many :call_logs, dependent: :nullify

  validates :name, presence: true, length: { maximum: 100 }
  validates :token_digest, presence: true, uniqueness: true

  scope :active, -> { where(revoked_at: nil) }

  def self.digest(plaintext) = Digest::SHA256.hexdigest(plaintext.to_s)

  # Returns [record, plaintext]. The plaintext is never stored.
  def self.generate!(name:)
    plaintext = "mcpgw_#{SecureRandom.urlsafe_base64(32)}"
    [ create!(name: name, token_digest: digest(plaintext)), plaintext ]
  end

  def self.authenticate(plaintext)
    return nil if plaintext.blank?
    token = active.find_by(token_digest: digest(plaintext))
    token&.touch_last_used!
    token
  end

  def revoked? = revoked_at.present?
  def revoke! = update!(revoked_at: Time.current)

  def touch_last_used!
    return if last_used_at && last_used_at > 1.minute.ago
    update_column(:last_used_at, Time.current)
  end
end
