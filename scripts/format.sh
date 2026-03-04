#! /usr/bin/env bash

## Get directory of the script itself: https://stackoverflow.com/a/246128/2137320
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

clang-format -i $DIR/../main.c

stylua $DIR/../lua/*.lua