Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Aggregated MCP endpoint (Streamable HTTP)
  post "/mcp", to: "mcp#create"
  get "/mcp", to: "mcp_stream#show"

  # Admin UI
  root "dashboard#show"
  resource :session, only: %i[new create destroy]
  get "login", to: "sessions#new"
  resources :mcp_servers do
    member do
      post :refresh
      patch :toggle
    end
    resources :tool_policies, only: [] do
      collection { patch :toggle }
    end
  end
  resources :gateway_tokens, only: %i[index new create] do
    member { patch :revoke }
  end
  resources :call_logs, only: :index
  get "connect", to: "connect#show"
end
