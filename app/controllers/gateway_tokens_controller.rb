class GatewayTokensController < ApplicationController
  def index
    @tokens = GatewayToken.order(created_at: :desc)
  end

  def new
    @token = GatewayToken.new
  end

  def create
    name = params.dig(:gateway_token, :name).to_s.strip
    if name.blank?
      @token = GatewayToken.new
      @token.errors.add(:name, "can't be blank")
      return render :new, status: :unprocessable_content
    end
    @token, @plaintext = GatewayToken.generate!(name: name)
    response.set_header("Cache-Control", "no-store")
    render :created # rendered directly so the plaintext never goes through session/redirect
  end

  def revoke
    GatewayToken.find(params[:id]).revoke!
    redirect_to gateway_tokens_path, notice: "Token revoked.", status: :see_other
  end
end
