ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=29
FROM elixir:${ELIXIR_VERSION}-otp-${OTP_VERSION}-slim AS build

ENV MIX_ENV=prod LANG=C.UTF-8 ERL_FLAGS="+S 2:2"
RUN apt-get update && apt-get install -y --no-install-recommends build-essential ca-certificates git && rm -rf /var/lib/apt/lists/* && mix local.hex --force && mix local.rebar --force
WORKDIR /app

COPY mix.exs mix.lock ./
COPY config ./config
RUN mix deps.get --only prod && mix deps.compile

COPY assets ./assets
COPY lib ./lib
COPY priv ./priv
RUN mix compile --warnings-as-errors && mix assets.setup && mix assets.deploy && mix release

FROM debian:trixie-slim AS runtime
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 MIX_ENV=prod PHX_SERVER=true PORT=4000 ERL_FLAGS="+S 2:2"
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl libstdc++6 libncurses6 libsctp1 openssl sqlite3 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/_build/prod/rel/still ./
COPY --chmod=755 docker/start.sh /app/bin/local-start
EXPOSE 4000
STOPSIGNAL SIGTERM
ENTRYPOINT ["/app/bin/local-start"]
