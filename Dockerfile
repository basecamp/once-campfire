# syntax = docker/dockerfile:1@sha256:87999aa3d42bdc6bea60565083ee17e86d1f3339802f543c0d03998580f9cb89

# Make sure it matches the Ruby version in .ruby-version
FROM docker.io/library/ruby:3.4.5-slim@sha256:f1cca61013f823406e5ec23d3b8804ee0ba916febbfee089e647db93e8e749c7 AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libsqlite3-0 libvips libjemalloc2 ffmpeg redis && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archive

# Set production environment
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    CAMPFIRE_OPERATION_LOCK_ROOT="/tmp/campfire-operation-locks" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"


# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages need to build gems
RUN apt-get update -qq && \
    apt-get install -y build-essential git pkg-config libsqlite3-dev libyaml-dev libssl-dev && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY Gemfile Gemfile.lock ./
COPY vendor ./vendor

RUN bundle install && \
    bundle exec ruby -r sqlite3 -r campfire_sqlite_native -r tmpdir -e \
      'Dir.mktmpdir { |dir| path = File.join(dir, "native.sqlite3"); db = SQLite3::Database.new(path); abort "campfire_sqlite_native verification failed" if CampfireSQLiteNative.main_database_moved?(db); File.rename(path, "#{path}.moved"); abort "campfire_sqlite_native move detection failed" unless CampfireSQLiteNative.main_database_moved?(db); db.close }' && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

# Copy application code
COPY . .

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

ARG GIT_REVISION
ARG BUILD_IDENTITY
RUN test "${#GIT_REVISION}" -eq 40 && \
    test -z "$(printf '%s' "$GIT_REVISION" | tr -d '0-9a-f')" && \
    test "${#BUILD_IDENTITY}" -eq 64 && \
    test -z "$(printf '%s' "$BUILD_IDENTITY" | tr -d '0-9a-f')" && \
    printf '{"format_version":1,"revision":"%s","build_identity":"%s"}\n' \
      "$GIT_REVISION" "$BUILD_IDENTITY" > /tmp/campfire-build-identity.json


# Final stage for app image
FROM base

# Image metadata
ARG OCI_DESCRIPTION
ARG OCI_SOURCE
ARG APP_VERSION
ARG GIT_REVISION
ARG BUILD_IDENTITY
LABEL org.opencontainers.image.title="Campfire" \
      org.opencontainers.image.description="${OCI_DESCRIPTION}" \
      org.opencontainers.image.source="${OCI_SOURCE}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_REVISION}" \
      com.basecamp.campfire.build-identity="${BUILD_IDENTITY}"

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    install -d --mode=1777 /tmp/campfire-operation-locks
USER 1000:1000

# Configure environment defaults
ENV HTTP_IDLE_TIMEOUT=60
ENV HTTP_READ_TIMEOUT=300
ENV HTTP_WRITE_TIMEOUT=300
ENV MAX_REQUEST_BODY=106954752

# Copy built artifacts: gems, application
COPY --from=build --chown=rails:rails /usr/local/bundle /usr/local/bundle
COPY --from=build --chown=rails:rails /rails /rails
COPY --from=build /tmp/campfire-build-identity.json /etc/campfire-build-identity.json

# Set version and revision
ENV APP_VERSION=$APP_VERSION
ENV GIT_REVISION=$GIT_REVISION

# Expose ports for HTTP and HTTPS
EXPOSE 80 443

# Start the server by default, this can be overwritten at runtime
CMD ["bin/boot"]
