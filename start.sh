#!/usr/bin/env sh

set -eu

cd "$(dirname "$0")"
exec bundle exec ruby bin/crystal "$@"
