# Image for the sample MCP servers (orders / payments). Pick the server with the command.
ARG RUBY_VERSION=4.0.5
FROM docker.io/library/ruby:$RUBY_VERSION-slim
RUN apt-get update -qq && apt-get install --no-install-recommends -y build-essential && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle config set --local without test && bundle install
COPY lib ./lib
COPY orders ./orders
COPY payments ./payments
RUN useradd --system --uid 1000 app
USER 1000
ENV HOST=0.0.0.0
CMD ["bundle", "exec", "ruby", "orders/server.rb"]
