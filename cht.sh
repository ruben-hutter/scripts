#!/usr/bin/env bash

languages=$(echo "python java c cpp rust go lua" | tr ' ' '\n')
core_utils=$(echo "xargs sed awk find grep echo" | tr ' ' '\n')

selected=$(printf "$languages\n$core_utils" | fzf)
read -p "Enter query: " query

if echo "$languages" | grep -qs "$selected"; then
    curl -s "cheat.sh/$selected/$(echo $query | tr ' ' '+')" & while [ : ]; do sleep 1; done
else
    curl "cheat.sh/$selected/$query" & while [ : ]; do sleep 1; done
fi
