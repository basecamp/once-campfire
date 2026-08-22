Rails.application.routes.draw do
  root "welcome#show"

  resource :first_run

  post "auth/openid_connect", to: "oidc/sessions#new", as: :openid_connect, format: false
  get "auth/openid_connect/callback", to: "oidc/sessions#create", format: false
  post "auth/openid_connect/backchannel_logout", to: "oidc/back_channel_logouts#create",
    as: :oidc_back_channel_logout, format: false
  get "auth/failure", to: "oidc/sessions#failure", format: false
  resource :oidc_link, only: %i[ show update ], controller: "oidc/links", format: false
  resource :oidc_flow, only: %i[ show destroy ], controller: "oidc/flows", format: false

  scope "/scim/v2", module: "scim/v2", as: "scim_v2", format: false do
    get "ServiceProviderConfig", to: "service_provider_configs#show", as: :service_provider_config
    get "Users", to: "users#index", as: :users
    get "Users/:id", to: "users#show", as: :user
    patch "Users/:id", to: "users#update"
    delete "Users/:id", to: "users#destroy"
  end

  resource :session
  get "session/transfer", to: "sessions/transfers#show", as: :session_transfer
  post "session/transfer/intent", to: "sessions/transfers#intent", as: :session_transfer_intent
  put "session/transfer", to: "sessions/transfers#update"

  resource :account do
    scope module: "accounts" do
      resources :users

      resources :bots do
        scope module: "bots" do
          resource :key, only: :update
        end
      end

      resource :join_code, only: :create
      resource :logo, only: %i[ show destroy ]
      resource :custom_styles, only: %i[ edit update ]
    end
  end

  direct :fresh_account_logo do |options|
    route_for :account_logo, v: Current.account&.updated_at&.to_fs(:number), size: options[:size]
  end

  get "join", to: "users#new", as: :join
  post "join/intent", to: "users/join_intents#create", as: :join_intent
  post "join", to: "users#create"

  resources :qr_code, only: :show

  resources :users, only: :show do
    scope module: "users" do
      resource :avatar, only: %i[ show destroy ]
      resource :ban, only: %i[ create destroy ]

      scope defaults: { user_id: "me" } do
        resource :sidebar, only: :show
        resource :profile
        resources :push_subscriptions do
          scope module: "push_subscriptions" do
            resources :test_notifications, only: :create
          end
        end
      end
    end
  end

  namespace :autocompletable do
    resources :users, only: :index
  end

  direct :fresh_user_avatar do |user, options|
    route_for :user_avatar, user.avatar_token, v: user.updated_at.to_fs(:number)
  end

  resources :rooms do
    resources :messages do
      get :reconciliation, on: :collection
      resource :attachment, only: :show, module: :messages
    end

    nested do
      scope path: "bot", as: :bot, defaults: { format: :json } do
        resources :messages, controller: "messages/by_bots", only: %i[ index create update destroy ] do
          resources :boosts, controller: "messages/boosts/by_bots", only: %i[ create destroy ]
        end
      end
    end

    scope module: "rooms" do
      resource :refresh, only: :show
      resource :settings, only: :show
      resource :involvement, only: %i[ show update ]
    end

    get "@:message_id", to: "rooms#show", as: :at_message
  end

  namespace :rooms do
    resources :opens
    resources :closeds
    resources :directs
  end

  resources :messages do
    scope module: "messages" do
      resources :boosts
    end
  end

  resources :searches, only: %i[ index create ] do
    delete :clear, on: :collection
  end

  resource :unfurl_link, only: :create

  get "webmanifest"    => "pwa#manifest"
  get "service-worker" => "pwa#service_worker"

  get "up" => "rails/health#show", as: :rails_health_check
  get "up/oidc" => "oidc/readiness#show", as: :oidc_readiness_check, format: false
  get "up/scim" => "scim/readiness#show", as: :scim_readiness_check, format: false
  get "up/work" => "reliable_work/readiness#show", as: :reliable_work_readiness_check
end
