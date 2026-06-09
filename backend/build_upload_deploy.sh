#!/bin/bash
exec "$(cd "$(dirname "$0")" && pwd)/publish.sh" "$@"
