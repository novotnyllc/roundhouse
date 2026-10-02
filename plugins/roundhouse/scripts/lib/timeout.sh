# roundhouse — bounded external commands.
#
# Every query a pass asks a package or agent manager (brew, npm, fnm, apt,
# jsm, claude, codex, chezmoi, …) can hang: one did, inside `jsm --json
# --offline list`, for ~37 hours, holding the run lock the whole time. Each
# such call goes through run_bounded with a ceiling sized to what it does —
# a listing gets about a minute, a real install much longer — and a call that
# reaches it is stopped together with every process it started, and answers
# 124. Callers read 124 as "this manager's state is UNKNOWN this pass":
# fail closed for that manager, alert, and let the rest of the pass run.
#
# macOS ships no GNU `timeout` everywhere, so the bound is perl's alarm (in
# every macOS and every mainstream Linux base system) around a child that
# leads its own process group, with a background watchdog as the fallback.
#
# Sourced by scripts/roundhouse and scripts/collect-posix; definitions only.
# shellcheck shell=bash

run_bounded_seconds() {
  # `run_bounded_seconds list|install` — the ceiling for that kind of call.
  # The self-check may SHORTEN both (a fake manager that never answers has
  # to time out inside a test); nothing else may move them.
  if [ "${ROUNDHOUSE_SELFTEST:-0}" = 1 ] &&
    [ -n "${ROUNDHOUSE_TEST_QUERY_TIMEOUT:-}" ]; then
    printf '%s\n' "$ROUNDHOUSE_TEST_QUERY_TIMEOUT"
    return
  fi
  case ${1:-list} in
    install) printf '1800\n' ;;
    *) printf '60\n' ;;
  esac
}

run_bounded() {
  # `run_bounded SECONDS COMMAND [ARG...]` — COMMAND's output and exit status,
  # or 124 when it was still running after SECONDS: then it and every process
  # it started get TERM, up to two seconds, then KILL. A TERM, INT or HUP to
  # this call stops the command the same way, so a stopped pass leaves nothing
  # behind. When `run_bounded_log` names a file, each TIMEOUT (never a command
  # that merely exits 124 itself) appends one `SECONDS COMMAND` line to it:
  # how a caller several functions up tells a hung manager from one that
  # answered with an error.
  #
  # Without a controlling terminal (every scheduled run) the command leads a
  # process group of its own, and the group goes with it. WITH one, it stays
  # in the terminal's foreground group — a command that reads or configures
  # the tty (a sudo prompt, a raw-mode CLI) would otherwise be stopped by the
  # terminal and sit out the ceiling — and is stopped by walking its process
  # tree instead.
  run_bounded_secs=$1
  shift
  case $(type -t "$1" 2>/dev/null) in
    function) run_bounded_watchdog "$@"; return ;;
  esac
  if command -v perl >/dev/null 2>&1; then
    perl -e '
      use POSIX ();
      my $t = shift @ARGV;
      my $log = shift @ARGV;
      my $tty = open(my $ttyfh, "<", "/dev/tty") ? 1 : 0;
      close($ttyfh) if $tty;
      my $pid = fork();
      exit 125 unless defined $pid;
      if ($pid == 0) {
        setpgrp(0, 0) unless $tty;
        exec { $ARGV[0] } @ARGV;
        exit 127;
      }
      my $tree = sub {
        my %kids;
        for (`ps -A -o pid= -o ppid= 2>/dev/null`) {
          my ($p, $pp) = split;
          push @{ $kids{$pp} }, $p if defined $pp;
        }
        my @q = ($pid);
        my @out;
        while (@q) { my $x = shift @q; push @out, $x; push @q, @{ $kids{$x} || [] }; }
        return @out;
      };
      my $signal = sub {
        my $s = shift;
        my @t = $tree->();
        kill($s, -$pid) unless $tty;
        kill($s, @t);
      };
      my $stop = sub {
        $signal->("TERM");
        for (1 .. 20) {
          last if waitpid($pid, POSIX::WNOHANG()) > 0;
          select(undef, undef, undef, 0.1);
        }
        $signal->("KILL");
        waitpid($pid, 0);
      };
      $SIG{ALRM} = sub {
        $stop->();
        if ($log ne "" && open(my $l, ">>", $log)) {
          my $name = $ARGV[0]; $name =~ s{.*/}{};
          print $l "$t $name\n";
          close($l);
        }
        exit 124;
      };
      $SIG{TERM} = sub { $stop->(); exit 143; };
      $SIG{INT}  = sub { $stop->(); exit 130; };
      $SIG{HUP}  = sub { $stop->(); exit 129; };
      alarm $t;
      waitpid($pid, 0);
      my $rc = $?;
      alarm 0;
      exit(($rc & 127) ? 128 + ($rc & 127) : ($rc >> 8));
    ' "$run_bounded_secs" "${run_bounded_log:-}" "$@"
    return
  fi
  run_bounded_watchdog "$@"
}

run_bounded_tree() {
  # `run_bounded_tree PID` — PID and every descendant, one `ps` of the table.
  ps -A -o pid= -o ppid= 2>/dev/null | awk -v root="$1" '
    { kids[$2] = kids[$2] " " $1 }
    END {
      n = 1; q[1] = root
      for (i = 1; i <= n; i++) {
        m = split(kids[q[i]], k, " ")
        for (j = 1; j <= m; j++) if (k[j] != "") q[++n] = k[j]
      }
      for (i = 1; i <= n; i++) printf "%s ", q[i]
    }'
}

run_bounded_watchdog() {
  # No perl, or a shell function (a test's stub, which cannot be exec'd): the
  # command in the background with this shell's stdin (a background job's is
  # /dev/null otherwise), a watchdog beside it, and the whole tree stopped on
  # a timeout. The mark file is what tells a timeout from the command's own
  # 143. (A signal to this shell is not forwarded here; only the perl path
  # does that.)
  run_bounded_mark=$(mktemp "${TMPDIR:-/tmp}/roundhouse-bounded.XXXXXX") || return 125
  rm -f "$run_bounded_mark"
  "$@" 0<&0 &
  run_bounded_pid=$!
  (
    # Its own sleep is stopped with it, so a command that finished early
    # leaves no watchdog sleeping out the rest of the ceiling.
    run_bounded_sleep=
    trap 'kill "$run_bounded_sleep" 2>/dev/null; exit 0' TERM
    sleep "$run_bounded_secs" &
    run_bounded_sleep=$!
    # Only a sleep that RAN OUT is a timeout; one stopped because the
    # command finished is not.
    wait "$run_bounded_sleep" || exit 0
    : >"$run_bounded_mark"
    # shellcheck disable=SC2046 # one pid per word
    kill -TERM $(run_bounded_tree "$run_bounded_pid") 2>/dev/null || :
    sleep 2
    # shellcheck disable=SC2046 # one pid per word
    kill -KILL $(run_bounded_tree "$run_bounded_pid") 2>/dev/null || :
  ) >/dev/null 2>&1 &
  run_bounded_watch=$!
  run_bounded_wrc=0
  { wait "$run_bounded_pid"; } 2>/dev/null || run_bounded_wrc=$?
  pkill -TERM -P "$run_bounded_watch" 2>/dev/null || :
  kill "$run_bounded_watch" 2>/dev/null || :
  pkill -TERM -P "$run_bounded_watch" 2>/dev/null || :
  wait "$run_bounded_watch" 2>/dev/null || :
  if [ -f "$run_bounded_mark" ]; then
    rm -f "$run_bounded_mark"
    [ -z "${run_bounded_log:-}" ] ||
      printf '%s %s\n' "$run_bounded_secs" "${1##*/}" >>"$run_bounded_log" 2>/dev/null || :
    return 124
  fi
  return "$run_bounded_wrc"
}

bounded_query() {
  # `bounded_query COMMAND [ARG...]` — a manager QUERY (a listing, an
  # inventory, a status) under the listing ceiling.
  run_bounded "$(run_bounded_seconds list)" "$@"
}

bounded_verb() {
  # `bounded_verb COMMAND [ARG...]` — a manager VERB that may download and
  # install (install, update, upgrade, marketplace refresh) under the install
  # ceiling. Still a ceiling: an install that never returns is stopped too.
  run_bounded "$(run_bounded_seconds install)" "$@"
}
