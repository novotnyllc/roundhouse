# shellcheck shell=bash

fleet_merge3() {
  # State words: enabled, disabled, absent (tombstone), missing, unknown.
  # An ignored baseline is passed as ignored:<state>.
  local base=$1 ours=$2 theirs=$3
  if [ "$ours" = unknown ]; then
    printf 'unknown\n'
  elif [[ $base == ignored:* ]]; then
    if [ "$theirs" = missing ]; then
      if [ "$ours" = absent ]; then printf 'forget\n'; else printf 'ignore\n'; fi
    elif [ "$ours" = "$theirs" ]; then
      printf 'agree\n'
    elif [ "$ours" = "${base#ignored:}" ]; then
      printf 'converge\n'
    else
      printf 'conflict\n'
    fi
  elif [ "$theirs" = missing ]; then
    if [ "$base" != missing ]; then
      printf 'ignore\n'
    elif [ "$ours" = absent ]; then
      printf 'same\n'
    else
      printf 'local\n'
    fi
  elif [ "$ours" = "$base" ]; then
    if [ "$theirs" = "$base" ]; then printf 'same\n'; else printf 'converge\n'; fi
  elif [ "$theirs" = "$base" ] || { [ "$base" = missing ] && [ "$ours" = absent ] && [ "$theirs" != absent ]; }; then
    if [ "$base" = missing ]; then printf 'converge\n'; else printf 'local\n'; fi
  elif [ "$ours" = "$theirs" ]; then
    printf 'agree\n'
  else
    printf 'conflict\n'
  fi
}
