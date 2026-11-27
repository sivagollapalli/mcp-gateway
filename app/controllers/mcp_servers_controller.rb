class McpServersController < ApplicationController
  before_action :set_server, only: %i[show edit update destroy refresh toggle]

  def index
    @servers = McpServer.order(:name)
  end

  def show
    @disabled = @server.disabled_tool_names.to_set
  end

  def new
    @server = McpServer.new(auth_type: "none", enabled: true)
  end

  def create
    @server = McpServer.new(server_params)
    if @server.save
      redirect_to @server, notice: "Server created. Discovering tools in the background."
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit; end

  def update
    attrs = server_params
    attrs = attrs.except(:auth_token) if attrs[:auth_token].blank? # blank keeps the stored secret
    attrs = attrs.except(:exchange_client_secret) if attrs[:exchange_client_secret].blank?
    if @server.update(attrs)
      redirect_to @server, notice: "Server updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    @server.destroy
    redirect_to mcp_servers_path, notice: "Server deleted.", status: :see_other
  end

  def refresh
    ok = @server.refresh_tools!
    @server.reload
    @disabled = @server.disabled_tool_names.to_set
    if ok
      flash.now[:notice] = "Connected to #{@server.name}: #{@server.tools_count} tools."
    else
      flash.now[:alert] = "Connection to #{@server.name} failed: #{@server.last_error}"
    end
    respond_to do |format|
      format.turbo_stream
      format.html { redirect_back fallback_location: @server, status: :see_other, flash: flash.to_hash }
    end
  end

  def toggle
    @server.update!(enabled: !@server.enabled)
    respond_to do |format|
      format.turbo_stream
      format.html { redirect_back fallback_location: mcp_servers_path, status: :see_other }
    end
  end

  private

  def set_server
    @server = McpServer.find(params[:id])
  end

  def server_params
    params.expect(mcp_server: %i[name url auth_type auth_token enabled description
                                 exchange_issuer exchange_client_id exchange_client_secret exchange_audience
                                 exchange_scope default_tool_scope tool_scopes_text])
  end
end
