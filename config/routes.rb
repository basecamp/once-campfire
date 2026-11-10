Rails.application.routes.draw do
  root "welcome#show"

  resource :first_run

  resource :session do
    scope module: "sessions" do
      resources :transfers, only: %i[ show update ]
    end
  end

  # OIDC callbacks (OmniAuth handles /auth/:provider request phase via middleware)
  get "auth/:provider/callback", to: "sso_sessions#create", as: :sso_callback
  get "auth/failure", to: "sso_sessions#failure", as: :sso_failure

  namespace :internal do
    namespace :backlit do
      resources :users, only: %i[ create update ], param: :sub
      resources :rooms, only: %i[ create update ] do
        member do
          post :archive
          post :memberships
          delete :memberships, action: :revoke_memberships
        end
      end
    end
  end

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

  get "join/:join_code", to: "users#new", as: :join
  post "join/:join_code", to: "users#create"

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

  # Keep static /rooms/* paths ahead of resources :rooms so "archived" is not treated as an id.
  namespace :rooms do
    resources :opens
    resources :closeds
    resources :directs
    resources :archived, only: %i[ index show ]
  end

  resources :rooms do
    resources :messages

    nested do
      scope path: ":bot_key", as: :bot, defaults: { format: :json } do
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
end
