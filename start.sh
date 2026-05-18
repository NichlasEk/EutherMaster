#!/usr/bin/env sh

set -eu

cd "$(dirname "$0")"
export RUBY_YJIT_ENABLE="${RUBY_YJIT_ENABLE:-1}"
exec bundle exec ruby bin/crystal "$@"
